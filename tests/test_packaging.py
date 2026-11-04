"""Check the Shell packaging pipeline's payload and APK Tools invocation."""
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
FAKE_APK = '''#!/usr/bin/env python3
import json
from pathlib import Path
import stat
import sys
args = sys.argv[1:]
assert args.pop(0) == 'mkpkg'
info = {}; scripts = {}; payload = None; output = None
while args:
    key, value = args.pop(0), args.pop(0)
    if key == '--info':
        name, content = value.split(':', 1)
        assert name not in info
        info[name] = content
    elif key == '--script':
        name, filename = value.split(':', 1)
        scripts[name] = Path(filename).read_text()
    elif key == '--files': payload = Path(value)
    elif key == '--output': output = Path(value)
    else: raise ValueError(key)
files = {str(p.relative_to(payload)): stat.S_IMODE(p.stat().st_mode)
         for p in payload.rglob('*') if p.is_file()}
output.write_text(json.dumps({'info': info, 'scripts': scripts, 'files': files,
    'filelist': (payload / 'lib/apk/packages/luci-app-honk.list').read_text(),
    'conffiles': (payload / 'lib/apk/packages/luci-app-honk.conffiles').read_text()}))
'''


class PackagingTests(unittest.TestCase):
    def test_apk_script_preserves_dependencies_modes_and_hooks(self):
        with tempfile.TemporaryDirectory(prefix='honk-package-test.') as directory:
            root = Path(directory).resolve()
            for name in ['root', 'htdocs', '.github/scripts']:
                shutil.copytree(ROOT / name, root / name)
            for name in ['Makefile', 'LICENSE']:
                shutil.copyfile(ROOT / name, root / name)
            tools = root / 'tools'
            tools.mkdir()
            (tools / 'apk').write_text(FAKE_APK)
            (tools / 'apk').chmod(0o755)
            (tools / 'fakeroot').write_text('#!/bin/sh\nexec "$@"\n')
            (tools / 'fakeroot').chmod(0o755)
            env = {**os.environ, 'TOOLS_DIR': str(tools), 'RELEASE_TAG': 'v0.1.0',
                   'PATH': str(tools) + os.pathsep + os.environ['PATH']}
            subprocess.run(['bash', str(root / '.github/scripts/build-apk.sh')],
                           env=env, check=True, capture_output=True, text=True)
            artifact = root / 'dist/luci-app-honk-0.1.0-r1.apk'
            metadata = json.loads(artifact.read_text())
            self.assertEqual(metadata['info']['name'], 'luci-app-honk')
            self.assertEqual(metadata['info']['version'], '0.1.0-r1')
            self.assertEqual(metadata['info']['arch'], 'noarch')
            deps = metadata['info']['depends'].split()
            for name in ['flock', 'curl', 'kmod-nft-queue', '!honk']:
                self.assertIn(name, deps)
            self.assertEqual(metadata['files']['etc/config/honk'], 0o600)
            self.assertEqual(metadata['files']['etc/honk/config.dae'], 0o600)
            for name in ['etc/init.d/honk', 'usr/libexec/rpcd/luci.honk', 'usr/libexec/honk-panel-worker']:
                self.assertEqual(metadata['files'][name], 0o755)
            self.assertIn('usr/share/licenses/luci-app-honk/LICENSE', metadata['files'])
            self.assertEqual(metadata['conffiles'].splitlines(), ['/etc/config/honk', '/etc/honk/config.dae'])
            self.assertEqual(set(metadata['filelist'].splitlines()), {'/' + name for name in metadata['files']})
            self.assertIn('export PKG_UPGRADE=1', metadata['scripts']['post-upgrade'])
            self.assertIn('default_postinst', metadata['scripts']['post-install'])
            self.assertIn('default_prerm', metadata['scripts']['pre-deinstall'])
            self.assertFalse(list((root / 'dist').glob('*.ipk')))


if __name__ == '__main__':
    unittest.main()

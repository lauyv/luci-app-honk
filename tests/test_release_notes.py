"""Check release-note ranges and literal multiline commit messages locally."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / '.github/scripts/release-notes.sh'


class ReleaseNotesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='honk-notes-test.')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / 'tools'
        self.bin.mkdir()
        self.releases = self.root / 'releases.tsv'
        self.releases.write_text('')
        fake_gh = self.bin / 'gh'
        fake_gh.write_text('#!/bin/sh\ncat "$TEST_RELEASES"\n')
        fake_gh.chmod(0o755)
        self.env = {**os.environ, 'PATH': str(self.bin) + os.pathsep + os.environ['PATH'],
            'TEST_RELEASES': str(self.releases), 'GH_REPO': 'owner/luci-app-honk',
            'NOTES_FILE': str(self.root / 'notes.md'),
            'GIT_AUTHOR_NAME': 'Test', 'GIT_AUTHOR_EMAIL': 'test@example.invalid',
            'GIT_COMMITTER_NAME': 'Test', 'GIT_COMMITTER_EMAIL': 'test@example.invalid',
            'GIT_CONFIG_GLOBAL': os.devnull, 'GIT_CONFIG_NOSYSTEM': '1'}
        self.git('init', '-q')
        self.commit('feat: first version')
        self.git('tag', 'v0.0.1')
        self.commit('fix: preserve config\n\nKeep $HOME, $(touch SHOULD_NOT_EXIST) and `literal` unchanged.')
        self.git('tag', 'v0.0.2')
        self.commit('docs: clarify core updates')
        self.env['BUILD_SHA'] = self.git('rev-parse', 'HEAD').strip()
        dist = self.root / 'dist'
        dist.mkdir()
        (dist / 'luci-app-honk-0.1.0-r1.apk').write_text('fixture')

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.root, env=self.env,
                                       text=True, stderr=subprocess.PIPE)

    def commit(self, text):
        message = self.root / 'message.txt'
        message.write_text(text)
        self.git('add', 'message.txt')
        self.git('commit', '-q', '-F', str(message))

    def run_notes(self):
        return subprocess.run(['bash', str(SCRIPT)], cwd=self.root, env=self.env,
                              text=True, capture_output=True)

    def test_first_release_preserves_all_commit_bodies_and_adds_apk_install(self):
        result = self.run_notes()
        self.assertEqual(result.returncode, 0, result.stderr)
        notes = Path(self.env['NOTES_FILE']).read_text()
        self.assertLess(notes.index('feat: first version'), notes.index('fix: preserve config'))
        self.assertLess(notes.index('fix: preserve config'), notes.index('docs: clarify core updates'))
        self.assertIn('Keep $HOME, $(touch SHOULD_NOT_EXIST) and `literal` unchanged.', notes)
        self.assertIn('apk add --allow-untrusted ./luci-app-honk-0.1.0-r1.apk', notes)
        self.assertNotIn('opkg', notes)
        self.assertFalse((self.root / 'SHOULD_NOT_EXIST').exists())

    def test_previous_release_is_selected_by_publication_time(self):
        # The later publication intentionally has the lower version number.
        self.releases.write_text('2026-10-01T00:00:00Z\tv0.0.2\n2026-11-01T00:00:00Z\tv0.0.1\n')
        result = self.run_notes()
        self.assertEqual(result.returncode, 0, result.stderr)
        notes = Path(self.env['NOTES_FILE']).read_text()
        self.assertNotIn('feat: first version', notes)
        self.assertIn('fix: preserve config', notes)
        self.assertIn('docs: clarify core updates', notes)

    def test_missing_previous_tag_stops_release_notes(self):
        self.releases.write_text('2026-11-01T00:00:00Z\tv9.9.9\n')
        result = self.run_notes()
        self.assertNotEqual(result.returncode, 0)

    def test_multiple_apks_stop_release_notes(self):
        (self.root / 'dist/luci-app-honk-0.0.9-r1.apk').write_text('old fixture')
        result = self.run_notes()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Expected exactly one APK', result.stderr)


if __name__ == '__main__':
    unittest.main()

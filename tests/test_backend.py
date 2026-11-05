"""Isolated shell tests. Fixtures never operate real services or download cores."""
import hashlib
import io
import json
import os
from pathlib import Path
import shlex
import struct
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
COMMON = ROOT / 'root/usr/share/honk-panel/common.sh'
DOWNLOAD = ROOT / 'root/usr/share/honk-panel/download.sh'
JSON_HELPER = ROOT / 'tests/json_fixture.py'

SETUP = r'''
. "$COMMON"
. "$DOWNLOAD"
RUN="$FIXTURE/run"
COREDIR="$FIXTURE/cores"
BIN="$COREDIR/honk-core"
BACKUP="$COREDIR/honk-core.old"
CONFIG="$FIXTURE/config.dae"
SERVICE_USER="$(id -un)"
mkdir -p "$RUN" "$COREDIR"
printf '%s' 'old config' > "$CONFIG"
chmod 640 "$CONFIG"
export TEST_CONFIG="$CONFIG"
settings() { [ ! -f "$FIXTURE/path-changed" ]; }
config_revision() { sha256sum "$CONFIG" | cut -d ' ' -f 1; }
run_timeout() { shift; if [ "${2:-}" = --version ]; then echo "honk-core v0.1.0-beta.5"; else "$@"; fi; }
service_snapshot() {
    [ ! -f "$FIXTURE/status-failure" ] || { ERROR=service_status_failed; return 1; }
    SERVICE_PID=''
    [ ! -f "$FIXTURE/running" ] || SERVICE_PID=$$
}
running_pid() { [ ! -f "$FIXTURE/running" ] || printf '%s' "$$"; }
stop_service() {
    printf 'stop\n' >> "$FIXTURE/actions"
    [ ! -f "$FIXTURE/stop-failure" ] || { ERROR=stop_failed; return 1; }
    rm -f "$FIXTURE/running"
}
run_service() {
    printf '%s\n' "$1" >> "$FIXTURE/actions"
    if [ -f "$FIXTURE/start-failure" ] && grep -q '^new core$' "$BIN"; then
        ERROR="$2"; DETAILS='new core failed'; return 1
    fi
    touch "$FIXTURE/running"
}
job() { :; }
CORE_STAGE=$(mktemp -d "$COREDIR/.update.XXXXXX")
jshn() { python3 "$JSON_HELPER" "$@"; }
jsonfilter() { python3 "$JSON_HELPER" filter "$@"; }
json_select() { local parsed; parsed=$(python3 "$JSON_HELPER" select "$1") || return 1; eval "$parsed"; export JSON_FIXTURE_PATH; }
json_get_keys() { eval "$(python3 "$JSON_HELPER" keys "$1")"; }
json_get_var() { eval "$(python3 "$JSON_HELPER" get "$1" "$2")"; }
json_init() { JSON_VERSIONS=''; }
json_add_array() { :; }
json_close_array() { :; }
json_add_string() { JSON_VERSIONS="$JSON_VERSIONS $2"; }
json_dump() { export JSON_VERSIONS; python3 "$JSON_HELPER" dump; }
export JSON_FIXTURE_FILE JSON_FIXTURE_PATH
expected=$(config_revision)
'''


class ShellTests(unittest.TestCase):
    def run_shell(self, body, files=None, expected_code=0):
        with tempfile.TemporaryDirectory(prefix='honk-test.') as directory:
            folder = Path(directory).resolve()
            directory = str(folder)
            for name, content in (files or {}).items():
                path = folder / name
                path.parent.mkdir(parents=True, exist_ok=True)
                if isinstance(content, bytes):
                    path.write_bytes(content)
                else:
                    path.write_text(content)
            result = subprocess.run(['sh', '-eu', '-c', SETUP + '\n' + body],
                env={**os.environ, 'COMMON': str(COMMON), 'DOWNLOAD': str(DOWNLOAD), 'JSON_HELPER': str(JSON_HELPER), 'FIXTURE': directory},
                capture_output=True, text=True)
            self.assertEqual(result.returncode, expected_code, result.stdout + result.stderr)
            return result.stdout

    def test_tag_validation(self):
        self.run_shell(r'''
for tag in v0.1.0 v0.1.0-beta.5 v1.2.3-rc.1; do valid_tag "$tag"; done
for tag in debug latest '../v1.0.0' 'v1.0.0;id' 'v1.0.0-beta.5/../../'; do
    if valid_tag "$tag"; then exit 1; fi
done
''')

    def test_proxy_prefix_validation(self):
        self.run_shell(r'''
valid_preferences ''
valid_preferences 'https://gh-proxy.com'
valid_preferences 'https://mirror.example/prefix/'
for proxy in 'http://mirror.example' 'https://user:password@host' 'https://host/?q=a' 'https://host/#x'; do
    if valid_preferences "$proxy"; then exit 1; fi
done
''')

    def test_asset_proxy_only_accepts_official_release_urls(self):
        self.run_shell(r'''
uci() {
    case "$*" in
        *proxy_prefix) echo https://gh-proxy.com/;;
    esac
}
url='https://github.com/daeuniverse/honk/releases/download/v0.1.0-beta.5/file.tar.gz'
[ "$(asset_url "$url")" = "https://gh-proxy.com/$url" ]
if asset_url https://evil.example/core; then exit 1; fi
''')

    def test_empty_proxy_prefix_is_direct_and_missing_option_uses_default(self):
        self.run_shell(r'''
url='https://github.com/daeuniverse/honk/releases/download/v0.1.0-beta.5/file.tar.gz'
uci() { return 0; }
[ "$(core_proxy_prefix)" = '' ]
[ "$(asset_url "$url")" = "$url" ]
uci() { return 1; }
[ "$(asset_url "$url")" = "https://gh-proxy.com/$url" ]
uci() { printf '%s' 'https://mirror.example/prefix/'; }
[ "$(asset_url "$url")" = "https://mirror.example/prefix/$url" ]
uci() { printf '%s' 'http://invalid.example'; }
if asset_url "$url"; then exit 1; fi
''')

    def test_checksum_requires_both_api_and_manifest(self):
        body = b'archive fixture'
        digest = hashlib.sha256(body).hexdigest()
        self.run_shell(f'''
ASSET_NAME=test.tar.gz
ASSET_DIGEST=sha256:{digest}
verify_archive "$FIXTURE/archive" "$FIXTURE/SHA256SUMS"
ASSET_DIGEST=sha256:{'0' * 64}
if verify_archive "$FIXTURE/archive" "$FIXTURE/SHA256SUMS"; then exit 1; fi
[ "$ERROR" = digest_mismatch ]
''', {'archive': body, 'SHA256SUMS': f'{digest}  test.tar.gz\n'})
        self.run_shell(f'''
ASSET_NAME=test.tar.gz
ASSET_DIGEST=sha256:{digest}
if verify_archive "$FIXTURE/archive" "$FIXTURE/SHA256SUMS"; then exit 1; fi
[ "$ERROR" = digest_mismatch ]
''', {'archive': body, 'SHA256SUMS': f"{'0' * 64}  test.tar.gz\n"})

    @staticmethod
    def archive(machine=183, kind='regular', duplicate=False):
        output = io.BytesIO()
        member = 'honk-core-v0.1.0-beta.5-aarch64-unknown-linux-musl-full/honk-core'
        binary = bytearray(128)
        binary[:6] = b'\x7fELF\x02\x01'
        binary[18:20] = struct.pack('<H', machine)
        with tarfile.open(fileobj=output, mode='w:gz') as archive:
            for _ in range(2 if duplicate else 1):
                info = tarfile.TarInfo(member)
                info.mode = 0o755
                if kind == 'symlink':
                    info.type = tarfile.SYMTYPE
                    info.linkname = '/etc/shadow'
                    archive.addfile(info)
                else:
                    info.size = len(binary)
                    archive.addfile(info, io.BytesIO(binary))
            # Extraneous traversal entries must never be extracted.
            info = tarfile.TarInfo('../../escaped')
            info.size = 1
            archive.addfile(info, io.BytesIO(b'x'))
        return output.getvalue()

    def test_extracts_only_exact_regular_binary_and_checks_architecture(self):
        self.run_shell(r'''
core_target() { echo aarch64-unknown-linux-musl; }
ASSET_NAME=honk-core-v0.1.0-beta.5-aarch64-unknown-linux-musl-full.tar.gz
extract_binary "$FIXTURE/archive" "$CORE_STAGE/candidate"
[ -x "$CORE_STAGE/candidate" ]
[ "$(wc -c < "$CORE_STAGE/candidate")" -eq 128 ]
[ ! -e "$FIXTURE/escaped" ]
''', {'archive': self.archive()})
        for body in [self.archive(machine=62), self.archive(kind='symlink'), self.archive(duplicate=True), b'bad gzip']:
            self.run_shell(r'''
core_target() { echo aarch64-unknown-linux-musl; }
ASSET_NAME=honk-core-v0.1.0-beta.5-aarch64-unknown-linux-musl-full.tar.gz
if extract_binary "$FIXTURE/archive" "$CORE_STAGE/candidate"; then exit 1; fi
''', {'archive': body})

    def test_save_does_not_invoke_core_or_require_valid_configuration(self):
        self.run_shell(r'''
printf '#!/bin/sh\ntouch "$FIXTURE/core-called"\nexit 1\n' > "$BIN"
chmod 700 "$BIN"
save_config 'invalid' "$expected"
[ "$(cat "$CONFIG")" = invalid ]
[ ! -e "$FIXTURE/core-called" ]
[ ! -e "$FIXTURE/actions" ]
[ -z "$SAVE_CANDIDATE" ]
''')

    def test_stopped_save_and_unchanged_save(self):
        self.run_shell(r'''
save_config 'new config' "$expected"
[ "$(cat "$CONFIG")" = 'new config' ]
[ "$SAVE_CODE" = config_saved ]
[ "$(ls -l "$CONFIG" | cut -c 1-10)" = '-rw-r-----' ]
[ ! -e "$FIXTURE/actions" ]
save_config 'new config' "$(config_revision)"
[ "$SAVE_CODE" = config_unchanged ]
[ ! -e "$FIXTURE/actions" ]
''')

    def test_concurrent_editor_changes_are_preserved(self):
        self.run_shell(r'''
stage_config() {
    local candidate
    candidate=$(mktemp "${CONFIG}.panel.XXXXXX")
    printf "%s" "$1" > "$candidate"
    echo external > "$CONFIG"
    echo "$candidate"
}
if save_config 'new config' "$expected"; then exit 1; fi
[ "$ERROR" = config_changed ]
[ "$(cat "$CONFIG")" = external ]
[ -z "$SAVE_CANDIDATE" ]
''')

    def test_running_save_restarts_and_reports_saved_revision_on_failure(self):
        self.run_shell(r'''
touch "$FIXTURE/running"
run_service() { ERROR=apply_failed; return 1; }
if save_config 'new config' "$expected"; then exit 1; fi
[ "$ERROR" = apply_failed ]
[ "$SAVE_REVISION" = "$(config_revision)" ]
[ "$(cat "$CONFIG")" = 'new config' ]
''')

    def test_initial_core_install_stays_stopped_even_if_config_invalid(self):
        self.run_shell(r'''
echo 'new core' > "$CORE_STAGE/candidate"
chmod 700 "$CORE_STAGE/candidate"
activate_core "$CORE_STAGE/candidate"
[ "$(cat "$BIN")" = 'new core' ]
[ ! -e "$FIXTURE/actions" ]
[ ! -e "$BACKUP" ]
''')

    def test_core_update_retains_previous_and_keeps_stopped_service_stopped(self):
        self.run_shell(r'''
echo 'old core' > "$BIN"; chmod 700 "$BIN"
echo 'new core' > "$CORE_STAGE/candidate"; chmod 700 "$CORE_STAGE/candidate"
activate_core "$CORE_STAGE/candidate"
[ "$(cat "$BIN")" = 'new core' ]
[ "$(cat "$BACKUP")" = 'old core' ]
[ ! -e "$FIXTURE/actions" ]
''')

    def test_failed_core_start_restores_old_core_and_running_state(self):
        self.run_shell(r'''
echo 'old core' > "$BIN"; chmod 700 "$BIN"
echo 'new core' > "$CORE_STAGE/candidate"; chmod 700 "$CORE_STAGE/candidate"
touch "$FIXTURE/running" "$FIXTURE/start-failure"
if activate_core "$CORE_STAGE/candidate"; then exit 1; fi
[ "$ERROR" = core_restored ]
[ "$(cat "$BIN")" = 'old core' ]
[ "$(cat "$BACKUP")" = 'old core' ]
[ -e "$FIXTURE/running" ]
[ "$(grep -c '^start$' "$FIXTURE/actions")" = 2 ]
''')

    def test_stop_failure_never_replaces_current_core(self):
        self.run_shell(r'''
echo 'old core' > "$BIN"; chmod 700 "$BIN"
echo 'new core' > "$CORE_STAGE/candidate"; chmod 700 "$CORE_STAGE/candidate"
touch "$FIXTURE/running" "$FIXTURE/stop-failure"
if activate_core "$CORE_STAGE/candidate"; then exit 1; fi
[ "$ERROR" = stop_failed ]
[ "$(cat "$BIN")" = 'old core' ]
''')

    def test_rollback_swaps_versions(self):
        self.run_shell(r'''
echo 'new core' > "$BIN"; chmod 700 "$BIN"
echo 'old core' > "$BACKUP"; chmod 700 "$BACKUP"
rollback_core
[ "$(cat "$BIN")" = 'old core' ]
[ "$(cat "$BACKUP")" = 'new core' ]
[ ! -e "$FIXTURE/actions" ]
''')

    def test_core_directory_symlinks_are_rejected(self):
        self.run_shell(r'''
mkdir "$FIXTURE/elsewhere"
COREDIR="$FIXTURE/redirected"
ln -s "$FIXTURE/elsewhere" "$COREDIR"
if prepare_core_dir; then exit 1; fi
[ "$ERROR" = core_path_unsafe ]
''')

    def test_boot_and_stop_do_not_depend_on_configuration(self):
        self.run_shell(r'''
settings() { ERROR=config_path_invalid; return 1; }
INIT=/usr/bin/true
service_do() { echo "$1" >> "$FIXTURE/actions"; }
set_autostart 1
set_autostart 0
action_settings stop
[ "$(cat "$FIXTURE/actions")" = "$(printf 'enable\ndisable')" ]
''')

    @staticmethod
    def release(tag='v0.1.0-beta.5'):
        base = 'https://github.com/daeuniverse/honk/releases/download/' + tag + '/'
        name = 'honk-core-' + tag + '-aarch64-unknown-linux-musl-full.tar.gz'
        return {'tag_name': tag, 'draft': False, 'body': 'x' * 150000, 'assets': [
            {'name': name, 'browser_download_url': base + name, 'digest': 'sha256:' + 'a' * 64},
            {'name': 'SHA256SUMS', 'browser_download_url': base + 'SHA256SUMS', 'digest': None}]}

    def test_release_selection_handles_large_metadata_and_rejects_tampering(self):
        body = r'''
core_target() { echo aarch64-unknown-linux-musl; }
download_file() { cp "$FIXTURE/release.json" "$2"; }
select_release v0.1.0-beta.5
[ "$ASSET_DIGEST" = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ]
[ "$ASSET_SOURCE" = 'https://github.com/daeuniverse/honk/releases/download/v0.1.0-beta.5/honk-core-v0.1.0-beta.5-aarch64-unknown-linux-musl-full.tar.gz' ]
'''
        self.run_shell(body, {'release.json': json.dumps(self.release())})
        for mutation in ['digest', 'url', 'duplicate', 'draft']:
            data = self.release()
            if mutation == 'digest':
                data['assets'][0]['digest'] = None
            elif mutation == 'url':
                data['assets'][0]['browser_download_url'] = 'https://evil.example/core'
            elif mutation == 'duplicate':
                data['assets'].append(data['assets'][0])
            else:
                data['draft'] = True
            self.run_shell(r'''
core_target() { echo aarch64-unknown-linux-musl; }
download_file() { cp "$FIXTURE/release.json" "$2"; }
if select_release v0.1.0-beta.5; then exit 1; fi
''', {'release.json': json.dumps(data)})

    def test_release_list_filters_unsupported_draft_and_debug(self):
        metadata = (ROOT / 'tests/fixtures/releases.json').read_text()
        for target, versions in [('aarch64-unknown-linux-musl', ['v0.1.0-beta.6', 'v0.1.0-beta.5']),
                                 ('x86_64-unknown-linux-musl', ['v0.1.0-beta.5'])]:
            expected = json.dumps({'versions': versions})
            self.run_shell('core_target() { echo ' + target + '; }\n' + r'''
download_file() {
    [ "$1" = 'https://api.github.com/repos/daeuniverse/honk/releases?per_page=10' ]
    cp "$FIXTURE/releases.json" "$2"
}
refresh_releases
''' + '[ "$(cat "$RUN/releases.json")" = ' + shlex.quote(expected) + ' ]\n', {'releases.json': metadata})

    def test_json_loader_rejects_invalid_json(self):
        self.run_shell(r'''
printf '{bad' > "$FIXTURE/bad.json"
if load_json_file "$FIXTURE/bad.json"; then exit 1; fi
''')

    def test_packaging_metadata_matches_makefile_and_rejects_wrong_tag(self):
        script = ROOT / '.github/scripts/build-apk.sh'
        result = subprocess.run(['bash', str(script), '--metadata'],
            env={**os.environ, 'RELEASE_TAG': 'v0.1.0'}, text=True, capture_output=True, check=True)
        version, dependencies = result.stdout.splitlines()
        self.assertEqual(version, '0.1.0-r1')
        depends = dependencies.split()
        self.assertIn('flock', depends)
        self.assertIn('kmod-nft-queue', depends)
        self.assertNotIn('honk', depends)
        for tag in ['v0.1.1', 'v0.1.0;touch unexpected']:
            result = subprocess.run(['bash', str(script), '--metadata'],
                env={**os.environ, 'RELEASE_TAG': tag}, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)

    def test_read_only_acl_does_not_grant_mutations(self):
        acl = json.loads((ROOT / 'root/usr/share/rpcd/acl.d/luci-app-honk.json').read_text())['luci-app-honk']
        self.assertEqual(set(acl['read']['ubus']['luci.honk']), {'status', 'read', 'logs'})
        self.assertTrue({'save', 'action', 'preferences'}.issubset(acl['write']['ubus']['luci.honk']))
        source = (ROOT / 'root/usr/libexec/rpcd/luci.honk').read_text()
        source = '\n'.join(line for line in source.splitlines() if not line.startswith('. /'))
        signatures = subprocess.check_output(['sh', '-c', source, 'fixture', 'list'], text=True)
        # The plugin normally sources router libraries even in list mode; its
        # signature is also checked statically when no router libraries exist.
        self.assertIn('"preferences"', signatures)
        self.assertNotIn('fetch', json.loads(signatures))
        self.assertNotIn('fetch', acl['write']['ubus']['luci.honk'])


if __name__ == '__main__':
    unittest.main()

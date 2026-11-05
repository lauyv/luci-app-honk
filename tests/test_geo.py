"""Fixed Geo destinations, safe replacement and rollback without router services."""
import json
from pathlib import Path
import shlex
import unittest

import test_backend as backend
ROOT = backend.ROOT

GEO_SETUP = '. ' + shlex.quote(str(ROOT / 'root/usr/share/honk-panel/geo.sh')) + r'''
GEOROOT="$FIXTURE/geo"
mkdir -p "$FIXTURE/state" "$GEOROOT"
uci() {
    case "$*" in
        '-q export honk') find "$FIXTURE/state" -type f -exec sha256sum '{}' \; | sort;;
        '-q get honk.panel.'*)
            key=${3##*.}
            [ -f "$FIXTURE/state/$key" ] && cat "$FIXTURE/state/$key";;
        *) return 1;;
    esac
}
geo_write_settings() {
    if [ -f "$FIXTURE/write-failure-once" ]; then rm "$FIXTURE/write-failure-once"; return 1; fi
    for key in geosite_url geoip_url geo_updated; do
        printf '%s' "$1" > "$FIXTURE/state/$key"
        shift
    done
}
download_file() {
    printf '%s\n' "$1" >> "$FIXTURE/downloads"
    [ "$3" -eq 67108864 ] || return 1
    case "$1" in
        *missing*) ERROR=download_failed; return 1;;
        *html*) printf '<html>Error</html>' > "$2";;
        *) printf '\012\002new' > "$2";;
    esac
}
old_files() {
    printf '\012\002old-site' > "$GEOROOT/geosite.dat"
    printf '\012\002old-ip' > "$GEOROOT/geoip.dat"
    cp "$GEOROOT/geosite.dat" "$FIXTURE/old-site"
    cp "$GEOROOT/geoip.dat" "$FIXTURE/old-ip"
}
assert_old_files() {
    cmp "$GEOROOT/geosite.dat" "$FIXTURE/old-site"
    cmp "$GEOROOT/geoip.dat" "$FIXTURE/old-ip"
}
cp "$FIXTURE/request.json" "$RUN/geo-request.json"
'''


class GeoTests(unittest.TestCase):
    def run_geo(self, body, site='https://gh-proxy.com/https://github.com/lauyv/rdat/raw/rel/geosite.dat',
                ip='https://gh-proxy.com/https://github.com/lauyv/cnip/raw/rel/chnroutes.dat'):
        files = {'request.json': json.dumps({'geosite_url': site, 'geoip_url': ip})}
        return backend.ShellTests.run_shell(self, GEO_SETUP + '\n' + body, files)

    def test_geo_downloads_use_the_exact_url_and_ignore_core_proxy_settings(self):
        self.run_geo(r'''
[ "$(geo_config_url geosite)" = 'https://gh-proxy.com/https://github.com/lauyv/rdat/raw/rel/geosite.dat' ]
[ "$(geo_config_url geoip)" = 'https://gh-proxy.com/https://github.com/lauyv/cnip/raw/rel/chnroutes.dat' ]
echo invalid-core-proxy > "$FIXTURE/state/proxy_prefix"
apply_geo
[ "$(sed -n '1p' "$FIXTURE/downloads")" = 'https://github.com/example/rules/raw/main/geosite.dat' ]
[ "$(sed -n '2p' "$FIXTURE/downloads")" = 'https://files.example/geoip.dat' ]
if valid_geo_url 'http://files.example/geoip.dat'; then exit 1; fi
if valid_geo_url 'https://user:password@files.example/data'; then exit 1; fi
''', site='https://github.com/example/rules/raw/main/geosite.dat', ip='https://files.example/geoip.dat')

    def test_downloads_to_fixed_files_without_starting_a_stopped_service(self):
        self.run_geo(r'''
apply_geo
geo_check_file "$GEOROOT/geosite.dat"
geo_check_file "$GEOROOT/geoip.dat"
[ "$(ls -l "$GEOROOT/geoip.dat" | cut -c 1-10)" = '-rw-------' ]
grep -q 'https://gh-proxy.com/https://github.com/lauyv/cnip/raw/rel/chnroutes.dat' "$FIXTURE/downloads"
[ ! -e "$FIXTURE/actions" ]
stage="$GEO_STAGE"
worker_exit
[ ! -e "$stage" ]
geo_check_file "$GEOROOT/geosite.dat"
''')

    def test_failed_download_or_error_page_never_replaces_local_files(self):
        for url in ['https://files.example/missing.dat', 'https://files.example/html.dat']:
            self.run_geo(r'''
old_files
if apply_geo; then exit 1; fi
assert_old_files
[ ! -e "$FIXTURE/state/geo_updated" ]
[ ! -e "$FIXTURE/actions" ]
stage="$GEO_STAGE"
worker_exit
[ ! -e "$stage" ]
''', ip=url)

    def test_partial_update_preserves_the_other_file_exactly(self):
        self.run_geo(r'''
old_files
chmod 640 "$GEOROOT/geoip.dat"
apply_geo
cmp "$GEOROOT/geoip.dat" "$FIXTURE/old-ip"
[ "$(ls -l "$GEOROOT/geoip.dat" | cut -c 1-10)" = '-rw-r-----' ]
grep -q new "$GEOROOT/geosite.dat"
[ "$(wc -l < "$FIXTURE/downloads")" -eq 1 ]
''', ip='')

    def test_partial_first_download_does_not_create_an_unrequested_file(self):
        self.run_geo(r'''
apply_geo
geo_check_file "$GEOROOT/geoip.dat"
[ ! -e "$GEOROOT/geosite.dat" ]
''', site='')

    def test_replacing_files_repairs_invalid_old_data(self):
        self.run_geo(r'''
printf '<html>old broken file</html>' > "$GEOROOT/geosite.dat"
apply_geo
geo_check_file "$GEOROOT/geosite.dat"
''')

    def test_start_failure_restores_old_files_settings_and_running_service(self):
        self.run_geo(r'''
old_files
echo https://old.example/site.dat > "$FIXTURE/state/geosite_url"
touch "$FIXTURE/running"
run_service() {
    printf '%s\n' "$1" >> "$FIXTURE/actions"
    if grep -q new "$GEOROOT/geosite.dat"; then ERROR=geo_restart_failed; DETAILS='bad Geo'; return 1; fi
    touch "$FIXTURE/running"
}
if apply_geo; then exit 1; fi
[ "$ERROR" = geo_restored ]
assert_old_files
[ "$(uci -q get honk.panel.geosite_url)" = https://old.example/site.dat ]
[ -e "$FIXTURE/running" ]
stage="$GEO_STAGE"
worker_exit
[ ! -e "$stage" ]
''')

    def test_first_download_failed_start_removes_only_new_files(self):
        self.run_geo(r'''
touch "$FIXTURE/running"
run_service() {
    if [ -e "$GEOROOT/geoip.dat" ]; then ERROR=geo_restart_failed; return 1; fi
    touch "$FIXTURE/running"
}
if apply_geo; then exit 1; fi
[ "$ERROR" = geo_restored ]
[ ! -e "$GEOROOT/geosite.dat" ] && [ ! -e "$GEOROOT/geoip.dat" ]
[ -f "$CONFIG" ] && [ -e "$FIXTURE/running" ]
''')

    def test_second_file_replace_failure_restores_the_complete_old_pair(self):
        self.run_geo(r'''
old_files
mv() {
    case "$*" in
        *'/new/geoip.dat '*) return 1;;
        *) command mv "$@";;
    esac
}
if apply_geo; then exit 1; fi
[ "$ERROR" = geo_write_failed ]
assert_old_files
[ ! -e "$FIXTURE/state/geo_updated" ]
''')

    def test_settings_write_failure_restores_the_old_files(self):
        self.run_geo(r'''
old_files
touch "$FIXTURE/write-failure-once"
if apply_geo; then exit 1; fi
[ "$ERROR" = geo_write_failed ]
assert_old_files
''')

    def test_changes_while_downloading_are_not_overwritten(self):
        for mutation in ['echo https://changed.example > "$FIXTURE/state/proxy_prefix"',
                         'echo manual > "$GEOROOT/geoip.dat"']:
            self.run_geo(r'''
old_files
download_file() {
    printf '\012\002new' > "$2"
''' + mutation + r'''
}
if apply_geo; then exit 1; fi
[ "$ERROR" = geo_settings_changed ]
cmp "$GEOROOT/geosite.dat" "$FIXTURE/old-site"
[ ! -e "$FIXTURE/actions" ]
''')

    def test_stop_failure_keeps_old_files(self):
        self.run_geo(r'''
old_files
touch "$FIXTURE/running" "$FIXTURE/stop-failure"
if apply_geo; then exit 1; fi
[ "$ERROR" = stop_failed ]
assert_old_files
''')

    def test_failed_recovery_keeps_backups(self):
        self.run_geo(r'''
old_files
touch "$FIXTURE/running"
run_service() { ERROR=geo_restart_failed; return 1; }
geo_restore_files() { return 1; }
if apply_geo; then exit 1; fi
[ "$ERROR" = geo_recovery_failed ]
stage="$GEO_STAGE"
worker_exit
cmp "$stage/backup/geosite.dat" "$FIXTURE/old-site"
cmp "$stage/backup/geoip.dat" "$FIXTURE/old-ip"
''')

    def test_destination_symlinks_and_directories_are_rejected(self):
        self.run_geo(r'''
ln -s "$CONFIG" "$GEOROOT/geoip.dat"
if apply_geo; then exit 1; fi
[ "$ERROR" = geo_path_invalid ]
[ "$(cat "$CONFIG")" = 'old config' ]
rm "$GEOROOT/geoip.dat"
mkdir "$GEOROOT/geoip.dat"
if apply_geo; then exit 1; fi
[ "$ERROR" = geo_path_invalid ]
''')

    def test_empty_urls_cannot_trigger_a_service_restart(self):
        self.run_geo(r'''
old_files
if apply_geo; then exit 1; fi
[ "$ERROR" = geo_empty ]
assert_old_files
[ ! -e "$FIXTURE/actions" ]
''', site='', ip='')

    def test_init_leaves_asset_lookup_to_the_core_configuration(self):
        init = (ROOT / 'root/etc/init.d/honk').read_text()
        config = (ROOT / 'root/etc/honk/config.dae').read_text()
        self.assertNotIn('DAE_LOCATION_ASSET', init)
        self.assertNotIn('geo_enabled', init)
        self.assertIn("data_dir: '/etc/honk'", config)
        acl = json.loads((ROOT / 'root/usr/share/rpcd/acl.d/luci-app-honk.json').read_text())['luci-app-honk']
        self.assertNotIn('geo', acl['read']['ubus']['luci.honk'])
        self.assertIn('geo', acl['write']['ubus']['luci.honk'])


if __name__ == '__main__':
    unittest.main()

#!/usr/bin/env bash
# Prepare one Geo data snapshot shared by every architecture in a release.
set -euo pipefail

verify_geodata() {
  local directory="$1" name expected actual
  for name in geosite.dat geoip.dat; do
    [[ -s "$directory/$name" ]] || { echo "Missing Geo data: $name" >&2; return 1; }
    expected=$(awk -v name="$name" '$2 == name {print $1}' "$directory/SHA256SUMS")
    actual=$(sha256sum "$directory/$name" | cut -d ' ' -f 1)
    [[ "$actual" == "$expected" ]] || { echo "Geo data digest mismatch: $name" >&2; return 1; }
  done
}

if [[ "${1:-}" == --verify ]]; then
  verify_geodata "${2:?Set Geo data directory}"
  exit 0
fi
OUTPUT=${1:?Usage: prepare-geodata.sh OUTPUT}
[[ $# == 1 ]] || { echo 'Usage: prepare-geodata.sh OUTPUT' >&2; exit 1; }
[[ ! -e "$OUTPUT" ]] || { echo "Output already exists: $OUTPUT" >&2; exit 1; }
WORK=$(mktemp -d "${RUNNER_TEMP:-/tmp}/honk-geodata.XXXXXX")
trap 'rm -rf -- "$WORK"' EXIT

fetch() {
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --connect-timeout 15 --max-time 600 --max-filesize 134217728 --retry 3 "$@"
}
fetch 'https://raw.githubusercontent.com/lauyv/rdat/rel/geosite.dat' -o "$WORK/geosite.dat"
fetch 'https://raw.githubusercontent.com/lauyv/cnip/rel/chnroutes.dat' -o "$WORK/geoip.dat"
(cd "$WORK" && sha256sum geosite.dat geoip.dat > SHA256SUMS)
verify_geodata "$WORK"
mkdir -p "$(dirname -- "$OUTPUT")"
cp -R "$WORK" "$OUTPUT"
printf '%s\n' "$OUTPUT"

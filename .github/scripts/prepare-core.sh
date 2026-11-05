#!/usr/bin/env bash
# Download the official static full core, notices and matching source archives.
set -euo pipefail
export LC_ALL=C
UPSTREAM=daeuniverse/honk

verify_core() {
  local directory="$1" target="$2" machine header
  case "$target" in
    aarch64-unknown-linux-musl) machine=AArch64;;
    x86_64-unknown-linux-musl) machine='Advanced Micro Devices X86-64';;
    *) echo "Unsupported core target: $target" >&2; return 1;;
  esac
  [[ -f "$directory/licenses/LICENSE" ]] || { echo 'Missing core license' >&2; return 1; }
  [[ "$(jq -er '.target' "$directory/core.json")" == "$target" ]] || return 1
  [[ "$(sha256sum "$directory/honk-core" | cut -d ' ' -f 1)" == "$(jq -er '.binary_sha256' "$directory/core.json")" ]] || return 1
  header=$(readelf -h "$directory/honk-core")
  grep -Eq 'Class: +ELF64' <<< "$header"
  grep -Eq 'Data: +2.s complement, little endian' <<< "$header"
  grep -Eq "Machine: +$machine$" <<< "$header"
  # Static PIE may have a dynamic table, but needs neither an interpreter nor shared libraries.
  if readelf -l "$directory/honk-core" | grep -q INTERP ||
     readelf -d "$directory/honk-core" | grep -q '(NEEDED)'; then
    echo 'The core must be statically linked' >&2; return 1
  fi
}

if [[ "${1:-}" == --verify ]]; then
  verify_core "${2:?Set core directory}" "${3:?Set core target}"
  exit 0
fi
TAG=${1:?Usage: prepare-core.sh TAG TARGET OUTPUT}
TARGET=${2:?Set core target}
OUTPUT=${3:?Set output directory}
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+)?$ ]] || { echo 'Invalid core tag' >&2; exit 1; }
case "$TARGET" in aarch64-unknown-linux-musl|x86_64-unknown-linux-musl) ;; *) echo 'Unsupported core target' >&2; exit 1;; esac
[[ ! -e "$OUTPUT" ]] || { echo "Output already exists: $OUTPUT" >&2; exit 1; }
WORK=$(mktemp -d "${RUNNER_TEMP:-/tmp}/honk-core.XXXXXX")
trap 'rm -rf -- "$WORK"' EXIT

fetch() {
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --connect-timeout 15 --max-time 600 --max-filesize 268435456 --retry 3 "$@"
}
if [[ -n "${GH_TOKEN:-}" ]]; then
  fetch -H "Authorization: Bearer $GH_TOKEN" "https://api.github.com/repos/$UPSTREAM/releases/tags/$TAG" -o "$WORK/release.json"
else
  fetch "https://api.github.com/repos/$UPSTREAM/releases/tags/$TAG" -o "$WORK/release.json"
fi
jq -e --arg tag "$TAG" '.tag_name == $tag and .draft == false' "$WORK/release.json" >/dev/null

asset() {
  jq -ce --arg name "$1" '[.assets[] | select(.name == $name)] | if length == 1 then .[0] else error("Missing or duplicate asset: " + $name) end' "$WORK/release.json"
}
asset_url() {
  local name="$1" url
  url=$(asset "$name" | jq -er '.browser_download_url')
  [[ "$url" == "https://github.com/$UPSTREAM/releases/download/$TAG/$name" ]] || return 1
  printf '%s\n' "$url"
}
fetch "$(asset_url SHA256SUMS)" -o "$WORK/SHA256SUMS"
verified_asset() {
  local name="$1" actual expected api_digest
  fetch "$(asset_url "$name")" -o "$WORK/$name"
  actual=$(sha256sum "$WORK/$name" | cut -d ' ' -f 1)
  expected=$(awk -v name="$name" '$2 == name || $2 == "*" name {print $1}' "$WORK/SHA256SUMS")
  api_digest=$(asset "$name" | jq -er '.digest')
  [[ "$actual" == "$expected" && "$api_digest" == "sha256:$actual" ]] || { echo "Digest mismatch: $name" >&2; return 1; }
}

NAME="honk-core-$TAG-$TARGET-full.tar.gz"
verified_asset "$NAME"
PREFIX=${NAME%.tar.gz}
# Accept only regular files/directories under the expected archive root.
tar -tzf "$WORK/$NAME" > "$WORK/members"
while IFS= read -r member; do
  [[ "$member" == "$PREFIX/"* && "/$member" != *'/../'* ]] || { echo 'Unexpected archive path' >&2; exit 1; }
done < "$WORK/members"
[[ "$(grep -cxF "$PREFIX/honk-core" "$WORK/members")" == 1 ]]
tar -tvzf "$WORK/$NAME" | awk 'substr($0,1,1) != "-" && substr($0,1,1) != "d" {bad=1} END {exit bad}'
mkdir -p "$WORK/prepared/licenses" "$WORK/prepared/sources"
tar -xOzf "$WORK/$NAME" "$PREFIX/honk-core" > "$WORK/prepared/honk-core"
tar -xzf "$WORK/$NAME" -C "$WORK/prepared/licenses" --strip-components=1 --exclude="$PREFIX/honk-core" --no-same-owner --no-same-permissions
chmod 0755 "$WORK/prepared/honk-core"
jq -n --arg tag "$TAG" --arg target "$TARGET" --arg release "https://github.com/$UPSTREAM/releases/tag/$TAG" \
  --arg archive_sha256 "$(sha256sum "$WORK/$NAME" | cut -d ' ' -f 1)" \
  --arg binary_sha256 "$(sha256sum "$WORK/prepared/honk-core" | cut -d ' ' -f 1)" \
  '{tag:$tag,target:$target,release:$release,archive_sha256:$archive_sha256,binary_sha256:$binary_sha256}' > "$WORK/prepared/core.json"
verify_core "$WORK/prepared" "$TARGET"
fetch "https://codeload.github.com/$UPSTREAM/tar.gz/refs/tags/$TAG" -o "$WORK/prepared/sources/honk-source-$TAG.tar.gz"
UI_SOURCE=$(jq -er '[.assets[].name | select(test("^doona-source-[A-Za-z0-9.+-]+\\.tar\\.gz$"))] | if length == 1 then .[0] else error("Missing doona source archive") end' "$WORK/release.json")
verified_asset "$UI_SOURCE"
cp "$WORK/$UI_SOURCE" "$WORK/prepared/sources/"
mkdir -p "$(dirname -- "$OUTPUT")"
cp -R "$WORK/prepared" "$OUTPUT"
printf '%s\n' "$OUTPUT"

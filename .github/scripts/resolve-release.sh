#!/usr/bin/env bash
# Select an upstream core and skip package revisions already published here.
set -euo pipefail
: "${GH_REPO:?Set GH_REPO}"
SOURCE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
RELEASE=$(sed -n 's/^PKG_RELEASE:=//p' "$SOURCE_DIR/Makefile")
[[ "$RELEASE" =~ ^[0-9]+$ ]] || {
  echo 'PKG_RELEASE must be a non-negative integer' >&2; exit 1;
}
WORK=$(mktemp -d "${RUNNER_TEMP:-/tmp}/honk-release.XXXXXX")
trap 'rm -rf -- "$WORK"' EXIT

gh api --paginate --slurp 'repos/daeuniverse/honk/releases?per_page=100' > "$WORK/upstream.json"
SELECTED=$(jq -c '
  [ .[][] | select(.draft == false)
    | select(.tag_name | test("^v[0-9]+\\.[0-9]+\\.[0-9]+(-(alpha|beta|rc)\\.[0-9]+)?$")) ]
  | sort_by(.published_at) | last // empty' "$WORK/upstream.json")
if [[ -z "$SELECTED" ]]; then
  printf 'No eligible versioned honk release was found upstream.\n' >&2
  printf 'Recent upstream tags (Debug tags are not eligible):\n' >&2
  jq -r '[.[][] | select(.draft == false) | .tag_name][0:10][]' "$WORK/upstream.json" >&2
  exit 1
fi
CORE_TAG=$(jq -er '.tag_name' <<< "$SELECTED")
TAG="$CORE_TAG-r$RELEASE"
gh api --paginate --slurp "repos/$GH_REPO/releases?per_page=100" > "$WORK/existing.json"
PUBLISH=true
if jq -e --arg tag "$TAG" 'any(.[][]; .tag_name == $tag and .draft == false and any(.assets[]; .name | test("^luci-app-honk-.*\\.apk$")))' "$WORK/existing.json" >/dev/null; then
  PUBLISH=false
fi
printf 'core_tag=%s\ntag=%s\nprerelease=%s\npublish=%s\n' "$CORE_TAG" "$TAG" "$(jq -r '.prerelease' <<< "$SELECTED")" "$PUBLISH"

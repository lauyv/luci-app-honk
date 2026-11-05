#!/usr/bin/env bash
# Select a versioned upstream release and skip versions already packaged here.
set -euo pipefail
: "${GH_REPO:?Set GH_REPO}"
REQUESTED_TAG=${1:-}
WORK=$(mktemp -d "${RUNNER_TEMP:-/tmp}/honk-release.XXXXXX")
trap 'rm -rf -- "$WORK"' EXIT

gh api --paginate --slurp 'repos/daeuniverse/honk/releases?per_page=100' > "$WORK/upstream.json"
SELECTED=$(jq -ce --arg tag "$REQUESTED_TAG" '
  [ .[][] | select(.draft == false)
    | select(.tag_name | test("^v[0-9]+\\.[0-9]+\\.[0-9]+(-(alpha|beta|rc)\\.[0-9]+)?$"))
    | select($tag == "" or .tag_name == $tag) ]
  | sort_by(.published_at) | last // error("No matching upstream release")' "$WORK/upstream.json")
TAG=$(jq -er '.tag_name' <<< "$SELECTED")
gh api --paginate --slurp "repos/$GH_REPO/releases?per_page=100" > "$WORK/existing.json"
PUBLISH=true
if jq -e --arg tag "$TAG" 'any(.[][]; .tag_name == $tag and .draft == false and any(.assets[]; .name | test("^luci-app-honk-.*\\.apk$")))' "$WORK/existing.json" >/dev/null; then
  PUBLISH=false
fi
printf 'tag=%s\nprerelease=%s\npublish=%s\n' "$TAG" "$(jq -r '.prerelease' <<< "$SELECTED")" "$PUBLISH"

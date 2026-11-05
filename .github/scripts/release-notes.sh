#!/usr/bin/env bash
set -euo pipefail

: "${GH_REPO:?Set GH_REPO to owner/repository}"
: "${BUILD_SHA:?Set BUILD_SHA to the commit being packaged}"
: "${NOTES_FILE:?Set NOTES_FILE to the release description file}"

RELEASES_FILE=$(mktemp)
trap 'rm -f -- "$RELEASES_FILE"' EXIT

# Include prereleases; ignore drafts and releases without this app's APK.
# Publication time determines the previous release, not the version or commit date.
gh api --paginate "repos/$GH_REPO/releases?per_page=100" \
  --jq '.[] | select(.draft == false and any(.assets[]; .name | test("^luci-app-honk-.*\\.apk$"))) | [.published_at, .tag_name] | @tsv' \
  > "$RELEASES_FILE"
PREVIOUS_TAG=$(LC_ALL=C sort -r "$RELEASES_FILE" | awk -F '\t' 'NR == 1 { print $2 }')

COMMIT_RANGE="$BUILD_SHA"
if [[ -n "$PREVIOUS_TAG" ]]; then
  PREVIOUS_COMMIT=$(git rev-parse --verify "refs/tags/$PREVIOUS_TAG^{commit}")
  COMMIT_RANGE="$PREVIOUS_COMMIT..$BUILD_SHA"
fi

# Keep full, multiline commit messages literal and in chronological order.
git log --reverse --format='%B' "$COMMIT_RANGE" -- > "$NOTES_FILE"
shopt -s nullglob
APK_FILES=(dist/luci-app-honk-*.apk)
[[ ${#APK_FILES[@]} -eq 5 ]] || {
  printf 'Expected five architecture APKs in dist, found %d\n' "${#APK_FILES[@]}" >&2
  exit 1
}
cat >> "$NOTES_FILE" <<EOF

Bundled honk: https://github.com/daeuniverse/honk/releases/tag/$RELEASE_TAG

Choose the APK matching \`apk --print-arch\`:
EOF
for apk in "${APK_FILES[@]}"; do
  printf '\napk add --allow-untrusted ./%s\n' "$(basename -- "$apk")" >> "$NOTES_FILE"
done
printf '\n/etc/init.d/rpcd restart\n' >> "$NOTES_FILE"

#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=package-common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/package-common.sh"
if [[ "${1:-}" == --metadata ]]; then
  printf '%s\n%s\n' "$VERSION" "$DEPENDS"
  exit 0
fi
[[ $# == 0 ]] || { echo 'Usage: build-apk.sh [--metadata]' >&2; exit 1; }
: "${TOOLS_DIR:?Set TOOLS_DIR to the directory containing APK Tools v3}"
TOOLS_DIR=$(cd -- "$TOOLS_DIR" && pwd)
[[ -x "$TOOLS_DIR/apk" ]] || { echo 'APK Tools v3 is missing' >&2; exit 1; }
prepare_payload

mkdir -p "$DATA/lib/apk/packages"
printf '/etc/config/honk\n/etc/honk/config.dae\n' > "$DATA/lib/apk/packages/$NAME.conffiles"
(
  cd "$DATA"
  { find . -type f -print | sed 's|^\./|/|'; printf '/lib/apk/packages/%s.list\n' "$NAME"; } | LC_ALL=C sort
) > "$WORK/$NAME.list"
install -m 0644 "$WORK/$NAME.list" "$DATA/lib/apk/packages/$NAME.list"
fakeroot "$TOOLS_DIR/apk" mkpkg \
  --info "name:$NAME" --info "version:$VERSION" --info 'arch:noarch' \
  --info "license:$LICENSE" --info "origin:$NAME" --info "url:$PROJECT_URL" \
  --info "description:$DESCRIPTION" --info "depends:$DEPENDS !honk" \
  --script "post-install:$HOOKS/postinst" \
  --script "post-upgrade:$HOOKS/post-upgrade" \
  --script "pre-deinstall:$HOOKS/prerm" \
  --files "$DATA" --output "$DIST/$NAME-$VERSION.apk"
printf 'Built %s\n' "$DIST/$NAME-$VERSION.apk"

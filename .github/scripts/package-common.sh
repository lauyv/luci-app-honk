#!/usr/bin/env bash
# Shared metadata and payload for the APK package.
# shellcheck disable=SC2034
set -euo pipefail

SOURCE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
NAME=luci-app-honk
DESCRIPTION='honk service and core manager for LuCI'
PROJECT_URL=https://github.com/lauyv/luci-app-honk
RELEASE=$(sed -n 's/^PKG_RELEASE:=//p' "$SOURCE_DIR/Makefile")
LICENSE=$(sed -n 's/^PKG_LICENSE:=//p' "$SOURCE_DIR/Makefile")
: "${RELEASE_TAG:?Set RELEASE_TAG, for example v0.1.1}"
[[ "$RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo 'RELEASE_TAG must be vMAJOR.MINOR.PATCH' >&2; exit 1;
}
[[ "$RELEASE" =~ ^[0-9]+$ ]] || {
  echo 'PKG_RELEASE must be a non-negative integer' >&2; exit 1;
}
VERSION="${RELEASE_TAG#v}-r$RELEASE"
# LUCI_DEPENDS contains unconditional package names, including continuation lines.
DEPENDS=$(awk '
  /^LUCI_DEPENDS:=/ { sub(/^LUCI_DEPENDS:=/, ""); reading=1 }
  reading { more=sub(/\\$/, ""); print; if (!more) exit }
' "$SOURCE_DIR/Makefile" | tr -d '+' | xargs)
[[ -n "$DEPENDS" ]] || { echo 'LUCI_DEPENDS is empty' >&2; exit 1; }
DIST="$SOURCE_DIR/dist"

prepare_payload() {
  WORK=$(mktemp -d "${RUNNER_TEMP:-/tmp}/honk-package.XXXXXX")
  trap 'rm -rf -- "$WORK"' EXIT
  DATA="$WORK/data"
  HOOKS="$WORK/hooks"
  mkdir -p "$DATA/www" "$DATA/usr/share/licenses/$NAME" "$HOOKS" "$DIST"
  cp -R "$SOURCE_DIR/root/." "$DATA/"
  cp -R "$SOURCE_DIR/htdocs/." "$DATA/www/"
  cp "$SOURCE_DIR/LICENSE" "$DATA/usr/share/licenses/$NAME/LICENSE"
  find "$DATA" -type d -exec chmod 0755 {} +
  find "$DATA" -type f -exec chmod 0644 {} +
  chmod 0755 "$DATA/etc/init.d/honk" "$DATA/etc/uci-defaults/90-honk-panel" \
    "$DATA/usr/libexec/rpcd/luci.honk" "$DATA/usr/libexec/honk-panel-worker"
  chmod 0600 "$DATA/etc/config/honk" "$DATA/etc/honk/config.dae"

  cat > "$HOOKS/postinst" <<'EOF'
#!/bin/sh
[ "${IPKG_NO_SCRIPT:-}" = 1 ] && exit 0
[ -s "${IPKG_INSTROOT}/lib/functions.sh" ] || exit 0
. "${IPKG_INSTROOT}/lib/functions.sh"
export root="${IPKG_INSTROOT}"
export pkgname="luci-app-honk"
default_postinst
[ -n "$IPKG_INSTROOT" ] || {
    rm -f /tmp/luci-indexcache.*
    rm -rf /tmp/luci-modulecache/
    /etc/init.d/rpcd reload 2>/dev/null
}
exit 0
EOF
  cat > "$HOOKS/prerm" <<'EOF'
#!/bin/sh
[ -s "${IPKG_INSTROOT}/lib/functions.sh" ] || exit 0
. "${IPKG_INSTROOT}/lib/functions.sh"
export root="${IPKG_INSTROOT}"
export pkgname="luci-app-honk"
default_prerm
EOF
  { printf '#!/bin/sh\nexport PKG_UPGRADE=1\n'; tail -n +2 "$HOOKS/postinst"; } > "$HOOKS/post-upgrade"
  chmod 0755 "$HOOKS/postinst" "$HOOKS/prerm" "$HOOKS/post-upgrade"
}

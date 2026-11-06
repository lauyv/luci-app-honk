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
: "${OPENWRT_ARCH:?Set OPENWRT_ARCH, such as x86_64 or aarch64_cortex-a53}"
: "${HONK_CORE_DIR:?Set HONK_CORE_DIR to a directory produced by prepare-core.sh}"
: "${HONK_GEODATA_DIR:?Set HONK_GEODATA_DIR to a directory produced by prepare-geodata.sh}"
case "$OPENWRT_ARCH" in
  x86_64) CORE_TARGET=x86_64-unknown-linux-musl;;
  aarch64_generic|aarch64_cortex-a53|aarch64_cortex-a72|aarch64_cortex-a76)
    CORE_TARGET=aarch64-unknown-linux-musl;;
  *) echo "Unsupported OpenWrt architecture: $OPENWRT_ARCH" >&2; exit 1;;
esac
HONK_CORE_DIR=$(cd "$HONK_CORE_DIR" && pwd)
bash "$SOURCE_DIR/.github/scripts/prepare-core.sh" --verify "$HONK_CORE_DIR" "$CORE_TARGET"
[[ "$(jq -er '.tag' "$HONK_CORE_DIR/core.json")" == "$RELEASE_TAG" ]] || { echo 'Package tag must match the bundled core' >&2; exit 1; }
bash "$SOURCE_DIR/.github/scripts/prepare-geodata.sh" --verify "$HONK_GEODATA_DIR"
prepare_payload
mkdir -p "$DATA/etc/honk/data"
install -m 0644 "$HONK_GEODATA_DIR/geosite.dat" "$HONK_GEODATA_DIR/geoip.dat" "$DATA/etc/honk/data/"
mkdir -p "$DATA/usr/bin" "$DATA/usr/share/licenses/honk" "$DATA/usr/share/honk"
install -m 0755 "$HONK_CORE_DIR/honk-core" "$DATA/usr/bin/honk-core"
cp -R "$HONK_CORE_DIR/licenses/." "$DATA/usr/share/licenses/honk/"
install -m 0644 "$HONK_CORE_DIR/core.json" "$DATA/usr/share/honk/core.json"

mkdir -p "$DATA/lib/apk/packages"
printf '/etc/config/honk\n/etc/honk/config.dae\n' > "$DATA/lib/apk/packages/$NAME.conffiles"
(
  cd "$DATA"
  { find . -type f -print | sed 's|^\./|/|'; printf '/lib/apk/packages/%s.list\n' "$NAME"; } | LC_ALL=C sort
) > "$WORK/$NAME.list"
install -m 0644 "$WORK/$NAME.list" "$DATA/lib/apk/packages/$NAME.list"
fakeroot "$TOOLS_DIR/apk" mkpkg \
  --info "name:$NAME" --info "version:$VERSION" --info "arch:$OPENWRT_ARCH" \
  --info "license:$LICENSE" --info "origin:$NAME" --info "url:$PROJECT_URL" \
  --info "description:$DESCRIPTION" --info "depends:$DEPENDS !honk" \
  --script "post-install:$HOOKS/postinst" \
  --script "post-upgrade:$HOOKS/post-upgrade" \
  --script "pre-deinstall:$HOOKS/prerm" \
  --files "$DATA" --output "$DIST/$NAME-$VERSION-$OPENWRT_ARCH.apk"
printf 'Built %s\n' "$DIST/$NAME-$VERSION-$OPENWRT_ARCH.apk"

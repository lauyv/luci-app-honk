include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-honk
PKG_RELEASE:=2
PKG_LICENSE:=MIT AND GPL-3.0-only

# SDK builds use the version recorded with the prepared core as well.
ifneq ($(HONK_CORE_DIR),)
  PKG_VERSION:=$(shell jq -r '.tag' "$(HONK_CORE_DIR)/core.json" | sed -E 's/^v//;s/-(alpha|beta|rc)\./_\1/')
endif

LUCI_TITLE:=honk 代理核心、配置与服务管理
LUCI_DEPENDS:=+luci-base +rpcd +jshn +jsonfilter +curl +ca-bundle +flock \
	+kmod-veth +kmod-sched-core +kmod-sched-bpf +kmod-nft-core +kmod-nft-queue \
	+kmod-nfnetlink-queue +kmod-nf-conntrack
LUCI_PKGARCH:=$(ARCH_PACKAGES)
LUCI_DEPENDS+=@(aarch64||x86_64)

# Prepare the official core before invoking the SDK build (see README).
HONK_CORE_TARGET:=$(if $(CONFIG_aarch64),aarch64-unknown-linux-musl,x86_64-unknown-linux-musl)

define Build/Prepare/luci-app-honk
	test -n "$(HONK_CORE_DIR)" || { echo 'Set HONK_CORE_DIR to the prepared official core directory (see README)'; exit 1; }
	bash $(CURDIR)/.github/scripts/prepare-core.sh --verify "$(HONK_CORE_DIR)" "$(HONK_CORE_TARGET)"
	$(INSTALL_DIR) $(PKG_BUILD_DIR)/root/usr/bin $(PKG_BUILD_DIR)/root/usr/share/licenses/honk $(PKG_BUILD_DIR)/root/usr/share/honk
	$(INSTALL_BIN) $(HONK_CORE_DIR)/honk-core $(PKG_BUILD_DIR)/root/usr/bin/honk-core
	$(CP) $(HONK_CORE_DIR)/licenses/. $(PKG_BUILD_DIR)/root/usr/share/licenses/honk/
	$(INSTALL_DATA) $(HONK_CORE_DIR)/core.json $(PKG_BUILD_DIR)/root/usr/share/honk/core.json
	chmod 0600 $(PKG_BUILD_DIR)/root/etc/honk/config.dae $(PKG_BUILD_DIR)/root/etc/config/honk
	chmod 0755 $(PKG_BUILD_DIR)/root/etc/init.d/honk \
		$(PKG_BUILD_DIR)/root/usr/libexec/rpcd/luci.honk \
		$(PKG_BUILD_DIR)/root/usr/libexec/honk-panel-worker
endef

define Package/luci-app-honk/conffiles
/etc/config/honk
/etc/honk/config.dae
endef

include $(TOPDIR)/feeds/luci/luci.mk

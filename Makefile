include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-honk
PKG_RELEASE:=1
PKG_LICENSE:=MIT

# Optional version override for SDK or firmware source builds.
ifneq ($(LUCI_HONK_VERSION),)
  PKG_VERSION:=$(LUCI_HONK_VERSION)
endif

LUCI_TITLE:=honk 配置、服务与核心管理
LUCI_DEPENDS:=+luci-base +rpcd +jshn +jsonfilter +curl +ca-bundle +flock \
	+kmod-veth +kmod-sched-core +kmod-nft-core +kmod-nft-queue \
	+kmod-nfnetlink-queue +kmod-nf-conntrack
LUCI_PKGARCH:=all

define Build/Prepare/luci-app-honk
	chmod 0600 $(PKG_BUILD_DIR)/root/etc/honk/config.dae $(PKG_BUILD_DIR)/root/etc/config/honk
	chmod 0755 $(PKG_BUILD_DIR)/root/etc/init.d/honk \
		$(PKG_BUILD_DIR)/root/etc/uci-defaults/90-honk-panel \
		$(PKG_BUILD_DIR)/root/usr/libexec/rpcd/luci.honk \
		$(PKG_BUILD_DIR)/root/usr/libexec/honk-panel-worker
endef

define Package/luci-app-honk/conffiles
/etc/config/honk
/etc/honk/config.dae
endef

include $(TOPDIR)/feeds/luci/luci.mk

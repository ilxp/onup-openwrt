# Copyright (C) 2026 ilxp <https://github.com/ilxp>

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-onup
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

LUCI_TITLE:=LuCI Support for onup
LUCI_DEPENDS:=+onup
LUCI_PKGARCH:=all

# 配置文件:卸载时保留
define Package/luci-app-onup/conffiles
/etc/config/onup
endef

# 安装后:清 LuCI 缓存 + 启用服务 + 重载权限
define Package/luci-app-onup/postinst
[ -n "$${IPKG_INSTROOT}" ] || {
	rm -rf /tmp/luci-indexcache
	rm -rf /tmp/luci-modulecache
	/etc/init.d/onup enable
	/etc/init.d/onup start >/dev/null 2>&1
	/etc/init.d/rpcd restart >/dev/null 2>&1
}
exit 0
endef

# 卸载前:停服务 + 禁自启
define Package/luci-app-onup/prerm
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/onup stop >/dev/null 2>&1
	/etc/init.d/onup disable
}
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
#$(eval $(call BuildPackage,$(PKG_NAME)))
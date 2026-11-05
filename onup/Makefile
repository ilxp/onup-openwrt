# Copyright (C) 2026 ilxp <https://github.com/ilxp>

include $(TOPDIR)/rules.mk

PKG_NAME:=onup
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
	SECTION:=utils
	CATEGORY:=Utilities
	TITLE:=ONUP - Online Upgrade System For OpenWRT
	DEPENDS:=+bash +jq +curl +wget-ssl +aria2 +ca-bundle +ca-certificates \
	         +coreutils-timeout
endef

define Package/$(PKG_NAME)/description
	onup - system online upgrade
endef

define Build/Compile
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(CURDIR)/files/bin/onup $(1)/usr/bin/onup
	$(INSTALL_DIR) $(1)/usr/lib/onup
	$(INSTALL_BIN) $(CURDIR)/files/usr/lib/onup/*.sh $(1)/usr/lib/onup/
	$(INSTALL_DIR) $(1)/etc/onup
	$(INSTALL_CONF) $(CURDIR)/files/etc/onup/default $(1)/etc/onup/default
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
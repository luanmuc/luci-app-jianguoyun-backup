#
# Copyright (C) 2024 OpenWrt.org
#
# This is free software, licensed under the GNU General Public License v2.
# See /LICENSE for more information.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-jianguoyun-backup

# 支持通过环境变量动态注入版本号
# GitHub Actions 中可以设置 PKG_VERSION 环境变量来覆盖
# 用法：make PKG_VERSION_OVERRIDE=1.2.3 package/luci-app-jianguoyun-backup/compile
ifdef PKG_VERSION_OVERRIDE
  PKG_VERSION:=$(PKG_VERSION_OVERRIDE)
else
  PKG_VERSION:=1.0.0
endif

PKG_RELEASE:=1
PKG_LICENSE:=GPL-3.0

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI Support for Jianguoyun Backup
  DEPENDS:=+luci-base +luci-compat +curl
  PKGARCH:=all
endef

define Package/$(PKG_NAME)/description
  Jianguoyun (Nutstore) WebDAV backup plugin for OpenWrt.
  Supports light backup and full backup with scheduled tasks.
  Features:
  - Light backup: system config + plugin configs
  - Full backup: system config + plugin configs + plugin binaries
  - Scheduled backup (daily/weekly/monthly)
  - One-click restore with snapshot protection
  - Complete logging system
  - Pure shell implementation, no extra dependencies
  - MD5/SHA256 integrity verification
  - Dual package manager support (opkg + apk)
endef

define Build/Prepare
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/$(PKG_NAME)/conffiles
/etc/config/jianguoyun-backup
endef

define Package/$(PKG_NAME)/install
	# LuCI files
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./luasrc/controller/jianguoyun-backup.lua $(1)/usr/lib/lua/luci/controller/

	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi
	$(INSTALL_DATA) ./luasrc/model/cbi/jianguoyun-backup.lua $(1)/usr/lib/lua/luci/model/cbi/

	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/jianguoyun-backup
	$(INSTALL_DATA) ./luasrc/view/jianguoyun-backup/status.htm $(1)/usr/lib/lua/luci/view/jianguoyun-backup/
	$(INSTALL_DATA) ./luasrc/view/jianguoyun-backup/restore.htm $(1)/usr/lib/lua/luci/view/jianguoyun-backup/
	$(INSTALL_DATA) ./luasrc/view/jianguoyun-backup/log.htm $(1)/usr/lib/lua/luci/view/jianguoyun-backup/

	# Root filesystem files
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DATA) ./root/etc/config/jianguoyun-backup $(1)/etc/config/

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./root/etc/init.d/jianguoyun-backup $(1)/etc/init.d/

	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./root/etc/uci-defaults/99-jianguoyun-backup $(1)/etc/uci-defaults/

	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./root/usr/bin/jianguoyun-backup.sh $(1)/usr/bin/

	# Create backup directory (permanent storage)
	$(INSTALL_DIR) $(1)/etc/jianguoyun-backup/local
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ]; then
	if [ -x /etc/init.d/jianguoyun-backup ]; then
		/etc/init.d/jianguoyun-backup enable
		/etc/init.d/jianguoyun-backup start
	fi
	rm -f /tmp/luci-indexcache
fi
exit 0
endef

define Package/$(PKG_NAME)/prerm
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ]; then
	if [ -x /etc/init.d/jianguoyun-backup ]; then
		/etc/init.d/jianguoyun-backup stop
		/etc/init.d/jianguoyun-backup disable
	fi
	# Clean up cron jobs
	crontab -l 2>/dev/null | grep -v "jianguoyun-backup" | crontab - 2>/dev/null || true
fi
exit 0
endef

define Package/$(PKG_NAME)/postrm
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ]; then
	# Note: Configuration and backup files are preserved by default
	# To completely remove everything, run:
	#   rm -rf /etc/jianguoyun-backup
	#   rm -f /etc/config/jianguoyun-backup
	rm -f /tmp/luci-indexcache
fi
exit 0
endef

$(eval $(call BuildPackage,$(PKG_NAME)))

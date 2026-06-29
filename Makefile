#
# Copyright (C) 2024 OpenWrt.org
#
# This is free software, licensed under the GNU General Public License v2.
# See /LICENSE for more information.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-jianguoyun-backup
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-3.0
PKG_MAINTAINER:=OpenWrt Community

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
  - MD5 checksum verification
  - Config import/export
  - Audit logging
  - Auto cleanup old backups
  - Progress display
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

	# Create backup directory
	$(INSTALL_DIR) $(1)/etc/jianguoyun-backup/local
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ]; then
	# 创建必要的目录
	mkdir -p /etc/jianguoyun-backup/local
	
	# 启用并启动服务
	if [ -x /etc/init.d/jianguoyun-backup ]; then
		/etc/init.d/jianguoyun-backup enable
		/etc/init.d/jianguoyun-backup start
	fi
	
	# 清理 LuCI 缓存
	rm -f /tmp/luci-indexcache
	rm -rf /tmp/luci-modulecache/
fi
exit 0
endef

define Package/$(PKG_NAME)/prerm
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ]; then
	# 停止并禁用服务
	if [ -x /etc/init.d/jianguoyun-backup ]; then
		/etc/init.d/jianguoyun-backup stop
		/etc/init.d/jianguoyun-backup disable
	fi
	
	# 清理定时任务
	if [ -f /etc/crontabs/root ]; then
		sed -i '/jianguoyun-backup/d' /etc/crontabs/root
		# 重启 cron 服务使更改生效
		if [ -x /etc/init.d/cron ]; then
			/etc/init.d/cron restart 2>/dev/null
		fi
	fi
	
	# 清理运行时文件（锁文件、状态文件、临时文件）
	rm -rf /var/run/jianguoyun-backup.lock
	rm -f /var/run/jianguoyun-backup.status
	rm -rf /tmp/jianguoyun-backup
	rm -rf /tmp/jianguoyun_restore
	rm -rf /tmp/restore_snapshot
	rm -f /tmp/.webdav_test_*
	rm -f /tmp/jianguoyun_import_*.json
fi
exit 0
endef

define Package/$(PKG_NAME)/postrm
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ]; then
	# 清理 LuCI 缓存
	rm -f /tmp/luci-indexcache
	rm -rf /tmp/luci-modulecache/
	
	# 交互式环境下显示提示信息
	if [ -t 1 ]; then
		echo ""
		echo "========================================"
		echo "  坚果云备份插件已卸载"
		echo "========================================"
		echo ""
		echo "  ✅ 已自动清理："
		echo "     • 服务已停止并禁用"
		echo "     • 定时任务已移除"
		echo "     • 运行时临时文件已清理"
		echo "     • LuCI 缓存已刷新"
		echo ""
		echo "  📁 以下用户数据已保留："
		echo "     • /etc/jianguoyun-backup/"
		echo "       ├── backup.log      (运行日志)"
		echo "       ├── audit.log       (审计日志)"
		echo "       └── local/          (本地备份文件)"
		echo "     • /etc/config/jianguoyun-backup (UCI 配置)"
		echo ""
		echo "  🗑️  如需完全清理所有数据，请执行："
		echo "     rm -rf /etc/jianguoyun-backup/"
		echo "     rm -f /etc/config/jianguoyun-backup"
		echo ""
	fi
fi
exit 0
endef

$(eval $(call BuildPackage,$(PKG_NAME)))

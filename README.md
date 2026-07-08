# luci-app-jianguoyun-backup

坚果云 WebDAV 备份插件 for OpenWrt

[![Build 24.10](https://github.com/luanmuc/luci-app-jianguoyun-backup/actions/workflows/build-24.10.yml/badge.svg)](https://github.com/luanmuc/luci-app-jianguoyun-backup/actions)
[![Build 25.12](https://github.com/luanmuc/luci-app-jianguoyun-backup/actions/workflows/build-25.12.yml/badge.svg)](https://github.com/luanmuc/luci-app-jianguoyun-backup/actions)
[![Latest Release](https://img.shields.io/github/v/release/luanmuc/luci-app-jianguoyun-backup?label=最新版本)](https://github.com/luanmuc/luci-app-jianguoyun-backup/releases)

## 功能特性

- **双模式备份**：轻量备份（系统+插件配置）、全量备份（含插件本体）
- **定时任务**：轻量/全量独立设置，支持每日/每周/每月
- **分类恢复**：多种恢复模式，支持单个插件配置恢复
- **安全可靠**：密码加密存储、备份完整性校验、操作审计日志
- **智能管理**：云端自动清理、本地存储优化、磁盘空间检查
- **配置导入导出**：JSON 格式，方便配置迁移

## 兼容性

| OpenWrt 版本 | 包格式 | 包管理器 |
|-------------|--------|----------|
| 24.10 | `.ipk` | opkg |
| 25.12 | `.apk` | apk |

- 全架构通用（PKGARCH:=all），支持 aarch64、x86_64、armv7、mips 等
- 兼容 LuCI 旧版与 LuCI3
- 深度适配 Argon 主题，兼容 bootstrap、material

## 安装

### 下载安装包

前往 [Releases 页面](https://github.com/luanmuc/luci-app-jianguoyun-backup/releases) 下载对应版本的安装包。

### 安装命令

**OpenWrt 24.10 (IPK):**
```bash
opkg install luci-app-jianguoyun-backup_24.10_all.ipk
```

**OpenWrt 25.12 (APK):**
```bash
apk add luci-app-jianguoyun-backup_25.12_all.apk --allow-untrusted
```

## 使用

1. 登录 LuCI 管理界面，进入「系统」→「坚果云备份」
2. 在设置页面填写坚果云 WebDAV 地址、账号、应用密码
3. 点击「测试WebDAV连接」验证配置
4. 设置定时备份策略，或手动执行备份
5. 在恢复页面可查看云端备份并执行恢复

## 云编译

本仓库配置了 GitHub Actions 自动编译：

- `build-24.10.yml` - 编译 OpenWrt 24.10 IPK 包
- `build-25.12.yml` - 编译 OpenWrt 25.12 APK 包

每次推送代码后自动编译，并发布到 Releases 页面。

## License

GPL-3.0

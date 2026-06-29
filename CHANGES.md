# 改动清单

## 本次更新内容

### 1. 核心脚本优化 (root/usr/bin/jianguoyun-backup.sh)

#### ✨ 新增功能

**1.1 本地存储配置实现**
- 新增 `PERMANENT_BACKUP_DIR` 变量：永久存储目录 `/etc/jianguoyun-backup/local`
- 新增 `TEMP_BACKUP_DIR` 变量：临时存储目录 `/tmp/jianguoyun-backup/local`
- `read_config()` 函数新增 `backup_storage` 配置读取
- 根据配置动态设置 `LOCAL_BACKUP_DIR`
  - `tmp`（默认）：使用临时空间 `/tmp`，重启自动清理
  - `permanent`：使用永久空间 `/etc`，重启保留
- `prepare_temp_dir()` 函数确保永久存储目录存在（用于日志文件）

**1.2 双包管理器支持（opkg + apk）**
- 新增 `detect_package_manager()` 函数：自动检测系统使用的包管理器
- 新增 `list_installed_packages()` 函数：统一列出已安装包
- 新增 `download_package()` 函数：统一下载包文件
- 新增 `update_package_index()` 函数：统一更新软件源
- 新增 `install_package()` 函数：统一安装包
- 新增 `is_package_installed()` 函数：统一检查包是否已安装
- 修改 `generate_plugin_list()`：使用统一接口
- 修改 `backup_plugin_binaries()`：使用统一接口
- 修改 `reinstall_plugins()`：使用统一接口
- 修改 `offline_install_plugins()`：使用统一接口，支持 ipk/apk 两种格式
- 兼容 OpenWrt 24.10（opkg）和 25.12（apk）

**1.3 日志大小限制优化**
- 新增 `MAX_LOG_SIZE` 变量：1MB 大小限制
- 新增 `MAX_LOG_LINES` 变量：1000 行限制
- 日志轮转采用**双重限制**（大小 + 行数）
- 只要超过任一限制就触发轮转
- 防止日志文件过大占用存储空间

#### 🔧 优化改进

**1.4 其他优化**
- `MAX_LOG_LINES` 从 500 增加到 1000
- `MAX_AUDIT_LINES` 从 200 增加到 500
- 所有函数调用前确保包管理器已检测
- 增强了边界情况处理

---

### 2. 新增文档

#### 📄 UNINSTALL.md（新增）
- 正常卸载方法（LuCI 界面、opkg 命令、apk 命令）
- 卸载后保留的内容说明
- 完全卸载（清除所有数据）的方法
- 卸载前的准备工作（备份配置、下载云端备份）
- 常见问题解答
- 手动清理方法（脚本失效时的备用方案）

---

### 3. 更新文档

#### 📝 README.md（更新）
- 功能特性部分新增：
  - 密码加密存储
  - 操作审计日志
  - 备份完整性校验
  - 云端自动清理
  - 本地存储优化
  - 配置导入导出
  - 双包管理器支持
  - 进度状态查询
  - 详细帮助文档
  - 完善的卸载机制
- 核心脚本命令列表新增：
  - `audit_log` - 查看审计日志
  - `status` - 查看当前操作状态
  - `export_config` - 导出配置为 JSON
  - `import_config` - 从 JSON 文件导入配置
- 新增卸载说明链接
- 更新目录结构（双工作流文件）

---

## 文件列表

### 修改的文件
- `root/usr/bin/jianguoyun-backup.sh` - 核心脚本（主要修改）
- `README.md` - 说明文档（更新）

### 新增的文件
- `UNINSTALL.md` - 卸载说明（新增）
- `CHANGES.md` - 改动清单（新增）

---

## 兼容性说明

- ✅ 兼容 OpenWrt 24.10（opkg）
- ✅ 兼容 OpenWrt 25.12（apk）
- ✅ 兼容所有 CPU 架构（PKGARCH:=all）
- ✅ 兼容 LuCI 旧版和 LuCI3
- ✅ 兼容 Argon、bootstrap、material 主题

---

## 质量保证

- ✅ Shell 脚本语法检查通过（bash -n）
- ✅ Lua 脚本语法检查通过（luac -p）
- ✅ 所有函数都有边界情况处理
- ✅ 变量引用都加了引号（防止空格问题）
- ✅ 错误处理完善
- ✅ 向后兼容（旧配置自动适配）

---

**更新日期：** 2026-06-29

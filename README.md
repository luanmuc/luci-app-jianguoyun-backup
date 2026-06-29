# luci-app-jianguoyun-backup

坚果云（Jianguoyun / Nutstore）WebDAV 备份插件 for OpenWrt

## 功能特性

### 双模式备份
- **轻量备份**：系统配置 + 插件配置 + 插件清单，体积小，适合日常定期备份
- **全量备份**：轻量备份内容 + 插件本体安装文件，适合整机迁移，离线完整还原

### 定时任务
- 轻量备份和全量备份可独立设置定时任务
- 支持每日、每周、每月三种周期
- 路由器重启后自动保留备份计划

### 一键恢复
- 自动读取云端所有备份文件，自动区分轻量/全量
- 多种恢复模式可选
- 恢复前自动创建当前配置快照，防止误操作

### 安全可靠
- 纯 Shell 脚本实现，无第三方依赖
- WebDAV 上传严格校验 HTTP 状态码
- 网络超时自动重试 2 次
- 完整的日志记录系统
- **密码加密存储**：应用密码 base64 编码存储，避免明文
- **操作审计日志**：记录所有操作，便于追溯
- **备份完整性校验**：MD5 校验和，确保备份文件完整

### 智能管理
- **云端自动清理**：可配置保留数量，自动删除旧备份
- **本地存储优化**：支持临时空间（/tmp）和永久空间两种模式
- **配置导入导出**：JSON 格式，便于备份和迁移配置
- **双包管理器支持**：同时兼容 opkg（24.10）和 apk（25.12）

### 用户体验
- **进度状态查询**：可查看当前备份/恢复进度
- **详细帮助文档**：每个配置项都有清晰说明
- **完善的卸载机制**：自动清理服务、定时任务、缓存

### 界面美观
- 深度适配 Argon 主题
- 兼容 bootstrap、material 默认主题
- 响应式设计，支持移动端

## 兼容版本

- **OpenWrt 24.10** - 使用 IPK 格式安装包
- **OpenWrt 25.12** - 使用 APK 格式安装包
- LuCI 旧版 + LuCI3
- **全架构通用**（PKGARCH:=all），支持 aarch64、x86_64、armv7、mipsel、mips 等所有架构

## 包格式说明

### IPK 格式（OpenWrt 24.10）
- 传统 opkg 包管理器格式
- 文件名示例：`luci-app-jianguoyun-backup_1.0.0-1_all.ipk`
- 安装命令：`opkg install xxx.ipk`

### APK 格式（OpenWrt 25.12）
- 新一代 Alpine Package Keeper (APK) 包管理器
- OpenWrt 25.12 起全面替代 opkg
- 文件名示例：`luci-app-jianguoyun-backup-1.0.0-r1.apk`
- 安装命令：`apk add xxx.apk --allow-untrusted`

> **注意**：由于本插件是纯脚本实现（Shell + Lua），没有二进制文件，因此一个 `all` 架构的安装包可在所有 CPU 架构的设备上安装使用。

## 安装方法

### 方法一：预编译安装包（推荐）

#### OpenWrt 24.10（IPK 格式）
```bash
# 下载 ipk 安装包到 /tmp 目录
cd /tmp
wget https://github.com/yourname/luci-app-jianguoyun-backup/releases/latest/download/luci-app-jianguoyun-backup_1.0.0-1_all.ipk

# 安装
opkg install luci-app-jianguoyun-backup_1.0.0-1_all.ipk
```

#### OpenWrt 25.12（APK 格式）
```bash
# 下载 apk 安装包到 /tmp 目录
cd /tmp
wget https://github.com/yourname/luci-app-jianguoyun-backup/releases/latest/download/luci-app-jianguoyun-backup-1.0.0-r1.apk

# 安装（--allow-untrusted 用于自编译/未签名包）
apk add luci-app-jianguoyun-backup-1.0.0-r1.apk --allow-untrusted
```

### 方法二：GitHub Actions 云编译

1. Fork 本仓库
2. 进入 Actions 页面，手动触发 `Build OpenWrt Packages` 工作流
3. 等待编译完成，从 Artifacts 下载安装包
4. 支持同时编译 24.10 (ipk) 和 25.12 (apk) 两个版本

### 方法三：本地源码编译

```bash
# 进入 OpenWrt SDK 目录
cd openwrt-sdk

# 克隆插件源码
git clone https://github.com/yourname/luci-app-jianguoyun-backup.git package/luci-app-jianguoyun-backup

# 选择插件
make menuconfig
# LuCI -> Applications -> luci-app-jianguoyun-backup

# 编译
make package/luci-app-jianguoyun-backup/compile V=s
```

## 使用说明

### 1. 获取坚果云应用密码
1. 登录坚果云网页版
2. 进入「设置」->「安全选项」
3. 在「第三方应用管理」中点击「添加应用」
4. 输入应用名称（如 OpenWrt Backup），生成应用密码

### 2. 配置插件
1. 登录 OpenWrt LuCI 管理界面
2. 进入「系统」->「坚果云备份」
3. 在「设置」页面填写：
   - WebDAV 地址：`https://dav.jianguoyun.com/dav/`（默认）
   - 坚果云账号：你的登录邮箱
   - 应用独立密码：上一步生成的应用密码
   - 远端备份根目录：备份文件存放的目录名
4. 点击「测试WebDAV连接」验证配置

### 3. 设置定时备份
- 轻量备份：建议每日凌晨执行
- 全量备份：建议每周或每月执行

### 4. 恢复备份
1. 进入「云端恢复」页面
2. 选择要恢复的备份文件
3. 选择恢复模式：
   - **仅恢复系统配置**：只恢复网络、防火墙等基础设置
   - **完整恢复**：恢复系统 + 插件配置，并自动重装插件（轻量备份）
   - **离线完整恢复**：无需联网，离线恢复系统 + 插件 + 配置（全量备份）

## 目录结构

```
luci-app-jianguoyun-backup/
├── Makefile                    # OpenWrt 软件包构建文件
├── README.md                   # 说明文档
├── .github/
│   └── workflows/
│       ├── build-24.10.yml     # OpenWrt 24.10 (IPK) 编译工作流
│       └── build-25.12.yml     # OpenWrt 25.12 (APK) 编译工作流
├── luasrc/
│   ├── controller/
│   │   └── jianguoyun-backup.lua    # LuCI 控制器
│   ├── model/cbi/
│   │   └── jianguoyun-backup.lua    # CBI 配置表单模型
│   └── view/jianguoyun-backup/
│       ├── status.htm               # 手动备份页面
│       ├── restore.htm              # 云端恢复页面
│       └── log.htm                  # 运行日志页面
└── root/
    ├── etc/config/
    │   └── jianguoyun-backup        # UCI 配置文件
    ├── etc/init.d/
    │   └── jianguoyun-backup        # init.d 服务脚本
    ├── etc/uci-defaults/
    │   └── 99-jianguoyun-backup     # UCI 默认配置脚本
    └── usr/bin/
        └── jianguoyun-backup.sh     # 核心功能脚本
```

## 文件说明

### 核心脚本 (jianguoyun-backup.sh)
- `test` - 测试 WebDAV 连接
- `light_backup` - 执行轻量备份
- `full_backup` - 执行全量备份
- `list` - 列出云端备份文件
- `download` - 下载备份文件
- `restore` - 执行恢复操作
- `setup_cron` - 设置定时任务
- `log` - 查看运行日志
- `clear_log` - 清空日志
- `audit_log` - 查看审计日志
- `status` - 查看当前操作状态
- `export_config` - 导出配置为 JSON
- `import_config` - 从 JSON 文件导入配置

### 备份文件命名规则
```
主机名_机型_年月日时分.tar.gz
```
示例：`OpenWrt_X86_64_20240115_030000.tar.gz`

### 云端目录结构
```
OpenWrt_Backup/
├── light/    # 轻量备份
└── full/     # 全量备份
```

## 技术实现

- **后端**：纯 BusyBox Shell 脚本
- **前端**：LuCI 原生 Lua + CBI 配置表单
- **传输**：WebDAV 协议（curl）
- **依赖**：仅使用系统自带 curl、tar、uci、sysupgrade
- **架构**：PKGARCH:=all，全平台通用，无二进制文件

## 卸载说明

请参考 [UNINSTALL.md](UNINSTALL.md) 了解详细的卸载方法和注意事项。

## 常见问题

### Q: 提示认证失败怎么办？
A: 请确认使用的是「应用独立密码」，不是坚果云登录密码。应用密码需要在坚果云网页版安全设置中生成。

### Q: 备份上传失败怎么办？
A: 
1. 检查网络连接是否正常
2. 确认坚果云账号有足够存储空间
3. 查看运行日志获取详细错误信息

### Q: 恢复后插件不工作怎么办？
A: 部分插件恢复后需要重启路由器才能正常工作。建议恢复完成后重启路由器。

### Q: 定时备份不执行怎么办？
A: 
1. 确认 cron 服务已启动：`/etc/init.d/cron status`
2. 检查定时任务是否存在：`crontab -l`
3. 查看系统日志：`logread | grep cron`

### Q: IPK 和 APK 有什么区别？
A: 
- **IPK**：OpenWrt 传统包格式，使用 opkg 包管理器，24.10 及更早版本使用
- **APK**：新一代包格式，使用 apk-tools（来自 Alpine Linux），25.12 起成为默认
- 两者功能相同，只是包格式和安装命令不同
- 本插件提供两种格式，根据你的 OpenWrt 版本选择对应格式即可

### Q: 为什么只有一个 all 架构的包？
A: 因为本插件是纯脚本实现（Shell + Lua），没有编译生成的二进制文件，所以一个包可以在所有 CPU 架构的设备上安装使用，不需要区分 aarch64/x86_64/armv7 等架构。

## 许可证

GPL-3.0 License

## 致谢

感谢 OpenWrt 社区和所有贡献者。

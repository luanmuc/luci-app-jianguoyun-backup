# 卸载说明

## 正常卸载

### 方式一：通过 LuCI 界面卸载
1. 进入 LuCI 管理界面
2. 打开「系统」→「软件包」
3. 搜索 `luci-app-jianguoyun-backup`
4. 点击「移除」

### 方式二：通过命令行卸载（opkg）
```bash
opkg remove luci-app-jianguoyun-backup
```

### 方式三：通过命令行卸载（apk）
```bash
apk del luci-app-jianguoyun-backup
```

---

## 卸载后保留的内容

正常卸载会保留以下用户数据：
- `/etc/config/jianguoyun-backup` - 插件配置文件
- `/etc/jianguoyun-backup/` - 插件数据目录（日志、本地备份等）

这样重新安装后，配置和数据都会保留。

---

## 完全卸载（清除所有数据）

如果需要完全清除所有数据，请在卸载后执行：

```bash
# 删除配置文件
rm -f /etc/config/jianguoyun-backup

# 删除数据目录（日志、本地备份等）
rm -rf /etc/jianguoyun-backup/

# 清理 LuCI 缓存
rm -f /tmp/luci-indexcache
```

---

## 卸载前的准备

### 备份配置（可选）
如果需要保留配置，可以先导出：

```bash
# 导出配置为 JSON
/usr/bin/jianguoyun-backup.sh export_config > /tmp/jianguoyun-backup-config.json
```

### 下载云端备份（可选）
如果云端有重要的备份文件，建议先下载到本地：

```bash
# 列出云端备份
/usr/bin/jianguoyun-backup.sh list

# 下载指定备份
/usr/bin/jianguoyun-backup.sh download light backup_filename.tar.gz
```

---

## 常见问题

### Q: 卸载后定时任务还会运行吗？
A: 不会。卸载时会自动停止并禁用服务，清理定时任务。

### Q: 卸载后坚果云上的备份文件会被删除吗？
A: 不会。插件只会删除本地文件，不会影响云端的备份文件。

### Q: 重新安装后配置还在吗？
A: 正常卸载会保留配置文件，重新安装后配置会自动恢复。如果需要全新安装，请先删除配置文件。

### Q: 卸载失败怎么办？
A: 可以尝试强制卸载：
```bash
# opkg 方式
opkg remove --force-remove luci-app-jianguoyun-backup

# apk 方式
apk del --force luci-app-jianguoyun-backup
```

---

## 手动清理（如果卸载脚本失效）

如果自动卸载出现问题，可以手动清理：

```bash
# 停止服务
/etc/init.d/jianguoyun-backup stop
/etc/init.d/jianguoyun-backup disable

# 清理定时任务
sed -i '/jianguoyun-backup/d' /etc/crontabs/root
/etc/init.d/cron restart

# 删除程序文件
rm -f /usr/bin/jianguoyun-backup.sh
rm -f /etc/init.d/jianguoyun-backup
rm -f /etc/uci-defaults/99-jianguoyun-backup
rm -rf /usr/lib/lua/luci/controller/jianguoyun-backup.lua
rm -rf /usr/lib/lua/luci/model/cbi/jianguoyun-backup.lua
rm -rf /usr/lib/lua/luci/view/jianguoyun-backup/

# 清理运行时文件
rm -rf /var/run/jianguoyun-backup.lock
rm -f /var/run/jianguoyun-backup.status

# 清理 LuCI 缓存
rm -f /tmp/luci-indexcache
```

---

**最后更新：** 2026-06-29

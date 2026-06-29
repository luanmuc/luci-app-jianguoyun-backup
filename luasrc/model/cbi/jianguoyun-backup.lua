-- 坚果云备份插件 - CBI配置模型（增强版）
-- 兼容 OpenWrt 24.10/25.12 + LuCI3

local m, s, o
local sys = require "luci.sys"
local http = require "luci.http"

m = Map("jianguoyun-backup", translate("坚果云备份设置"), 
    translate("配置坚果云WebDAV账号和备份策略，支持轻量备份与全量备份双模式。备份文件自动上传云端，支持一键恢复。"))

-- ==================== WebDAV基础配置 ====================
s = m:section(NamedSection, "global", "global", translate("WebDAV基础配置"))
s.anonymous = true
s.addremove = false

-- WebDAV地址
o = s:option(Value, "webdav_url", translate("WebDAV地址"))
o.datatype = "string"
o.placeholder = "https://dav.jianguoyun.com/dav/"
o.default = "https://dav.jianguoyun.com/dav/"
o.rmempty = false
o.description = translate("坚果云WebDAV服务器地址，默认无需修改。如使用其他WebDAV服务请填写对应地址。")

-- 账号
o = s:option(Value, "username", translate("坚果云账号"))
o.datatype = "string"
o.placeholder = "your@email.com"
o.rmempty = false
o.description = translate("你的坚果云登录账号（注册邮箱）。")

-- 应用密码
o = s:option(Value, "password", translate("应用独立密码"))
o.datatype = "string"
o.password = true
o.placeholder = "请输入应用密码"
o.rmempty = false
o.description = translate("重要：这不是登录密码！需要在坚果云网页端「安全设置」→「第三方应用管理」中生成应用独立密码。")

-- 远端根目录
o = s:option(Value, "remote_root", translate("远端备份根目录"))
o.datatype = "string"
o.placeholder = "OpenWrt_Backup"
o.default = "OpenWrt_Backup"
o.rmempty = false
o.description = translate("坚果云中存放备份的根目录名称，插件会自动创建 light/ 和 full/ 子目录分别存放两种备份。")

-- 云端备份保留数量
o = s:option(Value, "max_remote_backups", translate("云端备份保留数量"))
o.datatype = "range(1, 100)"
o.placeholder = "10"
o.default = "10"
o.rmempty = false
o.description = translate("每种备份类型（轻量/全量）分别保留的云端备份数量，超出后自动删除最旧的备份，避免占用过多云端空间。")

-- 本地备份存储位置
o = s:option(ListValue, "backup_storage", translate("本地备份存储位置"))
o:value("tmp", translate("临时空间 (/tmp，推荐)"))
o:value("permanent", translate("永久空间 (/etc)"))
o.default = "tmp"
o.rmempty = false
o.description = translate("临时空间：备份文件存放在内存中，重启后自动清除，不占用闪存空间，推荐使用。永久空间：备份文件保存在闪存中，重启后保留，适合仅本地备份不上传云端的场景。")

-- 连接测试按钮
o = s:option(Button, "_test", translate("测试WebDAV连接"))
o.inputtitle = translate("开始测试")
o.inputstyle = "apply"
o.description = translate("测试账号密码是否正确、网络是否连通、是否有写入权限。建议配置完成后先测试再保存。")
function o.write(self, section)
    -- 按钮点击后的处理在前端AJAX完成
end

-- ==================== 轻量备份定时设置 ====================
s = m:section(NamedSection, "light_backup", "light_backup", 
    translate("轻量备份定时设置"),
    translate("轻量备份包含系统配置和插件配置，体积小（通常几十KB），适合日常定期备份。恢复时需要联网重新下载插件。"))
s.anonymous = true
s.addremove = false

-- 启用开关
o = s:option(Flag, "enabled", translate("启用定时备份"))
o.rmempty = false
o.default = "0"
o.description = translate("开启后将按照设定的周期自动执行轻量备份。建议开启，每日备份一次系统配置。")

-- 备份周期
o = s:option(ListValue, "schedule", translate("备份周期"))
o:value("daily", translate("每日"))
o:value("weekly", translate("每周"))
o:value("monthly", translate("每月"))
o.default = "daily"
o:depends("enabled", "1")
o.description = translate("选择自动备份的周期。日常使用建议每日备份。")

-- 备份时间
o = s:option(Value, "time", translate("备份时间"))
o.datatype = "string"
o.placeholder = "03:00"
o.default = "03:00"
o:depends("enabled", "1")
o.description = translate("每日备份的执行时间，格式 HH:MM（24小时制）。建议选择凌晨3-4点低峰期，避免影响使用。")

-- 周几/几号
o = s:option(ListValue, "day", translate("备份日"))
o:value("0", translate("周日"))
o:value("1", translate("周一"))
o:value("2", translate("周二"))
o:value("3", translate("周三"))
o:value("4", translate("周四"))
o:value("5", translate("周五"))
o:value("6", translate("周六"))
o.default = "0"
o:depends("schedule", "weekly")
o.description = translate("每周备份时选择星期几执行。")

o = s:option(Value, "day_month", translate("备份日期"))
o.datatype = "range(1,31)"
o.placeholder = "1"
o.default = "1"
o:depends("schedule", "monthly")
o.description = translate("每月备份时选择几号执行（1-31）。")

-- ==================== 全量备份定时设置 ====================
s = m:section(NamedSection, "full_backup", "full_backup", 
    translate("全量备份定时设置"),
    translate("全量备份包含系统配置、插件配置和所有插件本体，体积较大（通常几MB到几十MB），适合整机迁移或离线恢复。"))
s.anonymous = true
s.addremove = false

-- 启用开关
o = s:option(Flag, "enabled", translate("启用定时备份"))
o.rmempty = false
o.default = "0"
o.description = translate("开启后将按照设定的周期自动执行全量备份。建议每周或每月备份一次，用于整机迁移。")

-- 备份周期
o = s:option(ListValue, "schedule", translate("备份周期"))
o:value("daily", translate("每日"))
o:value("weekly", translate("每周"))
o:value("monthly", translate("每月"))
o.default = "weekly"
o:depends("enabled", "1")
o.description = translate("选择自动备份的周期。全量备份体积较大，不建议每日备份。")

-- 备份时间
o = s:option(Value, "time", translate("备份时间"))
o.datatype = "string"
o.placeholder = "04:00"
o.default = "04:00"
o:depends("enabled", "1")
o.description = translate("每日备份的执行时间，格式 HH:MM（24小时制）。建议选择凌晨低峰期。")

-- 周几/几号
o = s:option(ListValue, "day", translate("备份日"))
o:value("0", translate("周日"))
o:value("1", translate("周一"))
o:value("2", translate("周二"))
o:value("3", translate("周三"))
o:value("4", translate("周四"))
o:value("5", translate("周五"))
o:value("6", translate("周六"))
o.default = "0"
o:depends("schedule", "weekly")
o.description = translate("每周备份时选择星期几执行。建议选周末。")

o = s:option(Value, "day_month", translate("备份日期"))
o.datatype = "range(1,31)"
o.placeholder = "1"
o.default = "1"
o:depends("schedule", "monthly")
o.description = translate("每月备份时选择几号执行（1-31）。建议选每月1号。")

-- 保存后应用配置
function m.on_after_commit(self)
    -- 设置定时任务
    sys.exec("/usr/bin/jianguoyun-backup.sh setup_cron >/dev/null 2>&1 &")
end

return m

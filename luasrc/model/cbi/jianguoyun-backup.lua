-- 坚果云备份插件 - CBI配置模型
-- 兼容 OpenWrt 21.02/23.05/24.10/25.12 + LuCI3

local m, s, o
local sys = require "luci.sys"
local http = require "luci.http"

m = Map("jianguoyun-backup", translate("坚果云备份设置"), 
    translate("配置坚果云WebDAV账号和备份策略，支持轻量备份与全量备份双模式。"))

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
o.description = translate("坚果云WebDAV服务器地址，默认为 https://dav.jianguoyun.com/dav/")

-- 账号
o = s:option(Value, "username", translate("坚果云账号"))
o.datatype = "string"
o.placeholder = "your@email.com"
o.rmempty = false
o.description = translate("你的坚果云登录账号（邮箱）")

-- 应用密码
o = s:option(Value, "password", translate("应用独立密码"))
o.datatype = "string"
o.password = true
o.placeholder = "请输入应用密码"
o.rmempty = false
o.description = translate("坚果云安全设置中生成的应用独立密码，不是登录密码")

-- 远端根目录
o = s:option(Value, "remote_root", translate("远端备份根目录"))
o.datatype = "string"
o.placeholder = "OpenWrt_Backup"
o.default = "OpenWrt_Backup"
o.rmempty = false
o.description = translate("坚果云中存放备份的根目录名称，会自动创建子目录 light/ 和 full/")

-- 连接测试按钮
o = s:option(Button, "_test", translate("测试WebDAV连接"))
o.inputtitle = translate("开始测试")
o.inputstyle = "apply"
o.description = translate("测试账号密码、网络连通性和写入权限")

function o.write(self, section)
    -- 按钮点击后的处理在前端AJAX完成
end

-- ==================== 轻量备份定时设置 ====================
s = m:section(NamedSection, "light_backup", "light_backup", 
    translate("轻量备份定时设置"),
    translate("轻量备份包含系统配置和插件配置，体积小，适合日常定期备份。"))
s.anonymous = true
s.addremove = false

-- 启用开关
o = s:option(Flag, "enabled", translate("启用定时备份"))
o.rmempty = false
o.default = "0"
o.description = translate("开启后将按照设定的周期自动执行轻量备份")

-- 备份周期
o = s:option(ListValue, "schedule", translate("备份周期"))
o:value("daily", translate("每日"))
o:value("weekly", translate("每周"))
o:value("monthly", translate("每月"))
o.default = "daily"
o:depends("enabled", "1")
o.description = translate("选择自动备份的周期")

-- 备份时间
o = s:option(Value, "time", translate("备份时间"))
o.datatype = "string"
o.placeholder = "03:00"
o.default = "03:00"
o:depends("enabled", "1")
o.description = translate("每日备份的执行时间，格式 HH:MM，建议选择凌晨低峰期")

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
o.description = translate("每周备份时选择星期几执行")

o = s:option(Value, "day_month", translate("备份日期"))
o.datatype = "range(1,31)"
o.placeholder = "1"
o.default = "1"
o:depends("schedule", "monthly")
o.description = translate("每月备份时选择几号执行（1-31）")

-- ==================== 全量备份定时设置 ====================
s = m:section(NamedSection, "full_backup", "full_backup", 
    translate("全量备份定时设置"),
    translate("全量备份包含系统配置、插件配置和插件本体，体积较大，适合整机迁移。"))
s.anonymous = true
s.addremove = false

-- 启用开关
o = s:option(Flag, "enabled", translate("启用定时备份"))
o.rmempty = false
o.default = "0"
o.description = translate("开启后将按照设定的周期自动执行全量备份")

-- 备份周期
o = s:option(ListValue, "schedule", translate("备份周期"))
o:value("daily", translate("每日"))
o:value("weekly", translate("每周"))
o:value("monthly", translate("每月"))
o.default = "weekly"
o:depends("enabled", "1")
o.description = translate("选择自动备份的周期")

-- 备份时间
o = s:option(Value, "time", translate("备份时间"))
o.datatype = "string"
o.placeholder = "04:00"
o.default = "04:00"
o:depends("enabled", "1")
o.description = translate("每日备份的执行时间，格式 HH:MM，建议选择凌晨低峰期")

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
o.description = translate("每周备份时选择星期几执行")

o = s:option(Value, "day_month", translate("备份日期"))
o.datatype = "range(1,31)"
o.placeholder = "1"
o.default = "1"
o:depends("schedule", "monthly")
o.description = translate("每月备份时选择几号执行（1-31）")

-- 保存后应用配置
function m.on_after_commit(self)
    -- 设置定时任务
    sys.exec("/usr/bin/jianguoyun-backup.sh setup_cron >/dev/null 2>&1 &")
end

return m

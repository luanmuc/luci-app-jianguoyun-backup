-- 坚果云备份插件 - LuCI控制器
-- 兼容 OpenWrt 21.02/23.05/24.10/25.12 + LuCI3

module("luci.controller.jianguoyun-backup", package.seeall)

function index()
    -- 主菜单入口 - 放在系统菜单下
    entry({"admin", "system", "jianguoyun-backup"}, firstchild(), _("坚果云备份"), 90).dependent = false
    
    -- 子菜单
    entry({"admin", "system", "jianguoyun-backup", "settings"}, cbi("jianguoyun-backup"), _("设置"), 1).leaf = true
    entry({"admin", "system", "jianguoyun-backup", "status"}, template("jianguoyun-backup/status"), _("手动备份"), 2).leaf = true
    entry({"admin", "system", "jianguoyun-backup", "restore"}, template("jianguoyun-backup/restore"), _("云端恢复"), 3).leaf = true
    entry({"admin", "system", "jianguoyun-backup", "log"}, template("jianguoyun-backup/log"), _("运行日志"), 4).leaf = true
    
    -- AJAX接口
    entry({"admin", "system", "jianguoyun-backup", "test_connection"}, call("action_test_connection"), nil).leaf = true
    entry({"admin", "system", "jianguoyun-backup", "do_backup"}, call("action_do_backup"), nil).leaf = true
    entry({"admin", "system", "jianguoyun-backup", "get_log"}, call("action_get_log"), nil).leaf = true
    entry({"admin", "system", "jianguoyun-backup", "clear_log"}, call("action_clear_log"), nil).leaf = true
    entry({"admin", "system", "jianguoyun-backup", "list_backups"}, call("action_list_backups"), nil).leaf = true
    entry({"admin", "system", "jianguoyun-backup", "do_restore"}, call("action_do_restore"), nil).leaf = true
    entry({"admin", "system", "jianguoyun-backup", "list_local"}, call("action_list_local"), nil).leaf = true
end

-- 测试WebDAV连接
function action_test_connection()
    local http = require "luci.http"
    local sys = require "luci.sys"
    
    -- 保存配置
    local webdav_url = http.formvalue("webdav_url") or ""
    local username = http.formvalue("username") or ""
    local password = http.formvalue("password") or ""
    local remote_root = http.formvalue("remote_root") or "OpenWrt_Backup"
    
    -- 临时写入UCI用于测试
    if webdav_url ~= "" and username ~= "" and password ~= "" then
        sys.exec("uci set jianguoyun-backup.@global[0].webdav_url='" .. webdav_url .. "'")
        sys.exec("uci set jianguoyun-backup.@global[0].username='" .. username .. "'")
        sys.exec("uci set jianguoyun-backup.@global[0].password='" .. password .. "'")
        sys.exec("uci set jianguoyun-backup.@global[0].remote_root='" .. remote_root .. "'")
        sys.exec("uci commit jianguoyun-backup")
    end
    
    -- 执行测试
    local result = sys.exec("/usr/bin/jianguoyun-backup.sh test 2>&1")
    
    http.prepare_content("text/plain; charset=utf-8")
    http.write(result)
end

-- 执行备份
function action_do_backup()
    local http = require "luci.http"
    local sys = require "luci.sys"
    
    local backup_type = http.formvalue("type") or "light"
    
    if backup_type == "light" then
        sys.exec("/usr/bin/jianguoyun-backup.sh light_backup >/dev/null 2>&1 &")
        http.prepare_content("text/plain; charset=utf-8")
        http.write("轻量备份已在后台启动，请稍候查看日志")
    elseif backup_type == "full" then
        sys.exec("/usr/bin/jianguoyun-backup.sh full_backup >/dev/null 2>&1 &")
        http.prepare_content("text/plain; charset=utf-8")
        http.write("全量备份已在后台启动，请稍候查看日志")
    else
        http.prepare_content("text/plain; charset=utf-8")
        http.write("错误：未知的备份类型")
    end
end

-- 获取日志
function action_get_log()
    local http = require "luci.http"
    local sys = require "luci.sys"
    
    local log = sys.exec("/usr/bin/jianguoyun-backup.sh log 2>&1")
    
    http.prepare_content("text/plain; charset=utf-8")
    http.write(log)
end

-- 清空日志
function action_clear_log()
    local http = require "luci.http"
    local sys = require "luci.sys"
    
    sys.exec("/usr/bin/jianguoyun-backup.sh clear_log 2>&1")
    
    http.prepare_content("text/plain; charset=utf-8")
    http.write("日志已清空")
end

-- 列出云端备份
function action_list_backups()
    local http = require "luci.http"
    local sys = require "luci.sys"
    
    local result = sys.exec("/usr/bin/jianguoyun-backup.sh list 2>&1")
    
    http.prepare_content("text/plain; charset=utf-8")
    http.write(result)
end

-- 执行恢复
function action_do_restore()
    local http = require "luci.http"
    local sys = require "luci.sys"
    
    local restore_type = http.formvalue("type") or "light"
    local filename = http.formvalue("filename") or ""
    local mode = http.formvalue("mode") or "system_only"
    
    if filename == "" then
        http.prepare_content("text/plain; charset=utf-8")
        http.write("错误：请选择要恢复的备份文件")
        return
    end
    
    -- 后台执行恢复
    local cmd = string.format("/usr/bin/jianguoyun-backup.sh restore '%s' '%s' '%s' >/dev/null 2>&1 &", 
        restore_type, filename, mode)
    sys.exec(cmd)
    
    http.prepare_content("text/plain; charset=utf-8")
    http.write("恢复操作已在后台启动，请查看日志了解进度。恢复前已自动创建当前配置快照。")
end

-- 列出本地备份
function action_list_local()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local nixio = require "nixio"
    
    local backup_dir = "/etc/jianguoyun-backup/local"
    local files = {}
    
    -- 检查目录是否存在
    local stat = nixio.stat(backup_dir)
    if stat and stat.type == "dir" then
        for file in nixio.fs.dir(backup_dir) do
            if file:match("%.tar%.gz$") then
                local fstat = nixio.stat(backup_dir .. "/" .. file)
                if fstat then
                    table.insert(files, {
                        name = file,
                        size = fstat.size,
                        mtime = fstat.mtime
                    })
                end
            end
        end
    end
    
    -- 按时间排序（最新的在前）
    table.sort(files, function(a, b)
        return a.mtime > b.mtime
    end)
    
    http.prepare_content("application/json")
    http.write(luci.jsonc.stringify(files))
end

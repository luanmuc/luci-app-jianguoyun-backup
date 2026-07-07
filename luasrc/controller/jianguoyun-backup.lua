-- 坚果云备份插件 - LuCI控制器（增强版）
-- 兼容 OpenWrt 24.10/25.12 + LuCI3

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
    entry({"admin", "system", "jianguoyun-backup", "get_status"}, call("action_get_status"), nil).leaf = true
    entry({"admin", "system", "jianguoyun-backup", "get_audit_log"}, call("action_get_audit_log"), nil).leaf = true
    entry({"admin", "system", "jianguoyun-backup", "export_config"}, call("action_export_config"), nil).leaf = true
    entry({"admin", "system", "jianguoyun-backup", "import_config"}, call("action_import_config"), nil).leaf = true
end

-- 工具函数：加密密码
local function encrypt_password(password)
    if not password or password == "" then
        return ""
    end
    
    -- v2 格式：字符偏移 + base64，与 Shell 端保持一致
    local PASSWORD_OFFSET = 47
    local PASSWORD_VERSION_PREFIX = "{v2}"
    
    local result = ""
    for i = 1, #password do
        local char = password:sub(i, i)
        local ascii = string.byte(char)
        local new_ascii = ascii + PASSWORD_OFFSET
        if new_ascii > 126 then
            new_ascii = new_ascii - 94  -- 94 = 126 - 32，可打印字符范围
        end
        result = result .. string.char(new_ascii)
    end
    
    -- base64 编码
    local sys = require "luci.sys"
    local encoded = sys.exec("printf '%s' '" .. result:gsub("'", "'\\''") .. "' | base64 2>/dev/null")
    encoded = encoded:gsub("%s+", "")
    
    return PASSWORD_VERSION_PREFIX .. encoded
end

-- 测试WebDAV连接
function action_test_connection()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local uci = require "luci.model.uci".cursor()
    
    -- 保存配置
    local webdav_url = http.formvalue("webdav_url") or ""
    local username = http.formvalue("username") or ""
    local password = http.formvalue("password") or ""
    local remote_root = http.formvalue("remote_root") or "OpenWrt_Backup"
    
    -- 输入验证
    if webdav_url ~= "" and not webdav_url:match("^https?://") then
        http.prepare_content("text/plain; charset=utf-8")
        http.write("ERROR: WebDAV地址格式不正确")
        return
    end
    
    if username ~= "" and #username > 255 then
        http.prepare_content("text/plain; charset=utf-8")
        http.write("ERROR: 用户名过长")
        return
    end
    
    -- 临时写入UCI用于测试（使用UCI库，避免命令注入）
    if webdav_url ~= "" and username ~= "" and password ~= "" then
        -- 加密密码后存储
        local encrypted_pass = encrypt_password(password)
        
        uci:set("jianguoyun-backup", "global", "webdav_url", webdav_url)
        uci:set("jianguoyun-backup", "global", "username", username)
        uci:set("jianguoyun-backup", "global", "password", encrypted_pass)
        uci:set("jianguoyun-backup", "global", "remote_root", remote_root)
        uci:commit("jianguoyun-backup")
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
    
    -- 参数验证
    local valid_types = { light = true, full = true }
    if not valid_types[backup_type] then
        http.prepare_content("text/plain; charset=utf-8")
        http.write("错误：无效的备份类型")
        return
    end
    
    if backup_type == "light" then
        sys.exec("/usr/bin/jianguoyun-backup.sh light_backup >/dev/null 2>&1 &")
        http.prepare_content("text/plain; charset=utf-8")
        http.write("轻量备份已在后台启动，请查看状态了解进度")
    elseif backup_type == "full" then
        sys.exec("/usr/bin/jianguoyun-backup.sh full_backup >/dev/null 2>&1 &")
        http.prepare_content("text/plain; charset=utf-8")
        http.write("全量备份已在后台启动，请查看状态了解进度")
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

-- 获取审计日志
function action_get_audit_log()
    local http = require "luci.http"
    local sys = require "luci.sys"
    
    local log = sys.exec("/usr/bin/jianguoyun-backup.sh audit_log 2>&1")
    
    http.prepare_content("text/plain; charset=utf-8")
    http.write(log)
end

-- 获取当前状态
function action_get_status()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local jsonc = require "luci.jsonc"
    
    local status_output = sys.exec("/usr/bin/jianguoyun-backup.sh status 2>&1")
    
    -- 解析状态输出
    local status = {
        status = "idle",
        progress = 0,
        message = "空闲",
        timestamp = ""
    }
    
    for line in status_output:gmatch("[^\r\n]+") do
        local key, value = line:match("^([^=]+)=(.*)$")
        if key and value then
            status[key] = value
        end
    end
    
    http.prepare_content("application/json")
    http.write(jsonc.stringify(status))
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
    
    -- 参数验证，防止命令注入
    local valid_types = { light = true, full = true }
    local valid_modes = { system_only = true, system_plugins = true, full_offline = true }
    
    if not valid_types[restore_type] then
        http.prepare_content("text/plain; charset=utf-8")
        http.write("错误：无效的备份类型")
        return
    end
    
    if not valid_modes[mode] then
        http.prepare_content("text/plain; charset=utf-8")
        http.write("错误：无效的恢复模式")
        return
    end
    
    -- 验证文件名，只允许安全字符
    if not filename:match("^[%w%-_%.]+$") then
        http.prepare_content("text/plain; charset=utf-8")
        http.write("错误：文件名包含非法字符")
        return
    end
    
    -- 后台执行恢复（使用安全的参数传递方式）
    local cmd = string.format("/usr/bin/jianguoyun-backup.sh restore %q %q %q >/dev/null 2>&1 &", 
        restore_type, filename, mode)
    sys.exec(cmd)
    
    http.prepare_content("text/plain; charset=utf-8")
    http.write("恢复操作已在后台启动，请查看状态了解进度。恢复前已自动创建当前配置快照。")
end

-- 列出本地备份
function action_list_local()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local nixio = require "nixio"
    local jsonc = require "luci.jsonc"
    local uci = require "luci.model.uci".cursor()
    
    -- 从UCI配置读取本地备份存储位置
    local backup_storage = uci:get("jianguoyun-backup", "global", "backup_storage") or "tmp"
    local backup_dir
    
    if backup_storage == "permanent" then
        backup_dir = "/etc/jianguoyun-backup/local"
    else
        backup_dir = "/tmp/jianguoyun-backup/local"
    end
    
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
    http.write(jsonc.stringify(files))
end

-- 导出配置
function action_export_config()
    local http = require "luci.http"
    local sys = require "luci.sys"
    
    local config = sys.exec("/usr/bin/jianguoyun-backup.sh export_config 2>&1")
    
    http.prepare_content("application/json")
    http.write(config)
end

-- 导入配置
function action_import_config()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local ltn12 = require "ltn12"
    
    -- 获取上传的文件
    local filecontent = http.formvalue("config_file") or ""
    
    if filecontent == "" then
        http.prepare_content("text/plain; charset=utf-8")
        http.write("错误：请选择配置文件")
        return
    end
    
    -- 检查文件大小（最大 100KB）
    local max_size = 100 * 1024  -- 100KB
    if #filecontent > max_size then
        http.prepare_content("text/plain; charset=utf-8")
        http.write("错误：配置文件过大，最大允许 " .. (max_size / 1024) .. "KB")
        return
    end
    
    -- 简单验证JSON格式
    if not filecontent:match("^%s*{") then
        http.prepare_content("text/plain; charset=utf-8")
        http.write("错误：配置文件格式不正确")
        return
    end
    
    -- 写入临时文件
    local tmpfile = "/tmp/jianguoyun_import_" .. os.time() .. ".json"
    local f = io.open(tmpfile, "w")
    if f then
        f:write(filecontent)
        f:close()
        
        -- 执行导入（使用安全的参数传递方式）
        local cmd = string.format("/usr/bin/jianguoyun-backup.sh import_config %q 2>&1", tmpfile)
        local result = sys.exec(cmd)
        
        -- 清理临时文件
        os.remove(tmpfile)
        
        http.prepare_content("text/plain; charset=utf-8")
        http.write(result)
    else
        http.prepare_content("text/plain; charset=utf-8")
        http.write("错误：无法写入临时文件")
    end
end

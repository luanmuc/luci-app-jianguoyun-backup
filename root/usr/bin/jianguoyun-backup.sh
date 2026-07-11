#!/bin/sh
# 坚果云备份插件 - 核心脚本（增强版）
# 严格模式：遇到错误立即退出，未定义变量报错，管道失败返回非零
set -euo pipefail

# 仅使用系统自带工具：curl, tar, uci, md5sum, base64
# 兼容 OpenWrt 24.10/25.12

# ==================== 基础配置 ====================
CONFIG_FILE="/etc/config/jianguoyun-backup"
LOG_FILE="/etc/jianguoyun-backup/backup.log"
AUDIT_LOG="/etc/jianguoyun-backup/audit.log"
BACKUP_DIR="/tmp/jianguoyun-backup"
# 本地备份目录（根据配置动态设置）
LOCAL_BACKUP_DIR=""
# 永久存储的本地备份目录
PERMANENT_BACKUP_DIR="/etc/jianguoyun-backup/local"
# 快照存储目录（永久空间，不受 backup_storage 影响）
SNAPSHOT_STORAGE_DIR="/etc/jianguoyun-backup/snapshots"
# 快照保留数量
MAX_SNAPSHOTS=5
# 临时存储的本地备份目录
TEMP_BACKUP_DIR="/tmp/jianguoyun-backup/local"
LOCK_DIR="/var/run/jianguoyun-backup.lock"
RESTORE_DIR="/tmp/jianguoyun_restore"
SNAPSHOT_DIR="/tmp/restore_snapshot"
STATUS_FILE="/var/run/jianguoyun-backup.status"

MAX_LOG_LINES=1000
MAX_LOG_SIZE=1048576  # 1MB
MAX_AUDIT_LINES=500
MAX_IMPORT_SIZE=102400  # 配置导入文件最大 100KB
# 配置导入最小文件大小（字节）
MIN_IMPORT_SIZE=10
LOG_CHECK_INTERVAL=10   # 每写10条日志检查一次轮转

# ==================== 统计变量 ====================
BACKUP_START_TIME=""
BACKUP_END_TIME=""
BACKUP_FILE_COUNT=0
BACKUP_TOTAL_SIZE=0

# 解析 curl 返回码
curl_error_msg() {
    local code="$1"
    case "$code" in
        0) echo "正常完成" ;;
        1) echo "不支持的协议" ;;
        2) echo "初始化失败" ;;
        3) echo "URL格式错误" ;;
        6) echo "无法解析主机（DNS失败）" ;;
        7) echo "无法连接到主机" ;;
        28) echo "操作超时" ;;
        35) echo "SSL连接错误" ;;
        56) echo "接收数据失败" ;;
        60) echo "SSL证书验证失败" ;;
        *) echo "未知错误 (代码: $code)" ;;
    esac
}

# 包管理器（自动检测）
PKG_MANAGER=""
# 配置版本号（用于配置迁移）
CONFIG_VERSION=1

DEFAULT_MAX_LOCAL_BACKUPS=5
DEFAULT_MAX_REMOTE_BACKUPS=10

# 备份大小估算相关常量
ESTIMATE_PKG_SIZE_KB=80          # 每个插件包平均大小（KB，保守估计）
ESTIMATE_DEFAULT_PKG_COUNT=100   # 默认估算的插件数量（无法统计时使用）
ESTIMATE_COMPRESS_RATIO=2        # 压缩比（原始大小/压缩后大小，即压缩后约为原始的50%）
DISK_SPACE_MARGIN=20             # 磁盘空间安全余量百分比

CURL_RETRY=2
# 日志轮转检查频率（每写N条日志检查一次）
LOG_ROTATE_CHECK_INTERVAL=10
CURL_TIMEOUT=30
CURL_SSL_OPT="-k"
# 重试间隔（秒）
CURL_RETRY_DELAY_SHORT=2
CURL_RETRY_DELAY_NORMAL=3
CURL_RETRY_DELAY_LONG=5
# 预估压缩比
ESTIMATE_COMPRESS_RATIO=2
# 每个插件预估大小(KB)
ESTIMATE_PKG_SIZE_KB=80
# 默认插件数量估算
ESTIMATE_DEFAULT_PKG_COUNT=100

# ==================== 工具函数 ====================

# ==================== 安全验证函数 ====================

# 验证文件名安全性（防止路径遍历）
validate_filename() {
    local filename="$1"
    
    # 空文件名
    if [ -z "$filename" ]; then
        return 1
    fi
    
    # 正则验证：只允许字母、数字、下划线、点、横杠
    # 自动排除路径遍历（..、/）、命令注入（$、`、;、|、&、*）等
    if ! echo "$filename" | grep -qE '^[a-zA-Z0-9._-]+$'; then
        return 1
    fi
    
    return 0
}

# 验证备份类型
validate_backup_type() {
    local type="$1"
    case "$type" in
        light|full)
            return 0
            ;;
        *)
            log_error "无效的备份类型: $type"
            return 1
            ;;
    esac
}

# 验证恢复模式
validate_restore_mode() {
    local mode="$1"
    case "$mode" in
        system_only|system_plugins|full_offline|plugin_config_only|reinstall_only|custom)
            return 0
            ;;
        *)
            log_error "无效的恢复模式: $mode"
            return 1
            ;;
    esac
}

# 简单的 base64 编码加密（混淆用）
# 密码编码偏移量
PASSWORD_OFFSET=47
# 版本前缀，用于区分不同的编码方式
PASSWORD_VERSION_PREFIX="{v2}"

# 密码编码（字符偏移 + Base64）
encrypt_password() {
    local plain="$1"
    if [ -z "$plain" ]; then
        echo ""
        return 0
    fi
    
    local result=""
    local i=1
    local len=$(expr length "$plain")
    
    while [ "$i" -le "$len" ]; do
        char=$(expr substr "$plain" $i 1)
        ascii=$(printf "%d" "'$char")
        new_ascii=$((ascii + PASSWORD_OFFSET))
        if [ "$new_ascii" -gt 126 ]; then
            new_ascii=$((new_ascii - 94))  # 94 = 126 - 32，可打印字符范围
        fi
        result="$result$(printf "\\$(printf '%03o' $new_ascii)")"
        i=$((i + 1))
    done
    
    local encoded=$(printf "%s" "$result" | base64 | tr -d '\n')
    echo "${PASSWORD_VERSION_PREFIX}${encoded}"
}

# 密码解码
decrypt_password() {
    local encoded="$1"
    if [ -z "$encoded" ]; then
        echo ""
        return 0
    fi
    
    # 检查是否是 v2 格式
    if echo "$encoded" | grep -q '^{v2}'; then
        local data=$(echo "$encoded" | sed 's/^{v2}//')
        local decoded=$(printf "%s" "$data" | base64 -d 2>/dev/null)
        
        if [ -z "$decoded" ]; then
            echo ""
            return 0
        fi
        
        local result=""
        local i=1
        local len=$(expr length "$decoded")
        
        while [ "$i" -le "$len" ]; do
            char=$(expr substr "$decoded" $i 1)
            ascii=$(printf "%d" "'$char")
            new_ascii=$((ascii - PASSWORD_OFFSET))
            if [ "$new_ascii" -lt 32 ]; then
                new_ascii=$((new_ascii + 94))
            fi
            result="$result$(printf "\\$(printf '%03o' $new_ascii)")"
            i=$((i + 1))
        done
        
        echo "$result"
        return 0
    else
        # 旧格式：纯 base64 或明文（向后兼容）
        local plain=$(printf "%s" "$encoded" | base64 -d 2>/dev/null)
        if [ -n "$plain" ] && ! printf "%s" "$plain" | grep -q '[^[:print:]]'; then
            echo "$plain"
        else
            echo "$encoded"
        fi
        return 0
    fi
}
# 记录审计日志
log_audit() {
    local action="$1"
    local status="$2"
    local detail="$3"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$action] [$status] $detail" >> "$AUDIT_LOG"
    
    # 限制审计日志行数
    if [ -f "$AUDIT_LOG" ]; then
        local lines=$(wc -l < "$AUDIT_LOG")
        if [ "$lines" -gt "$MAX_AUDIT_LINES" ]; then
            tail -n "$MAX_AUDIT_LINES" "$AUDIT_LOG" > "${AUDIT_LOG}.tmp"
            mv "${AUDIT_LOG}.tmp" "$AUDIT_LOG"
        fi
    fi
}

# 更新状态文件
update_status() {
    local status="$1"
    local progress="$2"
    local message="$3"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    cat > "$STATUS_FILE" << EOF
status=$status
progress=$progress
message=$message
timestamp=$timestamp
EOF
}

# ==================== 包管理器适配 ====================

# 检测系统使用的包管理器（opkg 或 apk）
detect_package_manager() {
    if [ -n "$PKG_MANAGER" ]; then
        return 0
    fi
    
    if command -v apk >/dev/null 2>&1; then
        PKG_MANAGER="apk"
        log_info "检测到包管理器: apk"
    elif command -v opkg >/dev/null 2>&1; then
        PKG_MANAGER="opkg"
        log_info "检测到包管理器: opkg"
    else
        PKG_MANAGER="unknown"
        log_error "未检测到包管理器（opkg 或 apk）"
        return 1
    fi
    
    return 0
}

# 列出已安装的软件包
list_installed_packages() {
    detect_package_manager
    
    case "$PKG_MANAGER" in
        apk)
            apk list --installed 2>/dev/null | awk '{print $1}'
            ;;
        opkg)
            opkg list-installed 2>/dev/null | awk '{print $1}'
            ;;
        *)
            return 1
            ;;
    esac
}

# 下载软件包
download_package() {
    local pkg="$1"
    local dest_dir="$2"
    
    detect_package_manager
    
    case "$PKG_MANAGER" in
        apk)
            apk fetch --output "$dest_dir" "$pkg" 2>/dev/null
            ;;
        opkg)
            (cd "$dest_dir" && opkg download "$pkg" 2>/dev/null)
            ;;
        *)
            return 1
            ;;
    esac
}

# 更新软件源索引
update_package_index() {
    detect_package_manager
    
    case "$PKG_MANAGER" in
        apk)
            apk update 2>/dev/null
            ;;
        opkg)
            opkg update 2>/dev/null
            ;;
        *)
            return 1
            ;;
    esac
}

# 安装软件包
install_package() {
    local pkg="$1"
    
    detect_package_manager
    
    case "$PKG_MANAGER" in
        apk)
            apk add "$pkg" 2>/dev/null
            ;;
        opkg)
            opkg install "$pkg" 2>/dev/null
            ;;
        *)
            return 1
            ;;
    esac
}

# 检查软件包是否已安装
is_package_installed() {
    local pkg="$1"
    
    detect_package_manager
    
    case "$PKG_MANAGER" in
        apk)
            apk list --installed 2>/dev/null | grep -q "^${pkg} "
            ;;
        opkg)
            opkg list-installed 2>/dev/null | grep -q "^${pkg} "
            ;;
        *)
            return 1
            ;;
    esac
}

# 计算文件校验和
calculate_checksum() {
    local file="$1"
    local type="${2:-md5}"
    
    if [ ! -f "$file" ]; then
        echo ""
        return 1
    fi
    
    case "$type" in
        md5)
            md5sum "$file" 2>/dev/null | awk '{print $1}'
            ;;
        sha256)
            sha256sum "$file" 2>/dev/null | awk '{print $1}'
            ;;
        *)
            md5sum "$file" 2>/dev/null | awk '{print $1}'
            ;;
    esac
}

# 验证文件校验和
verify_checksum() {
    local file="$1"
    local expected="$2"
    local type="${3:-md5}"
    
    if [ ! -f "$file" ]; then
        return 1
    fi
    
    local actual=$(calculate_checksum "$file" "$type")
    if [ -z "$actual" ]; then
        return 1
    fi
    
    if [ "$actual" = "$expected" ]; then
        return 0
    else
        return 1
    fi
}

# ==================== 磁盘空间检查 ====================

# 检查磁盘空间是否足够
check_disk_space() {
    local target_dir="$1"
    local estimated_size="$2"  # 预估需要的空间（字节）
    
    if [ ! -d "$target_dir" ]; then
        mkdir -p "$target_dir" 2>/dev/null || {
            log_error "无法创建目录: $target_dir"
            return 1
        }
    fi
    
    # 获取目标目录所在文件系统的剩余空间
    local available_space=$(df -k "$target_dir" 2>/dev/null | tail -n1 | awk '{print $4}')
    
    if [ -z "$available_space" ] || [ "$available_space" -eq 0 ]; then
        log_error "无法获取磁盘剩余空间信息"
        return 1
    fi
    
    # 转换为字节（df -k 返回的是 KB）
    local available_bytes=$((available_space * 1024))
    
    # 添加 20% 的安全余量
    local required_bytes=$((estimated_size * (100 + DISK_SPACE_MARGIN) / 100))
    
    log_info "磁盘剩余空间: $((available_space / 1024)) MB，预估需要: $((required_bytes / 1024 / 1024)) MB"
    
    if [ "$available_bytes" -lt "$required_bytes" ]; then
        log_error "磁盘空间不足！剩余: $((available_space / 1024)) MB，需要: $((required_bytes / 1024 / 1024)) MB"
        log_error "建议：清理 /tmp 目录或删除旧的备份文件释放空间"
        return 1
    fi
    
    return 0
}

# 预估备份大小
estimate_backup_size() {
    local type="$1"
    local estimated_size=0
    
    # 统计 /etc 目录大小（系统配置 + 所有插件配置）
    if [ -d /etc ]; then
        local etc_size=$(du -sk /etc 2>/dev/null | awk '{print $1}')
        estimated_size=$((estimated_size + etc_size * 1024))
    fi
    
    # 如果是全量备份，加上已安装插件包的预估大小
    if [ "$type" = "full" ]; then
        # 检测包管理器并统计已安装包数量
        detect_pkg_manager
        local pkg_count=$(list_installed_packages | wc -l)
        
        if [ "$pkg_count" -gt 0 ]; then
            # 按每个插件包平均 80KB 估算（保守估计）
            estimated_size=$((estimated_size + pkg_count * ESTIMATE_PKG_SIZE_KB * 1024))
        else
            # 如果无法统计，按默认 100 个插件估算
            estimated_size=$((estimated_size + ESTIMATE_DEFAULT_PKG_COUNT * ESTIMATE_PKG_SIZE_KB * 1024))
        fi
    fi
    
    # 压缩后大约是原始大小的 50%
    estimated_size=$((estimated_size / ESTIMATE_COMPRESS_RATIO))
    
    echo "$estimated_size"
}

# ==================== 锁文件与清理机制 ====================

# 获取锁（防止并发执行）- 使用mkdir原子操作
acquire_lock() {
    # 尝试创建锁目录（原子操作）
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        # 获取锁成功，写入PID
        echo $$ > "$LOCK_DIR/pid"
        return 0
    fi
    
    # 获取锁失败，检查是否是过期的锁
    local pid=""
    if [ -f "$LOCK_DIR/pid" ]; then
        pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
    fi
    
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        log_error "另一个备份/恢复进程正在运行 (PID: $pid)，请稍后再试"
        return 1
    else
        # 锁已过期，清理后重新尝试
        log_info "清理过期的锁文件"
        rm -rf "$LOCK_DIR"
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            echo $$ > "$LOCK_DIR/pid"
            return 0
        else
            log_error "获取锁失败"
            return 1
        fi
    fi
}

# 释放锁
release_lock() {
    rm -rf "$LOCK_DIR"
    rm -f "$STATUS_FILE"
}

# 清理临时文件（异常退出时也会执行）
cleanup_temp_files() {
    rm -rf "$BACKUP_DIR"
    rm -rf "$RESTORE_DIR"
    rm -rf "$SNAPSHOT_DIR"
    rm -f "/tmp/.webdav_test_$$"
    update_status "idle" "0" "空闲"
    release_lock
}

# 设置 trap，确保异常退出时清理
trap cleanup_temp_files EXIT INT TERM HUP

# ==================== 日志函数 ====================

# 日志写入计数器，每写10条检查一次轮转
LOG_WRITE_COUNT=0
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    # 限制日志大小（按行数和大小双重限制）
    # 每写10条日志才检查一次轮转，减少频繁文件操作
    LOG_WRITE_COUNT=$((LOG_WRITE_COUNT + 1))
    if [ "$LOG_WRITE_COUNT" -lt "$LOG_ROTATE_CHECK_INTERVAL" ]; then
        return 0
    fi
    LOG_WRITE_COUNT=0
    
    if [ -f "$LOG_FILE" ]; then
        local log_size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
        local lines=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
        
        if [ "$log_size" -gt "$MAX_LOG_SIZE" ] || [ "$lines" -gt "$MAX_LOG_LINES" ]; then
            tail -n "$MAX_LOG_LINES" "$LOG_FILE" > "${LOG_FILE}.tmp"
            mv "${LOG_FILE}.tmp" "$LOG_FILE"
        fi
    fi
}

log_info() {
    log "INFO" "$1"
}

log_error() {
    log "ERROR" "$1"
}

log_success() {
    log "SUCCESS" "$1"
}

log_warning() {
    log "WARNING" "$1"
}

# ==================== 配置读取 ====================

# 读取UCI配置
read_config() {
    WEBDAV_URL=$(uci -q get jianguoyun-backup.global.webdav_url)
    WEBDAV_USER=$(uci -q get jianguoyun-backup.global.username)
    WEBDAV_PASS_ENC=$(uci -q get jianguoyun-backup.global.password)
    REMOTE_ROOT=$(uci -q get jianguoyun-backup.global.remote_root)
    MAX_REMOTE_BACKUPS=$(uci -q get jianguoyun-backup.global.max_remote_backups)
    MAX_LOCAL_BACKUPS=$(uci -q get jianguoyun-backup.global.max_local_backups)
    BACKUP_STORAGE=$(uci -q get jianguoyun-backup.global.backup_storage)
    KEEP_LOCAL=$(uci -q get jianguoyun-backup.global.keep_local_backup)
    
    # 读取配置版本号
    local config_ver=$(uci -q get jianguoyun-backup.global.config_version)
    if [ -z "$config_ver" ]; then
        # 旧版本配置，设置版本号
        uci set jianguoyun-backup.global.config_version="$CONFIG_VERSION"
        uci commit jianguoyun-backup
        log_info "配置版本已初始化: $CONFIG_VERSION"
    elif [ "$config_ver" -lt "$CONFIG_VERSION" ]; then
        # 需要迁移配置
        log_info "检测到旧版本配置 ($config_ver)，正在迁移到版本 $CONFIG_VERSION..."
        # 预留迁移逻辑
        # case "$config_ver" in
        #     1)
        #         # 从版本1迁移到版本2
        #         ...
        #         config_ver=2
        #         ;;
        # esac
        uci set jianguoyun-backup.global.config_version="$CONFIG_VERSION"
        uci commit jianguoyun-backup
        log_info "配置迁移完成"
    fi
    
    # 解密密码
    WEBDAV_PASS=$(decrypt_password "$WEBDAV_PASS_ENC")
    
    # 根据配置设置本地备份目录
    case "$BACKUP_STORAGE" in
        permanent)
            LOCAL_BACKUP_DIR="$PERMANENT_BACKUP_DIR"
            ;;
        tmp|*)
            LOCAL_BACKUP_DIR="$TEMP_BACKUP_DIR"
            ;;
    esac
    
    # 检测包管理器
    detect_package_manager
    
    # 轻量备份定时配置
    LIGHT_ENABLED=$(uci -q get jianguoyun-backup.light_backup.enabled)
    LIGHT_SCHEDULE=$(uci -q get jianguoyun-backup.light_backup.schedule)
    LIGHT_TIME=$(uci -q get jianguoyun-backup.light_backup.time)
    LIGHT_DAY=$(uci -q get jianguoyun-backup.light_backup.day)
    LIGHT_DAY_MONTH=$(uci -q get jianguoyun-backup.light_backup.day_month)
    
    # 全量备份定时配置
    FULL_ENABLED=$(uci -q get jianguoyun-backup.full_backup.enabled)
    FULL_SCHEDULE=$(uci -q get jianguoyun-backup.full_backup.schedule)
    FULL_TIME=$(uci -q get jianguoyun-backup.full_backup.time)
    FULL_DAY=$(uci -q get jianguoyun-backup.full_backup.day)
    FULL_DAY_MONTH=$(uci -q get jianguoyun-backup.full_backup.day_month)
    
    # 默认值
    [ -z "$WEBDAV_URL" ] && WEBDAV_URL="https://dav.jianguoyun.com/dav/"
    [ -z "$REMOTE_ROOT" ] && REMOTE_ROOT="OpenWrt_Backup"
    [ -z "$MAX_REMOTE_BACKUPS" ] && MAX_REMOTE_BACKUPS="$DEFAULT_MAX_REMOTE_BACKUPS"
    [ -z "$MAX_LOCAL_BACKUPS" ] && MAX_LOCAL_BACKUPS="$DEFAULT_MAX_LOCAL_BACKUPS"
    [ -z "$BACKUP_STORAGE" ] && BACKUP_STORAGE="tmp"
    [ -z "$KEEP_LOCAL" ] && KEEP_LOCAL="0"
    
    # 验证远程根目录，防止路径遍历
    if echo "$REMOTE_ROOT" | grep -q '\.\.'; then
        log_warning "远程根目录包含非法字符，使用默认值"
        REMOTE_ROOT="OpenWrt_Backup"
    fi
    [ -z "$LIGHT_SCHEDULE" ] && LIGHT_SCHEDULE="daily"
    [ -z "$LIGHT_TIME" ] && LIGHT_TIME="03:00"
    [ -z "$LIGHT_DAY" ] && LIGHT_DAY="0"
    [ -z "$LIGHT_DAY_MONTH" ] && LIGHT_DAY_MONTH="1"
    [ -z "$FULL_SCHEDULE" ] && FULL_SCHEDULE="weekly"
    [ -z "$FULL_TIME" ] && FULL_TIME="04:00"
    [ -z "$FULL_DAY" ] && FULL_DAY="0"
    [ -z "$FULL_DAY_MONTH" ] && FULL_DAY_MONTH="1"
    
    log_info "配置读取完成，本地备份存储位置: $BACKUP_STORAGE"
}

# 获取主机名和机型信息
get_device_info() {
    HOSTNAME=$(uci -q get system.@system[0].hostname || echo "OpenWrt")
    MODEL=$(cat /tmp/sysinfo/model 2>/dev/null || echo "Unknown")
    # 清理机型名称中的特殊字符
    MODEL=$(echo "$MODEL" | sed 's/[ /]/_/g' | sed 's/[^a-zA-Z0-9_-]//g')
    TIMESTAMP=$(date "+%Y%m%d_%H%M%S")
}

# 创建临时目录
prepare_temp_dir() {
    rm -rf "$BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"/{system_config,plugin_data,plugin_bin}
    # LOCAL_BACKUP_DIR 将在 read_config 后由 prepare_temp_dir 创建
    # 确保永久存储目录存在（日志文件需要）
    mkdir -p "$PERMANENT_BACKUP_DIR"
    mkdir -p "$(dirname "$LOG_FILE")"
}

# 清理临时文件
cleanup_temp() {
    rm -rf "$BACKUP_DIR"
}

# ==================== WebDAV 操作函数 ====================

# WebDAV公共curl请求函数
# 参数: $1=HTTP方法 $2=URL $3=输出文件(/dev/null表示丢弃) $4=额外curl参数(空格分隔)
# 返回: 通过全局变量 WEBCDAV_HTTP_CODE 返回状态码
# 返回值: 0=成功(2xx), 1=失败
webdav_curl_request() {
    local method="$1"
    local url="$2"
    local output_file="$3"
    local extra_args="$4"
    local max_time_mult="${5:-2}"
    
    local retry=0
    local curl_exit=0
    local tmp_output="/tmp/webdav_curl_$$"
    
    while [ "$retry" -le "$CURL_RETRY" ]; do
        curl_exit=0
        local http_code
        
        # 构造curl命令
        http_code=$(curl -s "$CURL_SSL_OPT"             -o "$tmp_output"             -w "%{http_code}"             --user "${WEBDAV_USER}:${WEBDAV_PASS}"             --request "$method"             --connect-timeout "$CURL_TIMEOUT"             --max-time "$((CURL_TIMEOUT * max_time_mult))"             $extra_args             "$url" 2>/dev/null) || curl_exit=$?
        
        # 网络错误处理
        if [ "$curl_exit" -ne 0 ]; then
            local err_msg
            err_msg=$(curl_error_msg "$curl_exit")
            log_warning "网络错误($curl_exit): $err_msg (重试 $((retry+1))/$CURL_RETRY)"
            retry=$((retry + 1))
            sleep "$CURL_RETRY_DELAY_NORMAL"
            continue
        fi
        
        # HTTP状态码处理
        case "$http_code" in
            200|201|204|207)
                # 成功，复制输出文件
                if [ "$output_file" != "/dev/null" ]; then
                    mv "$tmp_output" "$output_file" 2>/dev/null || cp "$tmp_output" "$output_file" 2>/dev/null
                fi
                rm -f "$tmp_output"
                WEBDAV_HTTP_CODE="$http_code"
                return 0
                ;;
            401)
                log_error "认证失败（HTTP 401）"
                log_error "排查建议：1) 确认账号正确 2) 使用应用独立密码（非登录密码） 3) 检查应用密码是否过期"
                rm -f "$tmp_output"
                WEBDAV_HTTP_CODE="$http_code"
                return 1
                ;;
            403)
                log_error "权限不足（HTTP 403）"
                log_error "排查建议：检查账号是否有对应目录的读写权限"
                rm -f "$tmp_output"
                WEBDAV_HTTP_CODE="$http_code"
                return 1
                ;;
            404)
                # 404特殊处理，由调用方决定是否创建目录
                rm -f "$tmp_output"
                WEBDAV_HTTP_CODE="$http_code"
                return 2
                ;;
            413)
                log_error "文件过大（HTTP 413），超出服务器限制"
                rm -f "$tmp_output"
                WEBDAV_HTTP_CODE="$http_code"
                return 1
                ;;
            500|502|503|504)
                log_warning "服务器错误（HTTP $http_code），稍后重试 (重试 $((retry+1))/$CURL_RETRY)"
                retry=$((retry + 1))
                sleep "$CURL_RETRY_DELAY_LONG"
                ;;
            *)
                log_warning "HTTP请求失败，状态码: $http_code (重试 $((retry+1))/$CURL_RETRY)"
                retry=$((retry + 1))
                sleep "$CURL_RETRY_DELAY_NORMAL"
                ;;
        esac
    done
    
    rm -f "$tmp_output"
    log_error "请求失败，已达最大重试次数 ($CURL_RETRY 次)"
    WEBDAV_HTTP_CODE="000"
    return 1
}

# WebDAV创建目录
webdav_mkdir() {
    local remote_path="$1"
    
    # 参数验证
    if [ -z "$remote_path" ]; then
        log_error "webdav_mkdir: 远程路径不能为空"
        return 1
    fi
    
    # 检查路径遍历
    if echo "$remote_path" | grep -q '\.\.'; then
        log_error "webdav_mkdir: 路径包含非法字符: $remote_path"
        return 1
    fi
    
    local url="${WEBDAV_URL%/}/${remote_path}"
    
    log_info "创建远端目录: $remote_path"
    
    # 调用公共curl函数
    if webdav_curl_request "MKCOL" "$url" "/dev/null" "" 2; then
        log_info "目录创建成功或已存在: $remote_path"
        return 0
    fi
    
    local ret=$?
    # 405表示目录已存在，也算成功
    if [ "$ret" -eq 2 ] || [ "$WEBDAV_HTTP_CODE" = "405" ]; then
        log_info "目录已存在: $remote_path"
        return 0
    fi
    
    return 1
}

# WebDAV上传文件
webdav_upload() {
    local local_file="$1"
    local remote_path="$2"
    
    # 参数验证
    if [ -z "$local_file" ] || [ -z "$remote_path" ]; then
        log_error "webdav_upload: 参数不能为空"
        return 1
    fi
    
    # 检查路径遍历
    if echo "$remote_path" | grep -q '\.\.'; then
        log_error "webdav_upload: 远程路径包含非法字符: $remote_path"
        return 1
    fi
    
    if echo "$local_file" | grep -q '\.\.'; then
        log_error "webdav_upload: 本地路径包含非法字符: $local_file"
        return 1
    fi
    
    local url="${WEBDAV_URL%/}/${remote_path}"
    
    log_info "上传文件: $local_file -> $remote_path"
    
    if [ ! -f "$local_file" ]; then
        log_error "本地文件不存在: $local_file"
        return 1
    fi
    
    local file_size
    file_size=$(du -h "$local_file" | awk '{print $1}')
    log_info "文件大小: $file_size"
    
    # 第一次尝试上传
    if webdav_curl_request "PUT" "$url" "/dev/null" "--upload-file "$local_file"" 10; then
        log_success "文件上传成功: $remote_path ($file_size)"
        return 0
    fi
    
    local ret=$?
    
    # 404表示目录不存在，尝试创建目录后重试
    if [ "$ret" -eq 2 ]; then
        log_info "远端目录不存在，尝试创建..."
        local dir_path
        dir_path=$(dirname "$remote_path")
        if webdav_mkdir "$dir_path"; then
            # 目录创建成功，重新上传
            if webdav_curl_request "PUT" "$url" "/dev/null" "--upload-file "$local_file"" 10; then
                log_success "文件上传成功: $remote_path ($file_size)"
                return 0
            fi
        fi
    fi
    
    log_error "文件上传失败: $remote_path"
    return 1
}

# WebDAV下载文件
webdav_download() {
    local remote_path="$1"
    local local_file="$2"
    
    # 参数验证
    if [ -z "$remote_path" ] || [ -z "$local_file" ]; then
        log_error "webdav_download: 参数不能为空"
        return 1
    fi
    
    # 检查路径遍历
    if echo "$remote_path" | grep -q '\.\.'; then
        log_error "webdav_download: 远程路径包含非法字符: $remote_path"
        return 1
    fi
    
    if echo "$local_file" | grep -q '\.\.'; then
        log_error "webdav_download: 本地路径包含非法字符: $local_file"
        return 1
    fi
    
    local url="${WEBDAV_URL%/}/${remote_path}"
    
    log_info "下载文件: $remote_path -> $local_file"
    
    # 调用公共curl函数
    if webdav_curl_request "GET" "$url" "$local_file" "" 10; then
        # 检查文件是否为空
        if [ -s "$local_file" ]; then
            log_success "文件下载成功: $remote_path"
            return 0
        else
            log_error "下载的文件为空"
            rm -f "$local_file"
            return 1
        fi
    fi
    
    local ret=$?
    if [ "$ret" -eq 2 ]; then
        log_error "文件不存在: $remote_path"
    fi
    
    rm -f "$local_file"
    return 1
}

# WebDAV列出目录
webdav_list() {
    local remote_path="$1"
    
    # 参数验证
    if [ -z "$remote_path" ]; then
        log_error "webdav_list: 远程路径不能为空"
        return 1
    fi
    
    # 检查路径遍历
    if echo "$remote_path" | grep -q '\.\.'; then
        log_error "webdav_list: 路径包含非法字符: $remote_path"
        return 1
    fi
    
    local url="${WEBDAV_URL%/}/${remote_path}"
    local tmp_body="/tmp/webdav_list_$$"
    
    log_info "列出远端目录: $remote_path"
    
    # 使用公共curl请求函数
    if ! webdav_curl_request "PROPFIND" "$url" "$tmp_body" "--header \"Depth: 1\"" 2; then
        # 404特殊处理
        if [ "$WEBDAV_HTTP_CODE" = "404" ]; then
            log_error "目录不存在: $remote_path"
        fi
        rm -f "$tmp_body"
        return 1
    fi
    
    # 解析XML提取文件名
    if grep -q "D:href" "$tmp_body" 2>/dev/null; then
        grep -o '<D:href>[^<]*</D:href>' "$tmp_body" | 
            sed 's/<D:href>//g;s/<\/D:href>//g' | 
            sed "s|.*${remote_path}/||g" | 
            grep -v '^$' | grep -v '/$'
        rm -f "$tmp_body"
        return 0
    else
        log_error "目录列表解析失败，响应格式异常"
        log_warning "排查建议：服务器返回格式可能不是标准WebDAV XML"
        rm -f "$tmp_body"
        return 1
    fi
}
# WebDAV删除文件
webdav_delete() {
    local remote_path="$1"
    
    # 参数验证
    if [ -z "$remote_path" ]; then
        log_error "webdav_delete: 远程路径不能为空"
        return 1
    fi
    
    # 检查路径遍历
    if echo "$remote_path" | grep -q '\.\.'; then
        log_error "webdav_delete: 路径包含非法字符: $remote_path"
        return 1
    fi
    
    # 验证文件名（最后一部分）
    local file_name
    file_name=$(basename "$remote_path")
    if [ -n "$file_name" ] && [ "$file_name" != "." ] && [ "$file_name" != ".." ]; then
        if ! validate_filename "$file_name" 2>/dev/null; then
            # 如果不是纯文件名（可能是目录），只检查路径遍历
            if echo "$file_name" | grep -q '\.\.'; then
                log_error "webdav_delete: 文件名包含非法字符: $file_name"
                return 1
            fi
        fi
    fi
    
    local url="${WEBDAV_URL%/}/${remote_path}"
    
    log_info "删除远端文件: $remote_path"
    
    # 调用公共curl函数
    if webdav_curl_request "DELETE" "$url" "/dev/null" "" 2; then
        log_info "文件删除成功: $remote_path"
        return 0
    fi
    
    local ret=$?
    if [ "$ret" -eq 2 ]; then
        log_warning "文件不存在，删除跳过: $remote_path"
        return 0
    fi
    
    return 1
}


# ==================== 连接测试 ====================

test_connection() {
    read_config
    
    if [ -z "$WEBDAV_URL" ] || [ -z "$WEBDAV_USER" ] || [ -z "$WEBDAV_PASS" ]; then
        echo "ERROR: 请先配置WebDAV地址、账号和密码"
        return 1
    fi
    
    echo "正在测试WebDAV连接..."
    
    # 测试认证
    local test_url="${WEBDAV_URL%/}/${REMOTE_ROOT}"
    local http_code=$(curl -s "$CURL_SSL_OPT" -o /dev/null -w "%{http_code}" \
        --user "${WEBDAV_USER}:${WEBDAV_PASS}" \
        --request PROPFIND \
        --header "Depth: 0" \
        --connect-timeout "$CURL_TIMEOUT" \
        --max-time "$((CURL_TIMEOUT * 2))" \
        "$test_url" 2>/dev/null)
    
    case "$http_code" in
        207)
            echo "SUCCESS: 连接成功，认证通过"
            # 测试写入权限
            local test_file="${REMOTE_ROOT}/.write_test_$$"
            echo "test" > /tmp/.webdav_test_$$
            
            if webdav_upload "/tmp/.webdav_test_$$" "$test_file"; then
                webdav_delete "$test_file"
                rm -f /tmp/.webdav_test_$$
                echo "SUCCESS: 写入权限正常"
                # 确保目录结构存在
                webdav_mkdir "${REMOTE_ROOT}/light"
                webdav_mkdir "${REMOTE_ROOT}/full"
                echo "SUCCESS: 目录结构已就绪"
                log_audit "test_connection" "success" "连接测试成功"
                return 0
            else
                rm -f /tmp/.webdav_test_$$
                echo "ERROR: 写入权限测试失败"
                log_audit "test_connection" "failed" "写入权限测试失败"
                return 1
            fi
            ;;
        401)
            echo "ERROR: 认证失败，请检查账号和应用密码"
            log_audit "test_connection" "failed" "认证失败"
            return 1
            ;;
        404)
            echo "INFO: 根目录不存在，尝试创建..."
            if webdav_mkdir "$REMOTE_ROOT"; then
                echo "SUCCESS: 目录创建成功"
                webdav_mkdir "${REMOTE_ROOT}/light"
                webdav_mkdir "${REMOTE_ROOT}/full"
                echo "SUCCESS: 连接测试通过"
                log_audit "test_connection" "success" "连接测试成功（新建目录）"
                return 0
            else
                echo "ERROR: 目录创建失败"
                log_audit "test_connection" "failed" "目录创建失败"
                return 1
            fi
            ;;
        000)
            echo "ERROR: 网络连接失败，请检查网络设置"
            log_audit "test_connection" "failed" "网络连接失败"
            return 1
            ;;
        *)
            echo "ERROR: 连接失败，HTTP状态码: $http_code"
            log_audit "test_connection" "failed" "HTTP错误: $http_code"
            return 1
            ;;
    esac
}

# ==================== 备份功能 ====================

# 生成插件清单
generate_plugin_list() {
    log_info "生成已安装插件清单"
    if list_installed_packages > "$BACKUP_DIR/plugin_data/plugin_list.txt" 2>/dev/null; then
        log_info "插件清单生成成功，共 $(wc -l < "$BACKUP_DIR/plugin_data/plugin_list.txt") 个插件"
    else
        log_error "插件清单生成失败"
        echo "无法获取插件列表" > "$BACKUP_DIR/plugin_data/plugin_list.txt"
    fi
}

# 备份系统配置
backup_system_config() {
    log_info "备份系统配置 (/etc目录)"
    
    # 复制/etc目录，排除一些不需要的内容
    mkdir -p "$BACKUP_DIR/system_config"
    
    # 使用tar打包/etc，排除临时文件和运行时文件
    if tar czf "$BACKUP_DIR/system_config/etc_backup.tar.gz"         --exclude='/etc/rc.d/S*'         --exclude='/etc/modules-boot.d/*'         --exclude='/etc/modules.d/*'         --exclude='/etc/init.d/*'         --exclude='/etc/hotplug.d/*'         --exclude='/etc/config/luci*'         /etc 2>/dev/null; then
        log_info "系统配置备份成功"
        return 0
    else
        log_error "系统配置备份失败"
        return 1
    fi
}

# 备份插件配置
backup_plugin_config() {
    log_info "备份插件配置数据"
    
    mkdir -p "$BACKUP_DIR/plugin_data/configs"
    
    # 备份所有UCI配置文件
    if [ -d /etc/config ]; then
        cp -a /etc/config/* "$BACKUP_DIR/plugin_data/configs/" 2>/dev/null
        log_info "UCI配置文件备份完成"
    fi
    
    # 备份常见插件数据目录
    local plugin_dirs="/etc/AdGuardHome /etc/openclash /etc/passwall /etc/shadowvpn /etc/v2ray /etc/trojan /etc/xray /etc/ssrplus /etc/aria2 /etc/transmission /etc/samba /etc/vsftpd /etc/nginx /etc/uhttpd"
    
    for dir in $plugin_dirs; do
        if [ -d "$dir" ]; then
            local dir_name=$(basename "$dir")
            mkdir -p "$BACKUP_DIR/plugin_data/app_data/$dir_name"
            cp -a "$dir"/* "$BACKUP_DIR/plugin_data/app_data/$dir_name/" 2>/dev/null
            log_info "备份插件数据: $dir"
        fi
    done
    
    return 0
}

# 备份插件本体（全量备份）
backup_plugin_binaries() {
    log_info "备份插件本体文件（全量备份）"
    
    mkdir -p "$BACKUP_DIR/plugin_bin"
    
    # 获取已安装的软件包列表并下载包文件
    detect_package_manager
    if [ "$PKG_MANAGER" != "unknown" ]; then
        mkdir -p "$BACKUP_DIR/plugin_bin/packages"
        local pkg_list=$(list_installed_packages)
        local count=0
        local total=$(echo "$pkg_list" | wc -l)
        
        log_info "开始下载插件安装包，共 $total 个"
        
        for pkg in $pkg_list; do
            # 跳过系统核心包
            case "$pkg" in
                kernel|libc|libgcc|libstdcpp|uclient*|libubox*|libuci*|libblobmsg*)
                    continue
                    ;;
            esac
            
            # 下载包文件
            if download_package "$pkg" "$BACKUP_DIR/plugin_bin/packages" 2>/dev/null; then
                count=$((count + 1))
            fi
        done
        
        log_info "插件安装包下载完成，成功 $count 个"
        
        # 保存包列表
        echo "$pkg_list" > "$BACKUP_DIR/plugin_bin/package_list.txt"
    fi
    
    return 0
}

# 清理云端旧备份
cleanup_remote_backups() {
    local type="$1"
    local max_count="$2"
    
    log_info "清理云端${type}旧备份，保留最近 $max_count 个"
    
    local count=0
    
    webdav_list "${REMOTE_ROOT}/${type}" 2>/dev/null | sort -r | while read -r file; do
        count=$((count + 1))
        if [ "$count" -gt "$max_count" ]; then
            webdav_delete "${REMOTE_ROOT}/${type}/${file}"
            log_info "删除云端旧备份: $file"
        fi
    done
}

# 执行轻量备份
do_light_backup() {
    log_info "========== 开始轻量备份 =========="
    log_audit "light_backup" "running" "开始轻量备份"
    update_status "running" "10" "准备备份..."
    
    # 记录开始时间
    BACKUP_START_TIME=$(date +%s)
    BACKUP_FILE_COUNT=0
    BACKUP_TOTAL_SIZE=0
    
    read_config
    get_device_info
    prepare_temp_dir
    
    # 磁盘空间检查
    update_status "running" "15" "检查磁盘空间..."
    local estimated_size=$(estimate_backup_size "light")
    if ! check_disk_space "$LOCAL_BACKUP_DIR" "$estimated_size"; then
        log_error "磁盘空间不足，无法进行备份"
        update_status "failed" "100" "磁盘空间不足"
        log_audit "light_backup" "failed" "磁盘空间不足"
        cleanup_temp
        return 1
    fi
    
    update_status "running" "20" "备份系统配置..."
    
    # 备份内容
    backup_system_config
    
    update_status "running" "40" "备份插件配置..."
    backup_plugin_config
    generate_plugin_list
    
    update_status "running" "60" "生成备份包..."
    
    # 生成备份包
    local filename="${HOSTNAME}_${MODEL}_${TIMESTAMP}.tar.gz"
    local local_file="$LOCAL_BACKUP_DIR/light_$filename"
    local remote_path="${REMOTE_ROOT}/light/$filename"
    
    log_info "生成轻量备份包: $filename"
    
    cd "$BACKUP_DIR" || {
        log_error "无法进入备份目录: $BACKUP_DIR"
        return 1
    }
    
    
    # 统计备份文件数量和原始大小
    BACKUP_FILE_COUNT=$(find "$BACKUP_DIR" -type f 2>/dev/null | wc -l)
    BACKUP_TOTAL_SIZE=$(du -sb "$BACKUP_DIR" 2>/dev/null | awk "{print $1}")
    log_info "备份统计：共 $BACKUP_FILE_COUNT 个文件，原始大小 $((BACKUP_TOTAL_SIZE / 1024)) KB"
    if tar czf "$local_file" system_config plugin_data 2>/dev/null && [ -s "$local_file" ]; then
        local size=$(du -h "$local_file" | awk '{print $1}')
        log_success "轻量备份包生成成功，大小: $size"
        
        # 生成校验和
        update_status "running" "70" "生成校验和..."
        local checksum=$(calculate_checksum "$local_file" "md5")
        echo "$checksum  $(basename "$local_file")" > "${local_file}.md5"
        log_info "MD5校验和: $checksum"
        
        update_status "running" "80" "上传到坚果云..."
        
        # 上传到坚果云
        if webdav_upload "$local_file" "$remote_path"; then
            # 上传校验和文件
            if ! webdav_upload "${local_file}.md5" "${remote_path}.md5" 2>/dev/null; then
                log_warning "校验和文件上传失败，不影响备份文件本身"
            fi
            log_success "轻量备份上传成功"
            
            # 根据配置决定是否保留本地备份
            if [ "$KEEP_LOCAL" = "0" ]; then
                log_info "上传成功，删除本地备份文件"
                rm -f "$local_file"
                rm -f "${local_file}.md5"
            fi
            
            # 清理云端旧备份
            update_status "running" "90" "清理旧备份..."
            cleanup_remote_backups "light" "$MAX_REMOTE_BACKUPS"
            
            # 清理本地旧备份
            cleanup_local_backups "light"
            
            cleanup_temp
            
            # 计算耗时
            BACKUP_END_TIME=$(date +%s)
            local duration=$((BACKUP_END_TIME - BACKUP_START_TIME))
            local duration_str=""
            if [ "$duration" -ge 60 ]; then
                duration_str="$((duration / 60))分$((duration % 60))秒"
            else
                duration_str="${duration}秒"
            fi
            
            # 统计信息
            log_info "========== 轻量备份完成 =========="
            log_success "备份统计："
            log_success "  • 备份文件: $filename"
            log_success "  • 备份大小: $size"
            log_success "  • 文件数量: $BACKUP_FILE_COUNT 个"
            log_success "  • 原始大小: $((BACKUP_TOTAL_SIZE / 1024)) KB"
            log_success "  • 备份类型: 轻量备份"
            log_success "  • 耗时: $duration_str"
            log_success "  • 云端保留: $MAX_REMOTE_BACKUPS 个"
            
            update_status "success" "100" "轻量备份完成（耗时 $duration_str）"
            log_audit "light_backup" "success" "备份完成，大小: $size，耗时: $duration_str"
            return 0
        else
            log_error "轻量备份上传失败，本地文件已保留: $local_file"
            update_status "failed" "100" "上传失败"
            log_audit "light_backup" "failed" "上传失败"
            cleanup_temp
            return 1
        fi
    else
        log_error "轻量备份包生成失败"
        update_status "failed" "100" "备份包生成失败"
        log_audit "light_backup" "failed" "备份包生成失败"
        cleanup_temp
        return 1
    fi
}

# 执行全量备份
do_full_backup() {
    log_info "========== 开始全量备份 =========="
    log_audit "full_backup" "running" "开始全量备份"
    update_status "running" "5" "准备备份..."
    
    # 记录开始时间
    BACKUP_START_TIME=$(date +%s)
    BACKUP_FILE_COUNT=0
    BACKUP_TOTAL_SIZE=0
    
    read_config
    get_device_info
    prepare_temp_dir
    
    # 磁盘空间检查
    update_status "running" "10" "检查磁盘空间..."
    local estimated_size=$(estimate_backup_size "full")
    if ! check_disk_space "$LOCAL_BACKUP_DIR" "$estimated_size"; then
        log_error "磁盘空间不足，无法进行备份"
        update_status "failed" "100" "磁盘空间不足"
        log_audit "full_backup" "failed" "磁盘空间不足"
        cleanup_temp
        return 1
    fi
    
    update_status "running" "15" "备份系统配置..."
    
    # 备份内容
    backup_system_config
    
    update_status "running" "30" "备份插件配置..."
    backup_plugin_config
    generate_plugin_list
    
    update_status "running" "50" "备份插件本体..."
    backup_plugin_binaries
    
    update_status "running" "70" "生成备份包..."
    
    # 生成备份包
    local filename="${HOSTNAME}_${MODEL}_${TIMESTAMP}.tar.gz"
    local local_file="$LOCAL_BACKUP_DIR/full_$filename"
    local remote_path="${REMOTE_ROOT}/full/$filename"
    
    log_info "生成全量备份包: $filename"
    
    cd "$BACKUP_DIR" || {
        log_error "无法进入备份目录: $BACKUP_DIR"
        return 1
    }
    
    
    # 统计备份文件数量和原始大小
    BACKUP_FILE_COUNT=$(find "$BACKUP_DIR" -type f 2>/dev/null | wc -l)
    BACKUP_TOTAL_SIZE=$(du -sb "$BACKUP_DIR" 2>/dev/null | awk "{print $1}")
    log_info "备份统计：共 $BACKUP_FILE_COUNT 个文件，原始大小 $((BACKUP_TOTAL_SIZE / 1024)) KB"
    if tar czf "$local_file" system_config plugin_data plugin_bin 2>/dev/null && [ -s "$local_file" ]; then
        local size=$(du -h "$local_file" | awk '{print $1}')
        log_success "全量备份包生成成功，大小: $size"
        
        # 生成校验和
        update_status "running" "80" "生成校验和..."
        local checksum=$(calculate_checksum "$local_file" "md5")
        echo "$checksum  $(basename "$local_file")" > "${local_file}.md5"
        log_info "MD5校验和: $checksum"
        
        update_status "running" "85" "上传到坚果云..."
        
        # 上传到坚果云
        if webdav_upload "$local_file" "$remote_path"; then
            # 上传校验和文件
            if ! webdav_upload "${local_file}.md5" "${remote_path}.md5" 2>/dev/null; then
                log_warning "校验和文件上传失败，不影响备份文件本身"
            fi
            log_success "全量备份上传成功"
            
            # 根据配置决定是否保留本地备份
            if [ "$KEEP_LOCAL" = "0" ]; then
                log_info "上传成功，删除本地备份文件"
                rm -f "$local_file"
                rm -f "${local_file}.md5"
            fi
            
            # 清理云端旧备份
            update_status "running" "95" "清理旧备份..."
            cleanup_remote_backups "full" "$MAX_REMOTE_BACKUPS"
            
            # 清理本地旧备份
            cleanup_local_backups "full"
            
            cleanup_temp
            
            # 计算耗时
            BACKUP_END_TIME=$(date +%s)
            local duration=$((BACKUP_END_TIME - BACKUP_START_TIME))
            local duration_str=""
            if [ "$duration" -ge 60 ]; then
                duration_str="$((duration / 60))分$((duration % 60))秒"
            else
                duration_str="${duration}秒"
            fi
            
            # 统计信息
            log_info "========== 全量备份完成 =========="
            log_success "备份统计："
            log_success "  • 备份文件: $filename"
            log_success "  • 备份大小: $size"
            log_success "  • 文件数量: $BACKUP_FILE_COUNT 个"
            log_success "  • 原始大小: $((BACKUP_TOTAL_SIZE / 1024)) KB"
            log_success "  • 备份类型: 全量备份"
            log_success "  • 耗时: $duration_str"
            log_success "  • 云端保留: $MAX_REMOTE_BACKUPS 个"
            
            update_status "success" "100" "全量备份完成（耗时 $duration_str）"
            log_audit "full_backup" "success" "备份完成，大小: $size，耗时: $duration_str"
            return 0
        else
            log_error "全量备份上传失败，本地文件已保留: $local_file"
            update_status "failed" "100" "上传失败"
            log_audit "full_backup" "failed" "上传失败"
            cleanup_temp
            return 1
        fi
    else
        log_error "全量备份包生成失败"
        update_status "failed" "100" "备份包生成失败"
        log_audit "full_backup" "failed" "备份包生成失败"
        cleanup_temp
        return 1
    fi
}

# 清理本地旧备份
cleanup_local_backups() {
    local type="$1"
    
    log_info "清理本地${type}旧备份，保留最近 $MAX_LOCAL_BACKUPS 个"
    
    local count=0
    
    ls -t "$LOCAL_BACKUP_DIR"/${type}_*.tar.gz 2>/dev/null | while read -r file; do
        count=$((count + 1))
        if [ "$count" -gt "$MAX_LOCAL_BACKUPS" ]; then
            rm -f "$file"
            rm -f "${file}.md5"
            log_info "删除旧备份: $(basename "$file")"
        fi
    done
}

# ==================== 恢复功能 ====================

# 创建当前配置快照
create_snapshot() {
    log_info "创建当前配置快照（恢复前保护）"
    
    get_device_info
    local snapshot_file="$SNAPSHOT_STORAGE_DIR/snapshot_${TIMESTAMP}.tar.gz"
    
    mkdir -p "$SNAPSHOT_DIR"
    mkdir -p "$SNAPSHOT_STORAGE_DIR"
    
    # 备份整个 /etc 目录（排除运行时生成的文件）
    log_info "备份整个 /etc 目录到快照..."
    cd /
    if tar czf "$snapshot_file"         --exclude='/etc/rc.d/S*'         --exclude='/etc/modules-boot.d/*'         --exclude='/etc/modules.d/*'         --exclude='/etc/init.d/*'         --exclude='/etc/hotplug.d/*'         --exclude='/etc/config/luci*'         --exclude='/etc/jianguoyun-backup/local/*'         etc 2>/dev/null; then
        cd /
        rm -rf "$SNAPSHOT_DIR"
        
        if [ -s "$snapshot_file" ]; then
            local size=$(du -h "$snapshot_file" | awk '{print $1}')
            log_success "配置快照已保存: $snapshot_file (大小: $size)"
            # 清理旧快照
            cleanup_snapshots
            log_info "提示：如需回滚，可手动解压此文件到 / 目录"
            return 0
        else
            cd /
            rm -rf "$SNAPSHOT_DIR"
            log_error "配置快照创建失败：文件为空"
            rm -f "$snapshot_file"
            return 1
        fi
    else
        cd /
        rm -rf "$SNAPSHOT_DIR"
        log_error "配置快照创建失败：tar命令执行失败"
        rm -f "$snapshot_file"
        return 1
    fi
}

# 列出云端备份文件

# 清理旧快照（保留最近 MAX_SNAPSHOTS 个）
cleanup_snapshots() {
    if [ ! -d "$SNAPSHOT_STORAGE_DIR" ]; then
        return 0
    fi
    
    log_info "清理旧快照，保留最近 $MAX_SNAPSHOTS 个"
    
    # 按时间排序，删除超过保留数量的旧快照
    local count=0
    
    ls -t "$SNAPSHOT_STORAGE_DIR"/snapshot_*.tar.gz 2>/dev/null | while read -r file; do
        count=$((count + 1))
        if [ "$count" -gt "$MAX_SNAPSHOTS" ]; then
            rm -f "$file"
            log_info "删除旧快照: $(basename "$file")"
        fi
    done
    
    return 0
}
list_remote_backups() {
    read_config
    
    echo "=== 轻量备份 ==="
    webdav_list "${REMOTE_ROOT}/light" 2>/dev/null || echo "无法获取轻量备份列表"
    
    echo ""
    echo "=== 全量备份 ==="
    webdav_list "${REMOTE_ROOT}/full" 2>/dev/null || echo "无法获取全量备份列表"
}

# 下载备份文件
download_backup() {
    local type="$1"
    local filename="$2"
    
    # 参数验证 - 防止路径遍历和注入
    case "$type" in
        light|full) ;;
        *)
            echo "错误：无效的备份类型"
            return 1
            ;;
    esac
    
    # 验证文件名，只允许安全字符，防止路径遍历
    if ! validate_filename "$filename"; then
        echo "错误：文件名包含非法字符"
        return 1
    fi
    
    read_config
    
    local remote_path="${REMOTE_ROOT}/${type}/${filename}"
    local local_file="$LOCAL_BACKUP_DIR/download_${filename}"
    
    if webdav_download "$remote_path" "$local_file"; then
        echo "文件已下载到: $local_file"
        log_audit "download" "success" "下载 $type/$filename"
        return 0
    else
        echo "下载失败"
        log_audit "download" "failed" "下载 $type/$filename 失败"
        return 1
    fi
}

# 恢复系统配置
restore_system_config() {
    local backup_dir="$1"
    
    log_info "恢复系统配置"
    
    if [ -f "$backup_dir/system_config/etc_backup.tar.gz" ]; then
        # 恢复配置（快照已在 do_restore 开头创建）
        cd / || {
            log_error "无法进入根目录"
            return 1
        }
        
        if tar xzf "$backup_dir/system_config/etc_backup.tar.gz" 2>/dev/null; then
            log_success "系统配置恢复成功"
            # 提交UCI变更
            uci commit 2>/dev/null
            return 0
        else
            log_error "系统配置恢复失败"
            return 1
        fi
    else
        log_error "备份包中没有系统配置"
        return 1
    fi
}

# 恢复插件配置
restore_plugin_config() {
    local backup_dir="$1"
    
    log_info "恢复插件配置"
    
    local ret=0
    restore_plugin_config_all "$backup_dir" || ret=$?
    restore_plugin_appdata_all "$backup_dir" || ret=$((ret + $?))
    
    if [ "$ret" -eq 0 ]; then
        log_success "插件配置恢复完成"
    else
        log_warning "插件配置恢复部分失败"
    fi
    return "$ret"
}

# 恢复所有插件的UCI配置
restore_plugin_config_all() {
    local backup_dir="$1"
    
    log_info "恢复所有插件UCI配置"
    
    if [ -d "$backup_dir/plugin_data/configs" ]; then
        cp -a "$backup_dir/plugin_data/configs"/* /etc/config/ 2>/dev/null
        uci commit 2>/dev/null
        log_info "UCI配置恢复完成"
        return 0
    else
        log_warning "备份包中没有插件配置"
        return 1
    fi
}

# 恢复单个插件的UCI配置
restore_single_plugin_config() {
    local backup_dir="$1"
    local plugin_name="$2"
    
    # 验证插件名，防止路径遍历
    if ! validate_filename "$plugin_name"; then
        log_error "无效的插件名: $plugin_name"
        return 1
    fi
    
    log_info "恢复插件配置: $plugin_name"
    
    local config_file="$backup_dir/plugin_data/configs/$plugin_name"
    if [ -f "$config_file" ]; then
        cp -a "$config_file" /etc/config/ 2>/dev/null
        uci commit "$plugin_name" 2>/dev/null
        log_info "插件配置恢复完成: $plugin_name"
        return 0
    else
        log_error "备份包中没有插件配置: $plugin_name"
        return 1
    fi
}

# 恢复所有插件的数据目录
restore_plugin_appdata_all() {
    local backup_dir="$1"
    
    log_info "恢复所有插件数据目录"
    
    if [ -d "$backup_dir/plugin_data/app_data" ]; then
        local count=0
        for app_dir in "$backup_dir/plugin_data/app_data"/*; do
            if [ -d "$app_dir" ]; then
                local app_name=$(basename "$app_dir")
                local target_dir="/etc/$app_name"
                mkdir -p "$target_dir"
                cp -a "$app_dir"/* "$target_dir/" 2>/dev/null
                log_info "恢复插件数据: $app_name"
                count=$((count + 1))
            fi
        done
        log_info "插件数据恢复完成，共 $count 个"
        return 0
    else
        log_warning "备份包中没有插件数据目录"
        return 1
    fi
}

# 恢复单个插件的数据目录
restore_single_plugin_appdata() {
    local backup_dir="$1"
    local plugin_name="$2"
    
    # 验证插件名，防止路径遍历
    if ! validate_filename "$plugin_name"; then
        log_error "无效的插件名: $plugin_name"
        return 1
    fi
    
    log_info "恢复插件数据: $plugin_name"
    
    local app_dir="$backup_dir/plugin_data/app_data/$plugin_name"
    if [ -d "$app_dir" ]; then
        local target_dir="/etc/$plugin_name"
        mkdir -p "$target_dir"
        cp -a "$app_dir"/* "$target_dir/" 2>/dev/null
        log_info "插件数据恢复完成: $plugin_name"
        return 0
    else
        log_warning "备份包中没有插件数据: $plugin_name"
        return 1
    fi
}

# 仅重装插件（不恢复配置）
reinstall_plugins_only() {
    local backup_dir="$1"
    
    log_info "仅重装插件，不恢复配置"
    
    if [ ! -f "$backup_dir/plugin_data/plugin_list.txt" ]; then
        log_error "插件清单文件不存在"
        return 1
    fi
    
    reinstall_plugins "$backup_dir"
    return 0
}

# 列出备份包中可恢复的插件
list_backup_plugins() {
    local backup_dir="$1"
    local output_type="${2:-all}"  # configs, appdata, all
    
    log_info "列出备份包中的插件"
    
    local configs_dir="$backup_dir/plugin_data/configs"
    local appdata_dir="$backup_dir/plugin_data/app_data"
    
    case "$output_type" in
        configs)
            if [ -d "$configs_dir" ]; then
                ls -1 "$configs_dir" 2>/dev/null
            fi
            ;;
        appdata)
            if [ -d "$appdata_dir" ]; then
                ls -1 "$appdata_dir" 2>/dev/null
            fi
            ;;
        all)
            echo "=== 插件配置列表 ==="
            if [ -d "$configs_dir" ]; then
                ls -1 "$configs_dir" 2>/dev/null
            else
                echo "(无)"
            fi
            echo ""
            echo "=== 插件数据列表 ==="
            if [ -d "$appdata_dir" ]; then
                ls -1 "$appdata_dir" 2>/dev/null
            else
                echo "(无)"
            fi
            ;;
    esac
    
    return 0
}

# 自定义恢复入口
do_restore_custom() {
    local backup_dir="$1"
    local options="$2"  # 格式：system=1,config=all,appdata=none,reinstall=1
                        # 或者：system=1,config=plugin1:plugin2,appdata=plugin1,reinstall=0
    
    log_info "执行自定义恢复"
    
    local success_count=0
    local fail_count=0
    local total_count=0
    
    # 解析选项（用 grep/cut 方式，避免子 shell 问题）
    local opt_system=0
    local opt_config="none"  # none, all, 或插件列表
    local opt_appdata="none"  # none, all, 或插件列表
    local opt_reinstall=0
    
    # 提取每个选项的值
    local val_system=$(echo "$options" | tr ',' '
' | grep "^system=" | cut -d'=' -f2)
    local val_config=$(echo "$options" | tr ',' '
' | grep "^config=" | cut -d'=' -f2)
    local val_appdata=$(echo "$options" | tr ',' '
' | grep "^appdata=" | cut -d'=' -f2)
    local val_reinstall=$(echo "$options" | tr ',' '
' | grep "^reinstall=" | cut -d'=' -f2)
    
    [ "$val_system" = "1" ] && opt_system=1
    [ -n "$val_config" ] && opt_config="$val_config"
    [ -n "$val_appdata" ] && opt_appdata="$val_appdata"
    [ "$val_reinstall" = "1" ] && opt_reinstall=1
    
    log_info "恢复选项: system=$opt_system, config=$opt_config, appdata=$opt_appdata, reinstall=$opt_reinstall"
    
    # 1. 恢复系统配置
    if [ "$opt_system" -eq 1 ]; then
        total_count=$((total_count + 1))
        if restore_system_config "$backup_dir"; then
            success_count=$((success_count + 1))
        else
            fail_count=$((fail_count + 1))
        fi
    fi
    
    # 2. 恢复插件配置
    if [ "$opt_config" != "none" ]; then
        total_count=$((total_count + 1))
        if [ "$opt_config" = "all" ]; then
            if restore_plugin_config_all "$backup_dir"; then
                success_count=$((success_count + 1))
            else
                fail_count=$((fail_count + 1))
            fi
        else
            # 自定义插件列表（冒号分隔）
            local plugins="$opt_config"
            local plugins_success=0
            local plugins_fail=0
            local plugin_name
            
            # 用 for 循环遍历（插件名不含空格，安全）
            local old_ifs="$IFS"
            IFS=':'
            for plugin_name in $plugins; do
                IFS="$old_ifs"
                [ -z "$plugin_name" ] && continue
                # 验证插件名
                if ! validate_filename "$plugin_name"; then
                    log_error "跳过无效插件名: $plugin_name"
                    plugins_fail=$((plugins_fail + 1))
                    continue
                fi
                if restore_single_plugin_config "$backup_dir" "$plugin_name"; then
                    plugins_success=$((plugins_success + 1))
                else
                    plugins_fail=$((plugins_fail + 1))
                fi
            done
            IFS="$old_ifs"
            
            if [ "$plugins_success" -gt 0 ]; then
                success_count=$((success_count + 1))
            fi
            if [ "$plugins_fail" -gt 0 ]; then
                fail_count=$((fail_count + 1))
            fi
            log_info "插件配置恢复: 成功 $plugins_success，失败 $plugins_fail"
        fi
    fi
    
    # 3. 恢复插件数据
    if [ "$opt_appdata" != "none" ]; then
        total_count=$((total_count + 1))
        if [ "$opt_appdata" = "all" ]; then
            if restore_plugin_appdata_all "$backup_dir"; then
                success_count=$((success_count + 1))
            else
                fail_count=$((fail_count + 1))
            fi
        else
            # 自定义插件列表（冒号分隔）
            local plugins="$opt_appdata"
            local plugins_success=0
            local plugins_fail=0
            local plugin_name
            
            # 用 for 循环遍历（插件名不含空格，安全）
            local old_ifs="$IFS"
            IFS=':'
            for plugin_name in $plugins; do
                IFS="$old_ifs"
                [ -z "$plugin_name" ] && continue
                if ! validate_filename "$plugin_name"; then
                    log_error "跳过无效插件名: $plugin_name"
                    plugins_fail=$((plugins_fail + 1))
                    continue
                fi
                if restore_single_plugin_appdata "$backup_dir" "$plugin_name"; then
                    plugins_success=$((plugins_success + 1))
                else
                    plugins_fail=$((plugins_fail + 1))
                fi
            done
            IFS="$old_ifs"
            
            if [ "$plugins_success" -gt 0 ]; then
                success_count=$((success_count + 1))
            fi
            if [ "$plugins_fail" -gt 0 ]; then
                fail_count=$((fail_count + 1))
            fi
            log_info "插件数据恢复: 成功 $plugins_success，失败 $plugins_fail"
        fi
    fi
    
    # 4. 重装插件
    if [ "$opt_reinstall" -eq 1 ]; then
        total_count=$((total_count + 1))
        if reinstall_plugins "$backup_dir"; then
            success_count=$((success_count + 1))
        else
            fail_count=$((fail_count + 1))
        fi
    fi
    
    log_info "自定义恢复完成: 总计 $total_count 项，成功 $success_count，失败 $fail_count"
    
    if [ "$fail_count" -eq 0 ]; then
        return 0
    else
        return 1
    fi
}

# 根据插件清单重装插件
reinstall_plugins() {
    local backup_dir="$1"
    
    log_info "根据插件清单批量重装插件"
    
    if [ ! -f "$backup_dir/plugin_data/plugin_list.txt" ]; then
        log_error "插件清单文件不存在"
        return 1
    fi
    
    # 更新软件包列表
    log_info "更新软件包列表..."
    update_package_index
    
    local success=0
    local failed=0
    local total=0
    
    while IFS= read -r line; do
        local pkg=$(echo "$line" | awk '{print $1}')
        [ -z "$pkg" ] && continue
        
        # 检查是否已安装
        if is_package_installed "$pkg"; then
            continue
        fi
        
        total=$((total + 1))
        
        if install_package "$pkg"; then
            success=$((success + 1))
            log_info "安装成功: $pkg"
        else
            failed=$((failed + 1))
            log_error "安装失败: $pkg"
        fi
    done < "$backup_dir/plugin_data/plugin_list.txt"
    
    log_info "插件重装完成: 总计 $total，成功 $success，失败 $failed"
    return 0
}

# 离线安装插件（全量备份）
offline_install_plugins() {
    local backup_dir="$1"
    
    log_info "离线安装插件（全量恢复）"
    
    if [ ! -d "$backup_dir/plugin_bin/packages" ]; then
        log_error "插件安装包目录不存在"
        return 1
    fi
    
    detect_package_manager
    
    local success=0
    local failed=0
    
    # 根据包管理器确定文件扩展名
    local pkg_ext="ipk"
    if [ "$PKG_MANAGER" = "apk" ]; then
        pkg_ext="apk"
    fi
    
    for pkg_file in "$backup_dir/plugin_bin/packages"/*.${pkg_ext}; do
        if [ -f "$pkg_file" ]; then
            if install_package "$pkg_file"; then
                success=$((success + 1))
            else
                failed=$((failed + 1))
            fi
        fi
    done
    
    log_info "离线插件安装完成: 成功 $success，失败 $failed"
    return 0
}

# 执行恢复操作
# 列出备份包中的插件（命令入口）
list_plugins_cmd() {
    read_config
    local type="$1"
    local filename="$2"
    local list_type="${3:-all}"
    
    # 验证文件名
    if ! validate_filename "$filename"; then
        echo "错误：无效的文件名"
        exit 1
    fi
    
    # 验证类型
    case "$type" in
        light|full) ;;
        *)
            echo "错误：无效的备份类型"
            exit 1
            ;;
    esac
    
    # 创建临时目录
    local tmp_dir="/tmp/jianguoyun_list_$$"
    mkdir -p "$tmp_dir"
    
    # 远程路径
    local remote_path
    if [ "$type" = "light" ]; then
        remote_path="$REMOTE_ROOT/light/$filename"
    else
        remote_path="$REMOTE_ROOT/full/$filename"
    fi
    
    # 下载备份文件
    log_info "下载备份文件: $remote_path"
    if ! webdav_download "$remote_path" "$tmp_dir/$filename"; then
        log_error "下载备份文件失败"
        rm -rf "$tmp_dir"
        exit 1
    fi
    
    # 解压
    log_info "解压备份文件"
    if ! tar -xzf "$tmp_dir/$filename" -C "$tmp_dir" 2>/dev/null; then
        log_error "解压失败"
        rm -rf "$tmp_dir"
        exit 1
    fi
    
    # 找到解压后的目录（备份包根目录）
    local backup_dir
    backup_dir=$(find "$tmp_dir" -maxdepth 1 -type d ! -name "$(basename "$tmp_dir")" | head -1)
    
    if [ -z "$backup_dir" ]; then
        log_error "未找到备份目录"
        rm -rf "$tmp_dir"
        exit 1
    fi
    
    # 列出插件
    list_backup_plugins "$backup_dir" "$list_type"
    
    # 清理
    rm -rf "$tmp_dir"
    
    return 0
}

do_restore() {
    local type="$1"
    local filename="$2"
    local mode="$3"
    
    # 参数验证 - 防止路径遍历和注入
    case "$type" in
        light|full) ;;
        *)
            log_error "无效的备份类型: $type"
            return 1
            ;;
    esac
    
    # 验证文件名，只允许安全字符，防止路径遍历
    if ! validate_filename "$filename"; then
        log_error "文件名包含非法字符: $filename"
        return 1
    fi
    
    # 验证恢复模式
    case "$mode" in
        system_only|system_plugins|full_offline) ;;
        *)
            log_error "无效的恢复模式: $mode"
            return 1
            ;;
    esac
    
    log_info "========== 开始恢复 =========="
    log_info "备份类型: $type, 文件: $filename, 模式: $mode"
    log_audit "restore" "running" "开始恢复 $type/$filename ($mode)"
    update_status "running" "5" "准备恢复..."
    
    read_config
    
    # 恢复前创建快照（无论什么模式都创建）
    update_status "running" "10" "创建配置快照..."
    create_snapshot || log_warning "快照创建失败，继续恢复（无回滚）"
    
    # 下载备份文件
    local remote_path="${REMOTE_ROOT}/${type}/${filename}"
    local local_file="$LOCAL_BACKUP_DIR/restore_${filename}"
    
    update_status "running" "20" "下载备份文件..."
    
    if ! webdav_download "$remote_path" "$local_file"; then
        log_error "备份文件下载失败"
        update_status "failed" "100" "下载失败"
        log_audit "restore" "failed" "下载失败"
        return 1
    fi
    
    # 验证校验和（如果有）
    update_status "running" "30" "验证文件完整性..."
    local checksum_file="${local_file}.md5"
    local remote_checksum="${remote_path}.md5"
    if ! webdav_download "$remote_checksum" "$checksum_file" 2>/dev/null; then
        log_warning "校验和文件下载失败，将跳过完整性验证"
    fi
    
    if [ -f "$checksum_file" ] && [ -s "$checksum_file" ]; then
        local expected=$(awk '{print $1}' "$checksum_file")
        if verify_checksum "$local_file" "$expected" "md5"; then
            log_success "文件完整性校验通过"
        else
            log_error "文件完整性校验失败，文件可能已损坏"
            rm -f "$local_file" "$checksum_file"
            update_status "failed" "100" "校验失败"
            log_audit "restore" "failed" "校验和验证失败"
            return 1
        fi
    else
        log_info "无校验和文件，跳过完整性验证"
    fi
    
    # 解压备份包
    rm -rf "$RESTORE_DIR"
    mkdir -p "$RESTORE_DIR"
    
    update_status "running" "40" "解压备份文件..."
    log_info "解压备份文件..."
    if ! tar xzf "$local_file" -C "$RESTORE_DIR" 2>/dev/null; then
        log_error "备份文件解压失败"
        rm -rf "$RESTORE_DIR"
        rm -f "$local_file" "$checksum_file"
        update_status "failed" "100" "解压失败"
        log_audit "restore" "failed" "解压失败"
        return 1
    fi
    
    update_status "running" "50" "执行恢复..."
    
    # 根据模式执行恢复
    case "$mode" in
        system_only)
            # 仅恢复系统配置
            restore_system_config "$RESTORE_DIR"
            ;;
        plugin_config_only)
            # 仅恢复插件配置
            update_status "running" "60" "恢复插件配置..."
            restore_plugin_config "$RESTORE_DIR"
            ;;
        reinstall_only)
            # 仅重装插件，不恢复配置
            update_status "running" "60" "重装插件..."
            reinstall_plugins_only "$RESTORE_DIR"
            ;;
        system_plugins)
            # 恢复系统+插件配置，并重装插件
            update_status "running" "60" "恢复系统配置..."
            restore_system_config "$RESTORE_DIR"
            update_status "running" "70" "恢复插件配置..."
            restore_plugin_config "$RESTORE_DIR"
            update_status "running" "85" "重装插件..."
            reinstall_plugins "$RESTORE_DIR"
            ;;
        full_offline)
            # 全量离线恢复
            update_status "running" "60" "恢复系统配置..."
            restore_system_config "$RESTORE_DIR"
            update_status "running" "70" "恢复插件配置..."
            restore_plugin_config "$RESTORE_DIR"
            update_status "running" "85" "离线安装插件..."
            offline_install_plugins "$RESTORE_DIR"
            ;;
        custom)
            # 自定义恢复（第4个参数是 options）
            local custom_options="${4:-system=1,config=all,appdata=all,reinstall=0}"
            update_status "running" "60" "执行自定义恢复..."
            do_restore_custom "$RESTORE_DIR" "$custom_options"
            ;;
        *)
            log_error "未知的恢复模式: $mode"
            rm -rf "$RESTORE_DIR"
            rm -f "$local_file" "$checksum_file"
            update_status "failed" "100" "未知模式"
            log_audit "restore" "failed" "未知恢复模式"
            return 1
            ;;
    esac
    
    # 清理
    rm -rf "$RESTORE_DIR"
    rm -f "$local_file" "$checksum_file"
    
    update_status "success" "100" "恢复完成"
    log_success "========== 恢复操作完成 =========="
    log_warning "注意：配置已恢复，但部分服务可能需要重启才能生效"
    log_warning "建议重启路由器以确保所有配置完全生效"
    log_info "提示：网络、防火墙、服务类配置通常需要重启后生效"
    log_audit "restore" "success" "恢复完成"
    return 0
}

# ==================== 定时任务管理 ====================

# 设置定时任务

# 验证时间格式（HH:MM）
validate_time_format() {
    local time_str="$1"
    
    # 检查是否匹配 HH:MM 格式
    if echo "$time_str" | grep -qE '^([01]?[0-9]|2[0-3]):[0-5][0-9]$'; then
        return 0
    else
        return 1
    fi
}
setup_cron() {
    read_config
    
    log_info "设置定时任务"
    
    # 读取当前 crontab，移除旧的定时任务
    local current_cron=$(crontab -l 2>/dev/null | grep -v 'jianguoyun-backup' || true)
    local new_cron="$current_cron"
    
    # 轻量备份定时任务
    if [ "$LIGHT_ENABLED" = "1" ]; then
        # 验证时间格式
        if ! validate_time_format "$LIGHT_TIME"; then
            log_warning "轻量备份时间格式错误: $LIGHT_TIME，使用默认值 03:00"
            LIGHT_TIME="03:00"
        fi
        local hour minute
        hour=$(echo "$LIGHT_TIME" | cut -d: -f1)
        minute=$(echo "$LIGHT_TIME" | cut -d: -f2)
        
        case "$LIGHT_SCHEDULE" in
            daily)
                new_cron="$new_cron
$minute $hour * * * /usr/bin/jianguoyun-backup.sh light_backup"
                log_info "轻量备份：每日 $LIGHT_TIME 执行"
                ;;
            weekly)
                new_cron="$new_cron
$minute $hour * * $LIGHT_DAY /usr/bin/jianguoyun-backup.sh light_backup"
                log_info "轻量备份：每周第 $LIGHT_DAY 天 $LIGHT_TIME 执行"
                ;;
            monthly)
                new_cron="$new_cron
$minute $hour $LIGHT_DAY_MONTH * * /usr/bin/jianguoyun-backup.sh light_backup"
                log_info "轻量备份：每月第 $LIGHT_DAY_MONTH 日 $LIGHT_TIME 执行"
                ;;
        esac
    fi
    
    # 全量备份定时任务
    if [ "$FULL_ENABLED" = "1" ]; then
        # 验证时间格式
        if ! validate_time_format "$FULL_TIME"; then
            log_warning "全量备份时间格式错误: $FULL_TIME，使用默认值 04:00"
            FULL_TIME="04:00"
        fi
        local hour minute
        hour=$(echo "$FULL_TIME" | cut -d: -f1)
        minute=$(echo "$FULL_TIME" | cut -d: -f2)
        
        case "$FULL_SCHEDULE" in
            daily)
                new_cron="$new_cron
$minute $hour * * * /usr/bin/jianguoyun-backup.sh full_backup"
                log_info "全量备份：每日 $FULL_TIME 执行"
                ;;
            weekly)
                new_cron="$new_cron
$minute $hour * * $FULL_DAY /usr/bin/jianguoyun-backup.sh full_backup"
                log_info "全量备份：每周第 $FULL_DAY 天 $FULL_TIME 执行"
                ;;
            monthly)
                new_cron="$new_cron
$minute $hour $FULL_DAY_MONTH * * /usr/bin/jianguoyun-backup.sh full_backup"
                log_info "全量备份：每月第 $FULL_DAY_MONTH 日 $FULL_TIME 执行"
                ;;
        esac
    fi
    
    # 去除空行，写回 crontab
    if echo "$new_cron" | grep -v '^$' | crontab - 2>/dev/null; then
        log_info "定时任务写入成功"
    else
        log_error "定时任务写入失败，请检查crontab权限"
    fi
    
    # 重启cron服务
    /etc/init.d/cron restart 2>/dev/null || log_warning "cron服务重启失败，定时任务可能不立即生效"
    
    log_info "定时任务设置完成"
    return 0
}

# ==================== 配置导入导出 ====================

# 导出配置为JSON
export_config() {
    read_config
    
    cat << EOF
{
  "webdav_url": "$WEBDAV_URL",
  "username": "$WEBDAV_USER",
  "password": "$WEBDAV_PASS_ENC",
  "remote_root": "$REMOTE_ROOT",
  "max_remote_backups": "$MAX_REMOTE_BACKUPS",
  "max_local_backups": "$MAX_LOCAL_BACKUPS",
  "backup_storage": "$BACKUP_STORAGE",
  "keep_local_backup": "$KEEP_LOCAL",
  "light_backup": {
    "enabled": "$LIGHT_ENABLED",
    "schedule": "$LIGHT_SCHEDULE",
    "time": "$LIGHT_TIME",
    "day": "$LIGHT_DAY",
    "day_month": "$LIGHT_DAY_MONTH"
  },
  "full_backup": {
    "enabled": "$FULL_ENABLED",
    "schedule": "$FULL_SCHEDULE",
    "time": "$FULL_TIME",
    "day": "$FULL_DAY",
    "day_month": "$FULL_DAY_MONTH"
  },
  "export_time": "$(date '+%Y-%m-%d %H:%M:%S')"
}
EOF
    
    log_audit "export_config" "success" "配置已导出"
}

# 验证导入文件的基本合法性
_validate_import_file() {
    local config_file="$1"
    
    # 文件存在性
    if [ ! -f "$config_file" ]; then
        echo "错误：配置文件不存在"
        log_error "配置导入失败：文件不存在"
        return 1
    fi
    
    # 文件名安全性
    local file_basename=$(basename "$config_file")
    if ! validate_filename "$file_basename"; then
        echo "错误：配置文件名包含非法字符"
        log_error "配置导入失败：文件名包含非法字符"
        return 1
    fi
    
    # JSON 格式：开头 {
    if ! head -1 "$config_file" | grep -q '^{'; then
        echo "错误：配置文件格式不正确（缺少开头 {）"
        log_error "配置导入失败：文件格式不是有效的JSON"
        return 1
    fi
    
    # JSON 格式：结尾 }
    if ! tail -1 "$config_file" | grep -q '}$'; then
        echo "错误：配置文件格式不正确（缺少结尾 }）"
        log_error "配置导入失败：文件格式不是有效的JSON"
        return 1
    fi
    
    # 文件大小检查（10字节 - 100KB）
    local file_size=$(wc -c < "$config_file")
    if [ "$file_size" -lt "$MIN_IMPORT_SIZE" ]; then
        echo "错误：配置文件内容过少"
        log_error "配置导入失败：文件内容过少（${file_size}字节）"
        return 1
    fi
    if [ "$file_size" -gt "$MAX_IMPORT_SIZE" ]; then
        echo "错误：配置文件过大"
        log_error "配置导入失败：文件过大（${file_size}字节）"
        return 1
    fi
    
    # 关键配置项检查
    if ! grep -q '"webdav_url"' "$config_file"; then
        echo "错误：配置文件缺少 webdav_url 配置项"
        log_error "配置导入失败：缺少 webdav_url 配置项"
        return 1
    fi
    
    return 0
}

# 验证解析后的配置值（通过全局变量传递）
_validate_import_values() {
    local has_warning=0
    
    # WebDAV地址格式
    if [ -n "$_imp_webdav_url" ]; then
        if ! echo "$_imp_webdav_url" | grep -qE '^https?://'; then
            echo "警告：WebDAV地址格式不正确，已跳过"
            log_warning "配置导入：WebDAV地址格式不正确，已跳过"
            _imp_webdav_url=""
            has_warning=1
        fi
    fi
    
    # 数字范围：云端保留数量
    if [ -n "$_imp_max_remote" ]; then
        if ! echo "$_imp_max_remote" | grep -qE '^[0-9]+$' \
           || [ "$_imp_max_remote" -lt 1 ] \
           || [ "$_imp_max_remote" -gt 100 ]; then
            echo "警告：云端备份保留数量无效，已跳过"
            log_warning "配置导入：云端备份保留数量无效，已跳过"
            _imp_max_remote=""
            has_warning=1
        fi
    fi
    
    # 数字范围：本地保留数量
    if [ -n "$_imp_max_local" ]; then
        if ! echo "$_imp_max_local" | grep -qE '^[0-9]+$' \
           || [ "$_imp_max_local" -lt 1 ] \
           || [ "$_imp_max_local" -gt 100 ]; then
            echo "警告：本地备份保留数量无效，已跳过"
            log_warning "配置导入：本地备份保留数量无效，已跳过"
            _imp_max_local=""
            has_warning=1
        fi
    fi
    
    # 备份存储位置
    if [ -n "$_imp_backup_storage" ]; then
        case "$_imp_backup_storage" in
            tmp|permanent) ;;
            *)
                echo "警告：备份存储位置无效，已跳过"
                log_warning "配置导入：备份存储位置无效，已跳过"
                _imp_backup_storage=""
                has_warning=1
                ;;
        esac
    fi
    
    # 时间格式验证
    if [ -n "$_imp_light_time" ]; then
        if ! validate_time_format "$_imp_light_time"; then
            echo "警告：轻量备份时间格式无效，已跳过"
            log_warning "配置导入：轻量备份时间格式无效，已跳过"
            _imp_light_time=""
            has_warning=1
        fi
    fi
    if [ -n "$_imp_full_time" ]; then
        if ! validate_time_format "$_imp_full_time"; then
            echo "警告：全量备份时间格式无效，已跳过"
            log_warning "配置导入：全量备份时间格式无效，已跳过"
            _imp_full_time=""
            has_warning=1
        fi
    fi
    
    # 备份周期验证
    if [ -n "$_imp_light_schedule" ]; then
        case "$_imp_light_schedule" in
            daily|weekly|monthly) ;;
            *)
                echo "警告：轻量备份周期无效，已跳过"
                log_warning "配置导入：轻量备份周期无效，已跳过"
                _imp_light_schedule=""
                has_warning=1
                ;;
        esac
    fi
    if [ -n "$_imp_full_schedule" ]; then
        case "$_imp_full_schedule" in
            daily|weekly|monthly) ;;
            *)
                echo "警告：全量备份周期无效，已跳过"
                log_warning "配置导入：全量备份周期无效，已跳过"
                _imp_full_schedule=""
                has_warning=1
                ;;
        esac
    fi
    
    return $has_warning
}

# 应用验证后的配置到 UCI（通过全局变量传递）
_apply_imported_config() {
    # 全局配置
    [ -n "$_imp_webdav_url" ] && uci set jianguoyun-backup.global.webdav_url="$_imp_webdav_url"
    [ -n "$_imp_username" ] && uci set jianguoyun-backup.global.username="$_imp_username"
    [ -n "$_imp_remote_root" ] && uci set jianguoyun-backup.global.remote_root="$_imp_remote_root"
    [ -n "$_imp_max_remote" ] && uci set jianguoyun-backup.global.max_remote_backups="$_imp_max_remote"
    [ -n "$_imp_max_local" ] && uci set jianguoyun-backup.global.max_local_backups="$_imp_max_local"
    [ -n "$_imp_backup_storage" ] && uci set jianguoyun-backup.global.backup_storage="$_imp_backup_storage"
    [ -n "$_imp_keep_local" ] && uci set jianguoyun-backup.global.keep_local_backup="$_imp_keep_local"
    
    # 轻量备份配置
    [ -n "$_imp_light_enabled" ] && uci set jianguoyun-backup.light_backup.enabled="$_imp_light_enabled"
    [ -n "$_imp_light_schedule" ] && uci set jianguoyun-backup.light_backup.schedule="$_imp_light_schedule"
    [ -n "$_imp_light_time" ] && uci set jianguoyun-backup.light_backup.time="$_imp_light_time"
    [ -n "$_imp_light_day" ] && uci set jianguoyun-backup.light_backup.day="$_imp_light_day"
    [ -n "$_imp_light_day_month" ] && uci set jianguoyun-backup.light_backup.day_month="$_imp_light_day_month"
    
    # 全量备份配置
    [ -n "$_imp_full_enabled" ] && uci set jianguoyun-backup.full_backup.enabled="$_imp_full_enabled"
    [ -n "$_imp_full_schedule" ] && uci set jianguoyun-backup.full_backup.schedule="$_imp_full_schedule"
    [ -n "$_imp_full_time" ] && uci set jianguoyun-backup.full_backup.time="$_imp_full_time"
    [ -n "$_imp_full_day" ] && uci set jianguoyun-backup.full_backup.day="$_imp_full_day"
    [ -n "$_imp_full_day_month" ] && uci set jianguoyun-backup.full_backup.day_month="$_imp_full_day_month"
    
    uci commit jianguoyun-backup
}

# 导入配置
import_config() {
    local config_file="$1"
    
    log_info "导入配置文件: $config_file"
    
    # 步骤1：验证文件基本合法性
    _validate_import_file "$config_file" || return 1
    
    # 步骤2：备份当前配置（导入失败可恢复）
    local backup_file="/etc/jianguoyun-backup/config_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
    if [ -f "$CONFIG_FILE" ]; then
        if tar -czf "$backup_file" -C /etc/config jianguoyun-backup 2>/dev/null; then
            log_info "已备份当前配置到: $(basename "$backup_file")"
        else
            log_warning "配置备份失败，继续导入"
        fi
    fi
    
    # 步骤3：解析 JSON 配置
    # 基础配置
    _imp_webdav_url=$(grep '"webdav_url"' "$config_file" | sed 's/.*: *"\([^"]*\)".*/\1/')
    _imp_username=$(grep '"username"' "$config_file" | sed 's/.*: *"\([^"]*\)".*/\1/')
    _imp_remote_root=$(grep '"remote_root"' "$config_file" | sed 's/.*: *"\([^"]*\)".*/\1/')
    _imp_max_remote=$(grep '"max_remote_backups"' "$config_file" | sed 's/.*: *"?\([0-9]*\)"?.*/\1/')
    _imp_max_local=$(grep '"max_local_backups"' "$config_file" | sed 's/.*: *"?\([0-9]*\)"?.*/\1/')
    _imp_backup_storage=$(grep '"backup_storage"' "$config_file" | sed 's/.*: *"\([^"]*\)".*/\1/')
    _imp_keep_local=$(grep '"keep_local_backup"' "$config_file" | sed 's/.*: *"\([^"]*\)".*/\1/')
    
    # 提取嵌套对象内容
    local light_section=$(sed -n '/"light_backup": {/,/},/p' "$config_file" | sed '1d;$d')
    local full_section=$(sed -n '/"full_backup": {/,/},/p' "$config_file" | sed '1d;$d')
    [ -z "$light_section" ] && light_section=$(grep -A20 '"light_backup"' "$config_file")
    [ -z "$full_section" ] && full_section=$(grep -A20 '"full_backup"' "$config_file")
    
    # 解析轻量备份配置
    _imp_light_enabled=$(echo "$light_section" | grep '"enabled"' | sed 's/.*: *"\([^"]*\)".*/\1/')
    _imp_light_schedule=$(echo "$light_section" | grep '"schedule"' | sed 's/.*: *"\([^"]*\)".*/\1/')
    _imp_light_time=$(echo "$light_section" | grep '"time"' | sed 's/.*: *"\([^"]*\)".*/\1/')
    _imp_light_day=$(echo "$light_section" | grep '"day"' | sed 's/.*: *"\([^"]*\)".*/\1/')
    _imp_light_day_month=$(echo "$light_section" | grep '"day_month"' | sed 's/.*: *"\([^"]*\)".*/\1/')
    
    # 解析全量备份配置
    _imp_full_enabled=$(echo "$full_section" | grep '"enabled"' | sed 's/.*: *"\([^"]*\)".*/\1/')
    _imp_full_schedule=$(echo "$full_section" | grep '"schedule"' | sed 's/.*: *"\([^"]*\)".*/\1/')
    _imp_full_time=$(echo "$full_section" | grep '"time"' | sed 's/.*: *"\([^"]*\)".*/\1/')
    _imp_full_day=$(echo "$full_section" | grep '"day"' | sed 's/.*: *"\([^"]*\)".*/\1/')
    _imp_full_day_month=$(echo "$full_section" | grep '"day_month"' | sed 's/.*: *"\([^"]*\)".*/\1/')
    
    # 步骤4：验证配置值
    _validate_import_values || true  # 有警告不中断
    
    # 步骤5：应用配置
    _apply_imported_config
    
    # 步骤6：重新设置定时任务
    setup_cron
    
    # 清理全局变量
    unset _imp_webdav_url _imp_username _imp_remote_root _imp_max_remote _imp_max_local
    unset _imp_backup_storage _imp_keep_local
    unset _imp_light_enabled _imp_light_schedule _imp_light_time _imp_light_day _imp_light_day_month
    unset _imp_full_enabled _imp_full_schedule _imp_full_time _imp_full_day _imp_full_day_month
    
    echo "配置导入成功"
    log_audit "import_config" "success" "配置已导入"
    return 0
}
# ==================== 日志管理 ====================

# 清空日志
clear_log() {
    > "$LOG_FILE"
    echo "日志已清空"
    log_audit "clear_log" "success" "日志已清空"
    return 0
}

# 查看日志
show_log() {
    if [ -f "$LOG_FILE" ]; then
        cat "$LOG_FILE"
    else
        echo "暂无日志记录"
    fi
}

# 查看审计日志
show_audit_log() {
    if [ -f "$AUDIT_LOG" ]; then
        cat "$AUDIT_LOG"
    else
        echo "暂无审计记录"
    fi
}

# 查看状态
show_status() {
    if [ -f "$STATUS_FILE" ]; then
        cat "$STATUS_FILE"
    else
        echo "status=idle"
        echo "progress=0"
        echo "message=空闲"
        echo "timestamp=$(date '+%Y-%m-%d %H:%M:%S')"
    fi
}

# ==================== 主程序 ====================

# 确保日志目录存在
mkdir -p "$(dirname "$LOG_FILE")"
# LOCAL_BACKUP_DIR 将在 read_config 后由 prepare_temp_dir 创建
mkdir -p "$(dirname "$STATUS_FILE")"

case "$1" in
    test)
        test_connection
        ;;
    light_backup)
        acquire_lock || exit 1
        do_light_backup
        ;;
    full_backup)
        acquire_lock || exit 1
        do_full_backup
        ;;
    list)
        list_remote_backups
        ;;
    download)
        download_backup "$2" "$3"
        ;;
    list_plugins)
        if [ $# -lt 3 ]; then
            echo "用法: $0 list_plugins <type> <filename> [list_type]"
            exit 1
        fi
        list_plugins_cmd "$2" "$3" "${4:-all}"
        ;;
    restore)
        acquire_lock || exit 1
        do_restore "$2" "$3" "$4"
        ;;
    setup_cron)
        setup_cron
        ;;
    log)
        show_log
        ;;
    clear_log)
        clear_log
        ;;
    audit_log)
        show_audit_log
        ;;
    status)
        show_status
        ;;
    export_config)
        export_config
        ;;
    import_config)
        import_config "$2"
        ;;
    *)
        echo "用法: $0 {test|light_backup|full_backup|list|download|restore|setup_cron|log|clear_log|audit_log|status|export_config|import_config}"
        echo ""
        echo "命令说明:"
        echo "  test              - 测试WebDAV连接"
        echo "  light_backup      - 执行轻量备份"
        echo "  full_backup       - 执行全量备份"
        echo "  list              - 列出云端备份文件"
        echo "  download          - 下载备份文件 (type filename)"
        echo "  list_plugins      - 列出备份包中的插件 (type filename [list_type])"
        echo "  restore           - 恢复备份 (type filename mode [options])"
        echo "                     mode: system_only | system_plugins | full_offline"
        echo "  setup_cron        - 设置定时任务"
        echo "  log               - 查看运行日志"
        echo "  clear_log         - 清空日志"
        echo "  audit_log         - 查看审计日志"
        echo "  status            - 查看当前状态"
        echo "  export_config     - 导出配置为JSON"
        echo "  import_config     - 导入配置 (config_file)"
        exit 1
        ;;
esac

exit $?

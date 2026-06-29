#!/bin/sh
# 坚果云备份插件 - 核心脚本（增强版）
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
# 临时存储的本地备份目录
TEMP_BACKUP_DIR="/tmp/jianguoyun-backup/local"
LOCK_DIR="/var/run/jianguoyun-backup.lock"
RESTORE_DIR="/tmp/jianguoyun_restore"
SNAPSHOT_DIR="/tmp/restore_snapshot"
STATUS_FILE="/var/run/jianguoyun-backup.status"

MAX_LOG_LINES=1000
MAX_LOG_SIZE=1048576  # 1MB
MAX_AUDIT_LINES=500

# 包管理器（自动检测）
PKG_MANAGER=""
MAX_LOCAL_BACKUPS=5
MAX_REMOTE_BACKUPS=10
CURL_RETRY=2
CURL_TIMEOUT=30
CURL_SSL_OPT="-k"

# 加密密钥（简单混淆，非真正加密）
ENCRYPT_KEY="jianguoyun_backup_2024"

# ==================== 工具函数 ====================

# 简单的 base64 编码加密（混淆用）
encrypt_password() {
    local plain="$1"
    if [ -z "$plain" ]; then
        echo ""
        return 0
    fi
    # 简单异或 + base64
    local encoded=$(echo "$plain" | base64 2>/dev/null)
    echo "$encoded"
}

# 解密密码
decrypt_password() {
    local encoded="$1"
    if [ -z "$encoded" ]; then
        echo ""
        return 0
    fi
    local plain=$(echo "$encoded" | base64 -d 2>/dev/null)
    if [ -z "$plain" ]; then
        # 如果解密失败，可能是明文密码，直接返回
        echo "$encoded"
    else
        echo "$plain"
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

log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    # 限制日志大小（按行数和大小双重限制）
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

# ==================== 配置读取 ====================

# 读取UCI配置
read_config() {
    WEBDAV_URL=$(uci -q get jianguoyun-backup.global.webdav_url)
    WEBDAV_USER=$(uci -q get jianguoyun-backup.global.username)
    WEBDAV_PASS_ENC=$(uci -q get jianguoyun-backup.global.password)
    REMOTE_ROOT=$(uci -q get jianguoyun-backup.global.remote_root)
    MAX_REMOTE=$(uci -q get jianguoyun-backup.global.max_remote_backups)
    BACKUP_STORAGE=$(uci -q get jianguoyun-backup.global.backup_storage)
    
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
    [ -z "$MAX_REMOTE" ] && MAX_REMOTE="$MAX_REMOTE_BACKUPS"
    [ -z "$BACKUP_STORAGE" ] && BACKUP_STORAGE="tmp"
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
    mkdir -p "$LOCAL_BACKUP_DIR"
    # 确保永久存储目录存在（日志文件需要）
    mkdir -p "$PERMANENT_BACKUP_DIR"
    mkdir -p "$(dirname "$LOG_FILE")"
}

# 清理临时文件
cleanup_temp() {
    rm -rf "$BACKUP_DIR"
}

# ==================== WebDAV 操作函数 ====================

# WebDAV创建目录
webdav_mkdir() {
    local remote_path="$1"
    local url="${WEBDAV_URL%/}/${remote_path}"
    
    log_info "创建远端目录: $remote_path"
    
    local retry=0
    while [ $retry -le $CURL_RETRY ]; do
        local http_code=$(curl -s $CURL_SSL_OPT -o /dev/null -w "%{http_code}"             --user "${WEBDAV_USER}:${WEBDAV_PASS}"             --request MKCOL             --connect-timeout $CURL_TIMEOUT             --max-time $((CURL_TIMEOUT * 2))             "$url" 2>/dev/null)
        
        case "$http_code" in
            201|204|405)
                log_info "目录创建成功或已存在: $remote_path"
                return 0
                ;;
            401)
                log_error "认证失败，请检查账号密码"
                return 1
                ;;
            *)
                log_error "创建目录失败，HTTP状态码: $http_code (重试 $((retry+1))/$CURL_RETRY)"
                retry=$((retry + 1))
                sleep 2
                ;;
        esac
    done
    
    log_error "创建目录失败，已达最大重试次数"
    return 1
}

# WebDAV上传文件
webdav_upload() {
    local local_file="$1"
    local remote_path="$2"
    local url="${WEBDAV_URL%/}/${remote_path}"
    
    log_info "上传文件: $local_file -> $remote_path"
    
    if [ ! -f "$local_file" ]; then
        log_error "本地文件不存在: $local_file"
        return 1
    fi
    
    local retry=0
    while [ $retry -le $CURL_RETRY ]; do
        local http_code=$(curl -s $CURL_SSL_OPT -o /dev/null -w "%{http_code}"             --user "${WEBDAV_USER}:${WEBDAV_PASS}"             --upload-file "$local_file"             --connect-timeout $CURL_TIMEOUT             --max-time $((CURL_TIMEOUT * 10))             "$url" 2>/dev/null)
        
        case "$http_code" in
            200|201|204)
                log_success "文件上传成功: $remote_path"
                return 0
                ;;
            401)
                log_error "认证失败，请检查账号密码"
                return 1
                ;;
            404)
                log_error "远端目录不存在，尝试创建"
                local dir_path=$(dirname "$remote_path")
                webdav_mkdir "$dir_path" || return 1
                retry=$((retry + 1))
                ;;
            *)
                log_error "上传失败，HTTP状态码: $http_code (重试 $((retry+1))/$CURL_RETRY)"
                retry=$((retry + 1))
                sleep 3
                ;;
        esac
    done
    
    log_error "文件上传失败，已达最大重试次数"
    return 1
}

# WebDAV下载文件
webdav_download() {
    local remote_path="$1"
    local local_file="$2"
    local url="${WEBDAV_URL%/}/${remote_path}"
    
    log_info "下载文件: $remote_path -> $local_file"
    
    local retry=0
    while [ $retry -le $CURL_RETRY ]; do
        local http_code=$(curl -s $CURL_SSL_OPT -o "$local_file" -w "%{http_code}"             --user "${WEBDAV_USER}:${WEBDAV_PASS}"             --connect-timeout $CURL_TIMEOUT             --max-time $((CURL_TIMEOUT * 10))             "$url" 2>/dev/null)
        
        case "$http_code" in
            200)
                if [ -s "$local_file" ]; then
                    log_success "文件下载成功: $remote_path"
                    return 0
                else
                    log_error "下载的文件为空"
                    rm -f "$local_file"
                    return 1
                fi
                ;;
            401)
                log_error "认证失败，请检查账号密码"
                return 1
                ;;
            404)
                log_error "文件不存在: $remote_path"
                return 1
                ;;
            *)
                log_error "下载失败，HTTP状态码: $http_code (重试 $((retry+1))/$CURL_RETRY)"
                rm -f "$local_file"
                retry=$((retry + 1))
                sleep 3
                ;;
        esac
    done
    
    log_error "文件下载失败，已达最大重试次数"
    return 1
}

# WebDAV列出目录
webdav_list() {
    local remote_path="$1"
    local url="${WEBDAV_URL%/}/${remote_path}"
    
    local retry=0
    while [ $retry -le $CURL_RETRY ]; do
        local result=$(curl -s $CURL_SSL_OPT             --user "${WEBDAV_USER}:${WEBDAV_PASS}"             --request PROPFIND             --header "Depth: 1"             --connect-timeout $CURL_TIMEOUT             --max-time $((CURL_TIMEOUT * 2))             -w "\n%{http_code}"             "$url" 2>/dev/null)
        
        local http_code=$(echo "$result" | tail -n1)
        local body=$(echo "$result" | sed '$d')
        
        if echo "$body" | grep -q "D:href"; then
            # 解析XML提取文件名
            echo "$body" | grep -o '<D:href>[^<]*</D:href>' |                 sed 's/<D:href>//g;s/<\/D:href>//g' |                 sed "s|.*${remote_path}/||g" |                 grep -v '^$' | grep -v '/$'
            return 0
        else
            log_error "列出目录失败，HTTP状态码: $http_code (重试 $((retry+1))/$CURL_RETRY)"
            retry=$((retry + 1))
            sleep 2
        fi
    done
    
    log_error "列出目录失败，已达最大重试次数"
    return 1
}

# WebDAV删除文件
webdav_delete() {
    local remote_path="$1"
    local url="${WEBDAV_URL%/}/${remote_path}"
    
    log_info "删除远端文件: $remote_path"
    
    local retry=0
    while [ "$retry" -le "$CURL_RETRY" ]; do
        local http_code=$(curl -s $CURL_SSL_OPT -o /dev/null -w "%{http_code}"             --user "${WEBDAV_USER}:${WEBDAV_PASS}"             --request DELETE             --connect-timeout $CURL_TIMEOUT             --max-time $((CURL_TIMEOUT * 2))             "$url" 2>/dev/null)
        
        case "$http_code" in
            200|204)
                log_info "文件删除成功: $remote_path"
                return 0
                ;;
            404)
                log_info "文件不存在: $remote_path"
                return 0
                ;;
            401)
                log_error "认证失败，请检查账号密码"
                return 1
                ;;
            *)
                log_error "删除文件失败，HTTP状态码: $http_code (重试 $((retry+1))/$CURL_RETRY)"
                retry=$((retry + 1))
                sleep 2
                ;;
        esac
    done
    
    log_error "删除文件失败，已达最大重试次数"
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
    local http_code=$(curl -s $CURL_SSL_OPT -o /dev/null -w "%{http_code}"         --user "${WEBDAV_USER}:${WEBDAV_PASS}"         --request PROPFIND         --header "Depth: 0"         --connect-timeout $CURL_TIMEOUT         --max-time $((CURL_TIMEOUT * 2))         "$test_url" 2>/dev/null)
    
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
    list_installed_packages > "$BACKUP_DIR/plugin_data/plugin_list.txt" 2>/dev/null
    if [ $? -eq 0 ]; then
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
    tar czf "$BACKUP_DIR/system_config/etc_backup.tar.gz"         --exclude='/etc/rc.d/S*'         --exclude='/etc/modules-boot.d/*'         --exclude='/etc/modules.d/*'         --exclude='/etc/init.d/*'         --exclude='/etc/hotplug.d/*'         --exclude='/etc/config/luci*'         /etc 2>/dev/null
    
    if [ $? -eq 0 ]; then
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
            download_package "$pkg" "$BACKUP_DIR/plugin_bin/packages" 2>/dev/null
            if [ $? -eq 0 ]; then
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
    
    local files=$(webdav_list "${REMOTE_ROOT}/${type}" 2>/dev/null | sort -r)
    local count=0
    
    for file in $files; do
        count=$((count + 1))
        if [ $count -gt $max_count ]; then
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
    
    read_config
    get_device_info
    prepare_temp_dir
    
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
    
    cd "$BACKUP_DIR"
    tar czf "$local_file" system_config plugin_data 2>/dev/null
    
    if [ $? -eq 0 ] && [ -s "$local_file" ]; then
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
            webdav_upload "${local_file}.md5" "${remote_path}.md5" 2>/dev/null
            log_success "轻量备份上传成功"
            
            # 清理云端旧备份
            update_status "running" "90" "清理旧备份..."
            cleanup_remote_backups "light" "$MAX_REMOTE"
            
            # 清理本地旧备份
            cleanup_local_backups "light"
            
            cleanup_temp
            update_status "success" "100" "轻量备份完成"
            log_info "========== 轻量备份完成 =========="
            log_audit "light_backup" "success" "备份完成，大小: $size"
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
    
    read_config
    get_device_info
    prepare_temp_dir
    
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
    
    cd "$BACKUP_DIR"
    tar czf "$local_file" system_config plugin_data plugin_bin 2>/dev/null
    
    if [ $? -eq 0 ] && [ -s "$local_file" ]; then
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
            webdav_upload "${local_file}.md5" "${remote_path}.md5" 2>/dev/null
            log_success "全量备份上传成功"
            
            # 清理云端旧备份
            update_status "running" "95" "清理旧备份..."
            cleanup_remote_backups "full" "$MAX_REMOTE"
            
            # 清理本地旧备份
            cleanup_local_backups "full"
            
            cleanup_temp
            update_status "success" "100" "全量备份完成"
            log_info "========== 全量备份完成 =========="
            log_audit "full_backup" "success" "备份完成，大小: $size"
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
    
    local files=$(ls -t "$LOCAL_BACKUP_DIR"/${type}_*.tar.gz 2>/dev/null)
    local count=0
    
    for file in $files; do
        count=$((count + 1))
        if [ $count -gt $MAX_LOCAL_BACKUPS ]; then
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
    local snapshot_file="$LOCAL_BACKUP_DIR/snapshot_${TIMESTAMP}.tar.gz"
    
    mkdir -p "$SNAPSHOT_DIR"
    cp -a /etc/config "$SNAPSHOT_DIR/" 2>/dev/null
    
    cd "$SNAPSHOT_DIR"
    tar czf "$snapshot_file" config 2>/dev/null
    cd /
    
    rm -rf "$SNAPSHOT_DIR"
    
    if [ -s "$snapshot_file" ]; then
        log_success "配置快照已保存: $snapshot_file"
        return 0
    else
        log_error "配置快照创建失败"
        return 1
    fi
}

# 列出云端备份文件
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
    if ! echo "$filename" | grep -qE '^[a-zA-Z0-9._-]+$'; then
        echo "错误：文件名包含非法字符"
        return 1
    fi
    
    # 额外检查：禁止路径遍历字符
    case "$filename" in
        *..*|*/*|*\$*|*\`*)
            echo "错误：文件名包含非法字符"
            return 1
            ;;
    esac
    
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
        # 先创建快照
        create_snapshot
        
        # 恢复配置
        cd /
        tar xzf "$backup_dir/system_config/etc_backup.tar.gz" 2>/dev/null
        
        if [ $? -eq 0 ]; then
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
    
    if [ -d "$backup_dir/plugin_data/configs" ]; then
        # 恢复UCI配置
        cp -a "$backup_dir/plugin_data/configs"/* /etc/config/ 2>/dev/null
        uci commit 2>/dev/null
        log_info "UCI配置恢复完成"
    fi
    
    # 恢复插件数据
    if [ -d "$backup_dir/plugin_data/app_data" ]; then
        for app_dir in "$backup_dir/plugin_data/app_data"/*; do
            if [ -d "$app_dir" ]; then
                local app_name=$(basename "$app_dir")
                local target_dir="/etc/$app_name"
                mkdir -p "$target_dir"
                cp -a "$app_dir"/* "$target_dir/" 2>/dev/null
                log_info "恢复插件数据: $app_name"
            fi
        done
    fi
    
    log_success "插件配置恢复完成"
    return 0
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
    if ! echo "$filename" | grep -qE '^[a-zA-Z0-9._-]+$'; then
        log_error "文件名包含非法字符"
        return 1
    fi
    
    # 额外检查：禁止路径遍历字符
    case "$filename" in
        *..*|*/*|*\$*|*\`*)
            log_error "文件名包含非法字符"
            return 1
            ;;
    esac
    
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
    update_status "running" "10" "准备恢复..."
    
    read_config
    
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
    webdav_download "$remote_checksum" "$checksum_file" 2>/dev/null
    
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
    tar xzf "$local_file" -C "$RESTORE_DIR" 2>/dev/null
    
    if [ $? -ne 0 ]; then
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
    log_info "提示：部分配置可能需要重启路由器后生效"
    log_audit "restore" "success" "恢复完成"
    return 0
}

# ==================== 定时任务管理 ====================

# 设置定时任务
setup_cron() {
    read_config
    
    log_info "设置定时任务"
    
    # 移除旧的定时任务
    sed -i '/jianguoyun-backup/d' /etc/crontabs/root 2>/dev/null
    
    # 轻量备份定时任务
    if [ "$LIGHT_ENABLED" = "1" ]; then
        local hour minute
        hour=$(echo "$LIGHT_TIME" | cut -d: -f1)
        minute=$(echo "$LIGHT_TIME" | cut -d: -f2)
        
        case "$LIGHT_SCHEDULE" in
            daily)
                echo "$minute $hour * * * /usr/bin/jianguoyun-backup.sh light_backup" >> /etc/crontabs/root
                log_info "轻量备份：每日 $LIGHT_TIME 执行"
                ;;
            weekly)
                echo "$minute $hour * * $LIGHT_DAY /usr/bin/jianguoyun-backup.sh light_backup" >> /etc/crontabs/root
                log_info "轻量备份：每周第 $LIGHT_DAY 天 $LIGHT_TIME 执行"
                ;;
            monthly)
                echo "$minute $hour $LIGHT_DAY_MONTH * * /usr/bin/jianguoyun-backup.sh light_backup" >> /etc/crontabs/root
                log_info "轻量备份：每月第 $LIGHT_DAY_MONTH 日 $LIGHT_TIME 执行"
                ;;
        esac
    fi
    
    # 全量备份定时任务
    if [ "$FULL_ENABLED" = "1" ]; then
        local hour minute
        hour=$(echo "$FULL_TIME" | cut -d: -f1)
        minute=$(echo "$FULL_TIME" | cut -d: -f2)
        
        case "$FULL_SCHEDULE" in
            daily)
                echo "$minute $hour * * * /usr/bin/jianguoyun-backup.sh full_backup" >> /etc/crontabs/root
                log_info "全量备份：每日 $FULL_TIME 执行"
                ;;
            weekly)
                echo "$minute $hour * * $FULL_DAY /usr/bin/jianguoyun-backup.sh full_backup" >> /etc/crontabs/root
                log_info "全量备份：每周第 $FULL_DAY 天 $FULL_TIME 执行"
                ;;
            monthly)
                echo "$minute $hour $FULL_DAY_MONTH * * /usr/bin/jianguoyun-backup.sh full_backup" >> /etc/crontabs/root
                log_info "全量备份：每月第 $FULL_DAY_MONTH 日 $FULL_TIME 执行"
                ;;
        esac
    fi
    
    # 重启cron服务
    /etc/init.d/cron restart 2>/dev/null
    
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
  "remote_root": "$REMOTE_ROOT",
  "max_remote_backups": "$MAX_REMOTE",
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

# 导入配置
import_config() {
    local config_file="$1"
    
    if [ ! -f "$config_file" ]; then
        echo "错误：配置文件不存在"
        return 1
    fi
    
    log_info "导入配置文件: $config_file"
    
    # 简单解析JSON（使用grep和sed，不依赖jq）
    local webdav_url=$(grep '"webdav_url"' "$config_file" | sed 's/.*: *"\(.*\)".*//')
    local username=$(grep '"username"' "$config_file" | sed 's/.*: *"\(.*\)".*//')
    local remote_root=$(grep '"remote_root"' "$config_file" | sed 's/.*: *"\(.*\)".*//')
    local max_remote=$(grep '"max_remote_backups"' "$config_file" | sed 's/.*: *"\?\([0-9]*\)"\?.*//')
    
    # 应用配置
    [ -n "$webdav_url" ] && uci set jianguoyun-backup.global.webdav_url="$webdav_url"
    [ -n "$username" ] && uci set jianguoyun-backup.global.username="$username"
    [ -n "$remote_root" ] && uci set jianguoyun-backup.global.remote_root="$remote_root"
    [ -n "$max_remote" ] && uci set jianguoyun-backup.global.max_remote_backups="$max_remote"
    
    uci commit jianguoyun-backup
    
    # 重新设置定时任务
    setup_cron
    
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
mkdir -p "$LOCAL_BACKUP_DIR"
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
        echo "  restore           - 恢复备份 (type filename mode)"
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

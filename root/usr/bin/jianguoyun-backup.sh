#!/bin/sh
# 坚果云备份插件 - 核心脚本
# 仅使用系统自带工具：curl, tar, uci, sysupgrade
# 兼容 OpenWrt 21.02/23.05/24.10/25.12

# ==================== 基础配置 ====================
CONFIG_FILE="/etc/config/jianguoyun-backup"
LOG_FILE="/var/log/jianguoyun-backup.log"
BACKUP_DIR="/tmp/jianguoyun-backup"
LOCAL_BACKUP_DIR="/etc/jianguoyun-backup/local"
MAX_LOG_LINES=500
MAX_LOCAL_BACKUPS=5
CURL_RETRY=2
CURL_TIMEOUT=30

# ==================== 工具函数 ====================

log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    # 限制日志行数
    if [ -f "$LOG_FILE" ]; then
        local lines=$(wc -l < "$LOG_FILE")
        if [ "$lines" -gt "$MAX_LOG_LINES" ]; then
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

# 读取UCI配置
read_config() {
    WEBDAV_URL=$(uci get jianguoyun-backup.@global[0].webdav_url 2>/dev/null)
    WEBDAV_USER=$(uci get jianguoyun-backup.@global[0].username 2>/dev/null)
    WEBDAV_PASS=$(uci get jianguoyun-backup.@global[0].password 2>/dev/null)
    REMOTE_ROOT=$(uci get jianguoyun-backup.@global[0].remote_root 2>/dev/null)
    
    # 轻量备份定时配置
    LIGHT_ENABLED=$(uci get jianguoyun-backup.@light_backup[0].enabled 2>/dev/null)
    LIGHT_SCHEDULE=$(uci get jianguoyun-backup.@light_backup[0].schedule 2>/dev/null)
    LIGHT_TIME=$(uci get jianguoyun-backup.@light_backup[0].time 2>/dev/null)
    LIGHT_DAY=$(uci get jianguoyun-backup.@light_backup[0].day 2>/dev/null)
    
    # 全量备份定时配置
    FULL_ENABLED=$(uci get jianguoyun-backup.@full_backup[0].enabled 2>/dev/null)
    FULL_SCHEDULE=$(uci get jianguoyun-backup.@full_backup[0].schedule 2>/dev/null)
    FULL_TIME=$(uci get jianguoyun-backup.@full_backup[0].time 2>/dev/null)
    FULL_DAY=$(uci get jianguoyun-backup.@full_backup[0].day 2>/dev/null)
    
    # 默认值
    [ -z "$REMOTE_ROOT" ] && REMOTE_ROOT="OpenWrt_Backup"
    [ -z "$LIGHT_SCHEDULE" ] && LIGHT_SCHEDULE="daily"
    [ -z "$LIGHT_TIME" ] && LIGHT_TIME="03:00"
    [ -z "$FULL_SCHEDULE" ] && FULL_SCHEDULE="weekly"
    [ -z "$FULL_TIME" ] && FULL_TIME="04:00"
    [ -z "$FULL_DAY" ] && FULL_DAY="0"
}

# 获取主机名和机型信息
get_device_info() {
    HOSTNAME=$(uci get system.@system[0].hostname 2>/dev/null || echo "OpenWrt")
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
        local http_code=$(curl -s -o /dev/null -w "%{http_code}" \
            --user "${WEBDAV_USER}:${WEBDAV_PASS}" \
            --request MKCOL \
            --connect-timeout $CURL_TIMEOUT \
            --max-time $((CURL_TIMEOUT * 2)) \
            "$url" 2>/dev/null)
        
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
        local http_code=$(curl -s -o /dev/null -w "%{http_code}" \
            --user "${WEBDAV_USER}:${WEBDAV_PASS}" \
            --upload-file "$local_file" \
            --connect-timeout $CURL_TIMEOUT \
            --max-time $((CURL_TIMEOUT * 10)) \
            "$url" 2>/dev/null)
        
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
        local http_code=$(curl -s -o "$local_file" -w "%{http_code}" \
            --user "${WEBDAV_USER}:${WEBDAV_PASS}" \
            --connect-timeout $CURL_TIMEOUT \
            --max-time $((CURL_TIMEOUT * 10)) \
            "$url" 2>/dev/null)
        
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
        local result=$(curl -s \
            --user "${WEBDAV_USER}:${WEBDAV_PASS}" \
            --request PROPFIND \
            --header "Depth: 1" \
            --connect-timeout $CURL_TIMEOUT \
            --max-time $((CURL_TIMEOUT * 2)) \
            "$url" 2>/dev/null)
        
        local http_code=$(echo "$?" )
        
        if [ -n "$result" ] && echo "$result" | grep -q "D:href"; then
            # 解析XML提取文件名
            echo "$result" | grep -o '<D:href>[^<]*</D:href>' | \
                sed 's/<D:href>//g;s/<\/D:href>//g' | \
                sed "s|.*${remote_path}/||g" | \
                grep -v '^$' | grep -v '/$'
            return 0
        else
            log_error "列出目录失败 (重试 $((retry+1))/$CURL_RETRY)"
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
    
    local http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        --user "${WEBDAV_USER}:${WEBDAV_PASS}" \
        --request DELETE \
        --connect-timeout $CURL_TIMEOUT \
        --max-time $((CURL_TIMEOUT * 2)) \
        "$url" 2>/dev/null)
    
    case "$http_code" in
        200|204)
            log_info "文件删除成功: $remote_path"
            return 0
            ;;
        404)
            log_info "文件不存在: $remote_path"
            return 0
            ;;
        *)
            log_error "删除文件失败，HTTP状态码: $http_code"
            return 1
            ;;
    esac
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
    local http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        --user "${WEBDAV_USER}:${WEBDAV_PASS}" \
        --request PROPFIND \
        --header "Depth: 0" \
        --connect-timeout $CURL_TIMEOUT \
        --max-time $((CURL_TIMEOUT * 2)) \
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
                return 0
            else
                rm -f /tmp/.webdav_test_$$
                echo "ERROR: 写入权限测试失败"
                return 1
            fi
            ;;
        401)
            echo "ERROR: 认证失败，请检查账号和应用密码"
            return 1
            ;;
        404)
            echo "INFO: 根目录不存在，尝试创建..."
            if webdav_mkdir "$REMOTE_ROOT"; then
                echo "SUCCESS: 目录创建成功"
                webdav_mkdir "${REMOTE_ROOT}/light"
                webdav_mkdir "${REMOTE_ROOT}/full"
                echo "SUCCESS: 连接测试通过"
                return 0
            else
                echo "ERROR: 目录创建失败"
                return 1
            fi
            ;;
        000)
            echo "ERROR: 网络连接失败，请检查网络设置"
            return 1
            ;;
        *)
            echo "ERROR: 连接失败，HTTP状态码: $http_code"
            return 1
            ;;
    esac
}

# ==================== 备份功能 ====================

# 生成插件清单
generate_plugin_list() {
    log_info "生成已安装插件清单"
    opkg list-installed > "$BACKUP_DIR/plugin_data/plugin_list.txt" 2>/dev/null
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
    tar czf "$BACKUP_DIR/system_config/etc_backup.tar.gz" \
        --exclude='/etc/rc.d/S*' \
        --exclude='/etc/modules-boot.d/*' \
        --exclude='/etc/modules.d/*' \
        --exclude='/etc/init.d/*' \
        --exclude='/etc/hotplug.d/*' \
        --exclude='/etc/config/luci*' \
        /etc 2>/dev/null
    
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
    
    # 获取已安装的软件包列表并下载ipk文件
    if command -v opkg >/dev/null 2>&1; then
        mkdir -p "$BACKUP_DIR/plugin_bin/packages"
        local pkg_list=$(opkg list-installed | awk '{print $1}')
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
            
            # 下载ipk
            opkg download "$pkg" -d "$BACKUP_DIR/plugin_bin/packages" 2>/dev/null
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

# 执行轻量备份
do_light_backup() {
    log_info "========== 开始轻量备份 =========="
    
    read_config
    get_device_info
    prepare_temp_dir
    
    # 备份内容
    backup_system_config
    backup_plugin_config
    generate_plugin_list
    
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
        
        # 上传到坚果云
        if webdav_upload "$local_file" "$remote_path"; then
            log_success "轻量备份上传成功"
        else
            log_error "轻量备份上传失败，本地文件已保留: $local_file"
        fi
        
        # 清理本地旧备份
        cleanup_local_backups "light"
        
        cleanup_temp
        log_info "========== 轻量备份完成 =========="
        return 0
    else
        log_error "轻量备份包生成失败"
        cleanup_temp
        return 1
    fi
}

# 执行全量备份
do_full_backup() {
    log_info "========== 开始全量备份 =========="
    
    read_config
    get_device_info
    prepare_temp_dir
    
    # 备份内容
    backup_system_config
    backup_plugin_config
    generate_plugin_list
    backup_plugin_binaries
    
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
        
        # 上传到坚果云
        if webdav_upload "$local_file" "$remote_path"; then
            log_success "全量备份上传成功"
        else
            log_error "全量备份上传失败，本地文件已保留: $local_file"
        fi
        
        # 清理本地旧备份
        cleanup_local_backups "full"
        
        cleanup_temp
        log_info "========== 全量备份完成 =========="
        return 0
    else
        log_error "全量备份包生成失败"
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
    
    mkdir -p /tmp/restore_snapshot
    cp -a /etc/config /tmp/restore_snapshot/ 2>/dev/null
    
    cd /tmp/restore_snapshot
    tar czf "$snapshot_file" config 2>/dev/null
    cd /
    
    rm -rf /tmp/restore_snapshot
    
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
    
    read_config
    
    local remote_path="${REMOTE_ROOT}/${type}/${filename}"
    local local_file="$LOCAL_BACKUP_DIR/download_${filename}"
    
    if webdav_download "$remote_path" "$local_file"; then
        echo "文件已下载到: $local_file"
        return 0
    else
        echo "下载失败"
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
    opkg update 2>/dev/null
    
    local success=0
    local failed=0
    local total=0
    
    while IFS= read -r line; do
        local pkg=$(echo "$line" | awk '{print $1}')
        [ -z "$pkg" ] && continue
        
        # 检查是否已安装
        if opkg list-installed | grep -q "^${pkg} "; then
            continue
        fi
        
        total=$((total + 1))
        
        if opkg install "$pkg" 2>/dev/null; then
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
    
    local success=0
    local failed=0
    
    for pkg_file in "$backup_dir/plugin_bin/packages"/*.ipk; do
        if [ -f "$pkg_file" ]; then
            if opkg install "$pkg_file" 2>/dev/null; then
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
    
    log_info "========== 开始恢复 =========="
    log_info "备份类型: $type, 文件: $filename, 模式: $mode"
    
    read_config
    
    # 下载备份文件
    local remote_path="${REMOTE_ROOT}/${type}/${filename}"
    local local_file="$LOCAL_BACKUP_DIR/restore_${filename}"
    
    if ! webdav_download "$remote_path" "$local_file"; then
        log_error "备份文件下载失败"
        return 1
    fi
    
    # 解压备份包
    local restore_dir="/tmp/jianguoyun_restore"
    rm -rf "$restore_dir"
    mkdir -p "$restore_dir"
    
    log_info "解压备份文件..."
    tar xzf "$local_file" -C "$restore_dir" 2>/dev/null
    
    if [ $? -ne 0 ]; then
        log_error "备份文件解压失败"
        rm -rf "$restore_dir"
        return 1
    fi
    
    # 根据模式执行恢复
    case "$mode" in
        system_only)
            # 仅恢复系统配置
            restore_system_config "$restore_dir"
            ;;
        system_plugins)
            # 恢复系统+插件配置，并重装插件
            restore_system_config "$restore_dir"
            restore_plugin_config "$restore_dir"
            reinstall_plugins "$restore_dir"
            ;;
        full_offline)
            # 全量离线恢复
            restore_system_config "$restore_dir"
            restore_plugin_config "$restore_dir"
            offline_install_plugins "$restore_dir"
            ;;
        *)
            log_error "未知的恢复模式: $mode"
            rm -rf "$restore_dir"
            return 1
            ;;
    esac
    
    # 清理
    rm -rf "$restore_dir"
    rm -f "$local_file"
    
    log_success "========== 恢复操作完成 =========="
    log_info "提示：部分配置可能需要重启路由器后生效"
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
                echo "$minute $hour $LIGHT_DAY * * /usr/bin/jianguoyun-backup.sh light_backup" >> /etc/crontabs/root
                log_info "轻量备份：每月第 $LIGHT_DAY 日 $LIGHT_TIME 执行"
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
                echo "$minute $hour $FULL_DAY * * /usr/bin/jianguoyun-backup.sh full_backup" >> /etc/crontabs/root
                log_info "全量备份：每月第 $FULL_DAY 日 $FULL_TIME 执行"
                ;;
        esac
    fi
    
    # 重启cron服务
    /etc/init.d/cron restart 2>/dev/null
    
    log_info "定时任务设置完成"
    return 0
}

# ==================== 日志管理 ====================

# 清空日志
clear_log() {
    > "$LOG_FILE"
    echo "日志已清空"
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

# ==================== 主程序 ====================

# 确保日志目录存在
mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$LOCAL_BACKUP_DIR"

case "$1" in
    test)
        test_connection
        ;;
    light_backup)
        do_light_backup
        ;;
    full_backup)
        do_full_backup
        ;;
    list)
        list_remote_backups
        ;;
    download)
        download_backup "$2" "$3"
        ;;
    restore)
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
    *)
        echo "用法: $0 {test|light_backup|full_backup|list|download|restore|setup_cron|log|clear_log}"
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
        exit 1
        ;;
esac

exit $?

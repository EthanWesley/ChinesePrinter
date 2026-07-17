#!/bin/sh
# ============================================================================
# ChinesePrinter 一键安装/更新脚本 (Shell Edition)
# 目标设备: Luckfox Pico KVM (RV1106G3, 单核 Cortex-A7)
# 功能: 部署中文 Alt 码自动打字网页服务 + 开机自启
# 依赖: socat, awk（系统自带，无需 Python）
#
# 用法: sudo sh install.sh [端口号] [HID设备路径]
#   sudo sh install.sh              # 默认端口 8848, HID 自动识别
#   sudo sh install.sh 9000         # 端口 9000
#   sudo sh install.sh 9000 /dev/hidg1
#
# 自动识别模式：
#   - 首次运行（/opt/chinese-printer 不存在）-> 全新安装
#   - 再次运行（已存在）-> 自动更新（保留现有配置，备份旧代码）
# ============================================================================

set -e

# ---- 固定配置 ----
INSTALL_DIR="/opt/chinese-printer"
SERVICE_NAME="chinese-printer"
ENV_FILE="$INSTALL_DIR/chinese-printer.env"

# ---- 检测安装模式 ----
IS_UPDATE=0
if [ -d "$INSTALL_DIR" ] && [ -f "$INSTALL_DIR/server.sh" ]; then
    IS_UPDATE=1
fi

# ---- 从现有 .env 读取配置（更新模式）----
EXISTING_PORT=""
EXISTING_HID=""
if [ "$IS_UPDATE" -eq 1 ] && [ -f "$ENV_FILE" ]; then
    while IFS='=' read -r _key _val; do
        case "$_key" in
            APP_PORT)        EXISTING_PORT="$_val" ;;
            HID_DEVICE)      EXISTING_HID="$_val" ;;
        esac
    done < "$ENV_FILE" 2>/dev/null || true
fi

# ---- 校验从 env 读取的配置合法性 ----
# 防止 env 文件被破坏（如旧版 bug 写入 APP_PORT=--retain-config）导致服务无法启动
# 端口必须是 1-65535 的纯数字，HID 路径必须形如 /dev/hidgN
_valid_port() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null ;;
    esac
}
_valid_hid() {
    case "$1" in
        /dev/hidg[0-9]) return 0 ;;
        /dev/hidg[0-9][0-9]) return 0 ;;
        *) return 1 ;;
    esac
}
if [ -n "$EXISTING_PORT" ] && ! _valid_port "$EXISTING_PORT"; then
    EXISTING_PORT=""
fi
if [ -n "$EXISTING_HID" ] && ! _valid_hid "$EXISTING_HID"; then
    EXISTING_HID=""
fi

# ---- 参数解析 ----
# 支持 --retain-config 标志（更新模式下保留现有配置，不覆盖端口/HID）
# 也支持位置参数: sh install.sh [端口号] [HID设备路径]
_RETAIN_CONFIG=0
_ARG_PORT=""
_ARG_HID=""
for _a in "$@"; do
    case "$_a" in
        --retain-config) _RETAIN_CONFIG=1 ;;
        --*) : ;;  # 忽略未知长选项
        *)
            if [ -z "$_ARG_PORT" ]; then _ARG_PORT="$_a"
            elif [ -z "$_ARG_HID" ]; then _ARG_HID="$_a"
            fi
            ;;
    esac
done

# ---- 参数优先级：命令行 > 环境变量 > 现有配置 > 默认值 ----
# --retain-config 模式下，跳过命令行参数，使用现有配置
if [ "$_RETAIN_CONFIG" -eq 1 ] && [ "$IS_UPDATE" -eq 1 ]; then
    APP_PORT="${EXISTING_PORT:-8848}"
    HID_DEVICE="${EXISTING_HID:-/dev/hidg0}"
else
    APP_PORT="${_ARG_PORT:-${APP_PORT:-${EXISTING_PORT:-8848}}}"
    HID_DEVICE="${_ARG_HID:-${HID_DEVICE:-${EXISTING_HID:-/dev/hidg0}}}"
fi

# ---- 脚本所在目录（源文件目录）----
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---- 自动下载源文件（支持 curl | sh 一键安装/更新）----
# 如果当前目录没有 server.sh，说明是通过管道运行的，自动从 GitHub 下载
if [ ! -f "$SCRIPT_DIR/server.sh" ]; then
    _REPO_URL="https://github.com/EthanWesley/ChinesePrinter/archive/refs/heads/main.tar.gz"
    _TMP_DIR=$(mktemp -d 2>/dev/null || mkdir -p /tmp/cp-install-$$ && echo /tmp/cp-install-$$)
    printf "[INFO]  当前目录无源文件，从 GitHub 下载: %s\n" "$_REPO_URL"
    if command -v curl >/dev/null 2>&1; then
        curl -sSL "$_REPO_URL" -o "$_TMP_DIR/src.tar.gz" || { printf "[ERROR] 下载失败\n"; exit 1; }
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$_TMP_DIR/src.tar.gz" "$_REPO_URL" || { printf "[ERROR] 下载失败\n"; exit 1; }
    else
        printf "[ERROR] 需要 curl 或 wget 来下载源文件\n"; exit 1
    fi
    # BusyBox tar 不支持 -z，用 gzip 管道
    if ! gzip -d -c "$_TMP_DIR/src.tar.gz" | tar -xf - -C "$_TMP_DIR" 2>/dev/null; then
        printf "[ERROR] 解压失败\n"; rm -rf "$_TMP_DIR"; exit 1
    fi
    rm -f "$_TMP_DIR/src.tar.gz"
    # 重新执行解压目录中的 install.sh，传递相同参数
    if [ -f "$_TMP_DIR/ChinesePrinter-main/install.sh" ]; then
        exec sh "$_TMP_DIR/ChinesePrinter-main/install.sh" "$@"
    else
        printf "[ERROR] 解压后未找到 install.sh\n"; rm -rf "$_TMP_DIR"; exit 1
    fi
fi

# ---- 颜色 ----
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; NC=''
fi

info()  { printf "${CYAN}[INFO]${NC}  %s\n" "$1"; }
ok()    { printf "${GREEN}[OK]${NC}    %s\n" "$1"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$1"; }
err()   { printf "${RED}[ERROR]${NC} %s\n" "$1"; }
line()  { printf "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; }

line
if [ "$IS_UPDATE" -eq 1 ]; then
    printf "${YELLOW}  ChinesePrinter 更新${NC} (Shell Edition)\n"
    printf "  模式: 更新现有安装（保留配置）\n"
else
    printf "${CYAN}  ChinesePrinter 全新安装${NC} (Shell Edition)\n"
    printf "  模式: 首次安装\n"
fi
printf "  目标: Luckfox Pico KVM (RV1106G3)\n"
printf "  端口: %s | HID: %s\n" "$APP_PORT" "$HID_DEVICE"
line

# ============================================================================
# 1. 前置检查
# ============================================================================
info "步骤 1/5: 环境检查"

# 检查 root
if [ "$(id -u)" -ne 0 ]; then
    err "请使用 root 权限运行: sudo sh $0"
    exit 1
fi
ok "root 权限"

# 检查 socat（核心依赖，用于 HTTP 服务）
if ! command -v socat >/dev/null 2>&1; then
    err "未找到 socat，这是必须的依赖"
    err "请安装: opkg install socat 或 apt-get install socat"
    exit 1
fi
ok "socat: $(command -v socat)"

# 检查 awk（用于 JSON 解析和 URL 解码）
if ! command -v awk >/dev/null 2>&1; then
    err "未找到 awk，这是必须的依赖"
    err "请安装: opkg install awk 或 apt-get install gawk"
    exit 1
fi
ok "awk: $(command -v awk)"

# 检查 sh（解释器）
ok "sh: $0"

# 获取 HID 设备的 protocol（1=键盘, 2=鼠标，空=未知）
# 优先 /sys/class/hidg/<name>/protocol，回退到 configfs 的 hid.usbN
get_hid_protocol() {
    _dev_path="$1"
    _dev_name="${_dev_path#/dev/}"
    _dev_idx="${_dev_name#hidg}"

    _proto_file="/sys/class/hidg/${_dev_name}/protocol"
    if [ -r "$_proto_file" ]; then
        cat "$_proto_file" 2>/dev/null
        return
    fi
    for _cfg in /sys/kernel/config/usb_gadget/*/functions/hid.usb"${_dev_idx}"; do
        [ -r "$_cfg/protocol" ] || continue
        cat "$_cfg/protocol" 2>/dev/null
        return
    done
    echo ""
}

proto_to_desc() {
    case "$1" in
        1) echo "键盘" ;;
        2) echo "鼠标" ;;
        *) echo "未知($1)" ;;
    esac
}

# 检查 HID 设备（支持自动识别键盘设备）
detect_hid_keyboard() {
    for dev in /dev/hidg*; do
        [ -e "$dev" ] || continue
        proto=$(get_hid_protocol "$dev")
        if [ "$proto" = "1" ]; then
            echo "$dev"
            return 0
        fi
    done
    [ -e /dev/hidg0 ] && echo "/dev/hidg0" && return 0
    return 1
}

# 如果用户没显式指定 HID 设备（仍是默认值），尝试自动识别
if [ "$HID_DEVICE" = "/dev/hidg0" ]; then
    info "尝试自动识别 HID 键盘设备..."
    AUTO_HID=$(detect_hid_keyboard)
    if [ -n "$AUTO_HID" ]; then
        HID_DEVICE="$AUTO_HID"
        ok "自动识别到键盘设备: $HID_DEVICE"
    else
        warn "未自动识别到 HID 键盘设备"
    fi
fi

if [ -e "$HID_DEVICE" ]; then
    proto=$(get_hid_protocol "$HID_DEVICE")
    proto_desc=$(proto_to_desc "$proto")
    ok "HID 设备: $HID_DEVICE (类型: $proto_desc)"
else
    warn "HID 设备 $HID_DEVICE 不存在"
    warn "可能原因:"
    warn "  1. USB HID gadget 尚未配置（KVM 固件可能需要先启用 HID 模式）"
    warn "  2. 设备路径不同，可通过参数指定: sudo sh $0 $APP_PORT /dev/hidg1"
    warn "  3. USB 线未连接到目标电脑"
    echo ""
    info "搜索可能的 HID 设备..."
    for dev in /dev/hidg*; do
        [ -e "$dev" ] || continue
        proto=$(get_hid_protocol "$dev")
        proto_desc=$(proto_to_desc "$proto")
        echo "    发现: $dev (类型: $proto_desc)"
    done 2>/dev/null || true
    echo ""
    warn "服务仍会安装，但打字功能在 HID 设备可用前无法工作"
fi

# 检查 init 系统
HAS_SYSTEMD=0
if command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then
    HAS_SYSTEMD=1
    ok "init 系统: systemd"
else
    ok "init 系统: SysVinit / BusyBox"
fi

# ============================================================================
# 2. 安装文件（更新时先备份）
# ============================================================================
echo ""
info "步骤 2/5: 安装文件到 $INSTALL_DIR"

mkdir -p "$INSTALL_DIR/templates"

# 更新模式：备份当前代码文件（不备份 .env 和 templates）
BACKUP_DIR=""
if [ "$IS_UPDATE" -eq 1 ]; then
    BACKUP_DIR="$INSTALL_DIR/.backup-$(date +%Y%m%d%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    for f in server.sh hid_keyboard.sh; do
        [ -f "$INSTALL_DIR/$f" ] && cp "$INSTALL_DIR/$f" "$BACKUP_DIR/$f"
    done
    [ -f "$INSTALL_DIR/templates/index.html" ] && {
        mkdir -p "$BACKUP_DIR/templates"
        cp "$INSTALL_DIR/templates/index.html" "$BACKUP_DIR/templates/index.html"
    }
    [ -f "$INSTALL_DIR/templates/gbk_table.json" ] && {
        mkdir -p "$BACKUP_DIR/templates"
        cp "$INSTALL_DIR/templates/gbk_table.json" "$BACKUP_DIR/templates/gbk_table.json"
    }
    # 只保留最近 3 个备份
    ls -1d "$INSTALL_DIR/.backup-"* 2>/dev/null | sort -r | tail -n +4 | while read -r old; do
        rm -rf "$old" 2>/dev/null || true
    done
    ok "旧版本已备份到: $BACKUP_DIR"
fi

# 复制 Shell 脚本
for f in server.sh hid_keyboard.sh; do
    src="$SCRIPT_DIR/$f"
    if [ ! -f "$src" ]; then
        err "源文件不存在: $src"
        exit 1
    fi
    cp "$src" "$INSTALL_DIR/$f"
    ok "已安装: $f"
done

# 复制 C 原生加速器（如果存在）
if [ -f "$SCRIPT_DIR/native/hid_writer" ]; then
    cp "$SCRIPT_DIR/native/hid_writer" "$INSTALL_DIR/hid_writer"
    chmod 755 "$INSTALL_DIR/hid_writer"
    # 验证是否能执行
    if "$INSTALL_DIR/hid_writer" --help >/dev/null 2>&1; then
        ok "已安装: hid_writer (C 原生加速器, 已启用)"
    else
        warn "hid_writer 安装但无法执行 (可能是架构不匹配), 将回退到 Shell 模式"
        rm -f "$INSTALL_DIR/hid_writer"
    fi
else
    info "未找到 C 原生加速器 (native/hid_writer), 使用 Shell 模式"
fi

# 复制 HTML 和 GBK 编码表
for f in index.html gbk_table.json; do
    src="$SCRIPT_DIR/templates/$f"
    if [ -f "$src" ]; then
        cp "$src" "$INSTALL_DIR/templates/$f"
        ok "已安装: templates/$f"
    else
        warn "源文件不存在: $src（跳过）"
    fi
done

chmod 755 "$INSTALL_DIR/server.sh" "$INSTALL_DIR/hid_keyboard.sh"

# ============================================================================
# 3. 配置环境变量（更新时保留现有配置）
# ============================================================================
echo ""
info "步骤 3/5: 生成配置文件"

if [ "$IS_UPDATE" -eq 1 ] && [ -f "$ENV_FILE" ]; then
    NEED_UPDATE_ENV=0
    CUR_PORT=$(grep -m1 '^APP_PORT=' "$ENV_FILE" 2>/dev/null | cut -d= -f2 || echo "")
    CUR_HID=$(grep -m1 '^HID_DEVICE=' "$ENV_FILE" 2>/dev/null | cut -d= -f2 || echo "")

    # 比较 env 现值与校验后的目标值，不同则修复（含 env 被破坏被回退到默认值的情况）
    _env_fix() {
        _key="$1"; _val="$2"
        # BusyBox sed -i 可能不支持，提供 fallback
        sed -i "s/^${_key}=.*/${_key}=${_val}/" "$ENV_FILE" 2>/dev/null || \
            { cp "$ENV_FILE" "${ENV_FILE}.tmp"; sed "s/^${_key}=.*/${_key}=${_val}/" "${ENV_FILE}.tmp" > "$ENV_FILE"; rm -f "${ENV_FILE}.tmp"; }
    }
    if [ "$CUR_PORT" != "$APP_PORT" ]; then
        _env_fix "APP_PORT" "$APP_PORT"
        NEED_UPDATE_ENV=1
        warn "修复 env 中的 APP_PORT: '$CUR_PORT' -> '$APP_PORT'"
    fi
    if [ "$CUR_HID" != "$HID_DEVICE" ]; then
        _env_fix "HID_DEVICE" "$HID_DEVICE"
        NEED_UPDATE_ENV=1
        warn "修复 env 中的 HID_DEVICE: '$CUR_HID' -> '$HID_DEVICE'"
    fi

    if [ "$NEED_UPDATE_ENV" -eq 1 ]; then
        ok "配置已更新（端口/HID）: $ENV_FILE"
    else
        ok "保留现有配置: $ENV_FILE"
    fi
else
    cat > "$ENV_FILE" <<EOF
# ChinesePrinter 环境变量配置 (Shell Edition)
# 修改后重启服务生效
APP_HOST=0.0.0.0
APP_PORT=$APP_PORT
HID_DEVICE=$HID_DEVICE
KEY_DELAY=0
ALT_RELEASE_DELAY=0
CHAR_DELAY=0
EOF
    ok "配置文件已创建: $ENV_FILE"
fi

# ============================================================================
# 4. 配置开机自启（更新时确保配置同步）
# ============================================================================
echo ""
if [ "$IS_UPDATE" -eq 1 ]; then
    info "步骤 4/5: 更新服务配置"
else
    info "步骤 4/5: 配置开机自启"
fi

if [ "$HAS_SYSTEMD" -eq 1 ]; then
    SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=ChinesePrinter - 中文 Alt 码自动打字服务 (Shell Edition)
After=network.target
Wants=network.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$ENV_FILE
ExecStart=/bin/sh $INSTALL_DIR/server.sh
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    if [ "$IS_UPDATE" -eq 1 ]; then
        systemctl restart "$SERVICE_NAME"
        ok "systemd 服务已重启: $SERVICE_NAME"
    else
        systemctl enable "$SERVICE_NAME" 2>/dev/null
        systemctl restart "$SERVICE_NAME"
        ok "systemd 服务已创建并启用: $SERVICE_NAME"
    fi
else
    INIT_SCRIPT="/etc/init.d/$SERVICE_NAME"
    cat > "$INIT_SCRIPT" <<EOF
#!/bin/sh
### BEGIN INIT INFO
# Provides:          $SERVICE_NAME
# Required-Start:    \$network
# Required-Stop:     \$network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: ChinesePrinter 中文打字服务
### END INIT INFO

DAEMON_DIR="$INSTALL_DIR"
ENV_FILE="$ENV_FILE"
PIDFILE="/var/run/$SERVICE_NAME.pid"

if [ -f "\$ENV_FILE" ]; then
    export \$(grep -v '^#' "\$ENV_FILE" | xargs)
fi

case "\$1" in
    start)
        echo -n "Starting $SERVICE_NAME..."
        cd "\$DAEMON_DIR"
        start-stop-daemon -S -m -p "\$PIDFILE" -b \\
            -x /bin/sh -- \$DAEMON_DIR/server.sh
        echo " done"
        ;;
    stop)
        echo -n "Stopping $SERVICE_NAME..."
        if [ -f "\$PIDFILE" ]; then
            kill \$(cat "\$PIDFILE") 2>/dev/null || true
            rm -f "\$PIDFILE"
        fi
        # 也杀掉 socat 子进程
        pkill -f "server.sh" 2>/dev/null || true
        echo " done"
        ;;
    restart)
        \$0 stop
        sleep 1
        \$0 start
        ;;
    status)
        if [ -f "\$PIDFILE" ] && kill -0 \$(cat "\$PIDFILE") 2>/dev/null; then
            echo "$SERVICE_NAME is running (PID \$(cat \$PIDFILE))"
        else
            echo "$SERVICE_NAME is stopped"
        fi
        ;;
    *)
        echo "Usage: \$0 {start|stop|restart|status}"
        exit 1
        ;;
esac
exit 0
EOF

    chmod 755 "$INIT_SCRIPT"

    if [ "$IS_UPDATE" -eq 0 ]; then
        if command -v update-rc.d >/dev/null 2>&1; then
            update-rc.d "$SERVICE_NAME" defaults 2>/dev/null
            ok "update-rc.d 已启用开机自启"
        elif command -v chkconfig >/dev/null 2>&1; then
            chkconfig --add "$SERVICE_NAME" 2>/dev/null
            ok "chkconfig 已启用开机自启"
        else
            # BusyBox init: rcS 只执行 /etc/init.d/S??* 脚本
            # 必须用 SNN 前缀的软链接才能开机启动（rc.local 在此系统不会被调用）
            BUSYBOX_RCS_LINK=""
            if [ -f /etc/init.d/rcS ] && grep -q "S??\*" /etc/init.d/rcS 2>/dev/null; then
                # 检测为 BusyBox init rcS 机制
                for n in 99 98 97 50; do
                    _candidate="/etc/init.d/S${n}${SERVICE_NAME}"
                    if [ ! -e "$_candidate" ]; then
                        BUSYBOX_RCS_LINK="$_candidate"
                        break
                    fi
                done
            fi

            if [ -n "$BUSYBOX_RCS_LINK" ]; then
                # 创建 S99 软链接指向 init.d 脚本
                ln -sf "$INIT_SCRIPT" "$BUSYBOX_RCS_LINK"
                ok "BusyBox init 已启用开机自启: $(basename "$BUSYBOX_RCS_LINK") -> $SERVICE_NAME"
            else
                # 最后回退：rc.local（仅当系统确实会调用它时才有用）
                RC_LOCAL="/etc/rc.local"
                if [ -f "$RC_LOCAL" ]; then
                    if ! grep -q "$SERVICE_NAME" "$RC_LOCAL" 2>/dev/null; then
                        sed -i "/^exit 0/i $INIT_SCRIPT start" "$RC_LOCAL" 2>/dev/null || \
                            echo "$INIT_SCRIPT start" >> "$RC_LOCAL"
                    fi
                else
                    echo "#!/bin/sh" > "$RC_LOCAL"
                    echo "$INIT_SCRIPT start" >> "$RC_LOCAL"
                    echo "exit 0" >> "$RC_LOCAL"
                    chmod 755 "$RC_LOCAL"
                fi
                warn "已写入 rc.local，但请确认系统启动时是否调用 rc.local"
                warn "BusyBox init 系统通常需要 SNN 前缀的 init.d 脚本才会自动启动"
            fi
        fi
    else
        # 更新模式：确保软链接存在（之前版本可能漏创建）
        if [ ! -e "/etc/init.d/S99${SERVICE_NAME}" ] && [ -f /etc/init.d/rcS ] && grep -q "S??\*" /etc/init.d/rcS 2>/dev/null; then
            ln -sf "$INIT_SCRIPT" "/etc/init.d/S99${SERVICE_NAME}"
            ok "补建 BusyBox init 开机自启软链接: S99${SERVICE_NAME}"
        else
            ok "开机自启已配置（跳过）"
        fi
    fi

    if [ "$IS_UPDATE" -eq 1 ]; then
        "$INIT_SCRIPT" restart 2>/dev/null || "$INIT_SCRIPT" start
        ok "init.d 服务已重启: $SERVICE_NAME"
    else
        "$INIT_SCRIPT" start
        ok "init.d 服务已启动: $SERVICE_NAME"
    fi
fi

# ============================================================================
# 5. 验证 & 输出结果
# ============================================================================
echo ""
info "步骤 5/5: 验证服务"

sleep 2

# 获取 IP 地址（兼容 BusyBox，不使用 grep -P）
IP=""
if command -v ip >/dev/null 2>&1; then
    IP=$(ip -4 addr show 2>/dev/null | awk '/inet /{print $2}' | awk -F/ '{print $1}' | grep -v '127.0.0.1' | head -1)
fi
if [ -z "$IP" ] && command -v ifconfig >/dev/null 2>&1; then
    # 兼容两种 ifconfig 输出: "inet addr:1.2.3.4" 和 "inet 1.2.3.4"
    IP=$(ifconfig 2>/dev/null | awk '/inet /{print $0}' | sed -nE 's/.*inet (addr:)?([0-9.]+).*/\2/p' | grep -v '127.0.0.1' | head -1)
fi
[ -z "$IP" ] && IP="<设备IP>"

# 检查端口是否在监听（兼容 BusyBox netstat 输出格式）
_LISTENING=0
if command -v ss >/dev/null 2>&1; then
    ss -tlnp 2>/dev/null | grep -E ":$APP_PORT[^0-9]|:$APP_PORT$" >/dev/null 2>&1 && _LISTENING=1
elif command -v netstat >/dev/null 2>&1; then
    netstat -tln 2>/dev/null | grep -E ":$APP_PORT[^0-9]|:$APP_PORT$" >/dev/null 2>&1 && _LISTENING=1
fi
if [ "$_LISTENING" -eq 1 ]; then
    ok "端口 $APP_PORT 正在监听"
else
    warn "端口 $APP_PORT 尚未监听（可能正在启动中）"
fi

# 实际验证服务响应（比端口监听更可靠）
if command -v curl >/dev/null 2>&1; then
    _health=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$APP_PORT/api/health" 2>/dev/null)
    if [ "$_health" = "200" ]; then
        ok "服务响应正常 (/api/health → 200)"
    else
        warn "服务尚未响应 (HTTP $_health)，如持续异常请检查日志: tail -f /tmp/chinese-printer.log"
    fi
fi

echo ""
line
if [ "$IS_UPDATE" -eq 1 ]; then
    printf "${GREEN}  更新完成！${NC} (Shell Edition)\n"
    [ -n "$BACKUP_DIR" ] && printf "  旧版本备份: ${YELLOW}%s${NC}\n" "$BACKUP_DIR"
else
    printf "${GREEN}  安装完成！${NC} (Shell Edition)\n"
fi
line
echo ""
printf "  访问地址:  ${CYAN}http://%s:%s${NC}\n" "$IP" "$APP_PORT"
printf "  HID 设备:  %s\n" "$HID_DEVICE"
printf "  依赖:      socat + awk（系统自带，无 Python）\n"
printf "  安装目录:  %s\n" "$INSTALL_DIR"
echo ""
echo "  服务管理:"
if [ "$HAS_SYSTEMD" -eq 1 ]; then
    echo "    systemctl status  $SERVICE_NAME    # 查看状态"
    echo "    systemctl restart $SERVICE_NAME    # 重启服务"
    echo "    systemctl stop    $SERVICE_NAME    # 停止服务"
    echo "    journalctl -u $SERVICE_NAME -f     # 查看日志"
else
    echo "    $INIT_SCRIPT status               # 查看状态"
    echo "    $INIT_SCRIPT restart              # 重启服务"
    echo "    $INIT_SCRIPT stop                 # 停止服务"
    echo "    tail -f /tmp/chinese-printer.log  # 查看日志"
fi
echo ""
echo "  修改配置:  编辑 $ENV_FILE 后重启服务"
echo ""
line
printf "${YELLOW}  提示:${NC}\n"
echo "  1. 确保目标电脑 NumLock 已开启（Alt 码需用小键盘）"
echo "  2. GBK 模式要求目标电脑使用中文 Windows（GBK 代码页）"
echo "  3. Unicode 模式在大多数现代 Windows 上可用"
if [ "$IS_UPDATE" -eq 1 ]; then
    echo "  4. 如需回滚: 从 $INSTALL_DIR/.backup-* 恢复旧文件"
    echo "  5. 再次运行此脚本即可更新到最新版"
else
    echo "  4. 如果 HID 设备路径不是 $HID_DEVICE，重新运行:"
    echo "     sudo sh $0 $APP_PORT /dev/hidgN"
    echo "  5. 再次运行此脚本即可更新到最新版"
fi
line

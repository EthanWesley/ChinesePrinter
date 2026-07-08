#!/bin/sh
# ============================================================================
# ChinesePrinter 一键安装脚本
# 目标设备: Luckfox Pico KVM (RV1106G3, 单核 Cortex-A7)
# 功能: 部署中文 Alt 码自动打字网页服务 + 开机自启
# 用法: sudo sh install.sh [端口号] [HID设备路径]
#   sudo sh install.sh              # 默认端口 8848, HID /dev/hidg0
#   sudo sh install.sh 9000         # 端口 9000
#   sudo sh install.sh 9000 /dev/hidg1
# ============================================================================

set -e

# ---- 参数 ----
APP_PORT="${1:-${APP_PORT:-8848}}"
HID_DEVICE="${2:-${HID_DEVICE:-/dev/hidg0}}"
INSTALL_DIR="/opt/chinese-printer"
SERVICE_NAME="chinese-printer"
PYTHON_BIN="${PYTHON_BIN:-python3}"

# ---- 脚本所在目录（源文件目录）----
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

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
printf "${CYAN}  ChinesePrinter 一键安装${NC}\n"
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

# 检查 Python3
if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    # 尝试 python
    if command -v python >/dev/null 2>&1; then
        PYTHON_BIN="python"
    else
        err "未找到 python3 或 python，请先安装 Python 3"
        err "Luckfox Pico 上可通过: apt-get install python3  或  opkg install python3"
        exit 1
    fi
fi
PY_VER="$("$PYTHON_BIN" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo '?')"
ok "Python: $PY_VER ($PYTHON_BIN)"

# 检查 Python 标准库模块
for mod in http.server json os threading; do
    if ! "$PYTHON_BIN" -c "import $mod" 2>/dev/null; then
        err "Python 缺少标准库模块: $mod"
        exit 1
    fi
done
ok "Python 标准库完整"

# 检查 GBK 编码支持（优先系统 GBK，回退到内置表）
SYSTEM_GBK=0
if "$PYTHON_BIN" -c "'中'.encode('gbk')" 2>/dev/null; then
    SYSTEM_GBK=1
    ok "GBK 编码支持: 可用 (来源: Python 内置 gbk)"
else
    warn "Python 内置 GBK 不可用（精简版 Python 缺少 _codecs_cn 模块）"
    # 检查内置回退表
    if "$PYTHON_BIN" -c "import sys; sys.path.insert(0, '$SCRIPT_DIR'); import gbk_table; print(gbk_table.char_to_gbk_decimal('中'))" 2>/dev/null | grep -q 54992; then
        ok "GBK 编码支持: 可用 (来源: 内置 GBK 回退编码表)"
    else
        warn "GBK 编码支持: 不可用（系统 GBK 和内置回退表均缺失）"
        warn "GBK 模式将被禁用，仅可用 Unicode 模式"
    fi
fi

# 检查 HID 设备
if [ -e "$HID_DEVICE" ]; then
    ok "HID 设备: $HID_DEVICE (存在)"
else
    warn "HID 设备 $HID_DEVICE 不存在"
    warn "可能原因:"
    warn "  1. USB HID gadget 尚未配置（KVM 固件可能需要先启用 HID 模式）"
    warn "  2. 设备路径不同，可通过参数指定: sudo sh $0 $APP_PORT /dev/hidg1"
    warn "  3. USB 线未连接到目标电脑"
    echo ""
    info "搜索可能的 HID 设备..."
    for dev in /dev/hidg*; do
        if [ -e "$dev" ]; then
            echo "    发现: $dev"
        fi
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
# 2. 安装文件
# ============================================================================
echo ""
info "步骤 2/5: 安装文件到 $INSTALL_DIR"

mkdir -p "$INSTALL_DIR/templates"

# 复制 Python 文件
for f in app.py encoding.py hid_keyboard.py gbk_table.py; do
    src="$SCRIPT_DIR/$f"
    if [ ! -f "$src" ]; then
        err "源文件不存在: $src"
        exit 1
    fi
    cp "$src" "$INSTALL_DIR/$f"
    ok "已安装: $f"
done

# 复制 HTML
if [ -f "$SCRIPT_DIR/templates/index.html" ]; then
    cp "$SCRIPT_DIR/templates/index.html" "$INSTALL_DIR/templates/index.html"
    ok "已安装: templates/index.html"
else
    err "源文件不存在: $SCRIPT_DIR/templates/index.html"
    exit 1
fi

chmod 755 "$INSTALL_DIR/app.py"

# ============================================================================
# 3. 配置环境变量
# ============================================================================
echo ""
info "步骤 3/5: 生成配置文件"

ENV_FILE="$INSTALL_DIR/chinese-printer.env"
cat > "$ENV_FILE" <<EOF
# ChinesePrinter 环境变量配置
# 修改后重启服务生效: systemctl restart $SERVICE_NAME
APP_HOST=0.0.0.0
APP_PORT=$APP_PORT
HID_DEVICE=$HID_DEVICE
KEY_DELAY=0.05
ALT_RELEASE_DELAY=0.08
EOF
ok "配置文件: $ENV_FILE"

# ============================================================================
# 4. 配置开机自启
# ============================================================================
echo ""
info "步骤 4/5: 配置开机自启"

PYTHON_PATH="$(command -v "$PYTHON_BIN")"

if [ "$HAS_SYSTEMD" -eq 1 ]; then
    # ---- systemd 模式 ----
    SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=ChinesePrinter - 中文 Alt 码自动打字服务
After=network.target
Wants=network.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$PYTHON_PATH $INSTALL_DIR/app.py
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

# 安全限制（如设备支持）
NoNewPrivileges=false

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" 2>/dev/null
    systemctl restart "$SERVICE_NAME"
    ok "systemd 服务已创建并启用: $SERVICE_NAME"

else
    # ---- SysVinit / BusyBox 模式 ----
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

DAEMON="$PYTHON_PATH"
DAEMON_DIR="$INSTALL_DIR"
DAEMON_ARGS="$INSTALL_DIR/app.py"
ENV_FILE="$ENV_FILE"
PIDFILE="/var/run/$SERVICE_NAME.pid"

# 加载环境变量
if [ -f "\$ENV_FILE" ]; then
    export \$(grep -v '^#' "\$ENV_FILE" | xargs)
fi

case "\$1" in
    start)
        echo -n "Starting $SERVICE_NAME..."
        cd "\$DAEMON_DIR"
        start-stop-daemon -S -m -p "\$PIDFILE" -b \\
            -x "\$DAEMON" -- \$DAEMON_ARGS
        echo " done"
        ;;
    stop)
        echo -n "Stopping $SERVICE_NAME..."
        if [ -f "\$PIDFILE" ]; then
            kill \$(cat "\$PIDFILE") 2>/dev/null || true
            rm -f "\$PIDFILE"
        fi
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

    # 尝试不同方式启用开机自启
    if command -v update-rc.d >/dev/null 2>&1; then
        update-rc.d "$SERVICE_NAME" defaults 2>/dev/null
        ok "update-rc.d 已启用开机自启"
    elif command -v chkconfig >/dev/null 2>&1; then
        chkconfig --add "$SERVICE_NAME" 2>/dev/null
        ok "chkconfig 已启用开机自启"
    else
        # 回退到 rc.local
        RC_LOCAL="/etc/rc.local"
        if [ -f "$RC_LOCAL" ]; then
            # 检查是否已存在
            if ! grep -q "$SERVICE_NAME" "$RC_LOCAL" 2>/dev/null; then
                # 在 exit 0 之前插入
                sed -i "/^exit 0/i $INIT_SCRIPT start" "$RC_LOCAL" 2>/dev/null || \
                    echo "$INIT_SCRIPT start" >> "$RC_LOCAL"
            fi
        else
            echo "#!/bin/sh" > "$RC_LOCAL"
            echo "$INIT_SCRIPT start" >> "$RC_LOCAL"
            echo "exit 0" >> "$RC_LOCAL"
            chmod 755 "$RC_LOCAL"
        fi
        ok "rc.local 已启用开机自启"
    fi

    # 启动服务
    "$INIT_SCRIPT" start
    ok "init.d 服务已启动: $SERVICE_NAME"
fi

# ============================================================================
# 5. 验证 & 输出结果
# ============================================================================
echo ""
info "步骤 5/5: 验证服务"

sleep 2

# 获取 IP 地址
IP=""
for cmd in "ip -4 addr" "ifconfig"; do
    if command -v ip >/dev/null 2>&1; then
        IP=$(ip -4 addr show 2>/dev/null | grep -oP 'inet \K[\d.]+' | grep -v '127.0.0.1' | head -1)
        break
    elif command -v ifconfig >/dev/null 2>&1; then
        IP=$(ifconfig 2>/dev/null | grep -oP 'inet addr:\K[\d.]+' | grep -v '127.0.0.1' | head -1)
        [ -z "$IP" ] && IP=$(ifconfig 2>/dev/null | grep -oP 'inet \K[\d.]+' | grep -v '127.0.0.1' | head -1)
        break
    fi
done

[ -z "$IP" ] && IP="<设备IP>"

# 检查端口是否在监听
if command -v ss >/dev/null 2>&1; then
    ss -tlnp | grep ":$APP_PORT " >/dev/null 2>&1 && ok "端口 $APP_PORT 正在监听" || warn "端口 $APP_PORT 尚未监听（可能正在启动中）"
elif command -v netstat >/dev/null 2>&1; then
    netstat -tlnp 2>/dev/null | grep ":$APP_PORT " >/dev/null 2>&1 && ok "端口 $APP_PORT 正在监听" || warn "端口 $APP_PORT 尚未监听（可能正在启动中）"
fi

echo ""
line
printf "${GREEN}  安装完成！${NC}\n"
line
echo ""
printf "  访问地址:  ${CYAN}http://%s:%s${NC}\n" "$IP" "$APP_PORT"
printf "  HID 设备:  %s\n" "$HID_DEVICE"
printf "  GBK 支持:  %s\n" "$([ $SYSTEM_GBK -eq 1 ] && echo '可用 (系统内置)' || echo '可用 (内置回退表)')"
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
    echo "    tail -f /var/log/messages         # 查看日志"
fi
echo ""
echo "  修改配置:  编辑 $ENV_FILE 后重启服务"
echo ""
line
printf "${YELLOW}  提示:${NC}\n"
echo "  1. 确保目标电脑 NumLock 已开启（Alt 码需用小键盘）"
echo "  2. GBK 模式要求目标电脑使用中文 Windows（GBK 代码页）"
echo "  3. Unicode 模式在大多数现代 Windows 上可用"
echo "  4. 如果 HID 设备路径不是 /dev/hidg0，重新运行:"
echo "     sudo sh $0 $APP_PORT /dev/hidg1"
line

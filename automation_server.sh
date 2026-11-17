#!/bin/sh
# ============================================================================
# automation_server.sh - AI 自动化通道（:8849，纯 shell + socat）
#
# 与 :8848 打字机服务并行存在、互不干扰：
#   :8848  网页打字机（templates/index.html + /api/type）
#   :8849  本服务：截图 + 键鼠序列执行，供 PC 端 MCP 服务器调用
#
# 端点：
#   GET  /health            状态（busy/progress/step/error、设备可用性、对端忙状态）
#   GET  /capture?warmup=N  抓取一帧 JPEG（二进制响应 + X-Frame-* 头）
#   POST /seq               执行行协议序列（请求体为纯文本，见 native/seq_writer.c）
#   POST /stop              行边界优雅停止
#   POST /abort             强制中止并释放全部按键
#   GET  /probe             硬件能力探测（probe_device.sh 的 JSON）
#
# 设备端不做业务翻译：文本→Alt 码、绝对坐标→相对位移都在 PC 端完成。
# ============================================================================

# 注意：不使用 set -e（与 server.sh 一致，避免子进程 read 失败直接退出）

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="${INSTALL_DIR:-$SCRIPT_DIR}"
PORT="${AUTOMATION_PORT:-8849}"
STATE_DIR="${STATE_DIR:-/tmp/chinese-printer}"
LOG_FILE="${LOG_FILE_AUTO:-/tmp/chinese-printer-auto.log}"

# 状态文件（auto_ 前缀，避免与 :8848 冲突）
TW_STATUS_FILE="$STATE_DIR/status.json"
AUTO_STATUS="$STATE_DIR/auto_status.json"
AUTO_STOP="$STATE_DIR/auto_stop"
AUTO_PAUSE="$STATE_DIR/auto_pause"
AUTO_PROGRESS="$STATE_DIR/auto_progress"
AUTO_STEP="$STATE_DIR/auto_step"
AUTO_ERROR="$STATE_DIR/auto_error"
AUTO_SEQ="$STATE_DIR/auto_seq"
AUTO_PID="$STATE_DIR/auto_seq.pid"
AUTO_FRAME="$STATE_DIR/auto_frame.jpg"
AUTO_META="$STATE_DIR/auto_frame.json"

CAPTURE_BIN="${CAPTURE_BIN:-$INSTALL_DIR/capture}"
SEQ_BIN="${SEQ_BIN:-$INSTALL_DIR/seq_writer}"
PROBE_BIN="${PROBE_BIN:-$INSTALL_DIR/probe_device.sh}"
REPORT_DELAY="${REPORT_DELAY:-8}"
MOUSE_REPORT_SIZE="${MOUSE_REPORT_SIZE:-4}"
MOUSE_ABSOLUTE="${MOUSE_ABSOLUTE:-0}"
MAX_SEQ_BYTES=1048576

mkdir -p "$STATE_DIR"

# ---- 日志 ----
_log() {
    _level="$1"
    _msg="$2"
    _ts=$(date '+%Y-%m-%d %H:%M:%S')
    printf "[%s] [%s] %s\n" "$_ts" "$_level" "$_msg" >> "$LOG_FILE" 2>/dev/null || \
        printf "[%s] [%s] %s\n" "$_ts" "$_level" "$_msg"
}
log()  { _log "INFO" "$1"; }
warn() { _log "WARN" "$1"; }
err()  { _log "ERROR" "$1"; }

# ---- 通用：JSON 字段读取（与 server.sh 同款 awk 实现）----
json_get() {
    _json="$1"
    _field="$2"
    printf '%s' "$_json" | awk -v field="\"$_field\"" '
    {
        idx = index($0, field)
        if (idx > 0) {
            rest = substr($0, idx + length(field))
            sub(/^:[ \t]*/, "", rest)
            if (substr(rest, 1, 1) == "\"") {
                rest = substr(rest, 2)
                end = index(rest, "\"")
                if (end > 0) printf "%s", substr(rest, 1, end - 1)
            } else {
                match(rest, /[,}]/)
                if (RSTART > 0) printf "%s", substr(rest, 1, RSTART - 1)
                else printf "%s", rest
            }
        }
    }
    '
}

# 读取状态文件中的 busy 字段（文件不存在视为 false）
status_busy() {
    [ -f "$1" ] || { printf 'false'; return; }
    _v=$(json_get "$(cat "$1" 2>/dev/null)" busy)
    printf '%s' "${_v:-false}"
}

# ---- HID 设备探测 ----
# protocol: 1=键盘 2=鼠标（与 server.sh 相同的两级查找）
hid_protocol() {
    _dev_name="${1#/dev/}"
    _dev_idx="${_dev_name#hidg}"
    if [ -r "/sys/class/hidg/${_dev_name}/protocol" ]; then
        cat "/sys/class/hidg/${_dev_name}/protocol" 2>/dev/null
        return
    fi
    for _cfg in /sys/kernel/config/usb_gadget/*/functions/hid.usb"${_dev_idx}"; do
        [ -r "$_cfg/protocol" ] || continue
        cat "$_cfg/protocol" 2>/dev/null
        return
    done
    printf ''
}

# 键盘设备：显式配置 > 打字机当前设备 > 第一个 protocol=1 > /dev/hidg0
find_kbd() {
    if [ -n "$KBD_DEVICE" ]; then printf '%s' "$KBD_DEVICE"; return; fi
    if [ -f "$STATE_DIR/current_device" ]; then
        _d=$(cat "$STATE_DIR/current_device" 2>/dev/null)
        [ -n "$_d" ] && { printf '%s' "$_d"; return; }
    fi
    for _d in /dev/hidg*; do
        [ -e "$_d" ] || continue
        [ "$(hid_protocol "$_d")" = "1" ] && { printf '%s' "$_d"; return; }
    done
    printf '/dev/hidg0'
}

# 鼠标设备：显式配置 > 第一个 protocol=2 > 空（不可用）
find_mouse() {
    if [ -n "$MOUSE_DEVICE" ]; then printf '%s' "$MOUSE_DEVICE"; return; fi
    for _d in /dev/hidg*; do
        [ -e "$_d" ] || continue
        [ "$(hid_protocol "$_d")" = "2" ] && { printf '%s' "$_d"; return; }
    done
    printf ''
}

# ---- 状态写入（原子 mv）----
update_status() {
    _busy="${1:-false}"
    _progress="${2:-0}"
    _total="${3:-0}"
    _step="${4:--1}"
    _error="$5"
    _err_esc=$(printf '%s' "$_error" | tr -d '\r\n' | sed 's/\\/\\\\/g; s/"/\\"/g')
    _tmp="$AUTO_STATUS.tmp.$$"
    cat > "$_tmp" <<EOF
{"busy":$_busy,"progress":$_progress,"total":$_total,"step":$_step,"last_error":"$_err_esc","timestamp":"$(date '+%Y-%m-%dT%H:%M:%S')"}
EOF
    mv -f "$_tmp" "$AUTO_STATUS"
}

# ---- HTTP 响应 ----
http_response() {
    _status="$1"
    _content_type="$2"
    _body="$3"
    case "$_status" in
        200) _status_text="OK" ;;
        400) _status_text="Bad Request" ;;
        404) _status_text="Not Found" ;;
        405) _status_text="Method Not Allowed" ;;
        409) _status_text="Conflict" ;;
        413) _status_text="Payload Too Large" ;;
        503) _status_text="Service Unavailable" ;;
        *)   _status_text="OK" ;;
    esac
    _body_len=$(printf '%s' "$_body" | wc -c | tr -d ' ')
    printf 'HTTP/1.1 %s %s\r\n' "$_status" "$_status_text"
    printf 'Content-Type: %s\r\n' "$_content_type"
    printf 'Content-Length: %s\r\n' "$_body_len"
    printf 'Access-Control-Allow-Origin: *\r\n'
    printf 'Connection: close\r\n'
    printf '\r\n'
    printf '%s' "$_body"
}

http_json() {
    http_response "$1" "application/json; charset=utf-8" "$2"
}

# ---- API: /health ----
api_health() {
    _busy=$(status_busy "$AUTO_STATUS")
    _tw_busy=$(status_busy "$TW_STATUS_FILE")
    _progress=$(cat "$AUTO_PROGRESS" 2>/dev/null | tr -d '\r\n')
    case "$_progress" in ''|*[!0-9]*) _progress=0 ;; esac
    _step=$(cat "$AUTO_STEP" 2>/dev/null | tr -d '\r\n')
    case "$_step" in ''|*[!0-9-]*) _step=-1 ;; esac
    _total=$(json_get "$(cat "$AUTO_STATUS" 2>/dev/null)" total)
    case "$_total" in ''|*[!0-9]*) _total=0 ;; esac
    _last_err=$(cat "$AUTO_ERROR" 2>/dev/null | tr -d '\r\n' | sed 's/\\/\\\\/g; s/"/\\"/g')

    _kbd=$(find_kbd)
    _mouse=$(find_mouse)

    _kbd_ok=false; [ -e "$_kbd" ] && _kbd_ok=true
    _mouse_ok=false; [ -n "$_mouse" ] && [ -e "$_mouse" ] && _mouse_ok=true

    _cap_ok=false
    if [ -x "$CAPTURE_BIN" ]; then
        for _v in /dev/video*; do
            [ -e "$_v" ] && { _cap_ok=true; break; }
        done
    fi

    if [ -f "$AUTO_META" ]; then
        _frame=$(cat "$AUTO_META" 2>/dev/null | tr -d '\r\n')
        [ -n "$_frame" ] || _frame=null
    else
        _frame=null
    fi

    printf '{"ok":true,"busy":%s,"progress":%s,"total":%s,"step":%s,"last_error":"%s",' \
        "$_busy" "$_progress" "$_total" "$_step" "$_last_err"
    printf '"capture":{"available":%s,"binary":"%s","last_frame":%s},' \
        "$_cap_ok" "$CAPTURE_BIN" "$_frame"
    printf '"keyboard":{"available":%s,"device":"%s"},' "$_kbd_ok" "$_kbd"
    printf '"mouse":{"available":%s,"device":"%s","report_size":%s,"absolute":%s},' \
        "$_mouse_ok" "$_mouse" "$MOUSE_REPORT_SIZE" "$([ "$MOUSE_ABSOLUTE" = "1" ] && echo true || echo false)"
    printf '"typewriter_busy":%s,"port":%s}' "$_tw_busy" "$PORT"
}

# ---- API: /capture ----
# 响应为二进制 JPEG：Content-Length 由文件字节数给出，正文用 cat 直写 socket。
api_capture() {
    _warmup="${1:-3}"
    case "$_warmup" in ''|*[!0-9]*) _warmup=3 ;; esac

    if [ ! -x "$CAPTURE_BIN" ]; then
        http_json 503 '{"ok":false,"msg":"capture 二进制未安装"}'
        return
    fi

    _tmp_frame="$AUTO_FRAME.tmp.$$"
    _tmp_meta="$AUTO_META.tmp.$$"
    _err_file="$STATE_DIR/auto_capture.err.$$"
    rm -f "$_tmp_frame" "$_tmp_meta"

    "$CAPTURE_BIN" --output "$_tmp_frame" --meta "$_tmp_meta" --warmup "$_warmup" \
        >/dev/null 2>"$_err_file"
    _rc=$?

    if [ "$_rc" != "0" ] || [ ! -s "$_tmp_frame" ]; then
        _detail=$(tail -n 2 "$_err_file" 2>/dev/null | tr '\r\n' '  ' | sed 's/\\/\\\\/g; s/"/\\"/g')
        rm -f "$_tmp_frame" "$_tmp_meta" "$_err_file"
        warn "抓取失败 rc=$_rc: $_detail"
        http_json 503 "{\"ok\":false,\"msg\":\"抓取失败\",\"rc\":$_rc,\"detail\":\"$_detail\"}"
        return
    fi
    rm -f "$_err_file"
    mv -f "$_tmp_frame" "$AUTO_FRAME"
    mv -f "$_tmp_meta" "$AUTO_META"

    _len=$(wc -c < "$AUTO_FRAME" | tr -d ' ')
    _meta=$(cat "$AUTO_META" 2>/dev/null)
    _w=$(json_get "$_meta" width)
    _h=$(json_get "$_meta" height)
    _fmt=$(json_get "$_meta" format)

    printf 'HTTP/1.1 200 OK\r\n'
    printf 'Content-Type: image/jpeg\r\n'
    printf 'Content-Length: %s\r\n' "$_len"
    printf 'X-Frame-Width: %s\r\n' "$_w"
    printf 'X-Frame-Height: %s\r\n' "$_h"
    printf 'X-Frame-Format: %s\r\n' "$_fmt"
    printf 'X-Frame-Bytes: %s\r\n' "$_len"
    printf 'Access-Control-Allow-Origin: *\r\n'
    printf 'Access-Control-Expose-Headers: X-Frame-Width, X-Frame-Height, X-Frame-Format, X-Frame-Bytes\r\n'
    printf 'Cache-Control: no-store\r\n'
    printf 'Connection: close\r\n'
    printf '\r\n'
    cat "$AUTO_FRAME"
}

# ---- API: /seq ----
# 参数：$1 = 请求体字节数（正文仍在 stdin 上，直接落盘）
api_seq() {
    _len="$1"
    case "$_len" in ''|*[!0-9]*) _len=0 ;; esac

    if [ "$_len" -le 0 ]; then
        http_json 400 '{"ok":false,"msg":"空请求体"}'
        return
    fi
    if [ "$_len" -gt "$MAX_SEQ_BYTES" ]; then
        http_json 413 "{\"ok\":false,\"msg\":\"序列过大\",\"limit\":$MAX_SEQ_BYTES}"
        return
    fi

    # 跨通道互斥：打字机正在工作时不接受序列
    if [ "$(status_busy "$TW_STATUS_FILE")" = "true" ]; then
        http_json 409 '{"ok":false,"msg":"打字机通道忙，请先停止"}'
        return
    fi
    if [ "$(status_busy "$AUTO_STATUS")" = "true" ]; then
        http_json 409 '{"ok":false,"msg":"自动化通道忙"}'
        return
    fi

    _kbd=$(find_kbd)
    if [ ! -e "$_kbd" ]; then
        http_json 503 "{\"ok\":false,\"msg\":\"键盘设备不存在: $_kbd\"}"
        return
    fi
    if [ ! -x "$SEQ_BIN" ]; then
        http_json 503 '{"ok":false,"msg":"seq_writer 二进制未安装"}'
        return
    fi

    _seq_file="$AUTO_SEQ.$$"
    head -c "$_len" > "$_seq_file"
    # 补齐末尾换行，保证最后一条指令被计数
    [ -s "$_seq_file" ] && printf '\n' >> "$_seq_file"
    _total=$(wc -l < "$_seq_file" | tr -d ' ')
    if [ "$_total" -le 0 ]; then
        rm -f "$_seq_file"
        http_json 400 '{"ok":false,"msg":"序列为空"}'
        return
    fi

    _mouse=$(find_mouse)
    rm -f "$AUTO_STOP" "$AUTO_PAUSE" "$AUTO_ERROR"
    : > "$AUTO_PROGRESS"
    printf '%s\n' "-1" > "$AUTO_STEP"
    update_status true 0 "$_total" -1 ""

    _seq_args="--kbd $_kbd --report-delay $REPORT_DELAY --stop-file $AUTO_STOP --pause-file $AUTO_PAUSE --progress-file $AUTO_PROGRESS --step-file $AUTO_STEP --error-file $AUTO_ERROR --verbose"
    if [ -n "$_mouse" ]; then
        _seq_args="$_seq_args --mouse $_mouse --mouse-report-size $MOUSE_REPORT_SIZE"
        [ "$MOUSE_ABSOLUTE" = "1" ] && _seq_args="$_seq_args --mouse-absolute"
    fi

    log "开始执行序列: $_total 行, 键盘=$_kbd, 鼠标=${_mouse:-无}"

    (
        # shellcheck disable=SC2086
        "$SEQ_BIN" $_seq_args < "$_seq_file" >> "$LOG_FILE" 2>&1 &
        _pid=$!
        printf '%s\n' "$_pid" > "$AUTO_PID"

        while kill -0 "$_pid" 2>/dev/null; do
            sleep 0.05 2>/dev/null || sleep 1
        done
        wait "$_pid" 2>/dev/null
        _rc=$?

        _progress=$(cat "$AUTO_PROGRESS" 2>/dev/null | tr -d '\r\n')
        case "$_progress" in ''|*[!0-9]*) _progress=0 ;; esac
        _step=$(cat "$AUTO_STEP" 2>/dev/null | tr -d '\r\n')
        case "$_step" in ''|*[!0-9-]*) _step=-1 ;; esac
        _err=$(cat "$AUTO_ERROR" 2>/dev/null)
        if [ -z "$_err" ] && [ "$_rc" != "0" ]; then
            _err="seq_writer exit $_rc"
        fi

        update_status false "$_progress" "$_total" "$_step" "$_err"
        rm -f "$AUTO_PID" "$AUTO_STOP" "$AUTO_PAUSE" "$_seq_file"
        log "序列结束: rc=$_rc, progress=$_progress/$_total, step=$_step, err=${_err:-无}"
    ) </dev/null >> "$LOG_FILE" 2>&1 &

    http_json 200 "{\"ok\":true,\"total\":$_total,\"keyboard\":\"$_kbd\",\"mouse\":\"$_mouse\"}"
}

# ---- API: /stop ----
api_stop() {
    touch "$AUTO_STOP"
    log "收到停止请求"
    http_json 200 '{"ok":true,"msg":"已请求停止（行边界生效）"}'
}

# ---- API: /abort ----
api_abort() {
    touch "$AUTO_STOP"
    if [ -f "$AUTO_PID" ]; then
        _pid=$(cat "$AUTO_PID" 2>/dev/null)
        if [ -n "$_pid" ]; then
            kill "$_pid" 2>/dev/null
            log "强制终止 seq_writer pid=$_pid"
        fi
    fi

    # 强制释放键鼠状态（seq_writer 异常退出时兜底）
    _kbd=$(find_kbd)
    if [ -e "$_kbd" ]; then
        printf '\000\000\000\000\000\000\000\000' > "$_kbd" 2>/dev/null
    fi
    _mouse=$(find_mouse)
    if [ -n "$_mouse" ] && [ -e "$_mouse" ]; then
        printf '\000\000\000\000' > "$_mouse" 2>/dev/null
    fi

    _progress=$(cat "$AUTO_PROGRESS" 2>/dev/null | tr -d '\r\n')
    case "$_progress" in ''|*[!0-9]*) _progress=0 ;; esac
    _total=$(json_get "$(cat "$AUTO_STATUS" 2>/dev/null)" total)
    case "$_total" in ''|*[!0-9]*) _total=0 ;; esac
    update_status false "$_progress" "$_total" -1 "aborted"
    rm -f "$AUTO_STOP" "$AUTO_PID"

    http_json 200 '{"ok":true,"msg":"已强制中止并释放按键"}'
}

# ---- API: /probe ----
api_probe() {
    if [ ! -f "$PROBE_BIN" ]; then
        http_json 503 '{"ok":false,"msg":"probe_device.sh 未安装"}'
        return
    fi
    _json=$(sh "$PROBE_BIN" --capture-bin "$CAPTURE_BIN" 2>/dev/null)
    if [ -z "$_json" ]; then
        http_json 500 '{"ok":false,"msg":"探测失败"}'
        return
    fi
    http_response 200 "application/json; charset=utf-8" "$_json"
}

# ---- 请求分发 ----
handle_request() {
    _request_line=""
    read -r _request_line 2>/dev/null || true
    if [ -z "$_request_line" ]; then
        http_json 400 '{"ok":false,"msg":"空请求"}'
        return
    fi

    _method=$(printf '%s' "$_request_line" | awk '{print $1}')
    _path=$(printf '%s' "$_request_line" | awk '{print $2}')

    # 拆分查询串
    _query=""
    case "$_path" in
        *\?*) _query="${_path#*\?}"; _path="${_path%%\?*}" ;;
    esac

    # 读 headers，记录 Content-Length
    _content_length=0
    while IFS= read -r _header 2>/dev/null; do
        _header=$(printf '%s' "$_header" | tr -d '\r')
        [ -z "$_header" ] && break
        case "$_header" in
            [Cc]ontent-[Ll]ength:*)
                _content_length=$(printf '%s' "$_header" | awk '{print $2}')
                ;;
        esac
    done
    case "$_content_length" in ''|*[!0-9]*) _content_length=0 ;; esac

    case "$_method" in
        GET)
            case "$_path" in
                /health|/)
                    http_json 200 "$(api_health)"
                    ;;
                /capture)
                    _warmup=$(printf '%s' "$_query" | sed -n 's/.*warmup=\([0-9][0-9]*\).*/\1/p')
                    api_capture "$_warmup"
                    ;;
                /probe)
                    api_probe
                    ;;
                *)
                    http_json 404 '{"ok":false,"msg":"路径不存在"}'
                    ;;
            esac
            ;;
        POST)
            case "$_path" in
                /seq)
                    api_seq "$_content_length"
                    ;;
                /stop)
                    api_stop
                    ;;
                /abort)
                    api_abort
                    ;;
                *)
                    http_json 404 '{"ok":false,"msg":"路径不存在"}'
                    ;;
            esac
            ;;
        OPTIONS)
            printf 'HTTP/1.1 204 No Content\r\n'
            printf 'Access-Control-Allow-Origin: *\r\n'
            printf 'Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n'
            printf 'Access-Control-Allow-Headers: Content-Type\r\n'
            printf 'Access-Control-Expose-Headers: X-Frame-Width, X-Frame-Height, X-Frame-Format, X-Frame-Bytes\r\n'
            printf 'Content-Length: 0\r\n'
            printf '\r\n'
            ;;
        *)
            http_json 405 '{"ok":false,"msg":"不支持的请求方法"}'
            ;;
    esac
}

# ---- socat fork 子进程入口 ----
if [ "$1" = "handle" ]; then
    handle_request
    exit 0
fi

# ---- 主进程：初始化并启动 ----
update_status false 0 0 -1 ""

log "========================================="
log "ChinesePrinter 自动化通道启动 (shell + socat)"
log "  监听端口: $PORT"
log "  键盘设备: $(find_kbd)"
log "  鼠标设备: $(find_mouse)"
log "  截图工具: $CAPTURE_BIN"
log "  序列执行: $SEQ_BIN"
log "========================================="

if ! command -v socat >/dev/null 2>&1; then
    err "未找到 socat，请安装: opkg install socat"
    exit 1
fi

[ -x "$CAPTURE_BIN" ] || warn "capture 不可执行，截图端点将返回 503"
[ -x "$SEQ_BIN" ] || warn "seq_writer 不可执行，序列端点将返回 503"

export INSTALL_DIR PORT STATE_DIR LOG_FILE
export CAPTURE_BIN SEQ_BIN PROBE_BIN
export REPORT_DELAY MOUSE_REPORT_SIZE MOUSE_ABSOLUTE
export KBD_DEVICE MOUSE_DEVICE

log "服务已启动，等待连接..."
exec socat TCP-LISTEN:"$PORT",reuseaddr,fork SYSTEM:"sh '$INSTALL_DIR/automation_server.sh' handle"

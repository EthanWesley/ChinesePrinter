#!/bin/sh
# ============================================================================
# server.sh - ChinesePrinter 主服务（纯 shell + socat）
#
# 架构：
#   socat 监听端口 -> 每个连接 fork 一个 shell 处理
#   GET  /              -> 返回 index.html
#   GET  /api/health    -> JSON 状态
#   GET  /api/settings  -> JSON 延时配置
#   POST /api/type      -> 接收数字序列，执行 Alt 码打字
#   POST /api/stop      -> 中止当前打字任务
#   POST /api/settings  -> 更新延时配置
#
# 编码转换在网页前端（JS）完成，后端只接收纯数字序列。
# ============================================================================

# 注意：不使用 set -e，避免子进程中 read 失败时直接退出不返回数据

# ---- 配置 ----
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="${INSTALL_DIR:-$SCRIPT_DIR}"
PORT="${APP_PORT:-8848}"
HID_DEVICE="${HID_DEVICE:-/dev/hidg0}"
KEY_DELAY="${KEY_DELAY:-0}"
ALT_RELEASE_DELAY="${ALT_RELEASE_DELAY:-0}"
CHAR_DELAY="${CHAR_DELAY:-0}"
STATE_DIR="${STATE_DIR:-/tmp/chinese-printer}"
SETTINGS_FILE="$STATE_DIR/settings.env"
DEVICE_FILE="$STATE_DIR/current_device"
STOP_FLAG="$STATE_DIR/stop_flag"
STATUS_FILE="$STATE_DIR/status.json"
LOG_FILE="${LOG_FILE:-/tmp/chinese-printer.log}"

# ---- 状态目录 ----
mkdir -p "$STATE_DIR"

# ---- 获取当前 HID 设备（运行时可切换）----
get_current_device() {
    if [ -f "$DEVICE_FILE" ]; then
        cat "$DEVICE_FILE" 2>/dev/null
    else
        echo "$HID_DEVICE"
    fi
}

# 运行时读取当前设备（覆盖环境变量）
HID_DEVICE=$(get_current_device)

# ---- 日志函数 ----
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

# ---- 初始化配置文件 ----
init_settings() {
    if [ ! -f "$SETTINGS_FILE" ]; then
        cat > "$SETTINGS_FILE" <<EOF
KEY_DELAY=$KEY_DELAY
ALT_RELEASE_DELAY=$ALT_RELEASE_DELAY
EOF
    fi
    # 加载配置
    . "$SETTINGS_FILE"
    KEY_DELAY="${KEY_DELAY:-0.05}"
    ALT_RELEASE_DELAY="${ALT_RELEASE_DELAY:-0.08}"
}

# ---- 更新状态文件 ----
update_status() {
    _busy="${1:-false}"
    _progress="${2:-0}"
    _total="${3:-0}"
    _encoding="${4:-}"
    _error="${5:-}"
    cat > "$STATUS_FILE" <<EOF
{"busy":$_busy,"progress":$_progress,"total":$_total,"encoding":"$_encoding","last_error":"$_error","timestamp":"$(date '+%Y-%m-%dT%H:%M:%S')"}
EOF
}

# ---- 加载 HID 键盘控制 ----
. "$INSTALL_DIR/hid_keyboard.sh"

# ---- HTTP 响应函数 ----

http_response() {
    _status="$1"
    _content_type="$2"
    _body="$3"
    case "$_status" in
        200) _status_text="OK" ;;
        400) _status_text="Bad Request" ;;
        404) _status_text="Not Found" ;;
        500) _status_text="Internal Server Error" ;;
        *)  _status_text="OK" ;;
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

http_html() {
    http_response "$1" "text/html; charset=utf-8" "$2"
}

# ---- URL 解码 ----
url_decode() {
    # 将 + 转为空格，%XX 转为对应字符
    printf '%s' "$1" | sed 's/+/ /g' | awk '
    BEGIN { RS = "%"; ORS = "" }
    NR == 1 { printf "%s", $0 }
    NR > 1 {
        if (length($0) >= 2) {
            hex = substr($0, 1, 2)
            rest = substr($0, 3)
            printf "%c", strtonum("0x" hex)
            printf "%s", rest
        } else {
            printf "%%%s", $0
        }
    }
    '
}

# ---- 解析 JSON 中的字段值 ----
# 参数: $1=JSON 字符串, $2=字段名
# 返回: 字段值（字符串，不含引号）
json_get() {
    _json="$1"
    _field="$2"
    printf '%s' "$_json" | awk -v field="\"$_field\"" '
    {
        # 查找 "field":"value" 或 "field":value
        idx = index($0, field)
        if (idx > 0) {
            rest = substr($0, idx + length(field))
            # 跳过 :和空格
            sub(/^:[ \t]*/, "", rest)
            if (substr(rest, 1, 1) == "\"") {
                # 字符串值
                rest = substr(rest, 2)
                end = index(rest, "\"")
                if (end > 0) {
                    printf "%s", substr(rest, 1, end - 1)
                }
            } else {
                # 数字或布尔值
                # 取到逗号或 } 为止
                match(rest, /[,}]/)
                if (RSTART > 0) {
                    printf "%s", substr(rest, 1, RSTART - 1)
                } else {
                    printf "%s", rest
                }
            }
        }
    }
    '
}

# ---- 获取 HID 设备的 protocol ----
# 参数: $1 = 设备路径 (如 /dev/hidg0)
# 返回: protocol 数字 (1=键盘, 2=鼠标)，空字符串表示未知
# 查找顺序:
#   1. /sys/class/hidg/<name>/protocol (某些内核版本有)
#   2. /sys/kernel/config/usb_gadget/*/functions/hid.usb<N>/protocol (configfs)
get_hid_protocol() {
    _dev_path="$1"
    _dev_name="${_dev_path#/dev/}"
    _dev_idx="${_dev_name#hidg}"

    # 方式1: /sys/class/hidg/<name>/protocol
    _proto_file="/sys/class/hidg/${_dev_name}/protocol"
    if [ -r "$_proto_file" ]; then
        cat "$_proto_file" 2>/dev/null
        return
    fi

    # 方式2: configfs (按 hid.usbN 索引匹配 hidgN)
    for _cfg in /sys/kernel/config/usb_gadget/*/functions/hid.usb"${_dev_idx}"; do
        [ -r "$_cfg/protocol" ] || continue
        cat "$_cfg/protocol" 2>/dev/null
        return
    done

    # 未知
    echo ""
}

# protocol 数字转类型字符串
proto_to_type() {
    case "$1" in
        1) echo "keyboard" ;;
        2) echo "mouse" ;;
        *) echo "unknown" ;;
    esac
}

# ---- 列出所有 HID 设备 ----
list_hid_devices() {
    _first=1
    printf '['
    for dev in /dev/hidg*; do
        [ -e "$dev" ] || continue
        _proto=$(get_hid_protocol "$dev")
        _type=$(proto_to_type "$_proto")
        [ "$_first" = "1" ] || printf ','
        printf '{"path":"%s","protocol":"%s","type":"%s"}' "$dev" "$_proto" "$_type"
        _first=0
    done
    printf ']'
}

# ---- API: /api/health ----
api_health() {
    # 运行时读取当前设备
    _cur_device=$(get_current_device)

    _device_exists="false"
    [ -e "$_cur_device" ] && _device_exists="true"

    # 读取设备类型
    _proto=$(get_hid_protocol "$_cur_device")
    _device_type=$(proto_to_type "$_proto")

    # 读取当前状态
    _busy="false"
    _progress="0"
    _total="0"
    _encoding=""
    _last_error=""
    if [ -f "$STATUS_FILE" ]; then
        _busy=$(json_get "$(cat "$STATUS_FILE")" "busy")
        _progress=$(json_get "$(cat "$STATUS_FILE")" "progress")
        _total=$(json_get "$(cat "$STATUS_FILE")" "total")
        _encoding=$(json_get "$(cat "$STATUS_FILE")" "encoding")
        _last_error=$(json_get "$(cat "$STATUS_FILE")" "last_error")
    fi

    # 读取当前延时设置
    . "$SETTINGS_FILE" 2>/dev/null
    _cur_key_delay="${KEY_DELAY:-0}"
    _cur_alt_delay="${ALT_RELEASE_DELAY:-0}"
    _cur_char_delay="${CHAR_DELAY:-0}"

    # 列出所有设备
    _all_devices=$(list_hid_devices)

    cat <<EOF
{"ok":true,"busy":${_busy:-false},"progress":${_progress:-0},"total":${_total:-0},"encoding":"${_encoding:-}","last_error":"${_last_error:-}","device":"$_cur_device","device_exists":$_device_exists,"device_type":"$_device_type","all_devices":$_all_devices,"key_delay":$_cur_key_delay,"alt_release_delay":$_cur_alt_delay,"char_delay":$_cur_char_delay,"port":$PORT}
EOF
}

# ---- API: /api/device (POST) ----
# 切换当前 HID 设备
api_device_post() {
    _body="$1"
    _new_device=$(json_get "$_body" "device")

    if [ -z "$_new_device" ]; then
        printf '{"ok":false,"msg":"未提供 device 参数"}'
        return
    fi

    # 验证设备路径格式（必须是 /dev/hidgN）
    if ! printf '%s' "$_new_device" | grep -qE '^/dev/hidg[0-9]+$'; then
        printf '{"ok":false,"msg":"设备路径格式错误，必须是 /dev/hidgN"}'
        return
    fi

    # 验证设备存在
    if [ ! -e "$_new_device" ]; then
        printf '{"ok":false,"msg":"设备不存在: %s"}' "$_new_device"
        return
    fi

    # 读取设备类型
    _proto=$(get_hid_protocol "$_new_device")
    _dev_type=$(proto_to_type "$_proto")

    # 保存到文件
    printf '%s' "$_new_device" > "$DEVICE_FILE"
    log "HID 设备已切换: $_new_device (类型: $_dev_type)"

    printf '{"ok":true,"msg":"设备已切换","device":"%s","device_type":"%s"}' "$_new_device" "$_dev_type"
}

# ---- API: /api/settings (GET) ----
api_settings_get() {
    . "$SETTINGS_FILE" 2>/dev/null
    _cur_key_delay="${KEY_DELAY:-0}"
    _cur_alt_delay="${ALT_RELEASE_DELAY:-0}"
    _cur_char_delay="${CHAR_DELAY:-0}"
    cat <<EOF
{"ok":true,"key_delay":$_cur_key_delay,"alt_release_delay":$_cur_alt_delay,"char_delay":$_cur_char_delay,"key_delay_min":0,"key_delay_max":0.1,"alt_delay_min":0,"alt_delay_max":0.1,"char_delay_min":0,"char_delay_max":0.1}
EOF
}

# ---- API: /api/settings (POST) ----
# 参数: $1=请求体 JSON
api_settings_post() {
    _body="$1"
    _new_key_delay=$(json_get "$_body" "key_delay")
    _new_alt_delay=$(json_get "$_body" "alt_release_delay")
    _new_char_delay=$(json_get "$_body" "char_delay")

    _updated=0
    _errors=""

    if [ -n "$_new_key_delay" ]; then
        # 验证是数字且在范围内（0-100ms = 0-0.1s）
        if printf '%s' "$_new_key_delay" | grep -qE '^[0-9]+\.?[0-9]*$'; then
            _in_range=$(awk -v v="$_new_key_delay" 'BEGIN{ if(v>=0 && v<=0.1) print 1; else print 0 }')
            if [ "$_in_range" = "1" ]; then
                KEY_DELAY="$_new_key_delay"
                _updated=1
            else
                _errors="${_errors}key_delay 超出范围 [0,0.1] (0-100ms); "
            fi
        else
            _errors="${_errors}key_delay 不是合法数字; "
        fi
    fi

    if [ -n "$_new_alt_delay" ]; then
        if printf '%s' "$_new_alt_delay" | grep -qE '^[0-9]+\.?[0-9]*$'; then
            _in_range=$(awk -v v="$_new_alt_delay" 'BEGIN{ if(v>=0 && v<=0.1) print 1; else print 0 }')
            if [ "$_in_range" = "1" ]; then
                ALT_RELEASE_DELAY="$_new_alt_delay"
                _updated=1
            else
                _errors="${_errors}alt_release_delay 超出范围 [0,0.1] (0-100ms); "
            fi
        else
            _errors="${_errors}alt_release_delay 不是合法数字; "
        fi
    fi

    if [ -n "$_new_char_delay" ]; then
        if printf '%s' "$_new_char_delay" | grep -qE '^[0-9]+\.?[0-9]*$'; then
            _in_range=$(awk -v v="$_new_char_delay" 'BEGIN{ if(v>=0 && v<=0.1) print 1; else print 0 }')
            if [ "$_in_range" = "1" ]; then
                CHAR_DELAY="$_new_char_delay"
                _updated=1
            else
                _errors="${_errors}char_delay 超出范围 [0,0.1] (0-100ms); "
            fi
        else
            _errors="${_errors}char_delay 不是合法数字; "
        fi
    fi

    if [ -n "$_errors" ]; then
        printf '{"ok":false,"msg":"%s"}' "$_errors"
        return
    fi

    if [ "$_updated" = "0" ]; then
        printf '{"ok":false,"msg":"未提供可更新字段"}'
        return
    fi

    # 保存到配置文件
    cat > "$SETTINGS_FILE" <<EOF
KEY_DELAY=$KEY_DELAY
ALT_RELEASE_DELAY=$ALT_RELEASE_DELAY
CHAR_DELAY=$CHAR_DELAY
EOF
    log "延时设置已更新: key_delay=$KEY_DELAY, alt_release_delay=$ALT_RELEASE_DELAY, char_delay=$CHAR_DELAY"
    printf '{"ok":true,"msg":"设置已更新","key_delay":%s,"alt_release_delay":%s,"char_delay":%s}' "$KEY_DELAY" "$ALT_RELEASE_DELAY" "$CHAR_DELAY"
}

# ---- API: /api/stop (POST) ----
api_stop() {
    touch "$STOP_FLAG"
    log "用户请求停止打字"
    printf '{"ok":true,"msg":"已请求停止打字"}'
}

# ---- API: /api/type (POST) ----
# 请求体: {"encoding":"gbk","items":[{"code":54992},{"control":"enter"},...]}
api_type() {
    _body="$1"

    # 检查是否正在打字
    _busy=$(json_get "$(cat "$STATUS_FILE" 2>/dev/null)" "busy")
    if [ "$_busy" = "true" ]; then
        printf '{"ok":false,"msg":"正在打字中，请先停止"}'
        return
    fi

    # 运行时获取当前 HID 设备（允许网页切换）
    _cur_device=$(get_current_device)

    # 检查 HID 设备
    if [ ! -e "$_cur_device" ]; then
        printf '{"ok":false,"msg":"HID 设备不存在: %s"}' "$_cur_device"
        return
    fi

    # 解析编码和序列
    _encoding=$(json_get "$_body" "encoding")

    # 提取 items 数组中的 code 和 control 字段
    # 用 awk 循环解析所有匹配项（match() 只找第一个，需手动循环）
    _items_file="$STATE_DIR/items.tmp"
    printf '%s' "$_body" | awk '
    BEGIN { in_items = 0 }
    /"items"/ { in_items = 1 }
    in_items {
        # 循环查找所有 "code":数字
        rest = $0
        while (match(rest, /"code"[ \t]*:[ \t]*[0-9]+/)) {
            s = substr(rest, RSTART, RLENGTH)
            sub(/.*:[ \t]*/, "", s)
            print "code " s
            rest = substr(rest, RSTART + RLENGTH)
        }
        # 循环查找所有 "control":"字符串"
        rest = $0
        while (match(rest, /"control"[ \t]*:[ \t]*"[^"]*"/)) {
            s = substr(rest, RSTART, RLENGTH)
            sub(/.*:[ \t]*"/, "", s)
            sub(/"$/, "", s)
            print "control " s
            rest = substr(rest, RSTART + RLENGTH)
        }
    }
    /\]/ { if (in_items) in_items = 0 }
    ' > "$_items_file"

    _total=$(wc -l < "$_items_file" | tr -d ' ')
    if [ "$_total" = "0" ]; then
        printf '{"ok":false,"msg":"没有可打字的内容"}'
        rm -f "$_items_file"
        return
    fi

    # 启动后台打字任务
    rm -f "$STOP_FLAG"
    (
        # 重新加载最新延时设置
        . "$SETTINGS_FILE" 2>/dev/null
        KEY_DELAY="${KEY_DELAY:-0}"
        ALT_RELEASE_DELAY="${ALT_RELEASE_DELAY:-0}"
        CHAR_DELAY="${CHAR_DELAY:-0}"

        # CHAR_DELAY 秒转毫秒（C 程序用毫秒）
        _char_delay_ms=$(awk -v s="$CHAR_DELAY" 'BEGIN{ v=s*1000; if(v<0)v=0; printf "%.0f", v }')

        # 检测 C 原生加速器
        _use_native=0
        if [ -x "$INSTALL_DIR/hid_writer" ]; then
            _use_native=1
        fi

        update_status true 0 "$_total" "$_encoding" ""

        if [ "$_use_native" = "1" ]; then
            # ===== C 原生加速路径（快 50-100 倍）=====
            log "开始打字(C加速): 编码=$_encoding, 共 $_total 项, char_delay=${_char_delay_ms}ms"

            # 后台启动 C 程序
            cat "$_items_file" | "$INSTALL_DIR/hid_writer" \
                --device "$_cur_device" \
                --char-delay "$_char_delay_ms" \
                --batch 5 \
                --verbose >> "$LOG_FILE" 2>&1 &
            _writer_pid=$!

            # 监控停止标志（C 程序不检查 STOP_FLAG，需外部 kill）
            while kill -0 "$_writer_pid" 2>/dev/null; do
                if [ -f "$STOP_FLAG" ]; then
                    kill "$_writer_pid" 2>/dev/null
                    wait "$_writer_pid" 2>/dev/null
                    log "用户中止打字（C 程序已终止）"
                    break
                fi
                # 短暂等待（C 程序很快，100ms 轮询足够）
                sleep 0.1 2>/dev/null || sleep 1
            done
            wait "$_writer_pid" 2>/dev/null

            _progress=$_total
            update_status true "$_progress" "$_total" "$_encoding" ""
        else
            # ===== Shell 回退路径 =====
            # 加载 HID 控制
            . "$INSTALL_DIR/hid_keyboard.sh"

            # 初始化 HID（使用运行时选择的设备）
            if ! hid_init "$_cur_device" 2>/dev/null; then
                update_status false 0 "$_total" "$_encoding" "HID 初始化失败"
                exit 1
            fi

            log "开始打字(Shell): 编码=$_encoding, 共 $_total 项"

            _progress=0
            while IFS=' ' read -r _type _value; do
                # 检查停止标志
                if [ -f "$STOP_FLAG" ]; then
                    log "用户中止打字（已完成 $_progress/$_total）"
                    break
                fi

                case "$_type" in
                    code)
                        hid_type_alt_code "$_value"
                        ;;
                    control)
                        hid_type_control_char "$_value"
                        ;;
                esac

                _progress=$((_progress + 1))
                update_status true "$_progress" "$_total" "$_encoding" ""
            done < "$_items_file"
        fi

        rm -f "$_items_file" "$STOP_FLAG"
        update_status false "$_progress" "$_total" "$_encoding" ""
        log "打字完成: $_progress/$_total"
    ) &

    printf '{"ok":true,"msg":"开始打字","total":%s,"encoding":"%s"}' "$_total" "$_encoding"
}

# ---- 处理单个 HTTP 请求 ----
handle_request() {
    # 读取请求行（容错：read 失败时返回 400）
    _request_line=""
    read -r _request_line 2>/dev/null || true
    _request_line=$(printf '%s' "$_request_line" | tr -d '\r')

    # 如果读不到请求行，返回 400
    if [ -z "$_request_line" ]; then
        printf 'HTTP/1.1 400 Bad Request\r\n'
        printf 'Content-Type: application/json; charset=utf-8\r\n'
        printf 'Content-Length: 35\r\n'
        printf 'Connection: close\r\n'
        printf '\r\n'
        printf '{"ok":false,"msg":"空请求"}'
        return
    fi

    # 解析方法 和 路径
    _method=$(printf '%s' "$_request_line" | awk '{print $1}')
    _path=$(printf '%s' "$_request_line" | awk '{print $2}')

    # 读取 headers（直到空行），记录 Content-Length
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

    # 读取请求体（如果有）
    _body=""
    if [ "$_content_length" != "0" ] && [ -n "$_content_length" ]; then
        _body=$(dd bs=1 count="$_content_length" 2>/dev/null)
    fi

    # 路由
    case "$_method" in
        GET)
            case "$_path" in
                /|/index.html)
                    if [ -f "$INSTALL_DIR/templates/index.html" ]; then
                        _html=$(cat "$INSTALL_DIR/templates/index.html")
                        http_html 200 "$_html"
                    else
                        http_html 404 "<html><body><h1>404 Not Found</h1><p>index.html not found</p></body></html>"
                    fi
                    ;;
                /api/health)
                    _json=$(api_health)
                    http_json 200 "$_json"
                    ;;
                /api/settings)
                    _json=$(api_settings_get)
                    http_json 200 "$_json"
                    ;;
                /api/config)
                    # 兼容旧接口
                    _json=$(api_health)
                    http_json 200 "$_json"
                    ;;
                /gbk_table.json)
                    if [ -f "$INSTALL_DIR/templates/gbk_table.json" ]; then
                        _json=$(cat "$INSTALL_DIR/templates/gbk_table.json")
                        http_response 200 "application/json; charset=utf-8" "$_json"
                    else
                        http_json 404 '{"ok":false,"msg":"GBK 编码表不存在"}'
                    fi
                    ;;
                *)
                    http_json 404 '{"ok":false,"msg":"路径不存在"}'
                    ;;
            esac
            ;;
        POST)
            case "$_path" in
                /api/type)
                    _json=$(api_type "$_body")
                    http_json 200 "$_json"
                    ;;
                /api/stop)
                    _json=$(api_stop)
                    http_json 200 "$_json"
                    ;;
                /api/settings)
                    _json=$(api_settings_post "$_body")
                    http_json 200 "$_json"
                    ;;
                /api/device)
                    _json=$(api_device_post "$_body")
                    http_json 200 "$_json"
                    ;;
                *)
                    http_json 404 '{"ok":false,"msg":"路径不存在"}'
                    ;;
            esac
            ;;
        OPTIONS)
            # CORS 预检
            printf 'HTTP/1.1 204 No Content\r\n'
            printf 'Access-Control-Allow-Origin: *\r\n'
            printf 'Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n'
            printf 'Access-Control-Allow-Headers: Content-Type\r\n'
            printf 'Content-Length: 0\r\n'
            printf '\r\n'
            ;;
        *)
            http_json 400 '{"ok":false,"msg":"不支持的请求方法"}'
            ;;
    esac
}

# ---- 子命令模式：socat fork 出来处理单个连接 ----
# 必须在 handle_request 定义之后调用
if [ "$1" = "handle" ]; then
    handle_request
    exit 0
fi

# ---- 初始化并启动服务（仅主进程执行）----
init_settings
update_status false 0 0 "" ""

log "========================================="
log "ChinesePrinter 服务启动 (shell + socat)"
log "  监听端口: $PORT"
log "  HID 设备: $HID_DEVICE"
log "  按键间隔: ${KEY_DELAY}s"
log "  Alt 释放延时: ${ALT_RELEASE_DELAY}s"
log "  安装目录: $INSTALL_DIR"
log "========================================="

# 检查 socat
if ! command -v socat >/dev/null 2>&1; then
    err "未找到 socat，请安装: opkg install socat 或 apt-get install socat"
    exit 1
fi

# 检查 HID 设备
if [ ! -e "$HID_DEVICE" ]; then
    warn "HID 设备不存在: $HID_DEVICE，服务仍启动但打字不可用"
fi

# 用 socat 监听，每个连接 fork 一个 shell 处理
# 通过环境变量传递配置给子进程
export INSTALL_DIR
export HID_DEVICE
export PORT
export STATE_DIR
export SETTINGS_FILE
export STOP_FLAG
export STATUS_FILE
export LOG_FILE
export KEY_DELAY
export ALT_RELEASE_DELAY

log "服务已启动，等待连接..."
# 用 SYSTEM 而非 EXEC，避免参数解析问题
# socat 会将 stdin/stdout 连接到 socket
exec socat TCP-LISTEN:"$PORT",reuseaddr,fork SYSTEM:"sh '$INSTALL_DIR/server.sh' handle"

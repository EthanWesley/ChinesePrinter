#!/bin/sh
# ============================================================================
# hid_keyboard.sh - USB HID 键盘控制（直接写 /dev/hidgN）
#
# 报告格式：8 字节
#   byte 0: modifier (bit0=LCtrl, bit1=LShift, bit2=LAlt, bit3=LGui,
#                     bit4=RCtrl, bit5=RShift, bit6=RAlt, bit7=RGui)
#   byte 1: reserved (0x00)
#   byte 2-7: keycode（最多 6 个同时按下）
#
# 用法：
#   . /opt/chinese-printer/hid_keyboard.sh
#   hid_init /dev/hidg0
#   hid_type_alt_code 54992   # 直接输入一个 Alt 码字符
#
# 性能优化：
#   1. 预打开 FD 3（exec 3<>/dev/hidg0），避免每次 write 都 open/close 设备
#   2. 合并一个字符的全部 HID 报告为一次 printf（10 次 write → 1 次）
#      内核 hidg 驱动按 8 字节边界拆分，逐个提交给 USB host，不会丢字
#   3. 内联 numpad keycode case 语句，避免函数调用开销
#   4. _delay() 对值为 0 直接返回，零子进程开销
# ============================================================================

# ---- 全局状态 ----
HID_DEVICE="${HID_DEVICE:-/dev/hidg0}"
KEY_DELAY="${KEY_DELAY:-0}"               # 按键间隔（秒，0=最快，已弃用但保留兼容）
ALT_RELEASE_DELAY="${ALT_RELEASE_DELAY:-0}"  # 松开 Alt 前的等待（秒，0=最快）
CHAR_DELAY="${CHAR_DELAY:-0}"             # 字符间延时（秒，0=最快，防乱码用）
_HID_FD_OPEN=""                           # FD 3 是否已打开

# ---- 安全延时函数 ----
# 当值为 0 或空时直接返回，避免 sleep 0 的进程创建开销（约 40ms/次）
# shell 的 sleep 即使参数为 0 也要 fork+exec 子进程，这是打字慢的根源
_delay() {
    case "$1" in
        0|0.0|0.00|0.000|"") return ;;
        *) sleep "$1" ;;
    esac
}

# ---- 小键盘数字键码（十六进制字符串，直接用于 printf \x 转义）----
# Numpad0=0x62, Numpad1=0x59, Numpad2=0x5A, Numpad3=0x5B,
# Numpad4=0x5C, Numpad5=0x5D, Numpad6=0x5E, Numpad7=0x5F,
# Numpad8=0x60, Numpad9=0x61
_numpad_keycode_hex() {
    case "$1" in
        0) echo "62" ;;
        1) echo "59" ;;
        2) echo "5a" ;;
        3) echo "5b" ;;
        4) echo "5c" ;;
        5) echo "5d" ;;
        6) echo "5e" ;;
        7) echo "5f" ;;
        8) echo "60" ;;
        9) echo "61" ;;
        *) echo "00" ;;
    esac
}

# ---- 基础函数 ----

# 发送一个 8 字节 HID 报告
# 参数: $1=modifier $2=keycode1 ... $6=keycode6
hid_send() {
    _mod="${1:-0}"
    _kc1="${2:-0}"
    _kc2="${3:-0}"
    _kc3="${4:-0}"
    _kc4="${5:-0}"
    _kc5="${6:-0}"
    _kc6="${7:-0}"
    _h_mod=$(printf '%02x' "$_mod")
    _h_kc1=$(printf '%02x' "$_kc1")
    _h_kc2=$(printf '%02x' "$_kc2")
    _h_kc3=$(printf '%02x' "$_kc3")
    _h_kc4=$(printf '%02x' "$_kc4")
    _h_kc5=$(printf '%02x' "$_kc5")
    _h_kc6=$(printf '%02x' "$_kc6")
    if [ -n "$_HID_FD_OPEN" ]; then
        printf "\\x${_h_mod}\\x00\\x${_h_kc1}\\x${_h_kc2}\\x${_h_kc3}\\x${_h_kc4}\\x${_h_kc5}\\x${_h_kc6}" >&3
    else
        printf "\\x${_h_mod}\\x00\\x${_h_kc1}\\x${_h_kc2}\\x${_h_kc3}\\x${_h_kc4}\\x${_h_kc5}\\x${_h_kc6}" > "$HID_DEVICE"
    fi
}

# 发送空报告（松开所有键）
hid_release_all() {
    if [ -n "$_HID_FD_OPEN" ]; then
        printf '\x00\x00\x00\x00\x00\x00\x00\x00' >&3
    else
        printf '\x00\x00\x00\x00\x00\x00\x00\x00' > "$HID_DEVICE"
    fi
    _delay "$KEY_DELAY"
}

# 按住左 Alt（不松开）
hid_press_alt() {
    # modifier bit2 = LAlt = 0x04
    if [ -n "$_HID_FD_OPEN" ]; then
        printf '\x04\x00\x00\x00\x00\x00\x00\x00' >&3
    else
        printf '\x04\x00\x00\x00\x00\x00\x00\x00' > "$HID_DEVICE"
    fi
    _delay "$KEY_DELAY"
}

# 按下并松开一个键
# 参数: $1=modifier $2=keycode
hid_press_release() {
    _mod="${1:-0}"
    _kc="${2:-0}"
    _h_mod=$(printf '%02x' "$_mod")
    _h_kc=$(printf '%02x' "$_kc")
    if [ -n "$_HID_FD_OPEN" ]; then
        # 按下 + 松开合并为一次 write（16 字节）
        printf "\\x${_h_mod}\\x00\\x${_h_kc}\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00" >&3
    else
        # 回退路径
        printf "\\x${_h_mod}\\x00\\x${_h_kc}\\x00\\x00\\x00\\x00\\x00" > "$HID_DEVICE"
        _delay "$KEY_DELAY"
        printf '\x00\x00\x00\x00\x00\x00\x00\x00' > "$HID_DEVICE"
    fi
    _delay "$KEY_DELAY"
}

# 在小键盘上敲一个数字（0-9），保持 Alt 按下
# 参数: $1=数字字符
hid_type_numpad_digit() {
    _hc=$(_numpad_keycode_hex "$1")
    if [ -n "$_HID_FD_OPEN" ]; then
        # 按下 + 松开合并为一次 write（16 字节），Alt 仍按住 modifier=0x04
        printf "\\x04\\x00\\x${_hc}\\x00\\x00\\x00\\x00\\x00\\x04\\x00\\x00\\x00\\x00\\x00\\x00\\x00" >&3
    else
        printf "\\x04\\x00\\x${_hc}\\x00\\x00\\x00\\x00\\x00" > "$HID_DEVICE"
        _delay "$KEY_DELAY"
        printf '\x04\x00\x00\x00\x00\x00\x00\x00' > "$HID_DEVICE"
    fi
    _delay "$KEY_DELAY"
}

# ---- Alt 码打字（核心优化）----

# 通过 Alt 码输入一个字符
# 参数: $1=十进制编码值
#
# 优化策略：把一个字符的全部 HID 报告（press_alt + N×digit_down/up + release_all）
# 合并成一次 printf 调用。内核 hidg 驱动会按 8 字节边界拆分，逐个提交给 USB host。
# 这样 10 次 write 降到 1 次，大幅减少系统调用和 open/close 开销。
hid_type_alt_code() {
    _code="$1"
    [ -z "$_code" ] && return 1

    # 构造完整报告序列
    # 报告1: press alt (modifier=0x04)
    _buf='\x04\x00\x00\x00\x00\x00\x00\x00'

    # 每个数字：报告 down + 报告 up（保持 Alt 按住）
    _remaining="$_code"
    while [ -n "$_remaining" ]; do
        _digit="${_remaining%"${_remaining#?}"}"
        _remaining="${_remaining#?}"
        # 内联 numpad keycode（避免函数调用开销）
        case "$_digit" in
            0) _hc="62" ;;
            1) _hc="59" ;;
            2) _hc="5a" ;;
            3) _hc="5b" ;;
            4) _hc="5c" ;;
            5) _hc="5d" ;;
            6) _hc="5e" ;;
            7) _hc="5f" ;;
            8) _hc="60" ;;
            9) _hc="61" ;;
            *) _hc="00" ;;
        esac
        # down: Alt+key, up: Alt only（合并 16 字节）
        _buf="${_buf}\\x04\\x00\\x${_hc}\\x00\\x00\\x00\\x00\\x00"
        _buf="${_buf}\\x04\\x00\\x00\\x00\\x00\\x00\\x00\\x00"
    done

    # 最后报告: release all（松开 Alt 触发字符输入）
    _buf="${_buf}\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00"

    # 一次写入全部报告
    if [ -n "$_HID_FD_OPEN" ]; then
        printf "$_buf" >&3
    else
        printf "$_buf" > "$HID_DEVICE"
    fi

    # 松开 Alt 前的等待（让 Windows 准备好处理 Alt 码）
    _delay "$ALT_RELEASE_DELAY"
    # 字符间延时（防乱码）
    _delay "$CHAR_DELAY"
}

# ---- 控制字符 ----

# 输入控制字符（回车、空格等）
# 参数: $1=字符名（enter/space/tab/backspace/esc）
hid_type_control_char() {
    case "$1" in
        enter|return|newline)
            hid_press_release 0 0x28   # KEY_ENTER
            ;;
        space)
            hid_press_release 0 0x2c   # KEY_SPACE
            ;;
        tab)
            hid_press_release 0 0x2b   # KEY_TAB
            ;;
        backspace)
            hid_press_release 0 0x2a   # KEY_BACKSPACE
            ;;
        esc|escape)
            hid_press_release 0 0x29   # KEY_ESC
            ;;
        *)
            return 1
            ;;
    esac
}

# ---- 初始化 ----

# 初始化 HID 设备
# 参数: $1=设备路径（可选，默认用全局 HID_DEVICE）
# 优化：预打开 FD 3，后续所有 write 都用 >&3，避免每次 open/close 设备文件
hid_init() {
    if [ -n "$1" ]; then
        HID_DEVICE="$1"
    fi
    if [ ! -e "$HID_DEVICE" ]; then
        echo "ERROR: HID 设备不存在: $HID_DEVICE" >&2
        return 1
    fi

    # 关闭可能存在的旧 FD
    if [ -n "$_HID_FD_OPEN" ]; then
        exec 3>&- 2>/dev/null || true
        _HID_FD_OPEN=""
    fi

    # 预打开 FD 3（读写模式，兼容性最好）
    # 这样后续 printf >&3 不需要每次 open/close 设备文件
    # 节省约 1-2ms/次 write，10 次/字符 = 10-20ms/字符
    if exec 3<>"$HID_DEVICE" 2>/dev/null; then
        _HID_FD_OPEN=1
    else
        # 回退：不使用 FD（每次 write 都 open/close）
        _HID_FD_OPEN=""
    fi

    # 松开所有键，确保初始状态干净
    hid_release_all 2>/dev/null || true
    return 0
}

# 关闭 FD（可选，子进程退出时会自动关闭）
hid_close() {
    if [ -n "$_HID_FD_OPEN" ]; then
        exec 3>&- 2>/dev/null || true
        _HID_FD_OPEN=""
    fi
}

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
#   hid_press_alt    # 按下左 Alt
#   hid_type_numpad_digit 5  # 在小键盘上敲 5
#   hid_release_all  # 松开所有键（包括 Alt）→ 触发 Alt 码输入
# ============================================================================

# ---- 全局状态 ----
HID_DEVICE="${HID_DEVICE:-/dev/hidg0}"
KEY_DELAY="${KEY_DELAY:-0}"               # 按键间隔（秒，0=最快）
ALT_RELEASE_DELAY="${ALT_RELEASE_DELAY:-0}"  # 松开 Alt 前的等待（秒，0=最快）
CHAR_DELAY="${CHAR_DELAY:-0}"             # 字符间延时（秒，0=最快，防乱码用）

# ---- 安全延时函数 ----
# 当值为 0 或空时直接返回，避免 sleep 0 的进程创建开销（约 40ms/次）
# shell 的 sleep 即使参数为 0 也要 fork+exec 子进程，这是打字慢的根源
_delay() {
    case "$1" in
        0|0.0|0.00|0.000|"") return ;;
        *) sleep "$1" ;;
    esac
}

# ---- 基础函数 ----

# 发送一个 8 字节 HID 报告
# 参数: $1=modifier $2=keycode1 $3=keycode2 ... $6=keycode6
hid_send() {
    _mod="${1:-0}"
    _kc1="${2:-0}"
    _kc2="${3:-0}"
    _kc3="${4:-0}"
    _kc4="${5:-0}"
    _kc5="${6:-0}"
    _kc6="${7:-0}"
    # 预计算十六进制（避免嵌套 $(printf) 子进程）
    _h_mod=$(printf '%02x' "$_mod")
    _h_kc1=$(printf '%02x' "$_kc1")
    _h_kc2=$(printf '%02x' "$_kc2")
    _h_kc3=$(printf '%02x' "$_kc3")
    _h_kc4=$(printf '%02x' "$_kc4")
    _h_kc5=$(printf '%02x' "$_kc5")
    _h_kc6=$(printf '%02x' "$_kc6")
    printf "\\x${_h_mod}\\x00\\x${_h_kc1}\\x${_h_kc2}\\x${_h_kc3}\\x${_h_kc4}\\x${_h_kc5}\\x${_h_kc6}" > "$HID_DEVICE"
}

# 发送空报告（松开所有键）
hid_release_all() {
    printf '\x00\x00\x00\x00\x00\x00\x00\x00' > "$HID_DEVICE"
    _delay "$KEY_DELAY"
}

# 按住左 Alt（不松开）
hid_press_alt() {
    # modifier bit2 = LAlt = 0x04
    printf '\x04\x00\x00\x00\x00\x00\x00\x00' > "$HID_DEVICE"
    _delay "$KEY_DELAY"
}

# 按下并松开一个键
# 参数: $1=modifier $2=keycode
hid_press_release() {
    _mod="${1:-0}"
    _kc="${2:-0}"
    # 按下
    _h_mod=$(printf '%02x' "$_mod")
    _h_kc=$(printf '%02x' "$_kc")
    printf "\\x${_h_mod}\\x00\\x${_h_kc}\\x00\\x00\\x00\\x00\\x00" > "$HID_DEVICE"
    _delay "$KEY_DELAY"
    # 松开
    printf '\x00\x00\x00\x00\x00\x00\x00\x00' > "$HID_DEVICE"
    _delay "$KEY_DELAY"
}

# ---- 小键盘数字键码 ----
# Numpad 0-9 的 HID keycode（返回十六进制字符串，直接用于 printf \x 转义）
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

# 在小键盘上敲一个数字（0-9），保持 Alt 按下
# 参数: $1=数字字符
hid_type_numpad_digit() {
    _hc=$(_numpad_keycode_hex "$1")
    # 按下键（Alt 仍按住，modifier=0x04）
    # 直接用变量展开构造 printf 格式字符串，避免 hid_send 的多次 printf '%02x'
    printf "\\x04\\x00\\x${_hc}\\x00\\x00\\x00\\x00\\x00" > "$HID_DEVICE"
    _delay "$KEY_DELAY"
    # 松开键（Alt 仍按住）
    printf '\x04\x00\x00\x00\x00\x00\x00\x00' > "$HID_DEVICE"
    _delay "$KEY_DELAY"
}

# ---- Alt 码打字 ----

# 通过 Alt 码输入一个字符
# 参数: $1=十进制编码值
hid_type_alt_code() {
    _code="$1"
    [ -z "$_code" ] && return 1

    # 1. 按住左 Alt
    hid_press_alt

    # 2. 依次敲击数字（小键盘）
    # 将数字逐位拆分
    _remaining="$_code"
    while [ -n "$_remaining" ]; do
        # 取第一位
        _digit="${_remaining%"${_remaining#?}"}"
        # 剩余部分
        _remaining="${_remaining#?}"
        hid_type_numpad_digit "$_digit"
    done

    # 3. 等待一下，让目标电脑处理
    _delay "$ALT_RELEASE_DELAY"

    # 4. 松开 Alt（触发目标电脑输入字符）
    hid_release_all

    # 5. 字符间延时，让 Windows 完成字符输入后再开始下一个
    # 用独立的 CHAR_DELAY，便于网页单独调节防乱码延时
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
hid_init() {
    if [ -n "$1" ]; then
        HID_DEVICE="$1"
    fi
    if [ ! -e "$HID_DEVICE" ]; then
        echo "ERROR: HID 设备不存在: $HID_DEVICE" >&2
        return 1
    fi
    # 松开所有键，确保初始状态干净
    hid_release_all 2>/dev/null || true
    return 0
}

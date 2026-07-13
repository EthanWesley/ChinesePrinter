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
KEY_DELAY="${KEY_DELAY:-0.05}"         # 按键间隔（秒）
ALT_RELEASE_DELAY="${ALT_RELEASE_DELAY:-0.08}"  # 松开 Alt 前的等待

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
    # 用 printf 写二进制（\x00 表示 0x00 字节）
    printf "\\x$(printf '%02x' "$_mod")\\x00\\x$(printf '%02x' "$_kc1")\\x$(printf '%02x' "$_kc2")\\x$(printf '%02x' "$_kc3")\\x$(printf '%02x' "$_kc4")\\x$(printf '%02x' "$_kc5")\\x$(printf '%02x' "$_kc6")" > "$HID_DEVICE"
}

# 发送空报告（松开所有键）
hid_release_all() {
    printf '\x00\x00\x00\x00\x00\x00\x00\x00' > "$HID_DEVICE"
    sleep "$KEY_DELAY"
}

# 按住左 Alt（不松开）
hid_press_alt() {
    # modifier bit2 = LAlt = 0x04
    printf '\x04\x00\x00\x00\x00\x00\x00\x00' > "$HID_DEVICE"
    sleep "$KEY_DELAY"
}

# 按下并松开一个键
# 参数: $1=modifier $2=keycode
hid_press_release() {
    _mod="${1:-0}"
    _kc="${2:-0}"
    # 按下
    printf "\\x$(printf '%02x' "$_mod")\\x00\\x$(printf '%02x' "$_kc")\\x00\\x00\\x00\\x00\\x00" > "$HID_DEVICE"
    sleep "$KEY_DELAY"
    # 松开
    printf '\x00\x00\x00\x00\x00\x00\x00\x00' > "$HID_DEVICE"
    sleep "$KEY_DELAY"
}

# ---- 小键盘数字键码 ----
# Numpad 0-9 的 HID keycode（返回十进制值，供 hid_send 使用）
# Numpad0=0x62(98), Numpad1=0x59(89), Numpad2=0x5A(90), Numpad3=0x5B(91),
# Numpad4=0x5C(92), Numpad5=0x5D(93), Numpad6=0x5E(94), Numpad7=0x5F(95),
# Numpad8=0x60(96), Numpad9=0x61(97)
_numpad_keycode() {
    case "$1" in
        0) echo "98" ;;
        1) echo "89" ;;
        2) echo "90" ;;
        3) echo "91" ;;
        4) echo "92" ;;
        5) echo "93" ;;
        6) echo "94" ;;
        7) echo "95" ;;
        8) echo "96" ;;
        9) echo "97" ;;
        *) echo "0" ;;
    esac
}

# 在小键盘上敲一个数字（0-9），保持 Alt 按下
# 参数: $1=数字字符
hid_type_numpad_digit() {
    _digit="$1"
    _kc=$(_numpad_keycode "$_digit")
    # 按下键（Alt 仍按住，modifier=0x04）
    hid_send 4 "$_kc"
    sleep "$KEY_DELAY"
    # 松开键（Alt 仍按住）
    hid_send 4 0
    sleep "$KEY_DELAY"
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
    sleep "$ALT_RELEASE_DELAY"

    # 4. 松开 Alt（触发目标电脑输入字符）
    hid_release_all
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

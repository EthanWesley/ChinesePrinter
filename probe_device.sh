#!/bin/sh
# probe_device.sh - 一次性硬件能力探测（在 Luckfox Pico KVM 设备上运行）
#
# 用途：为 AI 自动化改造（:8849 通道）确认三个关键假设：
#   1. HDMI 采集设备是否存在（/dev/video*）及其支持的像素格式
#   2. HID 鼠标 gadget 是否存在（/dev/hidg*，protocol=2）
#   3. 鼠标 report descriptor 的报告长度与是否绝对坐标
#
# 输出：单段 JSON 到 stdout，便于直接回传分析。
# 用法：sh probe_device.sh [--capture-bin PATH]

CAPTURE_BIN="/opt/chinese-printer/capture"
[ "$1" = "--capture-bin" ] && CAPTURE_BIN="$2"

# JSON 字符串转义（仅处理引号与反斜杠，够用）
json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\r\n\t'
}

echo '{'

# ---- 基本信息 ----
_uptime=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)
_model=$(awk -F: '/^Model|^Hardware/ {gsub(/^ +/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null)
[ -z "$_model" ] && _model=$(cat /proc/device-tree/model 2>/dev/null | tr -d '\000')
_kernel=$(uname -r)
_mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null)

printf '  "system": {"model": "%s", "kernel": "%s", "mem_total_kb": %s, "uptime_s": %s},\n' \
    "$(json_escape "$_model")" "$(json_escape "$_kernel")" "${_mem_kb:-0}" "${_uptime%%.*}"

# ---- 采集设备 ----
printf '  "video": {"devices": ['
_first=1
for _v in /dev/video*; do
    [ -e "$_v" ] || continue
    _name=$(cat "/sys/class/video4linux/$(basename "$_v")/name" 2>/dev/null)
    [ -z "$_name" ] && _name="unknown"
    [ "$_first" = "1" ] || printf ', '
    _first=0
    printf '{"dev": "%s", "name": "%s"}' "$_v" "$(json_escape "$_name")"
done
printf ']'

# capture --probe 的格式枚举（若二进制已安装）
if [ -x "$CAPTURE_BIN" ]; then
    _probe=$("$CAPTURE_BIN" --probe 2>&1)
    printf ', "formats": %s' "$(printf '%s' "$_probe" | tr -d '\r\n' | sed 's/^ *//')"
else
    printf ', "formats": null, "formats_note": "capture binary not installed"'
fi
printf '},\n'

# ---- HID gadget ----
printf '  "hid": {"gadgets": ['
_first=1
for _h in /dev/hidg*; do
    [ -e "$_h" ] || continue
    _n=$(basename "$_h")
    _proto=$(cat "/sys/class/hidg/$_n/protocol" 2>/dev/null)
    _sub=$(cat "/sys/class/hidg/$_n/subclass" 2>/dev/null)
    [ -z "$_proto" ] && _proto=-1
    [ "$_first" = "1" ] || printf ', '
    _first=0
    printf '{"dev": "%s", "protocol": %s, "subclass": %s}' "$_h" "$_proto" "${_sub:--1}"
done
printf '],\n'

# configfs 中的 report descriptor（十六进制）
printf '         "descriptors": ['
_first=1
for _d in /sys/kernel/config/usb_gadget/*/functions/hid.usb*/report_desc; do
    [ -e "$_d" ] || continue
    _fn=$(basename "$(dirname "$_d")")
    _hex=$(od -An -v -tx1 "$_d" 2>/dev/null | tr -d ' \n')
    [ "$_first" = "1" ] || printf ', '
    _first=0
    printf '{"function": "%s", "hex": "%s"}' "$(json_escape "$_fn")" "$_hex"
done
printf ']},\n'

# ---- 运行时依赖 ----
printf '  "tools": {'
_first=1
for _t in socat awk curl wget ffmpeg v4l2-ctl; do
    _p=$(command -v "$_t" 2>/dev/null)
    [ "$_first" = "1" ] || printf ', '
    _first=0
    if [ -n "$_p" ]; then printf '"%s": "%s"' "$_t" "$(json_escape "$_p")"; else printf '"%s": null' "$_t"; fi
done
printf '},\n'

# ---- 现有服务 ----
_tw_busy="null"
[ -f /tmp/chinese-printer/status.json ] && _tw_busy=$(cat /tmp/chinese-printer/status.json 2>/dev/null | tr -d '\r\n' | grep -o '"busy"[ ]*:[ ]*[a-z]*' | sed 's/.*: *//')
printf '  "typewriter": {"status_file": %s, "busy": %s}\n' \
    "$([ -f /tmp/chinese-printer/status.json ] && echo true || echo false)" "${_tw_busy:-null}"

echo '}'

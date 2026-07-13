#!/bin/sh
# ============================================================================
# ChinesePrinter 远程一键安装/更新脚本（GitHub 版）
#
# 同一条命令既能全新安装，也能自动更新（已安装时保留配置，备份旧代码）
#
# 一行命令安装/更新（国内推荐用加速器前缀）：
#
#   # 方式1：直接访问 GitHub（网络好时）
#   curl -fsSL https://raw.githubusercontent.com/EthanWesley/ChinesePrinter/main/remote_install.sh | sudo sh
#
#   # 方式2：通过 ghproxy 加速（国内推荐）
#   curl -fsSL https://ghproxy.com/https://raw.githubusercontent.com/EthanWesley/ChinesePrinter/main/remote_install.sh | sudo sh
#
#   # 方式3：指定端口和 HID 设备
#   curl -fsSL https://ghproxy.com/https://raw.githubusercontent.com/EthanWesley/ChinesePrinter/main/remote_install.sh | sudo sh -s -- 9000 /dev/hidg1
#
# 本脚本会：
#   1. 下载项目代码（tarball，无需 git）
#   2. 解压到临时目录
#   3. 执行项目内的 install.sh（自动识别安装/更新模式）
#   4. 清理临时文件
#
# 更新行为：
#   - 首次运行 -> 全新安装，创建配置文件和开机自启
#   - 再次运行 -> 自动更新，保留现有配置，备份旧代码到 .backup-* 目录
#   - 传参数时 -> 用新参数覆盖配置（如改端口或 HID 设备）
# ============================================================================

set -e

# ---- 配置 ----
GITHUB_USER="EthanWesley"
GITHUB_REPO="ChinesePrinter"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"

# 加速器前缀（下载 tarball 用）。留空则直接访问 GitHub。
# 可通过环境变量 MIRROR 覆盖，例如：MIRROR=https://ghproxy.com/
MIRROR="${MIRROR:-}"

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
printf "${CYAN}  ChinesePrinter 远程安装/更新${NC}\n"
printf "  来源: GitHub ${GITHUB_USER}/${GITHUB_REPO} (分支: ${GITHUB_BRANCH})\n"
[ -n "$MIRROR" ] && printf "  加速: ${MIRROR}\n"
# 预检测是否已安装
if [ -d "/opt/chinese-printer" ] && [ -f "/opt/chinese-printer/app.py" ]; then
    printf "  模式: ${YELLOW}更新现有安装${NC}\n"
else
    printf "  模式: ${CYAN}全新安装${NC}\n"
fi
line

# ---- 检查 root ----
if [ "$(id -u)" -ne 0 ]; then
    err "请使用 root 权限运行"
    err "  方式1: curl -fsSL <url> | sudo sh"
    err "  方式2: curl -fsSL <url> -o install.sh && sudo sh install.sh"
    exit 1
fi
ok "root 权限"

# ---- 检查下载工具 ----
DOWNLOAD_CMD=""
if command -v curl >/dev/null 2>&1; then
    DOWNLOAD_CMD="curl"
    ok "下载工具: curl"
elif command -v wget >/dev/null 2>&1; then
    DOWNLOAD_CMD="wget"
    ok "下载工具: wget"
else
    err "未找到 curl 或 wget，请先安装其中一个"
    err "  apt-get install curl  或  opkg install curl"
    exit 1
fi

# ---- 检查 tar ----
if ! command -v tar >/dev/null 2>&1; then
    err "未找到 tar，请先安装: apt-get install tar 或 opkg install tar"
    exit 1
fi
ok "解压工具: tar"

# ---- 临时目录 ----
TMP_DIR="$(mktemp -d /tmp/chinese-printer-XXXXXX)"
cleanup() {
    info "清理临时文件..."
    rm -rf "$TMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ---- 构造下载 URL ----
# GitHub tarball 直链
TARBALL_DIRECT="https://github.com/${GITHUB_USER}/${GITHUB_REPO}/archive/refs/heads/${GITHUB_BRANCH}.tar.gz"
# 旧格式备用（兼容某些情况）
TARBALL_ALT="https://codeload.github.com/${GITHUB_USER}/${GITHUB_REPO}/tar.gz/refs/heads/${GITHUB_BRANCH}"

# 加速器 URL 列表（按优先级尝试）
# 国内设备优先用加速器，直连 GitHub 放最后
URLS=""
if [ -n "$MIRROR" ]; then
    # 用户指定了加速器，优先使用
    URLS="${MIRROR}${TARBALL_DIRECT}"
fi
# 常用加速器优先（国内设备直连 GitHub 大概率超时）
URLS="${URLS} https://gh-proxy.com/${TARBALL_DIRECT}"
URLS="${URLS} https://ghproxy.com/${TARBALL_DIRECT}"
URLS="${URLS} https://mirror.ghproxy.com/${TARBALL_DIRECT}"
URLS="${URLS} https://ghps.cc/${TARBALL_DIRECT}"
# 直连 GitHub 和备用地址放最后
URLS="${URLS} ${TARBALL_DIRECT}"
URLS="${URLS} ${TARBALL_ALT}"

# ---- 下载函数 ----
download() {
    _url="$1"
    _out="$2"
    if [ "$DOWNLOAD_CMD" = "curl" ]; then
        curl -fSL --connect-timeout 15 --max-time 120 -o "$_out" "$_url" 2>&1
    else
        wget -q --timeout=60 -O "$_out" "$_url" 2>&1
    fi
}

# ---- 下载项目 tarball ----
info "下载项目代码..."

TARBALL_FILE="${TMP_DIR}/project.tar.gz"
DOWNLOAD_OK=0

for url in $URLS; do
    [ -z "$url" ] && continue
    printf "  尝试: %s\n" "$url"
    if download "$url" "$TARBALL_FILE"; then
        # 验证文件不是空且是 gzip 格式
        if [ -s "$TARBALL_FILE" ] && head -c 2 "$TARBALL_FILE" | grep -q "$(printf '\037\213')" 2>/dev/null; then
            DOWNLOAD_OK=1
            ok "下载成功"
            break
        fi
    fi
    rm -f "$TARBALL_FILE" 2>/dev/null || true
done

if [ "$DOWNLOAD_OK" -eq 0 ]; then
    err "所有下载源均失败"
    err "请检查："
    err "  1. 仓库是否为公开: https://github.com/${GITHUB_USER}/${GITHUB_REPO}"
    err "  2. 分支名是否正确（当前: ${GITHUB_BRANCH}，若是 master 请设 GITHUB_BRANCH=master）"
    err "  3. 网络是否正常"
    err ""
    err "也可手动下载并安装："
    err "  1. 浏览器访问 https://github.com/${GITHUB_USER}/${GITHUB_REPO}"
    err "  2. Code -> Download ZIP"
    err "  3. 解压后执行: sudo sh install.sh"
    exit 1
fi

# ---- 解压 ----
info "解压项目代码..."
EXTRACT_DIR="${TMP_DIR}/extracted"
mkdir -p "$EXTRACT_DIR"

# BusyBox tar 不支持 -z，需要用 gzip 管道或 -a 自动解压
if ! tar -xzf "$TARBALL_FILE" -C "$EXTRACT_DIR" 2>/dev/null; then
    # 回退方案1：gzip 解压到 stdout 再 tar 解包
    if gzip -dc "$TARBALL_FILE" 2>/dev/null | tar -xf - -C "$EXTRACT_DIR" 2>&1; then
        ok "解压成功 (gzip 管道)"
    else
        # 回退方案2：BusyBox tar 的 -a 选项（按扩展名自动解压）
        if tar -xf "$TARBALL_FILE" -a -C "$EXTRACT_DIR" 2>&1; then
            ok "解压成功 (BusyBox -a)"
        else
            err "解压失败：tar 不支持 -z，且 gzip 也不可用"
            err "请安装 gzip: opkg install gzip 或 apt-get install gzip"
            exit 1
        fi
    fi
else
    ok "解压成功"
fi

# 查找包含 install.sh 的项目目录
PROJECT_DIR=""
for d in "$EXTRACT_DIR"/*; do
    if [ -d "$d" ] && [ -f "$d/install.sh" ]; then
        PROJECT_DIR="$d"
        break
    fi
done

if [ -z "$PROJECT_DIR" ] || [ ! -f "$PROJECT_DIR/install.sh" ]; then
    err "未在压缩包中找到 install.sh"
    err "解压内容:"
    ls -la "$EXTRACT_DIR" 2>/dev/null || true
    exit 1
fi
ok "项目代码已解压: $(basename "$PROJECT_DIR")"

# ---- 执行 install.sh ----
echo ""
info "开始执行安装脚本..."
echo ""

cd "$PROJECT_DIR"
sh install.sh "$@"

# install.sh 会处理后续所有工作：安装文件、配置开机自启、启动服务

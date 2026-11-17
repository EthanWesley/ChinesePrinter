#!/bin/sh
# build.sh - 交叉编译 native/ 下的设备二进制（在 WSL 中运行）
#
# 产物：
#   native/hid_writer   现有打字引擎（键盘 Alt 码）
#   native/capture      V4L2 截图（MJPEG 直通；YUYV 需 libjpeg-turbo）
#   native/seq_writer   键鼠序列执行器（:8849 自动化通道）
#
# 用法：
#   ./build.sh              编译全部（capture 无 libjpeg 时退化为 MJPEG-only）
#   ./build.sh libjpeg      先交叉编译 libjpeg-turbo 静态库（一次性）
#   ./build.sh clean        清理
#
# 依赖（WSL / Ubuntu）：
#   sudo apt install gcc-arm-linux-gnueabihf cmake git

set -e
cd "$(dirname "$0")"

CC=${CC:-arm-linux-gnueabihf-gcc}
CFLAGS="-static -O2 -s -Wall"
JPEG_SRC="third_party/libjpeg-turbo"
JPEG_BUILD="third_party/libjpeg-turbo/build-arm"
JPEG_LIB="$JPEG_BUILD/libjpeg.a"

need_cc() {
    command -v "$CC" >/dev/null 2>&1 || {
        echo "错误: 找不到 $CC，请先安装 gcc-arm-linux-gnueabihf" >&2
        exit 1
    }
}

build_libjpeg() {
    command -v cmake >/dev/null 2>&1 || {
        echo "错误: 需要 cmake 编译 libjpeg-turbo" >&2
        exit 1
    }
    if [ ! -d "$JPEG_SRC" ]; then
        mkdir -p third_party
        echo "==> 克隆 libjpeg-turbo"
        git clone --depth 1 https://github.com/libjpeg-turbo/libjpeg-turbo.git "$JPEG_SRC"
    fi
    echo "==> 交叉编译 libjpeg-turbo (ARM NEON, 静态)"
    cmake -S "$JPEG_SRC" -B "$JPEG_BUILD" \
        -DCMAKE_SYSTEM_NAME=Linux \
        -DCMAKE_SYSTEM_PROCESSOR=arm \
        -DCMAKE_C_COMPILER="$CC" \
        -DCMAKE_BUILD_TYPE=Release \
        -DENABLE_SHARED=OFF \
        -DENABLE_STATIC=ON \
        -DWITH_SIMD=1 \
        -DWITH_TURBOJPEG=OFF \
        -DWITH_JAVA=OFF \
        -DWITH_TOOLS=OFF >/dev/null
    cmake --build "$JPEG_BUILD" -j"$(nproc)" >/dev/null
    ls -l "$JPEG_LIB"
}

build_hid_writer() {
    echo "==> hid_writer"
    $CC $CFLAGS -o hid_writer hid_writer.c
}

build_capture() {
    echo "==> capture"
    if [ -f "$JPEG_LIB" ]; then
        $CC $CFLAGS -DHAVE_LIBJPEG \
            -I"$JPEG_SRC/src" -I"$JPEG_BUILD" \
            -o capture capture.c "$JPEG_LIB" -lm
    else
        echo "    提示: 未找到 $JPEG_LIB，编译为 MJPEG-only（YUYV 设备不可用）"
        echo "          需要 YUYV 支持请先运行: ./build.sh libjpeg"
        $CC $CFLAGS -o capture capture.c
    fi
}

build_seq_writer() {
    echo "==> seq_writer"
    $CC $CFLAGS -o seq_writer seq_writer.c
}

case "${1:-all}" in
    libjpeg) need_cc; build_libjpeg ;;
    clean)
        rm -f hid_writer capture seq_writer
        echo "已清理 native/ 产物"
        ;;
    all)
        need_cc
        build_hid_writer
        build_capture
        build_seq_writer
        echo
        ls -l hid_writer capture seq_writer
        echo
        echo "部署：复制到设备 /opt/chinese-printer/ 后重启服务"
        ;;
    *)
        echo "用法: $0 [all|libjpeg|clean]" >&2
        exit 1
        ;;
esac

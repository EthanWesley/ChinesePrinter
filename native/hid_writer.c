/*
 * hid_writer.c - 高性能 HID 键盘写入器（原生 C）
 *
 * 用途：替代 shell 的 printf > /dev/hidg0，大幅减少每字符的开销
 *
 * 核心优化：
 *   1. 直接 write() 系统调用，无 shell 解释器开销（~5ms/字符 → ~0.01ms/字符）
 *   2. 批量模式（--batch N）：一次 write N 个字符的全部 HID 报告
 *      内核 hidg 驱动自动按 8 字节边界拆分，连续排队发送
 *      减少用户态→内核态切换次数
 *   3. FD 常驻（open 一次），避免每次 write 都 open/close 设备
 *   4. 二进制构造报告，无 printf \x 转义开销
 *
 * 输入格式（stdin，每行一条指令）：
 *   code 54992        - 通过 Alt 码输入一个字符
 *   control enter     - 输入控制字符（enter/space/tab/backspace/esc）
 *
 * 用法：
 *   hid_writer --device /dev/hidg0 --batch 10 --char-delay 0 --verbose
 *
 * 编译（WSL 交叉编译）：
 *   arm-linux-gnueabihf-gcc -static -O2 -o hid_writer hid_writer.c
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <errno.h>

/* Numpad 0-9 HID keycodes */
static const unsigned char NUMPAD[10] = {
    0x62, 0x59, 0x5a, 0x5b, 0x5c, 0x5d, 0x5e, 0x5f, 0x60, 0x61
};

/* 构造一个 8 字节 HID 报告
 * [0]=modifier, [1]=reserved(0), [2]=keycode, [3-7]=0
 */
static inline void make_report(unsigned char *r, unsigned char mod, unsigned char kc) {
    r[0] = mod;
    r[1] = 0x00;
    r[2] = kc;
    r[3] = 0x00;
    r[4] = 0x00;
    r[5] = 0x00;
    r[6] = 0x00;
    r[7] = 0x00;
}

/* 构造一个 Alt 码字符的全部 HID 报告
 * 报告序列：press_alt + N×(digit_down + digit_up) + release_all
 * 4 位 Alt 码 = 1 + 4×2 + 1 = 10 个报告 = 80 字节
 *
 * 返回写入 buf 的字节数
 */
static int build_alt_code(unsigned char *buf, int code) {
    int pos = 0;
    char digits[16];
    int ndigits = snprintf(digits, sizeof(digits), "%d", code);
    if (ndigits <= 0) return 0;

    /* 1. 按下 Alt（modifier=0x04） */
    make_report(buf + pos, 0x04, 0x00);
    pos += 8;

    /* 2. 每个数字：按下 + 松开（Alt 保持） */
    for (int i = 0; i < ndigits; i++) {
        int d = digits[i] - '0';
        if (d < 0 || d > 9) continue;
        /* 按下：Alt + numpad_key */
        make_report(buf + pos, 0x04, NUMPAD[d]);
        pos += 8;
        /* 松开：Alt only */
        make_report(buf + pos, 0x04, 0x00);
        pos += 8;
    }

    /* 3. 松开所有键（触发 Alt 码输入） */
    make_report(buf + pos, 0x00, 0x00);
    pos += 8;

    return pos;
}

/* 构造控制字符的 HID 报告（按下 + 松开） */
static int build_control(unsigned char *buf, const char *name) {
    unsigned char kc = 0;
    if (!strcmp(name, "enter") || !strcmp(name, "return") || !strcmp(name, "newline"))
        kc = 0x28;  /* KEY_ENTER */
    else if (!strcmp(name, "space"))
        kc = 0x2c;  /* KEY_SPACE */
    else if (!strcmp(name, "tab"))
        kc = 0x2b;  /* KEY_TAB */
    else if (!strcmp(name, "backspace"))
        kc = 0x2a;  /* KEY_BACKSPACE */
    else if (!strcmp(name, "esc") || !strcmp(name, "escape"))
        kc = 0x29;  /* KEY_ESC */
    else
        return 0;

    /* 按下 + 松开 */
    make_report(buf, 0x00, kc);
    make_report(buf + 8, 0x00, 0x00);
    return 16;
}

int main(int argc, char *argv[]) {
    const char *dev = "/dev/hidg0";
    int char_delay_us = 0;   /* 字符间延时（微秒） */
    int verbose = 0;          /* 打印统计信息 */
    int batch_size = 0;       /* 批量大小：0=每字符一次write, >0=每N字符一次write */

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--device") && i + 1 < argc)
            dev = argv[++i];
        else if (!strcmp(argv[i], "--char-delay") && i + 1 < argc)
            char_delay_us = atoi(argv[++i]) * 1000;  /* ms → us */
        else if (!strcmp(argv[i], "--verbose") || !strcmp(argv[i], "-v"))
            verbose = 1;
        else if (!strcmp(argv[i], "--batch") && i + 1 < argc)
            batch_size = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
            fprintf(stderr,
                "hid_writer - 高性能 HID 键盘写入器\n\n"
                "用法: hid_writer [选项] < 指令文件\n\n"
                "选项:\n"
                "  --device PATH    HID 设备路径 (默认: /dev/hidg0)\n"
                "  --char-delay MS  字符间延时毫秒 (默认: 0)\n"
                "  --batch N        批量写入: 每 N 个字符一次 write (默认: 0=关闭)\n"
                "  --verbose, -v    打印速度统计到 stderr\n"
                "  --help, -h       显示帮助\n\n"
                "输入格式 (stdin, 每行一条):\n"
                "  code 54992       Alt 码输入一个字符\n"
                "  control enter    控制字符 (enter/space/tab/backspace/esc)\n");
            return 0;
        }
    }

    /* 打开 HID 设备（FD 常驻） */
    int fd = open(dev, O_WRONLY);
    if (fd < 0) {
        perror("open");
        fprintf(stderr, "无法打开设备: %s\n", dev);
        return 1;
    }

    /* 批量缓冲区 */
    unsigned char *batch_buf = NULL;
    int batch_pos = 0;
    int batch_count = 0;
    if (batch_size > 0) {
        /* 每个字符最多 128 字节（16 个报告，足够 7 位 Alt 码） */
        batch_buf = malloc(batch_size * 128);
        if (!batch_buf) {
            perror("malloc");
            close(fd);
            return 1;
        }
    }

    unsigned char buf[128];
    char line[256];
    int total = 0;
    struct timespec t_start, t_end;
    clock_gettime(CLOCK_MONOTONIC, &t_start);

    while (fgets(line, sizeof(line), stdin)) {
        /* 去除换行符 */
        line[strcspn(line, "\r\n")] = 0;
        if (line[0] == 0) continue;

        int len = 0;
        if (!strncmp(line, "code ", 5)) {
            int code = atoi(line + 5);
            len = build_alt_code(buf, code);
        } else if (!strncmp(line, "control ", 8)) {
            len = build_control(buf, line + 8);
        }

        if (len <= 0) continue;
        total++;

        if (batch_buf) {
            /* 批量模式：累积到缓冲区 */
            memcpy(batch_buf + batch_pos, buf, len);
            batch_pos += len;
            batch_count++;
            if (batch_count >= batch_size) {
                ssize_t n = write(fd, batch_buf, batch_pos);
                if (n < 0 && verbose) perror("write");
                batch_pos = 0;
                batch_count = 0;
            }
        } else {
            /* 逐字符模式：直接 write */
            ssize_t n = write(fd, buf, len);
            if (n < 0 && verbose) perror("write");
        }

        /* 字符间延时（批量模式下由内核排队，延时影响较小） */
        if (char_delay_us > 0)
            usleep(char_delay_us);
    }

    /* 刷新批量缓冲区剩余内容 */
    if (batch_buf && batch_pos > 0) {
        ssize_t n = write(fd, batch_buf, batch_pos);
        if (n < 0 && verbose) perror("write");
    }

    /* 确保最后一个报告被发送 */
    fsync(fd);

    clock_gettime(CLOCK_MONOTONIC, &t_end);
    double elapsed_ms = (t_end.tv_sec - t_start.tv_sec) * 1000.0 +
                        (t_end.tv_nsec - t_start.tv_nsec) / 1000000.0;

    if (verbose) {
        fprintf(stderr, "hid_writer: %d 字符, 耗时 %.1f ms, 速度 %.1f 字/秒\n",
                total, elapsed_ms,
                total > 0 ? total * 1000.0 / elapsed_ms : 0);
    }

    if (batch_buf) free(batch_buf);
    close(fd);
    return 0;
}

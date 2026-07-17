/*
 * hid_writer.c - 高性能 HID 键盘写入器（原生 C）
 *
 * 用途：替代 shell 的 printf > /dev/hidg0，大幅减少每字符的开销
 *
 * 核心优化：
 *   1. 直接 write() 系统调用，无 shell 解释器开销（~5ms/字符 → ~0.01ms/字符）
 *   2. FD 常驻（open 一次），避免每次 write 都 open/close 设备
 *   3. 二进制构造报告，无 printf \x 转义开销
 *
 * 重要：USB HID 报告传输受 bInterval 限制（默认 8ms/报告）
 *   - write() 非阻塞：内核把数据拷贝到 EP buffer 后立即返回
 *   - 但 USB host 实际轮询消费需要 8ms/报告
 *   - 一个 4 位 Alt 码 = 10 个报告 = 80ms USB 传输时间
 *   - 必须等待上一个字符的 release_all 被消费后才能发送下一个字符的 press_alt
 *   - 否则 EP buffer 队列会混乱，导致 Alt 键卡住
 *
 * 输入格式（stdin，每行一条指令）：
 *   code 54992        - 通过 Alt 码输入一个字符
 *   control enter     - 输入控制字符（enter/space/tab/backspace/esc）
 *
 * 用法：
 *   hid_writer --device /dev/hidg0 --char-delay 0 --report-delay 8 --verbose
 *
 * 编译（WSL 交叉编译）：
 *   arm-linux-gnueabihf-gcc -static -O2 -s -o hid_writer hid_writer.c
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

/* 构造一个 8 字节 HID 报告 */
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
 * 返回写入 buf 的字节数和报告数（通过 *out_reports）
 */
static int build_alt_code(unsigned char *buf, int code, int *out_reports) {
    int pos = 0;
    int reports = 0;
    char digits[16];
    int ndigits = snprintf(digits, sizeof(digits), "%d", code);
    if (ndigits <= 0) return 0;

    /* 1. 按下 Alt（modifier=0x04） */
    make_report(buf + pos, 0x04, 0x00);
    pos += 8; reports++;

    /* 2. 每个数字：按下 + 松开（Alt 保持） */
    for (int i = 0; i < ndigits; i++) {
        int d = digits[i] - '0';
        if (d < 0 || d > 9) continue;
        make_report(buf + pos, 0x04, NUMPAD[d]);
        pos += 8; reports++;
        make_report(buf + pos, 0x04, 0x00);
        pos += 8; reports++;
    }

    /* 3. 松开所有键（触发 Alt 码输入） */
    make_report(buf + pos, 0x00, 0x00);
    pos += 8; reports++;

    if (out_reports) *out_reports = reports;
    return pos;
}

/* 构造控制字符的 HID 报告（按下 + 松开） */
static int build_control(unsigned char *buf, const char *name, int *out_reports) {
    unsigned char kc = 0;
    if (!strcmp(name, "enter") || !strcmp(name, "return") || !strcmp(name, "newline"))
        kc = 0x28;
    else if (!strcmp(name, "space"))
        kc = 0x2c;
    else if (!strcmp(name, "tab"))
        kc = 0x2b;
    else if (!strcmp(name, "backspace"))
        kc = 0x2a;
    else if (!strcmp(name, "esc") || !strcmp(name, "escape"))
        kc = 0x29;
    else
        return 0;

    make_report(buf, 0x00, kc);
    make_report(buf + 8, 0x00, 0x00);
    if (out_reports) *out_reports = 2;
    return 16;
}

int main(int argc, char *argv[]) {
    const char *dev = "/dev/hidg0";
    int char_delay_us = 0;   /* 字符间延时（微秒），用户自定义防乱码 */
    int report_delay_us = 8000; /* 每个报告间延时，默认 8ms（匹配 bInterval=4） */
    int verbose = 0;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--device") && i + 1 < argc)
            dev = argv[++i];
        else if (!strcmp(argv[i], "--char-delay") && i + 1 < argc)
            char_delay_us = atoi(argv[++i]) * 1000;
        else if (!strcmp(argv[i], "--report-delay") && i + 1 < argc)
            report_delay_us = atoi(argv[++i]) * 1000;
        else if (!strcmp(argv[i], "--verbose") || !strcmp(argv[i], "-v"))
            verbose = 1;
        else if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
            fprintf(stderr,
                "hid_writer - 高性能 HID 键盘写入器\n\n"
                "用法: hid_writer [选项] < 指令文件\n\n"
                "选项:\n"
                "  --device PATH       HID 设备路径 (默认: /dev/hidg0)\n"
                "  --char-delay MS     字符间延时毫秒 (默认: 0)\n"
                "  --report-delay MS   报告间延时毫秒 (默认: 8, 匹配 USB bInterval)\n"
                "                     设为 0 可能导致 Alt 键卡住\n"
                "  --verbose, -v       打印速度统计到 stderr\n"
                "  --help, -h          显示帮助\n\n"
                "输入格式 (stdin, 每行一条):\n"
                "  code 54992          Alt 码输入一个字符\n"
                "  control enter       控制字符 (enter/space/tab/backspace/esc)\n");
            return 0;
        }
    }

    int fd = open(dev, O_WRONLY);
    if (fd < 0) {
        perror("open");
        fprintf(stderr, "无法打开设备: %s\n", dev);
        return 1;
    }

    unsigned char buf[128];
    char line[256];
    int total = 0;
    struct timespec t_start, t_end;
    clock_gettime(CLOCK_MONOTONIC, &t_start);

    while (fgets(line, sizeof(line), stdin)) {
        line[strcspn(line, "\r\n")] = 0;
        if (line[0] == 0) continue;

        int reports = 0;
        int len = 0;
        if (!strncmp(line, "code ", 5)) {
            int code = atoi(line + 5);
            len = build_alt_code(buf, code, &reports);
        } else if (!strncmp(line, "control ", 8)) {
            len = build_control(buf, line + 8, &reports);
        }

        if (len <= 0) continue;
        total++;

        /* 逐个报告发送，每个报告后等待 USB 传输
         * 这是关键：write() 非阻塞返回，但 USB host 需要 bInterval 时间消费
         * 如果连续 write，EP buffer 队列会堆积，导致报告顺序混乱
         */
        for (int r = 0; r < reports; r++) {
            ssize_t n = write(fd, buf + r * 8, 8);
            if (n < 0 && verbose) perror("write");
            if (report_delay_us > 0)
                usleep(report_delay_us);
        }

        /* 字符间延时（用户自定义防乱码） */
        if (char_delay_us > 0)
            usleep(char_delay_us);
    }

    clock_gettime(CLOCK_MONOTONIC, &t_end);
    double elapsed_ms = (t_end.tv_sec - t_start.tv_sec) * 1000.0 +
                        (t_end.tv_nsec - t_start.tv_nsec) / 1000000.0;

    if (verbose) {
        fprintf(stderr, "hid_writer: %d 字符, 耗时 %.1f ms, 速度 %.1f 字/秒\n",
                total, elapsed_ms,
                total > 0 ? total * 1000.0 / elapsed_ms : 0);
    }

    close(fd);
    return 0;
}


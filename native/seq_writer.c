/*
 * seq_writer.c - HID 键鼠序列执行器（AI 自动化通道 :8849）
 *
 * 从 stdin 读取纯文本行协议，逐条翻译为 HID 报告写入：
 *   键盘 → /dev/hidgN（8 字节 boot 报告）
 *   鼠标 → /dev/hidgM（默认 4 字节 boot 报告，可配 --mouse-report-size）
 *
 * 设计原则：设备端只做哑执行。文本→Alt 码、绝对坐标→相对位移、组合键展开
 * 全部由 PC 端 MCP 服务器完成；本程序不解析 JSON、不维护业务状态。
 *
 * 行协议（每行一条，# 开头为注释）：
 *   kbdset <mods> [kc...]   设置键盘报告状态（最多 6 键）
 *   tap <mods> [kc...]      组合键单击：按下 → 释放按键 → 释放修饰键
 *   down <mods> [kc...]     kbdset 别名（按住）
 *   up <mods>               释放所有按键，保留修饰键
 *   code <n>                Alt 码输入一个字符（复用 hid_writer 序列）
 *   control <name>          enter/space/tab/backspace/esc
 *   mmove <dx> <dy>         相对移动（-127..127，保持按键状态）
 *   mbtn <mask>             按键状态：0=全松 1=左 2=右 4=中
 *   mclick <btn>            单击（按下 → 40ms → 松开）
 *   mdclick <btn>           双击
 *   wheel <dy> [dx]         滚轮（dy 正=向上）
 *   mabs <x> <y>            绝对坐标（0..32767，需 --mouse-absolute）
 *   wait <ms>               等待（1..60000）
 *   step <n>                写 step 进度文件（高层动作索引）
 *   kbd <hex...>            原始键盘报告（不足 8 字节补零）
 *   mse <hex...>            原始鼠标报告
 *
 * mods 为 HID modifier 位掩码：bit0=LCtrl 1=LShift 2=LAlt 3=LGui
 * 4=RCtrl 5=RShift 6=RAlt 7=RGui；kc 为 USB HID usage 十进制。
 *
 * 用法：
 *   seq_writer --kbd /dev/hidg0 --mouse /dev/hidg1 \
 *              --report-delay 8 --stop-file ... --pause-file ... \
 *              --progress-file ... --step-file ... --verbose < seq.txt
 *
 * 行为对齐 hid_writer：报告间默认 8ms（USB bInterval），行边界检查
 * 停止/暂停，退出前释放全部按键与鼠标按钮。
 *
 * 编译（WSL 交叉编译）：
 *   arm-linux-gnueabihf-gcc -static -O2 -s -o seq_writer seq_writer.c
 *
 * 注：make_report/build_alt_code/build_control/wait_ready/save_progress
 * 源自 hid_writer.c（同仓库），保持报告序列与 Alt 码时序一致。
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <errno.h>
#include <limits.h>

/* Numpad 0-9 HID keycodes（与 hid_writer 一致） */
static const unsigned char NUMPAD[10] = {
    0x62, 0x59, 0x5a, 0x5b, 0x5c, 0x5d, 0x5e, 0x5f, 0x60, 0x61
};

static int g_kbd_fd = -1;
static int g_mouse_fd = -1;
static const char *g_mouse_dev = NULL;
static int g_mouse_report_size = 4;
static int g_mouse_absolute = 0;
static unsigned char g_mouse_buttons = 0;
static int g_report_delay_us = 8000;
static int g_verbose = 0;
static long g_reports = 0;
static long g_lines = 0;

/* ---------- 报告构造 ---------- */

static void make_report(unsigned char *r, unsigned char mod, const unsigned char *kcs, int nkc) {
    memset(r, 0, 8);
    r[0] = mod;
    for (int i = 0; i < nkc && i < 6; i++) r[2 + i] = kcs[i];
}

/* Alt 码字符的完整报告序列：press_alt + N×(digit↓+digit↑) + release_all */
static int build_alt_code(unsigned char *buf, int code, int *out_reports) {
    int pos = 0, reports = 0;
    char digits[16];
    int ndigits = snprintf(digits, sizeof(digits), "%d", code);
    if (ndigits <= 0) return 0;

    make_report(buf + pos, 0x04, NULL, 0); pos += 8; reports++;      /* Alt 按下 */
    for (int i = 0; i < ndigits; i++) {
        int d = digits[i] - '0';
        if (d < 0 || d > 9) continue;
        unsigned char kc = NUMPAD[d];
        make_report(buf + pos, 0x04, &kc, 1); pos += 8; reports++;   /* 数字按下 */
        make_report(buf + pos, 0x04, NULL, 0); pos += 8; reports++;  /* 数字松开 */
    }
    make_report(buf + pos, 0x00, NULL, 0); pos += 8; reports++;      /* 全部松开 */
    if (out_reports) *out_reports = reports;
    return pos;
}

static int build_control(unsigned char *buf, const char *name, int *out_reports) {
    unsigned char kc;
    if (!strcmp(name, "enter") || !strcmp(name, "return") || !strcmp(name, "newline")) kc = 0x28;
    else if (!strcmp(name, "space")) kc = 0x2c;
    else if (!strcmp(name, "tab")) kc = 0x2b;
    else if (!strcmp(name, "backspace")) kc = 0x2a;
    else if (!strcmp(name, "esc") || !strcmp(name, "escape")) kc = 0x29;
    else if (!strcmp(name, "delete") || !strcmp(name, "del")) kc = 0x4c;
    else return 0;

    make_report(buf, 0x00, &kc, 1);
    make_report(buf + 8, 0x00, NULL, 0);
    if (out_reports) *out_reports = 2;
    return 16;
}

/* 构造鼠标报告：boot 协议 [buttons, dx, dy, wheel, hwheel...] */
static void make_mouse_report(unsigned char *r, int dx, int dy, int wheel, int hwheel) {
    memset(r, 0, g_mouse_report_size);
    r[0] = g_mouse_buttons;
    r[1] = (unsigned char)(signed char)dx;
    r[2] = (unsigned char)(signed char)dy;
    if (g_mouse_report_size > 3) r[3] = (unsigned char)(signed char)wheel;
    if (g_mouse_report_size > 4) r[4] = (unsigned char)(signed char)hwheel;
}

/* 绝对鼠标报告：buttons, x_lo, x_hi, y_lo, y_hi, wheel（5 字节起） */
static void make_mouse_abs(unsigned char *r, int x, int y) {
    memset(r, 0, g_mouse_report_size);
    r[0] = g_mouse_buttons;
    r[1] = (unsigned char)(x & 0xff);
    r[2] = (unsigned char)((x >> 8) & 0xff);
    r[3] = (unsigned char)(y & 0xff);
    r[4] = (unsigned char)((y >> 8) & 0xff);
}

/* ---------- IO ---------- */

static int clamp127(int v) {
    if (v > 127) return 127;
    if (v < -127) return -127;
    return v;
}

static int write_reports(int fd, const unsigned char *buf, int reports, int size) {
    for (int r = 0; r < reports; r++) {
        ssize_t n = write(fd, buf + r * size, size);
        if (n != size) {
            perror("write");
            return -1;
        }
        g_reports++;
        if (g_report_delay_us > 0) usleep(g_report_delay_us);
    }
    return 0;
}

static int ensure_mouse_open(void) {
    if (g_mouse_fd >= 0) return 0;
    if (!g_mouse_dev || !*g_mouse_dev) {
        fprintf(stderr, "seq_writer: 未配置鼠标设备（缺少 --mouse 参数）\n");
        return -1;
    }
    g_mouse_fd = open(g_mouse_dev, O_WRONLY);
    if (g_mouse_fd < 0) {
        fprintf(stderr, "seq_writer: 无法打开鼠标设备 %s: %s\n", g_mouse_dev, strerror(errno));
        return -1;
    }
    return 0;
}

static int write_mouse(int dx, int dy, int wheel, int hwheel) {
    if (ensure_mouse_open() != 0) return -1;
    unsigned char rep[16];
    make_mouse_report(rep, dx, dy, wheel, hwheel);
    return write_reports(g_mouse_fd, rep, 1, g_mouse_report_size);
}

static int write_mouse_abs(int x, int y) {
    if (ensure_mouse_open() != 0) return -1;
    unsigned char rep[16];
    make_mouse_abs(rep, x, y);
    return write_reports(g_mouse_fd, rep, 1, g_mouse_report_size);
}

/* 行边界检查停止/暂停（暂停时阻塞，保证报告不撕裂） */
static int wait_ready(const char *stop_file, const char *pause_file) {
    for (;;) {
        if (stop_file && access(stop_file, F_OK) == 0) return 0;
        if (!pause_file || access(pause_file, F_OK) != 0) return 1;
        usleep(10000);
    }
}

/* 让 wait 指令也能响应 stop，避免长等待期间只能靠 abort */
static int wait_ms_interruptible(int ms, const char *stop_file) {
    int elapsed = 0;
    while (elapsed < ms) {
        if (stop_file && access(stop_file, F_OK) == 0) return 0;
        int slice = (ms - elapsed) > 20 ? 20 : (ms - elapsed);
        usleep((useconds_t)slice * 1000);
        elapsed += slice;
    }
    return 1;
}

static void save_progress(int fd, long total) {
    if (fd < 0) return;
    char value[32];
    int len = snprintf(value, sizeof(value), "%ld\n", total);
    lseek(fd, 0, SEEK_SET);
    if (write(fd, value, len) == len && ftruncate(fd, len) < 0) perror("progress truncate");
}

static void save_step(int fd, int step) {
    if (fd < 0) return;
    char value[32];
    int len = snprintf(value, sizeof(value), "%d\n", step);
    lseek(fd, 0, SEEK_SET);
    if (write(fd, value, len) == len && ftruncate(fd, len) < 0) perror("step truncate");
}

static void record_error(const char *error_file, const char *msg) {
    if (!error_file) return;
    int fd = open(error_file, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) return;
    if (write(fd, msg, strlen(msg)) < 0) { /* 尽力而为，无日志通道可报 */ }
    close(fd);
}

/* ---------- 解析辅助 ---------- */

/* 拆分参数，返回 token 数（就地写入 tok，最多 max） */
static int tokenize(char *line, char *tok[], int max) {
    int n = 0;
    char *p = line;
    while (*p && n < max) {
        while (*p == ' ' || *p == '\t') p++;
        if (!*p) break;
        tok[n++] = p;
        while (*p && *p != ' ' && *p != '\t') p++;
        if (*p) *p++ = 0;
    }
    return n;
}

static int parse_hex_report(const char *const *tok, int ntok, unsigned char *out, int max) {
    int n = 0;
    for (int i = 0; i < ntok && n < max; i++) {
        char *end = NULL;
        long v = strtol(tok[i], &end, 16);
        if (end == tok[i] || v < 0 || v > 255) return -1;
        out[n++] = (unsigned char)v;
    }
    return n;
}

/* ---------- 主循环 ---------- */

int main(int argc, char *argv[]) {
    const char *kbd_dev = "/dev/hidg0";
    const char *stop_file = NULL;
    const char *pause_file = NULL;
    const char *progress_file = NULL;
    const char *step_file = NULL;
    const char *error_file = NULL;
    int char_delay_us = 0;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--kbd") && i + 1 < argc) kbd_dev = argv[++i];
        else if (!strcmp(argv[i], "--mouse") && i + 1 < argc) g_mouse_dev = argv[++i];
        else if (!strcmp(argv[i], "--mouse-report-size") && i + 1 < argc) g_mouse_report_size = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--mouse-absolute")) g_mouse_absolute = 1;
        else if (!strcmp(argv[i], "--char-delay") && i + 1 < argc) char_delay_us = atoi(argv[++i]) * 1000;
        else if (!strcmp(argv[i], "--report-delay") && i + 1 < argc) g_report_delay_us = atoi(argv[++i]) * 1000;
        else if (!strcmp(argv[i], "--stop-file") && i + 1 < argc) stop_file = argv[++i];
        else if (!strcmp(argv[i], "--pause-file") && i + 1 < argc) pause_file = argv[++i];
        else if (!strcmp(argv[i], "--progress-file") && i + 1 < argc) progress_file = argv[++i];
        else if (!strcmp(argv[i], "--step-file") && i + 1 < argc) step_file = argv[++i];
        else if (!strcmp(argv[i], "--error-file") && i + 1 < argc) error_file = argv[++i];
        else if (!strcmp(argv[i], "--verbose") || !strcmp(argv[i], "-v")) g_verbose = 1;
        else if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
            fprintf(stderr,
                "seq_writer - HID 键鼠序列执行器\n\n"
                "用法: seq_writer [选项] < 序列文件\n\n"
                "选项:\n"
                "  --kbd PATH              键盘设备 (默认 /dev/hidg0)\n"
                "  --mouse PATH            鼠标设备 (默认不打开，遇到鼠标指令时才打开)\n"
                "  --mouse-report-size N   鼠标报告长度 (默认 4)\n"
                "  --mouse-absolute        绝对坐标鼠标 gadget (mabs 指令)\n"
                "  --char-delay MS         字符间延时 (默认 0)\n"
                "  --report-delay MS       报告间延时 (默认 8)\n"
                "  --stop-file PATH        行边界检查，文件存在则停止\n"
                "  --pause-file PATH       文件存在时暂停\n"
                "  --progress-file PATH    已执行行数\n"
                "  --step-file PATH        当前 step 编号\n"
                "  --error-file PATH       错误信息\n"
                "  --verbose, -v           输出统计\n"
                "  --help, -h              帮助\n\n"
                "行协议见源码头部注释。\n");
            return 0;
        }
    }

    if (g_mouse_report_size < 3) g_mouse_report_size = 4;
    if (g_mouse_report_size > 16) g_mouse_report_size = 16;

    g_kbd_fd = open(kbd_dev, O_WRONLY);
    if (g_kbd_fd < 0) {
        perror("open kbd");
        fprintf(stderr, "seq_writer: 无法打开键盘设备: %s\n", kbd_dev);
        return 1;
    }

    int progress_fd = progress_file ? open(progress_file, O_WRONLY | O_CREAT | O_TRUNC, 0600) : -1;
    int step_fd = step_file ? open(step_file, O_WRONLY | O_CREAT | O_TRUNC, 0600) : -1;
    save_progress(progress_fd, 0);
    save_step(step_fd, -1);
    if (error_file) unlink(error_file);

    char line[1024];
    int exit_code = 0;
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);

    while (fgets(line, sizeof(line), stdin)) {
        if (!wait_ready(stop_file, pause_file)) { exit_code = 130; break; }
        line[strcspn(line, "\r\n")] = 0;

        char *tok[10];
        int ntok = tokenize(line, tok, 10);
        if (ntok == 0 || tok[0][0] == '#') continue;

        const char *cmd = tok[0];
        int rc = 0;

        if (!strcmp(cmd, "kbdset") || !strcmp(cmd, "down")) {
            if (ntok < 2) { record_error(error_file, "kbdset: missing mods"); exit_code = 3; break; }
            int mods = atoi(tok[1]);
            unsigned char kcs[6];
            int nkc = 0;
            for (int i = 2; i < ntok && nkc < 6; i++) kcs[nkc++] = (unsigned char)atoi(tok[i]);
            unsigned char rep[8];
            make_report(rep, (unsigned char)mods, kcs, nkc);
            rc = write_reports(g_kbd_fd, rep, 1, 8);

        } else if (!strcmp(cmd, "up")) {
            int mods = ntok > 1 ? atoi(tok[1]) : 0;
            unsigned char rep[8];
            make_report(rep, (unsigned char)mods, NULL, 0);
            rc = write_reports(g_kbd_fd, rep, 1, 8);

        } else if (!strcmp(cmd, "tap")) {
            if (ntok < 2) { record_error(error_file, "tap: missing mods"); exit_code = 3; break; }
            int mods = atoi(tok[1]);
            unsigned char kcs[6];
            int nkc = 0;
            for (int i = 2; i < ntok && nkc < 6; i++) kcs[nkc++] = (unsigned char)atoi(tok[i]);
            unsigned char rep[8];
            make_report(rep, (unsigned char)mods, kcs, nkc);
            rc = write_reports(g_kbd_fd, rep, 1, 8);
            if (rc == 0) {
                make_report(rep, (unsigned char)mods, NULL, 0);   /* 释放按键，保留修饰键 */
                rc = write_reports(g_kbd_fd, rep, 1, 8);
            }
            if (rc == 0) {
                make_report(rep, 0, NULL, 0);                     /* 释放修饰键 */
                rc = write_reports(g_kbd_fd, rep, 1, 8);
            }

        } else if (!strcmp(cmd, "code")) {
            if (ntok < 2) { record_error(error_file, "code: missing value"); exit_code = 3; break; }
            unsigned char buf[128];
            int reports = 0;
            int len = build_alt_code(buf, atoi(tok[1]), &reports);
            if (len <= 0) { record_error(error_file, "code: invalid value"); exit_code = 3; break; }
            rc = write_reports(g_kbd_fd, buf, reports, 8);

        } else if (!strcmp(cmd, "control")) {
            if (ntok < 2) { record_error(error_file, "control: missing name"); exit_code = 3; break; }
            unsigned char buf[16];
            int reports = 0;
            int len = build_control(buf, tok[1], &reports);
            if (len <= 0) { record_error(error_file, "control: unknown key"); exit_code = 3; break; }
            rc = write_reports(g_kbd_fd, buf, reports, 8);

        } else if (!strcmp(cmd, "mmove")) {
            if (ntok < 3) { record_error(error_file, "mmove: need dx dy"); exit_code = 3; break; }
            int dx = clamp127(atoi(tok[1])), dy = clamp127(atoi(tok[2]));
            rc = write_mouse(dx, dy, 0, 0);

        } else if (!strcmp(cmd, "mbtn")) {
            if (ntok < 2) { record_error(error_file, "mbtn: missing mask"); exit_code = 3; break; }
            g_mouse_buttons = (unsigned char)atoi(tok[1]);
            rc = write_mouse(0, 0, 0, 0);

        } else if (!strcmp(cmd, "mclick") || !strcmp(cmd, "mdclick")) {
            int btn = ntok > 1 ? atoi(tok[1]) : 1;
            int clicks = !strcmp(cmd, "mdclick") ? 2 : 1;
            for (int c = 0; c < clicks && rc == 0; c++) {
                g_mouse_buttons = (unsigned char)btn;
                rc = write_mouse(0, 0, 0, 0);
                if (rc == 0) usleep(40000);
                g_mouse_buttons = 0;
                rc = write_mouse(0, 0, 0, 0);
                if (rc == 0 && c + 1 < clicks) usleep(40000);
            }

        } else if (!strcmp(cmd, "wheel")) {
            if (ntok < 2) { record_error(error_file, "wheel: need dy"); exit_code = 3; break; }
            int dy = clamp127(atoi(tok[1]));
            int dx = clamp127(ntok > 2 ? atoi(tok[2]) : 0);
            rc = write_mouse(0, 0, dy, dx);

        } else if (!strcmp(cmd, "mabs")) {
            if (!g_mouse_absolute) { record_error(error_file, "mabs: mouse not in absolute mode"); exit_code = 3; break; }
            if (ntok < 3) { record_error(error_file, "mabs: need x y"); exit_code = 3; break; }
            rc = write_mouse_abs(atoi(tok[1]), atoi(tok[2]));

        } else if (!strcmp(cmd, "wait")) {
            int ms = ntok > 1 ? atoi(tok[1]) : 0;
            if (ms < 0) ms = 0;
            if (ms > 60000) ms = 60000;
            if (!wait_ms_interruptible(ms, stop_file)) { exit_code = 130; break; }

        } else if (!strcmp(cmd, "step")) {
            save_step(step_fd, ntok > 1 ? atoi(tok[1]) : 0);

        } else if (!strcmp(cmd, "kbd")) {
            unsigned char rep[8];
            int n = parse_hex_report((const char *const *)(tok + 1), ntok - 1, rep, 8);
            if (n < 0) { record_error(error_file, "kbd: invalid hex"); exit_code = 3; break; }
            for (int i = n; i < 8; i++) rep[i] = 0;
            rc = write_reports(g_kbd_fd, rep, 1, 8);

        } else if (!strcmp(cmd, "mse")) {
            unsigned char rep[16];
            memset(rep, 0, sizeof(rep));
            int n = parse_hex_report((const char *const *)(tok + 1), ntok - 1, rep, g_mouse_report_size);
            if (n < 0) { record_error(error_file, "mse: invalid hex"); exit_code = 3; break; }
            if (g_mouse_fd < 0) {
                g_mouse_fd = open(g_mouse_dev, O_WRONLY);
                if (g_mouse_fd < 0) { rc = -1; }
            }
            if (rc == 0) rc = write_reports(g_mouse_fd, rep, 1, g_mouse_report_size);

        } else {
            char msg[128];
            snprintf(msg, sizeof(msg), "unknown command: %s", cmd);
            record_error(error_file, msg);
            fprintf(stderr, "seq_writer: %s\n", msg);
            exit_code = 3;
            break;
        }

        if (rc != 0) { exit_code = 1; break; }

        g_lines++;
        save_progress(progress_fd, g_lines);
        if (char_delay_us > 0) usleep(char_delay_us);
    }

    /* 退出前释放所有按键与鼠标按钮（避免目标机卡键） */
    if (g_kbd_fd >= 0) {
        unsigned char zero[8] = {0};
        if (write(g_kbd_fd, zero, 8) != 8) exit_code = exit_code ? exit_code : 1;
    }
    if (g_mouse_fd >= 0) {
        unsigned char zero[16];
        memset(zero, 0, sizeof(zero));
        if (write(g_mouse_fd, zero, g_mouse_report_size) != (ssize_t)g_mouse_report_size)
            exit_code = exit_code ? exit_code : 1;
    }

    clock_gettime(CLOCK_MONOTONIC, &t1);
    double elapsed_ms = (t1.tv_sec - t0.tv_sec) * 1000.0 + (t1.tv_nsec - t0.tv_nsec) / 1000000.0;
    if (g_verbose) {
        fprintf(stderr, "seq_writer: %ld 行, %ld 报告, 耗时 %.1f ms\n",
                g_lines, g_reports, elapsed_ms);
    }

    if (progress_fd >= 0) close(progress_fd);
    if (step_fd >= 0) close(step_fd);
    if (g_mouse_fd >= 0) close(g_mouse_fd);
    close(g_kbd_fd);
    return exit_code;
}

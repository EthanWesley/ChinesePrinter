/*
 * capture.c - Luckfox Pico KVM HDMI 单帧抓取（V4L2 → JPEG）
 *
 * 用途：为 AI 自动化通道（:8849 /capture）提供目标机屏幕截图。
 *
 * 策略：
 *   1. 优先使用 MJPEG：采集芯片（MS2130 类）原生输出 JPEG，直接截取
 *      SOI(FFD8)..EOI(FFD9) 直通，不解码、不缩放、不重编码（弱 CPU 最快路径）。
 *   2. 回退 YUYV：libjpeg-turbo 以 4:2:2 原始数据直接编码
 *      （jpeg_write_raw_data，跳过 RGB 转换）。需 -DHAVE_LIBJPEG 编译。
 *
 * 用法：
 *   capture --output /tmp/frame.jpg [--device /dev/video0] [--warmup 3]
 *           [--quality 85] [--timeout 5000]
 *   capture --probe            # 枚举 /dev/video0..3 的能力，输出 JSON
 *
 * 编译（WSL 交叉编译，见 native/build.sh）：
 *   arm-linux-gnueabihf-gcc -static -O2 -s -o capture capture.c libjpeg.a -DHAVE_LIBJPEG
 *   arm-linux-gnueabihf-gcc -static -O2 -s -o capture capture.c          # 仅 MJPEG
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <linux/videodev2.h>

#ifdef HAVE_LIBJPEG
#include <jpeglib.h>
#endif

#define MAX_BUFFERS 4
#define DEFAULT_OUT "/tmp/chinese-printer/auto_frame.jpg"

struct buffer {
    void *start;
    size_t length;
};

static int xioctl(int fd, unsigned long req, void *arg) {
    int r;
    do { r = ioctl(fd, req, arg); } while (r == -1 && errno == EINTR);
    return r;
}

/* 打开设备并确认具备视频采集能力 */
static int open_capture(const char *dev, int verbose) {
    int fd = open(dev, O_RDWR | O_NONBLOCK, 0);
    if (fd < 0) return -1;

    struct v4l2_capability cap;
    memset(&cap, 0, sizeof(cap));
    if (xioctl(fd, VIDIOC_QUERYCAP, &cap) < 0) {
        close(fd);
        return -1;
    }
    if (!(cap.capabilities & V4L2_CAP_VIDEO_CAPTURE) &&
        !(cap.capabilities & V4L2_CAP_VIDEO_CAPTURE_MPLANE)) {
        close(fd);
        return -1;
    }
    if (!(cap.capabilities & V4L2_CAP_STREAMING)) {
        close(fd);
        return -1;
    }
    if (verbose) {
        fprintf(stderr, "capture: 设备 %s = %s (%s)\n",
                dev, (const char *)cap.card, (const char *)cap.driver);
    }
    return fd;
}

/* 自动探测第一个可用的采集设备 */
static int find_device(char *out, size_t n) {
    for (int i = 0; i < 4; i++) {
        snprintf(out, n, "/dev/video%d", i);
        int fd = open_capture(out, 0);
        if (fd >= 0) { close(fd); return 0; }
    }
    return -1;
}

/* 请求指定像素格式，返回实际生效的宽高；失败返回 -1 */
static int try_format(int fd, unsigned int pixfmt, int *w, int *h) {
    struct v4l2_format fmt;
    memset(&fmt, 0, sizeof(fmt));
    fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (xioctl(fd, VIDIOC_G_FMT, &fmt) < 0) return -1;
    fmt.fmt.pix.pixelformat = pixfmt;
    fmt.fmt.pix.field = V4L2_FIELD_ANY;
    if (xioctl(fd, VIDIOC_S_FMT, &fmt) < 0) return -1;
    if (fmt.fmt.pix.pixelformat != pixfmt) return -1;  /* 驱动拒绝，回落 */
    *w = (int)fmt.fmt.pix.width;
    *h = (int)fmt.fmt.pix.height;
    return 0;
}

/* 在 MJPEG 帧中定位 SOI..EOI，返回有效长度 */
static size_t trim_jpeg(const unsigned char *data, size_t len) {
    size_t start = 0, end = len;
    for (size_t i = 0; i + 1 < len; i++) {
        if (data[i] == 0xFF && data[i + 1] == 0xD8) { start = i; break; }
    }
    /* 从尾部向前找 EOI（帧尾可能有填充字节） */
    for (size_t i = len; i >= start + 2; i--) {
        if (data[i - 2] == 0xFF && data[i - 1] == 0xD9) { end = i; break; }
    }
    if (end <= start) return 0;
    memmove((void *)data, data + start, end - start);
    return end - start;
}

#ifdef HAVE_LIBJPEG
/* YUYV(4:2:2 交织) → JPEG
 * jpeg_write_raw_data 要求按分量提供平面（Y / Cb / Cr），YUYV 必须先解交织。
 * 每行 w 像素：Y0 Cb Y1 Cr …，故 Y 平面 w 字节，Cb/Cr 各 w/2 字节。
 */
static int encode_yuyv(const unsigned char *src, int w, int h, int quality,
                       const char *out_path) {
    struct jpeg_compress_struct cinfo;
    struct jpeg_error_mgr jerr;
    FILE *fp = fopen(out_path, "wb");
    if (!fp) { perror("fopen"); return -1; }

    cinfo.err = jpeg_std_error(&jerr);
    jpeg_create_compress(&cinfo);
    jpeg_stdio_dest(&cinfo, fp);
    cinfo.image_width = (JDIMENSION)w;
    cinfo.image_height = (JDIMENSION)h;
    cinfo.input_components = 3;
    cinfo.in_color_space = JCS_YCbCr;
    jpeg_set_defaults(&cinfo);
    jpeg_set_colorspace(&cinfo, JCS_YCbCr);
    /* YCbCr 4:2:2：Y 全采样，Cb/Cr 水平减半 */
    cinfo.comp_info[0].h_samp_factor = 2;
    cinfo.comp_info[0].v_samp_factor = 1;
    cinfo.comp_info[1].h_samp_factor = 1;
    cinfo.comp_info[1].v_samp_factor = 1;
    cinfo.comp_info[2].h_samp_factor = 1;
    cinfo.comp_info[2].v_samp_factor = 1;
    jpeg_set_quality(&cinfo, quality, TRUE);
    /* 使用 jpeg_write_raw_data 必须先声明 raw 输入，否则状态机只接受 scanlines */
    cinfo.raw_data_in = TRUE;
    jpeg_start_compress(&cinfo, TRUE);

    int row_group = cinfo.max_v_samp_factor * DCTSIZE;   /* 每批行数（4:2:2 为 8） */
    int cw = w / 2;                                     /* 色度平面宽度 */
    size_t row_bytes = (size_t)w * 2;                   /* YUYV 每行字节数 */

    unsigned char *yp = malloc((size_t)row_group * (size_t)w);
    unsigned char *cbp = malloc((size_t)row_group * (size_t)cw);
    unsigned char *crp = malloc((size_t)row_group * (size_t)cw);
    JSAMPROW yrows[16], cbrows[16], crrows[16];
    JSAMPARRAY img[3] = { yrows, cbrows, crrows };
    if (!yp || !cbp || !crp) {
        free(yp); free(cbp); free(crp);
        jpeg_destroy_compress(&cinfo);
        fclose(fp);
        return -1;
    }

    while (cinfo.next_scanline < cinfo.image_height) {
        int rows = row_group;
        if (rows > (int)(cinfo.image_height - cinfo.next_scanline))
            rows = (int)(cinfo.image_height - cinfo.next_scanline);

        for (int r = 0; r < rows; r++) {
            const unsigned char *s = src + ((size_t)cinfo.next_scanline + r) * row_bytes;
            unsigned char *y = yp + (size_t)r * w;
            unsigned char *cb = cbp + (size_t)r * cw;
            unsigned char *cr = crp + (size_t)r * cw;
            for (int x = 0; x < cw; x++) {
                y[2 * x]     = s[4 * x];
                cb[x]        = s[4 * x + 1];
                y[2 * x + 1] = s[4 * x + 2];
                cr[x]        = s[4 * x + 3];
            }
            yrows[r] = y;
            cbrows[r] = cb;
            crrows[r] = cr;
        }
        jpeg_write_raw_data(&cinfo, img, rows);
    }

    free(yp); free(cbp); free(crp);
    jpeg_finish_compress(&cinfo);
    jpeg_destroy_compress(&cinfo);
    fclose(fp);
    return 0;
}
#endif

struct frame_info {
    int width;
    int height;
    int mjpeg;
};

/* 抓取一帧：返回 0 成功（JPEG 已写入 out_path） */
static int grab_frame(int fd, const char *out_path,
                      int warmup, int quality, int timeout_ms, int verbose,
                      struct frame_info *info) {
    int w = 0, h = 0;
    int is_mjpeg = 0;

    if (try_format(fd, V4L2_PIX_FMT_MJPEG, &w, &h) == 0) {
        is_mjpeg = 1;
    } else if (try_format(fd, V4L2_PIX_FMT_YUYV, &w, &h) == 0) {
        is_mjpeg = 0;
    } else {
        fprintf(stderr, "capture: 设备不支持 MJPEG/YUYV\n");
        return -1;
    }
    if (info) {
        info->width = w;
        info->height = h;
        info->mjpeg = is_mjpeg;
    }
    if (verbose)
        fprintf(stderr, "capture: 格式 %s %dx%d\n", is_mjpeg ? "MJPEG" : "YUYV", w, h);

    struct v4l2_requestbuffers req;
    memset(&req, 0, sizeof(req));
    req.count = MAX_BUFFERS;
    req.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    req.memory = V4L2_MEMORY_MMAP;
    if (xioctl(fd, VIDIOC_REQBUFS, &req) < 0 || req.count < 1) {
        perror("VIDIOC_REQBUFS");
        return -1;
    }

    struct buffer bufs[MAX_BUFFERS];
    memset(bufs, 0, sizeof(bufs));
    unsigned int nbuf = req.count > MAX_BUFFERS ? MAX_BUFFERS : req.count;
    for (unsigned int i = 0; i < nbuf; i++) {
        struct v4l2_buffer b;
        memset(&b, 0, sizeof(b));
        b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        b.memory = V4L2_MEMORY_MMAP;
        b.index = i;
        if (xioctl(fd, VIDIOC_QUERYBUF, &b) < 0) {
            perror("VIDIOC_QUERYBUF");
            return -1;
        }
        bufs[i].length = b.length;
        bufs[i].start = mmap(NULL, b.length, PROT_READ | PROT_WRITE,
                             MAP_SHARED, fd, b.m.offset);
        if (bufs[i].start == MAP_FAILED) {
            perror("mmap");
            return -1;
        }
        if (xioctl(fd, VIDIOC_QBUF, &b) < 0) {
            perror("VIDIOC_QBUF");
            return -1;
        }
    }

    enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (xioctl(fd, VIDIOC_STREAMON, &type) < 0) {
        perror("VIDIOC_STREAMON");
        return -1;
    }

    /* 丢弃预热帧，等待曝光/自动增益稳定 */
    int need = warmup > 0 ? warmup + 1 : 1;
    unsigned char *frame = NULL;
    size_t frame_len = 0;
    int rc = -1;

    for (int i = 0; i < need; i++) {
        fd_set fds;
        FD_ZERO(&fds);
        FD_SET(fd, &fds);
        struct timeval tv;
        tv.tv_sec = timeout_ms / 1000;
        tv.tv_usec = (timeout_ms % 1000) * 1000;
        int r = select(fd + 1, &fds, NULL, NULL, &tv);
        if (r <= 0) {
            fprintf(stderr, "capture: 等待帧超时 (%d ms)\n", timeout_ms);
            break;
        }

        struct v4l2_buffer b;
        memset(&b, 0, sizeof(b));
        b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        b.memory = V4L2_MEMORY_MMAP;
        if (xioctl(fd, VIDIOC_DQBUF, &b) < 0) {
            if (errno == EAGAIN) { i--; continue; }
            perror("VIDIOC_DQBUF");
            break;
        }

        if (i == need - 1) {
            frame = (unsigned char *)bufs[b.index].start;
            frame_len = b.bytesused;
        }
        if (xioctl(fd, VIDIOC_QBUF, &b) < 0) {
            perror("VIDIOC_QBUF");
            break;
        }
        if (i == need - 1) rc = 0;
    }

    if (rc == 0 && frame && frame_len > 0) {
        if (is_mjpeg) {
            size_t n = trim_jpeg(frame, frame_len);
            if (n == 0) {
                fprintf(stderr, "capture: MJPEG 帧缺少 SOI/EOI\n");
                rc = -1;
            } else {
                FILE *fp = fopen(out_path, "wb");
                if (!fp) { perror("fopen"); rc = -1; }
                else {
                    if (fwrite(frame, 1, n, fp) != n) { perror("fwrite"); rc = -1; }
                    fclose(fp);
                    if (verbose)
                        fprintf(stderr, "capture: 写出 %zu 字节 (MJPEG 直通)\n", n);
                }
            }
        } else {
#ifdef HAVE_LIBJPEG
            if (encode_yuyv(frame, w, h, quality, out_path) == 0) {
                if (verbose)
                    fprintf(stderr, "capture: 写出 %s (YUYV→JPEG q=%d)\n", out_path, quality);
            } else {
                rc = -1;
            }
#else
            fprintf(stderr, "capture: 该设备仅支持 YUYV，但编译时未启用 libjpeg\n");
            rc = -1;
#endif
        }
    }

    xioctl(fd, VIDIOC_STREAMOFF, &type);
    for (unsigned int i = 0; i < nbuf; i++) {
        if (bufs[i].start && bufs[i].start != MAP_FAILED)
            munmap(bufs[i].start, bufs[i].length);
    }
    return rc;
}

#ifdef HAVE_LIBJPEG
/* 自检：生成合成 YUYV 帧并编码，用于在无采集硬件时验证 YUYV→JPEG 路径 */
static int selftest_yuyv(const char *out_path, int quality) {
    int w = 640, h = 360;
    unsigned char *frame = malloc((size_t)w * h * 2);
    if (!frame) return -1;
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x += 2) {
            size_t o = ((size_t)y * w + x) * 2;
            unsigned char luma = (unsigned char)(x * 255 / w);
            frame[o]     = luma;                           /* Y0 */
            frame[o + 1] = 128;                            /* Cb */
            frame[o + 2] = luma;                           /* Y1 */
            frame[o + 3] = 128;                            /* Cr */
        }
    }
    int rc = encode_yuyv(frame, w, h, quality, out_path);
    free(frame);
    if (rc == 0)
        fprintf(stderr, "capture: selftest OK %s (%dx%d q=%d)\n", out_path, w, h, quality);
    return rc;
}
#endif

/* 写出帧元数据 JSON（供 :8849 /capture 响应头与 /health 使用） */
static void write_meta(const char *path, const struct frame_info *fi,
                       const char *out, long elapsed_ms) {
    struct stat st;
    long size = 0;
    if (stat(out, &st) == 0) size = (long)st.st_size;
    FILE *f = fopen(path, "w");
    if (!f) return;
    fprintf(f,
            "{\"ok\":true,\"format\":\"%s\",\"width\":%d,\"height\":%d,"
            "\"bytes\":%ld,\"elapsed_ms\":%ld}\n",
            fi->mjpeg ? "MJPEG" : "YUYV", fi->width, fi->height, size, elapsed_ms);
    fclose(f);
}

/* JSON 字符串转义（描述串一般 ASCII，仅处理引号/反斜杠/控制符） */
static void json_put(const char *s) {
    for (; *s; s++) {
        unsigned char c = (unsigned char)*s;
        if (c == '"' || c == '\\') { putchar('\\'); putchar(c); }
        else if (c < 0x20) printf("\\u%04x", c);
        else putchar(c);
    }
}

/* 枚举设备与格式，输出 JSON 数组 */
static void probe(void) {
    int first_dev = 1;
    printf("[");
    for (int i = 0; i < 4; i++) {
        char dev[32];
        snprintf(dev, sizeof(dev), "/dev/video%d", i);
        int fd = open_capture(dev, 0);
        if (fd < 0) continue;

        struct v4l2_capability cap;
        memset(&cap, 0, sizeof(cap));
        xioctl(fd, VIDIOC_QUERYCAP, &cap);

        if (!first_dev) printf(",");
        first_dev = 0;
        printf("{\"dev\":\"%s\",\"card\":\"", dev);
        json_put((const char *)cap.card);
        printf("\",\"formats\":[");

        int first_fmt = 1;
        struct v4l2_fmtdesc desc;
        memset(&desc, 0, sizeof(desc));
        desc.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        for (desc.index = 0; xioctl(fd, VIDIOC_ENUM_FMT, &desc) == 0; desc.index++) {
            if (!first_fmt) printf(",");
            first_fmt = 0;
            char fourcc[5] = {
                (char)(desc.pixelformat & 0xff),
                (char)((desc.pixelformat >> 8) & 0xff),
                (char)((desc.pixelformat >> 16) & 0xff),
                (char)((desc.pixelformat >> 24) & 0xff), 0
            };
            printf("{\"fourcc\":\"");
            json_put(fourcc);
            printf("\",\"desc\":\"");
            json_put((const char *)desc.description);
            printf("\",\"compressed\":%s}", (desc.flags & V4L2_FMT_FLAG_COMPRESSED) ? "true" : "false");
        }
        printf("],\"current\":");
        struct v4l2_format fmt;
        memset(&fmt, 0, sizeof(fmt));
        fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        if (xioctl(fd, VIDIOC_G_FMT, &fmt) == 0) {
            char fourcc[5] = {
                (char)(fmt.fmt.pix.pixelformat & 0xff),
                (char)((fmt.fmt.pix.pixelformat >> 8) & 0xff),
                (char)((fmt.fmt.pix.pixelformat >> 16) & 0xff),
                (char)((fmt.fmt.pix.pixelformat >> 24) & 0xff), 0
            };
            printf("{\"fourcc\":\"");
            json_put(fourcc);
            printf("\",\"width\":%u,\"height\":%u}", fmt.fmt.pix.width, fmt.fmt.pix.height);
        } else {
            printf("null");
        }
        printf("}");
        close(fd);
    }
    printf("]\n");
}

int main(int argc, char *argv[]) {
    const char *dev = NULL;
    const char *out = DEFAULT_OUT;
    const char *meta = NULL;
    int warmup = 3;
    int quality = 85;
    int timeout_ms = 5000;
    int verbose = 0;
    int do_probe = 0;
    int do_selftest = 0;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--device") && i + 1 < argc) dev = argv[++i];
        else if (!strcmp(argv[i], "--output") && i + 1 < argc) out = argv[++i];
        else if (!strcmp(argv[i], "--meta") && i + 1 < argc) meta = argv[++i];
        else if (!strcmp(argv[i], "--warmup") && i + 1 < argc) warmup = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--quality") && i + 1 < argc) quality = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--timeout") && i + 1 < argc) timeout_ms = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--probe")) do_probe = 1;
        else if (!strcmp(argv[i], "--selftest")) do_selftest = 1;
        else if (!strcmp(argv[i], "--verbose") || !strcmp(argv[i], "-v")) verbose = 1;
        else if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
            fprintf(stderr,
                "capture - KVM HDMI 单帧抓取\n\n"
                "用法: capture --output PATH [选项]\n"
                "      capture --probe\n\n"
                "选项:\n"
                "  --output PATH     输出 JPEG 路径 (默认 %s)\n"
                "  --device PATH     采集设备 (默认自动探测 /dev/video0..3)\n"
                "  --warmup N        丢弃的预热帧数 (默认 3)\n"
                "  --quality N       YUYV→JPEG 质量 (默认 85)\n"
                "  --timeout MS      单帧等待超时 (默认 5000)\n"
                "  --probe           枚举设备与格式，输出 JSON\n"
                "  --verbose, -v     打印诊断信息\n", DEFAULT_OUT);
            return 0;
        }
    }

    if (do_probe) { probe(); return 0; }

    if (do_selftest) {
#ifdef HAVE_LIBJPEG
        int src = selftest_yuyv(out, quality);
        if (src == 0 && meta) {
            struct frame_info fi = {640, 360, 0};
            write_meta(meta, &fi, out, 0);
        }
        return src == 0 ? 0 : 1;
#else
        fprintf(stderr, "capture: 未启用 libjpeg，无法执行 YUYV 自检\n");
        return 1;
#endif
    }

    char auto_dev[32];
    if (!dev) {
        if (find_device(auto_dev, sizeof(auto_dev)) < 0) {
            fprintf(stderr, "capture: 未找到可用的视频采集设备 (/dev/video0..3)\n");
            return 2;
        }
        dev = auto_dev;
    }

    int fd = open_capture(dev, verbose);
    if (fd < 0) {
        fprintf(stderr, "capture: 无法打开采集设备 %s: %s\n", dev, strerror(errno));
        return 2;
    }

    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    struct frame_info info = {0, 0, 0};
    int rc = grab_frame(fd, out, warmup, quality, timeout_ms, verbose, &info);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    close(fd);

    if (rc == 0) {
        struct stat st;
        long ms = (t1.tv_sec - t0.tv_sec) * 1000L + (t1.tv_nsec - t0.tv_nsec) / 1000000L;
        if (stat(out, &st) == 0)
            fprintf(stderr, "capture: OK %ld bytes %ld ms\n", (long)st.st_size, ms);
        if (meta) write_meta(meta, &info, out, ms);
        return 0;
    }
    fprintf(stderr, "capture: 抓取失败\n");
    return 1;
}

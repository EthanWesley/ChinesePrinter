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
 *   3. Luckfox Pico KVM 真机使用 Rockchip rkcif/rkisp 的 V4L2 MPLANE 节点，
 *      因此同时支持 V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE，并可处理
 *      NV16 / NV12 半平面格式（先转 YUYV 再编码）。
 *
 * 用法：
 *   capture --output /tmp/frame.jpg [--device /dev/video0] [--warmup 3]
 *           [--quality 85] [--timeout 5000] [--probe] [--selftest]
 *   capture --probe            # 枚举 /dev/video0..23 的能力，输出 JSON
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
    void *start[VIDEO_MAX_PLANES];
    size_t length[VIDEO_MAX_PLANES];
    unsigned int nplanes;
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

/* Rockchip CSI/ISP 节点只暴露 MPLANE 能力；用它选择正确的数据路径 */
static int device_is_mplane(int fd) {
    struct v4l2_capability cap;
    memset(&cap, 0, sizeof(cap));
    if (xioctl(fd, VIDIOC_QUERYCAP, &cap) < 0) return 0;
    if (!(cap.capabilities & V4L2_CAP_VIDEO_CAPTURE_MPLANE)) return 0;
    if (cap.capabilities & V4L2_CAP_VIDEO_CAPTURE) return 0;
    return 1;
}

/* fourcc 转可读字符串（调用方提供至少 5 字节） */
static void fourcc_str(unsigned int fourcc, char out[5]) {
    out[0] = (char)(fourcc & 0xff);
    out[1] = (char)((fourcc >> 8) & 0xff);
    out[2] = (char)((fourcc >> 16) & 0xff);
    out[3] = (char)((fourcc >> 24) & 0xff);
    out[4] = 0;
}

/* 自动探测第一个可用的采集设备 */
static int find_device(char *out, size_t n) {
    for (int i = 0; i < 24; i++) {
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

/* MPLANE 版请求指定像素格式，返回实际生效的宽高；失败返回 -1 */
static int try_format_mplane(int fd, unsigned int pixfmt, int *w, int *h) {
    struct v4l2_format fmt;
    memset(&fmt, 0, sizeof(fmt));
    fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    if (xioctl(fd, VIDIOC_G_FMT, &fmt) < 0 ||
        fmt.fmt.pix_mp.width == 0 || fmt.fmt.pix_mp.height == 0) {
        fmt.fmt.pix_mp.width = 640;
        fmt.fmt.pix_mp.height = 480;
    }
    fmt.fmt.pix_mp.pixelformat = pixfmt;
    fmt.fmt.pix_mp.field = V4L2_FIELD_ANY;
    fmt.fmt.pix_mp.num_planes = 1;
    if (xioctl(fd, VIDIOC_S_FMT, &fmt) < 0) return -1;
    if (fmt.fmt.pix_mp.pixelformat != pixfmt) return -1;
    *w = (int)fmt.fmt.pix_mp.width;
    *h = (int)fmt.fmt.pix_mp.height;
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

/* NV12: Y 平面 w*h，随后 CbCr 交错平面 w*h/2（色度 2x2 共用） */
static int nv12_to_yuyv(const unsigned char *y, const unsigned char *uv,
                        int w, int h, unsigned char *out) {
    if (w <= 0 || h <= 0 || (w & 1) || (h & 1)) return -1;
    for (int j = 0; j < h; j += 2) {
        for (int i = 0; i < w; i += 2) {
            size_t y00 = (size_t)j * w + i;
            size_t y01 = y00 + 1;
            size_t y10 = y00 + w;
            size_t y11 = y10 + 1;
            size_t uvoff = ((size_t)(j / 2) * w) + i;
            unsigned char cb = uv[uvoff];
            unsigned char cr = uv[uvoff + 1];
            size_t o = (y00 * 2);
            out[o]     = y[y00]; out[o + 1] = cb;
            out[o + 2] = y[y01]; out[o + 3] = cr;
            o = (y10 * 2);
            out[o]     = y[y10]; out[o + 1] = cb;
            out[o + 2] = y[y11]; out[o + 3] = cr;
        }
    }
    return 0;
}

/* NV16: Y 平面 w*h，随后 CbCr 交错平面 w*h（每行色度不共用） */
static int nv16_to_yuyv(const unsigned char *y, const unsigned char *uv,
                        int w, int h, unsigned char *out) {
    if (w <= 0 || h <= 0 || (w & 1)) return -1;
    for (int j = 0; j < h; j++) {
        for (int i = 0; i < w; i += 2) {
            size_t p = (size_t)j * (w / 2) + i / 2;
            size_t o = ((size_t)j * w + i) * 2;
            out[o]     = y[(size_t)j * w + i];
            out[o + 1] = uv[p * 2];
            out[o + 2] = y[(size_t)j * w + i + 1];
            out[o + 3] = uv[p * 2 + 1];
        }
    }
    return 0;
}
#endif

struct frame_info {
    int width;
    int height;
    int mjpeg;
    char format[8];
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
        strcpy(info->format, is_mjpeg ? "MJPEG" : "YUYV");
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
        bufs[i].nplanes = 1;
        bufs[i].length[0] = b.length;
        bufs[i].start[0] = mmap(NULL, b.length, PROT_READ | PROT_WRITE,
                                MAP_SHARED, fd, b.m.offset);
        if (bufs[i].start[0] == MAP_FAILED) {
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
            frame = (unsigned char *)bufs[b.index].start[0];
            frame_len = b.bytesused;
            /* 最后一帧不再入队，避免 Rockchip vb2 在 STREAMOFF 时等待该 buffer */
            rc = 0;
        } else if (xioctl(fd, VIDIOC_QBUF, &b) < 0) {
            perror("VIDIOC_QBUF");
            break;
        }
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
    {
        struct v4l2_requestbuffers rel;
        memset(&rel, 0, sizeof(rel));
        rel.count = 0;
        rel.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        rel.memory = V4L2_MEMORY_MMAP;
        xioctl(fd, VIDIOC_REQBUFS, &rel);
    }
    for (unsigned int i = 0; i < nbuf; i++) {
        for (unsigned int p = 0; p < bufs[i].nplanes; p++) {
            if (bufs[i].start[p] && bufs[i].start[p] != MAP_FAILED)
                munmap(bufs[i].start[p], bufs[i].length[p]);
        }
    }
    return rc;
}

/* Rockchip rkcif/rkisp 的 MPLANE 抓帧路径 */
static int grab_frame_mplane(int fd, const char *out_path,
                             int warmup, int quality, int timeout_ms, int verbose,
                             struct frame_info *info) {
    int w = 0, h = 0;
    unsigned int pixfmt = 0;
    const char *fmt_name = NULL;
    char fmt_buf[8] = "";
    /* rkcif 会“接受”MJPEG 请求却不出帧；按枚举结果优先使用原生 YUYV */
    unsigned int candidates[] = {
        V4L2_PIX_FMT_YUYV, V4L2_PIX_FMT_NV16, V4L2_PIX_FMT_NV12, 0
    };

    for (int i = 0; candidates[i]; i++) {
        if (try_format_mplane(fd, candidates[i], &w, &h) == 0) {
            pixfmt = candidates[i];
            char fc[5];
            fourcc_str(pixfmt, fc);
            snprintf(fmt_buf, sizeof(fmt_buf), "%s",
                     (pixfmt == V4L2_PIX_FMT_MJPEG) ? "MJPEG" :
                     (pixfmt == V4L2_PIX_FMT_YUYV) ? "YUYV" : fc);
            fmt_name = fmt_buf;
            break;
        }
    }
    if (!pixfmt) {
        fprintf(stderr, "capture: MPLANE 设备不支持 MJPEG/YUYV/NV16/NV12\n");
        return -1;
    }
    if (info) {
        info->width = w;
        info->height = h;
        info->mjpeg = (pixfmt == V4L2_PIX_FMT_MJPEG);
        strncpy(info->format, fmt_name, sizeof(info->format) - 1);
        info->format[sizeof(info->format) - 1] = 0;
    }
    if (verbose)
        fprintf(stderr, "capture: MPLANE 格式 %s %dx%d\n", fmt_name, w, h);

    enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;

    struct v4l2_requestbuffers req;
    memset(&req, 0, sizeof(req));
    req.count = MAX_BUFFERS;
    req.type = type;
    req.memory = V4L2_MEMORY_MMAP;
    if (xioctl(fd, VIDIOC_REQBUFS, &req) < 0 || req.count < 1) {
        perror("VIDIOC_REQBUFS(MPLANE)");
        return -1;
    }

    struct buffer bufs[MAX_BUFFERS];
    memset(bufs, 0, sizeof(bufs));
    unsigned int nbuf = req.count > MAX_BUFFERS ? MAX_BUFFERS : req.count;

    for (unsigned int i = 0; i < nbuf; i++) {
        struct v4l2_plane planes[VIDEO_MAX_PLANES];
        struct v4l2_buffer b;
        memset(planes, 0, sizeof(planes));
        memset(&b, 0, sizeof(b));
        b.type = type;
        b.memory = V4L2_MEMORY_MMAP;
        b.index = i;
        b.length = VIDEO_MAX_PLANES;
        b.m.planes = planes;
        if (xioctl(fd, VIDIOC_QUERYBUF, &b) < 0) {
            perror("VIDIOC_QUERYBUF(MPLANE)");
            return -1;
        }
        if (b.length < 1 || b.length > VIDEO_MAX_PLANES) {
            fprintf(stderr, "capture: 非法 plane 数 %u\n", b.length);
            return -1;
        }
        bufs[i].nplanes = b.length;
        for (unsigned int p = 0; p < b.length; p++) {
            bufs[i].length[p] = planes[p].length;
            bufs[i].start[p] = mmap(NULL, planes[p].length, PROT_READ | PROT_WRITE,
                                    MAP_SHARED, fd, planes[p].m.mem_offset);
            if (bufs[i].start[p] == MAP_FAILED) {
                perror("mmap(MPLANE)");
                return -1;
            }
        }
        b.length = bufs[i].nplanes;
        if (xioctl(fd, VIDIOC_QBUF, &b) < 0) {
            perror("VIDIOC_QBUF(MPLANE)");
            return -1;
        }
    }

    if (verbose) fprintf(stderr, "capture: stage=streamon(MPLANE)\n");
    if (xioctl(fd, VIDIOC_STREAMON, &type) < 0) {
        perror("VIDIOC_STREAMON(MPLANE)");
        return -1;
    }
    if (verbose) fprintf(stderr, "capture: stage=streamon(MPLANE) ok\n");

    int need = warmup > 0 ? warmup + 1 : 1;
    unsigned char *plane[VIDEO_MAX_PLANES];
    size_t plane_len[VIDEO_MAX_PLANES];
    unsigned int nplane = 0;
    int rc = -1;

    memset(plane, 0, sizeof(plane));
    memset(plane_len, 0, sizeof(plane_len));

    for (int i = 0; i < need; i++) {
        fd_set fds;
        FD_ZERO(&fds);
        FD_SET(fd, &fds);
        struct timeval tv;
        tv.tv_sec = timeout_ms / 1000;
        tv.tv_usec = (timeout_ms % 1000) * 1000;
        int r = select(fd + 1, &fds, NULL, NULL, &tv);
        if (r <= 0) {
            fprintf(stderr, "capture: 等待 MPLANE 帧超时 (%d ms)\n", timeout_ms);
            break;
        }

        struct v4l2_plane planes[VIDEO_MAX_PLANES];
        struct v4l2_buffer b;
        memset(planes, 0, sizeof(planes));
        memset(&b, 0, sizeof(b));
        b.type = type;
        b.memory = V4L2_MEMORY_MMAP;
        b.length = VIDEO_MAX_PLANES;
        b.m.planes = planes;
        if (xioctl(fd, VIDIOC_DQBUF, &b) < 0) {
            if (errno == EAGAIN) { i--; continue; }
            perror("VIDIOC_DQBUF(MPLANE)");
            break;
        }
        if (b.index >= nbuf) {
            fprintf(stderr, "capture: 非法 buffer index %u\n", b.index);
            xioctl(fd, VIDIOC_QBUF, &b);
            break;
        }

        if (i == need - 1) {
            nplane = b.length;
            if (nplane > VIDEO_MAX_PLANES) nplane = VIDEO_MAX_PLANES;
            for (unsigned int p = 0; p < nplane; p++) {
                plane[p] = (unsigned char *)bufs[b.index].start[p];
                plane_len[p] = planes[p].bytesused;
                if (!plane_len[p]) plane_len[p] = bufs[b.index].length[p];
            }
        }
        if (i == need - 1) {
            /* 最后一帧不再入队，避免 Rockchip vb2 在 STREAMOFF 时等待该 buffer */
            rc = 0;
        } else if (xioctl(fd, VIDIOC_QBUF, &b) < 0) {
            perror("VIDIOC_QBUF(MPLANE)");
            break;
        }
    }

    if (rc == 0 && plane[0] && plane_len[0] > 0) {
        if (pixfmt == V4L2_PIX_FMT_MJPEG) {
            size_t n = trim_jpeg(plane[0], plane_len[0]);
            if (n == 0) {
                fprintf(stderr, "capture: MJPEG 帧缺少 SOI/EOI\n");
                rc = -1;
            } else {
                FILE *fp = fopen(out_path, "wb");
                if (!fp) { perror("fopen"); rc = -1; }
                else {
                    if (fwrite(plane[0], 1, n, fp) != n) { perror("fwrite"); rc = -1; }
                    fclose(fp);
                    if (verbose)
                        fprintf(stderr, "capture: 写出 %zu 字节 (MJPEG 直通)\n", n);
                }
            }
        }
#ifdef HAVE_LIBJPEG
        else {
            unsigned char *yuyv = plane[0];
            if (pixfmt == V4L2_PIX_FMT_NV16 || pixfmt == V4L2_PIX_FMT_NV12) {
                if (nplane < 2 || !plane[1]) {
                    fprintf(stderr, "capture: %s 缺少第二个平面\n", fmt_name);
                    rc = -1;
                } else {
                    yuyv = malloc((size_t)w * h * 2);
                    if (!yuyv) {
                        fprintf(stderr, "capture: 分配 YUYV 缓冲失败\n");
                        rc = -1;
                    } else if (pixfmt == V4L2_PIX_FMT_NV16) {
                        rc = nv16_to_yuyv(plane[0], plane[1], w, h, yuyv);
                    } else {
                        rc = nv12_to_yuyv(plane[0], plane[1], w, h, yuyv);
                    }
                }
            }
            if (rc == 0 && encode_yuyv(yuyv, w, h, quality, out_path) == 0) {
                if (verbose)
                    fprintf(stderr, "capture: 写出 %s (%s→JPEG q=%d)\n",
                            out_path, fmt_name, quality);
            } else {
                rc = -1;
            }
            if (yuyv && yuyv != plane[0]) free(yuyv);
        }
#else
        else {
            fprintf(stderr, "capture: 非 MJPEG 格式需要 libjpeg 支持\n");
            rc = -1;
        }
#endif
    }

    if (verbose) fprintf(stderr, "capture: stage=streamoff(MPLANE) rc=%d\n", rc);
    xioctl(fd, VIDIOC_STREAMOFF, &type);
    if (verbose) fprintf(stderr, "capture: stage=streamoff(MPLANE) ok\n");
    {
        struct v4l2_requestbuffers rel;
        memset(&rel, 0, sizeof(rel));
        rel.count = 0;
        rel.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        rel.memory = V4L2_MEMORY_MMAP;
        xioctl(fd, VIDIOC_REQBUFS, &rel);
        if (verbose) fprintf(stderr, "capture: stage=reqbufs0(MPLANE) ok\n");
    }
    for (unsigned int i = 0; i < nbuf; i++) {
        for (unsigned int p = 0; p < bufs[i].nplanes; p++) {
            if (bufs[i].start[p] && bufs[i].start[p] != MAP_FAILED)
                munmap(bufs[i].start[p], bufs[i].length[p]);
        }
    }
    if (verbose) fprintf(stderr, "capture: stage=munmap(MPLANE) ok\n");
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
            (fi->format[0] ? fi->format : (fi->mjpeg ? "MJPEG" : "YUYV")),
            fi->width, fi->height, size, elapsed_ms);
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

/* 枚举设备与格式，输出 JSON 数组（同时兼容单平面与 MPLANE） */
static void probe(void) {
    int first_dev = 1;
    printf("[");
    for (int i = 0; i < 24; i++) {
        char dev[32];
        snprintf(dev, sizeof(dev), "/dev/video%d", i);
        int fd = open_capture(dev, 0);
        if (fd < 0) continue;

        struct v4l2_capability cap;
        memset(&cap, 0, sizeof(cap));
        xioctl(fd, VIDIOC_QUERYCAP, &cap);
        int single = !!(cap.capabilities & V4L2_CAP_VIDEO_CAPTURE);
        int mplane = !!(cap.capabilities & V4L2_CAP_VIDEO_CAPTURE_MPLANE);
        const char *type = (mplane && !single) ? "mplane" :
                           (single && !mplane) ? "single" : "both";

        if (!first_dev) printf(",");
        first_dev = 0;
        printf("{\"dev\":\"%s\",\"card\":\"", dev);
        json_put((const char *)cap.card);
        printf("\",\"type\":\"%s\",\"formats\":[", type);

        int first_fmt = 1;
        for (int t = 0; t < 2; t++) {
            enum v4l2_buf_type buf_type = t == 0 ?
                V4L2_BUF_TYPE_VIDEO_CAPTURE : V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
            if ((t == 0 && !single) || (t == 1 && !mplane)) continue;

            struct v4l2_fmtdesc desc;
            memset(&desc, 0, sizeof(desc));
            desc.type = buf_type;
            for (desc.index = 0; xioctl(fd, VIDIOC_ENUM_FMT, &desc) == 0; desc.index++) {
                if (!first_fmt) printf(",");
                first_fmt = 0;
                char fourcc[5];
                fourcc_str(desc.pixelformat, fourcc);
                printf("{\"fourcc\":\"");
                json_put(fourcc);
                printf("\",\"desc\":\"");
                json_put((const char *)desc.description);
                printf("\",\"compressed\":%s,\"mplane\":%s}",
                        (desc.flags & V4L2_FMT_FLAG_COMPRESSED) ? "true" : "false",
                        t == 1 ? "true" : "false");
            }
        }
        printf("],\"current\":");

        struct v4l2_format fmt;
        memset(&fmt, 0, sizeof(fmt));
        enum v4l2_buf_type current_type = mplane && !single ?
            V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE : V4L2_BUF_TYPE_VIDEO_CAPTURE;
        fmt.type = current_type;
        if (xioctl(fd, VIDIOC_G_FMT, &fmt) == 0) {
            char fourcc[5];
            unsigned int pf = current_type == V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE ?
                fmt.fmt.pix_mp.pixelformat : fmt.fmt.pix.pixelformat;
            unsigned int width = current_type == V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE ?
                fmt.fmt.pix_mp.width : fmt.fmt.pix.width;
            unsigned int height = current_type == V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE ?
                fmt.fmt.pix_mp.height : fmt.fmt.pix.height;
            fourcc_str(pf, fourcc);
            printf("{\"fourcc\":\"");
            json_put(fourcc);
            printf("\",\"width\":%u,\"height\":%u}", width, height);
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
                "  --device PATH     采集设备 (默认自动探测 /dev/video0..23)\n"
                "  --warmup N        丢弃的预热帧数 (默认 3)\n"
                "  --quality N       YUYV/NV12/NV16→JPEG 质量 (默认 85)\n"
                "  --timeout MS      单帧等待超时 (默认 5000)\n"
                "  --probe           枚举设备与格式（含 MPLANE），输出 JSON\n"
                "  --verbose, -v     打印诊断信息\n", DEFAULT_OUT);
            return 0;
        }
    }

    if (do_probe) { probe(); return 0; }

    if (do_selftest) {
#ifdef HAVE_LIBJPEG
        int src = selftest_yuyv(out, quality);
        if (src == 0 && meta) {
            struct frame_info fi = {640, 360, 0, "YUYV"};
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
            fprintf(stderr, "capture: 未找到可用的视频采集设备 (/dev/video0..23)\n");
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
    struct frame_info info = {0, 0, 0, ""};
    int mplane = device_is_mplane(fd);
    int rc = mplane
        ? grab_frame_mplane(fd, out, warmup, quality, timeout_ms, verbose, &info)
        : grab_frame(fd, out, warmup, quality, timeout_ms, verbose, &info);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    if (verbose) fprintf(stderr, "capture: stage=close fd=%d rc=%d\n", fd, rc);
    close(fd);
    if (verbose) fprintf(stderr, "capture: stage=close ok\n");

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

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ChinesePrinter —— 运行在 Luckfox Pico KVM (RV1106G3) 上的中文自动打字网页服务。

功能：
- 提供本地网页（通过 IP:端口 访问），开机自启
- 网页里有中文文本框 + 编码选择（GBK / Unicode）+ 打字按钮
- 点击按钮后，通过 USB HID gadget (/dev/hidg0) 用 Alt 码方式
  把中文逐字"打"到 KVM 所连的目标电脑上

纯 Python 标准库实现，无需额外安装 Flask / PyYAML / websocket-client 等依赖。

配置：通过环境变量覆盖默认值
  APP_HOST            监听地址（默认 0.0.0.0）
  APP_PORT            监听端口（默认 8848）
  HID_DEVICE          HID 设备路径（默认 /dev/hidg0）
  KEY_DELAY           每步按键间隔秒（默认 0.05）
  ALT_RELEASE_DELAY   松开 Alt 前等待秒（默认 0.08）
"""

import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from encoding import encode_text, GBK_AVAILABLE, GBK_SOURCE, SYSTEM_GBK_AVAILABLE
from hid_keyboard import HidKeyboard, HidError

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
TEMPLATE_DIR = os.path.join(BASE_DIR, "templates")

# ---- 配置（环境变量覆盖） ----
HOST = os.environ.get("APP_HOST", "0.0.0.0")
PORT = int(os.environ.get("APP_PORT", "8848"))
HID_DEVICE = os.environ.get("HID_DEVICE", "/dev/hidg0")
KEY_DELAY = float(os.environ.get("KEY_DELAY", "0.05"))
ALT_RELEASE_DELAY = float(os.environ.get("ALT_RELEASE_DELAY", "0.08"))


def _detect_hid_keyboard():
    """自动识别 HID 键盘设备。

    遍历 /dev/hidg*，通过 /sys/class/hidg/<name>/protocol 判断设备类型：
      protocol=1 -> 键盘
      protocol=2 -> 鼠标
    返回找到的第一个键盘设备路径，找不到返回 None。
    """
    try:
        import glob
        for dev in sorted(glob.glob("/dev/hidg*")):
            if not os.path.exists(dev):
                continue
            name = os.path.basename(dev)
            proto_file = f"/sys/class/hidg/{name}/protocol"
            try:
                with open(proto_file, "r") as f:
                    proto = f.read().strip()
                if proto == "1":
                    return dev
            except (OSError, IOError):
                continue
    except Exception:
        pass
    return None


def _resolve_hid_device():
    """解析实际使用的 HID 设备路径。

    1. 如果 HID_DEVICE 环境变量显式指定且存在，直接用
    2. 否则尝试自动识别键盘设备
    3. 都不行就回退到默认 /dev/hidg0
    """
    env_device = os.environ.get("HID_DEVICE", "")
    # 如果用户显式指定了非默认值，尊重用户选择
    if env_device and env_device != "/dev/hidg0":
        return env_device
    # 默认值时尝试自动识别
    auto = _detect_hid_keyboard()
    if auto:
        return auto
    return HID_DEVICE


# 实际使用的 HID 设备（启动时解析一次）
HID_DEVICE = _resolve_hid_device()


def _get_device_protocol(device):
    """读取 HID 设备的 protocol（1=键盘, 2=鼠标）。"""
    if not device:
        return None
    name = os.path.basename(device)
    proto_file = f"/sys/class/hidg/{name}/protocol"
    try:
        with open(proto_file, "r") as f:
            return f.read().strip()
    except (OSError, IOError):
        return None


def _list_all_hid_devices():
    """列出所有 /dev/hidg* 设备及其类型。"""
    import glob
    result = []
    for dev in sorted(glob.glob("/dev/hidg*")):
        if not os.path.exists(dev):
            continue
        proto = _get_device_protocol(dev)
        type_desc = {"1": "keyboard", "2": "mouse"}.get(proto, "unknown")
        result.append({"path": dev, "protocol": proto, "type": type_desc})
    return result


# ---- 状态 ----
_typing_lock = threading.Lock()
_stop_event = threading.Event()
_typing_busy = {
    "value": False,
    "progress": 0,
    "total": 0,
    "last_error": "",
    "encoding": "",
}


def _log(msg, level="info"):
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] [{level}] {msg}", flush=True)


def _do_type(text, encoding):
    """后台打字任务。"""
    with _typing_lock:
        _stop_event.clear()
        try:
            sequences, skipped = encode_text(text, encoding)
        except RuntimeError as exc:
            _typing_busy["last_error"] = str(exc)
            _log(str(exc), "error")
            return

        total = len(sequences)
        _typing_busy.update(
            value=True, progress=0, total=total,
            last_error="", encoding=encoding,
        )
        _log(f"开始打字：编码={encoding}，共 {total} 字符，跳过 {len(skipped)} 字")
        if skipped:
            _log(f"以下字符无法用 {encoding} 编码，已跳过: {''.join(skipped)}", "warn")

        try:
            kb = HidKeyboard(HID_DEVICE, KEY_DELAY, ALT_RELEASE_DELAY)
            kb.open()
            for idx, item in enumerate(sequences):
                if _stop_event.is_set():
                    _log(f"用户中止打字（已完成 {idx}/{total}）", "warn")
                    break
                if item.get("control"):
                    kb.type_control_char(item["char"])
                elif item.get("code") is not None:
                    kb.type_alt_code(item["code"])
                _typing_busy["progress"] = idx + 1
            kb.close()
            if not _stop_event.is_set():
                _log("打字完成")
        except HidError as exc:
            _typing_busy["last_error"] = str(exc)
            _log(f"打字失败: {exc}", "error")
        except Exception as exc:
            _typing_busy["last_error"] = str(exc)
            _log(f"打字异常: {exc}", "error")
        finally:
            _typing_busy["value"] = False


# ---- HTTP 请求处理 ----

class Handler(BaseHTTPRequestHandler):
    """处理网页和 API 请求。"""

    server_version = "ChinesePrinter/1.0"

    def _send_json(self, code, data):
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(body)

    def _send_file(self, filepath, content_type):
        try:
            with open(filepath, "rb") as f:
                body = f.read()
        except FileNotFoundError:
            self._send_json(404, {"ok": False, "msg": "文件不存在"})
            return
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/" or path == "/index.html":
            self._send_file(os.path.join(TEMPLATE_DIR, "index.html"),
                            "text/html; charset=utf-8")
        elif path == "/api/health":
            proto = _get_device_protocol(HID_DEVICE)
            type_desc = {"1": "keyboard", "2": "mouse"}.get(proto, "unknown")
            self._send_json(200, {
                "ok": True,
                "busy": _typing_busy["value"],
                "progress": _typing_busy["progress"],
                "total": _typing_busy["total"],
                "encoding": _typing_busy["encoding"],
                "last_error": _typing_busy["last_error"],
                "device": HID_DEVICE,
                "device_exists": os.path.exists(HID_DEVICE),
                "device_type": type_desc,
                "all_devices": _list_all_hid_devices(),
                "gbk_available": GBK_AVAILABLE,
                "gbk_source": GBK_SOURCE,
                "system_gbk": SYSTEM_GBK_AVAILABLE,
            })
        elif path == "/api/config":
            proto = _get_device_protocol(HID_DEVICE)
            type_desc = {"1": "keyboard", "2": "mouse"}.get(proto, "unknown")
            self._send_json(200, {
                "ok": True,
                "server": {"host": HOST, "port": PORT},
                "typing": {
                    "key_delay": KEY_DELAY,
                    "alt_release_delay": ALT_RELEASE_DELAY,
                },
                "device": HID_DEVICE,
                "device_exists": os.path.exists(HID_DEVICE),
                "device_type": type_desc,
                "all_devices": _list_all_hid_devices(),
                "gbk_available": GBK_AVAILABLE,
                "gbk_source": GBK_SOURCE,
                "system_gbk": SYSTEM_GBK_AVAILABLE,
            })
        else:
            self._send_json(404, {"ok": False, "msg": "路径不存在"})

    def do_POST(self):
        path = self.path.split("?")[0]
        if path == "/api/type":
            self._handle_type()
        elif path == "/api/stop":
            _stop_event.set()
            self._send_json(200, {"ok": True, "msg": "已请求停止打字"})
        else:
            self._send_json(404, {"ok": False, "msg": "路径不存在"})

    def _handle_type(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length > 0 else b""
        try:
            data = json.loads(raw) if raw else {}
        except (ValueError, TypeError):
            self._send_json(400, {"ok": False, "msg": "请求体不是合法 JSON"})
            return

        text = data.get("text", "")
        encoding = (data.get("encoding") or "gbk").lower()

        if not text:
            self._send_json(400, {"ok": False, "msg": "文本不能为空"})
            return
        if encoding not in ("gbk", "unicode"):
            self._send_json(400, {"ok": False, "msg": "编码方案只支持 gbk / unicode"})
            return
        if encoding == "gbk" and not GBK_AVAILABLE:
            self._send_json(400, {
                "ok": False,
                "msg": "当前 Python 不支持 GBK 编码，请改用 Unicode 方案",
            })
            return
        if _typing_lock.locked():
            self._send_json(409, {"ok": False, "msg": "正在打字中，请等待当前任务完成"})
            return

        t = threading.Thread(target=_do_type, args=(text, encoding), daemon=True)
        t.start()
        self._send_json(200, {
            "ok": True,
            "msg": "已开始打字",
            "encoding": encoding,
            "length": len(text),
        })

    def log_message(self, fmt, *args):
        # 只记录 4xx/5xx，静默正常请求
        code = args[1] if len(args) >= 2 else 200
        try:
            code = int(code)
        except (ValueError, TypeError):
            code = 200
        if code >= 400:
            _log(f"{self.address_string()} - {fmt % args}", "warn")


def main():
    _log(f"ChinesePrinter 启动")
    _log(f"  监听: {HOST}:{PORT}")
    _log(f"  HID 设备: {HID_DEVICE} (存在: {os.path.exists(HID_DEVICE)}, 类型: {_get_device_protocol(HID_DEVICE) or '未知'})")
    all_devs = _list_all_hid_devices()
    if len(all_devs) > 1:
        _log(f"  发现 {len(all_devs)} 个 HID 设备:")
        for d in all_devs:
            _log(f"    {d['path']} -> {d['type']}")
    gbk_desc = f"可用 (来源: {GBK_SOURCE})"
    if not GBK_AVAILABLE:
        gbk_desc = "不可用"
    _log(f"  GBK 编码: {gbk_desc}")
    _log(f"  按键间隔: {KEY_DELAY}s, Alt 释放延迟: {ALT_RELEASE_DELAY}s")

    server = ThreadingHTTPServer((HOST, PORT), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        _log("收到 Ctrl+C，正在停止…")
    finally:
        server.shutdown()
        _log("已停止")


if __name__ == "__main__":
    main()

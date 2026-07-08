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

from encoding import encode_text, GBK_AVAILABLE
from hid_keyboard import HidKeyboard, HidError

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
TEMPLATE_DIR = os.path.join(BASE_DIR, "templates")

# ---- 配置（环境变量覆盖） ----
HOST = os.environ.get("APP_HOST", "0.0.0.0")
PORT = int(os.environ.get("APP_PORT", "8848"))
HID_DEVICE = os.environ.get("HID_DEVICE", "/dev/hidg0")
KEY_DELAY = float(os.environ.get("KEY_DELAY", "0.05"))
ALT_RELEASE_DELAY = float(os.environ.get("ALT_RELEASE_DELAY", "0.08"))

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
            self._send_json(200, {
                "ok": True,
                "busy": _typing_busy["value"],
                "progress": _typing_busy["progress"],
                "total": _typing_busy["total"],
                "encoding": _typing_busy["encoding"],
                "last_error": _typing_busy["last_error"],
                "device": HID_DEVICE,
                "device_exists": os.path.exists(HID_DEVICE),
                "gbk_available": GBK_AVAILABLE,
            })
        elif path == "/api/config":
            self._send_json(200, {
                "ok": True,
                "server": {"host": HOST, "port": PORT},
                "typing": {
                    "key_delay": KEY_DELAY,
                    "alt_release_delay": ALT_RELEASE_DELAY,
                },
                "device": HID_DEVICE,
                "device_exists": os.path.exists(HID_DEVICE),
                "gbk_available": GBK_AVAILABLE,
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
    _log(f"  HID 设备: {HID_DEVICE} (存在: {os.path.exists(HID_DEVICE)})")
    _log(f"  GBK 编码: {'可用' if GBK_AVAILABLE else '不可用'}")
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

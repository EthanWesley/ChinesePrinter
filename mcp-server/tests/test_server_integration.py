"""MCP 工具层集成测试：用 httpx.MockTransport 模拟整台设备。

覆盖 capture_screen / run_sequence 与设备 HTTP 协议的交互，不建立真实 socket。
"""

from __future__ import annotations

import io
import pathlib
import sys

import httpx
import pytest
from PIL import Image as PILImage

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "mcp-server"))

from chinese_printer_mcp import server  # noqa: E402
from chinese_printer_mcp.actions import Translator, validate_actions  # noqa: E402
from chinese_printer_mcp.device import DeviceClient  # noqa: E402
from chinese_printer_mcp.mouse import MouseState  # noqa: E402

MAX_CHUNK_BYTES = 32768


def _make_jpeg(width: int, height: int, color: tuple[int, int, int] = (30, 90, 160)) -> bytes:
    """生成一张真实的小 JPEG，供 /capture 返回。"""
    buffer = io.BytesIO()
    PILImage.new("RGB", (width, height), color).save(buffer, format="JPEG", quality=80)
    return buffer.getvalue()


class FakeDevice:
    """记录请求的假设备：/seq 追加行记录，/health 反映执行状态。"""

    def __init__(self) -> None:
        self.posts: list[list[str]] = []  # 每次 POST /seq 解析后的行
        self.bodies: list[bytes] = []  # 原始请求体，便于校验大小
        self.progress = 0
        self.total = 0
        self.step = -1
        self.busy = False
        self.last_error = ""
        self.forced_step: int | None = None
        self.typewriter_busy = False
        self.mouse_available = True
        self.frame_width = 1920
        self.frame_height = 1080
        self.jpeg = _make_jpeg(640, 360)
        self.capture_width = 640
        self.capture_height = 360
        self.stop_calls = 0

    # ---- 状态变更 ----
    def apply(self, lines: list[str]) -> None:
        for line in lines:
            self.progress += 1
            if line.startswith("step "):
                self.step = int(line.split()[1])
        self.total = self.progress

    def health_payload(self) -> dict:
        return {
            "ok": True,
            "busy": self.busy,
            "progress": self.progress,
            "total": self.total,
            "step": self.step if self.forced_step is None else self.forced_step,
            "last_error": self.last_error,
            "capture": {
                "available": True,
                "last_frame": {
                    "width": self.frame_width,
                    "height": self.frame_height,
                    "format": "MJPEG",
                },
            },
            "mouse": {"available": self.mouse_available, "device": "/dev/hidg1" if self.mouse_available else ""},
            "keyboard": {"available": True},
            "typewriter_busy": self.typewriter_busy,
        }

    # ---- 路由 ----
    def handler(self, request: httpx.Request) -> httpx.Response:
        path = request.url.path

        # 打字机通道 :8848 —— 只用于忙状态探测
        if request.url.port == 8848 and path == "/api/health":
            return httpx.Response(200, json={"ok": True, "busy": self.typewriter_busy})

        if path == "/health":
            return httpx.Response(200, json=self.health_payload())

        if path == "/capture":
            return httpx.Response(
                200,
                content=self.jpeg,
                headers={
                    "X-Frame-Width": str(self.capture_width),
                    "X-Frame-Height": str(self.capture_height),
                    "X-Frame-Format": "MJPEG",
                },
            )

        if path == "/seq":
            self.bodies.append(request.content)
            lines = [line for line in request.content.decode("ascii").splitlines() if line]
            self.posts.append(lines)
            self.apply(lines)
            return httpx.Response(200, json={"ok": True, "total": len(lines)})

        if path in ("/stop", "/abort"):
            self.stop_calls += 1
            return httpx.Response(200, json={"ok": True})

        raise AssertionError(f"未预期的请求: {request.method} {request.url}")


@pytest.fixture
def fake() -> FakeDevice:
    return FakeDevice()


@pytest.fixture
def device_env(monkeypatch, fake):
    """把 server 的模块级 DEVICE/MOUSE/SCREEN 指向假设备，退出时自动还原。"""
    cfg = server.CFG
    monkeypatch.setattr(cfg, "host", "kvm.test")
    monkeypatch.setattr(cfg, "port", 8849)
    monkeypatch.setattr(cfg, "typewriter_port", 8848)
    monkeypatch.setattr(cfg, "poll_interval_ms", 10)  # 轮询下限 50ms，仍然很快

    client = DeviceClient(cfg, transport=httpx.MockTransport(fake.handler))
    monkeypatch.setattr(server, "DEVICE", client)
    monkeypatch.setattr(
        server, "MOUSE", MouseState(width=1920, height=1080, rehome=False, cursor=None)
    )
    monkeypatch.setattr(server, "SCREEN", {"width": 0, "height": 0})
    return fake


def flat_lines(posts: list[list[str]]) -> list[str]:
    return [line for chunk in posts for line in chunk]


# ---------------------------------------------------------------- capture_screen


def test_capture_screen_returns_jpeg_and_syncs_screen(device_env):
    fake = device_env

    image = server.capture_screen(scale=1.0, quality=75)

    assert hasattr(image, "data"), f"预期返回 Image，实际是 {image!r}"
    assert image.data.startswith(b"\xff\xd8")
    assert len(image.data) > 100
    # 分辨率由响应头决定，而不是 JPEG 自身尺寸
    assert server.SCREEN == {"width": 640, "height": 360}
    assert server.MOUSE.width == 640 and server.MOUSE.height == 360


def test_capture_screen_reports_device_error(device_env, monkeypatch):
    def broken(request):
        return httpx.Response(503, json={"detail": "no /dev/video0"})

    monkeypatch.setattr(
        server, "DEVICE", DeviceClient(server.CFG, transport=httpx.MockTransport(broken))
    )
    result = server.capture_screen()
    assert isinstance(result, str)
    assert "截图失败" in result and "no /dev/video0" in result


# ---------------------------------------------------------------- run_sequence


def test_run_sequence_happy_path(device_env):
    fake = device_env
    server.MOUSE.rehome = False
    server.MOUSE.cursor = None

    result = server.run_sequence(
        [
            {"t": "click", "x": 100, "y": 50},
            {"t": "type", "text": "张三"},
            {"t": "key", "keys": ["tab"]},
        ]
    )

    assert result["ok"] is True
    assert result["steps_done"] == 3
    assert result["failed_step"] is None

    lines = flat_lines(fake.posts)
    assert "step 0" in lines and "step 2" in lines
    assert "mmove 100 50" in lines
    assert "mclick 1" in lines
    # GBK 码位：张=54725，三=51453（中=54992，不在本用例文本中）
    assert "code 54725" in lines and "code 51453" in lines
    # tab 的 HID usage 为 0x2B=43，无修饰键
    assert "kbdset 0 43" in lines


def test_run_sequence_rejects_typewriter_busy(device_env):
    fake = device_env
    fake.typewriter_busy = True

    result = server.run_sequence([{"t": "key", "keys": ["tab"]}])

    assert result["ok"] is False
    assert "打字机" in result["error"]
    assert fake.posts == []  # 冲突时不应下发任何序列


def test_run_sequence_propagates_device_failure(device_env):
    fake = device_env
    fake.last_error = "unknown command: x"
    fake.forced_step = 1

    result = server.run_sequence(
        [{"t": "type", "text": "a"}, {"t": "type", "text": "b"}]
    )

    assert result["ok"] is False
    assert result["failed_step"] == 1
    assert result["error"] == "unknown command: x"
    assert "hint" in result


def test_run_sequence_chunks_large_text(device_env):
    fake = device_env
    text = "a" * 5000  # 每个字符一行 "code 97"，远超 32KB
    actions = [{"t": "type", "text": text}]

    result = server.run_sequence(actions)
    assert result["ok"] is True

    assert len(fake.posts) > 1, "超过 32KB 的序列应拆成多个请求"
    for body in fake.bodies:
        assert len(body) <= MAX_CHUNK_BYTES

    # 分块后的行序列应与一次性翻译完全一致
    translator = Translator(MouseState(width=1920, height=1080, rehome=False, cursor=None))
    expected = [
        line for step in translator.translate(validate_actions(actions)) for line in step.lines
    ]
    assert flat_lines(fake.posts) == expected


def test_run_sequence_rejects_mouse_actions_without_gadget(device_env):
    fake = device_env
    fake.mouse_available = False

    result = server.run_sequence([{"t": "click", "x": 10, "y": 10}])

    assert result["ok"] is False
    assert "mouse.available" in result["error"]
    assert fake.posts == []  # 预检失败，不应下发任何序列


def test_run_sequence_allows_keyboard_only_without_mouse(device_env):
    fake = device_env
    fake.mouse_available = False

    result = server.run_sequence([{"t": "type", "text": "a"}, {"t": "wait", "ms": 10}])

    assert result["ok"] is True
    assert len(fake.posts) == 1

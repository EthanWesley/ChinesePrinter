"""DeviceClient behaviour against a mocked HTTP transport."""

import pathlib
import sys

import httpx
import pytest

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "mcp-server"))

from chinese_printer_mcp.config import Config  # noqa: E402
from chinese_printer_mcp.device import DeviceClient, DeviceError  # noqa: E402


def make_client(handler):
    cfg = Config(host="kvm.test", port=8849, typewriter_port=8848)
    return DeviceClient(cfg, transport=httpx.MockTransport(handler))


def test_health_returns_json():
    client = make_client(
        lambda request: httpx.Response(200, json={"ok": True, "busy": False})
    )
    assert client.health()["busy"] is False


def test_capture_reads_frame_headers():
    def handler(request):
        assert request.url.path == "/capture"
        assert request.url.params["warmup"] == "3"
        return httpx.Response(
            200,
            content=b"\xff\xd8\xff\xd9",
            headers={
                "X-Frame-Width": "1920",
                "X-Frame-Height": "1080",
                "X-Frame-Format": "MJPEG",
            },
        )

    data, meta = make_client(handler).capture()
    assert data == b"\xff\xd8\xff\xd9"
    assert meta == {"width": 1920, "height": 1080, "format": "MJPEG"}


def test_capture_error_surfaces_device_message():
    client = make_client(
        lambda request: httpx.Response(503, json={"ok": False, "detail": "no /dev/video0"})
    )
    with pytest.raises(DeviceError) as exc:
        client.capture()
    assert "no /dev/video0" in str(exc.value)


def test_post_sequence_sends_ascii_lines():
    captured = {}

    def handler(request):
        captured["body"] = request.content
        captured["type"] = request.headers.get("content-type")
        return httpx.Response(200, json={"ok": True, "total": 2})

    result = make_client(handler).post_sequence(["step 0", "code 65"])
    assert result["total"] == 2
    assert captured["body"] == b"step 0\ncode 65\n"
    assert captured["type"].startswith("text/plain")


def test_post_sequence_reports_conflict():
    client = make_client(
        lambda request: httpx.Response(409, json={"ok": False, "msg": "打字机通道忙，请先停止"})
    )
    with pytest.raises(DeviceError) as exc:
        client.post_sequence(["code 65"])
    assert "打字机通道忙" in str(exc.value)


def test_connect_error_is_wrapped():
    def handler(request):
        raise httpx.ConnectError("refused", request=request)

    with pytest.raises(DeviceError) as exc:
        make_client(handler).health()
    assert "无法连接设备" in str(exc.value)


def test_typewriter_busy_is_best_effort():
    def handler(request):
        if request.url.port == 8848:
            raise httpx.ConnectError("offline", request=request)
        return httpx.Response(200, json={"ok": True})

    assert make_client(handler).typewriter_busy() is False


def test_typewriter_busy_reads_flag():
    def handler(request):
        return httpx.Response(200, json={"ok": True, "busy": True})

    assert make_client(handler).typewriter_busy() is True

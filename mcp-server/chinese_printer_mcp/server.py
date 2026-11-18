"""FastMCP server exposing the KVM automation channel to an AI agent.

Tools:
  capture_screen  – grab the target PC screen (returns a JPEG image block)
  run_sequence    – execute a list of mouse/keyboard actions
  stop_sequence   – graceful stop, escalating to abort
  get_status      – device availability, screen size, channel busy state
  set_config      – change device address / pointer behaviour

The device only executes primitive HID reports; all translation (text →
Alt codes, absolute → relative pointer motion, chunking) happens here.
"""

from __future__ import annotations

import io
import time

from mcp.server.fastmcp import FastMCP, Image
from PIL import Image as PILImage

from . import actions as action_mod
from .config import Config, load_config, save_config
from .device import DeviceClient, DeviceError
from .mouse import MouseState

MAX_CHUNK_BYTES = 32768
MAX_IMAGE_SIDE = 1600

mcp = FastMCP(
    "chinese-printer",
    instructions=(
        "控制一台 Luckfox Pico KVM：通过 HDMI 采集看目标机屏幕，通过 USB HID 模拟键鼠。\n"
        "典型流程：capture_screen 截图 → 规划动作 → run_sequence 执行 → 再截图验证。\n"
        "坐标使用截图原图的像素坐标（左上角为原点）。\n"
        "目标电脑需关闭 Windows「提高指针精确度」，否则鼠标定位会有偏差。"
    ),
)

CFG: Config = load_config()
DEVICE = DeviceClient(CFG)
MOUSE = MouseState(
    rehome=CFG.rehome_before_first_move, absolute=CFG.mouse_assume_absolute
)
SCREEN: dict[str, int] = {"width": 0, "height": 0}


# ---------------------------------------------------------------- helpers


def _sync_screen(width: int, height: int) -> None:
    if width > 0 and height > 0:
        SCREEN["width"], SCREEN["height"] = width, height
        MOUSE.set_screen(width, height)


def _ensure_screen() -> tuple[int, int]:
    """Screen size from the last capture, the device's last frame, or 1080p."""
    if SCREEN["width"] and SCREEN["height"]:
        return SCREEN["width"], SCREEN["height"]
    try:
        frame = DEVICE.health().get("capture", {}).get("last_frame") or {}
        width, height = int(frame.get("width") or 0), int(frame.get("height") or 0)
        if width and height:
            _sync_screen(width, height)
            return width, height
    except (DeviceError, TypeError, ValueError):
        pass
    _sync_screen(1920, 1080)
    return 1920, 1080


def _pack_chunks(steps: list[action_mod.Step]) -> list[list[str]]:
    """Split translated steps into ≤32 KB line batches (safe for the device)."""
    chunks: list[list[str]] = []
    current: list[str] = []
    size = 0
    for step in steps:
        for line in step.lines:
            cost = len(line) + 1
            if current and size + cost > MAX_CHUNK_BYTES:
                chunks.append(current)
                current, size = [], 0
            current.append(line)
            size += cost
    if current:
        chunks.append(current)
    return chunks


def _run_chunks(chunks: list[list[str]], timeout_s: int) -> dict:
    """Execute chunks sequentially, polling /health until each one finishes."""
    started = time.monotonic()
    deadline = started + timeout_s
    last_step = -1
    progress = 0
    executed = 0

    for chunk in chunks:
        if time.monotonic() > deadline:
            return {
                "ok": False,
                "error": f"序列执行超时（{timeout_s}s）",
                "steps_done": max(last_step + 1, 0),
                "failed_step": last_step + 1,
            }
        DEVICE.post_sequence(chunk)
        executed += 1

        while True:
            time.sleep(max(CFG.poll_interval_ms, 50) / 1000.0)
            health = DEVICE.health()
            if not health.get("busy"):
                break
            if time.monotonic() > deadline:
                DEVICE.stop()
                return {
                    "ok": False,
                    "error": f"序列执行超时（{timeout_s}s），已请求停止",
                    "steps_done": max(last_step + 1, 0),
                    "failed_step": int(health.get("step", last_step)) + 1,
                }

        progress = int(health.get("progress") or 0)
        step = int(health.get("step") or -1)
        error = (health.get("last_error") or "").strip()
        if error:
            failed = step if step >= 0 else max(last_step + 1, 0)
            return {
                "ok": False,
                "error": error,
                "steps_done": failed,
                "failed_step": failed,
                "lines_executed": progress,
            }
        last_step = max(last_step, step)

    elapsed_ms = int((time.monotonic() - started) * 1000)
    return {
        "ok": True,
        "steps_done": last_step + 1,
        "failed_step": None,
        "error": None,
        "lines_executed": progress,
        "chunks": executed,
        "elapsed_ms": elapsed_ms,
    }


# ---------------------------------------------------------------- tools


@mcp.tool()
def capture_screen(scale: float | None = None, quality: int | None = None):
    """截取目标电脑当前屏幕。

    返回 JPEG 图像（可直接查看）。坐标以原图分辨率为准，与 run_sequence 的
    x/y 一致；本工具返回的图可能已缩小，按比例换算后再填写坐标。

    Args:
        scale: 缩放比例（0.1–1.0），默认取配置 capture_scale（0.5）。
        quality: JPEG 质量（30–95），默认取配置 capture_quality（75）。
    """
    scale = CFG.capture_scale if scale is None else scale
    quality = CFG.capture_quality if quality is None else quality
    if not 0.1 <= scale <= 1.0:
        return "scale 必须在 0.1 到 1.0 之间"
    if not 30 <= quality <= 95:
        return "quality 必须在 30 到 95 之间"

    try:
        data, meta = DEVICE.capture()
    except DeviceError as exc:
        return (
            f"截图失败：{exc}\n"
            "排查：1) get_status 查看 capture.available；2) 设备上运行 "
            "`sh probe_device.sh` 确认 /dev/video* 与采集格式；"
            "3) 确认 HDMI 线已连接目标机。"
        )

    try:
        image = PILImage.open(io.BytesIO(data))
        image.load()
    except Exception as exc:  # noqa: BLE001 - 损坏帧直接反馈给模型
        return f"截图数据无法解码：{exc}"

    width, height = image.size
    _sync_screen(meta.get("width") or width, meta.get("height") or height)

    longest = max(width, height)
    target = min(int(longest * scale), MAX_IMAGE_SIDE)
    if target < longest:
        ratio = target / longest
        image = image.resize(
            (max(1, int(width * ratio)), max(1, int(height * ratio))),
            PILImage.LANCZOS,
        )

    buffer = io.BytesIO()
    image.convert("RGB").save(buffer, format="JPEG", quality=quality, optimize=True)
    return Image(data=buffer.getvalue(), format="jpeg")


@mcp.tool()
def run_sequence(actions: list[dict], timeout_s: int | None = None) -> dict:
    """执行一组鼠标/键盘动作（顺序执行，失败时报告具体步骤）。

    坐标是截图原图像素坐标（左上角原点）。动作类型：
      {"t":"move","x":100,"y":200}
      {"t":"click","x":100,"y":200,"button":"left"}     # x/y 省略则原地点击
      {"t":"doubleclick","x":100,"y":200}
      {"t":"drag","from":{"x":10,"y":10},"to":{"x":300,"y":300}}
      {"t":"scroll","dy":-3,"x":500,"y":400}            # dy 正=向上
      {"t":"type","text":"张三","enc":"auto"}            # 经 Alt 码输入，enc 可省略
      {"t":"key","keys":["ctrl","s"]}                   # 组合键
      {"t":"key_down","keys":["shift"]} / {"t":"key_up","keys":["shift"]}
      {"t":"wait","ms":300}

    批量填表的推荐模式：click 单元格 → type 文本 → key ["tab"] → …，
    完成后再次 capture_screen 验证。返回 ok/steps_done/failed_step/error。

    Args:
        actions: 动作列表（最多 2000 个）。
        timeout_s: 整体超时秒数，默认取配置 default_timeout_s（120）。
    """
    timeout_s = CFG.default_timeout_s if timeout_s is None else timeout_s
    try:
        validated = action_mod.validate_actions(actions)
    except action_mod.ActionError as exc:
        return {"ok": False, "error": str(exc), "steps_done": 0, "failed_step": 0}

    try:
        health = DEVICE.health()
    except DeviceError as exc:
        return {"ok": False, "error": str(exc), "steps_done": 0, "failed_step": 0}

    typewriter_busy = health.get("typewriter_busy")
    if typewriter_busy is None:
        typewriter_busy = DEVICE.typewriter_busy()
    if typewriter_busy:
        return {
            "ok": False,
            "error": "打字机通道（:8848）正在打字，两个通道不能同时操作目标机",
            "steps_done": 0,
            "failed_step": 0,
        }

    # 鼠标 gadget 缺失时在翻译前就拒绝，避免序列执行到一半才失败
    mouse_actions = {"move", "click", "doubleclick", "drag", "scroll"}
    if any(action.t in mouse_actions for action in validated) and not health.get(
        "mouse", {}
    ).get("available"):
        return {
            "ok": False,
            "error": "设备未检测到鼠标 gadget（mouse.available=false）。"
            "请用 get_status 查看，或在设备上运行 probe_device.sh 确认 /dev/hidg* 配置；"
            "仅键盘动作（type/key/wait）仍可执行。",
            "steps_done": 0,
            "failed_step": 0,
        }

    _ensure_screen()
    if CFG.rehome_before_first_move:
        MOUSE.forget_cursor()  # 每个序列首个鼠标动作前重新归位，消除人工移动造成的漂移
    translator = action_mod.Translator(MOUSE)
    try:
        steps = translator.translate(validated)
    except action_mod.ActionError as exc:
        return {"ok": False, "error": str(exc), "steps_done": 0, "failed_step": 0}

    chunks = _pack_chunks(steps)
    result = _run_chunks(chunks, max(5, timeout_s))
    result["steps_total"] = len(steps)
    if not result.get("ok"):
        result.setdefault("steps_done", 0)
        result["hint"] = (
            "失败点之前的动作已生效；可修正后只重发失败步骤之后的动作，"
            "或先 capture_screen 确认当前界面状态。"
        )
    return result


@mcp.tool()
def stop_sequence() -> dict:
    """停止当前序列。先请求行边界停止，20 秒内未停则强制中止并释放所有按键。"""
    try:
        DEVICE.stop()
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            time.sleep(0.3)
            if not DEVICE.health().get("busy"):
                return {"ok": True, "stopped": "graceful"}
        DEVICE.abort()
        return {"ok": True, "stopped": "aborted"}
    except DeviceError as exc:
        return {"ok": False, "error": str(exc)}


@mcp.tool()
def get_status() -> dict:
    """查看设备状态：通道是否忙、截图/鼠标/键盘是否可用、屏幕分辨率、当前配置。"""
    try:
        health = DEVICE.health()
    except DeviceError as exc:
        return {
            "ok": False,
            "error": str(exc),
            "device_config": {"host": CFG.host, "port": CFG.port},
        }

    frame = health.get("capture", {}).get("last_frame") or {}
    if frame.get("width") and frame.get("height"):
        _sync_screen(int(frame["width"]), int(frame["height"]))

    return {
        "ok": True,
        "busy": bool(health.get("busy")),
        "progress": health.get("progress", 0),
        "total": health.get("total", 0),
        "step": health.get("step", -1),
        "last_error": health.get("last_error", ""),
        "capture_available": bool(health.get("capture", {}).get("available")),
        "capture_backend": health.get("capture", {}).get("prefer"),
        "capture_format": frame.get("format"),
        "mouse_available": bool(health.get("mouse", {}).get("available")),
        "mouse_device": health.get("mouse", {}).get("device", ""),
        "keyboard_available": bool(health.get("keyboard", {}).get("available")),
        "typewriter_busy": bool(health.get("typewriter_busy")),
        "screen": {
            "width": SCREEN["width"] or frame.get("width") or 0,
            "height": SCREEN["height"] or frame.get("height") or 0,
        },
        "cursor": list(MOUSE.cursor) if MOUSE.cursor else None,
        "device_config": {
            "host": CFG.host,
            "port": CFG.port,
            "typewriter_port": CFG.typewriter_port,
            "mouse_assume_absolute": CFG.mouse_assume_absolute,
            "rehome_before_first_move": CFG.rehome_before_first_move,
        },
    }


@mcp.tool()
def set_config(
    host: str | None = None,
    port: int | None = None,
    mouse_assume_absolute: bool | None = None,
    rehome_before_first_move: bool | None = None,
    poll_interval_ms: int | None = None,
) -> dict:
    """修改并持久化设备配置（写入 ~/.chinese-printer-mcp.json）。

    Args:
        host: 设备地址，如 192.168.1.50。
        port: 自动化通道端口（默认 8849）。
        mouse_assume_absolute: 鼠标 gadget 为绝对坐标设备时设为 true（罕见）。
        rehome_before_first_move: 每个序列首个鼠标动作前把指针归位到左上角。
        poll_interval_ms: 轮询 /health 的间隔（默认 300ms）。
    """
    CFG.update(
        host=host,
        port=port,
        mouse_assume_absolute=mouse_assume_absolute,
        rehome_before_first_move=rehome_before_first_move,
        poll_interval_ms=poll_interval_ms,
    )
    MOUSE.rehome = CFG.rehome_before_first_move
    MOUSE.absolute = CFG.mouse_assume_absolute
    MOUSE.forget_cursor()  # 地址/行为变化后位置假设失效
    path = save_config(CFG)
    return {"ok": True, "config": CFG.to_dict(), "saved_to": str(path)}


def main() -> None:
    mcp.run()


if __name__ == "__main__":
    main()

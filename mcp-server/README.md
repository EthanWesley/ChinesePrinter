# chinese-printer-mcp

把 Luckfox Pico KVM 暴露成 MCP 工具：AI 通过 HDMI 采集看目标机屏幕，通过 USB HID 模拟鼠标键盘。

```
AI harness ──MCP stdio──▶ python -m chinese_printer_mcp.server
                            │ HTTP :8849 (/health /capture /seq /stop /abort /probe)
                            ▼
                    Luckfox Pico KVM (automation_server.sh)
                            │ USB HID (hidg)      │ HDMI 采集 (V4L2)
                            ▼                     ▼
                                         目标 PC
```

设备端只执行原始 HID 报告；文本→Alt 码、绝对坐标→相对位移、分块与轮询都在 PC 侧完成。

## 前置条件

- Python ≥ 3.10。
- 设备已装本仓库固件与脚本（在设备上 `sudo sh install.sh` 部署/更新），`automation_server.sh` 在 :8849 运行；先 `curl http://<设备IP>:8849/health` 确认。
- 目标 PC 开启 NumLock（Alt 码依赖数字小键盘），关闭 Windows「提高指针精确度」，否则点击会偏移。
- HDMI 采集线与 USB HID 线已接好。

## 安装

在仓库根目录执行（PyPI 慢或不可达时加 `-i https://pypi.tuna.tsinghua.edu.cn/simple`）：

```bash
pip install -e mcp-server
```

不想装成包时只装依赖（与 `pyproject.toml` 一致）：

```bash
pip install "mcp>=1.2.0" "httpx>=0.27" "pillow>=10.0" "pydantic>=2.6"
```

## 配置

默认读取 `~/.chinese-printer-mcp.json`，模板见 `mcp-server/config.json.example`：

```bash
cp mcp-server/config.json.example ~/.chinese-printer-mcp.json
```

三种方式，优先级为 默认值 < 配置文件 < 环境变量：

1. 编辑配置文件的 `host`（默认 `chinese-printer.local`）。
2. 环境变量 `CHINESEPRINTER_HOST`、`CHINESEPRINTER_PORT`、`CHINESEPRINTER_TYPEWRITER_PORT`；`CHINESEPRINTER_CONFIG` 可指定其它配置文件路径。
3. 运行中调用 `set_config(host=..., port=...)`，立即生效并写回配置文件。

确认连接：`get_status` 返回 `ok: true`，检查 `capture_available` / `mouse_available` / `keyboard_available` 与 `screen`。

`set_config` 的 `mouse_assume_absolute`、`rehome_before_first_move`、`poll_interval_ms` 均会实际生效。
绝对坐标模式需要两端一致：PC 侧 `set_config(mouse_assume_absolute=true)`，同时设备端
`/opt/chinese-printer/chinese-printer.env` 设 `MOUSE_ABSOLUTE=1` 并重启服务；此时坐标以
`mabs` 单条报告下发（0–32767 归一化），不再分段与 rehome。

## 接入 harness

stdio 启动命令（FastMCP 默认 stdio）：

```bash
python -m chinese_printer_mcp.server   # 安装后也可用入口 chinese-printer-mcp
```

通用 MCP JSON（Cline / Claude Desktop 类客户端；示例，按你的 harness 文档调整键名）：
```json
{
  "mcpServers": {
    "chinese-printer": {
      "command": "python",
      "args": ["-m", "chinese_printer_mcp.server"],
      "env": {"CHINESEPRINTER_HOST": "192.168.1.50", "CHINESEPRINTER_PORT": "8849"}
    }
  }
}
```

Codex CLI 的 `~/.codex/config.toml`（示例，按你的版本文档调整）：

```toml
[mcp_servers.chinese-printer]
command = "python"
args = ["-m", "chinese_printer_mcp.server"]

[mcp_servers.chinese-printer.env]
CHINESEPRINTER_HOST = "192.168.1.50"
CHINESEPRINTER_PORT = "8849"
```

用官方 `mcp` Python SDK 直接驱动（Open Interpreter 或自研 harness）：

```python
import asyncio, os
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

async def main():
    params = StdioServerParameters(
        command="python", args=["-m", "chinese_printer_mcp.server"],
        env={**os.environ, "CHINESEPRINTER_HOST": "192.168.1.50"})
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            print((await session.call_tool("get_status", {})).content)
            shot = await session.call_tool("capture_screen", {"scale": 0.5, "quality": 75})
            print(shot.content)  # 含 image 块
            print((await session.call_tool("run_sequence", {
                "actions": [{"t": "key", "keys": ["ctrl", "s"]}]})).content)

asyncio.run(main())
```

## 工具速查

| 工具 | 参数 | 返回 |
|---|---|---|
| `capture_screen` | `scale` 0.1–1.0（默认 0.5）、`quality` 30–95（默认 75） | JPEG 图像块；最长边上限 1600px |
| `run_sequence` | `actions`（≤2000 个）、`timeout_s`（默认 120） | `ok` / `steps_total` / `steps_done` / `failed_step` / `error` / `elapsed_ms` |
| `stop_sequence` | 无 | `ok`、`stopped`: `graceful` 或 `aborted` |
| `get_status` | 无 | 忙闲、采集/鼠标/键盘可用性、分辨率、光标假设、当前配置 |
| `set_config` | `host` / `port` / `mouse_assume_absolute` / `rehome_before_first_move` / `poll_interval_ms` | 新配置与写入路径 |

动作类型：`move`、`click`、`doubleclick`、`drag`、`scroll`、`type`、`key`、`key_down`、`key_up`、`wait`。未知类型或非法字段会整单拒绝并报出下标。

填表示例（点击 → 输入 → Tab 循环 → 保存 → 截图验证）：

```json
[
  {"t": "click", "x": 420, "y": 310},
  {"t": "type", "text": "张三"},
  {"t": "key", "keys": ["tab"]},
  {"t": "type", "text": "13800000000"},
  {"t": "key", "keys": ["tab"]},
  {"t": "type", "text": "2026-11-17"},
  {"t": "key", "keys": ["ctrl", "s"]},
  {"t": "wait", "ms": 500}
]
```

`type` 用 Alt 码逐字符输入，`enc` 可选 `auto`（默认，有 GBK 表时用 `gbk`）/`gbk`/`unicode`/`mdwin`/`ascii`/`base64`，目标机代码页与输入法需与所选编码匹配。`scroll` 的 `dy` 为正表示向上。

## 坐标与鼠标

- `x`/`y` 是 `capture_screen` 原图像素坐标（左上角原点），与 `run_sequence` 一致；返回图会按 `scale` 缩小（最长边另有 1600px 上限），换算后再填：`原图坐标 = 图中坐标 ÷ 实际缩放比`。
- 设备鼠标是相对位移 gadget：PC 侧维护假想光标位置，单次移动按 127px 分段。
- 若 probe 显示鼠标 gadget 为绝对坐标（report descriptor 含 Absolute 位），两端都切到绝对模式（见「配置」），每条 `mabs` 直达目标点。
- 序列首个鼠标动作前默认 rehome（连续 `mmove -127 -127` 钉到左上角），人工动过鼠标后开新序列也能恢复。
- 仍漂移时先 `capture_screen` 确认界面，再重发失败点之后的动作；`failed_step` 之前的动作已生效，不要整段重放。

## 故障排查

| 现象 | 处理 |
|---|---|
| `无法连接设备` | 确认设备上电、同网段、`host` 正确；`curl http://<host>:8849/health` 直连验证 |
| `capture` 返回 503 | 设备无 `/dev/video*`、`capture` 二进制缺失或 HDMI 未接；设备上跑 `sh probe_device.sh` |
| `mouse_available: false` | 没有 `/dev/hidg*` 鼠标 gadget，鼠标动作不生效，可先用键盘 |
| 409 通道忙 | `:8848` 打字机正在打字，或 `:8849` 自身在跑序列；先 `stop_sequence` 或等打字结束 |
| 乱码 / 无输入 | 检查目标机 NumLock、输入法与代码页，换 `type.enc`；Alt 码必须走数字小键盘 |
| 点击偏移 | 关闭「提高指针精确度」；分辨率变化后重新 `capture_screen`；重跑序列触发 rehome |
| 序列超时 | 调大 `timeout_s`，或拆成多段执行 |

## 测试

```bash
cd mcp-server && python -m pytest tests -q
```

编码回归（与网页 JS 引擎逐字节一致），在仓库根目录：

```bash
node tests/encoding.test.cjs
```

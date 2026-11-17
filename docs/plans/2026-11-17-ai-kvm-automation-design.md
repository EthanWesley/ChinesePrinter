# AI 可操作 KVM 自动化通道

现有 :8848 打字机保持不变，新增 :8849 自动化通道：AI 截屏 → 规划操作序列 →
设备执行 → 再截屏验证。设备端只做采集与哑执行，PC 端 Python MCP 服务器做全部
高层翻译。

## 分工

- 设备（RV1106 单核 A7）：V4L2 单帧抓取输出 JPEG；执行键盘/鼠标原始 HID 报告；
  行边界响应停止/暂停；逐步记录进度。
- PC（MCP 服务器）：文本→Alt 码编码（与网页 JS 引擎逐字节一致）；绝对坐标→
  相对鼠标位移；序列分块与轮询；把 JPEG 作为 Image content block 交给 LLM。

## 新端口与端点

`automation_server.sh` 由 socat 逐连接 fork，镜像 server.sh 的纯 shell 模式。
状态文件沿用 `/tmp/chinese-printer/`，加 `auto_` 前缀。

| 端点 | 方法 | 说明 |
|---|---|---|
| `/health` | GET | busy/progress/total/step/error、capture/mouse/keyboard 可用性、typewriter_busy |
| `/capture` | GET | 调 `capture` 输出 JPEG；`?warmup=N`；响应体经 `cat` 直写 socket |
| `/seq` | POST | 请求体为行协议纯文本，落盘后后台执行 seq_writer |
| `/stop` | POST | 行边界优雅停止 |
| `/abort` | POST | 停止 + kill + 向两个 hidg 写全零报告 |
| `/probe` | GET | probe_device.sh 的 JSON 诊断 |

## 行协议（设备输入）

每行一条，纯 ASCII：`tap <mods> <kc>`、`down/up <mods> <kc>`、`code <n>`、
`control <name>`、`mmove <dx> <dy>`、`mbtn <mask>`、`mclick/mdclick <btn>`、
`wheel <dy> [dx]`、`wait <ms>`、`step <n>`、`kbd/mse <hex...>`（逃生舱）。

mods 为 HID modifier 位掩码（bit0=LCtrl, 1=LShift, 2=LAlt, 3=LGui, 4..7 右侧），
kc 为 HID usage。报告间隔默认 8ms（bInterval），与 hid_writer 一致。

## 高层动作（MCP `run_sequence` 输入）

`move`、`click`、`doubleclick`、`drag`、`scroll`、`type`、`key`、`key_down`、
`key_up`、`wait`。坐标即 capture 原图像素坐标。`type.enc` 支持 auto/gbk/unicode/
mdwin/ascii/base64，与网页一致。未知动作或非法字段整单拒绝并报索引。

执行结果返回 `steps_total/steps_done/failed_step/error/elapsed_ms`，
`steps_done` 取设备最后写入的 `step` 标记，失败后可从该点续传。

## 效率

- 截图默认 scale=0.5、quality=75；1080p 交付约 80–150KB。
- 轮询起始 300ms，每 10 次退避到 1s；超时按报告数×8ms×1.5 + 等待 + 15s。
- 行协议超过 32KB 按动作边界分块，type 内部按 128 字符再分。
- 双通道互斥复用各自 status.json 的 busy 字段，不引入新锁文件：
  :8849 启动前查 :8848 busy；:8848 api_type 启动前查 auto_status busy。

## 采集实现

`capture.c` 枚举格式：MJPEG 直通（SOI/EOI 截取，不解码不缩放）；YUYV 回退
libjpeg-turbo `jpeg_write_raw_data` 4:2:2 直接编码。默认丢弃 3 帧预热。
YUYV 路径依赖静态链接的 libjpeg-turbo（`native/build.sh` 交叉编译）。

## 鼠标

PC 侧维护光标位置：序列首个鼠标动作前 rehome（多次 `mmove -127 -127` 钉到
左上角），随后按 127 像素步长分段移动，尾报告补余数。点击前等待 50ms 稳定。
目标电脑应关闭「提高指针精确度」以消除加速曲线。鼠标 gadget 若为绝对坐标
（report descriptor 判断），预留 `mouse_assume_absolute` 开关。

## 风险

- 固件未启用 UVC：/health 报 `capture.available=false`，功能降级为盲操作。
- 无鼠标 gadget：翻译阶段拒绝鼠标动作并说明。
- 鼠标报告长度非 4 字节：`--mouse-report-size` 可配。
- 人工移动鼠标导致位置漂移：rehome 兜底，截屏验证闭环。

## 验收

1. `sh probe_device.sh` 确认采集格式与鼠标 gadget。
2. 真机 `curl :8849/capture -o t.jpg` 可打开。
3. `curl -X POST :8849/seq --data-binary @seq.txt` 执行组合键、打字、点击。
4. 8848 打字中 :8849 返回 409，反之亦然。
5. `node tests/encoding.test.cjs`、`python3 tests/native_controls.py`、
   `python3 tests/native_seq_protocol.py`、`python3 -m pytest mcp-server/tests` 全过。

## 实现状态（2026-11-17）

已完成并可在无硬件环境验证的部分：

- `native/capture.c`：V4L2 单帧 + MJPEG 直通 + YUYV→libjpeg-turbo；`--probe`
  无设备时输出 `[]` 且退出码 0；`--selftest` 生成 640×360 渐变 JPEG 验证编码
  路径（含 `--meta` 元数据）。
- `native/seq_writer.c`：全部行协议指令、stop/pause/progress/step/error 文件；
  `tests/native_seq_protocol.py` 5 项通过（全协议、暂停恢复、停止、未知指令、
  绝对模式拒绝）。
- `automation_server.sh`：`/health` `/capture` `/seq` `/stop` `/abort` `/probe`
  在本机以 `/dev/null` 伪设备验证；`/capture` 二进制正文与 `X-Frame-*` 头正确；
  打字机忙时 `/seq` 返回 409。
- `server.sh`：新增 4 行跨通道检查；`node tests/encoding.test.cjs` 16 项仍通过；
  自动化通道忙时 `/api/type` 拒绝。
- `mcp-server/`：编码 parity（65 条 fixtures，覆盖 5 种编码 × 13 组文本）、
  动作翻译、鼠标分段、HTTP 客户端共 36 项单测通过。

待真机验收（需要 Luckfox 设备）：

- M0 `probe_device.sh` 实测：`/dev/video*` 格式、鼠标 gadget 与报告长度。
- M1 实拍 JPEG 可打开；M3/M4 真机组合键、打字、点击、拖拽、滚轮。
- M6 端到端：截屏 → 批量填表 → 截屏验证。


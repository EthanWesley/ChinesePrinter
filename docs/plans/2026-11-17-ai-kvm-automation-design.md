# AI 可操作 KVM 自动化通道

现有 :8848 打字机保持不变，新增 :8849 自动化通道：AI 截屏 → 规划操作序列 →
设备执行 → 再截屏验证。设备端只做采集与哑执行，PC 端 Python MCP 服务器做全部
高层翻译。

## 分工

- 设备（RV1106 单核 A7）：V4L2 单帧抓取输出 JPEG（单平面/Multiplanar）；
  执行键盘/鼠标原始 HID 报告；行边界响应停止/暂停，`wait` 也可被 stop 中断；
  逐步记录进度。
- PC（MCP 服务器）：文本→Alt 码编码（与网页 JS 引擎逐字节一致）；绝对坐标→
  相对鼠标位移；序列分块与轮询；把 JPEG 作为 Image content block 交给 LLM。

## 新端口与端点

`automation_server.sh` 由 socat 逐连接 fork，镜像 server.sh 的纯 shell 模式。
状态文件沿用 `/tmp/chinese-printer/`，加 `auto_` 前缀。

| 端点 | 方法 | 说明 |
|---|---|---|
| `/health` | GET | busy/progress/total/step/error、capture/mouse/keyboard 可用性、typewriter_busy |
| `/capture` | GET | 输出 JPEG；首选从 Web H.264 流抽帧（`CAPTURE_PREFER=webstream`，不中断视频），失败回退 V4L2 直采；`?warmup=N`；响应体经 `cat` 直写 socket；`X-Frame-Backend` 头标明实际后端 |
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

`capture.c` 同时支持单平面与 Multiplanar（Rockchip rkcif/rkisp）V4L2：
- MJPEG：SOI/EOI 截取直通，不解码不缩放（USB UVC 采集芯片路径）。
- YUYV：libjpeg-turbo `jpeg_write_raw_data` 4:2:2 直接编码。
- NV16/NV12：先解成交织 YUYV，再走同一编码器。
- MPLANE 抓帧会设置 `VIDIOC_REQBUFS count=0` 后再 close；最后一帧不再入队，
  规避当前 Rockchip 固件在 `vb2_fop_release` 处的卡死。
默认丢弃 3 帧预热；静态链接 libjpeg-turbo 由 `native/build.sh` 交叉编译。

真机 `192.168.10.114` 上 `/dev/video0` 是 rkcif 直采节点（640×480，YUYV），
必须显式使用；`video11+` 的 rkisp 节点在本固件上 `STREAMON` 会触发内核 oops，
已通过 `CAPTURE_DEVICE=/dev/video0` 在设备 env 中锁定。

## 鼠标

PC 侧维护光标位置：序列首个鼠标动作前 rehome（多次 `mmove -127 -127` 钉到
左上角），随后按 127 像素步长分段移动，尾报告补余数。点击前等待 50ms 稳定。
目标电脑应关闭「提高指针精确度」以消除加速曲线。若 gadget 为绝对坐标，
PC 与设备须同时开启绝对模式（`mouse_assume_absolute` + `MOUSE_ABSOLUTE=1`），
使用 `mabs` 报告 16-bit 归一化坐标；真机 `/dev/hidg2` 是 3 字节相对鼠标，
因此安装参数固定为 `MOUSE_DEVICE=/dev/hidg2 MOUSE_REPORT_SIZE=3 MOUSE_ABSOLUTE=0`，
滚轮在该 gadget 上不可用。

## 风险

- 采集节点选错：真机 rkisp 节点会内核 oops；env 已锁定 `/dev/video0`。
- 目标机 HDMI 无信号/休眠：`capture` 超时返回 503，MCP 侧转成明确错误；
  接通信号后 `/capture` 自动恢复。
- 无鼠标 gadget：翻译阶段拒绝鼠标动作并说明。
- 鼠标报告长度非 4 字节：`--mouse-report-size` 可配（真机为 3）。
- 人工移动鼠标导致位置漂移：rehome 兜底，截屏验证闭环。
- `mcp` SDK 2.x 已重命名 `FastMCP`；依赖必须锁定 `mcp>=1.2,<2`。

## 验收

1. `sh probe_device.sh /tmp/capture` 确认采集格式与鼠标 gadget。
2. 真机 `curl :8849/capture -o t.jpg` 可打开（需目标机 HDMI 有信号）。
3. `curl -X POST :8849/seq --data-binary @seq.txt` 执行组合键、打字、点击。
4. 8848 打字中 :8849 返回 409，反之亦然。
5. `node tests/encoding.test.cjs`、
   `python3 tests/native_seq_protocol.py .deleted/seq_writer-host`、
   `python -m pytest mcp-server/tests` 全过。

## 实现状态（2026-11-17，真机 192.168.10.114 已部署）

已完成并验证：

- `native/capture.c`：单平面 + MPLANE；MJPEG/YUYV/NV16/NV12；
  `--probe` 在真机正确枚举出 21 个视频节点及 MPLANE 格式；
  `--selftest` 生成 640×360 渐变 JPEG 验证编码路径。
  真机锁定 `/dev/video0` 后 `STREAMON/STREAMOFF/close` 不再卡死。
- `native/seq_writer.c`：全部行协议指令、stop/pause/progress/step/error 文件；
  `wait` 现可被 `/stop` 中断；`tests/native_seq_protocol.py` 5 项通过。
- `automation_server.sh`：`/health` `/capture` `/seq` `/stop` `/abort` `/probe`
  全部在真机验证。`wait` 序列的 `total` 现按非空行计数，客户端多带换行不再
  虚增一步。
- `server.sh`：双通道互斥真机验证通过；修复了 dash 下 `source` 不存在的
  `settings.env` 导致后台打字任务静默退出的问题。
- `install.sh`：修复自动化 init 脚本路径被全局替换误改为
  `/opt/chinese-printer-auto` 的问题；修复主服务 `pkill -f server.sh`
  误杀 `automation_server.sh` 的问题；env 新增 `CAPTURE_DEVICE` 及鼠标参数。
- `mcp-server/`：编码 parity（65 条 fixtures）、动作翻译、鼠标分段、HTTP 客户端
  及集成测试共 **46 项通过**；依赖锁定 `mcp>=1.2,<2`；真实设备
  `DeviceClient` 的 health / typewriter_busy / probe / seq / stop 均通过。

真机部署参数：`APP_PORT=8848`、`AUTOMATION_PORT=8849`、
`CAPTURE_DEVICE=/dev/video0`、`CAPTURE_YIELD_KVM=1`、`HID_DEVICE=/dev/hidg0`、
`MOUSE_DEVICE=/dev/hidg2`、`MOUSE_REPORT_SIZE=3`、`MOUSE_ABSOLUTE=0`。

### 截图链路实测（2026-11-18，HDMI 源已接通）

HDMI 源接通后（rk628 锁 1920×1080@60），完整截图链路已实测打通：

- `/capture` 返回 **1920×1080 有效桌面 JPEG**（ffd8 头正确，约 100 KB，
  单帧约 1.4 s）。截图内容清晰，任务栏图标/时间/文字均可辨认。
- MCP `DeviceClient.capture()` 返回 `(bytes, headers)`，JPEG 可正常解码。
- FastMCP `capture_screen(scale=0.5, quality=75)` 返回 `mcp...Image` 图像块，
  缩放后 960×540、约 20 KB，画质仍可辨认任务栏——满足 AI 看图规划需求。
- 5 个 MCP 工具（capture_screen / run_sequence / stop_sequence / get_status /
  set_config）均正常注册。

**硬件限制与解决**：rkcif 只有一路 DMA，设备自带 `kvm_video`（Web 视频流）
与截图无法同时独占 `/dev/video0`。已验证的可选节点均不可用：

- rkisp 节点（video11+）：`STREAMON` 触发内核 oops；
- rkcif_id1..3（video1..3）：虽能 `STREAMON` 但没有数据流；
- rkcif_scale_ch0（video4）：只支持 Bayer（BYR2），不支持 YUYV/NV12；
- media-ctl 改链路绑定：视频流运行时返回 `resource busy`。

因此 `CAPTURE_YIELD_KVM=1`（默认）时，`/capture` 首轮抓帧失败后会临时
kill `kvm_video` 让出设备，抓帧成功后 `kvm_app` 在数秒内自动把视频服务拉起
（实测 Web 端口恢复 200）。代价是每次截图时 Web 视频短暂中断约 3 秒。
若不允许中断，设 `CAPTURE_YIELD_KVM=0`，此时 Web 视频占用期间 `/capture`
返回 503。

剩余外部条件：

- 真机键鼠实动作（组合键、打字、点击、拖拽）尚未在目标电脑上肉眼验收；
  设备端协议与状态回传已通过 `wait` 类安全序列验证。
- M6 完整闭环（截屏 → 批量填表 → 再截屏验证）待键鼠实动作验收后执行。

### 更优雅的截图后端：Web 视频流抽帧（2026-11-18，已实测部署）

前述 V4L2 直采需要临时让出 `kvm_video`，会中断 Web 视频约 3 秒。发现设备
自带的 `kvm_app`（Luckfox PicoKVM 固件）其实**已经在把 video0 编码为 H.264
并持续推送到 `http://127.0.0.1:80/video/stream`**（`Content-Type: video/x-h264`，
免认证，Annex-B NALU `00 00 00 01 41 e0` 开头）。于是截图不必再抢
`/dev/video0` 的单路 DMA——直接从这条现成的 H.264 流解一帧即可。

**实现**（`automation_server.sh` + `install.sh`）：

- 新增 `CAPTURE_PREFER`（默认 `webstream`）选择截图后端：
  - `webstream`（首选）：设备自带 `ffmpeg` 从 `WEBSTREAM_URL`
    （默认 `http://127.0.0.1:80/video/stream`）抽 1 帧转 JPEG。
      全程不触碰 video0、不 kill `kvm_video`、Web 视频零中断。
    `WEBSTREAM_TIMEOUT` 默认 25 s（受关键帧间隔影响，实测单帧约 4–8 s）。
  - `v4l2`（保底）：原 `capture` 二进制直采 `/dev/video0`，失败时沿用
    `CAPTURE_YIELD_KVM=1` 的让出逻辑。webstream 出错时自动回退到此路径。
- `/capture` 响应新增 `X-Frame-Backend: webstream|v4l2` 头（实际生效后端）；
  `/health` 的 `capture` 新增 `prefer` 与 `webstream.available/url`。
- MCP 端 `DeviceClient.capture()` 的 headers 增加 `backend`，
  `get_status()` 增加 `capture_backend`。均为增量字段，向后兼容。

**实测结果（192.168.10.114）**：

- 默认 webstream：`X-Frame-Backend: webstream`，1920×1080 mjpeg，
  连续 3 帧均成功、约 4.7 s/帧；截图前后 `kvm_video`（PID 2964）始终存活，
  `/video/stream` 持续 HTTP 200 —— **Web 视频零中断**。
- 切到 `CAPTURE_PREFER=v4l2`：返回 `X-Frame-Backend: v4l2`、YUYV，保底路径可用；
  测试后已恢复默认 webstream。
- 抽出的画面为有效桌面（Ubuntu dock、时间、壁纸清晰可辨）。

**注意**：ffmpeg 4.x 靠扩展名推断输出格式，临时文件名带 `.tmp.<pid>` 后缀，
必须显式加 `-f mjpeg`，否则报 `Unable to find a suitable output format`。


# Microsoft Edge Add-ons Store Listing — ChinesePrinter Sidebar

> 用途：Edge Add-ons 提交表单的文案。分两部分：Short description（摘要，≤132 字符）与 Detailed description（详细描述）。
>
> **URL 安全约定**：本文件所有面向商店表单的文案**不出现任何带 scheme 的链接**（不写 `http://`、`https://`、`chrome://`、`edge://`）。商店表单会对文案与 URL 字段做可达性校验，含 scheme 的示例地址会被判定为"broken or invalid"而拦截提交。示例地址一律以裸地址 + 端口文字描述呈现。

---

## Short description (summary, ≤132 characters)

```
Open the Chinese typewriter interface of your local device in a side panel, based on the IP/domain of the page you are viewing.
```

Character count: 127 / 132

---

## Detailed description

```
ChinesePrinter Sidebar brings the Chinese typewriter (中文打字机) interface of your local device directly into your browser's side panel, so you can type and send Chinese text without leaving the page you are working on.

WHAT IT DOES
ChinesePrinter Sidebar works together with a ChinesePrinter device or service that exposes a web-based typewriter interface on port 8848. Instead of manually navigating to the device's IP address, you simply click the extension icon and the typewriter interface opens in the browser's native side panel, next to whatever page you are already viewing.

KEY FEATURES

1. One-click side panel
   Click the extension's toolbar icon and the side panel opens automatically. No manual navigation to the device address is required.

2. Automatic device detection
   The extension reads the hostname (IP address or domain) of the page you are currently viewing and loads the typewriter interface from that same host on port 8848. For example, if you are viewing a page served from the address 192.168.10.104, the panel loads the typewriter interface from that same address on port 8848.

3. Works alongside the current page
   The typewriter interface is displayed in the browser's native side panel, so it stays open and visible while you continue to browse or read the main page. Nothing is covered and no separate window is needed.

4. Automatic reload on tab switch
   When you switch to another tab, the side panel automatically reloads the typewriter interface for the device of the newly active tab. If you manage several devices, switching tabs switches the target device accordingly.

5. Manual refresh
   A refresh button in the top bar lets you reload the typewriter interface at any time, for example after reconnecting the device.

6. Target address display
   The top bar shows the exact device address currently loaded (for example, the address 192.168.10.104 on port 8848), so you always know which device you are controlling.

7. Friendly error handling
   If the current page is not a regular web page (for example the browser's own settings, extensions, history, or new-tab pages), the extension displays a clear message and a hint instead of failing silently.

HOW TO USE

1. Make sure your ChinesePrinter device is powered on and reachable from your computer (typically on the same local network).
2. In the browser, open the device's address (for example, the address 192.168.10.104).
3. Click the ChinesePrinter Sidebar icon in the toolbar.
4. The side panel opens on the right and automatically loads the typewriter interface from that address on port 8848.
5. Type your Chinese text in the panel and use it as usual.
6. If you need to reload, click the refresh button in the top bar.

REQUIREMENTS

- A ChinesePrinter device or service running the typewriter web interface on port 8848.
- The device must be reachable from your browser, typically on the same local network.
- The current tab must be a regular web page served over http or https.
- A Chromium-based browser that supports the Side Panel API (Chrome 114+ and equivalent Microsoft Edge versions).

PERMISSIONS AND PRIVACY

This extension requests only the permissions it needs to fulfil its single purpose:
- activeTab and tabs: used to read the hostname of the currently active tab and to detect tab switches, so the correct device page can be loaded and reloaded.
- sidePanel: used to display the typewriter interface in the browser's side panel.

The extension does not collect, store, or transmit any personal data. It reads the hostname of the current tab locally, only to determine which device's typewriter page to open. There are no analytics, no tracking, no advertising, and no developer-operated servers. The only network request made is from your browser to your own local device. See the privacy policy for full details.

NOTES AND LIMITATIONS

- The device port is fixed at 8848 in this version.
- The extension communicates only with your own local device; it never contacts any server operated by the developer.
- Internal browser pages (the browser's own settings, extensions, and similar pages) are not supported, because their addresses cannot be resolved to a device.
```

---

## 提交注意

### Privacy policy URL（本次提交被拦截的直接原因）

填写值：

```
https://ethanwesley.github.io/ChinesePrinter/privacy-policy.html
```

该字段曾返回 **HTTP 404**，导致商店提示 "The entered URL(s) seem broken or invalid. Please verify that each URL is reachable."

**根因**：`privacy-policy.html` 位于仓库根目录，但此前**从未被 git 跟踪**（`git status` 显示为 `?? privacy-policy.html`）。GitHub Pages 已启用（source = `main` / 根目录，build_type = legacy），但部署产物中不含该文件，故页面 404。

**修复**：将 `privacy-policy.html` 提交并推送到 `main`，Pages 会自动重新构建（约 1 分钟）。构建完成后该 URL 返回 200。

**校验命令**：

```bash
curl -s -o /dev/null -w "%{http_code}\n" \
  https://ethanwesley.github.io/ChinesePrinter/privacy-policy.html
```

### 其它字段

- **Website / Support URL**：可填仓库主页 `https://github.com/EthanWesley/ChinesePrinter`（实测返回 200）。
- **Detailed description 中的地址**：已全部去除 scheme，示例地址为裸 IP + 文字端口（如"the address 192.168.10.104 on port 8848"），不构成可点击外链，不参与 URL 可达性校验。
- 商店若要求隐私政策页面必须为可读 HTML（而非源码视图），GitHub Pages 渲染的页面满足该要求；不要改用 raw 链接（会以纯文本返回 HTML 源码）。

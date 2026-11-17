# ChinesePrinter Sidebar - Chrome 扩展

点击 Chrome 工具栏图标，在侧边栏（Side Panel）打开当前访问 IP/域名对应的中文打字机界面（端口 8848）。

## 功能

- 点击工具栏图标，自动在右侧打开侧边栏
- 读取当前标签页的 IP/域名，拼接 `:8848` 端口加载打字机界面
- 切换标签页时自动重新加载
- 顶部有刷新按钮可手动重载

## 目录结构

```
chrome-extension/
├── manifest.json       # 扩展配置（MV3）
├── background.js       # 后台脚本：点击图标打开侧边栏
├── sidepanel.html      # 侧边栏 UI
├── sidepanel.js        # 侧边栏逻辑：获取 IP + iframe 加载
├── icons/
│   ├── icon16.png      # 工具栏图标
│   ├── icon48.png      # 扩展管理页图标
│   └── icon128.png     # Chrome Web Store 图标
└── README.md
```

> 本扩展与主项目（ChinesePrinter 打字机服务）完全独立，仅通过 HTTP 访问设备 8848 端口，不修改原项目代码。

## 安装方法（开发者模式）

1. 打开 Chrome，访问 `chrome://extensions/`
2. 右上角开启「开发者模式」
3. 点击「加载已解压的扩展程序」
4. 选择本目录（`chrome-extension/`）
5. 工具栏会出现键盘图标

## 使用方法

1. 在浏览器访问设备 IP 页面（如 `http://192.168.10.104/`）
2. 点击工具栏的键盘图标
3. 右侧侧边栏自动打开 `http://192.168.10.104:8848/`
4. 即可在侧边栏中输入中文并打字

## 注意事项

- 当前标签页必须是 `http://` 或 `https://` 协议（不支持 `chrome://` 等内部页面）
- 设备需运行 ChinesePrinter 服务（默认端口 8848）
- 如需修改端口，编辑 `sidepanel.js` 顶部的 `PORT` 常量
- Chrome 114+ 支持 Side Panel API

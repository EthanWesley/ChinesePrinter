// background.js - 点击扩展图标时打开侧边栏
// 使用 Chrome Side Panel API，点击图标即打开/聚焦侧边栏

// 设置点击 action 图标的行为：直接打开侧边栏
chrome.sidePanel
  .setPanelBehavior({ openPanelOnActionClick: true })
  .catch((error) => console.error("setPanelBehavior 失败:", error));

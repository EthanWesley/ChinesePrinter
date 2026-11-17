// sidepanel.js - 获取当前标签页的 IP/域名，拼接 :8848 加载到 iframe

const PORT = 8848;

const targetEl = document.getElementById("target");
const frameEl = document.getElementById("frame");
const contentEl = document.getElementById("content");
const refreshBtn = document.getElementById("refreshBtn");

// 从 URL 中提取 hostname（IP 或域名）
function getHostname(url) {
  try {
    const u = new URL(url);
    return u.hostname;
  } catch (e) {
    return null;
  }
}

// 显示错误信息
function showError(msg, hint) {
  contentEl.innerHTML =
    '<div class="error">' + msg +
    (hint ? '<div class="hint">' + hint + '</div>' : '') +
    '</div>';
}

// 加载打字机界面
async function loadPanel() {
  try {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    if (!tab || !tab.url) {
      showError("无法获取当前标签页", "请尝试切换标签后重新点击图标");
      return;
    }

    // 跳过 chrome:// 和扩展页面
    if (/^(chrome|edge|about|chrome-extension):/i.test(tab.url)) {
      showError("不支持在此页面使用", "请切换到普通网页（如设备 IP 页面）后重试");
      return;
    }

    const hostname = getHostname(tab.url);
    if (!hostname) {
      showError("无法解析当前页面地址", "请确保当前在 http:// 或 https:// 页面");
      return;
    }

    const targetUrl = "http://" + hostname + ":" + PORT + "/";
    targetEl.textContent = hostname + ":" + PORT;
    targetEl.title = targetUrl;
    frameEl.src = targetUrl;
  } catch (e) {
    showError("加载失败: " + e.message);
  }
}

refreshBtn.addEventListener("click", () => {
  // 恢复 iframe 结构（如果之前出错了）
  if (!document.getElementById("frame")) {
    contentEl.innerHTML = '<iframe id="frame" src="about:blank"></iframe>';
  }
  loadPanel();
});

// 当用户切换标签时自动重新加载
chrome.tabs.onActivated.addListener(() => {
  loadPanel();
});

// 初始加载
loadPanel();

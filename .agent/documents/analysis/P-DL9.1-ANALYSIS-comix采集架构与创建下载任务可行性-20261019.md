# comix 采集架构与「创建下载任务」可行性分析

> 目标：在写回代码之前，回答 6 个架构问题：采集逻辑写回是否有用、WebView2 能否当真实浏览器、
> 是否改弹窗、URL 驱动创建下载任务是否可行、能否内置真实浏览器。
> 依据：`comix_client.dart` / `webview.dart` / `download_manager_page.dart` 实读 + `data/logs.txt` 实跑日志。

---

## 0. 结论速览（TL;DR）

| # | 问题 | 结论 |
|---|---|---|
| 1 | 采集逻辑写回 mangrove 还有用吗 | **有用，但只能定位为「人机协作采集器」**：借真实浏览器过一次 CF → 复用会话采集。不能承诺无头全自动过 CF。主采集通道应从 WebView2 迁到「真实 Chrome + CDP」，WebView2 降级为图片字节兜底/展示。 |
| 2 | "远程计算机拒绝网络连接"= 被判定第三方？ | **不是**。这是 `ComixCDPWorker.isAvailable()` 探 `localhost:9222` 的**本地 TCP 连接被拒（errno 1225）**，因为 App 没自动拉起 Chrome、9222 无监听。CF 拦截是 HTTP 200 challenge / "Third-party" HTML，不会 RST。 |
| 3 | WebView2 能否当真实浏览器跑自动化 | **能做 DOM/JS 自动化，但不能稳定冒充真实 Chrome 过强 CF**。UA/headers/JS 可伪装；**TLS/JA3、WebGL/canvas 深层指纹改不了**，站方会持续挑战。适合「会话内采集」，不适合「无人值守过 CF」。 |
| 4 | webview 与主页冲突 → 改弹窗？ | 现状已是 `showGeneralDialog` 弹窗 + `DesktopWebview` 独立窗口，路由冲突不成立。真正限制是 **WebView2 同进程 headless 与可见实例不能并存**。桌面端**推荐独立窗口（DesktopWebview）**，与主窗口彻底隔离。 |
| 5 | 「创建下载任务」URL→章节→选章→建任务 可行吗 | **可行性高**。复用 `fetchChapters` + `ComicChapters` + `ImagesDownloadTask` 即可。此入口**天然适合人机协作**：用户贴 URL 时顺手弹窗口过 CF，再从该会话抓章节。**需要真实浏览器**（章节仍受 CF 保护）。 |
| 6 | 能否内置真实浏览器 + 自动化 | **能**。首选「App 自动拉起本机 Chrome（专用 user-data-dir + 9222 + `--disable-blink-features=AutomationControlled`）」，无 Chrome 时回落「内置 Chrome for Testing（~150–250MB）」。采集走 CDP，WebView2 仅兜底。 |

---

## 1. 事实基线（代码现状）

- **双采集 worker**（`comix_client.dart`）：
  - `_ComixWorker`（L2643）：`HeadlessInAppWebView`（WebView2 内核，离屏）。已做 Chrome UA 155、
    假 `sec-ch-ua` 头、AT_DOCUMENT_START 反检测 JS、`cf_clearance` 注入（读 `cf_cookie.json`）。
  - `ComixCDPWorker`（L3985）：连 `localhost:9222` 的**真实 Chrome**；非首页导航用 `history.pushState`
    （站方对 `Page.navigate` 返回 Third-party 页）。
- **优先级**（`_tryFetchChapters` L599-659）：CDP → headless WebView2 API → headless DOM。
  即：**CDP 是可选加速，真正兜底是 WebView2**。
- **CDP 依赖外部 Chrome**：`cdp_start.ps1` 需用户**手动**用专用 profile（`C:\Temp\comix_cdp_final`）
  启动 `chrome.exe --remote-debugging-port=9222 --disable-blink-features=AutomationControlled`。
  App 自身**不启动 Chrome**（lib 内无 chrome.exe 的 Process.start）。
- **WebView2 实例限制**：`verifyCloudflare` 注释明确「同一进程内 HeadlessInAppWebView 和可见
  InAppWebview 不能并存，开可见前必须 dispose 所有 headless」（L2509-2511）。
- **验证并发 guard**：`_verifyGuard`（L69/L2496），5 分钟超时、`finally` 复位（L2616）。
- **「创建下载任务」占位**：`download_manager_page.dart:_showCreateTaskPlaceholder()`（L247）
  当前只弹 `ContentDialog` 说明，**无实际逻辑**；i18n key = `Create Download Task` / `Create Download Task Hint`。

## 2. Q1：采集逻辑写回是否还有用？

**分两层看：**

1. **纯 HTTP（dio/curl/Node/headless 无浏览器）**：**无用**。已验证 comix 图片/页面对非浏览器
   TLS 指纹一律 403/1020，带 Referer/完整头也没用。这条路彻底放弃。
2. **WebView2（headless InAppWebView）**：**部分有用，但目前不稳定**，原因不是"被永久判第三方"，而是：
   - 站方返回 "Third-party apps are not supported" 的触发是 **UA/Client Hints/`navigator.webdriver`/
     `window.chrome` 等特征**；代码已用 UA+headers+JS 伪装，但 **TLS/JA3 与 WebGL/canvas 指纹无法改**；
   - 现在能"过一点"，是因为注入了**真实 `cf_clearance`**（来自 Playwright/真实浏览器过的会话）。
     但 **`cf_clearance` 绑定 IP + UA + 会话**，跨引擎注入（Playwright 的 cookie 塞进 WebView2）
     很脆弱 → **第一次能过、后续会话重建/指纹不一致就被降级重挑战**。这与你的实测完全吻合。

**结论**：写回**有用**，但产品定位要改成 **「人机协作采集」**——
> 用户用真实浏览器（或 App 拉起的真实 Chrome）过一次 CF → App 复用该会话 → 自动采集/下载。

不能承诺"无头全自动过 CF"。这与"先放弃在线阅读、恢复下载"的方向一致。

## 3. Q2：误判纠正 —— "远程计算机拒绝网络连接"

`data/logs.txt` 实证（2026-10-19 15:05–15:14）：

```
warning ComixCDP ... isAvailable failed: SocketException: 远程计算机拒绝网络连接。
(OS Error: 远程计算机拒绝网络连接。, errno = 1225), address = localhost, port = 8067
```

- 来源 = `ComixCDPWorker.isAvailable()` 探 `http://localhost:9222/json`。
- **errno 1225 = ERROR_CONNECTION_REFUSED**，即**本地 9222 没有进程监听**（App 没自动拉起 Chrome）。
  日志里的 8067/2601/7500… 是本地临时端口，目标始终是 9222。
- **这不是 Cloudflare 的"第三方"拒绝**：CF 拦截返回 HTTP 200 challenge 页 / "Third-party" HTML，
  永远不会是 TCP RST。
- 随后链路（日志实证）：CDP 不可用 → 回落 headless WebView2 → `navigate → both evals timed out → blocked`
  → `CF detected → auto verifyCloudflare()` → 弹 AppWebview → 再点则 `already in progress, awaiting...`。
- 所以"卡死/不再弹"是**工程链路问题**（CDP 未自动拉起 + headless/visible 并存限制 + guard 占用），
  **不是"CF 把你永久拉黑"**。这三条都可修。

## 4. Q3：WebView2 能不能担当真实浏览器完成自动化？

- **能力**：WebView2 = Edge Chromium 内核，DOM 查询、JS 执行、fetch/XHR、点击、导航、cookie
  全都能做，自动化能力**足够**。
- **差异（关键）**：它不是 Chrome。默认 `UA` 带 `Edg`、Client Hints 带 `Microsoft Edge`、
  `navigator.webdriver` 可能为 true、`window.chrome` 不完整、**TLS 指纹（JA3）与 Chrome 不同**、
  WebGL/canvas/字体指纹也不同。代码能改的只有 JS 可见层与前两者，**改不了 TLS 与渲染指纹**。
- **结论**：WebView2 **能做"真实浏览器级 DOM 自动化"，但不能稳定"冒充真实 Chrome 过强 CF"**。
  定位应是：用户手动过验证后的**会话内采集器**，而非无人值守的过验证器。

## 5. Q4：是否改成弹窗？

- 现状其实**已经是弹窗**：`verifyCloudflare` 用 `showGeneralDialog` + `AppWebview`（overlay），
  不是主页面跳转；另有 `DesktopWebview`（`desktop_webview_window`）= **独立 OS 窗口**。
- "与主页冲突"的真实来源不是路由，而是 **WebView2 引擎同进程只能有一个可见实例**，
  且开可见前必须 dispose 所有 headless（L2509）。
- **建议**：桌面端优先用 **`DesktopWebview` 独立窗口**（与主窗口彻底隔离、不抢焦点、用户可像正常
  浏览器操作、可关可重开）；若坚持 in-app overlay，则必须补：① 可最小化/可再次唤起；② guard 超时/
  取消复位；③ 打开前确保 headless 全部 dispose。**结论：改弹窗是必要的，但推荐"独立窗口"而非 overlay。**

## 6. Q5：「创建下载任务」（URL→章节→选章→建任务）可行性

**可行性：高。** 数据链路已齐备：

- **输入**：comix 标题页 URL，如 `https://comix.to/title/503jz-i-will-save-my-father`。
  最后一段 `503jz-i-will-save-my-father` = `hid + "-" + slug`（hid=`503jz`，slug=`i-will-save-my-father`），
  与本地库 id `503jz//i-will-save-my-father` 对应。
- **采集**：复用 `ComixClient.fetchChapters(hid, slug, url)` → `ComicChapters`（版本化矩阵，
  含 `scanlationGroupsSorted` / `allVersions`）。
- **选章**：复用 `actions.dart:_buildDownloadSections`（L593）的分组+计数思路（注意先修 A07b 的
  同组重复 bug，否则选章列表会虚高）。
- **建任务**：构造 `ImagesDownloadTask`（`DownloadTask` 子类）入 `LocalManager` 队列，
  与现有下载面板同源。
- **是否需真实浏览器**：**是**。URL→章节列表仍受 CF 保护。但此入口**天然适合人机协作**：
  用户主动贴 URL 时，顺势弹一个可见窗口（DesktopWebview）让他过 CF/确认，然后**从同一会话**
  抓章节 DOM/API。**只要求"过一次 CF"，不要求"全自动过 CF"**。
- **推荐流程**：
  1. 用户输入 URL（粘贴标题页）→ 解析 hid/slug；
  2. 打开可见窗口加载该标题页（用户过 CF / 确认漫画）；
  3. 同一会话内抓章节列表（DOM/API）→ 展示选章（分翻译组）；
  4. 选章 → 建 `ImagesDownloadTask` → 入队；
  5. 下载图片走现有 `fetchImageBytes`（WebView2 兜底）。

## 7. Q6：能否内置真实浏览器 + 自动化？

| 方案 | 真实 Chrome 指纹 | 可打包/分发 | 成本 | 评价 |
|---|---|---|---|---|
| **Chrome for Testing（推荐内置）** | ✅ 是 | ✅ 可随 App 打包（~150–250MB） | 中 | 官方"自动化专用"真实 Chrome，TLS/UA 真实，CDP 友好 |
| **复用本机 Chrome（推荐优先）** | ✅ 是 | ❌ 依赖用户装 Chrome | 低 | `cdp_start.ps1` 已是雏形；App 可自动拉起专用 profile |
| WebView2 Fixed Runtime | ⚠️ 否（Edge 内核） | ✅ 可打包 | 低 | 仍是 Edg 特征，过不了强 CF |
| CEF | ✅ 是 | ✅ 可打包 | 高 | 体积大、集成/维护重 |
| Playwright + Chrome | ✅ 是 | ❌ 需带 Node+浏览器 | 中 | 开发期好用，分发重 |

**推荐组合**：
1. **优先复用本机 Chrome**：App 用 `Process.start` 拉起 `chrome.exe`
   `--remote-debugging-port=9222 --user-data-dir=<App专用目录> --disable-blink-features=AutomationControlled`，
   不碰用户日常 profile；
2. **无本机 Chrome 时回落内置 Chrome for Testing**；
3. 采集走 **CDP（真实指纹）**，WebView2 仅做**图片字节兜底/展示**；
4. 会话持久化：专用 `user-data-dir` + 复用 `cf_clearance`，减少重复过验证。

**风险（必须承认）**：CDP 自动化仍可能被检测（`navigator.webdriver`、automation flags、非持久
profile）。用 Chrome for Testing + 上述 flags + 真实持久 profile + **用户先手动过一次 CF**，
可显著降低，但**无 100% 保证**（站方持续升级）。

## 8. 推荐落地节奏（写回代码时）

- **阶段 0（建议立刻做）**：不做"全自动过 CF"。「创建下载任务」= **URL 驱动 + 可见窗口人机协作**
  （输入 URL → 过 CF → 抓章节 → 选章 → 建任务）。先把下载主链路恢复。
- **阶段 1**：App 自动管理一个专用真实 Chrome（优先本机、回落 CfT），采集走 CDP；WebView2 降级兜底。
- **阶段 2**：会话持久化（专用 profile + cf_clearance），减少重复验证；修 A07b 的同组重复 bug。
- **阶段 3**：若 CDP 仍被检测，再评估 CEF / 内置 CfT 深度定制。

## 9. 不能承诺的 & 待你拍板的岔路

**不能承诺**：
- 无人值守全自动过 CF；
- 永久稳定（CF 会升级，需持续维护）。

**需要你拍板**：
1. 是否接受「首次需用户手动过一次 CF」的人机协作模式？（这是所有方案的共同前提）
2. 内置浏览器体积（+~200MB）可接受，还是优先「复用本机 Chrome」？
3. 「创建下载任务」是否就以 **URL 驱动**为主入口，保留原「搜索→详情页」路径作为补充？

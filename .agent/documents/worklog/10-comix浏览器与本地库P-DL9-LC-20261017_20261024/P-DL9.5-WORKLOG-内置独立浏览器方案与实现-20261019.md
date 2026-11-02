# comix.to 内置独立浏览器（Chrome for Testing）方案与实现

> 阶段：P4 / 落地节奏阶段 1（内置真实浏览器）
> 时间：2026-10-19
> 关联：`../../analysis/P-DL9.1-ANALYSIS-comix采集架构与创建下载任务可行性-20261019.md`、`A07-comix源.md`、`A07b-comix章节列表采集与分组.md`

## 一、用户决策（2026-10-19）

- **路线：独立一个、随 App 分发、大小不担心。**
- 目标场景：Mangrove 拷到别的电脑，即使该机**没有 Chrome、只有 Edge**，也能用自己的内置浏览器完成 comix.to 采集。
- 因此**不再"优先拉起本机 Chrome"**（那只是省体积的优化），改为**只认随 App 分发的 Chrome for Testing**。

## 二、Chrome for Testing 是什么（澄清）

| 问题 | 答案 |
|---|---|
| 是独立浏览器吗？ | **是。** Google 官方发布的绿色版完整 Chrome，`chrome-win64.zip` 解压即用，不写注册表、不依赖系统 Chrome。 |
| 为什么之前说要拉起本机 Chrome？ | 纯体积优化（省 ~150MB）。不符合"移植到无 Chrome 机器也能用"的诉求，**已废弃**。 |
| 体积多大？ | 压缩包约 **150MB**，解压后约 **350–450MB**（本次实测目录 ~437MB 属正常量级）。 |
| 会自动更新吗？ | **不会。** CfT 版本固定，不受系统 Chrome 自动更新影响，行为可复现。 |
| 和 WebView2 的区别？ | WebView2 是 **Edge 内核**、依赖系统运行时；CfT 是**真 Chrome**，指纹更接近普通 Chrome，过 CF 更稳。 |
| 能嵌进 Mangrove 窗口里吗？ | **不能直接嵌。** CfT 是独立进程/独立窗口。要"窗口内嵌"需 CEF（重）。当前采用"独立窗口 + CDP 驱动"，与现有 DesktopWebview 形态一致。 |

## 三、实现（代码）

### 新增 `lib/network/comix_browser.dart` —— `ComixBrowserManager`（单例）
职责：**找到 / 拉起 / 探活 / 停止 / 首次下载**，不负责采集本身。

- **查找顺序**（`resolveChrome()`）：
  1. `<exeDir>/chrome-win64/chrome.exe` —— 随 App 分发的 CfT（主路径）
  2. `<exeDir>/browser/chrome.exe` —— 兼容旧布局
  3. `%APPDATA%/Mangrove/browser/chrome-win64/chrome.exe` —— 运行时下载缓存
  4. `%LOCALAPPDATA%/ms-playwright/chromium-*/chrome-win64` —— **仅开发机兜底**
  - ⚠️ **不查 `C:\Program Files\Google\Chrome`** —— 绝不拉起用户日常 Chrome。
- **拉起参数**：`--remote-debugging-port=9222`、专用 `--user-data-dir=%APPDATA%/Mangrove/comix_cdp_profile`、`--no-first-run`、`--no-default-browser-check`、`--disable-blink-features=AutomationControlled`、`--no-sandbox`，起始页 `https://comix.to/`。
- **探活**：`GET http://127.0.0.1:9222/json/version`（`findProxy = DIRECT`，绕开 Clash 等环境代理）。
- **下载兜底** `provision()`：读 Google 官方 CfT 清单 → Stable/win64 → 下载 zip → `archive` 解压到 `%APPDATA%/Mangrove/browser/`。

### 改动 `lib/network/comix_client.dart`
- `ComixCDPWorker.isAvailable()` 改为先调 `ComixBrowserManager.instance.ensureRunning()`：
  - 9222 已有 CDP → 直接复用（兼容用户手动 `cdp_start.ps1` 的外部 Chrome）；
  - 没有 → 拉起内置 CfT；
  - 找不到内置二进制 → 返回 false，回落 WebView2（不崩）。

### CF 会话共享（关键一环）
`verifyCloudflare` 原本用 AppWebview 拿 cf_clearance，只写文件 + JS 引擎；**内置 CfT 的 cookie jar 拿不到**，会出现"验证过了但采集仍被拦"。已补：
- `ComixCDPWorker.setCookie()`：CDP `Network.setCookie` 写入 `cf_clearance`（domain `.comix.to`、Secure、SameSite=None）。
- `ComixCDPWorker.injectSavedCfCookie()`：从 `cf_cookie.json` 读取并注入。
- `_tryFetchChapters` CDP 分支：`navigate` 前先 `injectSavedCfCookie()`。
- `verifyCloudflare` 检测到 cf_clearance 后：除存文件外，同步 `setCookie` 到内置 CfT。

### 新增 `tools/fetch_cft.py`
把 CfT 下载解压到 `builds/mangrove/chrome-win64/`（与 `mangrove.exe` 同级），使整个 `builds/mangrove/` 目录可整体拷到别的电脑直接运行。

## 四、静态校验、构建与实测状态

- `flutter analyze lib/network/comix_browser.dart` → **0 issue**（新文件干净）。
- `comix_client.dart` 余 3 条为**既有** issues（unused import / 空 catch），非本次引入。
- 阶段 0 占位符修复 + 阶段 1 代码均已 **BUILD_OK**（10-19 16:05 二次构建，`data/app.so` 更新为 21.25MB）。
- **CfT 已就位**：`builds/mangrove/chrome-win64/chrome.exe`（CfT Stable 155.0.8059.84，zip 196.6MB）。
- **端到端实测（本机）**：直接拉起该 chrome.exe（9333 端口 + 临时 profile）后
  `GET /json/version` 返回 `"Browser": "Chrome/155.0.8059.84"`、真实 Chrome UA、Protocol 1.3；
  `/json` 正常列出 page target。**证明内置浏览器可启动、CDP 可用**（与 `ensureRunning` 所需完全一致）。

## 五、遗留与注意

1. **分发许可**：CfT 面向测试用途发布；随商业 App 分发前需确认 Google 的分发条款（个人使用无碍）。
2. **窗口形态**：当前是独立窗口。若要求"真正嵌在 Mangrove 界面内"，需评估 CEF（集成成本高）。
3. **构建流程**：`tools/fetch_cft.py` 目前是**手动一次性**执行；若清空 `builds/` 需重跑。后续可挂进打包脚本（仅在缺失时下载）。
4. **首次过 CF**：仍建议保留"可见窗口让人过验证"的交互（`verifyCloudflare` 现走 DesktopWebview，后续可改为直接复用内置 CfT 窗口）。

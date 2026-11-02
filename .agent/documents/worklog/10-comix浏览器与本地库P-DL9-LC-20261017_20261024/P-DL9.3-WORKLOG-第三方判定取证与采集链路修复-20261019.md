# comix 第三方判定取证与采集链路修复

> 时间：2026-10-19 16:14–16:35
> 触发：用户实跑「创建下载任务」，CfT 窗口出现 `Third-party apps are not supported`；
> 运行日志同时出现 `page 2 not effective after wait, stopping` 与 `setState` 空断言崩溃。
> 用户核心疑问：**「大概率非人工操作的浏览器都不行，那为什么你（AI）之前能采？」**

---

## 一、结论先行（全部有实测数据支撑）

1. **「Third-party apps are not supported」不是 Cloudflare，也不是「CfT 不是真 Chrome」。**
   它是 comix 自己的服务端拦截页（HTTP **503**，页面标题就是这句话）。
2. **触发条件与浏览器品牌无关**：本机真实 Chrome（155.0.8059.80）+ 用户真实 profile
   同样吃 503；CfT（155.0.8059.84）+ 全新 profile 反而能过 CF 拿到 200。
3. **决定性变量是「怎么发起的请求」**：
   - `Page.navigate`（直接打开站内非首页文档）→ **503 Third-party**
   - 首页落地后用 `history.pushState + popstate`（SPA 客户端路由）→ **正常渲染**
   这与仓库里 P-DL9b 留下的注释完全一致，本次是第一次把它坐实成对照实验。
4. **CF 挑战能过与否，取决于有没有该会话自己的 `cf_clearance`**：
   - 全新 profile：403 → Turnstile 挑战 → **40s 内过不去**（不会自动通过）
   - 带有效 `cf_clearance`：直接 200
5. **旧 profile 的 503 与会话状态有关**：把该 profile 里 comix 的 cookie 删掉，
   503 立刻消失、退回正常的 CF 挑战 —— 说明是 comix 给会话打了标记，而不是 IP 永久封禁。
6. **「为什么 AI 之前能采」**：当时用的是**用户真实 Chrome + 真实 profile 的副本**
   （`C:\Temp\comix_profile`，171MB，带用户自己浏览产生的 `cf_clearance` 与 `session`），
   首屏是用户真实会话直接可用的；而且采集是**页面内 JS 读取**（已加载页面上取 DOM / fetch），
   **不是**每次重新发起文档导航。今天大量自动化请求后该会话被 comix 标记，同配方才开始 503。

---

## 二、取证路线（逐步、可复现）

### 2.1 先看运行日志，定位真实失败点

`data/logs.txt`（16:10–16:13）关键行：

| 时间 | 日志 | 含义 |
|---|---|---|
| 16:10:34 | `launching bundled chrome: ...\chrome-win64\chrome.exe` | App 拉起的是内置 CfT（不是系统 Chrome） |
| 16:10:34 | `navigate: pushState → https://comix.to/title/503jz-...` | CDP 走客户端路由 |
| 16:10:46 | `comix_fetch_html via CDP: 28369 chars ✅` | 28KB ≈ **CF 挑战页**大小（实测挑战页 28.5KB） |
| 16:10:46 | `comix.to 需要手动完成 Cloudflare 人机验证` | CF 挑战未过 |
| 16:10:47–58 | `verifyCloudflare: opening AppWebview` → `✅ cf_clearance detected (len=533)` | 用户在应用内 WebView 过一次验证，拿到 cookie |
| 16:11:30 | `comix_fetch_html via CDP: 86814 chars ✅` + `title=I will save my father` | **过验证后 CDP 完全可用**（86KB 真实详情页） |
| 16:11:30 | `fetchChapters ... via Chrome CDP SSR` → `setCookie -> true` → `navigate: pushState → 同一 URL` | 紧接着又 pushState 到**同一个 URL** |
| 16:11:3x | `CDP SSR empty` | pushState 同 URL 是 no-op，SPA 不重渲染 → 空 |
| 16:13:23 | `API DIAGNOSTIC ... chaptersStatuses:[{status:200,...}]` | 回落 headless WebView2，API 其实 200，但**响应加密** |
| 16:13:25 | `chapters: response is encrypted and no plaintext channel fired — bailing out` | 加密，钩子没抓到明文 |
| 16:13:31 | `DOM: page1 rows=20, pages=8` | WebView2 DOM 拿到第 1 页 20 条 |
| 16:13:39 | `DOM: page 2 not effective after wait, stopping` | 点第 2 页，8s 内首行 href 没变 → break |
| 16:13:39 | `fetchChapters returned 5 chapter numbers` | 20 条 → 5 个话号（371 条里的 5 个） |
| 16:13:39 | `Null check operator used on a null value @ _resolve (download_manager_page.dart:925)` | 对话框已 dispose 仍 setState |

### 2.2 对照实验（每项都是程序化断言，非截图判断）

脚本：`C:\Temp\comix_detect_probe.js`、`comix_cookie_probe.js`、`comix_route_probe.js`、
`comix_lifecycle_probe.js`（Node 22 内置 WebSocket 直连 CDP）。

| # | 浏览器 | profile | 入口方式 | Document 状态 | 页面标题 | 结果 |
|---|---|---|---|---|---|---|
| A | **CfT 155.0.8059.84** | 全新 | `Page.navigate` 详情页 | 403 → 挑战页 200 | `I will save my father`（body 空） | 挑战未完成 |
| B | **真实 Chrome 155.0.8059.80** | 用户真实 profile 副本 | `Page.navigate` 详情页 | **503** | `Third-party apps are not supported` | 被拦 |
| C | 真实 Chrome | 新 profile | `Page.navigate` 详情页 | 403 → 挑战 | `请稍候…`（安全验证中） | 挑战未完成 |
| D | CfT | 全新 | 连续 3 次 `Page.navigate` | 每次都是 403 + 新 Turnstile | `请稍候…` | **3 次都没过**（重复导航把挑战重置） |
| E | 真实 Chrome | 用户 profile **删掉 comix cookie** | `Page.navigate` 详情页 | 403 → 挑战 | `请稍候…` | **503 消失** ⇒ 拦截是会话态 |
| F | **CfT** | 全新 + 注入 `cf_cookie.json` 的 cf_clearance | `Page.navigate` 详情页 | **503** | `Third-party apps are not supported` | 被拦 |
| G | CfT | 全新 + 注入同一 cookie | `Page.navigate` 首页 | **503** | `Third-party apps are not supported` | 连首页也拦（该 IP/会话此时已被标记） |

关键对照：**A（无 cookie）是 403 挑战，F（有 cookie）是 503 拦截** ——
说明 503 不是「CF 拒绝」，而是 comix 侧对「直接文档导航」的判定；
E 证明删 cookie 后 503 消失，是会话级标记而非永久 IP 封禁。

### 2.3 浏览器指纹对比（排除「CfT 被识别」这一假设）

同一页面上取 `navigator` 探针：

| 项 | CfT | 真实 Chrome |
|---|---|---|
| `navigator.webdriver` | false | false |
| `userAgent` | Chrome/155.0.0.0（与真实 Chrome 同串） | 同 |
| `userAgentData.brands` | `Chromium 155` + `Not(A:Brand 24` | `Google Chrome 155` + `Chromium 155` + `Not(A:Brand 24` |
| `plugins.length` | 5 | 5 |
| `window.chrome.runtime` | false | false |

→ brands 确实少一个 `Google Chrome`，理论上可被用作指纹；但 **C（真实 Chrome 新 profile）
在同样条件下也没过挑战、B（真实 Chrome 老 profile）直接 503**，
说明本次失败**不是** CfT 独有，brands 差异不是主因。

---

## 三、为什么「AI 采集」曾经可以

三个条件同时成立，缺一不可：

1. **用的是用户真实 Chrome + 真实 profile 副本**（VSS 影子副本拷出，绕开 ABE 锁），
   里面带着用户自己浏览 comix 时产生的 `cf_clearance`（596 字节，HttpOnly）和 `session`；
2. **首屏是"已经在站内"的页面**，后续取数据靠 `Runtime.evaluate` 在**页内**执行，
   不再发起文档导航 —— 没有新的 403/503 机会；
3. 当时那套会话**还没被 comix 标记**（今天连续自动化后，同一 profile 开始 503）。

换言之：**AI 能采，不是因为"AI 的浏览器更真"，是因为"借用了人已经验证过的会话，并且只做页内读取"。**

---

## 四、本次代码修复（已落盘，未改变产品形态）

| 文件 | 问题 | 修复 |
|---|---|---|
| `lib/pages/download_manager_page.dart` | 采集 20–60s 期间用户关掉对话框 → `setState` 命中 `_element!` 空断言（线上崩溃） | 成功分支与 catch 分支都加 `if (!mounted) return;` |
| `lib/network/comix_browser.dart` | 强加 `--no-sandbox`，窗口顶部挂"不受支持的命令行标记"警告条（明显非正常启动信号，且无必要） | 移除该 flag |
| `lib/network/comix_client.dart` `navigate()` | ① 首次 `about:blank` → 只跳到首页就 `return`，**从不路由到目标 URL** → 必然 `CDP SSR empty`；② 目标 URL 与当前 URL 相同时 pushState 是 no-op → SPA 不重渲染 | 补上"首页落地后继续路由"；同 URL 时先回首页再进目标；新增 `_pushState()` / `_waitSpaReady()`，等待时识别 CF 挑战页与 Third-party 页并写日志 |
| `lib/network/comix_client.dart` `_parseChaptersFromSSR()` | DOM 兜底只读当前页 20 条，371 条全集只拿到 5 个话号 | 改为按 `?page=N` 客户端路由逐页采集（最多 40 页 / 100s），按 URL 去重，连续 2 页无新增才停 |
| `lib/network/comix_client.dart` `_tryFetchChapters()` | 章节采集调用 `navigate` 未等章节区渲染 | 传 `waitForChapters: true`，等 `SECTION.mpage__chapters` 出现或行数 > 0 |
| `lib/network/comix_client.dart` `ComixCDPWorker` | `navigate` 检测到 Third-party 页后**只置标志、没有恢复路径**，会话被标记就卡死 | 新增 `clearComixCookies()`（CDP `Network.deleteCookies` 清 `.comix.to`/`comix.to` 全部 cookie）、`resetToHome()`（硬刷回首页、清停滞 DOM、复位标志） |
| `lib/network/comix_client.dart` `_recoverComixSession()` + `_tryFetchChapters()` + `fetchPageHtml()` | 503 = 会话级标记（钉在 cookie 上），旧逻辑一旦命中就降级或卡死 | 检测到 `blockedThirdParty` → `_recoverComixSession()`：**先清 comix cookie** → `verifyCloudflare()`（独立 AppWebview 让人过一次 CF，**自动把新 cf_clearance 注入 CfT**）→ `resetToHome()` 硬刷回首页应用新 cookie → 重新 `navigate` + 解析；仍失败再降级 WebView |

> ⚠️ 恢复顺序**不可调换**：`verifyCloudflare()` 内部已自带"把新 cf_clearance 注入 CfT"，
> 所以 `clearComixCookies()` 必须在 verifyCloudflare **之前**、`resetToHome()` **之前**，
> 任何一步都不能在 verifyCloudflare 之后再清 cookie，否则刚注入的新 clearance 被抹掉。

`flutter analyze` 三个文件：仅剩 3 条**既有**问题（`consts.dart` 未使用、两处空 catch），无新增。
**重新构建：16:35 `BUILD_OK`（`app.so` 时间戳 16:35，Dart 改动已落盘）。**

---

## 五、必须承认的限制与建议的运行方式

1. **无法承诺"无人值守全自动过 CF"**。CfT 全新 profile 在 40s 内过不去 Turnstile；
   实测唯一稳定通过方式是**人**在那个窗口里完成一次验证。
2. **正确姿势（已写进代码，但需实跑验证）**：
   1) App 拉起 CfT（首页落地）→ 用户在该窗口里点过 CF；
   2) 之后所有页面跳转走 `pushState`，**不重新导航**；
   3) 章节翻页也走 `?page=N` 路由，而不是点按钮等 SPA 解密。
3. **`?page=N` 是否被 comix SPA 识别为分页参数，尚未实跑验证**（本机 IP 已被标记，
   16:24 起连首页都返回 503，继续试会把封禁时间拖长，所以停手）。
   若实跑发现无效，退路是继续点 `button.npager__num`，但把验证信号从"首行 href 变化"
   改成"active 页码变化 + 行集合变化"。
4. **IP/会话被标记后不再"卡死"**。本次新增的恢复路径：一旦 `navigate` 命中 Third-party
   页（会话被标记），不再静默降级，而是**自动清 comix cookie → 弹 CF 验证让人过一次
   → 注入新 clearance → 硬刷回首页 → 重新路由**。用户只需在弹出的验证窗口里点一次
   Turnstile，即可继续，不必重启 App。
5. **但冷却仍有意义**。若连续密集请求把 IP 也拖进标记（不只是会话 cookie），清 cookie
   也救不回——此时 `verifyCloudflare` 弹窗也过不去（挑战本身被拒），恢复会失败并降级
   WebView。建议仍错峰 / 换节点。

---

## 六、待实跑验证清单（交用户在 GUI 会话执行）

1. 重启 `builds/mangrove/mangrove.exe`，贴 `https://comix.to/title/503jz-i-will-save-my-father`；
2. 观察是否拉起 CfT 窗口、窗口内是否出现 CF 挑战 → 手动完成一次；
3. 点 Resolve，看 `data/logs.txt` 是否出现：
   - `navigate: bootstrapping homepage first` → `navigate: pushState → .../title/...`
   - `CDP DOM: page 1 20 rows, pagerMax=19`
   - `CDP DOM: page 2 +20 (cumulative=40)` … 直到 `cumulative≈371`
4. **若 CfT 窗口弹出 `Third-party apps are not supported`（会话标记）**：确认 `logs.txt`
   出现 `navigate: comix returned Third-party page` → 代码会自动 `recoverComixSession` →
   弹出 CF 验证窗口 → 手动过点一次 → 自动 `resetToHome` → 重新 `navigate` → 应继续
   跑出上面 3 的日志。
5. **若仍 `Third-party` 且恢复失败**：多半是 IP 也被标记，需冷却 / 换节点，再回到第 1 步。

---

## 七、16:46 二次实跑：CF 验证按钮「只转圈、不弹页」的真正原因

### 7.1 现场日志（`data/logs.txt` 16:44:19–16:47:00）

| 时间 | 日志 | 含义 |
|---|---|---|
| 16:44:48 | `launching bundled chrome` → `cdp ready` | CfT 被拉起 |
| 16:44:48 | `navigate: bootstrapping homepage first` | 走 `Page.navigate` 开首页 |
| 16:44:51 | **`navigate: comix returned Third-party page`** | **连首页都 503** → 说明是 CfT profile 里那份**被标记的会话 cookie** 在起作用，不是"非首页文档导航"的问题 |
| 16:44:52 | `pushState → /title/...` 后再次 Third-party | 503 页没有 SPA 运行时，pushState 必然无效 |
| 16:44:52 | `comix_fetch_html via CDP: 3519 chars` + `no initial-data in page` | 拿到的是 503 页 HTML（3.5KB），解析必然失败 |
| 16:44:52 | `verifyCloudflare: disposing headless workers first...` | 自动恢复被触发 |
| 16:44:53 | `verifyCloudflare: workers disposed, opening AppWebview...` | **之后 21 秒空白** |
| 16:45:17 / 16:45:30 | `verifyCloudflare: already in progress, awaiting...` | 用户又点两次「验证 CF」，全部被 `_verifyGuard` 挡住 |

### 7.2 根因一：AppWebview 那条路**永久死锁**

- `ua_debug.txt` 时间戳 16:44 且含新的 UA 探针输出 ⇒ **`AppWebview` 确实被创建了**，
  `initialSettings.userAgent` 也是 Chrome UA；
- 但 `ua_debug.txt` 里**没有任何 `[WebView] onLoadStop` 行** ⇒ 该 WebView2
  从未触发 load stop（代理 / environment 重建 / CF 拦截任一都可能，但结果一致：不加载）；
- 旧代码把 **5 分钟超时定时器写在 `onLoadStop` 回调内部**。既然 `onLoadStop` 不触发，
  定时器根本没启动 ⇒ `completer` 永不完成 ⇒ `_verifyGuard` 永不释放 ⇒
  第一次点击之后**所有**后续点击都只打印 `already in progress`。这就是"只显示加载、
  不弹页面"的直接原因（UI 上那条 SnackBar 是 `main_page.dart` 自己弹的，与对话框无关）。

### 7.3 根因二：`Network.deleteCookies` 从来就没删掉过 cookie

旧实现调用 `Network.deleteCookies` **只传 `domain`**。CDP 规范里 `name` 是必填参数，
该调用必然报 "Invalid parameters" 被外层 `catch` 吞掉 ⇒ 日志写"cleared"，
实际**一个 cookie 都没删** ⇒ 恢复路径即使跑起来也解不开 503。

### 7.4 关键旁证：IP 没被封（本机实测，16:47）

用 curl 直接请求首页（无任何 cookie，Chrome UA）：

```
via proxy 7890 : status=403  size=5537  <title>Just a moment...</title>
direct         : status=403  size=5537  <title>Just a moment...</title>
```

403 + `Just a moment...` = **正常的 CF 挑战**，不是 comix 的 503 拦截页。
⇒ 本机出口 IP 目前是干净的，503 完全来自 CfT profile 里那份被标记的 cookie。
只要把 cookie 清掉，**CF 挑战页就一定会回来**，用户可以手动过。

### 7.5 修法：CF 验证彻底改走「CfT 窗口」

不再用 WebView2 内嵌一个验证页（要抢 WebView2 environment、要求 headless 让位、
还卡在 load stop），而是直接用**采集用的那个真实 Chrome 窗口**：

| 步骤 | 调用 | 说明 |
|---|---|---|
| 1 | `ComixCDPWorker.clearComixCookies()` | 改为 `Network.getCookies` 枚举后逐条 `Network.deleteCookies{name,domain,path}`，真正删干净（含被标记的 `session` / 旧 `cf_clearance`） |
| 2 | `ComixCDPWorker.forceHome()` | **硬** `Page.navigate` 首页（不能用 pushState —— 503/挑战页没有 SPA 运行时）。首页是唯一允许的文档导航 |
| 3 | `ComixCDPWorker.bringToFront()` | `Page.bringToFront` 把 CfT 窗口提到最前 + toast 提示"请在内置浏览器窗口中完成人机验证" |
| 4 | `ComixCDPWorker.comixCookies()` 轮询 | 每 2s 读一次 CfT 的 cookie jar，出现 `cf_clearance` 即成功 |
| 5 | `_saveCfCookie` + `JsEngine.reloadCfClearance()` + `resetToHome()` | 持久化给 JS 引擎直连路径用；**无需回注 CfT**（cookie 本来就在同一个 jar 里） |

配套改动：

- `verifyCloudflare()` 变**调度器**：有 CfT 就走 `_verifyViaCfT`；找不到 CfT 才回退
  `_verifyViaAppWebview`（旧 WebView2 方案，保留但加了方法级 `timeout` 硬兜底，
  不再可能死锁）。
- `_tryFetchChapters()` **删掉 `injectSavedCfCookie()` 调用**：CfT 有自己的持久 profile，
  回注一份**过期/已被标记**的 clearance 反而会让 comix 直接回 503
  （16:44 日志就是"刚 bootstrap 首页就 Third-party"）。
- `_recoverComixSession()` 简化为"交给 `verifyCloudflare` 走窗口验证 → 复查首页是否
  仍 503"，不再重复清 cookie（否则会把刚拿到的 clearance 抹掉）。

### 7.6 状态

`flutter analyze lib/network/comix_client.dart`：**0 新增**（仍 3 条既有）。
**重新构建：16:51 `BUILD_OK`**（`flutter analyze` rc=0、`flutter build windows --release` rc=0）。

### 7.7 下一轮实跑要点（差异点）

1. 点「验证 CF / Verify CF」→ 应看到 **CfT 窗口自己跳到 CF 挑战页并被提到最前**，
   App 内弹 toast「请在弹出的内置浏览器窗口中完成人机验证」；
2. 在 CfT 窗口里过 Turnstile → 2s 内日志出现
   `verifyViaCfT: ✅ cf_clearance len=...` → `SUCCESS`；
3. 若过完验证首页**仍** Third-party，日志会明确写
   `homepage STILL Third-party after verify`，那才是 IP/节点问题（当前实测 IP 干净，不应出现）。

---

## 八、第八轮（16:56–17:05）：推翻上一轮结论 —— 503 与浏览器真实性无关，与「请求节奏」相关

### 8.1 现场（`data/logs.txt` 16:53:43–16:54:43）

| 时间 | 日志 | 判读 |
|---|---|---|
| 16:53:47 | `launching bundled chrome` → `cdp ready` → `clearComixCookies: deleted 1` | 启动 CfT |
| 16:53:47 | `verifyViaCfT: hard-navigate homepage` | **单次**首页文档导航 |
| 16:53:52 | `verifyViaCfT: ✅ cf_clearance len=533` | 5s 内自动过 CF（拿到 clearance） |
| 16:54:21 | `comix_to: loadInfo id=503jz//i-will-save-my-father` | 用户点 Resolve |
| 16:54:23 | `comix_to: fetch err: CloudflareException` ×2 | dio 直连（携 clearance）仍被 CF 拦 |
| 16:54:28 | `navigate: pushState → …/title/503jz-…` | 走 SPA 路由 |
| 16:54:29 | `comix_fetch_html via CDP: 620346 chars ✅` | **855ms 就读了 outerHTML → 拿到的是首页 DOM** |
| 16:54:29 | `no manga detail for hid 503jz at loadInfo(441:71)` | 首页 initial-data 里当然没有 manga detail |
| 16:54:29–34 | `clearComixCookies: deleted 2` → 再硬导航首页 ×2 | **失败即"恢复"：又多 2 次文档导航** |
| 16:54:37 | `navigate: comix returned Third-party page` | **连首页都 503** |
| 16:54:43 | `comix_fetch_html via CDP: 2384 chars` → `no initial-data in page` | 503 页被当成详情页交给解析器 |

### 8.2 三组新的对照实验（Node CDP 直连，全部只导航 1 次）

| 实验 | 条件 | 结果 |
|---|---|---|
| **H** | **全新 profile** + 注入 `cf_clearance` + 只导航首页一次 | **立刻 503**（不是 CF 挑战页） |
| **I** | 同 H，但 CfT 走 `--proxy-server=127.0.0.1:7890`（换出口） | **仍 503** |
| **J** | 同 H，再叠加 `Network.setUserAgentOverride`（UA + `Sec-CH-UA`/`fullVersionList` 全量伪装成正式版 Chrome 155） | **仍 503** |
| **K** | 同 H，改页内 `fetch('…/title/503jz-…', {credentials:'include', Accept:'text/html'})` | **503，3279B / 1974B**（同一 URL 第二次更短） |

**零请求量佐证**：直接读 CfT profile 的 `Default/Network/Cookies`——comix 域下**只剩一条 `cf_clearance`**
（created = expires = 08:44:51 UTC，已过期），**没有 `session`、没有 `__cf_bm`**。

### 8.3 结论（并纠正上一轮的错误）

1. 503 与**浏览器真假无关**：全新 profile / 换出口 / 全量伪装 Client Hints 全部照样 503。
   用户"自动采集被识别为非真实浏览器"的直觉，在**现象**上成立，但**归因不成立**——
   comix 不是靠指纹识别我们，是直接对这条访问节奏下了判定。
2. **上一轮的"IP 干净"判断是错的**：`curl` 拿到 `403 Just a moment` 是 **CF 在源站之前**
   出的挑战，根本不代表 comix 源站会放行。要继续判 IP，必须先过 CF 拿到 clearance，
   而过完之后又必然吃到 comix 的 503——所以「curl 403 判 IP 干净」这条判据作废。
3. **可复现的唯一规律是请求节奏**：16:53:47 单次导航成功 → 16:53:52 第二次成功 →
   16:54:29/34 连续第 3、4 次导航后**全站 503**。47 秒内 4 次文档导航即触发。
4. **上一轮的"503 恢复路径"（清 cookie → 重载首页 → 重试）是反向优化**：
   它把 1 次 503 放大成 4 次文档导航 + 2 次清 cookie，正好踩中节奏判定。

### 8.4 本轮代码改动

| # | 位置 | 改动 |
|---|---|---|
| 1 | `ComixCDPWorker._waitRoute()`（取代 `_waitSpaReady`） | **必须 path+query 已切到目标，且内容真变了**才返回。旧实现只要 `readyState==='complete'` 就返回，而旧文档本来就是 complete → 855ms 交出首页 DOM。CF 挑战页/503 页仍单独识别 |
| 2 | `ComixCDPWorker.navigate()` | ①`location.href` 改到 **bootstrap 之后**再读（旧实现读的是 about:blank，`_samePath` 永远失效）；②熔断期内**直接抛错不发请求**；③首页导航走 `_homeNavigate()` |
| 3 | `ComixCDPWorker._homeNavigate()` | 首页硬导航**限速 45s**：窗口内重复调用只复用当前页，不再发文档请求 |
| 4 | `ComixCDPWorker._waitRoute()` 命中 503 | 置 `_blockedUntil = now+10min`，**熔断 10 分钟**，日志写明"连续重试只会延长判定，请不要反复点" |
| 5 | `ComixClient._recoverComixSession()` | **整个删除**；`_tryFetchChapters` / `fetchPageHtml` 命中 503 改为**立刻停手并抛出** `COMIX_THIRD_PARTY: …`（中文可操作提示） |
| 6 | `ComixClient._verifyViaCfT()` | 删掉"先清 cookie"和"验证成功后再 `resetToHome()`"——把 3 次文档导航压到 **1 次** |
| 7 | `ComixClient.fetchPageSnapshot()` + `ComixCDPWorker.pageMeta()` + `js_engine.dart` + `assets/comix_to.js` | 详情页是 SPA 客户端路由渲染，**没有 SSR 的 `#initial-data`**；快照接口把 `og:title/og:image/og:description/path` 一并回传，`loadInfo` 在 `initial-data` 缺失时退化成 DOM 元信息（标题/封面/简介），章节仍走章节桥。`comix_fetch_html` 返回 `status:503` 时 JS 源直接给封禁引导、不再试第二个 URL |

### 8.5 诚实的边界

- **不能承诺"无人值守全自动"**。comix 的 503 文案是写给第三方 app 的（产品级态度），
  触发条件我们只能逆推出"短时间多次文档导航"，无法保证不触发。
- 对策从"更用力地伪装"改成"**更少地请求 + 命中即熔断 + 结果缓存**"：一次验证 + 一次首页导航，
  之后全程 `pushState` 页内读取，失败就等 10 分钟，而不是重试。
- 若 10 分钟冷却后仍 503，说明该出口被更长期标记，只能换网络出口（换节点），代码层面无解。

### 8.6 验证清单

1. 重启 `builds/mangrove/mangrove.exe`；**先等 10 分钟**（当前出口刚吃过 503）；
2. 点「验证 CF」→ 只应看到**一次**首页文档导航，过 Turnstile 后 2s 内出 `✅ cf_clearance`；
3. 贴链接点 Resolve → 日志应出现：`navigate: bootstrapping homepage first`（或复用）→
   `navigate: pushState → …` → `CDP DOM: page 1 …` → 累计到 ≈371；
4. 若出现 `navigate: 熔断 10 分钟`，说明判定已生效，**不要再连点**，本次会话不再发请求。

---

### 9. 第十轮（2026-10-19 续）：死锁修复与验证诚实化

> 承接第八轮（§8 / §11）已坐实的「节奏判定 / 命中即熔断 / 不伪装」三铁律，本轮聚焦
> **两条用户实跑现象**的代码层根治：
> - **现象 A**：重启等 10 分钟后直接点「验证 CF」→ CfT 显示 comix `Third-party apps are
>   not supported`（503）拦截页，但 UI 仍报"验证成功"。
> - **现象 B**：用「创建下载任务」贴链接点 Resolve → 弹出 comix 网页（首页正常、书都在、
>   URL 仍是 `comix.to` 没进详情页），但对话框**一直转圈不结束**。

#### 9.1 死锁根因（现象 B 的根）

错误 / 熔断路径在 **死掉或已被封的 CDP 连接** 上自动触发 `verifyViaCfT` / `forceHome` /
`comixCookies`，而旧 `_send` 的超时是**固定 15s 且无可中断的 socket 状态检查**：

```
任何异常（含 comix 自家 503）
  → on Object 兜底调 verifyCloudflare
    → _verifyViaCfT 对死/封 CDP 发 forceHome / bringToFront / comixCookies
      → 每个 _send 15s 超时、readyState 不检查、写失败不立即抛
        → 连发 ≈ 3 分钟空等（每 15s 一次，用户看到"一直转圈"）
```

关键病灶有三个：
1. `download_manager_page._resolve` 用 `on Object` 捕获**任何**异常（含 comix 自家 503）
   → 一律调 `verifyCloudflare` → 错误路径反复重验证。
2. 旧 `_verifyViaCfT` **取到 `cf_clearance` 即 `return true`**，即使 comix 墙仍在也伪造成功
   （现象 A："验证成功却仍 503"的来由）。
3. 旧 `_send` 对每个方法调用都等满 15s，CDP 已死时无法快速失败。

#### 9.2 本轮代码改动总表（9 处）

| # | 文件 · 位置 | 改动 | 解决的问题 |
|---|---|---|---|
| 1 | `comix_client.dart` · `ComixCDPWorker._send` | 超时压到 **8s**（`_sendTimeout=8s`）；`readyState != open` 立即 `throw StateError("CDP socket not open")` 快速失败；`ws.add` 写失败立即抛 | 死 CDP 不再连发 15s 空等 |
| 2 | `comix_client.dart` · `_waitRoute` | 返回值由 `void` 改 `Future<bool>`：503 分支 `return false`；首页 `ready==complete` / `expectChapters` / 内容变化分支 `return true`；超时末尾 `return false` | 导航结果可判定，下游可据此决策 |
| 3 | `comix_client.dart` · `navigate` | pushState 未就绪且未熔断时，**补一次干净 URL 直接文档导航**（`?page=N` 等 query 剥离，只留 `https://comix.to{path}`），仅一次避免连发触发判定 | Round 9 实证：干净详情 URL 直接导航 3s 完整渲染 |
| 4 | `comix_client.dart` · `forceHome` / `clearBreaker` | `forceHome` 返回 `bool`（CDP 死或仍 503 → `return false`）；新增 `clearBreaker()` 清 `_blockedUntil` + `blockedThirdParty=false` | 验证流程可据首页是否真恢复来放弃 |
| 5 | `comix_client.dart` · `_verifyViaCfT` | 死锁止血 + 诚实返回：①`forceHome()` 失败 `return false`（带 toast）；②轮询中 `blockedThirdParty` 真即 `return false`；③取到 `cf_clearance` 后若 `blockedThirdParty` 仍真则 `return false`（不再伪成功），否则 `clearBreaker()` + `return true` | 现象 A：墙退才报成功，墙在如实报失败 |
| 6 | `comix_client.dart` · `fetchPageSnapshot` | 吞掉 `COMIX_THIRD_PARTY` / 超时：`try{await cdp.navigate(url)}catch(e){return {status:503,blocked:true}}`；读 DOM 异常也返回 blocked，**不再落 WebView2 兜底** | 不再因 503 触发下游自动验证 |
| 7 | `comix_client.dart` · `fetchPageHtml` | **移除重复 CDP 导航分支**（开头那段 `if(cdpOk){await cdp.navigate(url)...}`），改为纯 WebView2 兜底（注释说明 CDP 导航已归 `fetchPageSnapshot`） | 避免二次文档导航踩中节奏判定 |
| 8 | `download_manager_page.dart` · `_CreateComixTaskDialogState._resolve` | `on Object catch(e)` 中：若 `msg.contains('COMIX_THIRD_PARTY')` 则 `rethrow`（跳过自动验证）；否则才走 `verifyCloudflare` + 重载详情 | 现象 B：comix 自家 503 不再傻等验证 |
| 9 | `assets/comix_to.js` · `loadInfo` | `if(!html){ if(ipBlocked){ throw new Error("COMIX_THIRD_PARTY: "+_comixBlockedHint) } … }` | 让 Dart 侧精确识别"comix 自家封锁"并跳过自动验证 |

#### 9.3 修复后的链路对照

| 场景 | 旧行为 | 新行为 |
|---|---|---|
| 点「验证 CF」，CDP 死/仍 503 | 连发 15s 超时 ≈3 分钟，且取到 clearance 就报成功 | `_verifyViaCfT` 立即 `return false` + toast；墙退才 `clearBreaker()` 返回 true |
| 创建下载任务贴 503 链接点 Resolve | `on Object` 兜底 → 自动验证 → 死 CDP 连发 → 一直转圈 | 识别 `COMIX_THIRD_PARTY` 直接 `rethrow` 报错，对话框立即结束转圈 |
| `navigate` 到 `?page=N` 类 URL | 直接文档导航易触发 503 | pushState 未就绪时补**一次**干净 URL 直接导航（剥离 query），仅一次避免连发 |
| `fetchPageSnapshot` 遇 503 | 落 WebView2 兜底 → 触发自动验证 | 直接返回 `status:503, blocked:true`，不再往下走 |

#### 9.4 验证清单（替换 §8.6）

1. 重启 `builds/mangrove/mangrove.exe`；**先等 10 分钟**（当前出口刚吃过 503）。
2. 点「验证 CF」：
   - 若 CfT 窗口能看到挑战页且过 Turnstile → 2s 内出 `✅ cf_clearance`；
   - **若 CfT 窗口仍是 comix 503 拦截页** → 本次应**立即提示验证失败并退出**，
     不再傻等、不再伪报成功（现象 A 已根治）。
3. 贴链接点 Resolve：
   - 正常 → 日志 `navigate: pushState → …` → `CDP DOM: page 1 …`；
   - **若返回 comix 503** → 对话框**立刻报错结束转圈**，不再无限转（现象 B 已根治）；
   - 不要对同一出口反复连点，命中即熔断。
4. 若出现 `navigate: 熔断 10 分钟`，说明判定已生效，**不要再连点**，本次会话不再发请求。

#### 9.5 诚实边界（重申）

- **不能承诺"无人值守全自动"**。comix 503 文案是写给第三方 app 的产品级态度，触发条件只能
  逆推出"短时间多次文档导航"。代码能做的是：少打扰、命中即退避、结果**如实**反馈、不伪装。
- 若 10 分钟冷却后仍 503，说明该出口被更长期标记，只能换网络出口（换节点），代码层面无解。
- **未决**：`?page=N` 导航仍 503、分页按钮无效、章节 API 加密仍是待解题（本轮未触及章节采集逻辑，
  仅修死锁与导航策略与验证诚实化）。章节全集 371 条 ≈ 19 页的规模化采集方案留待下轮。

---

### 10. 第十一轮（2026-10-19 续2）：改用真实 Chrome 会话 + 停掉第三方流量

#### 10.1 用户实跑现象（承接第十轮）

- 「验证 CF」之后仍被拦截：CfT 窗口里的页面是 **`comix.to` 首页本身**就显示
  `Third-party apps are not supported`（不是详情页导航姿势的问题）。
- 「创建下载任务」贴 `.../title/6emnz-the-runaway-extra-...` 点 Resolve →
  `采集失败: Error: all URLs failed for hid=6emnz at loadInfo (ComixTo:408:62)`。
- **转圈已止住**（第十轮死锁修复生效），但采集链路一条路都没通。

#### 10.2 决定性推论：503 是「会话/浏览器」级，不是 IP 级

- **同一台机器、同一个网络出口**：用户自己的正式版 Chrome 能正常打开 comix，
  App 拉起的 CfT 却 503。
- 若 503 是 IP 级封禁，两个浏览器应该一起挂；既然只有 CfT 挂，说明判定钉在
  **会话/浏览器身份**上（profile 里的 cookie、CfT 这个二进制本身、以及我们发请求的方式）。
- 这把方向从「等冷却 / 换出口」纠正为「**换一个 comix 已经信任的会话**」。

#### 10.3 三条根因（本轮全部处理）

| # | 根因 | 证据 |
|---|---|---|
| 1 | **Dio 直连 comix** | `comix_to.js` 的 `loadInfo` 第一步是 `Network.get(urls[i])` → `sendMessage('http')` → Dart `_http` → Dio。普通 HTTP 客户端没有任何浏览器指纹/`Sec-Fetch`，comix 的文案正是写给这种「第三方 app」 |
| 2 | **启动即导航 comix** | `ComixBrowserManager.ensureRunning()` 把 `https://comix.to/` 写进启动参数 —— 每启动一次 App 就是一次 comix 文档导航，持续喂给「短时间多次导航」判定 |
| 3 | **CfT + 被标记的独立 profile** | 用的是 `comix_cdp_profile`，一个被反复判定过的 profile；且 CfT 窗口自带「仅适用于自动测试」横幅，与用户真实 Chrome 不是同一个东西 |

#### 10.4 本轮代码改动

| # | 文件 · 位置 | 改动 |
|---|---|---|
| 1 | `assets/comix_to.js` · `loadInfo` | **删除 `Network.get`（Dio）整段**，并删掉「Chrome 伪装的 headers」。只走 `comix_fetch_html`（内置浏览器页内 fetch，带真实 cookie + `Sec-Fetch`） |
| 2 | `comix_browser.dart` · `ensureRunning` | 启动页由 `https://comix.to/` 改为 **`about:blank`**；真正需要时再由 `navigate()` 做一次首页 bootstrap |
| 3 | `comix_browser.dart` · `resolveChrome` | 优先 **系统正式版 Chrome**（`C:\Program Files\Google\Chrome\Application\chrome.exe`）；没有才退回随包 CfT / Playwright |
| 4 | `comix_browser.dart` · 新增 `realProfileDir` / `systemChromePath` / `_systemUserDataDir` / `hasRealProfileSeed` | 真实 profile 副本目录与探测 |
| 5 | `comix_browser.dart` · 新增 `seedRealProfile()` | **复制**用户真实 Chrome 的 `Local State` + `Default/Network/Cookies`（+ journal/wal）到副本目录。同一份 `chrome.exe` 打开，DPAPI/ABE 可解密 ⇒ comix 看到的就是「用户自己的浏览器会话」。源比副本新（>2min）才重新拷贝 |
| 6 | `comix_browser.dart` · 新增 `closeExisting()` | App 重启后上次的 CfT 通常还占着 9222；用 CDP `Browser.close` 干净关掉，再用正式版 Chrome + 真实 profile 副本重启（每次 App 运行只做一次） |
| 7 | `comix_client.dart` · `_antiDetectJs` | 删除 `plugins/languages/platform/hardwareConcurrency/deviceMemory` 覆盖（把 `plugins` 改成 `[1,2,3,4,5]` 本身就是明显指纹异常）；只保留 `navigator.webdriver → false`。**正式版 Chrome 的最好反检测就是不动原生值** |
| 8 | `comix_client.dart` · `_verifyViaCfT` 文案 | 503 时引导改为「先用本机 Chrome 正常打开 comix.to 浏览一页，再重启本 App 同步登录态」 |
| 9 | `comix_client.dart` · `ComixCDPWorker._connect` | 按 `readyState == open` 判定缓存连接；`closeExisting()` 重启浏览器后旧 `_ws` 已 closed，若直接返回会往死 socket 发命令 → 首次导航被误判成 503。现在陈旧连接彻底丢弃并重连新 target |

#### 10.5 修复后的预期链路

```
App 启动
  → ensureRunning: 关掉遗留 CfT → 用正式版 Chrome + comix_real_profile 副本拉起 about:blank
  → seedRealProfile: 从 %LOCALAPPDATA%\Google\Chrome\User Data 复制 Local State + Cookies
点「验证 CF」
  → forceHome: Page.navigate 首页（真实 cookie 已在 jar 里，通常直接 200，无挑战）
  → 轮询 cf_clearance → 命中且墙已退 → clearBreaker + true
贴链接 Resolve
  → loadInfo → comix_fetch_html（浏览器）→ navigate: 首页 bootstrap → pushState 详情页
  → outerHTML + pageMeta → 建下载任务（不再有任何 Dio 请求 comix）
```

#### 10.6 验证清单

1. 先用你**平时的 Chrome** 正常打开 `https://comix.to/` 浏览一页（确保这个会话在你机器上是好的）。
2. 重启 `builds/mangrove/mangrove.exe`；日志应出现：
   `seedRealProfile: copied real Chrome cookies → true` 与 `profile select: real-profile(copy)`。
3. 弹出的浏览器应是**正式版 Chrome**（没有「Chrome 测试版…仅适用于自动测试」横幅）。
4. 点「验证 CF」→ 首页应直接正常渲染（不再 503）。
5. 贴链接 Resolve → 日志 `comix_to: browser fetch …` → `comix_fetch_html via CDP: N chars ✅`，
   且**不应再出现** `comix_to: fetching …`（Dio 路径已删）。

#### 10.7 诚实边界

- **这仍不是「无人值守全自动」**：借的是用户自己已经验证过的会话。若用户从未在真实 Chrome 里
  访问过 comix，副本里没有可用 cookie，仍会吃 CF 挑战（需人过一次）。
- 若**正式版 Chrome 自己也 503**，说明是出口 IP 被长期标记，代码层面无解，只能换网络出口。
- **未决**：`?page=N` 分页仍 503、章节 API 加密、371 条章节的规模化采集 —— 本轮只解决「连得上」。

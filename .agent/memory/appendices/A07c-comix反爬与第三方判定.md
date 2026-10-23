# A07c · comix.to 反爬判定：Third-party 页 / CF 挑战 / 会话标记

> **触发时机**：comix 采集出现 `Third-party apps are not supported`、`请稍候…`、
> 503、或"明明过完验证还是被拦"**之前**读本篇。
> 上位：`A07-comix源.md`（源配置/WAF/token）｜`A07b`（章节列表/分组/翻页）
> 取证全过程：`.agent/documents/worklog/comix-第三方判定取证与采集链路修复.md`

---

## 1. 🔴 「Third-party apps are not supported」不是 Cloudflare

- 它是 **comix 自己的页面**，HTTP **状态码 503**，`document.title` 就是这句话。
- CF 挑战页长什么样：`document.title = "请稍候…" / "Just a moment..."`，
  body 含「正在进行安全验证」/「Verify you are human」，html ≈ **28KB**。
- 两者要分开判断：
  - 挑战页 → 等/过验证；
  - 503 Third-party → **请求姿势不对，过验证也没用**。

## 2. 🔴 触发条件：直接打开站内非首页文档

实测对照（Node CDP，同一 cookie、同一 IP）：

| 入口方式 | 结果 |
|---|---|
| `Page.navigate` 到 `/title/<hid>-<slug>` | **503 Third-party** |
| `Page.navigate` 到 `/`（首页） | 正常（会话未标记时） |
| 首页落地后 `history.pushState` + `popstate` 到详情页 | **正常渲染** |

⇒ **硬规矩：comix 站内跳转一律走客户端路由 `pushState`，禁止 `Page.navigate` 到非首页 URL。**
已有实现：`ComixCDPWorker.navigate()`（`lib/network/comix_client.dart`）。

## 3. 🔴 `pushState` 到**同一 URL** 是 no-op

- SPA 不会因为"路由到当前地址"而重新渲染 → 章节区仍是空的。
- 线上实证：`comix_fetch_html via CDP: 86814 chars ✅`（详情页已渲染）
  紧接着 `fetchChapters` 再 pushState 同一 URL → `CDP SSR empty`。
- 处理：同 URL 时**先 pushState 回首页、再进目标**（代码已修）。

## 4. 🔴 CF 挑战只认「本会话自己的 cf_clearance」

- 全新 profile（无 cookie）：403 → Turnstile → **40s 内不会自动过**；
- 带有效 `cf_clearance`：直接 200；
- **重复文档导航会把挑战重置**：连续 3 次 `Page.navigate` → 3 次都是 403 + 新挑战，
  一次都没清过。⇒ **一次导航，后面全靠页内读取/路由。**

## 5. 🔴 503 是会话级标记，不是 IP 永久封禁

- 把某个 profile 里 `comix.to` 的 cookie 全删 → 503 **立刻消失**，退回正常 CF 挑战。
- 说明 comix 会给"看起来像第三方应用"的会话打标记（服务端），换干净会话即恢复。
- 反过来：**同一份被标记的 profile 反复试，只会一直 503**。冷却或换会话。

## 6. 🔴 与浏览器品牌无关（别浪费时间在"换个更真的浏览器"上）

同页面探针实测：

| 项 | CfT 155.0.8059.84 | 真 Chrome 155.0.8059.80 |
|---|---|---|
| `navigator.webdriver` | false | false |
| `userAgent` | `...Chrome/155.0.0.0 Safari/537.36` | 同串 |
| `uaData.brands` | `Chromium` + `Not(A:Brand` | `Google Chrome` + `Chromium` + `Not(A:Brand` |
| `plugins.length` | 5 | 5 |

- brands 少一个 `Google Chrome` 是 CfT 的客观差异，但**真实 Chrome + 真实 profile 一样吃 503**，
  所以它不是本次失败的主因。
- 真正决定成败的是 ①请求姿势（文档导航 vs 页内路由）②会话有没有被标记 ③有没有本会话的 cf_clearance。

## 7. 🔴 「AI 之前能采」的真实原因（可复现配方）

1. 用**用户真实 Chrome** + **真实 profile 的副本**（VSS 影子副本，带用户自己的
   `cf_clearance`(HttpOnly) + `session`）；
2. 首屏加载后，采集全部是 **`Runtime.evaluate` 页内读**（DOM / 页内 fetch），
   **不再发起文档导航**；
3. 该会话当时**未被标记**。

⇒ 结论：不是"AI 的浏览器更真"，是"借了人已验证过的会话 + 只做页内读取"。

## 8. 其他实测坑

- **`--no-sandbox` 不要加**：非容器环境无收益，还会在窗口顶部挂
  「不受支持的命令行标记：--no-sandbox」警告条（明显的非正常启动信号）。
- 章节 API 响应是**加密**的：`/api/v1/manga/<hid>/chapters?...&w=ff0ff&_=<token>`
  返回 200 但 payload 加密，`json.parse` 钩子只抓得到 SSR 的 detail JSON。
  ⇒ 章节数量仍要靠 **DOM**（见 A07b）或破译加密，不要指望直接读 API。
- 章节列表每页 **20 条**；503jz 全集 **371 条 ≈ 19 页**。
  旧 DOM 兜底只读当前页 → 20 条 → 只有 **5 个话号**（线上日志实证）。

## 9. 🔴 503 会话标记恢复路径（2026-10-19 定稿，已进码）

- `navigate()` 检测到 Third-party 页时置 `blockedThirdParty = true`。
- 恢复流程（`ComixClient.verifyCloudflare` → `_verifyViaCfT`）：
  1. `clearComixCookies()` —— 先枚举 `Network.getCookies`，再逐条
     `Network.deleteCookies{name,domain,path}` 删干净。
     ⚠️ **`name` 是必填参数**，只传 domain 会报 "Invalid parameters" 且被 catch 吞掉
     （旧实现就是这样，日志写"cleared"其实一个都没删）。
  2. `forceHome()` —— **硬 `Page.navigate` 首页**（不能用 pushState：503/挑战页没有 SPA 运行时）。
  3. `bringToFront()` —— 把 CfT 窗口提到最前，让用户看得见挑战页。
  4. 每 2s `comixCookies()` 轮询 CfT 的 cookie jar，出现 `cf_clearance` 即成功。
  5. `_saveCfCookie` + `JsEngine.reloadCfClearance()` + `resetToHome()`。
     **不需要回注 CfT**——人在 CfT 窗口里过验证，cookie 本来就在同一个 jar 里。
- **触发点**：`fetchChapters`（`_tryFetchChapters`）、`fetchPageHtml` 两条直接 navigate 路径。
- **优先级铁律**（呼应 §2）：恢复到目标页仍走 `pushState`；只有**首页**可以用 `Page.navigate`。

## 10. 🔴 CF 验证不要再走 WebView2（2026-10-19 实跑教训）

- 现象：点「验证 CF」→ `verifyCloudflare: workers disposed, opening AppWebview...` 之后
  **再无任何日志**；再点只打印 `already in progress, awaiting...`，永远不恢复。
- 取证：`data/ua_debug.txt` 时间戳更新、含新 UA 探针 ⇒ **WebView2 确实建出来了**；
  但文件里**没有 `[WebView] onLoadStop`** ⇒ 页面从未 load stop。
- 死锁成因：旧代码把 5 分钟超时定时器写在 `onLoadStop` **内部**；回调不触发 ⇒ 定时器不启动
  ⇒ completer 永不完成 ⇒ `_verifyGuard` 永不释放 ⇒ 之后所有点击都被挡住。
  **凡是"等回调再起超时"的写法都必须改成方法级 `timeout` 兜底。**
- 现状：`verifyCloudflare` 是调度器 —— 有内置 CfT 就用 CfT 窗口验证（默认路径），
  没有 CfT 才回退 `_verifyViaAppWebview`（已加方法级超时）。
- 旁证（curl 实测，无 cookie + Chrome UA 请求首页）：`403 / 5537B / Just a moment...`
  —— 是 CF 挑战而不是 503 ⇒ **出口 IP 干净，503 完全来自被标记的会话 cookie**。
  这条探测应作为"到底是 IP 还是会话"的快速判据：
  - 200 正常 / 403 Just a moment → IP 干净，清 cookie 就能救；
  - 503 + `Third-party apps` → IP 或节点被标记，清 cookie 也救不回，需冷却/换节点。

---

## 11. 🔴 重大更正（2026-10-19 第八轮，推翻 §5 与 §9）

### 11.1 被推翻的两条旧结论

| 旧结论（错） | 本轮实证 |
|---|---|
| 「503 是会话级标记，删掉 comix cookie 就消失」 | **全新 profile + 只导航一次首页 → 立刻 503**。cookie 不是变量 |
| 「`curl` 拿到 `403 Just a moment` 说明出口 IP 干净」 | **无效判据**。403 是 CF 在源站之前出的挑战，源站是否 503 完全没被问到 |
| 「恢复路径：清 cookie → 人过 CF → 重载首页 → 重试」 | **反向优化**。把 1 次 503 放大成 4 次文档导航，正好踩中判定 |

### 11.2 三组对照实验（Node CDP，全部只导航 1 次）

| 实验 | 变量 | 结果 |
|---|---|---|
| H | 全新 profile + 注入 cf_clearance，只导航首页 | 立刻 503 |
| I | 同 H + `--proxy-server=127.0.0.1:7890`（换出口） | 仍 503 |
| J | 同 H + `Network.setUserAgentOverride`（UA + `Sec-CH-UA` + `fullVersionList` 伪装正式版 Chrome 155） | 仍 503 |
| K | 同 H + 页内 `fetch(title, {credentials:'include', Accept:'text/html'})` | 503（3279B / 第二次 1974B） |

⇒ **指纹、UA/Client Hints、出口 IP 都不是决定性变量**。comix 的判定看的是
**这条访问的节奏**（同一出口短时间内的文档导航次数）。

零请求佐证：CfT profile 的 `Default/Network/Cookies` 里 comix 只剩一条已过期的
`cf_clearance`，**没有 `session` / `__cf_bm`**。

### 11.3 现在遵循的铁律

1. **一次会话只做一次首页硬导航**（`_homeNavigate()` 限速 45s，窗口内复用当前页）。
2. 之后全程 `pushState` 页内读取；**失败绝不重载、绝不清 cookie**。
3. 命中 503 → `_blockedUntil = now + 10min` **熔断**，`navigate()` 直接抛
   `COMIX_THIRD_PARTY: …`，不再发任何 comix 请求。
4. `_waitRoute()` 必须等「path+query 已切换 **且** 内容真的变了」才返回——
   旧实现 `readyState==='complete'` 恒真，会把首页 DOM 当详情页交出去（620KB 那次的根因）。
5. 详情页走 SPA 路由后**没有 SSR `#initial-data`**：靠 `pageMeta()` 的
   `og:title/og:image/og:description/path` 兜底，章节另走章节桥。
6. **不要承诺无人值守全自动**。comix 的 503 文案本身就是写给第三方 app 的；
   代码能做的是少打扰、命中即退避，而不是"更用力地伪装"。

---

## 12. 🔴 第十轮更正（2026-10-19 续）：死锁止血 + 验证诚实化

承接 §11 的"节奏判定三铁律"，本轮把用户实跑的两条现象在代码层根治。

### 12.1 推翻的旧认知（本轮）

| 旧认知（错） | 本轮修正 |
|---|---|
| 「`_verifyViaCfT` 取到 `cf_clearance` 即 `return true`」 | **CF 过 ≠ comix 放行**。CF clearance 只代表过了 Cloudflare，comix 自己的 503 墙仍在时仍应 `return false`，只有 `blockedThirdParty` 已清才报成功 |
| 「任何异常都兜底自动验证」 | comix 自家 503（`COMIX_THIRD_PARTY`）**不应**触发自动验证——它没有验证可过，只会死等 |
| 「`_send` 固定 15s 超时即可」 | 死/封 CDP 上 15s × N 连发 = 用户看到的"一直转圈"。必须 **8s 短超时 + `readyState` 检查 + 写失败即抛** 才能快速失败 |

### 12.2 死锁链路（现象：创建下载任务一直转圈）

```
任何异常（含 comix 自家 503）
  → download_manager_page._resolve 的 on Object 兜底 → verifyCloudflare
    → _verifyViaCfT 对死/封 CDP 发 forceHome/comixCookies
      → 每个 _send 15s 超时、不查 readyState → 连发 ≈3 分钟空等
```

### 12.3 修复要点（9 处，详表见工作日志 §9.2）

1. `_send` 超时压到 **8s** + socket 状态检查 + 写失败即抛（死 CDP 快速失败）。
2. `_waitRoute` 改返回 `bool`，导航结果可判定。
3. `navigate` 在 pushState 未就绪时补**一次**干净 URL 直接文档导航（剥离 `?page` 等 query，
   仅一次避免连发触发判定；Round 9 实证干净详情 URL 直接导航 3s 完整渲染）。
4. `forceHome` 返回 `bool` + 新增 `clearBreaker()`；CDP 死/仍 503 时验证流程据首页是否真恢复而放弃。
5. `_verifyViaCfT` 诚实返回：取到 `cf_clearance` 后若 `blockedThirdParty` 仍真则 `return false`
   （不再伪成功），否则 `clearBreaker()` + `return true`。
6. `fetchPageSnapshot` 吞掉 `COMIX_THIRD_PARTY`/超时，返回 `status:503,blocked:true`，不再落 WebView2 兜底。
7. `fetchPageHtml` 移除重复 CDP 导航分支，避免二次文档导航踩中节奏判定。
8. `download_manager_page._resolve` 识别 `COMIX_THIRD_PARTY` 直接 `rethrow`，跳过自动验证。
9. `assets/comix_to.js` 的 `loadInfo` 抛 `COMIX_THIRD_PARTY: …` 标记，让 Dart 侧精确识别"comix 自家封锁"。

### 12.4 验证达成标准

- 点「验证 CF」：CfT 窗口仍是 comix 503 拦截页时，**立即提示失败并退出**，不再傻等、不再伪报成功。
- 贴 503 链接点 Resolve：对话框**立刻报错结束转圈**，不再无限转圈。
- 构建版本：`2.8.5+249`（本轮交付，`run_build_task.py` → `BUILD_OK`，全量 `flutter analyze` 零新增）。
- **未决**：`?page=N` 导航 503 / 分页按钮无效 / 章节 API 加密的规模化采集方案仍未触及，留待下轮。

---

## 13. 🔴 第十一轮（2026-10-19 续2）：改用真实 Chrome 会话 + 停掉第三方流量

### 13.1 决定性事实：503 是会话级，不是 IP 级

**同一台机器、同一个出口**：用户自己的正式版 Chrome 打开 comix 正常，App 拉起的
Chrome for Testing 首页就 503。若是 IP 级封禁，两者应一起挂 ⇒ 判定钉在**会话/浏览器身份**上。
⇒ 方向从「等冷却/换出口」改为「**换一个 comix 已信任的会话**」。

### 13.2 三条根因（已全部修复）

| 根因 | 说明 | 修法 |
|---|---|---|
| **Dio 直连 comix** | `comix_to.js loadInfo` 第一步 `Network.get` → Dart `_http` → Dio。无浏览器指纹/`Sec-Fetch`，正是 comix 文案针对的「第三方 app」 | 删除整段 `Network.get`，只走 `comix_fetch_html`（浏览器页内 fetch） |
| **启动即导航** | `ensureRunning` 把 `https://comix.to/` 当启动参数，每开一次 App 就多一次文档导航 | 启动页改 `about:blank`，按需再 bootstrap 首页 |
| **CfT + 被标记 profile** | 用 `comix_cdp_profile`（已被反复判定）+ CfT 二进制 | 改用**系统正式版 Chrome** + **真实 profile 的 cookie 副本** |

### 13.3 核心机制：借用真实 Chrome 会话（唯一实证可用的配方）

`ComixBrowserManager.seedRealProfile()`：
1. 源 = `%LOCALAPPDATA%\Google\Chrome\User Data`；
2. 复制 `Local State`（含 DPAPI 包裹的 os_crypt key）+ `Default/Network/Cookies`
   （+ `Cookies-journal` / `Cookies-wal`）到 `%APPDATA%\Mangrove\comix_real_profile`；
3. 用**同一份 `chrome.exe`** 以 `--user-data-dir=<副本>` 拉起 ⇒ DPAPI/ABE 可解密，
   comix 看到 `session` / `cf_clearance` / `__cf_bm`，等价于用户自己的浏览器；
4. 每次 App 运行先用 CDP `Browser.close` 关掉遗留实例（Chrome 不随父进程退出），
   再用正式版 Chrome 重启一次，保证副本是最新的。

### 13.4 反检测的正确姿势：别乱改原生值

旧 `_antiDetectJs` 把 `navigator.plugins` 覆盖成 `[1,2,3,4,5]`（数字数组，非 Plugin 对象），
还改写 `languages/platform/hardwareConcurrency/deviceMemory` —— 在正式版 Chrome 里这是
**明显的指纹异常**。现在只保留 `navigator.webdriver → false`，其余不动。

### 13.5 验证要点

- 日志应出现 `seedRealProfile: copied real Chrome cookies → true` 与
  `profile select: real-profile(copy)`；
- 弹出的浏览器应是**正式版 Chrome**（无「仅适用于自动测试」横幅）；
- 点「验证 CF」→ 首页应直接渲染（不再 503）；
- Resolve 时**不应再出现** `comix_to: fetching …`（Dio 路径已删）。

### 13.6 诚实边界

- 借的是用户**已验证过**的会话；若用户从未在真实 Chrome 访问过 comix，副本无可用 cookie，
  仍需人过一次 CF。
- 若**正式版 Chrome 自己也 503**，是出口 IP 被长期标记，代码无解，只能换网络出口。
- `?page=N` 分页 503 / 章节 API 加密 / 371 条规模化采集仍未解决，本轮只保证「连得上」。

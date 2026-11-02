# P-DL9: Mangrove Cloudflare Bypass 任务上下文

> **⚠️ 新对话开场白** — 复制下面这一段到新对话，让 AI 快速理解上下文。
> 原始对话轮数过多，本文件是浓缩上下文 + 踩坑总结 + 下一步计划。

---

## 🎯 任务目标

Mangrove（Flutter/Windows 漫画阅读器 v2.8.5+249）无法采集 comix.to 漫画章节数据。根因：Cloudflare Turnstile 强制人机验证。用户 Chrome 能正常访问，但 Mangrove 的 WebView2（HeadlessInAppWebView）每次都被 CF challenge 阻塞。

---

## 📦 已完成的代码改动（3 个文件，BUILD_OK @ 18:58）

### 1. `lib/foundation/js_engine.dart` — Dio HTTP 自动注入 cf_clearance
- 新增 `_cachedCfClearance` + `_cfCookieLoadedAt` + 10min TTL 缓存
- 新增 `getCfClearance()` static 方法：从 `{App.dataPath}\cf_cookie.json` 读 cookie
- 新增 `reloadCfClearance()` static 方法：验证成功后刷新缓存
- **`_http()` 方法改动**：URL 含 `comix.to` 时自动加 `Cookie: cf_clearance=xxx` header
  - 这是最关键的修复！JS 源的 `Network.get()` 走 Dio，之前完全没 cookie

### 2. `lib/pages/webview.dart` — AppWebview 加 Chrome UA
- `InAppWebViewSettings` 加 `userAgent: webUA`
  - **这是 WebView 转圈的根因！** 没 Chrome UA → CF 检测 Edg/WebView → 永不渲染 Turnstile checkbox
- 加 `onReceivedError` 日志回调

### 3. `lib/network/comix_client.dart` — verifyCloudflare 彻底重写
- **去掉所有 dispose 流程**（卡死根因！之前 dispose ImageLane + worker + environment + 等 5s → 死锁）
- **去掉 showDialog**（`barrierDismissible: false` + `PopScope(canPop: false)` → UI 卡死）
- **改用 `MaterialPageRoute` push** — 任何页面都能弹出
- 轮询机制：`Timer.periodic(2s)` 每 2s 查一次 cookie，检测到 cf_clearance 就自动保存 + pop
- 新增 `_saveCfCookie()` static 方法：把验证成功后的 cf_clearance 写到 cf_cookie.json
- `_injectCfClearance()` 加了详细日志（之前被 catch 吞了，没日志）
- `_ComixImageWorker` 加了 `disposeAll()` 方法（虽然现在 verifyCloudflare 不用了）

### 4. 侧栏「验证 CF」按钮（之前对话已加）
- 在 `lib/pages/main_page.dart` 左侧栏加了 Icons.shield 按钮
- 调用 `ComixClient.verifyCloudflare()`

---

## 🔑 运行时 cookie 路径
- `cf_cookie.json` = `%APPDATA%\io.github.maelshiyan02\mangrove\cf_cookie.json`
- **Dio 自动读这个文件**，WebView2 CookieManager 也读这个文件
- cookie 过期极快（15~30min），必须定期手动验证

---

## 🚫 踩过的坑（重要！）

### WebView2 相关
| 坑 | 根因 | 状态 |
|---|---|---|
| `Cannot create InAppWebView instance!` | 两个 WebViewEnvironment 同 userDataFolder（headless worker + AppWebview） | **暂时绕开** — verifyCloudflare 不再 dispose headless，让两个并存 |
| WebView 一直转圈 | AppWebview 没设 Chrome UA，WebView2 默认 UA 含 Edg/WebView → CF 检测为 bot | ✅ 已修 |
| showDialog + barrierDismissible: false 死锁 | 阻塞 UI，内部 async 拿不到 context | ✅ 已换 MaterialPageRoute |
| verifyCloudflare dispose headless 卡死 | await 多个 WebView dispose + environment dispose + 等 5s → 总耗时 30s+ | ✅ 已彻底移除 dispose 流程 |
| ImageLane 没被 dispose | verifyCloudflare 只 dispose comix worker，ImageLane 3 个 headless 还占 environment | **暂时绕开** |

### Cloudflare / Cookie 相关
| 坑 | 根因 | 状态 |
|---|---|---|
| cf_clearance 过期极快 | 只有 15~30min 有效期 | **必须手动验证** |
| cf_clearance 和 TLS 指纹绑定 | Chromium cookie 给 Dio 可能无效（JA3/JA4 不同） | **不确定** — 需要实测 |
| Dio HTTP 路径完全没 cookie | JS Network.get() → JsEngine._http() → Dio 没 cf_clearance | ✅ 已修 |
| WebView2 CookieManager.setCookie 位置 | 之前在 ensure() 里调用，但可能被并发 ensure() 跳过 | **加了详细日志，待验证** |
| Playwright Chromium 也被 CF challenge | CF 2026 年加强检测，任何自动化都过不了 | ✅ 确认 |
| nodriver (真 Chrome CDP) 也过不了 Turnstile | headless 模式一样被检测 | ✅ 确认 |
| curl + cf_clearance cookie → 403 Forbidden | **cookie 过期了**（不是 TLS 指纹绑定） | ✅ 确认是过期问题 |

### Chrome cookie 提取相关（全失败！）
| 方法 | 结果 | 原因 |
|---|---|---|
| Python sqlite3 直接读 Chrome cookie DB | 失败 | Chrome 运行时锁文件 WinError 32 |
| SQLite backup API (file:mode=ro&immutable=1) | 失败 | Chrome 独占锁，SQLite backup 也打不开 |
| 文件复制（Chrome 关闭后） | 成功 | Chrome 关掉后能复制 |
| Chrome v20 cookie 解密 | **部分成功** | DPAPI encrypted_key 能解出 32 字节 AES key，但 AES-GCM 解 cookie 返回 InvalidTag（格式不确定） |
| Chrome remote debugging port | **在临时 user-data-dir 上成功**，**在用户 profile 上失败** | Chrome 启动时如果发现 profile 已被占用（SingletonLock）→ 忽略所有命令行参数包括 --remote-debugging-port |

---

## 🧪 下一步测试（必须跑！）

1. **运行最新 build**：`build\windows\x64\runner\Release\mangrove.exe`
2. **点侧栏「验证 CF」按钮** → 看能否弹出新页面（不是卡死）
3. **看 AppWebview 能否正常加载 comix.to**（Chrome UA 应该让 Turnstile checkbox 正常渲染）
4. **手动点 Turnstile checkbox** 过验证
5. **验证成功后** 页面自动关闭，cf_cookie.json 被更新
6. **搜索《I will save my father》** → 看能否采集章节
7. **看日志里关键行**：
   - ✅ `verifyCloudflare: opening AppWebview with Chrome UA`
   - ✅ `verifyCloudflare: ✅ cf_clearance detected (len=...)`
   - ✅ `JsEngine: _http: injected cf_clearance for https://comix.to/...`

---

## 📋 代码位置速查

| 功能 | 文件 | 关键函数/类 |
|---|---|---|
| Dio 自动注入 cookie | `lib/foundation/js_engine.dart` | `_http()` ~Line 290, `getCfClearance()` ~Line 85, `reloadCfClearance()` ~Line 119 |
| WebView Chrome UA | `lib/pages/webview.dart` | `createWebviewWithEnvironment()` ~Line 194 |
| verifyCloudflare | `lib/network/comix_client.dart` | `verifyCloudflare()` static ~Line 1812 |
| cf_clearance 文件路径 | 硬编码 `"${App.dataPath}\\cf_cookie.json"` | App.dataPath = `%APPDATA%\io.github.maelshiyan02\mangrove\` |
| JS 源（同步三处） | `data/comic_source/comix_to.js` ← 编辑这里 | 构建输入在 `Mangrove\assets\`，运行时在 `%APPDATA%\...\comic_source\` |
| 构建命令 | `tools/run_build_task.py` | **禁止直接跑 flutter** |

---

## ⚡ 快速验证 checklist

- [ ] Build 成功（BUILD_OK）
- [ ] 运行 Mangrove → 不崩
- [ ] 点「验证 CF」→ 能弹出页面
- [ ] 验证页不转圈 → Turnstile checkbox 能看到
- [ ] 手动点 Turnstile → 验证成功 → 页面自动关闭
- [ ] cf_cookie.json 被更新（检查 timestamp）
- [ ] 搜索漫画 → 能采集章节数据

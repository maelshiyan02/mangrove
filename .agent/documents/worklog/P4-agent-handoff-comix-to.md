# P4 comix.to 漫画源 — Agent 交接开场白

> 用途：把这段内容作为开场白贴给任何新 AI agent（Trae sub-agent / Cursor / Claude / Copilot），它会立刻获得完整上下文。
> 最后更新：2026-10-01（v0.5.0：token 参数名 `_`、加密响应双通道、阅读器虚拟化、CDN 防盗链）
>
> 📌 **完整工程记录（含全部轮次复盘与下载设计）已整合到
> `docs/P4-针对comix.to漫画源配置文件的设计与实施工程记录日志.md`**，
> 本文件只保留"新 Agent 上手所需的最小上下文"。

---

## 项目身份

**VeneraX** — Flutter Windows 桌面应用，路径 `D:\Ballonstranslator_Windows\VeneraX`。
当前任务：P4 comix.to 漫画源集成。章节采集链路已验证；v0.3.0 重构为常驻 HeadlessInAppWebView（无窗口）+ API JSON 直采，loadEp（阅读）已实现待实测。

---

## 🔑 API 逆向成果（2026-09-30，直接决定架构）

comix.to 是 Laravel + Vue SPA，**有标准 REST API**（axios baseURL `/api/v1`）：

| 功能 | 端点 | 响应（原始 body 带 `{status:"ok",result:{...}}` 包装） |
|------|------|------|
| 元数据 | `GET /title/{hid}` SSR | `<script id="initial-data">` 的 queries |
| 章节列表 | `GET /api/v1/manga/{hid}/chapters?page=N&...&_=token` | `result.items[]`: `{id,url,number,volume,name,group:{id,name},isOfficial,...}`、`result.meta.last_page` |
| **章节图片** | `GET /api/v1/chapters/{chapterId}?_=token` | `result.pages: {baseUrl, items:[{width,height,url}]}`，图片 URL = `baseUrl + item.url` |

- 无 token 直接调 API → `403 {"message":"Missing token."}`。
- 🔥 **token 参数名是单下划线 `_`，不是 `__`**（2026-10-01 实测：`?_=abc` → `Invalid token.`，其它名字一律 `Missing token.`）。v0.4.x 写成 `__=` 导致所有 API 路径静默降级 DOM，是"章节不全/只读到 3 页"的总根因。
- 🔥 **token 绑定完整 query string**：加/改任意一个参数（哪怕是 `page=2`）都会 `Invalid token.`。**不能复用 token 自己拼分页 URL** —— 必须让 SPA 自己发请求（点分页按钮 / 导航 browse 页）再截获；兜底只能整条重放截获到的 URL。
- 🔥 **部分响应是加密的**：原始 body 形如 `{"e":"fktAPNu-..."}`，只有 SPA 解密后经 `JSON.parse` 的才是明文。所以采集要 **fetch/XHR 截获 + JSON.parse 载荷** 双通道。
- 🔥 **阅读器是 Swiper slides 虚拟化**（同屏只渲染 3~5 张，不是懒加载）→ DOM 兜底最多拿 3~4 张，图片必须走 API。
- 🔥 **图片 CDN 要 `Referer: https://comix.to/`**，且单张响应可能很慢（30s 空闲超时会误判，需 90s）。
- token 由 **VMP 混淆的 `secure-*.js`** 生成，与浏览器指纹绑定（Node 里跑直接 RangeError），**只能在 comix.to 页面上下文内运行**。不要试图在 Dart/Node 侧复现。
- token 每次部署会换 chunk hash（如 `secure-tm5efk-B6Wo2GRC.js`），不要硬编码文件名。
- 纯 HTTP 直连 comix.to 页面（SSR）没有 Cloudflare 拦截（curl 直接 200），但 API 需要 token，所以列表/图片走 headless webview 页内截获。

### v0.3.0 无窗口架构（comix_client.dart）

1. `_ComixWorker` 单例：全 App 一个 `HeadlessInAppWebView`（离屏，**不弹窗**），cookie 持久化在 `{App.dataPath}\webview`，`enqueue()` 串行所有任务。
2. document-start 注入 fetch/XHR 钩子 → SPA 自己发的 `/api/` 响应记录进 `window.__comixApiLog` → Dart 轮询读取。
3. 章节列表：导航到 `/title/{hid}` 截获第 1 页 → 页内复用截获的 `__=` token 直接 fetch 第 2..N 页（不点分页按钮）。
4. 图片：导航到章节页 URL，截获 `/api/v1/chapters/{id}` → `baseUrl + item.url`。
5. DOM 采集（v1 逻辑）保留为兜底路径；API 路径失败自动降级。

---

## 核心文件

| 文件 | 说明 |
|------|------|
| `assets/comix_to.js` | JS source v0.3.0：loadInfo HTTP GET initial-data + 章节走 Dart headless 桥接 + `_chaptersCache` 缓存 + **loadEp 已实现**（comix_fetch_pages） |
| `lib/network/comix_client.dart` | **v2 全面重写**：常驻 HeadlessInAppWebView Worker（无窗口）+ API 截获直采 + DOM 兜底 |
| `lib/foundation/js_engine.dart` L218-226 | 桥接入口：`switch (method)` case `'comix_fetch_chapters'` / `'comix_fetch_pages'` |
| `lib/pages/webview.dart` | DesktopWebview 类（v1 弹窗方案，已不再是主路径）+ AppWebview（flutter_inappwebview 用法参考） |
| `lib/pages/comic_details_page/chapters.dart` | 翻译组 chips 可见性 bug 已修（见下） |
| `lib/pages/reader/images.dart` | 网络分支加了空图片防御（P0 崩溃修复） |
| `lib/network/app_dio_io.dart` | 简化版 RHttpAdapter（走 dart:io），pubspec 已注释 rhttp / flutter_rust_bridge |
| `pubspec.yaml` L62-63 | 已注释 `flutter_rust_bridge: 2.11.1` 和 `rhttp: ^0.15.1`（没人 import） |
| `tools/run_venera_check.bat` | analyze+test 一键脚本（本会话环境嵌套进程受限，用它在外部终端跑检查） |

---

## 已验证通过的功能

| 功能 | 状态 | 证据 |
|------|------|------|
| 章节采集完整链路 | ✅ | DesktopWebview → SPA 渲染 → 采集 DOM → dispatchEvent 翻 16 页 → 315 行 → versioned 聚合 **35 唯一章节号**（Sleepless Death, hid=9l3kj） |
| 元数据层 | ✅ | HTTP GET `/title/{hid}` → 解析 `<script id="initial-data">` → 标题/封面/标签/作者（纯 SSR） |
| JS 侧章节缓存 | ✅ | `var _chaptersCache = {};` 模块级变量，避免每次 loadInfo 重开 Webview |
| 双重 JSON 解析 | ✅ | `_parseEvalResult` 循环 jsonDecode 直到 `startsWith('{')` |
| SPA 翻页 | ✅ | `dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true, view: window}))` |
| 翻页验证 | ✅ | 每页翻完检查 `firstHref` 和 `button.npager__num.is-active` 是否变化 |

---

## 🔥 必须记住的踩坑经验（不看必炸）

| # | 坑 | 解法 |
|---|-----|------|
| 1 | **WebView2 evaluateJavascript 双重 JSON 序列化** | JS `return JSON.stringify({...})` → WebView2 再 stringify → Dart 拿到 `"JSON-string"`。**循环 jsonDecode** 直到 `startsWith('{')` |
| 2 | **SPA 翻页 btn.click() 无效** | React/Vue 不响应原生 click()。必须 `btn.dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true, view: window}))` |
| 3 | **翻页必须验证 DOM 变化** | click() 返回 `{ok:true}` 不代表 SPA 真翻了。每页翻完检查 firstHref 和 activeBtn |
| 4 | **onTitleChange 触发太晚** | DesktopWebview 用 `onStarted`（200ms 就触发），轮询等待自己在 `_evalWithRetry` 里实现 |
| 5 | **pubspec Rust 依赖** | rhttp + flutter_rust_bridge 全项目没人 import，已注释。app_dio_io.dart 保留简化版 RHttpAdapter（API 兼容 webdav_library/data_sync） |
| 6 | **comix.to 详情页只有 SSR** | 只有 `/title/{hid}` 的 initial-data 有数据，搜索/分类页 `queries: {}` 空壳。所有列表功能必须走 DesktopWebview |
| 7 | **comix.to 分页结构** | 第一页只显示 `button.npager__num` 数字 1-8，后面是 "Next page"/"Last page"。href 格式 `/title/{hid}-{slug}/{id}-chapter-{N}` |
| 8 | **Windows DevMode symlink** | 注册表改了必须**重启系统**才生效 |
| 9 | **nuget 在 PATH** | `D:\dev\tools\nuget.exe` 必须在 PATH，否则 flutter_inappwebview_windows 编译失败 |
| 10 | **cmake install 目标** | Release 构建后 cmake install 硬编码目标 `../../builds/venera/`，不是 runner/Release。关键产物是 `data/app.so`（17MB AOT），不是 0.15MB 的 venera.exe 壳 |
| 11 | **JS 源不进 flutter_assets** | `assets/comix_to.js` 不会被打包；运行时从 `%APPDATA%\io.github.kyosee\venera\comic_source\*.js` 加载。**改了 JS 源必须手动复制到该目录**，否则 app 里跑的还是旧版 |
| 12 | **会话内构建** | WorkBuddy 会话内 flutter 嵌套进程必失败（CreateFile 231）。用 `tools/build_venera_release.bat` + 计划任务（schtasks）在独立进程树跑；analyze 必须加 `--no-fatal-infos` 否则 info lint 也返回非零 |

---

## comix.to 实际 DOM 结构（浏览器验证）

| 元素 | CSS 选择器 |
|------|-----------|
| 章节区域 | `SECTION.mpage__chapters` |
| 章节条目 | `li.mchap-item` |
| 主链接 | `a.mchap-row__primary`（**双下划线 BEM**） |
| 翻译组 | `a.mchap-row__group > span` |
| 分页按钮 | `button.npager__num`（active 页带 `.is-active`） |
| 每页条数 | 20 条，最后一页可能不足 |
| 总条目数 | 315 条（Sleepless Death 含多翻译组版本） |
| Versioned 聚合后 | 35 个唯一章节号 |

### href 格式
```
/title/{hid}-{slug}/{chapterId}-chapter-{chapterNum}
例: /title/9l3kj-sleepless-death/11408803-chapter-35
```

---

## 完整构建命令（Windows PowerShell）

```powershell
# === 环境 ===
$env:PATH = 'C:\Flutter\bin;D:\dev\tools;' + 'D:\Ballonstranslator_Windows\tools;' + $env:PATH
$env:HTTP_PROXY = 'http://127.0.0.1:7890'
$env:HTTPS_PROXY = 'http://127.0.0.1:7890'

# === 构建前闸门 ===
cd D:\Ballonstranslator_Windows\VeneraX
flutter clean          # 删 ephemeral（junction 可能失败，见踩坑 #8）
flutter pub get        # 拿依赖
flutter analyze        # 0 error / 0 warning（14 info 基线）
flutter test           # 838 单测

# === Release 构建 ===
flutter build windows --release --no-pub  # 增量 ~58s，全量 ~241s

# === 组装完整产物 ===
$cmake = 'D:\Visual Studio Windows\Visual Studio 2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
& $cmake --install 'D:\Ballonstranslator_Windows\VeneraX\build\windows\x64'

# === 运行 ===
Start-Process 'D:\Ballonstranslator_Windows\builds\venera\venera.exe'

# === 实时看日志 ===
Get-Content "$env:APPDATA\io.github.kyosee\venera\logs.txt" -Wait -Tail 100
```

---

## 日志路径

```
C:\Users\{USERNAME}\AppData\Roaming\io.github.kyosee\venera\logs.txt
```

- Release 模式也会写（Log.info 文件写入不区分 kDebugMode）
- Dart 侧日志前缀：`[ComixClient] ...`

---

## 当前遗留问题

| 优先级 | 问题 | 说明 | 涉及文件 |
|--------|------|------|----------|
| ✅已修 | 翻译组 chips 点击后消失 | 根因：可见性条件误用 `_displayChapters`（过滤后单组 → length==1 → 整行隐藏且无法取消）。已改为用原始 `chapters` 判断；顺带修了过滤态下 duplicateChapterIndices 错位问题 | `lib/pages/comic_details_page/chapters.dart` |
| ✅已修(待实测) | 阅读崩溃 Invalid argument(s): 1 | loadEp stub 返回空 images → 阅读器按成功处理 → maxPage=0 下游崩溃。修复：loadEp 实装 + images.dart 网络/无缝连续两个分支都加了 isEmpty 防御（转可重试错误页） | `assets/comix_to.js` + `lib/pages/reader/images.dart` |
| ✅已修(待实测) | 每次采集弹 Webview 窗口 | v2 改为常驻 HeadlessInAppWebView，无窗口、cookie 复用、API 直采 | `lib/network/comix_client.dart` |
| **P0** | v2 链路实测 | 需构建后实测：API 截获是否生效（看日志 "captured chapters API"）、`__=` token 复用是否可行（若 403 会自动降级 DOM 兜底）、阅读全流程 | — |
| P1 | versioned 阅读器分组行为 | `preferredVersionKey` 与阅读器 `filteredChapters` 交互，选组后历史记录 key 是否一致 | `lib/pages/reader/` + `chapters.dart` |
| P2 | 封面图为空 | `detail.poster.large`（initial-data 里可能只有 medium）| `assets/comix_to.js` loadInfo |
| P3 | 真实搜索 | API 已知：`/api/v1/manga` 列表端点 + search 参数（bundle 里 `["manga","search",a]` 查询），同样走 headless 截获 | `assets/comix_to.js` search |
| P3 | Next page / Last page 导航 | API 直采路径已不需要（分页循环到 last_page）；仅 DOM 兜底路径仍需处理 | `comix_client.dart` DOM 路径 |
| 环境坑 | 本会话无法跑 flutter 命令 | 工具会话内嵌套进程创建失败（CreateFile failed 231 / where.exe 管道占用）。用 `tools/run_venera_check.bat` 在外部终端跑 analyze+test | — |

---

## 技术栈速查

| 层 | 技术 |
|----|------|
| UI 框架 | Flutter Windows 3.29+ |
| Webview | `desktop_webview_window` 插件（WebView2） |
| HTTP | dio + 简化版 RHttpAdapter（走 dart:io） |
| JS bridge | `js_engine.dart` + `init.js` 的 `sendMessage` → `_messageReceiver` |
| JSON 解析 | `initial-data` 在 `<script type="application/json" id="initial-data">` 里 |
| comix.to SPA | React，章节 API 带 `__=` token + Cloudflare cf_clearance |
| 运行时日志 | `io.github.kyosee.venera/logs.txt` |

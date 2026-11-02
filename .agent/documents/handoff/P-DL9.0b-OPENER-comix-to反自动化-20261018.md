# 新对话开场白 — Mangrove + comix.to 反自动化

> 本文件用于在新对话开头快速恢复上下文。**直接复制粘贴给 AI**，让它立即理解当前状态。

---

## 任务背景

我在用 Flutter Windows 漫画阅读器 **Mangrove v2.8.5** 读 **comix.to** 网站的漫画（Overgeared、I will save my father 等）。comix.to 有极强的反自动化，本会话要解决**让 Mangrove 能正常浏览 comix.to** 这个核心问题。

---

## 当前状态（一句话版）

**CDP 被封 → WebView2 也被封 → 所有 SPA API（/api/v1/manga/*）100% 返回 503 third_party_app。只能靠 SSR DOM scraping。在线阅读基本死了。**

---

## 关键文件路径速查

| 文件 | 路径 |
|------|------|
| 项目根 | `D:\AI Coding Project Management\Mangrove\Mangrove\` |
| comix.to 网络层 | `lib\network\comix_client.dart` |
| 设置页（发现分类） | `lib\pages\settings\explore_settings.dart` |
| 设置组件 | `lib\pages\settings\setting_components.dart` |
| 搜索结果页 | `lib\pages\search_result_page.dart` |
| 应用数据 | `C:\Users\Administrator\AppData\Roaming\io.github.maelshiyan02\mangrove\` |
| build 输出 | `build\windows\x64\runner\Debug\mangrove.exe` |
| flutter 路径 | `C:\Flutter\bin\flutter.bat` |
| Chrome 路径 | `C:\Program Files\Google\Chrome\Application\chrome.exe` |
| project_memory | `c:\Users\Administrator\.trae-cn\memory\projects\-d-AI-Coding-Project-Management--p2-c32a245d39cb8ddc5ece\project_memory.md` |

---

## comix.to 反自动化三层结构

| 层 | 拦截什么 | 当前状态 | 说明 |
|---|---------|---------|------|
| **L1 navigator.webdriver** | CDP/自动化特征 | ✅ 可绕过 | `--disable-blink-features=AutomationControlled` + JS 覆盖 |
| **L2 Page.navigate 非首页** | 硬刷非 / 路径 | ✅ 可绕过 | 用 `history.pushState` 客户端路由替代 |
| **L3 /api/v1/manga/* API** | SPA 所有 API 请求 | ❌ **死** | 返回 `503 third_party_app` |

### 为什么 L3 绕不过？

**WebView2 runtime 在网络层自动给 fetch/XHR 子请求追加 `sec-ch-ua: "Edg";v=xxx`**，这个追加发生在 JS 层之下，导致：
- `--disable-features=SecCHUserAgent` flag 只管导航请求，不管子请求
- JS fetch hook 删不掉浏览器自动追加的 headers
- flutter_inappwebview 没有暴露 WebResourceRequested 拦截器
- cf_clearance cookie 可能绑定 JA3/JA4 指纹 → WebView2 和 Chrome 指纹不同 → cookie 被拒

---

## WebView2 在 comix.to 里**能**做什么

| 功能 | 状态 | 说明 |
|------|------|------|
| SSR 首页 browse | ✅ | 130 张卡片 `a.card` DOM，不需要 API |
| 封面图片 | ✅ | 走静态 CDN，不过 API |
| 标题页 metadata | ✅ | `#initial-data` JSON 预渲染 |
| 标题页章节列表 | ⚠️ 部分 | DOM `.mchap-row` 只有第一页 ~20 行 |
| 章节翻页 | ❌ | 翻页按钮触发 API → 503 → 无新章节 |
| 章节图片 URL | ❌ | `/api/v1/manga/{hid}/chapters/{cid}/pages` → 503 |
| browseManga API | ❌ | `/api/v1/manga?search=...` → 503 |

---

## 已写代码（可以直接用）

### comix_client.dart 当前结构

- `ComixCDPWorker` — CDP 单例（已封，但代码保留做 fallback）
- `ComixWebviewWorker` — HeadlessInAppWebView 单例（**当前主路径**）
- `_worker` 属性 → 优先 CDP，fallback WebView2
- `browseManga(query)` — 搜索方法（有 CF 自动恢复）
- `fetchChapters(title)` — 章节采集（API 路径 + SSR fallback）
- `fetchImageUrls(chapter)` — 章节图片 URL 采集（API 路径，死）
- `_captureHookJs` — fetch/XHR 响应拦截 JS（用于截获 SPA API 响应）
- `_navigate()` — pushState 导航（comix.to 站内），Page.navigate（外部）
- `_parseChaptersFromSSR()` — DOM 章节解析（有 `seenUrls Set` 去重）
- `verifyCloudflare()` — 弹出可见 AppWebview 让用户过 CF

### 已加的诊断代码（可删）

`_fetchChaptersViaApi` 里 navigate 完会等 5 秒然后检查 `window.__comixApiLog`，输出到 `comix_diagnostic.txt`（AppData 目录）。

### 已加的高级筛选开关

- `appdata.dart` defaults 加了 `'enableAdvancedSearchFilters': false`
- `explore_settings.dart` 设置页加了开关（发现分类）
- `search_result_page.dart` 在 loadPage/loadNext 调用时动态读 settings
- **已知 bug**：appdata.json 里没这个 key（老版本）→ defaults 应该生效但 UI 可能因为 _SwitchSetting 断言不显示

---

## 三个选项（待用户决定）

### 选项 A：SSR DOM 彻底化（短期方案）

**放弃所有 API 路径，全用 DOM 抓取**：

- Browse/Search → 读首页 SSR `a.card` 元素（已有 ✅）
- Title page 章节 → 读 DOM `.mchap-row`（只有 ~20 行，**翻页是瓶颈**）
- 章节翻页 → 方案 A1：点 SPA 分页按钮等渲染（依赖 SPA 但 SPA 渲染前要 API，API 死了 = 点了没反应）；方案 A2：直接请求 `/browse/overgeared?page=2` 这种 URL 用 SSR HTML 解析；方案 A3：可能有其他分页方式
- 章节图片 → 方案 A1：直接请求章节页 SSR HTML，读 DOM 里的图片 src（可能有防盗链）；方案 A2：可能有其他图片来源
- **关键问题**：`/api/v1/manga/{hid}/chapters` 的 token 是 SPA 生成的，SSRF 直请求也通不过；但 SSR HTML 里有没有嵌入章节图片 URL？需要验证

### 选项 B：下载器 + 本地库（终极方案）

**完全放弃在线阅读，做独立下载器**：
- 写一个 Python/Go 程序（可以用 DrissionPage 这种反反爬库）
- 下载漫画到本地（epub/cbz/pdf/文件夹）
- Mangrove 从本地库阅读（已有完整的本地阅读功能）
- 适合翻译工程的素材来源需求

### 选项 C：Chrome Extension 桥接

**让 Mangrove 借用用户 Chrome 的会话**：
- 做一个 Manifest V3 扩展
- 用户装在自己的 Chrome 里（正常能访问 comix.to）
- 扩展拦截 SPA 的 API 响应，通过 Native Messaging 传给 Mangrove
- 最稳但需要写扩展 + Native Messaging host
- 用户体验：还得开 Chrome

---

## 历史坑点（必读，别再踩）

1. **Dart HttpClient/WebSocket 都要 `findProxy = (_) => 'DIRECT'`** — 否则 localhost 请求会被 Clash 代理
2. **CDP 启动命令不能和正常 Chrome 共享 profile** — 会文件锁冲突
3. **PowerShell 5 不支持 `&&`/`||`，没有续行符** — 脚本要用分号或单独执行，多行命令别粘贴
4. **`Start-Process mangrove.exe` 不稳定** — 进程可能瞬崩，用 `flutter run -d windows --debug` 或前台 `& exe` 最稳
5. **HeadlessInAppWebView 和 InAppWebview 不能同进程并存** — 可见 CF 验证用完后必须 dispose，再启动 headless
6. **`_SwitchSetting` 对 null value 不安全** — assert + fallback，但 debug 模式 assert 可能导致整个设置页 category 不渲染
7. **flutter_inappwebview 没有 WebResourceRequested** — 改不了 fetch/XHR 子请求的 headers
8. **cf_clearance 可能绑定 JA3/JA4 指纹** — Chrome 和 WebView2 的 TLS 指纹不同，cookie 不能通用
9. **章节重复问题** — 已在 `_parseChaptersFromSSR` 加了 `seenUrls Set` 去重 + token 保留 + 重复页自动停
10. **VSCode 报 runner_windows 找不到** — 清理 `%APPDATA%\Code\User\workspaceStorage\` 下所有 state.vscdb

---

## 快速构建 & 部署

```powershell
# 编译
& "C:\Flutter\bin\flutter.bat" build windows --debug

# 复制插件 DLL（build 后需要手动复制到 runner 目录）
$pluginsDir = "build\windows\x64\plugins"
$runnerDir = "build\windows\x64\runner\Debug"
Get-ChildItem $pluginsDir -Recurse -Filter "*.dll" | ForEach-Object {
    Copy-Item $_.FullName -Destination (Join-Path $runnerDir $_.Name) -Force
}

# 启动（最稳）
flutter run -d windows --debug

# 或直接运行
& "build\windows\x64\runner\Debug\mangrove.exe"
```

---

## 给 AI 的初始指令

> 先读 project_memory.md 里的 P-DL9b、P-DL9c 段了解完整反自动化诊断历史。然后：
>
> 1. 如果用户说"继续"或"选项 A" → 开始实现 SSR DOM 彻底化方案，首先验证：comix.to 标题页 SSR HTML 里 `.mchap-row` 有多少行、翻页 URL 格式是什么、章节页 SSR HTML 里有没有图片 URL
> 2. 如果用户说"选项 B" → 开始规划下载器的技术栈和架构
> 3. 如果用户说"选项 C" → 开始设计 Chrome Extension + Native Messaging 桥接方案
> 4. 如果用户有其他问题 → 按问题处理，随时参考 memory 里的坑点

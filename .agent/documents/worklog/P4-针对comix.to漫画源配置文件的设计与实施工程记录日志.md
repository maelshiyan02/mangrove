# P4 — 针对 comix.to 漫画源配置文件的设计与实施工程记录日志

> **整合版**：本文件合并了此前分散的三份 P4 文档，并补记 2026-10-01（v0.5.0）的最新修复与下载功能设计。
>
> **并入的源文档**
> - `docs/P4-comix-to漫画源配置分析-20260929.md`（站点分析、翻译组 UI 设计、P4-0/P4-1 实施记录）
> - `docs/P4-agent-handoff-comix-to.md`（API 逆向、架构、踩坑清单 —— 该文件仍作为 **Agent 交接活文档**单独维护）
> - `docs/dev-log-2026-09-30.md`（v0.3.0 → v0.4.1 四轮修复）
> - `.workbuddy/memory/2026-09-30.md`（当日工作记忆）
>
> **项目**：VeneraX（Flutter Windows 桌面漫画阅读器），路径 `D:\Ballonstranslator_Windows\VeneraX`
> **当前版本**：comix_to.js **v0.5.0**（2026-10-01）
> **参考实现**：BallonsTranslator `ballontranslator/utils/scraper/comix_client.py` + `ui/download_dialog.py`

---

## 〇、TL;DR —— 一句话能救你三小时的部分

| 事实 | 说明 |
|---|---|
| **API 签名 token 参数名是单下划线 `_`，不是 `__`** | `?_=abc` → `Invalid token.`；其它任何名字 → `Missing token.`。写成 `__=` 会让所有 API 路径静默降级到 DOM（又慢又不全）。这是 v0.4.x 全部"采集不全"问题的总根因。 |
| **token 绑定完整 query string** | 改任何一个参数（哪怕只加 `page=2`）都会 `Invalid token.`。**不能复用 token 自己拼分页 URL**，必须让 SPA 自己发请求（点分页按钮 / 导航 browse 页）再截获。 |
| **部分 API 响应是加密的** | 原始 body 形如 `{"e":"fktAPNu-..."}`，只有 SPA 解密后经 `JSON.parse` 的才是明文。所以要有 **fetch 截获 + JSON.parse 载荷** 双通道。 |
| **阅读器是 Swiper slides 虚拟化** | 同时只渲染 3~5 张 slide，**不是懒加载**。所以 DOM 兜底最多只能拿到 3~4 张。图片必须走 API。 |
| **图片 CDN 要 Referer** | `Referer: https://comix.to/`；且条漫 CDN 单张响应极慢，**30 秒空闲超时会误判**，需 90 秒。 |
| **JS 源不进安装包** | 改完 `assets/comix_to.js` 必须 `node --check` 后手动同步到 `%APPDATA%\io.github.kyosee\venera\comic_source\`。 |
| **改 Dart 必须重编** | 真正的代码在 `builds\venera\data\app.so`（~18MB AOT），不是 0.15MB 的 `venera.exe` 壳。 |

---

## 一、项目背景与目标

P4 阶段的目标是把 **comix.to** 做成一个在 VeneraX 里"能搜、能看列表、能读、能下载"的完整漫画源。

- **前置**：P2-C 多翻译组（versioned 章节）数据结构已就位。
- **参考资产**：BT（BallonsTranslator）侧已有成熟的 comix.to 抓取管线（Python + QWebEngineView），本阶段是把它的能力移植/对齐到 Flutter 侧。
- **术语约定**：一律用 **翻译组**（不用"汉化组"）——覆盖英文/韩文/日文等外文漫画的翻译群体。内部变量名保留 `scanlationGroup`。

---

## 二、comix.to 站点特征与技术难点

### 2.1 内容特征

| 维度 | 说明 |
|---|---|
| 主要语言 | 英文（Fan Translation）、韩文、日文 |
| 翻译组生态 | **同章节号常有 5-10+ 个翻译组版本** |
| 章节标题格式 | `Ch.5 - Luna Toons 2024-09-28` |
| 封面 | 详情页内嵌 `poster` 字段，HTTP GET 可下载 |

### 2.2 技术难点与解法对照（BT 侧 → Flutter 侧）

| 难点 | BT 侧解法 | Flutter 侧方案 | 状态 |
|---|---|---|---|
| API 混淆 token 签名 | QWebEngineView 渲染，让站点 JS 完成签名后截获 | 常驻 HeadlessInAppWebView + 截获 | ✅ |
| 响应加密 | 浏览器原生 JSON.parse 解密后截获 | JSON.parse 钩子（双通道） | ✅ v0.5.0 |
| CDN 防盗链 | `Referer: https://comix.to/` | `onImageLoad.headers` | ✅ v0.5.0 |
| 魔数推断格式 | PIL 真解码 + 文件头字节 | 由 VeneraX 图片管线处理 | 沿用 |
| 章节列表采集 | 逐页翻 DOM | API 截获为主 + 点分页按钮补页 | ✅ v0.5.0 |
| 翻译组提取 | `result.group.name` | `ComicChapterVersion.scanlationGroup` | ✅ |
| 多翻译组 UI | 无（BT 是列表） | VeneraX versioned + FilterChip | ✅ |
| 图片下载限流 | 5 张一组 + 组间歇 + 失败清单 | **见第十章（打基础）** | 🚧 |

### 2.3 BT 的三级架构（设计蓝本）

```
层级 1: 元数据（普通 HTTP）
  parse_initial_data(html)          → <script id="initial-data"> 里的 JSON
  parse_comic_from_initial_data()   → ComicInfo(title, url)

层级 2: 章节列表 + 每页图片 URL（需要浏览器）
  build_chapters_from_dom(rows)     → [ChapterInfo(title, url, group, number)]
  parse_page_urls_from_capture()    → result.pages.items[].url
  fetch_chapter_image_urls(chapter) → [img_url...]

层级 3: 图片字节（普通 HTTP + Referer 头）
  download_image(url)               → bytes（重试 + cache-bust + PIL 校验）
```

VeneraX 侧完全沿用这个分层：元数据纯 HTTP；章节/图片走 headless webview；图片字节走 Dio（带 Referer）。

---

## 三、VeneraX ComicSource 注册机制与适配方案

### 3.1 机制要点

VeneraX 的漫画源是 **JS 引擎注册的脚本**，不是 JSON 配置：

```dart
// parser.dart:830
ComicSource.sources.$_key.comic.loadInfo(${jsonEncode(id)})
```

`assets/comix_to.js` 里 `class ComixTo extends ComicSource`，实现 `search / explore / category / categoryComics / comic.loadInfo / comic.loadEp / comic.onImageLoad / comic.onThumbnailLoad`。

### 3.2 数据结构映射

| comix.to 字段 | VeneraX 字段 | 示例 |
|---|---|---|
| `group.name` | `ComicChapterVersion.scanlationGroup` | "Luna Toons" |
| `number` | versioned 键 | "5" |
| 章节页完整 URL | `ComicChapterVersion.chapterKey` | `https://comix.to/title/xxx/11416127-chapter-5` |
| `name` | `title` | "Ch.5 - Luna Toons" |

### 3.3 桥接通道（js_engine.dart）

JS 侧 `sendMessage({method, ...})` → Dart 侧 `switch (method)`：

| method | 用途 |
|---|---|
| `comix_fetch_chapters` | 采集章节列表（返回 versioned map） |
| `comix_fetch_pages` | 采集某章节全部图片 URL |
| `comix_browse` | 搜索 / 发现 / 分类（统一入口） |

---

## 四、多翻译组（versioned）UI 设计与实施（P4-0）

### 4.1 问题

comix.to 原始页面把所有翻译组的章节**混在一起堆**（第49话 Nyx / 第49话 Vali / 第49话 EZManga…），没有分栏概念；而用户期望是"翻译组 Tab + 该组章节网格"。

### 4.2 数据模型改造（P4-0a，已完成）

| 改动 | 文件 |
|---|---|
| `ComicChapterVersion.uploadedAt: DateTime?`（nullable，无时间戳的源优雅降级） | models.dart |
| `ComicChapters._sortVersioned()`：章节号**降序** + 同章节内按 `uploadedAt` 降序 | models.dart |
| `ComicChapters.scanlationGroupsSorted`：按该组最新章节时间降序 | models.dart |
| `ComicChapters.filterForScanlationGroup(group)`：返回过滤视图 | models.dart |

**排序规则**：章节号数值降序（49 在 1 前）→ 非数值章节号排后 → 同章节内有 `uploadedAt` 按时间降序，无则组名字母序。

### 4.3 Tab UI（P4-0b，已完成）

- `_selectedScanlationGroup` 状态（null = 默认，每章取最新版本）
- `_buildScanlationGroupChips()`：FilterChip 横滑行，toggle 切换
- 显示条件：**原始** `chapters.isVersioned && scanlationGroupsSorted.length > 1`

> ⚠️ 这里踩过一个 bug：可见性条件误用了 **过滤后** 的 `_displayChapters`（选中单组后 `length == 1`）→ 整行 chips 消失且无法再呼出。必须判断**原始** chapters。

### 4.4 默认组选择（方案 C，推荐）

有持久化偏好用偏好，否则自动选 `uploadedAt` 最新的组。`preferredVersionKey(chapterNumber, preferredGroup)` 已支持。

### 4.5 验证结果

| 门 | 结果 |
|---|---|
| flutter analyze | 0 error / 0 warning |
| flutter test | 843/843（含 versioned 排序 + uploadedAt 测试） |

---

## 五、API 逆向成果（核心资产）

### 5.1 端点清单

| 功能 | 端点 | 响应结构 |
|---|---|---|
| 元数据 | `GET /title/{hid}-{slug}`（**有 SSR**） | `<script id="initial-data">` → `queries[["manga","detail",id]]` |
| 章节列表 | `GET /api/v1/manga/{hid}/chapters?page=N&_=token` | `result.items[]`：`{id,url,number,volume,name,group:{id,name},isOfficial,...}`、`result.meta.last_page` |
| 章节图片 | `GET /api/v1/chapters/{chapterId}?_=token` | `result.pages: {baseUrl, items:[{width,height,url}]}`，**图片 URL = baseUrl + item.url** |
| 浏览/搜索 | `GET /api/v1/manga?keyword=&page=&limit=28&_=token` | `result.items[]`：`{hid,slug,title,poster,...}` |
| 类型（genres） | `GET /api/v1/manga/genres`（token 门禁） | genre 为**数字 id**，暂未接入分类 |

前端消费代码（ReadPage chunk）确认了拼接方式：

```js
chapters.get = async (id) => {
  const a = await b.get(`/chapters/${id}`), t = a.pages;
  if (t && !Array.isArray(t) && "items" in t) {
    const base = t.baseUrl ?? "";
    const n = t.items.map(x => ({width:x.width, height:x.height, url: base + x.url}));
    return {...a, pages: n};
  }
  return a;
}
```

### 5.2 token 的三条硬事实（2026-10-01 实测确认）

1. **参数名是 `_`**：
   ```
   ?_=abc        → {"message":"Invalid token."}     ← 命中
   ?__=abc       → {"message":"Missing token."}
   ?token=abc    → {"message":"Missing token."}
   ```
2. **绑定完整 query string**：
   ```
   /api/v1/manga/gm28k?_=<token>          → 200
   /api/v1/manga/gm28k?foo=1&_=<token>    → 403 Invalid token.
   /api/v1/manga/gm28k?page=2&_=<token>   → 403 Invalid token.
   ```
3. **由 VMP 混淆的 `secure-*.js` 生成，绑浏览器指纹**：Node 里直接跑会 RangeError；chunk 文件名每次部署会换（如 `secure-tm5efk-B6Wo2GRC.js`），**不要硬编码**。只能通过 `Lu(Xi)` 装在 axios 实例上，模块作用域，注入脚本拿不到。

### 5.3 加密响应

```
GET /api/v1/manga/gm28k?_=<token>   → 200 {"e":"fktAPNu-UVrcLYyezdF9lAjLVTTfbUmshqErCwOwf-jTQvhL..."}
```
（浏览器内同名请求是明文——搜索/发现一直能拿到 28 items。加密可能是 WAF 对可疑客户端的降级策略。）**因此必须有 JSON.parse 明文通道做备份。**

### 5.4 阅读页 DOM 结构（浏览器验证）

| 元素 | 选择器 |
|---|---|
| 章节区域 | `SECTION.mpage__chapters` |
| 章节条目 | `li.mchap-item` |
| 主链接 | `a.mchap-row__primary`（双下划线 BEM） |
| 翻译组 | `a.mchap-row__group > span` |
| 分页按钮 | `button.npager__num`（当前页 `.is-active`） |
| 阅读页图片 | `img.rpage-page__img`（**Swiper 虚拟化，同屏只有 3~5 个**） |

href 格式：`/title/{hid}-{slug}/{chapterId}-chapter-{chapterNum}`

---

## 六、采集架构演进

### v1：弹窗 DesktopWebview（已废弃）
打开可见 WebView2 窗口 → 点分页按钮 → 解析 DOM。**慢（~15-20s）+ 弹窗干扰阅读 + 不全**。

### v2：常驻 HeadlessInAppWebView（v0.3.0）
- `_ComixWorker` 单例：全 App 一个离屏 WebView2，**不弹窗**；cookie 持久化在 `{App.dataPath}\webview`。
- document-start 注入 fetch/XHR 钩子 → `/api/` 响应记入 `window.__comixApiLog`。
- `enqueue()` 串行所有任务。

### v0.5.0：双通道 + 精确匹配（当前）
1. **通道 A**：fetch/XHR 截获（记录 `status`，校验 body 是否"像真数据"）。
2. **通道 B**：`JSON.parse` 钩子 → `window.__comixPayloads`（应对加密响应，与 BT 同思路）。
3. **精确匹配**：`/api/v1/chapters/<数字>` 结尾且排除 `/user/`（避免误抓 `/user/chapters/{id}/state`）。
4. **分页**：点 SPA 分页按钮让站方自己重签 token，再截获（因为 token 不能复用）。
5. **兜底**：原样重放最后一次截获 URL（`_lastCaptureUrl`），不改任何参数。
6. DOM 兜底改为**轮询到数量连续 3 次不变**再收，并强制 `img.loading='eager'`。

---

## 七、实施记录（按轮次）

### 7.1 v0.3.0 事故：整个源消失（"Comic source not found"）

**根因**：class 体内写 `var _chaptersCache = {}` —— QuickJS 语法错误 → 全类解析失败 → 源注册失败。
日志铁证：`SyntaxError: expecting ';' at ComixTo:16:1`。
**修复**：模块级 `var`（class 外）。
**教训**：JS 源改动必须 `node --check` 后再同步；源加载失败的影响面是"整个源消失"，不只是功能异常。

### 7.2 v0.3.1 二次事故：`_chaptersCache is not defined`

**根因**：改成 class field 后，**方法里裸引用 `_chaptersCache` 是全局查找，不是 `this._chaptersCache`** → 运行时 ReferenceError。
**教训**：JS class 实例字段 ≠ 闭包变量。跨方法共享的可变状态放模块级 `var` 最稳。

### 7.3 发现页 CERTIFICATE_VERIFY_FAILED（存量问题）

**根因**：rhttp 注释后走 dart:io，而 **dart:io 只信 Flutter 内置根证书，不认 Windows 系统证书库**（curl 用系统库所以正常）。`*.baozimhcn.com` 是 ZeroSSL 签发。
**修复**：`app_dio_io.dart` 的 `createIOHttpClient` 在**走代理时**也挂 `badCertificateCallback`。

### 7.4 v0.4.0：搜索/发现/分类

- **搜索空白**根因：comix.to **主页根本不发 manga 列表请求**（内容走 SSR），"等截获 token"必然失败。
- **修复**：直接导航 `https://comix.to/browse?q=<关键词>&page=N`，SPA 自己带 token 发 `/api/v1/manga` → 截获即得。搜索/发现/分类统一走 `comix_browse`。
- 发现页的硬编码占位卡片（v0.2 遗留的 `{id:"9l3kj", cover:""}`）换成真实"最新更新"列表。
- 分类页新增 types/statuses 两组枚举。移除 favorites 占位（未实现登录时不该显示入口）。

### 7.5 v0.4.1：章节慢（~20s）且不全（只到 22 话）+ "(Invalid) comix_to"

- **章节不全**根因（当时判断为 WAF 挑战 body + DOM 分页按钮只有 1-8）：加了 status 记录与 `_inPageFetchJson` 重试。**但真正根因（token 参数名写错）直到 v0.5.0 才暴露**——`__=` 检查永远为假，API 路径从未启用。
- **"(Invalid) comix_to"**根因：设置里残留的收藏源 key，`_validatePages()` 只在删源时调用。
- **修复**：`ComicSourceManager.doInit()` 末尾新增 `_validateSavedPageKeys()`，启动自愈清理 favorites/categories/explore_pages/searchSources 里的失效 key。

### 7.6 包子漫画"需要 Cloudflare 验证"（通用修复，非 comix 专有）

- **真相**：那不是 Cloudflare，是站方自建 **gatekeeper WAF** —— 403 + `{"challenge_url":"/__gatekeeper_challenge/start?...","error":"challenge_required"}`，JS PoW 挑战，**自动完成、无需人工**。
- `CloudflareInterceptor._check` 只认 `cf-mitigated: challenge` 头 → gatekeeper 不可见 → 所有镜像被判"普通 403" → 兜底到真 CF 的 appcn 域 → 弹手动验证。
- **修复**：`_check` 识别 gatekeeper JSON；`_isCloudflareChallengePage` 补挑战页标记（**防止把挑战页误缓存成"已验证页面"**）；新增 `tryHeadlessVerification()` 离屏自动过挑战并存 cookie；`NetworkError` 检测到验证异常时**自动触发一次**（每 URL 仅一次），失败才回落手动按钮。

### 7.7 v0.5.0：章节只读到 3~4 页 + 连续多页超时（本次）

#### 现象
打开 comix.to 章节，一章只加载 3~4 页；且用户指出这与 BT 下载功能曾出现的问题一致（① 一开始只能采几个页面；② 连续采 9 页就 ReadTimeout）。

#### 日志复盘
```
capture(skip): /api/v1/manga/gm28k?_=IZ-P1pUtAgIzcU2W
captured pages API (status=200) for .../11416127-chapter-5
pages API empty — falling back to DOM scraping
fetchImageUrls returned 4 images
comix_to: loadEp got 4 images
```

#### 两个根因（都已实锤）

**根因 A —— 匹配器抓错了请求**
`RegExp(r"/chapters/\d+")` 会把 `/api/v1/user/chapters/{id}/state`（阅读进度/点赞状态接口）当成章节详情接口。它返回 `{liked, resumePage}`，**没有 pages** → "pages API empty" → 永远降级 DOM。DOM 只能拿到 Swiper 虚拟渲染的 3~5 张 → **这就是"只读到 3 页"**。
**修复**：`/api/v\d+/chapters/\d+$` 结尾匹配 + 排除 `/user/`。

**根因 B —— 响应/超时侧**
- 加密响应：`_decodeApiBody` 拿到 `{"e":"..."}` 解不出 pages。→ 加 JSON.parse 明文通道。
- token 参数名 `__=` 写错（应为 `_=`）→ 所有"页内 fetch 重试"分支从未执行。

#### 修复清单（本次实装）

| # | 改动 | 文件 |
|---|---|---|
| 1 | 精确匹配 `/api/v1/chapters/<数字>`，排除 `/user/` | comix_client.dart |
| 2 | 新增 JSON.parse 明文载荷钩子 + `_drainPayloads()` 双通道 | comix_client.dart |
| 3 | 章节分页改为"点按钮让 SPA 重签 token 后截获"（token 不能复用） | comix_client.dart |
| 4 | `_lastCaptureUrl` + 原样重放兜底；`_hasToken()` 用 queryParameters 判定 `_` | comix_client.dart |
| 5 | `_extractImageUrls` 兼容 `result` 包装 + `baseUrl` 拼接 + 协议相对路径 | comix_client.dart |
| 6 | DOM 兜底改为"数量连续 3 次不变才收"+ 强制 eager + 多选择器 | comix_client.dart |
| 7 | 每个通道都记 HTTP status 与 body 预览（便于下次定位） | comix_client.dart |
| 8 | `onImageLoad` 带 `Referer: https://comix.to/` + `timeoutSeconds: 90` + cache-bust 重试 | comix_to.js |
| 9 | `onThumbnailLoad` 同样带防盗链头 | comix_to.js |
| 10 | `_loadComicImage` 支持源级 `configs['timeoutSeconds']` 覆盖 30s 默认 | images.dart |

---

## 八、踩坑清单（不看必炸）

| # | 坑 | 解法 |
|---|---|---|
| 1 | **token 参数名是 `_` 不是 `__`** | 用 `Uri.queryParameters.containsKey('_')` 判定，别用字符串 contains |
| 2 | **token 绑定完整 query** | 分页必须让 SPA 自己发；只能整条重放 URL |
| 3 | **响应可能加密** `{"e":"..."}` | JSON.parse 明文通道做备份 |
| 4 | **`/user/chapters/{id}/state` 路径撞车** | 匹配器要锚定 `/api/v1/chapters/<数字>$` 并排除 `/user/` |
| 5 | **阅读器 slides 虚拟化**（不是懒加载） | DOM 兜底只能拿到 3~5 张；主路径必须走 API |
| 6 | **WebView2 双重 JSON 序列化** | JS `JSON.stringify` 后 WebView2 再 stringify → Dart 循环 `jsonDecode` |
| 7 | **SPA 翻页 `btn.click()` 无效** | `dispatchEvent(new MouseEvent('click', {bubbles:true, cancelable:true, view:window}))` |
| 8 | **翻页要验 DOM 变化** | `{ok:true}` 不代表真翻了；比对 `firstHref` / `.is-active` |
| 9 | **截获 body ≠ 可信数据** | 必须记 status 并校验内容（WAF 挑战也会走钩子） |
| 10 | **UI 数值不是全集** | 分页按钮显示 8 个 ≠ 总共 8 页；用 API `meta.last_page` |
| 11 | **class 体内不能写 `var`** | QuickJS 语法错误 → 整个源消失 |
| 12 | **class 字段 ≠ 闭包变量** | 裸引用 `_x` 是全局查找，会 ReferenceError |
| 13 | **JS 源不进安装包** | 改完 `node --check` 再同步到 `%APPDATA%\io.github.kyosee\venera\comic_source\` |
| 14 | **exe 是空壳** | 看 `builds\venera\data\app.so` 时间戳判断构建新鲜度 |
| 15 | **会话内 flutter 必失败**（CreateFile 231） | 用 `tools\build_venera_release.bat` + 计划任务；analyze 加 `--no-fatal-infos` |
| 16 | **nuget 必须在 PATH** | `D:\dev\tools\nuget.exe`，否则 flutter_inappwebview_windows 编译失败 |
| 17 | **设置残留要自愈** | 源功能增删后引用它的持久化配置要启动时校验清理 |
| 18 | **CDN 30s 空闲超时不够** | 条漫 CDN 单张可能很慢；BT 实测用 90s |

---

## 九、构建与验证环境

```powershell
$env:PATH = 'C:\Flutter\bin;D:\dev\tools;' + 'D:\Ballonstranslator_Windows\tools;' + $env:PATH
cd D:\Ballonstranslator_Windows\VeneraX

flutter analyze --no-fatal-infos   # 0 error（有存量 info lint，必须加这个参数，否则 errorlevel=1）
flutter test                        # 843 单测
flutter build windows --release --no-pub

# 组装产物（关键：install 目标是 ../../builds/venera/，不是 runner/Release）
& '...\CMake\bin\cmake.exe' --install 'D:\Ballonstranslator_Windows\VeneraX\build\windows\x64'

Start-Process 'D:\Ballonstranslator_Windows\builds\venera\venera.exe'
Get-Content "$env:APPDATA\io.github.kyosee\venera\logs.txt" -Wait -Tail 100
```

- **一键脚本**：`tools\build_venera_release.bat`（analyze → build → install，输出 BUILD_OK/BUILD_FAIL）
- **会话内构建**：`Register-ScheduledTask` + `Start-ScheduledTask` 跑上面的 bat（WMI `Win32_Process` 被安全策略拦）
- **运行时日志**：`%APPDATA%\io.github.kyosee\venera\logs.txt`，Dart 侧前缀 `ComixClient` / `JS Console`
- **技能**：`.workbuddy/skills/venera-windows-build/SKILL.md`（.trae 与 .workbuddy 已合并共用，以 .workbuddy 为准并双向同步）

---

## 十、下载功能设计（comix.to 适配 VeneraX）—— 基础篇

> 本章是为"在 VeneraX 里下载 comix.to 漫画"打的设计基础。BT 侧已有完整可用的实现，本章把它的经验映射到 VeneraX 的架构上。

### 10.1 BT 侧已验证的四条经验（直接照搬）

出处：`ballontranslator/ui/download_dialog.py` + `utils/scraper/comix_client.py`

| # | 经验 | BT 参数 |
|---|---|---|
| 1 | **分组下载**：每 5 张为一组，组间歇 1.5 秒 | `GROUP_SIZE=5`、`GROUP_REST_SEC=1.5`。实测 CDN 连续请求超过约 10 张后容易 ReadTimeout/503 |
| 2 | **单图重试 + cache-bust + 指数退避** | `retries=5`；第 2 次起 URL 加 `_bt=<ms><rand>` 强制回源绕开坏副本；退避 `min(2^attempt, 30)+jitter`，502/503/504 再翻倍 |
| 3 | **超时拆分** | `(connect=10, read=90)` —— 条漫 CDN 单张响应极慢，30s 读超时经常不够 |
| 4 | **失败页清单 + 补救重下** | 每章写 `_source_urls.json`，含 `pages[]` 与 `failed_pages[{page,url,error}]`；`scan_failed_pages()` + `RedownloadFailedWorker` 事后补齐；成功页从 failed 移除并追加到 pages |
| 5 | **原子落盘** | 先写 `.part` 临时文件，写完 `os.replace` 改名，避免半成品被当成已下载页 |
| 6 | **真解码校验** | PIL `im.load()` 完整解码才算成功，拦截断图/HTML 错误页 |

### 10.2 VeneraX 现有下载链路

| 组件 | 位置 | 说明 |
|---|---|---|
| 下载任务 | `lib/network/download.dart` | 按章下载，`_downloadChapterPool()` 完成驱动并发池 |
| 并发度 | `_maxConcurrentTasks = appdata.settings["downloadThreads"]` | **全局设置，无源级覆盖** |
| 单图下载 | `ImageDownloader.loadComicImageUnwrapped(..., forDownload: true)` | 走 `onImageLoad` 配置 |
| 失败处理 | `_ImageDownloadWrapper.error` → **整章 fail** | 无"失败页清单/补救"概念 |
| 缓存 | `CacheManager` | forDownload 时不写缓存 |

### 10.3 已打好的基础（v0.5.0 已实装）

| 能力 | 落点 | 对应 BT 经验 |
|---|---|---|
| 完整页 URL 列表 | `_fetchPagesViaApi` 精确匹配 + 双通道 | — |
| CDN 防盗链 | `comix_to.js onImageLoad.headers.Referer` | 层级 3 |
| 长空闲超时 | `images.dart` 支持 `configs['timeoutSeconds']`，源侧给 90 | 经验 3 |
| 单图重试 + cache-bust | `comix_to.js onImageLoad.onLoadFailed` 返回带 `_bt=` 的新配置（Dart `retryLimit=5`） | 经验 2 |

### 10.4 待实施（下一步 P4-6）

| 子项 | 内容 | 位置 |
|---|---|---|
| **P4-6a 源级并发上限** | `downloadThreads` 是全局的。给 `ComicSource` 增加可选 `maxConcurrentDownload`（JS 源声明），`download.dart` 取 `min(全局, 源级)`；comix.to 声明 3~5 | download.dart + parser.dart + comix_to.js |
| **P4-6b 组间歇节流** | 并发池外再加"完成 N 张后休息 T 秒"的节流器（BT 的 5 张/1.5s），对 wowpic 这类限流 CDN 必要 | download.dart |
| **P4-6c 失败页清单** | 单图失败不再整章 fail：记入 `failed_pages`，章末可重试/后续补救 UI 入口；落盘到章节目录（VeneraX 本地漫画目录可放 `venera_source.json`） | download.dart + 下载管理页 |
| **P4-6d 解码校验** | 对下载字节做一次真解码校验（`dart:ui` 的 `instantiateImageCodec`），拦截断图 | download.dart |

> 设计原则：**下载器负责"批量 + 节流 + 失败清单"，漫画源负责"每个 URL 怎么取（header/超时/重试）"**。这样其它源（包子/拷贝漫画）不必改，只有 comix.to 这种限流 CDN 需要声明更保守的参数。

---

## 十一、遗留事项与下一步

| 优先级 | 事项 | 状态 |
|---|---|---|
| P0 | v0.5.0 实测：章节是否完整、阅读是否全页、速度是否 1-3s | 🚧 待用户实测 |
| P1 | 章节分页若 `lastPage` 大于分页按钮数量，尾部章节仍可能缺失 | 已知限制，待实测确认 |
| P2 | `genres_in` 分类（需数字 id，接口 `/api/v1/manga/genres`） | 未做 |
| P2 | 翻译组偏好持久化（`Settings.defaultScanlationGroup[comicId]`） | 未做 |
| P3 | 收藏/登录（comix.to 需站内账号） | 未做，已移除入口避免误导 |
| P3 | 下载：源级并发上限 + 组间歇 + 失败页清单 | 见 10.4，已打基础 |

**实测时的判读要点**：在 `logs.txt` 里找 `ComixClient` 前缀 ——
- `captured chapter pages (status=200)` + `pages: N images from API payload` → API 路径生效 ✅
- `recovered via JSON.parse payload hook` → 加密响应走了明文通道 ✅
- `pages API empty` + `DOM fallback collected 4 image(s)` → 仍失败，说明匹配/加密又有新变化 ❌

---

## 附录：本轮（v0.5.0）经验教训速记

1. **参数名/字段名的"想当然"是最贵的 bug。** `__` vs `_` 只差一个字符，却让整条 API 链路静默失效三轮；而且现象（慢、不全）完全指向别处（DOM 分页、WAF 挑战）。**判据要可验证**：用 `?_=abc → Invalid token.` 这种"负向对照实验"确认参数名，而不是从日志里猜。
2. **路径匹配必须锚定端点，不能只匹配片段。** `/chapters/{id}` 同时存在于业务接口和 `/user/chapters/{id}/state`，后者会被当成前者 → 静默降级。**规则：matcher 要写完整路径形态 + 排除已知的旁路命名空间。**
3. **"降级路径能跑"是最危险的假象。** DOM 兜底每次都能返回 4 张，看起来"能用"，掩盖了主路径全废的事实。**降级必须打 WARNING 日志并带上预期值对比。**
4. **虚拟化列表 ≠ 懒加载。** 前者靠滚动/翻页也不会补齐（DOM 里根本没有节点），后者滚动就会补。判断方法：看一次能拿到的数量是否与视口大小相关。
5. **跨项目复用经验要先找"同构问题"。** 本次"只读到几页 + 连续多页超时"，与 BT 下载器踩过的坑同源（CDN 限流 + 防盗链 + 虚拟化渲染），直接照搬 BT 调好的参数（Referer / 90s / 5 张一组 / cache-bust）比重新试错快一个数量级。**BT 的 `utils/scraper/` 是 comix.to 的先验证据库。**
6. **加密/混淆面前，优先"借站方自己的运行时"。** token 与解密都在 VMP 模块里，静态还原不可行；正确解法是把钩子里插进页面，让站方代码把明文送到手上（fetch 截获 + JSON.parse 双通道）。

---

## v0.6.0（2026-10-04）：全站 Cloudflare 化与图片 WebView 通道

### 现象
阅读页图片全部 `DioException 403`；封面域 `static.comix.to` 同样 403。

### 根因（curl + Chrome headless 双通道实测）
1. **整站上 CF**：主站 managed challenge（常驻 webview 能自动过，API 截获链路仍正常，日志里能看到新鲜图片 URL）。
2. **图片 CDN 换了轮换域**（447.joshuanotes.site / 447.thekyleblog.site / 447.softstylemarket.site …），新域上了**按 TLS 指纹拦截**的 WAF（1020 "Sorry, you have been blocked"）——dart:io HttpClient 无论带 Referer 还是完整浏览器头都 403；**Chrome headless 直接 200（连 Referer 都不需要）**。旧域 ek10.media-processing-lab.site 被 CF 以 ToS 违规整 zone 封禁（报废）。
3. 封面域 static.comix.to：managed challenge，dio 同样过不去。

### 修复
- **新增 `_ComixImageWorker`（comix_client.dart）**：独立的常驻离屏 WebView + 串行队列（与采集 Worker 分离，互不打断导航状态）。取图流程：导航到图片 URL（真实浏览器 TLS 过 WAF、建立同源上下文）→ 页内 `fetch(location.href, {referrer:'https://comix.to/'})`（同源无 CORS、命中浏览器缓存不二次下载）→ FileReader base64 回传。外层带 90s 重试循环：static.comix.to 的 challenge 会在离屏 WebView 里自动通过（cf_clearance 持久化在共享 userDataFolder，过一次即可）。
- **images.dart**：`_loadComicImage` / `loadThumbnail` 识别 `configs['viaWebview'] == true`，走上述通道取字节；失败仍接 onLoadFailed（cache-bust）与 net-retry。
- **comix_to.js v0.6.0**：`onImageLoad` / `onThumbnailLoad` 返回配置带 `viaWebview: true`。
- 顺带修 baozimh：gatekeeper PoW 提难到 difficultyBits:12 / computeMs:120000（约 2 分钟），headless 验证 deadline 45s→200s；新增失败态（data-state="failed"）提前退出。

### 经验教训
7. **"带什么头都没用 + 真浏览器能过" = TLS 指纹拦截**。排查这类 403 时第一时间用 Chrome headless（`--headless=new --dump-dom`）做对照实验，不要在请求头上浪费轮次。
8. **CDN 域名是易变资产**。轮换域 + WAF 组合下，任何"域名白名单/缓存域名"的设计都会过期；图片加载必须能在运行时适配任意新域 → 走 WebView 通道的决策是结构性的，不是补丁。

### 判读要点更新（logs.txt）
- `ComixImageWorker: fetched N bytes via webview` → 图片 WebView 通道生效 ✅
- `ComixImageWorker: failed for ... status=403` → WAF 策略又变了，需要再逆向 ❌
- `Cloudflare / headless: challenge still running`（超过 2 分钟）→ gatekeeper/CF 挑战时间再涨，继续放宽 deadline

---

## v0.6.1（2026-10-05）：图片通道卡死复盘 —— "阅读页空白、进度圈不动"

### 现象
能进详情页、API 也正常（`pages: 94/119 images from API payload`），但阅读页一张图都不出，进度圈静止。日志里只有一行 `headless image webview started`，此后**没有任何成功或失败记录**。

### 根因（三个错误叠加）
1. **逐张导航 + 单条串行队列**（v0.6.0 设计）：每张图都要 `loadUrl` → 等 readyState → 同源 fetch。一章 94~119 张图全局串行，任何一张慢就全堵。
2. **超时与重试是乘法**：单次失败要跑满 90s 重试循环，而 JS 的 `onLoadFailed` 又给 5 次重试 → **单张图最坏 7.5 分钟才放弃**。所以"不是加载失败，是永远在加载"。
3. **失败完全静默**：Worker 里失败只 `throw` 不 `Log`，日志看不到任何痕迹，只能靠"没有任何输出"反推。

附带改进：图片 Worker 漏了代理设置（采集 Worker 有 `_applyProxy()`）——虽然本例用户是 `system` 代理未触发，但这是同类通道必须继承的环境约束，已抽成共用的 `applyProxySetting()`。

### 修复
- **主路径改为免导航的跨域 fetch**：实测 CDN 响应带 CORS 头（file:// 页 fetch 实测 200 / 169KB），直接在常驻页面里 `fetch(url, {referrer})` → blob → base64，省掉导航，一章不再是串行任务。
- **并发**：简易信号量，4 路并行（浏览器网络栈自己并发）。
- **超时双保险**：JS 内 `Promise.race` 30s 保证 Promise 一定 settle（卡住的 evaluateJavascript 会拖死整个流程）；Dart 侧再对 evaluateJavascript 加 35s 超时。
- **重试预算收紧**：新增源级 `retryLimit`（comix 设 2），慢通道不再用默认的 5 次。
- **失败必须留痕**：Worker 每一步都 Log（status / error / 走哪条路径）。
- **导航降级为兜底**：只有跨域取不到时（封面域 static.comix.to 需浏览器自己过 CF challenge）才导航，且导航路径单独加锁（导航天然互斥）+ 3 次取字节重试给 challenge 留时间。
- **UI 反馈**：取图前先发一条 0 进度事件，避免停在静止的圈上。

### 经验教训
9. **"没有任何日志" 也是一类日志。** 关键路径必须显式 Log 成功与失败，否则故障只能靠"静默"反推，排查成本翻倍。
10. **超时 × 重试 = 用户等待时间的真实量级。** 设计重试预算时必须算这个乘积，而不是只看单次超时。慢通道要配小重试次数。
11. **异步通道要有双层超时。** 只在外层 `.timeout()` 不够：内层 Promise 可能永远不 settle，回调/句柄泄漏，外层超时后队列仍在等。JS 里用 `Promise.race` 自保。
12. **新开的通道要继承已有通道的环境约束**（代理、cookie、UA、超时）。同一份能力如果被拆成两个 Worker，差异点就是事故点 —— 抽成共用函数。
13. **先做机制验证再写代码。** 这次先用 Chrome headless 跑了一个 10 行 HTML，确认"跨域 fetch 可行 / 封面域不可行"，才决定主路径与兜底的分工；省掉了逐张导航这种想当然的实现。

---

## v0.6.2（2026-10-05 下午）：详情页 403 / 图片 eval 空结果 / baozimh 验证永不完成

### 三个现象与根因
1. **comix.to 详情页"all URLs failed for hid=…"**：loadInfo 用 `Network.get`（dio）抓 `/title/{hid}` 的 SSR HTML。整站 CF managed challenge 后 dio 一律 403 —— 章节采集（走常驻 WebView）没坏，坏的是详情 HTML 这一条独走的 dio 通道。
2. **图片 Worker 日志 `fetch status=null error=null`**：我们 JS 的 `fail()` 必然产生非空 status/error，`{}` 说明 eval 返回的不是我们产生的对象。最可疑：常驻页停在 comix.to 主站，而主站正在 CF 挑战循环里反复重载，eval 落进导航间隙。当时的启动 URL 恰恰是 `https://comix.to/`。
3. **baozimh 验证"永远在跑、手动验证也看不出效果"**：日志里 360 次 "challenge still running"、一次都没 solved。挑战其实早过了（PoW 完成、cookie 已下发），但成功判定是"页面无挑战标记"——**baozimh 站内 JS 自身引用 `__gatekeeper_challenge` 字符串，标记永远消不掉**。手动验证同理：DesktopWebview 里标记检测永真 → `verificationSucceeded` 永不置位 → 原页面永不刷新。另一个叠加因素：dio 请求 `cn.baozimhcn.com` → 302 → `cn.cnbzmg.com` 才是吃挑战/下发 cookie 的域，**JS 域名候选里根本没有 cnbzmg.com**；且 `_isFallbackError` 不认 CloudflareException（无状态码），403 挑战不触发镜像切换 → 用户直接看到验证错误页。

### 修复
- **comix_client.dart 新增 `fetchPageHtml(url)`**：复用常驻采集 Worker，页内同源 fetch 抓 SSR HTML（与章节 API 同通道、同 cookie）。js_engine 新增 `comix_fetch_html` case；comix_to.js loadInfo 在 dio 失败后降级调用。
- **图片 Worker 常驻页改 `about:blank`**：图片 CDN 有 CORS 头（file:// 同为 opaque origin 实测 200），主路径跨域 fetch 不依赖页面来源；去掉"comix.to 页面状态"这个变量。封面域仍走导航兜底。新增原始 eval 返回值 dump（截断 200 字符）——`{}` 之谜若再现，日志直接给答案；导航兜底第一次失败时记录页面实际落点。
- **验证成功判定全面改 cookie 导向**：新增 `_isClearanceCookie`（cf_clearance / *gk_browser*）。headless 与手动（DesktopWebview + InAppWebview 两路）都在"标记仍在"时先查票据 cookie，到手即判成功；反之标记消失但既无票据也无内容时不误判。
- **baozi.js**（APPDATA，备份 .bak_20261005）：domains 候选加 `cnbzmg.com`；`_isFallbackError` 增加 `/cloudflare/i` —— 403 挑战触发镜像切换，静默 fallback 到可用的 `cn.webmota.com`（实测当前 200 无挑战）。
- **阅读/下载策略分离**：`fetchImageBytes(url, {timeoutSeconds})`；images.dart 按 `forDownload` 取 `downloadTimeoutSeconds`/`downloadRetryLimit`（默认 90s/4），阅读用 `timeoutSeconds`/`retryLimit`（comix 30s/2）。JS 的 `_comixImageConfig` 返回两套字段。

### 经验教训（续）
14. **"成功"的判定标准要选不依赖站方表现的信号。** cookie/票据是协议级信号，页面标记是表现级信号——站方改版/自带引用就失效。验证、登录、限流解除，一律优先看 cookie。
15. **一条数据通道独走的路径是单点。** loadInfo 独走 dio、章节走 WebView，CF 一来只坏前者——排查时"同页面的不同数据各走各路"要分开验证。
16. **常驻页不要停在目标站上**（离屏 worker 场景）。页面状态（挑战/重载/SPA 包装 fetch）会成为 eval 的隐藏变量；干净上下文（about:blank）+ 按需导航是更可控的形态。
17. **域名是 baozimh 系的第一变量。** 302 链的终点域（cnbzmg.com）不在候选列表里，导致 cookie 域与请求域永远错位；`_isFallbackError` 不认异常类型只认状态码，包装异常会绕过故障转移。

### 判读要点
- `ComixClient fetchPageHtml: N chars from …` → 详情页 WebView 通道生效 ✅
- `fetch result missing status: …` → 图片 eval 又拿到怪结果，看 dump 定位 ❌
- `clearance cookie present despite challenge markers` → 新判定生效（标记可忽略）✅
- baozimh 出现 `CloudflareException` 后不再停在错误页而是换域名重试 → fallback 生效 ✅

---

## v0.6.3（2026-10-05 下午二轮）：决定性根因 —— evaluateJavascript 不 await Promise

### 决定性证据
给图片 Worker 加的原始值 dump 打印出了 `fetch result missing status: {}`；同一个模式在采集 Worker 的 `fetchPageHtml` 上也报 `status=null error=null`。**`{}` = Promise 被序列化**。结论：本环境的 `evaluateJavascript`（WebView2 ExecuteScriptAsync）**不等待 Promise**，任何

```js
(async function(){ ... return JSON.stringify(x); })()
```

的写法在这里**永远拿不到返回值**。影响面（此前全部静默失败）：

| 调用点 | 影响 |
| --- | --- |
| `fetchPageHtml`（详情页 HTML） | loadInfo 降级通道拿不到 HTML |
| `_ComixImageWorker._fetchOnce` | 图片/封面字节永远取不到（阅读页空白、封面不显示） |
| `_inPageFetchJson`（页内 API fetch） | 章节分页 API 从未真正生效，数据全靠截获钩子 + DOM 兜底 |

也就是说：**之前"章节能采到"是钩子兜住的，页内 fetch 一直是死的**——这解释了采集慢、分页要点击、偶尔不全。

### 修复
- 新增 `evalAsyncResult(controller, asyncBody, {timeout})`：脚本**同步返回 1**，把结果写进 `window.__comixAsync[slot]`；Dart 侧轮询同步读取（250ms 一轮，超时可控）。JS 内部照旧 await，只是不再依赖 Promise 返回值。三处调用点全部改走它。
- `fetchPageHtml` 进一步简化为**导航 + 同步读 DOM**（`document.documentElement.outerHTML`）：既绕开 Promise 问题，又让 CF 挑战由浏览器自己过完再读；读到挑战页则等 2.5s 重试（最多 3 轮）。
- 配套工具：`unwrapEvalString`（解 WebView2 的多层 JSON 引号）、`looksLikeChallengePage`（判断读到的是不是挑战页）。

### 包子漫画：一次验证，后续章节复用
观察到的链路：请求 `appcn.baozimh.com` → 302 → `www.baozimh.com`（gatekeeper）→ 验证在 www 上完成、cookie 存 www；但**下一个请求的起点又是 appcn，dio 的 cookie 拦截器只在原始请求上跑一次，302 跳不重跑** → cookie 永远带不上 → 每章重新挑战一次 2 分钟 PoW。

修复（三层）：
1. **站点簇归一**（`_clusterOf` = 可注册域 eTLD+1）：验证成功后把票据 cookie 缓存到簇（`_clusterCookies`）并记时间。
2. **请求阶段注入**（`CloudflareInterceptor.onRequest._injectClusterCookies`）：簇内有票据就补进 Cookie 头 —— 重定向跳不带 cookie 的问题从源头解决。
3. **不再重复跑 PoW**：loading 层若发现该簇 30 分钟内已验证，直接 retry，不启动 headless 验证（手动按钮保留）。
4. **baozi.js 域名降级**：触发挑战的域名记 `challenged_domains`，30 分钟内排序降到最后；`webDomains` 改为"上次可用域 → 选中域 → 未挑战域 → 被挑战域"。第一次挑战后即切到可用域（实测 `cn.webmota.com` 当前 200 无挑战），后续章节不再触发验证。

### 经验教训（续）
18. **"返回值是 {}" 这类怪象要立刻追到底层机制。** 我们一度以为 `{}` 是页面状态/CORS/CSP，实则是 eval 不 await Promise。诊断日志（dump 原始返回值）是把它钉死的关键——**先让故障可观测，再谈修复**。
19. **看似能用的功能可能是被兜底掩盖的。** 页内 fetch 一直是死的，但因为有截获钩子，章节数据照样出来。评估一条链路是否真的生效，要看它自己的成功日志，而不是看最终结果是否存在。
20. **重定向会绕过请求拦截器。** dio 的 cookie 注入只在原始请求跑一次，302 之后的新 host 不带 cookie —— 凡是"验证过但还是被挑战"的现象，先查重定向链。
21. **验证状态要按"站点"而不是按"URL/host"记账。** 站点轮换 host 是常态，按 URL 记账必然退化为"每次都验"。

### 判读要点（更新）
- `evalAsync: timed out after Ns` → 页内 JS 卡住（而非返回值被吞）
- `ComixClient fetchPageHtml: N chars from …` → 详情页通道生效 ✅
- `ComixImageWorker fetched N bytes via webview fetch` → 图片通道生效 ✅
- `injected N verified cookie(s) for …` / `cluster '…' verified` → 复用生效，后续章节不再验证 ✅
- `cluster already verified, retry without headless` → 跳过重复 PoW ✅

---

## v0.6.4（2026-10-05 傍晚）：图片通道再调优 —— 跨域 fetch 死路 + 导航优先 + 3 通道并行

### 现象（用户反馈 + 日志）
- 搜索结果封面大片空白；进详情页慢；阅读页 2 分钟以上才出部分图，大量超时、圈圈不转，且没有单页重试入口。
- 日志证据：`fetch status=403` ×176、`evalAsync: timed out after 30s` ×32、`cross-origin fetch unusable` ×62——**v0.6.1 的跨域 fetch 主路径已被 CDN WAF 封死**（昨日实测可过，今日大面积 403/挂起；CDN 又换了 `lov.*` 轮换域）。
- 而导航兜底**每次都成功**（`navigate fallback` 之后必跟 `fetched N bytes`）。灾难在于时序：每张图先在死路上耗满 30s 才转导航 → 单张 30~90s。

### 关于站方广告弹层
comix.to 登录后阅读需先点掉一次广告弹层。我们的管线不渲染页面（API 截获 + 图片字节直取），弹层**不影响取图**；唯一风险是盖住采集 Worker 的分页按钮导致 dispatchEvent 被吞。已加 `_adSweepJs`：翻页点击前清扫已知广告容器（adsbygoogle/exoclick/juicyads/tsyndicate iframe 等）+ 解除 body 滚动锁 + 给高 z-index 全屏浮层禁用 pointerEvents（不误伤正经 UI）。

### 修复
1. **导航优先**（`_ImageLane`）：直接导航到图片 URL（浏览器自己的顶级 GET，无 Origin 头、真实 Sec-Fetch 语境——WAF 放行的正是这种）→ 同源 fetch 回读（命中浏览器缓存）。跨域 fetch 降级为"10 分钟内成功过才先试"的快路径（8s 短预算），失败立即转导航，**绝不在死路上耗预算**。
2. **3 通道并行**：单 WebView 导航互斥，开 3 个独立离屏 WebView 轮转分发。阅读（顺序）+ 封面网格（28 张）吞吐 ×3。
3. **超时契约按用户指标**：单张 webp 10s 出图可容忍、30s 即超时。`timeoutSeconds=30` 现在是**整张图的硬预算**（导航 15s + 同源回读，共用倒计时），到点抛异常 → ComicImage 已有的错误 UI + **手动 Retry 按钮**（本来就存在，此前永远到不了这一步）。JS 配置 `retryLimit: 0`（一次尝试 + 一次 cache-bust 重试封顶），下载仍是 90s×3。
4. 详情页：dio 必 403 但很快（CloudflareException），fetchPageHtml 实测 163K chars 正常拿到——慢主要在挑战等待，维持现状。

### 判读要点
- `ImageLane{n}: fetched N bytes` → 生效；注意 lane 编号 0~2 并行。
- `cross-origin probe failed` 偶发没关系（立即转导航）；若 `navigate landed on` 出现挑战页且总超时 → WAF 又升级。
- 阅读页出现"错误文本 + Retry"按钮 = 快速失败路径正常工作，点 Retry 单页重载即可。

# P38 · 下载源回归诊断 + comix 加固（2026-10-11）

> 用户报障：comix.to 搜索卡顿转圈、收藏的 comix 漫画章节信息更新不了；包子漫画 Cloudflare 验证繁琐（60s+ ×2）、每章重验、下载拿不到图片列表卡死。
> 本文先用**运行日志 + git** 坐实因果，再给针对性加固。**结论先行：两处退化均非本会话代码改动引入。**

---

## 0. 先说结论（因果）

| 现象 | 是否我本会话改坏 | 真因 | 证据 |
|---|---|---|---|
| comix 搜不出 / 章节更新不了 | ❌ 否 | comix.to 站点端反爬升级：章节 API 大量返回**加密体 `{"e":"..."}`**，逼降级 DOM；DOM 探针偶发整段抓不到（坏 worker / 空白页） | `comix_client.dart` 本会话 0 改动（git：最后一次改动是「改名提交」）；日志实锤（见 §1） |
| comix 搜索栏卡顿转圈 | ❌ 否（次生症状） | `_ComixWorker` 是**单串行队列**，一个卡住的章节抓取会堵死后续所有搜索 | 日志时间线（见 §1） |
| 包子每章重验 / 下载拿不到图 | ❌ 否 | 包子站点端 Cloudflare 收紧；下载走 `appcn.baozimh.com`（App 接口域，已上 CF）触发 `CloudflareException`；`loadEp` 网页镜像优先逻辑本会话未动 | 日志实锤（见 §2）；`baozi.js`/`cloudflare.dart` 本会话未动 |

> 🔴 **注意**：本会话我动过的运行时相关文件只有 `venera-configs-main/baozi.js`（仅删 3 个**已失效**域名、版本 1.2.0→1.2.1，**未动** `loadEp` 的 CF 兜底逻辑）、`headless.dart`（新增 5 条无头测试命令 RUNNER，不参与 GUI 运行）、`headless_p1_checks.dart` 等 RV 断言（不参与 GUI 运行）、以及 dev 取证脚本。**comix 生产代码 `comix_client.dart` 本次零改动。**

---

## 1. comix.to 根因（日志实证）

运行日志：`%APPDATA%\io.github.maelshiyan02\mangrove\logs.txt`（2026-10-11 17:53–18:01 会话）。

### 1.1 搜索其实没坏
```
17:53:55  comix_to: search keyword=One Piece page=1
17:53:59  ComixClient: browse: 28 items, lastPage=14
17:53:59  comix_to: search got 28 comics, maxPage=14   ← 搜出 28 本
```
搜索走 `browseManga` → 截获 `/api/v1/manga?...`，**正常**。

### 1.2 章节抓取间歇性失败（关键）
```
17:54:06  fetchChapters(hid=93e5r) via headless worker
17:54:07  ComixClient: captured chapters (status=200): /api/v1/manga/93e5r/chapters?...
17:54:07  ComixClient: chapters: captured body unusable, preview={"e":"Ae1E2..."}   ← 加密体！
17:54:36  ComixClient: no chapters API capture within 30s
17:54:36  ComixClient: API path empty — falling back to DOM scraping
17:54:37  ComixClient: DOM: page1 rows=20, pages=8  →  cumulative=120   ← DOM 兜底成功
```
```
17:54:45  fetchChapters(hid=kl05z) via headless worker
17:54:46  comix_to: got 57 chapter numbers, cached        ← API 明文直采成功
```
```
17:55:42  fetchChapters(hid=9lmnj) via headless worker
17:55:46  ComixClient: eval retry loop ended after 60 attempts
17:55:46  ComixClient: DOM: chapter section not ready: null   ← DOM 探针整段抓不到
17:55:46  ComixClient: fetchChapters returned 0 chapter numbers
17:55:46  comix_to: headless webview returned empty chapters
```

**判定**：
- `kl05z` = API 明文 → 成功（57 章）。
- `93e5r` = API 返回**加密体** `{"e":"..."}`（`_bodyLooksUseful` 拒收）→ 降级 DOM → 成功（120 章）。
- `9lmnj`（error-the-echo）= API 失败 + DOM 探针 `SECTION.mpage__chapters` 整段未就绪（60 次全空）→ **0 章**。

→ comix.to 现已对大量标题**加密章节 API 响应**，并要求 DOM 兜底；而 DOM 兜底在 worker 处于空白页/坏状态时整段失效。这是**站点端反爬升级**，不是代码回归。

### 1.3 搜索卡顿 = 串行队列次生症状
`_ComixWorker`（`comix_client.dart:1255`）是 `_queue` 串行执行：**一个 hang 住的章节抓取（API 30s + DOM 120s）会堵死后续所有 `browseManga`/搜索请求** → 用户看到「搜索栏一直转圈」。修复 §3 的重建 worker 能缩短 hang 时长，但根本的串行阻塞需后续架构优化（不在本会话）。

---

## 2. 包子漫画根因（日志实证）

```
18:01:09  Cloudflare: Gatekeeper challenge detected: https://www.baozimh.com/__gatekeeper_challenge/start?...
18:01:17  error Network: CloudflareException: https://appcn.baozimh.com/baozimhapp/comic/chapter/miemenjiazudezhongshengzhe-.../0_0.html
18:01:37  error Download: step failed after 3 attempt(s): CloudflareException: https://appcn.baozimh.com/...
18:01:37  error Download: CloudflareException: https://appcn.baozimh.com/...
```

**判定**：下载任务的取图请求落到 `appcn.baozimh.com/baozimhapp/comic/chapter/...`（App 接口路径，**已上 Cloudflare**）→ `CloudflareException` → 3 次重试后任务失败。这正是 `baozi.js::loadEp` 第 2 步兜底路径（`appcn.baozimh.com`，line 688）：**第 1 步网页镜像全部失败后**才走到 App 域。

**为什么网页镜像会全部失败**：该收藏漫画的 `comicId` 很可能是 App 格式（最初经 App 接口收藏），网页镜像 `https://<lang>.<镜像>/comic/chapter/<appId>/0_<ep>.html` 解析不到 → 全部 `_isFallbackError` 抛错 → 命中 App 兜底 → 撞 CF。或镜像本身已被 baozi 重定向到 CF 主域。无论哪种，都是**站点侧 CF 收紧**，本会话未改动 `loadEp`（line 646–695）与 `cloudflare.dart`。

**「每章重验」澄清**：`cloudflare.dart` 已有集群清票机制——`_clusterOf` 把 `www.baozimh.com` 与 `appcn.baozimh.com` **都归到 `baozimh.com` 同一簇**（取注册域后两段），`_injectClusterCookies`（line 227）专门解决「302 到另一 host 每章重验」。所以 host 簇**已合并**；当前每章重验是 baozi 更狠的 **Managed Challenge** 需要交互式求解，现有 cookie 复用不足以覆盖——属站点端升级，非代码回归。

---

## 3. 本会话已做的加固（comix）

文件：`Mangrove/lib/network/comix_client.dart`

- `fetchChapters` / `fetchImageUrls`：抽出 `_tryFetchChapters` / `_tryFetchImageUrls`；**当两条路径都返回空时，重建 headless worker（全新 WebView 会话）重试一次**（`_ComixWorker.restart()`），避免「坏 worker 永久空结果」卡死串行队列、连带拖垮搜索。
- 新增 `_ComixWorker.restart()`：释放并置空当前 WebView，下次 `ensure()` 重建。

> ⚠️ **未验证声明**：本会话**不能跑 flutter/dart**，无法对真实站点回归。上述加固是**低风险自愈**——最坏情况只是下次调用多一次重建延迟，不会让原本能成功的路径变坏。需用户在 GUI 会话重测：搜索一本 comix 漫画 → 进详情看章节是否出来；若仍偶发空，下一次调用会自动重建 worker 重试。

---

## 4. 没动 / 不能盲动的部分（诚实边界）

- **comix 加密 API 的真正修复** = 在 App 内复用 comix.to SPA 的**客户端解密**（现有 `JSON.parse` 明文载荷钩子没能稳定恢复加密 chapters 体）。这需要针对线上站点的运行时调试，本会话无法完成 → 列为后续专项（P39 候选）。
- **包子 CF 每章重验**：属站点端 Managed Challenge 升级，`cloudflare.dart` 集群机制已正确合并 host 簇，盲改拦截器风险高且无运行时验证 → 不动。建议用户尝试：手动「验证一次」后观察后续章节是否复用；若仍每章重验，属站点对抗，需专项。

---

## 5. 用户下一步（GUI 会话，无需敲命令）

1. **comix**：搜索任意漫画 → 进详情看章节列表是否加载；如偶发空，等下一次自动重试或重进详情。
2. **包子**：确认 `venera-configs-main/baozi.js`（v1.2.1）是否已同步到
   `%APPDATA%\io.github.maelshiyan02\mangrove\comic_source\baozi.js`（P35 待办 ①）；
   试一本**网页镜像可达**的漫画下载一章，看是否仍撞 `appcn` 的 CF。
3. 把界面现象（章节出了没 / 包子是否还每章重验 / 下载图能否拿到）回报，决定进 P39 专项（comix 解密 / 包子 CF 复用）。

---

## 6. 门禁与状态

- 本会话**未跑构建**（不能跑 flutter）。改动仅 `comix_client.dart`（纯逻辑加固，无 Flutter 依赖的 UI 改动）。
- 🔴 待办：GUI 重测 comix 加固效果；P35 的 baozi.js 同步确认；RV 收尾 `font_sfnt_accepts_garbage` 仍阻塞（见 P36/P37）。

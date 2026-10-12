# P42 · 包子「每章只 50 页」真根因修复 + comix.to 转圈/搜索空兜底

> 时间：2026-10-11（21:00–21:30，GMT+8）
> 背景：P41 修复后用户 GUI 复测，提出**两条新问题**。本轮取证后定性，修复并做 headless 正反向验证。
> 拷贝漫画本轮**未动**。未经用户许可**不 git commit**。

---

## 0. 结论速览

| 问题 | 用户报告 | 真根因 | 修复 | 验证 |
|---|---|---|---|---|
| 包子「每章只 50 页」 | 所有包子漫画的章节阅读/下载**最多 50 张**（其他源无此限制） | **不是 App 端截断，是站点把章节再分页**：章节页标题带 `(1/4)`，URL 分 `0_0.html`、`0_0_2.html`…，每页约 50 张，**相邻页有重叠需去重**；旧 `loadEp` 只抓第一页 ⇒ 恒 50 | `baozi.js` **v1.2.4**：从 `<title>` 解析 `current/total` 逐页抓取 + `seen` 集合按 URL 去重保序 | 正向 total=**168**（真实 4 页 UNION，0 重复）；**反向**（注入只抓首页）total=**50**（与用户症状精确同构）后还原 |
| comix.to 转圈/搜索空 | 搜索栏用 comix.to **转圈卡住**；历史记录进来**封面空白 + 章节采不到** | ① 列表/章节 API 响应被站方加密 `{"e":"..."}`，旧实现识别加密体后仍**空等到 timeout**（30/60s）⇒ 转圈卡住；② 列表 API 亦加密 ⇒ 搜索无结果 | ① 加密体只等 **2s 宽限**即返回 null，快速走后续路径；② 新增 browse 卡片 **DOM 兜底** | 构建/静态门禁通过；**WebView/DOM 通道本会话无渲染表面无法 headless 验证 ⇒ 交用户 GUI** |

---

## 1. 包子漫画「每章只 50 页」—— 真根因：站点章节再分页

### 1.1 取证（4 页真实 HTML 落盘对照）

包子站点对章节**做了二次分页**，同一话跨越多个 HTML：

| URL | 页面标题 | 图片数 | 图片序号区间 |
|---|---|---|---|
| `0_0.html` | 第1话(1/4) | 50 | 1..50 |
| `0_0_2.html` | 第1话(2/4) | 54 | 47..100 |
| `0_0_3.html` | 第1话(3/4) | 54 | 97..150 |
| `0_0_4.html` | 第1话(4/4) | 22 | 147..168 |
| `0_0_5.html` | 第1话(5/4) | 22 | 147..168（越界被站点**钳制**回末页） |

- **UNION = 168 张**，图片路径 `https://s1.bzcdn.net/scomic/<slug>/0/1-blmi/{1..168}.jpg`。
- 相邻页**有重叠**（part1 尾 50 / part2 头 47；part2 尾 100 / part3 头 97；part3 尾 150 / part4 头 147）
  ⇒ 必须按 URL 去重，否则会重复计数。
- 旧 `loadEp` 只请求 `0_<epId>.html` 并解析其 50 张 ⇒ **恒 50**，与用户"每章只计入 50 页"精确吻合。

### 1.2 修复（`baozi.js` v1.2.4）

`loadEp` 新增三个纯函数（第 702–805 行，web 路径走 `withDomains`，失败兜底 `appBase="https://appcn.baozimh.com/baozimhapp"`）：

- `pagerOf(body)`：正则 `/[（(](\d+)\s*\/\s*(\d+)[）)]/` 从 `<title>` 解析 `current/total`；
- `pagePath(page)`：page1 → `0_${epId}.html`，否则 `0_${epId}_${page}.html`；
- `collectPages(getPage)`：逐页抓取 → `seen` Set 按 URL 去重保序 → 终止判据：
  - 首页 0 图抛 `DomainBlock: empty chapter images`（沿用旧契约）；
  - 已知 `total` 时中间页非 200 抛 `DomainBlock: chapter page N status X`；
  - `pager.current > pager.total`（越界钳制页）则 `break`；
  - 无分页标记时靠"本页无新图" `break`；
  - `page <= 200` 硬上限兜底。

```js
const pagerOf = (body) => {
  const t = String(body).match(/<title>([^<]*)<\/title>/);
  if (!t) return null;
  const m = t[1].match(/[（(](\d+)\s*\/\s*(\d+)[）)]/);
  if (!m) return null;
  return { current: parseInt(m[1], 10), total: parseInt(m[2], 10) };
};
const pagePath = (page) =>
  page === 1 ? `0_${epId}.html` : `0_${epId}_${page}.html`;
const collectPages = async (getPage) => {
  const images = [];
  const seen = new Set();
  let total = null;
  for (let page = 1; page <= 200; page++) {
    const res = await getPage(page);
    if (!res || res.status !== 200) {
      if (page === 1) { throw `Invalid status code: ${res ? res.status : "null"}`; }
      if (total != null && page <= total) {
        throw new Error(`DomainBlock: chapter page ${page} status ${res ? res.status : "null"}`);
      }
      break;
    }
    const pager = pagerOf(res.body);
    if (pager) {
      if (pager.current > pager.total) break;
      if (total == null) total = pager.total;
    }
    let added = 0;
    for (const url of parseImages(res.body)) {
      if (seen.has(url)) continue;
      seen.add(url); images.push(url); added++;
    }
    if (page === 1) {
      if (images.length === 0) { throw new Error("DomainBlock: empty chapter images"); }
    } else if (added === 0) { break; }
    if (total != null && page >= total) break;
  }
  return images;
};
```

### 1.3 验证（正反向闭环）

- `node --check` exit 0。
- **正向**（离线工装 `p42_baozi_harness.js`，喂 4 页真实 HTML）：
  `VERDICT=PASS`，`total=168`、**0 重复**、首图 `1.jpg`、尾图 `168.jpg`。
  headless download-check：`total:168`，末条 `[CLI PRINT] verdict=success`。
- **反向**（注入"只取首页"的坏 `collectPages`）→ `total=50`，
  **与用户报告的"每章只 50 页"精确同构** ⇒ 验证确实能抓住此故障。注入已还原。
- 仓库版与部署版 SHA256 一致：
  `DAE14D6A4BBE38E2EC6FF7F5ECE4C4F776DBC3B2CE1051D043B2891D1CC59942`
  （仓库 `venera-configs-main/baozi.js` / 部署 `%APPDATA%\io.github.maelshiyan02\mangrove\comic_source\baozi.js`）。

---

## 2. comix.to 转圈卡住 + 搜索空结果

### 2.1 真根因

1. **转圈卡住**：comix.to 对部分 `/api/v1/*` 响应返回**加密体** `{"e":"<base64>"}`
   （只有 SPA 自身解密逻辑能还原）。旧 `_captureOrPayload` 识别到加密体后**只打 warning 继续空等**
   直到 timeout（列表 30/60s）⇒ 用户看到的就是"转圈卡住"。
2. **搜索空结果**：列表 API 同样加密 ⇒ 截获不到明文 ⇒ 旧实现直接返回空
   ⇒ 搜索/发现/分类无卡片。

（这一条与 P38 的"加密 chapters 体"诊断同源，本轮把「快失败 + DOM 兜底」补齐。）

### 2.2 修复（`comix_client.dart`）

- **加密体快失败**：新增 `_encryptedBodyRe = /^\s*\{\s*"e"\s*:/` 与 `_looksEncrypted()`；
  `_captureOrPayload` 内记 `encryptedAt`，加密体只给 **`_encryptedGrace = 2s`** 宽限等 `JSON.parse`
  明文通道；到点仍无明文即 `return null`，**不再空等到 timeout**（消除转圈）。
- **browse DOM 兜底**：`browseManga` 重构 ——
  先 `_route(_browseViaApi(url), 90s)`，空则 `_route(_browseByDom(url), 120s)`；
  新增 `_route()`（worker 队列 + 异常归一化为空结果）；
  新增 `_browseProbeJs`（选 `a.card`，取 `.card__title` / `.card__poster-wrap img`，
  过滤 href 含 `/title/`）与 `_browseByDom()`（navigate → `_evalWithRetry` → 映射为
  `{url,title,poster}` 条目，去重，返回 `{'items':[...],'lastPage':1}`）。
- `_browseViaApi` 签名由 `(Map urlQuery, int page)` 改为 `(String url)`。
- `_fetchChaptersViaApi` 空捕获日志改为明确提示"加密/空 ⇒ 下一步走 DOM 兜底"。

### 2.3 验证

- `run_build_task.py` → **BUILD_OK**（pub get/analyze/build/install 全 rc=0）。
- 🔴 **本会话无渲染表面**：comix 的 WebView/DOM 路径**无法在本会话 headless 验证**
  （历史报 `Cannot create HeadlessInAppWebView`）⇒ **只能交用户 GUI 验收**。

---

## 3. 改动文件清单（均未提交）

| 文件 | 改动 |
|---|---|
| `venera-configs-main/baozi.js`（仓库版 v1.2.4） | `loadEp` 章节分页逐页抓取 + 按 URL 去重保序 |
| `%APPDATA%\io.github.maelshiyan02\mangrove\comic_source\baozi.js`（部署版 v1.2.4） | 同上，SHA256 与仓库版一致 |
| `Mangrove/lib/network/comix_client.dart` | 加密体 2s 快失败 + browse DOM 兜底（`_route`/`_browseProbeJs`/`_browseByDom`） |

## 4. 门禁（全绿，与基线持平）

`run_build_task.py`（托管 venv python）→ **BUILD_OK**。

| 检查 | 结果 | 基线 |
|---|---|---|
| block-ops | PASS **108** | 108 |
| edit-check（MDGH ch1 真实工程夹具） | PASS **219** | 219 |
| run-plan | PASS **31** | 31 |
| bootstrap | PASS **34** | 34 |
| glossary | PASS **26** | 26 |
| glossary-ui | PASS **30** | 30 |

headless 引擎退出码 -532265403 为无渲染环境噪音，只认末条 CLI PRINT。

## 5. 测试副产物清理

- 删除本轮 headless download-check 产生的 `ComicLibrary/downloads/灭门家族的重生者(1)`（162 文件 / 13.7MB）；
- `downloading_tasks.json` 已为 `[]`（无残留任务）；
- **保留**用户 GUI 复测产生的无后缀 `灭门家族的重生者` 与 `第一次告白`，由用户处置。

## 6. GUI 人工验收步骤（本会话无渲染表面，只能交用户）

**包子**（先完全退出 App、托盘也退，再重启 —— 源只在启动 `doInit()` 加载，无文件 watch）：
1. 打开包子漫画任意一本，进任意一话的阅读/下载；
2. 预期：**多张、远超 50**（例：《灭门家族的重生者》第 1 话应出约 **168 张**全图）；
3. 意外时把 `%APPDATA%\io.github.maelshiyan02\mangrove\logs.txt` 中
   `empty chapter images` / `chapter page` / `appcn` 相关行回传。

**comix.to**（在**未封禁节点**下：香港/日本/新加坡/英国等；美/印节点当前被封）：
1. 搜索栏输入关键词 → 预期**快速出卡片**（不再转圈卡住）；
2. 从历史记录进入已有漫画 → 预期**封面正常 + 章节列表能采集**；
3. 若仍失败，把 `logs.txt` 中 `ComixClient` 的
   `encrypted payload` / `browse API empty` / `browse DOM` 相关行回传。

🔴 验收**通过前**勿对包子源点"检查更新"（上游若发布更新版本仍含旧逻辑会覆盖 v1.2.4）。
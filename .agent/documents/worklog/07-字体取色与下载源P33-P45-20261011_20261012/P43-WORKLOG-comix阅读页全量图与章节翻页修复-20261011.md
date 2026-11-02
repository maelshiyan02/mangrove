# P43 · comix.to 阅读页全量图（React fiber）+ 章节翻页硬化

> 时间：2026-10-11（22:00–23:00，GMT+8）
> 背景：P42 后用户 GUI 复测 comix.to，报**两个症状**（本轮唯一用户消息）：
> ① 漫画信息/章节列表「**只采到一个页面的量**」，翻译组只显示一页的章节数；
> ② 每个章节进阅读页「**只能显示三张图片**」。
> 包子漫画本轮**未动**（用户明确：除速度慢外可接受，30 秒内出图即可）。拷贝漫画**未动**。
> 未经用户许可**不 git commit**。

---

## 🔴 后记（2026-10-12）：GUI 验收**未通过** + 真因改判为「代理节点被封」

> **本节由 2026-10-12 会话追加，优先级高于下文原有措辞。**

**用户 GUI 实测（P43 落地后）原话**：

> 「搜索栏只能借助部分历史记录使用 comix.to 漫画源搜索部分漫画，简单来说就是**网络失败，抓取不到信息**。
> 同时使用收藏的 comix.to 漫画就明确发现**抓取不到完善的章节信息**，以及**部分翻译组名字无法正确显示**。
> 点击阅读一个章节则会产生**只有 3 页或者干脆报错 network error**。」

⇒ P43 新增的 fiber / 翻页逻辑**在本机当前的网络条件下根本没有机会执行**（页面在 WebView 里就没加载出来）。
**P43 定级：代码已落地 + 逻辑层反向验证通过，但 GUI 验收 = 未通过。**

**2026-10-12 决定性取证（Clash 换节点对照，`curl` 经混合端口 `127.0.0.1:7890` 实测）**：

| 出口 | 结果 |
|---|---|
| **🇺🇲 美国Y02**（当时活跃节点）经代理 | 200 → `comix.to/@waf/challenge`（**WAF 挑战页**，9,394 B） |
| **直连**（不走代理） | 同上，仍是 WAF 挑战页 |
| 🇭🇰 香港Y01 / 🇯🇵 日本Y01 / 🇸🇬 新加坡Y01 / 🇬🇧 英国Y01 经代理 | **200 → `https://comix.to/` 真首页**（393,913 B） |

- 真因：**当时 Clash 活跃节点是美区，被 comix.to 的 WAF 拦在挑战页**；这与 A08/P41 记录的「美/印被封、港/日/新/英可用」精确一致。
- 本轮已把 Clash `🔰 选择节点` 切到 **🇭🇰 香港Y01**（`http://127.0.0.1:8445/proxies` PUT 切换，3 次复测全 200 / ~0.65s）。
- ⚠️ 因此 P43 的 fiber / 翻页改动**是否真正有效，仍未被端到端验证**——网通之后才轮得到它。
  下一轮首选：网通的前提下重测阅读页图片数是否 > 3、章节是否翻全。

**已知仍未解**：comix.to 列表/章节 API 响应加密 `{"e":"..."}`（P42 只做 2s 快失败兜底）；
SSR 章节偶发 `Comic has no chapters`。**包子漫画 / 拷贝漫画本轮未动。**

---

## 0. 结论速览

| 症状 | 真根因 | 本轮修复 | 验证 |
|---|---|---|---|
| 阅读页「只有 3 张图」 | 阅读器是 **Swiper slides 虚拟化**——同屏只挂 3 张 `<img class="rpage-page__img">`，滚动也不补加载；而 `<img>` 探针只认 DOM。**整章页数组其实在 React 内存里** | 新增 `_pagesByReactJs`（沿 React fiber 挖页数组，元素字段 `bZ` = 完整图片 URL）+ `_pagesViaReact` 轮询；`_fetchPagesByDom` 改为 **fiber 优先、`<img>` 探针次之** | Node **合成 fiber 图**跑**真实常量**：正向 3 图恢复 ✓、故障（`bZ` 改名）0 图 ✓、通用字段回退 ✓、故障（回退缺 `q2` 守卫）0 图 ✓；9 个 JS 常量全 `parse` 通过 |
| 章节列表「只有一页」 | 旧 DOM 翻页点完只**固定等 1.2s**；站方对章节接口加密，SPA 要先解密再渲染 ⇒ 读到的还是上一页 → 判「未生效」提前 `break`（线上日志实证 `page 4 not effective`）。且 `pagesHint` 取自**可见数字按钮的最大值**（Next-only 时 =1）⇒ `for p<=pagesHint` 循环根本不进 | `_fetchChaptersByDom` 硬化：基准改为**首页首行的 href**（不再是 null）、上界放宽到 200、**轮询最多 8s 等首行变化**、数字按钮缺失时点 **Next 兜底**（`_clickNextPageJs`） | 同上（`_clickNextPageJs`/`_pageVerifyJs` parse ✓）；端到端**待 GUI**（本会话无渲染表面） |

🔴 **定级**：两处均为**代码已落地 + 逻辑层正反向验证通过**，但 comix 的 WebView/DOM 通道
**本会话无渲染表面**（历史报 `Cannot create the HeadlessInAppWebView instance!`），
**端到端一律待用户 GUI 验收**——不标「已完成 ✅」。
🔴🔴 **2026-10-12 更新：GUI 验收结果 = 未通过**（真因是代理节点被封，页面没加载出来；见文首「后记」）。

---

## 1. 取证过程（站点侧静态逆向 + 运行日志）

### 1.1 运行日志（`%APPDATA%\io.github.maelshiyan02\mangrove\logs.txt`）

- 本会话任何 comix 的 WebView 调用都直接抛
  `PlatformException(0, Cannot create the HeadlessInAppWebView instance!)`
  ⇒ `API path empty — falling back to DOM scraping` ⇒ `DOM path failed` ⇒
  `fetchChapters returned 0 chapter numbers` ⇒ 重启 worker 重试一次，仍然 0。
  **这解释了「只在用户 GUI 会话里才看得到真实行为」**（A01 §3：无渲染表面）。
- 站方反爬三层（P38–P42 已证）：① 签名 token（参数名 **单下划线** `_`，绑定完整 query，
  不能自己拼分页参数）；② 部分 `/api/v1/*` 响应**加密** `{"e":"<base64>"}`；
  ③ Cloudflare 按出口 IP 封禁（跟随用户代理，P41 已改）。

### 1.2 站点构建产物逆向（reader chunk）

对 `/assets/build/35595e3de3c99889c1aa70/dist/tmq6ux-*.js` 逐块扫描（`python -u` 落盘对照）：

| chunk | 大小 | 命中 |
|---|---|---|
| `tmq6ux-CARftgsC2.js` | 61,878 | `"pages"`×12、`rpage`×**252**、`swiper`×6 ⇒ **阅读器 chunk** |
| `secure-tmq6ux-cJcHHB1g.js` | 191,139 | `atob`×4、`btoa`×4、`charCodeAt`×22、`Uint8Array`×5 ⇒ **crypto chunk** |
| `tmq6ux-QgOrPl2t.js` | 36,821 | `lastPage`×1 |

阅读器**URL 构造器**（从 reader chunk 逆出）：

```js
const t = function(a, b, c, d, e) {          // a=bZ, b=q9, c=ym, d=页序, e=重试计数
  if (!a || e <= 0) return a;                // 🔴 重试 <= 0 时**原样返回 bZ** ⇒ bZ 就是完整图片 URL
  ...  // 只在重试时按 e 轮换子域并拼 "?r="
}(page.bZ, page.q9, page.ym, 页序, 重试次数);
```

调用点 `lt` 组件 `function({page:b,total:c,loaded:d,onSettled:e})`，`f=b.q2`（页序）；
`<img class="rpage-page__img" src={t}>`，另有 `data-page` 属性与 `long-strip`（长条）模式。

**页对象字段**：`bZ`(完整 URL 字符串)、`q2`(页序数字)、`q9`(域名数组)、`ym`(子域)、
`Tl`(高，默认 800)、`FL`(宽，默认 1200)、`cK`(占位标记)。

⇒ **结论**：整章页数组由 SPA 解密后落在 React 内存；同屏只渲染 3 张是 **Swiper 虚拟化**，
不是懒加载。所以「3 张」必须从 **React fiber** 拿，DOM 探针无解。

### 1.3 详情页 SSR（另一条路，本轮未采纳）

详情页 `<script type="application/json" id="initial-data">` 是 TanStack Query（react-query）
SSR 水合，形状 `{"page":"manga","queries":{...},"routes":{...},"manga":{...}}`，
`queries` 键为序列化 query key（`["manga","detail","503jz"]` 等）。
**章节/图片 query 不在 SSR 里**（客户端经加密 API 拉取）⇒ 本轮不走 SSR，走 fiber。

---

## 2. 修复（`Mangrove/lib/network/comix_client.dart`，5 处）

1. **`_clickNextPageJs`（新增）**：分页控件只剩 Next（数字窗口滚动 / `pagesHint` 失准）时，
   找 `aria-label`/`title`/文本含 `next` 的按钮或链接并 `dispatchEvent`。
2. **`_pagesByReactJs`（新增）**：React fiber 挖取整章页数组。要点：
   - `fiberOf`：从任一元素找 `__reactFiber$*` / `__reactInternalInstance$*`；
   - `urlOf`：优先 `bZ`（完整 URL）；**字段名随构建漂移时的后路**——只有对象带数字 `q2`（页对象判据）
     才认 `url/src/image/imageUrl/file/link`，避免把章节数组/头像数组误当页数组；
   - `harvest`：数组长度 ≥2 且取到 ≥2 URL 才更新 `best`（取最长）；`scan` 深度 ≤7 + `visited` 去重；
   - seeds：`img.rpage-page__img` 优先，再 `.rpage-main/#root/#__next/main/section`（≤8）；
     每个 seed 沿 fiber 向上 ≤150 层，逐层 `scan(memoizedProps)` 与 `scan(memoizedState)`；
   - 返回 `{ok, count, urls}`（去重）。
3. **`_fetchPagesByDom`（改写）**：navigate 后**先 fiber**（`_pagesViaReact`），≥2 条直接返回；
   否则退回原 `<img>` 探针 25s 轮询（虚拟化下通常只有 3~5 张）。
4. **`_pagesViaReact`（新增）**：20s 内轮询 `_pagesByReactJs`，「数量连续 3 次不变且 ≥2」提前收。
5. **`_fetchChaptersByDom`（分页硬化）**：
   - 总预算 `chapterDeadline = now + 100s`（enqueue timeout 120s 留余量）；
   - 🔴 基准 `prevFirstHref` 改为**首页首行的 href**（旧代码为 `null` ⇒ 第一跳轮询第一拍就
     「以为改了」——读到的还是首页 → 新增 0 → 立刻 `break`，章节仍只一页）；
   - 🔴 上界从 `p <= pagesHint && p <= 40` 改为 `p <= 200`：`pages` 只是**可见数字按钮最大值**
     （Next-only 时 =1，旧写法循环根本不进）；
   - 终止靠四条：**控件消失 / 首行不再变化 / 本轮新增为 0 / 预算耗尽**；
   - 数字按钮点失败 → 改点 Next（`_clickNextPageJs`）；
   - 点击后由「固定等 1.2s」改为「**轮询最多 8s 等首行变化**」。

---

## 3. 反向验证（逻辑层，Node 跑**真实常量**）

工装：`%TEMP%\comix_fiber_test.js` + `%TEMP%\comix_js_syntax_test.js`（**不进仓库**，
从 `comix_client.dart` **正则抽出真实常量**再执行，避免副本漂移）。

| 用例 | 输入 | 期望 | 实测 |
|---|---|---|---|
| A 正向 | 页对象带 `bZ` ×3 | 恢复 3 图 | `{"ok":true,"count":3}` ✓ |
| B **故障** | `bZ` 改名成 `bZ_x` | 恢复 0（**证 A 依赖 `bZ`**） | `{"ok":false,"count":0}` ✓ |
| C 正向 | 页对象带 `url` + `q2` ×2 | 恢复 2（通用回退） | `{"ok":true,"count":2}` ✓ |
| D **故障** | `url` 在但缺 `q2` | 恢复 0（**证回退被 `q2` 守卫闸住**） | `{"ok":false,"count":0}` ✓ |

`_js_syntax_test`：9 个 JS 常量（`_browseProbeJs`/`_chaptersProbeJs`/`_adSweepJs`/`_clickPageJs`/
`_clickNextPageJs`/`_pageVerifyJs`/`_pagesProbeJs`/`_pagesByReactJs`/`_captureHookJs`）
**全部 parse 通过、0 语法错误**。

**新代码确实进产物**（A01 §4 口径：grep **字符串字面量**，不用私有标识符）：
`builds/mangrove/data/app.so`（20,693,896 B）里
`React fiber recovered` / `chapter paging budget exhausted` / `no pager control for page` /
`React fiber probe error` 各 **1** 命中；`app.so` mtime `22:45:29` > 源码 mtime `22:44:09`。

---

## 4. 门禁

`run_build_task.py`（托管 venv python：`.workbuddy\binaries\python\envs\default\Scripts\python.exe`）
→ **BUILD_OK**（pubget/analyze/build/install 全 rc=0）。

| 检查 | 结果 | 基线 |
|---|---|---|
| block-ops | PASS **108** | 108 |
| edit-check | PASS **216** / 0 fail（夹具替换，见下） | 219 |
| run-plan | PASS **31** | 31 |
| bootstrap | PASS **34** | 34 |
| glossary | PASS **26** | 26 |
| glossary-ui | PASS **30** | 30 |

🔴 **edit-check 216 vs 基线 219 的差**：**不是回归，是夹具**。
记录基线的 MDGH ch1 工程夹具 `ComicLibrary/projects/My Dragon Girlfriend Has Returned-1 [Asura Scans]/`
**已不在磁盘**（`ComicLibrary/projects/` 现为空，全工作区仅 `Ballonstranslator_store/` 下还有真实工程）。
本轮改用真实 FT 工程夹具（`Ballonstranslator_store/Manhwa/The Heroine Takes Everything/…json`），
**0 fail**；并**另测第二个 FT 夹具，两次 check 名集合逐字相同（均 216）** ⇒ 差值来自
「夹具是否含 Mangrove 自建特征」而非代码。待原夹具恢复后可复测 219。

---

## 5. 改动文件清单（均未提交）

| 文件 | 改动 |
|---|---|
| `Mangrove/lib/network/comix_client.dart` | 新增 `_clickNextPageJs` / `_pagesByReactJs` / `_pagesViaReact`；改写 `_fetchPagesByDom`（fiber 优先）；硬化 `_fetchChaptersByDom`（首行基准 / 上界 200 / Next 兜底 / 轮询 8s） |

## 6. GUI 人工验收步骤（本会话无渲染表面，只能交用户）

**comix.to**（先**完全退出 App**（含托盘）再重启；源只在启动 `doInit()` 加载，无文件 watch）：

1. 进任意漫画详情 → 预期章节**能翻到全部页**、翻译组 chips 数量**完整**（不再只有一页）；
2. 进任意章节阅读页 → 预期图片**远超 3 张**（整章全量）；
3. 若仍失败，回传 `logs.txt` 里 `ComixClient` 的
   `DOM: React fiber recovered N image(s)` / `DOM: page N M rows` /
   `page N not effective after wait` / `React fiber probe error` 相关行。

🔴 节点要求：**未封禁节点**（港/日/新/英等；美/印当前被封）——封禁页会抛 `COMIX_IP_BLOCKED`
并给中英双语「请切换节点」提示。
🔴 验收**通过前**勿对包子源点「检查更新」（上游若发布更高版本号且仍含旧选择器会覆盖 v1.2.4）。

## 7. 遗留 / 风险

- 阅读器页对象字段名是**压缩名**（`bZ`/`q2`），站方下次改构建可能漂移 ⇒ 已加 `q2` 守卫的通用回退，
  但仍需 GUI 实测确认；若 `bZ` 与 `q2` 同时改名，需重新逆向 reader chunk。
- 本会话 IP 已被 comix.to WAF 封（Python 客户端 403），**无法再静态取证**；fiber 方案未经真实浏览器验证。
- 遗留（非本轮域）：comix 详情成功但短 hid 报 `Comic has no chapters`（SSR 章节解析），列后续专项。
# P59 · Scrapling 抓取 comix.to 可行性实测报告

> 日期：2026-11-15　｜　类型：实测分析（P58 的后续验证）　｜　结论先行
> 样本：Full-Time Awakening · Ch.171（`/title/qqwrm-full-time-awakening/11735187-chapter-171`，101 页）
> 环境：Scrapling 0.5.1 隔离 venv（`<工作区>/_reference/apps/Scrapling/.venv`）+ patchright chromium + 7890 代理
> 事实口径：全部结论来自本机实跑，证据 JSON 在 `_reference/apps/Scrapling/_probe/`，可复现脚本在 `examples/comix_to_scraper.py`。**未实测的一律不写"可以"。**

---

## 0. 结论先行（TL;DR）

| 命题 | 结果 | 证据 |
|---|---|---|
| Scrapling 能否打开 comix.to 而**不触发 503 / CF 挑战**？ | ✅ **能**。单次 goto 首页 + 页内 pushState，全程 200，无 `Third-party`、无 `Just a moment` | `probe_comix_home.json`：home/detail 均 `state=likely_normal` |
| 能否拿到章节页与**全量正文图 URL**？ | ✅ **能**。101 个 `Go to page N` 按钮 → 101 个唯一正文图 URL，比率 **1.0** | `collect_comix_chapter.json`：`buttonCount=101, unique=101` |
| 能否把**图片字节**下载落盘？ | ✅ **能**。101/101 张 webp 落盘（24MB），页号无空洞、全部 `RIFF` 头 | 端到端实跑：首次 99/101（2 张读超时），加 3 次重试后 **101/101** |
| 相对 Mangrove 现有离屏 WebView 方案 | **更轻、更快、更可控**：一次浏览器会话拿 URL + 普通并发下载字节，约 25s 拿全 101 页 | 端到端 24.4s（重试轮） |
| 是否建议纳入 Mangrove？ | ⚠️ **技术完全可行，但需决策**：这是 Python 运行时 + 浏览器二进制（+100MB），与 Dart 架构割裂。建议作为**独立的外部抓取工具/备用取图通道**，不直接嵌进 App；Dart 侧仍走 A 方案（策略层借鉴）。 | 见 §4 |

**一句话**：上一轮 P58 判断"comix 取图需实测"的部分，本轮已实测并**证实可行**——关键不是更强的指纹伪装，而是**严格遵守 comix 的会话节奏（一次导航 + 页内路由）**，Scrapling 的 `page_action` 恰好是这种手法的理想载体。真正卡住 Mangrove 下载器的从来不是"库不够强"，而是"用错了请求姿势"。

---

## 1. 实测链路（四步，每步都有证据）

### 1.1 步骤一：单次导航进站，不触发拦截

- `StealthyFetcher.fetch("https://comix.to/", proxy=7890, network_idle=True)` —— **只调用一次**。
- 在 `page_action(page)` 内做后续一切，绝不再 `goto`。
- 结果：首页 `htmlLen=600699`（正常首页 ~600KB），`state=likely_normal`；title 链接、章节链接均能读到。
- **对照 A07c §11**：全新 profile 只导航一次首页仍可能 503——本轮实测未触发，说明当前出口/会话状态干净；但这是**概率性**的，不是永久保证。代码层面仍应遵守"命中 503 即退避、不重试不硬撞"。

### 1.2 步骤二：页内 pushState 到详情页 / 章节页

- 🔴 **踩坑实证**：pushState 必须分两步——先 Python 侧 `page.evaluate("(u)=>history.pushState({},'',u)", abs_url)`，再单独执行采集脚本。
  若把 pushState 塞进 `async` 收集函数的**参数**，patchright 参数序列化会把 `/title/...` 改写成 `file://<浏览器进程cwd>/title/...` → `SecurityError: cross-origin`（实测 3 次复现）。
- 🔴 **第二个坑**：Git Bash 下传 `/title/...` 作命令行参数会被 MSYS 转成 `D:/.../title/...`（POSIX 路径转换）。**必须传完整 `https://` URL**。
- 结果：章节页 `title='Full-Time Awakening · Ch.171'`，`htmlLen=66394`，正常渲染。

### 1.3 步骤三：DOM 树层级分析 + 全量 URL 采集

DOM 层级诊断（用户补充要求"多注意 DOM 树层级"）——不同页面结构不同，不能用一套选择器硬套：

| 页面 | 关键容器（tag.class / depth） | 说明 |
|---|---|---|
| 首页 | `main.layout.layout--top` (d=3) → `section.section` (d=5) → `div.swiper-wrapper` (d=7, 50 kids) | 首页是多个 swiper 横滑列表 |
| 详情页 | `main.layout.layout--single` (d=3) → `article.mpage` (d=4) → `section.mpage__chapters` (d=7) | 章节列表在 `article.mpage` 内；链接 `/title/<hid>/<id>-chapter-N` |
| 章节页 | `img` 挂 `[class*=rpage]`；进度条 `[aria-label="Go to page N"]` 共 101 个 | 正文图虚拟列表只挂 3 张 |

采集手法（A25 实证仍成立）：
```
MutationObserver(documentElement, {childList,subtree,attributes:['src','currentSrc','data-src']})
  → 点全部 [aria-label*="Go to page N"]，每页 120ms 挂载延时，边点边收 src
  → 正文图无扩展名（https://pq4.<随机域>/hi/<token>），按 class*=rpage / alt="Page N" 认
结果：buttons=101 → unique=101（比率 1.0），alt 为 Page 1..101
```
**动态加载延时参数**（用户要求调优）：初始渲染等待 `wait_ms=3800`（含 SPA 路由 + 首批虚拟列表）、每页点击 `step_ms=120`、收尾 `1200ms`。实测这个组合稳定拿到 101/101；低于 ~80ms 会漏页。两个参数已暴露为脚本参数可调。

### 1.4 步骤四：图床字节下载 —— 纠正一条旧认知

- 🔴 **新事实（推翻 P58/A25 的"带 Referer 直连"假设）**：正文图床对请求头极敏感：
  | 请求头组合 | 结果 |
  |---|---|
  | 带 `Referer: https://comix.to/` + `Sec-Fetch-Dest:image` | ❌ **403** |
  | 带 `page.request.get`（共享浏览器 cookie/指纹） | ❌ 403 |
  | 页内 `fetch(u, {credentials:'include'})` | ❌ `Failed to fetch`（CORS + WAF） |
  | **只带普通 UA + Accept，无 Referer / 无 Sec-Fetch** | ✅ **200，`image/webp`，RIFF 头，175514 B** |
- ⇒ 结论：**图床把 comix 的 Referer / Sec-Fetch 特征当成第三方 app 信号**；朴素请求反而过。下载走 7890 代理，8 并发，3 次重试救回网络抖动。
- 端到端：`101 按钮 → 101 URL → 首轮 99 落盘（2 张读超时）→ 重试后 101/101`，24MB，`missing=[]`，`all_RIFF_webp=True`。

---

## 2. 对 P58 三套方案的修正

| 方案 | P58 判断 | P59 实测后修正 |
|---|---|---|
| A · Dart 内建策略层 | ✅ 首选 | ✅ **不变**，仍是 Mangrove 主路线（见任务二）；comix 的"请求姿势"经验可写进配置注释 |
| B · Scrapling sidecar | ⚠️ 仅实测后再定 | 🟢 **实测通过，升级为"推荐作为独立备用取图通道"**：技术闭环、25s/章、无拦截。但仍是外部 Python 工具，不嵌 App；是否产品化由用户定 |
| C · 整体替换 | ❌ 不推荐 | ❌ 不变 |

---

## 3. 复用资产（可直接跑）

| 文件 | 用途 |
|---|---|
| `_reference/apps/Scrapling/examples/comix_to_scraper.py` | 正式采集器：一次导航 + pushState + 页按钮全点 + 无 Referer 并发下载 + 断点续传 + 3 次重试 |
| `_reference/apps/Scrapling/_probe/probe_comix_home.json` | 首页/详情页 DOM 层级 + 三态判定证据 |
| `_reference/apps/Scrapling/_probe/collect_comix_chapter.json` | 101 URL 采集证据（含 alt=Page N） |

复跑命令（注意传完整 URL，避免 Git Bash 路径转换）：
```bash
cd "<工作区>/_reference/apps/Scrapling"
.venv/Scripts/python.exe examples/comix_to_scraper.py \
  "https://comix.to/title/qqwrm-full-time-awakening/11735187-chapter-171" \
  "C:/Users/Administrator/AppData/Local/Temp/comix_out" --workers 8
```

---

## 4. 边界与风险

1. **概率性拦截**：本轮一次成功不代表永久。comix 的 503 是会话节奏判定，跑多了仍可能命中；脚本不硬撞、不重试导航，命中即如实报错。
2. **无 chapter 列表自动化**：本轮从已知章节 URL 入手。章节列表的 20 条分页（A07c §8）未在本脚本实现——需要时按详情页 `.mpage__chapters` + 翻页按钮扩展。
3. **合规**：BSD-3-Clause 允许技术使用，但绕过站点 WAF 是否违反 ToS 是业务/法务判断，本报告只做技术验证。
4. **体量**：浏览器二进制在 `%LOCALAPPDATA%/ms-playwright`（patchright chromium-1248），未塞进工作区；venv 265MB 在 `_reference` 共享参考层，不进任何 git 仓库。
5. **图床域名轮换**：URL 里的随机域名（`pq4.thebrandonblog.site` 等）会变；脚本按 `<token>` 动态取，不硬编码域名。

---

## 5. 交付判定

- [x] 单次导航不触发 503/CF —— 实测 `state=likely_normal`
- [x] DOM 层级逐页分析 —— 首页/详情页/章节页三类结构已记录
- [x] 动态加载延时参数可调并经实测 —— `wait_ms=3800` / `step_ms=120`
- [x] 全量 URL 采集 —— 101/101，比率 1.0
- [x] 图片字节落盘 —— 101/101，无缺页，webp 格式校验通过
- [x] 可复现脚本 —— `examples/comix_to_scraper.py`
- [ ] 产品化集成（是否做 sidecar / 是否接进 Mangrove 下载器）—— **待用户决策**

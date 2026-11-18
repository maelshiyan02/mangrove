# P58 · Scrapling 借鉴与漫画源配置升级可行性分析

> 日期：2026-11-15　｜　类型：可行性分析　｜　结论先行
> 范围：评估 Scrapling（D4Vinci/Scrapling 0.5.1）是否适用于 Mangrove 漫画源配置升级，能否改善 comix.to 高频封禁、包子漫画分页漏抓两大痛点。
> 事实口径：Scrapling 侧结论来自本地源码逐行读取（已隔离安装）；Mangrove 侧结论来自 `comic_source/*.js` 的实测注释与实现。**所有未实测项均显式标注「需实测」，不臆造能力。**

---

## 0. 结论先行（TL;DR）

| 问题 | 结论 | 置信度 |
|---|---|---|
| Scrapling 能否直接接入 Mangrove？ | **不能**。它是 Python ≥3.10 库，Mangrove 抓取在 Flutter/Dart + JS 源配置里跑，无 Python 运行时；`curl_cffi`/`patchright`/`lxml` 全是 Python 原生绑定。 | 高（源码事实） |
| 它的能力命中我们的痛点吗？ | **部分命中**。按域名自适应限速＋封禁退避、TLS 指纹伪装、代理轮换、请求指纹去重——直接命中 comix.to 的高频封禁；但**解决不了**「站点下架接口转 app 侧」这种业务层收缩。 | 高 |
| 对「150 页只抓 50 页」有帮助吗？ | **基本没有**。Scrapling 的 checkpoint 只恢复「已入队未完成」的请求；从未被解析出来的页不在队列里，恢复后还跳过 `start_requests()`，**不会自动补抓**。这是我们自己的分页解析 bug，得自己修。 | 高（源码事实） |
| 值得借鉴吗？ | **值得，但借的是机制不是代码**。推荐 A 方案（Dart 内实现策略层）先行，B 方案（Scrapling sidecar 服务）用于 TLS 指纹攻坚并需实测，不推荐 C（整体替换）。 | 中高 |
| 是否要装到共享库？ | **已装**。隔离 venv 落在 `_reference/apps/Scrapling/`，作为跨项目参考依赖，未污染任何项目。 | 高（已执行） |

**一句话**：Scrapling 是一面好镜子——它把我们散落在各 JS 源里的「限速/重试/代理/进度」经验收敛成了统一策略层；但它是 Python，且最强项（TLS 指纹、CF 求解）在我们这两个源上要么已被离屏 WebView 等价解决，要么需实测才能替代。**真正该抄的是它的「策略与业务分离」架构和「封禁即退避 + 遵守 Retry-After」的克制，而不是把整个库搬进来。**

---

## 1. 下载与隔离安装记录（可复现）

| 项 | 值 |
|---|---|
| 官方仓库 | `https://github.com/D4Vinci/Scrapling`（作者 Karim Shoair / D4Vinci） |
| 许可证 | BSD-3-Clause（可商用、可修改，需保留版权声明） |
| 版本 / commit | `0.5.1` ／ `bb223f2f5fc8f743772751a5ce283ef7851ca6be`（2026-11-11 19:04 +0200） |
| 源码落点 | `<工作区>/_reference/apps/Scrapling/`（699 文件 / 12MB，`git clone --depth 1`） |
| 隔离环境 | 同目录 `.venv/`（Python 3.13.14，265MB / 2415 文件），`pip install -e ".[fetchers]"` |
| 安装源 | 经 `127.0.0.1:7890` 代理，scrapling 0.5.1 + curl_cffi 0.17.0 + playwright 1.65.2 + patchright 1.64.4 + browserforge 1.2.4 等 |
| 复用方式 | `<工作区>/_reference/apps/Scrapling/.venv/Scripts/python.exe`，不进任何项目、不污染全局 |
| 安装验证 | `Selector(html).css('.book h3::text').getall()` → `['海贼王','火影']`；`fetchers` 导入 OK |

**⚠️ 关键版本陷阱**：网上流传的 Scrapling 技能文档/SKILL.md 多为 0.3.x，写的是 `DynamicFetcher`、`PlayWrightFetcher`、`auto_match=True`。**0.5.1 里这些全都不存在**（实测 `ImportError: cannot import name 'DynamicFetcher'`）。真实 API 只有 `Fetcher` / `AsyncFetcher` / `StealthyFetcher` / `FetcherSession` / `StealthySession` / `AsyncStealthySession` / `RemoteSession`，自适应参数是 `adaptive=True`（非 `auto_match`）。**任何后续引用必须以本地源码为准，不得照抄网络文档。**

> 浏览器二进制未安装（避免 100MB+ 产物进工作区）。需要实测 StealthyFetcher 时在该 venv 内单独跑 `scrapling install`。

---

## 2. Scrapling 能力事实（源码逐行核对）

### 2.1 三层抓取器

| 抓取器 | 底层 | 反爬能力 | 默认 |
|---|---|---|---|
| `Fetcher` / `AsyncFetcher` | curl_cffi | TLS/JA3 指纹伪装 `impersonate="chrome"`、HTTP3 可选、`stealthy_headers=True` 自动补 Referer | 同步/异步 |
| `StealthyFetcher` | patchright（改版 Playwright） | 指纹伪装启动参数、`solve_cloudflare` 可选 | `solve_cloudflare=False` |
| `RemoteSession` | CDP 接真实浏览器 | 复用真人浏览器上下文 | 需外部浏览器 |

**Cloudflare 真相**：`solve_cloudflare` 默认是 **关** 的；开启后是 `_cloudflare_solver()` 用 DOM 检测 + 模拟点击 checkbox（最多 3 次尝试），**不是第三方打码服务，也不保证成功**（`_stealth.py:107-222`、`_validators.py:143`）。宣传语「bypass all levels of Cloudflare」要打折看。

### 2.2 自适应限速（`spiders/throttle.py`）—— 最值得抄的部分

```
target_delay = latency / target_concurrency
new_delay    = max((current_delay + target_delay) / 2, target_delay)
被封禁时: penalty = Retry-After秒数 或 current_delay × 2.0
new_delay    = max(new_delay, penalty, current_delay)   # 封禁永不加速
new_delay    = clamp(new_delay, floor, max_delay)        # floor=max(配置延迟, robots Crawl-delay)
```

- **按域名**维护延迟表（`delays: Dict[str,float]`），互不牵连。
- 默认：`start_delay=5s`、`max_delay=60s`、`target_concurrency=1`、`block_backoff=True`；但 `autothrottle_enabled` **默认 False**，必须显式开。
- **无随机抖动**（源码无 jitter）——这是它的短板，真实反爬场景固定间隔反而可被识别。

### 2.3 代理轮换（`engines/toolbelt/proxy_rotation.py`）

- 内置**仅轮询**（`cyclic_rotation`），随机/粘性需自定义策略函数。
- 失败识别靠错误字符串（`is_proxy_error()`），失败不主动拉黑坏代理，只靠轮询自然换到下一个（retries=3, retry_delay=1s）。

### 2.4 断点与缓存（`spiders/checkpoint.py` / `cache.py`）

- checkpoint 存「待处理请求 `requests` + 已见指纹 `seen`」，`pickle` 原子落盘（`.tmp` → `replace`），每 300s 一次；崩溃保留、正常完成清理。
- **关键限定**：只恢复仍在队列里的 Request；恢复后跳过 `start_requests()`。→ **对「解析阶段就漏掉的页」无能为力**（详见 §3.2）。
- `cache.py` 是开发期响应回放（`development_mode=True` 才启用），与断点续爬无关。

### 2.5 自适应选择器（`parser.py` + `core/storage.py`）

- `auto_save=True` 存元素结构特征（tag / path / attributes / 父 / 兄弟 / 文本）进 SQLite；站点改版后 `adaptive=True` 用 `difflib.SequenceMatcher` 多维打分（阈值默认 40%）全页重定位。
- 对「局部属性/class 变化」有自愈价值；对「API 接口整体下线」无效——因为根本没有 DOM 可定位。
- 阈值语义硬编码、需按站点调校，**效果需实测**。

### 2.6 并发/重试/robots

- 默认并发 4、`concurrent_requests_per_domain=0`（不单独限域）、`max_blocked_retries=3`、`robots_txt_obey=False`。
- 网络异常只计数不重试；被封禁才重试（复制请求、降优先级、去代理、重排）。
- HTTP 层 `timeout=30s`、`follow_redirects="safe"`（SSRF 防护）、`max_redirects=30`。

---

## 3. 对照 Mangrove 两大痛点

### 3.1 comix.to：高频请求被识别拦截

**现状证据**（`comic_source/comix_to.js` 头部注释 + 实现）：
- 2026-10 起整站（含封面域）上 Cloudflare；图片 CDN 轮换域（`*.joshuanotes.site` 等）按 **TLS 指纹** 拦截 WAF，`dart:io HttpClient` 带任何头都 403。
- 出口 IP 被 comix 自家 WAF 拦时重定向到 `/@waf/challenge`（HTTP 200 的 9.4KB 滑块页），Dart 桥 ~1s 内识别抛 `COMIX_IP_BLOCKED`，按 IP 名单切节点。
- API 签名 token 绑定**完整 query string**，改任何参数即失效 → 分页必须让 SPA 自己发；阅读器是 Swiper slides 虚拟化，DOM 兜底只能拿 3~4 张。
- 现有解法：图片走 `viaWebview: true` 由离屏 WebView 取字节；元数据走详情页 SSR；章节/图片经 Dart 桥截获 SPA 的 `/api/v1/*`。

**Scrapling 能给什么**：

| 能力 | 对 comix.to 的价值 | 判定 |
|---|---|---|
| curl_cffi TLS 指纹伪装 | 理论上能替代离屏 WebView 取图（更轻、更快），但 comix 的 WAF 是专有 TLS 指纹策略，**必须实测能否过** | 中（需实测） |
| 自适应限速 + 封禁退避 | **直接可用理念**：给下载器加按域名退避，命中 WAF 时翻倍降速、遵守 `Retry-After`，从源头减少触发拦截 | 高（理念可移植） |
| 代理轮换 | 我们已有 IP 名单切换；Scrapling 仅轮询、不拉黑坏节点，比我们现有逻辑弱，**不建议采用** | 低 |
| CF checkbox 求解 | 我们已有「离屏 WebView 自动验证」自愈通道，且 Scrapling 求解器不保证成功，**不替代** | 低 |
| SPA 签名 token | 库帮不上——这是「必须真实浏览器执行 JS 才能拿到」的业务约束，Scrapling 也得靠 WebView/CDP | 无 |

**结论**：comix.to 的**根因是 TLS 指纹 + 专有 WAF**，Scrapling 的指纹伪装值得作为「离屏 WebView 之外的第二取图通道」实测；但**真正能立刻降低封禁率的是把它的「自适应退避」抄进我们的下载调度器**——这是纯逻辑、零依赖、可单测。

### 3.2 包子漫画：150 页只抓 50 页

**现状证据**（`comic_source/baozi.js` 注释 + `loadEp` 实现）：
- 站点把每章再分页（标题「第 N 话 (a/b)」，URL `0_<ep>.html` / `0_<ep>_2.html` …），每页约 50 张且相邻页有重叠 → 旧实现只取首页恒定 50 张。
- 更隐蔽的坑：阅读页 `comicId` 必须带 per-comic 后缀（`<cid>_9lavj0`），否则**第 2 页起被钳制回第 1 页** → URL 去重后 `added=0` 提前 break → 截断成 50 页（实测「秘密小姐」第 11 话只显 50、实有 144 页）。
- 现有解法（v1.2.9）：首页 HTML 翻页链接现取后缀并持久化、`effectiveId` 拼接、逐页抓取 + URL 去重保序、多域名故障转移、镜像残缺串错书识别、`onImageLoad` 链式穷举图床、兜底官方 app 域。
- 站点趋势：逐步下架网页源接口、转 app 侧数据接口（`appcn.baozimh.com`），最新章只有 app 完整。

**Scrapling 能给什么**：

| 能力 | 对包子漏页的价值 | 判定 |
|---|---|---|
| checkpoint 断点续爬 | **无效且有害**：checkpoint 只恢复已入队 Request；漏掉的 100 页从没被解析出来、不在队列里，恢复后还跳过 `start_requests()` → 永远不会补抓 | 否 |
| 自适应选择器 | 只对「DOM 结构变化导致解析不到图」有用；包子是「分页链接解析 + id 后缀钳制」逻辑 bug，选择器救不了 | 低 |
| 自适应限速 | 与漏页无关（漏页不是被封，是钳制） | 无 |
| 外部 app 接口调用 | 库帮不上——「站点下架网页接口转 app 侧」是数据可得性问题，需要逆向 app 接口或换数据源 | 无 |

**结论**：这是**我们自己的分页完整性 bug**，Scrapling 帮不上。真正需要的是一个**「期望页数 vs 实收页数」对账机制**：每章抓完后拿 `pager.total`（或 app 接口返回的页数）与 `collected.length` 比对，缺口显式标记 `missing_pages` 并按章节页号**重新入队补抓**——这正是我们 `lib/foundation/missing_pages.dart` 已有的概念，缺的是把它接到「分页循环」上而非只接下载失败。

> 顺带指出：P42/P54 修复里 `if (pgAdded===0) break` 是「无新图即到底」的启发式，在「第 2 页起被钳制回第 1 页」时会误判为到底。应改为「只要 `page <= total` 就必须继续，`added=0` 只记异常不 break」。

---

## 4. 三套落地方案与推荐

| 方案 | 做法 | 收益 | 代价/风险 | 推荐 |
|---|---|---|---|---|
| **A · 纯借鉴（Dart 内建策略层）** | 在 `comic_source` 配置契约里增加声明式 `rateLimit` / `pagination.expectTotal` / `retryPolicy` 字段，由 Dart 下载器统一执行：按域名自适应延迟 + 封禁翻倍退避 + `Retry-After` + 分页对账补抓 | 零 Python 依赖；可单测；两个痛点都触及；配置升级一步到位 | 需改配置契约 + 下载器，中等工作量 | **✅ 首选，先做** |
| **B · Scrapling sidecar 服务** | 隔离 venv 里用 FastAPI 包一层 `StealthyFetcher`，Mangrove 本地 HTTP 调用，作为「comix 取图第二通道」 | TLS 指纹伪装能力可直接用；与 Dart 解耦 | 部署重（浏览器二进制 100MB+）；跨进程；**过 WAF 成功率未实测**；启动慢 | ⚠️ 仅在 A 不够时实测后再定 |
| **C · 整体替换为 Python 抓取后端** | 把 JS 源配置全改成 Scrapling Spider | 统一框架 | 与现有 Flutter 架构割裂；源配置生态废弃；app 接口/签名 token 问题依旧；风险极高 | ❌ 不推荐 |

**建议执行顺序**：A（策略层 + 分页对账，可验收）→ 若 comix 取图仍不稳，再对 B 做**限定时长的可行性实测**（只测「Scrapling 能否取到 comix 图片字节」这一个命题，成功才继续）。

---

## 5. 建议的漫画源配置升级项（A 方案细化）

> 目标：把散落在 20+ 个 `comic_source/*.js` 里的限速/重试/分页经验，收敛为**声明式配置 + 引擎统一执行**。

| 配置项 | 语义 | 借鉴自 | 验收判据 |
|---|---|---|---|
| `rateLimit.perDomain` | 每域名初始延迟 / 上限 / 目标并发 | `AutoThrottle` start=5s/max=60s/concurrency=1 | 故障注入：命中 403 后退避翻倍且遵守 Retry-After；正常 2xx 后按时延收敛；不同域名延迟互不影响 |
| `rateLimit.enableAdaptive` | 是否启用自适应（默认开，替代 Scrapling 默认关） | `autothrottle_enabled` | 关闭时延迟恒等于 floor |
| `retry.blockedBackoff` | 封禁退避倍数（默认 2.0）+ `Retry-After` 优先 | `BLOCK_BACKOFF_FACTOR` | 注入 Retry-After=3s，断言实际等待 ≥3s |
| `pagination.expectTotal` | 章节期望页数来源（pager.total / app 接口字段） | 我们自己的缺口 | 断言：total=150、实收=50 时标记 100 页 missing |
| `pagination.onEmptyPage` | `added=0` 且 `page<=total` 时记异常继续，不 break | 包子 P54 教训 | 故障注入「第 2 页起钳制回第 1 页」，断言不再提前 break、缺口被记录 |
| `dedupe.key` | 请求/图片指纹（URL 规范化 + 页码） | `request fingerprint` SHA1 | 跨页重叠图只收一次、保序 |

**与现有代码的关系**：`lib/foundation/missing_pages.dart` 已有缺页概念，`baozi.js` 已有 `pagerOf`/`detectSuffix` 自愈——升级是**把它们接进统一策略层并补断言**，不是推倒重来。

---

## 6. 风险与边界

1. **合规**：Scrapling BSD-3-Clause 允许商用与修改；但用它绕过站点 WAF 是否违反目标站 ToS 是**业务/法务判断**，本分析只做技术评估，不替用户决策。
2. **能力边界**：Cloudflare / 专有 WAF 的对抗是动态博弈，任何「绕过」都不承诺长期有效；宣传文案不可当验收标准。
3. **未实测项清单**（不得当成已验证）：Scrapling 取 comix 图片字节是否成功；CF 求解成功率；自适应选择器在包子 DOM 上的阈值；B 方案跨进程延迟。
4. **产物体量**：`.venv` 265MB 已在 `_reference`（工作区内但属共享参考层），不进任何 git 仓库；浏览器二进制按需另装，勿塞进工作区（GLOBAL_RULES §9）。

---

## 7. 交付物与后续

- 参考库：`<工作区>/_reference/apps/Scrapling/`（源码 + 隔离 venv，可直接 `python.exe` 复用）。
- 本文档：`<项目根>/.agent/documents/analysis/P58-ANALYSIS-Scrapling借鉴与漫画源升级可行性-20261115.md`。
- **未改动任何生产代码**（本次仅调研 + 安装 + 分析）；是否进入 A 方案实施由用户决定。
- 若实施 A，建议新建 `P59-PLAN-漫画源策略层与分页对账-YYYYMMDD.md`，按阶段带故障注入断言推进。

# A25 · 跨源补章：comix.to 实操与可复用套路

> 触发场景：主源章节落后于原作最新（包子 152 vs 原作 157），需要从第二个源
> 补几话，并让它们**和主源并进同一本漫画**。
> 首次落地：2026-10-27，《灭门家族的重生者》补 153–157（704 张）。

---

## 1. 先判「能不能补」——三种拦截，别硬撞

| 拦截 | 表现 | 结论 |
|---|---|---|
| Cloudflare 托管挑战 | 403 + `cf-mitigated:challenge` | 真实浏览器能过（`--headless=new` 就够） |
| 自家 WAF / 第三方判定 | 200 但 HTML 只有壳；或整页 `Third-party apps` | 换出口 / 等冷却；重试与清 cookie 只会放大封禁 |
| **API 响应加密** | `{"e":"…"}` 单个字段 | 拿到也用不了 —— **只能让页面自己解密**（走 DOM） |

comix.to 三种都占：首屏空壳、章节 API 要 SPA 现算的 `_=` token、**响应体
还是加密的**。所以"用 requests 拼 API"这条路彻底不通，只能开真浏览器。

---

## 2. comix.to 的三条硬事实（换别的源也先验证这三条）

1. **章节列表拿不到，但单章 URL 可穷举不了** —— 所以不要试图先拿列表。
   用**已知的最新一话 URL** 当入口，点 `aria-label="Previous chapter"`
   倒着走：一个入口 URL 就能补齐任意 N 话。
2. **阅读器是虚拟列表**，滚动只挂当前屏 1–3 张（曾经滚 40 次只拿到 16 张，
   误以为章节就 16 页）。真正的开关是进度条：每页一个
   `aria-label="Go to page N"`（或 `.rpage-progress__seg`），**全套点一遍**
   + `MutationObserver` 收 `src`。
   判据：**收到的张数 == 页按钮数**。不等就是没点完。
3. **正文图 URL 没有扩展名**：`https://1xx.<随机域名>/hi/<token>`。
   拿 `.jpg|.webp` 过滤会把正文全过滤掉（曾经 0 张）。用
   `class*=rpage` 或 `alt="Page N"` 判。图床**域名会轮换**，但**直连可下**，
   不需要代理（页面本身要代理）。

---

## 3. 落地脚手架（`tools/`）

| 脚本 | 干什么 |
|---|---|
| `comix_cdp_probe.py` | 只探测：导航 + 抓所有 JSON 响应，输出 URL 与顶层结构。**先跑它**，别一上来写下载器 |
| `comix_cdp_scrape.py` | 通用抓取：`links` / `images` / `pages` 三种模式，带截图排查 |
| `comix_to_download.py` | 成品：翻章 + 点页按钮 + 并发下载落盘 |
| `merge_external_chapters.py` | 把补来的章节并进 `local.db`（校验有图才写） |
| `tag_chapter_languages.py` | 给补来的章节标语言（记录表第二落点） |

### CDP 三件套（每一条都是踩坑换来的）

```python
# 1. 持久 profile：每次新建 profile 等于每次重过一次 WAF
--user-data-dir=%TEMP%/comix_dl_profile

# 2. 导航后**轮询**到正文出现，别固定睡 N 秒
#    （固定睡 6s 时 img=0、正文 0 字，因为踩在空壳上）

# 3. Runtime.evaluate 用 returnByValue + awaitPromise，
#    长脚本用 `(async function(){...})()` 包起来
```

---

## 4. 并进同一本漫画：key 坐标系必须对齐

`local.db.comics.chapters` 是扁平 `{key: 标题}`，**key 的坐标系必须和主源
一致**，否则详情页的"已下载"判定（靠 `chapterDirectoryName` 反算目录名）
失效 —— 磁盘上有图却显示未下载。

```
包子：key "151" → 标题「第152话」→ 目录 `[zh-Hans] 151 [baozimh]`
comix：key "152" → 标题「第153话」→ 目录 `[en] 152 [Asura Scans] [comix.to]`
```

统一规则：**key = 话号 - 1**。两个源落进同一套 0-based 坐标系，既不撞也
不错位。`merge_external_chapters.py` 就是按这个规则算 key 的。

---

## 5. 别踩这些

* **不要靠章节页的 `alt` 判"翻过去没有"**：翻页后 alt 会复用/缺失，靠它计数
  会停在第 3 页（实测）。用「累加当前所有 `src`、连续 N 拍无新增才收工」。
* **不要用 `documentElement.scrollHeight` 判滚动进度**：阅读器滚动在内部容器，
  `documentElement.scrollHeight` 恒等于视口高（804），`atEnd` 永远真。
* **不要拿 `data`（当前视图）当章节并集的底**：网络模式下 `data` 就是
  `online`，自己和自己合 = 没合，跨源补的话会被合并掉。
* **图床域名会变**，别把域名写进白名单；按 `class` / `alt` 认图。

---

## 6. 验收口径（缺一条就不算完成）

1. 逐章 `图片张数 == 页按钮数`；
2. 页号 `0..n-1` 无空洞；
3. `chapters` 与 `downloadedChapters` 条数一致、数值连续；
4. 语种标注条数 == 章节数（`chapter_languages`）；
5. 详情页能点开、能翻页（GUI 验证，脚本验不了渲染）。

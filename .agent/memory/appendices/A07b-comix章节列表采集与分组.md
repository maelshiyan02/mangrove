# A07b · comix.to 章节列表采集 · 分组 · 翻页 · 同组重复 bug 实证

> **触发时机**：碰 comix.to 的**章节列表采集 / 分组下拉 / 翻页 / 下载面板分组计数**之前。
> 上级索引：`../MEMORY.md`（A07）｜ 基础配置（WAF / token / WebView 取字节）见 `A07-comix源.md`。
> 创建：2026-10-17，由 503jz「同组重复」bug 排查驱动，内容从 A07 扩篇。

---

## 1. 🔴 章节列表「分组下拉」是真实可用的分组维度（不是装饰）

- 详情页章节区 `SECTION.mpage__chapters` 顶部有 `button.ubtn`（文案 "All groups"）+ `.fdrop__pop` 下拉菜单。
- 菜单项结构：`.fdrop__pop--menu` 内 `.fdrop__item`（role=menuitemradio）。
- 选中组 → URL 变为 `?group_id=N`：
  - `N=0` = 网页标签 "Unknown group"；`N>0` = 具体翻译组。
- 实测 503jz 共 **14 个选项**：All groups / Unknown group / EZManga / Lua Comic / Luna Toons /
  MagusManga / Nuviatoon / Nyx Scans / Reset Scans / RinkoComics / Rokari Comics / UToon /
  Valir Scans / Violet Scans。
- **关键规则**：`?group_id=N` 过滤后列表长度大幅缩短（单组最多 38 行）→
  **先切组再翻页，可彻底绕开「长列表翻页卡顿」**（见 §2）。
- 切换组后计数文案形如 `Showing X to Y of Z items`（Z = 该组真实条目数）。

## 2. 🔴 翻页卡顿是真实通用问题（非偶发），会导致只采到部分章节

- 现象（用户实测）：章节列表翻到第 21 页时卡住，手动点一下才脱离。
- 代码实证（`comix_client.dart`）：`_fetchChaptersByDom`（L1784）点 `button.npager__num` 翻页，
  轮询首行 `a.mchap-row__primary` 的 href 是否变化（L1852-1863，最多等 8s）。
  - 站方对章节接口做了**加密**，SPA 要先解密再渲染，8s 内首行没变 → 打日志
    `DOM: page $p not effective after wait, stopping`（L1868）→ **直接 break**，本次只采到部分页。
  - 代码注释（L1849-1851）**已自我承认**旧实现 1.2s 等待不够、会提前 break 只采一页；
    现已放宽到 8s，但线上日志仍出现 `page 2 not effective`（加密解密更慢时 8s 仍不够）。
- **后果链**：残缺采集（如只采到 20 行 / 5 话号）→ `enrichComicChapters` → `mergedWith`
  按 chapterKey 并集「只增不减」→ 本地库逐步累积出不完整又被反复补充的脏数据。
- **规避（用户建议，已验证有效）**：翻页前先用 §1 的 "All groups" 下拉切到单翻译组，
  列表变短，翻页次数骤减，卡顿概率大幅下降。

## 3. 🔴 源站「无组内重复」——下载面板"同组重复"是 Mangrove bug

- CDP 直连（见 §6）逐组过滤并读 `Showing X to Y of Z items`，503jz 各组建真实条目数：
  - Lua Comic=38、MagusManga=37、Valir Scans=37、Nyx Scans=37、Rokari Comics=37、
    EZManga=34、Luna Toons=34、RinkoComics=34、Nuviatoon=32、Violet Scans=25、
    UToon=21、Reset Scans=4、Unknown group=1、All groups=371。
  - **Lua Comic 源站仅 38 章、API/DOM 验证 dupes=[]（组内无重复）**。
- 但 Mangrove 本地库（实时 `data/local.db`，连 WAL 读取）503jz：
  - **38 个话号、375 条 version 记录**，却含 **4 处 intra-(组,话) 重复**：
    - `Lua Comic` 的 **Ch.35 / Ch.36 / Ch.37 各 ×2**（实计 **41 条**，应 38）
    - `Valir Scans` 的 **Ch.34 ×2**（实计 38 条，应 37）
  - ⇒ 正好对应下载面板"Lua Comic 显示约 40 章（实际 38）"的用户投诉。
- 每条重复都是**两条不同 chapterKey 的记录并存**：
  - 一条 `{group:"Lua Comic", lang:"en", title:"Ch.35", key:"https://comix.to/.../11370807-chapter-35", uploadedAt:0}`
  - 另一条 `{group:"Lua Comic", title:"Ch.35", key:""}`（**无 lang、无 uploadedAt** → chapterKey=""）
  - 二者 chapterKey 不同 → `mergedWith`（见 §4）按 key 去重时当成两条独立版本，**全部保留**。

## 4. 🔴 根因定位（代码）

- **采集侧**：`comix_client.dart:_fetchChaptersByDom`（L1784）翻页遇 `page N not effective`
  直接 break（§2）→ 残缺页集合；单次 run 内仅按 `href` 去重（L1886-1893），
  跨 run 的"半截采集"会被 `mergedWith` 累加。
- **合并侧**：`models.dart:ComicChapters.mergedWith`（L774）版本化分支按 **`chapterKey` 做并集**
  （同 key 保留本地值，异 key 并入）。它**没有按 (group, chapterNumber) 做逻辑去重**，
  于是「URL-key 版」与「空 key 版」同一话同一组被当成两个版本共存。
- **展示侧**：`actions.dart:_buildDownloadSections`（L593）按 `scanlationGroup` 分节并
  `items: allVersions`（每个 version 一条）→ 面板计数 = 全部 version 条数，
  重复 version 直接放大显示（Lua Comic 41 / 面板约 40）。
- **次要显示问题**：`actions.dart:629` 把无组名兜底写成 `"Unknown group".tl`，
  但源站 `group_id=0` 那 1 行其 `.mchap-row__uploader` 显示 **"Uploaded by NUVIATOON"**
  （§5）→ 正确组名应是 **NUVIATOON**，"Unknown group"标签不准确。

## 5. 🔴 "Unknown group" 标签误导：真实组名藏在 uploader 字段

- `?group_id=0`（网页 "Unknown group"）过滤后仅 1 行 **Ch.32**，
  其行内 `.mchap-row__uploader` 文案为 **"Uploaded by NUVIATOON"**。
- ⇒ comix 的分组下拉把这一行标成 "Unknown group" 本身就是**不准确的**；
  真组名应取自 **uploader 字段（NUVIATOON）**。
- 影响：Mangrove 若照搬 "Unknown group" 标签会在下载面板把 NUVIATOON 的章节归错组。

## 6. 取证工装与反向验证方法（不靠截图，程序化）

- **CDP 直连**：`C:\Temp\cdp_lib.js`（复用 `C:\Temp\comix_profile` 带会话 profile，
  绕过 ABE / Chrome 155 锁文件；`--disable-blink-features=AutomationControlled`）。
- **章节 API 不可直接复现**：直接调 `/api/v1/manga/{hid}/chapters` 返回 `403 Invalid token`
  （token 绑定完整 query，不可复用）；SPA 自发的 API 在当前 headless 环境未触发 →
  **改用 DOM 行计数 + 本地 DB 交叉取证**。
- **DB 取证**：`data/local.db` / `details_cache.db` 须连同 `-wal` 拷贝后查询，才看得到实时数据。
- **反向验证纪律**：所有结论来自程序化读取（计数文案 / DOM 行 / DB JSON），截图仅作复核，
  不凭截图下结论（呼应 A02）。
- ⚠️ `details_cache.db` 现存 503jz 记录组构成与 local 不一致（疑似旧缓存/被覆盖，
  其内 `title` 字段甚至指向另一部漫画），**不作为干净对照基线**；干净基线以源站 CDP 实测为准。

## 7. 当前结论与下一步（未写回代码）

- **结论**：「同组重复」是 Mangrove 自身 bug（残缺翻页采集 + `mergedWith` 仅按 chapterKey
  并集 + `_buildDownloadSections` 按 version 计数），源站无此现象。
- **修复方向（待用户确认后再写回）**：
  1. `mergedWith` 增加「(group, chapterNumber) 逻辑去重」或归一化空 key；
  2. `_fetchChaptersByDom` 翻页失败时不直接 break，改为重试/续采或标记"采集不完整"；
  3. 下载面板优先用 uploader 真组名，弃用 "Unknown group" 兜底标签。
- 用户明确：comix 采集逻辑**暂不固化进代码**，本附录只归纳规则与根因，供后续决策。

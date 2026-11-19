# P72 施工日志 · 补全 The Runaway Extra and the Obsessive Duke 至源站最新（50 → 54）

> 日期：2026-11-19（任务书写作 20261120，实际跨零点前完成，按惯例记**实际日期**）
> 性质：**内容补全**，不改业务代码；版本号不变 `3.1.9+285`
> 目标源：`https://comix.to/title/6emnz-the-runaway-extra-and-the-obsessive-duke`
> 状态：4 话落盘 + 写库 + 对账全绿 + 反向验证 7 项真红；GUI 验收待用户

---

## 0. 结论先行

| 项 | 结果 |
|---|---|
| 源站最新话 | **Ch.54**（MagusManga / Lux Manga 都到 54；Rokari 到 53） |
| 本轮补的话 | **51 / 52 / 53 / 54**，翻译组 **MagusManga** |
| 张数 | 93 / 101 / 96 / 85 = **375 张** |
| 每话四件套 | 全部通过（收图数==页按钮数、页号 1..n 无空洞、PIL 全解码、同话内宽度 100% 一致） |
| 库 | `chapters` **50 → 54 格**，`downloadedChapters` **50 → 54 条**，唯一话号 **54**，孤儿 key **0** |
| 磁盘 | 50 → **54 个目录**，新增 4 个 `N [MagusManga] [comix.to]` |
| page-reconcile | `54 → 54 downloaded (0 newly registered)`、`0 → 0 missing` |
| chapter-order | passed，54 话标签 `第1话 … 第54话`，`orderViolations: []` |
| 反向验证 | 7 项全部按预期变红（少页 / 空目录 / 坏图 / 少登记 / 孤儿 key / 重复话号 / 还原后转绿） |

**关键推翻**：任务书里「Rokari 是否也到 50+ 必须现场核验」——现场结论是 **Rokari 已到 53**，Lux 是 49–54 的后来者，MagusManga 是唯一 1–54 全连续的一组。三组独立印证 54 就是当前最新话。

---

## 1. 组过滤权威表（源站真相，`?group_id=` 口径）

### 1.1 首屏（未翻页，默认 20 行）—— 证明「不翻页会看错」

| 组 | 首屏行数 | 首屏区间 |
|---|---|---|
| EZManga | 20 | 34–53 |
| Fairy Scans | 20 | 19–38 |
| Lua Comic | 20 | 34–53 |
| Luna Toons | 20 | 14–33 |
| **Lux Manga** | 6 | 49–54 |
| **MagusManga** | 20 | 35–54 |
| Nyx Scans | 20 | 34–53 |
| RinkoComics | 20 | 34–53 |
| **Rokari Comics** | 20 | 34–53 |
| Siren Scans | 20 | 19–38 |
| Tapas | 20 | 19–38 |
| Valir Scans | 20 | 34–53 |
| Violet Scans | 20 | 33–52 |

### 1.2 翻完 `.npager__num` 后的完整表（只取关键三组）

| 组 | 行数 | 覆盖 | 区间内空洞 | 来源 |
|---|---|---|---|---|
| **MagusManga**（`group_id=267`） | 54 | 1–54 | **无** | 3 页分页 |
| **Rokari Comics**（`group_id=2604`） | 53 | 1–53 | 无 | 3 页分页 |
| **Lux Manga**（`group_id=11444`） | 6 | 49–54 | 无 | 无分页控件（≤20 行） |

> 13 个组里，只有 MagusManga 覆盖到 1–54 全区间连续无缺口 ⇒ 选它做本轮补全组。
> `Lux` 的空洞口径按「自己覆盖区间」算（49–54 无洞），不是「1..54 缺 48 话」。

---

## 2. 选组与分辨率差异

- **选 MagusManga**：用户指定；1–54 连续；最新话就在这一组。
- **分辨率差异（重要，别当缺陷）**：MagusManga 上传的是 **720 宽**，本册既有 Rokari/Lux 是 **800 宽**。
  - 同话内 100% 统一（93/101/96/85 张全是 720×h，格式全 WEBP），跨组差异来自上传方，不是下载错图。
  - 若后续希望全册 800 宽：可用 **Rokari 51–53 + Lux 54**（两组都到 53/54）。本次不替换，避免动既有 50 话数据。
- **未替换 1–50 话**：换组会把已下载目录、阅读历史话号、翻译工程路径全部牵动，且与「不靠删历史重导」相冲突。只在日志留替代方案。

---

## 3. 逐话四件套

| 话 | 组 | 页按钮 | 收图 URL | 落盘 | 页号 | PIL 解码失败 | 宽度分布 | 判定 |
|---|---|---|---|---|---|---|---|---|
| 51 | MagusManga | 93 | 93 | 93 | 1–93 | 0 | 720×93 | ✅ |
| 52 | MagusManga | 101 | 101 | 101 | 1–101 | 0 | 720×101 | ✅ |
| 53 | MagusManga | 96 | 96 | 96 | 1–96 | 0 | 720×96 | ✅ |
| 54 | MagusManga | 85 | 85 | 85 | 1–85 | 0 | 720×85 | ✅ |

- 取图：`MutationObserver` + 点全部 `[aria-label*="Go to page N"]`，按 `alt="Page N"` 回排顺序（`order_method=alt`，101 页全有 alt，无一张靠发现顺序兜底）。
- 取字节：无 Referer / 无 `Sec-Fetch-*` 的朴素直连，代理 7890，8 并发 3 重试。
- Ch.52 第 1 页首次 `TimeoutError` → 单页补下（`p72_repair.py`）后 101/101，**没有拿「少一张也能读」蒙过去**。

---

## 4. 落盘与写库

### 4.1 目录名

`chapterDirectoryName` = `sanitizePathSegment('$number $site')` 的实际形态 → `51 [MagusManga] [comix.to]`。
组名取自组过滤表的组名文本，未猜。

### 4.2 页文件编号统一为 1 基

下载器先落的是 `000.webp…`，与**本册已有 50 话全部是 `001.webp` 起**不一致，已逆序改名成 `001…N`。
证据：page-reconcile 对既有 50 话与新增 4 话给出**完全相同**的 `gaps:[0]`（都对 0 基缺口报 0 号位），说明 1 基就是本册的事实标准。

### 4.3 备份

```
data/local.db.bak.p72-20261119-233521{,-wal,-shm}     ← 写 chapters 前
data/local.db.bak.p72b-20261119-233556               ← 写 downloadedChapters 前
```

### 4.4 写入口径

- `chapters[key] = [{"title": "第51话 · MagusManga", "key": "51 [MagusManga] [comix.to]"}]`
  —— 与既有 50 条**逐字段同形**（无 `group` / `lang` 字段，key 即目录名）。
- `downloadedChapters += 目录名 key`（与 `refreshLocalComicChapters` 的 `{...old, ...newKeys}` 同形）。
- 没有走「等 page-reconcile 自愈」这条路，原因见 §6 坑 3。

---

## 5. 验收证据

### 5.1 库与磁盘对账（`test-materials/runs/p72_verdict.json`）

```
cells 54 == uniqueNumbers 54 == downloaded 54 == diskDirs 54
话号 1..54 ｜ duplicateNumbers [] ｜ orphanKeys []
downloadedWithoutDir [] ｜ dirNotDownloaded [] ｜ emptyDirs []
```

### 5.2 page-reconcile（真实 `LocalManager.init`）

```
Page reconcile: 0 -> 0 missing page(s) (0 newly recorded),
                54 -> 54 downloaded chapter(s) (0 newly registered)
```
新增 4 话逐目录：`registeredBefore:true / registeredAfter:true`，`gaps:[0]`（与既有 50 话一致）。

### 5.3 chapter-order

```
chapters 54, isVersioned true, orderViolations [], prefixedKeys 0,
last ["第51话","第52话","第53话","第54话"] → passed
```

### 5.4 反向验证（`p72_negative_control.py`，7 项）

| 注入 | 必须红 | 实测 |
|---|---|---|
| 抽走 1 页（85→84） | 是 | `rc=1 count=84 gaps=[41]` |
| 空目录 | 是 | `rc=1 count=0` |
| 坏字节图 | 是 | `rc=1 decodeFail=1` |
| 少一条 downloaded | 是 | `rc=1 dirNotDownloaded=['54 …']` |
| 孤儿 key | 是 | `rc=1 orphan=['99 [Ghost] [comix.to]']` |
| 同组同话号重复格 | 是 | `rc=1 dup=['54']` |
| 还原后 | 绿 | `rc=0` |

> 反向验证直接改真库再还原（改前 `cp` 到 `.negctl`），所以「全绿」不是靠没测。

---

## 6. 本轮新踩的坑（三条，都有实证）

1. **pushState 目标 URL 拼错 → 4 章全 0 图**。
   组过滤表给的是 `/title/<slug>/<id>-chapter-N`，脚本又前缀了一次 `/title/<slug>/` ⇒ 404 空壳 ⇒ `buttons=0`。
   **规避**：URL 一律「站根 + 表里的 href」，且 `buttons==0` 必须判 FAIL（本轮已改成重试一次后记账失败，不再静默继续）。

2. **页文件编号基数必须跟本册历史一致**。
   本册既有 50 话是 `001` 起；新话先落成 `000` 起，虽然能读，但会让缺页表/比较口径与历史不同。
   **规避**：落盘后立刻按「本册已有章节」的编号基数改名，并用 page-reconcile 的 `gaps` 字段做一致性对照（1 基时报 `[0]`，与历史一样）。

3. 🔴 **`chapterKeysForDirectoryName` 在「版本没带 scanlationGroup」时认不出带组目录名**（P70 盲区）。
   版本里 `scanlationGroup` 为空时，该函数解析的是 `chapterDirectoryName(chapters, key)` 的结果（`51`，光秃秃没组），
   而**组名只写在 key 里**（`51 [MagusManga] [comix.to]`）。于是 `byNumberGroup` 只有 `51|`，磁盘 `diskGroup=magusmanga` 匹配不到 ⇒ 返回空。
   **实证**：第一次 `page-reconcile` 对 51–54 报 `registeredAfter:false`、`0 newly registered`；手写 `downloadedChapters` 后立刻变 `true`。
   **影响**：凡「版本无组名 + 目录名带组」的书，用户把目录手工拷进库后点「刷新章节 / 对账」都不会自动登记（蓝标不亮）。
   **P73 候选修法**：在 `ref == null || ref.groups.isEmpty()` 时回退 `parseChapterDirectoryName(key)`，把 key 里的组拿来做 `byNumberGroup` 的键。
   本轮**不动代码**（任务边界：只补数据）。

---

## 7. 交付清单

| 类型 | 路径 |
|---|---|
| 台账·组过滤表 | `test-materials/runs/p72_group_filter.json` |
| 台账·逐话核验 | `test-materials/runs/p72_chapters.json` |
| 台账·判定 | `test-materials/runs/p72_verdict.json` |
| 抓取/下载脚本 | `_work/p72_probe_groups.py`、`p72_probe_tables.py`、`p72_download.py`、`p72_repair.py`（工作区级临时脚本，不入库） |
| 校验脚本 | `_work/p72_verify.py`、`p72_audit.py`、`p72_negative_control.py`、`p72_ledger.py` |
| 代码改动 | **无**（版本号不变） |

---

## 8. 用户 GUI 验收清单（脚本验不了渲染）

- [ ] 启动 Mangrove，打开《The Runaway Extra and the Obsessive Duke》详情页：应看到 **54 格**，无重复话号，载入不卡；
- [ ] 51–54 四格显示**蓝标**（已下载）；
- [ ] 点开第 51 话能正常出图，翻页顺畅，第 54 话同理；
- [ ] 点「刷新章节」应提示 **「没有新增章节」**；
- [ ] 顺手看一眼 51 话画质：这批是 MagusManga 的 720 宽，比前 50 话（800 宽）略窄，属正常换组差异。

> 若蓝标或翻页异常，请取 `%APPDATA%\io.github.maelshiyan02\mangrove\logs.txt` 对应时间片段给我，不要删库重导。

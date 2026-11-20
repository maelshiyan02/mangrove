# P72 · HANDOFF · The Runaway Extra 补全收尾（2026-11-19）

> 性质：内容补全，**零代码改动**，版本号仍 `3.1.9+285`
> 前序：`P72-OPENER-TheRunawayExtra补全最新章节-20261119.md`
> 日志：`worklog/14-漫画源A方案升级P60-20261115/P72-WORKLOG-补全TheRunawayExtra至54话-20261119.md`

## 1. 已做完（可直接引用）

| 项 | 终值 |
|---|---|
| 章节 | 50 → **54**（51/52/53/54 = MagusManga） |
| 张数 | 93 + 101 + 96 + 85 = **375** |
| 库 `data/local.db` id=2 | `chapters` 54 格、`downloadedChapters` 54 条、唯一话号 54、孤儿 0 |
| 磁盘 | 54 个目录：1–49 `[Rokari Comics]`、50 `[Lux Manga]`、51–54 `[MagusManga]` |
| page-reconcile | `0→0 missing`、`54→54 downloaded (0 newly registered)` |
| chapter-order | passed（`第1话..第54话`，无顺序违规） |
| 反向验证 | 7 项全部按预期变红（改真库→还原，`.negctl` 已删） |
| 台账 | `test-materials/runs/p72_group_filter.json` / `p72_chapters.json` / `p72_verdict.json` |

**备份**：`data/local.db.bak.p72-20261119-233521{,-wal,-shm}`（写 chapters 前）、`data/local.db.bak.p72b-20261119-233556`（写 downloaded 前）。

## 2. 源站事实（下次别再猜）

- 最新话 = **Ch.54**；`?group_id=` 组过滤表是唯一权威。
- **MagusManga（267）= 1–54 全连续无缺口**；**Rokari（2604）已到 53**；**Lux（11444）= 49–54**（6 话，无分页控件）。
- 详情页首屏只 20 行，`.npager__num` 最多 8 页，**必须翻页**才能拿到全表。
- MagusManga 图片 **720 宽**，Rokari/Lux **800 宽** —— 换组正常现象。

## 3. 待用户 GUI 验收（脚本验不了）

- [ ] 详情页 54 格、无重复、载入不卡
- [ ] 51–54 蓝标
- [ ] 51 与 54 能打开、翻页不卡
- [ ] 「刷新章节」报「没有新增章节」

## 4. ~~下一轮候选（唯一真问题）~~ ❌ 已证伪（2026-11-20，P73 查漏补缺轮）

> **结论：下面这条 P73 候选是假阳性，不改代码。原推断的两处前提都经实测推翻。**
> 查漏补缺 experimentation 见 `_work/p73_probe_reconcile.py`、`_work/p73_probe_result.json`、
> `_work/p73_diag.json`；本轮未改任何业务代码，版本仍 `3.1.9+285`，基线仍 97/97。

~~🔴 `chapterKeysForDirectoryName` 的组名回退缺失（P73 候选）：版本 `scanlationGroup == null`
时只从规范名 `51`（无组）解析组名、不回退 key ⇒ byNumberGroup 键成 `51|`、磁盘带组目录
匹配不到 ⇒ 自动登记 0 条。~~

**证伪证据（三条，均可复算）**：

1. **诊断断言实测**：`ComicChapters.versioned({'51':[ComicChapterVersion(title:'第51话 ·
   MagusManga', chapterKey:'51 [MagusManga] [comix.to]')]})` 上，
   `chapterDirectoryName` 返回 **`51 [MagusManga] [comix.to]`**（原样带组，并非推断的裸 `51`）——
   因为 versioned + group 空时走 `parseChapterTitle(chapterKey)`，它认不出带方括号的目录名，
   fallback 原样返回 chapterKey。`chapterKeysForDirectoryName` 字面命中即返回该 key。
   加了「无组回退 key」修复后，故障对照 `broken_would_pass=true`（新旧实现结果相同）⇒ 该回退是惰性的。
2. **决定性实验**：把 `data/local.db` 的 `downloadedChapters` 临时从 54 回退到 50，
   跑官方 `page-reconcile 2`，结果仍 `50 → 50 / 0 newly registered`（`_work/p73_probe_result.json`），
   且 51–54 四话 `pagesOnDisk=93/101/96/85`（磁盘有图）。已自动恢复 54 条。
3. **真因**：`id=2` 的 `comic_type=0 = ComicType.local`，而 `reconcileDownloadedChapters`
   首行 `if (comic.comicType == ComicType.local) return 0;` 直接跳过所有对账 —— 与组名解析无关。
   local 漫画的目录名本身就是 key，下载时即写入 `downloadedChapters`，本就不走 reconcile 自愈。
   P72 手写登记是正确路径，不是绕 bug。

**修订后的认知**：数据侧已自洽（54 格 / 54 条 / 54 目录 / 0 孤儿 / 四话图片齐全），
无待修 bug。`page-reconcile` 不登记 local 漫画是设计边界，不是缺陷；
若要让 local 漫画也支持「磁盘补登」，那是新需求（需去掉守卫并评估副作用），不属于 bug 修复。

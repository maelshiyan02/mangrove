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

## 4. 下一轮候选（唯一真问题）

🔴 **`chapterKeysForDirectoryName` 的组名回退缺失**（P73 候选，本轮只记录未改）：

版本 `scanlationGroup == null` 时（本库绝大多数 agent 落库记录都是这种形态），该函数只用
`chapterDirectoryName(chapters, key)` 的结果（如 `51`，无组）去解析组名，而**组名只写在 key 里**
（`51 [MagusManga] [comix.to]`）⇒ `byNumberGroup` 键变成 `51|`，磁盘 `diskGroup=magusmanga`
匹配不到 ⇒ 自动登记 0 条。

- 实证：P72 首次 `page-reconcile` 对 51–54 报 `registeredAfter:false / 0 newly registered`；
  手写 `downloadedChapters` 后立即 `true`。
- 影响面：所有「版本无组名 + 目录名带组」的书 —— 用户把下载目录手工拷进库后，
  「刷新章节」「磁盘对账」都不会自动登记（蓝标不亮、需人工写库）。
- 修法建议：`ref == null || ref.groups.isEmpty()` 时回退 `parseChapterDirectoryName(key)`
  取组名，再做 `byNumberGroup` 查询；顺带给 `refreshLocalComicChapters` 加同一回退。
- 断言口径：造「版本无组 + 目录 `51 [MagusManga]`」夹具，要求 `chapterKeysForDirectoryName` 非空；
  注入回退删除后必须变红。

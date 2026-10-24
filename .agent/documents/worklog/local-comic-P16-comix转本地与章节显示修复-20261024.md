# P16 · comix 源转本地漫画 + 章节显示只留话号

> 日期：2026-10-24
> 范围：`ComicLibrary/downloads` 下 5 本 comix.to 漫画（Exception：The Runaway 早已是本地）
> 版本：`2.8.18+262` → 本次未改版本号（代码仅 `chapters.dart` 显示层 + 记录表数据）
> 前置：**P15**（下载实验坑与核验铁律）、**A19**（章节目录命名 D1）

---

## 0. 用户要的五件事

1. 剩余 comix 漫画：按名字去 comix 站抓**完整章节信息**填进记录表，更新封面，确认有没有多季度封面
2. `I will save my father` 记录混乱（长期当测试载体），脚本侧清理
3. **所有 comix.to 来源漫画转成本地漫画**（源站已封禁）
4. 记录表里填的必须是「本地那套字段」，**不能留网络标签**（`类型:Fantasy` 这种）
5. 章节列表只显示**话号**，翻译组只是 UI 分类标识（截图里 `11 [Rokari Comics] [comix.to]` 直接铺在格子上）
6. 包子 / 拷贝 / cos写真 **不许动**

---

## 1. 章节格子显示 bug：根因与修法

**现象**：详情页格子显示 `11 [Rokari Comics] [comix.to]`，被截成 `11 [Rokari C…`，话号都读不全。
第 1–10 话正常，11 话之后全乱。

**根因**：`chapters.dart` 的格子主标题走 `parseChapterTitle(value).displayTitle`。
`parseChapterTitle` 只认 `Ch.5 - X` / `第5话` / 纯数字三种写法，遇到**未清洗的目录名**原样返回。
而 `local.db` 里 Runaway 前 10 话的 value 早已是 `第1话 · Rokari Comics`（P14 洗过），
11 话以后仍是目录名原文 —— 所以断在第 10 话。

**修法**（`lib/foundation/chapter_directory.dart` + `chapters.dart`）：

| 函数 | 职责 |
|---|---|
| `chapterDisplayName(dir)` | 目录名 → `第N话 · 组名`（文本列表用，**跳过站点标签**） |
| `chapterNumberLabel(value)` ← 新增 | 只出 `第N话`。既能吃目录名，也能吃已清洗的显示名 |

- 两处格子（普通视图 `_chapterGroupLabel`、分组视图 `_groupLabelAt`）主标题统一改 `chapterNumberLabel(value)`
- 组名降级成格子下的 **10px 次要小字**，且**只在同一话号真的存在多个组时**才渲染
  （`_ambiguousGroups`：扫全书 key，按话号聚合组名，>1 个才进集合）
- 好处：Runaway 50 章一片干净；MDGH 的第 6 话有两个组（Asura / Diva）才标出来，否则就是两个一模一样的「第6话」

**踩坑**：分组视图那份 `_groupLabelAt` 里原有 `if (index >= chapters.groupCount) return null;`，
扁平章节 `groupCount == 0` 会**直接返回 null**，组名永远不显示。判据必须放行扁平分支。

---

## 2. 数据形状：为什么本地漫画必须写**扁平** chapters

`ComicChapters.fromJson` 按值类型分流：

| value 类型 | 落到的模式 | 谁在用 |
|---|---|---|
| `List<{title,key,…}>` | `versioned`（版本矩阵） | 网络源；Runaway（P14 遗留） |
| `Map` | `grouped`（分组 tab） | copymanga 的 `{"默認":{uuid:标题}}` |
| `String` | **扁平** | `local_comic_scanner.dart` 对磁盘扫描的输出 |

`local_comic_scanner.dart` 产出的就是扁平 `{目录名: chapterDisplayName(目录名)}`。
真相层写别的形状，下次 `refreshLocalComic` 一跑就被覆盖 —— 所以 **5 本统一写扁平**，
key 仍是目录名（读图路径来源），value 是显示名。两者分开，D1 改名才安全。

Runaway 保留 P14 的 versioned 形状不动（50 条 title 已经全是 `第N话 · Rokari Comics`，0 条不规范，
实测过）。形状不同不影响显示，`chapterNumberLabel` 两种都吃。

---

## 3. 记录表重建（`tools/_p15_migrate_to_local.py`）

### 3.1 两个库的分工，别搞反

| 库 | 角色 | 改什么 |
|---|---|---|
| `data/local.db` | **真相层** | `comic_type`、title/subtitle/description/tags/cover/chapters/downloadedChapters |
| `data/data/mangrove.db` | **镜像层（域库）** | comics / comic_sources / local_library_items / chapters / chapter_sources |

**关键发现**：域库 `chapters` 只按 `(comic_id, chapter_index)` **upsert，从不清空**
（只有 `chapter_sources` 是 delete+reinsert）。所以：
- `chapters` 可以装**全量**章节信息（38/116/113 话），App 重新镜像也不会被删
- `chapter_sources` 才是「磁盘上真有哪一话」的来源映射

而且全库 grep 过：**没有任何代码读 `chapters` 表**，它纯粹是记录 ——
所以全量登记不会凭空多出可点的空章节（章节列表来自 `local.db.chapters`）。

### 3.2 `comic_type` 约定

`local.db.comics` 主键是 `(id, comic_type)`：

| comic_type | 含义 |
|---|---|
| `0` | 本地漫画（`ComicType.local`） |
| `496108553` / `233488852` / `557997769` | comix_to / baozi / copy_manga 等远端类型 |

3 本 comix 从 `496108553` 改成 `0`，**id 保持原值不改**（`9lmnj//error-the-echo` 等）——
改 id 会打断 history / favorites 的既有引用。域库 comic_id 因此变成 `local:9lmnj//error-the-echo`，
长是长了点，但 identity 一致、不产生孤儿。

### 3.3 清掉的垃圾（逐条核实过，不是一把梭）

| 条目 | 为什么删 |
|---|---|
| `local:0` | cos写真 的重复身份（真相层只有 `id=1`），两条 local_library_items 指同一个目录 |
| `local:bt_e12050d7` | dir 指向 `D:/Mangrove_Windows/...`（盘符早就没了） |
| `local:bt_823c608b` | 同上，且目录名是 `0` |
| `local:bt_5be94984` | 同上（projects/Error the Echo） |
| `local:bt_6c25fb2a` | `S9Fixture` 测试夹具 |
| `local:bt_c3d2c83c` | `MDGH-ch1` 下载实验残留 |
| `local:bt_e2a58772` / `local:bt_640abdde` | `My Dragon Girlfriend Has Returned-1 …` 项目残留 |
| `remote:comix_to:{9lmnj,503jz,gm28k}` | 转本地后旧远端身份，留着就是同书两行 |

**没删的**：`remote:comic_collection_*`（Error the Echo 的另一个合集源身份）、
`goda` 的「被狼家团宠的小鸟媳妇」（目录不在盘上，但属于网络源记录，不在授权范围）、
包子 / 拷贝 / cos写真 —— 一律不动。

删除靠 `PRAGMA foreign_keys=ON` + `ON DELETE CASCADE`，一次删 comics 行即连带
comic_sources / local_library_items / chapters / chapter_sources，不留孤儿（已对账：孤儿 0）。

### 3.4 中文元数据

5 本全部翻成中文写进真相层（标题、作者/画师行、简介、题材标签），
标签是**题材**（奇幻·恐怖·惊悚），不是网络标签（`类型:Fantasy`、`更新:13h ago` 这类全部丢弃）。
Echo 那本源站没标作者，写「作者未标注」而不是留空。

### 3.5 全量章节登记结果

| 漫画 | 站上话号 | 登记 | 磁盘有图 |
|---|---|---|---|
| 回声错误 | 1–9 | 9 | 1（第1话 HiveToons，182 页） |
| 我要救爸爸 | 1–38 | 38 | 1（第1话 Lua Comic，90 页） |
| 龙女友回归 | 1–10 | 10 | 8 话 / 9 章（第6话两个组） |
| 黑幕男主的限时保姆 | 1–116 + 108.5 | **117** | 1（第116话，124 页） |
| 做个恶女好安逸 | 1–110 + 32.5/39.5/42.5 | **113** | 1（第109话，79 页） |

`.5` 是番外半话，不是脏数据 —— 一开始按 `1–116 话` 打印看着像多了一条，查过才确认。

---

## 4. 封面

5 本各 `cover/[cover]season(1).jpg`（comix 官方 poster）。
多季度核对结论：**都只有一季**。
- AniList 关系图（SEQUEL / PREQUEL / SIDE_STORY / ALTERNATIVE）逐本查过，4 本零关系
- MDGH 在 comix 与 Naver 原站都是单季
- 「做个恶女好安逸」别名带 S2，是续章不是独立封面

只有 The Runaway 是双季（P14 已处理）。

---

## 5. 验收

```
flutter analyze  rc=0        （0 error）
flutter build    rc=0
cmake --install  rc=0        === RESULT: BUILD_OK ===
app.so  21,463,944 B @20:45  （源码最后改动 20:41，产物更新）
mangrove.exe md5 与构建产物一致
```

**两库对账**：

```
local.db 本地漫画  : 1, 2, 4, 5, 9lmnj//…, 503jz//…, gm28k//…
域库 local 源      : 完全相同（差异 0 / 0）
local_library_items: 11 条，无孤儿
死路径残留         : 0
bt_ 身份残留       : 0
孤儿 chapters      : 0
```

**磁盘结构**（5 本）：

```
Error the Echo                     章 1  页 182  命名不合规 0  cover/[cover]season(1).jpg
I will save my father              章 1  页  90  命名不合规 0  cover/[cover]season(1).jpg
My Dragon Girlfriend Has Returned  章 9  页1148  命名不合规 0  cover/[cover]season(1).jpg
The Archvillain's Dying Nanny      章 1  页 124  命名不合规 0  cover/[cover]season(1).jpg
The Perks of Being a Villainess    章 1  页  79  命名不合规 0  cover/[cover]season(1).jpg
```

---

## 6. 遗留

- 这 5 本磁盘上只有 1–9 章不等（历史遗留），站上仍有 38/116/113 话未下。
  用户本轮明确「不补下载」，记录表按全量登记，已下载的挂真实目录名、未下载的 `source_chapter_id` 留空。
- 唯一没验证的是**界面实际渲染**（无渲染表面，只能靠构建通过 + 数据核对）。
  启动后应看到：5 本显示中文标题、章节格子只有「第N话」、龙女友回归第 6 话两个组各带小字。

---

## 7. 事故与补救：删旧身份连带删掉 798 条阅读历史

**这是本轮自己造成的真实数据损失，不是误报。**

`history_events.comic_id` 有 `ON DELETE CASCADE`。我删 `remote:comix_to:*` 三行时
只想到「旧身份是重复记录」，没先数历史事件 → 798 条阅读史 + 2 个收藏被一起带走。

**怎么发现的**：全部收尾之后，例行查「收藏是否指向已删身份」，顺手把备份库和历史
一起对上，才发现 history 从 7132 掉到 6154（差 978 条）。

**补救**（`tools/_p16_restore_history.py`）：从改库前备份 `mangrove.db.bak_p15_*`
把三本的历史捞回来，只改 `comic_id` 归属：

| 漫画 | 迁回 history | 迁回 favorites |
|---|---|---|
| 回声错误 | 86 | 0 |
| 我要救爸爸 | 273 | 1 |
| 龙女友回归 | 439 | 1 |
| **合计** | **798** | **2** |

**为什么能无损**：这三本的 history 行 `chapter_id` **全是 NULL**（旧版只记「读过」，
没记到章），所以不需要把章节 id 从 `remote:…:chapter:N` 重映射到 `local:…:chapter:N`
—— 那一步才是真正危险的地方（新旧 chapter_index 排序规则不同，强行按序号搬会指错章）。
脚本里对非 NULL 的 chapter_id 一律置空，宁可丢章节粒度也不指错章。

**剩下 180 条没救**：属于 7 个 `local:bt_*` 死路径条目（`D:/Mangrove_Windows` 早没了），
它们的目录不存在、记录本身就是测试残留，随条目一起清掉是预期行为。

**核对**：history 总数 6154 → 6952（= 7132 − 180），孤儿 0。

### 教训（已写入 A21）

**域库删 `comics` 行之前，必须先数 `history_events` / `favorites` / `works` 的依赖，
并想清楚是「该跟着消失」还是「该改挂到新身份」。**
`ON DELETE CASCADE` 是静默的 —— 删的时候不会提醒你还带走了多少阅读史。
正确姿势是先 `UPDATE ... SET comic_id = 新身份` 迁完，再删旧行；
或者干脆不删，只把 `comic_sources` 摘掉。

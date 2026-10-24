# P14 命名规范落地：D1 迁移 · 兼容读取 · 编辑入口 · 章节排序

> 2026-10-24 ｜ 版本 `2.8.17+261` → `2.8.18+262`
> 上游：`local-comic-P12-模式权限内核与封面池.md`（P11~P13）
> 承接开场白：`.agent/documents/worklog/新对话开场白-本地库重构与模式权限升级.md` §5

---

## 0. 这一轮在解决什么

用户在 P11~P13 交付后提了五件事，按"影响面"排序：

| # | 问题现象 | 真实根因 |
|---|---|---|
| 1 | **详情页找不到「编辑信息」按钮**（截图：纯本地漫画） | P11 的显示条件写了 `comic.sourceKey != 'local'`，把最需要手填信息的**纯本地漫画**整块排除了 |
| 2 | **章节列表顺序乱**：`第1话 第2话 第3话 第4话 第48话 第49话 第5话 第6话 第7话` | `ComicChapters` 只对**版本化**章节排序，扁平章节沿用插入顺序（= 目录名字符串序） |
| 3 | **D1 命名要落地到已有目录** | `chapterDirectoryName` 只产出 `<话号> [组名]`，缺来源站点；且改规则必然读不到老目录 |
| 4 | **封面要进 cover 池、旧文件要删** | 只有 The Runaway 一本有池；其余 8 本封面散在根目录或指向章节内页 |
| 5 | **缺页章节要补** | 第 2 话只有 12 页却因"目录非空"被永久跳过（见 A17） |

---

## 1. 编辑入口（本轮最直接的 bug）

### 根因

```dart
// P11 写的（错）
if (displayMode == ComicDisplayMode.local && comic.sourceKey != 'local')
```

当时的推理是"本地漫画的信息本来就存在 `LocalComic` 里，不需要覆盖层"——**推理对，结论错**：
`showEditLocalComicInfoDialog` 早就存在于 `local_comic_edit_dialogs.dart:431`，
但**只有 `local_comics_page.dart` 调它**，详情页从来没接过。于是纯本地漫画在
详情页里是彻底没有编辑入口的，而它们恰恰是最需要手填的一类（没有源站可抓）。

### 修法：按身份分流，而不是排除

```dart
if (displayMode == ComicDisplayMode.local)
  IconButton(
    onPressed: () async {
      final local = _localComic;
      if (comic.sourceKey == 'local' && local != null) {
        final updated = await showEditLocalComicInfoDialog(App.rootContext, local);
        if (updated == null) return;
        refreshLocalComic();   // 必须重建 data，只 update() 还是旧标题
        return;
      }
      // 网络漫画 → 覆盖层
      final changed = await showComicOverrideDialog(...);
      if (changed) update();
    },
    icon: const Icon(Icons.edit_note),
    tooltip: 'Edit Local Info'.tl,
  ),
```

两条路径的语义差别要记住：

- **纯本地漫画**：改的就是 `LocalComic` 本体（标题/作者/来源/更新时间/标签/简介）
- **网络漫画**：写 `comic_field_overrides`（覆盖层），网络原文保留、随时可恢复
- **网络模式**：不给入口——那时看到的就是站点原文，改了也无处可存

⚠️ `refreshLocalComic()` 而不是 `update()`：`update()` 只 `setState`，
`buildContent(context, data)` 收到的还是旧 `data`，标题不会变。这是 P10 的原坑。

---

## 2. 章节排序：扁平模式漏了排序

`ComicChapters` 有两条构造路径：

- `ComicChapters.versioned(...)` → 走 `_sortVersioned`，按 `_compareChapterNumbersAsc` 排
- `ComicChapters(Map)` → **const 构造，不排序**

本地漫画走的正是后者（`Map.fromIterables(chapterNames, chapterNames)`），
而 `chapterNames` 来自 `chapterDirectories.sort((a,b) => a.name.compareTo(b.name))`
——纯字符串序，于是 `1,2,3,4,48,49,5,6,7`。

### 修法：在显示序层加自然排序

改 `ChapterOrderPrefs._orderedIndices`：用户自定义序优先，**剩下的**按话号自然序补：

```dart
final rest = [for (var i = 0; i < ids.length; i++) if (!used.contains(i)) rest.add(i)];
rest.sort((x, y) => _compareChapterKeys(ids[x], ids[y]));
```

`_compareChapterKeys` 读前导数字比大小，没数字的排后面。

为什么改这里而不是 `ComicChapters` 构造？

1. 扁平构造是 `const`，加排序就丢 const
2. `ids` 的原始顺序对阅读器翻页/下载顺序也有意义，改容器影响面太大
3. 显示层排序本来就是这个类的职责

---

## 3. D1：命名规范 + 兼容读取

### 3.1 规范

```
<话号> [<翻译组>] [<来源站点>]        49 [Rokari Comics] [comix.to]
<话号> [<来源站点>]                   116 [comix.to]        （源没给组名）
<话号>                                119                   （扁平章节，无组无站）
```

站点标签用**稳定的网站名**而不是当前域名：

```dart
const _sourceSiteTags = {
  'comix_to': 'comix.to',
  'baozi': 'baozimh',      // 域名一年换几个（baozimh → webmota → kukuc.co）
  'copy_manga': 'copymanga',
  ...
};
```

写进目录名的东西必须十年后还认得出来，用会漂移的域名就是自找麻烦。

### 3.2 为什么不能直接改 `chapterDirectoryName` 的输出就完事

读取侧（`getImagesForComic`）也调这个函数算目录名。新下载写 `<话号> [组] [站]`，
而读取侧若算 `<话号> [组]`，就"下完读不到"。三条腿必须同时落地：

| 层 | 改动 |
|---|---|
| 写入 | `ImagesDownloadTask._chapterDirectoryName` 传 `siteTag` |
| 读取 | 目录不存在 → `resolveChapterDirectoryName` 语义匹配 |
| 反查 | `reconcileDownloadedChapters` 加"话号+组名"二级索引 |

### 3.3 语义匹配（兼容的核心）

`chapterDirectoryMatchScore(candidate, template)`：

- 话号必须相等，重名后缀 `(2)` 必须相等
- 模板点了组名 → 候选必须同组（**组名不同一定是别的版本，必须拒绝**）
- 站点标签有无都算命中（这正是要兼容的差异）

**为什么不用"前缀匹配"**：`5` 会匹配到 `5`、`5 [A]`、`5 [B]`，同一话两组的图会串。
组名必须硬比。

### 3.4 缺页表的连带修复

`missing_pages.json` 的 `chapterId` 就是目录名。规则升级后同一条目新旧两种写法
字面不等 → **红标凭空消失**（明明缺页却显示完整）。加 `countOfChapterFuzzy`，
读取侧（`chapter_download_status.dart` / `reader/scaffold.dart` /
`repair_download.dart`）全部改用它。

---

## 4. 迁移脚本 `tools/library_migrate.py`

### 4.1 站点怎么确定（关键设计）

一开始想靠目录名里的组名猜站点，**错的**：同样 `[Asura Scans]` 可能来自
asuracomic.net，也可能来自 comix.to 聚合。不猜。

真正的答案在 App 自己的数据里：

```
data/implicitData.json → sourceTypeRegistry → {"496108553": "comix_to", ...}
data/local.db          → comics.comic_type
```

`comic_type = source.key.hashCode`，两者一拼就知道每本从哪来。32 条映射覆盖全部网络漫画。
纯本地记录（`comic_type = 0`）走第二层：目录名自带站标 / 采集脚本产物。

三层都失败 → **原样保留**并列入报告。写错站名比不写更糟。

### 4.2 踩的三个坑

**坑 1：脚本不幂等**
第一版把 `119 [baozimh]` 里的 `baozimh` 当成**翻译组**（它没有点，不匹配域名正则），
再补一次站点 → `119 [baozimh] [baozimh]`。**跑两次脚本就污染一遍磁盘**。
修：`KNOWN_SITE_TAGS` 显式收集所有已知站标；`build()` 里组名与站标同名则只留一份。

**坑 2：UUID 被当成话号**
`2860aaf9-bc44-11f1-...` 被 `^(\d+)` 吃掉前四位，算出"第 2860 话"。
修：正则加 lookahead `(?=\s|\[|$)`，数字后必须跟空格/方括号/结尾。

**坑 3：扁平 chapters 的键就是目录名**
改了磁盘不改库 → 图在磁盘上但读不到。而且**只有扁平结构能改**：
版本矩阵的键是源 id（整条 URL）、分组结构的键是 UUID，动了就切断源数据。
判据：`all(isinstance(v, str) for v in data.values())`，否则整条跳过。

这个坑在现场已经发生：`扔掉的渣男，绝不再捡！` 133 章要回填键，`灭门家族` 1 章。

### 4.3 结果

```
合计：改名 145，封面池 8，删旧封面 1
```

| 漫画 | 站点 | 章节目录 |
|---|---|---|
| The Runaway… | comix.to | 已是新规范，只补封面 |
| Error the Echo | comix.to | `1 [HiveToons]` → `1 [HiveToons] [comix.to]` |
| My Dragon Girlfriend… | comix.to | 8 章全部补站标 |
| I will save my father | comix.to | 1 章补站标 |
| 扔掉的渣男，绝不再捡！ | baozimh | 133 章 `N` → `N [baozimh]` + 记录表同步 |
| 灭门家族的重生者 | baozimh | `119` → `119 [baozimh]` |
| 第一次告白 | copymanga | UUID 目录，**不改**（改名就读不到） |
| The Archvillain's… / The Perks… | comix.to | 已规范，封面从章节内页复制进池 |

---

## 5. 封面池

规则：`<漫画>/cover/[cover]season(N).<ext>`，N 大者为默认。

三种历史形态都要处理：

| 形态 | 处理 |
|---|---|
| 根目录 `cover.jpg` | 移入池并改名 `[cover]season(1).jpg`，根目录原文件删 |
| 池里已有 season(1)、根目录还有残留 | 只删残留 |
| 封面指向章节内页（`116 [comix.to]\0.webp`） | **复制**，不是移动——那页是正文 |

⚠️ `116 [comix.to]\0.webp` 里的 `\0` 是**路径分隔符 + 文件名 `0.webp`**，
不是转义序列。用 `partition("\\0")` 会拆成 `116 [comix.to]` + `.webp` 然后找不到文件。
必须 `replace("\\", "/")` 后按段拆。

删旧文件放在"池里确实有封面"之后：顺序错了会把唯一一张封面删掉。

---

## 6. 缺口报告 `tools/comix_gap_report.py`

判据五条，第四条最阴：

> **无 manifest 记录却已经有图** = 中断留下的半章，无法自证完整

旧版下载器不写 manifest，一个 12 页的残目录会被"目录非空就跳过"永久放过，
界面上显示"已下载"、翻开只有 12 页。这类静默缺页比报错难发现得多。

当前报告（批量仍在跑，只统计已完成的）：

| 章节 | 页数 | 原因 |
|---|---|---|
| 2 | 12 | 无 manifest（中断残留） |
| 3 | 64 / 65 | 1 页下载失败 |
| 5 | 81 / 82 | 1 页下载失败 |
| 7 | 82 / 83 | 1 页下载失败 |
| 8 | 78 / 80 | 2 页下载失败 |
| 49 | 95 | 无 manifest（早期下载） |
| 9 | 90 | 正在下 |

---

## 7. 中文详情信息

用户要求"英文网站获得的要翻译成中文填入详细信息"。

`data/local.db` 里这本原本 `title` 是英文、`subtitle`/`description`/`tags` 全空。写入：

- **标题**：逃离偏执男主的配角
- **副标题**：Dan Rihan（단리한）原作 · SIXA（식사）作画
- **标签**：奇幻 / 异世界 / 恋爱 / 转生 / 反派千金 / 契约婚姻 / 偏执男主
- **简介**：中文全文（保留韩文原名与 Tapas 官方英文名作为别名，不混用小说版）

译本依据：Tapas 官方英文名 `The Runaway Extra and the Obsessive Duke`，
韩文原名 `집착남주 두고 튀려는 엑스트라입니다`，日文译名
`執着系ヒーローから逃げたいモブ令嬢です`。

---

## 8. 构建

`flutter analyze` rc=0（0 error）。`flutter build windows` 在 **INSTALL** 阶段
失败——`mangrove.exe` 正被运行中的 App（PID 22160）占用，不是代码问题。
关掉 App 重跑即可。

---

## 9. 待办

1. 关闭 App → 重跑 `run_build_task.py` 完成安装
2. 批量下完后补 2 / 3 / 5 / 7 / 8 / 49（`comix_gap_report.py` 可直接出命令）
3. 第 50 话只有 Lux Manga 有，批量末尾会下
4. 多季封面：目前只有 The Runaway 找到两季，其余需逐本核对

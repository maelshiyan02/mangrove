# P52 · 拷贝漫画章节乱码修复（第一次告白 / dycgb）

## 1. 现象（用户报）
《第一次告白》（本地 id=`dycgb`，源 `copy_manga`）执行「网络信息刷新」后，原本正常的章节列表
变成乱码：章节标题显示为 `第39244565话` / `第44059405话` 这类被错误解析的「话号」，以及一整串
UUID 碎片（`003b54f5-31b5-…`、`fff13136-d071-…`）。这是 P51 §5.1 记载的遗留「假绿」现象的实锤。

## 2. 取证（实时库）
- `data/details_cache.db`（源缓存）**完全正确**：`copy_manga/dycgb → {默認:{uuid: 第1话 … 第64话}}`（64 话）。
- `data/local.db`（本地库）**已损坏**：`dycgb.chapters` 共 63 条，外键全部是 UUID，内 `title` 被写成
  - `第39244565话` / `第44059405话`（UUID 首段为纯数字，被当话号）；
  - 或原样 UUID（`003b54f5-…`，首段含字母，未包成 第N话）。
- 全库 12 本漫画中**仅 `dycgb`** 受影响（拷贝漫画 UUID key 专属）。

## 3. 根因
唯一写入 `第<uuid首段>话` 的代码路径是 `local_comic_edit.dart` 的 `refreshLocalComicChapters`
里的 `relabel` 循环：它对每个版本的 `chapterKey`（拷贝漫画是 UUID）调用 `chapterDisplayName(key)`，
把源站给的正确 `第N话` 标题覆盖掉。

`chapterDisplayName → splitLeadingChapterNumber` 的负向断言 `(?![0-9A-Za-z])` 只挡住了
「首段含字母」的 UUID（`003b54f5-…` 读不出 → 原样返回），却**漏掉首段纯数字的 UUID**
（`39244565-0629-…`：首段后接 `-`，不是字母数字 → 断言放行 → 读成 `第39244565话`）。
`chapterNumberValueOf`（排序/去重唯一入口）同样漏判，导致排序也曾把 UUID 首段当话号。

> 网络刷新路径（`_persistEnrichedChapters → enrichComicChapters → mergedWith`）只增不减、保留本地
> title，**不会**主动破坏；它只是把已经被「刷新章节」写坏的 title 保留了下来，所以用户在「网络信息刷新」
> 后看到乱码。

## 4. 修复（代码）
- `lib/foundation/chapter_directory.dart`
  - 新增顶层 `isUuidLike(String)`（完整 8-4-4-4-12 十六进制形态判定）。
  - `splitLeadingChapterNumber` 开头加 UUID 守卫：UUID 直接返回 null，绝不当话号。
- `lib/foundation/chapter_title_parser.dart`
  - `chapterNumberValueOf` 内联同一套 UUID 正则守卫（叶子模块不反向依赖 chapter_directory），返回 null。
- `lib/utils/local_comic_edit.dart`
  - `relabel` 循环：UUID 形态的 `chapterKey` 直接 `continue`，**保留源站给的 第N话**，不再用
    `chapterDisplayName(key)` 覆盖。

## 5. 修复（数据）
- 关 App 后备份 `data/local.db` → `local.db.bak.20261027-163715`。
- 用 `details_cache.db` 的 `uuid→第N话` 映射，重建 `dycgb.chapters` 为 versioned 矩阵：
  外键 = 数字 `1..63`（源站话号，保证升序），`title = 第N话`，`key = 原 UUID`（目录/下载/进度
  全部按 UUID 对齐，一个字节不动）。源站第 64 话本地未下载，暂不包含（用户可再次网络刷新补全）。

## 6. 验证
- `flutter analyze` rc=0；`flutter build windows --release` rc=0；`cmake --install` rc=0 → BUILD_OK。
- headless `chapter-order --comic dycgb`：**PASS**。`allLabels = 第1话…第63话`（单调不减），
  `prefixedKeys=0`，`orderViolations=[]`。`idsHead` 仍为 UUID，证明源站 key 未被改动。
- 全库 12 本 `chapter-order` 闸门：**12 passed / 0 failures**（无回归）。

## 7. 版本
`2.8.26+270 → 2.8.27+271`（pubspec.yaml）。改动只进本地 git，未推送。

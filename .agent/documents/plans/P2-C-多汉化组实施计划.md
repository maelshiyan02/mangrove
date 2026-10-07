# P2-C 实施计划：多汉化组支持

## Context

P2-A 已完成章节名格式化（`parseChapterTitle` → "第X话"），P2-B 已完成封面收录。P2-C 是最终阶段：支持同一章节号下多汉化组版本并列显示与切换。

用户需求：comix.to 同一章节有多个汉化组版本（如 Ch.5 有 8 个组），当前 `ComicChapters` 无法表达"同章节号多版本"。用户选择新建多版本数据结构。

## 现有结构

`ComicChapters`（models.dart:337-495）有两种模式：
- Flat: `Map<String, String>`（chapterId → title）
- Grouped: `Map<String, Map<String, String>>`（groupName → {chapterId → title}）

现有 grouped 模式的 group 通常是语言/卷宗分组，不是汉化组分组。用户明确说"语言和汉化组不能混为一谈"。

## 实施方案

### 1. 新建 ComicChapterVersion 类

**文件**: `lib/foundation/comic_source/models.dart`（在 ComicChapters 类之前）

```dart
class ComicChapterVersion {
  final String? scanlationGroup;
  final String? language;
  final String title;
  final String chapterKey;

  const ComicChapterVersion({
    this.scanlationGroup,
    this.language,
    required this.title,
    required this.chapterKey,
  });

  factory ComicChapterVersion.fromJson(Map<String, dynamic> json) =>
    ComicChapterVersion(
      scanlationGroup: json['group'],
      language: json['lang'],
      title: json['title'],
      chapterKey: json['key'],
    );

  Map<String, dynamic> toJson() => {
    if (scanlationGroup != null) 'group': scanlationGroup,
    if (language != null) 'lang': language,
    'title': title,
    'key': chapterKey,
  };
}
```

### 2. 扩展 ComicChapters

**文件**: `lib/foundation/comic_source/models.dart`

在现有字段基础上新增 `_versionedChapters`：

```dart
class ComicChapters {
  final Map<String, String>? _chapters;
  final Map<String, Map<String, String>>? _groupedChapters;
  final Map<String, List<ComicChapterVersion>>? _versionedChapters; // 新增

  // 现有构造函数不变
  const ComicChapters(Map<String, String> this._chapters)
    : _groupedChapters = null, _versionedChapters = null;

  const ComicChapters.grouped(Map<String, Map<String, String>> grouped)
    : _chapters = null, _groupedChapters = grouped, _versionedChapters = null;

  // 新构造函数
  const ComicChapters.versioned(Map<String, List<ComicChapterVersion>> versions)
    : _chapters = null, _groupedChapters = null, _versionedChapters = versions;
}
```

**新增 API**：
- `bool get isVersioned => _versionedChapters != null;`
- `Map<String, List<ComicChapterVersion>> get versionedChapters => _versionedChapters!;`
- `Set<String> get scanlationGroups` — 所有汉化组名集合
- `List<ComicChapterVersion>? versionsFor(String chapterKey)` — 某章节的所有版本
- `String? preferredVersionKey(String chapterKey, String? preferredGroup)` — 取首选汉化组的版本 key

**现有 API 兼容**：`ids`、`titles`、`[]`、`titleAt`、`length` 等，当 `_versionedChapters != null` 时，遍历版本取第一个版本的 chapterKey/title。这样不破坏现有代码。

### 3. fromJson / toJson 扩展

`fromJson`：检测 JSON 中是否有 `versions` 字段（`Map<String, List<Map>>`），有则走 versioned 分支。

`toJson`：versioned 模式输出 `{chapterKey: [{group, lang, title, key}, ...]}`。

### 4. 章节解析器适配

**文件**: `lib/foundation/comic_state_repository.dart` L637-664

当前：source 返回 flat/grouped chapters → 直接构造 ComicChapters。

新增：source 返回的 chapters 中，若 `ParsedChapterTitle.scanlationGroup != null`，按章节号聚合为 versioned 结构：
```dart
final versions = <String, List<ComicChapterVersion>>{};
for (final entry in sourceChapters.entries) {
  final parsed = parseChapterTitle(entry.value);
  final chNumber = parsed.chapterNumber?.toString() ?? entry.key;
  versions.putIfAbsent(chNumber, () => []).add(ComicChapterVersion(
    scanlationGroup: parsed.scanlationGroup,
    title: parsed.displayTitle,
    chapterKey: entry.key,
  ));
}
if (versions.values.any((v) => v.length > 1)) {
  return ComicChapters.versioned(versions);
}
```

### 5. 章节列表 UI 改造

**文件**: `lib/pages/comic_details_page/chapters.dart`

当 `chapters.isVersioned` 时，渲染方式：
- 章节网格：每个 cell 显示 `第X话`（大字）+ 汉化组名（小字 subtitle）
- 若同章节号多版本：cell 下方显示汉化组标签栏（类似图 3 的语言标签），点击切换
- 单版本章节：只显示 `第X话`，不显示标签栏

**文件**: `lib/pages/reader/chapters.dart`

当 `chapters.isVersioned` 时：
- 章节列表每项显示 `第X话` + 汉化组名小字
- 多版本章节展开为子列表

### 6. Reader 章节切换适配

**文件**: `lib/pages/reader/reader.dart` 及关联文件

当 `chapters.isVersioned` 时，`toChapter(ep)` 需要额外接收 `scanlationGroup` 参数，定位到正确版本的 chapterKey。

### 7. 下载逻辑适配

**文件**: `lib/network/download.dart`

`_images!.keys.elementAt(_chapter)` 当前按 flat index 取 key。versioned 模式下，需要先确定汉化组版本，再取该版本下的 chapterKey。

### 8. BT 工程适配

**文件**: `lib/foundation/bt_project/bt_project_manager.dart`

BT 工程通常单汉化组，`_registerLocal` 中继续使用 flat `ComicChapters`，无需 versioned。保持不变。

---

## 验证

### 代码质量
- `flutter analyze` → 0 error
- `flutter test --concurrency=4` → 840+ 全过

### 功能验证
1. 网络漫画（comick 等有多汉化组的源）章节列表显示"第X话" + 汉化组标签
2. 切换汉化组标签 → 章节列表更新
3. 阅读器章节列表显示汉化组信息
4. 下载指定汉化组版本
5. BT 工程章节仍显示"第0话"（单汉化组，无标签）
6. 现有 flat/grouped 章节显示不受影响

### 构建
- 沙箱外运行 `build_venera.ps1`
- 验收：`data/app.so` 时间戳刷新

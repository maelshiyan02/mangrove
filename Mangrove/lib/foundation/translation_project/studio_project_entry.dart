// 「创建翻译工程」入口的**纯逻辑层**。
//
// ## 这个文件回答的唯一一组问题
//
// 用户在工作室里点【创建翻译工程】时要选三样东西：哪本漫画、哪一章、工程叫什么。
// 这三步里每一步都有一个**选错了不报错、只是结果不对**的坑：
//
// | 步 | 判断 | 出错的样子 |
// |---|---|---|
// | 1 | 这本漫画**能不能**建工程 | 列表里混进 `bt_` 工程 / `ft_` 成品（建出来指向产物自己）；**或反过来，真正的素材一本都不列** —— 判据写成 `comicType == local` 时就是这个症状 |
// | 2 | 这一章**有没有**页图 | 选了一个空目录，"建出来"的工程 0 页 —— 在工作室里只表现为一张空白 |
// | 3 | 工程名怎么算 | 入口算的名字与阅读器开关算的名字**不一致** ⇒ 同一章建出两个工程 |
//
// 第 3 条的写法尤其要紧：名字规则原先**只有** `StudioReaderLink.locate` 里那一份
// 内联实现。入口再抄一遍就会漂移（入口化一个字符、开关那边不化），而漂移的后果
// 不是报错，是"同一章两个工程、术语表也分家"。所以规则收敛到
// [studioProjectNameFor] 一处，两边都调它。
//
// ## 为什么能被 headless 验
//
// 本文件只依赖 `dart:io` 与 `chapter_directory.dart`（纯字符串），不碰
// `dart:ui` / 渲染（`A01 §3`：本会话没有渲染表面）。于是"可选性判据"与
// "命名规则"都能在临时目录里被注入故障打红 —— 见 `headless_p9_checks.dart`。
library;

import 'package:mangrove/foundation/chapter_directory.dart';
import 'package:mangrove/foundation/comic_source/comic_source.dart'
    show ComicChapters;
import 'package:mangrove/foundation/translation_project/project_bootstrap.dart';

/// 工程名的字符上限。
///
/// 🔴 与 `ProjectBootstrap.validate` 的"不能含路径分隔符"是两条独立的约束：
/// 长度上限防的是**路径总长**（Windows 的 260 字符），分隔符防的是目录穿越。
/// 只查一条会让另一条以"文件建不出来"的形式暴露。
const int studioProjectNameLimit = 60;

/// 建议的工程名：`<漫画名>[-<章节目录名>]`，截到 [studioProjectNameLimit]。
///
/// [chapterName] 为空 = 无章节的漫画（页直接躺在漫画根下）⇒ 只用漫画名。
///
/// 🔴 **全仓唯一实现**。`StudioReaderLink.locate` 与建工程入口都调这里；
/// 谁再内联一次这套拼接，就会造出"同一章两个工程"。
String studioProjectNameFor({
  required String comicTitle,
  required String chapterName,
}) {
  final title = sanitizePathSegment(comicTitle);
  final stub = chapterName.isEmpty
      ? title
      : '$title-${sanitizePathSegment(chapterName)}';
  final bounded = stub.length > studioProjectNameLimit
      ? stub.substring(0, studioProjectNameLimit)
      : stub;
  return bounded.isEmpty ? 'studio-project' : bounded;
}

/// 工程名能不能用。返回 `null` 表示可以，否则是一个**码**（不是句子）。
///
/// 返回码而不是句子：句子要落进调用方的字面量里，i18n 扫描器才扫得到 —— 与
/// `StudioEnqueueStatus` / `RunBlockReason` 同一条规矩。纯逻辑层不该持有 UI 文案。
String? studioProjectNameProblem(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return 'empty';
  // `.` / `..` 不是"含分隔符"但同样是目录穿越，必须一起挡。
  if (trimmed == '.' || trimmed == '..') return 'separator';
  if (trimmed.contains('/') || trimmed.contains('\\')) return 'separator';
  if (trimmed.length > studioProjectNameLimit) return 'too-long';
  return null;
}

/// 一本漫画是不是"建工程"的候选。
///
/// 判据只有**两句**，但第一版把两句都写成了另一件事（见文末），于是界面上出现
/// 的是"素材列表里只有一本**成品**、真正的素材一本都不在"。
///
/// 1. [!isDerivedCard] —— `bt_<hash>` 是**工程**、`ft_<hash>` 是**成品**，两者
///    都是从素材派生出来的产物。给产物再建工程，新工程的"原图"会指向上一层的
///    中间产物（`projects/<名>/source/` 或 `translated/<名>/`）；
/// 2. [hasLocalPages] —— 工程要把原图**复制**进 `source/`（`ProjectBootstrap`
///    的硬约束 1）。判据是"本地真的有一章/一页"，用 `downloadedChapters`。
///
/// 🔴 第 2 条**不能**写成 `comicType == ComicType.local`。`ComicType.local` 的
/// 含义是"这本漫画的来源类型是本地"，而本流水线注册的**产物卡**（`bt_`/`ft_`）
/// 恰恰也被登记成 `local`；反过来，从 comix.to 这类源**下载**到本地的漫画，
/// `comicType` 是源类型（`496108553` 这种），却是最正统的素材。
/// 实测（2026-10-09，`local.db` 三行）：`ft_` 成品卡被放行，只下了 9 话的
/// `My Dragon Girlfriend Has Returned` 被排除。
///
/// [isFlat] 是"页直接躺在漫画根下、没有章节目录"的漫画（本地导入一个纯图片
/// 文件夹）。它 `chapters == null` **且** `downloadedChapters` 为空，但它能读、
/// 也照样能建工程 —— 所以必须单独放行。宁可多列一条（点进去会说"这一本没有
/// 含页图的章节"），也不要少列一条（用户找不到自己的素材）。
///
/// 三条都写成**外部传进来的布尔**，是为了让判据能在 headless 里被直接喂故障
/// （`isDerivedCard: true` 必须让它变 false），不必先搭一个库。
bool studioProjectComicEligible({
  required bool isDerivedCard,
  required bool hasLocalPages,
  required bool isFlat,
}) => !isDerivedCard && (hasLocalPages || isFlat);

/// 建工程时可选的**一章**（UI 侧的原始输入）。
///
/// [chapterName] 是**相对漫画根**的章节目录名，由 [chapterDirectoryName] 算出；
/// 无章节的漫画是空串，此时 [eid] 恒为 `'0'`（与阅读器 `_currentChapterEid`
/// 的写法一致 —— 两边必须一致，否则同一章在两处是两个键）。
class StudioChapterRef {
  const StudioChapterRef({
    required this.eid,
    required this.label,
    required this.chapterName,
  });

  final String eid;
  final String label;
  final String chapterName;
}

/// 一本漫画的候选章节（纯逻辑：只看 chapters 矩阵，不碰磁盘）。
///
/// [preferredKeys] 传**这一本已下载**的章节 key。它决定了版本化源上"这一话
/// 归哪一个翻译组"：
///
/// 🔴 `chapters.ids`（以及下游的 `eid`）每话**只给一个 key** —— 也就是该话版本
/// 列表的**第一个**。所以"哪一版排在首位"直接决定入口与阅读器说的是不是同一
/// 章。用原始序会出现：用户下载了 Asura 版，而列表里首版是 DivaScans 版 ⇒
/// 入口列出一个目录根本不存在的章（扫出来 0 页 ⇒ 灰掉），而真下了的那一话连列
/// 都不列。
///
/// 阅读器算 `eid` 用的是 `LocalComic.effectiveChapters`（同一份
/// `preferDownloaded`），所以两边**必然**落在同一个 key 上。
///
/// 无章节的漫画（[chapters] 为 null，页直接躺在漫画根下）返回一个 `eid = '0'`
/// 的伪章节 —— 与 `ReaderScaffold._currentChapterEid` 的回落一致。
List<StudioChapterRef> studioChapterRefs(
  ComicChapters? chapters, {
  Set<String> preferredKeys = const {},
}) {
  if (chapters == null) {
    return const [StudioChapterRef(eid: '0', label: '', chapterName: '')];
  }
  final ordered = chapters.preferDownloaded(preferredKeys);
  return [
    for (final key in ordered.ids)
      StudioChapterRef(
        eid: key,
        label: ordered.allChapters[key] ?? key,
        chapterName: chapterDirectoryName(ordered, key),
      ),
  ];
}

/// 一章的扫描结果：能不能建，以及为什么不能。
class StudioChapterOption {
  const StudioChapterOption({required this.ref, required this.pageCount});

  final StudioChapterRef ref;

  /// 扫到的页图数。
  final int pageCount;

  bool get selectable => pageCount > 0;

  /// 不可选的原因码。可选时为空串。
  String get blockedReason => pageCount > 0 ? '' : 'no-page';
}

/// 逐个扫描 [chapters]，得到可选项。
///
/// 🔴 页数判据走 `ProjectBootstrap.scanPageNames` —— 与真正建工程时**同一份
/// 扫描实现**。各写一遍会出现"列表里可选、点下去报 `chapter-has-no-page`"。
/// 这一步有磁盘 IO（只读目录项，不读文件头），所以调用方要放进异步流程里。
List<StudioChapterOption> studioChapterOptions({
  required String comicDirectory,
  required List<StudioChapterRef> chapters,
}) => [
  for (final ref in chapters)
    StudioChapterOption(
      ref: ref,
      pageCount: countStudioChapterPages(
        comicDirectory: comicDirectory,
        chapterName: ref.chapterName,
      ),
    ),
];

/// [chapterName] 这一章能扫出几页图。
int countStudioChapterPages({
  required String comicDirectory,
  required String chapterName,
}) => ProjectBootstrap.scanPageNames(
  comicDirectory: comicDirectory,
  chapterName: chapterName,
).length;

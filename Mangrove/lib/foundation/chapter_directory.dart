import 'package:mangrove/foundation/chapter_title_parser.dart';
import 'package:mangrove/foundation/comic_source/comic_source.dart';

/// 把任意字符串清洗成可安全用作单层目录名的片段。
///
/// 只处理 Windows/NTFS 与 POSIX 共同的非法字符；`.`/空格/方括号一律保留
/// （扫描器 `local_comic_scanner.dart` 对目录名除"不能有子目录"外没有限制）。
String sanitizePathSegment(String name) {
  final builder = StringBuffer();
  for (var i = 0; i < name.length; i++) {
    final char = name[i];
    if (char == '/' ||
        char == '\\' ||
        char == ':' ||
        char == '*' ||
        char == '?' ||
        char == '"' ||
        char == '<' ||
        char == '>' ||
        char == '|') {
      builder.write('_');
    } else {
      builder.write(char);
    }
  }
  return builder.toString();
}

/// 封面候选池的目录名（P12，2026-10-24）。
///
/// 一本漫画因季度更新会有多张封面，全部放进 `<漫画目录>/cover/`，文件名带语义
/// （`[cover]season(1).jpg`）。它**不是章节**：章节扫描、章节刷新、封面兜底
/// 三条路径都必须跳过它，否则详情页会凭空多出一个叫 "cover" 的假章节。
const coverDirectoryName = 'cover';

/// 目录名是否就是封面池（大小写不敏感，允许用户手写成 `Cover`）。
bool isCoverDirectoryName(String name) =>
    name.trim().toLowerCase() == coverDirectoryName;

/// 从封面文件名里读季度序号：`[cover]season(1).jpg` → 1。
///
/// 认 `season(1)` / `season 1` / `Season1` / 全角括号；读不出返回 null
/// （贺图、特典之类没有季度概念的文件走文件名兜底排序）。
int? coverSeasonOf(String fileName) {
  final match = RegExp(
    r'season\s*[\(（]?\s*(\d+)\s*[\)）]?',
    caseSensitive: false,
  ).firstMatch(fileName);
  if (match == null) return null;
  return int.tryParse(match.group(1) ?? '');
}

/// 已知源站标签的样子：`comix.to` 这种"带点的域名"，不含空格。
///
/// 只用来决定**显示时要不要露面**，不影响目录名本身——目录名里保留源站是为了
/// 同话不同源各自成目录，这条规则不能动。
final _siteTagPattern = RegExp(r'^[\w-]+(?:\.[\w-]+)+$');

/// 把**目录名**翻译成章节列表里的显示文案（P13，2026-10-24）。
///
/// 目录名是磁盘标识（`49 [Rokari Comics] [comix.to]`），直接当显示名太长，
/// 在窄屏上会被截成 `49 [Rokari C…`，看不出是哪一话。这里只改**显示**，
/// 不动 key——key 是读图时的路径来源，改名等于把已下载的图弄丢。
///
/// 规则：
/// - `49 [Rokari Comics] [comix.to]` → `第49话 · Rokari Comics`
/// - `116 [comix.to]` → `第116话`（方括号里只有源站，不算翻译组）
/// - `1` / `12.5` → `第1话` / `第12.5话`
/// - 不以数字开头的（`默認`、`番外`）→ 原样返回，别硬套"第X话"
String chapterDisplayName(String directoryName) {
  final name = directoryName.trim();
  if (name.isEmpty) return name;
  final match = RegExp(r'^(\d+(?:\.\d+)?)[\s_]*(.*)$').firstMatch(name);
  if (match == null) return name;
  final number = match.group(1)!;
  final rest = match.group(2)!.trim();
  final labels = <String>[];
  for (final bracket in RegExp(r'\[([^\]]*)\]').allMatches(rest)) {
    final text = (bracket.group(1) ?? '').trim();
    if (text.isEmpty) continue;
    // 源站标签不当翻译组显示：读者关心的是"谁翻的"，不是"从哪抓的"。
    if (_siteTagPattern.hasMatch(text)) continue;
    labels.add(text);
  }
  final suffix = labels.isEmpty ? '' : ' · ${labels.join(' ')}';
  return '第$number话$suffix';
}

/// **章节目录名的唯一真相。**
///
/// 下载侧（`ImagesDownloadTask`）、读取侧（`LocalManager.getImagesForComic`）、
/// 删除侧（`LocalManager.deleteComicChapters`）、缺失页表侧
/// （`chapterDirectoryId`）**必须全部走这里**。上一版把这同一条规则抄了
/// 四份，下载侧改名而读取侧没跟上就会"下完读不到"。
///
/// 规则：
/// - 版本化章节且该版本带组名 → `<话号> [组名]`，例如 `6 [Asura Scans]`。
///   这样同一话的多个翻译组各自成目录，不再互相覆盖。
/// - 其余情况（扁平、分组、版本化但取不到组名）→ 沿用旧规则
///   `parseChapterTitle(key).chapterNumber ?? key`，保证既有下载不会被改名。
///
/// 同名兜底：同一话号 + 同一组名出现多个版本时（例如同组两种语言），
/// 从第二个起追加 ` (2)`、` (3)`… 序号由 (chapters, chapterKey) 唯一决定，
/// 因此下载侧与读取侧算出的结果一定相同。
String chapterDirectoryName(ComicChapters? chapters, String chapterKey) {
  final base = _baseChapterDirectoryName(chapters, chapterKey);
  if (chapters == null || !chapters.isVersioned) return base;
  var seen = 0;
  var index = -1;
  for (final entry in chapters.allVersions) {
    if (_baseChapterDirectoryName(chapters, entry.version.chapterKey) != base) {
      continue;
    }
    if (entry.version.chapterKey == chapterKey) index = seen;
    seen++;
  }
  // 没找到自己（key 已不在 chapters 里）或没有重名 → 不追加后缀。
  if (index <= 0) return base;
  return '$base (${index + 1})';
}

String _baseChapterDirectoryName(ComicChapters? chapters, String chapterKey) {
  if (chapters != null && chapters.isVersioned) {
    final entry = chapters.versionEntryOf(chapterKey);
    final group = entry?.version.scanlationGroup?.trim() ?? '';
    if (entry != null && group.isNotEmpty) {
      // 话号用版本矩阵的**外层 key**（源给的话号），不是从 chapterKey 里
      // 正则抠出来的：comix.to 这类源的 chapterKey 是整条 URL，抠不出话号。
      return sanitizePathSegment('${entry.chapterNumber} [$group]');
    }
  }
  return sanitizePathSegment(
    parseChapterTitle(chapterKey).chapterNumber?.toString() ?? chapterKey,
  );
}

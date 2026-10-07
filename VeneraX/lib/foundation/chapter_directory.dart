import 'package:venera/foundation/chapter_title_parser.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';

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

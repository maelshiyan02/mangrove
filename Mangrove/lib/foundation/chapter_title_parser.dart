/// Parses chapter titles from various comic sources into structured data.
///
/// Source chapter titles come in many formats:
/// - "Ch.5 - Luna Toons" (comix.to)
/// - "Chapter 5" (generic)
/// - "第5话" (Chinese sources)
/// - "5" (pure number)
/// - "Ch.5" (no group)
///
/// This parser extracts the chapter number and scanlation group (if present)
/// and provides a formatted display title ("第5话" for Chinese display).
class ParsedChapterTitle {
  const ParsedChapterTitle({
    this.chapterNumber,
    this.scanlationGroup,
    required this.rawTitle,
  });

  /// Extracted chapter number, or null if the title doesn't contain one.
  final int? chapterNumber;

  /// Extracted scanlation group name, or null if not present.
  final String? scanlationGroup;

  /// The original title string as received from the source.
  final String rawTitle;

  /// Formatted display title: "第X话" when a chapter number was extracted,
  /// otherwise the raw title unchanged.
  String get displayTitle {
    if (chapterNumber != null) return '第$chapterNumber话';
    return rawTitle;
  }

  @override
  String toString() =>
      'ParsedChapterTitle(ch=$chapterNumber, group=$scanlationGroup, raw=$rawTitle)';
}

/// Parses a chapter title string into a [ParsedChapterTitle].
///
/// Supported patterns (checked in priority order):
/// 1. "Ch.5 - Luna Toons" / "Chapter 5 - Group" → ch + group
/// 2. "第5话" / "第 5 话" → ch only
/// 3. "5" (pure number) → ch only
/// 4. "Ch.5" / "Chapter 5" → ch only
/// 5. fallback → raw title only
ParsedChapterTitle parseChapterTitle(String title) {
  if (title.isEmpty) {
    return ParsedChapterTitle(rawTitle: title);
  }

  // Pattern 1: "Ch.5 - Luna Toons" or "Chapter 5 - Group"
  // Separators: -, –, —, :
  final chGroup = RegExp(
    r'(?:Ch\.|Chapter)\s*(\d+)\s*[-–—:]\s*(.+)',
    caseSensitive: false,
  ).firstMatch(title);
  if (chGroup != null) {
    final ch = int.tryParse(chGroup.group(1)!);
    final group = chGroup.group(2)!.trim();
    if (ch != null && group.isNotEmpty) {
      return ParsedChapterTitle(
        chapterNumber: ch,
        scanlationGroup: group,
        rawTitle: title,
      );
    }
  }

  // Pattern 2: "第5话" / "第 5 话" / "第5話"
  final chinese = RegExp(r'第\s*(\d+)\s*话?話?').firstMatch(title);
  if (chinese != null) {
    final ch = int.tryParse(chinese.group(1)!);
    if (ch != null) {
      return ParsedChapterTitle(
        chapterNumber: ch,
        rawTitle: title,
      );
    }
  }

  // Pattern 3: "5" (pure number)
  final pureNumber = int.tryParse(title.trim());
  if (pureNumber != null) {
    return ParsedChapterTitle(
      chapterNumber: pureNumber,
      rawTitle: title,
    );
  }

  // Pattern 4: "Ch.5" / "Chapter 5" (no group)
  final chOnly = RegExp(
    r'(?:Ch\.|Chapter)\s*(\d+)',
    caseSensitive: false,
  ).firstMatch(title);
  if (chOnly != null) {
    final ch = int.tryParse(chOnly.group(1)!);
    if (ch != null) {
      return ParsedChapterTitle(
        chapterNumber: ch,
        rawTitle: title,
      );
    }
  }

  // Pattern 5: fallback
  return ParsedChapterTitle(rawTitle: title);
}

/// 从「章节 key / 目录名 / 标题」里取出**可排序的话号**，读不出返回 null。
///
/// 这是全库唯一的"话号 → 数值"入口：章节列表排序、去重判定、下载顺序
/// 都走它，避免各处各写一条正则（写歪一条，那个入口就单独乱序）。
///
/// 认的写法（按优先级）：
/// - `第12话` / `第 12.5 话`（已经格式化过的显示名）
/// - `12` / `12.5`
/// - `120 [baozimh]` / `49 [Rokari Comics] [comix.to]`（目录名形态）
/// - `[zh-Hans] 120 [baozimh]`（P49 遗留的语言段，先剥掉再认）
///
/// 🔴 数字后紧跟字母/数字一律**不认**（P51，2026-10-27）。
/// 松一档的 `^(\d+)` 会把 UUID 的开头当成话号：`003b54f5-31b5-11f1-…`
/// 读成「第003话」，一本 63 话的书炸成 63 个胡话号。
///
/// 读不出话号**不是错误**：UUID key、`番外`、`默認` 都属此类。调用方该做的是
/// **保留源侧给的顺序**，而不是退回字典序 —— 字典序在没有话号时就是随机。
double? chapterNumberValueOf(String raw) {
  var name = raw.trim();
  if (name.isEmpty) return null;
  // 剥 P49 遗留的语言段（`[zh-Hans] `）。与 chapter_directory 的
  // splitChapterLanguageTag 同规则；这里是叶子模块，不能反向依赖它。
  name = name
      .replaceFirst(
        RegExp(r'^\[[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})?\]\s+'),
        '',
      )
      .trim();
  if (name.isEmpty) return null;
  final already = RegExp(r'^第\s*(\d+(?:\.\d+)?)\s*话').firstMatch(name);
  if (already != null) return double.tryParse(already.group(1)!);
  final lead = RegExp(r'^(\d+(?:\.\d+)?)(?![0-9A-Za-z])').firstMatch(name);
  if (lead != null) return double.tryParse(lead.group(1)!);
  return null;
}

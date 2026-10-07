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

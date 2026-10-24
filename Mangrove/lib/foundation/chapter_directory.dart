import 'dart:io';

import 'package:mangrove/foundation/chapter_title_parser.dart';
import 'package:mangrove/foundation/comic_source/comic_source.dart';
import 'package:mangrove/utils/io.dart';

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

/// 章节 chip 的**主标题**：只留「第N话」（P16，2026-10-24）。
///
/// 章节列表的格子只有 44px 高、宽不到 220px，塞进
/// `11 [Rokari Comics] [comix.to]` 会被截成 `11 [Rokari C…`，连话号都读不全。
/// 组名和站点名是**分类标识**（分组 tab / 次要标签），不该占主标题。
///
/// 与 [chapterDisplayName] 的区别：那个会拼 ` · 组名` 供文字列表用，
/// 这里**只出话号**。两者都不改 key，改的只是显示。
///
/// - `11 [Rokari Comics] [comix.to]` → `第11话`
/// - `第49话 · Rokari Comics`（已经是显示名）→ `第49话`
/// - `116 [comix.to]` → `第116话`
/// - `12.5` → `第12.5话`
/// - 非数字开头（`番外`）→ 原样返回
String chapterNumberLabel(String keyOrTitle) {
  final name = keyOrTitle.trim();
  if (name.isEmpty) return name;
  // 已经是显示名（域库里存的历史数据），剥掉后缀即可，别再包一层。
  final already = RegExp(r'^第\s*(\d+(?:\.\d+)?)\s*话').firstMatch(name);
  if (already != null) return '第${already.group(1)}话';
  final match = RegExp(r'^(\d+(?:\.\d+)?)[\s_]*(.*)$').firstMatch(name);
  if (match == null) return name;
  return '第${match.group(1)}话';
}

/// 已知源 key → 目录名里用的站点标签（D1，2026-10-24）。
///
/// 目录名要能**独立说明这一话是谁翻的、从哪抓的**。标签用**稳定的网站名**
/// 而不是当前解析域名：包子漫画的域名一年换好几个（baozimh → webmota →
/// kukuc.co），写进目录名就废了。未登记的源直接降级用 key 本身，不丢信息。
const _sourceSiteTags = <String, String>{
  'comix_to': 'comix.to',
  'comix': 'comix.to',
  'baozi': 'baozimh',
  'copy_manga': 'copymanga',
  'comick': 'comick',
  'manga_dex': 'mangadex',
  'Komiic': 'komiic',
  'dm5': 'dm5',
  'goda': 'goda',
  'manhuaren': 'manhuaren',
  'mycomic': 'mycomic',
};

/// 把源 key 转成目录名里的站点标签；本地漫画返回空串（不写站标）。
String sourceSiteTag(String sourceKey) {
  final key = sourceKey.trim();
  if (key.isEmpty || key == 'local') return '';
  return _sourceSiteTags[key] ?? key;
}

/// 反过来：把站点标签认回源 key。迁移脚本与"从目录名猜来源"用。
///
/// 未登记的标签原样返回（它可能就是 key 本身）。
String sourceKeyOfSiteTag(String siteTag) {
  final tag = siteTag.trim();
  if (tag.isEmpty) return '';
  for (final entry in _sourceSiteTags.entries) {
    if (entry.value.toLowerCase() == tag.toLowerCase()) return entry.key;
  }
  return tag;
}

/// 章节目录名里的一份结构化信息（D1 兼容读取用）。
class ChapterDirectoryRef {
  const ChapterDirectoryRef({
    required this.name,
    required this.number,
    this.groups = const <String>[],
    this.site,
    this.variant = 1,
  });

  /// 原始目录名。
  final String name;

  /// 话号（保留源给的字符串形态，`12.5` 这类半话不会被截断）。
  final String number;

  /// 翻译组名；不含站点标签。
  final List<String> groups;

  /// 站点标签（`comix.to`），没有则 null。
  final String? site;

  /// 同话同组重名时的 ` (2)`、` (3)` 序号；无名后缀为 1。
  final int variant;

  String get groupKey => groups.map((e) => e.toLowerCase()).join('|');
}

final _leadingNumberPattern = RegExp(r'^\s*(\d+(?:\.\d+)?)\s*(.*)$');
final _bracketPattern = RegExp(r'\[([^\]]*)\]');
final _variantSuffixPattern = RegExp(r'\((\d+)\)\s*$');

/// 解析一个章节目录名，读不出话号返回 null。
///
/// 认这几种历史/现行写法，用来做**兼容读取**：
/// - `49 [Rokari Comics] [comix.to]` （D1 新规范）
/// - `49 [Rokari Comics]`            （P13 旧规范）
/// - `116 [comix.to]`                （只有站标）
/// - `5` / `12.5` / `5 (2)`          （手抄 / 重名）
ChapterDirectoryRef? parseChapterDirectoryName(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return null;
  final match = _leadingNumberPattern.firstMatch(trimmed);
  if (match == null) return null;
  final number = match.group(1)!;
  var rest = match.group(2)!.trim();

  var variant = 1;
  final variantMatch = _variantSuffixPattern.firstMatch(rest);
  if (variantMatch != null) {
    variant = int.tryParse(variantMatch.group(1)!) ?? 1;
    rest = rest.substring(0, variantMatch.start).trim();
  }

  final groups = <String>[];
  String? site;
  for (final bracket in _bracketPattern.allMatches(rest)) {
    final text = (bracket.group(1) ?? '').trim();
    if (text.isEmpty) continue;
    if (_siteTagPattern.hasMatch(text)) {
      site = text;
    } else {
      groups.add(text);
    }
  }
  // 括号外的裸文字也算组名（`5 Rokari Comics` 这种手写）。
  final loose = rest.replaceAll(_bracketPattern, '').trim();
  if (loose.isNotEmpty) groups.add(loose);

  return ChapterDirectoryRef(
    name: trimmed,
    number: number,
    groups: groups,
    site: site,
    variant: variant,
  );
}

/// [candidate] 与 [template] 是不是**同一话的同一个版本**，返回匹配分
/// （越高越可信；-1 表示不匹配）。
///
/// 只比"语义骨架"，不比字面：新规范比旧规范多一个 `[站点]`，这正是要兼容的
/// 差异；组名不同则一定是别的版本，必须拒绝，否则会把别组的图当成本组的。
int chapterDirectoryMatchScore(String candidate, String template) {
  if (candidate == template) return 100;
  final a = parseChapterDirectoryName(candidate);
  final b = parseChapterDirectoryName(template);
  if (a == null || b == null) return -1;
  if (a.number != b.number) return -1;
  if (a.variant != b.variant) return -1;
  var score = 10;
  if (b.groups.isNotEmpty) {
    // 模板点名了组 → 候选必须同组，否则是别人的版本。
    if (a.groupKey != b.groupKey) return -1;
    score += 20;
  }
  if (b.site != null && a.site == b.site) score += 5;
  return score;
}

/// 在 [parentDirPath] 下找出与 [templateName] 对应的**真实**目录名。
///
/// 磁盘上的目录名可能是旧规范（`49 [Rokari Comics]`）、新规范（多带站标）或
/// 手抄名。找不到就返回 null，由调用方决定要不要再试别的回退。
///
/// 这个函数只**读**目录，不动磁盘：改名一律交给迁移脚本，程序运行期不做
/// 隐式重命名（用户可能正开着资源管理器）。
String? resolveChapterDirectoryName(
  String parentDirPath,
  String templateName,
) {
  final template = templateName.trim();
  if (template.isEmpty) return null;
  final parent = Directory(parentDirPath);
  if (!parent.existsSync()) return null;
  if (Directory(FilePath.join(parentDirPath, template)).existsSync()) {
    return template;
  }
  String? best;
  var bestScore = 0;
  for (final entity in parent.listSync()) {
    if (entity is! Directory) continue;
    final name = entity.name;
    if (name.startsWith('.')) continue;
    final score = chapterDirectoryMatchScore(name, template);
    if (score > bestScore) {
      bestScore = score;
      best = name;
    }
  }
  return best;
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
/// - 传了 [siteTag]（D1 新规范）→ 末尾再补一个 `[站点]`，例如
///   `6 [Asura Scans] [asuracomic.net]`。**基础命名三件套 = 话号 + 翻译组 +
///   来源站点**，三者齐了目录名本身就能自证身份，跨设备拷来也能认出来。
/// - 其余情况（扁平、分组、版本化但取不到组名）→ 沿用旧规则
///   `parseChapterTitle(key).chapterNumber ?? key`，保证既有下载不会被改名。
///   解析不出话号时**不加**站标：那时目录名就是原始 key，加了反而更难认。
///
/// 兼容性：[siteTag] 为 null 时输出与旧版**逐字节相同**，因此读取侧不传也能
/// 命中老目录；新老并存由 [resolveChapterDirectoryName] 负责抹平。
///
/// 同名兜底：同一话号 + 同一组名出现多个版本时（例如同组两种语言），
/// 从第二个起追加 ` (2)`、` (3)`… 序号由 (chapters, chapterKey) 唯一决定，
/// 因此下载侧与读取侧算出的结果一定相同。
String chapterDirectoryName(
  ComicChapters? chapters,
  String chapterKey, {
  String? siteTag,
}) {
  final site = (siteTag ?? '').trim();
  final base = _baseChapterDirectoryName(chapters, chapterKey, site);
  if (chapters == null || !chapters.isVersioned) return base;
  var seen = 0;
  var index = -1;
  for (final entry in chapters.allVersions) {
    if (_baseChapterDirectoryName(chapters, entry.version.chapterKey, site) !=
        base) {
      continue;
    }
    if (entry.version.chapterKey == chapterKey) index = seen;
    seen++;
  }
  // 没找到自己（key 已不在 chapters 里）或没有重名 → 不追加后缀。
  if (index <= 0) return base;
  return '$base (${index + 1})';
}

String _baseChapterDirectoryName(
  ComicChapters? chapters,
  String chapterKey,
  String siteTag,
) {
  final site = siteTag.isEmpty ? '' : ' [$siteTag]';
  if (chapters != null && chapters.isVersioned) {
    final entry = chapters.versionEntryOf(chapterKey);
    final group = entry?.version.scanlationGroup?.trim() ?? '';
    if (entry != null && group.isNotEmpty) {
      // 话号用版本矩阵的**外层 key**（源给的话号），不是从 chapterKey 里
      // 正则抠出来的：comix.to 这类源的 chapterKey 是整条 URL，抠不出话号。
      return sanitizePathSegment('${entry.chapterNumber} [$group]$site');
    }
  }
  final number = parseChapterTitle(chapterKey).chapterNumber?.toString();
  if (number == null) {
    // 连话号都读不出来：保持旧行为，原样用 key 当目录名，不追加站标。
    return sanitizePathSegment(chapterKey);
  }
  return sanitizePathSegment('$number$site');
}

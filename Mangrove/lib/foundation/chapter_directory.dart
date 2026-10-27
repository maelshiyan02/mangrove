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

/// 从封面文件名里读**季度**序号：`[cover]season(1).jpg` → 1。
///
/// 这是**韩漫**的封面维度。韩国网漫把长连载切成"季"（시즌），一季几十话，
/// 季末标注 Season Finale，休载几个月再开下一季，每开一季平台就换一张主视觉。
/// 所以韩漫封面按 `season(N)` 编号——N 是季，不是卷。
///
/// 认 `season(1)` / `season 1` / `Season1` / 全角括号；读不出返回 null
/// （贺图、特典之类没有季度概念的文件走文件名兜底排序，见 [coverEventOf]）。
int? coverSeasonOf(String fileName) {
  final match = RegExp(
    r'season\s*[\(（]?\s*(\d+)\s*[\)）]?',
    caseSensitive: false,
  ).firstMatch(fileName);
  if (match == null) return null;
  return int.tryParse(match.group(1) ?? '');
}

/// 从封面文件名里读**单行本卷号**：`[KR][cover]vol(3).jpg` → 3（P18，2026-10-24）。
///
/// 这是**日漫**的封面维度。日本漫画按单行本（単行本）出版，一卷一张新封面，
/// 而且卷封面往往和杂志连载时的彩页完全不是一张图，所以要单独成一系列。
///
/// 和 season 是两套体系，不是一条时间轴上的两个刻度：韩漫极少出单行本
/// （Kakao 上 `[단행본]` 基本都是原著**小说**的单行本，不是漫画），日漫
/// 也基本不按季换主视觉。一本漫画正常只会用其中一种；真出现混用时按
/// [coverVersionOf] 取较大者，语言仅在相同时决胜。
///
/// 认 `vol(3)` / `vol 3` / `volume3` / 全角括号。
int? coverVolumeOf(String fileName) {
  final match = RegExp(
    r'(?:vol|volume)\s*[\(（]?\s*(\d+)\s*[\)）]?',
    caseSensitive: false,
  ).firstMatch(fileName);
  if (match == null) return null;
  return int.tryParse(match.group(1) ?? '');
}

/// 封面是不是**节日贺图 / 特别插画**：`[KR][cover]event(chuseok).jpg`
/// → `chuseok`（P19，2026-10-24）。
///
/// 为什么要单独一类，而不是塞进 season：韩国网漫平台每逢节日会**整批换掉
/// 连载作品的缩略图**，这些图不是"新的一季"，只是当期活动的视觉。已核实的
/// 例子（Naver 官方新闻稿）：
/// - 2026-04-01 愚人节：约 900 部连载作品缩略图换成 SNS 概念版，500 部最新
///   免费话次追加作者手绘的愚人节特别画面；
/// - 2025-04-30 黄金连休（5/1~5/5，含儿童节）：约 900 部换成"连休主角也放假"
///   主题缩略图，配最新话次特别插画；
/// - 2021-02-11 春节：游戏角色穿韩服的"설맞이 축전"。
/// 秋夕（추석）同理，画面符号是韩服 + 柿子树 + 月兔 + 满月。
///
/// 用 `season(N)` 编码贺图有两个坏处：把"换活动图"误读成"推进了一季"，
/// 且默认封面会被一张兔子图顶掉。所以贺图单独成 `event(名)`，排序时整体
/// 排在正篇封面之后（没有版本号 → [coverVersionOf] 返回 null）。
///
/// 认 `event(chuseok)` / `event chuseok` / `event=chuseok`，大小写不敏感，
/// 名字取 `[a-z0-9-_]`。
String? coverEventOf(String fileName) {
  final match = RegExp(
    r'event\s*[\(（=:]\s*([a-z0-9_-]+)',
    caseSensitive: false,
  ).firstMatch(fileName);
  if (match == null) return null;
  final tag = match.group(1)?.trim().toLowerCase() ?? '';
  return tag.isEmpty ? null : tag;
}

/// 封面的"新旧序号"：季号与卷号取较大者；贺图与无名文件返回 null（排最后）。
///
/// 排序只认这一个数。若把季、卷当两个维度比较，同一本漫画里
/// `[CN][cover]season(1)` 会永远压住 `[KR][cover]vol(4)`，读者看到的是旧的
/// 网络版主视觉，而不是最新的单行本封面。合成一维后"谁大谁新"，
/// 语言只在**新旧相同时**才参与决胜（见 [coverLanguageRank]）。
///
/// 贺图刻意没有版本号：它是当期活动图（见 [coverEventOf]），不是连载推进，
/// 默认封面应当是正篇主视觉，读者想用贺图自己去封面选择器里挑。
int? coverVersionOf(String fileName) {
  final season = coverSeasonOf(fileName);
  final volume = coverVolumeOf(fileName);
  if (season == null) return volume;
  if (volume == null) return season;
  return season > volume ? season : volume;
}

/// 章节语种的规范写法（P49，2026-10-27）。
///
/// ## 为什么目录名要加语言维度
///
/// 复合漫画（一本书绑多个源、甚至多个语种）里，**"同一话的简体版、繁体版、
/// 英文版、日文版"是四份不同的内容**，不是同一话的四个镜像。只靠 `[站点]`
/// 区分不够：comix.to / mangadex / comick 这类源**同一个站点同时供多种语言**，
/// 站点标签相同、话号相同，目录名就会撞车；而读者想看的恰恰是"我要中文的
/// 那一版"。
///
/// 所以目录名的规范从三件套升级成四件套，语言放**最前面**（分类的第一维）：
///
/// ```
/// [zh-Hans] 120 [baozimh]            ← 简体，包子源，无组名
/// [zh-Hans] 5 [Rokari Comics] [comix.to]
/// [en]      5 [Asura Scans] [comix.to]
/// ```
///
/// 简繁必须分开写：漫画汉化里"简/繁"造成的差异比"中/英"更常见，
/// 用 `zh-Hans` / `zh-Hant`（BCP 47 子标签）而不是含糊的 `zh`。
const chapterLanguageTags = <String>[
  'zh-Hans',
  'zh-Hant',
  'en',
  'ja',
  'ko',
];

/// 目录名最前面那个方括号是不是**语言段**（只有登记过的才认）。
///
/// 刻意窄判定：`[Rokari Comics]`（带空格）、`[comix.to]`（带点）都不会被
/// 当成语言，所以老目录名一个都不会被误解析。
final _leadingLanguagePattern = RegExp(r'^\s*\[([^\[\]]{2,12})\]\s*');

/// 把各种写法归一成规范语言标签；认不出返回 null。
///
/// 归一的口径是"读者关心的是哪国话/哪种字形"，不是完整 BCP 47：
/// `zh` / `zh-cn` / `chs` / `CN` → `zh-Hans`；`zh-tw` / `zh-hk` / `cht` → `zh-Hant`；
/// `jp` / `jpn` → `ja`；`kr` / `kor` → `ko`；其余两字母 ISO 639-1 原样保留
/// （`id` 印尼、`th` 泰、`vi` 越、`es` 西……），不维护全表。
String? normalizeChapterLanguage(String? raw) {
  final text = (raw ?? '').trim();
  if (text.isEmpty) return null;
  final lower = text.toLowerCase().replaceAll('_', '-');
  switch (lower) {
    case 'zh':
    case 'zh-cn':
    case 'zh-sg':
    case 'zh-my':
    case 'zh-hans':
    case 'chs':
    case 'cn':
    case 'gb':
      return 'zh-Hans';
    case 'zh-tw':
    case 'zh-hk':
    case 'zh-mo':
    case 'zh-hant':
    case 'cht':
    case 'tw':
    case 'hk':
    case 'big5':
      return 'zh-Hant';
    case 'en':
    case 'eng':
      return 'en';
    case 'ja':
    case 'jp':
    case 'jpn':
      return 'ja';
    case 'ko':
    case 'kr':
    case 'kor':
      return 'ko';
  }
  if (lower.startsWith('zh-')) {
    return lower.contains('hant') || lower.contains('tw') || lower.contains('hk')
        ? 'zh-Hant'
        : 'zh-Hans';
  }
  if (RegExp(r'^[a-z]{2}(-[a-z]{2,4})?$').hasMatch(lower)) return lower;
  return null;
}

/// 语言标签的**中文短名**，给章节列表的小字/筛选 chip 用。
///
/// 未知语种返回原标签本身（例如 `id` → `id`），不猜成中文。
String chapterLanguageLabel(String? language) {
  switch (normalizeChapterLanguage(language)) {
    case 'zh-Hans':
      return '简中';
    case 'zh-Hant':
      return '繁中';
    case 'en':
      return '英';
    case 'ja':
      return '日';
    case 'ko':
      return '韩';
  }
  final text = (language ?? '').trim();
  return text.isEmpty ? '' : text;
}

/// 拆出目录名最前面的语言段 → (语言标签 或 null, 去掉语言段后的名字)。
///
/// 老目录名（`120 [baozimh]`）没有语言段，原样返回，`null` 表示"未标注"。
/// 这个函数是**向后兼容的闸门**：所有解析入口都先过它，于是加语言维度不会
/// 让既有下载变成"读不到"。
(String?, String) splitChapterLanguageTag(String name) {
  final match = _leadingLanguagePattern.firstMatch(name);
  if (match == null) return (null, name.trim());
  final normalized = normalizeChapterLanguage(match.group(1));
  if (normalized == null) return (null, name.trim());
  return (normalized, name.substring(match.end).trim());
}

/// 源 → 该源章节的**默认语种**（P49，2026-10-27）。
///
/// 只登记"一站一语种"的中文站；comix.to / mangadex / comick 这类
/// **多语种共站**的源刻意不登记——它们的语种必须来自章节自身的
/// `lang` 字段，凭源名猜会把英文版标成中文版，比不标更糟。
const _sourceDefaultLanguages = <String, String>{
  'baozi': 'zh-Hans', // 包子漫画（app 端同源）
  'copy_manga': 'zh-Hans', // 拷贝漫画
  'dm5': 'zh-Hans',
  'manhuaren': 'zh-Hans',
  'Komiic': 'zh-Hans',
  'mycomic': 'zh-Hans',
  'goda': 'zh-Hans',
  'manhuagui': 'zh-Hans',
  'zaimanhua': 'zh-Hans',
  'rumanhua': 'zh-Hans',
  'komiic': 'zh-Hans',
};

/// 某源的章节默认语种；未登记返回 null（= 不写语言段，退回老命名）。
String? defaultChapterLanguageOf(String? sourceKey) {
  final key = (sourceKey ?? '').trim();
  if (key.isEmpty || key == 'local') return null;
  return normalizeChapterLanguage(_sourceDefaultLanguages[key]);
}

/// 已知源站标签的样子：`comix.to` 这种"带点的域名"，不含空格。
///
/// 只用来决定**显示时要不要露面**，不影响目录名本身——目录名里保留源站是为了
/// 同话不同源各自成目录，这条规则不能动。
final _siteTagPattern = RegExp(r'^[\w-]+(?:\.[\w-]+)+$');

/// 封面的语言标识（P17，2026-10-24）。
///
/// 同一本漫画可能有多张封面：韩文原版、简体中文正版（快看）、英文版……文件名
/// 里必须能看出**这张图是哪国语言的封面**，否则多语言候选池混在一起只能靠
/// 猜。注意这是**封面版本的语言**，不是漫画的原始国籍——一本韩国漫画的
/// 中文版封面标 `CN`，不标 `KR`。
const coverLanguages = <String>['CN', 'EN', 'KR', 'JP'];

/// 一个方括号标签是不是**站点标签**（`comix.to` 带点域名，或 `baozimh`
/// 这类登记过的站名）。
///
/// 为什么要把登记过的站名也算进来：`_siteTagPattern` 只认带点的域名，
/// 而包子源的目录名写作 `116 [baozimh]`——不带点，于是被当成"翻译组"，
/// 章节列表里整本挂一行 `baozimh`，把真正的组信息挤没了。
bool isSourceSiteTag(String text) {
  final tag = text.trim();
  if (tag.isEmpty) return false;
  if (_siteTagPattern.hasMatch(tag)) return true;
  final lower = tag.toLowerCase();
  for (final site in _sourceSiteTags.values) {
    if (site.toLowerCase() == lower) return true;
  }
  return false;
}

/// 章节 key / 目录名是否形如 UUID（拷贝漫画的章节 id：
/// `39244565-0629-11f1-b4dc-fa163e02432f`）。
///
/// UUID 没有任何可读的话号，**绝不能**拿去当章节号解析——否则它首段若是全数字
/// （`39244565-…`），松一档的 `^(\d+)` 会读成「第39244565话」，整本章节列表
/// 炸成 63 个胡话号（P52，2026-10-27 修《第一次告白》乱码）。**认的是完整
/// 8-4-4-4-12 十六进制形态**，普通目录名（`49 [Rokari Comics]`）与纯数字
/// （`120`）都不会命中，不会误伤。
bool isUuidLike(String s) =>
    RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
        .hasMatch(s.trim());

/// 话号 + 余下部分的**严格**切分：`120 [baozimh]` → (`120`, `[baozimh]`)。
///
/// 🔴 数字后面必须**不是字母/数字**（P51，2026-10-27）。
///
/// 松一点的 `^(\d+)` 会把 UUID 的开头几位当成话号：`003b54f5-31b5-11f1-…
/// fa163e02432f` 会被读成「第003话」，于是整本章节列表变成
/// 第0话 / 第01话 / 第003话 / 第065话 / 第2820话 / 第39244559话 ——
/// 一本 63 话的书被拆成 63 个互不相干的胡话号（用户 2026-10-27 报的现象）。
///
/// 认的形态：
/// - `12` / `12.5`（纯数字，可带小数）
/// - `120 [baozimh]` / `49 [Rokari Comics] [comix.to]`（数字 + 空格 + 方括号）
/// - `12_x` / `12 x`（数字 + 空格/下划线 + 文字）
/// 不认：`003b54f5-…`（UUID）、`v2`、`番外`。
({String number, String rest})? splitLeadingChapterNumber(String name) {
  // P52：UUID 形态（拷贝漫画 key）没有任何可读话号，直接判无——否则首段全数字
  // （`39244565-…`）会被当话号，章节列表炸成 第39244565话 这类乱码。
  if (isUuidLike(name)) return null;
  final match = RegExp(r'^(\d+(?:\.\d+)?)(?![0-9A-Za-z])[\s_]*').firstMatch(name);
  if (match == null) return null;
  return (
    number: match.group(1)!,
    rest: name.substring(match.end).trim(),
  );
}

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
/// - 不以数字开头的（`默認`、`番外`、UUID）→ 原样返回，别硬套"第X话"
String chapterDisplayName(String directoryName) {
  // P49：先剥掉最前面的语言段（`[zh-Hans] 120 [baozimh]` → `120 [baozimh]`）。
  // P51 起写入侧不再生成语言段，但别的设备/历史数据里还可能有，读取侧必须兼容。
  final name = splitChapterLanguageTag(directoryName).$2;
  if (name.isEmpty) return name;
  final lead = splitLeadingChapterNumber(name);
  if (lead == null) return name;
  final number = lead.number;
  final rest = lead.rest;
  final labels = <String>[];
  for (final bracket in RegExp(r'\[([^\]]*)\]').allMatches(rest)) {
    final text = (bracket.group(1) ?? '').trim();
    if (text.isEmpty) continue;
    // 源站标签不当翻译组显示：读者关心的是"谁翻的"，不是"从哪抓的"。
    if (isSourceSiteTag(text)) continue;
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
/// - 非数字开头（`番外`、UUID）→ 原样返回
String chapterNumberLabel(String keyOrTitle) {
  // P49：语言段在最前面，先剥掉再认话号。
  final name = splitChapterLanguageTag(keyOrTitle).$2;
  if (name.isEmpty) return name;
  // 已经是显示名（域库里存的历史数据），剥掉后缀即可，别再包一层。
  final already = RegExp(r'^第\s*(\d+(?:\.\d+)?)\s*话').firstMatch(name);
  if (already != null) return '第${already.group(1)}话';
  final lead = splitLeadingChapterNumber(name);
  if (lead == null) return name;
  return '第${lead.number}话';
}

/// 从封面文件名里读语言标识：`[KR][cover]season(1).jpg` → `KR`。
///
/// 认 `[CN]` / `[EN]` / `[KR]` / `[JP]` 四种（大小写不敏感）。老命名
/// （`[cover]season(1).jpg`）没有语言段，返回 null——调用方把它排在最后，
/// 于是"新抓的多语言封面"会自然顶掉老的无语言封面，无需额外迁移。
String? coverLanguageOf(String fileName) {
  for (final match in RegExp(r'\[([A-Za-z]{2})\]').allMatches(fileName)) {
    final code = match.group(1)!.toUpperCase();
    if (coverLanguages.contains(code)) return code;
  }
  return null;
}

/// 同季度多语言封面的默认优先级：韩文原版 > 简体中文 > 英文 > 日文。
///
/// 原版排第一不是"崇洋"：原版封面通常带原作标题字（韩文/日文 Logo 完整），
/// 翻译版封面要么被重新排版、要么干脆是无字插画，信息量反而更少。中文版
/// 排在第二位，原因是没有原版时才轮到它。
int coverLanguageRank(String? code) {
  const order = ['KR', 'CN', 'EN', 'JP'];
  if (code == null) return order.length;
  final index = order.indexOf(code.toUpperCase());
  return index < 0 ? order.length : index;
}

/// 封面候选池里给每张图配的短标签（P19，2026-10-24）。
///
/// 文件名本身就是元数据，但 `[KR][cover]event(cherry-blossom).jpg` 这种
/// 塞不进网格卡片，缩略图下只能显示成 `[KR][cover]e…`。所以抽成
/// 「第3季 · 韩」「贺图 · 秋夕」这样的短语，让读者一眼分清**哪张是正篇季
/// 封面、哪张只是当期活动图**——这正是分 season/vol/event 三类的原因。
///
/// 未知写法返回 null，卡片就不显示标签（不猜）。
String? coverBadgeOf(String fileName) {
  const langNames = {'CN': '中', 'EN': '英', 'KR': '韩', 'JP': '日'};
  final lang = langNames[coverLanguageOf(fileName)];
  final event = coverEventOf(fileName);
  if (event != null) {
    const names = {
      'chuseok': '秋夕',
      'seollal': '春节',
      'april-fools': '愚人节',
      'cherry-blossom': '樱花季',
      'christmas': '圣诞',
      'halloween': '万圣节',
      'valentine': '情人节',
      'holiday': '连休',
    };
    final label = '贺图 · ${names[event] ?? event}';
    return lang == null ? label : '$label · $lang';
  }
  String? version;
  final season = coverSeasonOf(fileName);
  if (season != null) {
    version = '第$season季';
  } else {
    final volume = coverVolumeOf(fileName);
    if (volume != null) version = '第$volume卷';
  }
  if (version == null) return lang;
  return lang == null ? version : '$version · $lang';
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
    this.language,
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

  /// 语言标签（`zh-Hans` / `en`…）；老目录名没有语言段时为 null（P49）。
  final String? language;

  String get groupKey => groups.map((e) => e.toLowerCase()).join('|');
}

// 🔴 数字后面必须不是字母/数字（P51）。否则 UUID 开头的 `003b54f5-31b5-…`
// 会被解析成「第003话」，一本 63 话的书会炸成 63 个胡话号。
final _leadingNumberPattern = RegExp(
  r'^\s*(\d+(?:\.\d+)?)(?![0-9A-Za-z])\s*(.*)$',
);
final _bracketPattern = RegExp(r'\[([^\]]*)\]');
final _variantSuffixPattern = RegExp(r'\((\d+)\)\s*$');

/// 解析一个章节目录名，读不出话号返回 null。
///
/// 认这几种历史/现行写法，用来做**兼容读取**：
/// - `[zh-Hans] 49 [Rokari Comics] [comix.to]` （P49 新规范，语言在最前）
/// - `49 [Rokari Comics] [comix.to]` （D1 新规范）
/// - `49 [Rokari Comics]`            （P13 旧规范）
/// - `116 [comix.to]`                （只有站标）
/// - `5` / `12.5` / `5 (2)`          （手抄 / 重名）
ChapterDirectoryRef? parseChapterDirectoryName(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return null;
  // P49：语言段在最前面，先剥掉再走老解析，老目录名（无语言段）行为不变。
  final split = splitChapterLanguageTag(trimmed);
  final language = split.$1;
  final body = split.$2;
  final match = _leadingNumberPattern.firstMatch(body);
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
    if (isSourceSiteTag(text)) {
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
    language: language,
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
  // P49：两边都标了语种却不同 → 一定是别的语言版本，不能互相顶替。
  // 只有一边标了语种（老目录没有语言段）则放行——那正是要兼容的差异。
  if (a.language != null &&
      b.language != null &&
      a.language != b.language) {
    return -1;
  }
  if (a.language != null && b.language != null) score += 20;
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
/// 🔴 **语言段永远不进目录名**（P51，2026-10-27 定案）。
///
/// P49 曾经在最前面加过 `[zh-Hans] `，理由（语言是第一分类维度）本身没错，
/// 但落点错了 —— 目录名同时是**本地漫画的章节 key**和**排序依据**：
/// 加了前缀，key 就从 `"120"` 变成 `"[zh-Hans] 120 [baozimh]"`，
/// `_leadingChapterNumber` 抠不出数字、排序退化成字典序
/// （第 0 话、第 1 话、第 10 话、第 100 话…），整套章节列表直接烂掉；
/// 而且源侧下一轮同步会按它自己的规则重新命名，我们改的这层迟早被覆盖。
///
/// 所以语言只存**记录表**：`comic_field_overrides.chapter_languages`
/// （读取见 [ComicOverrideStore.chapterLanguageOf]）。目录名只归源站所有。
///
/// 兼容性：[siteTag] 为 null 时输出与旧版**逐字节相同**，
/// 因此读取侧不传也能命中老目录；新老并存由 [resolveChapterDirectoryName] 负责抹平。
/// 读取侧仍会剥掉历史遗留的语言段（[splitChapterLanguageTag]），
/// 但写入侧永远不再生成。
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
    if (_baseChapterDirectoryName(
          chapters,
          entry.version.chapterKey,
          site,
        ) !=
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
    final number = parseChapterTitle(chapterKey).chapterNumber?.toString();
    if (number == null) return sanitizePathSegment(chapterKey);
    return sanitizePathSegment('$number$site');
  }
  final number = parseChapterTitle(chapterKey).chapterNumber?.toString();
  if (number == null) {
    // 连话号都读不出来：保持旧行为，原样用 key 当目录名，不追加站标。
    return sanitizePathSegment(chapterKey);
  }
  return sanitizePathSegment('$number$site');
}

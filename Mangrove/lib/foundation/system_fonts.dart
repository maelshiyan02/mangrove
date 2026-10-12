// 系统字体探测（2026-10-11 · ⑦a）。
//
// 🔴 **为什么有这个文件**：打包字体（`bundled_fonts.dart`）只有 4 个族
// （Noto Sans SC/KR 的 Regular/Bold），而 Windows 一台机器上通常装着上百个
// 字体。用户拍板的取舍是「**不打包，改用系统字体探测**」——零包体增长、
// 可选字体极多，代价是换机器可能缺字。
//
// 🔴 **与 A05 §3 契约的关系（就地说明，不是推翻）**：
// 原契约说「未注册的字族必须显式落到打包字体」。本文件把它**扩展**成三档：
//   打包字体 → 系统字体 → 打包字体（回退终点）
// `primaryBundledFamily` **仍然**是回退终点，`_aliasToBundled` 的历史别名
// **仍然**优先于未知回落 ⇒ **旧工程（FT 默认 "Microsoft YaHei UI"）的行为
// 一个字节都不变**。系统字体只在用户**主动选**时才生效（见
// `bundled_fonts.resolveFamily` 的第 5 条规则）。
//
// ## 只有纯逻辑，没有 Flutter
// 解析部分（sfnt 头 / name 表 / cmap 表）全部是纯函数，输入 `Uint8List`
// 输出 `SystemFontInfo` ⇒ headless 可以拿合成字节与真实字体文件做正反断言，
// 不需要渲染表面（A01 §3）。文件 I/O 只在 [scanSystemFonts] 一处。
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:mangrove/foundation/log.dart';

/// 用于判断「这个字体能不能显示这种文字」的文种类别。
enum FontScript {
  latin('Latin', '拉丁'),
  kana('Kana', '假名'),
  hangul('Hangul', '谚文'),
  cjk('CJK', '汉字'),
  punctuation('CJK punct', '中日标点');

  const FontScript(this.english, this.chinese);

  final String english;
  final String chinese;
}

/// 判定「支持该文种」的覆盖率门槛。
///
/// 取 0.9 而不是 1.0：CJK 字体几乎都是按「常用字集合」做的，缺一两个罕见
/// 码位不代表不支持；而缺 10% 就已经会在实际译文里出现豆腐块了。
const double scriptCoverageThreshold = 0.9;

/// 一个字体文件的探测结果。
class SystemFontInfo {
  const SystemFontInfo({
    required this.family,
    required this.subfamily,
    required this.weight,
    required this.italic,
    required this.path,
    required this.codepoints,
    required this.coverage,
  });

  /// sfnt `name` 表里的 family（优先 typographic family 16，回落 1）。
  final String family;

  /// sfnt `name` 表的 subfamily（17 / 2），用于推断 weight 与 italic。
  final String subfamily;

  /// `OS/2.usWeightClass`，缺失时由 [subfamily] 推断，100..900。
  final int weight;

  /// subfamily 含 "italic"/"oblique"。
  final bool italic;

  /// 字体文件在磁盘上的路径 —— 面板不显示，但去重与诊断要靠它。
  final String path;

  /// cmap 覆盖的码位总数（format 4 按段累加，format 12 按组累加）。
  final int codepoints;

  /// 各类文种的覆盖率 0..1。
  final Map<FontScript, double> coverage;

  bool covers(FontScript script) =>
      (coverage[script] ?? 0.0) >= scriptCoverageThreshold;

  /// 面板上的一行说明，例如「汉字 · 假名 · 拉丁」。
  String get scriptLabel => FontScript.values
      .where(covers)
      .map((s) => s.chinese)
      .join(' · ');

  /// 去重键：同 family + weight + italic 只留一个文件。
  String get dedupKey => '${family.toLowerCase()}|$weight|${italic ? 1 : 0}';
}

/// 从一个字体文件的字节里读出 family / weight / cmap 覆盖。
///
/// 返回 null 表示「这不是我们能用的字体」（不是 sfnt、表目录损坏、取不到
/// family 名、`.ttc` 集合里没有可用成员……）。**不抛异常** —— 系统字体
/// 目录里什么都可能躺着（`.fon`、快捷方式、零字节文件），扫描一个目录时
/// 任何一次抛异常都会让整次扫描半途而废。
SystemFontInfo? parseFontBytes(Uint8List bytes, String path) {
  final r = _Reader(bytes);
  if (bytes.length < 12) return null;
  final tag = r.uint32(0);
  // 'ttcf' = TrueType Collection: 取第一个成员，其余忽略（Windows 的
  // msgothic.ttc 之类是常见日文字体，整个跳过太可惜）。
  var dirOffset = 0;
  if (tag == 0x74746366) {
    if (bytes.length < 16) return null;
    final numFonts = r.uint32(8);
    if (numFonts < 1 || bytes.length < 12 + 4 * numFonts) return null;
    dirOffset = r.uint32(12);
  } else if (tag != 0x00010000 && tag != 0x4F54544F && tag != 0x74727565) {
    return null; // 不是 sfnt（可能是 .fon / .pfb / 位图字体）
  }
  final tables = _readTableDirectory(r, dirOffset);
  if (tables == null) return null;

  final name = _readName(r, tables['name']);
  if (name == null || name.family.isEmpty) return null;
  final os2 = tables['OS/2'];
  final weight = os2 != null && os2.length >= 6
      ? _clampWeight(r.uint16(os2.offset + 4))
      : _weightFromSubfamily(name.subfamily);
  final italic = _italicFromSubfamily(name.subfamily);
  final cmap = tables['cmap'];
  final coverage = cmap == null
      ? const <FontScript, double>{}
      : _readCmap(r, cmap);
  return SystemFontInfo(
    family: name.family,
    subfamily: name.subfamily,
    weight: weight,
    italic: italic,
    path: path,
    codepoints: cmap == null ? 0 : _totalCodepoints(r, cmap),
    coverage: coverage,
  );
}

/// 系统字体表：**纯逻辑**（不碰文件系统），便于断言。
class SystemFontIndex {
  SystemFontIndex(this.fonts);

  final List<SystemFontInfo> fonts;

  /// family（小写）→ 该族下所有字重文件。
  late final Map<String, List<SystemFontInfo>> byFamily = () {
    final map = <String, List<SystemFontInfo>>{};
    for (final f in fonts) {
      map.putIfAbsent(f.family.toLowerCase(), () => <SystemFontInfo>[]).add(f);
    }
    return map;
  }();

  bool has(String? family) {
    final key = (family ?? '').trim().toLowerCase();
    if (key.isEmpty) return false;
    final list = byFamily[key];
    return list != null && list.isNotEmpty;
  }

  /// [family] 装着，且**能显示至少一种 CJK 文种**。
  ///
  /// 🔴 `resolveFamily` 只认这一档，不认 [has]。理由就是 A05 §3 的那条底线：
  /// "中文一定出字"。一台机器上装着 Arial / Times New Roman，而 FT 工程里
  /// 完全可能写着 `font_family: "Arial"` —— 若因为"装了"就原样用它，译文会
  /// 变成一片豆腐块，而且**不报错**。用 CJK 覆盖做门槛后，Arial 落回打包
  /// 字体（和今天一样），雅黑/宋体这类**真的能出中文**的才被放行。
  bool hasCjk(String? family) {
    final list = byFamily[(family ?? '').trim().toLowerCase()];
    if (list == null || list.isEmpty) return false;
    for (final f in list) {
      if (f.covers(FontScript.cjk) ||
          f.covers(FontScript.kana) ||
          f.covers(FontScript.hangul)) {
        return true;
      }
    }
    return false;
  }

  /// 选出最接近 [weight] 的字重（同族内取距离最小，平手取更重的）。
  SystemFontInfo? best(String family, int weight, bool italic) {
    final list = byFamily[family.trim().toLowerCase()];
    if (list == null || list.isEmpty) return null;
    SystemFontInfo? chosen;
    var bestGap = 1 << 30;
    for (final f in list) {
      if (f.italic != italic) continue;
      final gap = (f.weight - weight).abs();
      if (gap < bestGap || (gap == bestGap && f.weight > (chosen?.weight ?? 0))) {
        bestGap = gap;
        chosen = f;
      }
    }
    // 没有正好匹配斜体/正体的（多数字体只有正体）→ 退而求其次。
    if (chosen == null) {
      for (final f in list) {
        final gap = (f.weight - weight).abs();
        if (gap < bestGap) {
          bestGap = gap;
          chosen = f;
        }
      }
    }
    return chosen;
  }

  /// 面板候选：有汉字的排前面，其次按 family 名排序。
  ///
  /// 🔴 只列「能显示至少一种 CJK 文种」的字体。系统里绝大多数西文字体对
  /// 漫画嵌字毫无用处，全列出来会把真正可选的十几个中文字体淹没掉。
  List<SystemFontInfo> get choices {
    final seen = <String>{};
    final result = <SystemFontInfo>[];
    for (final f in fonts) {
      final hasCjk =
          f.covers(FontScript.cjk) ||
          f.covers(FontScript.kana) ||
          f.covers(FontScript.hangul);
      if (!hasCjk) continue;
      if (!seen.add(f.family.toLowerCase())) continue;
      result.add(f);
    }
    result.sort((a, b) {
      final ca = a.covers(FontScript.cjk) ? 0 : 1;
      final cb = b.covers(FontScript.cjk) ? 0 : 1;
      if (ca != cb) return ca - cb;
      return a.family.toLowerCase().compareTo(b.family.toLowerCase());
    });
    return result;
  }
}

/// 扫描 Windows 字体目录，返回去重后的 [SystemFontIndex]。
///
/// 🔴 **只读文件头，不读整个文件**：`C:\Windows\Fonts` 里一个中日韩字体
/// 动辄 10~20 MB，全读一遍是秒级的 I/O 卡顿。表目录 + name 表 + cmap 表
/// 通常集中在前几百 KB，[_maxHeaderBytes] 就是这条边界；cmap 表恰好越过
/// 边界时 [parseFontBytes] 会返回空覆盖（而不是崩溃）—— 该字体就被
/// `choices` 的「至少一种 CJK」过滤掉，属可接受的降级。
Future<SystemFontIndex> scanSystemFonts() async {
  final dir = _windowsFontDirectory();
  if (dir == null) return SystemFontIndex(const <SystemFontInfo>[]);
  final fonts = <SystemFontInfo>[];
  final seen = <String>{};
  await for (final entity in dir.list(followLinks: false)) {
    if (entity is! File) continue;
    final name = entity.path.toLowerCase();
    if (!(name.endsWith('.ttf') ||
        name.endsWith('.otf') ||
        name.endsWith('.ttc'))) {
      continue;
    }
    Uint8List head;
    try {
      final handle = await entity.open(mode: FileMode.read);
      try {
        final len = await handle.length();
        head = await handle.read(math.min(len, _maxHeaderBytes));
      } finally {
        await handle.close();
      }
    } catch (_) {
      continue; // 权限/占用/零字节 —— 跳过，不让一个坏文件毁掉整次扫描
    }
    final info = parseFontBytes(head, entity.path);
    if (info == null) continue;
    if (!seen.add(info.dedupKey)) continue;
    fonts.add(info);
  }
  return SystemFontIndex(fonts);
}

/// 扫描器读多少字节就够（表目录 + name + cmap 的常规上界）。
const int _maxHeaderBytes = 512 * 1024;

/// 进程内唯一的系统字体表。
///
/// 🔴 初始值是一张**空表**而不是 null —— 扫描完成前 `resolveFamily` 走的是
/// 「系统字体表里没有」这一支，行为与扫描功能上线前**完全一致**（旧工程
/// 不会在启动的头一秒里突然换字体）。扫描是启动后异步发起的。
SystemFontIndex systemFonts = SystemFontIndex(const <SystemFontInfo>[]);

Future<void>? _scanFuture;

/// 幂等的扫描入口：多次调用共享同一个 Future（A02 §3：不要每次 build 都新建）。
Future<void> ensureSystemFontsScanned() {
  return _scanFuture ??= () async {
    try {
      systemFonts = await scanSystemFonts();
      Log.info(
        'SystemFonts',
        'scanned ${systemFonts.fonts.length} faces, '
            '${systemFonts.choices.length} usable for CJK',
      );
    } catch (e) {
      // 扫描失败不该让应用变形：保持空表，行为同旧版。
      Log.info('SystemFonts', 'scan failed: $e');
    }
  }();
}

/// 仅供断言：把扫描 Future 与表重置（注入故障后要能复现两条路径）。
void resetSystemFontsForTest() {
  _scanFuture = null;
  systemFonts = SystemFontIndex(const <SystemFontInfo>[]);
}

/// 断言用的扫描根目录覆盖（headless 里指向 `assets/fonts/` 做真字体验证）。
/// 为 null 时走真实的 `%WINDIR%\Fonts`。
String? systemFontDirectoryOverride;

Directory? _windowsFontDirectory() {
  final override = systemFontDirectoryOverride;
  if (override != null) return Directory(override);
  if (!Platform.isWindows) return null;
  final windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
  return Directory('$windir${Platform.pathSeparator}Fonts');
}

// ---------------------------------------------------------------------------
// sfnt 解析（全部私有，纯字节操作）
// ---------------------------------------------------------------------------

class _Reader {
  _Reader(this.bytes) : _bd = ByteData.sublistView(bytes);

  final Uint8List bytes;
  final ByteData _bd;

  bool has(int offset, int width) =>
      offset >= 0 && offset + width <= bytes.length;

  int uint16(int o) => has(o, 2) ? _bd.getUint16(o) : 0;

  int uint32(int o) => has(o, 4) ? _bd.getUint32(o) : 0;

  int int16(int o) => has(o, 2) ? _bd.getInt16(o) : 0;
}

class _Table {
  _Table(this.offset, this.length);
  final int offset;
  final int length;
}

Map<String, _Table>? _readTableDirectory(_Reader r, int base) {
  if (!r.has(base + 4, 2)) return null;
  final numTables = r.uint16(base + 4);
  if (numTables == 0 || !r.has(base + 12, 16 * numTables)) return null;
  final out = <String, _Table>{};
  for (var i = 0; i < numTables; i++) {
    final e = base + 12 + 16 * i;
    final tag = String.fromCharCodes([
      (r.uint32(e) >> 24) & 0xFF,
      (r.uint32(e) >> 16) & 0xFF,
      (r.uint32(e) >> 8) & 0xFF,
      r.uint32(e) & 0xFF,
    ]);
    out[tag] = _Table(r.uint32(e + 8), r.uint32(e + 12));
  }
  return out;
}

class _Names {
  _Names(this.family, this.subfamily);
  final String family;
  final String subfamily;
}

/// name 表：按「平台/编码/语言」优先级挑最可信的那份。
///
/// 优先级 Windows(3,1,0x409) → Unicode(0,*,*) → Macintosh(1,0,0) → 第一个。
/// 之所以要挑：同一份 name 表里可能既有 UTF-16BE 又有 Mac Roman，拿错那份
/// 会把 UTF-16 当单字节读，得到 "N\x00o\x00t\x00o\x00" 这种名字 —— 而它
/// **看起来**像个字体名，于是 bug 会一直活到用户选中它才发现。
_Names? _readName(_Reader r, _Table? table) {
  if (table == null || !r.has(table.offset + 2, 2)) return null;
  final count = r.uint16(table.offset + 2);
  final stringBase = table.offset + r.uint16(table.offset + 4);
  if (count == 0 || !r.has(table.offset + 6, 12 * count)) return null;

  String? pick(int nameId) {
    var fallback = '';
    for (var pass = 0; pass < 4; pass++) {
      for (var i = 0; i < count; i++) {
        final e = table.offset + 6 + 12 * i;
        if (r.uint16(e + 6) != nameId) continue;
        final platform = r.uint16(e);
        final encoding = r.uint16(e + 2);
        final language = r.uint16(e + 4);
        final ok = switch (pass) {
          0 => platform == 3 && encoding == 1 && language == 0x0409,
          1 => platform == 0,
          2 => platform == 1 && encoding == 0 && language == 0,
          _ => true,
        };
        if (!ok) continue;
        final len = r.uint16(e + 8);
        final off = r.uint16(e + 10);
        final text = _decodeName(r, stringBase + off, len, platform, encoding);
        if (text.isEmpty) continue;
        if (pass < 3) return text;
        if (fallback.isEmpty) fallback = text;
      }
    }
    return fallback.isEmpty ? null : fallback;
  }

  // nameID 16/17（typographic family/subfamily）优先：它就是「用户看到的
  // 那个字族名」，1/2 在部分字体里是 RIBBI 的旧式命名（"Noto Sans SC Light"
  // 被拆成 family="Noto Sans SC Light" subfamily="Regular"）。
  final family = pick(16) ?? pick(1);
  if (family == null) return null;
  final subfamily = pick(17) ?? pick(2) ?? '';
  return _Names(family, subfamily);
}

String _decodeName(
  _Reader r,
  int offset,
  int length,
  int platform,
  int encoding,
) {
  if (length <= 0 || !r.has(offset, length)) return '';
  final raw = r.bytes.sublist(offset, offset + length);
  final utf16 = platform == 0 || platform == 3 || (platform == 1 && encoding >= 2);
  if (!utf16) return String.fromCharCodes(raw);
  if (length < 2 || length.isOdd) return String.fromCharCodes(raw);
  final out = StringBuffer();
  for (var i = 0; i + 1 < length; i += 2) {
    final unit = (raw[i] << 8) | raw[i + 1];
    if (unit == 0) continue;
    out.writeCharCode(unit);
  }
  return out.toString();
}

int _clampWeight(int value) => value < 100
    ? 100
    : value > 900
    ? 900
    : value;

int _weightFromSubfamily(String subfamily) {
  final s = subfamily.toLowerCase();
  if (s.contains('black') || s.contains('heavy')) return 900;
  if (s.contains('extrabold') || s.contains('ultrabold')) return 800;
  if (s.contains('bold')) return 700;
  if (s.contains('semibold') || s.contains('demibold')) return 600;
  if (s.contains('medium')) return 500;
  if (s.contains('extralight') || s.contains('ultralight')) return 200;
  if (s.contains('light')) return 300;
  if (s.contains('thin')) return 100;
  return 400;
}

bool _italicFromSubfamily(String subfamily) {
  final s = subfamily.toLowerCase();
  return s.contains('italic') || s.contains('oblique');
}

/// cmap 子表位置。优先 format 12（UCS-4，中日韩字体一定有），回落 format 4。
class _CmapSub {
  _CmapSub(this.offset, this.format);
  final int offset;
  final int format;
}

_CmapSub? _pickCmap(_Reader r, _Table table) {
  if (!r.has(table.offset + 2, 2)) return null;
  final n = r.uint16(table.offset + 2);
  _CmapSub? f12;
  _CmapSub? f4;
  for (var i = 0; i < n; i++) {
    final e = table.offset + 4 + 8 * i;
    if (!r.has(e, 8)) break;
    final subOffset = table.offset + r.uint32(e + 4);
    if (!r.has(subOffset, 2)) continue;
    final format = r.uint16(subOffset);
    if (format == 12 && f12 == null) {
      if (r.has(subOffset + 12, 4)) f12 = _CmapSub(subOffset, 12);
    } else if (format == 4 && f4 == null) {
      if (r.has(subOffset + 6, 2)) f4 = _CmapSub(subOffset, 4);
    }
  }
  return f12 ?? f4;
}

Map<FontScript, double> _readCmap(_Reader r, _Table table) {
  final sub = _pickCmap(r, table);
  if (sub == null) return const <FontScript, double>{};
  final out = <FontScript, double>{};
  for (final script in FontScript.values) {
    final points = _samplePoints(script);
    var hit = 0;
    for (final p in points) {
      if (sub.format == 12 ? _lookup12(r, sub.offset, p) : _lookup4(r, sub.offset, p)) {
        hit++;
      }
    }
    out[script] = points.isEmpty ? 0.0 : hit / points.length;
  }
  return out;
}

int _totalCodepoints(_Reader r, _Table table) {
  final sub = _pickCmap(r, table);
  if (sub == null) return 0;
  if (sub.format == 12) {
    if (!r.has(sub.offset + 12, 4)) return 0;
    final n = r.uint32(sub.offset + 12);
    var total = 0;
    for (var i = 0; i < n; i++) {
      final e = sub.offset + 16 + 12 * i;
      if (!r.has(e, 12)) break;
      final start = r.uint32(e);
      final end = r.uint32(e + 4);
      if (end < start) continue;
      total += end - start + 1;
    }
    return total;
  }
  final segX2 = r.uint16(sub.offset + 6);
  final seg = segX2 ~/ 2;
  var total = 0;
  for (var i = 0; i < seg; i++) {
    final start = r.uint16(sub.offset + 16 + segX2 + 2 + 2 * i);
    final end = r.uint16(sub.offset + 14 + 2 * i);
    if (end < start) continue;
    total += end - start + 1;
  }
  return total;
}

bool _lookup4(_Reader r, int base, int c) {
  if (c > 0xFFFF) return false;
  final segX2 = r.uint16(base + 6);
  final seg = segX2 ~/ 2;
  if (seg == 0) return false;
  final endBase = base + 14;
  final startBase = endBase + segX2 + 2;
  final deltaBase = startBase + segX2;
  final rangeBase = deltaBase + segX2;
  for (var i = 0; i < seg; i++) {
    final end = r.uint16(endBase + 2 * i);
    if (c > end) continue;
    final start = r.uint16(startBase + 2 * i);
    if (c < start) return false;
    final rangeOffset = r.uint16(rangeBase + 2 * i);
    if (rangeOffset == 0) {
      return ((c + r.int16(deltaBase + 2 * i)) & 0xFFFF) != 0;
    }
    // glyphIdArray 间接寻址：`&idRangeOffset[i] + idRangeOffset[i] + 2*(c-start)`
    final glyphBase = rangeBase + 2 * i + rangeOffset + 2 * (c - start);
    if (!r.has(glyphBase, 2)) return false;
    return r.uint16(glyphBase) != 0;
  }
  return false;
}

bool _lookup12(_Reader r, int base, int c) {
  final n = r.uint32(base + 12);
  var lo = 0;
  var hi = n - 1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    final e = base + 16 + 12 * mid;
    if (!r.has(e, 12)) return false;
    final start = r.uint32(e);
    final end = r.uint32(e + 4);
    if (c < start) {
      hi = mid - 1;
    } else if (c > end) {
      lo = mid + 1;
    } else {
      // format 12 的组本身就是「这段码位有映射」的声明：字体不会为未覆盖
      // 的字符建组。所以命中即覆盖，不再去查 startGlyphID。
      return true;
    }
  }
  return false;
}

/// 各类文种的采样码位。
///
/// 🔴 采样而不是全量：CJK 有 2 万多个码位，逐个查 format 4（线性扫段）
/// 在扫几百个字体时会变成秒级开销。等距采样在「常用字集中在前段」的
/// 真实字体上覆盖率仍然接近 1，而缺字的字体（比如纯西文字体）采样命中率
/// 会掉到 0 —— 这正是我们要区分的两种情形。
List<int> _samplePoints(FontScript script) {
  switch (script) {
    case FontScript.latin:
      return [
        for (var c = 0x41; c <= 0x5A; c++) c,
        for (var c = 0x61; c <= 0x7A; c++) c,
        for (var c = 0xC0; c <= 0xFF; c += 3) c,
      ];
    case FontScript.punctuation:
      return [for (var c = 0x3000; c <= 0x303F; c += 2) c];
    case FontScript.kana:
      return [
        for (var c = 0x3041; c <= 0x3096; c += 2) c,
        for (var c = 0x30A1; c <= 0x30FA; c += 2) c,
      ];
    case FontScript.hangul:
      return [for (var c = 0xAC00; c <= 0xD7A3; c += 41) c];
    case FontScript.cjk:
      return [for (var c = 0x4E00; c <= 0x9FA5; c += 13) c];
  }
}

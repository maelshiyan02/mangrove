// A-1（左侧缩略图栏）的 headless 断言集。
//
// 缩略图栏本身是 widget，本会话没有渲染表面（`A01 §3`）⇒ 观感只能由用户在 GUI
// 会话验收。但**它依赖的两块逻辑是纯的**：
//
// 1. 门控真值表（`thumbRailGate`）—— "何时能开"；
// 2. 页筛选（`thumbRailVisibleIndices` / `isLandscapePage`）—— "哪些页要显示，
//    且页号不错位"。
//
// 外加两块被它复用的纯逻辑：序号/状态覆盖层的位置（`thumbTileOverlay`）与页尺寸
// 的头解析（`page_size_probe.dart`）。这一批全部能 headless 跑完。
//
// ## 反向验证（M08）
//
// 每条断言跑两遍：绿路径喂**真实现**，故障路径喂一个**故意写错的实现**，且两条
// 路径检验的是**同一个命题**。`故障路径=变红` 才说明判据不是装饰品。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:mangrove/foundation/image_translation/balloon_clustering.dart'
    show ReadingDirection;
import 'package:mangrove/foundation/translation_project/page_size_probe.dart';
import 'package:mangrove/foundation/translation_project/thumb_rail.dart';
import 'package:mangrove/headless_p1_checks.dart' show CheckSink;

const _studioPath = 'lib/pages/translation_studio/studio_page.dart';

// ── 夹具 ────────────────────────────────────────────────────────────────

/// 构造一个最小的合法 PNG 头：魔数 + IHDR（宽 1600 / 高 2400）。CRC 不参与
/// 解析，填 0；解析器只认偏移 16/20 的大端宽高。
Uint8List _pngFixture(int width, int height) {
  final b = BytesBuilder();
  b.add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  b.add([0x00, 0x00, 0x00, 0x0D]); // 块长 13
  b.add('IHDR'.codeUnits);
  b.add([(width >> 24) & 0xFF, (width >> 16) & 0xFF, (width >> 8) & 0xFF, width & 0xFF]);
  b.add([(height >> 24) & 0xFF, (height >> 16) & 0xFF, (height >> 8) & 0xFF, height & 0xFF]);
  b.add([8, 0, 0, 0, 0]); // bit depth 8 · colour type 0 · 其余 0
  b.add([0, 0, 0, 0]); // CRC（不校验）
  return b.toBytes();
}

/// 构造一个最小的 JPEG：`SOI` + `SOF0`（宽 800 / 高 600）。
Uint8List _jpegFixture(int width, int height) {
  return Uint8List.fromList([
    0xFF, 0xD8, // SOI
    0xFF, 0xC0, // SOF0
    0x00, 0x0B, // 段长 11
    0x08, // 精度
    (height >> 8) & 0xFF, height & 0xFF,
    (width >> 8) & 0xFF, width & 0xFF,
    0x01, 0x01, 0x11, 0x00, // 1 个分量
  ]);
}

// ── 判据（绿/红两条路径喂的是**同一个**命题） ──────────────────────────

typedef _GateFn = ThumbRailGate Function({
  required bool hasProject,
  required bool stripMode,
  required int pageCount,
});

/// 完整真值表（含**原因码**，不只布尔）。判定顺序 = tooltip 优先级，所以表里
/// 特意放了"工程优先于模式""模式优先于页数"两条交叉用例。
///
/// P30：方向门控已删 —— 表里仍保留三种方向各一行，钉住"日漫/左起也放行"。
bool _gateTableMatches(_GateFn fn) {
  const expected = <(bool, bool, ReadingDirection, int, ThumbRailGate)>[
    (false, false, ReadingDirection.topToBottom, 5, ThumbRailGate.noProject),
    (false, true, ReadingDirection.rightToLeft, 0, ThumbRailGate.noProject),
    (true, true, ReadingDirection.topToBottom, 5, ThumbRailGate.stripMode),
    (true, true, ReadingDirection.rightToLeft, 5, ThumbRailGate.stripMode),
    // 三种方向在单页模式下全部放行（P30）。
    (true, false, ReadingDirection.rightToLeft, 5, ThumbRailGate.ready),
    (true, false, ReadingDirection.leftToRight, 5, ThumbRailGate.ready),
    (true, false, ReadingDirection.topToBottom, 5, ThumbRailGate.ready),
    (true, false, ReadingDirection.topToBottom, 0, ThumbRailGate.tooFewPages),
    (true, false, ReadingDirection.topToBottom, 1, ThumbRailGate.tooFewPages),
    (true, false, ReadingDirection.topToBottom, 2, ThumbRailGate.ready),
    (true, false, ReadingDirection.topToBottom, 100, ThumbRailGate.ready),
  ];
  for (final (hasProject, strip, dir, pages, want) in expected) {
    if (fn(
          hasProject: hasProject,
          stripMode: strip,
          pageCount: pages,
        ) !=
        want) {
      // ignore: avoid_print
      print('gate row failed: project=$hasProject strip=$strip '
          'dir=$dir pages=$pages want=$want');
      return false;
    }
  }
  return true;
}

List<int> _visibleReal(List<PageSize?> sizes) => thumbRailVisibleIndices(
      pageCount: sizes.length,
      widthOf: (i) => sizes[i]?.width,
      heightOf: (i) => sizes[i]?.height,
    );

/// 故障实现：用 `>` 而不是 `>=`（正方形页没被隐藏）。
List<int> _visibleFaulty(List<PageSize?> sizes) {
  final out = <int>[];
  for (var i = 0; i < sizes.length; i++) {
    final s = sizes[i];
    if (s != null && s.width > s.height) continue;
    out.add(i);
  }
  return out;
}

bool _listEq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 横版页被剔除、正方形页被剔除、尺寸未知页保留，且返回的是**原始下标**
/// （页号 = 下标 + 1 ⇒ [1,3,5]，不是被压缩过的 [1,2,3]）。
bool _landscapeOk(List<int> Function(List<PageSize?>) filter) {
  const portrait = PageSize(1600, 2400);
  const landscape = PageSize(2400, 1600);
  const square = PageSize(800, 800);
  final sizes = <PageSize?>[portrait, landscape, portrait, square, null];
  final visible = filter(sizes);
  if (!_listEq(visible, const [0, 2, 4])) return false;
  final labels = [for (final i in visible) i + 1];
  return _listEq(labels, const [1, 3, 5]);
}

bool _overlayOk(
  ThumbTileOverlay Function({required bool large}) fn,
  String studioSource,
) {
  if (studioSource.trim().isEmpty) return false;
  // 界面必须**真的**调用这个判据，否则断言只是自证。
  if (!studioSource.contains('thumbTileOverlay(large:')) return false;
  return fn(large: true) == ThumbTileOverlay.center &&
      fn(large: false) == ThumbTileOverlay.edge;
}

/// `_thumbRail` 的声明处是不是"关"。认 `false` 或我们的默认常量；不认 `true`。
bool _thumbRailIsOffByDefault(String src) {
  final m = RegExp(r'bool _thumbRail = ([A-Za-z0-9_]+);').firstMatch(src);
  if (m == null) return false;
  final expr = m.group(1)!;
  if (expr == 'true') return false;
  if (expr == 'false') return true;
  return expr == 'thumbRailDefaultOn' && thumbRailDefaultOn == false;
}

bool _sizeEq(PageSize? s, int w, int h) =>
    s != null && s.width == w && s.height == h;

/// 页尺寸头解析的判据：两种格式都取到正确宽高，**且截断输入必须返回 null**
/// （截断那一条才是分辨点 —— 不校验长度的实现会"读出"一个垃圾尺寸）。
bool _probeOk({
  required PageSize? Function(Uint8List) byBytes,
  required PageSize? Function(String) byFile,
  required Uint8List pngFull,
  required Uint8List pngTrunc,
  required Uint8List jpegFull,
  required String fullPath,
  required String truncPath,
}) {
  if (!_sizeEq(byBytes(pngFull), 1600, 2400)) return false;
  if (!_sizeEq(byBytes(jpegFull), 800, 600)) return false;
  if (byBytes(pngTrunc) != null) return false;
  if (!_sizeEq(byFile(fullPath), 1600, 2400)) return false;
  if (byFile(truncPath) != null) return false;
  return true;
}

/// 故障实现：PNG 读宽高**不做长度校验**（缺字节当 0），于是截断输入也返回一个
/// 尺寸；JPEG 交给真解析器（本判据只需一条能分辨的路径）。
PageSize? _naiveProbe(Uint8List b) {
  if (b.length >= 16 &&
      b[12] == 0x49 &&
      b[13] == 0x48 &&
      b[14] == 0x44 &&
      b[15] == 0x52) {
    return PageSize(_safeBe32(b, 16), _safeBe32(b, 20));
  }
  return probePageSize(b);
}

int _safeBe32(Uint8List b, int o) {
  var v = 0;
  for (var i = 0; i < 4; i++) {
    v = (v << 8) | (o + i < b.length ? b[o + i] : 0);
  }
  return v;
}

PageSize? _naiveProbeFile(String path) {
  final f = File(path);
  if (!f.existsSync()) return null;
  try {
    return _naiveProbe(f.readAsBytesSync());
  } catch (_) {
    return null;
  }
}

Future<void> _probe(
  CheckSink check,
  String name,
  Future<bool> Function() green,
  Future<bool> Function() red,
  String Function() detail,
) async {
  bool g;
  bool r;
  var err = '';
  try {
    g = await green();
  } catch (e) {
    g = false;
    err = 'green threw: $e';
  }
  try {
    r = await red();
  } catch (e) {
    // 故障路径抛异常 ≠ 断言变红。
    r = true;
    err = '${err.isEmpty ? '' : '$err | '}red threw: $e';
  }
  check(
    name,
    g && !r,
    '${detail()} | 绿路径=${g ? 'true' : 'FALSE'} '
    '故障路径=${r ? '仍绿(装饰品)' : '变红'}${err.isEmpty ? '' : ' | $err'}',
  );
}

/// A-1 的 5 条断言（由 `block-ops-check` 汇总）。
Future<void> runP10Checks(
  CheckSink check, {
  required Directory packageRoot,
}) async {
  final studioFile = File('${packageRoot.path}/$_studioPath');
  final studioSource =
      studioFile.existsSync() ? studioFile.readAsStringSync() : '';
  String code() => studioSource;

  // 1 · 默认关。
  await _probe(
    check,
    'thumbrail.default_is_off',
    () async => _thumbRailIsOffByDefault(code()),
    () async => _thumbRailIsOffByDefault(
      code().replaceFirst(
        'bool _thumbRail = thumbRailDefaultOn;',
        'bool _thumbRail = true;',
      ),
    ),
    () => '绿=声明为关 / 故障=声明为 true ⇒ 判据分辨得出',
  );

  // 2 · 门控真值表（含原因码）。
  await _probe(
    check,
    'thumbrail.gate_truth_table',
    () async => _gateTableMatches(thumbRailGate),
    () async => _gateTableMatches(
      ({
        required bool hasProject,
        required bool stripMode,
        required int pageCount,
      }) {
        // 故障：漏掉"页数 ≥ 2"那一条。
        if (!hasProject) return ThumbRailGate.noProject;
        if (stripMode) return ThumbRailGate.stripMode;
        return ThumbRailGate.ready;
      },
    ),
    () => '绿=11 组含原因码全中（三种方向都放行）/ 故障=漏判页数 ⇒ 1 页也 ready ⇒ 变红',
  );

  // 3 · 横版页隐藏且页号不错位。
  await _probe(
    check,
    'thumbrail.landscape_pages_are_hidden',
    () async => _landscapeOk(_visibleReal),
    () async => _landscapeOk(_visibleFaulty),
    () => '绿=横版/正方形隐藏·页号 1/3/5 / 故障=用 > 留下正方形 ⇒ 变红',
  );

  // 4 · 缩略图模式不存在贴边覆盖层。
  await _probe(
    check,
    'thumbrail.tile_hides_edge_overlays',
    () async => _overlayOk(thumbTileOverlay, code()),
    () async => _overlayOk(
      ({required bool large}) => large
          ? ThumbTileOverlay.edge
          : ThumbTileOverlay.center,
      code(),
    ),
    () => '绿=large 走 center / 故障=large 仍贴边 ⇒ 变红',
  );

  // 5 · 页尺寸头解析（PNG / JPEG，含截断故障路径）。
  final pngFull = _pngFixture(1600, 2400);
  final pngTrunc = Uint8List.sublistView(pngFull, 0, 23);
  final jpegFull = _jpegFixture(800, 600);

  await _probe(
    check,
    'pageheader.reads_png_and_jpeg_size',
    () async {
      final dir = Directory.systemTemp.createTempSync('mangrove_hdr_');
      try {
        final full = File('${dir.path}/full.png')..writeAsBytesSync(pngFull);
        final trunc = File('${dir.path}/trunc.png')
          ..writeAsBytesSync(pngTrunc);
        return _probeOk(
          byBytes: probePageSize,
          byFile: probePageSizeFromFile,
          pngFull: pngFull,
          pngTrunc: pngTrunc,
          jpegFull: jpegFull,
          fullPath: full.path,
          truncPath: trunc.path,
        );
      } finally {
        dir.deleteSync(recursive: true);
      }
    },
    () async {
      final dir = Directory.systemTemp.createTempSync('mangrove_hdr_');
      try {
        final full = File('${dir.path}/full.png')..writeAsBytesSync(pngFull);
        final trunc = File('${dir.path}/trunc.png')
          ..writeAsBytesSync(pngTrunc);
        return _probeOk(
          byBytes: _naiveProbe,
          byFile: _naiveProbeFile,
          pngFull: pngFull,
          pngTrunc: pngTrunc,
          jpegFull: jpegFull,
          fullPath: full.path,
          truncPath: trunc.path,
        );
      } finally {
        dir.deleteSync(recursive: true);
      }
    },
    () => '绿=1600x2400/800x600·截断→null / 故障=不校验长度 ⇒ 截断也出尺寸 ⇒ 变红',
  );
}
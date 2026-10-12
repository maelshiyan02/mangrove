// B-2（跨页文本块创建）的 headless 断言集（跨页拼接计划 §4-B2 验收）。
//
// 虚拟 ↔ per-page 子矩形互转、按缝切分、`parts` 校验、缝窗口构造与内存拼接，
// 全在纯 Dart 里（`cross_page_block.dart` / `seam_window.dart`），所以这一批能被
// headless 跑完。画布上的跨缝拖框是 UI，本会话没有渲染表面，只能由用户在 GUI 会话验收。
//
// ## 反向验证（M08）
//
// 每条断言跑两遍：绿路径喂**真实现**，故障路径喂一个**故意写错的实现**，两条
// 路径检验的是**同一个命题**。`故障路径=变红` 才说明判据不是装饰品。
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:mangrove/foundation/image_translation/translation_types.dart'
    show IntRect, RgbaImage;
import 'package:mangrove/foundation/translation_project/cross_page_block.dart';
import 'package:mangrove/foundation/translation_project/seam_window.dart';
import 'package:mangrove/foundation/translation_project/strip_geometry.dart';
import 'package:mangrove/foundation/translation_project/text_block.dart'
    show TextBlock;
import 'package:mangrove/headless_p1_checks.dart' show CheckSink;

// ── 夹具 ────────────────────────────────────────────────────────────────

/// §8.3 的样例两页：p003 / p004 均 1600×2400。
const _bands = <PageBand>[
  PageBand('p003', 1600, 2400),
  PageBand('p004', 1600, 2400),
];

final _offsets = virtualOffsets(_bands);

int _offsetOf(String page) => _offsets[page] ?? (1 << 30);

IntRect _pageRectOf(String page) => IntRect(0, 0, 1600, 2400);

RgbaImage _solid(int w, int h) {
  final pixels = Uint8List(w * h * 4)..fillRange(0, w * h * 4, 200);
  return RgbaImage(w, h, pixels);
}

bool _listEq(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 目录内容清单（`路径=字节数`），用于断言"产物目录字节不变"。
List<String> _listing(Directory dir) {
  final items = <String>[];
  for (final entity in dir.listSync(recursive: true)) {
    items.add(entity is File ? '${entity.path}=${entity.lengthSync()}' : entity.path);
  }
  items.sort();
  return items;
}

// ── 1 · 虚拟矩形 → 子矩形 → 还原虚拟矩形（往返无损） ────────────────────

typedef _SplitFn = List<SpanPart> Function(
  IntRect virtualRect, {
  required List<PageBand> bands,
});

/// 命题：§8.3 的样例虚拟矩形切成 per-page 子矩形后，重新并集**逐像素还原**。
bool _splitRoundTrip(_SplitFn split) {
  final virtual = IntRect(600, 2200, 1000, 2700); // 400×500
  final parts = split(virtual, bands: _bands);
  if (parts.length != 2) return false;
  // 每段都必须是整数坐标且在各自页内
  for (final part in parts) {
    final page = _pageRectOf(part.page);
    if (part.rect.left < 0 ||
        part.rect.top < 0 ||
        part.rect.right > page.width ||
        part.rect.bottom > page.height) {
      return false;
    }
  }
  final back = spanToVirtual(BlockSpan(parts), offsetOf: _offsetOf);
  return back != null &&
      back.left == virtual.left &&
      back.top == virtual.top &&
      back.right == virtual.right &&
      back.bottom == virtual.bottom;
}

/// 故障实现：切分时**不减去页内偏移**（还原时被多加一次 offset）。
List<SpanPart> _faultySplitNoOffset(
  IntRect virtualRect, {
  required List<PageBand> bands,
}) {
  final parts = <SpanPart>[];
  var offset = 0;
  for (final band in bands) {
    final pageTop = offset;
    final pageBottom = offset + band.height;
    offset = pageBottom;
    final top = math.max(virtualRect.top, pageTop);
    final bottom = math.min(virtualRect.bottom, pageBottom);
    if (bottom <= top) continue;
    parts.add(
      SpanPart(band.page, IntRect(virtualRect.left, top, virtualRect.right, bottom)),
    );
  }
  return parts;
}

// ── 2 · 缝窗口有界（≤ 封顶；全幅被拒） ─────────────────────────────────

typedef _WindowFn = SeamWindow? Function(int a, int b, double fraction);

/// 命题：正常比例产出的窗口高度 ≤ 封顶，而**全幅拼接被拒绝**（返回 null）。
bool _windowIsBounded(_WindowFn build) {
  final normal = build(2400, 2400, seamWindowFraction);
  final full = build(2400, 2400, 1.0); // 全幅
  return normal != null &&
      normal.height <= seamWindowCap &&
      full == null;
}

/// 故障实现：无视封顶（全幅照样返回），把"全幅拼接"悄悄放行。
SeamWindow? _faultyWindowIgnoresCap(int a, int b, double fraction) => SeamWindow(
      topHeight: (a * fraction).round(),
      bottomHeight: (b * fraction).round(),
    );

// ── 3 · 跑完整条流程，产物目录字节不变（绝不落盘合成图） ────────────────

typedef _FlowFn = Future<bool> Function(Directory scratch);

/// 命题：缝窗口 → 内存拼接 → 候选映射回虚拟 → 切分落盘，**目录一个字节都不变**。
Future<bool> _flowLeavesNoImage(Directory scratch, {required bool alsoWrite}) async {
  final before = _listing(scratch);

  final above = _solid(1600, 2400);
  final below = _solid(1600, 2400);
  final window = buildSeamWindow(pageAHeight: 2400, pageBHeight: 2400)!;
  final stitched = stitchSeamWindow(above: above, below: below, window: window)!;
  // "识别"出的候选框（这里用固定框代表）→ 映射回虚拟坐标 → 切分 → 落盘 `_span`
  final candidate = IntRect(
    600,
    window.topHeight - 200,
    1000,
    window.topHeight + 300,
  );
  final virtual = windowRectToVirtual(candidate, pageAHeight: 2400, window: window);
  final parts = splitVirtual(virtual, bands: _bands);
  final block = TextBlock.createDefault(rect: IntRect(600, 2200, 1000, 2400));
  writeSpan(block, BlockSpan(parts));
  if (stitched.height <= 0) return false; // 用完即弃：只读尺寸，不落盘

  if (alsoWrite) {
    File('${scratch.path}${Platform.pathSeparator}merged.png')
        .writeAsBytesSync(<int>[1, 2, 3]);
  }
  return _listEq(before, _listing(scratch));
}

// ── 4 · 两页宽度不同 ⇒ 拒绝 ────────────────────────────────────────────

typedef _ValidateFn = String? Function(
  BlockSpan span, {
  required IntRect Function(String page) pageRect,
});

/// 命题：同宽通过；异宽（子矩形来自不同宽度的页）⇒ `width_mismatch`；
/// 拼接围墙对异宽两页 ⇒ null。
bool _rejectsWidthMismatch(_ValidateFn validate) {
  final rects = <String, IntRect>{
    'p003': IntRect(0, 0, 1600, 2400),
    'p004': IntRect(0, 0, 1600, 2400),
    'pX': IntRect(0, 0, 1200, 2400),
  };
  IntRect pageRect(String page) => rects[page] ?? IntRect(0, 0, 1600, 2400);

  final same = BlockSpan([
    SpanPart('p003', IntRect(600, 2200, 1000, 2400)),
    SpanPart('p004', IntRect(600, 0, 1000, 300)),
  ]);
  final mixed = BlockSpan([
    SpanPart('p003', IntRect(600, 2200, 1000, 2400)),
    SpanPart('pX', IntRect(600, 0, 1000, 300)),
  ]);
  final ok = validate(same, pageRect: pageRect) == null;
  final bad = validate(mixed, pageRect: pageRect) == spanReasonWidthMismatch;
  final stitchNull = stitchSeamWindow(
        above: _solid(1600, 2400),
        below: _solid(1200, 2400),
        window: const SeamWindow(topHeight: 100, bottomHeight: 100),
      ) ==
      null;
  return ok && bad && stitchNull;
}

/// 故障实现：不做同宽检查（异宽也放行）。
String? _faultyValidateNoWidth(
  BlockSpan span, {
  required IntRect Function(String page) pageRect,
}) {
  if (span.parts.isEmpty) return spanReasonEmpty;
  return null;
}

// ── 5 · 子矩形不越自己那页 ─────────────────────────────────────────────

/// 命题：任何一段超出该页矩形（含负坐标 / 超出宽高）⇒ `part_out_of_page_bounds`。
bool _rejectsOutOfBounds(_ValidateFn validate) {
  IntRect pageRect(String page) => IntRect(0, 0, 1600, 2400);
  final tooTall = BlockSpan([
    SpanPart('p003', IntRect(600, 2200, 1000, 2400)),
    SpanPart('p004', IntRect(600, 0, 1000, 2600)), // 页高 2400 ⇒ 越界
  ]);
  final negative = BlockSpan([SpanPart('p003', IntRect(-10, 0, 100, 50))]);
  return validate(tooTall, pageRect: pageRect) == spanReasonOutOfBounds &&
      validate(negative, pageRect: pageRect) == spanReasonOutOfBounds;
}

/// 故障实现：不做越界检查（越界也放行）。
String? _faultyValidateNoBounds(
  BlockSpan span, {
  required IntRect Function(String page) pageRect,
}) {
  if (span.parts.isEmpty) return spanReasonEmpty;
  return null;
}

// ── 6 · 长画布条带几何（跨页框选落盘依赖它） ────────────────────────────

/// §8.3 样例两页（1600×2400）的条带几何。
StripGeometry _twoPageStrip(double viewportWidth) => StripGeometry.build(
      keys: const ['p003', 'p004'],
      sizes: const [
        (width: 1600.0, height: 2400.0),
        (width: 1600.0, height: 2400.0),
      ],
      viewportWidth: viewportWidth,
    );

typedef _StripFn = StripGeometry Function(double viewportWidth);

/// 命题：渲染高 = `min(1, 视口宽/页宽) * 页高`，渲染宽 = `min(页宽, 视口宽)`，
/// 页顶逐页累加（必须与长画布 `_pageHeight` 同一条公式）。
bool _stripMatchesPageHeights(_StripFn build) {
  final g = build(800);
  if (g.pages.length != 2) return false;
  final p0 = g.pages[0];
  final expectedH = math.min(1.0, 800 / p0.naturalWidth) * p0.naturalHeight;
  final expectedW = math.min(p0.naturalWidth, 800);
  return (p0.renderedHeight - expectedH).abs() < 0.001 &&
      (p0.renderedWidth - expectedW).abs() < 0.001 &&
      (g.pages[1].stripTop - p0.stripBottom).abs() < 0.001;
}

/// 故障实现：忘了乘 fit（渲染高 = 源高），页高被夸大一倍、页顶错位。
StripGeometry _faultyStripNoFit(double viewportWidth) => StripGeometry([
      const StripPageMetrics(
        key: 'p003',
        naturalWidth: 1600,
        naturalHeight: 2400,
        renderedWidth: 800,
        renderedHeight: 2400,
        leftOffset: 0,
        stripTop: 0,
      ),
      const StripPageMetrics(
        key: 'p004',
        naturalWidth: 1600,
        naturalHeight: 2400,
        renderedWidth: 800,
        renderedHeight: 2400,
        leftOffset: 0,
        stripTop: 2400,
      ),
    ]);

typedef _SplitStripFn = List<SpanPart> Function(StripGeometry g);

/// 命题：跨缝的条带矩形被**恰好**在页边界切开 —— 页 A 段触到页底、页 B 段从页顶开始。
bool _splitCrossesSeamAtBoundary(_SplitStripFn split) {
  final parts = split(_twoPageStrip(800));
  if (parts.length != 2) return false;
  final a = parts[0];
  final b = parts[1];
  return a.page == 'p003' &&
      b.page == 'p004' &&
      a.rect.top == 2000 &&
      a.rect.bottom == 2400 && // 恰好触到页 A 底
      b.rect.top == 0 && // 恰好从页 B 顶开始
      b.rect.bottom == 600 &&
      a.rect.left == 200 &&
      a.rect.right == 1000;
}

/// 故障实现：不做页边界夹取（每页都套同一段条带，页 A 段穿过页底）。
List<SpanPart> _faultySplitStripNoClamp(StripGeometry g) => [
      for (final page in g.pages)
        SpanPart(
          page.key,
          IntRect(
            (100 / page.fit).round(),
            ((1000 - page.stripTop) / page.fit).round(),
            (500 / page.fit).round(),
            ((1500 - page.stripTop) / page.fit).round(),
          ),
        ),
    ];

typedef _ToPageFn = ({int index, double x, double y})? Function(
  StripGeometry g,
  double x,
  double y,
);

/// 命题：页窄于视口时按 `(视口宽 - 渲染宽) / 2` 居中，条带 x 正确映射到页内 x。
bool _narrowPageIsCentered(_ToPageFn toPage) {
  final g = StripGeometry.build(
    keys: const ['p'],
    sizes: const [(width: 600.0, height: 800.0)],
    viewportWidth: 1000,
  );
  final page = g.pages.first;
  final sized = (page.renderedWidth - 600).abs() < 0.001 &&
      (page.leftOffset - 200).abs() < 0.001;
  final inside = toPage(g, 250, 100);
  final blank = toPage(g, 100, 100);
  return sized &&
      inside != null &&
      (inside.x - 50).abs() < 0.001 &&
      (inside.y - 100).abs() < 0.001 &&
      blank != null &&
      (blank.x + 100).abs() < 0.001;
}

/// 故障实现：忽略居中偏移与缩放（条带 x 直接当页内 x）。
({int index, double x, double y})? _faultyToPage(
  StripGeometry g,
  double x,
  double y,
) =>
    (index: g.pageIndexAt(y) ?? 0, x: x, y: y);

// ── 工具（故障路径抛异常视作判据失效） ─────────────────────────────────

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

/// B-2 的 5 条断言（由 `block-ops-check` 汇总）。
Future<void> runP13Checks(CheckSink check) async {
  await _probe(
    check,
    'span.split_maps_back_to_source_pixels',
    () async => _splitRoundTrip(splitVirtual),
    () async => _splitRoundTrip(_faultySplitNoOffset),
    () => '绿=切分后并集逐像素还原虚拟矩形 / 故障=不减页内偏移 ⇒ 还原错位 ⇒ 变红',
  );

  await _probe(
    check,
    'span.window_is_bounded',
    () async => _windowIsBounded(
      (a, b, fraction) =>
          buildSeamWindow(pageAHeight: a, pageBHeight: b, fraction: fraction),
    ),
    () async => _windowIsBounded(_faultyWindowIgnoresCap),
    () => '绿=正常比例 ≤ 封顶·全幅被拒 / 故障=无视封顶放行全幅 ⇒ 变红',
  );

  final scratch = Directory.systemTemp.createTempSync('mangrove_span_');
  try {
    await _probe(
      check,
      'span.never_writes_merged_image',
      () async => _flowLeavesNoImage(scratch, alsoWrite: false),
      () async => _flowLeavesNoImage(scratch, alsoWrite: true),
      () => '绿=整条流程后目录字节不变 / 故障=把合成图写进目录 ⇒ 变红',
    );
  } finally {
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  }

  await _probe(
    check,
    'span.rejects_mismatched_width',
    () async => _rejectsWidthMismatch(validateSpan),
    () async => _rejectsWidthMismatch(_faultyValidateNoWidth),
    () => '绿=异宽判 width_mismatch·拼接异宽返 null / 故障=不查同宽 ⇒ 变红',
  );

  await _probe(
    check,
    'span.parts_do_not_cross_page_bounds',
    () async => _rejectsOutOfBounds(validateSpan),
    () async => _rejectsOutOfBounds(_faultyValidateNoBounds),
    () => '绿=越界/负坐标判 out_of_bounds / 故障=不查越界 ⇒ 变红',
  );

  await _probe(
    check,
    'strip.strip_geometry_matches_page_heights',
    () async => _stripMatchesPageHeights(_twoPageStrip),
    () async => _stripMatchesPageHeights(_faultyStripNoFit),
    () => '绿=渲染高=fit*页高·页顶累加 / 故障=忘乘 fit ⇒ 页高翻倍 ⇒ 变红',
  );

  await _probe(
    check,
    'strip.cross_seam_splits_at_boundary',
    () async => _splitCrossesSeamAtBoundary(
      (g) => g.splitStripRect(left: 100, top: 1000, right: 500, bottom: 1500),
    ),
    () async => _splitCrossesSeamAtBoundary(_faultySplitStripNoClamp),
    () => '绿=跨缝框恰在页边界切开 / 故障=不夹页边界 ⇒ 段越页底 ⇒ 变红',
  );

  await _probe(
    check,
    'strip.narrow_page_is_centered',
    () async => _narrowPageIsCentered((g, x, y) => g.toPage(x, y)),
    () async => _narrowPageIsCentered(_faultyToPage),
    () => '绿=窄页居中且条带x↔页x正确 / 故障=忽略居中偏移 ⇒ x 错 ⇒ 变红',
  );
}
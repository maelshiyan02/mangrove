// Geometry-only balloon clustering + reading order (S9 · P1-3 · 方案 A).
//
// 🔴 **为什么这个文件不含任何 widget / Flutter 代码**：算法要能被 headless
// 断言逐条验证（P9.3 的元教训：扫描型检查空结果必须判 FAIL，所以关键决策
// 必须有可执行的断言，而不是靠肉眼看图）。它只 import
// `image_translation/translation_types.dart` 里的 `IntRect` —— 那是本仓自有的
// 纯整数矩形，**不是** `dart:ui` 的同名类。
//
// 与 `translation_worker.dart` 里 `clusterOcrBoxes` 的分工（两者都叫"聚类"
// 但目标不同，阈值也因此必须不同）：
//
// | 层 | 输入 | 目的 | 犯错的代价 |
// |---|---|---|---|
// | `clusterOcrBoxes`（worker 内，isolate 侧） | DBNet 文本**行**框 | 把同一气泡内的多行并成一个 OCR 输入，**为了识别准确率** | 合并错 → OCR 识别崩坏 |
// | 本文件（P1-3） | 已 OCR 的**行** | 聚成**气泡**（版面单元）+ **阅读顺序**，**为了工程块粒度与校对顺序** | 合并错 → 一个块太大，逐字校对变累 |
//
// 所以本层**允许**比 worker 层更激进的合并：气泡大一点只影响排版，不影响
// 识别；反之 worker 层不敢激进。
library;

import 'dart:math' as math;

import 'translation_types.dart';

/// 一条已识别的文本行 —— 聚类的最小单位。
///
/// 刻意只用**几何 + 文本**，不带 `OcrBlock` 的颜色：聚类不关心那些，而把它
/// 排除掉能让本文件与 OCR 引擎解耦，也让人造数据能直接驱动它。
class TextLine {
  const TextLine({
    required this.rect,
    required this.text,
    this.language = 'unknown',
    this.lineHeight = 0,
  });

  final IntRect rect;

  /// 该行识别出的文本。空文本的行不参与聚类（见 [clusterBalloons]）。
  final String text;

  final String language;

  /// 原文字高（px），聚类后取中位数写进气泡。
  final int lineHeight;

  bool get isBlank => text.trim().isEmpty;
}

/// 一个聚出来的气泡：若干行 + 包住它们的框 + 阅读顺序位置。
///
/// 这是**几何结果**，不写进工程；`TextBlock.fromOcr` 才把它变成 FT 块。
class Balloon {
  Balloon({
    required this.lines,
    required this.bounds,
    this.column = 0,
    this.order = 0,
  });

  final List<TextLine> lines;

  /// 包住所有行的最小外框（**不加额外留白**，与 `fromOcr` 的 `xyxy` 一致）。
  final IntRect bounds;

  /// 所属列的序号。列的编号沿**阅读方向**递增（右起模式下 0 是最右列）。
  final int column;

  /// 全页阅读顺序中的下标，0 起。
  final int order;

  /// 气泡内文本，按阅读方向排好的行序。
  String get text => lines.map((l) => l.text.trim()).join('\n');

  /// 原文字高的中位数；`0` 表示未知（渲染器退回按框适配）。
  ///
  /// 用**中位数**而非均值：均值会被一个异常高的框拉走，而 `lineHeight` 唯一
  /// 的作用是给译文字号封顶。
  int get medianLineHeight {
    final heights = [for (final l in lines) l.lineHeight]
      ..removeWhere((h) => h <= 0)
      ..sort();
    if (heights.isEmpty) return 0;
    return heights[heights.length ~/ 2];
  }

  /// 主导书写方向。混排时以**多数行**为准。
  ///
  /// 🔴 不能只看外框：`fromOcr` 会按外框宽高比决定 `src_is_vertical`，两个
  /// 判据不一致时块会被标成竖排而文字是横排的。
  bool get isVertical {
    if (lines.isEmpty) return looksVertical;
    final vertical = [for (final l in lines) if (isVerticalLine(l.rect)) true]
        .length;
    return vertical * 2 > lines.length;
  }

  /// 外框高远大于宽（与 `TextBlock.fromOcr` 的 1.3 阈值**保持一致**）。
  bool get looksVertical => bounds.height > bounds.width * 1.3;
}

/// 单行是否竖排。包成顶层函数是为了让 [Balloon.isVertical] 与排序共用同一判据。
bool isVerticalLine(IntRect box) {
  if (box.height > box.width * 1.3) return true;
  return box.height > box.width && box.height - box.width <= 4;
}

/// 阅读方向。
///
/// 🔴 顺序不是"随便定一下"：日漫右起（左页在右），顺序错了整章校对顺序就
/// 完全颠倒，而用户只能靠逐块点选才发现。
enum ReadingDirection {
  /// 列从右往左，列内从上往下（日漫默认）。
  rightToLeft,

  /// 列从左往右，列内从上往下（欧漫/条漫默认）。
  leftToRight,
}

/// 聚块参数。默认值全部有 comic 排版上的依据，依据写在每个字段上。
class ClusterParams {
  const ClusterParams({
    this.gapFactor = 0.6,
    this.minGap = 6,
    this.maxGap = 90,
    this.columnGapFactor = 0.04,
  });

  /// 允许的最大行间隙 = `gapFactor × 全页字高中位数`，再夹到
  /// `[minGap, maxGap]`。
  ///
  /// **取值依据**：气泡内相邻行的行距通常是字高的 0.2~0.5 倍；相邻两个气泡
  /// 之间至少隔半个气泡短边，在 900×1778 的页面上普遍是 20~60px。取 0.6
  /// 倍字高能桥接气泡内的行距，同时跨不过气泡间的空隙。
  ///
  /// **上限 90px** 是必需的，不设上限时两个并排的大气泡会被横向桥接成一个
  /// 横跨半页的巨块。下限 6px：比 6px 更小的"间隙"是检测抖动而非真实排版。
  final double gapFactor;
  final int minGap;

  /// 见 [gapFactor]。必须存在，否则大页（1600×2500）上会误合并。
  final int maxGap;

  /// 列间判定的最小相对水平间隙 = `columnGapFactor × 页宽`。
  ///
  /// **取值依据**：分栏/多格版面的列间距通常在页宽的 4%~10%；取 4% 的下限是
  /// 为了不把"同一格子里左右两小段文字"错判成两列。
  final double columnGapFactor;
}

/// 把文本行聚成气泡，并按版面排出阅读顺序。
///
/// ## 算法（方案 A · 纯几何）
///
/// 1. **合并行**：并查集。若两行的"允许间隙"框相交**且**书写方向一致、
///    字高相差不过 `_mergeable` 里的倍数，则合并。
///    🔴 用**并查集**而非按顺序贪心两两合并：并查集对传递性是自然的
///    （A~B、B~C ⇒ A~C），贪心在检测器不保证输出顺序时会漏合并。
/// 2. **切列**：把气泡的 x 区间投到页面上，找**覆盖率为 0 的纵向缝隙**，
///    缝隙宽度超过 `columnGapFactor × 页宽` 就切一刀。列是阅读顺序的第一维
///    —— 不先切列，左右两格会被当成一列从上往下排。
/// 3. **排序**：列沿阅读方向编号（右起模式下 0 是最右列），列内按纵向位置
///    从上往下。
///
/// [pageWidth] 为 0 时**不切列**（整页当一列）：0 宽的页切出来是 0 列，比
/// 不切更糟。
List<Balloon> clusterBalloons(
  List<TextLine> lines, {
  int pageWidth = 0,
  ReadingDirection direction = ReadingDirection.rightToLeft,
  ClusterParams params = const ClusterParams(),
}) {
  final usable = [
    for (final line in lines)
      if (!line.isBlank && line.rect.width > 0 && line.rect.height > 0) line,
  ];
  if (usable.isEmpty) return const [];

  final heights = [for (final l in usable) l.rect.height]..sort();
  final medianHeight = heights[heights.length ~/ 2].toDouble();
  // 间隙阈值**全页统一**，而不是逐对计算：逐对会让阈值取决于"谁先被看到"，
  // 于是同一页两次跑可能给出不同的气泡数 —— 那会让"重跑一次就改了版面"
  // 成为可能，评审时无法区分是模型抖动还是代码不确定。
  final gap = (medianHeight * params.gapFactor)
      .round()
      .clamp(params.minGap, params.maxGap);

  final groups = _merge(usable, gap);
  final columnOfGroup = _assignColumns(groups, pageWidth, params.columnGapFactor);

  // 列号沿阅读方向递增：右起模式下 0 是最右列。
  final columnCount = columnOfGroup.values.toSet().length;
  final result = <Balloon>[];
  var order = 0;
  for (var readColumn = 0; readColumn < columnCount; readColumn++) {
    final inColumn = [
      for (final g in groups)
        // 🔴 `columnOfGroup` numbers columns left-to-right starting at 0;
        // this maps one of those to "is this the readColumn-th column".
        if (_isReadingColumn(columnOfGroup[g]!, readColumn, columnCount,
            direction))
          g,
    ]..sort((a, b) => a.bounds.top.compareTo(b.bounds.top));
    for (final group in inColumn) {
      result.add(
        Balloon(
          lines: _orderedLines(group.lines),
          bounds: group.bounds,
          column: readColumn,
          order: order++,
        ),
      );
    }
  }
  return result;
}

/// 左起列的序号（自左向右）是否就是当前正在读的那一列。
///
/// 右起模式下最右那列先读，所以阅读列 0 = 左起列的最后一列。分成这个函数是
/// 为了让「列号」与「阅读序」在代码里不再混用 —— 把两者揉在一个排序函数
/// 里，读起来像「方向只影响排序」，而实际上它还决定列号本身。
///
/// 🔴 返回 **bool** 而不是"列号 == readColumn ? 1 : 0"：后者在 `if` 里能过
/// 类型检查（int 在 Dart 里可以当条件），但它把"是不是这一列"和"这一列是
/// 几"两件事编码成同一个数，读的人得自己反应过来。
bool _isReadingColumn(
  int leftToRightIndex,
  int readColumn,
  int columnCount,
  ReadingDirection direction,
) {
  return direction == ReadingDirection.rightToLeft
      ? readColumn == columnCount - 1 - leftToRightIndex
      : readColumn == leftToRightIndex;
}

/// 把每个组指派到一列，返回 组 → 左起列号 的映射。
///
/// ## 列是怎么切的
///
/// 把所有组的 x 区间投到一条水平轴上，从左到右扫：**当前最右沿**与下一个
/// 区间左沿之间的空隙 ≥ 阈值时切一刀。阈值是 `columnGapFactor × 页宽`。
///
/// 🔴 明确**不做**"横向重叠即同列"的传递闭包：那个写法会把一页里所有横向
/// 互相搭上的气泡并成一列（三个气泡排成阶梯时 A~B、B~C 立刻全并），右起
/// 漫画于是被当成单列从上往下读 —— 恰好是本项要修的那个错。
///
/// 页宽未知（≤ 0）时返回全 0：**整页一列**。0 宽的页切出来是 0 列，比不切
/// 更糟，而调用方（`PureGeometryBalloonDetector`）总会传真实页宽。
Map<_Group, int> _assignColumns(
  List<_Group> groups,
  int pageWidth,
  double columnGapFactor,
) {
  final assignment = <_Group, int>{for (final g in groups) g: 0};
  if (groups.isEmpty || pageWidth <= 0) return assignment;
  final minGap = math.max(1, (pageWidth * columnGapFactor).round());
  // 按左沿排序；同左沿时按右沿排，保证结果与输入顺序无关（确定性）。
  final sorted = [...groups]
    ..sort((a, b) {
      final byLeft = a.bounds.left.compareTo(b.bounds.left);
      return byLeft != 0 ? byLeft : a.bounds.right.compareTo(b.bounds.right);
    });
  var column = 0;
  var rightmost = sorted.first.bounds.right;
  for (final group in sorted.skip(1)) {
    // 🔴 Assign on **every** path. An earlier version `continue`d past the
    // assignment when opening a new column, so the first group of every column
    // after the first kept the initial 0 — and the symptom was "all balloons
    // report column 0", i.e. the reading order silently degraded to top-to-bottom
    // for exactly the right-to-left manga this item exists for.
    if (group.bounds.left - rightmost >= minGap) {
      column++;
      rightmost = group.bounds.right;
    } else if (group.bounds.right > rightmost) {
      rightmost = group.bounds.right;
    }
    assignment[group] = column;
  }
  return assignment;
}

/// 并查集的一个组：若干行 + 包住它们的最小外框。
class _Group {
  _Group(this.first) : bounds = first.rect;

  /// 组的第一条行 —— 只用来在 `_merge` 里做种子（外框初值与方向判据）。
  final TextLine first;

  final List<TextLine> lines = [];

  /// 包住 [lines] 全部的最小外框。
  IntRect bounds;

  /// 把一行并进来并把 [bounds] 长到包住它。
  ///
  /// [IntRect] 的字段可变但没有合并方法，所以这里逐边取 min/max —— 顺带
  /// 也说明为什么这里不能直接把行框当成不可变值来传递。
  void add(TextLine line) {
    lines.add(line);
    final r = line.rect;
    bounds = IntRect(
      r.left < bounds.left ? r.left : bounds.left,
      r.top < bounds.top ? r.top : bounds.top,
      r.right > bounds.right ? r.right : bounds.right,
      r.bottom > bounds.bottom ? r.bottom : bounds.bottom,
    );
  }
}

/// 并查集合并：把「允许间隙内相交且方向一致」的行归到同组。
List<_Group> _merge(List<TextLine> lines, int gap) {
  final parents = List<int>.generate(lines.length, (i) => i);
  int find(int i) {
    while (parents[i] != i) {
      parents[i] = parents[parents[i]];
      i = parents[i];
    }
    return i;
  }

  // 间隙通过外扩实现。`IntRect.inflated` 要求页宽/页高做夹取，而这里只是
  // 判相交，夹取会破坏几何，因此传一个极大值（见 [_unclamped]）。
  final boxes = [
    for (final l in lines) l.rect.inflated(gap, gap, _unclamped, _unclamped),
  ];

  for (var i = 0; i < lines.length; i++) {
    for (var j = i + 1; j < lines.length; j++) {
      if (!boxes[i].intersects(boxes[j])) continue;
      if (!_mergeable(lines[i], lines[j])) continue;
      final ri = find(i);
      final rj = find(j);
      if (ri == rj) continue;
      parents[rj] = ri;
    }
  }

  final groups = <int, _Group>{};
  for (var i = 0; i < lines.length; i++) {
    groups.putIfAbsent(find(i), () => _Group(lines[i])).add(lines[i]);
  }
  return groups.values.toList();
}

/// A large "page size" so `IntRect.inflated` never clips during clustering.
///
/// 🔴 传真实页宽/页高会把落在页外的框夹回页内，让两个本不相交的框看起来
/// 相接 —— 那是典型的「阈值看起来在动、结果却在骗你」。
const int _unclamped = 1 << 28;

/// 行序：横排自上而下、同行自左而右；竖排自右而左、同列自上而下。
///
/// 🔴 竖排必须右起。竖排气泡里**右边的列先读**，用 `top` 排会把竖排译文
/// 左右颠倒 —— 这正是 P9.5 §三"绝不做没验证的断言"要防的那类错误。
List<TextLine> _orderedLines(List<TextLine> lines) {
  final sorted = [...lines];
  final vertical = [
    for (final l in lines)
      if (isVerticalLine(l.rect)) true
  ].length * 2 >
      lines.length;
  sorted.sort((a, b) {
    if (vertical) {
      final byColumn = b.rect.left.compareTo(a.rect.left);
      if (byColumn != 0) return byColumn;
      return a.rect.top.compareTo(b.rect.top);
    }
    final overlap = _verticalOverlap(a.rect, b.rect);
    final shorter = math.min(a.rect.height, b.rect.height);
    // 同"行"（垂直重叠过半）内按 x 排，否则按 y 排 —— 纯按 y 排会把
    // 同一行里因标点/假名宽窄不同而错开几个像素的行来回交换。
    if (shorter > 0 && overlap > shorter * 0.5) {
      final byRow = a.rect.left.compareTo(b.rect.left);
      if (byRow != 0) return byRow;
    }
    return a.rect.top.compareTo(b.rect.top);
  });
  return sorted;
}

int _verticalOverlap(IntRect a, IntRect b) {
  final top = math.max(a.top, b.top);
  final bottom = math.min(a.bottom, b.bottom);
  return bottom > top ? bottom - top : 0;
}

/// 两行能否归进同一个气泡。
///
/// 三个否决条件，每一个都对应一种真实的漫画排版：
///
/// 1. **方向不同**（一行明显横、一行明显竖）—— 一页里的图注与旁白常方向
///    相反，合起来送 OCR 会得到垃圾。
/// 2. **字高相差超过 2.2 倍** —— 漫画里小字注释与大号旁白并排很常见，
///    强行合并会让 `medianLineHeight` 取到折中值，译文字号两头不讨好。
/// 3. ~~同一行内左右相距过远~~ —— **否决**：这个条件看起来合理，但在
///    分栏版面里"同一个气泡"的两行本来就可能左右错开（竖排），加上它会把
///    竖排气泡拆成两半。先不加，由 `gap` 上限兜住跨气泡误合并。
bool _mergeable(TextLine a, TextLine b) {
  final dirA = _lineDirection(a.rect);
  final dirB = _lineDirection(b.rect);
  if (dirA != 0 && dirB != 0 && dirA != dirB) return false;
  final minH = math.min(a.rect.height, b.rect.height);
  final maxH = math.max(a.rect.height, b.rect.height);
  if (minH > 0 && maxH > minH * 2.2) return false;
  return true;
}

int _lineDirection(IntRect box) {
  if (box.width >= box.height * 1.25) return 1;
  if (box.height >= box.width * 1.25) return -1;
  return 0;
}

/// 扩展点（方案 B）：注入一个外部气泡检测器。
///
/// 🔴 **故意做成一个当前只有纯几何实现可用的接口**。方案 B 需要新增一个
/// ONNX 模型组件（下载/注册/worker 加载），工作量与 P0-1 同量级，且它的产出
/// 必须能被接缝消费 —— 在真的接上之前先把接口固定下来，好让落地路径
/// **现在**就写成「谁聚的都一样用」，将来换实现不改接缝。
///
/// [DetectedPage] / [DetectedBalloon] 只带纯几何，不 import 任何 OCR 类型：
/// 一个外部检测器不该被本仓的 OCR 形状绑住。
abstract class BalloonDetector {
  /// 检测一页的气泡，返回值**必须已按阅读顺序排好**。
  Future<List<DetectedBalloon>> detect(DetectedPage page);
}

/// 一页交给 [BalloonDetector] 的原始输入。
class DetectedPage {
  const DetectedPage({
    required this.width,
    required this.height,
    required this.lines,
  });

  final int width;
  final int height;

  /// 检测器输出的文本行框（未 OCR 亦可）。
  final List<IntRect> lines;
}

/// 检测器产出的一团候选气泡。
class DetectedBalloon {
  const DetectedBalloon({required this.bounds, this.lines = const []});

  final IntRect bounds;

  /// 归到该气泡的行框；空表示"检测器只给了气泡轮廓"。
  final List<IntRect> lines;
}

/// 方案 A：纯几何聚类，无需模型。
class PureGeometryBalloonDetector implements BalloonDetector {
  const PureGeometryBalloonDetector({
    this.direction = ReadingDirection.rightToLeft,
    this.params = const ClusterParams(),
  });

  final ReadingDirection direction;
  final ClusterParams params;

  @override
  Future<List<DetectedBalloon>> detect(DetectedPage page) async {
    final balloons = clusterBalloons(
      [
        // 聚类只看几何；给个非空占位文本免得被 `isBlank` 过滤掉。
        for (final rect in page.lines) TextLine(rect: rect, text: 'x'),
      ],
      pageWidth: page.width,
      direction: direction,
      params: params,
    );
    return [
      for (final b in balloons)
        DetectedBalloon(
          bounds: b.bounds,
          lines: [for (final l in b.lines) l.rect],
        ),
    ];
  }
}

/// 把一个气泡转成 `OcrBlock`，好让现有的 `TextBlock.fromOcr` 直接接上。
///
/// ## 为什么这一层存在
///
/// `TextBlock.fromOcr`（P9.5）消费的是 [OcrBlock]，不是 [Balloon]。若让
/// 落地路径自己从 `Balloon` 拼 `OcrBlock`，那份"颜色/语言怎么继承"的决定
/// 就会散落在工作室页面里 —— 而它必须和检测器一致（背景色取**并集内每个
/// 行的采样色**，不是随便挑一行），所以收在这里。
///
/// [backgroundColor] / [textColor] 由调用方给：聚类层不做像素采样（那需要
/// `RgbaImage`，而本文件刻意只依赖 [IntRect]）。
OcrBlock balloonToOcrBlock(
  Balloon balloon, {
  required int backgroundColor,
  required int textColor,
}) {
  return OcrBlock(
    rect: balloon.bounds,
    // 擦除掩码用**逐行**框而不是整块框：整块框会把气泡内相邻的美术一起擦掉
    // （worker 侧 `clusterOcrBoxes` 之后的 `ocrPage` 也是这么做的），这里
    // 保持一致，否则同一页在"旧引擎"与"工作室"两条路上的擦除结果会不同。
    eraseRects: [for (final l in balloon.lines) l.rect],
    text: balloon.text,
    // 语言取多数：聚类不识别语言，而 `fromOcr` 会把它写进 `language`。
    language: _majorLanguage(balloon.lines),
    backgroundColor: backgroundColor,
    textColor: textColor,
    lineHeight: balloon.medianLineHeight,
  );
}

String _majorLanguage(List<TextLine> lines) {
  if (lines.isEmpty) return 'unknown';
  final votes = <String, int>{};
  for (final line in lines) {
    final lang = line.language.trim();
    if (lang.isEmpty) continue;
    votes[lang] = (votes[lang] ?? 0) + 1;
  }
  if (votes.isEmpty) return 'unknown';
  // 相同票数时按语言码字典序取定序，避免"输入顺序不同→语言不同"的抖动。
  final best = votes.entries.reduce((a, b) {
    if (a.value != b.value) return a.value > b.value ? a : b;
    return a.key.compareTo(b.key) <= 0 ? a : b;
  });
  return best.key;
}
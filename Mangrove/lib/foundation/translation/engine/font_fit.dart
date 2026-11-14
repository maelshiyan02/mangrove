import 'dart:math' as math;

/// 「缩到放进框」的搜索起点：**用户请求的字号**（FT 的 `font_size`）与
/// **源文字实测高度**（`_detected_font_size`，在 region / 画布上叫
/// `lineHeight`）谁说了算。
///
/// 🔴 两条规则，按顺序：
///
/// 1. **用户一旦明确要了某个字号（`requested` 与 `measured` 不同），它就是上限。**
///    这里曾经是 `min(42, measured * 0.9, requested)` —— 三个 `min` 连乘。
///    对检测块来说 `requested == measured`（Mangrove 写入时两者同源），于是
///    用户的请求**永远**被 `measured * 0.9`（或那个写死的 42）压住：把字号从
///    24 拖到 120，屏幕上的字纹丝不动，看上去像"放大器坏了"。P0-1 声称"把
///    `font_size` 交给渲染器"，实际效果被这两层 `min` 完全抵消。
/// 2. 否则回落到**源字号**（×0.9：检测框含 leading，译文不该读起来比原文
///    还大），再回落到 [fallback]（什么都不知道时）。**这一步保证"没动过
///    滑块的块行为不变"**。
///
/// 返回的仍是**上限**，不是替换值：调用方的收缩循环可以**低于**它，所以
/// "20px 的框里请求 120px"照样不会溢出气泡。
///
/// ⚠️ `requested == measured` 之所以能代表"用户没动过"，是因为 Mangrove 写入时
/// 两者同源 —— `text_block.dart` 把 `_detected_font_size` 与 `font_size` 一起
/// 赋成同一个检测值，而用户拖动滑块**只**改 `font_size`。成品路径读的是
/// `round(_detected_font_size)`，所以 [tolerance] 要吃掉那 ≤0.5 的取整误差，
/// 同时小于滑块的最小步进（1），拖动一格即算"改过"。
double fitFontSizeCap({
  required double? requested,
  required double measured,
  double fallback = 42.0,
  double tolerance = 0.6,
}) {
  if (requested != null && requested > 0) {
    final userAsked = measured <= 0 || (requested - measured).abs() > tolerance;
    if (userAsked) return requested;
  }
  if (measured > 0) return math.max(10.0, measured * 0.9);
  return fallback;
}

/// P32 · 文字在块框内的放置偏移（纯数值，无 Flutter 依赖）。
///
/// 用户诉求：译文要像单元格里的文字一样**上下左右居中**落在气泡中心，而不
/// 是从框的左上角起排（旧行为在框大于文字时看起来像"首行缩进顶格"）。
///
/// 规则（画布预览与 result 出图**必须共用同一份**，见 A05 双端一致纪律）：
/// - 垂直方向：**恒居中**，`dy = (boxH - textH) / 2`；
/// - 水平方向：由对齐码决定（FT 约定 0=left / 1=center / 2=right）：
///   left ⇒ [inset]，center ⇒ `(boxW - textW) / 2`，
///   right ⇒ `boxW - inset - textW`；
/// - 文字比框宽/高时偏移允许为负（向两侧等量出血），不做夹取 —— 居中语义
///   本身就是对称的，夹到 0 会重新变成顶格。
///
/// [inset] 是 left/right 对齐时离框边的内缩像素（出图路径历史上留 2px）。
({double dx, double dy}) placeTextInBox({
  required double boxWidth,
  required double boxHeight,
  required double textWidth,
  required double textHeight,
  required int alignment,
  double inset = 0.0,
}) {
  final dx = switch (alignment) {
    0 => inset,
    2 => boxWidth - inset - textWidth,
    _ => (boxWidth - textWidth) / 2,
  };
  return (dx: dx, dy: (boxHeight - textHeight) / 2);
}

/// P33 · 字距：FT 的 `letter_spacing` 是**倍率**（1.15 = 自然字距 + 15%），
/// Flutter 的 `TextStyle.letterSpacing` 是**逻辑像素** ⇒ 换算必须乘字号。
///
/// 🔴 **为什么要有这个函数**：两条渲染路径原本各写一行，画布侧是
/// `(v - 1.0) * size`（对），成品侧 `page_renderer._fillStyle` 是 `(v - 1.0)`
/// （**漏乘字号**）—— 0.15 逻辑像素在 40px 的字上完全看不出来，于是
/// 「调字距滑块没反应」在**出图**上是个真 bug，而在画布上不是。这正是
/// A05 §1 警告的「两条路径不共享代码」的代价，P32 已把这类规则收敛进
/// 共用纯函数，本轮照做。
double? letterSpacingPx(double? multiplier, double fontSize) {
  if (multiplier == null) return null;
  return (multiplier - 1.0) * fontSize;
}

/// P33 · 行距默认值（FT `line_spacing` 的缺省，也是 Flutter `height` 的单位）。
///
/// 画布侧原本写 `?? 1.15`、成品侧 `RegionFontStyle` 默认 `1.2` —— 同一个
/// 「没设过行距」的块在两端行高差 0.05em。统一到 [this] 一个常量。
const double defaultLineSpacingValue = 1.2;

/// 行距倍率：缺失时取 [defaultLineSpacingValue]。
double lineSpacingOf(double? value) =>
    (value == null || value <= 0) ? defaultLineSpacingValue : value;

/// P33 · FT 字重（100..900，步长 100）→ Flutter `FontWeight` 的下标。
///
/// 🔴 两份**逐行相同**的 switch 原本分别躺在 `page_renderer._fontWeightOf`
/// 与 `text_block_canvas._weight`，注释里还互相称对方为「查表/阶梯」——
/// 任何一处改动都要靠人记得改另一处。抽出来后，双端共用同一张表。
int fontWeightIndex(int value) => switch (value) {
  <= 150 => 100,
  <= 250 => 200,
  <= 350 => 300,
  <= 450 => 400,
  <= 550 => 500,
  <= 650 => 600,
  <= 750 => 700,
  <= 850 => 800,
  _ => 900,
};

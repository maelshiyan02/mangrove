// Geometry only: pure functions over `Rect`/`Offset`, no widget code.
//
// 🔴 `Rect`/`Offset` live in `dart:ui`, so this file **does** import it — an
// earlier version of this comment claimed otherwise and the analyzer was right
// to reject it. What matters for headless testability is that there is no
// *widget* code and no need for a live Flutter binding: `dart:ui`'s `Rect` and
// `Offset` are plain geometry classes that resolve fine in the headless runner
// (the same reason `translation_types.dart` declares its own `IntRect` is to
// avoid the *binding*, not the geometry types).
//
// Consumers get `Rect`/`Offset` from their own imports; this file only has to
// use the types.
library;

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

/// The eight resize affordances of a selected text block.
///
/// Mirrors what every image editor shows: **four corners** (scale both axes,
/// keeping the opposite corner pinned) and **four edge midpoints** (one axis
/// only). [corners] exists so the painter and the hit test agree on the set and
/// its order — a mismatch there is the classic source of "the handle is drawn
/// there but dragging it does nothing".
enum ResizeHandle {
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
  top,
  bottom,
  left,
  right;

  bool get isCorner =>
      this == topLeft ||
      this == topRight ||
      this == bottomLeft ||
      this == bottomRight;

  /// True when this handle moves the **left** edge (so dragging must not also
  /// move the block's origin).
  bool get movesLeft => this == topLeft || this == bottomLeft || this == left;

  bool get movesRight =>
      this == topRight || this == bottomRight || this == right;

  bool get movesTop => this == topLeft || this == topRight || this == top;

  bool get movesBottom =>
      this == bottomLeft || this == bottomRight || this == bottom;
}

/// The eight handles, in a fixed order: corners first, then edges.
const resizeHandles = <ResizeHandle>[
  ResizeHandle.topLeft,
  ResizeHandle.topRight,
  ResizeHandle.bottomLeft,
  ResizeHandle.bottomRight,
  ResizeHandle.top,
  ResizeHandle.bottom,
  ResizeHandle.left,
  ResizeHandle.right,
];

/// Side length of a handle's hit target in **canvas** pixels.
///
/// 🔴 12 is deliberately larger than the 8px square that gets *drawn*: a finger
/// (or a mouse) rarely lands on an 8px target, and a handle that is visible but
/// not grabbable is the single most common complaint about hand-rolled resize
/// UI. The extra margin is invisible but doubles the usable target.
const resizeHandleHitSize = 12.0;

/// Side length of a handle's drawn square in canvas pixels.
const resizeHandleDrawSize = 8.0;

/// Centre of [handle] on a block whose box is [rect] — [rect] in **canvas**
/// pixels (i.e. already multiplied by the canvas fit).
///
/// Computed from the *midpoint* of the edge for the four edge handles so the
/// handle stays put even when the block is very narrow.
({Offset center, Rect box}) resizeHandleBox(Rect rect, ResizeHandle handle) {
  final cx = rect.center.dx;
  final cy = rect.center.dy;
  final Offset center0 = switch (handle) {
    ResizeHandle.topLeft => rect.topLeft,
    ResizeHandle.topRight => rect.topRight,
    ResizeHandle.bottomLeft => rect.bottomLeft,
    ResizeHandle.bottomRight => rect.bottomRight,
    ResizeHandle.top => Offset(cx, rect.top),
    ResizeHandle.bottom => Offset(cx, rect.bottom),
    ResizeHandle.left => Offset(rect.left, cy),
    ResizeHandle.right => Offset(rect.right, cy),
  };
  return (center: center0, box: rect);
}

/// The handle under [local], or null.
///
/// [local] is in canvas pixels; [rect] is the selected block's box in the same
/// space. Corners are tested **before** edges so that at a small block's corner
/// the corner (two-axis) handle wins — otherwise the invisible overlap belongs
/// to whichever was tested last, which made corners unusable on small boxes.
ResizeHandle? hitTestResizeHandle(Rect rect, Offset local) {
  if (rect.isEmpty) return null;
  ResizeHandle? cornerHit;
  ResizeHandle? edgeHit;
  for (final handle in resizeHandles) {
    final center = resizeHandleBox(rect, handle).center;
    final box = Rect.fromCenter(
      center: center,
      width: resizeHandleHitSize,
      height: resizeHandleHitSize,
    );
    if (!box.contains(local)) continue;
    if (handle.isCorner) {
      cornerHit = handle;
    } else {
      edgeHit ??= handle;
    }
  }
  return cornerHit ?? edgeHit;
}

/// Applies a resize drag to [start], returning the new box.
///
/// [start] and the result are in **page pixels** (the model's unit, i.e.
/// unscaled); [delta] is the pointer movement converted to page pixels.
///
/// ## Rules
///
/// * **Corners** scale both axes; the opposite corner stays put, so the block
///   grows away from the point the user grabbed.
/// * **Edges** move one axis only; the other edges stay put.
/// * The box is **never inverted and never collapses**: a minimum of
///   [minSize] is enforced, and dragging past the opposite edge clamps instead
///   of flipping (a flipped rect would render its text upside down and, worse,
///   write a negative width into FT's `xyxy`).
///
/// [minSize] is enforced **after** the clamp, because clamping against zero
/// and then against the minimum are different operations: the first prevents a
/// negative width, the second prevents an unusable sliver.
Rect applyResize({
  required Rect start,
  required ResizeHandle handle,
  required Offset delta,
  double minSize = 16.0,
}) {
  var left = start.left;
  var top = start.top;
  var right = start.right;
  var bottom = start.bottom;

  if (handle.movesLeft) left += delta.dx;
  if (handle.movesRight) right += delta.dx;
  if (handle.movesTop) top += delta.dy;
  if (handle.movesBottom) bottom += delta.dy;

  // Clamp each axis so the box can never invert. `right` is held at least
  // `left + minSize` and vice versa; using a single comparison direction avoids
  // the two-offsets-inconsistent flip.
  if (right - left < minSize) {
    if (handle.movesLeft) {
      left = right - minSize;
    } else {
      right = left + minSize;
    }
  }
  if (bottom - top < minSize) {
    if (handle.movesTop) {
      top = bottom - minSize;
    } else {
      bottom = top + minSize;
    }
  }
  return Rect.fromLTRB(left, top, right, bottom);
}

/// Normalises a drag from [anchor] to [current] into a positive-area rect.
///
/// A marquee dragged up/left has a negative width/height; FT's `xyxy` needs
/// l < t < r < b, so the axes are swapped when needed. A drag shorter than
/// [minSize] on either axis returns null so a stray click never creates a
/// degenerate block (which would be unletterable and, because it stays selected,
/// awkward to delete).
Rect? normalizeMarquee(Offset anchor, Offset current, {double minSize = 8.0}) {
  final left = math.min(anchor.dx, current.dx);
  final top = math.min(anchor.dy, current.dy);
  final right = math.max(anchor.dx, current.dx);
  final bottom = math.max(anchor.dy, current.dy);
  if (right - left < minSize || bottom - top < minSize) return null;
  return Rect.fromLTRB(left, top, right, bottom);
}

// ── 吸附（S9 · P9.7）───────────────────────────────────────────────────────
//
// 为什么需要：P9.3 登记过"缩放不吸附"。手工对齐 FT 里的块（同一格里的两块
// 上下对齐、跨页保持栏宽）靠眼睛在 900×1778 的页面上做，误差几十像素是常态，
// 而 FT 的 `xyxy` 是整数比较 —— 差 3px 就是一次假的"版面不一致"。
//
// 🔴 两个刻意的设计约束：
//
// 1. **吸附必须能被看见。** 拖到一半突然跳到别的位置、松手后没有解释，就是
//    本项目反复点名的"静默改动"。所以每个函数都**回传命中的参考线坐标**，
//    由画布画成虚线 —— 吸附是一个"被提示的动作"，不是一个偷换。
// 2. **吸附不许把矩形吸成不合法。** 吸附发生在 [applyResize] 的 `minSize`
//    夹取**之后**，一次吸附最多移动 [tolerance]，正好可能把尺寸压到最小之下
//    （小块的角点很容易）。所以每条边吸附后都要重新验证尺寸，不合格就退回
//    吸附前的值 —— 宁可不对齐，也不产出一个不可用的细条。

/// 默认吸附容差，单位是**页像素**（模型单位）。取值依据：900×1778 的页面上
/// 人手拖动的稳定精度约在 3–5px，取 4 既能把"想对齐"和"差一点"分开，又不会
/// 在块密集处把用户**想**放的位置抢走。
const resizeSnapTolerance = 4.0;

/// [value] 拉到 [targets] 里最近的一个，前提是距离 ≤ [tolerance]。
({double value, bool snapped}) snapEdge(
  double value,
  Iterable<double> targets,
  double tolerance,
) {
  if (tolerance <= 0) return (value: value, snapped: false);
  var best = value;
  var bestDistance = tolerance;
  var snapped = false;
  for (final target in targets) {
    final distance = (target - value).abs();
    if (distance > bestDistance) continue;
    // `<=` 让"等距时取后者"成为确定行为：候选取自一个 List，顺序稳定，
    // 于是同一拖动序列两次跑给出同一个结果（P9.6 `cluster.order_is_deterministic`
    // 定的同一条规矩）。
    best = target;
    bestDistance = distance;
    snapped = true;
  }
  return (value: best, snapped: snapped);
}

/// [applyResize] + 把**被该 handle 移动的那条边**吸附到 [targetsX]/[targetsY]。
///
/// 只吸附被移动的边：未移动的边本来就没动，允许它们吸附等于让"正确的"那条边
/// 也跳一下，用户会以为是自己拖歪了。
///
/// 返回的 `guidesX`/`guidesY` 是真正命中的参考线坐标（也是页像素），供画布
/// 画指示线；**空表示没有吸附**，所以调用方不能把"有 guide"当成"有吸附意图"。
({Rect rect, List<double> guidesX, List<double> guidesY}) snapResize({
  required Rect start,
  required ResizeHandle handle,
  required Offset delta,
  Iterable<double> targetsX = const [],
  Iterable<double> targetsY = const [],
  double tolerance = resizeSnapTolerance,
  double minSize = 16.0,
}) {
  var rect = applyResize(
    start: start,
    handle: handle,
    delta: delta,
    minSize: minSize,
  );
  final guidesX = <double>[];
  final guidesY = <double>[];

  if (handle.movesLeft) {
    final hit = snapEdge(rect.left, targetsX, tolerance);
    if (hit.snapped && rect.right - hit.value >= minSize) {
      rect = Rect.fromLTRB(hit.value, rect.top, rect.right, rect.bottom);
      guidesX.add(hit.value);
    }
  } else if (handle.movesRight) {
    final hit = snapEdge(rect.right, targetsX, tolerance);
    if (hit.snapped && hit.value - rect.left >= minSize) {
      rect = Rect.fromLTRB(rect.left, rect.top, hit.value, rect.bottom);
      guidesX.add(hit.value);
    }
  }
  if (handle.movesTop) {
    final hit = snapEdge(rect.top, targetsY, tolerance);
    if (hit.snapped && rect.bottom - hit.value >= minSize) {
      rect = Rect.fromLTRB(rect.left, hit.value, rect.right, rect.bottom);
      guidesY.add(hit.value);
    }
  } else if (handle.movesBottom) {
    final hit = snapEdge(rect.bottom, targetsY, tolerance);
    if (hit.snapped && hit.value - rect.top >= minSize) {
      rect = Rect.fromLTRB(rect.left, rect.top, rect.right, hit.value);
      guidesY.add(hit.value);
    }
  }
  return (rect: rect, guidesX: guidesX, guidesY: guidesY);
}

/// 移动一个块的同时把它的边吸附到 [targetsX]/[targetsY]，返回**修正后的位移**。
///
/// 每一步只改一条轴，且该轴上取"调整量更小"的那条边（左边对齐更近就按左边，
/// 右边对齐更近就按右边）：只看左边的话，把块的右边缘对到另一块的左边缘就
/// 永远对不上，而那恰恰是最常用的对齐方式（两块并排）。
///
/// 与 [snapResize] 不同，这里没有尺寸约束要验 —— 平移不改变宽高，因此吸附
/// 不可能造出不合法矩形。
({Offset offset, List<double> guidesX, List<double> guidesY}) snapMove({
  required Rect start,
  required Offset offset,
  Iterable<double> targetsX = const [],
  Iterable<double> targetsY = const [],
  double tolerance = resizeSnapTolerance,
}) {
  var dx = offset.dx;
  var dy = offset.dy;
  final guidesX = <double>[];
  final guidesY = <double>[];

  final moved = start.shift(offset);
  final leftHit = snapEdge(moved.left, targetsX, tolerance);
  final rightHit = snapEdge(moved.right, targetsX, tolerance);
  final leftAdjust = leftHit.snapped ? leftHit.value - moved.left : null;
  final rightAdjust = rightHit.snapped ? rightHit.value - moved.right : null;
  if (leftAdjust != null || rightAdjust != null) {
    final byLeft = rightAdjust == null ||
        (leftAdjust != null && leftAdjust.abs() <= rightAdjust.abs());
    final adjust = byLeft ? leftAdjust! : rightAdjust!;
    dx += adjust;
    guidesX.add((byLeft ? leftHit.value : rightHit.value));
  }
  final topHit = snapEdge(moved.top, targetsY, tolerance);
  final bottomHit = snapEdge(moved.bottom, targetsY, tolerance);
  final topAdjust = topHit.snapped ? topHit.value - moved.top : null;
  final bottomAdjust = bottomHit.snapped ? bottomHit.value - moved.bottom : null;
  if (topAdjust != null || bottomAdjust != null) {
    final byTop = bottomAdjust == null ||
        (topAdjust != null && topAdjust.abs() <= bottomAdjust.abs());
    final adjust = byTop ? topAdjust! : bottomAdjust!;
    dy += adjust;
    guidesY.add((byTop ? topHit.value : bottomHit.value));
  }
  return (offset: Offset(dx, dy), guidesX: guidesX, guidesY: guidesY);
}

/// 吸附参考坐标：其它块的边 + 页面边界。
///
/// 🔴 [self] 必须排除在外。把被拖动的块自己的边当成参考，每条边都会"吸"回
/// 原位，块就再也拖不动了 —— 而症状看起来像"卡住"，不是"吸附配错了"。
({List<double> xs, List<double> ys}) snapTargets(
  Iterable<Rect> others, {
  double? pageWidth,
  double? pageHeight,
}) {
  final xs = <double>[];
  final ys = <double>[];
  for (final rect in others) {
    xs..add(rect.left)..add(rect.right);
    ys..add(rect.top)..add(rect.bottom);
  }
  if (pageWidth != null) xs..add(0)..add(pageWidth);
  if (pageHeight != null) ys..add(0)..add(pageHeight);
  return (xs: xs, ys: ys);
}

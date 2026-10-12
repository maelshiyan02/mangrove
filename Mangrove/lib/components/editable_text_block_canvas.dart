import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'block_resize_geometry.dart';
import 'text_block_canvas.dart';

/// Interactive page canvas for the translation studio: tap to select, drag to
/// move a text block, drag a handle to resize it, double-tap to ask the owner to
/// edit its text.
///
/// ## Why a separate widget instead of making [TextBlockCanvas] editable
///
/// [TextBlockCanvas] is shared by the studio page **and** the read-only
/// `StudioPreviewPage`, so bolting gestures onto it would change the preview
/// too. P8.0 §三 item 2 recorded this as the "shared read-only canvas" risk and
/// suggested a distinct widget over a shared drawing layer — which is what this
/// is: it reuses [PageCanvasPainter] and [hitTestCanvasBlocks] and only adds the
/// gesture handling and the live drag overlay. The painting rules stay in one
/// place, so the read-only and editable canvases cannot drift apart.
///
/// ## Why the drag is not written to the model until it ends
///
/// Dragging mutates only a local offset and repaints the dragged block at its
/// preview position. The model (and therefore the undo command) is touched once,
/// on drag end, so a drag is **one** undo step rather than one per pointer
/// event — which is what the acceptance criterion "Ctrl+Z 连续撤销 20 步正确"
/// needs. Resize follows the same rule for the same reason.
///
/// ## How the three drag gestures avoid fighting each other
///
/// A canvas this small has to answer "is this drag a move, a resize, or a new
/// box?" on pointer-down. The resolution is by **intent**, decided once at
/// `onPanStart` and then held for the whole gesture:
///
/// 1. **Marquee mode** ([marqueeMode] on) → any drag draws a new box. This is an
///    explicit mode rather than "drag on empty space", because a drag starting
///    inside the selected block is far more often a move than an intent to
///    replace the selection.
/// 2. **A handle of the selected block** → resize (checked *before* the block
///    hit test; a handle sits inside the block, so the wrong order makes small
///    blocks unresizeable).
/// 3. **Inside any block** → move.
/// 4. **Empty space** → nothing (a plain tap clears the selection).
///
/// Deciding once matters: re-deciding per `onPanUpdate` would flip a move into a
/// marquee the moment the pointer crossed the block's edge.
class EditableTextBlockCanvas extends StatefulWidget {
  const EditableTextBlockCanvas({
    super.key,
    required this.blocks,
    required this.selectedIndex,
    required this.onSelect,
    this.base,
    this.originalSize,
    this.loading = false,
    this.showBoxes = true,
    this.onMoveBlock,
    this.onResizeBlock,
    this.onMarquee,
    this.onEditText,
    this.marqueeMode = false,
    this.groupFrame,
    this.onResizeGroup,
    this.groupPickMode = false,
    this.onPickBlock,
  });

  final List<CanvasTextBlock> blocks;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  final DecodedPage? base;
  final Size? originalSize;
  final bool loading;
  final bool showBoxes;

  /// Fires once when a drag finishes, with the block index and its top-left in
  /// **page pixels** before and after the move.
  final void Function(int index, Offset oldTopLeft, Offset newTopLeft)? onMoveBlock;

  /// Fires once when a resize drag finishes, with the block index and its box
  /// in **page pixels** before and after.
  final void Function(int index, Rect oldRect, Rect newRect)? onResizeBlock;

  /// Fires when the user drags out a new box, with its rect in **page pixels**.
  ///
  /// Ignored (no call) when the drag was too small to be a box — a stray click
  /// must not create an unletterable sliver.
  final void Function(Rect rect)? onMarquee;

  /// Fires on double-tap, so the owner can focus the translation field.
  final ValueChanged<int>? onEditText;

  /// When true the canvas is in "draw a new box" mode: every drag draws a
  /// marquee instead of moving or resizing. Toggled by the owner's toolbar.
  final bool marqueeMode;

  /// P31：当前可整体缩放的 nest 组外框（成员都在本页时 owner 才给）；null =
  /// 没有可拖的组外框。框上 8 个手柄与块手柄走同一套 eager 抢占。
  final CanvasGroupFrame? groupFrame;

  /// P31：组外框缩放结束回调一次（页像素的旧/新**并集框**）。owner 负责把同
  /// 一几何变换施加到全部成员块并合成**一次**撤销步。
  final void Function(String groupId, Rect oldBounds, Rect newBounds)?
      onResizeGroup;

  /// P32：建组点选模式（单页/缩放模式下也可用）。
  ///
  /// 为 true 时本画布**只读化**：命中块的 tap 改走 [onPickBlock]（再点同块
  /// 取消由 owner 处理），点空白不回调；移动/缩放/框选/长按拖/双击编辑全部
  /// 禁用 —— 点选模式里任何改框手势都是误触风险（与长画布点选时换用只读
  /// TextBlockCanvas 是同一条策略）。
  final bool groupPickMode;

  /// 命中块时回调本页块下标（单页画布没有投影片段，下标即真身）。
  final ValueChanged<int>? onPickBlock;

  @override
  State<EditableTextBlockCanvas> createState() => _EditableTextBlockCanvasState();
}

/// What the current drag is doing. Decided once on pan start.
enum _DragKind {
  none,
  move,
  resize,
  marquee,

  /// P31：拖 nest 组外框手柄 —— 全部成员块随并集框同因子整体缩放。
  groupResize,
}

class _EditableTextBlockCanvasState extends State<EditableTextBlockCanvas> {
  _DragKind _kind = _DragKind.none;

  /// Index being moved or resized, or -1.
  int _dragIndex = -1;

  /// Live move offset, in page pixels.
  Offset _dragOffset = Offset.zero;

  /// Live resize delta from the gesture's start, in page pixels.
  ///
  /// 🔴 Accumulated from the gesture's start rather than from the previous
  /// frame's result: `applyResize` clamps to prevent inversion, and clamping
  /// is not invertible — measuring the next frame from the clamped box would
  /// ratchet the edge further on every event.
  Offset _dragDelta = Offset.zero;

  /// Which handle is being dragged.
  ResizeHandle _dragHandle = ResizeHandle.topLeft;

  /// Marquee anchor in canvas pixels (set on pan start in marquee mode).
  Offset? _marqueeAnchor;

  /// The canvas scale of the last build, stashed because the gesture callbacks
  /// are invoked outside the `LayoutBuilder` that computed it.
  double _fit = 1.0;

  /// The natural page size of the last build — long-press callbacks run outside
  /// the `LayoutBuilder` but [_captureSnapTargets] needs it.
  Size _natural = Size.zero;

  /// Last pointer position during a long-press drag; deltas are the difference
  /// between consecutive updates (long-press updates have no `delta` field).
  Offset _longPressLastLocal = Offset.zero;

  /// Snap reference coordinates for the current gesture, in **page** pixels.
  ///
  /// Captured once at pan start rather than recomputed per event, so the set
  /// cannot change mid-drag (the preview and the committed command must agree).
  List<double> _snapXs = const [];
  List<double> _snapYs = const [];

  /// Live marquee in canvas pixels — the unit the painter draws it in.
  Rect? _marquee;

  int _doubleTapIndex = -1;

  /// 🔴 P31：pointer-down 当下就判定这一势是否要让 pan 识别器**抢先独占**。
  ///
  /// 背景：手柄命中盒只有 ±6px，触摸 pan slop 36px、鼠标 2px；旧实现的"定种"
  /// 发生在越 slop 之后（localPosition 已是漂移位置），垂直拖手柄还会被外层
  /// ListView（slop 1px）/ InteractiveViewer 先抢赢 —— 8 个手柄于是全部失灵。
  /// 这里在 down 点（**未漂移的按下位置**）命中手柄/框选模式时，让
  /// [_EagerPanGestureRecognizer] 在竞技场 close 前直接声明获胜，同时取消 pan
  /// 的 slop 门槛，第一个 move 就进 resize/marquee，无死区。
  ///
  /// 不包括"块体普通移动"：块体的垂直拖动仍让位给长画布滚动（P30：移动块用
  /// 长按 500ms），这里只抢"除了手势没有别的解释"的两类起手。
  bool _eagerClaimAt(Offset local) {
    // P32：点选模式整体只读，任何抢先（框选/手柄）都不允许 —— 单指拖动要
    // 留给外层 InteractiveViewer 平移页面。
    if (widget.groupPickMode) return false;
    if (widget.marqueeMode) return true;
    // P31：组外框手柄在最外层（并集 ±8px），先于成员块手柄判定 —— 恰好压在
    // 并集边上的成员角点两者命中盒重叠，让看得见、画在最上面的组框先赢。
    if (_hitGroupFrameHandle(local) != null) return true;
    final sel = widget.selectedIndex;
    if (sel < 0 || sel >= widget.blocks.length) return false;
    final r = widget.blocks[sel].rect;
    final canvasRect = Rect.fromLTRB(
      r.left * _fit,
      r.top * _fit,
      r.right * _fit,
      r.bottom * _fit,
    );
    return hitTestResizeHandle(canvasRect, local) != null;
  }

  /// P31：把组外框（页像素并集）换算成画布坐标的**视觉框**（与 painter 的
  /// nest rrect 同框：并集 ±8px）；无活动组框返回 null。
  Rect? _groupFrameCanvasRect() {
    final frame = widget.groupFrame;
    if (frame == null) return null;
    final b = frame.bounds;
    return Rect.fromLTRB(
      b.left * _fit - 8,
      b.top * _fit - 8,
      b.right * _fit + 8,
      b.bottom * _fit + 8,
    );
  }

  /// P31：[local]（画布像素）是否落在组外框的某个手柄上；命中返回手柄。
  ResizeHandle? _hitGroupFrameHandle(Offset local) {
    final rect = _groupFrameCanvasRect();
    if (rect == null) return null;
    return hitTestResizeHandle(rect, local);
  }

  /// P31：组外框整体缩放时，把成员矩形 [r] 从旧并集框线性映射到新并集框
  /// （双精度 live preview 版；落盘的整数版在 `block_group.scaleRectsToBounds`，
  /// headless 断言钉的是同一条公式）。
  Rect _mapRectToBounds(Rect r, Rect oldBounds, Rect newBounds) {
    if (oldBounds.width <= 0 || oldBounds.height <= 0) return r;
    final sx = newBounds.width / oldBounds.width;
    final sy = newBounds.height / oldBounds.height;
    return Rect.fromLTRB(
      newBounds.left + (r.left - oldBounds.left) * sx,
      newBounds.top + (r.top - oldBounds.top) * sy,
      newBounds.left + (r.right - oldBounds.left) * sx,
      newBounds.bottom + (r.bottom - oldBounds.top) * sy,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (widget.loading) {
      return Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2, color: scheme.primary),
        ),
      );
    }
    final page = widget.base;
    if (page == null) {
      return Center(
        child: Text(
          'No image for this page',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      );
    }
    final natural = widget.originalSize ?? page.originalSize;
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = Size(
          constraints.maxWidth.isFinite ? constraints.maxWidth : natural.width,
          constraints.maxHeight.isFinite ? constraints.maxHeight : natural.height,
        );
        final fit = math.min(
          available.width / natural.width,
          available.height / natural.height,
        );
        final canvasSize = Size(natural.width * fit, natural.height * fit);
        final preview = _preview(fit, natural);
        // 手势回调在 LayoutBuilder 之外触发（长按系列尤其是），fit/页面自然
        // 尺寸必须随每次 build 存好，不能只在 onPanStart 里赋值。
        _fit = fit;
        _natural = natural;

        /// Convert a canvas-pixel point to page pixels (the model's unit).
        Offset toPage(Offset local) => Offset(local.dx / fit, local.dy / fit);

        int hit(Offset local) => hitTestCanvasBlocks(preview.blocks, toPage(local));

        return Center(
          // 🔴 P31：RawGestureDetector + [_EagerPanGestureRecognizer]。
          // pan 在按下点命中手柄/框选时立即声明获胜，不再让 slop 漂移后的位置
          // 决定命中、也不再被外层 ListView/InteractiveViewer 以 1~2px 的 slop
          // 抢走。tap/doubleTap 仍走 [_gestureTeam] 共存，long-press 拖动（P30）
          // 原样保留。识别器映射的顺序即 pointer 注册顺序：pan 第一，只有它
          // 会 eager 声明，因此不会出现两个 eager 赢家的歧义。
          child: RawGestureDetector(
            behavior: HitTestBehavior.opaque,
            gestures: <Type, GestureRecognizerFactory>{
              _EagerPanGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<_EagerPanGestureRecognizer>(
                () => _EagerPanGestureRecognizer(
                  debugOwner: this,
                  claimAt: _eagerClaimAt,
                ),
                (r) {
                  r
                    ..dragStartBehavior = DragStartBehavior.down
                    ..onStart = (details) {
                      _onPanStart(details.localPosition, fit, natural);
                    }
                    ..onUpdate = (details) {
                      _onPanUpdate(details.localPosition, details.delta);
                    }
                    ..onEnd = (_) {
                      _finishDrag();
                    }
                    ..onCancel = _finishDrag;
                },
              ),
              LongPressGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
                () => LongPressGestureRecognizer(debugOwner: this),
                (r) {
                  r
                    // 🔴 长按拖动（P30）：长画布里垂直拖拽归 ListView 滚动、
                    // 单页里 InteractiveViewer 也会争用 pan —— 普通 pan 经常赢
                    // 不了竞技场。长按 500ms 后长按识别器**独占**手势，随后移动
                    // 必然到达这里，块才"拖得动"。判定顺序与 [_onPanStart] 完全
                    // 一致（先手柄后块、一次定种、整势保持）。
                    ..onLongPressStart = (details) {
                      _onLongPressStart(details.localPosition);
                    }
                    ..onLongPressMoveUpdate = (details) {
                      _onLongPressMove(details.localPosition);
                    }
                    ..onLongPressEnd = (_) {
                      _finishDrag();
                    }
                    ..onLongPressCancel = _finishDrag;
                },
              ),
              TapGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                () => TapGestureRecognizer(debugOwner: this),
                (r) {
                  r
                    ..onTapUp = (details) {
                      // P32：建组点选模式 —— 命中块才回调（再点取消由 owner
                      // 判定）；点空白不回调，避免误清普通选择之外的状态。
                      if (widget.groupPickMode) {
                        final index = hit(details.localPosition);
                        if (index >= 0) widget.onPickBlock?.call(index);
                        return;
                      }
                      // In marquee mode a tap must not steal the selection: the
                      // user is lining up a drag, and clearing the selection
                      // mid-way would drop the handles they are aiming between.
                      if (widget.marqueeMode) return;
                      widget.onSelect(hit(details.localPosition));
                    };
                },
              ),
              DoubleTapGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<DoubleTapGestureRecognizer>(
                () => DoubleTapGestureRecognizer(debugOwner: this),
                (r) {
                  r
                    ..onDoubleTapDown = (details) {
                      _doubleTapIndex = hit(details.localPosition);
                    }
                    ..onDoubleTap = () {
                      // P32：点选模式禁用双击进编辑。
                      if (widget.groupPickMode) return;
                      if (_doubleTapIndex >= 0) {
                        widget.onEditText?.call(_doubleTapIndex);
                      }
                    };
                },
              ),
            },
            child: CustomPaint(
              size: canvasSize,
              painter: PageCanvasPainter(
                page: page,
                natural: natural,
                fit: fit,
                blocks: preview.blocks,
                selectedIndex: widget.selectedIndex,
                showBoxes: widget.showBoxes,
                outline: scheme.outlineVariant,
                selection: scheme.primary,
                untranslated: scheme.onSurfaceVariant,
                showResizeHandles: true,
                activeGroupFrame: preview.groupFrame,
                marquee: _marquee,
                snapGuidesX: preview.guidesX,
                snapGuidesY: preview.guidesY,
              ),
            ),
          ),
        );
      },
    );
  }

  /// The drag preview plus the snap guides it landed on, both ready for the
  /// painter (guides already converted to **canvas** pixels).
  ///
  /// One function feeds both, on purpose: when the drawn box and the committed
  /// box were computed separately they could disagree, and the user would see
  /// the block jump on release — the exact complaint snapping is supposed to
  /// fix, only louder.
  ({
    List<CanvasTextBlock> blocks,
    List<double> guidesX,
    List<double> guidesY,
    CanvasGroupFrame? groupFrame,
  }) _preview(double fit, Size natural) {
    final index = _dragIndex;
    final live = _kind != _DragKind.none &&
        (_kind == _DragKind.groupResize
            ? widget.groupFrame != null
            : index >= 0 && index < widget.blocks.length) &&
        (_dragOffset != Offset.zero || _dragDelta != Offset.zero);
    if (!live) {
      return (
        blocks: widget.blocks,
        guidesX: const <double>[],
        guidesY: const <double>[],
        groupFrame: widget.groupFrame,
      );
    }
    // P31：组外框整体缩放 —— 新并集框由同一条 applyResize 几何给出，每个成员
    // 块按 [_mapRectToBounds] 同步换矩形；不做吸附（参考系是整组，逐边吸附会
    // 让同组块错位），手柄/大框跟随新并集。
    if (_kind == _DragKind.groupResize) {
      final frame = widget.groupFrame!;
      final liveBounds = applyResize(
        start: frame.bounds,
        handle: _dragHandle,
        delta: _dragDelta,
        // 组框最小边给 32：成员往往不止一个，16 会把整组压成不可读的细条。
        minSize: 32.0,
      );
      final result = List<CanvasTextBlock>.of(widget.blocks);
      for (final memberIndex in frame.memberIndices) {
        if (memberIndex < 0 || memberIndex >= result.length) continue;
        result[memberIndex] = result[memberIndex].copyWith(
          rect: _mapRectToBounds(
            result[memberIndex].rect,
            frame.bounds,
            liveBounds,
          ),
        );
      }
      return (
        blocks: result,
        guidesX: const <double>[],
        guidesY: const <double>[],
        groupFrame: CanvasGroupFrame(
          groupId: frame.groupId,
          bounds: liveBounds,
          memberIndices: frame.memberIndices,
        ),
      );
    }
    final result = List<CanvasTextBlock>.of(widget.blocks);
    final block = result[index];
    if (_kind == _DragKind.move) {
      final snap = snapMove(
        start: block.rect,
        offset: _dragOffset,
        targetsX: _snapXs,
        targetsY: _snapYs,
      );
      result[index] = block.copyWith(rect: block.rect.shift(snap.offset));
      return (
        blocks: result,
        guidesX: [for (final x in snap.guidesX) x * fit],
        guidesY: [for (final y in snap.guidesY) y * fit],
        groupFrame: widget.groupFrame,
      );
    }
    // 🔴 Resize accumulates from the gesture's **start** box, never from the
    // previous frame's result: `applyResize` clamps to prevent inversion, and a
    // clamp is not invertible — measuring the next frame from the already-clamped
    // box would ratchet that edge further on every event.
    final snap = snapResize(
      start: block.rect,
      handle: _dragHandle,
      delta: _dragDelta,
      targetsX: _snapXs,
      targetsY: _snapYs,
    );
    result[index] = block.copyWith(rect: snap.rect);
    return (
      blocks: result,
      guidesX: [for (final x in snap.guidesX) x * fit],
      guidesY: [for (final y in snap.guidesY) y * fit],
      groupFrame: widget.groupFrame,
    );
  }

  /// Decides what the whole gesture will do, once. See the class doc for why
  /// this must not be re-evaluated during the drag.
  void _onPanStart(Offset local, double fit, Size natural) {
    _fit = fit;
    // P32：点选模式只读 —— 即便 pan 识别器赢了竞技场也不定种任何拖拽，
    // 更不能借 onSelect 改普通选择。
    if (widget.groupPickMode) return;
    if (widget.marqueeMode) {
      setState(() {
        _kind = _DragKind.marquee;
        _marqueeAnchor = local;
        _marquee = Rect.fromPoints(local, local);
      });
      return;
    }

    // P31：nest 组外框手柄最先判（它画在最外层、并集外扩 8px；与成员角点
    // 重叠时组框赢）。命中即定种 groupResize，整势不变。
    final groupHandle = _hitGroupFrameHandle(local);
    if (groupHandle != null) {
      setState(() {
        _kind = _DragKind.groupResize;
        _dragIndex = -1;
        _dragHandle = groupHandle;
        _dragDelta = Offset.zero;
      });
      return;
    }

    // 🔴 Handles are tested **before** the block hit test. A handle sits inside
    // the block it belongs to, so testing blocks first would make the corner
    // handles of a small block unreachable — the classic "the dots are there
    // but dragging them moves the block" bug.
    final sel = widget.selectedIndex;
    if (sel >= 0 && sel < widget.blocks.length) {
      final r = widget.blocks[sel].rect;
      final canvasRect = Rect.fromLTRB(
        r.left * fit,
        r.top * fit,
        r.right * fit,
        r.bottom * fit,
      );
      final handle = hitTestResizeHandle(canvasRect, local);
      if (handle != null) {
        _captureSnapTargets(sel, natural);
        setState(() {
          _kind = _DragKind.resize;
          _dragIndex = sel;
          _dragHandle = handle;
        });
        return;
      }
    }

    final index = hitTestMovableCanvasBlocks(
      widget.blocks,
      Offset(local.dx / fit, local.dy / fit),
    );
    if (index < 0) return; // empty space: let a plain tap clear the selection
    _captureSnapTargets(index, natural);
    setState(() {
      _kind = _DragKind.move;
      _dragIndex = index;
      _dragOffset = Offset.zero;
      widget.onSelect(index);
    });
  }

  /// Long-press counterpart of [_onPanStart] (marquee is intentionally not
  /// reachable this way — a long press inside the new-box mode must not start
  /// moving blocks).
  void _onLongPressStart(Offset local) {
    // P32：点选模式禁用长按拖拽。
    if (widget.groupPickMode) return;
    if (widget.marqueeMode) return;
    final fit = _fit;
    final natural = _natural;
    // P31：组外框手柄与 pan 路径同一判定顺序（先于成员手柄/块体）。
    final groupHandle = _hitGroupFrameHandle(local);
    if (groupHandle != null) {
      _longPressLastLocal = local;
      setState(() {
        _kind = _DragKind.groupResize;
        _dragIndex = -1;
        _dragHandle = groupHandle;
        _dragDelta = Offset.zero;
      });
      return;
    }
    final sel = widget.selectedIndex;
    if (sel >= 0 && sel < widget.blocks.length) {
      final r = widget.blocks[sel].rect;
      final canvasRect = Rect.fromLTRB(
        r.left * fit,
        r.top * fit,
        r.right * fit,
        r.bottom * fit,
      );
      final handle = hitTestResizeHandle(canvasRect, local);
      if (handle != null) {
        _captureSnapTargets(sel, natural);
        _longPressLastLocal = local;
        setState(() {
          _kind = _DragKind.resize;
          _dragIndex = sel;
          _dragHandle = handle;
          _dragDelta = Offset.zero;
        });
        return;
      }
    }
    final index = hitTestMovableCanvasBlocks(
      widget.blocks,
      Offset(local.dx / fit, local.dy / fit),
    );
    if (index < 0) return;
    _captureSnapTargets(index, natural);
    _longPressLastLocal = local;
    setState(() {
      _kind = _DragKind.move;
      _dragIndex = index;
      _dragOffset = Offset.zero;
      // Pick it up on contact, the same feedback a pan move gives.
      widget.onSelect(index);
    });
  }

  /// Long-press updates carry an absolute position, so the delta is derived
  /// from the previous update and routed through the same accumulation the
  /// pan path uses (move accumulates an offset, resize a start-based delta).
  void _onLongPressMove(Offset local) {
    if (_kind == _DragKind.none) return;
    final delta = local - _longPressLastLocal;
    _longPressLastLocal = local;
    _onPanUpdate(local, delta);
  }

  /// Snap references for this gesture: every **other** block's edges, plus the
  /// page bounds, in page pixels.
  ///
  /// 🔴 [index] is excluded. Letting the block snap to its own edges pins every
  /// drag back where it started, and the symptom reads as "the block is stuck",
  /// not as "the snap list is wrong".
  void _captureSnapTargets(int index, Size natural) {
    final others = <Rect>[
      for (var i = 0; i < widget.blocks.length; i++)
        // 🔴 投影片段（`ownerPageKey != null`）不作为吸附参考：它的 rect 是别页
        // 上真身的派生视图，拿它当"这条边"会把块吸附到一个本页并不存在的边界。
        if (i != index && widget.blocks[i].ownerPageKey == null)
          widget.blocks[i].rect,
    ];
    final targets = snapTargets(
      others,
      pageWidth: natural.width,
      pageHeight: natural.height,
    );
    _snapXs = targets.xs;
    _snapYs = targets.ys;
  }

  void _onPanUpdate(Offset local, Offset delta) {
    switch (_kind) {
      case _DragKind.none:
        return;
      case _DragKind.move:
        setState(() {
          // local delta is in canvas space; the model is in page pixels.
          _dragOffset += delta / _fit;
        });
      case _DragKind.resize:
      case _DragKind.groupResize:
        setState(() {
          // 🔴 Resize accumulates from the gesture's **start** box, never from
          // the previous frame's result: `applyResize` clamps to prevent
          // inversion, and a clamp is not invertible — measuring the next frame
          // from the already-clamped box would ratchet that edge further on
          // every event, so the box would creep while the pointer stood still.
          // 组外框缩放与单块缩放共用同一个从起点累计的 delta。
          _dragDelta += delta / _fit;
        });
      case _DragKind.marquee:
        final anchor = _marqueeAnchor;
        if (anchor == null) return;
        setState(() {
          // `Rect.fromPoints` normalises, so dragging up/left still yields a
          // positive-area rect for the painter.
          _marquee = Rect.fromPoints(anchor, local);
        });
    }
  }

  /// Ends the gesture and reports **one** command to the owner.
  ///
  /// [fit] is the canvas scale, needed to convert the marquee back into page
  /// pixels. It is stashed on pan start rather than read from the build scope
  /// because the gesture callbacks outlive the `LayoutBuilder` that produced it.
  void _finishDrag() {
    final kind = _kind;
    final index = _dragIndex;
    final offset = _dragOffset;
    final delta = _dragDelta;
    final handle = _dragHandle;
    final anchor = _marqueeAnchor;
    final marquee = _marquee;
    // P31：组框在 reset 前留住（reset 只清拖拽状态，widget.groupFrame 来自
    // owner 本来就不受影响，但提交用的旧并集必须是这一势开始时的那一版）。
    final groupFrame = widget.groupFrame;
    // Captured **before** the reset below clears them: the committed command has
    // to use the same snap set the preview was drawn with.
    final snapXs = _snapXs;
    final snapYs = _snapYs;

    setState(() {
      _kind = _DragKind.none;
      _dragIndex = -1;
      _dragOffset = Offset.zero;
      _dragDelta = Offset.zero;
      _marqueeAnchor = null;
      _marquee = null;
      _snapXs = const [];
      _snapYs = const [];
    });

    switch (kind) {
      case _DragKind.none:
        return;
      case _DragKind.move:
        if (offset == Offset.zero || index >= widget.blocks.length) return;
        final start = widget.blocks[index].rect;
        // 🔴 The committed box goes through the **same** snap as the preview
        // (`_preview`). Two independent computations here is how a block ends up
        // jumping on release.
        final snap = snapMove(
          start: start,
          offset: offset,
          targetsX: snapXs,
          targetsY: snapYs,
        );
        widget.onMoveBlock?.call(
          index,
          start.topLeft,
          start.topLeft + snap.offset,
        );
      case _DragKind.resize:
        if (index < 0 || index >= widget.blocks.length) return;
        if (delta == Offset.zero) return;
        final start = widget.blocks[index].rect;
        widget.onResizeBlock?.call(
          index,
          start,
          snapResize(
            start: start,
            handle: handle,
            delta: delta,
            targetsX: snapXs,
            targetsY: snapYs,
          ).rect,
        );
      case _DragKind.groupResize:
        // P31：提交旧/新**并集框**（与 live preview 同一 applyResize、同一
        // minSize、无吸附）；owner 把变换施加到全部成员块，一次撤销步。
        if (groupFrame == null || delta == Offset.zero) return;
        final newBounds = applyResize(
          start: groupFrame.bounds,
          handle: handle,
          delta: delta,
          minSize: 32.0,
        );
        if ((newBounds.left - groupFrame.bounds.left).abs() < 0.5 &&
            (newBounds.top - groupFrame.bounds.top).abs() < 0.5 &&
            (newBounds.width - groupFrame.bounds.width).abs() < 0.5 &&
            (newBounds.height - groupFrame.bounds.height).abs() < 0.5) {
          return;
        }
        widget.onResizeGroup?.call(groupFrame.groupId, groupFrame.bounds, newBounds);
      case _DragKind.marquee:
        if (anchor == null || marquee == null) return;
        // 🔴 The canvas normalises in **canvas** pixels and hands the owner
        // **page** pixels: `xyxy` lives in source pixels, so the fit conversion
        // happens exactly once, here. Also note the marquee is rebuilt from the
        // raw anchor rather than re-derived from the drawn rect, so a drag up or
        // left (negative extent) still yields l<t<r<b.
        final rect = normalizeMarquee(anchor, marquee.bottomRight);
        if (rect == null) return;
        widget.onMarquee?.call(
          Rect.fromLTRB(
            rect.left / _fit,
            rect.top / _fit,
            rect.right / _fit,
            rect.bottom / _fit,
          ),
        );
    }
  }

  // 🔴 `_blocksWithDrag()` used to live here and returned the preview list
  // alone. It was replaced by `_preview()`, which returns the preview **and**
  // the snap guides it landed on: keeping two functions meant two chances for
  // the drawn box and the committed box to disagree.
}

/// P31：在 pointer-down 当下"按意图抢先"的 pan 识别器。
///
/// 两处超越普通 [PanGestureRecognizer] 的行为，都只在 [claimAt] 命中时生效：
///
/// 1. [addAllowedPointer] 里（super 已把本识别器登记进竞技场**之后**）立即
///    `resolve(accepted)`：竞技场在该指针 close 时直接把这一势判给它，外层
///    ListView 的 VerticalDrag（鼠标 slop 1px）/ InteractiveViewer 再没机会
///    抢赢；
/// 2. [hasSufficientGlobalDistanceToAccept] 对被抢先的指针直接放行：越过
///    slop 的门槛取消，第一个 move 事件就触发 onStart —— 否则即使赢了竞技场，
///    触摸上仍要白走 36px 才开始缩放，手柄像"咬不住"。
///
/// 未命中时行为与普通 pan 完全一致：块体的垂直拖拽依旧让位给滚动（移动块走
/// P30 的长按路径）。
class _EagerPanGestureRecognizer extends PanGestureRecognizer {
  _EagerPanGestureRecognizer({
    required this.claimAt,
    super.debugOwner,
  });

  /// 用**按下点**判定这一势是否需要抢先（命中手柄 / 框选模式）。
  final bool Function(Offset localPosition) claimAt;

  bool _claimedAtDown = false;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    _claimedAtDown = claimAt(event.localPosition);
    if (_claimedAtDown) {
      resolve(GestureDisposition.accepted);
    }
  }

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) {
    if (_claimedAtDown) return true;
    return super.hasSufficientGlobalDistanceToAccept(
      pointerDeviceKind,
      deviceTouchSlop,
    );
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _claimedAtDown = false;
    super.didStopTrackingLastPointer(pointer);
  }
}

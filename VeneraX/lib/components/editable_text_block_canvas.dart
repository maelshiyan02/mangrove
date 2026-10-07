import 'dart:math' as math;

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

  @override
  State<EditableTextBlockCanvas> createState() => _EditableTextBlockCanvasState();
}

/// What the current drag is doing. Decided once on pan start.
enum _DragKind {
  none,
  move,
  resize,
  marquee,
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

  /// Snap reference coordinates for the current gesture, in **page** pixels.
  ///
  /// Captured once at pan start rather than recomputed per event, so the set
  /// cannot change mid-drag (the preview and the committed command must agree).
  List<double> _snapXs = const [];
  List<double> _snapYs = const [];

  /// Live marquee in canvas pixels — the unit the painter draws it in.
  Rect? _marquee;

  int _doubleTapIndex = -1;

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

        /// Convert a canvas-pixel point to page pixels (the model's unit).
        Offset toPage(Offset local) => Offset(local.dx / fit, local.dy / fit);

        int hit(Offset local) => hitTestCanvasBlocks(preview.blocks, toPage(local));

        return Center(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (details) {
              // In marquee mode a tap must not steal the selection: the user is
              // lining up a drag, and clearing the selection mid-way would drop
              // the handles they are aiming between.
              if (widget.marqueeMode) return;
              widget.onSelect(hit(details.localPosition));
            },
            onDoubleTapDown: (details) =>
                _doubleTapIndex = hit(details.localPosition),
            onDoubleTap: () {
              if (_doubleTapIndex >= 0) widget.onEditText?.call(_doubleTapIndex);
            },
            onPanStart: (details) =>
                _onPanStart(details.localPosition, fit, natural),
            onPanUpdate: (details) =>
                _onPanUpdate(details.localPosition, details.delta),
            onPanEnd: (_) => _finishDrag(),
            onPanCancel: _finishDrag,
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
  ({List<CanvasTextBlock> blocks, List<double> guidesX, List<double> guidesY})
      _preview(double fit, Size natural) {
    final index = _dragIndex;
    final live = _kind != _DragKind.none &&
        index >= 0 &&
        index < widget.blocks.length &&
        (_dragOffset != Offset.zero || _dragDelta != Offset.zero);
    if (!live) {
      return (
        blocks: widget.blocks,
        guidesX: const <double>[],
        guidesY: const <double>[],
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
    );
  }

  /// Decides what the whole gesture will do, once. See the class doc for why
  /// this must not be re-evaluated during the drag.
  void _onPanStart(Offset local, double fit, Size natural) {
    _fit = fit;
    if (widget.marqueeMode) {
      setState(() {
        _kind = _DragKind.marquee;
        _marqueeAnchor = local;
        _marquee = Rect.fromPoints(local, local);
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

    final index = hitTestCanvasBlocks(
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

  /// Snap references for this gesture: every **other** block's edges, plus the
  /// page bounds, in page pixels.
  ///
  /// 🔴 [index] is excluded. Letting the block snap to its own edges pins every
  /// drag back where it started, and the symptom reads as "the block is stuck",
  /// not as "the snap list is wrong".
  void _captureSnapTargets(int index, Size natural) {
    final others = <Rect>[
      for (var i = 0; i < widget.blocks.length; i++)
        if (i != index) widget.blocks[i].rect,
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
        setState(() {
          // 🔴 Resize accumulates from the gesture's **start** box, never from
          // the previous frame's result: `applyResize` clamps to prevent
          // inversion, and a clamp is not invertible — measuring the next frame
          // from the already-clamped box would ratchet that edge further on
          // every event, so the box would creep while the pointer stood still.
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

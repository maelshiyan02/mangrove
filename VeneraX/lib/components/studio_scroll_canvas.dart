// dart:io comes through utils/io.dart (File).

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:venera/foundation/log.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';

import 'editable_text_block_canvas.dart';
import 'text_block_canvas.dart';

/// One page's worth of state inside a [StudioScrollCanvas].
///
/// The scroll canvas keeps a small window of decoded pages alive (see
/// [_keepAlive]) instead of decoding a 200-page project up front — that is the
/// whole point: a continuous strip has to be cheap to scroll.
class StudioStripPage {
  StudioStripPage({
    required this.index,
    required this.key,
    required this.file,
    this.fromInpainted = false,
  });

  /// Index into the project's page list.
  ///
  /// 🔴 **Mutable on purpose.** [StudioScrollCanvasState._reconcile] reuses an
  /// existing instance when the incoming key matches, so a caller that rebuilds
  /// the list with a different ordering must still be able to correct the index
  /// instead of getting a stale one.
  int index;

  /// Page key as stored in the json (`0/12.webp`). Immutable: it is the identity
  /// the canvas reconciles on, so changing it would mean a different page.
  final String key;

  /// Resolved image file for [key] (already fell back to inpainted/mask).
  ///
  /// 🔴 **Mutable on purpose**: when the detection pass writes `inpainted/` under
  /// a key we already decoded, the resolution order flips and the canvas must
  /// swap the source and re-decode rather than keep showing the raw page.
  File file;

  /// Whether [file] is the `inpainted/` artifact rather than the raw page.
  bool fromInpainted;

  DecodedPage? decoded;
  bool loading = false;

  /// Decode was attempted and came back empty. Without this the page retries on
  /// **every scroll notification** — a corrupt file would then be re-read
  /// dozens of times per second for the rest of the session.
  bool failed = false;

  int token = 0;

  /// Releases the bitmap and invalidates any decode still in flight.
  ///
  /// 🔴 Bumping [token] is what makes this safe to call on a page that is
  /// currently decoding: the completion callback checks the token and, finding
  /// it stale, disposes its own result instead of adopting it. Without the bump
  /// an evicted page would keep a live bitmap nobody can reach — a leak that
  /// grows for as long as the project is open.
  void dispose() {
    token++;
    decoded?.dispose();
    decoded = null;
    loading = false;
    failed = false;
  }
}

/// FT-style continuous vertical strip of pages for the translation studio.
///
/// 🔴 Why this exists: the studio used to show exactly **one** page inside an
/// `InteractiveViewer`, so reviewing a 97-page translation meant clicking
/// "next" 97 times and never seeing the pages as a sequence — which is exactly
/// how a human proofreads a translation. FT itself shows the whole project as
/// one tall scroll.
///
/// Two things make it work:
///
/// * **Per-page decode with a bounded window.** Only pages near the viewport
///   hold a decoded [ui.Image]; the rest keep just their file handle. Decoding
///   all 97 up front would be hundreds of MB and freeze the UI.
/// * **Blocks are painted from json, not from the bitmap.** The overlay comes
///   from [blocksFor], so a page's translations show up the moment its bitmap
///   arrives, and the reader never has to round-trip through a raster cache.
///
/// This widget is read-only. Editing gestures arrive in S8.
class StudioScrollCanvas extends StatefulWidget {
  const StudioScrollCanvas({
    super.key,
    required this.pages,
    required this.blocksFor,
    this.selectedIndex = -1,
    this.onSelect,
    this.onPageChanged,
    this.showBoxes = true,
    this.pageGap = 0,
    this.controller,
    this.editable = false,
    this.onMoveBlock,
    this.onEditText,
    this.onResizeBlock,
    this.onMarquee,
    this.marqueeMode = false,
  });

  /// Optional external controller so the owner can drive the strip (page rail,
  /// "go to page" dialog). When supplied, the caller owns disposal.
  final ScrollController? controller;

  /// Every page of the project, in reading order. Callers resolve each key to
  /// an existing file before handing it over, so every entry is displayable.
  final List<StudioStripPage> pages;

  /// Text blocks of a page, in the studio's flattened projection. Returns an
  /// empty list for a page with nothing to paint.
  final List<CanvasTextBlock> Function(String pageKey) blocksFor;

  /// Index into the **reported page's** block list for the current selection,
  /// or -1.
  final int selectedIndex;

  /// Reports a block tap together with the page it belongs to — in a strip the
  /// selection is meaningless without the page key, since the same index exists
  /// on every page.
  final void Function(String pageKey, int index)? onSelect;

  /// Fires with the page index currently dominating the viewport — this is what
  /// drives the page rail and the "page N of M" label.
  final ValueChanged<int>? onPageChanged;

  final bool showBoxes;

  /// 相邻页之间的留白。默认 **0**：条漫作品本身就是一幅接一幅的连续画面，
  /// 中间夹一条空白会把跨页动作/渐变切断（用户反馈："两张图片之间能否不要有
  /// 空白，我希望相邻的两张图可以衔接的紧密"）。页与页的分界改由每页左上角
  /// 的页码浮标 + 1px 分隔线表达，不再占用布局高度。
  final double pageGap;

  /// When true each page is an [EditableTextBlockCanvas] (drag to move a block)
  /// instead of the read-only [TextBlockCanvas].
  final bool editable;

  /// Fires once per finished drag, with the page key and the block's top-left
  /// in page pixels before and after the move.
  final void Function(String pageKey, int index, Offset oldTopLeft, Offset newTopLeft)?
      onMoveBlock;

  /// Fires on double-tap of a block, with its page key and index.
  final void Function(String pageKey, int index)? onEditText;

  /// Fires once per finished resize, with the page key, the block's index and
  /// its box in **page pixels** before and after.
  final void Function(String pageKey, int index, Rect oldRect, Rect newRect)?
      onResizeBlock;

  /// Fires when the user drags out a marquee on a page, with that rect in
  /// **page pixels**. Ignored when the drag was too small to be a box.
  final void Function(String pageKey, Rect rect)? onMarquee;

  /// When true every page's canvas is in "draw a new box" mode.
  final bool marqueeMode;

  @override
  State<StudioScrollCanvas> createState() => StudioScrollCanvasState();
}

class StudioScrollCanvasState extends State<StudioScrollCanvas> {
  final _ownedController = ScrollController();
  final _keys = <int, GlobalKey>{};

  ScrollController get _controller => widget.controller ?? _ownedController;

  /// True when this widget created the controller and must dispose it.
  bool get _ownsController => widget.controller == null;

  /// 🔴 **The canvas owns its page list — callers must not hand it a fresh list
  /// of throwaway objects every build.**
  ///
  /// Decoded bitmaps live on [StudioStripPage], so if the state's page list were
  /// rebuilt from scratch each frame the decode cache would be thrown away on
  /// every parent `setState` (which a scroll triggers, via `onPageChanged`) and
  /// every page would flip back to "page image missing" **permanently** — the
  /// length never changes, so the old length check never fired and nothing ever
  /// re-decoded. Hence [_syncPages]: incoming pages are matched **by key** and
  /// the surviving instance (with its bitmap) is reused.
  List<StudioStripPage> _pages = const [];

  /// Cross-axis extent of the strip, i.e. how wide a page may render.
  ///
  /// 🔴 Read from a `LayoutBuilder`, **not** from
  /// `ScrollPosition.viewportDimension`: for a *vertical* scroll that property
  /// is the viewport's **height**. Using it as the page width made every page
  /// estimate the wrong height, so `scrollToPage` and the current-page
  /// calculation both drifted.
  double _viewportWidth = 0;

  /// Pages that may hold a decoded image. Small on purpose: a 97-page project
  /// keeps ~7 bitmaps (~7 x 2400px x 2400px) instead of 97.
  static const _keepAlive = 7;

  /// Aspect ratio (h / w) assumed for a page that has not been decoded yet.
  ///
  /// A comic page is portrait, ~1.4:1, so a fixed pixel guess is wrong for both
  /// the layout and the scrollbar. This starts as [_defaultPageAspect] and is
  /// replaced by the real ratio of the first page that decodes, which makes the
  /// estimate correct for essentially every project (pages of one comic share
  /// their dimensions).
  static const _defaultPageAspect = 1.4;
  double _pageAspect = _defaultPageAspect;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
    _syncPages();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadAround(0));
  }

  @override
  void didUpdateWidget(covariant StudioScrollCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.removeListener(_onScroll);
      _controller.addListener(_onScroll);
    }
    if (!identical(oldWidget.pages, widget.pages)) {
      _syncPages();
    }
  }

  /// Folds [widget.pages] into [_pages], reusing existing instances by key so
  /// already-decoded bitmaps survive a parent rebuild.
  void _syncPages() {
    final incoming = widget.pages;
    final previous = _pages;
    final byKey = <String, StudioStripPage>{
      for (final p in previous) p.key: p,
    };
    final next = <StudioStripPage>[];
    // Whether the *page set* itself changed, as opposed to the incoming list
    // merely being a fresh set of objects describing the same pages. Only the
    // former is worth correcting the scroll position for — scrolling on every
    // rebuild would fight the user's own scrolling.
    var structureChanged = previous.length != incoming.length;
    for (var i = 0; i < incoming.length; i++) {
      final page = incoming[i];
      final kept = byKey.remove(page.key);
      if (kept == null) {
        next.add(page);
        structureChanged = true;
        continue;
      }
      if (kept.index != page.index) structureChanged = true;
      kept.index = page.index;
      // A different file for the same key means the artifact on disk changed
      // (e.g. the detection pass just produced `inpainted/`): the cached bitmap
      // is stale, so drop it and re-decode. Comparing paths rather than
      // `fromInpainted` alone catches the file actually changing underneath us.
      if (!_samePath(kept.file.path, page.file.path)) {
        kept.dispose();
        kept.file = page.file;
        kept.fromInpainted = page.fromInpainted;
      }
      next.add(kept);
    }
    // Keys the caller no longer lists (a rescan shrank the project) must release
    // their bitmaps, or the canvas leaks every page it ever decoded.
    for (final orphan in byKey.values) {
      orphan.dispose();
      structureChanged = true;
    }
    if (previous.isEmpty && next.isEmpty) return;
    _pages = next;
    if (structureChanged && _controller.hasClients) {
      // Hold the same *page* rather than the same pixel offset: heights change
      // as real page sizes arrive, so a pixel offset would drift.
      final page = _currentPageIndex().clamp(0, _pages.length - 1);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_controller.hasClients) return;
        scrollToPage(page);
      });
    }
  }

  static bool _samePath(String a, String b) =>
      a.replaceAll('\\', '/').toLowerCase() ==
      b.replaceAll('\\', '/').toLowerCase();

  @override
  void dispose() {
    _controller.removeListener(_onScroll);
    if (_ownsController) _ownedController.dispose();
    for (final p in _pages) {
      p.dispose();
    }
    super.dispose();
  }

  /// Scrolls so [index] sits at the top of the viewport, decoding it on the
  /// way. Used by the page rail and the "go to page" dialog.
  void scrollToPage(int index) {
    if (index < 0 || index >= _pages.length) return;
    _loadAround(index);
    if (!_controller.hasClients) return;
    var target = 0.0;
    for (var i = 0; i < index; i++) {
      target += _pageHeight(i) + widget.pageGap;
    }
    _controller.jumpTo(target.clamp(0.0, _controller.position.maxScrollExtent));
  }

  GlobalKey _keyFor(int index) =>
      _keys.putIfAbsent(index, () => GlobalKey());

  void _onScroll() {
    if (!_controller.hasClients || _pages.isEmpty) return;
    final best = _currentPageIndex();
    widget.onPageChanged?.call(best);
    _loadAround(best);
  }

  /// Index of the page dominating the viewport's upper third — that is what the
  /// reader considers "the page they are on".
  int _currentPageIndex() {
    final offset = _controller.offset;
    final viewport = _controller.position.viewportDimension;
    final target = offset + viewport / 3;
    var best = 0;
    var acc = 0.0;
    for (var i = 0; i < _pages.length; i++) {
      final h = _pageHeight(i) + widget.pageGap;
      if (acc + h > target) {
        return i;
      }
      acc += h;
      best = i;
    }
    return best;
  }

  /// 🔴 The height a page occupies in the strip.
  ///
  /// This is the **single source of truth** for the strip's vertical geometry:
  /// [_StripItem] sizes its placeholder with it too. They used to disagree
  /// (420 vs 1100), which meant the layout and the scroll maths each told a
  /// different story — the reported page drifted and `scrollToPage` landed
  /// somewhere else entirely.
  ///
  /// The formula mirrors the canvas widgets' own "contain" fit (`min(w/sw, h/sh)`
  /// with an unbounded list height), **including the `min(…, 1.0)` clamp**: a
  /// page narrower than the strip renders at its natural size, so scaling it up
  /// to the strip width would overstate its height and desync the geometry again.
  double _pageHeight(int index) {
    if (index < 0 || index >= _pages.length) return 0;
    final width = _viewportWidth > 0 ? _viewportWidth : 800.0;
    final decoded = _pages[index].decoded;
    final size = decoded?.originalSize;
    if (size == null || size.width <= 0 || size.height <= 0) {
      return width * _pageAspect;
    }
    final fit = math.min(1.0, width / size.width);
    return size.height * fit;
  }

  /// Decodes pages around [center] and releases the ones that fell out of the
  /// window. Never blocks the scroll: the bitmap appears when it is ready.
  void _loadAround(int center) {
    if (!mounted || _pages.isEmpty) return;
    final lo = (center - _keepAlive ~/ 2).clamp(0, _pages.length);
    final hi = (center + _keepAlive ~/ 2 + 1).clamp(0, _pages.length);
    // Evict outside the window. Tracked separately from the decode completions
    // below because those land **asynchronously**, long after this method has
    // returned — sharing one flag meant the `setState` read it before any decode
    // had finished, so a freshly decoded page never repainted.
    var needsRebuild = false;
    for (var i = lo; i < hi; i++) {
      final page = _pages[i];
      if (page.decoded != null || page.loading || page.failed) continue;
      page.loading = true;
      final token = ++page.token;
      decodePageFile(page.file, fromInpainted: page.fromInpainted).then(
        (decoded) {
          if (!mounted || page.token != token) {
            decoded?.dispose();
            return;
          }
          page.loading = false;
          page.decoded = decoded;
          if (decoded == null) {
            // Stop retrying: a corrupt file would otherwise be re-read on every
            // scroll notification for the rest of the session.
            page.failed = true;
            Log.warning(
              'TranslationStudio.Strip',
              'Failed to decode page image: ${page.file.path}',
            );
          } else {
            // Learn the real aspect ratio from the first page that decodes so
            // the not-yet-decoded ones stop being laid out at a guess.
            _pageAspect =
                decoded.originalSize.height / decoded.originalSize.width;
          }
          // 🔴 Repaint from **here**, not from the caller: this is the only place
          // that knows the bitmap arrived.
          setState(() {});
        },
      );
    }
    for (var i = 0; i < _pages.length; i++) {
      if (i >= lo && i < hi) continue;
      final page = _pages[i];
      if (page.decoded != null) {
        page.dispose();
        needsRebuild = true;
      }
    }
    if (needsRebuild && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_pages.isEmpty) {
      return Center(
        child: Text(
          'This project has no readable page image'.tl,
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      );
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (_) {
        _onScroll();
        return false;
      },
      child: Scrollbar(
        controller: _controller,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // The strip is the scroll axis' cross axis: its width is how wide a
            // page may render. Captured here because `viewportDimension` is the
            // scroll axis' extent (the height, for a vertical strip).
            //
            // 🔴 Assigned **before** `itemBuilder` reads it, so the very first
            // frame already lays pages out at the real width. A full `setState`
            // is not needed on change: `ListView` re-lays out on the next frame
            // anyway, and forcing one here caused a rebuild storm while scrolling
            // (a resize and a decode could each schedule one per frame).
            if (constraints.maxWidth.isFinite) {
              _viewportWidth = constraints.maxWidth;
            }
            return ListView.builder(
              controller: _controller,
              padding: EdgeInsets.symmetric(vertical: widget.pageGap),
              itemCount: _pages.length,
              itemBuilder: (context, index) {
                final page = _pages[index];
                return _StripItem(
                  key: _keyFor(index),
                  page: page,
                  height: _pageHeight(index),
                  blocks: widget.blocksFor(page.key),
                  selectedIndex: widget.selectedIndex,
                  showBoxes: widget.showBoxes,
                  onSelect: (index) => widget.onSelect?.call(page.key, index),
                  gap: widget.pageGap,
                  editable: widget.editable,
                  // 🔴 [_StripItem] is per-page and already closes over
                  // `page.key`, so all of its callbacks are **page-key-free**.
                  // The wrapping here is the single place that re-attaches the
                  // key on the way out — one hop, rather than every widget
                  // remembering to do it.
                  onMoveBlock: (index, oldTopLeft, newTopLeft) => widget
                      .onMoveBlock
                      ?.call(page.key, index, oldTopLeft, newTopLeft),
                  onResizeBlock: (index, oldRect, newRect) => widget
                      .onResizeBlock
                      ?.call(page.key, index, oldRect, newRect),
                  onMarquee: (rect) => widget.onMarquee?.call(page.key, rect),
                  marqueeMode: widget.marqueeMode,
                  onEditText: (index) =>
                      widget.onEditText?.call(page.key, index),
                  isFirst: index == 0,
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _StripItem extends StatelessWidget {
  const _StripItem({
    super.key,
    required this.page,
    required this.height,
    required this.blocks,
    required this.selectedIndex,
    required this.showBoxes,
    required this.onSelect,
    required this.gap,
    required this.editable,
    required this.onMoveBlock,
    required this.onEditText,
    required this.onResizeBlock,
    required this.onMarquee,
    required this.marqueeMode,
    required this.isFirst,
  });

  final StudioStripPage page;

  /// 🔴 Height the owning state computed for this page. The placeholder **must**
  /// use it: a hardcoded height made the layout disagree with the scroll
  /// arithmetic, so the reported page and `scrollToPage` both drifted while the
  /// user was certain they were on the page the status bar named.
  final double height;

  final List<CanvasTextBlock> blocks;
  final int selectedIndex;
  final bool showBoxes;
  final void Function(int index)? onSelect;
  final double gap;
  final bool editable;
  final void Function(int index, Offset oldTopLeft, Offset newTopLeft)?
      onMoveBlock;
  final void Function(int index)? onEditText;
  final void Function(int index, Rect oldRect, Rect newRect)? onResizeBlock;
  final void Function(Rect rect)? onMarquee;
  final bool marqueeMode;

  /// 第一页不画顶部 1px 分隔线（上面没有前一页）。
  final bool isFirst;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final decoded = page.decoded;
    final Widget body;
    if (decoded == null) {
      body = SizedBox(
        height: height,
        width: double.infinity,
        child: Center(
          child: page.loading
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(
                  'page image missing'.tl,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
        ),
      );
    } else if (editable) {
      body = EditableTextBlockCanvas(
        blocks: blocks,
        selectedIndex: selectedIndex,
        onSelect: (index) => onSelect?.call(index),
        base: decoded,
        showBoxes: showBoxes,
        // 🔴 These fields are **page-key-free**: [_StripItem] is per-page, so
        // it already knows `page.key` and closes over it. Passing it again
        // would double the argument count.
        onMoveBlock: (index, oldTopLeft, newTopLeft) =>
            onMoveBlock?.call(index, oldTopLeft, newTopLeft),
        onResizeBlock: (index, oldRect, newRect) =>
            onResizeBlock?.call(index, oldRect, newRect),
        onMarquee: (rect) => onMarquee?.call(rect),
        marqueeMode: marqueeMode,
        onEditText: (index) => onEditText?.call(index),
      );
    } else {
      body = TextBlockCanvas(
        blocks: blocks,
        selectedIndex: selectedIndex,
        onSelect: (index) => onSelect?.call(index),
        base: decoded,
        showBoxes: showBoxes,
      );
    }
    // 页码浮标与分隔线画在**页面之上**：布局高度因此严格等于画面高度，
    // 相邻两页真正贴在一起（原来是"页标签独占一行 + 上下各 gap/2"）。
    return Padding(
      padding: EdgeInsets.symmetric(vertical: gap / 2),
      child: Stack(
        children: [
          // 非定位子节点决定 Stack 尺寸（= 画面高度），其余都是叠加层。
          body,
          if (!isFirst)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(height: 1, color: scheme.outlineVariant),
            ),
          Positioned(
            left: 8,
            top: 6,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.surface.withValues(alpha: 0.72),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  child: Text(
                    '#${page.index + 1}  ${page.key}'
                    '${page.fromInpainted ? '  ·  ${'inpainted'.tl}' : ''}',
                    style: TextStyle(
                      fontSize: 10,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// dart:io comes through utils/io.dart (File).

import 'dart:math' as math;

import 'package:flutter/gestures.dart' show PointerScrollEvent, PointerSignalEvent;
import 'package:flutter/material.dart';
// HardwareKeyboard / KeyEvent 在 services 里（material 不重导出）。
import 'package:flutter/services.dart' show HardwareKeyboard, KeyEvent;

import 'package:mangrove/foundation/log.dart';
import 'package:mangrove/foundation/translation_project/cross_page_block.dart'
    show SpanPart;
import 'package:mangrove/foundation/translation_project/strip_decode_planner.dart';
import 'package:mangrove/foundation/translation_project/strip_geometry.dart';
import 'package:mangrove/utils/io.dart';
import 'package:mangrove/utils/translations.dart';

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

  /// 连续解码失败次数。小于 [maxDecodeAttempts] 时页再次进入窗口会自动重试；
  /// 到顶后占位符显示「点击重试」，由用户手动触发。
  ///
  /// 🔴 取代旧的 `bool failed` 永久闩锁：内存压力下的失败本是暂时的，一次
  /// null 就把这一页判死刑，是"大面积缺页且再也不好转"的直接来源（P30）。
  int failures = 0;

  bool get permanentlyFailed => failures >= maxDecodeAttempts;

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
    // 离开窗口即"翻篇"：滚回来时重新计数、重新解码（暂时故障不该被记仇）。
    failures = 0;
  }

  /// 离开驻留窗口但解码**仍在飞**：作废 token、放下 loading 标记。
  ///
  /// 与 [dispose] 的区别：没有位图可放（否则走的是 evictDecoded），也**不动
  /// failures**（在飞说明本轮还没失败）。在飞的 Future 完成时发现 token 已过期
  /// 会自行 dispose 结果；并发名额由 [DecodeBudget] 在那条终结路径上归还。
  ///
  /// 🔴 P31：旧逻辑出窗只处理"有位图"的页，在飞的废解码必须跑完才释放名额，
  /// 快滚时新页一直排在 3 个废解码后面；先作废 token 让结果到达即弃，配合
  /// planner 的 cancelLoading，名额周转跟得上甩动。
  void cancelInFlight() {
    token++;
    loading = false;
  }
}

/// 单页解码在被判定为「永久失败」前允许的尝试次数。
const int maxDecodeAttempts = 3;

/// 同时进行的图片解码上限。
///
/// 🔴 快速甩动长画布时，窗口每帧越过好几页；不限流会把几十张全分辨率 webp
/// 同时压进引擎解码管线（每张都先吃一份全幅 RGBA），本机内存/显存尖峰直接
/// 把进程带走（用户实测十几页后崩溃）。3 路并发足以让可见页秒开。
const int maxConcurrentDecodes = 3;

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
    this.selectedPageKey,
    this.onSelect,
    this.onPageChanged,
    this.showBoxes = true,
    this.pageGap = 0,
    this.controller,
    this.editable = false,
    this.onMoveBlock,
    this.onEditText,
    this.onResizeBlock,
    this.onResizeGroup,
    this.groupFrameFor,
    this.onMarquee,
    this.marqueeMode = false,
    this.spanMode = false,
    this.onSpanMarquee,
    this.groupPickMode = false,
    this.onPickBlock,
    this.hiddenPages = const <String>{},
    this.probedSizeOf,
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
  ///
  /// 🔴 P31：长画布里选择是**逐页**的 —— 必须配合 [selectedPageKey] 使用：
  /// 只有页键相等的那一个 item 拿到该下标，其余页一律 -1。此前 owner 根本没
  /// 给条带传选择态（恒为 -1），于是长画布里选中块**不画手柄**，缩放从来无从
  /// 开始；拖动（P30 长按）不依赖选中态所以没暴露这个缺口。
  final int selectedIndex;

  /// 当前选中块的**真身页键**；与 [selectedIndex] 配对，null = 全页无选中。
  final String? selectedPageKey;

  /// 点选回报：**[块真身所在页, 真身下标]**，或 `(本页, -1)` 表示空点。
  ///
  /// 🔴 在条带里选择离不开页 key（同一个下标每页都有），而跨页块的**投影片段**
  /// 画在下页、真身却在顶页 —— 所以这里回报的页 key 是**真身页**，不是被点的那页。
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

  /// P31：nest 组外框整体缩放结束，回调一次（页键 + 组 id + 旧/新并集框，
  /// 均为页像素）。owner 把同因子变换施加到全部成员块并合成一次撤销。
  final void Function(String pageKey, String groupId, Rect oldBounds, Rect newBounds)?
      onResizeGroup;

  /// P31：逐页给出当前可整体缩放的 nest 组外框；null = 该页没有活动组框。
  /// owner 只在"选中块属于某组、且该组全部成员都在这一页、形态为 nest"时
  /// 才返回非 null（跨页组不出手柄）。
  final CanvasGroupFrame? Function(String pageKey)? groupFrameFor;

  /// Fires when the user drags out a marquee on a page, with that rect in
  /// **page pixels**. Ignored when the drag was too small to be a box.
  final void Function(String pageKey, Rect rect)? onMarquee;

  /// When true every page's canvas is in "draw a new box" mode.
  final bool marqueeMode;

  /// B-2：跨页框选模式。整个条带被一层透明手势层盖住，拖出的框可以**跨过缝线**，
  /// 松手时按缝切成 per-page 子矩形交回 [onSpanMarquee]。
  ///
  /// 🔴 与 [marqueeMode] 一样是**一次性的模式**（画完自动由 owner 关掉）；
  /// 它盖住整条画布，所以页内的点选/拖拽在此模式下不可用 —— 这是刻意的：
  /// 跨缝的拖拽与"移动某个块"在手势上无法共存，只能靠显式模式区分。
  final bool spanMode;

  /// 跨缝框选松手时回调：**已按缝切好**的 per-page 子矩形（页内像素，>=1 段）。
  ///
  /// 段数 == 1 表示框只落在一页内（走普通建块）；>= 2 表示跨缝（落 `_span`）。
  /// 太小 / 完全落在页外的拖拽不会回调。
  final void Function(List<SpanPart> parts)? onSpanMarquee;

  /// B-3：建组点选模式。开启后页内块**不可拖动/缩放**（点选只用于把块加入待
  /// 确认名单），但正常滚动不受影响 —— 与 [spanMode] 的整条手势覆盖层不同，
  /// 建组要跨多页滚着点，不能吃掉滚轮。
  final bool groupPickMode;

  /// 建组点选回调：**[块真身所在页, 真身下标]**（投影片段回指真身，同
  /// [onSelect]）。空点不回调（建组模式下点空白不改选择）。
  final void Function(String pageKey, int index)? onPickBlock;

  /// P30：在长画布中被**隐藏**的页键集合。隐藏页不占布局、不参与缝线几何、
  /// 不保留解码位图；单页模式不受此影响（由调用方决定在何处过滤）。
  final Set<String> hiddenPages;

  /// 只读文件头得到的页尺寸（`(width, height)`，未知给 null）。
  ///
  /// 用于把"未解码页"的估高从一个全局猜测改成**逐页真值** —— 横版首页会让
  /// 全局长宽比失准，进而让加载窗口与可见页错位（P30 缺页隐患）。
  final ({int? width, int? height})? Function(String pageKey)? probedSizeOf;

  @override
  State<StudioScrollCanvas> createState() => StudioScrollCanvasState();
}

class StudioScrollCanvasState extends State<StudioScrollCanvas> {
  final _ownedController = ScrollController();

  /// P31：横向滚动轴（放大后横滚看全宽）。自持控制器是为了在缩放档变化时
  /// 保持**视口中心不动**（与纵轴同一条缩放公式）。
  final _horizontalController = ScrollController();

  final _keys = <int, GlobalKey>{};

  ScrollController get _controller => widget.controller ?? _ownedController;

  /// True when this widget created the controller and must dispose it.
  bool get _ownsController => widget.controller == null;

  /// Whether [_controller] is attached to **exactly one** [ScrollPosition].
  ///
  /// 🔴 这不是洁癖，是修过的一次崩溃：`ScrollController.offset` / `.position`
  /// 内部都是 `_positions.single`。切进跨页框选时，`ListView` 从
  /// `LayoutBuilder` 的直接子节点被挪进 `Stack` —— 结构变了，Flutter 会**先让
  /// 旧的 `Scrollable` 失活、到帧末才 unmount**。于是同一帧里 `_positions`
  /// 临时有 2 个元素，`.single` 抛 `Bad state: Too many elements`
  /// （release 下 `_positions.length == 1` 那条 assert 被剥掉，只剩这句原始
  /// 错误，完全看不出是滚动控制器）。
  /// 现在 `Stack` 常驻、`ListView` 不再重挂，已从根上消除该瞬态；这里再兜一层：
  /// 不唯一时一律当作"读不到"，绝不抛。
  bool get _hasSolePosition => _controller.positions.length == 1;

  /// 唯一的滚动偏移；控制器不唯一/未附着时为 0。
  double get _scrollOffset => _hasSolePosition ? _controller.offset : 0.0;

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

  /// P30：当前**可见**页在 [_pages] 里的原始下标（升序）。隐藏页被剔除 ——
  /// 所有布局/几何/解码窗口都只遍历它；[onPageChanged] 等对外回报仍给原始
  /// 工程下标。
  List<int> _visible = const [];

  void _rebuildVisible() {
    final hidden = widget.hiddenPages;
    _visible = [
      for (var i = 0; i < _pages.length; i++)
        if (!hidden.contains(_pages[i].key)) i,
    ];
  }

  /// Cross-axis extent of the strip, i.e. how wide a page may render.
  ///
  /// 🔴 Read from a `LayoutBuilder`, **not** from
  /// `ScrollPosition.viewportDimension`: for a *vertical* scroll that property
  /// is the viewport's **height**. Using it as the page width made every page
  /// estimate the wrong height, so `scrollToPage` and the current-page
  /// calculation both drifted.
  double _viewportWidth = 0;

  /// P30：长画布显示缩放（Ctrl + 滚轮，0.5~2.0，1.0 = 适配宽度）。
  double _stripZoom = 1.0;
  static const double _minStripZoom = 0.5;
  static const double _maxStripZoom = 2.0;

  /// P32：同一帧内连续滚轮事件的**缩放锚点链**。
  ///
  /// 一帧可能挤进多个 Ctrl+滚轮事件：旧实现每个事件都抓自己的旧偏移、各排
  /// 一个 postFrame，帧末两个回调都用**缩放前**的旧偏移算 jumpTo —— 缩放链
  /// 在边界夹取处互相覆盖，滚动位置在帧间来回抖，解码窗口随之振荡（缩小到
  /// ~88% 必现缺页的诱因之一）。现在锚点只在链头抓一次，帧末按最终 zoom
  /// 一次 jumpTo，多个事件的复合比例 = finalZoom/anchorZoom。
  ({double oldZoom, double oldV, double oldH, double vpHeight, double vpWidth})?
      _zoomAnchor;

  /// 页宽 = 视口宽 × 缩放；`_pageHeight` / 缝几何的唯一宽度来源。
  double get _effectiveWidth =>
      (_viewportWidth > 0 ? _viewportWidth : 800.0) * _stripZoom;

  /// P31：页间距随缩放等比变化 —— zoom 改的是整条长画布（图、块、间距一起），
  /// gap 不乘 zoom 会让放大时间距显得塌缩、缝几何与真实布局错位。
  double get _effectiveGap => widget.pageGap * _stripZoom;

  /// Ctrl 是否正按住：按住时 ListView 临时不可滚（滚轮只缩放，不滚页）。
  bool _ctrlHeld = false;

  /// 当前在飞的解码名额账（[maxConcurrentDecodes] 限流）。
  ///
  /// 🔴 P31 起规则落在纯逻辑件 [DecodeBudget] 上（成功/null/异常/过期/取消
  /// 五条终结路径都恰好归还一次），可在 headless 里反向断言"漏还即饿死"。
  final DecodeBudget _decodeBudget = DecodeBudget(maxConcurrentDecodes);

  /// Pages that may hold a decoded image. Small on purpose: a 97-page project
  /// keeps ~10 bitmaps (~10 x 2400px x 2400px) instead of 97.
  ///
  /// 🔴 7 → 10（P28）。7 时窗口只有 `中心 ±3`，而 `_loadAround` 会在页离开窗口
  /// 的那一帧 `setState`：连续滚动时几乎每滚一页就重建整条 `ListView`，而
  /// `ListView` 的重建会连带可见页一起走一遍 layout —— 用户看到的"卡顿甚至频闪"
  /// 很大一部分来自这里。窗口放宽到 10 后，淘汰与重建的频率降到约 1/3。
  static const _keepAlive = 10;

  /// P32：ListView 在视口上下额外构建的像素（cacheExtent）。
  ///
  /// 🔴 解码调度的**紧带**边距必须覆盖它：被 cache 区构建出来的页若不在
  /// 驻留集合，就会出现"页面已构建却没有位图"的缺图占位 —— P32 实锤的
  /// 88% 缺页正是"固定页数窗口"与 ListView 真实像素构建范围脱节所致。
  /// 显式写死而不是依赖框架默认值（虽然默认也是 250），让两处同源可查。
  static const double _stripCacheExtent = 250.0;

  /// P32：竖向滚动条轨道在画面**外侧**预留的宽度（条身 10 + 两侧空隙）。
  static const double _scrollbarGutter = 14.0;

  /// Aspect ratio (h / w) assumed for a page that has not been decoded yet.
  ///
  /// A comic page is portrait, ~1.4:1, so a fixed pixel guess is wrong for both
  /// the layout and the scrollbar. This starts as [_defaultPageAspect] and is
  /// replaced by the real ratio of the first page that decodes, which makes the
  /// estimate correct for essentially every project (pages of one comic share
  /// their dimensions).
  static const _defaultPageAspect = 1.4;
  double _pageAspect = _defaultPageAspect;

  /// B-2 跨页框选：锚点与当前点都记在**条带坐标**里（含滚动偏移），
  /// 绘制时再减去偏移换算回视口坐标。
  Offset? _spanAnchorStrip;
  Offset? _spanCurrentStrip;

  /// 离拖拽点最近的缝（条带坐标 y），用于高亮；无则 null。
  double? _spanHighlightSeam;

  /// 跨页框选的**实时状态变化信号**。
  ///
  /// 🔴 拖框用 [ValueNotifier] 而不是 `setState`：拖框是**高频手势**，而
  /// `setState` 会把整条 `ListView`（以及每个可见页的块列表）重建一遍 —— 只为
  /// 让覆盖层上的框动起来。notifier 只唤醒订阅它的覆盖层（见 [_spanOverlay]）。
  final _spanRepaint = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
    _syncPages();
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
    _ctrlHeld = HardwareKeyboard.instance.isControlPressed;
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadAround());
  }

  bool _onKeyEvent(KeyEvent event) {
    final next = HardwareKeyboard.instance.isControlPressed;
    if (next != _ctrlHeld && mounted) {
      setState(() => _ctrlHeld = next);
    }
    return false;
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
    if (oldWidget.hiddenPages.length != widget.hiddenPages.length ||
        !oldWidget.hiddenPages.containsAll(widget.hiddenPages)) {
      _rebuildVisible();
      // 隐藏集合变了：窗口随之变（新显示的页要解码，新隐藏的页要释放）。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _loadAround();
        if (_hasSolePosition) {
          // 保持停在当前可见页，避免高度回收后停在错位的偏移上。
          scrollToPage(_currentPageIndex());
        }
      });
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
    _rebuildVisible();
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
    HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    _controller.removeListener(_onScroll);
    _spanRepaint.dispose();
    _horizontalController.dispose();
    if (_ownsController) _ownedController.dispose();
    for (final p in _pages) {
      p.dispose();
    }
    super.dispose();
  }

  /// Scrolls so [index] (a **project** page index) sits at the top of the
  /// viewport, decoding it on the way. Hidden pages before it contribute zero
  /// height, so their existence does not shift the target.
  void scrollToPage(int index) {
    if (index < 0 || index >= _pages.length) return;
    final pos = _visible.indexOf(index);
    if (pos < 0) return; // 目标页被隐藏：没有可滚到的位置。
    _loadAround();
    if (!_hasSolePosition) return;
    var target = 0.0;
    for (var v = 0; v < pos; v++) {
      target += _pageHeight(_visible[v]) + _effectiveGap;
    }
    _controller.jumpTo(target.clamp(0.0, _controller.position.maxScrollExtent));
  }

  /// B-2b：返回**离视口中心最近的那道缝**（上页/下页的**工程**下标），供
  /// 「识别跨页块」决定在哪两页上拼缝窗口。没有相邻两页 / 控制器未附着时
  /// 返回 null。隐藏页不产生缝。
  ///
  /// 🔴 不用 [StripGeometry.nearestSeam] 的 28px 阈值 —— 这里要的是"用户视野
  /// 中央最近的缝"，离得远也该给答案（后续窗口识别失败会如实报错），而不是
  /// 返回 null 让按钮看起来失灵。
  ({int above, int below})? nearestSeamToViewport() {
    if (_visible.length < 2 || !_hasSolePosition) return null;
    final center =
        _controller.offset + _controller.position.viewportDimension / 2;
    final seams = _spanGeometry().seamStripYs;
    if (seams.isEmpty) return null;
    var bestPos = 0;
    var bestDistance = double.infinity;
    for (var i = 0; i < seams.length; i++) {
      final distance = (seams[i] - center).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        bestPos = i;
      }
    }
    // seamStripYs[i] = 可见第 i+1 页的 stripTop ⇒ 缝夹在可见 i 与 i+1 之间；
    // 再映射回工程下标给调用方。
    return (above: _visible[bestPos], below: _visible[bestPos + 1]);
  }

  GlobalKey _keyFor(int index) =>
      _keys.putIfAbsent(index, () => GlobalKey());

  void _onScroll() {
    if (!_controller.hasClients || _visible.isEmpty) return;
    final best = _currentPageIndex();
    widget.onPageChanged?.call(best);
    _loadAround();
  }

  /// 视口中占主导（上 1/3 线所落）的可见页位置。
  int _currentVisiblePosition() {
    if (!_hasSolePosition || _visible.isEmpty) return 0;
    final target = _controller.offset + _controller.position.viewportDimension / 3;
    var acc = 0.0;
    for (var v = 0; v < _visible.length; v++) {
      final h = _pageHeight(_visible[v]) + _effectiveGap;
      if (acc + h > target) return v;
      acc += h;
    }
    return _visible.length - 1;
  }

  /// Project index of the page dominating the viewport's upper third — that is
  /// what the reader considers "the page they are on".
  int _currentPageIndex() =>
      _visible.isEmpty ? 0 : _visible[_currentVisiblePosition()];

  /// 某页经文件头探测得到的尺寸（无探测回调/未探测均为 null）。
  ({double width, double height})? _probedSize(String key) {
    final probed = widget.probedSizeOf?.call(key);
    if (probed == null) return null;
    final w = probed.width;
    final h = probed.height;
    if (w == null || h == null || w <= 0 || h <= 0) return null;
    return (width: w.toDouble(), height: h.toDouble());
  }

  /// 🔴 The height a page occupies in the strip.
  ///
  /// This is the **single source of truth** for the strip's vertical geometry:
  /// [_StripItem] sizes its placeholder with it too. They used to disagree
  /// (420 vs 1100), which meant the layout and the scroll maths each told a
  /// different story — the reported page drifted and `scrollToPage` landed
  /// somewhere else entirely.
  ///
  /// The formula mirrors the canvas widgets' fit in the strip (list height is
  /// unbounded, so it is simply `有效宽 / 页自然宽`).
  ///
  /// 🔴 P31：**去掉 `min(…, 1.0)` 钳制**。旧公式在 zoom>1 时仍按自然宽渲染，
  /// 放大只剩横向裁切宽度变化 —— 这正是「Ctrl+滚轮只出现横滚、图片/块不放大」
  /// 的根因；同时 item 真实高度（painter 已按放大后的 fit 撑高）与这里的估高
  /// 不一致，窗口中心随缩放算错，放大后滚几页就看到缺页占位符。
  ///
  /// P30：未解码页优先用文件头探测的**逐页真值**，全局 [_pageAspect] 只是最后
  /// 的兜底 —— 横版首页不会再把整本竖版页的估高带偏。
  double _pageHeight(int index) {
    if (index < 0 || index >= _pages.length) return 0;
    final width = _effectiveWidth;
    // 🔴 两路尺寸统一成同一个 record 类型再 ??：Size 与 (double,double) record
    // 的最小公共上界是 Object，直接 `a ?? b` 后读 .width 编译不过。
    final decodedSize = _pages[index].decoded?.originalSize;
    final ({double width, double height})? size = decodedSize == null
        ? _probedSize(_pages[index].key)
        : (width: decodedSize.width, height: decodedSize.height);
    if (size == null || size.width <= 0 || size.height <= 0) {
      // 兜底高度同样随 effectiveWidth（含 zoom）等比缩放。
      return width * _pageAspect;
    }
    return size.height * (width / size.width);
  }

  /// 围绕当前视口（或 [forcePos] 指定的可见位置）解码并淘汰。
  ///
  /// 🔴 P31 起规则全部落在纯逻辑件 [StripDecodePlanner]：窗口范围、距中心
  /// 优先、并发名额、永久闩锁、出窗翻篇都能在 headless 正反断言。窗口只按
  /// **可见页位置**计算：隐藏页既不入队，也必然被淘汰/取消。
  ///
  /// 🔴 P32：滚动位置已附着时改走 [StripDecodePlanner.planForViewport] ——
  /// 紧带按「视口像素 + cacheExtent」开窗（保证 ListView 构建出的页必在
  /// wanted），宽保活带再外扩 1.5 屏做迟滞（边界抖动不取消在飞解码）。
  /// [forcePos] / 位置未附着的首帧仍走固定页数窗口（[StripDecodePlanner.plan]）。
  void _loadAround([int? forcePos]) {
    if (!mounted || _visible.isEmpty) return;
    final StripDecodePlan plan;
    if (forcePos == null && _hasSolePosition) {
      plan = _planForViewport();
    } else {
      final center =
          (forcePos ?? _currentVisiblePosition()).clamp(0, _visible.length - 1);
      plan = StripDecodePlanner.plan(
        visible: _visible,
        total: _pages.length,
        center: center,
        keepAlive: _keepAlive,
        capacity: maxConcurrentDecodes,
        busy: _decodeBudget.busy,
        maxAttempts: maxDecodeAttempts,
        stateOf: _slotStateOf,
      );
    }
    _applyPlan(plan);
  }

  StripSlotState _slotStateOf(int i) => (
        decoded: _pages[i].decoded != null,
        loading: _pages[i].loading,
        failures: _pages[i].failures,
      );

  /// 按 ListView 的真实像素几何构造每页的「内容顶 y / 内容高」。
  ///
  /// 与 [_spanGeometry] / item 的 Padding 同源：ListView 顶部 padding 一个
  /// gap、每个 item 上下各 gap/2 ⇒ 首页内容顶 = 1.5·gap，之后每页步进
  /// `页高 + gap`。用错半格，紧带边界就会错位半页，缺图症会回来。
  StripDecodePlan _planForViewport() {
    final position = _controller.position;
    final gap = _effectiveGap;
    final tops = <double>[];
    final heights = <double>[];
    var y = gap * 1.5;
    for (final idx in _visible) {
      final h = _pageHeight(idx);
      tops.add(y);
      heights.add(h);
      y += h + gap;
    }
    final viewportH = position.viewportDimension;
    return StripDecodePlanner.planForViewport(
      visible: _visible,
      tops: tops,
      heights: heights,
      total: _pages.length,
      scrollOffset: position.pixels,
      viewportHeight: viewportH,
      // 紧带：视口上下各外扩一整屏 + cacheExtent，快滚也有提前量，
      // 且 ListView cache 区构建的页必在其中。
      preloadPad: viewportH + _stripCacheExtent,
      // 宽带：紧带之外再多保活 1.5 屏 —— zoom 一档改 12% 页高，边界页
      // 一次手势内不可能跨出宽带，"刚入队就取消"的振荡被迟滞吞掉。
      retainPad: viewportH * 2.5 + _stripCacheExtent,
      capacity: maxConcurrentDecodes,
      busy: _decodeBudget.busy,
      maxAttempts: maxDecodeAttempts,
      stateOf: _slotStateOf,
    );
  }

  void _applyPlan(StripDecodePlan plan) {
    // ① 出窗且在飞：先作废 token（结果到达即弃），名额在终结回调归还。
    for (final idx in plan.cancelLoading) {
      _pages[idx].cancelInFlight();
      Log.info(
        'TranslationStudio.Strip',
        'decode canceled (left window): #${idx + 1} ${_pages[idx].key}',
      );
    }
    // ② 出窗且持有位图：释放。
    var needsRebuild = plan.cancelLoading.isNotEmpty;
    for (final idx in plan.evictDecoded) {
      _pages[idx].dispose();
      needsRebuild = true;
    }
    // ③ 出窗空闲但带失败计数：翻篇（旧逻辑漏了这一类，null 失败页出窗后
    //   闩锁永不解除 —— P31「深页永久缺页」的实锤缺陷之一）。
    for (final idx in plan.resetFailures) {
      _pages[idx].failures = 0;
    }
    // ④ 窗口内按距中心顺序补队，数量已被 planner 夹到剩余名额。
    for (final idx in plan.startInOrder) {
      _startDecode(_pages[idx]);
    }
    if (needsRebuild && mounted) setState(() {});
  }

  /// 任何一次解码结束（成功/失败/过期）后补队，让被并发上限挡下的页接着解。
  void _pumpDecode() {
    if (mounted) _loadAround();
  }

  void _startDecode(StudioStripPage page) {
    // 名额账唯一入口：planner 已按剩余名额夹过，这里再兜一层。
    if (!_decodeBudget.acquire()) return;
    page.loading = true;
    final token = ++page.token;
    final attempt = page.failures + 1;
    final sw = Stopwatch()..start();
    Log.info(
      'TranslationStudio.Strip',
      'decode start: #${page.index + 1} ${page.key} '
      'attempt=$attempt busy=${_decodeBudget.busy}',
    );
    decodePageFile(page.file, fromInpainted: page.fromInpainted).then(
      (decoded) {
        // 🔴 五条终结路径的共同第一步：先还名额，再看 token。
        _decodeBudget.release();
        if (!mounted || page.token != token) {
          decoded?.dispose();
          Log.info(
            'TranslationStudio.Strip',
            'decode stale (discarded): #${page.index + 1} ${page.key}',
          );
          _pumpDecode();
          return;
        }
        page.loading = false;
        page.decoded = decoded;
        if (decoded == null) {
          page.failures++;
          // 🔴 P31 取证：decodePageFile 内部会先打出**原始错误**（读盘失败 /
          // codec 失败 / 资源不足），这行给次数与闩锁状态 —— 深页永久缺页到底
          // 是"真解码失败"还是"窗口错位"，靠 logs.txt 这两行一锤定音。
          Log.warning(
            'TranslationStudio.Strip',
            'decode null: #${page.index + 1} ${page.key} '
            'attempt=$attempt failures=${page.failures}/$maxDecodeAttempts '
            '${page.file.path}',
          );
        } else {
          Log.info(
            'TranslationStudio.Strip',
            'decode ok: #${page.index + 1} ${page.key} '
            '${sw.elapsedMilliseconds}ms '
            '${decoded.originalSize.width.round()}x'
            '${decoded.originalSize.height.round()}',
          );
          // 只在还是默认估计时、且从**竖版页**学习全局兜底长宽比（P30）：
          // 横版宣传首页是例外，不该让 94 张竖版页都按它的比例估高。
          final os = decoded.originalSize;
          if (_pageAspect == _defaultPageAspect && os.height >= os.width) {
            _pageAspect = os.height / os.width;
          }
        }
        // 🔴 Repaint from **here**, not from the caller: this is the only place
        // that knows the bitmap arrived (or the failure state changed).
        if (mounted) setState(() {});
        _pumpDecode();
      },
      onError: (Object error, StackTrace stack) {
        // decodePageFile 内部已全捕获；这层只是保证并发额度永不泄漏。
        _decodeBudget.release();
        if (!mounted || page.token != token) {
          _pumpDecode();
          return;
        }
        page.loading = false;
        page.failures++;
        Log.warning(
          'TranslationStudio.Strip',
          'decode threw: #${page.index + 1} ${page.key} '
          'failures=${page.failures}/$maxDecodeAttempts $error',
        );
        if (mounted) setState(() {});
        _pumpDecode();
      },
    );
  }

  /// 占位符上的「点击重试」：清零失败计数并立刻补队。
  void retryPage(StudioStripPage page) {
    if (page.decoded != null || page.loading) return;
    page.failures = 0;
    _loadAround();
  }

  // ── B-2 跨页框选 ────────────────────────────────────────────────────

  /// 当前条带的几何（与 [_pageHeight] 同一条公式；见 `strip_geometry.dart`）。
  ///
  /// 只含**可见页**；未解码页依次用「文件头探测尺寸 → [_pageAspect]」，与
  /// [_pageHeight] 完全一致 —— 否则拖出来的框会与落盘的块错位。
  StripGeometry _spanGeometry() => StripGeometry.build(
        keys: [for (final i in _visible) _pages[i].key],
        sizes: [
          for (final i in _visible)
            () {
              final decoded = _pages[i].decoded;
              if (decoded != null) {
                return (
                  width: decoded.originalSize.width.toDouble(),
                  height: decoded.originalSize.height.toDouble(),
                );
              }
              return _probedSize(_pages[i].key);
            }(),
        ],
        viewportWidth: _effectiveWidth,
        // P31：gap/topPadding 都随 zoom 等比（见 [_effectiveGap]）。
        gap: _effectiveGap,
        // 🔴 起始偏移 = ListView 的上下 padding(各 gap) + 每页自带的 padding(gap/2)
        // = 1.5·gap。少算这半个 gap 时（gap 非 0 时）缝线会与真正的页边界差半格，
        // 落盘的块随之整体上移。
        topPadding: _effectiveGap * 1.5,
        fallbackAspect: _pageAspect,
        // P31：放大（zoom>1）不设 fit 上限，缝几何必须和真实渲染一样把页放大；
        // 否则跨页框选在放大状态下落盘坐标整体偏小。
        maxFit: double.infinity,
      );

  /// 视口局部坐标 → 条带坐标（加上滚动偏移）。
  Offset _toStrip(Offset local) => Offset(local.dx, local.dy + _scrollOffset);

  void _spanPanStart(Offset local) {
    final strip = _toStrip(local);
    _spanAnchorStrip = strip;
    _spanCurrentStrip = strip;
    _spanHighlightSeam = null;
    _spanRepaint.value++;
  }

  void _spanPanUpdate(Offset local) {
    if (_spanAnchorStrip == null) return;
    final strip = _toStrip(local);
    _spanCurrentStrip = strip;
    _spanHighlightSeam = _spanGeometry().nearestSeam(strip.dy);
    _spanRepaint.value++;
  }

  void _spanPanEnd() {
    final anchor = _spanAnchorStrip;
    final current = _spanCurrentStrip;
    _spanAnchorStrip = null;
    _spanCurrentStrip = null;
    _spanHighlightSeam = null;
    _spanRepaint.value++;
    if (anchor == null || current == null) return;
    final rect = Rect.fromPoints(anchor, current);
    // 太小的拖拽当误触：既不是框选，也不该建出一个没法嵌字的细条。
    if (rect.width < 8 || rect.height < 8) return;
    final parts = _spanGeometry().splitStripRect(
      left: rect.left,
      top: rect.top,
      right: rect.right,
      bottom: rect.bottom,
    );
    if (parts.isEmpty) return;
    widget.onSpanMarquee?.call(parts);
  }

  /// 跨页框选时把滚轮转发给条带：手势层盖住了 ListView，滚轮自己到不了它。
  /// Ctrl+滚轮不转发 —— 那是缩放手势（见 [_onPointerSignal]）。
  void _spanPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_hasSolePosition) return;
    if (HardwareKeyboard.instance.isControlPressed) return;
    _controller.jumpTo(
      (_controller.offset + event.scrollDelta.dy)
          .clamp(0.0, _controller.position.maxScrollExtent),
    );
  }

  /// P30：Ctrl + 滚轮缩放长画布（50%~200%）。
  ///
  /// Listener 无法"吃掉"滚轮（PointerSignal 不走竞技场，Scrollable 仍会收到），
  /// 所以同时把按住 Ctrl 时的 ListView physics 换成不可滚（[_ctrlHeld]），
  /// 双管齐下保证缩放时不混着翻页。
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (!HardwareKeyboard.instance.isControlPressed) return;
    // 触控板的捏合手势 delta 很大，指数曲线把它压成"一格一档"的手感。
    final factor = math.exp(-event.scrollDelta.dy / 600);
    final next =
        (_stripZoom * factor).clamp(_minStripZoom, _maxStripZoom).toDouble();
    if ((next - _stripZoom).abs() <= 0.001 || !mounted) return;

    // 🔴 P31：缩放是**整条内容等比缩放** —— 每个页高、每条 gap、ListView 的
    // 上下 padding 都严格乘 zoom，所以同一内容点在新旧两档下只差一个比例
    // `ratio`。以视口中心为锚点：newOffset = ratio·old + (ratio−1)·视口半宽，
    // 缩放后眼里的画面中心仍是同一处，上下页连贯不跳。
    //
    // 🔴 P32：一帧内可能连来多个滚轮事件 —— 锚点（缩放前的 zoom 与两轴偏移）
    // 只在**链头**抓一次，每个事件只推进 `_stripZoom`；帧末统一按
    // finalZoom/anchorZoom 的复合比例校正一次。旧实现每事件各抓旧偏移各排
    // postFrame，帧末两个 jumpTo 都以缩放前偏移为基准互相覆盖，位置抖动直接
    // 放大了解码窗口振荡（缩小到 ~88% 缺图的诱因之一）。
    final anchor = _zoomAnchor;
    if (anchor == null) {
      _zoomAnchor = (
        oldZoom: _stripZoom,
        oldV: _scrollOffset,
        oldH: _horizontalController.hasClients ? _horizontalController.offset : 0.0,
        vpHeight: _hasSolePosition
            ? _controller.position.viewportDimension
            : 0.0,
        vpWidth: _viewportWidth > 0 ? _viewportWidth : 800.0,
      );
    }
    setState(() => _stripZoom = next);
    if (anchor != null) return; // 本帧已有帧末校正排队，不再重复排。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final a = _zoomAnchor;
      _zoomAnchor = null;
      if (!mounted || a == null) return;
      final ratio = _stripZoom / a.oldZoom;
      if (_hasSolePosition && a.vpHeight > 0) {
        final target = ratio * a.oldV + (ratio - 1) * a.vpHeight / 2;
        _controller.jumpTo(
          target.clamp(0.0, _controller.position.maxScrollExtent),
        );
      }
      if (_horizontalController.hasClients && a.vpWidth > 0) {
        final target = ratio * a.oldH + (ratio - 1) * a.vpWidth / 2;
        _horizontalController.jumpTo(
          target.clamp(0.0, _horizontalController.position.maxScrollExtent),
        );
      }
      // 高度整体变了：窗口中心、驻留集合按新几何重算。
      _loadAround();
    });
  }

  Widget _spanOverlay(StripGeometry geometry) {
    return Positioned.fill(
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerSignal: _spanPointerSignal,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (d) => _spanPanStart(d.localPosition),
          onPanUpdate: (d) => _spanPanUpdate(d.localPosition),
          onPanEnd: (_) => _spanPanEnd(),
          onPanCancel: _spanPanEnd,
          // 🔴 缝线/框都记在条带坐标里，绘制前要减 `scrollOffset`。滚动本身
          // **不会**触发本 widget 的 `build`（只有 `onPageChanged` 跨页时父级才
          // 重建），所以这里必须自己订阅信号源 —— 否则缝线会钉在屏幕上不动，
          // 用户对着一条与画面无关的横线拖框。两个信号源：`_controller`（滚动
          // 偏移变了）与 `_spanRepaint`（拖框状态变了）。订阅只重绘这层覆盖层，
          // 不重建整条 ListView。
          child: ListenableBuilder(
            listenable: Listenable.merge([_controller, _spanRepaint]),
            builder: (context, _) {
              final anchor = _spanAnchorStrip;
              final current = _spanCurrentStrip;
              return CustomPaint(
                size: Size.infinite,
                painter: _SpanOverlayPainter(
                  scrollOffset: _scrollOffset,
                  marquee: anchor == null || current == null
                      ? null
                      : Rect.fromPoints(anchor, current),
                  seamStripYs: geometry.seamStripYs,
                  highlightSeamStripY: _spanHighlightSeam,
                  color: Theme.of(context).colorScheme.primary,
                ),
              );
            },
          ),
        ),
      ),
    );
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
    return Listener(
      onPointerSignal: _onPointerSignal,
      child: NotificationListener<ScrollNotification>(
      onNotification: (_) {
        _onScroll();
        return false;
      },
      child: Scrollbar(
        controller: _controller,
        // P32：滚动条加粗并常显（旧版细到难以点拖）；interactive 允许直接
        // 拖动条身翻页。
        thickness: 10.0,
        radius: const Radius.circular(5),
        thumbVisibility: true,
        interactive: true,
        // 🔴 轨道在画面**外侧**：用 Padding 在内容右侧预留等宽留白，滚动条
        // 画在留白上，任何 zoom 档位都不遮挡漫画（P27 教训：树结构恒常，
        // 这里只是常驻一层 Padding，不随任何模式重挂）。
        child: Padding(
          padding: const EdgeInsets.only(right: _scrollbarGutter),
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
            final viewportWidth = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : 800.0;
            final effectiveWidth = viewportWidth * _stripZoom;
            final listView = ListView.builder(
              controller: _controller,
              // Ctrl 按住时滚轮只缩放、不翻页（见 [_onPointerSignal]）。
              physics: _ctrlHeld
                  ? const NeverScrollableScrollPhysics()
                  : null,
              // P32：显式与解码紧带的边距同源（见 [_stripCacheExtent]）。
              cacheExtent: _stripCacheExtent,
              // P31：上下留白随 zoom 等比（与页高、缝几何同一比例）。
              padding: EdgeInsets.symmetric(vertical: _effectiveGap),
              itemCount: _visible.length,
              itemBuilder: (context, v) {
                final index = _visible[v];
                final page = _pages[index];
                return _StripItem(
                  key: _keyFor(index),
                  page: page,
                  height: _pageHeight(index),
                  blocks: widget.blocksFor(page.key),
                  // P31：选择态只落在真身页那一个 item 上。
                  selectedIndex: widget.selectedPageKey == page.key
                      ? widget.selectedIndex
                      : -1,
                  groupFrame: widget.groupFrameFor?.call(page.key),
                  showBoxes: widget.showBoxes,
                  onSelect: (pageKey, index) =>
                      widget.onSelect?.call(pageKey, index),
                  gap: _effectiveGap,
                  editable: widget.editable,
                  // 🔴 拖动/缩放/框选的回调是 **page-key-free**：[_StripItem] 是
                  // 逐页的，已经闭包住了 `page.key`；手势也只可能落在本页自己的块
                  // 上（投影片段不可拖），所以这里补回 `page.key` 就是唯一的一处。
                  //
                  // 点选/双击**不在此列**：它们可能是画在别页的投影片段，真身在
                  // 另一页，所以 [_StripItem] 已经把[真身页, 真身下标]算好再回报。
                  onMoveBlock: (index, oldTopLeft, newTopLeft) => widget
                      .onMoveBlock
                      ?.call(page.key, index, oldTopLeft, newTopLeft),
                  onResizeBlock: (index, oldRect, newRect) => widget
                      .onResizeBlock
                      ?.call(page.key, index, oldRect, newRect),
                  onResizeGroup: (groupId, oldBounds, newBounds) => widget
                      .onResizeGroup
                      ?.call(page.key, groupId, oldBounds, newBounds),
                  onMarquee: (rect) => widget.onMarquee?.call(page.key, rect),
                  marqueeMode: widget.marqueeMode,
                  onEditText: (pageKey, index) =>
                      widget.onEditText?.call(pageKey, index),
                  isFirst: v == 0,
                  groupPickMode: widget.groupPickMode,
                  onPickBlock: (pageKey, index) =>
                      widget.onPickBlock?.call(pageKey, index),
                  onRetry: () => retryPage(page),
                );
              },
            );
            // 🔴 这层树结构**不随缩放变化**（P27 教训：ListView 重挂会同帧挂
            // 两个 ScrollPosition）：外层 SizedBox 永远取 `max(视口, 有效宽)`，
            // 缩放 <100% 由 Align 居中，>100% 由横向 SingleChildScrollView
            // 提供左右滚动；切档只改一个宽度数字。
            final stripBody = SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              // P31：自持控制器，缩放档变化时以视口中心为锚点校正横向偏移。
              controller: _horizontalController,
              child: SizedBox(
                width: math.max(viewportWidth, effectiveWidth),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: SizedBox(width: effectiveWidth, child: listView),
                ),
              ),
            );
            // 🔴 `Stack` **常驻**，即使不在跨页框选也保留 —— 这不是为了少写一行。
            // 上一版在 `spanMode` 时把 `ListView` 从"LayoutBuilder 的直接子节点"
            // 挪进 `Stack`：结构一变，旧的 `Scrollable` 会先失活、帧末才 unmount，
            // 同一帧里滚动控制器上挂着 2 个 `ScrollPosition`，覆盖层读
            // `_controller.offset` 就抛 `Bad state: Too many elements`
            // （见 [_hasSolePosition]）。顺带还有两个副作用：整条 ListView 重挂
            // ⇒ 滚动位置被重置、每页重解码。常驻后条带始终是 `children[0]`，
            // `Stack` 的 `updateChildren` 按位置就地更新它，切模式/缩放都只是
            // 增删覆盖层或改宽度数字。
            return Stack(
              children: [
                stripBody,
                // 🔴 覆盖层必须盖住**整条**条带：每页的 EditableTextBlockCanvas
                // 手势被限制在单页内（D16 第②层），跨缝的拖拽只能靠这层条带级
                // 覆盖层。覆盖层会吃掉 ListView 的滚轮（见 [_spanPointerSignal]）。
                if (widget.spanMode) _spanOverlay(_spanGeometry()),
                if ((_stripZoom - 1.0).abs() > 0.001)
                  Positioned(
                    bottom: 8,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      child: Center(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: scheme.surface.withValues(alpha: 0.72),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            child: Text(
                              '${(_stripZoom * 100).round()}%',
                              style: TextStyle(
                                fontSize: 12,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
          ),
        ),
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
    this.groupFrame,
    required this.showBoxes,
    required this.onSelect,
    required this.gap,
    required this.editable,
    required this.onMoveBlock,
    required this.onEditText,
    required this.onResizeBlock,
    this.onResizeGroup,
    required this.onMarquee,
    required this.marqueeMode,
    required this.isFirst,
    required this.groupPickMode,
    required this.onPickBlock,
    required this.onRetry,
  });

  final StudioStripPage page;

  /// 🔴 Height the owning state computed for this page. The placeholder **must**
  /// use it: a hardcoded height made the layout disagree with the scroll
  /// arithmetic, so the reported page and `scrollToPage` both drifted while the
  /// user was certain they were on the page the status bar named.
  final double height;

  final List<CanvasTextBlock> blocks;
  final int selectedIndex;

  /// P31：本页当前可整体缩放的 nest 组外框（无则 null）。
  final CanvasGroupFrame? groupFrame;

  final bool showBoxes;

  /// 点选回报：**[块真身所在页, 真身下标]**。
  ///
  /// 🔴 不再是"本页 + 列表下标"（P28）。页的块列表现在可能含**跨页块的投影片段**
  /// （[CanvasTextBlock.ownerPageKey] != null）：片段画在下页，真身却在别的页上，
  /// 直接回报"本页 + 列表下标"会选中同下标的另一个块。映射在 [_reportTap] 一处完成。
  final void Function(String pageKey, int index)? onSelect;
  final double gap;
  final bool editable;
  final void Function(int index, Offset oldTopLeft, Offset newTopLeft)?
      onMoveBlock;

  /// 双击回报：同 [onSelect]，回指真身。
  final void Function(String pageKey, int index)? onEditText;
  final void Function(int index, Rect oldRect, Rect newRect)? onResizeBlock;

  /// P31：组外框整体缩放（页键已在外层闭包补齐）。
  final void Function(String groupId, Rect oldBounds, Rect newBounds)?
      onResizeGroup;

  final void Function(Rect rect)? onMarquee;
  final bool marqueeMode;

  /// 第一页不画顶部 1px 分隔线（上面没有前一页）。
  final bool isFirst;

  /// B-3 建组点选模式（见 [StudioScrollCanvas.groupPickMode]）。
  final bool groupPickMode;
  final void Function(String pageKey, int index)? onPickBlock;

  /// 解码失败（[_StudioStripPageState.maxDecodeAttempts] 次后闩锁）时
  /// 点击占位卡片重试 —— 旧版一旦失败就永久"缺少页面图片"，没有恢复路径。
  final VoidCallback onRetry;

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
              : InkWell(
                  onTap: onRetry,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        page.permanentlyFailed
                            ? Icons.broken_image_outlined
                            : Icons.image_outlined,
                        size: 18,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        page.permanentlyFailed
                            ? 'page image missing, tap to retry'.tl
                            : 'page image missing'.tl,
                        style:
                            TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
        ),
      );
    } else if (groupPickMode) {
      // B-3：建组点选用**只读**画布 —— 拖动/缩放在点选模式里是误触风险，而
      // 点选（含投影片段回指真身）由只读画布的 onSelect 同样支持。空点（-1）
      // 不回调：点空白不该清掉已有选择。
      body = TextBlockCanvas(
        blocks: blocks,
        selectedIndex: selectedIndex,
        onSelect: (index) {
          if (index < 0) return;
          _reportTap(onPickBlock, index);
        },
        base: decoded,
        showBoxes: showBoxes,
      );
    } else if (editable) {
      body = EditableTextBlockCanvas(
        blocks: blocks,
        selectedIndex: selectedIndex,
        onSelect: (index) => _reportTap(onSelect, index),
        base: decoded,
        showBoxes: showBoxes,
        // 🔴 These fields are **page-key-free**: [_StripItem] is per-page, so
        // it already knows `page.key` and closes over it. Passing it again
        // would double the argument count.
        onMoveBlock: (index, oldTopLeft, newTopLeft) =>
            onMoveBlock?.call(index, oldTopLeft, newTopLeft),
        onResizeBlock: (index, oldRect, newRect) =>
            onResizeBlock?.call(index, oldRect, newRect),
        groupFrame: groupFrame,
        onResizeGroup: onResizeGroup,
        onMarquee: (rect) => onMarquee?.call(rect),
        marqueeMode: marqueeMode,
        onEditText: (index) => _reportTap(onEditText, index),
      );
    } else {
      body = TextBlockCanvas(
        blocks: blocks,
        selectedIndex: selectedIndex,
        onSelect: (index) => _reportTap(onSelect, index),
        base: decoded,
        showBoxes: showBoxes,
      );
    }
    // 页码浮标与分隔线画在**页面之上**：布局高度因此严格等于画面高度，
    // 相邻两页真正贴在一起（原来是"页标签独占一行 + 上下各 gap/2"）。
    //
    // 🔴 整块包 `RepaintBoundary`（P28）：`ListView` 在滚动时会对视口做整体
    // 重绘，若没有这一层，每个可见页的 `_paintText`（每块数次 `TextPainter.layout`）
    // 都会跟着跑一遍 —— 这正是"长画布连续滚很卡"的直接来源。有了这一层，页与页
    // 互不牵连，只有自身内容变化时才重绘。
    return RepaintBoundary(
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: gap / 2),
        child: Stack(
          children: [
            // 非定位子节点决定 Stack 尺寸（= 画面高度），其余都是叠加层。
            //
            // 🔴 P31：**每个** item（含解码完成的）都钉死在 state 算出的同一
            // 高度上。放大档下 painter 自己的 fit 也会撑高，但那是布局侧的高度；
            // 滚动/窗口/缝几何全部只认 `_pageHeight` —— 两侧哪怕只差一个像素，
            // 深滚时窗口中心就会累计错位（旧版 420 vs 1100 事故的同类）。
            SizedBox(
              height: height,
              width: double.infinity,
              child: body,
            ),
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
      ),
    );
  }

  /// 把画布回报的**列表下标**翻译成[块真身所在页, 真身下标]。
  ///
  /// 列表里既有本页自己的块（`ownerPageKey == null`），也有跨页块投影过来的
  /// 片段；空点（-1）回报本页 -1，让 owner 清掉选择（与改动前一致）。
  void _reportTap(void Function(String pageKey, int index)? callback, int listIndex) {
    if (callback == null) return;
    if (listIndex < 0 || listIndex >= blocks.length) {
      callback(page.key, -1);
      return;
    }
    final block = blocks[listIndex];
    callback(block.ownerPageKey ?? page.key, block.index);
  }
}

/// 跨页框选覆盖层的画笔：画出**每一条缝**、离拖拽点最近的那条（高亮）以及
/// 正在进行中的框。
///
/// 🔴 缝线与框都记在**条带坐标**里（内容坐标），而覆盖层铺在**视口**里，所以
/// 绘制前要减去 [scrollOffset]。少了这一步，缝线会在滚动时钉死在屏幕上，用户
/// 会对着一条与画面无关的横线拖框。
class _SpanOverlayPainter extends CustomPainter {
  _SpanOverlayPainter({
    required this.scrollOffset,
    required this.marquee,
    required this.seamStripYs,
    required this.highlightSeamStripY,
    required this.color,
  });

  final double scrollOffset;
  final Rect? marquee;
  final List<double> seamStripYs;
  final double? highlightSeamStripY;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final seamPaint = Paint()
      ..strokeWidth = 1
      ..color = color.withValues(alpha: 0.30);
    final hotPaint = Paint()
      ..strokeWidth = 2
      ..color = color.withValues(alpha: 0.90);
    for (final stripY in seamStripYs) {
      final y = stripY - scrollOffset;
      // 视口外的缝不画（条带可以有上百页）。
      if (y < -2 || y > size.height + 2) continue;
      final hot = highlightSeamStripY != null &&
          (highlightSeamStripY! - stripY).abs() < 0.5;
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        hot ? hotPaint : seamPaint,
      );
    }
    final box = marquee;
    if (box != null) {
      final local = box.shift(Offset(0, -scrollOffset));
      canvas.drawRect(local, Paint()..color = color.withValues(alpha: 0.12));
      canvas.drawRect(
        local,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = color.withValues(alpha: 0.95),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SpanOverlayPainter old) =>
      old.scrollOffset != scrollOffset ||
      old.marquee != marquee ||
      old.highlightSeamStripY != highlightSeamStripY ||
      !_sameDoubles(old.seamStripYs, seamStripYs) ||
      old.color != color;

  static bool _sameDoubles(List<double> a, List<double> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

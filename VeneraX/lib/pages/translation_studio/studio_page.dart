// dart:io comes through utils/io.dart (Directory/File/FilePath).

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:venera/components/components.dart';
import 'package:venera/components/editable_text_block_canvas.dart';
import 'package:venera/components/studio_scroll_canvas.dart';
import 'package:venera/components/text_block_canvas.dart';
import 'package:venera/foundation/bt_project/bt_project_manager.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/context.dart';
// 🔴 `IntRect` comes from **this** file, not `dart:ui`. The repo declares its
// own `IntRect` (left/top/right/bottom, no `fromLTWH`) in
// translation_types.dart so the translation model stays Flutter-free and
// testable headlessly; importing `dart:ui`'s same-named class instead compiles
// to a type error that reads like a missing identifier.
import 'package:venera/foundation/image_translation/balloon_clustering.dart';
import 'package:venera/foundation/image_translation/translation_config.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';
import 'package:venera/foundation/leave_guard.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/translation_project/edit_command.dart';
import 'package:venera/foundation/translation_project/finished_export.dart';
import 'package:venera/foundation/translation_project/project.dart';
import 'package:venera/foundation/translation_project/project_writer.dart';
import 'package:venera/foundation/translation_project/result_renderer.dart';
import 'package:venera/foundation/translation_project/rich_text_sync.dart';
import 'package:venera/foundation/translation_project/studio_pipeline.dart';
import 'package:venera/foundation/translation_project/text_block.dart';
import 'package:venera/foundation/widget_utils.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';

import 'studio_block_panel.dart';
import 'studio_preview.dart';

/// Editable studio canvas for one FT project (P6 S8).
///
/// Opened from the library's "翻译工作室" tab, which lists whatever
/// `btProjectRoot` points at — `ComicLibrary/projects/` for studio projects, or
/// the in-place layout an old FT project still uses.
///
/// Everything on screen is assembled from **two roots** (P6 §2.11(a)):
/// `project.directory` for the source page images and `project.workspace`
/// (the JSON's own folder when the file has no `workspace` key) for
/// `inpainted/`, `mask/` and `result/`.
///
/// ## What S8 added here
///
/// S7 made this page read-only. S8 turns it into an editor:
///
/// * the single-page canvas is [EditableTextBlockCanvas] (tap to select, drag to
///   move) and the strip canvas is the same widget per page;
/// * the property panel ([StudioBlockPanel]) writes back through
///   [TextBlock]/[FontFormat] setters;
/// * every change goes through an [EditHistory] command (Ctrl+Z / Ctrl+Y);
/// * Ctrl+S runs the unified save contract — JSON synchronously, `result/` in
///   the background — and invalidates the reader's `@bt:` caches so the reader
///   shows the new lettering.
class TranslationStudioPage extends StatefulWidget {
  const TranslationStudioPage({super.key, required this.comicId});

  final String comicId;

  @override
  State<TranslationStudioPage> createState() => _TranslationStudioPageState();
}

class _TranslationStudioPageState extends State<TranslationStudioPage> {
  TranslationProject? _project;
  String _error = '';
  String _title = '';

  /// Page keys that have something to show: a source image or an artifact.
  /// FT's json also stores keys for files that never existed (phantom `.jpg`
  /// shells next to the real `.webp` pages), and those must not become pages.
  List<String> _pageKeys = const [];

  int _pageIndex = 0;
  int _selectedBlock = -1;
  DecodedPage? _base;
  bool _loadingBase = false;
  int _baseToken = 0;

  /// Continuous-strip mode (all pages in one scroll) vs single-page + zoom.
  ///
  /// Defaults to the strip: reviewing a translation is a *sequence* job, and
  /// clicking "next" 97 times is what made the old canvas unusable for the
  /// proofread it exists to support.
  bool _stripMode = true;

  /// Marquee ("draw a new box") mode.
  ///
  /// 🔴 An explicit mode rather than "drag on empty space draws a box": a drag
  /// that starts inside the selected block is far more often a **move** than an
  /// intent to replace the selection, and guessing wrong would make the block
  /// the user just positioned jump somewhere else. A mode costs one click and
  /// removes the ambiguity entirely; it also auto-exits after a successful draw
  /// so consecutive blocks can be placed without re-arming.
  bool _marqueeMode = false;

  /// Creates a block from a marquee the user dragged on the canvas.
  ///
  /// Auto-exits marquee mode: the overwhelmingly common case is "place this
  /// block, then type", and leaving the mode on would make the next drag on the
  /// page draw another box instead of doing what the user expects.
  void _onMarquee(Rect rect) {
    if (!_marqueeMode) return;
    setState(() => _marqueeMode = false);
    _createBlockAt(rect);
  }

  /// Drives the strip so the page rail and the "go to page" dialog can scroll
  /// it. Only attached while [_stripMode] is on.
  final _stripController = ScrollController();
  final _stripKey = GlobalKey<StudioScrollCanvasState>();

  /// Undo/redo stack over the loaded project's blocks (P6 S8).
  final _history = EditHistory();

  /// Bumped on every model change — edit **and** undo/redo — so the property
  /// panel's text controller can follow the model instead of going stale.
  int _revision = 0;

  /// Page key that owns [_selectedBlock]. In strip mode the same block index
  /// exists on every page, so the index alone cannot identify a selection.
  String? _selectedPageKey;

  /// Set while a save's background `result/` pass is running, for the status bar.
  bool _renderingResults = false;

  // ── S9 · P1-5: 自动管线触发入口 ──────────────────────────────────────────
  //
  // 🔴 进度与取消**不复用** `PreTranslationTaskManager`。那套状态机绑在旧引擎
  // 的章节/分组模型上（`eid`、group committer、断点游标），拉过来就得把旧
  // OCR 缓存的写入口一起拉进来 —— 而本项的全部意义就是"产物写工程、不写
  // 缓存"（P9.5 §四）。这里用一个 token + 一个计数器，最朴素也最不容易把
  // 两条路糊在一起。

  /// 非空表示管线在跑。
  final _pipeline = _StudioPipelineState();

  /// 批量运行时"跳过已有块"的开关。
  ///
  /// 默认**开**：整章重跑是最容易点错的按钮，而用户已经校对过的块比新检测的
  /// 块更值钱。关掉它等于允许一次批量运行覆盖人工工作，那必须是一个
  /// 明确的选择，不能是默认值。
  bool _pipelineSkipExisting = true;

  /// 日漫右起是默认；欧漫/条漫的用户需要能改。
  ///
  /// 🔴 做成**会话内状态而不是设置项**：阅读方向是"看这一本时怎么读"，
  /// 写进全局设置意味着为了一本横排漫画改掉了所有漫画的默认。它不进
  /// `appdata` 也不进工程 json，因此**不会**破坏零字节 diff。
  bool _pipelineRightToLeft = true;

  /// 关掉时只做检测 + OCR + 建块，不调 LLM。
  bool _pipelineTranslate = true;

  /// 「从这一页继续」的断点 = **第一条没有跑完的页** key，null 表示没有断点。
  ///
  /// 🔴 会话内状态，与上面三项同理：不进 `appdata`，不写工程 json。
  /// 跨会话续跑要把断点持久化，而那要么写进工程（立刻破坏零字节 diff），
  /// 要么写进 `appdata`（而"整章跑到哪"是一次性状态，不是设置）—— 留给 P10
  /// 的批量任务框架；本项只做当前会话内的续跑，并如实说明这一点。
  String? _pipelineResumeFrom;

  void _runPipelineCurrentPage() {
    if (_pageKeys.isEmpty) return;
    unawaited(_runPipeline(pages: [_pageKeys[_pageIndex]]));
  }

  void _runPipelineAllPages() {
    unawaited(_runPipeline(pages: _pageKeys));
  }

  /// 从断点继续：只把断点之后的页交给管线。
  ///
  /// 幂等：断点之前已经落地的块由去重保护，而断点页本身会被重跑一次 ——
  /// 这正是"失败页重试"想要的行为。
  void _resumePipeline() {
    final from = _pipelineResumeFrom;
    if (from == null) return;
    // 🔴 语义只有一个来源（`resumePages`）：断点不在页集里时它是**空**，
    // 于是这里清断点而不是从第 0 页开始 —— 否则"继续"会静默变成整章重跑。
    final pages = resumePages(_pageKeys, from);
    if (pages.isEmpty) {
      setState(() => _pipelineResumeFrom = null);
      return;
    }
    unawaited(_runPipeline(pages: pages));
  }

  /// 跑 [pages]，逐页落地并刷新 UI。
  Future<void> _runPipeline({required List<String> pages}) async {
    final project = _project;
    if (project == null || pages.isEmpty) return;
    if (_pipeline.running) return;
    // 🔴 批量建块会产生几十个块，而 `EditHistory.limit` 是 200：整章 97 页
    // × 平均 8 块 = 776 步，一次批量运行就会把最早的编辑挤出 undo 栈。
    // 所以每页一次 push（可整页撤销），而不是每块一次。
    setState(() {
      _pipeline
        ..running = true
        ..done = 0
        ..total = pages.length
        ..blocks = 0
        ..skipped = 0
        ..failures = 0
        ..current = pages.first
        ..cancel = CancellationToken()
        ..lastMessage = 'Running…'.tl;
    });
    final cancel = _pipeline.cancel!;
    final config = TranslationConfig.of(widget.comicId, null);
    final pipeline = StudioPagePipeline();
    final options = StudioRunOptions(
      // 工作室没有"这本漫画"的上下文可继承，读全局设置：用户在阅读器里改过
      // 的语向对同一本漫画同样成立，而猜一个默认值只会让第一次运行的产物
      // 全是错的语言。
      sourceLang: config.sourceLang,
      targetLang: config.targetLang,
      readingDirection: _pipelineRightToLeft
          ? ReadingDirection.rightToLeft
          : ReadingDirection.leftToRight,
      translate: _pipelineTranslate,
    );

    var blocks = 0;
    var skipped = 0;
    var failures = 0;
    // 🔴 P9.7 断点：取**第一条没有跑完的页**。取消时它就是停在的那一页，
    // 失败时它就是第一页失败页 —— 两种续跑都是幂等的，因为断点之前已落地的
    // 块由去重保护，断点页本身重跑一次正是"失败页重试"想要的行为。
    String? resumeFrom;
    for (final pageKey in pages) {
      if (cancel.isCanceled) {
        resumeFrom ??= pageKey;
        break;
      }
      if (mounted) setState(() => _pipeline.current = pageKey);
      final file = _resolvePageFile(pageKey);
      if (file == null) {
        // 🔴 页面图不在盘上（Error the Echo 那种原图已删的工程）。这种情况
        // **不静默跳过**：检测没有输入，页面上现有的块仍然保留，用户需要
        // 知道这一页没被处理过。
        failures++;
        resumeFrom ??= pageKey;
        if (mounted) {
          setState(() => _pipeline.lastMessage =
              'No page image for @a'.tlParams({'a': pageKey}));
        }
        continue;
      }
      final bytes = await file.readAsBytes();
      final size = _pageSizeInPixels(pageKey);
      final run = await pipeline.runPage(
        pageKey,
        bytes,
        options: options,
        pageWidth: size.width.round(),
        cancel: cancel,
      );
      if (run.error is PipelineCanceled) {
        resumeFrom ??= pageKey;
        break;
      }
      if (run.failed) {
        failures++;
        resumeFrom ??= pageKey;
        if (mounted) {
          setState(() => _pipeline.lastMessage =
              'Page @a failed: @b'.tlParams({
            'a': pageKey,
            // `Object?` is not assignable to the parameter map's `Object` value
            // type, and `run.error` is legitimately null on the success path —
            // stringify it so the message is honest either way.
            'b': '${run.error}',
          }));
        }
        continue;
      }
      // 去重在落地之前，且**只读**既有块（见 `overlapsExistingBlock` 的说明）。
      final page = project.pages[pageKey];
      if (page == null) {
        // 🔴 页在工程里不存在（页集变了，或 key 打错）。不能 `page!` 崩掉整章，
        // 也不能继续往下走 —— 那样 `blocks` 会计入**根本没落地**的块，状态栏
        // 报"本页新增 N 块"而画布上什么都没有，正是本项要消灭的那类静默。
        failures++;
        resumeFrom ??= pageKey;
        if (mounted) {
          setState(() => _pipeline.lastMessage =
              'Page @a is not in the project'.tlParams({'a': pageKey}));
        }
        continue;
      }
      var fresh = _pipelineSkipExisting
          ? [
              for (final block in run.blocks)
                if (!overlapsExistingBlock(page, block.rect)) block,
            ]
          : run.blocks;
      // 🔴 落地必须走与 Create/Delete 块**同一条**路径（硬规矩 3）：任何写
      // `pages[key]` 而不登记脏页的写法，都会让 `result/` 增量重渲漏掉这一页
      // —— 用户看到的是"跑完了，导出还是旧的"。
      if (fresh.isNotEmpty) {
        final command = captureBlockListEdit(
          page.rawBlocks,
          () => page.addBlocks(fresh),
          pageKey: pageKey,
          label: 'Detect blocks',
        );
        if (!command.isEmpty) _history.push(command);
      }
      blocks += fresh.length;
      skipped += run.skipped;
      if (mounted) {
        setState(() {
          _pipeline.done++;
          _pipeline.blocks = blocks;
          _pipeline.skipped = skipped;
          _pipeline.failures = failures;
        });
      }
    }

    if (!mounted) return;
    final stopped = cancel.isCanceled;
    setState(() {
      _pipeline
        ..running = false
        ..cancel = null
        ..lastMessage = _pipelineSummary(
          pages: pages,
          blocks: blocks,
          skipped: skipped,
          failures: failures,
          stopped: stopped,
        );
      // 全成功 = 没有断点；停止或有失败页 = 记住"从哪继续"。
      _pipelineResumeFrom = (stopped || failures > 0) ? resumeFrom : null;
      _revision++;
    });
    // 🔴 一次运行留下的**机器可读**痕迹。
    //
    // 端到端验证只能在 GUI 里跑（headless 无法建立渲染表面 → `dart:ui` 图像
    // 解码一律抛 `No Impeller context is available`，见 `P9.8`）。而状态栏
    // 文案是给人看的、关掉就没了 —— 没有这一行，"整章跑了一次"这件事事后
    // **无法取证**：块数可以从 json 数出来，但 `skipped`（漏检/误检的第一手
    // 线索）与失败页数只在 status bar 上出现过。
    //
    // 键名刻意与 `venera.exe --headless pipeline-check` 的报告对齐，两边的
    // 数字可以直接比对。
    Log.info(
      'Studio Pipeline',
      jsonEncode({
        'pages': pages.length,
        'done': _pipeline.done,
        'blocks': blocks,
        'skipped': skipped,
        'failures': failures,
        'stopped': stopped,
        'resumeFrom': _pipelineResumeFrom,
        'translate': _pipelineTranslate,
        'skipExisting': _pipelineSkipExisting,
        'rightToLeft': _pipelineRightToLeft,
      }),
    );
    // 页集/分辨率可能变了（inpainted/ 被写入），条带缓存必须重算。
    _invalidateStripCache();
    if (!stopped && failures == 0) {
      // 全成功才自动存：自动管线跑完不存等于用户还要按一次 Ctrl+S，而这一批
      // 块有可能是几十页的量。失败/取消时**不**自动存，让用户先看状态栏。
      unawaited(_save());
    }
  }

  /// 运行结束后的状态栏文案。三种结局必须能被一眼分开：全成 / 有失败 /
  /// 用户停的 —— 混成一句"完成"就会让漏掉的页被当成已处理。
  String _pipelineSummary({
    required List<String> pages,
    required int blocks,
    required int skipped,
    required int failures,
    required bool stopped,
  }) {
    if (stopped) {
      return 'Stopped after @a of @b pages'.tlParams({
        'a': '${_pipeline.done}',
        'b': '${pages.length}',
      });
    }
    if (failures > 0) {
      return '@a blocks on @b/@c pages, @d pages failed'.tlParams({
        'a': '$blocks',
        'b': '${pages.length - failures}',
        'c': '${pages.length}',
        'd': '$failures',
      });
    }
    return '@a blocks on @b pages@c'.tlParams({
      'a': '$blocks',
      'b': '${pages.length}',
      'c': skipped > 0 ? ', @a lines skipped'.tlParams({'a': '$skipped'}) : '',
    });
  }

  void _stopPipeline() {
    _pipeline.cancel?.cancel();
  }

  /// 侧栏联动：进入工作室时把左侧栏收起，退出时还原（见 [_autoCollapseSidebar]）。
  NaviPaneState? _pane;
  bool _sidebarCollapsedByUs = false;

  /// Whether [LeaveGuardRegistry] currently holds this page's [_leaveGuard].
  /// Disposal must not remove a guard it never added, and vice versa.
  bool _guardRegistered = false;

  /// Memoised [_stripPages] result, tagged with the project it was built for.
  /// See [_stripPages] for why this must not be recomputed per build.
  ({TranslationProject project, List<StudioStripPage> pages})? _stripCache;

  /// Set while the unsaved-changes prompt is open, so a second trigger (user
  /// mashing Back, or a close button landing mid-dialog) reuses the pending
  /// future instead of stacking a second dialog on top of the first.
  Future<bool>? _leaveCheckInFlight;

  @override
  void initState() {
    super.initState();
    _guardRegistered = true;
    LeaveGuardRegistry.add(_leaveGuard);
    _load();
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoCollapseSidebar());
  }

  @override
  void dispose() {
    if (_guardRegistered) LeaveGuardRegistry.remove(_leaveGuard);
    _stripController.dispose();
    _base?.dispose();
    // 侧栏是**祖先**的 state，此刻不能直接 setState（会被判为 build/dispose
    // 期间标记脏），推到下一帧再做。
    final pane = _pane;
    if (_sidebarCollapsedByUs && pane != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => pane.setSidebarCollapsed(false),
      );
    }
    super.dispose();
  }

  /// 工作室是横向最吃空间的页面（页轨 + 画布 + 属性面板），而左侧栏固定占掉
  /// 224px。进来时自动收起，退出时还原 —— 用户仍可用侧栏上的箭头手动切换。
  void _autoCollapseSidebar() {
    if (!mounted) return;
    final pane = NaviPane.maybeOf(context);
    if (pane == null || pane.sidebarCollapsed) return;
    _pane = pane;
    _sidebarCollapsedByUs = true;
    pane.setSidebarCollapsed(true);
  }

  Future<void> _load() async {
    final project = await BtProjectManager().ensureTranslationProject(
      widget.comicId,
    );
    if (!mounted) return;
    if (project == null) {
      setState(() => _error = 'Project not found. Rescan the workspace root.'.tl);
      return;
    }
    final keys = <String>[];
    for (final key in project.pageOrder) {
      if (_pageExists(project, key)) keys.add(key);
    }
    final comic = LocalManager().isInitialized
        ? LocalManager().find(widget.comicId, ComicType.local)
        : null;
    _history.clear();
    setState(() {
      _project = project;
      _pageKeys = keys;
      _error = keys.isEmpty ? 'This project has no readable page image.' : '';
      _title = comic?.title ?? project.jsonFileName;
      _pageIndex = 0;
      _selectedBlock = -1;
      _selectedPageKey = null;
      // 页集可能整个换掉了：断点指向的 key 未必还在（P9.7）。
      _pipelineResumeFrom = null;
      _revision++;
    });
    // The page set changed: the memoised strip list is stale.
    _invalidateStripCache();
    // The strip canvas decodes its own window, so priming a single page here
    // would just burn a bitmap nobody looks at.
    if (keys.isNotEmpty && !_stripMode) await _loadBase(keys.first);
  }

  static bool _pageExists(TranslationProject project, String key) {
    if (File(project.originalPath(key)).existsSync()) return true;
    for (final kind in const ['inpainted', 'mask']) {
      if (File(project.artifactPath(kind, key)).existsSync()) return true;
    }
    return false;
  }

  /// Case- and separator-insensitive path comparison. `File(path).path` keeps
  /// whatever form the caller passed, so `resolved` may differ from a
  /// hand-built path only by slash direction or drive-letter case.
  static bool _samePath(String? a, String? b) {
    if (a == null || b == null) return false;
    return a.replaceAll('\\', '/').toLowerCase() ==
        b.replaceAll('\\', '/').toLowerCase();
  }

  Future<void> _loadBase(String pageKey) async {
    final project = _project;
    if (project == null) return;
    final token = ++_baseToken;
    setState(() {
      _loadingBase = true;
      _selectedBlock = -1;
      _selectedPageKey = null;
    });
    // FT's own reading canvas shows the text-free `inpainted/` page by default
    // and falls back to the original. `mask/` is the last resort: it is what
    // survives when the raw comic folder was deleted but BT's artifacts were
    // kept, which is exactly the "Error the Echo" case — without it the whole
    // project has no displayable page at all.
    DecodedPage? decoded;
    for (final kind in const ['inpainted', 'mask']) {
      final file = File(project.artifactPath(kind, pageKey));
      if (!file.existsSync()) continue;
      final attempt = await decodePageFile(file, fromInpainted: true);
      if (attempt != null) {
        decoded = attempt;
        break;
      }
    }
    if (decoded == null) {
      decoded = await decodePageFile(File(project.originalPath(pageKey)));
    }
    if (!mounted || token != _baseToken) {
      decoded?.dispose();
      return;
    }
    setState(() {
      _base?.dispose();
      _base = decoded;
      _loadingBase = false;
    });
  }

  /// Resolves the bitmap for a page: raw original when present, else the
  /// text-free `inpainted/`, else `mask/`. Returns null when nothing is on disk.
  File? _resolvePageFile(String pageKey) {
    final project = _project;
    if (project == null) return null;
    final original = File(project.originalPath(pageKey));
    if (original.existsSync()) return original;
    for (final kind in const ['inpainted', 'mask']) {
      final file = File(project.artifactPath(kind, pageKey));
      if (file.existsSync()) return file;
    }
    return null;
  }

  /// Strip pages for the continuous canvas, resolved through [_resolvePageFile]
  /// so a project with no raw comic still scrolls.
  ///
  /// 🔴 **Cached, and the cache is what makes the strip work at all.**
  ///
  /// This used to be called straight from `build()`, which meant a fresh list of
  /// fresh [StudioStripPage] objects on *every frame* — and since decoded bitmaps
  /// live on those objects, each one silently threw the decode cache away.
  /// A scroll triggers a parent `setState` (via `onPageChanged`), so scrolling
  /// to page 2 and back left **every** page showing "page image missing",
  /// permanently: the page count never changed, so the canvas's old
  /// length-based reset never fired and nothing re-decoded.
  ///
  /// The list is also memoised because [_resolvePageFile] stats up to three
  /// paths per page — 97 pages means ~300 blocking filesystem calls per frame.
  List<StudioStripPage> _stripPages() {
    final project = _project;
    if (project == null) return const [];
    final cached = _stripCache;
    // Re-resolve when the project or the page set changed; otherwise reuse.
    if (cached != null && identical(cached.project, project)) return cached.pages;
    final result = <StudioStripPage>[];
    for (var i = 0; i < _pageKeys.length; i++) {
      final key = _pageKeys[i];
      final file = _resolvePageFile(key);
      if (file == null) continue;
      final isOriginal = _samePath(file.path, project.originalPath(key));
      result.add(
        StudioStripPage(
          index: i,
          key: key,
          file: file,
          fromInpainted: !isOriginal,
        ),
      );
    }
    _stripCache = (project: project, pages: result);
    return result;
  }

  /// Drops the memoised strip list. Must be called whenever the resolution
  /// order could have flipped on disk — i.e. after the detection pass writes
  /// `inpainted/`, which outranks the original page.
  void _invalidateStripCache() {
    _stripCache = null;
  }

  List<CanvasTextBlock> _blocksFor(String pageKey) {
    final page = _project?.pages[pageKey];
    if (page == null) return const [];
    final result = <CanvasTextBlock>[];
    for (var i = 0; i < page.blocks.length; i++) {
      result.add(_toCanvasBlock(page.blocks[i], i));
    }
    return result;
  }

  void _selectPage(int index) {
    if (index < 0 || index >= _pageKeys.length) return;
    setState(() {
      _pageIndex = index;
      _selectedBlock = -1;
      _selectedPageKey = null;
      // 🔴 P9.7: 翻页要把"框选新建"这个**模式**关掉。模式本身就设计成"画完
      // 一个自动退出"（[_onMarquee]），因为常见用法是"放一个块然后打字"；
      // 跨页保留它则相反 —— 用户换页多半只是想看看，下一次拖动就会在他
      // 没打算动的那一页上造出一个块，而块一旦落地就进了 undo 栈与脏页集合。
      // 两条翻页入口（本方法与长画布的 `onPageChanged`）必须一起清，只改
      // 一条会留下"单页模式正常、长画布漏"的假象。
      _marqueeMode = false;
    });
    if (_stripMode) {
      // In strip mode the canvas owns scroll position, so the jump buttons and
      // the page rail must scroll it rather than swap a hidden page underneath.
      _stripKey.currentState?.scrollToPage(index);
      return;
    }
    _loadBase(_pageKeys[index]);
  }

  ProjectPage? get _currentPage {
    final key = _pageKeys.isEmpty ? null : _pageKeys[_pageIndex];
    if (key == null) return null;
    return _project?.pages[key];
  }

  List<CanvasTextBlock> get _canvasBlocks {
    final page = _currentPage;
    if (page == null) return const [];
    final result = <CanvasTextBlock>[];
    for (var i = 0; i < page.blocks.length; i++) {
      result.add(_toCanvasBlock(page.blocks[i], i));
    }
    return result;
  }

  static CanvasTextBlock _toCanvasBlock(TextBlock block, int index) {
    final format = block.fontFormat;
    final box = block.xyxy;
    return CanvasTextBlock(
      index: index,
      rect: Rect.fromLTRB(box[0], box[1], box[2], box[3]),
      translation: block.translation,
      sourceText: block.sourceText,
      fontFamily: format?.fontFamily ?? FontFormat.defaultFontFamily,
      fontSize: format?.fontSize ?? block.detectedFontSize,
      fontWeight: format?.fontWeight ?? FontFormat.defaultFontWeight,
      alignment: format?.alignment ?? FontFormat.defaultAlignment,
      vertical: format?.vertical ?? block.sourceIsVertical,
      foreground: _colorOf(format?.foregroundColor ?? const [0, 0, 0]),
      hasFormat: format != null,
      // S7 flattened a block to 11 fields and dropped the rest, so the panel
      // could not show them and the painter could not honour them. Carrying
      // them here is what makes S8's editing and the honest property panel
      // possible without a second round of model changes.
      strokeColor: format == null
          ? null
          : _colorOf(format.strokeColor, fallbackAlpha: 0),
      strokeWidth: format?.strokeWidth ?? 0,
      letterSpacing: format?.letterSpacing,
      lineSpacing: format?.lineSpacing,
      opacity: format?.opacity ?? 1.0,
      gradientEnabled: format?.gradientEnabled ?? false,
      gradientStart: format == null
          ? null
          : _colorOf(format.gradientStartColor),
      gradientEnd: format == null
          ? null
          : _colorOf(format.gradientEndColor),
      gradientAngle: format?.gradientAngle ?? 0,
      angle: block.angle,
    );
  }

  /// FT stores colours as `[r, g, b]` or `[r, g, b, a]`. [fallbackAlpha] is
  /// used when the list has no alpha channel — a stroke with no alpha means
  /// "no stroke", so it maps to fully transparent rather than opaque.
  static Color _colorOf(List<int> rgb, {int fallbackAlpha = 255}) {
    if (rgb.length < 3) return const Color(0xFF000000);
    final alpha = rgb.length >= 4 ? rgb[3].clamp(0, 255) : fallbackAlpha;
    return Color.fromARGB(
      alpha,
      rgb[0].clamp(0, 255).toInt(),
      rgb[1].clamp(0, 255).toInt(),
      rgb[2].clamp(0, 255).toInt(),
    );
  }

  // ── S8: editing ─────────────────────────────────────────────────────────────

  /// The currently selected block, or null.
  TextBlock? get _currentBlock {
    final key = _selectedPageKey;
    if (key == null) return null;
    final page = _project?.pages[key];
    if (page == null) return null;
    final index = _selectedBlock;
    if (index < 0 || index >= page.blocks.length) return null;
    return page.blocks[index];
  }

  TextBlock? _blockAt(String pageKey, int index) {
    final page = _project?.pages[pageKey];
    if (page == null) return null;
    if (index < 0 || index >= page.blocks.length) return null;
    return page.blocks[index];
  }

  void _selectBlock(String pageKey, int index) {
    setState(() {
      _selectedPageKey = index < 0 ? null : pageKey;
      _selectedBlock = index;
    });
  }

  /// Applies [mutate] to one block, records it as a single undo step, and
  /// rebuilds. [syncRichText] regenerates FT's `rich_text` payload, which is
  /// mandatory for text/lettering edits (see `rich_text_sync.dart`).
  void _editBlock(
    String pageKey,
    int index,
    String label,
    void Function(TextBlock block) mutate, {
    bool syncRichText = false,
  }) {
    final block = _blockAt(pageKey, index);
    if (block == null) return;
    final command = captureBlockEdit(
      block.raw,
      () {
        mutate(block);
        if (syncRichText) syncFtRichText(block);
      },
      pageKey: pageKey,
      label: label,
    );
    if (command.isEmpty) return;
    _history.push(command);
    setState(() => _revision++);
  }

  /// Records a finished drag: the block moves by the same delta in `xyxy`, and
  /// the whole drag is one undo step (the canvas only reports on drag end).
  void _moveBlock(
    String pageKey,
    int index,
    Offset oldTopLeft,
    Offset newTopLeft,
  ) {
    final dx = newTopLeft.dx - oldTopLeft.dx;
    final dy = newTopLeft.dy - oldTopLeft.dy;
    if (dx.abs() < 0.5 && dy.abs() < 0.5) return;
    _editBlock(pageKey, index, 'Move block', (block) {
      final box = block.xyxy;
      block.xyxy = [box[0] + dx, box[1] + dy, box[2] + dx, box[3] + dy];
    });
  }

  /// Records a finished resize: `xyxy` becomes [newRect] outright rather than
  /// being accumulated, so the result matches exactly what the user saw during
  /// the drag (the canvas previews with the same clamp rules).
  ///
  /// One undo step, for the same reason as [_moveBlock].
  void _resizeBlock(String pageKey, int index, Rect oldRect, Rect newRect) {
    // A sub-pixel change is almost always a stray click on a handle, and
    // committing it would put a no-op entry on the undo stack — which then
    // makes Ctrl+Z appear to do nothing, which is worse than not recording it.
    if ((newRect.left - oldRect.left).abs() < 0.5 &&
        (newRect.top - oldRect.top).abs() < 0.5 &&
        (newRect.width - oldRect.width).abs() < 0.5 &&
        (newRect.height - oldRect.height).abs() < 0.5) {
      return;
    }
    _editBlock(pageKey, index, 'Resize block', (block) {
      block.xyxy = [
        newRect.left,
        newRect.top,
        newRect.right,
        newRect.bottom,
      ];
    });
  }

  void _deleteSelectedBlock() {
    final pageKey = _selectedPageKey;
    final index = _selectedBlock;
    if (pageKey == null) return;
    final page = _project?.pages[pageKey];
    if (page == null || index < 0 || index >= page.blocks.length) return;
    final block = page.blocks[index];
    final command = captureBlockListEdit(
      page.rawBlocks,
      () => page.removeBlock(block),
      pageKey: pageKey,
      label: 'Delete block',
    );
    if (command.isEmpty) return;
    _history.push(command);
    setState(() {
      _selectedBlock = -1;
      _selectedPageKey = null;
      _revision++;
    });
  }

  /// Creates a blank block on the current page, selects it, and puts it on the
  /// undo stack (S8 leftover, P9.3).
  ///
  /// ## Placement
  ///
  /// The block lands at a **fraction of the page** (centre horizontally, upper
  /// third vertically) rather than at a pixel constant, because `xyxy` is in
  /// source pixels while the canvas is scaled — a fixed pixel size would be a
  /// postage stamp on a hi-res page and oversized on a small one. Speech
  /// balloons live in the upper third, and a box dropped in the middle of the
  /// art is easy to lose against a busy background.
  ///
  /// ## Two ways in
  ///
  /// This button is the **keyboard-free fallback**. The primary path is the
  /// marquee mode next to it: drag a box exactly where the text goes. The
  /// button exists because marquee needs a non-touch-friendly pointer for
  /// precise work, and because "I just need a block here" should not require
  /// entering a mode.
  ///
  /// ## One undo step
  ///
  /// `captureBlockListEdit` snapshots the whole list — the same path delete
  /// uses, so create and delete are symmetric and neither can drift.
  void _createBlock() {
    _createBlockAt(null);
  }

  /// Creates a block at [rect] (page pixels), or at the default spot when null.
  ///
  /// Both entry points funnel through here so a marquee-created block and a
  /// button-created block are **byte-identical** except for geometry — no second
  /// construction path that could drift.
  void _createBlockAt(Rect? rect) {
    final project = _project;
    if (project == null || _pageKeys.isEmpty) return;
    final pageKey = _pageKeys[_pageIndex];
    final page = project.pages[pageKey];
    if (page == null) return;

    final box = rect ?? _defaultBlockRect(pageKey);
    final block = TextBlock.createDefault(
      rect: IntRect(
        box.left.round(),
        box.top.round(),
        box.right.round(),
        box.bottom.round(),
      ),
    );
    final command = captureBlockListEdit(
      page.rawBlocks,
      () => page.addBlock(block),
      pageKey: pageKey,
      label: 'Create block',
    );
    if (command.isEmpty) return;
    // 🔴 Select by identity, not by `blocks.length - 1`:
    // [ProjectPage.blocks] skips raw entries that are not JSON objects (the
    // model tolerates a hand-edited file containing them), so the typed view
    // can be shorter than the raw list and the last *typed* index is not
    // necessarily the one just appended. Every selection helper indexes into
    // `blocks`, so picking the wrong index would select a neighbour instead of
    // the block the user just made.
    _history.push(command);
    final selected = page.blocks.indexWhere((b) => identical(b.raw, block.raw));
    setState(() {
      _selectedPageKey = pageKey;
      _selectedBlock = selected < 0 ? page.blocks.length - 1 : selected;
      _revision++;
    });
  }

  /// Where [_createBlock] puts a block when the user did not drag one out.
  Rect _defaultBlockRect(String pageKey) {
    final pageSize = _pageSizeInPixels(pageKey);
    const widthFraction = 0.42;
    const heightFraction = 0.09;
    // 🔴 `clamp` on a `double` yields `num`, and a degenerate page (a 1px
    // `image_info` entry) would otherwise collapse the box to nothing and put
    // an unletterable sliver on the canvas. Clamp against the minimum first,
    // then against the page, and coerce back to double explicitly.
    final boxWidth = (pageSize.width * widthFraction)
        .round()
        .clamp(48, pageSize.width)
        .toDouble();
    final boxHeight = (pageSize.height * heightFraction)
        .round()
        .clamp(24, pageSize.height)
        .toDouble();
    final left = (pageSize.width - boxWidth) / 2;
    final top = (pageSize.height - boxHeight) / 3;
    return Rect.fromLTWH(left, top, boxWidth, boxHeight);
  }

  /// The page's pixel dimensions from FT's own `image_info`.
  ///
  /// Falls back to a portrait A4-ish shape when the entry is missing or
  /// nonsensical, because a zero-sized page would collapse every created box to
  /// nothing and there would be no diagnostic.
  Size _pageSizeInPixels(String pageKey) {
    final info = _project?.imageInfo[pageKey];
    final width = info is Map ? (info['width'] as num?)?.toDouble() : null;
    final height = info is Map ? (info['height'] as num?)?.toDouble() : null;
    if (width == null || height == null || width <= 0 || height <= 0) {
      return const Size(1200, 1800);
    }
    return Size(width, height);
  }

  void _undo() {
    if (!_history.undo()) return;
    setState(() => _revision++);
  }

  void _redo() {
    if (!_history.redo()) return;
    setState(() => _revision++);
  }

  /// Ctrl+S: the unified save contract (P6 §2.8).
  ///
  /// The JSON is written atomically and synchronously; `mask/` and `inpainted/`
  /// are this project's inputs and are left as they are; `result/` is
  /// regenerated in the background because re-lettering 97 pages is expensive
  /// and must not block the editor.
  ///
  /// 🔴 The regeneration is **incremental** (P9.1 §2): the set of dirty pages is
  /// sampled *before* [EditHistory.markSaved], because marking the project
  /// saved is exactly what makes those pages clean. Sampling afterwards would
  /// always yield an empty set and silently degrade back to "render nothing",
  /// leaving `result/` permanently stale — the same silent-divergence class of
  /// bug this layer keeps hitting. Passing `dirtyPages` as [ProjectWriter
  /// .writeArtifacts]'s `filter` turns "one page changed" into "one page
  /// re-lettered" instead of re-rendering the whole chapter.
  ///
  /// Returns whether the JSON reached disk. [showMessage] fires on both
  /// outcomes; the `false` case exists for "save then leave" ([_leaveGuard]),
  /// where leaving on a failed write would drop the edits the user was told
  /// were safe.
  Future<bool> _save() async {
    final project = _project;
    if (project == null) return false;
    final messenger = context;
    try {
      // Snapshot first — `markSaved` below clears the dirty set by design.
      final dirtyPages = _history.dirtyPages;
      final report = await ProjectWriter.save(
        root: project.workspace,
        project: project,
        keepBackup: true,
      );
      _history.markSaved();
      // The reader caches rendered BT pages under `@bt:` keys; notifying the
      // local-comic store drops them so the reader shows the new lettering.
      if (LocalManager().isInitialized) LocalManager().notifyListeners();
      if (!mounted) return true;
      messenger.showMessage(
        message: 'Saved @a (@b B)'.tlParams({
          'a': report.jsonFile.path,
          'b': report.bytes,
        }),
      );
      setState(() {});
      unawaited(_regenerateResults(dirtyPages: dirtyPages));
      return true;
    } catch (e, s) {
      Log.error('Translation Studio', 'Save failed', s);
      if (!mounted) return false;
      messenger.showMessage(message: 'Save failed: @a'.tlParams({'a': e}));
      return false;
    }
  }

  /// The [LeaveGuardRegistry] callback: "may this screen go away?"
  ///
  /// Clean project → `true` with no dialog. Dirty → the three-way prompt, and
  /// `saveAndLeave` writes first and only reports success if the write landed.
  ///
  /// Re-entrancy: a second trigger while the dialog is open awaits the same
  /// future. That matters because the registry can be consulted by two
  /// different leave paths in the same frame (e.g. Back, then the title-bar
  /// close button) and two stacked dialogs would each hold a "leave" answer.
  Future<bool> _leaveGuard() {
    return _leaveCheckInFlight ??= _resolveLeave().whenComplete(() {
      _leaveCheckInFlight = null;
    });
  }

  Future<bool> _resolveLeave() async {
    if (!_history.isDirty) return true;
    if (!mounted) return false;
    final choice = await showUnsavedChangesDialog(
      context: context,
      title: 'Unsaved changes'.tl,
      content: 'This project has edits that are not saved yet.'.tl,
    );
    switch (choice) {
      case UnsavedChangesChoice.cancel:
        return false;
      case UnsavedChangesChoice.discard:
        // Drop the history so the pending pop cannot be re-vetoed by
        // `isDirty` on a second, imperative pass (see `_onLeaveAllowed`).
        _history.clear();
        return true;
      case UnsavedChangesChoice.saveAndLeave:
        // `mounted` can go false while the dialog is up; saving is still
        // correct (it only touches the model and disk), and the pop that
        // follows is the caller's business.
        final saved = await _save();
        // A failed write must not read as "go ahead" — the edits are still
        // only in memory, and leaving now is exactly the data loss this
        // prompt exists to prevent.
        if (!saved && mounted) setState(() {});
        return saved;
      default:
        return false;
    }
  }

  /// Re-issues the pop that [PopScope] blocked, once the guard has approved.
  ///
  /// This is the `onPopInvokedWithResult(didPop: false)` half of the contract:
  /// the cancelled attempt is *not* retried by the framework, so the approved
  /// pop has to be issued explicitly.
  Future<void> _attemptLeave() async {
    final navigator = Navigator.of(context);
    if (!await _leaveGuard()) return;
    if (!mounted) return;
    // Re-check the live state instead of trusting the guard's answer: the
    // project may still be dirty (a failed save leaves it dirty), and popping
    // anyway would drop the edits behind the user's back.
    if (_history.isDirty) return;
    if (navigator.canPop()) navigator.pop();
  }

  /// Re-letters `result/` in the background.
  ///
  /// [dirtyPages] limits the work to the pages that actually changed since the
  /// last save. A **null** value means "render everything", which is what a
  /// caller with no dirty-page information must ask for; an **empty** set is a
  /// legitimate answer ("the user undid back to the saved state") and must not
  /// be conflated with "no idea, render everything".
  Future<void> _regenerateResults({Set<String>? dirtyPages}) async {
    final project = _project;
    if (project == null) return;
    setState(() => _renderingResults = true);
    try {
      bool Function(String)? filter =
          dirtyPages == null ? null : (key) => dirtyPages.contains(key);
      // 🔴 两阶段，顺序不可交换：`result/` 的渲染以 `inpainted/` 为**输入**
      // 位图，而 `writeArtifacts` 内部是并发 worker —— 把两者放进同一次调用，
      // 结果会读到还没写出来的底图（或被记成 skipped，且只在数据量小的时候
      // 侥幸成功）。先同步写完底图，再渲染成品。
      //
      // 底图这一阶段是 S9.5-a 补的一场欠账：契约（P6 §2.8）早就把
      // `mask/` + `inpainted/` 定为"保存时同步产出"，但 S8 把它推迟给 S9、
      // S9 又没捡回来，于是**没有任何代码生产 `inpainted/`** → `result/`
      // 永远 0 张且不报错（证据见 `renderInpaintedPage` 的文档）。
      final bases = await ProjectWriter.writeArtifacts(
        root: project.workspace,
        project: project,
        kinds: const {ProjectArtifactKind.inpainted},
        filter: filter,
        concurrency: 2,
        source: (kind, pageKey) => renderInpaintedPage(project, pageKey),
      );
      final report = await ProjectWriter.writeArtifacts(
        root: project.workspace,
        project: project,
        kinds: const {ProjectArtifactKind.result},
        filter: filter,
        concurrency: 2,
        source: (kind, pageKey) => renderProjectResultPage(project, pageKey),
      );
      Log.info(
        'Translation Studio',
        'artifacts regenerated: inpainted=$bases result=$report '
        '(dirty=${dirtyPages?.length ?? 'all'})',
      );
    } catch (e, s) {
      Log.error('Translation Studio', 'result regeneration failed', s);
    } finally {
      if (mounted) setState(() => _renderingResults = false);
    }
  }

  /// Copies the project's finished pages into `ComicLibrary/translated/` and
  /// registers the result as its own local comic, grouped with the original
  /// under one `tabs` card (P6 §2.10 / §2.9(c)).
  Future<void> _publish() async {
    final project = _project;
    if (project == null) return;
    final libraryRoot = LocalManager().path;
    if (libraryRoot.isEmpty) {
      context.showMessage(message: 'Local library is not ready yet.'.tl);
      return;
    }
    final translatedRoot = FilePath.join(
      Directory(libraryRoot).parent.path,
      'translated',
    );
    final comicName = FinishedExport.comicNameFor(project);
    String? sourceComicId;
    for (final comic in LocalManager().getComics(LocalSortType.defaultSort)) {
      // A `bt_` row is the editable project, not the original artwork, so it
      // must not be picked as the collection's source member.
      if (comic.id.startsWith(FinishedExport.btProjectIdPrefix)) continue;
      if (comic.directory.replaceAll('\\', '/') == project.directory) {
        sourceComicId = comic.id;
        break;
      }
    }
    final progress = showLoadingDialog(
      context,
      message: 'Publishing…'.tl,
      barrierDismissible: false,
      allowCancel: false,
      withProgress: true,
    );
    FinishedExportReport report;
    try {
      report = await FinishedExport.publish(
        project: project,
        translatedRoot: translatedRoot,
        comicName: comicName,
        sourceComicId: sourceComicId,
        onProgress: (done, total) {
          if (total > 0) progress.setProgress(done / total);
        },
      );
    } catch (e, s) {
      Log.error('Translation Studio', 'Publish failed', s);
      progress.close();
      if (mounted) {
        context.showMessage(
          message: 'Publish failed: @a'.tlParams({'a': e}),
        );
      }
      return;
    }
    progress.close();
    if (!mounted) return;
    context.showMessage(
      message: report.ok
          ? 'Published @a pages to @b'.tlParams({
              'a': report.copied,
              'b': report.directory,
            })
          : 'Nothing published (@a)'.tlParams({'a': report.error ?? report.directory}),
    );
  }

  @override
  Widget build(BuildContext context) {
    final project = _project;
    final dirty = _history.isDirty;
    // `canPop` is the *only* thing `PopScope` contributes: it makes the first
    // Back press a no-op so `onPopInvokedWithResult` fires and we can ask.
    // The approved pop itself goes through `Navigator.pop`, which is
    // imperative and therefore not re-vetoed by `canPop` (P9.2 §2.2).
    return PopScope<Object?>(
      canPop: !dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        unawaited(_attemptLeave());
      },
      child: Scaffold(
        appBar: AppBar(
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  (_title.isEmpty ? 'Translation Studio'.tl : _title) +
                      (dirty ? ' •' : ''),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          actions: [
            // ── S9 · P1-5: 自动管线 ──────────────────────────────────
            // 单页 / 整章 / 停止。三件事而不是一个"运行"按钮，因为它们的
            // 代价差一个数量级：单页是"这一格没跑"，整章是"整本重跑一遍"。
            // 停止在跑的时候顶替整章按钮的位置 —— 放在原处不动，用户得在
            // 一排图标里找那一个会变的。
            Builder(
              builder: (context) {
                final running = _pipeline.running;
                return running
                    ? IconButton(
                        tooltip: 'Stop pipeline'.tl,
                        icon: Icon(Icons.stop_circle_outlined,
                            color: context.colorScheme.error),
                        onPressed: _stopPipeline,
                      )
                    : IconButton(
                        tooltip: 'Run pipeline on this page'.tl,
                        icon: const Icon(Icons.play_arrow),
                        onPressed: project == null
                            ? null
                            : () => _runPipelineCurrentPage(),
                      );
              },
            ),
            Builder(
              builder: (context) {
                final running = _pipeline.running;
                return IconButton(
                  tooltip: 'Run pipeline on the whole chapter'.tl,
                  icon: const Icon(Icons.playlist_play),
                  onPressed: project == null || running
                      ? null
                      : () => _runPipelineAllPages(),
                );
              },
            ),
            // 🔴 S9 · P9.7: 续跑按钮**只在真的有断点时出现**。
            // 常驻一个禁用的"继续"等于多一个要读的按钮；而断点的语义是
            // "上一轮没跑完"，那是一个偶发状态，不是一种模式。
            if (_pipelineResumeFrom != null && !_pipeline.running)
              IconButton(
                tooltip: 'Resume from page @a'.tlParams({
                  'a': '${_pageKeys.indexOf(_pipelineResumeFrom!) + 1}',
                }),
                icon: Icon(Icons.play_circle_outline,
                    color: context.colorScheme.primary),
                onPressed: project == null ? null : _resumePipeline,
              ),
            IconButton(
              tooltip: 'Create block'.tl,
              icon: const Icon(Icons.add_comment_outlined),
              onPressed: project == null ? null : _createBlock,
            ),
            // 🔴 Marquee mode: the primary way to place a block, because it puts
            // the box exactly where the text goes instead of at a default spot
            // the user then has to drag. Kept as a mode (not "drag on empty
            // space") so it can never hijack the move gesture.
            //
            // Each state is its own button so both icon references are `const`
            // (`Icons.crop` 0xe1a3 and `Icons.crop_outlined` 0xef9a are both
            // present in the shipped font subset — this is style, not a fix).
            //
            // 🔴 The active state must be unmistakable. Relying on
            // `IconButton.isSelected` alone left the button looking identical
            // to every other action, so users could not tell that marquee mode
            // was armed — the complaint that it "shows nothing when active".
            // The tinted container plus a filled-vs-outlined icon gives two
            // independent cues, and the tooltip says which click will do.
            Builder(
              builder: (context) {
                final active = _marqueeMode;
                return Tooltip(
                  message: active
                      ? 'Cancel box draw'.tl
                      : 'Draw box for new block'.tl,
                  child: IconButton(
                    isSelected: active,
                    style: active
                        ? IconButton.styleFrom(
                            backgroundColor:
                                context.colorScheme.primaryContainer,
                            foregroundColor:
                                context.colorScheme.onPrimaryContainer,
                          )
                        : null,
                    icon: Icon(
                      active ? Icons.crop : Icons.crop_outlined,
                      color: active
                          ? context.colorScheme.onPrimaryContainer
                          : null,
                    ),
                    onPressed: project == null
                        ? null
                        : () => setState(() => _marqueeMode = !active),
                  ),
                );
              },
            ),
            IconButton(
              tooltip: 'Undo (Ctrl+Z)'.tl,
              icon: const Icon(Icons.undo),
              onPressed: _history.canUndo ? _undo : null,
            ),
            IconButton(
              tooltip: 'Redo (Ctrl+Y)'.tl,
              icon: const Icon(Icons.redo),
              onPressed: _history.canRedo ? _redo : null,
            ),
            // 🔴 A dirty project means unsaved edits, so the save button says so with
            // colour as well as shape — the filled/outlined pair alone is easy
            // to miss in a row of eight identical-looking buttons.
            Builder(
              builder: (context) {
                final dirty = _history.isDirty;
                return IconButton(
                  tooltip: 'Save (Ctrl+S)'.tl,
                  icon: Icon(
                    dirty ? Icons.save : Icons.save_outlined,
                    color: dirty ? context.colorScheme.primary : null,
                  ),
                  onPressed: project == null
                      ? null
                      : () => unawaited(_save()),
                );
              },
            ),
            // Strip vs single-page: the two ways to move through a project.
            Builder(
              builder: (context) {
                final strip = _stripMode;
                return IconButton(
                  tooltip: strip
                      ? 'Single page + zoom'.tl
                      : 'Continuous strip'.tl,
                  isSelected: strip,
                  style: strip
                      ? IconButton.styleFrom(
                          backgroundColor: context.colorScheme.secondaryContainer,
                          foregroundColor:
                              context.colorScheme.onSecondaryContainer,
                        )
                      : null,
                  icon: Icon(
                    strip ? Icons.crop_portrait : Icons.view_agenda_outlined,
                    color: strip
                        ? context.colorScheme.onSecondaryContainer
                        : null,
                  ),
                  onPressed: project == null
                      ? null
                      : () => setState(() => _stripMode = !strip),
                );
              },
            ),
            IconButton(
              tooltip: 'Publish finished product'.tl,
              icon: const Icon(Icons.outbox_outlined),
              onPressed: project == null ? null : _publish,
            ),
            IconButton(
              tooltip: 'Continuous preview'.tl,
              icon: const Icon(Icons.view_carousel_outlined),
              onPressed: project == null
                  ? null
                  : () => context.to(
                      () => StudioPreviewPage(
                        project: project,
                        pageKeys: _pageKeys,
                        startIndex: _pageIndex,
                      ),
                    ),
            ),
          ],
        ),
        body: _shortcuts(
          project == null
              ? Center(
                  child: Text(
                    _error.isEmpty ? 'Loading...'.tl : _error,
                    style: ts.s16,
                  ),
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    // 属性面板要放下三档对齐、9 项颜色分级、两行文字框，太窄会
                    // 挤成一团（用户反馈："右侧显示太小了，太挤了"）。分档给宽
                    // 度，并且只有真的放得下三栏时才并排 —— 否则画布被压到无法
                    // 审校，那正是这个页面存在的意义。
                    final panelWidth = constraints.maxWidth >= 1600 ? 400.0 : 340.0;
                    final wide = constraints.maxWidth >= 1180;
                    final canvas = _buildCanvas();
                    final panel = _buildPanel();
                    if (!wide) {
                      return Column(
                        children: [
                          Expanded(child: canvas),
                          SizedBox(
                            height: 180,
                            child: _buildPageRail(horizontal: true),
                          ),
                          SizedBox(height: 320, child: panel),
                        ],
                      );
                    }
                    return Row(
                      children: [
                        SizedBox(width: 156, child: _buildPageRail()),
                        const VerticalDivider(width: 1),
                        Expanded(child: canvas),
                        const VerticalDivider(width: 1),
                        SizedBox(width: panelWidth, child: panel),
                      ],
                    );
                  },
                ),
        ),
      ),
    );
  }

  /// Keyboard bindings: Ctrl+S save, Ctrl+Z undo, Ctrl+Y / Ctrl+Shift+Z redo.
  ///
  /// Wrapped in a focusable node so the page receives keys without the user
  /// having to click the canvas first (text fields keep their own editing keys,
  /// since a focused `TextField` consumes them before they bubble up).
  Widget _shortcuts(Widget child) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): () {
          if (_project != null) unawaited(_save());
        },
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): _undo,
        const SingleActivator(LogicalKeyboardKey.keyY, control: true): _redo,
        const SingleActivator(
          LogicalKeyboardKey.keyZ,
          control: true,
          shift: true,
        ): _redo,
      },
      child: Focus(autofocus: true, child: child),
    );
  }

  Widget _buildCanvas() {
    final key = _pageKeys.isEmpty ? null : _pageKeys[_pageIndex];
    return Column(
      children: [
        Expanded(
          child: _stripMode
              // 连续长画布：整章一路滚下去，页内可点选/拖拽文本框。
              // 翻到哪一页由 strip 回报，页轨/页码随之同步。
              ? StudioScrollCanvas(
                  key: _stripKey,
                  controller: _stripController,
                  pages: _stripPages(),
                  blocksFor: _blocksFor,
                  editable: true,
                  onSelect: _selectBlock,
                  onMoveBlock: _moveBlock,
                  onResizeBlock: _resizeBlock,
                  onMarquee: (pageKey, rect) => _onMarquee(rect),
                  marqueeMode: _marqueeMode,
                  onEditText: (pageKey, index) =>
                      _selectBlock(pageKey, index),
                  onPageChanged: (index) {
                    if (index == _pageIndex) return;
                    setState(() {
                      _pageIndex = index;
                      // 🔴 P9.7: 与 [_selectPage] 同一条规则 —— 滚动翻页也是
                      // 翻页。这里以前只改页码，于是长画布模式下"上一页开的
                      // 框选模式"会跟着滚到下一页继续生效。
                      _marqueeMode = false;
                    });
                  },
                )
              : InteractiveViewer(
                  minScale: 0.2,
                  maxScale: 8,
                  child: Center(
                    child: EditableTextBlockCanvas(
                      blocks: _canvasBlocks,
                      selectedIndex: _selectedBlock,
                      onSelect: (index) => _selectBlock(key ?? '', index),
                      onMoveBlock: (index, oldTopLeft, newTopLeft) {
                        if (key != null) {
                          _moveBlock(key, index, oldTopLeft, newTopLeft);
                        }
                      },
                      onResizeBlock: (index, oldRect, newRect) {
                        if (key != null) {
                          _resizeBlock(key, index, oldRect, newRect);
                        }
                      },
                      onMarquee: (rect) => _onMarquee(rect),
                      marqueeMode: _marqueeMode,
                      onEditText: (index) => _selectBlock(key ?? '', index),
                      base: _base,
                      loading: _loadingBase,
                    ),
                  ),
                ),
        ),
        _buildStatusBar(key),
      ],
    );
  }

  Widget _buildStatusBar(String? key) {
    final scheme = Theme.of(context).colorScheme;
    final page = _currentPage;
    final blocks = page?.blocks.length ?? 0;
    final translated = page?.translatedBlocks.length ?? 0;
    // In strip mode nothing is "loaded" into [_base]; report what the strip is
    // actually showing for the current page instead of a stale "no image".
    final String kind;
    if (_stripMode) {
      final file = key == null ? null : _resolvePageFile(key);
      if (file == null) {
        kind = 'no image'.tl;
      } else {
        // A path can be relative to CWD, so compare normalized forms rather
        // than assuming both sides are absolute.
        final isOriginal = _samePath(
          file.path,
          _project?.originalPath(key ?? ''),
        );
        kind = (isOriginal ? 'original' : 'artifact').tl;
      }
    } else {
      kind = (_base == null
              ? 'no image'
              : (_base!.fromInpainted ? 'inpainted' : 'original'))
          .tl;
    }
    final total = _pageKeys.length;
    final current = _pageKeys.isEmpty ? 0 : _pageIndex + 1;
    return Container(
      width: double.infinity,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: DefaultTextStyle(
        style: ts.s14.copyWith(color: scheme.onSurfaceVariant),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Previous page'.tl,
              onPressed: current > 1 ? () => _selectPage(_pageIndex - 1) : null,
              icon: const Icon(Icons.chevron_left),
            ),
            // A 200-page project is unusable without a jump box, and the rail
            // on the left is a strip of thumbnails rather than a pager.
            InkWell(
              onTap: total == 0 ? null : _promptPage,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Text(
                  'Page @a of @b'.tlParams({'a': current, 'b': total}),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Next page'.tl,
              onPressed: current < total ? () => _selectPage(_pageIndex + 1) : null,
              icon: const Icon(Icons.chevron_right),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                key ?? '',
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text('base: @a'.tlParams({'a': kind})),
            const SizedBox(width: 16),
            Text(
              'blocks: @a / @b'.tlParams({'a': translated, 'b': blocks}),
            ),
            const SizedBox(width: 16),
            // 🔴 管线进度放在状态栏而不是只放在对话框里：整章运行要几十秒到
            // 几分钟，一个模态对话框会挡住画布，而**看块出现在画布上**正是
            // 用户判断"跑得对不对"的唯一手段。
            if (_pipeline.running) ...[
              SizedBox(
                width: 110,
                child: LinearProgressIndicator(
                  value: _pipeline.total == 0
                      ? 0
                      : _pipeline.done / _pipeline.total,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '@a / @b'.tlParams({
                  'a': '${_pipeline.done}',
                  'b': '${_pipeline.total}',
                }),
                style: ts.s12,
              ),
              const SizedBox(width: 12),
            ],
            if (_pipeline.lastMessage.isNotEmpty)
              Flexible(
                child: Text(
                  _pipeline.lastMessage,
                  style: ts.s12.copyWith(
                    color: _pipeline.failures > 0 ? scheme.error : null,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            if (_renderingResults)
              Text('rendering result…'.tl, style: ts.s12)
            else if (_history.isDirty)
              Text('unsaved'.tl, style: ts.s12),
          ],
        ),
      ),
    );
  }

  Future<void> _promptPage() async {
    final controller = TextEditingController(text: '${_pageIndex + 1}');
    final result = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Go to page'.tl),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: 'Page number (1 - @n)'.tlParams({'n': _pageKeys.length}),
          ),
          onSubmitted: (value) {
            final parsed = int.tryParse(value.trim());
            if (parsed != null) Navigator.of(ctx).pop(parsed);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('Cancel'.tl),
          ),
          TextButton(
            onPressed: () {
              final parsed = int.tryParse(controller.text.trim());
              if (parsed != null) Navigator.of(ctx).pop(parsed);
            },
            child: Text('OK'.tl),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null) return;
    _selectPage(result - 1);
  }

  Widget _buildPageRail({bool horizontal = false}) {
    final project = _project;
    if (project == null) return const SizedBox.shrink();
    final children = <Widget>[];
    for (var i = 0; i < _pageKeys.length; i++) {
      final key = _pageKeys[i];
      final page = project.pages[key];
      final total = page?.blocks.length ?? 0;
      final done = page?.translatedBlocks.length ?? 0;
      children.add(
        _PageTile(
          // Falls back to `inpainted`/`mask` so the rail still renders for a
          // project whose raw comic folder is gone.
          file: _resolvePageFile(key) ?? File(project.originalPath(key)),
          label: '${i + 1}',
          selected: i == _pageIndex,
          complete: total > 0 && done == total,
          partial: done > 0 && done < total,
          onTap: () => _selectPage(i),
        ),
      );
    }
    if (horizontal) {
      return ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: children.length,
        itemBuilder: (_, i) => SizedBox(width: 96, child: children[i]),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: children.length,
      itemBuilder: (_, i) => children[i],
    );
  }

  Widget _buildPanel() {
    final project = _project;
    final block = _currentBlock;
    if (block != null) {
      // Keyed by selection so a new block starts a fresh text controller; edits
      // to the same block reuse it and follow the model through [_revision].
      return StudioBlockPanel(
        key: ValueKey('${_selectedPageKey ?? ''}#$_selectedBlock'),
        block: block,
        index: _selectedBlock,
        revision: _revision,
        onEdit: (label, mutate, {bool syncRichText = false}) {
          final pageKey = _selectedPageKey;
          if (pageKey == null) return;
          _editBlock(
            pageKey,
            _selectedBlock,
            label,
            mutate,
            syncRichText: syncRichText,
          );
        },
        onDelete: _deleteSelectedBlock,
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        Text('Page'.tl, style: ts.s16),
        const SizedBox(height: 8),
        _kv('Source root', project?.directory ?? '-', small: true),
        _kv('Artifact root', project?.workspace ?? '-', small: true),
        _kv(
          'Layout',
          (project?.isInPlaceLayout ?? true) ? 'in-place'.tl : 'split'.tl,
          small: true,
        ),
        const Divider(height: 28),
        _buildPipelinePanel(context),
        const Divider(height: 28),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Text(
            'Tap a text block on the canvas to edit it.'.tl,
            style: ts.s14,
          ),
        ),
      ],
    );
  }

  /// 管线选项面板（未选中块时显示在属性面板位置）。
  ///
  /// 🔴 三项都是**会话内**状态，不落 `appdata`、不写工程 json：它们描述的是
  /// "这一次怎么跑"，写进工程会让零字节 diff 立刻破掉。
  Widget _buildPipelinePanel(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final running = _pipeline.running;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Automatic pipeline'.tl, style: ts.s16),
        const SizedBox(height: 4),
        Text(
          // 🔴 Single literal, never two adjacent quoted strings with the
          // translation call on the second. Dart concatenates adjacent literals
          // at parse time, so the lookup key would be the *joined* string while
          // the i18n scan (`i18n.studio_tooltips_registered`) matches each
          // quoted run separately and would demand the trailing fragment be a
          // key of its own. Registering that fragment would satisfy the check
          // while the real key stayed untranslated — a green light on an
          // English label. `studio_block_panel.dart` still has two such
          // fragments from S8; the widened scan is what surfaced them.
          'Detects text, reads it and fills the translation. Results are written into this project as editable blocks.'.tl,
          style: ts.s12.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 10),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text('Translate too'.tl, style: ts.s14),
          subtitle: Text(
            'Off = detect and read only, so the layout can be checked before spending a translation request.'.tl,
            style: ts.s12,
          ),
          value: _pipelineTranslate,
          onChanged: running
              ? null
              : (v) => setState(() => _pipelineTranslate = v),
        ),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text('Skip blocks that already exist'.tl, style: ts.s14),
          subtitle: Text(
            'On = a detected balloon that overlaps an existing block is left alone, so reviewed work is never overwritten.'.tl,
            style: ts.s12,
          ),
          value: _pipelineSkipExisting,
          onChanged: running
              ? null
              : (v) => setState(() => _pipelineSkipExisting = v),
        ),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text('Read right to left'.tl, style: ts.s14),
          subtitle: Text(
            'On for Japanese manga. Off for western/vertical-scroll pages.'.tl,
            style: ts.s12,
          ),
          value: _pipelineRightToLeft,
          onChanged: running
              ? null
              : (v) => setState(() => _pipelineRightToLeft = v),
        ),
        const SizedBox(height: 8),
        if (_pipeline.lastMessage.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              _pipeline.lastMessage,
              style: ts.s12.copyWith(
                color: _pipeline.failures > 0 ? scheme.error : null,
              ),
            ),
          ),
        // 🔴 失败/部分成功必须给一个**下一步**，而不只是一句汇报：漏检的块
        // 没有自动补救手段，用户只能手工补 —— 那是 Create 块按钮（P9.3），
        // 所以这里明确指向它，而不是让用户自己猜。
        if (_pipeline.done > 0 && _pipeline.skipped > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              '@a text lines were skipped. Use "Create block" or "Draw box for new block" to add anything the detector missed.'.tlParams({
                'a': '${_pipeline.skipped}',
              }),
              style: ts.s12.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        Row(
          children: [
            FilledButton.icon(
              onPressed: running ? null : _runPipelineCurrentPage,
              icon: const Icon(Icons.play_arrow, size: 18),
              label: Text('Run this page'.tl),
            ),
            const SizedBox(width: 10),
            OutlinedButton.icon(
              onPressed: running ? null : _runPipelineAllPages,
              icon: const Icon(Icons.playlist_play, size: 18),
              label: Text('Run chapter'.tl),
            ),
            if (running) ...[
              const SizedBox(width: 10),
              TextButton.icon(
                onPressed: _stopPipeline,
                icon: const Icon(Icons.stop, size: 18),
                label: Text('Stop'.tl),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _kv(String key, String value, {bool small = false}) {
    final style = small ? ts.s12 : ts.s14;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            key.tl,
            style: style.copyWith(
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          Text(value, style: style),
        ],
      ),
    );
  }
}

/// 一组可变字段而不是 `setState` 上的十几个单独字段。
///
/// 理由是进度刷新频率高（每页一次），而每个字段各自 `setState` 会在连续
/// 多次 `setState` 里反复重建整棵画布树。合成一个对象后一次 `setState`
/// 就够，且 [_pipeline] 的存在本身就能当"管线在跑"的判据。
class _StudioPipelineState {
  bool running = false;
  int done = 0;
  int total = 0;

  /// 已写进工程的块数。
  int blocks = 0;

  /// 被跳过的检测行数（漏检的第一手线索）。
  int skipped = 0;

  /// 处理失败的页数。
  int failures = 0;

  /// 正在处理的页 key。
  String current = '';

  /// 非空表示可取消。
  CancellationToken? cancel;

  /// 状态栏/进度卡上的一句话。
  String lastMessage = '';
}

class _PageTile extends StatelessWidget {
  const _PageTile({
    required this.file,
    required this.label,
    required this.selected,
    required this.complete,
    required this.partial,
    required this.onTap,
  });

  final File file;
  final String label;
  final bool selected;
  final bool complete;
  final bool partial;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 2 : 0.5,
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (file.existsSync())
              Padding(
                padding: const EdgeInsets.all(2),
                child: Image.file(
                  file,
                  fit: BoxFit.contain,
                  // Decoding a 2000px page for a 96px tile is the single
                  // easiest way to make a long project stutter.
                  cacheWidth: 96,
                  filterQuality: FilterQuality.low,
                  errorBuilder: (context, error, stackTrace) =>
                      const SizedBox.shrink(),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(Icons.broken_image_outlined, size: 20, color: scheme.outline),
              ),
            Positioned(
              left: 2,
              bottom: 2,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: scheme.surface.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(label, style: ts.s12),
              ),
            ),
            Positioned(
              right: 2,
              top: 2,
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: complete
                      ? const Color(0xFF3B6D11)
                      : partial
                      ? const Color(0xFFBA7517)
                      : Colors.transparent,
                  border: complete || partial
                      ? null
                      : Border.all(color: scheme.outlineVariant, width: 0.5),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

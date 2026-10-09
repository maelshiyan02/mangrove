// dart:io comes through utils/io.dart (Directory/File/FilePath).

import 'dart:async';
import 'dart:convert';
// `Uint8List` 由下面的 `flutter/services.dart` 一并带进来（analyze 会报
// `unnecessary_import`），所以这里**不**显式 import `dart:typed_data`。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:mangrove/components/components.dart';
import 'package:mangrove/components/editable_text_block_canvas.dart';
import 'package:mangrove/components/studio_scroll_canvas.dart';
import 'package:mangrove/components/text_block_canvas.dart';
import 'package:mangrove/foundation/appdata.dart';
import 'package:mangrove/foundation/bt_project/bt_project_manager.dart';
import 'package:mangrove/foundation/comic_type.dart';
import 'package:mangrove/foundation/context.dart';
// 🔴 `IntRect` comes from **this** file, not `dart:ui`. The repo declares its
// own `IntRect` (left/top/right/bottom, no `fromLTWH`) in
// translation_types.dart so the translation model stays Flutter-free and
// testable headlessly; importing `dart:ui`'s same-named class instead compiles
// to a type error that reads like a missing identifier.
import 'package:mangrove/foundation/image_translation/balloon_clustering.dart';
import 'package:mangrove/foundation/image_translation/translation_config.dart';
import 'package:mangrove/foundation/image_translation/translation_dispatcher.dart';
import 'package:mangrove/foundation/image_translation/translation_pipeline.dart';
import 'package:mangrove/foundation/image_translation/translation_types.dart';
import 'package:mangrove/foundation/leave_guard.dart';
import 'package:mangrove/foundation/local.dart';
import 'package:mangrove/foundation/log.dart';
import 'package:mangrove/foundation/translation_project/artifact_reconciliation.dart';
import 'package:mangrove/foundation/translation_project/edit_command.dart';
import 'package:mangrove/foundation/translation_project/finished_export.dart';
import 'package:mangrove/foundation/translation_project/glossary_backend.dart';
import 'package:mangrove/foundation/translation_project/glossary_store_app.dart';
import 'package:mangrove/foundation/translation_project/project.dart';
import 'package:mangrove/foundation/translation_project/project_writer.dart';
import 'package:mangrove/foundation/translation_project/result_renderer.dart';
import 'package:mangrove/foundation/translation_project/rich_text_sync.dart';
import 'package:mangrove/foundation/translation_project/run_plan.dart';
import 'package:mangrove/foundation/translation_project/studio_block_ops.dart';
import 'package:mangrove/foundation/translation_project/studio_pipeline.dart';
import 'package:mangrove/foundation/translation_project/studio_reader_app.dart';
import 'package:mangrove/foundation/translation_project/text_block.dart';
import 'package:mangrove/foundation/widget_utils.dart';
import 'package:mangrove/pages/comic_details_page/glossary_editor.dart';
import 'package:mangrove/utils/io.dart';
import 'package:mangrove/utils/translations.dart';

import 'run_dialog.dart';
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

  /// 术语表的身份（scope + 翻译组）。
  ///
  /// 🔴 真相在**绑定表**里，不是 `widget.comicId`。一个工程 = 一章，拿工程 id
  /// 当 scope 会让同一本漫画的 20 章各有一份互不相通的术语表 —— 与"同一本漫画
  /// 共用"直接冲突。而工程 json 是 FT 兼容格式、**顶层键序被断言锁死**
  /// （`headless_p3_checks` 的 `key_order_matches_ft`），来源写不进 json
  /// ⇒ 只能经绑定表反查（`StudioReaderStore.originForProject`）。
  ///
  /// `widget.comicId` 只是**回落**：绑定表出现之前建的老工程没有绑定，那种工程
  /// 本来就没人往里写过术语 —— 回落成 `comicId` 与回落成"另一份空表"等价。
  String _glossaryScope = '';
  String _glossaryGroup = '';

  /// Page keys that have something to show: a source image or an artifact.
  /// FT's json also stores keys for files that never existed (phantom `.jpg`
  /// shells next to the real `.webp` pages), and those must not become pages.
  List<String> _pageKeys = const [];

  int _pageIndex = 0;
  int _selectedBlock = -1;

  /// S-N1: a 【识别】/【翻译】 action is in flight for the selected block.
  ///
  /// 🔴 Session-only, like the pipeline options: it describes "what is running
  /// right now", not a setting. Persisting it would mean the studio came back
  /// with a permanently disabled panel after a crash mid-OCR.
  bool _blockOpBusy = false;

  /// Re-reads only the selected block's box (S-N1 【识别】).
  ///
  /// 🔴 Three things this deliberately does **not** do:
  ///
  /// 1. **不跑整页检测**。走 `ocrPage` 会重检测全页并重投语言票（一次点击 =
  ///    94 页的活），而按钮的契约是"重读这一块"。
  /// 2. **不自动覆盖原文**。空结果必须报错而不是把已有原文清空 —— 那是本项目
  ///    最忌讳的静默数据损失。
  /// 3. **不落盘任何配置**。语向取当前运行选项（会话内），与 S-N2 的弹窗一致。
  Future<void> _recogniseSelectedBlock() async {
    final project = _project;
    final pageKey = _selectedPageKey;
    if (project == null || pageKey == null || _selectedBlock < 0) return;
    final block = _currentBlock;
    if (block == null) return;
    final original = File(project.originalPath(pageKey));
    if (!original.existsSync()) {
      // 🔴 没有**原图**就不能识别：`inpainted/` 里原文已经被抹掉了，在上面
      // 跑 OCR 认的是译文。这是必须说出口的拒绝，而不是让它返回空。
      context.showMessage(message: 'The original page is missing.'.tl);
      return;
    }
    setState(() => _blockOpBusy = true);
    try {
      final decoded = await decodePageFile(original);
      if (decoded == null) {
        if (mounted) {
          context.showMessage(message: 'Page @a failed: @b'.tlParams({
            'a': '${_pageIndex + 1}',
            'b': 'decode failed',
          }));
        }
        return;
      }
      // 🔴 用**原图**尺寸（`originalSize`）而不是解码后的 `image.width`：
      // 块的 `xyxy` 是源像素坐标，拿解码尺寸去夹取会在大页上裁错位置。
      final crop = StudioBlockOps.cropWindow(
        block.xyxy,
        decoded.originalSize.width.round(),
        decoded.originalSize.height.round(),
      );
      if (crop == null) {
        // 块坐标坏了 —— 说出真话，而不是"点了没反应"。
        if (mounted) {
          context.showMessage(message: 'This block has no usable box.'.tl);
        }
        return;
      }
      final bytes = await original.readAsBytes();
      final blocks = await PageTranslationPipeline().ocrRegion(
        bytes,
        IntRect(crop.left, crop.top, crop.right, crop.bottom),
        sourceLang: _currentSourceLang(),
      );
      final lines = StudioTranslateOps.splitLines(
        blocks.map((b) => b.text).join('\n'),
      );
      if (lines.isEmpty) {
        if (mounted) {
          context.showMessage(message: 'Recognise failed: no text found.'.tl);
        }
        Log.info(
          'Studio Block',
          'recognise ${block.xyxy} crop=$crop lines=0',
        );
        return;
      }
      final text = StudioTranslateOps.joinLines(lines);
      final box = blocks.isEmpty
          ? null
          : StudioBlockOps.toPageCoords(
              crop,
              [
                blocks.first.rect.left,
                blocks.first.rect.top,
                blocks.first.rect.right,
                blocks.first.rect.bottom,
              ],
            );
      _editBlock(
        pageKey,
        _selectedBlock,
        'Recognise',
        (b) => b.sourceText = text,
        // 🔴 识别框与字形色都变了，而 FT 的 rich_text 里存着排版结果 ——
        // 不同步就会出图时用旧的字号画新的文字。
        syncRichText: true,
      );
      Log.info(
        'Studio Block',
        'recognise ${block.xyxy} crop=$crop lines=${lines.length} '
        'box=$box',
      );
    } catch (e, s) {
      Log.error('Studio Block', 'recognise failed', s);
      if (mounted) context.showMessage(message: 'Recognise failed.'.tl);
    } finally {
      if (mounted) setState(() => _blockOpBusy = false);
    }
  }

  /// Re-translates only the selected block (S-N1 【翻译】).
  ///
  /// 🔴 空结果 / 与现有译文逐字相同的结果**都不写**（`StudioTranslateOps`
  /// 负责判）。翻译动作会返回一句看起来一模一样的话，这时写回去只会让用户
  /// 以为按钮生效了，而实际上什么都没变。
  Future<void> _translateSelectedBlock() async {
    final project = _project;
    final pageKey = _selectedPageKey;
    if (project == null || pageKey == null || _selectedBlock < 0) return;
    final block = _currentBlock;
    if (block == null) return;
    final source = block.sourceText.trim();
    if (source.isEmpty) {
      if (mounted) {
        context.showMessage(message: 'This block has no source text.'.tl);
      }
      return;
    }
    setState(() => _blockOpBusy = true);
    try {
      final glossary = _glossary;
      final lang = _currentSourceLang();
      final response = await TranslationDispatcher.translateBatch(
        [source],
        _currentTargetLang(),
        sourceLang: lang,
        sourceLangs: [lang],
        glossary: glossary,
      );
      final incoming = response.texts.isEmpty ? '' : response.texts.first;
      if (!StudioTranslateOps.shouldApply(
        incoming,
        currentTranslation: block.translation,
        currentSource: source,
      )) {
        Log.info(
          'Studio Block',
          'translate ${block.xyxy} rejected (empty or unchanged)',
        );
        if (mounted) {
          context.showMessage(message: 'Translate returned nothing new.'.tl);
        }
        return;
      }
      _editBlock(
        pageKey,
        _selectedBlock,
        'Translate',
        (b) => b.translation = incoming.trim(),
        syncRichText: true,
      );
      if (response.glossary.isNotEmpty) {
        _mergeGlossary(response.glossary);
      }
      Log.info(
        'Studio Block',
        'translate ${block.xyxy} applied, glossary=${response.glossary.length}',
      );
    } catch (e, s) {
      Log.error('Studio Block', 'translate failed', s);
      if (mounted) context.showMessage(message: 'Translate failed.'.tl);
    } finally {
      if (mounted) setState(() => _blockOpBusy = false);
    }
  }

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

  /// 上一轮的**三段选择**（检测 / 识别 / 翻译，P10.15 §4.3）与阅读方向。
  ///
  /// 🔴 P2（P10.15 §4.2 选项②）：**跨重启记忆**，落点是
  /// `appdata.settings['studioRunDefaults']` —— 一个**独立命名空间**，而不是
  /// `TranslationConfig`。两条路径必须分开：#178 就是"把为这一本临时改的
  /// 语言变成了所有漫画的全局默认"踩出来的。详见 [_loadRunDefaults]。
  ///
  /// 默认值按 §4.2 的拍板：**不勾翻译**（先看版面、不花 token）、方向
  /// **左起**（不勾右起）。旧默认是 `translate=true / rightToLeft=true`，
  /// 那是"日漫+直接出成品"的设定，对第一次打开工作室的人偏激进。
  StudioRunStages _runStages = const StudioRunStages(
    detect: true,
    recognize: true,
    translate: false,
  );
  ReadingDirection _runDirection = ReadingDirection.leftToRight;

  /// 「从这一页继续」的断点 = **第一条没有跑完的页** key，null 表示没有断点。
  ///
  /// 🔴 会话内状态，与上面三项同理：不进 `appdata`，不写工程 json。
  /// 跨会话续跑要把断点持久化，而那要么写进工程（立刻破坏零字节 diff），
  /// 要么写进 `appdata`（而"整章跑到哪"是一次性状态，不是设置）—— 留给 P10
  /// 的批量任务框架；本项只做当前会话内的续跑，并如实说明这一点。
  String? _pipelineResumeFrom;

  /// 本次运行的语向覆盖（S-N2）。`null` = 跟随全局 `TranslationConfig`。
  ///
  /// 🔴 与 [StudioRunChoice] 一起被记进 `studioRunDefaults`（P2 选项②），
  /// 所以它能跨重启活下来。**仍然不写工程 json** —— 那是零字节 diff 的
  /// 红线上；也不进 `TranslationConfig` —— 那是 #178 的红线。语向之所以
  /// 值得记，是因为它不随工程变（日漫就该是日→中），而页码会变。
  String? _runSourceLang;
  String? _runTargetLang;

  /// 「上次怎么跑的」在 `appdata.settings` 里的**独立命名空间**（P2 选项②）。
  ///
  /// 🔴 独立于 `TranslationConfig`：后者是"全局翻译默认"，改它等于改所有
  /// 漫画；这里记的是"上次在工作室点的那几个开关"。#178 就是这两者混在
  /// 一起踩出来的（为某一本临时改的语言变成了全局默认）。
  static const String _runDefaultsKey = 'studioRunDefaults';

  /// 读回上次的运行选项（三段 / 方向 / 语向）。
  ///
  /// 🔴 **缺失就不写**：只有"存过"才覆盖字段，没存过时保留声明处的默认值。
  /// 若把"没存过"也走一遍赋值，第一次打开工作室就会拿到一份由
  /// `fromJson(null)` 推出来的全 false 三段 —— 于是弹窗里「开始」被
  /// "Select at least one stage" 禁用，而用户从没关过任何阶段。
  ///
  /// 存储损坏（类型不对）时**逐字段**回落，不整块丢弃：一次手改
  /// `appdata.json` 把 `readingDirection` 写成数字，不该顺带把三段和语向
  /// 也一起忘掉。
  void _loadRunDefaults() {
    final raw = appdata.settings[_runDefaultsKey];
    if (raw is! Map) return;
    if (raw['stages'] is Map) {
      _runStages = StudioRunStages.fromJson(raw['stages']);
    }
    final direction = readingDirectionFromName(raw['readingDirection']);
    if (direction != null) _runDirection = direction;
    final source = raw['sourceLang'];
    if (source is String && source.isNotEmpty) _runSourceLang = source;
    final target = raw['targetLang'];
    if (target is String && target.isNotEmpty) _runTargetLang = target;
  }

  /// 记住这一轮的选择。**只在用户按下「开始」之后调用** —— 拖滑块、试点
  /// 阶段都不落盘，否则"打开弹窗随便看看"会污染记忆，而用户下次会以为
  /// 那些状态是自己上次定的。
  void _saveRunDefaults(StudioRunChoice choice) {
    appdata.settings[_runDefaultsKey] = <String, Object?>{
      'stages': choice.stages.toJson(),
      'readingDirection': readingDirectionName(choice.direction),
      'sourceLang': choice.sourceLang,
      'targetLang': choice.targetLang,
    };
  }

  /// 本次运行生效的源语言：S-N2 弹窗选过的优先，否则读全局设置。
  ///
  /// 🔴 单块【识别】/【翻译】必须走**同一个**来源，理由与 `_confirmAndRun`
  /// 里读 `config.sourceLang` 完全一样：猜一个默认值只会让用户点了按钮之后
  /// 得到一个用错语向识别的结果，而识别错字与"语向不对"在界面上长得一模一样。
  String _currentSourceLang() {
    final lang = _runSourceLang;
    if (lang != null && lang.isNotEmpty && lang != 'auto') return lang;
    return TranslationConfig.of(widget.comicId, null).sourceLang;
  }

  String _currentTargetLang() =>
      _runTargetLang ?? TranslationConfig.of(widget.comicId, null).targetLang;

  /// 统计**选中页范围**内的三类块数，供弹窗的工作量预估（P3 选项①）。
  ///
  /// 🔴 与 `_runPipeline` 读的是**同一份** `project.pages`，所以弹窗里那句
  /// "Detect 12 pages, recognize 34 blocks, translate 34 items"就是这一轮
  /// 真正会处理的量。统计口径写错（比如把别页的块算进来）会让「开始」按钮
  /// 的禁用判断放行一次空跑 —— 而空跑报 0 与"识别了但没认出字"在界面上
  /// 长得一模一样，正是本项目最忌讳的那类静默。
  ///
  /// 口径：
  /// * `blocks` —— 选中页的块总数；
  /// * `unrecognized` —— 其中**原文为空**的块（识别阶段的输入）；
  /// * `untranslated` —— 其中**有原文、还没译文**的块（翻译阶段的输入）。
  StudioRunCounts _countBlocks(List<String> pages) {
    final project = _project;
    if (project == null) return (blocks: 0, unrecognized: 0, untranslated: 0);
    var blocks = 0;
    var unrecognized = 0;
    var untranslated = 0;
    for (final key in pages) {
      final page = project.pages[key];
      if (page == null) continue;
      for (final block in page.blocks) {
        blocks++;
        if (block.sourceText.trim().isEmpty) {
          unrecognized++;
        } else if (!block.hasTranslation) {
          untranslated++;
        }
      }
    }
    return (
      blocks: blocks,
      unrecognized: unrecognized,
      untranslated: untranslated,
    );
  }

  /// 「本页 / 整章」两个按钮的**共同入口**：先弹确认窗，再带着选择去跑。
  ///
  /// 🔴 这两个入口此前直接进 `_runPipeline`（P10.6 §4.5 问题 8）：整章重跑是
  /// 最容易点错的按钮，而语向此前无处可改。弹窗返回 `null`（取消 / 点遮罩 /
  /// 按返回）一律当作"不要跑" —— 不能读成"用户没说不要"。
  ///
  /// [wholeChapter] 只决定弹窗**预选**的区间：本页入口预选当前这一页（用户
  /// 想扩成整章照样可以在弹窗里拖），整章入口预选全章。
  Future<void> _confirmAndRun({required bool wholeChapter}) async {
    final project = _project;
    if (project == null || _pageKeys.isEmpty) return;
    if (_pipeline.running) return;
    final config = TranslationConfig.of(widget.comicId, null);
    final current = _pageIndex + 1;
    final StudioRunChoice? choice = await showStudioRunDialog(
      context: context,
      pageKeys: _pageKeys,
      initialStart: wholeChapter ? 1 : current,
      initialEnd: wholeChapter ? _pageKeys.length : current,
      sourceLang: _runSourceLang ?? config.sourceLang,
      targetLang: _runTargetLang ?? config.targetLang,
      stages: _runStages,
      direction: _runDirection,
      countsOf: _countBlocks,
    );
    if (choice == null || !mounted) return;
    setState(() {
      _runSourceLang = choice.sourceLang;
      _runTargetLang = choice.targetLang;
      // 🔴 面板上的三段/方向必须跟着弹窗走：它们是**同一件事**的两种呈现，
      // 不同步就会出现"面板写着'同时翻译'开着、实际这轮没翻"——而那正是
      // 这个项目反复栽的"UI 在说谎"那一类。
      _runStages = choice.stages;
      _runDirection = choice.direction;
    });
    _saveRunDefaults(choice);
    unawaited(_runPipeline(pages: choice.pages));
  }

  void _runPipelineCurrentPage() {
    unawaited(_confirmAndRun(wholeChapter: false));
  }

  void _runPipelineAllPages() {
    unawaited(_confirmAndRun(wholeChapter: true));
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
    // 🔴 本次运行的语向：弹窗选过就用它，没选过才落到全局设置（S-N2）。
    final sourceLang = _runSourceLang ?? config.sourceLang;
    final targetLang = _runTargetLang ?? config.targetLang;
    final pipeline = StudioPagePipeline();
    // 🔴 三段（P10.15 §4.3）在这里**分叉**。分叉点只有一处，就是
    // [StudioRunStages.detect]：
    //
    // * 勾了检测 ⇒ 走引擎的整页管线（`StudioPagePipeline.runPage`）：检测、
    //   聚类、取色、建块、翻译都是一趟里的事，拆开反而要重造聚类。
    // * 没勾检测 ⇒ 引擎完全不参与，只在**页上已有的块**上做"识别"和
    //   "翻译"。这两件事工作室早就有单块按钮（`_recogniseSelectedBlock` /
    //   `_translateSelectedBlock`），这里是同一套代码的批量版。
    //
    // 之所以不做成"第三条路"（只检测不识别）：本引擎的检测后处理
    // （`clusterOcrBoxes` + 行高 + 取色）与识别同在一趟里，而检测框的下游
    // （建块）恰恰需要这些量。见 [StudioRunOptions.recognize] 的说明。
    final stages = _runStages;
    final options = StudioRunOptions(
      // 工作室没有"这本漫画"的上下文可继承，读全局设置：用户在阅读器里改过
      // 的语向对同一本漫画同样成立，而猜一个默认值只会让第一次运行的产物
      // 全是错的语言。弹窗（`_confirmAndRun`）给出的覆盖优先。
      sourceLang: sourceLang,
      targetLang: targetLang,
      readingDirection: _runDirection,
      translate: stages.translate,
      recognize: stages.recognize,
      // 🔴 这一行是"术语表进工作室"的**注入端**。字段早就有了
      // （`StudioRunOptions.glossary`），但一直没人传 ⇒ 工作室此前跑整章时
      // 术语表恒为空，跨页/跨章人名一致性是个空承诺。
      // 工作室工程没有 sourceKey，scope 直接用 comicId（见 glossary_store.dart）。
      glossary: _glossary,
    );

    var blocks = 0;
    var skipped = 0;
    var failures = 0;
    var learned = 0;
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
      // 🔴 页不存在就**在跑之前**判掉（原始版本是跑完再判）。原写法会把一次
      // 整页 OCR 白跑掉再丢弃结果，而"页不在工程里"是个与图像内容无关的
      // 事实，不需要先付检测的代价。
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
      final bytes = await file.readAsBytes();
      final result = stages.detect
          ? await _runDetectStage(
              pipeline,
              page,
              bytes,
              pageKey: pageKey,
              options: options,
              cancel: cancel,
            )
          : await _runBlockStages(
              page,
              bytes,
              pageKey: pageKey,
              stages: stages,
              sourceLang: sourceLang,
              targetLang: targetLang,
              cancel: cancel,
            );
      if (result.canceled) {
        resumeFrom ??= pageKey;
        break;
      }
      // 🔴 回报端：模型在本页新学到的专名**立刻**进 store，下一页就能用上 ——
      // 攒到最后再合并会让"同一章内"的人名也不一致。真 LLM 才回报，
      // 免 Key / 本地 NMT 恒为空（`run.glossary` 为空时 `merge` 直接返回 0）。
      learned += result.learned;
      if (result.failed) {
        failures++;
        resumeFrom ??= pageKey;
        if (mounted) {
          setState(() => _pipeline.lastMessage = result.message);
        }
        continue;
      }
      blocks += result.blocks;
      skipped += result.skipped;
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
    // 键名刻意与 `mangrove.exe --headless pipeline-check` 的报告对齐，两边的
    // 数字可以直接比对。
    //
    // 🔴 P10.15 §3.1-C：同一个 map 现在还会被写进产物**对账表**
    // （`imgtrans_<名>.artifacts.json` 的 `run` 段）。`failures > 0` 时那条
    // "失败不自动存"的规则仍然成立 —— 但一次 94 页全失败的运行此前只在这行
    // 日志里留痕，工程目录看起来和"没跑过"一模一样。进了对账表就分得开了。
    final runSummary = <String, Object?>{
      'pages': pages.length,
      'done': _pipeline.done,
      'blocks': blocks,
      'skipped': skipped,
      'failures': failures,
      'stopped': stopped,
      // 本轮新学到的术语条数：0 有两种可能（本页没有新专名 / 引擎根本
      // 不回报），配合日志里的 `Glossary Bridge` 行才能区分。
      'glossaryLearned': learned,
      'resumeFrom': _pipelineResumeFrom,
      // S-N2：语向现在是**每次运行可变**的（弹窗覆盖），所以必须记进凭据行
      // —— 否则"这一轮的产物为什么是这种语言"事后无法重建。
      'sourceLang': sourceLang,
      'targetLang': targetLang,
      // P10.15 §4.3：三段取代了旧的 `translate` 开关。**三个键都记**，而不是
      // 只记 `translate`：`translate:false` 在旧模型里只有一个含义（只检测
      // 不翻译），在新模型里"没勾检测"才是另一条完全不同的代码路径
      // （不跑引擎、只处理已有块）。只记一个 `translate` 会让两份日志的
      // `translate:false` 看起来一样，而它们做的事不一样。
      'stages': stages.toJson(),
      'direction': readingDirectionName(_runDirection),
      'skipExisting': _pipelineSkipExisting,
    };
    Log.info('Studio Pipeline', jsonEncode(runSummary));
    // 页集/分辨率可能变了（inpainted/ 被写入），条带缓存必须重算。
    _invalidateStripCache();
    if (!stopped && failures == 0) {
      // 全成功才自动存：自动管线跑完不存等于用户还要按一次 Ctrl+S，而这一批
      // 块有可能是几十页的量。失败/取消时**不**自动存，让用户先看状态栏。
      unawaited(_save(run: runSummary));
    } else {
      // 失败/取消：不写 JSON，但**照样**落一份对账表。否则一次失败运行在
      // 工程目录里不留任何痕迹，`reason` 也永远停在旧状态。
      unawaited(_writeReconciliation(runSummary));
    }
  }

  /// 只写对账表、不动 JSON 与产物。用于"不自动存"的那条路径。
  Future<void> _writeReconciliation(Map<String, Object?> run) async {
    final project = _project;
    if (project == null) return;
    try {
      final file = await ArtifactReconciliation.write(project, run: run);
      Log.info('Translation Studio', 'reconciliation written: ${file.path}');
    } catch (e, s) {
      Log.error('Translation Studio', 'reconciliation failed', s);
    }
  }

  /// 检测阶段（§4.3 第一段）：整页交给引擎，一趟拿到块。
  ///
  /// 只在 `stages.detect` 为真时调用。识别是否发生由
  /// [StudioRunOptions.recognize] 决定（见那里的说明）。
  Future<_PageStageResult> _runDetectStage(
    StudioPagePipeline pipeline,
    ProjectPage page,
    Uint8List bytes, {
    required String pageKey,
    required StudioRunOptions options,
    required CancellationToken cancel,
  }) async {
    final size = _pageSizeInPixels(pageKey);
    final run = await pipeline.runPage(
      pageKey,
      bytes,
      options: options,
      pageWidth: size.width.round(),
      cancel: cancel,
    );
    if (run.error is PipelineCanceled) {
      return const _PageStageResult(
        blocks: 0,
        skipped: 0,
        learned: 0,
        failed: false,
        canceled: true,
        message: '',
      );
    }
    var learned = 0;
    if (run.glossary.isNotEmpty) {
      learned = _mergeGlossary(run.glossary);
    }
    if (run.failed) {
      return _PageStageResult(
        blocks: 0,
        skipped: 0,
        learned: learned,
        failed: true,
        canceled: false,
        message: 'Page @a failed: @b'.tlParams({
          'a': pageKey,
          // `Object?` is not assignable to the parameter map's `Object` value
          // type, and `run.error` is legitimately null on the success path —
          // stringify it so the message is honest either way.
          'b': '${run.error}',
        }),
      );
    }
    // 去重在落地之前，且**只读**既有块（见 `overlapsExistingBlock` 的说明）。
    final fresh = _pipelineSkipExisting
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
    return _PageStageResult(
      blocks: fresh.length,
      skipped: run.skipped,
      learned: learned,
      failed: false,
      canceled: false,
      message: '',
    );
  }

  /// 识别 + 翻译阶段（§4.3 第二、三段）：**不跑引擎的整页管线**，只在页上
  /// **已有的块**上做事。
  ///
  /// 只在 `stages.detect` 为假时调用。
  ///
  /// ## 为什么不去调 `StudioPagePipeline.runPage`
  ///
  /// 那条路的第一步就是整页检测，而本路径的**全部意义**正是"不重新检测"：
  /// 用户已经手工把版面排好了（拖框、删块、改字号），只想把文字补齐/翻掉。
  /// 整页检测会把用户排好的块当成待检内容重新划一遍，去重又只挡显著重叠的，
  /// 于是"改一个字"变成"多出三个新块"。
  ///
  /// ## 两个动作分别复用已验证的入口
  ///
  /// * 识别 → [PageTranslationPipeline.ocrRegion]（框内 OCR）。与单块
  ///   【识别】按钮（`_recogniseSelectedBlock`）**同一个** API，只是这里按块
  ///   批量走。
  /// * 翻译 → [TranslationDispatcher.translateBatch]。与单块【翻译】按钮
  ///   （`_translateSelectedBlock`）**同一个** API。
  ///
  /// ## 只认"还没做过"的块
  ///
  /// 已经有原文的块不再 OCR，已经有译文的块不再翻译。理由与 `skipExisting`
  /// 同源：人工校对过的块比机器新认出来的值钱，拿一次批量运行覆盖它属于
  /// "用机器换掉人工"。想重做某一块，用单块按钮 —— 那里是有意的覆盖。
  Future<_PageStageResult> _runBlockStages(
    ProjectPage page,
    Uint8List bytes, {
    required String pageKey,
    required StudioRunStages stages,
    required String sourceLang,
    required String targetLang,
    required CancellationToken cancel,
  }) async {
    final blocks = page.blocks;
    var processed = 0;
    var learned = 0;
    final glossary = _glossary;
    final size = _pageSizeInPixels(pageKey);
    try {
      // ── 识别 ──────────────────────────────────────────────────────────
      if (stages.recognize) {
        final pipeline = PageTranslationPipeline();
        final updates = <int, String>{};
        for (var i = 0; i < blocks.length; i++) {
          cancel.throwIfCanceled();
          final block = blocks[i];
          if (block.sourceText.trim().isNotEmpty) continue;
          final crop = StudioBlockOps.cropWindow(
            block.xyxy,
            size.width.round(),
            size.height.round(),
          );
          // 坐标坏掉的块**跳过而不是失败**：它本来就没有可读的框，把它算作
          // 本页失败会让一次整章运行因为一个坏块而报失败页。
          if (crop == null) continue;
          final found = await pipeline.ocrRegion(
            bytes,
            IntRect(crop.left, crop.top, crop.right, crop.bottom),
            sourceLang: sourceLang,
          );
          final lines = StudioTranslateOps.splitLines(
            found.map((b) => b.text).join('\n'),
          );
          if (lines.isEmpty) continue;
          updates[i] = StudioTranslateOps.joinLines(lines);
        }
        if (updates.isNotEmpty) {
          // 🔴 一次页级编辑（与 `captureBlockListEdit` 的"一页一步"约定一致）：
          // 逐块 push 会在一页十几块时把 undo 栈冲掉。
          final command = captureBlockListEdit(
            page.rawBlocks,
            () {
              for (final entry in updates.entries) {
                final block = blocks[entry.key];
                block.sourceText = entry.value;
                // 🔴 识别框与字形色都变了，而 FT 的 `rich_text` 里存着排版
                // 结果 —— 不同步就会出图时用旧字号画新文字。
                syncFtRichText(block);
              }
            },
            pageKey: pageKey,
            label: 'Recognise blocks',
          );
          if (!command.isEmpty) _history.push(command);
          processed += updates.length;
        }
      }

      // ── 翻译 ──────────────────────────────────────────────────────────
      if (stages.translate) {
        // 🔴 一次请求带整页所有待翻块，而不是逐块请求：`translateBatch` 的
        // 契约就是批（术语表、上下文都在一次请求里），逐块调用会把"同一页
        // 内的人名一致"这个它唯一的优势丢掉，还会把请求数乘以块数。
        final targets = <int>[];
        final texts = <String>[];
        final langs = <String>[];
        // `sourceLangs` 在这里传**本次运行的源语言**而不是每块自己的
        // `sourceLang`：块上那个字段是识别阶段的产物，老工程里可能为空或
        // 过时，而弹窗给出的语向是用户这一轮明确的选择。
        for (var i = 0; i < blocks.length; i++) {
          final block = blocks[i];
          // 🔴 拟声词默认不译（P10.15 §4.5 · 序6）：检测阶段已按 `StudioSfxOps`
          // 打了 `label: 'sfx'`。这里若只按"没译文就翻"的通用规则走，标记就会
          // 变成 json 里一个没人用的字段 —— token 照花、荒唐译文照拿。
          //
          // 刻意**不**在这一段给旧块补标记：本段的语言来自"用户这一轮选的语向"，
          // 而标记必须依据该块**自己**的检测语言，否则同一页会因为用户换了语向
          // 而得到不同的标记。标记只有一个产生点：`StudioPagePipeline.runPage`。
          // 面板上的【翻译】是**单块**动作、不看这个标记，误标一次点击就能回来。
          if (StudioSfxOps.isMarkedSfx(block)) continue;
          final source = block.sourceText.trim();
          if (source.isEmpty || block.hasTranslation) continue;
          targets.add(i);
          texts.add(source);
          langs.add(sourceLang);
        }
        if (targets.isNotEmpty) {
          cancel.throwIfCanceled();
          final response = await TranslationDispatcher.translateBatch(
            texts,
            targetLang,
            sourceLang: sourceLang,
            sourceLangs: langs,
            glossary: glossary,
          );
          if (response.glossary.isNotEmpty) {
            learned = _mergeGlossary(response.glossary);
          }
          final applied = <int, String>{};
          for (var k = 0; k < targets.length; k++) {
            final incoming = k < response.texts.length ? response.texts[k] : '';
            final block = blocks[targets[k]];
            // 🔴 空结果 / 与原文逐字相同的结果**都不写**（判据与单块按钮
            // 共用 `StudioTranslateOps.shouldApply`）。写回去只会让用户以为
            // 按钮生效了，而实际什么都没变 —— 正是本项目最忌讳的静默。
            if (!StudioTranslateOps.shouldApply(
              incoming,
              currentTranslation: block.translation,
              currentSource: block.sourceText,
            )) {
              continue;
            }
            applied[targets[k]] = incoming.trim();
          }
          if (applied.isNotEmpty) {
            final command = captureBlockListEdit(
              page.rawBlocks,
              () {
                for (final entry in applied.entries) {
                  final block = blocks[entry.key];
                  block.translation = entry.value;
                  syncFtRichText(block);
                }
              },
              pageKey: pageKey,
              label: 'Translate blocks',
            );
            if (!command.isEmpty) _history.push(command);
            processed += applied.length;
          }
        }
      }
      return _PageStageResult(
        blocks: processed,
        skipped: 0,
        learned: learned,
        failed: false,
        canceled: false,
        message: '',
      );
    } on PipelineCanceled {
      return const _PageStageResult(
        blocks: 0,
        skipped: 0,
        learned: 0,
        failed: false,
        canceled: true,
        message: '',
      );
    } catch (e, s) {
      Log.error('Studio Pipeline', 'block stages $pageKey failed: $e', s);
      return _PageStageResult(
        blocks: 0,
        skipped: 0,
        learned: learned,
        failed: true,
        canceled: false,
        message: 'Page @a failed: @b'.tlParams({'a': pageKey, 'b': '$e'}),
      );
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
    // 术语表身份：先反查绑定表，拿不到才回落（见 `_glossaryScope` 的注释）。
    final origin = StudioReaderStore.originForProject(project.jsonFile.path);
    _history.clear();
    setState(() {
      _project = project;
      _pageKeys = keys;
      _error = keys.isEmpty ? 'This project has no readable page image.' : '';
      _title = comic?.title ?? project.jsonFileName;
      _glossaryScope = origin?.$1 ?? widget.comicId;
      _glossaryGroup = origin?.$2 ?? '';
      _pageIndex = 0;
      _selectedBlock = -1;
      _selectedPageKey = null;
      // 页集可能整个换掉了：断点指向的 key 未必还在（P9.7）。
      _pipelineResumeFrom = null;
      // 语向 / 三段 / 方向按 P2 选项②**从设置里读回**（`studioRunDefaults`）。
      // 这与"断点作废"是两条相反的决定，理由也相反：断点说的是"这一本跑到
      // 哪"，换工程就不成立；而语向/方向说的是"我平时怎么跑"，它跨工程、
      // 跨重启都成立（日漫就该日→中）。两者唯一的共同点是都必须显式处理 ——
      // 默默留着旧值或默默清掉都会做成一种"看起来正常"的错。
      _loadRunDefaults();
      _revision++;
    });
    // The page set changed: the memoised strip list is stale.
    _invalidateStripCache();
    // The strip canvas decodes its own window, so priming a single page here
    // would just burn a bitmap nobody looks at.
    if (keys.isNotEmpty && !_stripMode) await _loadBase(keys.first);
  }

  /// 下发 / 编辑用的术语表：**共用层 ∪ 本组**（本组同名条目覆盖共用层）。
  ///
  /// 判据与注入端同一处：`GlossaryStore.of` 是唯一的合并实现，所以"工作室里
  /// 看到的"与"发给引擎的"必然一致 —— 分开拼两次就会出现编辑器里改好了、
  /// 引擎那边没生效的假象。
  Map<String, String> get _glossary =>
      appGlossary.of(_glossaryScope, group: _glossaryGroup);

  /// 把模型回报的专名并进**本组**的桶，返回新增条数。
  ///
  /// 🔴 写组桶而不是共用层：这是"这一组翻译时学到的说法"，而共用层是人工确认过
  /// 的名字（`glossary_store.dart` 头部）。混在一起会让某一组的自动学习覆盖掉
  /// 用户在另一组手填的译法。
  int _mergeGlossary(Map<String, String> discovered) =>
      appGlossary.merge(_glossaryScope, discovered, group: _glossaryGroup);

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
      // 🔴 P10.15 序2: the source-scale anchor the canvas's shrink-to-fit needs
      // (`page_renderer._fitFontSize` reads the same number as `lineHeight`).
      // Without it the canvas had nothing to cap against and drew oversized
      // lettering that it then truncated with `…`.
      lineHeight: block.detectedFontSize,
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
  Future<bool> _save({Map<String, Object?>? run}) async {
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
      unawaited(_regenerateResults(dirtyPages: dirtyPages, run: run));
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
  ///
  /// [run] is the last pipeline summary, recorded into the reconciliation table
  /// so a run that produced nothing is still auditable (P10.15 §3.1-C).
  Future<void> _regenerateResults({
    Set<String>? dirtyPages,
    Map<String, Object?>? run,
  }) async {
    final project = _project;
    if (project == null) return;
    setState(() => _renderingResults = true);
    // 用 `File?` 而不是 `ArtifactReconciliation?`：`write` 返回的是**落盘后的
    // 文件**（要打日志用它的 path），类型只挂在 `write` 的签名上。
    File? reconciliation;
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
      // 顺序由 `inLayeredOrder` 表达而不是靠"两个相邻的 await"——后者写反了
      // 不报错，只是静静地少一半产物（见该函数的文档与
      // `inpaint.layered_order_bases_first`）。
      final (bases, report) = await ProjectWriter.inLayeredOrder(
        () => ProjectWriter.writeArtifacts(
          root: project.workspace,
          project: project,
          kinds: const {
            ProjectArtifactKind.mask,
            ProjectArtifactKind.inpainted,
          },
          filter: filter,
          concurrency: 2,
          source: (kind, pageKey) => kind == ProjectArtifactKind.mask
              // 🔴 mask 与 inpainted 放进**同一次**调用是安全的：两者都只依赖
              // 原图 + regions，互不读取对方的产物（`renderInpaintedPage` 不看
              // mask，`renderMaskPage` 不看 inpainted）。真正不可交换的是它们
              // 与 `result/` 的顺序 —— 那个必须单独一轮。
              ? renderMaskPage(project, pageKey)
              : renderInpaintedPage(project, pageKey),
        ),
        () => ProjectWriter.writeArtifacts(
          root: project.workspace,
          project: project,
          kinds: const {ProjectArtifactKind.result},
          filter: filter,
          concurrency: 2,
          source: (kind, pageKey) => renderProjectResultPage(project, pageKey),
        ),
      );
      // 🔴 对账表（P10.15 §3.1-B）：每次重生成后落一份**逐页**证据。
      //
      // 没有它，"78 页有 inpainted 没有 mask"这件事只能在文件管理器里一页
      // 一页数出来，而且数出来也分不清"本来就没字"和"真的丢了"。有了它，
      // 缺口是可断言的（`reason` 字段），补没补回也一目了然。
      reconciliation = await ArtifactReconciliation.write(project, run: run);
      Log.info(
        'Translation Studio',
        'artifacts regenerated: bases=$bases result=$report '
        '(dirty=${dirtyPages?.length ?? 'all'}) '
        'reconciliation=${reconciliation.path}',
      );
    } catch (e, s) {
      Log.error('Translation Studio', 'result regeneration failed', s);
    } finally {
      if (mounted) setState(() => _renderingResults = false);
    }
  }

  /// 「重新生成全部产物」：把**每一页**的 `mask/` `inpainted/` `result/` 重算一遍。
  ///
  /// 🔴 为什么需要一个**全量**入口：保存走的是**脏页增量**
  /// （`_save -> _regenerateResults(dirtyPages)`），而 `writeArtifacts` 只处理
  /// 计划里的页 —— 于是**一页只要不再被编辑，它缺的产物就永远不会被补回来**。
  /// S9.5-a 的 78 页 `inpainted 有 / mask 无` 正是这个状态：那批产物产出时
  /// mask 接线还没写，而后续每次保存都只碰"刚改过的那一页"。
  ///
  /// 语义上 `dirtyPages: null` 就是"全部"（该参数早就有这个含义），所以这里
  /// 没有新机制，只是把那个语义接到一个按钮上。
  Future<void> _regenerateAllArtifacts() async {
    final project = _project;
    if (project == null || _renderingResults) return;
    final go = await _confirmRegenerateAll();
    if (!go || !mounted) return;
    await _regenerateResults(dirtyPages: null);
    if (!mounted) return;
    final reconciliation = ArtifactReconciliation.read(project);
    final summary = reconciliation?['summary'];
    final detail = summary is Map
        ? summary.entries.map((e) => '${e.key}=${e.value}').join(', ')
        : 'no report';
    context.showMessage(
      message: 'Regenerated all artifacts. @a'.tlParams({'a': detail}),
    );
  }

  /// 全量重生成的确认框。整章重算 + 重新渲染是分钟级的，不能一点就跑。
  Future<bool> _confirmRegenerateAll() async {
    final answer = await showDialog<bool>(
      context: context,
      builder: (_) => ContentDialog(
        title: 'Regenerate all artifacts'.tl,
        content: Text(
          'Recompute mask, inpainted and result for every page of this project. Use it to fill in pages whose artifacts are missing; a large project can take a while.'.tl,
        ).paddingHorizontal(16).paddingVertical(8),
        actions: [
          TextButton(
            onPressed: () => context.pop(false),
            child: Text('Cancel'.tl),
          ),
          FilledButton.icon(
            onPressed: () => context.pop(true),
            icon: const Icon(Icons.refresh, size: 18),
            label: Text('Regenerate'.tl),
          ),
        ],
      ),
    );
    return answer ?? false;
  }

  /// 打开本工程的术语表编辑器（A08 §1.1 · C）。
  ///
  /// 🔴 scope 是**来源漫画身份** `cid@sourceKey`、group 是本章所属的翻译组 ——
  /// 两者都在 `_load` 里经绑定表反查得到（见 `_glossaryScope` 的注释），所以这
  /// 一份表与阅读器里那份**是同一份数据**。上一版这里是 `widget.comicId`，那让
  /// 同一本漫画的每一章各有一份表。
  ///
  /// 改动立刻落 `implicitData`（`GlossaryStore` 每次写都 persist），下一次
  /// 运行自动管线时读的就是新表，不需要重开工程。
  void _openGlossary() {
    context.to(
      () => GlossaryEditorPage(
        backend: StoreGlossaryBackend(
          appGlossary,
          _glossaryScope,
          group: _glossaryGroup,
        ),
      ),
    );
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
            // 🔴 P10.15 序1: 全量产物重生成。保存走的是**脏页增量**，所以
            // 「一页不再被编辑 ⇒ 它缺的 mask/inpainted/result 永远补不回来」。
            // 这个按钮就是那条缺口的唯一出口（S9.5-a 的 78 页掩膜来源于此）。
            Builder(
              builder: (context) {
                final busy = _renderingResults;
                return IconButton(
                  tooltip: 'Regenerate all artifacts'.tl,
                  icon: busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                  onPressed: project == null || busy
                      ? null
                      : () => unawaited(_regenerateAllArtifacts()),
                );
              },
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
            // 术语表（A08 §1.1 · C）：这本工程的译名约定。与"发布成品"同级 ——
            // 它是**工程级**的元数据，不是当前这一页的编辑动作。
            IconButton(
              tooltip: 'Glossary'.tl,
              icon: const Icon(Icons.menu_book_outlined),
              onPressed: project == null ? null : _openGlossary,
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
        // 🔴 S-N1：两个按钮都**可反复点击**。判据在 `StudioBlockOps` /
        // `StudioTranslateOps`（纯逻辑，可 headless 测），这里只做接线与
        // 取字节。禁用条件只有一个：这一页没有可用原图。
        onRecognise: _blockOpBusy || _pageKeys.isEmpty
            ? null
            : () => _recogniseSelectedBlock(),
        onTranslate: _blockOpBusy || _pageKeys.isEmpty
            ? null
            : () => _translateSelectedBlock(),
        busy: _blockOpBusy,
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
  /// 🔴 三段 / 方向 / `skipExisting` 的落盘规则**各不相同**，不能一句话概括：
  ///
  /// * 三段与方向 —— 按 P2 选项②记进 `appdata.settings['studioRunDefaults']`
  ///   （**独立命名空间**，与 `TranslationConfig` 隔离），跨重启沿用；
  /// * 语向 —— 同上，一起记；
  /// * `skipExisting` —— 仍是**会话内**状态，不落盘（默认开、且描述的是
  ///   "这次要不要覆盖已有块"，属于一次性决定）。
  ///
  /// 三者都不写工程 json —— 写进工程会让零字节 diff 立刻破掉。
  ///
  /// 面板上的三段/方向与弹窗里的是**同一份状态**：这里改了，下次弹窗的
  /// 初始值就跟着改，反之亦然。两处各存一份会让"面板写着 A、弹窗预选 B"
  /// 这种 UI 自相矛盾的状态成为可能。
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
        Text('Stages'.tl, style: ts.s14.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          children: [
            FilterChip(
              label: Text('Detect'.tl),
              selected: _runStages.detect,
              onSelected: running
                  ? null
                  : (on) => setState(
                      () => _runStages = _runStages.copyWith(detect: on)),
            ),
            FilterChip(
              label: Text('Recognize'.tl),
              selected: _runStages.recognize,
              onSelected: running
                  ? null
                  : (on) => setState(
                      () => _runStages = _runStages.copyWith(recognize: on)),
            ),
            FilterChip(
              label: Text('Translate'.tl),
              selected: _runStages.translate,
              onSelected: running
                  ? null
                  : (on) => setState(
                      () => _runStages = _runStages.copyWith(translate: on)),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          // 与弹窗同一句话：三段能不能互相独立，取决于同一份工作量判断。
          'Stages run in order: detect, then recognize, then translate.'.tl,
          style: ts.s12.copyWith(color: scheme.onSurfaceVariant),
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
        const SizedBox(height: 8),
        Text(
          'Reading direction'.tl,
          style: ts.s14.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          children: [
            // 🔴 `ChoiceChip` 而不是 `SwitchListTile`：方向自 P10.15 §4.4 起是
            // **三值**（右起 / 左起 / 纵向），一个开关塞不下第三个状态，硬塞
            // 会把"纵向"静默变成"左起"——那正是这条改动要修的那类错。
            ChoiceChip(
              label: Text('Right to left'.tl),
              selected: _runDirection == ReadingDirection.rightToLeft,
              onSelected: running
                  ? null
                  : (_) => setState(
                      () => _runDirection = ReadingDirection.rightToLeft),
            ),
            ChoiceChip(
              label: Text('Left to right'.tl),
              selected: _runDirection == ReadingDirection.leftToRight,
              onSelected: running
                  ? null
                  : (_) => setState(
                      () => _runDirection = ReadingDirection.leftToRight),
            ),
            ChoiceChip(
              label: Text('Top to bottom'.tl),
              selected: _runDirection == ReadingDirection.topToBottom,
              onSelected: running
                  ? null
                  : (_) => setState(
                      () => _runDirection = ReadingDirection.topToBottom),
            ),
          ],
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

/// 一页跑完的汇总：检测路径与"只处理已有块"路径的共同返回。
///
/// 🔴 做成**类**而不是 record typedef：record 的字段名在类型别名上不会被
/// 解析成"构造参数"，`const _PageStageResult(...)` 会被判成
/// `creation_with_non_type`（"isn't a class"）—— 报错信息看起来像名字打错了，
/// 实际是别名解析的问题。一个 6 字段的小类在这里更贵一点也更好读。
///
/// [blocks] 的含义**随路径不同**：检测路径是"本页新增的块数"，非检测路径
/// 是"本页被填了原文或译文的块数"。两者都不是"页上块总数"。
/// [canceled] 与 [failed] 分开：取消不是失败（断点语义不同），把取消算成
/// 失败会让状态栏报一页失败而用户只是自己点了停止。
class _PageStageResult {
  const _PageStageResult({
    required this.blocks,
    required this.skipped,
    required this.learned,
    required this.failed,
    required this.canceled,
    required this.message,
  });

  final int blocks;
  final int skipped;
  final int learned;
  final bool failed;
  final bool canceled;

  /// 失败时给状态栏的一句话（成功/取消时为空）。
  final String message;
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

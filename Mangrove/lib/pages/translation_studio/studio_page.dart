// dart:io comes through utils/io.dart (Directory/File/FilePath).

import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;
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
import 'package:mangrove/foundation/image_translation/inpaint.dart';
// 🔴 `IntRect` comes from **this** file, not `dart:ui`. The repo declares its
// own `IntRect` (left/top/right/bottom, no `fromLTWH`) in
// translation_types.dart so the translation model stays Flutter-free and
// testable headlessly; importing `dart:ui`'s same-named class instead compiles
// to a type error that reads like a missing identifier.
import 'package:mangrove/foundation/image_translation/balloon_clustering.dart';
import 'package:mangrove/foundation/image_translation/page_renderer.dart';
import 'package:mangrove/foundation/image_translation/translation_config.dart';
import 'package:mangrove/foundation/image_translation/translation_dispatcher.dart';
import 'package:mangrove/foundation/image_translation/translation_models.dart';
import 'package:mangrove/foundation/image_translation/text_color.dart';
import 'package:mangrove/foundation/image_translation/translation_pipeline.dart';
import 'package:mangrove/foundation/image_translation/translation_types.dart';
import 'package:mangrove/foundation/image_translation/translation_worker.dart';
import 'package:mangrove/foundation/leave_guard.dart';
import 'package:mangrove/foundation/local.dart';
import 'package:mangrove/foundation/log.dart';
import 'package:mangrove/foundation/translation_project/artifact_reconciliation.dart';
import 'package:mangrove/foundation/translation_project/block_artifacts.dart';
import 'package:mangrove/foundation/translation_project/block_group.dart';
import 'package:mangrove/foundation/translation_project/cross_page_block.dart';
import 'package:mangrove/foundation/translation_project/edit_command.dart';
import 'package:mangrove/foundation/translation_project/finished_export.dart';
import 'package:mangrove/foundation/translation_project/glossary_backend.dart';
import 'package:mangrove/foundation/translation_project/glossary_store_app.dart';
import 'package:mangrove/foundation/translation_project/gray_png.dart';
import 'package:mangrove/foundation/translation_project/mask_producer.dart';
import 'package:mangrove/foundation/translation_project/page_size_probe.dart';
import 'package:mangrove/foundation/translation_project/project.dart';
import 'package:mangrove/foundation/translation_project/project_io.dart';
import 'package:mangrove/foundation/translation_project/project_writer.dart';
import 'package:mangrove/foundation/translation_project/result_renderer.dart';
import 'package:mangrove/foundation/translation_project/rich_text_sync.dart';
import 'package:mangrove/foundation/translation_project/run_plan.dart';
import 'package:mangrove/foundation/translation_project/seam_detect.dart';
import 'package:mangrove/foundation/translation_project/seam_review.dart';
import 'package:mangrove/foundation/translation_project/seam_window.dart';
import 'package:mangrove/foundation/translation_project/span_artifacts.dart';
import 'package:mangrove/foundation/translation_project/group_translate.dart';
import 'package:mangrove/foundation/translation_project/studio_block_ops.dart';
import 'package:mangrove/foundation/translation_project/studio_pipeline.dart';
import 'package:mangrove/foundation/translation_project/studio_reader_app.dart';
import 'package:mangrove/foundation/translation_project/strip_hidden_pages.dart';
import 'package:mangrove/foundation/translation_project/text_block.dart';
import 'package:mangrove/foundation/translation_project/thumb_rail.dart';
import 'package:mangrove/foundation/widget_utils.dart';
import 'package:mangrove/pages/comic_details_page/glossary_editor.dart';
import 'package:mangrove/pages/settings/settings_page.dart';
import 'package:mangrove/pages/translation_studio/studio_translation_settings_page.dart';
import 'package:mangrove/utils/io.dart';
import 'package:mangrove/utils/translations.dart';

import 'run_dialog.dart';
import 'studio_block_panel.dart';
import 'studio_group_panel.dart';
import 'studio_preview.dart';
import 'studio_project_menu.dart';

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
  /// P33 ⑦b【从原图取色】：在当前选中块的框内采样原图文字色，写进 `frgb`
  /// 并把块标记为"自动"。
  ///
  /// 🔴 三种失败都要**说出口**，不能静默返回（静默的失败会让用户以为"点了没
  /// 反应"或"取色功能坏了"，而真相是原图丢了 / 这块是纯色）。
  Future<void> _resampleSelectedBlockColor() async {
    final project = _project;
    final pageKey = _selectedPageKey;
    if (project == null || pageKey == null || _selectedBlock < 0) return;
    final block = _currentBlock;
    if (block == null) return;
    final original = File(project.originalPath(pageKey));
    if (!original.existsSync()) {
      context.showMessage(message: 'The original page is missing.'.tl);
      return;
    }
    setState(() => _blockOpBusy = true);
    try {
      final decoded = await decodePageFile(original);
      if (decoded == null) {
        context.showMessage(
          message: 'Page @a failed: @b'.tlParams({
            'a': '${_pageIndex + 1}',
            'b': 'decode failed',
          }),
        );
        return;
      }
      final crop = StudioBlockOps.cropWindow(
        block.xyxy,
        decoded.originalSize.width.round(),
        decoded.originalSize.height.round(),
      );
      if (crop == null) {
        context.showMessage(message: 'This block has no usable box.'.tl);
        return;
      }
      final rgb = await _sampleTextColor(
        decoded,
        IntRect(crop.left, crop.top, crop.right, crop.bottom),
      );
      if (rgb == null) {
        // 🔴 取不出色要如实说明：最常见的真相是这块里压根没有可辨的笔画
        // （纯色气泡、框选到了空白处），而不是"算法坏了"。
        context.showMessage(
          message: 'Could not sample a colour from this box.'.tl,
        );
        return;
      }
      _editBlock(
        pageKey,
        _selectedBlock,
        'Sample colour',
        (b) {
          b.ensureFontFormat().foregroundColor = rgb;
          b.colorIsAuto = true;
        },
        syncRichText: true,
      );
    } finally {
      if (mounted) setState(() => _blockOpBusy = false);
    }
  }

  /// P33 ⑦b：从**原图**上取 [sourceRect]（源像素坐标）内文字的颜色。
  ///
  /// 返回 null = 取不出可信的颜色（纯色区域、笔画太细…），调用方应当保持原样。
  ///
  /// 🔴 两个坐标陷阱：
  /// 1. 块的 `xyxy` 是**源像素**坐标，而 [DecodedPage.image] 可能被降采样
  ///    （`maxDimension=2400`）⇒ 窗口必须按 `image.width / originalSize.width`
  ///    缩放，否则在大页上取的是完全不同的地方；
  /// 2. `ui.Image.toByteData` 读的是**整页**（2400×3400×4 ≈ 32 MB），所以只在
  ///    用户显式触发/重新识别时才调，不放在每帧的路径上。
  Future<List<int>?> _sampleTextColor(
    DecodedPage decoded,
    IntRect sourceRect,
  ) async {
    final w = decoded.image.width;
    final h = decoded.image.height;
    final natural = decoded.originalSize;
    if (w <= 0 || h <= 0 || natural.width <= 0 || natural.height <= 0) {
      return null;
    }
    final scale = w / natural.width;
    int clampX(double v) => (v * scale).round().clamp(0, w - 1);
    int clampY(double v) => (v * scale).round().clamp(0, h - 1);
    final window = IntRect(
      clampX(sourceRect.left.toDouble()),
      clampY(sourceRect.top.toDouble()),
      clampX(sourceRect.right.toDouble()),
      clampY(sourceRect.bottom.toDouble()),
    );
    if (window.width < 3 || window.height < 3) return null;
    try {
      final data = await decoded.image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      if (data == null) return null;
      final rgba = RgbaImage(w, h, data.buffer.asUint8List());
      final estimate = estimateTextColor(rgba, window);
      return estimate?.textRgb;
    } catch (e) {
      // 读像素失败不该让识别整体失败：颜色是可选项，文字才是这次的目的。
      Log.info('Studio Block', 'colour sample failed: $e');
      return null;
    }
  }

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
      // P33 ⑦b：颜色**只在"上次是自动取的"时**才跟着更新。用户手动调过颜色
      // 的块（`_color_auto` 键已被删掉）绝不能被一次重新识别悄悄覆盖 —— 那是
      // "我调好的字色又变回去了"这类最难查的投诉。
      List<int>? autoColor;
      if (block.colorIsAuto) {
        autoColor = await _sampleTextColor(
          decoded,
          IntRect(crop.left, crop.top, crop.right, crop.bottom),
        );
      }
      _editBlock(
        pageKey,
        _selectedBlock,
        'Recognise',
        (b) {
          b.sourceText = text;
          if (autoColor != null && b.colorIsAuto) {
            b.fontFormat?.foregroundColor = autoColor;
          }
        },
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
  /// 🔴 默认**单页 + 缩放**：打开翻译工程时用户要的是"这一页对得不对"的精细对照，
  /// 长画布把 97 页压成一条、字号被缩到认不出字，正好背道而驰。单页模式一屏一
  /// 页、可缩放，校对/排版都顺手（P6 用户要求）。需要纵览再切长画布即可。
  bool _stripMode = false;

  /// Marquee ("draw a new box") mode.
  ///
  /// 🔴 An explicit mode rather than "drag on empty space draws a box": a drag
  /// that starts inside the selected block is far more often a **move** than an
  /// intent to replace the selection, and guessing wrong would make the block
  /// the user just positioned jump somewhere else. A mode costs one click and
  /// removes the ambiguity entirely; it also auto-exits after a successful draw
  /// so consecutive blocks can be placed without re-arming.
  bool _marqueeMode = false;

  /// B-2 跨页框选模式（仅长画布可用）。
  ///
  /// 🔴 与 [_marqueeMode] 一样是**一次性模式**（画完自动关），且两者**互斥**：
  /// 跨页框选盖住整条条带、吃掉页内手势，"在某一页里拖框移动块"与"跨缝拖框
  /// 建块"在手势上无法共存，只能靠显式模式二选一。仅在 [_stripMode] 下可用 ——
  /// 单页模式里根本没有相邻页，跨缝无从谈起。
  bool _spanMode = false;

  /// B-3 建组点选模式（仅长画布）。
  ///
  /// 🔴 与 [_marqueeMode] / [_spanMode] 互斥，但**不**用全屏手势覆盖层：建组
  /// 要跨多页滚着点，覆盖层会吃掉滚轮。它只让页内块变成"只读 + 点选即加入
  /// 名单"，见 `studio_scroll_canvas.dart`。
  bool _groupPickMode = false;

  /// 建组点选名单：`(块真身页, 真身下标)`，可再点取消。完成时排序、补 `_uid`、
  /// 写 `_groups`。
  final List<({String page, int index})> _groupDraft = [];

  /// A-2 右栏 Tab：0 块 / 1 组 / 2 运行；折叠态另由 [_panelCollapsed] 控制。
  int _panelTab = 0;
  bool _panelCollapsed = false;

  /// 组 Tab 里手动选择的组（下拉），null = 跟随当前选中块所属组。
  String? _chosenGroupId;

  /// A-1 左侧缩略图栏（默认关）。
  ///
  /// 🔴 它是为"人眼逐条检查**页间截断**"服务的**临时视图**，不是翻页手段：
  /// 常开会让左栏一直占着 240px 宽，而绝大多数编辑动作并不需要它。默认值来自
  /// [thumbRailDefaultOn]（界面与断言共用同一个常量）。
  bool _thumbRail = thumbRailDefaultOn;

  /// 页尺寸缓存（页 key → 尺寸），缩略图栏据此隐藏横版页（A-1.4）。
  ///
  /// 🔴 key 是页 key 而不是下标 —— 下标会随页序变化。与 B-1 的缝视图共用
  /// 同一份尺寸（都只要"这页多宽多高"，重复读头没有意义）。读不出尺寸时为
  /// `null`，调用方据此**保留显示**那一页。
  final Map<String, PageSize?> _pageSizeCache = {};

  /// P30：在**连续长画布**中被隐藏的页键（持久化在工程 `_strip_hidden`）。
  ///
  /// 纯视图层：不删任何块/跨页/组数据，单页模式照常显示。长画布据此不构建
  /// 这些页（其块/跨页片段自然也不画）。
  Set<String> _hiddenPages = <String>{};

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

  /// B-2：跨缝拖框松手 —— [parts] 已由长画布**按缝切好**（每页一个子矩形）。
  ///
  /// 单段 = 框只落在一页内 → 走普通建块（与 [_onMarquee] 同一条路径）。
  /// 多段 = 跨缝 → 校验（同宽 / 不越页 / 同页不重叠）后，在**顶页**落一个普通块，
  /// 再给它补写 `_span`（per-page 子矩形 = 真相，D8）与惰性 `_uid`（D9）。
  void _onSpanMarquee(List<SpanPart> parts) {
    if (!_spanMode) return;
    setState(() => _spanMode = false);
    if (parts.isEmpty) return;
    if (parts.length == 1) {
      _createBlockOn(parts.first.page, parts.first.rect);
      return;
    }
    final span = BlockSpan(parts);
    final reason = validateSpan(span, pageRect: _pageRectOf);
    if (reason != null) {
      // 🔴 D12：两页**同宽**是虚拟坐标的前提，异宽只能拒绝并说明理由 ——
      // 悄悄建一个几何自相矛盾的块，比不建更糟。
      showToast(
        context: context,
        message: reason == spanReasonWidthMismatch
            ? 'The two pages must have the same width.'.tl
            : 'The box could not be turned into a cross-page block.'.tl,
      );
      return;
    }
    // 顶段所在的页（虚拟坐标里最上）承载这个块：块本身落在该页，`_span` 记全部段。
    final head = parts.first;
    _createBlockOn(
      head.page,
      head.rect,
      label: 'Create cross-page block',
      decorate: (block) {
        writeSpan(block, span);
        ensureBlockUid(block);
      },
    );
  }

  /// 在 [pageKey] 这一页上落一个块（[rect] 为**页内像素**矩形），并入 undo 栈。
  ///
  /// [decorate] 在建块之后、入栈之前调用，供跨页块补写 `_span` / `_uid` 这类
  /// 可选键 —— 这样"块长什么样"与"块被谁创建"只有一条路径，不会与
  /// [_createBlockAt] 漂移。
  void _createBlockOn(
    String pageKey,
    IntRect rect, {
    String label = 'Create block',
    void Function(TextBlock block)? decorate,
  }) {
    final project = _project;
    if (project == null) return;
    final page = project.pages[pageKey];
    if (page == null) return;
    final block = TextBlock.createDefault(rect: rect);
    decorate?.call(block);
    final command = captureBlockListEdit(
      page.rawBlocks,
      () => page.addBlock(block),
      pageKey: pageKey,
      label: label,
    );
    if (command.isEmpty) return;
    _history.push(command);
    // 按 identity 选中：`blocks` 会跳过非对象条目，末位下标未必是刚加的那个。
    final selected = page.blocks.indexWhere((b) => identical(b.raw, block.raw));
    setState(() {
      _selectedPageKey = pageKey;
      _selectedBlock = selected < 0 ? page.blocks.length - 1 : selected;
      _revision++;
    });
  }

  /// 某页的页内矩形（`0,0,w,h`），供 [validateSpan] 判定越界/同宽。
  IntRect _pageRectOf(String pageKey) {
    final size = _pageSizeInPixels(pageKey);
    return IntRect(0, 0, size.width.round(), size.height.round());
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
  /// * `untranslated` —— 其中**有原文、还没译文**的块（翻译阶段的输入）；
  /// * `translatedPages` —— **至少有一个译文块**的**页数**（第四段「修图」的
  ///   输入量；口径是页不是块，见 `StudioRunCounts` 的说明）。
  StudioRunCounts _countBlocks(List<String> pages) {
    final project = _project;
    if (project == null) {
      return (
        blocks: 0,
        unrecognized: 0,
        untranslated: 0,
        translatedPages: 0,
      );
    }
    var blocks = 0;
    var unrecognized = 0;
    var untranslated = 0;
    var translatedPages = 0;
    for (final key in pages) {
      final page = project.pages[key];
      if (page == null) continue;
      var pageHasTranslation = false;
      for (final block in page.blocks) {
        blocks++;
        if (block.sourceText.trim().isEmpty) {
          unrecognized++;
        } else if (!block.hasTranslation) {
          untranslated++;
        } else {
          // 🔴 用 `pageHasTranslation` 而不是直接数块：一页里 8 个块只画 1 张
          // `inpainted/`，报 8 会让用户以为要跑 8 次。
          pageHasTranslation = true;
        }
      }
      if (pageHasTranslation) translatedPages++;
    }
    return (
      blocks: blocks,
      unrecognized: unrecognized,
      untranslated: untranslated,
      translatedPages: translatedPages,
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
    // 🔴 **只勾修图**时短路整个文本段循环（2026-10-09）。
    //
    // 不短路的话，每一页都会被"没有块可识别"记一次跳过，最后报成"整章有 N 页
    // 失败" —— 而实际上什么都没做错，用户只是选了第四段。那种红字比不显示更糟。
    // 短路之后这段 run 的语义就是干净的："不改一个字，只出图"。
    final repairOnly = stages.repair &&
        !stages.detect &&
        !stages.recognize &&
        !stages.translate;
    for (final pageKey in repairOnly ? const <String>[] : pages) {
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
          // 🔴 逐页落地也是**模型变更**：下一帧 `_blocksFor` 的 memo 必须放行，
          // 否则这一页刚检出的块要等到整章跑完才出现在画布上（P28 引入投影 memo
          // 后必须在这里补上，`_revision` 的契约本就是"每次模型变更都 ++"）。
          _revision++;
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
    // 🔴 第四段「修图」：位图层的产出**只**由这一句触发（2026-10-09，2026-10-09 续）。
    //
    // 以前出图挂在 `_save()` 末尾，于是**任何一次写盘**都会连带重渲产物 ——
    // 用户反馈的"莫名其妙再生成一次产物"就是那一句。现在：
    //   · Ctrl+S ⇒ 只写 JSON（见 [_save]）；
    //   · 这里 ⇒ 用户在弹窗里勾了「修图」。
    // 只有**一条**出图入口，日志里 `stages.repair` 与产物对账表能对上。
    if (stages.repair) {
      // 🔴 `filter` 用**本页集里已有译文的页**，而不是整个 `pages`：
      // 一页都没有译文的页画出来是一张去字的白页，比原图更糟（用户会以为
      // "翻译把字弄没了"）。`planStudioRun` 的 `nothing-to-repair` 码
      // 已经在勾选阶段挡住"一页译文都没有"，这里再夹一次是为了兜住
      // "只勾了修图 + 检测也勾了"这种组合（检测会造新块，但它们还没译文）。
      final repairable = pages
          .where((k) => project.pages[k]?.hasTranslation ?? false)
          .toSet();
      if (repairable.isEmpty) {
        if (mounted) {
          setState(() => _pipeline.lastMessage =
              'No translated box to repair in this range'.tl);
        }
        Log.info(
          'Studio Pipeline',
          'repair requested but no page has a translated box: '
          'range=${pages.length}',
        );
      } else {
        final (bases, report) = await _regenerateResults(
          dirtyPages: repairable,
          run: runSummary,
        );
        runSummary['repair'] = {
          'pages': repairable.length,
          'skippedNoTranslation': pages.length - repairable.length,
          'bases': bases,
          'written': report,
        };
        Log.info('Studio Pipeline', 'repair done: $runSummary');
      }
    }
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
      // 换了工程 ⇒ 页尺寸缓存整体作废（key 是页 key，跨工程会串）。
      _pageSizeCache.clear();
      // P30：长画布隐藏页随工程读回（_strip_hidden，持久化）。
      _hiddenPages = readHiddenPages(project.raw);
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

  /// 重载当前位图（修图 / 复原后让画布看到新产物）。
  ///
  /// [resetSelection]：翻页时必须 true（新页没有"已选块"）；单块修图 / 复原
  /// 后传 false —— 用户刚在这个块上操作完，重画底图不该顺手取消他的选择。
  Future<void> _loadBase(String pageKey, {bool resetSelection = true}) async {
    final project = _project;
    if (project == null) return;
    final token = ++_baseToken;
    setState(() {
      _loadingBase = true;
      if (resetSelection) {
        _selectedBlock = -1;
        _selectedPageKey = null;
      }
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

  /// 页 → 该页要画的块列表（含跨页块在**本页**上的投影片段）。
  ///
  /// 🔴 **memo，且与撤销栈联动**（P28）。长画布的 [`StudioScrollCanvas`] 在滚动/
  /// 父级 setState 时会为每个**已构建**的页调用本方法；没有 memo 时每帧都要重新
  /// 投影一遍块（以及为跨页片段扫全工程），而 `_revision` 正是"模型变了"的唯一
  /// 信号 —— 编辑、undo/redo、批量运行都 ++ 它。于是索引只在模型真正变化时重建
  /// 一次，滚动期间整段是零成本。
  ///
  /// 🔴 跨页块的**真身只落在顶页**（见 `_onSpanMarquee`，`_span.parts` 是真相）。
  /// 若本方法只返回"存这一页的块"，下页就**什么都不画** —— 用户看到的现象是
  /// "文字块只能存在上页 / 在下页像被下页遮住"。所以这里还要把别的页上、`_span`
  /// 含本页的块，按 per-page 子矩形投影过来。
  List<CanvasTextBlock> _blocksFor(String pageKey) {
    final cache = _blockProjectionCache;
    if (cache == null || cache.revision != _revision) {
      _blockProjectionCache = _BlockProjectionCache(_revision);
    }
    final byPage = _blockProjectionCache!.byPage;
    final hit = byPage[pageKey];
    if (hit != null) return hit;
    final result = _projectBlocks(pageKey);
    byPage[pageKey] = result;
    return result;
  }

  /// [CanvasTextBlock] 列表的投影缓存，整体随 [_revision] 失效。
  _BlockProjectionCache? _blockProjectionCache;

  /// 跨页片段索引：页 key → 画在该页上、真身在别的页的片段。
  ///
  /// 与 [_blockProjectionCache] 同寿命 —— 二者都由 [_revision] 决定何时重建，
  /// 分开放只是为了让"扫全工程找 `_span`"与"逐页投影"各自只做一次。
  ({int revision, Map<String, List<_SpanFragment>> byPage})? _spanFragmentCache;

  /// 建立（或复用）跨页片段索引。只扫**有 `_span` 的块**，单页块直接跳过。
  Map<String, List<_SpanFragment>> _spanFragments() {
    final cached = _spanFragmentCache;
    if (cached != null && cached.revision == _revision) return cached.byPage;
    final byPage = <String, List<_SpanFragment>>{};
    final project = _project;
    if (project != null) {
      for (final ownerKey in project.pageOrder) {
        final page = project.pages[ownerKey];
        if (page == null) continue;
        for (var i = 0; i < page.blocks.length; i++) {
          final span = readSpan(page.blocks[i]);
          if (span == null) continue;
          for (final part in span.parts) {
            // 真身所在页由它自己的块列表覆盖（用 `xyxy`），这里只投别页。
            if (part.page == ownerKey) continue;
            byPage.putIfAbsent(part.page, () => <_SpanFragment>[]).add(
                  _SpanFragment(ownerKey: ownerKey, ownerIndex: i, rect: part.rect),
                );
          }
        }
      }
    }
    _spanFragmentCache = (revision: _revision, byPage: byPage);
    return byPage;
  }

  /// 真的去投影一页：本页自己的块 + `_span` 落在本页的片段。
  List<CanvasTextBlock> _projectBlocks(String pageKey) {
    final result = <CanvasTextBlock>[];
    final page = _project?.pages[pageKey];
    if (page != null) {
      for (var i = 0; i < page.blocks.length; i++) {
        result.add(_toCanvasBlock(page.blocks[i], i, contextPageKey: pageKey));
      }
    }
    for (final fragment in _spanFragments()[pageKey] ?? const <_SpanFragment>[]) {
      final ownerPage = _project?.pages[fragment.ownerKey];
      if (ownerPage == null) continue;
      if (fragment.ownerIndex < 0 ||
          fragment.ownerIndex >= ownerPage.blocks.length) {
        continue;
      }
      final rect = fragment.rect;
      result.add(
        _toCanvasBlock(
          ownerPage.blocks[fragment.ownerIndex],
          fragment.ownerIndex,
          rectOverride: Rect.fromLTRB(
            rect.left.toDouble(),
            rect.top.toDouble(),
            rect.right.toDouble(),
            rect.bottom.toDouble(),
          ),
          ownerPageKey: fragment.ownerKey,
        ),
      );
    }
    return result;
  }

  // ── B-3/B-4：组投影（随 [_revision] 失效，与块投影同纪律） ──────────────

  _GroupProjection? _groupProjectionCache;

  /// 读 `_groups` 并建立 `"<page>#<uid>" → 组标记` 反查表。
  ///
  /// 🔴 只在模型变化（[_revision]）时重建一次：长画布每帧为每页投影块，逐块
  /// 反查必须是 O(1) 表查，不能每次扫全组。同一块属于多组时，序号标记取**最后
  /// 一组**（组装饰仍按各自 groupId 聚合，两套颜色都会画）。
  _GroupProjection get _groupProjection {
    final cached = _groupProjectionCache;
    if (cached != null && cached.revision == _revision) return cached;
    final projection = _GroupProjection(_revision);
    final project = _project;
    if (project != null) {
      final groups = readGroups(project.raw);
      projection.groups.addAll(groups);
      for (final group in groups.values) {
        for (var i = 0; i < group.members.length; i++) {
          final member = group.members[i];
          projection.tags[member.key] = _GroupTag(
            member.key,
            group.id,
            i + 1,
            group.mode == GroupMode.link,
          );
        }
      }
    }
    _groupProjectionCache = projection;
    return projection;
  }

  /// 块（真身页/真身下标）的组标记；没有组返回 null。
  _GroupTag? _tagOf(String? ownerPageKey, TextBlock block) {
    final page = ownerPageKey ?? _selectedPageKey;
    final uid = blockUid(block);
    if (page == null || uid == null) return null;
    return _groupProjection.tags['$page#$uid'];
  }

  /// 建组名单里是否已点选某真身（再点 = 取消）。
  bool _isPicked(String pageKey, int index) =>
      _groupDraft.any((d) => d.page == pageKey && d.index == index);

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
      _spanMode = false;
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
    final key = _pageKeys.isEmpty ? null : _pageKeys[_pageIndex];
    if (page == null) return const [];
    final result = <CanvasTextBlock>[];
    for (var i = 0; i < page.blocks.length; i++) {
      result.add(_toCanvasBlock(page.blocks[i], i, contextPageKey: key));
    }
    return result;
  }

  CanvasTextBlock _toCanvasBlock(
    TextBlock block,
    int index, {
    Rect? rectOverride,
    String? ownerPageKey,
    String? contextPageKey,
  }) {
    final format = block.fontFormat;
    final box = block.xyxy;
    // 🔴 组反查用的页键与「投影片段」标记是**两件事**（P30 教训）：
    // 自有块 ownerPageKey 必须是 null（否则 hitTestMovableCanvasBlocks 会把它
    // 当片段跳过 ⇒ 整块拖不动），但组/picked 反查仍要知道它属于哪一页。
    final lookupPage = contextPageKey ?? ownerPageKey ?? _selectedPageKey;
    final tag = _tagOf(lookupPage, block);
    return CanvasTextBlock(
      index: index,
      rect: rectOverride ?? Rect.fromLTRB(box[0], box[1], box[2], box[3]),
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
      ownerPageKey: ownerPageKey,
      // B-3/B-4：组装饰（nest 大框 / link 连线 / 序号）与建组点选高亮。
      groupId: tag?.groupId,
      groupOrdinal: tag?.ordinal ?? -1,
      groupIsLink: tag?.isLink ?? false,
      picked: _isPicked(lookupPage ?? '', index),
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
      // A-2：点选一个真实块时默认跳块 Tab（面板若折叠则只换 Tab 不展开，
      // 避免打断正在看图的用户）；空点（-1）不改 Tab。
      if (index >= 0) _panelTab = 0;
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

  /// P31：某页当前**可整体缩放**的 nest 组外框（成员并集，页像素）。
  ///
  /// 任一条件不满足就返回 null（不画手柄、不可拖）：
  /// 1. 当前选中块就在 [pageKey]、且块上有 `_uid` 与组标记；
  /// 2. 组形态为 nest（link 只有连线，没有"外框"语义）；
  /// 3. 组的**全部**成员都在本页，且都能按 `_uid` 解析到真身块 —— 跨页组
  ///    不支持整体缩放：两页坐标原点不同，一个缩放因子没有良好定义（用户
  ///    2026-10-11 选定的整体等比语义先覆盖同页 nest 组）。
  ///
  /// 返回的成员下标是**投影列表**下标：本页真身块在投影里总排在跨页片段
  /// 之前且下标等于 `page.blocks` 下标（见 [_projectBlocks]）。
  CanvasGroupFrame? _activeGroupFrameFor(String pageKey) {
    final selPage = _selectedPageKey;
    final selIndex = _selectedBlock;
    if (selPage != pageKey || selIndex < 0) return null;
    final page = _project?.pages[pageKey];
    if (page == null || selIndex >= page.blocks.length) return null;
    final uid = blockUid(page.blocks[selIndex]);
    if (uid == null) return null;
    final projection = _groupProjection;
    final tag = projection.tags['$pageKey#$uid'];
    if (tag == null || tag.isLink) return null;
    final group = projection.groups[tag.groupId];
    if (group == null || group.mode != GroupMode.nest) return null;

    final byUid = <String, int>{};
    for (var i = 0; i < page.blocks.length; i++) {
      final u = blockUid(page.blocks[i]);
      if (u != null) byUid[u] = i;
    }
    final memberIndices = <int>[];
    for (final member in group.members) {
      if (member.page != pageKey) return null; // 跨页组：不出手柄
      final i = byUid[member.uid];
      if (i == null) return null; // 孤儿引用：不提供缩放
      memberIndices.add(i);
    }
    IntRect? rectAt(GroupMemberRef ref) {
      if (ref.page != pageKey) return null;
      final i = byUid[ref.uid];
      if (i == null) return null;
      final x = page.blocks[i].xyxy;
      return IntRect(
        x[0].round(),
        x[1].round(),
        x[2].round(),
        x[3].round(),
      );
    }

    final bounds = groupBounds(group.members, rectOf: rectAt);
    if (bounds == null) return null;
    return CanvasGroupFrame(
      groupId: group.id,
      bounds: Rect.fromLTRB(
        bounds.left.toDouble(),
        bounds.top.toDouble(),
        bounds.right.toDouble(),
        bounds.bottom.toDouble(),
      ),
      memberIndices: memberIndices,
    );
  }

  /// P31：nest 组外框整体缩放的**提交端**（一次撤销步）。
  ///
  /// 画布回报拖拽开始/结束时的并集框（页像素）。落盘前在**当前模型**上重算
  /// 成员并集（不盲信画布的旧框：防止拖动期间模型已被别的路径改过导致几何
  /// 基准漂移），再用纯函数 [scaleRectsToBounds] 给每个成员写新 `xyxy`。
  /// 整块列表一次快照（与删除同路径），所以整组缩放是 **Ctrl+Z 的一步**。
  void _resizeGroup(
    String pageKey,
    String groupId,
    Rect oldBounds,
    Rect newBounds,
  ) {
    final page = _project?.pages[pageKey];
    if (page == null) return;
    final group = _groupProjection.groups[groupId];
    if (group == null || group.mode != GroupMode.nest) return;

    final blocks = <TextBlock>[];
    final rects = <IntRect>[];
    var left = 0, top = 0, right = 0, bottom = 0;
    var have = false;
    for (final ref in group.members) {
      if (ref.page != pageKey) return; // 拖拽期间组成员变了，放弃提交
      final block = findBlockByUid(page.blocks, ref.uid);
      if (block == null) return;
      final x = block.xyxy;
      final r = IntRect(
        x[0].round(),
        x[1].round(),
        x[2].round(),
        x[3].round(),
      );
      blocks.add(block);
      rects.add(r);
      if (!have) {
        left = r.left;
        top = r.top;
        right = r.right;
        bottom = r.bottom;
        have = true;
      } else {
        if (r.left < left) left = r.left;
        if (r.top < top) top = r.top;
        if (r.right > right) right = r.right;
        if (r.bottom > bottom) bottom = r.bottom;
      }
    }
    if (!have) return;
    final union = IntRect(left, top, right, bottom);
    final target = IntRect(
      newBounds.left.round(),
      newBounds.top.round(),
      newBounds.right.round(),
      newBounds.bottom.round(),
    );
    // 亚像素 no-op 与 [_resizeBlock] 同一条门槛：避免给撤销栈塞空步。
    if ((target.left - union.left).abs() < 1 &&
        (target.top - union.top).abs() < 1 &&
        (target.width - union.width).abs() < 1 &&
        (target.height - union.height).abs() < 1) {
      return;
    }
    final mapped = scaleRectsToBounds(
      oldBounds: union,
      newBounds: target,
      rects: rects,
    );
    final command = captureBlockListEdit(
      page.rawBlocks,
      () {
        for (var i = 0; i < blocks.length; i++) {
          final r = mapped[i];
          blocks[i].xyxy = [
            r.left.toDouble(),
            r.top.toDouble(),
            r.right.toDouble(),
            r.bottom.toDouble(),
          ];
        }
      },
      pageKey: pageKey,
      label: 'Resize group',
    );
    if (command.isEmpty) return;
    _history.push(command);
    setState(() => _revision++);
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
    // P30：撤销可能回退的是 _strip_hidden 的切换，集合要从 raw 重读。
    final project = _project;
    setState(() {
      if (project != null) _hiddenPages = readHiddenPages(project.raw);
      _revision++;
    });
  }

  void _redo() {
    if (!_history.redo()) return;
    final project = _project;
    setState(() {
      if (project != null) _hiddenPages = readHiddenPages(project.raw);
      _revision++;
    });
  }

  /// Ctrl+S: writes the project JSON. **Nothing else** (2026-10-09 用户修订).
  ///
  /// 🔴 **保存不再自动出图**。此前这里有一句
  /// `unawaited(_regenerateResults(dirtyPages: dirtyPages, run: run))`，
  /// 于是"保存"这个动作会**顺带**重渲一遍 `mask/` `inpainted/` `result/`。
  /// 用户反馈的原话是"拒绝在运行对整个章节进行自动化之后再莫名其妙的使用
  /// 一次产物生成" —— 那句话的实质是：**位图层的产出必须由一个明确的、
  /// 用户看得见的选择来触发**，而不是任何一次写盘顺带捎上。
  ///
  /// 为什么这不只是"少做一件事"：`inpainted/` 一旦写出，原图上的字**已经被
  /// 算法抹掉**，用户想"框歪了，重画一下"就得重新下载原图。把一个不可逆的
  /// 操作挂在一个随时会按的快捷键上，是把不可逆性藏了起来。
  ///
  /// 出图现在只有一条路：运行弹窗里的**第四段「修图」**（[StudioRunStages.repair]）。
  /// 用户在跑修图之前，可以先看块、拖块、改完再跑。
  ///
  /// 参数 [run] 仍然透传给对账表 —— 它记的是"这一轮跑了什么"，与出不出图无关。
  Future<bool> _save({Map<String, Object?>? run}) async {
    final project = _project;
    if (project == null) return false;
    final messenger = context;
    try {
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
      return true;
    } catch (e, s) {
      Log.error('Translation Studio', 'Save failed', s);
      if (!mounted) return false;
      messenger.showMessage(message: 'Save failed: @a'.tlParams({'a': e}));
      return false;
    }
  }

  /// 把一种产物（`mask` / `inpainted` / `result`）原子写到工程目录，
  /// 目录不存在时先建。路径规则与 [ProjectWriter] 完全一致
  /// （`<workspace>/<kind>/<pageStem>.png`）。
  Future<void> _writeArtifactBytes(
    String root,
    ProjectArtifactKind kind,
    String pageKey,
    Uint8List bytes,
  ) async {
    final dir = Directory(ProjectWriter.artifactDirectory(root, kind));
    if (!dir.existsSync()) await dir.create(recursive: true);
    final target = File(
      _project!.artifactPath(kind.directoryName, pageKey, root: root),
    );
    await TranslationProjectIo.writeBytesAtomically(target, bytes);
  }

  /// 重画这一页的 `result/` 并落盘（在 mask/inpainted 写完**之后**调 ——
  /// 顺序契约同 [_regenerateResults]）。
  ///
  /// [renderProjectResultPage] 返回 null（这页已没有任何可填字的块）时，
  /// **删掉**旧的 result 而不是保留：保留会让阅读器继续展示一张带着旧字的
  /// 成品图，把刚刚的复原/抹字完全遮住。
  Future<void> _rerenderResultPage(
    TranslationProject project,
    String root,
    String pageKey,
  ) async {
    final bytes = await renderProjectResultPage(project, pageKey);
    final target = File(project.artifactPath(
      ProjectArtifactKind.result.directoryName,
      pageKey,
      root: root,
    ));
    if (bytes == null) {
      if (target.existsSync()) {
        await target.delete();
        Log.info('Translation Studio', 'result removed (nothing to letter): $target');
      }
      return;
    }
    await _writeArtifactBytes(
      root,
      ProjectArtifactKind.result,
      pageKey,
      bytes,
    );
  }

  /// 单块修图：只抹掉当前选中块的原字并在该框填译文。
  ///
  /// 🔴 这是**整页修图**（[stages.repair]）的收窄版本 —— 同一条 mask →
  /// inpaint → result 路径，但范围锁定为当前选中的**一个块**。用户可以
  /// 先在工作室里核对块位置（这是不可逆操作的前提），再只对这一块跑修图。
  ///
  /// 像素流程（纯 Dart 核心在 `block_artifacts.dart`，可 headless 断言）：
  /// 1. 原图全分辨率解码（拒绝降采样 —— 块坐标是源像素，同整页路径的契约）；
  /// 2. 用原图的**副本**只擦这一块（`buildMaskPage` + `TextInpainter.erase`）；
  /// 3. 只在**本块字形掩膜像素**上合并进现有 inpainted（其他块的底图不动，
  ///    也绝不对已抹底图重复 inpaint）；
  /// 4. 掩膜与现有 `mask/` 取并集；
  /// 5. 先写 mask + inpainted，再重画整页 result（本块译文出现、他块不丢）。
  Future<void> _repairSelectedBlock() async {
    final project = _project;
    final pageKey = _selectedPageKey;
    final block = _currentBlock;
    if (project == null || pageKey == null || block == null) return;
    if (block.translation.trim().isEmpty) {
      if (mounted) {
        context.showMessage(message: 'This block has no translation yet.'.tl);
      }
      return;
    }
    // B-5：跨页块的抹字/出图**逐页**做（mask/inpainted/result 契约是逐页的）。
    final span = readSpan(block);
    if (span != null && span.isCrossPage) {
      await _repairSpanBlock(project, block, span);
      return;
    }
    final originalFile = File(project.originalPath(pageKey));
    if (!originalFile.existsSync()) {
      if (mounted) {
        context.showMessage(message: 'The original page is missing.'.tl);
      }
      return;
    }
    setState(() => _blockOpBusy = true);
    try {
      final original = await decodeFullResolutionRgba(originalFile);
      if (original == null) {
        if (mounted) {
          context.showMessage(
            message: 'Block repair needs the full-resolution page.'.tl,
          );
        }
        return;
      }
      final rects = block.eraseRects;
      // 字形级掩膜（255 = 本块要抹的笔画）。
      final maskPage = buildMaskPage(original, rects);
      if (maskPage.isEmpty) {
        if (mounted) {
          context.showMessage(
            message: 'No lettering detected inside this block.'.tl,
          );
        }
        return;
      }
      // 在原图**副本**上只擦这一块；块外像素与原图逐字节相同。
      final erased = RgbaImage(
        original.width,
        original.height,
        Uint8List.fromList(original.pixels),
      );
      TextInpainter.erase(erased, rects);

      final root = project.workspace;
      final inpaintedFile = File(project.artifactPath('inpainted', pageKey));
      final existingInpainted = inpaintedFile.existsSync()
          ? await decodeFullResolutionRgba(inpaintedFile)
          : null;
      final merged = mergeRepairedInpainted(
        erasedBlock: erased,
        blockMask: maskPage.pixels,
        existingInpainted: existingInpainted,
      );
      if (merged == null) {
        if (mounted) {
          context.showMessage(
            message: 'Block repair failed: image size mismatch.'.tl,
          );
        }
        return;
      }
      // 掩膜并集：保住在先修过的其他块记录。
      final maskFile = File(project.artifactPath('mask', pageKey));
      Uint8List? existingMask;
      if (maskFile.existsSync()) {
        final decoded = await decodeGreyscaleMask(maskFile);
        if (decoded != null &&
            decoded.width == original.width &&
            decoded.height == original.height) {
          existingMask = decoded.grey;
        }
      }
      final combinedMask = unionMasks(
        added: maskPage.pixels,
        existing: existingMask,
      );

      // 🔴 两阶段顺序：先底图（mask + inpainted），再 result（result 以
      // inpainted 为输入位图）。同 ProjectWriter.inLayeredOrder 契约。
      await _writeArtifactBytes(
        root,
        ProjectArtifactKind.mask,
        pageKey,
        GrayPng.encode(original.width, original.height, combinedMask),
      );
      final originalBytes = await originalFile.readAsBytes();
      final inpaintedPng = await renderTranslatedPage(
        originalBytes,
        RgbaImage(original.width, original.height, merged),
        const [],
        mode: InpaintMode.smart,
      );
      await _writeArtifactBytes(
        root,
        ProjectArtifactKind.inpainted,
        pageKey,
        inpaintedPng,
      );
      await _rerenderResultPage(project, root, pageKey);
      await ArtifactReconciliation.write(project);

      Log.info(
        'Translation Studio',
        'block repaired: page=$pageKey block=$_selectedBlock '
        'strokes=${maskPage.strokes} hadExistingInpainted=${existingInpainted != null}',
      );
      if (LocalManager().isInitialized) LocalManager().notifyListeners();
      if (!mounted) return;
      setState(() {});
      await _loadBase(pageKey, resetSelection: false);
      if (mounted) context.showMessage(message: 'Block repaired.'.tl);
    } catch (e, s) {
      Log.error('Translation Studio', 'block repair failed', s);
      if (mounted) {
        context.showMessage(
          message: 'Block operation failed: @a'.tlParams({'a': e}),
        );
      }
    } finally {
      if (mounted) setState(() => _blockOpBusy = false);
    }
  }

  /// 单块复原原图：把这个块已经被抹掉的像素放回原图。
  ///
  /// 🔴 核心算法路径：`buildRestorationMask`（外扩 ≥30% 的掩膜）→ 与现有
  /// mask **取交**（只盖回"真的被抹过"的像素，防误伤交叠块）→
  /// `restoreErasedPage(original, inpainted, effectiveMask)`。这是 BT 没有
  /// 的能力 —— 按字形级掩膜复原只能盖回原来那几笔字，而 inpaint 的实际
  /// 影响范围比字形大（笔画被抹掉后周围像素被算法改写过），必须外扩。
  ///
  /// 同时**清空本块译文**：底图退回原字后若仍在上面画译文，就是两层字叠在
  /// 一起。清译文走 [_editBlock]（可撤销），但注意撤销只回滚文字、不回滚
  /// 像素（像素的撤销就是再按一次【修图】）。
  Future<void> _restoreOriginalSelectedBlock() async {
    final project = _project;
    final pageKey = _selectedPageKey;
    final block = _currentBlock;
    if (project == null || pageKey == null || block == null) return;
    // B-5：跨页块复原要逐页盖回原字，再统一清译文。
    final span = readSpan(block);
    if (span != null && span.isCrossPage) {
      await _restoreSpanBlock(project, pageKey, block, span);
      return;
    }
    final originalFile = File(project.originalPath(pageKey));
    final inpaintedFile = File(project.artifactPath('inpainted', pageKey));
    final maskFile = File(project.artifactPath('mask', pageKey));
    if (!originalFile.existsSync()) {
      if (mounted) {
        context.showMessage(message: 'The original page is missing.'.tl);
      }
      return;
    }
    if (!inpaintedFile.existsSync() || !maskFile.existsSync()) {
      if (mounted) {
        context.showMessage(
          message: 'Nothing to restore yet — repair this page first.'.tl,
        );
      }
      return;
    }
    setState(() => _blockOpBusy = true);
    try {
      final original = await decodeFullResolutionRgba(originalFile);
      final inpainted = await decodeFullResolutionRgba(inpaintedFile);
      final decodedMask = await decodeGreyscaleMask(maskFile);
      if (original == null) {
        if (mounted) {
          context.showMessage(
            message: 'Block restore needs the full-resolution page.'.tl,
          );
        }
        return;
      }
      if (inpainted == null ||
          inpainted.width != original.width ||
          inpainted.height != original.height) {
        if (mounted) {
          context.showMessage(
            message: 'Block restore failed: image size mismatch.'.tl,
          );
        }
        return;
      }
      if (decodedMask == null ||
          decodedMask.width != original.width ||
          decodedMask.height != original.height) {
        if (mounted) {
          context.showMessage(
            message: 'Block restore failed: image size mismatch.'.tl,
          );
        }
        return;
      }
      final existingMask = decodedMask.grey;
      // 外扩 30% 检测原字，再与"实际被抹"记录取交。
      final dilated = buildRestorationMask(original, block.rect);
      final effective = intersectMasks(dilated, existingMask);
      if (!maskHasAny(effective)) {
        if (mounted) {
          context.showMessage(
            message: 'No erased pixels found for this block.'.tl,
          );
        }
        return;
      }
      final restored = restoreErasedPage(
        original: original,
        inpainted: inpainted,
        mask: effective,
      );
      if (restored == null) {
        if (mounted) {
          context.showMessage(
            message: 'No erased pixels found for this block.'.tl,
          );
        }
        return;
      }
      final remainingMask = subtractMasks(from: existingMask, removed: effective);
      final root = project.workspace;

      // 底图先写，result 后画（顺序契约同上）。
      final originalBytes = await originalFile.readAsBytes();
      final inpaintedPng = await renderTranslatedPage(
        originalBytes,
        RgbaImage(original.width, original.height, restored),
        const [],
        mode: InpaintMode.smart,
      );
      await _writeArtifactBytes(
        root,
        ProjectArtifactKind.inpainted,
        pageKey,
        inpaintedPng,
      );
      // 全 0 的掩膜不落盘：FT 把"已存在的 mask"当权威，写一张全 0 图会把
      // "什么都没抹"伪装成"抹过但没笔画"（renderMaskPage 的同一条理由）。
      if (maskHasAny(remainingMask)) {
        await _writeArtifactBytes(
          root,
          ProjectArtifactKind.mask,
          pageKey,
          GrayPng.encode(original.width, original.height, remainingMask),
        );
      } else if (maskFile.existsSync()) {
        await maskFile.delete();
        Log.info(
          'Translation Studio',
          'mask removed (page fully restored): $maskFile',
        );
      }

      // 清空译文（可撤销的一步），再重画 result —— 本块不再被填字。
      final blockIndex = _selectedBlock;
      _editBlock(
        pageKey,
        blockIndex,
        'Restore original',
        (b) => b.translation = '',
        syncRichText: true,
      );
      await _rerenderResultPage(project, root, pageKey);
      await ArtifactReconciliation.write(project);

      Log.info(
        'Translation Studio',
        'block restored: page=$pageKey block=$blockIndex',
      );
      if (LocalManager().isInitialized) LocalManager().notifyListeners();
      if (!mounted) return;
      setState(() {});
      await _loadBase(pageKey, resetSelection: false);
      if (mounted) {
        context.showMessage(message: 'Original restored for this block.'.tl);
      }
    } catch (e, s) {
      Log.error('Translation Studio', 'block restore failed', s);
      if (mounted) {
        context.showMessage(
          message: 'Block operation failed: @a'.tlParams({'a': e}),
        );
      }
    } finally {
      if (mounted) setState(() => _blockOpBusy = false);
    }
  }

  // ── B-5：跨页块的多页修图 / 复原 / 解跨页 ──────────────────────────────
  //
  // 产物契约（mask → inpainted → result）是**逐页**的，跨页块只是把同一套
  // 单页像素链路在每一页各跑一遍；摊平计划（哪几页、每页哪些矩形）在
  // `span_artifacts.dart`（纯逻辑，headless_p14 已反向断言）。
  // 🔴 与单块路径一样：这些像素操作本环境无渲染表面可验，全部待 GUI 复测。

  /// 跨页块修图：对 `_span` 涉及的**每一页**复刻单块两阶段（mask/inpainted
  /// 合并），全部页写完后统一重画 result 与对账。
  Future<void> _repairSpanBlock(
    TranslationProject project,
    TextBlock block,
    BlockSpan span,
  ) async {
    setState(() => _blockOpBusy = true);
    try {
      final byPage = spanEraseRectsByPage(span);
      final root = project.workspace;
      final touched = <String>{};
      for (final entry in byPage.entries) {
        final pageKey = entry.key;
        final originalFile = File(project.originalPath(pageKey));
        if (!originalFile.existsSync()) {
          Log.info(
            'Translation Studio',
            'span repair skipped (missing original): $pageKey',
          );
          continue;
        }
        final original = await decodeFullResolutionRgba(originalFile);
        if (original == null) continue;
        final maskPage = buildMaskPage(original, entry.value);
        if (maskPage.isEmpty) continue;
        final erased = RgbaImage(
          original.width,
          original.height,
          Uint8List.fromList(original.pixels),
        );
        TextInpainter.erase(erased, entry.value);

        final inpaintedFile =
            File(project.artifactPath('inpainted', pageKey));
        final existingInpainted = inpaintedFile.existsSync()
            ? await decodeFullResolutionRgba(inpaintedFile)
            : null;
        final merged = mergeRepairedInpainted(
          erasedBlock: erased,
          blockMask: maskPage.pixels,
          existingInpainted: existingInpainted,
        );
        if (merged == null) {
          Log.info(
            'Translation Studio',
            'span repair size mismatch: $pageKey',
          );
          continue;
        }
        final maskFile = File(project.artifactPath('mask', pageKey));
        Uint8List? existingMask;
        if (maskFile.existsSync()) {
          final decoded = await decodeGreyscaleMask(maskFile);
          if (decoded != null &&
              decoded.width == original.width &&
              decoded.height == original.height) {
            existingMask = decoded.grey;
          }
        }
        final combinedMask =
            unionMasks(added: maskPage.pixels, existing: existingMask);
        await _writeArtifactBytes(
          root,
          ProjectArtifactKind.mask,
          pageKey,
          GrayPng.encode(original.width, original.height, combinedMask),
        );
        final originalBytes = await originalFile.readAsBytes();
        final inpaintedPng = await renderTranslatedPage(
          originalBytes,
          RgbaImage(original.width, original.height, merged),
          const [],
          mode: InpaintMode.smart,
        );
        await _writeArtifactBytes(
          root,
          ProjectArtifactKind.inpainted,
          pageKey,
          inpaintedPng,
        );
        touched.add(pageKey);
      }
      if (touched.isEmpty) {
        if (mounted) {
          context.showMessage(
            message: 'No lettering detected inside this block.'.tl,
          );
        }
        return;
      }
      for (final pageKey in touched) {
        await _rerenderResultPage(project, root, pageKey);
      }
      await ArtifactReconciliation.write(project);
      Log.info(
        'Translation Studio',
        'span block repaired on ${touched.length} page(s): $touched',
      );
      if (LocalManager().isInitialized) LocalManager().notifyListeners();
      final selected = _selectedPageKey;
      if (!mounted) return;
      setState(() {});
      // 长画布的条带自行解码各页；单页模式只重拉当前展示的页。
      if (!_stripMode && selected != null) {
        await _loadBase(selected, resetSelection: false);
      }
      if (mounted) {
        context.showMessage(
          message:
              'Repaired on @a page(s).'.tlParams({'a': '${touched.length}'}),
        );
      }
    } catch (e, s) {
      Log.error('Translation Studio', 'span repair failed', s);
      if (mounted) {
        context.showMessage(
          message: 'Block operation failed: @a'.tlParams({'a': e}),
        );
      }
    } finally {
      if (mounted) setState(() => _blockOpBusy = false);
    }
  }

  /// 把一组 [SpanPart]（可只给尾页段 = 解跨页；给全部段 = 跨页复原）在各自
  /// 页上盖回原字。逐段与该页现有 mask 取交、从剩余 mask 里扣掉，**只写真的
  /// 被抹过的像素**（与单块复原同一条核心路径）。返回真正改动的页。
  Future<Set<String>> _restoreSpanParts(
    TranslationProject project,
    List<SpanPart> parts,
  ) async {
    final touched = <String>{};
    final root = project.workspace;
    final byPage = spanEraseRectsByPage(BlockSpan(parts));
    for (final entry in byPage.entries) {
      final pageKey = entry.key;
      final originalFile = File(project.originalPath(pageKey));
      final inpaintedFile = File(project.artifactPath('inpainted', pageKey));
      final maskFile = File(project.artifactPath('mask', pageKey));
      if (!originalFile.existsSync() ||
          !inpaintedFile.existsSync() ||
          !maskFile.existsSync()) {
        continue;
      }
      final original = await decodeFullResolutionRgba(originalFile);
      final inpainted = await decodeFullResolutionRgba(inpaintedFile);
      final decodedMask = await decodeGreyscaleMask(maskFile);
      if (original == null ||
          inpainted == null ||
          decodedMask == null ||
          inpainted.width != original.width ||
          inpainted.height != original.height ||
          decodedMask.width != original.width ||
          decodedMask.height != original.height) {
        continue;
      }
      var remaining = decodedMask.grey;
      // restoreErasedPage 返回原始 RGBA 字节（与单块复原同路径），不是
      // RgbaImage 包装；写 artifact 时再包回去。
      var restored = inpainted.pixels;
      var changed = false;
      for (final rect in entry.value) {
        final dilated = buildRestorationMask(original, rect);
        final effective = intersectMasks(dilated, remaining);
        if (!maskHasAny(effective)) continue;
        final next = restoreErasedPage(
          original: original,
          inpainted: RgbaImage(original.width, original.height, restored),
          mask: effective,
        );
        if (next == null) continue;
        restored = next;
        remaining = subtractMasks(from: remaining, removed: effective);
        changed = true;
      }
      if (!changed) continue;
      final originalBytes = await originalFile.readAsBytes();
      final inpaintedPng = await renderTranslatedPage(
        originalBytes,
        RgbaImage(original.width, original.height, restored),
        const [],
        mode: InpaintMode.smart,
      );
      await _writeArtifactBytes(
        root,
        ProjectArtifactKind.inpainted,
        pageKey,
        inpaintedPng,
      );
      if (maskHasAny(remaining)) {
        await _writeArtifactBytes(
          root,
          ProjectArtifactKind.mask,
          pageKey,
          GrayPng.encode(original.width, original.height, remaining),
        );
      } else if (maskFile.existsSync()) {
        await maskFile.delete();
        Log.info(
          'Translation Studio',
          'mask removed (span page fully restored): $maskFile',
        );
      }
      touched.add(pageKey);
    }
    return touched;
  }

  /// 跨页块复原：逐页盖回原字 + 清空本块译文（可撤销；像素不可逆同单块约定）。
  Future<void> _restoreSpanBlock(
    TranslationProject project,
    String headPageKey,
    TextBlock block,
    BlockSpan span,
  ) async {
    setState(() => _blockOpBusy = true);
    try {
      final touched = await _restoreSpanParts(project, [...span.parts]);
      if (touched.isEmpty) {
        if (mounted) {
          context.showMessage(
            message: 'No erased pixels found for this block.'.tl,
          );
        }
        return;
      }
      _editBlock(
        headPageKey,
        _selectedBlock,
        'Restore original',
        (b) => b.translation = '',
        syncRichText: true,
      );
      final root = project.workspace;
      for (final pageKey in touched) {
        await _rerenderResultPage(project, root, pageKey);
      }
      await ArtifactReconciliation.write(project);
      Log.info(
        'Translation Studio',
        'span block restored on ${touched.length} page(s): $touched',
      );
      if (LocalManager().isInitialized) LocalManager().notifyListeners();
      if (!mounted) return;
      setState(() {});
      if (!_stripMode) await _loadBase(headPageKey, resetSelection: false);
      if (mounted) {
        context.showMessage(
          message: 'Original restored on @a page(s).'.tlParams(
            {'a': '${touched.length}'},
          ),
        );
      }
    } catch (e, s) {
      Log.error('Translation Studio', 'span restore failed', s);
      if (mounted) {
        context.showMessage(
          message: 'Block operation failed: @a'.tlParams({'a': e}),
        );
      }
    } finally {
      if (mounted) setState(() => _blockOpBusy = false);
    }
  }

  /// 解跨页：尾页像素复原 + 真身块缩回顶段子矩形 + 清 `_span`。
  ///
  /// 顶页的抹痕/译文原样保留（块在那一页上继续成立）；尾页上本块不复存在，
  /// 抹痕必须盖回，否则留下无主空白。
  Future<void> _dissolveSelectedSpanBlock() async {
    final project = _project;
    final pageKey = _selectedPageKey;
    final block = _currentBlock;
    if (project == null || pageKey == null || block == null) return;
    final span = readSpan(block);
    if (span == null || !span.isCrossPage) return;
    final plan = dissolveSpanPlan(span);
    if (plan == null) return;
    setState(() => _blockOpBusy = true);
    try {
      // 只复原顶段之外的尾页段（parts 去重保序，同页多段会一起盖）。
      final tailParts = <SpanPart>[
        for (var i = 1; i < span.parts.length; i++) span.parts[i],
      ];
      final touched = await _restoreSpanParts(project, tailParts);
      final head = plan.headRect;
      _editBlock(
        pageKey,
        _selectedBlock,
        'Split back to one page',
        (b) {
          b.xyxy = [
            head.left.toDouble(),
            head.top.toDouble(),
            head.right.toDouble(),
            head.bottom.toDouble(),
          ];
          clearSpan(b);
        },
        // 块框几何变了，rich_text 的排版结果必须按新框重算。
        syncRichText: true,
      );
      if (touched.isNotEmpty) {
        final root = project.workspace;
        for (final touchedPage in touched) {
          await _rerenderResultPage(project, root, touchedPage);
        }
        await ArtifactReconciliation.write(project);
      }
      Log.info(
        'Translation Studio',
        'span dissolved: head=$pageKey tail restored=$touched',
      );
      if (LocalManager().isInitialized) LocalManager().notifyListeners();
      if (!mounted) return;
      setState(() {});
      if (!_stripMode) await _loadBase(pageKey, resetSelection: false);
      if (mounted) {
        context.showMessage(
          message: touched.isEmpty
              ? 'Split back to one page.'.tl
              : 'Split back; @a page(s) restored.'.tlParams(
                  {'a': '${touched.length}'},
                ),
        );
      }
    } catch (e, s) {
      Log.error('Translation Studio', 'span dissolve failed', s);
      if (mounted) {
        context.showMessage(
          message: 'Block operation failed: @a'.tlParams({'a': e}),
        );
      }
    } finally {
      if (mounted) setState(() => _blockOpBusy = false);
    }
  }

  // ── B-3/B-4：文字块小组 ──────────────────────────────────────────────────
  //
  // 数据流纪律（与块编辑同一条）：
  // * 块级改动（惰性 `_uid`、逐块译文、rich_text）= captureBlockEdit；
  // * 工程级改动（`_groups`）= captureSeamReviewEdit（通用工程 Map 快照）；
  // * 一次语义动作碰两边 = CompoundEditCommand 合成**一个撤销步**；
  // * 任何写回后 `_revision++`，组投影随它重建。

  /// 进/出建组点选模式（与框选/跨页框选互斥；名单随退出清空）。
  ///
  /// P32：不再限长画布 —— 单页（含缩放）模式同样可点选建组；跨页点选时用
  /// 页轨/翻页按钮换页，名单保留（见 [_selectPage] / 模式切换处）。
  void _toggleGroupPick() {
    setState(() {
      _groupPickMode = !_groupPickMode;
      if (_groupPickMode) {
        _marqueeMode = false;
        _spanMode = false;
        _groupDraft.clear();
      }
    });
  }

  void _cancelGroupPick() {
    if (!_groupPickMode) return;
    setState(() {
      _groupPickMode = false;
      _groupDraft.clear();
    });
  }

  /// 点选回调（真身页/真身下标；投影片段已由画布回指真身）。再点同一块 = 取消。
  void _onPickBlock(String pageKey, int index) {
    if (_blockAt(pageKey, index) == null) return;
    setState(() {
      final existing = _groupDraft
          .indexWhere((d) => d.page == pageKey && d.index == index);
      if (existing >= 0) {
        _groupDraft.removeAt(existing);
      } else {
        _groupDraft.add((page: pageKey, index: index));
      }
    });
  }

  /// 完成建组：补惰性 `_uid` → 按阅读序排成员 → 写 `_groups`，一个撤销步。
  void _confirmCreateGroup() {
    final project = _project;
    if (project == null) return;
    final picked = <({String page, int index, TextBlock block})>[];
    for (final d in _groupDraft) {
      final block = _blockAt(d.page, d.index);
      if (block != null) {
        picked.add((page: d.page, index: d.index, block: block));
      }
    }
    if (picked.length < 2) {
      context.showMessage(message: 'Pick at least two blocks.'.tl);
      return;
    }
    final commands = <ProjectEditCommand>[];
    final refs = <GroupMemberRef>[];
    for (final p in picked) {
      // 惰性 `_uid`：已有不重铸，保持零字节 diff 的前提。
      if (blockUid(p.block) == null) {
        final command = captureBlockEdit(
          p.block.raw,
          () => ensureBlockUid(p.block),
          pageKey: p.page,
          label: 'Assign block id',
        );
        if (!command.isEmpty) commands.add(command);
      }
      refs.add(GroupMemberRef(p.page, blockUid(p.block)!));
    }
    final ordered = sortMembersReadingOrder(
      refs,
      pageIndex: (page) => _pageKeys.indexOf(page),
      rectOf: (ref) {
        final blocks = project.pages[ref.page]?.blocks ?? const <TextBlock>[];
        return findBlockByUid(blocks, ref.uid)?.rect;
      },
    );
    // 恰好跨相邻两页时记缝（顺序按阅读序，防止点选顺序污染）。
    String? seam;
    final pages = <String>{for (final ref in ordered) ref.page}.toList()
      ..sort((a, b) => _pageKeys.indexOf(a).compareTo(_pageKeys.indexOf(b)));
    if (pages.length == 2 &&
        _pageKeys.indexOf(pages[1]) - _pageKeys.indexOf(pages[0]) == 1) {
      seam = '${pages[0]}|${pages[1]}';
    }
    // P32：按页跨度自动建议形态 —— 同页/相邻两页 nest（大框套小框，含跨缝
    // 断句气泡），跨 ≥3 页或两页不相邻 link（连线）。组面板仍可手切。
    final mode = suggestGroupMode(
      members: ordered,
      pageIndexOf: (page) => _pageKeys.indexOf(page),
    );
    final group = BlockGroup(
      id: mintGroupId(),
      members: ordered,
      seam: seam,
      mode: mode,
    );
    final meta = captureSeamReviewEdit(
      project.raw,
      key: groupKey,
      pageKey: ordered.first.page,
      mutate: () {
        final live = readGroups(project.raw);
        live[group.id] = group;
        writeGroups(project.raw, live);
      },
      label: 'Create group',
    );
    commands.add(meta);
    final compound = CompoundEditCommand(commands, label: 'Create group');
    if (compound.isEmpty) return;
    _history.push(compound);
    final firstRef = ordered.first;
    final firstIndex = project.pages[firstRef.page]?.blocks
            .indexWhere((b) => blockUid(b) == firstRef.uid) ??
        -1;
    setState(() {
      _revision++;
      _groupPickMode = false;
      _groupDraft.clear();
      _chosenGroupId = group.id;
      _panelTab = 1;
      _panelCollapsed = false;
      _selectedPageKey = firstRef.page;
      _selectedBlock = firstIndex;
    });
  }

  /// 通用：改 `_groups` 并入一次撤销栈。
  void _commitGroups(
    String? pageKeyHint,
    String label,
    void Function(Map<String, BlockGroup> groups) mutate,
  ) {
    final project = _project;
    if (project == null) return;
    final command = captureSeamReviewEdit(
      project.raw,
      key: groupKey,
      pageKey: pageKeyHint ??
          _selectedPageKey ??
          (_pageKeys.isNotEmpty ? _pageKeys.first : ''),
      mutate: () {
        final live = readGroups(project.raw);
        mutate(live);
        writeGroups(project.raw, live);
      },
      label: label,
    );
    if (command.isEmpty) return;
    _history.push(command);
    setState(() => _revision++);
  }

  void _setGroupMode(String groupId, GroupMode mode) {
    _commitGroups(null, 'Change group style', (groups) {
      groups[groupId]?.mode = mode;
    });
  }

  void _setGroupSource(String groupId, String text) {
    _commitGroups(null, 'Edit group source', (groups) {
      groups[groupId]?.source = text.trim().isEmpty ? null : text;
    });
  }

  void _setGroupTranslation(String groupId, String text) {
    _commitGroups(null, 'Edit group translation', (groups) {
      groups[groupId]?.translation = text.trim().isEmpty ? null : text;
    });
  }

  /// 【组合】按成员顺序拼原文写回 group.source（成员块本身一字不改）。
  void _combineGroupSource(String groupId) {
    final project = _project;
    if (project == null) return;
    final group = _groupProjection.groups[groupId];
    if (group == null) return;
    final sources = <String>[
      for (final ref in group.members)
        findBlockByUid(project.pages[ref.page]?.blocks ?? const <TextBlock>[],
                ref.uid)
            ?.sourceText ??
            '',
    ];
    final combined = concatMemberSources(sources);
    if (combined.trim().isEmpty) {
      context.showMessage(
        message: 'Group members have no source text.'.tl,
      );
      return;
    }
    _commitGroups(null, 'Combine group source', (groups) {
      groups[groupId]?.source = combined;
    });
  }

  /// 【翻译一次】：整组只发一次翻译请求，结果存 group.translation。
  Future<void> _translateGroupOnce(String groupId) async {
    final project = _project;
    if (project == null) return;
    final group = _groupProjection.groups[groupId];
    if (group == null) return;
    if ((group.source ?? '').trim().isEmpty) {
      context.showMessage(message: 'Combine the source text first.'.tl);
      return;
    }
    setState(() => _blockOpBusy = true);
    try {
      final lang = _currentSourceLang();
      final attempt = await translateGroupOnce(
        source: group.source,
        translate: (texts) => TranslationDispatcher.translateBatch(
          texts,
          _currentTargetLang(),
          sourceLang: lang,
          sourceLangs: [lang],
          glossary: _glossary,
        ).then((response) => response.texts),
      );
      if (attempt.calls == 0 || (attempt.text ?? '').trim().isEmpty) {
        if (mounted) {
          context.showMessage(message: 'Translate returned nothing new.'.tl);
        }
        return;
      }
      _commitGroups(null, 'Translate group once', (groups) {
        groups[groupId]?.translation = attempt.text!.trim();
      });
    } catch (e, s) {
      Log.error('Translation Studio', 'group translate failed', s);
      if (mounted) context.showMessage(message: 'Translate failed.'.tl);
    } finally {
      if (mounted) setState(() => _blockOpBusy = false);
    }
  }

  void _reorderGroupMember(String groupId, int from, int to) {
    _commitGroups(null, 'Reorder group members', (groups) {
      final g = groups[groupId];
      if (g == null) return;
      if (from < 0 || from >= g.members.length) return;
      final member = g.members.removeAt(from);
      g.members.insert(to.clamp(0, g.members.length), member);
    });
  }

  /// 移除成员；成员删光的组整组删除；被移除且不再被任何组引用的 `_uid` 回收。
  void _removeGroupMember(String groupId, int memberIndex) {
    final project = _project;
    if (project == null) return;
    final group = readGroups(project.raw)[groupId];
    if (group == null ||
        memberIndex < 0 ||
        memberIndex >= group.members.length) {
      return;
    }
    final removed = [group.members[memberIndex]];
    final commands = <ProjectEditCommand>[
      captureSeamReviewEdit(
        project.raw,
        key: groupKey,
        pageKey: group.members.first.page,
        mutate: () {
          final live = readGroups(project.raw);
          final g = live[groupId];
          if (g == null) return;
          g.members.removeAt(memberIndex);
          // 空成员的组无法再 fromRaw 读出（坏记录），直接删组。
          if (g.members.isEmpty) live.remove(groupId);
          writeGroups(project.raw, live);
        },
        label: 'Remove group member',
      ),
      ..._uidRecycleCommands(project, removed),
    ];
    final compound = CompoundEditCommand(commands, label: 'Remove group member');
    if (compound.isEmpty) return;
    _history.push(compound);
    setState(() => _revision++);
  }

  /// 【应用分配】：逐块译文（+rich_text）与组 assignment 记录，一个撤销步。
  ///
  /// 🔴 倒装合法：[values] 可给任意成员任意片段，只要每个成员键都在。
  void _applyGroupAssignment(String groupId, Map<String, String> values) {
    final project = _project;
    if (project == null) return;
    final group = readGroups(project.raw)[groupId];
    if (group == null) return;
    // 先记录"译文会被改动"的块 —— applyGroupAssignment 只设置 translation，
    // 出图需要的 rich_text 由我们在同一撤销步里补同步。
    final changed = <TextBlock>[];
    for (final member in group.members) {
      final text = values[member.key];
      if (text == null) continue;
      final block = findBlockByUid(
        project.pages[member.page]?.blocks ?? const <TextBlock>[],
        member.uid,
      );
      if (block != null && block.translation != text) changed.add(block);
    }
    final commands = <ProjectEditCommand>[
      ...applyGroupAssignment(
        group: group,
        assignment: values,
        blockOf: (ref) => findBlockByUid(
          project.pages[ref.page]?.blocks ?? const <TextBlock>[],
          ref.uid,
        ),
        label: 'Apply group assignment',
      ),
      for (final block in changed)
        captureBlockEdit(
          block.raw,
          () => syncFtRichText(block),
          pageKey: group.members
              .firstWhere(
                (m) =>
                    project.pages[m.page]?.blocks.contains(block) ?? false,
                orElse: () => group.members.first,
              )
              .page,
          label: 'Sync group lettering',
        ),
      captureSeamReviewEdit(
        project.raw,
        key: groupKey,
        pageKey: group.members.first.page,
        mutate: () {
          final live = readGroups(project.raw);
          final assignment = live[groupId]?.assignment;
          if (assignment != null) {
            assignment
              ..clear()
              ..addAll(values);
          }
          writeGroups(project.raw, live);
        },
        label: 'Save group assignment',
      ),
    ];
    final compound = CompoundEditCommand(commands, label: 'Apply group assignment');
    if (compound.isEmpty) return;
    _history.push(compound);
    setState(() => _revision++);
  }

  /// 解组：删组定义 + 回收只被它引用的 `_uid`。块本身一个不动。
  void _dissolveGroup(String groupId) {
    final project = _project;
    if (project == null) return;
    final group = readGroups(project.raw)[groupId];
    if (group == null) return;
    final removed = [...group.members];
    final commands = <ProjectEditCommand>[
      captureSeamReviewEdit(
        project.raw,
        key: groupKey,
        pageKey: group.members.first.page,
        mutate: () {
          final live = readGroups(project.raw);
          live.remove(groupId);
          writeGroups(project.raw, live);
        },
        label: 'Ungroup',
      ),
      ..._uidRecycleCommands(project, removed),
    ];
    final compound = CompoundEditCommand(commands, label: 'Ungroup');
    if (compound.isEmpty) return;
    _history.push(compound);
    setState(() {
      _revision++;
      if (_chosenGroupId == groupId) _chosenGroupId = null;
    });
  }

  /// 对"刚从引用表移除"的成员回收 `_uid`：仍被其他组引用的跳过（纯函数
  /// [referencedMembersByPage] 保证不跨组误删）。
  ///
  /// 🔴 必须在工程 Map 快照命令**捕获之后**调用 —— 那时 live raw 已是删除后
  /// 状态，"仍引用"集合才准确。
  List<ProjectEditCommand> _uidRecycleCommands(
    TranslationProject project,
    List<GroupMemberRef> removed,
  ) {
    final stillReferenced =
        referencedMembersByPage(readGroups(project.raw).values);
    final commands = <ProjectEditCommand>[];
    for (final ref in removed) {
      if (stillReferenced[ref.page]?.contains(ref.uid) ?? false) continue;
      final block = findBlockByUid(
        project.pages[ref.page]?.blocks ?? const <TextBlock>[],
        ref.uid,
      );
      if (block == null) continue;
      final command = captureBlockEdit(
        block.raw,
        () => clearBlockUid(block),
        pageKey: ref.page,
        label: 'Ungroup',
      );
      if (!command.isEmpty) commands.add(command);
    }
    return commands;
  }

  /// 在画布上定位某个组成员（跨页则滚到它所在页），并切到块 Tab 编辑它。
  void _selectGroupMember(GroupMemberRef ref) {
    final pageIndex = _pageKeys.indexOf(ref.page);
    final index = _project?.pages[ref.page]?.blocks
        .indexWhere((b) => blockUid(b) == ref.uid);
    if (index == null || index < 0) return;
    setState(() {
      _selectedPageKey = ref.page;
      _selectedBlock = index;
      _panelTab = 0;
      _panelCollapsed = false;
      if (!_stripMode && pageIndex >= 0) _pageIndex = pageIndex;
    });
    if (_stripMode && pageIndex >= 0) {
      _stripKey.currentState?.scrollToPage(pageIndex);
    } else if (!_stripMode && pageIndex >= 0) {
      _loadBase(ref.page);
    }
  }

  /// 组 Tab 当前要看的组：手动选择优先，否则跟随选中块所属组。
  BlockGroup? get _activeGroup {
    final groups = _groupProjection.groups;
    final chosen = _chosenGroupId;
    if (chosen != null && groups[chosen] != null) return groups[chosen];
    final block = _currentBlock;
    final pageKey = _selectedPageKey;
    final uid = block == null ? null : blockUid(block);
    if (pageKey != null && uid != null) {
      final key = '$pageKey#$uid';
      for (final group in groups.values) {
        if (group.members.any((m) => m.key == key)) return group;
      }
    }
    return null;
  }

  // ── B-2b：识别跨页块（缝窗口拼接 → 现有检测 → 候选确认 → 落块） ─────────
  //
  // 🔴 整条链**只在 GUI 会话可用**：`decodeFullResolutionRgba` 走 dart:ui，
  // 本工作室的 headless 环境没有渲染表面。过滤/映射/切分/校验全在
  // `seam_detect.dart`（纯逻辑，headless_p14 已反向断言），这里只做接线、
  // ONNX 检测与人工确认对话框。

  /// 对"视口中心最近的那道缝"跑跨页检测；候选经人工勾选后才落块。
  Future<void> _detectAcrossSeam() async {
    final project = _project;
    if (project == null || !_stripMode) return;
    final seam = _stripKey.currentState?.nearestSeamToViewport();
    if (seam == null || seam.below >= _pageKeys.length) {
      context.showMessage(
        message: 'No adjacent pages near the viewport center.'.tl,
      );
      return;
    }
    final keyA = _pageKeys[seam.above];
    final keyB = _pageKeys[seam.below];
    final fileA = File(project.originalPath(keyA));
    final fileB = File(project.originalPath(keyB));
    if (!fileA.existsSync() || !fileB.existsSync()) {
      context.showMessage(message: 'The original page is missing.'.tl);
      return;
    }
    setState(() => _blockOpBusy = true);
    try {
      final above = await decodeFullResolutionRgba(fileA);
      final below = await decodeFullResolutionRgba(fileB);
      if (above == null || below == null) {
        if (mounted) {
          context.showMessage(
            message: 'Block repair needs the full-resolution page.'.tl,
          );
        }
        return;
      }
      final window = buildSeamWindow(
        pageAHeight: above.height,
        pageBHeight: below.height,
      );
      if (window == null) {
        if (mounted) {
          context.showMessage(
            message:
                'The seam window is too tall; scroll to a shorter page pair.'.tl,
          );
        }
        return;
      }
      final stitched =
          stitchSeamWindow(above: above, below: below, window: window);
      if (stitched == null) {
        // stitchSeamWindow 唯一的拒绝原因就是两页异宽（D12）。
        if (mounted) {
          context.showMessage(
            message: 'The two pages must have the same width.'.tl,
          );
        }
        return;
      }
      final ocr = await TranslationWorker.instance.ocrPage(
        stitched,
        sourceLang: _currentSourceLang(),
        paths: TranslationModels.workerPaths(),
      );
      final plans = planSeamCandidates(
        windowRects: [for (final b in ocr) b.rect],
        pageAHeight: above.height,
        window: window,
        bands: [
          PageBand(keyA, above.width, above.height),
          PageBand(keyB, below.width, below.height),
        ],
        pageRect: _pageRectOf,
      );
      if (!mounted) return;
      if (plans.isEmpty) {
        context.showMessage(
          message: 'No cross-page text found near this seam.'.tl,
        );
        return;
      }
      // IntRect 没有值相等，按字段把候选对齐回 OCR 文本（同位序 + 同框）。
      String textFor(SeamCandidatePlan plan) {
        for (final b in ocr) {
          final r = b.rect;
          final w = plan.windowRect;
          if (r.left == w.left &&
              r.top == w.top &&
              r.right == w.right &&
              r.bottom == w.bottom) {
            return b.text;
          }
        }
        return '';
      }

      final items = [
        for (final plan in plans) (plan: plan, text: textFor(plan)),
      ];
      final pickedIndexes = await _showSeamCandidatesDialog(
        items,
        pageA: seam.above + 1,
        pageB: seam.below + 1,
      );
      if (pickedIndexes == null || pickedIndexes.isEmpty || !mounted) return;
      _commitSeamCandidates(
        [for (final i in pickedIndexes) items[i]],
      );
    } catch (e, s) {
      Log.error('Translation Studio', 'seam detection failed', s);
      if (mounted) {
        context.showMessage(
          message: 'Block operation failed: @a'.tlParams({'a': e}),
        );
      }
    } finally {
      if (mounted) setState(() => _blockOpBusy = false);
    }
  }

  /// 候选确认对话框。返回勾选的下标集合；取消返回 null。
  Future<Set<int>?> _showSeamCandidatesDialog(
    List<({SeamCandidatePlan plan, String text})> items, {
    required int pageA,
    required int pageB,
  }) {
    final selected = <int>{for (var i = 0; i < items.length; i++) i};
    return showDialog<Set<int>>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text('Candidates crossing the seam'.tl),
              content: SizedBox(
                width: 460,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Page @a / @b'.tlParams({'a': '$pageA', 'b': '$pageB'}),
                      style: ts.s12.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: items.length,
                        itemBuilder: (context, i) {
                          final item = items[i];
                          final parts = item.plan.span.parts;
                          return CheckboxListTile(
                            dense: true,
                            value: selected.contains(i),
                            onChanged: (on) => setDialogState(() {
                              if (on ?? false) {
                                selected.add(i);
                              } else {
                                selected.remove(i);
                              }
                            }),
                            title: Text(
                              item.text.trim().isEmpty
                                  ? '(no text recognised)'.tl
                                  : item.text,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '@a segment(s)'.tlParams(
                                {'a': '${parts.length}'},
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: Text('Cancel'.tl),
                ),
                FilledButton(
                  onPressed: selected.isEmpty
                      ? null
                      : () => Navigator.of(dialogContext).pop(selected),
                  child: Text('Create selected blocks'.tl),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// 把确认过的跨页候选落块（每个候选 = 顶页一个带 `_span`/`_uid` 的块）。
  /// 同顶页的块合并进**一个**列表编辑命令；多顶页再用 [CompoundEditCommand]
  /// 合成一个撤销步。
  void _commitSeamCandidates(
    List<({SeamCandidatePlan plan, String text})> items,
  ) {
    final project = _project;
    if (project == null || items.isEmpty) return;
    final byPage = <String, List<({SeamCandidatePlan plan, String text})>>{};
    for (final item in items) {
      final headPage = item.plan.span.parts.first.page;
      byPage.putIfAbsent(headPage, () => []).add(item);
    }
    final commands = <ProjectEditCommand>[];
    for (final entry in byPage.entries) {
      final page = project.pages[entry.key];
      if (page == null) continue;
      final command = captureBlockListEdit(
        page.rawBlocks,
        () {
          for (final item in entry.value) {
            final head = item.plan.span.parts.first;
            final block = TextBlock.createDefault(rect: head.rect);
            writeSpan(block, item.plan.span);
            ensureBlockUid(block);
            final text = item.text.trim();
            if (text.isNotEmpty) block.sourceText = text;
            page.addBlock(block);
          }
        },
        pageKey: entry.key,
        label: 'Create cross-page block',
      );
      if (!command.isEmpty) commands.add(command);
    }
    if (commands.isEmpty) return;
    final compound =
        CompoundEditCommand(commands, label: 'Create cross-page block');
    _history.push(compound);
    setState(() => _revision++);
    context.showMessage(
      message: '@a cross-page block(s) created'.tlParams(
        {'a': '${items.length}'},
      ),
    );
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
  ///
  /// 返回 `(底图/掩膜数, 成品数)` —— 调用方要把它报进日志与对账表，否则"跑了
  /// 一次修图"这件事在事后无法区分"画了 0 张"与"根本没跑"。
  Future<(int, int)> _regenerateResults({
    Set<String>? dirtyPages,
    Map<String, Object?>? run,
  }) async {
    final project = _project;
    if (project == null) return (0, 0);
    setState(() => _renderingResults = true);
    // 用 `File?` 而不是 `ArtifactReconciliation?`：`write` 返回的是**落盘后的
    // 文件**（要打日志用它的 path），类型只挂在 `write` 的签名上。
    File? reconciliation;
    var baseCount = 0;
    var resultCount = 0;
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
      baseCount = bases.written.length;
      resultCount = report.written.length;
      reconciliation = await ArtifactReconciliation.write(project, run: run);
      Log.info(
        'Translation Studio',
        'artifacts regenerated: bases=$baseCount result=$resultCount '
        '(dirty=${dirtyPages?.length ?? 'all'}) '
        'reconciliation=${reconciliation.path}',
      );
    } catch (e, s) {
      Log.error('Translation Studio', 'result regeneration failed', s);
    } finally {
      if (mounted) setState(() => _renderingResults = false);
    }
    return (baseCount, resultCount);
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
                        : () => setState(() {
                              _marqueeMode = !active;
                              // 与跨页框选互斥（两者都靠拖拽，含义不同）。
                              if (_marqueeMode) _spanMode = false;
                            }),
                  ),
                );
              },
            ),
            // B-2：跨页框选。仅在长画布模式下可用 —— 单页模式里没有相邻页。
            Builder(
              builder: (context) {
                final active = _spanMode;
                final available = project != null && _stripMode;
                return Tooltip(
                  message: active
                      ? 'Cancel cross-page box'.tl
                      : 'Cross-page box select'.tl,
                  child: IconButton(
                    isSelected: active,
                    style: active
                        ? IconButton.styleFrom(
                            backgroundColor:
                                context.colorScheme.tertiaryContainer,
                            foregroundColor:
                                context.colorScheme.onTertiaryContainer,
                          )
                        : null,
                    icon: Icon(
                      active
                          ? Icons.select_all
                          : Icons.select_all_outlined,
                      color: active
                          ? context.colorScheme.onTertiaryContainer
                          : null,
                    ),
                    onPressed: available
                        ? () => setState(() {
                              _spanMode = !active;
                              if (_spanMode) _marqueeMode = false;
                            })
                        : null,
                  ),
                );
              },
            ),
            // B-2b：识别跨页块 —— 对当前视口中心的缝跑检测，候选确认后落块。
            // 仅长画布可用（单页没有相邻页）；不是模式按钮，点一下跑一次。
            IconButton(
              tooltip: 'Detect cross-page block'.tl,
              icon: const Icon(Icons.document_scanner_outlined),
              onPressed: project == null ||
                      !_stripMode ||
                      _blockOpBusy
                  ? null
                  : () => unawaited(_detectAcrossSeam()),
            ),
            // B-3：建组点选。与框选/跨页框选互斥，但不挡滚动（见
            // [_groupPickMode] 与 StudioScrollCanvas.groupPickMode）。
            // P32：单页（含缩放）模式同样可用 —— 同页大框套小框、翻页跨页
            // 点选都走这条通道。
            Builder(
              builder: (context) {
                final active = _groupPickMode;
                final available = project != null;
                return Tooltip(
                  message: active
                      ? 'Cancel grouping'.tl
                      : 'Pick blocks to group'.tl,
                  child: IconButton(
                    isSelected: active,
                    style: active
                        ? IconButton.styleFrom(
                            backgroundColor:
                                context.colorScheme.secondaryContainer,
                            foregroundColor:
                                context.colorScheme.onSecondaryContainer,
                          )
                        : null,
                    icon: Icon(
                      active
                          ? Icons.account_tree
                          : Icons.account_tree_outlined,
                      color: active
                          ? context.colorScheme.onSecondaryContainer
                          : null,
                    ),
                    onPressed: available && !_blockOpBusy
                        ? _toggleGroupPick
                        : null,
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
                      : () => setState(() {
                            _stripMode = !strip;
                            // D14：切进长画布就自动关掉缩略图栏 —— 避免留下
                            // 一个"开着却看不见"（且按钮已置灰）的状态。
                            if (_stripMode) {
                              _thumbRail = false;
                              // P30：长画布的逐页估高要用文件头真值（横版首页
                              // 不能带偏整本竖版页的高度）。
                              unawaited(_ensurePageSizes());
                            } else {
                              // 离开长画布：跨页框选是长画布专属，复位。
                              // 🔴 P32：建组点选**保留** —— 单页模式同样支持
                              // 点选；跨页建组要能在单页间翻页累计名单。
                              _spanMode = false;
                            }
                          }),
                );
              },
            ),
            // A-1：缩略图栏开关，与「连续条漫 / 单页」相邻 —— 两者都是"怎么看
            // 这一章"的**视图模式**。不可用时**置灰**（不隐藏），与日漫的处理
            // 方式统一；四种不可用各一句独立 tooltip（A-1.2）。
            Builder(
              builder: (context) {
                final gate = _thumbRailGate;
                final available = thumbRailAvailable(gate);
                final active = _thumbRailActive;
                return Tooltip(
                  message: _thumbRailTooltip(gate, active),
                  child: IconButton(
                    isSelected: active,
                    style: active
                        ? IconButton.styleFrom(
                            backgroundColor:
                                context.colorScheme.secondaryContainer,
                            foregroundColor:
                                context.colorScheme.onSecondaryContainer,
                          )
                        : null,
                    icon: Icon(
                      active ? Icons.view_list : Icons.view_list_outlined,
                      color: active
                          ? context.colorScheme.onSecondaryContainer
                          : null,
                    ),
                    onPressed: available ? _toggleThumbRail : null,
                  ),
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
            // 术语表（A08 §1.1 · C）：这本工程的译名约定。与"发布成品"同级 ——
            // 它是**工程级**的元数据，不是当前这一页的编辑动作。
            IconButton(
              tooltip: 'Glossary'.tl,
              icon: const Icon(Icons.menu_book_outlined),
              onPressed: project == null ? null : _openGlossary,
            ),
            // 🔴 P1a：AI 翻译设置整块从阅读设置搬进工作室后，这里给一个入口
            // （与详情页「翻译这一章」、阅读器侧栏同源，都改 `ReaderSettings`）。
            // 用 `Icons.translate`，和阅读设置里的 AI 翻译块图标一致。
            IconButton(
              tooltip: 'Translation settings'.tl,
              icon: const Icon(Icons.translate),
              onPressed: project == null
                  ? null
                  : () => context.to(
                        () => StudioTranslationSettingsPage(
                          comicId: widget.comicId,
                        ),
                      ),
            ),
            // 右上角最外侧：「翻译工程」可展开菜单。与列表页那一份是**同一个**
            // 组件（`StudioProjectMenu`）—— 两处各写一遍，加第二个动作时
            // 必然只加一处。
            const StudioProjectMenu(),
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
                        // A-1.3：缩略图模式加宽到 240（D6），紧凑模式保持 156。
                        SizedBox(
                          width: _thumbRailActive ? _kThumbRailWidth : 156,
                          child: _buildPageRail(),
                        ),
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
          // 🔴 P27：这里只在**常驻 Stack** 上条件增删一个覆盖条子，绝不条件重挂
          // 下方的条带 ListView（同帧双 ScrollPosition 的崩溃就是那么来的）。
          child: Stack(
            children: [
              _stripMode
                  // 连续长画布：整章一路滚下去，页内可点选/拖拽文本框。
                  // 翻到哪一页由 strip 回报，页轨/页码随之同步。
                  ? StudioScrollCanvas(
                      key: _stripKey,
                      controller: _stripController,
                      pages: _stripPages(),
                      blocksFor: _blocksFor,
                      editable: true,
                      // P31：把选择态按真身页喂给条带（此前条带恒为 -1，
                      // 长画布里手柄根本不画）。
                      selectedPageKey: _selectedPageKey,
                      selectedIndex: _selectedBlock,
                      groupFrameFor: _activeGroupFrameFor,
                      onSelect: _selectBlock,
                      onMoveBlock: _moveBlock,
                      onResizeBlock: _resizeBlock,
                      onResizeGroup: _resizeGroup,
                      onMarquee: (pageKey, rect) => _onMarquee(rect),
                      marqueeMode: _marqueeMode,
                      spanMode: _spanMode,
                      onSpanMarquee: _onSpanMarquee,
                      groupPickMode: _groupPickMode,
                      onPickBlock: _onPickBlock,
                      hiddenPages: _hiddenPages,
                      probedSizeOf: (pageKey) {
                        final size = _pageSizeCache[pageKey];
                        if (size == null) return null;
                        return (width: size.width, height: size.height);
                      },
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
                          _spanMode = false;
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
                          // P31：nest 组外框整体缩放（单页画布）。
                          groupFrame: key == null ? null : _activeGroupFrameFor(key),
                          onResizeGroup: (groupId, oldBounds, newBounds) {
                            if (key != null) {
                              _resizeGroup(key, groupId, oldBounds, newBounds);
                            }
                          },
                          onMarquee: (rect) => _onMarquee(rect),
                          marqueeMode: _marqueeMode,
                          onEditText: (index) => _selectBlock(key ?? '', index),
                          // P32：单页（含缩放）模式下的建组点选。命中块即
                          // 入名单（再点取消），画布内部已禁用拖/缩/双击等
                          // 普通编辑手势；跨页用页轨/翻页按钮换页，名单保留。
                          groupPickMode: _groupPickMode,
                          onPickBlock: (index) {
                            if (key != null) _onPickBlock(key, index);
                          },
                          base: _base,
                          loading: _loadingBase,
                        ),
                      ),
                    ),
              if (_groupPickMode) _buildGroupPickBar(),
            ],
          ),
        ),
        _buildStatusBar(key),
      ],
    );
  }

  /// B-3：建组点选时的浮动提示/完成条。不吃条带手势（只盖顶部一小条），
  /// 滚动与页内点选都照常。
  Widget _buildGroupPickBar() {
    final scheme = Theme.of(context).colorScheme;
    final count = _groupDraft.length;
    return Positioned(
      top: 8,
      left: 8,
      right: 8,
      child: Align(
        alignment: Alignment.topCenter,
        child: Material(
          elevation: 3,
          borderRadius: BorderRadius.circular(20),
          color: scheme.secondaryContainer,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.touch_app_outlined,
                    size: 18, color: scheme.onSecondaryContainer),
                const SizedBox(width: 8),
                Text(
                  'Finish group (@a picked)'.tlParams({'a': '$count'}),
                  style: ts.s12.copyWith(color: scheme.onSecondaryContainer),
                ),
                const SizedBox(width: 8),
                FilledButton.tonalIcon(
                  onPressed: count < 2 ? null : _confirmCreateGroup,
                  icon: const Icon(Icons.check, size: 18),
                  label: Text('Finish group'.tl),
                ),
                TextButton(
                  onPressed: _cancelGroupPick,
                  child: Text('Cancel'.tl),
                ),
              ],
            ),
          ),
        ),
      ),
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
            // P30：页码右边的小方框 —— 该页在**连续长画布**里显示(✓)/隐藏(✗)。
            // 两种视图模式都显示、都可点：单页模式下横版宣传图照常看，靠这个
            // ✗ 表达"它在长画布里被隐藏了"。
            if (key != null)
              Tooltip(
                message: (_hiddenPages.contains(key)
                        ? 'Show in continuous strip'
                        : 'Hide in continuous strip')
                    .tl,
                child: InkWell(
                  onTap: () => _toggleStripHidden(key),
                  child: Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: _hiddenPages.contains(key)
                            ? scheme.error
                            : scheme.onSurfaceVariant,
                      ),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Icon(
                      _hiddenPages.contains(key)
                          ? Icons.close
                          : Icons.check,
                      size: 14,
                      color: _hiddenPages.contains(key)
                          ? scheme.error
                          : scheme.onSurfaceVariant,
                    ),
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

  /// A-1.2 门控：缩略图栏当前能不能用（原因码见 [ThumbRailGate]）。
  ThumbRailGate get _thumbRailGate => thumbRailGate(
        hasProject: _project != null,
        stripMode: _stripMode,
        pageCount: _pageKeys.length,
      );

  /// 缩略图栏"生效中"：开着**且**当前可用。
  ///
  /// 🔴 两个条件都要。`_thumbRail` 是用户的开关，门控是"现在这个模式/方向/页数
  /// 下它还有没有意义"。少了门控，切到长画布后左栏会停在一个已失效的宽版上
  /// （D14 已要求联动关闭，这里再兜一层，保证任何路径下都不会留下"宽版但失效"）。
  bool get _thumbRailActive => _thumbRail && thumbRailAvailable(_thumbRailGate);

  /// 缩略图栏按钮的 tooltip：可用时说明"点它会做什么"，不可用时说明"为什么
  /// 不能开"（四种原因四句话，不共用一句）。
  String _thumbRailTooltip(ThumbRailGate gate, bool active) {
    switch (gate) {
      case ThumbRailGate.noProject:
        return 'No project is open'.tl;
      case ThumbRailGate.stripMode:
        return 'Not needed in continuous strip mode'.tl;
      case ThumbRailGate.tooFewPages:
        return 'Needs at least two pages to check page seams'.tl;
      case ThumbRailGate.ready:
        return active ? 'Hide thumbnail rail'.tl : 'Show thumbnail rail'.tl;
    }
  }

  /// 惰性读取所有页的尺寸（**只读文件头**，见 `page_size_probe.dart`）。
  Future<void> _ensurePageSizes() async {
    final project = _project;
    if (project == null) return;
    var changed = false;
    for (final key in _pageKeys) {
      if (_pageSizeCache.containsKey(key)) continue;
      final path = _resolvePageFile(key)?.path ?? project.originalPath(key);
      _pageSizeCache[key] = probePageSizeFromFile(path);
      changed = true;
    }
    if (changed && mounted) setState(() {});
  }

  void _toggleThumbRail() {
    final next = !_thumbRail;
    setState(() => _thumbRail = next);
    // 打开时才需要尺寸（要据此隐藏横版页）；关闭不动缓存 —— 再打开不必重读。
    if (next) unawaited(_ensurePageSizes());
  }

  /// P30：切换某页在**连续长画布**中的隐藏状态（持久化 + 一个撤销步）。
  ///
  /// 纯视图层：不删块/跨页/组数据。隐藏的是**当前**页且正处在长画布时，
  /// 把视图带到下一张可见页（后可见优先，否则前可见）；单页模式下只改状态，
  /// 页面照常显示（左下角勾选框表达"它在长画布里是隐藏的"）。
  void _toggleStripHidden(String? pageKey) {
    final project = _project;
    if (project == null || pageKey == null) return;
    final next = toggleHiddenPage(_hiddenPages, pageKey);
    final becameHidden = next.contains(pageKey);
    final command = captureSeamReviewEdit(
      project.raw,
      key: stripHiddenKey,
      pageKey: pageKey,
      label: 'Hide page in continuous strip',
      mutate: () => writeHiddenPages(project.raw, next),
    );
    if (command.isEmpty) return;
    _history.push(command);
    setState(() {
      _hiddenPages = next;
      // 块投影不依赖隐藏集，但 ++revision 与其余编辑提交保持同一条节奏。
      _revision++;
    });
    if (!becameHidden) return;
    final currentKey =
        _pageIndex >= 0 && _pageIndex < _pageKeys.length
            ? _pageKeys[_pageIndex]
            : null;
    if (currentKey != pageKey) return;
    if (!_stripMode) return;
    final target = nextVisibleAfterHide(
      current: _pageIndex,
      visible: visiblePageIndices(pageKeys: _pageKeys, hidden: next),
    );
    if (target == null) return;
    // 等隐藏页高度回收完再跳，避免在旧高度上算出错位偏移。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _selectPage(target);
    });
  }

  // ── B-1 · 缝发现与标记 ───────────────────────────────────────────────

  /// 当前工程的缝检视记录（快照）。
  Map<String, String> get _seamReviews =>
      _project?.seamReviews ?? const <String, String>{};

  /// 某页是不是"缩略图栏里被隐藏的横版页"（A-1.4 / D11）。
  ///
  /// 尺寸未知（尚未探测完）时**不**当作隐藏页 —— 宁可暂时多显示一条可选缝，
  /// 也不要在尺寸就绪前把缝误标成 `n/a`。
  bool _isHiddenPage(String pageKey) {
    final size = _pageSizeCache[pageKey];
    return size != null && isLandscapePage(size.width, size.height);
  }

  SeamCounts get _seamCounts => seamCounts(
        seamsOf(_pageKeys),
        reviews: _seamReviews,
        isHiddenPage: _isHiddenPage,
      );

  /// 把 [seam] 标成 [state]；`null` = 清除记录（回到"未记录"）。
  ///
  /// 一个 undo step（[SeamReviewEditCommand]），与块编辑同一条路径 ⇒ "未保存"
  /// 提示与撤销都认它。
  void _setSeamReview(SeamEntry seam, String? state) {
    final project = _project;
    if (project == null) return;
    final command = captureSeamReviewEdit(
      project.raw,
      key: seamReviewKey,
      pageKey: seam.upper,
      label: 'Seam review',
      mutate: () {
        if (state == null) {
          project.clearSeamReview(seam.id);
        } else {
          project.setSeamReview(seam.id, state);
        }
      },
    );
    if (command.isEmpty) return;
    _history.push(command);
    setState(() => _revision++);
  }

  /// D7：跳到**下一条**待检视的缝（选中它的上页 —— 缝就是那条下边缘）。
  ///
  /// 从**当前页的下边缘**往后找并回绕：这样连点几次是"一条一条往下走"，而不是
  /// 每次都跳回工程里第一条 todo。当前页是末页（没有下边缘）时从末条缝起算，
  /// 于是回绕到第一条。
  void _jumpToNextUnreviewedSeam() {
    final seams = seamsOf(_pageKeys);
    if (seams.isEmpty) return;
    final current = _pageIndex >= 0 && _pageIndex < _pageKeys.length
        ? _pageKeys[_pageIndex]
        : null;
    final upperOfCurrent = seams.indexWhere((s) => s.upper == current);
    final index = nextUnreviewedIndex(
      seams,
      reviews: _seamReviews,
      isHiddenPage: _isHiddenPage,
      fromIndex: upperOfCurrent >= 0 ? upperOfCurrent : seams.length - 1,
    );
    if (index == null) return;
    final upper = _pageKeys.indexOf(seams[index].upper);
    if (upper >= 0) _selectPage(upper);
  }

  /// 相邻两张缩略图之间那条**缝**。
  ///
  /// 只会拿到 `clean` / `split` / `todo` 三态：标记只插在阅读序**相邻的两张可见
  /// 页**之间（[_buildPageRail]），而两侧只要有一页是被隐藏的横版页就不会插进去
  /// —— 那种缝是 `n/a`，在栏里根本不出现（D11）。
  Widget _buildSeamMarker(SeamEntry seam) {
    final scheme = Theme.of(context).colorScheme;
    final state = effectiveSeamState(
      seam,
      reviews: _seamReviews,
      isHiddenPage: _isHiddenPage,
    );
    final (Color color, IconData icon, String label) = switch (state) {
      SeamState.clean => (
          scheme.primary,
          Icons.check_circle_outline,
          'Page seam: clean'.tl,
        ),
      SeamState.split => (
          scheme.error,
          Icons.content_cut,
          'Page seam: truncated'.tl,
        ),
      _ => (
          scheme.outline,
          Icons.remove,
          'Page seam: not checked'.tl,
        ),
    };
    // 标记**居中**、很小，绝不压在上下两张图的边缘上 —— 那正是要看"有没有被
    // 切到的字"的地方（A-1.1 第 5 条）。
    return SizedBox(
      height: 18,
      child: Center(
        child: PopupMenuButton<SeamState>(
          tooltip: label,
          padding: EdgeInsets.zero,
          iconSize: 16,
          splashRadius: 16,
          // `todo` 就是"没有记录" ⇒ 落盘时清掉该条（`null`）。
          onSelected: (value) => _setSeamReview(
            seam,
            value == SeamState.todo ? null : value.wire,
          ),
          itemBuilder: (_) => [
            CheckedPopupMenuItem(
              value: SeamState.clean,
              checked: state == SeamState.clean,
              child: Text('Mark as clean'.tl),
            ),
            CheckedPopupMenuItem(
              value: SeamState.split,
              checked: state == SeamState.split,
              child: Text('Mark as truncated'.tl),
            ),
            CheckedPopupMenuItem(
              value: SeamState.todo,
              checked: state == SeamState.todo,
              child: Text('Clear mark'.tl),
            ),
          ],
          icon: Icon(icon, size: 16, color: color),
        ),
      ),
    );
  }

  /// 缩略图栏顶部：还有几条缝没看 + "下一条"跳转（D7）。
  Widget _buildSeamHeader() {
    final counts = _seamCounts;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              counts.toReview == 0
                  ? 'All page seams reviewed'.tl
                  : '@a page seam(s) to review'.tlParams({'a': counts.toReview}),
              style: ts.s12.copyWith(color: scheme.onSurfaceVariant),
              maxLines: 2,
            ),
          ),
          IconButton(
            tooltip: 'Next unreviewed page seam'.tl,
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            onPressed:
                counts.toReview == 0 ? null : _jumpToNextUnreviewedSeam,
            icon: const Icon(Icons.skip_next),
          ),
        ],
      ),
    );
  }

  Widget _buildPageRail({bool horizontal = false}) {
    final project = _project;
    if (project == null) return const SizedBox.shrink();
    // 缩略图模式只在**竖排左栏**生效；窄屏底栏（horizontal）永远是紧凑模式。
    final thumb = !horizontal && _thumbRailActive;
    final indices = thumb
        ? thumbRailVisibleIndices(
            pageCount: _pageKeys.length,
            widthOf: (i) => _pageSizeCache[_pageKeys[i]]?.width,
            heightOf: (i) => _pageSizeCache[_pageKeys[i]]?.height,
          )
        : List<int>.generate(_pageKeys.length, (i) => i);
    final children = <Widget>[];
    for (final i in indices) {
      final key = _pageKeys[i];
      final page = project.pages[key];
      final total = page?.blocks.length ?? 0;
      final done = page?.translatedBlocks.length ?? 0;
      children.add(
        _PageTile(
          // Falls back to `inpainted`/`mask` so the rail still renders for a
          // project whose raw comic folder is gone.
          file: _resolvePageFile(key) ?? File(project.originalPath(key)),
          // 🔴 真实页号（`i + 1`），不是过滤后的位置 —— 隐藏横版页时序号必须
          // 跟着**它自己那一页**，不能整体前移（A-1.4）。
          label: '${i + 1}',
          selected: i == _pageIndex,
          complete: total > 0 && done == total,
          partial: done > 0 && done < total,
          large: thumb,
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
    if (thumb) {
      // 🔴 缩略图模式给固定高度：单张放大后要能看出"这页上下边缘有没有被切到
      // 的字"，统一高度让上下两张的**缝**在视觉上连续可比。
      //
      // 缝标记**只插在阅读序真正相邻的两张之间**（`indices[k-1] + 1 ==
      // indices[k]`）。中间夹着被隐藏的横版页时，那两条缝都是 `n/a`、永远
      // 不可检视，这里就不该出现可点的标记（D11）。
      final plan = <Object>[];
      for (var k = 0; k < indices.length; k++) {
        if (k > 0 && indices[k - 1] + 1 == indices[k]) {
          plan.add(SeamEntry(_pageKeys[indices[k - 1]], _pageKeys[indices[k]]));
        }
        plan.add(k);
      }
      return Column(
        children: [
          _buildSeamHeader(),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: plan.length,
              itemBuilder: (_, i) {
                final item = plan[i];
                if (item is SeamEntry) return _buildSeamMarker(item);
                return SizedBox(
                  height: _kThumbTileHeight,
                  child: children[item as int],
                );
              },
            ),
          ),
        ],
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: children.length,
      itemBuilder: (_, i) => children[i],
    );
  }

  /// A-2：右栏 = 折叠图标条（44px 常驻）+ 三个保活 Tab（块 / 组 / 运行）。
  ///
  /// 🔴 **不丢编辑态**：折叠只让内容区 [Offstage] 零尺寸，三个子视图始终在
  /// [IndexedStack] 里保活 —— 块面板的 TextEditingController、组面板未提交的
  /// 分配草稿都不会因切 Tab/折叠而销毁。
  Widget _buildPanel() {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surface,
      child: Row(
        children: [
          Flexible(
            flex: _panelCollapsed ? 0 : 1,
            child: Offstage(
              offstage: _panelCollapsed,
              child: SizedBox.expand(child: _panelContent()),
            ),
          ),
          if (_panelCollapsed) const Spacer(),
          _panelRail(),
        ],
      ),
    );
  }

  Widget _panelContent() {
    return Column(
      children: [
        SizedBox(height: 40, child: _panelTabBar()),
        const Divider(height: 1),
        Expanded(
          child: IndexedStack(
            sizing: StackFit.expand,
            index: _panelTab < 0
                ? 0
                : (_panelTab > 2 ? 2 : _panelTab),
            children: [
              _blockTab(),
              _groupTab(),
              _runTab(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _panelTabBar() {
    final scheme = Theme.of(context).colorScheme;
    Widget tab(IconData icon, String label, int index) {
      final selected = _panelTab == index;
      final color = selected
          ? scheme.onSecondaryContainer
          : scheme.onSurfaceVariant;
      return Expanded(
        child: InkWell(
          onTap: () => setState(() => _panelTab = index),
          child: ColoredBox(
            color: selected ? scheme.secondaryContainer : Colors.transparent,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 18, color: color),
                const SizedBox(height: 2),
                Text(label, style: ts.s12.copyWith(color: color)),
              ],
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        // P30：折叠钮不再放这里 —— 它与窄图标条上的展开钮共用同一个位置
        // （窄条顶部），展开态三个切换只出现在本 Tab 行，不再与窄条重复。
        tab(Icons.touch_app_outlined, 'Text block'.tl, 0),
        tab(Icons.account_tree_outlined, 'Group'.tl, 1),
        tab(Icons.playlist_play, 'Run'.tl, 2),
      ],
    );
  }

  /// 右缘 44px 窄图标条。
  ///
  /// P30 去重（用户图 2）：
  /// * **展开态**：窄条只留一个「折叠」钮（chevron_right）—— 文字块/组/运行
  ///   三个切换只在内容区顶部的 Tab 行，窄条不再重复一遍；
  /// * **折叠态**：内容区（连同 Tab 行）Offstage 保活，窄条放出「展开」钮
  ///   （chevron_left）+ 三个图标，点图标 = 展开并切到该 Tab。
  /// 折叠/展开因此共用窄条顶部这一个位置，不会两个钮同时出现。
  Widget _panelRail() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 44,
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(left: Divider.createBorderSide(context)),
      ),
      child: Column(
        children: [
          IconButton(
            tooltip: _panelCollapsed
                ? 'Expand panel'.tl
                : 'Collapse panel'.tl,
            iconSize: 20,
            visualDensity: VisualDensity.compact,
            icon: Icon(
              _panelCollapsed ? Icons.chevron_left : Icons.chevron_right,
            ),
            onPressed: () =>
                setState(() => _panelCollapsed = !_panelCollapsed),
          ),
          // 展开态窄条到此为止：三个切换只在 Tab 行里，不重复。
          if (_panelCollapsed) ...[
            const Divider(height: 1),
            _railTabIcon(Icons.touch_app_outlined, 'Text block'.tl, 0),
            _railTabIcon(Icons.account_tree_outlined, 'Group'.tl, 1),
            _railTabIcon(Icons.playlist_play, 'Run'.tl, 2),
            const Spacer(),
          ],
        ],
      ),
    );
  }

  /// 折叠态窄条上的单个 Tab 图标：点击 = 展开右栏并切到该 Tab。
  Widget _railTabIcon(IconData icon, String tip, int index) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _panelTab == index;
    return IconButton(
      tooltip: tip,
      iconSize: 20,
      visualDensity: VisualDensity.compact,
      color: selected ? scheme.primary : null,
      icon: Icon(icon),
      onPressed: () => setState(() {
        _panelTab = index;
        _panelCollapsed = false;
      }),
    );
  }

  /// 块 Tab：选中块 → 块属性面板（B-5：跨页块多一个「解跨页」按钮）；否则
  /// 显示工程根信息与点选提示（管线选项挪去【运行】Tab）。
  Widget _blockTab() {
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
        isCrossPage: readSpan(block)?.isCrossPage ?? false,
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
        // 🔴 2026-10-09 续：单块级修图 / 复原。禁用条件与识别/翻译相同（busy
        // 或没有可用原图的页），回调内部会进一步判"块有没有译文"等细节。
        onRepair: _blockOpBusy || _pageKeys.isEmpty
            ? null
            : () => _repairSelectedBlock(),
        onRestoreOriginal: _blockOpBusy || _pageKeys.isEmpty
            ? null
            : () => _restoreOriginalSelectedBlock(),
        onDissolveSpan:
            _blockOpBusy ? null : _dissolveSelectedSpanBlock,
        // P33 ⑦b：取色同样需要**原图**（`inpainted/` 上的字已经被抹掉了，
        // 在上面取样取到的是译文的颜色），所以禁用条件与识别/翻译一致。
        onSampleColor: _blockOpBusy || _pageKeys.isEmpty
            ? null
            : () => _resampleSelectedBlockColor(),
        busy: _blockOpBusy,
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        ..._projectInfoTiles(project),
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

  /// 运行 Tab：工程根信息 + 自动管线选项（旧版无选中块时的默认内容）。
  Widget _runTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        ..._projectInfoTiles(_project),
        const Divider(height: 28),
        _buildPipelinePanel(context),
      ],
    );
  }

  List<Widget> _projectInfoTiles(TranslationProject? project) => [
        Text('Page'.tl, style: ts.s16),
        const SizedBox(height: 8),
        _kv('Source root', project?.directory ?? '-', small: true),
        _kv('Artifact root', project?.workspace ?? '-', small: true),
        _kv(
          'Layout',
          (project?.isInPlaceLayout ?? true) ? 'in-place'.tl : 'split'.tl,
          small: true,
        ),
      ];

  /// 组 Tab：组选择器（多组时）+ 组模式面板；一个组都没有时给入口说明。
  Widget _groupTab() {
    final groups = _groupProjection.groups;
    if (groups.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Text group'.tl, style: ts.s16),
          const SizedBox(height: 8),
          Text(
            'Switch to the continuous strip, tap the group icon, then pick the blocks that belong to one sentence.'.tl,
            style:
                ts.s12.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ],
      );
    }
    final active = _activeGroup ?? groups.values.first;
    final views = <StudioGroupMemberView>[
      for (final member in active.members) _memberView(member),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            children: [
              Expanded(
                child: DropdownButton<String>(
                  isDense: true,
                  isExpanded: true,
                  value: groups.containsKey(active.id) ? active.id : null,
                  items: [
                    for (final g in groups.values)
                      DropdownMenuItem(
                        value: g.id,
                        child: Text(
                          '@a · @b'.tlParams({
                            'a': g.id.length > 10
                                ? '${g.id.substring(0, 10)}…'
                                : g.id,
                            'b': '${g.members.length}',
                          }),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (id) => setState(() => _chosenGroupId = id),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: StudioGroupPanel(
            key: ValueKey('group#${active.id}'),
            group: active,
            revision: _revision,
            busy: _blockOpBusy,
            members: views,
            onModeChanged: (mode) => _setGroupMode(active.id, mode),
            onCombine: () => _combineGroupSource(active.id),
            onTranslateOnce: () => _translateGroupOnce(active.id),
            onSourceSubmitted: (text) =>
                _setGroupSource(active.id, text),
            onTranslationSubmitted: (text) =>
                _setGroupTranslation(active.id, text),
            onReorder: (from, to) =>
                _reorderGroupMember(active.id, from, to),
            onRemoveMember: (i) => _removeGroupMember(active.id, i),
            onSelectMember: (i) => _selectGroupMember(active.members[i]),
            onApplyAssignment: (values) =>
                _applyGroupAssignment(active.id, values),
            onDissolve: () => _dissolveGroup(active.id),
          ),
        ),
      ],
    );
  }

  StudioGroupMemberView _memberView(GroupMemberRef ref) {
    final pageNumber = _pageKeys.indexOf(ref.page) + 1;
    final block = findBlockByUid(
      _project?.pages[ref.page]?.blocks ?? const <TextBlock>[],
      ref.uid,
    );
    return StudioGroupMemberView(
      pageLabel: 'Page @a'.tlParams({'a': '$pageNumber'}),
      sourcePreview: block?.sourceText ?? '',
      exists: block != null,
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
            // 🔴 第四段「修图」（2026-10-09 用户修订）。默认不勾：抹字不可逆，
            // 用户要先看块、拖块、改完再出图。
            FilterChip(
              label: Text('Repair artwork'.tl),
              selected: _runStages.repair,
              onSelected: running
                  ? null
                  : (on) => setState(
                      () => _runStages = _runStages.copyWith(repair: on)),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          // 与弹窗同一句话：四段能不能互相独立，取决于同一份工作量判断。
          'Stages run in order: detect, then recognize, then translate. Repair artwork erases the original lettering and draws the translation into the same boxes; it only touches the image files, so check the boxes in the studio first.'.tl,
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
                  : (_) => setState(() {
                      _runDirection = ReadingDirection.rightToLeft;
                      // 缩略图栏只对"上→下"有意义：切到左右阅读就关掉，
                      // 不留一个已失效的宽版左栏。
                      _thumbRail = false;
                    }),
            ),
            ChoiceChip(
              label: Text('Left to right'.tl),
              selected: _runDirection == ReadingDirection.leftToRight,
              onSelected: running
                  ? null
                  : (_) => setState(() {
                      _runDirection = ReadingDirection.leftToRight;
                      _thumbRail = false;
                    }),
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

/// 投影缓存：`_revision` 变了就整体作废（见 `_blocksFor`）。
class _BlockProjectionCache {
  _BlockProjectionCache(this.revision);

  /// 建立本缓存时的 [_revision]。
  final int revision;

  /// 页 key → 该页要画的块列表（含投影片段）。
  final Map<String, List<CanvasTextBlock>> byPage = {};
}

/// 跨页块在**某一页**上的投影片段：真身在 [ownerKey] 页的 `blocks[ownerIndex]`。
///
/// 它不是落盘形态 —— 落盘只有真身的 `_span.parts`（D8：per-page 子矩形是真相），
/// 这里只是"要把这段画到这一页上"的运行时索引。
class _SpanFragment {
  const _SpanFragment({
    required this.ownerKey,
    required this.ownerIndex,
    required this.rect,
  });

  final String ownerKey;
  final int ownerIndex;

  /// 该片段在**本页页内坐标**里的矩形。
  final IntRect rect;
}

/// B-3/B-4：一次 [_revision] 下的组投影：工程里的全部组 + 成员反查表。
class _GroupProjection {
  _GroupProjection(this.revision);

  final int revision;

  /// 组 id → 组（`readGroups` 的新表，仅读）。
  final Map<String, BlockGroup> groups = {};

  /// 成员键 `"<page>#<uid>"` → 组标记。
  final Map<String, _GroupTag> tags = {};
}

/// 一个块在组里的可视化标记：组 id + 阅读序序号（1 起）+ 是否连线形态。
class _GroupTag {
  const _GroupTag(this.refKey, this.groupId, this.ordinal, this.isLink);

  final String refKey;
  final String groupId;
  final int ordinal;
  final bool isLink;
}

/// A-1.3 缩略图模式左栏宽度（D6 = 240）。
const double _kThumbRailWidth = 240;

/// A-1.3 缩略图模式单张高度。统一高度让上下相邻两张的**缝**在视觉上连续可比。
const double _kThumbTileHeight = 300;

class _PageTile extends StatelessWidget {
  const _PageTile({
    required this.file,
    required this.label,
    required this.selected,
    required this.complete,
    required this.partial,
    required this.onTap,
    this.large = false,
  });

  final File file;
  final String label;
  final bool selected;
  final bool complete;
  final bool partial;
  final VoidCallback onTap;

  /// 缩略图模式（A-1.3）：单张更大、序号**居中**、完成状态改用**边框色**。
  final bool large;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // A-1.1 第 5 条：缩略图模式的覆盖层**不贴边** —— 上下边缘正是用户要看
    // "缝"的地方。位置由 [thumbTileOverlay] 唯一决定（界面与断言同一判据）。
    final centered = thumbTileOverlay(large: large) == ThumbTileOverlay.center;
    // 完成状态色。缩略图模式把它落在**边框**上（无贴边覆盖点）；紧凑模式仍用
    // 右上角的状态点（保持不变）。
    final statusColor = complete
        ? const Color(0xFF3B6D11)
        : partial
        ? const Color(0xFFBA7517)
        : scheme.outlineVariant;
    return InkWell(
      onTap: onTap,
      child: Container(
        margin: EdgeInsets.symmetric(horizontal: 8, vertical: large ? 5 : 3),
        decoration: BoxDecoration(
          border: Border.all(
            color: selected
                ? scheme.primary
                : (centered ? statusColor : scheme.outlineVariant),
            width: selected ? 2 : (centered ? 1.5 : 0.5),
          ),
          borderRadius: BorderRadius.circular(large ? 8 : 6),
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
                  // easiest way to make a long project stutter. 缩略图模式
                  // 放大到 240px 左栏后 96 会把字糊成一团；320 仍远小于原图。
                  cacheWidth: large ? 320 : 96,
                  filterQuality: FilterQuality.low,
                  errorBuilder: (context, error, stackTrace) =>
                      const SizedBox.shrink(),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(
                  Icons.broken_image_outlined,
                  size: large ? 28 : 20,
                  color: scheme.outline,
                ),
              ),
            if (centered)
              Align(alignment: Alignment.center, child: _label(scheme))
            else
              Positioned(left: 2, bottom: 2, child: _label(scheme)),
            // 状态点只在紧凑模式出现 —— 缩略图模式用边框色代替。
            if (!centered)
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

  Widget _label(ColorScheme scheme) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: large ? 6 : 4,
        vertical: large ? 2 : 1,
      ),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(label, style: large ? ts.s14 : ts.s12),
    );
  }
}

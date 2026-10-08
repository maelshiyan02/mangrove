// S9 · P1-5 — 把"检测/OCR/翻译"的结果**写进工作室工程**。
//
// 🔴 **这个文件存在的全部理由是一条分叉**：旧的 AI 翻译引擎把产物写进
// **阅读器的 OCR 缓存**（`pageTranslation@2@…` 那一套 key），工作室工程完全
// 看不到它；本文件把产物写成**工程的 `TextBlock`**，让工作室立刻能编辑、
// 能撤销、能存进 FT 的 json。反过来也成立：工作室里的任何编辑都不会流回
// 阅读器缓存。两条路各自完整，S9 之后也不合并 —— 合并要等 P10。
//
// 因此本文件刻意**不 import** `pre_translation_tasks.dart`（旧引擎的任务
// 框架）：那里的 `start()` 会拉起整条旧管线并写旧缓存，把工作室的 UI 耦合
// 进去等于把分叉糊掉。进度/取消在这里用最朴素的方式实现（一个
// [CancellationToken] + 一个进度回调），详见 P9.6 §三。
library;

import 'dart:async';
import 'dart:typed_data';

import '../image_translation/balloon_clustering.dart';
import '../image_translation/translation_dispatcher.dart';
import '../image_translation/translation_pipeline.dart';
import '../image_translation/translation_types.dart';
import '../log.dart';
import 'glossary_store.dart';
import 'project.dart';
import 'rich_text_sync.dart';
import 'studio_block_ops.dart';
import 'text_block.dart';

/// 一次运行的协作式取消。
///
/// 刻意不用 `PreTranslationTaskManager` 的暂停/恢复：那套状态机绑在旧引擎的
/// 章节/分组模型上（`eid`、group committer、断点游标），把它拉进工作室就得
/// 连带把旧缓存写入口一起拉进来 —— 正是本文件要避免的。
class CancellationToken {
  bool _canceled = false;

  bool get isCanceled => _canceled;

  void cancel() => _canceled = true;

  /// 在每个页边界调用；已取消则抛 [PipelineCanceled]，调用方据此停止。
  void throwIfCanceled() {
    if (_canceled) throw const PipelineCanceled();
  }
}

/// 一页的检测结果 + 落地后的统计。
class StudioPageRun {
  StudioPageRun({
    required this.pageKey,
    required this.blocks,
    required this.skipped,
    this.error,
    this.glossary = const {},
  });

  final String pageKey;

  /// 已写进工程的块（**新建**的，不是全部块）。
  final List<TextBlock> blocks;

  /// 被跳过的检测行数：空文本、纯符号、或与已有块重叠。
  ///
  /// 🔴 不静默丢弃：`skipped > 0` 就是"漏检/误检"的第一手线索，用户靠它
  /// 判断要不要用 Create 块手工补（P9.3 §9 的兜底手段）。
  final int skipped;

  /// 本页模型**回报**的新专名（原文 → 译法）。
  ///
  /// 🔴 只有真 LLM 会回报；免 Key 公共端点与本地 NMT 恒为空 —— 那两类引擎
  /// 连术语表的"写入端"都没有，硬造一条会让人以为术语表在学习。
  /// 调用方负责把它合并进 [GlossaryStore]，跨页/跨章人名一致性就靠这一步。
  final Map<String, String> glossary;

  final Object? error;

  bool get failed => error != null;

  bool get hasWork => blocks.isNotEmpty;
}

/// 一次批量运行的汇总。
class StudioRunReport {
  StudioRunReport(this.pages);

  final List<StudioPageRun> pages;

  int get totalBlocks => pages.fold(0, (sum, p) => sum + p.blocks.length);

  int get failedPages => pages.where((p) => p.failed).length;

  int get skippedLines => pages.fold(0, (sum, p) => sum + p.skipped);

  bool get canceled => pages.any((p) => p.error is PipelineCanceled);
}

/// 一次运行的配置。
class StudioRunOptions {
  const StudioRunOptions({
    required this.sourceLang,
    required this.targetLang,
    this.readingDirection = ReadingDirection.rightToLeft,
    this.translate = true,
    this.recognize = true,
    this.glossary = const {},
  });

  final String sourceLang;
  final String targetLang;

  /// 日漫右起是默认；欧漫/条漫传 [ReadingDirection.leftToRight]。
  final ReadingDirection readingDirection;

  /// 关掉时只做"检测 + OCR + 建块"，不调LLM —— 用户想先看版面对不对。
  ///
  /// 分开是因为版面与翻译的失败率完全不同：版面错要重跑检测，翻译错只要
  /// 重填译文。把两者绑在一起意味着每次调版面参数都要重新请求一次 LLM。
  final bool translate;

  /// 是否**识别**块内文字（P10.15 §4.3 第二段）。
  ///
  /// false = 只检测：块照建、框照准，但 `text` 为空。
  ///
  /// 🔴 **本引擎做不到"检测与识别的计算分离"**，这里必须说清楚，否则下一个人
  /// 会以为这个开关省了识别那一步。`ocrPage` 的检测后处理（`clusterOcrBoxes`
  /// 聚类 + 行高中位数 + 取色）与识别同在一趟里，而**建块恰恰需要这些量**
  /// （`TextBlock.fromOcr` 要吃 `rect` / `lineHeight` / `textColor` /
  /// `backgroundColor` / `eraseRects`）。所以 `recognize: false` 的实现是
  /// **跑完整趟然后丢掉文本**：
  ///
  /// * 用户看到的结果与真正的"只检测"**完全一致**（框有、字空）；
  /// * 省下的是**翻译请求**（§4.3 里"只检测"想省的正是这个），不是识别算力；
  /// * 代价是白跑一趟识别 —— 不花 token、不发网络请求。
  ///
  /// 做成"跳过识别"需要给 worker 加一条独立入口（`_WorkerState._detectBoxes`
  /// 目前是私有的，且它的输出还没有聚类/取色那一层）。那条路在 headless 里
  /// **无法验证**（无 ONNX、无渲染表面），所以等有 GUI 验收手段时再做。
  final bool recognize;

  final Map<String, String> glossary;
}

/// 单页管线：图片字节 → 聚类 → 翻译 → `TextBlock` 列表。
///
/// 刻意**不接受**一个 `TranslationProject`：它只产出块，落地由
/// [applyBlocksToPage] 走脏页登记入口完成。把"算"与"写"分开，才能让
/// headless 断言直接测前者而不碰工程文件。
class StudioPagePipeline {
  StudioPagePipeline({PageTranslationPipeline? inner})
      : _inner = inner ?? PageTranslationPipeline();

  final PageTranslationPipeline _inner;

  /// 跑一页。返回的块**尚未**写进工程。
  ///
  /// ## 🔴 两个必须说清的地方
  ///
  /// 1. **颜色不在这里采样**，而是**按行**从 `OcrBlock` 取回。聚类的输入是
  ///    `TextLine`（只有几何 + 文本），而背景/前景色住在 `OcrBlock` 上。
  ///    早期版本试图用"气泡外框"去反查 `OcrBlock`，但气泡外框是**若干行的
  ///    并集**，几乎不可能等于任何一行的矩形 —— 于是查不到、整页产出 0 块，
  ///    而且**不报错**。现在改成按行回查。
  /// 2. **`ocr.ready` 里是 `TranslatedRegion` 而不是 `OcrBlock`**（zh→zh-TW
  ///    已在 `ocrPage` 里转好、不要再问模型）。早期版本用 `is OcrBlock` 过滤，
  ///    于是这一类区域被**静默丢弃**。现在两条路都收，只是走不同的落地方式。
  Future<StudioPageRun> runPage(
    String pageKey,
    Uint8List imageBytes, {
    required StudioRunOptions options,
    required int pageWidth,
    CancellationToken? cancel,
  }) async {
    try {
      cancel?.throwIfCanceled();
      final ocr = await _inner.ocrPage(
        imageBytes,
        sourceLang: options.sourceLang,
        targetLang: options.targetLang,
      );
      cancel?.throwIfCanceled();

      // 聚类输入：待翻译的原文行 + 已转好的目标语行，两类都参与版面切分 ——
      // 一个 zh 源页上"要翻译的日文"与"已转好的中文"在版面上是并排的，
      // 只聚类其中一类会把另一个的框算进间隙里。
      final pendingByRect = <String, OcrBlock>{
        for (final block in ocr.pending) _rectKey(block.rect): block,
      };
      final readyByRect = <String, TranslatedRegion>{
        for (final region in ocr.ready) _rectKey(region.rect): region,
      };
      // 两类载荷的静态类型不同（`OcrBlock` / `TranslatedRegion`），合成一个
      // 列表会让元素类型退化成 `Object`，`.rect` 随即不解析 —— 报错读起来
      // 像"忘了 import"，实际是类型推断问题。所以分别映射再合并。
      final allLines = <TextLine>[
        for (final block in ocr.pending)
          TextLine(
            rect: block.rect,
            text: block.text,
            language: block.language,
            lineHeight: block.lineHeight,
          ),
        for (final region in ocr.ready)
          TextLine(
            rect: region.rect,
            text: region.text,
            // 🔴 `TranslatedRegion` carries **no** language: it is the
            // post-translation shape (rect/text/colours only). Claiming
            // otherwise would invent a detection result. `ocrPage` only puts
            // already-target-language text in `ready`, so the target language
            // is the accurate label here.
            language: options.targetLang == 'zh-TW' ? 'zh' : options.targetLang,
            lineHeight: region.lineHeight,
          ),
      ];
      final balloons = clusterBalloons(
        allLines,
        pageWidth: pageWidth,
        direction: options.readingDirection,
      );
      cancel?.throwIfCanceled();

      // 回查每一行的原始载荷：颜色在 `OcrBlock` / `TranslatedRegion` 上，
      // 不在 `TextLine` 上。逐行查而不是按气泡外框查 —— 外框是并集。
      //
      // 🔴 `sources` 只在"这个气泡有待翻译行"时才增长，所以它自己的下标
      // 与气泡下标**不是一回事**。早期版本拿气泡下标去索引 `sources`，
      // 于是一个"前面有 N 个只含 ready 行的气泡"的页会把译文写到错误的块上
      // —— 内容错位而不报错。所以 `readyTranslations` 按 `sources` 下标记。
      final sources = <OcrBlock>[];
      final readyTranslations = <int, String>{};
      var skipped = 0;
      for (final balloon in balloons) {
        final pendingLines = [
          for (final line in balloon.lines)
            if (pendingByRect[_rectKey(line.rect)] case final block?) block,
        ];
        final readyLines = [
          for (final line in balloon.lines)
            if (readyByRect[_rectKey(line.rect)] case final region?) region,
        ];
        if (pendingLines.isEmpty && readyLines.isEmpty) {
          // 每一行都没能回查 —— 说明聚类用的行与载荷对不上。这必须计入
          // skipped 而不是静默丢弃，否则"跑完了、块数为 0"看起来像成功。
          skipped += balloon.lines.length;
          continue;
        }
        final readyText = readyLines
            .map((r) => r.text.trim())
            .where((t) => t.isNotEmpty)
            .join('\n');
        if (pendingLines.isEmpty) {
          // 整个气泡都已转好目标语：它仍要成为一个块，只是**不再问模型**。
          // 丢掉它会让"中文页跑管线"产出 0 块。
          sources.add(
            balloonToOcrBlock(
              balloon,
              // 已转好的区域没有"原文色"的概念，用 region 自带的颜色。
              backgroundColor: readyLines.first.backgroundColor,
              textColor: readyLines.first.textColor,
            ),
          );
          readyTranslations[sources.length - 1] = readyText;
          continue;
        }
        sources.add(
          balloonToOcrBlock(
            balloon,
            backgroundColor: pendingLines.first.backgroundColor,
            textColor: pendingLines.first.textColor,
          ),
        );
        if (readyText.isNotEmpty) {
          readyTranslations[sources.length - 1] = readyText;
        }
      }

      // 🔴 拟声词先于翻译判一次（P10.15 §4.5 · 序6）：判出来的是**下标集合**，
      // 因为同一条判据要驱动两件事 —— 不进翻译批次、以及建块时打标记。在这里
      // 算一次并传下去，两处就不可能各判一次而判出不同结果。
      final sfxIndexes = <int>{
        for (var i = 0; i < sources.length; i++)
          if (StudioSfxOps.looksLikeSfx(
            sources[i].text,
            language: sources[i].language,
          ))
            i,
      };

      final outcome = options.translate && options.recognize && sources.isNotEmpty
          ? await _translate(sources, options, cancel, skip: sfxIndexes)
          : _TranslationOutcome(
              List<String>.filled(sources.length, ''), const {});
      final translated = outcome.texts;

      // 🔴 只检测（§4.3 第一段，见 [StudioRunOptions.recognize]）：本引擎
      // 的检测后处理与识别同在一趟里，而建块需要那一步的产物，所以这里是
      // "跑完整趟、把文本丢掉"。丢掉的是**原文与译文两边** —— 只清原文会
      // 留下 `translation`，而一个"有译文、没原文"的块既不能校对也不能重译，
      // 是纯粹的数据垃圾。
      final detectOnly = !options.recognize;

      final blocks = <TextBlock>[];
      for (var i = 0; i < sources.length; i++) {
        final source = sources[i];
        // 只检测时**不能**按"原文为空"剔除：那正是本模式全部产物的样子，
        // 剔完就是"跑完了、一页 0 块"，与真正的空页在界面上长得一模一样。
        if (!detectOnly && source.text.trim().isEmpty) {
          skipped++;
          continue;
        }
        final block = TextBlock.fromOcr(source);
        // 🔴 打标记（§4.5 · 序6）。写在 `fromOcr` **之后**而不是塞进 `fromOcr`
        // 里：`fromOcr` 是纯映射（OCR 载荷 → FT 块），"哪些块算拟声词"是**策略**，
        // 混进去会让"检测到的块"和"手工建的块"在形状上分不出差别 —— 而那正是
        // 零字节 diff 与 `fromOcr` 那批断言赖以成立的前提。
        if (sfxIndexes.contains(i)) block.label = StudioSfxOps.label;
        if (detectOnly) {
          block.sourceText = '';
          block.translation = '';
          blocks.add(block);
          continue;
        }
        // 译文对齐：`_translate` 返回与 `sources` 等长的列表（可能含空串），
        // 所以下标可以直接用。
        var text = i < translated.length ? translated[i].trim() : '';
        final readyText = readyTranslations[i];
        if (readyText != null && readyText.isNotEmpty) {
          text = readyText;
        }
        if (text.isNotEmpty && text != source.text) {
          block.translation = text;
          syncFtRichText(block);
        }
        blocks.add(block);
      }
      return StudioPageRun(
        pageKey: pageKey,
        blocks: blocks,
        skipped: skipped,
        glossary: outcome.glossary,
      );
    } on PipelineCanceled {
      return StudioPageRun(pageKey: pageKey, blocks: const [], skipped: 0,
          error: const PipelineCanceled());
    } catch (e, s) {
      Log.error('Studio Pipeline', 'page $pageKey failed: $e', s);
      return StudioPageRun(pageKey: pageKey, blocks: const [], skipped: 0, error: e);
    }
  }

  /// 把待翻译块交给 dispatcher，返回与入参等长的译文**加上模型回报的专名**。
  ///
  /// 🔴 等长是**刻意的**：用 `Map<rect, text>` 会让"哪一条丢了"变成隐式的，
  /// 而下标对齐 + 空串占位能让"这一块没翻出来"在块上直接看得见（空译文 =
  /// 不letter，用户自己补），这正是漏检兜底要的行为。
  ///
  /// [skip] 里的下标**不发给模型**（用来跳过拟声词，见 `StudioSfxOps`），它们
  /// 在结果里同样是空串 —— 与"翻失败"在下游看起来一样，这是有意的：两者都
  /// 应当表现为"这一块没有译文"，不该让下游去分辨原因。
  Future<_TranslationOutcome> _translate(
    List<OcrBlock> blocks,
    StudioRunOptions options,
    CancellationToken? cancel, {
    Set<int> skip = const {},
  }) async {
    final pending = <int>[];
    for (var i = 0; i < blocks.length; i++) {
      if (skip.contains(i)) continue;
      final text = blocks[i].text.trim();
      if (text.length < 2) continue;
      // 已是目标语言的不必再问模型（`ocrPage` 已把这类放进 `ready`，
      // 但逐块再判一次可以防住聚类把两类混进同一个气泡的情况）。
      if (blocks[i].language == _baseLang(options.targetLang)) continue;
      pending.add(i);
    }
    final result = List<String>.filled(blocks.length, '');
    if (pending.isEmpty) {
      return _TranslationOutcome(result, const {});
    }
    cancel?.throwIfCanceled();
    final response = await TranslationDispatcher.translateBatch(
      [for (final i in pending) blocks[i].text],
      options.targetLang,
      sourceLang: options.sourceLang,
      sourceLangs: [for (final i in pending) blocks[i].language],
      glossary: options.glossary,
    );
    cancel?.throwIfCanceled();
    for (var k = 0; k < pending.length; k++) {
      result[pending[k]] = k < response.texts.length ? response.texts[k] : '';
    }
    return _TranslationOutcome(result, response.glossary);
  }

  static String _baseLang(String lang) => lang == 'zh-TW' ? 'zh' : lang;
}

/// [_translate] 的产物：下标对齐的译文 + 模型回报的专名。
class _TranslationOutcome {
  const _TranslationOutcome(this.texts, this.glossary);

  final List<String> texts;
  final Map<String, String> glossary;
}

String _rectKey(IntRect rect) => '${rect.left},${rect.top},'
    '${rect.right},${rect.bottom}';

/// 落地入口：把 [blocks] 写进 `project` 的某一页，并**通过调用方给的登记入口**
/// 记录脏页。
///
/// ## 为什么必须传一个 `mutate` 回调
///
/// 规矩（项目硬规矩 3）：任何写 `pages[key]` 的路径都必须走统一入口登记脏页，
/// 否则 `result/` 增量重渲会漏。本函数**自己**不做登记 —— 它不持有
/// `EditHistory`，也不该持有（`EditHistory` 是工作室页面的 UI 状态）。
/// 把登记交给调用方，就从类型上保证了"这里不可能绕过它"：不传就没有落地。
///
/// [mutate] 的契约是：把 [blocks] 追加进该页的块列表。调用方应当把它包进
/// `captureBlockListEdit(...)` + `_history.push(...)`，也就是与
/// `studio_page.dart` 里 Create/Delete 块完全同一条路径 —— 三者共用一条，
/// 批量建块才不会成为第四个入口。
///
/// 返回真正落地的块数（调用方若因去重等原因少收了几个，以返回值为准）。
int applyBlocksToPage(
  TranslationProject project,
  String pageKey,
  List<TextBlock> blocks, {
  required int Function(List<TextBlock> blocks) mutate,
}) {
  if (blocks.isEmpty) return 0;
  final page = project.pages[pageKey];
  if (page == null) {
    Log.error('Studio Pipeline', 'applyBlocksToPage: no page $pageKey');
    return 0;
  }
  return mutate(blocks);
}

/// 检测阶段与既有块的**去重**判断：新建的气泡是否与页上某个块显著重叠。
///
/// 🔴 单独拎出来是因为它有一条硬约束：**只能读，绝不能改**既有块。整章
/// 重跑时，用户已经校对过的块必须原样保留 —— 覆盖它们等于丢掉人工工作。
/// 与 P9.5 那条"`det_model` 必须留空，否则下一轮 re-detect 把它当自己的
/// 输出"是同一条理由的两面。
///
/// [overlapRatio] 是交集面积占**较小框**面积的比例；超过 [threshold] 判为
/// 同一个块。
bool overlapsExistingBlock(
  ProjectPage page,
  IntRect rect, {
  double threshold = 0.5,
}) {
  var best = 0.0;
  for (final block in page.blocks) {
    final box = block.rect;
    final w = box.right > rect.left && rect.right > box.left
        ? (box.right < rect.right ? box.right : rect.right) -
            (box.left > rect.left ? box.left : rect.left)
        : 0;
    final h = box.bottom > rect.top && rect.bottom > box.top
        ? (box.bottom < rect.bottom ? box.bottom : rect.bottom) -
            (box.top > rect.top ? box.top : rect.top)
        : 0;
    if (w <= 0 || h <= 0) continue;
    final inter = (w * h).toDouble();
    final smaller = box.area < rect.area ? box.area : rect.area;
    if (smaller <= 0) continue;
    final ratio = inter / smaller;
    if (ratio > best) best = ratio;
  }
  return best > threshold;
}
/// 「从断点继续」到底要跑哪些页 —— 这是该语义的**唯一**来源。
///
/// S9 · P9.7。断点本身由工作室在每轮结束时记下（第一条没跑完的页），本函数
/// 回答"那之后还有哪些页"。做成纯函数有两个理由：
///
/// 1. 它能被 headless 直接测 —— 而 `sublist(index)` 这种散在 widget 里的写法
///    测不到，只能靠眼睛，正是 P9.0 §五说的"视觉验收兜不住的那类改动"。
/// 2. 🔴 它把一条容易被写错的行为钉住：**断点页不在 [pages] 里时返回空列表，
///    而不是整份 [pages]**。写反了，"继续"会静默变成"整章重跑"—— 一次
///    97 页的重跑，用户点的是"继续"。
///
/// [from] 为 null（没有断点）同样返回空：调用方什么都没记下时，"继续"不该
/// 自己发明一个起点。
List<String> resumePages(List<String> pages, String? from) {
  if (from == null) return const [];
  final index = pages.indexOf(from);
  if (index < 0) return const [];
  return pages.sublist(index);
}

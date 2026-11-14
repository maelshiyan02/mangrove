import 'dart:convert';
import 'dart:io';

import 'project.dart';
import 'project_bootstrap.dart';
import 'project_writer.dart';

/// 一页的产物对账条目。
///
/// 这是用户 S9.5-a 验收 #3 说的「给目录核对数据的时候补充证据」：**逐页**
/// 记下三类产物到底产没产出、这一页有几个块、几个已译，以及**为什么**缺。
///
/// 🔴 存在的理由：`of 94 pages -> mask=2, inpainted=80, result=80` 这种数字
/// 在磁盘上要一页一页 `ls` 才能看出来，而且"缺"有很多种原因（本来就没字 /
/// 没有译文 / 需要降采样 / 真的丢了），光看有没有文件**分不出**它们是哪一种。
/// 分不出就等于静默 —— 而静默正是这条链路反复栽的那一类。
class PageArtifactStatus {
  const PageArtifactStatus({
    required this.pageKey,
    required this.blocks,
    required this.translated,
    required this.mask,
    required this.inpainted,
    required this.result,
    required this.reason,
  });

  final String pageKey;

  /// 这一页的块总数。
  final int blocks;

  /// 其中带译文的块数（只有它们才会被渲染）。
  final int translated;

  final bool mask;
  final bool inpainted;
  final bool result;

  /// 取值为 [ArtifactReconciliation.reasons] 之一。
  final String reason;

  Map<String, Object?> toJson() => {
        'blocks': blocks,
        'translated': translated,
        'mask': mask,
        'inpainted': inpainted,
        'result': result,
        'reason': reason,
      };
}

/// 产物对账表：`imgtrans_<工程名>.artifacts.json`。
///
/// 整个文件**零 Flutter 依赖**（只用 `dart:io` / `dart:convert`），因此能在
/// `init()` 之前被 headless 直接断言 —— 而"补回 78 页掩膜"这件事**只能靠
/// 眼睛看**（GUI 跑一次），拿不到断言就等于没法回头确认它没再退化。
abstract final class ArtifactReconciliation {
  ArtifactReconciliation._();

  /// 与 `result_renderer._decodeBounded` 的降采样预算**同一组数**。
  ///
  /// 🔴 必须一致，否则对账表会把"刻意不产出"记成"缺产物"：`mask/` 与
  /// `inpainted/` 对超过这个预算的页**故意**不产出（坐标契约，见
  /// `renderInpaintedPage` 的文档），而对账表的职责恰恰是把这一类与"缺块"
  /// 分开，不然它又变成一种新的静默。
  static const int maxPixels = 12 * 1024 * 1024;
  static const int maxDimension = 8000;

  /// 对账表文件名后缀。`imgtrans_MDGH-ch1.json` → `imgtrans_MDGH-ch1.artifacts.json`。
  static const String fileSuffix = '.artifacts.json';

  /// `reason` 的全部取值。前三个是"正常"，后三个是"真的缺"。
  ///
  /// * `ok` —— 该有的都有。
  /// * `no-blocks` —— 这一页没有文字块，按设计不产任何产物。
  /// * `no-translation` —— 有块但一条译文都没有，`result/` 按设计缺席。
  /// * `downscaled` —— 页超过解码预算，`mask/`+`inpainted/` 刻意不产出。
  /// * `source-missing` —— 原图不在，且没有任何产物。
  /// * `base-missing` —— 有译文但 `mask/` 或 `inpainted/` 缺（历史缺口）。
  /// * `result-missing` —— 底图在、译文在，但 `result/` 缺。
  static const List<String> reasons = [
    'ok',
    'no-blocks',
    'no-translation',
    'downscaled',
    'source-missing',
    'base-missing',
    'result-missing',
  ];

  /// 对账表在本工程 `workspace` 下的绝对路径。
  static String pathFor(TranslationProject project, {String? root}) {
    final base = project.jsonFileName.replaceAll(RegExp(r'\.json$'), '');
    return '${ProjectWriter.normaliseRoot(root ?? project.workspace)}/'
        '$base$fileSuffix';
  }

  /// 逐页判定，不做任何写盘。
  static PageArtifactStatus statusFor(
    TranslationProject project,
    String pageKey, {
    String? root,
  }) {
    final artifactRoot = ProjectWriter.normaliseRoot(root ?? project.workspace);
    final stem = TranslationProject.pageStem(pageKey);
    final page = project.pages[pageKey];
    final blocks = page?.blocks.length ?? 0;
    final translated = page?.translatedBlocks.length ?? 0;
    final source = File(project.originalPath(pageKey));
    final sourceExists = source.existsSync();
    final mask = File('$artifactRoot/mask/$stem.png').existsSync();
    final inpainted = File('$artifactRoot/inpainted/$stem.png').existsSync();
    final result = File('$artifactRoot/result/$stem.png').existsSync();
    final tooLarge = isBeyondDecodeBudget(project, pageKey, source);

    return PageArtifactStatus(
      pageKey: pageKey,
      blocks: blocks,
      translated: translated,
      mask: mask,
      inpainted: inpainted,
      result: result,
      reason: _reasonFor(
        blocks: blocks,
        translated: translated,
        mask: mask,
        inpainted: inpainted,
        result: result,
        sourceExists: sourceExists,
        tooLarge: tooLarge,
      ),
    );
  }

  /// 组装对账表（不写盘）。[run] 是最近一次自动运行的摘要，可选。
  static Map<String, Object?> build(
    TranslationProject project, {
    String? root,
    Map<String, Object?>? run,
  }) {
    final artifactRoot = ProjectWriter.normaliseRoot(root ?? project.workspace);
    final pages = <String, Object?>{};
    final counts = <String, int>{for (final reason in reasons) reason: 0};
    for (final key in project.pageOrder) {
      if (!TranslationProject.isImagePage(key)) continue;
      // 幻影页（FT 留下的、盘上从来没有的 `.jpg` 壳）不进对账表 —— 它们
      // 连可显示的位图都没有，记进来只会把"页数"说多。
      if (!project.hasDisplayImage(key)) continue;
      final status = statusFor(project, key, root: artifactRoot);
      pages[key] = status.toJson();
      counts[status.reason] = (counts[status.reason] ?? 0) + 1;
    }
    return <String, Object?>{
      'version': 1,
      'project': project.jsonFileName,
      'root': artifactRoot,
      'directory': project.directory,
      'generatedAt': DateTime.now().toIso8601String(),
      'pages': pages,
      'summary': <String, Object?>{
        'pages': pages.length,
        for (final entry in counts.entries)
          if (entry.value > 0) entry.key: entry.value,
      },
      if (run != null) 'run': run,
    };
  }

  /// 写对账表并返回落盘的文件。
  static Future<File> write(
    TranslationProject project, {
    String? root,
    Map<String, Object?>? run,
  }) async {
    final payload = build(project, root: root, run: run);
    final file = File(pathFor(project, root: root));
    if (!file.parent.existsSync()) {
      await file.parent.create(recursive: true);
    }
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
      encoding: utf8,
    );
    return file;
  }

  /// 读回已落盘的对账表，供调用方报告与断言。不存在 → `null`。
  static Map<String, Object?>? read(
    TranslationProject project, {
    String? root,
  }) {
    final file = File(pathFor(project, root: root));
    if (!file.existsSync()) return null;
    final decoded = jsonDecode(file.readAsStringSync());
    // 🔴 **不要**写成 `decoded is Map<String, Object?> ? decoded : null`：
    // `jsonDecode` 交出的是 `Map<String, dynamic>`，而这条 `is` 判据对它并不
    // 可靠地成立 —— 一旦为 false，读一份**真实存在**的对账表会返回 `null`，
    // 调用方（与 `_regenerateAllArtifacts` 的汇总弹窗）看到的是"没写过"。
    // 那是本项目最忌讳的一类静默：写成功了、读却假装没有。
    // 显式归一就没有这个不确定性，与 `asObjectMap` 的兜底是同一条理由。
    if (decoded is! Map) return null;
    return <String, Object?>{
      for (final entry in decoded.entries) '${entry.key}': entry.value,
    };
  }

  /// 该页是否超过解码预算（>12MP 或 >8000px 任一边）。
  ///
  /// 🔴 尺寸优先读工程 json 的 `image_info`（零 IO），缺失才去读文件头
  /// （`PageImageHeader`，纯 Dart、不解码像素）。两处都拿不到 ⇒ 返回 `false`：
  /// 「量不出宽高」和「超预算」是两件事，把量不出当成超预算会把真缺口
  /// 记成"按设计不产出"。
  static bool isBeyondDecodeBudget(
    TranslationProject project,
    String pageKey,
    File source,
  ) {
    var width = 0;
    var height = 0;
    final info = project.imageInfo[pageKey];
    if (info is Map) {
      width = ((info['width'] as num?) ?? 0).toInt();
      height = ((info['height'] as num?) ?? 0).toInt();
    }
    if ((width <= 0 || height <= 0) && source.existsSync()) {
      final size = PageImageHeader.ofFile(source);
      if (size != null) {
        width = size.width;
        height = size.height;
      }
    }
    if (width <= 0 || height <= 0) return false;
    if (width * height > maxPixels) return true;
    return width > maxDimension || height > maxDimension;
  }

  static String _reasonFor({
    required int blocks,
    required int translated,
    required bool mask,
    required bool inpainted,
    required bool result,
    required bool sourceExists,
    required bool tooLarge,
  }) {
    if (blocks == 0) return 'no-blocks';
    if (tooLarge) return 'downscaled';
    // 🔴 顺序要紧：`mask/`+`inpainted/` 只对**有译文**的页产出（它们的输入是
    // `page.regions`，而 region 只由带译文的块产生）。所以"没有译文"必须排在
    // "底图缺"前面，否则刚检测完、还没翻译的页会被整片记成缺口。
    if (translated == 0) return 'no-translation';
    if (!sourceExists && !inpainted && !mask) return 'source-missing';
    if (!mask || !inpainted) return 'base-missing';
    if (!result) return 'result-missing';
    return 'ok';
  }
}

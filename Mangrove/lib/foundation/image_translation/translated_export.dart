import 'dart:io';

import 'package:mangrove/foundation/local.dart';
import 'package:mangrove/foundation/log.dart';
import 'package:mangrove/foundation/translation_project/project.dart';
import 'package:mangrove/foundation/translation_project/project_io.dart';
import 'package:mangrove/foundation/translation_project/studio_reader.dart';
import 'package:mangrove/foundation/translation_project/studio_reader_app.dart';
import 'package:mangrove/utils/io.dart';

/// Builds translated-export mirrors: a folder that reproduces a local comic's
/// on-disk layout (cover at the root, one numbered subdirectory per chapter)
/// but with every page that has a **工作室工程产物** replaced by that product's
/// bitmap. Pages without a product are copied byte for byte, so a partially
/// translated comic still exports cleanly.
///
/// 🔴 S9.5-b 追补：数据源从**旧引擎的即时缓存**（`image_translation.db` 的
/// `TranslationStore` + 现场重绘）换成**工程的 `result/`**。
///
/// 换的原因不是"想统一"，是旧数据源**会导出错的东西**：旧链路取的是
/// `ImageTranslationService.cacheKeyFor(..., page)` 那一行缓存，而阅读器已经
/// 不看它了（`studio_reader.dart::chooseReaderPageSource` 明确不下线到它）。
/// 于是同一个工程会出现"阅读器里是排好版的成品、导出里是旧缓存或原图"，而
/// 两者都不报错。`result/` 是阅读器、工作室预览、导出**三者**共用的那一份。
///
/// The returned [LocalComic] is deliberately NOT registered with
/// [LocalManager]: [LocalComic.baseDir] treats a [LocalComic.directory]
/// containing a path separator as an absolute path, so the existing
/// CBZ/PDF/EPUB exporters can consume the mirror directly without a library
/// entry that would later need cleaning up.
abstract class TranslatedExport {
  /// Writes [comic] into `<parentDir>/mirror` and returns a non-registered
  /// [LocalComic] rooted there. [onProgress] reports emitted/copied pages.
  /// Caller owns [parentDir] cleanup.
  static Future<LocalComic> buildMirror(
    LocalComic comic,
    String parentDir, {
    void Function(int done, int total)? onProgress,
  }) async {
    final mirror = Directory(FilePath.join(parentDir, 'mirror'));
    if (mirror.existsSync()) {
      mirror.deleteSync(recursive: true);
    }
    mirror.createSync(recursive: true);

    // Chapter id doubles as the translation scope id and the on-disk
    // directory name. Flat single-chapter comics scope under eid '0' (the
    // same fallback the reader uses) and write pages at the mirror root.
    final chapterIds = comic.hasChapters
        ? comic.downloadedChapters
        : const <String>['0'];

    // Resolve every chapter's page list up front so progress can report a
    // real total instead of a moving denominator.
    final pages = <(String eid, String? dirName, List<String> urls)>[];
    var totalPages = 0;
    for (final eid in chapterIds) {
      // Flat comics ignore the chapter argument entirely; passing the eid is
      // harmless and keeps one call shape.
      final urls = await LocalManager().getImagesForComic(comic, eid);
      pages.add((eid, comic.hasChapters ? eid : null, urls));
      totalPages += urls.length;
    }

    var done = 0;
    for (final (eid, dirName, urls) in pages) {
      final outDir = dirName == null
          ? mirror
          : (Directory(FilePath.join(mirror.path, dirName))
            ..createSync(recursive: true));
      final products = await _resultPagesFor(comic, eid, urls);
      for (var page = 0; page < urls.length; page++) {
        final src = File(urls[page].replaceFirst('file://', ''));
        final ok = await _emitPage(
          src: src,
          outDir: outDir.path,
          product: products[page],
        );
        if (!ok) {
          Log.error(
            'TranslatedExport',
            'Failed to materialize page ${src.path}',
          );
        }
        done++;
        onProgress?.call(done, totalPages);
      }
    }

    // The cover is never translated; reuse the original bytes.
    await comic.coverFile.copyMem(
      FilePath.join(mirror.path, comic.cover),
    );

    return LocalComic(
      id: comic.id,
      title: comic.title,
      subtitle: comic.subtitle,
      tags: comic.tags,
      comicType: comic.comicType,
      // Absolute path => LocalComic.baseDir uses it verbatim.
      directory: mirror.path,
      chapters: comic.chapters,
      downloadedChapters: comic.downloadedChapters,
      cover: comic.cover,
      createdAt: comic.createdAt,
      description: comic.description,
    );
  }

  /// 这一章每一页的工程成品文件。没有产物的页是 `null`（调用方复制原图）。
  ///
  /// 🔴 页键用 [projectPageKeyFor]（`studio_reader.dart`）算 —— 与阅读器把
  /// 绝对图片路径映射到工程页键用的是**同一个**函数。各写一遍（比如"文件名
  /// 相同就算同一页"）会让 `第1话/1.webp` 撞上 `第2话/1.webp`：每一话的第一页
  /// 都叫 `1.webp`，于是导出里整章被换成别话的图，而文件名看起来完全正常。
  ///
  /// 绑定 / 工程取不到时**整章回落到原图**，不抛：导出一次漫画不该因为一个
  /// 工程的 json 坏掉而整个失败（与 `StudioReaderRenderer.render` 同一条规矩）。
  static Future<List<File?>> _resultPagesFor(
    LocalComic comic,
    String eid,
    List<String> urls,
  ) async {
    final none = List<File?>.filled(urls.length, null);
    if (urls.isEmpty) return none;
    // 🔴 `sourceKey` 取法必须与**写绑定那一侧**一致（建工程入口与详情页预翻译
    // 传的都是 `LocalComic.sourceKey`）。不一致的症状是"绑定在，但导出取不到
    // 产物" —— 整本静默地导回原图。
    final binding = StudioReaderStore.bindingFor(
      cid: comic.id,
      sourceKey: comic.sourceKey,
      eid: eid,
    );
    if (binding == null) return none;
    final file = File(binding.jsonPath);
    if (!file.existsSync()) return none;
    final TranslationProject project;
    try {
      project = await TranslationProjectIo.load(file);
    } catch (e, s) {
      Log.error('TranslatedExport', 'load ${binding.jsonPath} failed: $e', s);
      return none;
    }
    return [
      for (final url in urls)
        switch (projectPageKeyFor(
          projectPageKeys: project.pageOrder,
          imagePath: url,
          comicDirectory: binding.comicDirectory,
        )) {
          final key? => switch (project.resultPath(key)) {
            final path? => File(path),
            _ => null,
          },
          _ => null,
        },
    ];
  }

  /// Writes one page into [outDir]: the project's finished PNG when this page has
  /// one, otherwise an untouched copy of the original. Returns false when the
  /// source file cannot be read.
  static Future<bool> _emitPage({
    required File src,
    required String outDir,
    required File? product,
  }) async {
    if (!src.existsSync()) return false;
    if (product == null) {
      await src.copyMem(FilePath.join(outDir, src.name));
      return true;
    }
    // A PNG container always matches the PNG bytes the renderer wrote; keeping
    // the original extension would lie about the payload.
    await product.copyMem(
      FilePath.join(outDir, '${src.basenameWithoutExt}.png'),
    );
    return true;
  }
}

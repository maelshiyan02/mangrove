import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/source_platform.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/foundation/image_translation/translation_config.dart';
import 'package:venera/foundation/image_translation/translation_pipeline.dart';
import 'package:venera/foundation/image_translation/translation_service.dart';
import 'package:venera/foundation/image_translation/translation_store.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';

/// Builds translated-export mirrors: a folder that reproduces a local comic's
/// on-disk layout (cover at the root, one numbered subdirectory per chapter)
/// but with every page that has a stored translation replaced by its rendered
/// translated bitmap. Pages without a stored translation are copied byte for
/// byte, so a partially translated comic still exports cleanly.
///
/// The returned [LocalComic] is deliberately NOT registered with
/// [LocalManager]: [LocalComic.baseDir] treats a [LocalComic.directory]
/// containing a path separator as an absolute path, so the existing
/// CBZ/PDF/EPUB exporters can consume the mirror directly without a library
/// entry that would later need cleaning up.
abstract class TranslatedExport {
  /// Renders [comic] into `<parentDir>/mirror` and returns a non-registered
  /// [LocalComic] rooted there. [onProgress] reports rendered/copied pages.
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

    final mode = TranslationConfig.of(
      comic.id,
      SourcePlatformResolver.localCanonicalKey,
    ).mode;
    final pipeline = PageTranslationPipeline();
    final store = TranslationStore();
    var done = 0;

    for (final (eid, dirName, urls) in pages) {
      final outDir = dirName == null
          ? mirror
          : (Directory(FilePath.join(mirror.path, dirName))
            ..createSync(recursive: true));
      for (var page = 0; page < urls.length; page++) {
        final src = File(urls[page].replaceFirst('file://', ''));
        final cacheKey = ImageTranslationService.cacheKeyFor(
          SourcePlatformResolver.localCanonicalKey,
          comic.id,
          eid,
          page + 1, // translation keys are 1-based within the chapter
        );
        final ok = await _materializePage(
          src: src,
          outDir: outDir.path,
          regions: store.get(cacheKey),
          pipeline: pipeline,
          mode: mode,
        );
        if (!ok) {
          Log.error(
            'TranslatedExport',
            'Failed to materialize page $cacheKey from ${src.path}',
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

  /// Writes one page into [outDir]: the rendered PNG when a non-empty
  /// translation exists, otherwise an untouched copy. Returns false when the
  /// source file cannot be read.
  static Future<bool> _materializePage({
    required File src,
    required String outDir,
    required List<TranslatedRegion>? regions,
    required PageTranslationPipeline pipeline,
    required InpaintMode mode,
  }) async {
    if (!src.existsSync()) return false;
    if (regions == null || regions.isEmpty) {
      await src.copyMem(FilePath.join(outDir, src.name));
      return true;
    }
    final Uint8List bytes;
    try {
      bytes = await src.readAsBytes();
    } catch (_) {
      return false;
    }
    final rendered = await pipeline.renderPage(bytes, regions, mode: mode);
    // A PNG container always matches the PNG bytes produced by the renderer;
    // keeping the original extension would lie about the payload.
    await File(
      FilePath.join(outDir, '${src.basenameWithoutExt}.png'),
    ).writeAsBytes(rendered);
    return true;
  }
}

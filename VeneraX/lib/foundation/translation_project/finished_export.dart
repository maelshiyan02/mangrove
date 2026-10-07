import 'dart:io';

import 'package:venera/foundation/comic_collection_store.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/local_comic_scanner.dart';

import 'project.dart';

/// Outcome of one [FinishedExport.publish] run.
class FinishedExportReport {
  const FinishedExportReport({
    required this.directory,
    required this.copied,
    required this.missing,
    required this.chapters,
    this.comicId,
    this.collectionId,
    this.error,
  });

  final String directory;
  final int copied;
  final int missing;
  final int chapters;

  /// Library id of the registered "translated" comic, when registration worked.
  final String? comicId;

  /// Collection that groups the source and translated versions, when created.
  final String? collectionId;

  final String? error;

  bool get ok => error == null && copied > 0;

  @override
  String toString() =>
      'copied=$copied missing=$missing chapters=$chapters dir=$directory'
      '${error == null ? '' : ' error=$error'}';
}

/// One page's destination in the finished-product tree.
class FinishedExportItem {
  const FinishedExportItem({
    required this.chapter,
    required this.ordinal,
    required this.pageKey,
    required this.source,
    required this.target,
    required this.sourceExists,
    required this.targetExists,
  });

  final String chapter;

  /// 1-based position inside the chapter, in reading order.
  final int ordinal;

  final String pageKey;
  final String source;
  final String target;

  /// FT's own `result/` page for this key.
  final bool sourceExists;

  /// The page is already in the finished-product tree.
  final bool targetExists;

  /// Available to publish: either FT rendered it, or a previous run did.
  ///
  /// The finished library is the **long-lived** home of the rendered page — the
  /// project's own `result/` is FT's working output and is expected to be
  /// cleaned up once the product is published. Treating an already-published
  /// page as available is what makes re-publishing idempotent instead of
  /// reporting every page as missing.
  bool get available => sourceExists || targetExists;

  /// Whether a copy is worth *attempting*: there is a rendered source, and the
  /// target either doesn't exist yet or holds a stale version.
  ///
  /// 🔴 Was `sourceExists && !targetExists`, which meant a page already
  /// published was **never refreshed** — edit a typo, publish again, and the
  /// product still showed the old page. Correctness now comes from
  /// [FinishedExport.sameContent] (byte compare), which the caller applies
  /// before touching the disk; this flag only says "a copy could be needed".
  bool get needsCopy => sourceExists;
}

/// What a publish run *would* do, computed without touching the filesystem.
///
/// The naming rule is the whole point of the finished-product layout, and it is
/// the one thing that silently breaks the library: a single extra directory
/// level inside a chapter makes the scanner reject the entire comic
/// (`local_comic_scanner.dart`). Being able to ask "where exactly would these
/// 97 pages land?" turns that from a manual click into a check.
class FinishedExportPlan {
  const FinishedExportPlan({
    required this.root,
    required this.items,
    required this.chapters,
  });

  final String root;
  final List<FinishedExportItem> items;
  final List<String> chapters;

  int get total => items.length;

  int get available => items.where((e) => e.available).length;

  int get alreadyPublished => items.where((e) => e.targetExists).length;

  int get missing => total - available;

  /// Chapter directories that would contain a nested directory — must be 0.
  int get nestedViolations =>
      chapters.where((c) => c.contains('/') || c.contains('\\')).length;

  Map<String, dynamic> toJson() => {
    'root': root,
    'chapters': chapters,
    'total': total,
    'available': available,
    'alreadyPublished': alreadyPublished,
    'missing': missing,
    'nestedViolations': nestedViolations,
    'sample': [
      for (final item in items.take(3))
        {
          'chapter': item.chapter,
          'ordinal': item.ordinal,
          'pageKey': item.pageKey,
          'target': item.target,
          'available': item.available,
        },
    ],
  };
}

/// Publishes a project's `result/` pages as a **finished product** (P6 §2.10).
///
/// The shape it writes, `<translated>/<comic>/<chapter>/1.png`, is deliberately
/// the one the local scanner accepts: chapter folders holding nothing but
/// images, no nesting. That is what lets a finished product show up as an
/// ordinary local comic — no special-casing in the reader, no per-page routing
/// (P6 §2.9(c), §2.11(b)).
///
/// Naming is **natural order** (`1.png`, `2.png`, …) rather than FT's page key:
/// the key contains a `/`, so keeping it would nest a folder inside the chapter
/// directory and get the whole comic rejected by the scanner. The
/// key ↔ ordinal mapping is recoverable from the project's `page_order`, so
/// nothing is actually lost.
class FinishedExport {
  const FinishedExport._();

  /// Id prefix of a published product. Distinct from `bt_` so the finished
  /// comic is never mistaken for an editable project.
  static const idPrefix = 'ft_';

  /// Mirrors `BtProjectManager.idPrefix`. Spelled out rather than imported:
  /// this file must stay usable from the headless command without dragging the
  /// reader-side manager (and its Flutter dependencies) along.
  static const btProjectIdPrefix = 'bt_';

  /// Stable id for a product directory, so re-publishing refreshes the same row
  /// instead of piling up duplicates. Same FNV-1a the BT manager uses.
  static String idFor(String directory) {
    var hash = 0x811c9dc5;
    for (final unit in directory.toLowerCase().codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return '$idPrefix${hash.toRadixString(16).padLeft(8, '0')}';
  }

  /// Default product title, distinct from the source comic's so the scanner's
  /// `findByName` duplicate guard does not reject the export.
  static String titleFor(String comicName) => '$comicName · 翻译版';

  /// Resolves the destination of every page without writing anything.
  ///
  /// A flat project has no chapter folders, but the scanner derives pages from
  /// chapter directories — so a flat project gets one synthetic chapter rather
  /// than a comic with no pages at all.
  ///
  /// Keys that have neither a source image nor a finished page are dropped
  /// before numbering. FT's json lists phantom shells (a `.jpg` entry per real
  /// `.webp` page, and on aggregated projects a third variant as well — 291
  /// keys for 97 real pages), and `result/<stem>.png` maps a `.jpg` and a
  /// `.webp` key with the same stem onto **the same file**, so keeping them
  /// would inflate the chapter and break the 1..n numbering. A page that simply
  /// has not been rendered yet is kept and reported as missing instead.
  static FinishedExportPlan plan({
    required TranslationProject project,
    required String translatedRoot,
    required String comicName,
  }) {
    final root =
        '${translatedRoot.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '')}/$comicName';
    final chapters = project.chapters.isNotEmpty
        ? project.chapters
        : {'0': project.pageOrder};
    final items = <FinishedExportItem>[];
    final chapterNames = <String>[];
    for (final chapter in chapters.entries) {
      final name = _safeName(chapter.key);
      var ordinal = 0;
      var wroteChapter = false;
      for (final pageKey in chapter.value) {
        final source = project.artifactPath('result', pageKey);
        final hasResult = File(source).existsSync();
        if (!hasResult && !project.hasDisplayImage(pageKey)) {
          // No `result/` and no usable page image at all — there is nothing to
          // publish for this key. `hasDisplayImage` also accepts `inpainted`/
          // `mask`, so a project whose raw comic folder is gone still exports.
          continue;
        }
        ordinal++;
        // Numbering must be assigned before the target is spelled out: the
        // chapter folder is `<ordinal>.png` starting at 1, and computing the
        // path first shifts the whole chapter by one (page 1 lands on `0.png`).
        final targetPath = '$root/$name/$ordinal.png';
        if (!wroteChapter) {
          chapterNames.add(name);
          wroteChapter = true;
        }
        items.add(
          FinishedExportItem(
            chapter: name,
            ordinal: ordinal,
            pageKey: pageKey,
            source: source,
            target: targetPath,
            sourceExists: hasResult,
            targetExists: File(targetPath).existsSync(),
          ),
        );
      }
    }
    return FinishedExportPlan(root: root, items: items, chapters: chapterNames);
  }

  /// The comic a project belongs to, for naming the product directory.
  ///
  /// FT happily stores a project per chapter (`<comic>/0/imgtrans_0.json`) as
  /// well as one per comic, so the folder name alone is ambiguous: taking
  /// `basename(directory)` of a chapter-scoped project yields `"0"`. A parent
  /// folder that itself holds an `imgtrans_*.json` is the giveaway.
  static String comicNameFor(TranslationProject project) {
    final sourceDir = project.directory;
    final parent = Directory(sourceDir).parent;
    var scopedToChapter = false;
    if (parent.existsSync()) {
      try {
        scopedToChapter = parent.listSync(followLinks: false).whereType<File>().any(
              (file) {
                final name = file.uri.pathSegments.last.toLowerCase();
                return name.startsWith('imgtrans_') && name.endsWith('.json');
              },
            );
      } catch (_) {
        scopedToChapter = false;
      }
    }
    return _basename(scopedToChapter ? parent.path : sourceDir);
  }

  static String _basename(String path) {
    final normalised = path.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
    final slash = normalised.lastIndexOf('/');
    return slash < 0 ? normalised : normalised.substring(slash + 1);
  }

  /// Whether [a] and [b] hold identical bytes.
  ///
  /// 🔴 The publish path used to compare `lengthSync()`, which is not a
  /// content test: a re-rendered page whose only change is a one-character
  /// edit has the **same length**, so the product silently kept the stale
  /// image. Cheap length pre-check first, then a real byte compare.
  ///
  /// Returns false when either file is unreadable — the caller then copies,
  /// which is the safe direction.
  static Future<bool> sameContent(File a, File b) async {
    try {
      if (!a.existsSync() || !b.existsSync()) return false;
      if (a.lengthSync() != b.lengthSync()) return false;
      final left = await a.readAsBytes();
      final right = await b.readAsBytes();
      return _bytesEqual(left, right);
    } catch (_) {
      return false;
    }
  }

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Copies `result/` into [translatedRoot] and registers the result.
  ///
  /// [sourceComicId] is the library id of the original comic; when given, the
  /// two are grouped into one `tabs` collection so a single card carries both
  /// the original and the translation.
  static Future<FinishedExportReport> publish({
    required TranslationProject project,
    required String translatedRoot,
    required String comicName,
    String? sourceComicId,
    void Function(int done, int total)? onProgress,
  }) async {
    final target = Directory(
      '${translatedRoot.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '')}/$comicName',
    );
    try {
      await target.create(recursive: true);
    } catch (e, s) {
      Log.error('Finished Export', 'Cannot create $target', s);
      return FinishedExportReport(
        directory: target.path,
        copied: 0,
        missing: 0,
        chapters: 0,
        error: e.toString(),
      );
    }

    // The plan is the single source of truth for *which* pages ship, so
    // publishing cannot drift from what `export-check` verified.
    final pagePlan = plan(
      project: project,
      translatedRoot: translatedRoot,
      comicName: comicName,
    );
    final chapters = <String, List<FinishedExportItem>>{};
    for (final item in pagePlan.items) {
      chapters.putIfAbsent(item.chapter, () => []).add(item);
    }
    var copied = 0;
    var missing = 0;
    String? firstResult;

    for (final chapter in chapters.entries) {
      final dir = Directory('${target.path}/${chapter.key}');
      await dir.create(recursive: true);
      for (final item in chapter.value) {
        if (item.needsCopy) {
          final destination = File(item.target);
          final source = File(item.source);
          // 🔴 Re-copy when the bytes differ, not when the *length* differs.
          // A re-rendered page can land on exactly the same byte count with
          // different content (a one-word edit is often the same length), and
          // a length check would then silently keep the stale published page —
          // the user re-publishes after fixing a typo and sees no change.
          if (!destination.existsSync() ||
              !await FinishedExport.sameContent(destination, source)) {
            await source.copy(destination.path);
          }
        }
        if (!item.available) {
          // FT never rendered this page and nothing was published for it;
          // numbering stays continuous so the rest keep their reading order.
          missing++;
          onProgress?.call(copied + missing, pagePlan.total);
          continue;
        }
        if (!item.targetExists) firstResult ??= item.target;
        copied++;
        onProgress?.call(copied + missing, pagePlan.total);
      }
    }

    await _writeCover(target, project, firstResult ?? '');

    final comicId = idFor(target.path);
    String? collectionId;
    try {
      collectionId = await _register(
        target: target,
        comicId: comicId,
        comicName: comicName,
        sourceComicId: sourceComicId,
      );
    } catch (e, s) {
      Log.error('Finished Export', 'Registration failed for ${target.path}', s);
      return FinishedExportReport(
        directory: target.path,
        copied: copied,
        missing: missing,
        chapters: chapters.length,
        comicId: comicId,
        error: e.toString(),
      );
    }

    return FinishedExportReport(
      directory: target.path,
      copied: copied,
      missing: missing,
      chapters: chapters.length,
      comicId: comicId,
      collectionId: collectionId,
    );
  }

  /// Copies the project's own cover, falling back to the first finished page so
  /// the library grid has something to show.
  static Future<void> _writeCover(
    Directory target,
    TranslationProject project,
    String firstResult,
  ) async {
    for (final ext in ['jpg', 'jpeg', 'png', 'webp']) {
      final candidate = File('${project.directory}/cover.$ext');
      if (!candidate.existsSync()) continue;
      await candidate.copy('${target.path}/cover.$ext');
      return;
    }
    if (firstResult.isEmpty) return;
    final page = File(firstResult);
    if (!page.existsSync()) return;
    await page.copy('${target.path}/cover.png');
  }

  static Future<String?> _register({
    required Directory target,
    required String comicId,
    required String comicName,
    String? sourceComicId,
  }) async {
    if (!LocalManager().isInitialized) return null;
    final manager = LocalManager();
    final previous = manager.find(comicId, ComicType.local);
    // `rejectExisting: false` — re-publishing must refresh the row we own
    // rather than trip the scanner's duplicate-name guard.
    final scanned = await scanLocalComicDirectory(
      target,
      previous: previous,
      id: comicId,
      title: previous?.title ?? titleFor(comicName),
      subtitle: previous?.subtitle,
      tags: previous?.tags ?? const ['Translated'],
      rejectExisting: false,
    );
    if (scanned == null) return null;
    await manager.add(scanned);
    return _ensureCollection(scanned, comicName, sourceComicId);
  }

  /// One card, two tabs: the original comic and its translation.
  ///
  /// `ComicCollection` already registers itself as a comic source and is
  /// transparent to the reader, history and downloads, which is why this route
  /// was chosen over teaching the reader to follow two `baseDir`s per comic.
  static String? _ensureCollection(
    LocalComic translated,
    String comicName,
    String? sourceComicId,
  ) {
    final source = sourceComicId == null
        ? null
        : LocalManager().find(sourceComicId, ComicType.local);
    final members = <CollectionMember>[
      if (source != null)
        CollectionMember(
          sourceKey: source.sourceKey,
          comicId: source.id,
          // A `bt_` entry is not the original artwork — it is the editable
          // project, which the reader re-renders. Label it for what it is
          // instead of pretending the tab is the raw comic.
          displayName: source.id.startsWith(btProjectIdPrefix)
              ? '工程（重绘）'
              : '原版',
          cachedTitle: source.title,
          cachedCover: source.cover,
        ),
      CollectionMember(
        sourceKey: translated.sourceKey,
        comicId: translated.id,
        displayName: '翻译版',
        cachedTitle: translated.title,
        cachedCover: translated.cover,
      ),
    ];
    // Reuse the collection this pair already lives in, so publishing twice does
    // not create a second card.
    for (final collection in ComicCollectionStore.all()) {
      if (collection.members.any((m) => m.comicId == translated.id)) {
        ComicCollectionStore.update(
          collection.id,
          displayMode: CollectionDisplayMode.tabs,
          members: members,
        );
        return collection.id;
      }
    }
    if (members.length < 2) return null;
    return ComicCollectionStore.create(
      name: comicName,
      members: members,
      displayMode: CollectionDisplayMode.tabs,
    ).id;
  }

  /// Chapter folders are user-visible names; strip what a path cannot hold.
  static String _safeName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '0';
    final cleaned = trimmed.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    return cleaned;
  }
}

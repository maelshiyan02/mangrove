import 'dart:io';

import '../image_translation/translation_types.dart';
import 'text_block.dart';

/// One page of a translation project: its key plus its text blocks.
///
/// The block list is held as the raw decoded list so that anything FT wrote and
/// we do not model — including entries that are not objects at all — survives a
/// save untouched.
class ProjectPage {
  ProjectPage(this.key, this.rawBlocks);

  /// Page key as stored in the project, e.g. `0/1.webp` (forward slashes).
  final String key;

  /// The live JSON array; mutations land here.
  final List<Object?> rawBlocks;

  /// Typed views over [rawBlocks], skipping anything that is not an object.
  List<TextBlock> get blocks {
    return [
      for (final entry in rawBlocks)
        if (asObjectMap(entry) case final map?) TextBlock(map),
    ];
  }

  /// Blocks that actually carry a translation worth rendering.
  List<TextBlock> get translatedBlocks {
    return [
      for (final block in blocks)
        if (block.hasTranslation) block,
    ];
  }

  bool get hasTranslation => blocks.any((block) => block.hasTranslation);

  /// Regions for the existing renderer, in order.
  List<TranslatedRegion> get regions {
    final result = <TranslatedRegion>[];
    for (final block in blocks) {
      final region = block.toTranslatedRegion();
      if (region != null) result.add(region);
    }
    return result;
  }

  /// Appends [block]'s raw payload to the page.
  void addBlock(TextBlock block) => rawBlocks.add(block.raw);

  /// Appends several blocks at once.
  ///
  /// 🔴 存在的理由是**批量落地必须是一次可撤销的编辑**：S9 的自动管线一章会
  /// 产生几十个块，若逐块 `addBlock`，用户要按几十次 Ctrl+Z 才能回到跑之前的
  /// 状态 —— 而"跑错了，一键回退"是这个按钮存在的前提。工作室的批量路径因此
  /// 走这个方法（配合 `captureBlockListEdit`，与 Create/Delete 同一条）。
  void addBlocks(Iterable<TextBlock> blocks) {
    for (final block in blocks) {
      rawBlocks.add(block.raw);
    }
  }

  /// Drops every block whose raw payload is [block].
  bool removeBlock(TextBlock block) => rawBlocks.remove(block.raw);
}

/// A Fan Translation project loaded from an `imgtrans_*.json` file.
///
/// ## Ordered DOM passthrough
///
/// [raw] is the decoded JSON, kept in its original key order, and it is what
/// gets written back. Typed views ([pages], [pageOrder], [chapters], …) are
/// derived from it. Nothing is ever dropped: unknown top-level keys, unknown
/// per-block keys, and page keys with no corresponding file on disk all survive
/// a save, which is what keeps "read -> unchanged -> write" a zero-byte diff.
///
/// ## Two roots
///
/// FT separates the root of the **source images** ([directory]) from the root
/// of its **generated artifacts** ([workspace]: `mask/`, `inpainted/`,
/// `result/`). Both are absolute paths in the file, and [workspace] may differ
/// from [directory] — that is how the studio can keep its products outside the
/// read-only download folder while FT still opens the project.
///
/// [directory] and [workspace] here are **resolved** (falling back to the
/// JSON's own folder when the stored path is missing or absent). Use
/// [setDirectory] / [setWorkspace] to change them; the resolved values are
/// never written back implicitly, so loading a project cannot rewrite it.
class TranslationProject {
  TranslationProject({
    required this.raw,
    required this.jsonFile,
    required this.pages,
  });

  /// The decoded JSON object, in its original key order. Authoritative.
  final Map<String, Object?> raw;

  /// The file this project was read from (may not exist for a new project).
  final File jsonFile;

  /// Pages by key, in the order FT stored them.
  final Map<String, ProjectPage> pages;

  static const Set<String> _imageExtensions = {
    '.jpg',
    '.jpeg',
    '.png',
    '.webp',
    '.bmp',
    '.gif',
    '.avif',
  };

  /// Normalises Windows separators the way FT does.
  static String _normalisePath(String path) => path.replaceAll('\\', '/');

  /// Folder holding the JSON file, as an absolute forward-slash path.
  String get jsonDirectory => _normalisePath(jsonFile.parent.absolute.path);

  /// File name FT expects for a project rooted at [directoryName] —
  /// `imgtrans_<name>.json`, matching both real sample projects.
  static String jsonFileNameFor(String directoryName) {
    final trimmed = directoryName
        .replaceAll(RegExp(r'[\\/]+$'), '')
        .split(RegExp(r'[\\/]'))
        .last;
    return 'imgtrans_$trimmed.json';
  }

  /// Name of this project's JSON file.
  String get jsonFileName => jsonFile.uri.pathSegments.last;

  /// Root of the source page images.
  String get directory {
    final stored = _normalisePath(raw['directory']?.toString() ?? '');
    if (stored.isEmpty || !Directory(stored).existsSync()) {
      return jsonDirectory;
    }
    return stored;
  }

  /// Root of FT's generated artifacts (`mask/`, `inpainted/`, `result/`).
  ///
  /// Resolution order — **this is the "assembly" rule of the studio layout**
  /// (P6 §2.11(a)):
  ///
  /// 1. the stored `workspace` key, when it points at a directory that exists;
  /// 2. otherwise **the folder holding this JSON file**.
  ///
  /// It deliberately does *not* fall back to [directory]. FT never writes a
  /// `workspace` key at all (`proj_imgtrans.py`'s `to_dict` only emits
  /// `directory`, and `mask_dir()`/`inpainted_dir()`/`result_dir()` all hang off
  /// that same folder), so a missing key means "unknown", not "same as
  /// `directory`". Falling back to the JSON's own folder keeps both real
  /// layouts correct with one rule:
  ///
  /// * an in-place FT project — JSON sits next to its images, so this equals
  ///   [directory] and nothing changes;
  /// * a studio project under `ComicLibrary/projects/<manga>/` — sources stay in
  ///   the read-only download folder and the artifacts sit next to the JSON.
  ///
  /// Resolved values are never written back implicitly, so loading a project
  /// cannot rewrite it.
  String get workspace {
    final stored = _normalisePath(raw['workspace']?.toString() ?? '');
    if (stored.isNotEmpty && Directory(stored).existsSync()) {
      return stored;
    }
    return jsonDirectory;
  }

  /// Whether the project keeps its artifacts next to the source images.
  bool get isInPlaceLayout => workspace == directory;

  /// Points the artifact root at [path] — the only difference between an
  /// in-place FT project and a studio project under `ComicLibrary/projects/`.
  void setWorkspace(String path) => raw['workspace'] = _normalisePath(path);

  /// Points the source-image root at [path].
  void setDirectory(String path) => raw['directory'] = _normalisePath(path);

  /// Drops the `workspace` key, restoring FT's in-place layout.
  void clearWorkspace() => raw.remove('workspace');

  /// Page keys in reading order.
  ///
  /// Mirrors the legacy `BtProject.parse`: the stored `page_order` is filtered
  /// to keys that exist in `pages`, and the raw key order is the fallback.
  List<String> get pageOrder {
    final result = <String>[];
    final stored = asObjectList(raw['page_order']);
    if (stored != null) {
      for (final entry in stored) {
        final key = _normalisePath(entry.toString());
        if (pages.containsKey(key)) result.add(key);
      }
    }
    if (result.isEmpty) return pages.keys.toList();
    return result;
  }

  /// Chapter name -> page keys, in order. Empty for flat projects.
  Map<String, List<String>> get chapters {
    final result = <String, List<String>>{};
    final stored = asObjectList(raw['chapters']);
    if (stored == null) return result;
    for (final chapter in stored) {
      final map = asObjectMap(chapter);
      if (map == null) continue;
      final name = map['name']?.toString() ?? '';
      if (name.isEmpty) continue;
      final inChapter = <String>[];
      final chapterPages = asObjectList(map['pages']);
      if (chapterPages != null) {
        for (final entry in chapterPages) {
          final key = _normalisePath(entry.toString());
          if (pages.containsKey(key)) inChapter.add(key);
        }
      }
      if (inChapter.isNotEmpty) result[name] = inChapter;
    }
    return result;
  }

  /// Per-page metadata FT records: `{finish_code, width, height,
  /// translation_target}` keyed by page key.
  Map<String, Object?> get imageInfo =>
      asObjectMap(raw['image_info']) ?? const {};

  /// The page FT last had open, if recorded.
  String? get currentImage {
    final value = raw['current_img'];
    return value is String && value.isNotEmpty ? value : null;
  }

  set currentImage(String? value) {
    if (value == null) {
      raw.remove('current_img');
    } else {
      raw['current_img'] = value;
    }
  }

  /// Registers a new page and, when given, its position in `page_order`.
  ProjectPage putPage(String key, {List<Object?>? blocks}) {
    final normalised = _normalisePath(key);
    final existing = pages[normalised];
    if (existing != null) {
      if (blocks != null) {
        existing.rawBlocks
          ..clear()
          ..addAll(blocks);
      }
      return existing;
    }
    final created = ProjectPage(normalised, blocks ?? <Object?>[]);
    pages[normalised] = created;
    final stored = asObjectMap(raw['pages']);
    if (stored != null) stored[normalised] = created.rawBlocks;
    return created;
  }

  /// Removes a page from both the map view and the JSON.
  bool removePage(String key) {
    final normalised = _normalisePath(key);
    final removed = pages.remove(normalised);
    asObjectMap(raw['pages'])?.remove(normalised);
    final stored = asObjectList(raw['page_order']);
    if (stored != null) {
      stored.removeWhere(
        (entry) => _normalisePath(entry.toString()) == normalised,
      );
    }
    return removed != null;
  }

  /// Whether [pageKey] names something the reader can display.
  static bool isImagePage(String pageKey) {
    final dot = pageKey.lastIndexOf('.');
    if (dot < 0) return false;
    return _imageExtensions.contains(pageKey.substring(dot).toLowerCase());
  }

  /// Absolute path of the source page image.
  String originalPath(String pageKey) => '$directory/$pageKey';

  /// Strips the extension from [pageKey] — artifact files are always `.png`.
  static String pageStem(String pageKey) {
    final dot = pageKey.lastIndexOf('.');
    return dot < 0 ? pageKey : pageKey.substring(0, dot);
  }

  /// Absolute path of an artifact of [kind] for [pageKey], whether or not it
  /// exists. This is the single rule behind the unified save contract:
  /// `<root>/<kind>/<page key without extension>.png`.
  String artifactPath(String kind, String pageKey, {String? root}) {
    return '${root ?? workspace}/$kind/${pageStem(pageKey)}.png';
  }

  /// Absolute path of the inpainted (text-erased) page, or null when FT has
  /// not produced one (or produced a format Flutter cannot decode, e.g. .jxl).
  String? inpaintedPath(String pageKey) {
    final path = artifactPath('inpainted', pageKey);
    return File(path).existsSync() ? path : null;
  }

  /// Absolute path of the mask page, or null when absent.
  String? maskPath(String pageKey) {
    final path = artifactPath('mask', pageKey);
    return File(path).existsSync() ? path : null;
  }

  /// Absolute path of the lettered product page, or null when absent.
  ///
  /// The reader uses this for "prefer the finished bitmap" while the studio
  /// always re-draws from `inpainted` + JSON, so a stale `result/` can never
  /// mask an edit.
  String? resultPath(String pageKey) {
    final path = artifactPath('result', pageKey);
    return File(path).existsSync() ? path : null;
  }

  /// Best available bitmap for [pageKey]: the source page, else `inpainted/`
  /// (text already erased — a better base than the raw page), else `mask/`.
  ///
  /// 🔴 A project whose `directory` (the raw comic) was moved or deleted used
  /// to be treated as having no pages at all: the scan dropped it, the studio
  /// list came up empty, and nothing said why. BT's derived artifacts live
  /// under [workspace] and survive, so they are a legitimate page source.
  String? displayPath(String pageKey) {
    final original = originalPath(pageKey);
    if (File(original).existsSync()) return original;
    return inpaintedPath(pageKey) ?? maskPath(pageKey) ?? resultPath(pageKey);
  }

  /// Whether [pageKey] has any usable bitmap (see [displayPath]).
  bool hasDisplayImage(String pageKey) => displayPath(pageKey) != null;

  /// Page keys of chapter [chapter] in reading order, restricted to image
  /// files that still exist on disk.
  ///
  /// Mirrors the legacy `BtProject.pageKeysForChapter`, including its "file
  /// existence" filter that hides FT's phantom page keys — but resolves
  /// existence through [displayPath] so a project whose raw comic folder is
  /// gone still lists its pages from `inpainted`/`mask`.
  List<String> pageKeysForChapter(Object chapter) {
    final byChapter = chapters;
    List<String> keys;
    if (byChapter.isEmpty) {
      keys = pageOrder;
    } else {
      final index = chapter is int
          ? chapter - 1
          : byChapter.keys.toList().indexOf(chapter.toString());
      if (index < 0 || index >= byChapter.length) return const [];
      keys = byChapter.values.elementAt(index);
    }
    return [
      for (final key in keys)
        if (isImagePage(key) && hasDisplayImage(key)) key,
    ];
  }

  /// A shallow copy sharing [raw] is not safe for editing, so this copies the
  /// decoded structure — used by tests and by "save as" flows.
  TranslationProject copy({File? jsonFile}) {
    final cloned = _deepCopyMap(raw);
    return buildFrom(cloned, jsonFile ?? this.jsonFile);
  }

  /// Wraps an already-decoded JSON object without re-reading the file.
  static TranslationProject buildFrom(Map<String, Object?> raw, File jsonFile) {
    final pages = <String, ProjectPage>{};
    final stored = asObjectMap(raw['pages']);
    if (stored != null) {
      for (final entry in stored.entries) {
        final key = _normalisePath(entry.key);
        final blocks = asObjectList(entry.value);
        // Non-list payloads stay in the JSON untouched but get no page view,
        // matching how the legacy parser walks the map.
        if (blocks != null) pages[key] = ProjectPage(key, blocks);
      }
    }
    return TranslationProject(raw: raw, jsonFile: jsonFile, pages: pages);
  }

  /// Creates an empty project.
  ///
  /// [directory] is the root of the source images; [workspace] is the root of
  /// the generated artifacts. Passing a [workspace] different from [directory]
  /// is the studio layout; leaving it null keeps FT's in-place layout, and the
  /// key is then absent from the JSON exactly as FT leaves it.
  ///
  /// The key order matches what FT writes, so a project saved straight after
  /// creation already looks like something FT produced.
  static TranslationProject create({
    required File jsonFile,
    required String directory,
    String? workspace,
  }) {
    final raw = <String, Object?>{
      'directory': _normalisePath(directory),
      if (workspace != null) 'workspace': _normalisePath(workspace),
      'pages': <String, Object?>{},
      'current_img': '',
      'image_info': <String, Object?>{},
      'page_order': <Object?>[],
      'chapters': <Object?>[],
    };
    return buildFrom(raw, jsonFile);
  }

  static Map<String, Object?> _deepCopyMap(Map<String, Object?> source) {
    final result = <String, Object?>{};
    source.forEach((key, value) => result[key] = _deepCopy(value));
    return result;
  }

  static Object? _deepCopy(Object? value) {
    if (value is Map) {
      final result = <String, Object?>{};
      value.forEach((key, entry) => result[key.toString()] = _deepCopy(entry));
      return result;
    }
    if (value is List) return [for (final entry in value) _deepCopy(entry)];
    return value;
  }
}

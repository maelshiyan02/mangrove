import 'dart:convert';
import 'dart:io';

import '../image_translation/translation_types.dart';
import '../translation_project/project.dart';
import '../translation_project/project_io.dart';

/// Read-only access to one BallonsTranslator project file (imgtrans_*.json).
///
/// The JSON mirrors BT's on-disk workspace: [directory] is the root of the
/// original page images, page keys in [pages] are forward-slash paths relative
/// to it, and inpainted (text-erased) pages live at
/// `<workspace>/inpainted/<page key without extension>.png`.
class BtProject {
  BtProject._({
    required this.jsonFile,
    required this.directory,
    required this.workspace,
    required this.pageOrder,
    required this.chapters,
    required Map<String, List<TranslatedRegion>> regions,
  }) : _regions = Map.unmodifiable(regions);

  /// The imgtrans_*.json file this project was parsed from.
  final File jsonFile;

  /// Absolute root of the original page images (forward slashes).
  final String directory;

  /// Absolute root of BT's generated artifacts (inpainted/mask/result).
  /// Equals [directory] when the project uses BT's in-place layout.
  final String workspace;

  /// Page keys in BT's reading order. Falls back to the raw key order of the
  /// `pages` map when the project has no explicit `page_order`.
  final List<String> pageOrder;

  /// Chapter title -> page keys, in order. Empty for flat projects.
  final Map<String, List<String>> chapters;

  final Map<String, List<TranslatedRegion>> _regions;

  static const _imageExtensions = {
    '.jpg',
    '.jpeg',
    '.png',
    '.webp',
    '.bmp',
    '.gif',
    '.avif',
  };

  /// Whether the most recent [load] had to fall back to [parse].
  ///
  /// Kept as a flag rather than logged here so this file stays free of Flutter
  /// imports and can run under a plain `dart run` during verification.
  /// [BtProjectManager] reports it through the app log.
  static bool lastLoadUsedLegacyParser = false;

  /// The error that forced the fallback, for the same reporting path.
  static Object? lastLoadError;

  /// Reads [file] through the full translation model.
  ///
  /// The model understands every FT field, so it is the primary path; the
  /// hand-rolled [parse] below stays as a safety net so that a project whose
  /// shape the model rejects still opens instead of vanishing from the
  /// library. The two are equivalent by construction — same page-order
  /// fallback, same chapter filtering, same block-to-region rules — and
  /// `tools/s6_project_roundtrip.dart` checks that against a real project.
  static Future<BtProject> load(File file) async {
    final raw = await file.readAsString();
    try {
      final project = TranslationProjectIo.parse(raw, file);
      lastLoadUsedLegacyParser = false;
      lastLoadError = null;
      return BtProject.fromTranslationProject(project, file);
    } catch (error) {
      lastLoadUsedLegacyParser = true;
      lastLoadError = error;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException(
          'Not a BT project: top level is not an object',
        );
      }
      return BtProject.parse(decoded, file);
    }
  }

  /// Builds the reader-facing view from the full translation model.
  factory BtProject.fromTranslationProject(
    TranslationProject project,
    File jsonFile,
  ) {
    final regions = <String, List<TranslatedRegion>>{};
    project.pages.forEach((key, page) {
      regions[key] = page.regions;
    });
    return BtProject._(
      jsonFile: jsonFile,
      directory: project.directory,
      workspace: project.workspace,
      pageOrder: project.pageOrder,
      chapters: project.chapters,
      regions: regions,
    );
  }

  /// Pure-Dart parse path, separated from IO so tests can feed fixtures.
  ///
  /// Retained as the reference implementation and as [load]'s fallback; the
  /// full model in `lib/foundation/translation_project/` is the primary path
  /// now that the studio needs to read and write the same files.
  static BtProject parse(Map<String, dynamic> json, File jsonFile) {
    final jsonDir = jsonFile.parent.absolute.path.replaceAll('\\', '/');

    var directory = (json['directory'] as String?)?.replaceAll('\\', '/') ?? '';
    if (directory.isEmpty || !Directory(directory).existsSync()) {
      directory = jsonDir;
    }
    var workspace = (json['workspace'] as String?)?.replaceAll('\\', '/') ?? '';
    if (workspace.isEmpty || !Directory(workspace).existsSync()) {
      // Same assembly rule as `TranslationProject.workspace`: FT never writes
      // the key, so the JSON's own folder is the fallback — which equals
      // `directory` for every in-place FT project and points at the real
      // artifact root for a studio project under ComicLibrary/projects/.
      workspace = jsonDir;
    }

    final regions = <String, List<TranslatedRegion>>{};
    final pages = json['pages'];
    if (pages is Map) {
      for (final entry in pages.entries) {
        final key = entry.key.toString().replaceAll('\\', '/');
        final blocks = entry.value;
        if (blocks is! List) continue;
        final parsed = <TranslatedRegion>[];
        for (final block in blocks) {
          final region = _parseBlock(block);
          if (region != null) parsed.add(region);
        }
        regions[key] = parsed;
      }
    }

    var pageOrder = <String>[];
    final rawOrder = json['page_order'];
    if (rawOrder is List) {
      pageOrder = rawOrder
          .map((e) => e.toString().replaceAll('\\', '/'))
          .where(regions.containsKey)
          .toList();
    }
    if (pageOrder.isEmpty) {
      pageOrder = regions.keys.toList();
    }

    final chapters = <String, List<String>>{};
    final rawChapters = json['chapters'];
    if (rawChapters is List) {
      for (final chapter in rawChapters) {
        if (chapter is! Map) continue;
        final name = chapter['name']?.toString() ?? '';
        if (name.isEmpty) continue;
        final rawPages = chapter['pages'];
        final pagesInChapter = <String>[];
        if (rawPages is List) {
          for (final p in rawPages) {
            final key = p.toString().replaceAll('\\', '/');
            if (regions.containsKey(key)) pagesInChapter.add(key);
          }
        }
        if (pagesInChapter.isNotEmpty) {
          chapters[name] = pagesInChapter;
        }
      }
    }

    return BtProject._(
      jsonFile: jsonFile,
      directory: directory,
      workspace: workspace,
      pageOrder: pageOrder,
      chapters: chapters,
      regions: regions,
    );
  }

  /// One BT text block -> one render region. Returns null for blocks without a
  /// translation (BT stores them with an empty string) or with unusable boxes.
  static TranslatedRegion? _parseBlock(Object? block) {
    if (block is! Map) return null;
    final text = block['translation']?.toString().trim() ?? '';
    if (text.isEmpty) return null;
    final xyxy = block['xyxy'];
    if (xyxy is! List || xyxy.length < 4) return null;
    final numbers = [
      for (final v in xyxy.take(4)) (v as num?)?.toDouble() ?? 0.0,
    ];
    final rect = IntRect(
      numbers[0].floor(),
      numbers[1].floor(),
      numbers[2].ceil(),
      numbers[3].ceil(),
    );
    if (rect.width < 4 || rect.height < 4) return null;

    var fontSize = 0;
    final detected = block['_detected_font_size'];
    if (detected is num && detected > 0) {
      fontSize = detected.round();
    }

    int textColor = 0xFF000000;
    int backgroundColor = 0xFFFFFFFF;
    final fontformat = block['fontformat'];
    if (fontformat is Map) {
      textColor = _rgb(fontformat['frgb']) ?? textColor;
      backgroundColor = _rgb(fontformat['srgb']) ?? backgroundColor;
    }

    return TranslatedRegion(
      rect: rect,
      text: text,
      backgroundColor: backgroundColor,
      textColor: textColor,
      lineHeight: fontSize,
    );
  }

  /// BT stores colours as `[r, g, b]` with values in 0..255.
  static int? _rgb(Object? value) {
    if (value is! List || value.length < 3) return null;
    final r = (value[0] as num?)?.round().clamp(0, 255);
    final g = (value[1] as num?)?.round().clamp(0, 255);
    final b = (value[2] as num?)?.round().clamp(0, 255);
    if (r == null || g == null || b == null) return null;
    return 0xFF000000 | (r << 16) | (g << 8) | b;
  }

  /// Whether [pageKey] is an image file the reader can display.
  static bool isImagePage(String pageKey) {
    final dot = pageKey.lastIndexOf('.');
    if (dot < 0) return false;
    return _imageExtensions.contains(pageKey.substring(dot).toLowerCase());
  }

  /// Translated regions of one page; empty when the page has no usable blocks.
  List<TranslatedRegion> regionsFor(String pageKey) =>
      _regions[pageKey] ?? const [];

  /// Whether the page has at least one translated block worth rendering.
  bool hasTranslation(String pageKey) => regionsFor(pageKey).isNotEmpty;

  /// Absolute path of the original page image.
  String originalPath(String pageKey) => '$directory/$pageKey';

  /// Absolute path of the inpainted (text-erased) page, or null when BT has
  /// not produced it (or produced a format Flutter cannot decode, e.g. .jxl).
  String? inpaintedPath(String pageKey) {
    final dot = pageKey.lastIndexOf('.');
    final stem = dot < 0 ? pageKey : pageKey.substring(0, dot);
    final file = File('$workspace/inpainted/$stem.png');
    return file.existsSync() ? file.path : null;
  }

  /// Absolute path of the mask page, or null when absent.
  String? maskPath(String pageKey) {
    final dot = pageKey.lastIndexOf('.');
    final stem = dot < 0 ? pageKey : pageKey.substring(0, dot);
    final file = File('$workspace/mask/$stem.png');
    return file.existsSync() ? file.path : null;
  }

  /// Best available bitmap for [pageKey], or null when nothing exists on disk.
  ///
  /// 🔴 Why this exists: a project whose `directory` (the raw comic) was moved
  /// or deleted used to make the whole project unusable — the scan silently
  /// dropped it ([BtProjectManager] skips projects with no resolvable cover)
  /// and the studio list came up empty. But BT's *derived* artifacts
  /// (`inpainted/`, `mask/`) live under [workspace] and survive, and they are
  /// what the studio actually needs: `inpainted` already has the text erased,
  /// so it is a strictly better base than the raw page.
  ///
  /// Preference: original → inpainted → mask. The original wins when present so
  /// nothing changes for healthy projects.
  String? displayPath(String pageKey) {
    final original = originalPath(pageKey);
    if (File(original).existsSync()) return original;
    return inpaintedPath(pageKey) ?? maskPath(pageKey);
  }

  /// Whether [pageKey] has any usable bitmap (see [displayPath]).
  bool hasDisplayImage(String pageKey) => displayPath(pageKey) != null;

  /// Page keys of chapter [ep] (1-based) in reading order, restricted to pages
  /// that still have an image on disk. Flat projects treat the whole
  /// [pageOrder] as the only chapter.
  ///
  /// Uses [displayPath] rather than the raw original so a project whose
  /// `directory` is gone still lists its pages (from inpainted/mask).
  List<String> pageKeysForChapter(Object ep) {
    List<String> keys;
    if (chapters.isEmpty) {
      keys = pageOrder;
    } else {
      final index = ep is int
          ? ep - 1
          : chapters.keys.toList().indexOf(ep.toString());
      if (index < 0 || index >= chapters.length) return const [];
      keys = chapters.values.elementAt(index);
    }
    return keys
        .where((key) => isImagePage(key) && hasDisplayImage(key))
        .toList();
  }
}

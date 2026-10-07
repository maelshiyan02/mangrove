import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../appdata.dart';
import '../comic_source/comic_source.dart' show ComicChapters;
import '../comic_type.dart';
import '../image_translation/page_renderer.dart';
import '../image_translation/translation_types.dart';
import '../local.dart';
import '../log.dart';
import '../../utils/file_type.dart';
import '../chapter_title_parser.dart';
import 'bt_project.dart';
import '../translation_project/project.dart';
import '../translation_project/project_io.dart';

/// Registers BallonsTranslator projects as read-only local comics.
///
/// [appdata.settings['btProjectRoot']] points at BT's own workspace root (kept
/// outside the comic library so the raw-comic scanner never picks it up). A
/// scan walks that tree for `imgtrans_*.json` files — each one becomes one
/// [LocalComic] whose id carries [idPrefix] so every later decision (page
/// listing, reader rendering, delete-dialog defaults) can recognise it without
/// touching paths.
class BtProjectManager extends ChangeNotifier {
  static BtProjectManager? _instance;

  BtProjectManager._();

  factory BtProjectManager() => _instance ??= BtProjectManager._();

  static const idPrefix = 'bt_';

  /// BT artifact directories that mirror the source tree — skipping them keeps
  /// the walk from descending into hundreds of generated images.
  static const _skippedDirs = {'mask', 'inpainted', 'result', 'assets'};

  /// comicId -> parsed project. Rebuilt by [scan].
  final Map<String, BtProject> _projects = {};

  /// comicId -> imgtrans json mtime (ms), also used as the reader cache buster.
  final Map<String, int> _mtimes = {};

  /// Shared scan future. Concurrent callers (startup + local page + reader)
  /// all await the SAME scan instead of one of them getting an empty "done"
  /// while another walk is still in flight.
  Future<void>? _scanFuture;

  /// The configured workspace root; empty disables the feature.
  ///
   /// Kept for callers that only need one path (settings UI, diagnostics). New
   /// code should use [roots]: a studio project lives in `ComicLibrary/projects`
   /// while an old in-place FT project still sits next to its images in
   /// `ComicLibrary/downloads`, and pointing the setting at either one alone
   /// means the other becomes invisible.
  static String get root =>
      (appdata.settings['btProjectRoot'] as String? ?? '').trim();

  /// Every configured root. Semicolon-separated so the setting stays a plain
  /// string and an existing single-path value keeps working untouched.
  static List<String> get roots {
    final raw = appdata.settings['btProjectRoot'];
    if (raw is! String) return const [];
    final result = <String>[];
    for (final part in raw.split(';')) {
      final trimmed = part.trim();
      if (trimmed.isNotEmpty && !result.contains(trimmed)) {
        result.add(trimmed);
      }
    }
    return result;
  }

  static bool get isEnabled => roots.isNotEmpty;

  /// Every comic this manager registered carries the prefix.
  static bool isBtComic(String? id) => id != null && id.startsWith(idPrefix);

  BtProject? projectFor(String comicId) => _projects[comicId];

  /// Runs a scan when the in-memory registry is empty. The registry is the
  /// only thing that can answer reader/cover requests, and not every entry
  /// point (home history, favorites, deep links) passes through the local
  /// comics page that historically owned scanning.
  Future<void> ensureReady() async {
    if (!isEnabled) return;
    if (_projects.isNotEmpty) return;
    await scan();
  }

  /// Returns the project after making sure at least one scan has run. Null
  /// means the project genuinely does not exist under [root].
  Future<BtProject?> ensureProject(String comicId) async {
    final cached = _projects[comicId];
    if (cached != null) return cached;
    await ensureReady();
    return _projects[comicId];
  }

  /// mtime of the project's json file, 0 when unknown. Mixed into the reader's
  /// image-provider key so saving in BT refreshes the displayed page.
  int jsonMtimeMs(String comicId) => _mtimes[comicId] ?? 0;

  /// Page image urls (`file://` + absolute path) of chapter [ep] in BT's
  /// reading order. Throws when the project is unknown so the reader surfaces
  /// an error instead of silently listing the raw directory.
  Future<List<String>> getImages(String comicId, Object ep) async {
    final project = await ensureProject(comicId);
    if (project == null) {
      throw "BT project not found (rescan needed)";
    }
    return project
        .pageKeysForChapter(ep)
        .map((key) => 'file://${project.displayPath(key)}')
        .toList();
  }

  /// Resolves a project's cover: a `cover.*` file in the project directory
  /// takes priority; otherwise the first existing page image in BT's page
  /// order. Returns null when the project is unknown or no usable file exists.
  Future<BtCover?> loadCover(String comicId) async {
    final project = await ensureProject(comicId);
    if (project == null) return null;
    final key = coverKeyFor(project);
    if (key == null) return null;
    final path = key.startsWith('cover.')
        ? '${project.directory}/$key'
        : (project.displayPath(key) ?? project.originalPath(key));
    final bytes = await File(path).readAsBytes();
    if (bytes.isEmpty) return null;
    return BtCover(key, bytes);
  }

  /// Cover key: `cover.<ext>` if a cover file exists in the project directory,
  /// otherwise the first page key (in BT reading order) whose image file exists.
  ///
  /// 🔴 Uses [BtProject.displayPath] (original → inpainted → mask), not the raw
  /// original: a project whose raw comic folder was moved/deleted used to have
  /// no resolvable cover, which made [scan] drop the whole project and left the
  /// studio list silently empty with no clue why.
  static String? coverKeyFor(BtProject project) {
    for (final ext in ['jpg', 'jpeg', 'png', 'webp']) {
      final coverPath = '${project.directory}/cover.$ext';
      if (File(coverPath).existsSync()) {
        return 'cover.$ext';
      }
    }
    final key = project.pageOrder.firstWhere(
      (key) => BtProject.isImagePage(key) && project.hasDisplayImage(key),
      orElse: () => '',
    );
    return key.isEmpty ? null : key;
  }

  /// Sets a custom cover for a BT project. Writes the bytes to
  /// `directory/cover.<ext>`, removes any previous cover file with a
  /// different extension, updates the LocalComic cover field, and evicts
  /// cached image entries so the UI refreshes immediately.
  Future<bool> setCover(String comicId, Uint8List bytes) async {
    final project = await ensureProject(comicId);
    if (project == null) return false;
    final fileType = detectFileType(bytes);
    final coverPath = '${project.directory}/cover${fileType.ext}';

    // Remove old cover files with different extensions.
    for (final ext in ['jpg', 'jpeg', 'png', 'webp']) {
      final old = File('${project.directory}/cover.$ext');
      if (old.existsSync() && 'cover.$ext' != 'cover${fileType.ext}') {
        await old.delete();
      }
    }

    await File(coverPath).writeAsBytes(bytes);
    final coverKey = 'cover${fileType.ext}';

    // Update LocalComic so the grid and history pick up the new cover.
    final manager = LocalManager();
    final old = manager.find(comicId, ComicType.local);
    if (old != null) {
      manager.add(
        LocalComic(
          id: old.id,
          title: old.title,
          subtitle: old.subtitle,
          tags: old.tags,
          directory: old.directory,
          chapters: old.chapters,
          cover: coverKey,
          comicType: old.comicType,
          downloadedChapters: old.downloadedChapters,
          createdAt: old.createdAt,
          description: old.description,
        ),
      );
    }

    // Evict cached image so the new cover shows immediately.
    PaintingBinding.instance.imageCache.clear();

    return true;
  }

  /// Full FT-contract model for [comicId], parsed on demand.
  ///
  /// [BtProject] is the reader's view: it keeps only rect/text/colour, which is
  /// all a re-render needs. The studio's property panel has to show
  /// `font_family` / `alignment` / `vertical` / `line_spacing` verbatim, so it
  /// re-reads the same json through the full model. Only one project is open at
  /// a time, so the second parse costs a few hundred kilobytes once.
  Future<TranslationProject?> ensureTranslationProject(String comicId) async {
    final project = await ensureProject(comicId);
    if (project == null) return null;
    return TranslationProjectIo.load(project.jsonFile);
  }

  /// Renders one BT page: inpainted base + translated blocks drawn with the
  /// existing translation pipeline. Returns null when the page has no usable
  /// translation or no inpainted image — the caller then shows the original.
  Future<Uint8List?> renderBtPage(String comicId, String imageKey) async {
    var project = _projects[comicId];
    // The reader can open a BT comic straight from history before any scan ran.
    project ??= await ensureProject(comicId);
    if (project == null) return null;
    final path = imageKey.startsWith('file://')
        ? imageKey.substring(7)
        : imageKey;
    final prefix = '${project.directory}/';
    if (!path.startsWith(prefix)) return null;
    final pageKey = path.substring(prefix.length);
    final regions = project.regionsFor(pageKey);
    if (regions.isEmpty) return null;
    final inpaintedPath = project.inpaintedPath(pageKey);
    if (inpaintedPath == null) return null;
    final bytes = await File(inpaintedPath).readAsBytes();
    if (bytes.isEmpty) return null;

    final decoded = await _decodeBounded(bytes);
    final scale = decoded.width / decoded.originalWidth;
    final scaled = [
      for (final region in regions)
        TranslatedRegion(
          rect: IntRect(
            (region.rect.left * scale).round(),
            (region.rect.top * scale).round(),
            (region.rect.right * scale).round(),
            (region.rect.bottom * scale).round(),
          ),
          text: region.text,
          backgroundColor: region.backgroundColor,
          textColor: region.textColor,
          lineHeight: region.lineHeight > 0
              ? (region.lineHeight * scale).round()
              : 0,
        ),
    ];
    // The inpainted PNG is already text-free, so render in smart mode: the
    // decoded pixels are used as the base directly without another erase pass.
    return renderTranslatedPage(
      bytes,
      decoded.image,
      scaled,
      mode: InpaintMode.smart,
    );
  }

  /// Rescans the configured root: registers new/updated projects and drops
  /// registrations whose json disappeared. Safe to call repeatedly; concurrent
  /// callers share one in-flight scan.
  Future<void> scan() {
    return _scanFuture ??= _scan().whenComplete(() {
      _scanFuture = null;
    });
  }

  Future<void> _scan() async {
    final seen = <String>{};
    for (final rootDir in roots.map(Directory.new)) {
      if (!await rootDir.exists()) continue;
      final files = <File>[];
      await _collectJsonFiles(rootDir, files, 0);
      for (final file in files) {
        try {
          final id = _comicIdFor(file.path);
          final mtime = (await file.lastModified()).millisecondsSinceEpoch;
          var project = _projects[id];
          if (project == null || _mtimes[id] != mtime) {
            project = await BtProject.load(file);
            // The loader reports a fallback instead of logging it, so that the
            // parsing file stays Flutter-free; surface it here where a logger
            // is already available.
            if (BtProject.lastLoadUsedLegacyParser) {
              Log.warning(
                'BT Project',
                'Translation model rejected ${file.path} '
                    '(${BtProject.lastLoadError}); used the legacy parser.',
              );
            }
          }
          // The parsed project is cached for readers no matter whether the
          // local-comic database is ready yet; DB registration is best effort
          // and healed on the next scan / local-page visit.
          //
          // 🔴 A project with no resolvable image at all is genuinely broken
          // (json + neither original nor inpainted/mask on disk). Skipping it
          // silently is what made a project vanish from the studio with no
          // diagnostic, so say so loudly instead.
          if (coverKeyFor(project) == null) {
            Log.warning(
              'BT Project',
              'Skipped ${file.path}: no cover and no page image found '
                  '(looked in ${project.directory} and ${project.workspace}/'
                  'inpainted|mask).',
            );
            continue;
          }
          _projects[id] = project;
          _mtimes[id] = mtime;
          seen.add(id);
          final manager = LocalManager();
          if (manager.isInitialized) {
            _registerLocal(manager, id, project, mtime);
          }
        } catch (e, s) {
          Log.error('BT Project', 'Failed to load ${file.path}: $e', s);
        }
      }
    }

    // Drop registrations whose json vanished (or root was cleared).
    final staleProjects = _projects.keys
        .where((id) => !seen.contains(id))
        .toList();
    for (final id in staleProjects) {
      _projects.remove(id);
      _mtimes.remove(id);
    }
    final manager = LocalManager();
    if (manager.isInitialized) {
      final staleComics = manager
          .getComics(LocalSortType.defaultSort)
          .where((c) => isBtComic(c.id) && !seen.contains(c.id))
          .toList();
      for (final comic in staleComics) {
        manager.remove(comic.id, comic.comicType);
      }
    }
    if (staleProjects.isNotEmpty || seen.isNotEmpty) {
      notifyListeners();
    }
  }

  Future<void> _collectJsonFiles(
    Directory dir,
    List<File> out,
    int depth,
  ) async {
    if (depth > 6) return;
    try {
      await for (final entity in dir.list(followLinks: false)) {
        final name = _basename(entity.path);
        if (entity is File) {
          if (name.startsWith('imgtrans_') && name.endsWith('.json')) {
            out.add(entity);
          }
        } else if (entity is Directory) {
          if (name.startsWith('.')) continue;
          if (_skippedDirs.contains(name.toLowerCase())) continue;
          await _collectJsonFiles(entity, out, depth + 1);
        }
      }
    } catch (e, s) {
      Log.error('BT Project', 'Failed to list ${dir.path}: $e', s);
    }
  }

  static String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    final slash = normalized.lastIndexOf('/');
    return slash < 0 ? normalized : normalized.substring(slash + 1);
  }

  /// Stable 8-hex-char id derived from the json path so the same project keeps
  /// its comic entry (and history) across rescans.
  static String _comicIdFor(String jsonPath) {
    var hash = 0x811c9dc5;
    for (final unit in jsonPath.toLowerCase().codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return '$idPrefix${hash.toRadixString(16).padLeft(8, '0')}';
  }

  /// Writes/refreshes the [LocalComic] row for [project]. The parsed project
  /// itself is cached by the caller regardless of this outcome; this only keeps
  /// the local-comic database (grid, favorites, state) in sync.
  void _registerLocal(
    LocalManager manager,
    String id,
    BtProject project,
    int mtime,
  ) {
    final coverKey = coverKeyFor(project);
    if (coverKey == null) return;

    final jsonPath = project.jsonFile.path.replaceAll('\\', '/');
    final parent = _basename(_dirname(jsonPath));
    final grandParent = _basename(_dirname(_dirname(jsonPath)));
    final chapterNames = project.chapters.keys.toList();
    final displayTitles = {
      for (final name in chapterNames)
        name: parseChapterTitle(name).displayTitle,
    };

    final comic = LocalComic(
      id: id,
      title: parent.isEmpty ? project.jsonFile.path : parent,
      subtitle: grandParent,
      tags: const ['BT'],
      directory: project.directory,
      chapters: chapterNames.isEmpty ? null : ComicChapters(displayTitles),
      cover: coverKey,
      comicType: ComicType.local,
      downloadedChapters: chapterNames,
      createdAt: DateTime.fromMillisecondsSinceEpoch(mtime),
      description: 'BallonsTranslator 工程',
    );

    final old = manager.find(id, ComicType.local);
    // downloadedChapters in the old row must match exactly (same set, no
    // duplicates); otherwise a rewrite heals rows grown by older rescans.
    final sameDownloadedChapters =
        old != null &&
        old.downloadedChapters.length == chapterNames.length &&
        old.downloadedChapters.toSet().containsAll(chapterNames);
    if (old != null &&
        sameDownloadedChapters &&
        old.title == comic.title &&
        old.directory == comic.directory &&
        old.cover == comic.cover &&
        old.createdAt.millisecondsSinceEpoch == mtime &&
        old.chapters?.length == comic.chapters?.length) {
      return; // unchanged: skip the write and its notifyListeners churn
    }
    manager.add(comic);
  }

  static String _dirname(String normalizedPath) {
    final slash = normalizedPath.lastIndexOf('/');
    return slash < 0 ? '' : normalizedPath.substring(0, slash);
  }
}

/// A resolved BT project cover: its page key relative to the project dir and
/// the loaded file bytes.
class BtCover {
  BtCover(this.key, this.bytes);

  final String key;
  final Uint8List bytes;
}

class _BoundedDecode {
  _BoundedDecode(this.image, this.originalWidth);
  final RgbaImage image;

  /// Width of the undecoded source, needed to scale BT's original-resolution
  /// coordinates down to the working image.
  final int originalWidth;

  int get width => image.width;
}

/// Mirrors the translation pipeline's decode budget (≤12MP, ≤8000px on a side)
/// so a BT page costs the same memory as a pipeline page. BT's xyxy boxes are
/// in the source's full resolution; the caller scales them by
/// `image.width / originalWidth`.
Future<_BoundedDecode> _decodeBounded(Uint8List bytes) async {
  var buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  var descriptor = await ui.ImageDescriptor.encoded(buffer);
  const maxPixels = 12 * 1024 * 1024;
  const maxDimension = 8000;
  var w = descriptor.width;
  var h = descriptor.height;
  var scale = 1.0;
  if (w * h > maxPixels) {
    scale = math.sqrt(maxPixels / (w * h));
  }
  if (math.max(w, h) * scale > maxDimension) {
    scale = maxDimension / math.max(w, h);
  }
  int? targetW;
  int? targetH;
  if (scale < 1.0) {
    targetW = math.max(1, (w * scale).round());
    targetH = math.max(1, (h * scale).round());
  }
  var codec = await descriptor.instantiateCodec(
    targetWidth: targetW,
    targetHeight: targetH,
  );
  var frame = await codec.getNextFrame();
  var image = frame.image;
  try {
    var data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) {
      throw Exception('Failed to read image pixels');
    }
    return _BoundedDecode(
      RgbaImage(image.width, image.height, data.buffer.asUint8List()),
      w,
    );
  } finally {
    image.dispose();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
  }
}

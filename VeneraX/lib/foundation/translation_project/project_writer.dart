import 'dart:async';
import 'dart:io';

import 'project.dart';
import 'project_io.dart';

/// The three artifact folders FT keeps beside a project.
///
/// `mask/` and `inpainted/` are intermediates; `result/` holds the lettered
/// bitmaps. All three use the same naming rule — see
/// [ProjectWriter.artifactPath].
enum ProjectArtifactKind {
  /// Text masks cut out of the source lettering.
  mask('mask'),

  /// Text-erased base images the studio lettering is drawn on.
  inpainted('inpainted'),

  /// Finished lettered bitmaps, for readers that do not re-draw.
  result('result');

  const ProjectArtifactKind(this.directoryName);

  /// Folder name on disk.
  final String directoryName;
}

/// One artifact path belonging to a project.
class ProjectArtifact {
  const ProjectArtifact({
    required this.kind,
    required this.pageKey,
    required this.path,
  });

  final ProjectArtifactKind kind;
  final String pageKey;
  final String path;

  @override
  String toString() => '${kind.directoryName}:$pageKey -> $path';
}

/// Produces the bytes of one artifact, or null when there is nothing to write.
///
/// The studio supplies this for `inpainted`/`mask` (from its pipeline) and for
/// `result` (from its renderer). Keeping it a callback is what lets one writer
/// serve both the old in-place layout and the new `projects/` layout.
typedef ProjectArtifactSource =
    Future<List<int>?> Function(ProjectArtifactKind kind, String pageKey);

/// Outcome of writing a project's JSON, and of ensuring its artifact folders.
class ProjectSaveReport {
  const ProjectSaveReport({
    required this.root,
    required this.jsonFile,
    required this.bytes,
    required this.workspace,
    required this.directory,
    required this.artifactDirectories,
    this.previousRaw,
  });

  /// Root the project was written to.
  final String root;

  /// The JSON file that was written.
  final File jsonFile;

  /// Size of the written JSON.
  final int bytes;

  /// Value the `workspace` key holds after the save.
  final String workspace;

  /// Value the `directory` key holds after the save.
  final String directory;

  /// Artifact folders that exist under [root] afterwards.
  final List<String> artifactDirectories;

  /// The project's `raw` map **as it was before** this save mutated
  /// `directory`/`workspace` on it.
  ///
  /// 🔴 `save()` writes those two keys into the caller's live project object
  /// before serialising, so after a save the in-memory model no longer matches
  /// what the user had before. That is fine for a one-shot save, but it makes
  /// "undo the save" impossible: an undo stack needs the pre-state, and asking
  /// the caller to re-read the file is not enough (the file is already
  /// overwritten). A deep copy taken *before* the mutation is the only cheap
  /// correct source. Unused by current callers — provided for S8.
  final Map<String, Object?>? previousRaw;

  bool get isInPlaceLayout => workspace == directory;

  @override
  String toString() =>
      'saved $bytes B to ${jsonFile.path} (root=$root, '
      'workspace=$workspace, directory=$directory)';
}

/// Outcome of writing artifact bitmaps.
class ProjectArtifactReport {
  const ProjectArtifactReport({
    required this.written,
    required this.skipped,
    required this.failed,
  });

  /// Artifacts actually written.
  final List<ProjectArtifact> written;

  /// Artifacts the source had no bytes for.
  final List<ProjectArtifact> skipped;

  /// Artifacts whose write threw; the message is the failure reason.
  final List<(ProjectArtifact, Object)> failed;

  bool get hasFailures => failed.isNotEmpty;

  @override
  String toString() =>
      'artifacts written=${written.length} skipped=${skipped.length} '
      'failed=${failed.length}';
}

/// The unified save contract.
///
/// FT keeps a project's JSON, `mask/`, `inpainted/` and `result/` under one
/// root. Which root that is — the download folder (FT's in-place layout) or a
/// separate project folder (the studio's layout) — is the **only** difference
/// between the two: same file names, same folder names, same naming rule, same
/// atomic write. So there is one writer here, and [save] takes the root as a
/// parameter rather than deriving it.
///
/// Two roots, one implementation:
///
/// ```text
/// old project  root = ComicLibrary/downloads/<manga>/    workspace == directory
/// new project  root = ComicLibrary/projects/<manga>/     workspace != directory
/// ```
///
/// Layout produced under either root:
///
/// ```text
/// <root>/imgtrans_<name>.json
/// <root>/mask/<page key without extension>.png
/// <root>/inpainted/<page key without extension>.png
/// <root>/result/<page key without extension>.png
/// ```
///
/// The page key keeps its chapter folder (`0/1.webp` -> `inpainted/0/1.png`),
/// matching both sample projects on disk and FT's own
/// `osp.splitext(imgname)` rule.
class ProjectWriter {
  const ProjectWriter._();

  /// Artifact kinds the studio keeps in step with edits.
  static const Set<ProjectArtifactKind> allArtifactKinds = {
    ProjectArtifactKind.mask,
    ProjectArtifactKind.inpainted,
    ProjectArtifactKind.result,
  };

  /// Strips trailing separators and normalises to forward slashes.
  static String normaliseRoot(String root) =>
      root.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');

  /// Absolute path of one artifact under [root].
  ///
  /// `inpainted/0/1.png` for page key `0/1.webp`: the extension is replaced
  /// with `.png` because FT saves every intermediate as PNG
  /// (`pcfg.intermediate_imgsave_ext`), and `result/` follows the source
  /// extension only when the user picked something other than PNG.
  static String artifactPath(
    String root,
    ProjectArtifactKind kind,
    String pageKey,
  ) {
    return '${artifactDirectory(root, kind)}/'
        '${TranslationProject.pageStem(pageKey)}.png';
  }

  /// Absolute path of the folder holding one artifact kind under [root].
  static String artifactDirectory(String root, ProjectArtifactKind kind) {
    return '${normaliseRoot(root)}/${kind.directoryName}';
  }

  /// Absolute path of the project JSON under [root].
  static String jsonPath(String root, String jsonFileName) {
    return '${normaliseRoot(root)}/$jsonFileName';
  }

  /// Every artifact path a project is expected to own under [root].
  ///
  /// Restricted to pages whose source image exists, matching what the reader
  /// will actually ask for. Pass [includePhantomPages] to list the entries FT
  /// keeps for pages that are gone from disk.
  static List<ProjectArtifact> planArtifacts(
    String root,
    TranslationProject project, {
    Set<ProjectArtifactKind> kinds = allArtifactKinds,
    bool includePhantomPages = false,
    bool Function(String pageKey)? filter,
  }) {
    final result = <ProjectArtifact>[];
    for (final pageKey in project.pages.keys) {
      if (filter != null && !filter(pageKey)) continue;
      if (!includePhantomPages && !project.hasDisplayImage(pageKey)) {
        // 🔴 Was `File(originalPath).existsSync()`, which planned **zero**
        // artifacts for a project whose raw comic folder was gone — the save
        // then silently did nothing. Artifacts under `workspace` are a
        // legitimate page source, so ask the project, not the raw path.
        continue;
      }
      for (final kind in kinds) {
        result.add(
          ProjectArtifact(
            kind: kind,
            pageKey: pageKey,
            path: artifactPath(root, kind, pageKey),
          ),
        );
      }
    }
    return result;
  }

  /// Saves [project]'s JSON under [root] and makes sure its artifact folders
  /// exist.
  ///
  /// [workspace] and [directory] are written into the JSON **only when
  /// supplied**. Leaving them null is what makes a plain save a no-op for an
  /// FT project: FT does not write a `workspace` key at all, so inventing one
  /// would show up as a diff on a file nobody edited. Pass [workspace] to adopt
  /// the project into the studio layout.
  static Future<ProjectSaveReport> save({
    required String root,
    required TranslationProject project,
    String? jsonFileName,
    String? workspace,
    String? directory,
    bool ensureArtifactDirectories = true,
    // 🔴 Default ON. This is the writer that edits a user's FT project in
    // place, and S8 makes it a routine "save" — with backups off, a bad edit
    // (or a crash mid-write) is unrecoverable. Callers that genuinely don't
    // want a `.bak` pass `keepBackup: false` explicitly.
    bool keepBackup = true,
  }) async {
    // Snapshot before the mutation below — see [ProjectSaveReport.previousRaw].
    // `copy()` is the project's own deep-copy entry point (it rebuilds through
    // `buildFrom`, so nested lists/maps are duplicated, not shared).
    final previousRaw =
        (directory != null || workspace != null) ? project.copy().raw : null;
    if (directory != null) project.setDirectory(directory);
    if (workspace != null) {
      project.setWorkspace(workspace);
    }
    // The JSON references the project by absolute path, so it must be written
    // where it claims to live for FT to find it again.
    final target = File(jsonPath(root, jsonFileName ?? project.jsonFileName));
    final bytes = await TranslationProjectIo.writeAtomically(
      target,
      project,
      keepBackup: keepBackup,
    );

    final directories = <String>[];
    if (ensureArtifactDirectories) {
      for (final kind in allArtifactKinds) {
        final dir = Directory(artifactDirectory(root, kind));
        if (!dir.existsSync()) {
          await dir.create(recursive: true);
        }
        directories.add(dir.path);
      }
    }

    return ProjectSaveReport(
      root: root,
      jsonFile: target,
      bytes: bytes,
      workspace: project.workspace,
      directory: project.directory,
      artifactDirectories: directories,
      previousRaw: previousRaw,
    );
  }

  /// Adopts [project] into the studio layout: artifacts under [root], sources
  /// where they already are.
  ///
  /// This is the whole of the "A plan" — FT already models it through its
  /// `workspace` field, so nothing about the file format changes.
  static Future<ProjectSaveReport> adopt({
    required String root,
    required TranslationProject project,
    String? sourceDirectory,
    String? jsonFileName,
    bool ensureArtifactDirectories = true,
  }) {
    return save(
      root: root,
      project: project,
      jsonFileName: jsonFileName,
      workspace: root,
      directory: sourceDirectory ?? project.directory,
      ensureArtifactDirectories: ensureArtifactDirectories,
    );
  }

  /// Writes artifact bitmaps for [project] under [root].
  ///
  /// [source] produces the bytes; a null result marks the artifact as skipped
  /// rather than failed, because "the pipeline has not produced this page yet"
  /// is a normal state, not an error.
  ///
  /// [concurrency] is deliberately settable: `result/` rendering is expensive,
  /// so the save flow runs it in the background at low parallelism while the
  /// editor stays responsive.
  ///
  /// [shouldCancel] is polled between artifacts; returning true stops the run
  /// without marking the remaining work as failed.
  static Future<ProjectArtifactReport> writeArtifacts({
    required String root,
    required TranslationProject project,
    required ProjectArtifactSource source,
    Set<ProjectArtifactKind> kinds = allArtifactKinds,
    bool includePhantomPages = false,
    bool Function(String pageKey)? filter,
    int concurrency = 1,
    void Function(int done, int total)? onProgress,
    bool Function()? shouldCancel,
  }) async {
    final plan = planArtifacts(
      root,
      project,
      kinds: kinds,
      includePhantomPages: includePhantomPages,
      filter: filter,
    );

    final written = <ProjectArtifact>[];
    final skipped = <ProjectArtifact>[];
    final failed = <(ProjectArtifact, Object)>[];

    var done = 0;
    var index = 0;
    final lanes = concurrency < 1 ? 1 : concurrency;

    Future<void> worker() async {
      while (true) {
        if (shouldCancel?.call() ?? false) return;
        final current = index++;
        if (current >= plan.length) return;
        final artifact = plan[current];
        try {
          final bytes = await source(artifact.kind, artifact.pageKey);
          if (bytes == null) {
            skipped.add(artifact);
          } else {
            // 🔴 Atomic: a bare `writeAsBytes` here could leave a truncated PNG,
            // and every downstream existence check (`existsSync` in the export
            // plan, the reader's "prefer the finished bitmap") would report
            // that half-image as a finished page and ship it.
            await TranslationProjectIo.writeBytesAtomically(
              File(artifact.path),
              bytes,
            );
            written.add(artifact);
          }
        } catch (error) {
          failed.add((artifact, error));
        }
        done++;
        onProgress?.call(done, plan.length);
      }
    }

    await Future.wait([for (var i = 0; i < lanes; i++) worker()]);

    return ProjectArtifactReport(
      written: written,
      skipped: skipped,
      failed: failed,
    );
  }

  /// Copies artifacts from the project's current workspace into [root].
  ///
  /// Used when adopting an FT project that already has `inpainted/`: the bytes
  /// are merely relocated, so there is no reason to re-render them.
  static Future<ProjectArtifactReport> copyArtifacts({
    required String root,
    required TranslationProject project,
    Set<ProjectArtifactKind> kinds = allArtifactKinds,
    bool includePhantomPages = true,
    int concurrency = 2,
  }) {
    final sourceRoot = project.workspace;
    return writeArtifacts(
      root: root,
      project: project,
      kinds: kinds,
      includePhantomPages: includePhantomPages,
      concurrency: concurrency,
      source: (kind, pageKey) async {
        final from = File(artifactPath(sourceRoot, kind, pageKey));
        if (!from.existsSync()) return null;
        return from.readAsBytes();
      },
    );
  }

  /// Deletes every artifact belonging to [pageKey] under [root].
  ///
  /// Returns the paths that were removed, so a caller can report what a page
  /// deletion actually cleaned up.
  static Future<List<String>> deletePageArtifacts(
    String root,
    String pageKey, {
    Set<ProjectArtifactKind> kinds = allArtifactKinds,
  }) async {
    final removed = <String>[];
    for (final kind in kinds) {
      final file = File(artifactPath(root, kind, pageKey));
      if (file.existsSync()) {
        await file.delete();
        removed.add(file.path);
      }
    }
    return removed;
  }
}

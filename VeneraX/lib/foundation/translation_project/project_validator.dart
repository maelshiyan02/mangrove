import 'dart:convert';
import 'dart:io';

import '../bt_project/bt_project.dart';
import '../image_translation/translation_types.dart';
import 'json_codec.dart';
import 'project.dart';
import 'project_io.dart';
import 'project_writer.dart';
import 'text_block.dart';

/// One named verification step.
class ProjectCheck {
  const ProjectCheck(this.name, this.passed, this.detail);

  final String name;
  final bool passed;
  final String detail;

  @override
  String toString() => '${passed ? 'PASS' : 'FAIL'} $name — $detail';
}

/// Result of validating one project file.
class ProjectValidationReport {
  ProjectValidationReport(this.jsonFile, this.checks);

  final String jsonFile;
  final List<ProjectCheck> checks;

  bool get passed => checks.every((check) => check.passed);

  int get passedCount => checks.where((check) => check.passed).length;

  /// Print-ready summary, one line per check.
  String toText() {
    final buffer = StringBuffer()
      ..writeln('project: $jsonFile')
      ..writeln(
        'result : ${passed ? 'PASS' : 'FAIL'} '
        '($passedCount/${checks.length})',
      );
    for (final check in checks) {
      buffer.writeln('  $check');
    }
    return buffer.toString();
  }

  Map<String, Object?> toJson() => {
    'project': jsonFile,
    'passed': passed,
    'passedCount': passedCount,
    'total': checks.length,
    'checks': [
      for (final check in checks)
        {'name': check.name, 'passed': check.passed, 'detail': check.detail},
    ],
  };
}

/// Checks that a real FT project survives a read/write cycle unchanged, and
/// that the reader sees the same thing through both parsers.
///
/// This exists because the studio edits files that have to stay openable by
/// FT. A bug here does not crash anything — it silently rewrites a user's
/// project — so the properties are asserted rather than assumed:
///
/// * the project re-encodes to the **same bytes** it was read from,
/// * phantom page keys and unknown fields survive,
/// * the unified save contract lays out both roots identically,
/// * the reader's view through the model equals its view through the legacy
///   parser.
///
/// It is written as a normal library (not a test) so the same code can run
/// under `dart run tool/s6_project_roundtrip.dart` and from the app's
/// `--headless project-check` command. The latter is what proves the model is
/// really compiled into the shipped binary.
class ProjectValidator {
  const ProjectValidator._();

  /// Formatting rules captured from a real run of
  /// `json.dumps(v, ensure_ascii=False)`.
  ///
  /// Hard-coded on purpose: these are the exact strings FT writes, produced by
  /// CPython, so the codec is checked against Python rather than against
  /// itself. The exponent forms are the ones Dart and Python disagree on
  /// (`1e+16` vs `10000000000000000.0`, `1e-07` vs `1e-7`).
  static const Map<String, num> pythonNumberCases = {
    '20.0': 20.0,
    '0.0': 0.0,
    '-0.0': -0.0,
    '1.15': 1.15,
    '166.02710622064097': 166.02710622064097,
    '1000000000000000.0': 1e15,
    '1e+16': 1e16,
    '1e+20': 1e20,
    '1e+21': 1e21,
    '1e-05': 1e-5,
    '1e-07': 1e-7,
    '0.0001': 0.0001,
    '1.5e+300': 1.5e300,
    '5e-324': 5e-324,
    '100.0': 100.0,
    '690': 690,
    '-42': -42,
  };

  /// Whole-value cases: containers, key order and non-ASCII.
  static const Map<String, Object?> pythonValueCases = {
    '[1, 2.0, "x", true, null]': [1, 2.0, 'x', true, null],
    '{"a": 20.0, "b": 0.0}': {'a': 20.0, 'b': 0.0},
    '{"z": 1, "a": 1, "m": 1}': {'z': 1, 'a': 1, 'm': 1},
    '"简体中文"': '简体中文',
    '"a\\"b"': 'a"b',
    '"a\\nb"': 'a\nb',
    '"a\\\\b"': r'a\b',
  };

  /// Checks the serializer against CPython's output.
  static List<ProjectCheck> checkCodec() {
    final checks = <ProjectCheck>[];
    final numberMismatches = <String>[];
    pythonNumberCases.forEach((expected, value) {
      final actual = PyJson.encodeNumber(value);
      if (actual != expected) {
        numberMismatches.add('$value -> "$actual" != "$expected"');
      }
    });
    checks.add(
      ProjectCheck(
        'codec.numbers',
        numberMismatches.isEmpty,
        numberMismatches.isEmpty
            ? '${pythonNumberCases.length} cases match json.dumps'
            : numberMismatches.take(3).join(' | '),
      ),
    );

    final valueMismatches = <String>[];
    pythonValueCases.forEach((expected, value) {
      final actual = PyJson.encode(value);
      if (actual != expected) {
        valueMismatches.add('$value -> "$actual" != "$expected"');
      }
    });
    checks.add(
      ProjectCheck(
        'codec.values',
        valueMismatches.isEmpty,
        valueMismatches.isEmpty
            ? '${pythonValueCases.length} cases match json.dumps'
            : valueMismatches.take(3).join(' | '),
      ),
    );
    return checks;
  }

  /// Validates [jsonFile].
  ///
  /// [originalBytes] lets a caller supply the file's contents when they were
  /// already read (the headless command does this); otherwise the file is read
  /// here. [scratch] is where the writer checks land — a temporary folder by
  /// default, and it is always cleaned up.
  static Future<ProjectValidationReport> validate({
    required File jsonFile,
    List<int>? originalBytes,
    Directory? scratch,
  }) async {
    final checks = <ProjectCheck>[];

    if (!jsonFile.existsSync()) {
      return ProjectValidationReport(jsonFile.path, [
        ProjectCheck('exists', false, 'file not found'),
      ]);
    }

    final bytes = originalBytes ?? await jsonFile.readAsBytes();
    final text = utf8.decode(bytes);
    final project = TranslationProjectIo.parse(text, jsonFile);

    final pageCount = project.pages.length;
    var blockCount = 0;
    var translatedCount = 0;
    for (final page in project.pages.values) {
      for (final block in page.blocks) {
        blockCount++;
        if (block.hasTranslation) translatedCount++;
      }
    }
    checks.add(
      ProjectCheck(
        'parse',
        pageCount > 0,
        '$pageCount pages, $blockCount blocks, $translatedCount translated',
      ),
    );

    // --- 1. Byte-level round trip -----------------------------------------
    final encoded = TranslationProjectIo.encode(project);
    final encodedBytes = utf8.encode(encoded);
    final diff = _firstDifference(bytes, encodedBytes);
    checks.add(
      ProjectCheck(
        'roundtrip',
        diff == null,
        diff == null
            ? 'identical (${bytes.length} B)'
            : 'differs at byte ${diff.$1}: '
                  '${diff.$2} vs ${diff.$3} '
                  '(len ${bytes.length} vs ${encodedBytes.length})',
      ),
    );

    // --- 2. Phantom page keys survive --------------------------------------
    final phantomKeys = [
      for (final key in project.pages.keys)
        if (!File(project.originalPath(key)).existsSync()) key,
    ];
    checks.add(
      ProjectCheck(
        'phantom-keys',
        phantomKeys.isEmpty || encoded.contains('"${phantomKeys.first}"'),
        phantomKeys.isEmpty
            ? 'none present'
            : '${phantomKeys.length} keys with no file on disk, all preserved',
      ),
    );

    // --- 3. Unknown fields pass through ------------------------------------
    checks.add(_checkUnknownPassthrough(project));

    // --- 4. FontFormat completeness ----------------------------------------
    checks.add(_checkFontFormat(project));

    // --- 5. Unified save contract: both roots ------------------------------
    final work = scratch ?? Directory.systemTemp.createTempSync('vene_valid_');
    final createdScratch = scratch == null;
    try {
      checks.addAll(await _checkSaveContract(work, project, bytes));
      // --- 5b. Studio assembly rule (artifact root = JSON's own folder) ----
      checks.add(_checkAssemblyRule(work, project));
    } finally {
      if (createdScratch && work.existsSync()) {
        work.deleteSync(recursive: true);
      }
    }

    // --- 6. Reader equivalence ---------------------------------------------
    checks.add(await _checkReaderEquivalence(jsonFile, bytes, project));

    return ProjectValidationReport(jsonFile.path, checks);
  }

  /// Adds keys nobody models and asserts they survive the write.
  static ProjectCheck _checkUnknownPassthrough(TranslationProject project) {
    final probe = project.copy();
    final raw = probe.raw;
    raw['_venera_probe'] = {
      'nested': [1, 2.5, '中文'],
      'flag': true,
    };

    final firstPage = probe.pages.values.isEmpty
        ? null
        : probe.pages.values.first;
    if (firstPage != null) {
      firstPage.rawBlocks.add(<String, Object?>{'_venera_phantom_block': true});
      final pageBlocks = firstPage.blocks;
      if (pageBlocks.isNotEmpty) {
        pageBlocks.first.raw['_venera_unknown_block_key'] = 'keep me';
        pageBlocks.first.ensureFontFormat().raw['_venera_unknown_ff_key'] = 42;
      }
    }

    final text = TranslationProjectIo.encode(probe);
    final decoded = PyJson.decode(text);
    final decodedMap = asObjectMap(decoded)!;

    final topKept = decodedMap.containsKey('_venera_probe');
    final blockKept = text.contains('_venera_unknown_block_key');
    final formatKept = text.contains('_venera_unknown_ff_key');
    final phantomKept = text.contains('_venera_phantom_block');
    final survived = topKept && blockKept && formatKept && phantomKept;

    // Round-tripping the *probe* must also be stable, i.e. re-reading it and
    // writing again is a no-op — an unknown key must not be reordered away.
    final again = TranslationProjectIo.encode(
      TranslationProjectIo.parse(text, project.jsonFile),
    );

    return ProjectCheck(
      'unknown-fields',
      survived && again == text,
      'top=$topKept block=$blockKept fontformat=$formatKept '
          'block-entry=$phantomKept stable=${again == text}',
    );
  }

  /// Asserts every FontFormat FT wrote is still readable through the model.
  static ProjectCheck _checkFontFormat(TranslationProject project) {
    var formats = 0;
    var keyCount = 0;
    final samples = <String>[];
    for (final page in project.pages.values) {
      for (final block in page.blocks) {
        final format = block.fontFormat;
        if (format == null) continue;
        formats++;
        keyCount += format.raw.length;
        if (samples.isEmpty) {
          samples.add(
            'family=${format.fontFamily} size=${format.fontSize} '
            'align=${format.alignment} vertical=${format.vertical} '
            'weight=${format.fontWeight} fg=${format.foregroundColor} '
            'stroke=${format.strokeWidth}',
          );
        }
      }
    }
    return ProjectCheck(
      'fontformat',
      formats > 0,
      '$formats blocks, avg ${formats == 0 ? 0 : (keyCount / formats).toStringAsFixed(1)} keys'
          '${samples.isEmpty ? '' : ' | ${samples.first}'}',
    );
  }

  /// The studio "assembly" rule (P6 §2.11(a)): with no `workspace` key — which
  /// is every real FT project, because FT never writes one — the artifact root
  /// is the JSON's own folder. For an in-place project that equals `directory`;
  /// for a studio project under `projects/` it points at the real artifacts.
  ///
  /// [work] is a scratch directory; both roots are created for real because the
  /// getters only accept folders that exist on disk.
  static ProjectCheck _checkAssemblyRule(
    Directory work,
    TranslationProject project,
  ) {
    final jsonDir = project.jsonDirectory;
    final fileName = project.jsonFileName;
    final slashes = (String p) => p.replaceAll('\\', '/');

    // (1) As stored: FT writes no `workspace` key, so the artifact root must be
    // the JSON's own folder — which for this sample coincides with `directory`.
    final stored = TranslationProject.buildFrom(
      Map<String, Object?>.from(project.raw),
      File('$jsonDir/$fileName'),
    );
    final assemblyOk = stored.workspace == jsonDir;

    // (2) Split layout: JSON under projects/<manga>/, sources elsewhere.
    final splitJson = Directory(
      '${work.path}/assembly/projects/manga',
    )..createSync(recursive: true);
    final splitSourceDir = Directory(
      '${work.path}/assembly/downloads/manga',
    )..createSync(recursive: true);
    final splitJsonDir = slashes(splitJson.path);
    final splitSources = slashes(splitSourceDir.path);
    final splitRaw = Map<String, Object?>.from(project.raw)
      ..['directory'] = splitSources;
    splitRaw.remove('workspace');
    final split = TranslationProject.buildFrom(
      splitRaw,
      File('$splitJsonDir/$fileName'),
    );
    final splitResolves = split.workspace == splitJsonDir;
    final splitIsSeparate = !split.isInPlaceLayout && split.directory == splitSources;

    // (3) An explicit `workspace` still wins over the folder fallback.
    final explicit = split.copy()..setWorkspace(splitSources);
    final explicitOk = explicit.workspace == splitSources;

    return ProjectCheck(
      'assembly.workspace',
      assemblyOk && splitResolves && splitIsSeparate && explicitOk,
      'stored=${assemblyOk ? 'jsonDir' : stored.workspace} '
          'split=${splitResolves && splitIsSeparate ? 'jsonDir' : split.workspace} '
          'explicit=${explicitOk ? 'honoured' : explicit.workspace}',
    );
  }

  /// Saves the project under both layouts and compares the outcomes.
  static Future<List<ProjectCheck>> _checkSaveContract(
    Directory work,
    TranslationProject project,
    List<int> originalBytes,
  ) async {
    final checks = <ProjectCheck>[];

    // Old layout: in-place, root == directory, no workspace key written.
    //
    // "In place" is a property of the *loaded* project, not of the sample we
    // happen to have: a studio project under ComicLibrary/projects/ is split by
    // definition, and the writer must not silently turn it into an in-place one
    // (nor invent a `workspace` key). The invariant is therefore "the layout is
    // preserved", not "the result is in-place".
    final expectInPlace = project.directory == project.jsonDirectory;
    final oldRoot = Directory('${work.path}/downloads/manga')
      ..createSync(recursive: true);
    final oldReport = await ProjectWriter.save(
      root: oldRoot.path,
      project: project.copy(),
      jsonFileName: project.jsonFileName,
    );
    final oldBytes = await oldReport.jsonFile.readAsBytes();
    checks.add(
      ProjectCheck(
        'save.in-place',
        _firstDifference(originalBytes, oldBytes) == null &&
            oldReport.isInPlaceLayout == expectInPlace,
        'json identical=${_firstDifference(originalBytes, oldBytes) == null}, '
            'workspace==directory=${oldReport.isInPlaceLayout} '
            '(expected=$expectInPlace), dirs=${oldReport.artifactDirectories.length}',
      ),
    );

    // New layout: workspace points at projects/<manga>, directory unchanged.
    final newRoot = '${work.path}/projects/manga';
    final adopted = project.copy();
    final newReport = await ProjectWriter.adopt(
      root: newRoot,
      project: adopted,
    );
    final newText = await newReport.jsonFile.readAsString();
    final newRaw = asObjectMap(PyJson.decode(newText))!;
    checks.add(
      ProjectCheck(
        'save.studio-layout',
        newRaw['workspace'] == ProjectWriter.normaliseRoot(newRoot) &&
            newRaw['directory'] == project.directory,
        'workspace=${newRaw['workspace']} directory=${newRaw['directory']}',
      ),
    );

    // Artifact naming rule, validated against both page-key shapes in the
    // sample: `0/1.webp` (with a chapter folder) and `1.webp` (flat).
    final expectedNested =
        '${ProjectWriter.normaliseRoot(newRoot)}/inpainted/0/1.png';
    final expectedFlat =
        '${ProjectWriter.normaliseRoot(newRoot)}/inpainted/1.png';
    final namingOk =
        ProjectWriter.artifactPath(
              newRoot,
              ProjectArtifactKind.inpainted,
              '0/1.webp',
            ) ==
            expectedNested &&
        ProjectWriter.artifactPath(
              newRoot,
              ProjectArtifactKind.inpainted,
              '1.webp',
            ) ==
            expectedFlat;
    checks.add(
      ProjectCheck(
        'artifact-paths',
        namingOk,
        namingOk
            ? '0/1.webp -> inpainted/0/1.png ; 1.webp -> inpainted/1.png'
            : 'mismatch',
      ),
    );

    // The writer must agree with the reader about where artifacts live.
    //
    // `includePhantomPages: true` for the same reason as below: right after
    // `adopt()` the copy's workspace is the *new* (still empty) root, so the
    // default "page image exists" filter plans nothing.
    final plan = ProjectWriter.planArtifacts(
      newRoot,
      adopted,
      includePhantomPages: true,
    );
    final missingDirs = <String>[];
    for (final kind in ProjectWriter.allArtifactKinds) {
      final dir = Directory(ProjectWriter.artifactDirectory(newRoot, kind));
      if (!dir.existsSync()) missingDirs.add(kind.directoryName);
    }
    checks.add(
      ProjectCheck(
        'artifact-dirs',
        missingDirs.isEmpty && plan.isNotEmpty,
        'planned=${plan.length} missing=${missingDirs.isEmpty ? 'none' : missingDirs.join(',')}',
      ),
    );

    // Writing artifacts through the callback API lands where planned.
    //
    // 🔴 Order matters: `adopt()` only relocates the *json*; the artifacts are
    // moved by `copyArtifacts` afterwards. So the plan must be built with
    // `includePhantomPages: true` — the same way `copyArtifacts` does it.
    // Relying on the default (which filters by "page image exists on disk")
    // planned **zero** artifacts for any project whose raw comic folder is
    // gone, and this check then failed for a project that is perfectly fine.
    final artifactReport = await ProjectWriter.writeArtifacts(
      root: newRoot,
      project: adopted,
      kinds: {ProjectArtifactKind.result},
      includePhantomPages: true,
      source: (kind, pageKey) async => [1, 2, 3],
    );
    checks.add(
      ProjectCheck(
        'artifact-write',
        artifactReport.failed.isEmpty &&
            artifactReport.written.isNotEmpty &&
            artifactReport.written.every((a) => File(a.path).existsSync()),
        '${artifactReport.written.length} written, '
            '${artifactReport.skipped.length} skipped, '
            '${artifactReport.failed.length} failed',
      ),
    );

    return checks;
  }

  /// Asserts the model and the legacy parser produce the same reader view.
  static Future<ProjectCheck> _checkReaderEquivalence(
    File jsonFile,
    List<int> bytes,
    TranslationProject project,
  ) async {
    final decoded = PyJson.decode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic>) {
      return const ProjectCheck(
        'reader-equivalence',
        false,
        'top level not an object',
      );
    }
    final legacy = BtProject.parse(decoded, jsonFile);
    final modelled = BtProject.fromTranslationProject(project, jsonFile);

    final problems = <String>[];
    if (legacy.directory != modelled.directory) {
      problems.add('directory');
    }
    if (legacy.workspace != modelled.workspace) {
      problems.add('workspace');
    }
    if (!_sameList(legacy.pageOrder, modelled.pageOrder)) {
      problems.add('pageOrder');
    }
    if (legacy.chapters.keys.join('|') != modelled.chapters.keys.join('|')) {
      problems.add('chapterNames');
    }
    for (final key in legacy.chapters.keys) {
      if (!_sameList(
        legacy.chapters[key]!,
        modelled.chapters[key] ?? const [],
      )) {
        problems.add('chapter:$key');
        break;
      }
    }

    var comparedPages = 0;
    var comparedRegions = 0;
    for (final key in legacy.pageOrder) {
      final a = legacy.regionsFor(key);
      final b = modelled.regionsFor(key);
      comparedPages++;
      if (a.length != b.length) {
        problems.add('regions:$key(${a.length} vs ${b.length})');
        break;
      }
      for (var i = 0; i < a.length; i++) {
        if (!_sameRegion(a[i], b[i])) {
          problems.add('region:$key[$i]');
          break;
        }
        comparedRegions++;
      }
      if (problems.isNotEmpty) break;
    }

    // Every page key the reader can ask for must resolve identically too.
    // Hoisted: `pageKeysForChapter` stats the disk on every call.
    final legacyChapterPages = legacy.pageKeysForChapter(1);
    final modelledChapterPages = modelled.pageKeysForChapter(1);
    if (!_sameList(legacyChapterPages, modelledChapterPages)) {
      problems.add(
        'chapterPages(${legacyChapterPages.length} vs ${modelledChapterPages.length})',
      );
    }

    return ProjectCheck(
      'reader-equivalence',
      problems.isEmpty,
      problems.isEmpty
          ? '$comparedPages pages / $comparedRegions regions identical '
                'through both parsers'
          : 'mismatch: ${problems.take(3).join(', ')}',
    );
  }

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _sameRegion(TranslatedRegion a, TranslatedRegion b) {
    return a.text == b.text &&
        a.textColor == b.textColor &&
        a.backgroundColor == b.backgroundColor &&
        a.lineHeight == b.lineHeight &&
        a.rect.left == b.rect.left &&
        a.rect.top == b.rect.top &&
        a.rect.right == b.rect.right &&
        a.rect.bottom == b.rect.bottom;
  }

  /// Index of the first differing byte plus a short readable context, or null
  /// when the two are equal.
  static (int, String, String)? _firstDifference(List<int> a, List<int> b) {
    final max = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < max; i++) {
      if (a[i] != b[i]) {
        return (i, _context(a, i), _context(b, i));
      }
    }
    if (a.length != b.length) {
      final longer = a.length > b.length ? a : b;
      return (max, _context(longer, max), '<end>');
    }
    return null;
  }

  static String _context(List<int> bytes, int index) {
    final start = index - 20 < 0 ? 0 : index - 20;
    final end = index + 20 > bytes.length ? bytes.length : index + 20;
    return utf8.decode(bytes.sublist(start, end), allowMalformed: true);
  }
}

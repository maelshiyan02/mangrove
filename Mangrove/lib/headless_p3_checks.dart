// P6 §4.10.2 表 #3 · 「从下载创建工程」的断言集。
//
// 🔴 为什么单独一个文件：这批断言要造磁盘夹具、要写工程、还要做故障注入，
// 塞进 `headless.dart`（已 2500 行）就等于宣告"以后不再加断言"。
//
// ## 反向验证的方式与 P1/P2 不同，但更硬
//
// P1/P2 是**改源码注入故障 → 重新构建 → 看断言红不红**，一条断言一次构建，
// 代价高到会让人跳过（A08 §4 里那 11 条 pending 就是这么来的）。
//
// 这一批的被测对象是「一份工程 JSON + 一次计划」，不是源码里的某一行，所以
// 故障可以在**运行时**注入：同一个判据 `P` 跑两次 ——
//
// * `green()`：喂正确输入，`P` 必须为 **true**；
// * `red()`：喂故意做错的输入，`P` 必须为 **false**。
//
// 一条断言通过的条件是 `green() == true && red() == false`。**`red()` 还是绿的
// 那条断言就是装饰品**，会当场判 FAIL 并在 detail 里写明。这样一次构建就能
// 把全部断言反向验证完，不必为每条断言重建一次。
library;

import 'dart:io';

import 'package:mangrove/foundation/translation_project/project.dart';
import 'package:mangrove/foundation/translation_project/project_bootstrap.dart';
import 'package:mangrove/foundation/translation_project/project_io.dart';
import 'package:mangrove/headless_p1_checks.dart' show CheckSink;

/// FT 写工程 JSON 的顶层键序。建出来的工程必须长这个样子，否则「存一次」
/// 就会在 FT 那边产生 diff。
const List<String> ftTopLevelKeyOrder = [
  'directory',
  'pages',
  'current_img',
  'image_info',
  'page_order',
  'chapters',
];

/// 夹具预期的页序：数字页按**数值**排，所以 `10.webp` 在 `9.webp` 之后。
const List<String> expectedPageOrder = [
  'ch1/1.webp',
  'ch1/2.webp',
  'ch1/3.png',
  'ch1/4.jpg',
  'ch1/5.gif',
  'ch1/9.webp',
  'ch1/10.webp',
];

/// 夹具里**量得出**的页（`9.webp` 的头是坏的，不在其中）。
const Map<String, List<int>> expectedSizes = {
  'ch1/1.webp': [800, 1200],
  'ch1/2.webp': [801, 1201],
  'ch1/3.png': [803, 1203],
  'ch1/4.jpg': [804, 1204],
  'ch1/5.gif': [805, 1205],
  'ch1/10.webp': [802, 1202],
};

/// 一条断言：绿路径 + 故障路径 + 可诊断的 detail。
class _Probe {
  const _Probe(this.name, this.green, this.red, this.detail);

  final String name;

  /// 正确输入下必须为 true。
  final Future<bool> Function() green;

  /// 注入故障后必须为 false —— 仍为 true 说明这条断言是装饰品。
  final Future<bool> Function() red;

  final String Function() detail;
}

/// 跑完「从下载创建工程」的全部断言。
///
/// [tempRoot] 由调用方提供（headless 的临时目录）；本函数负责在其中建夹具
/// 并在结束时清理。
Future<void> runP3Checks(CheckSink check, {required Directory tempRoot}) async {
  final base = '${tempRoot.path}/bootstrap_p3_$pid';
  await Directory(base).create(recursive: true);
  try {
    await _run(check, base);
  } finally {
    try {
      await Directory(base).delete(recursive: true);
    } catch (_) {}
  }
}

Future<void> _run(CheckSink check, String baseInput) async {
  // 🔴 `Directory.systemTemp.createTemp()` 给的是 **反斜杠** 路径（还带 8.3
  // 短名 `ADMINI~1`）。直接拼进 `comicDir` 会得到混合分隔符，而产品侧
  // 一律归一成正斜杠 —— 于是"raw['directory'] 是否等于 comicDir"这种比较
  // 会因为夹具自己的分隔符风格而假红。夹具也按同一条规则归一。
  final base = ProjectBootstrap.normalizeDirectoryPath(baseInput);
  final downloads = '$base/downloads';
  final comicDir = '$downloads/FixtureComic';
  const chapter = 'ch1';
  final projects = '$base/projects';

  // ── 造一本「已下载的漫画」 ──
  // 🔴 只写文件头、不写可解码的像素：本会话没有渲染表面（A01 §3），而尺寸
  // 解析本来就只需要头。断言测的是「头解析 + 计划 + 落盘」，不是解码。
  await _write('$comicDir/cover.webp', _webpVp8x(100, 150));
  await _write('$comicDir/$chapter/1.webp', _webpVp8x(800, 1200));
  await _write('$comicDir/$chapter/2.webp', _webpVp8l(801, 1201));
  await _write('$comicDir/$chapter/3.png', _png(803, 1203));
  await _write('$comicDir/$chapter/4.jpg', _jpeg(804, 1204));
  await _write('$comicDir/$chapter/5.gif', _gif(805, 1205));
  await _write('$comicDir/$chapter/9.webp', _webpUnknownCodec());
  await _write('$comicDir/$chapter/10.webp', _webpVp8(802, 1202));
  await _write('$comicDir/$chapter/notes.txt', [0x6E, 0x6F, 0x74, 0x65]);
  final inventoryBefore = _inventory(downloads);

  final plan = ProjectBootstrap.plan(
    comicDirectory: comicDir,
    chapterName: chapter,
  );
  final raw = ProjectBootstrap.buildRaw(plan);

  final created = await ProjectBootstrap.create(
    projectsRoot: projects,
    name: 'P3Fixture',
    plan: plan,
  );

  // 落盘后重新读回来 —— 除「计划」类断言外，其余都以磁盘上的真相为准，
  // 而不是以内存里的对象为准（内存对、磁盘错是最难发现的一类失败）。
  TranslationProject? reloaded;
  String reloadError = '';
  if (created.created) {
    try {
      reloaded = await TranslationProjectIo.load(created.jsonFile);
    } catch (e) {
      reloadError = e.toString();
    }
  }

  final probes = <_Probe>[];
  void probe(
    String name,
    Future<bool> Function() green,
    Future<bool> Function() red,
    String Function() detail,
  ) {
    probes.add(_Probe(name, green, red, detail));
  }

  // ── 1 · 计划类 ────────────────────────────────────────────────────────
  probe(
    'plan_non_empty',
    () async => plan.pageKeys.length == expectedPageOrder.length,
    // 故障：扫一个不存在的章节 → 空计划。空结果必须判 FAIL（A02 §7.1）。
    () async =>
        ProjectBootstrap.plan(comicDirectory: comicDir, chapterName: 'nope')
            .pageKeys
            .length ==
        expectedPageOrder.length,
    () => 'pages=${plan.pageKeys.length} '
        '(expected ${expectedPageOrder.length}), '
        'unknownSize=${plan.unknownSizeKeys.length}',
  );

  probe(
    'page_keys_are_chapter_relative',
    () async => _allChapterRelative(plan.pageKeys, chapter),
    // 故障：页键丢了章节前缀（`1.webp` 而不是 `ch1/1.webp`）→ 工程找不到图。
    () async => _allChapterRelative(
      [for (final key in plan.pageKeys) key.replaceFirst('$chapter/', '')],
      chapter,
    ),
    () => plan.pageKeys.join(', '),
  );

  probe(
    'page_order_is_natural',
    () async => _sameList(plan.pageKeys, expectedPageOrder),
    // 故障：字典序（`10.webp` 会排到 `2.webp` 前面）。
    () async => _sameList(_lexicographic(plan.pageKeys), expectedPageOrder),
    () => '${plan.pageKeys.join(', ')} | 字典序=${_lexicographic(plan.pageKeys).join(', ')}',
  );

  probe(
    'non_images_ignored',
    () async =>
        plan.pageKeys.isNotEmpty &&
        plan.pageKeys.every((key) => !key.endsWith('.txt')) &&
        !plan.pageKeys.any((key) => key == 'cover.webp'),
    () async => [for (final key in plan.pageKeys) key, 'notes.txt']
        .every((key) => !key.endsWith('.txt')),
    () => plan.pageKeys.join(', '),
  );

  probe(
    'sizes_measured',
    () async => _sizesMatch(plan.sizes, expectedSizes),
    // 故障：把一页的尺寸改错。
    () async => _sizesMatch(
      {...plan.sizes, 'ch1/1.webp': const PageImageSize(1, 1)},
      expectedSizes,
    ),
    () => 'measured=${plan.sizes.length} '
        '[${plan.sizes.entries.map((e) => '${e.key}=${e.value}').join(', ')}]',
  );

  probe(
    'unknown_size_still_a_page',
    () async => _unknownSizeStillAPage(raw, 'ch1/9.webp'),
    // 故障：量不出尺寸的页被从 `pages` 里丢掉 → 那一页静默消失。
    () async => _unknownSizeStillAPage(
      _withoutPage(raw, 'ch1/9.webp'),
      'ch1/9.webp',
    ),
    () => 'unknownSizeKeys=${plan.unknownSizeKeys.join(', ')}',
  );

  // ── 2 · JSON 内容类 ───────────────────────────────────────────────────
  probe(
    'image_info_only_measured',
    () async => _imageInfoOnlyMeasured(raw),
    // 故障：`image_info` 里混进 FT 才会写的 `finish_code`（编造字段）。
    () async => _imageInfoOnlyMeasured(
      _withImageInfoExtra(raw, 'ch1/1.webp', 'finish_code', 0),
    ),
    () => '${(raw['image_info'] as Map?)?.length ?? 0} image_info '
        'entry/entries',
  );

  probe(
    'directory_is_comic_root',
    () async => raw['directory'] == comicDir,
    // 故障：`directory` 指到了章节目录 → 页键会变成 `ch1/ch1/1.webp`。
    () async => _withKey(raw, 'directory', '$comicDir/$chapter')['directory'] ==
        comicDir,
    () => 'directory=${raw['directory']}',
  );

  probe(
    'no_workspace_key',
    () async => !raw.containsKey('workspace'),
    // 故障：写出 `workspace` 键 —— FT 自己不写，写了就是编造（A03 §3.3）。
    () async => !_withKey(raw, 'workspace', projects).containsKey('workspace'),
    () => 'keys=${raw.keys.join(',')}',
  );

  probe(
    'chapter_recorded',
    () async => _chapterMatches(raw, chapter, expectedPageOrder),
    () async => _chapterMatches(_withKey(raw, 'chapters', <Object?>[]), chapter,
        expectedPageOrder),
    () => 'chapters=${(raw['chapters'] as List?)?.length ?? 0}',
  );

  probe(
    'key_order_matches_ft',
    () async => _sameList(raw.keys.toList(), ftTopLevelKeyOrder),
    // 故障：键序打乱 → FT 那边读回来再存一次就会产生 diff。
    () async => _sameList(
      <String>{...raw.keys}.toList()..sort(),
      ftTopLevelKeyOrder,
    ),
    () => raw.keys.join(','),
  );

  // ── 3 · 红线与落盘类 ──────────────────────────────────────────────────
  probe(
    'root_is_safe',
    () async => ProjectBootstrap.rootIsSafe(projects, comicDir),
    // 故障：把工程根设在源漫画目录自己身上。
    () async => ProjectBootstrap.rootIsSafe(comicDir, comicDir),
    () => 'projects=$projects source=$comicDir',
  );

  probe(
    'refuses_inside_downloads',
    () async {
      final bad = await ProjectBootstrap.create(
        projectsRoot: comicDir,
        name: 'Unsafe',
        plan: plan,
      );
      return bad.error != null && !bad.created;
    },
    () async {
      final good = await ProjectBootstrap.create(
        projectsRoot: projects,
        name: 'Unsafe',
        plan: plan,
      );
      return good.error != null && !good.created;
    },
    () => 'refusal=${ProjectBootstrap.validate(
      projectsRoot: comicDir,
      comicDirectory: comicDir,
      name: 'Unsafe',
    )}',
  );

  probe(
    'existing_project_not_overwritten',
    () async {
      await ProjectBootstrap.create(
        projectsRoot: projects,
        name: 'FxForce',
        plan: plan,
      );
      final again = await ProjectBootstrap.create(
        projectsRoot: projects,
        name: 'FxForce',
        plan: plan,
      );
      return !again.created;
    },
    () async {
      await ProjectBootstrap.create(
        projectsRoot: projects,
        name: 'FxForceB',
        plan: plan,
      );
      final again = await ProjectBootstrap.create(
        projectsRoot: projects,
        name: 'FxForceB',
        plan: plan,
        force: true,
      );
      return !again.created;
    },
    () => 'target=${projects}/FxForce',
  );

  probe(
    'existing_project_bytes_untouched',
    () async {
      final first = await ProjectBootstrap.create(
        projectsRoot: projects,
        name: 'FxKeep',
        plan: plan,
      );
      final before = first.jsonFile.readAsBytesSync();
      await ProjectBootstrap.create(
        projectsRoot: projects,
        name: 'FxKeep',
        plan: plan,
      );
      final after = first.jsonFile.readAsBytesSync();
      return _sameBytes(before, after) &&
          !File('${first.jsonFile.path}.backup').existsSync();
    },
    () async {
      final first = await ProjectBootstrap.create(
        projectsRoot: projects,
        name: 'FxKeepB',
        plan: plan,
      );
      final before = first.jsonFile.readAsBytesSync();
      // 故障：显式 force + 少一页的计划 → 文件被改写。
      final shorter = ProjectBootstrapPlan(
        comicDirectory: plan.comicDirectory,
        chapterName: plan.chapterName,
        pageKeys: plan.pageKeys.sublist(0, plan.pageKeys.length - 1),
        sizes: plan.sizes,
      );
      await ProjectBootstrap.create(
        projectsRoot: projects,
        name: 'FxKeepB',
        plan: shorter,
        force: true,
      );
      final after = first.jsonFile.readAsBytesSync();
      return _sameBytes(before, after);
    },
    () => 'target=${projects}/FxKeep',
  );

  probe(
    'downloads_untouched',
    () async => _sameInventory(_inventory(downloads), inventoryBefore),
    () async {
      // 故障：真的往 downloads 里塞一个文件（这正是红线要禁的事）。
      final stray = File('$comicDir/$chapter/stray.json');
      await stray.writeAsString('{}');
      final result = _sameInventory(_inventory(downloads), inventoryBefore);
      await stray.delete();
      return result;
    },
    () => '${inventoryBefore.length} file(s) under downloads',
  );

  probe(
    'sources_not_copied',
    () async => _noImageAtRoot(created.root, plan),
    // 故障：把判据指向原图目录本身 —— 那里当然全是图片。
    () async => _noImageAtRoot('$comicDir/$chapter', plan),
    () {
      // detail 里枚举目录：目录不存在会抛，别让"取个 detail"把整批掀翻。
      final dir = Directory(created.root);
      // 🔴 不能用 `entity.uri.pathSegments.last`：目录 URI 必带结尾斜杠，
      // 取出来恒为 ''（`A02 §5`）—— 上一版 detail 里那串 `,,,` 就是三个
      // 产物目录，看上去像有三个空文件。
      final entries = dir.existsSync()
          ? dir.listSync().map((e) => _basename(e.path)).join(',')
          : '(missing)';
      return 'root=${created.root} entries=$entries';
    },
  );

  probe(
    'artifact_directories_created',
    () async => _artifactDirsExist(created.root),
    () async {
      final bare = await ProjectBootstrap.create(
        projectsRoot: projects,
        name: 'FxNoDirs',
        plan: plan,
        ensureArtifactDirectories: false,
      );
      return _artifactDirsExist(bare.root);
    },
    () => 'root=${created.root}',
  );

  // ── 4 · 回读类 ────────────────────────────────────────────────────────
  probe(
    'workspace_falls_back_to_project_dir',
    () async {
      final loaded = reloaded;
      return loaded != null && loaded.workspace == created.root;
    },
    () async => _workspaceOfWritten(
          _withKey(raw, 'workspace', base),
          created.jsonFile,
        ) ==
        created.root,
    () => 'workspace=${reloaded?.workspace} root=${created.root} '
        'reloadError=$reloadError',
  );

  probe(
    'reload_matches_plan',
    () async {
      final loaded = reloaded;
      return loaded != null &&
          _sameList(loaded.pageOrder, expectedPageOrder) &&
          _sameSet(loaded.pages.keys.toList(), expectedPageOrder) &&
          _sizesMatchByReload(loaded, expectedSizes);
    },
    () async {
      // 故障：用少一页的计划另建一个工程再回读。
      final shorter = ProjectBootstrapPlan(
        comicDirectory: plan.comicDirectory,
        chapterName: plan.chapterName,
        pageKeys: plan.pageKeys.sublist(0, plan.pageKeys.length - 1),
        sizes: plan.sizes,
      );
      final partial = await ProjectBootstrap.create(
        projectsRoot: projects,
        name: 'FxPartial',
        plan: shorter,
      );
      final loaded = await TranslationProjectIo.load(partial.jsonFile);
      return _sameList(loaded.pageOrder, expectedPageOrder) &&
          _sameSet(loaded.pages.keys.toList(), expectedPageOrder) &&
          _sizesMatchByReload(loaded, expectedSizes);
    },
    () => 'created=${created.created} bytes=${created.jsonFile.existsSync()
        ? created.jsonFile.lengthSync()
        : 0} reloadError=$reloadError',
  );

  probe(
    'reloaded_keys_are_image_pages',
    () async {
      final loaded = reloaded;
      return loaded != null &&
          loaded.pageOrder.isNotEmpty &&
          loaded.pageOrder.every(TranslationProject.isImagePage);
    },
    () async => ['ch1/1.webp', 'ch1/notes.txt']
        .every(TranslationProject.isImagePage),
    () => 'pageOrder=${reloaded?.pageOrder.join(', ') ?? '(null)'}',
  );

  // 空结果判 FAIL：一条都没定义出来，说明这批断言自己坏了。
  check(
    'bootstrap.probes_defined',
    probes.isNotEmpty,
    probes.isEmpty ? 'no probes defined' : '${probes.length} probe(s)',
  );

  // 🔴 每条探针单独 try：一条探针抛异常不能连带整批判不出来，更不能因为
  // "没跑完"而被当成通过 —— 默认值就是「判 FAIL」那一侧。
  for (final item in probes) {
    var green = false;
    var red = true;
    String? probeError;
    try {
      green = await item.green();
      red = await item.red();
    } catch (e) {
      probeError = e.toString();
    }
    String detail;
    try {
      detail = item.detail();
    } catch (e) {
      detail = '(detail threw: $e)';
    }
    check(
      'bootstrap.${item.name}',
      probeError == null && green && !red,
      probeError != null
          ? 'probe threw: $probeError'
          : '$detail | 绿路径=${green ? 'true' : 'FALSE'} '
              '故障路径=${red ? '仍绿(装饰品)' : '变红'}',
    );
  }
}

// ---------------------------------------------------------------------------
// 判据（纯函数，绿/红两条路径共用）
// ---------------------------------------------------------------------------

bool _allChapterRelative(List<String> keys, String chapter) =>
    keys.isNotEmpty &&
    keys.every((key) => key.startsWith('$chapter/') && !key.contains('\\'));

bool _sameList(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _sameSet(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  final set = a.toSet();
  return set.length == a.length && b.every(set.contains);
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

List<String> _lexicographic(List<String> keys) => [...keys]..sort();

bool _sizesMatch(Map<String, PageImageSize> actual, Map<String, List<int>> want) {
  if (actual.length != want.length) return false;
  for (final entry in want.entries) {
    final got = actual[entry.key];
    if (got == null) return false;
    if (got.width != entry.value[0] || got.height != entry.value[1]) {
      return false;
    }
  }
  return true;
}

bool _unknownSizeStillAPage(Map<String, Object?> raw, String key) {
  final pages = raw['pages'];
  final order = raw['page_order'];
  final info = raw['image_info'];
  if (pages is! Map || order is! List || info is! Map) return false;
  return pages.containsKey(key) &&
      order.contains(key) &&
      !info.containsKey(key);
}

bool _imageInfoOnlyMeasured(Map<String, Object?> raw) {
  final info = raw['image_info'];
  if (info is! Map || info.isEmpty) return false;
  for (final value in info.values) {
    if (value is! Map) return false;
    final keys = value.keys.map((k) => k.toString()).toList()..sort();
    if (!_sameList(keys, ['height', 'width'])) return false;
    for (final entry in value.values) {
      if (entry is! int || entry <= 0) return false;
    }
  }
  return true;
}

bool _chapterMatches(
  Map<String, Object?> raw,
  String chapter,
  List<String> pages,
) {
  final chapters = raw['chapters'];
  if (chapters is! List || chapters.length != 1) return false;
  final first = chapters.first;
  if (first is! Map) return false;
  if (first['name'] != chapter) return false;
  final listed = first['pages'];
  if (listed is! List) return false;
  return _sameList(
    [for (final entry in listed) entry.toString()],
    pages,
  );
}

bool _noImageAtRoot(String root, ProjectBootstrapPlan plan) {
  final dir = Directory(root);
  if (!dir.existsSync()) return false;
  for (final entity in dir.listSync(followLinks: false)) {
    if (entity is! File) continue;
    final name = _basename(entity.path);
    final dot = name.lastIndexOf('.');
    if (dot < 0) continue;
    if (ProjectBootstrap.pageImageExtensions
        .contains(name.substring(dot).toLowerCase())) {
      return false; // 原图被复制进来了 —— 这正是要禁止的。
    }
  }
  // 反过来：计划的每一页在源目录里都还在（没被"移动"过来）。
  for (final key in plan.pageKeys) {
    if (!File('${plan.comicDirectory}/$key').existsSync()) return false;
  }
  return true;
}

bool _artifactDirsExist(String root) {
  for (final kind in ['mask', 'inpainted', 'result']) {
    if (!Directory('$root/$kind').existsSync()) return false;
  }
  return true;
}

String _workspaceOfWritten(Map<String, Object?> raw, File jsonFile) {
  final project = TranslationProject.buildFrom(raw, jsonFile);
  return project.workspace;
}

bool _sizesMatchByReload(
  TranslationProject project,
  Map<String, List<int>> want,
) {
  final info = project.imageInfo;
  if (info.length != want.length) return false;
  for (final entry in want.entries) {
    final value = info[entry.key];
    if (value is! Map) return false;
    if (value['width'] != entry.value[0] || value['height'] != entry.value[1]) {
      return false;
    }
  }
  return true;
}

List<String> _inventory(String dir) {
  final root = Directory(dir);
  if (!root.existsSync()) return const [];
  return [
    for (final entity in root.listSync(recursive: true, followLinks: false))
      entity.path.replaceAll('\\', '/'),
  ]..sort();
}

bool _sameInventory(List<String> a, List<String> b) => _sameList(a, b);

/// 目录名/文件名。🔴 见 `A02 §5`：`uri.pathSegments.last` 对目录返回空串。
String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  final slash = normalized.lastIndexOf('/');
  return slash < 0 ? normalized : normalized.substring(slash + 1);
}

// ---------------------------------------------------------------------------
// raw 的变异（只用于故障路径）
// ---------------------------------------------------------------------------

Map<String, Object?> _withKey(
  Map<String, Object?> raw,
  String key,
  Object? value,
) {
  final copy = <String, Object?>{...raw};
  copy[key] = value;
  return copy;
}

Map<String, Object?> _withoutPage(Map<String, Object?> raw, String pageKey) {
  final copy = <String, Object?>{...raw};
  final pages = <String, Object?>{...?copy['pages'] as Map?};
  pages.remove(pageKey);
  copy['pages'] = pages;
  return copy;
}

Map<String, Object?> _withImageInfoExtra(
  Map<String, Object?> raw,
  String pageKey,
  String extraKey,
  Object? extraValue,
) {
  final copy = <String, Object?>{...raw};
  final info = <String, Object?>{
    for (final entry in (copy['image_info'] as Map? ?? const {}).entries)
      entry.key.toString(): entry.value,
  };
  final target = info[pageKey];
  if (target is Map) {
    info[pageKey] = <String, Object?>{
      for (final entry in target.entries) entry.key.toString(): entry.value,
      extraKey: extraValue,
    };
  }
  copy['image_info'] = info;
  return copy;
}

// ---------------------------------------------------------------------------
// 文件头夹具
// ---------------------------------------------------------------------------

Future<void> _write(String path, List<int> bytes) async {
  final file = File(path);
  if (!file.parent.existsSync()) {
    await file.parent.create(recursive: true);
  }
  await file.writeAsBytes(bytes, flush: true);
}

List<int> _be16Bytes(int v) => [(v >> 8) & 0xFF, v & 0xFF];

List<int> _le16Bytes(int v) => [v & 0xFF, (v >> 8) & 0xFF];

List<int> _le32Bytes(int v) => [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

List<int> _le24Bytes(int v) => [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF];

/// PNG：签名 + IHDR 的长度/类型 + 宽高（大端）。
List<int> _png(int width, int height) => [
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
      0x00, 0x00, 0x00, 0x0D, //
      0x49, 0x48, 0x44, 0x52, //
      ..._be16Bytes(width >> 16), ..._be16Bytes(width & 0xFFFF),
      ..._be16Bytes(height >> 16), ..._be16Bytes(height & 0xFFFF),
    ];

/// WebP / VP8X：画布宽高存成 24 位的「实际值 - 1」。
List<int> _webpVp8x(int width, int height) => [
      0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00, // RIFF + size
      0x57, 0x45, 0x42, 0x50, // WEBP
      0x56, 0x50, 0x38, 0x58, // VP8X
      0x00, 0x00, 0x00, 0x00, // chunk size
      // 🔴 第 20 字节是 flags，21~23 是 reserved —— 三个零会让宽高整体错位
      // 一个字节（`head[24:27]` / `head[27:30]` 是 FT 与 Python 侧共同的口径）。
      0x00, // flags
      0x00, 0x00, 0x00, // reserved
      ..._le24Bytes(width - 1),
      ..._le24Bytes(height - 1),
    ];

/// WebP / VP8L：宽高各 14 位打包进一个 32 位，同样存「实际值 - 1」。
List<int> _webpVp8l(int width, int height) => [
      0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00,
      0x57, 0x45, 0x42, 0x50,
      0x56, 0x50, 0x38, 0x4C, // VP8L
      0x00, 0x00, 0x00, 0x00,
      0x2F, // VP8L signature
      ..._le32Bytes((width - 1) | ((height - 1) << 14)),
    ];

/// WebP / VP8（有损）：帧头之后的第 26/28 字节是 14 位宽高。
List<int> _webpVp8(int width, int height) => [
      0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00,
      0x57, 0x45, 0x42, 0x50,
      0x56, 0x50, 0x38, 0x20, // 'VP8 '
      0x00, 0x00, 0x00, 0x00, // chunk size
      0x00, 0x00, 0x00, // frame tag
      0x9D, 0x01, 0x2A, // start code
      ..._le16Bytes(width & 0x3FFF),
      ..._le16Bytes(height & 0x3FFF),
    ];

/// 容器认得（RIFF/WEBP）但编码块不认 → 尺寸解析应当返回 null。
List<int> _webpUnknownCodec() => [
      0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00,
      0x57, 0x45, 0x42, 0x50,
      0x58, 0x58, 0x58, 0x58, // 未知 fourcc
      ...List<int>.filled(16, 0x00),
    ];

/// JPEG：SOI + APP0 + SOF0（宽高在 SOF0 里，大端）。
List<int> _jpeg(int width, int height) => [
      0xFF, 0xD8, // SOI
      0xFF, 0xE0, 0x00, 0x10, // APP0, length 16
      ...List<int>.filled(14, 0x41), // APP0 payload
      0xFF, 0xC0, 0x00, 0x11, // SOF0, length 17
      0x08, // precision
      ..._be16Bytes(height),
      ..._be16Bytes(width),
      ...List<int>.filled(10, 0x01), // 分量表（长度凑够即可）
    ];

/// GIF89a：第 6/8 字节是小端宽高。
List<int> _gif(int width, int height) => [
      0x47, 0x49, 0x46, 0x38, 0x39, 0x61, // GIF89a
      ..._le16Bytes(width),
      ..._le16Bytes(height),
      0x00, 0x00,
    ];

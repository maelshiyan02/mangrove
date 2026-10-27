// P53 创建链路核验：走**和「新建翻译工程」向导完全相同**的那条函数，
// 看它是不是真的把工程落到「漫画级根 / 章节键」下面。
//
// ## 为什么要有这条命令
//
// 向导本身是 UI（选漫画 → 选章节 → 命名 → 创建），headless 跑不了；但它最后
// 调的是 `StudioReaderLink.locate` + `StudioReaderLink.ensureBinding` ——
// 这两个是纯逻辑 + IO，可以在 headless 里跑。于是「向导会不会把工程建对地方」
// 这件事，不必点界面也能验。
//
// ## 判据
//
// 1. 绑定指向的 json 落在 `<漫画级根>/<章节键>/` 里面（不是平铺、不是整本）；
// 2. 漫画级根有 `level: comic` 的边车 + 一份封面；
// 3. 章节级目录有 `level: chapter` 的边车；
// 4. 该章**已有工程**时不许新建第二份（json 数量恒为 1）。
//
// ## 用法
//
// `mangrove.exe --headless project-create-check --comic-id 5 --chapter "<章节键>"`
library;

import 'dart:convert';
import 'dart:io';

import 'package:mangrove/foundation/appdata.dart';
import 'package:mangrove/foundation/log.dart';
import 'package:mangrove/foundation/translation_project/studio_project_meta.dart';
import 'package:mangrove/foundation/translation_project/studio_reader_app.dart';

void _print(Map<String, dynamic> data) {
  print('[CLI PRINT] ${jsonEncode(data)}');
}

String _norm(String path) =>
    path.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');

/// `--headless project-create-check --comic-id <cid> --chapter <章节键> [--json out.json]`
Future<void> runProjectCreateCheck(
  List<String> args,
  int commandIndex,
) async {
  String argOr(String flag, String fallback) {
    final i = args.indexOf(flag);
    return i != -1 && i + 1 < args.length ? args[i + 1] : fallback;
  }

  final cid = argOr('--comic-id', '');
  final chapterKey = argOr('--chapter', '');
  final sourceKey = argOr('--source-key', 'local');
  final outIndex = args.indexOf('--json');
  final outPath = outIndex >= 0 && outIndex + 1 < args.length
      ? args[outIndex + 1]
      : '';

  final checks = <Map<String, Object?>>[];
  void check(String name, bool passed, String detail) {
    checks.add({'name': name, 'passed': passed, 'detail': detail});
  }

  if (cid.isEmpty || chapterKey.isEmpty) {
    _print({
      'status': 'error',
      'message': 'project-create-check needs --comic-id and --chapter.',
    });
    return;
  }

  final target = StudioReaderLink.locate(
    cid: cid,
    sourceKey: sourceKey,
    eid: chapterKey,
  );
  check(
    'locate.finds_comic_and_chapter',
    target != null && target.chapterName == chapterKey,
    'target=${target?.toString()}',
  );
  if (target == null) {
    _print({
      'status': 'error',
      'message': 'locate failed for $cid / $chapterKey',
      'data': {'checks': checks},
    });
    return;
  }

  final (binding, reason) = await StudioReaderLink.ensureBinding(
    cid: cid,
    sourceKey: sourceKey,
    eid: chapterKey,
    target: target,
    allowEmptyShell: true,
  );
  check(
    'ensureBinding.succeeds',
    binding != null,
    'reason=$reason',
  );
  if (binding == null) {
    await appdata.flushImplicitData();
    _print({
      'status': 'error',
      'message': 'ensureBinding failed: $reason',
      'data': {'checks': checks},
    });
    return;
  }

  final jsonPath = _norm(binding.jsonPath);
  final chapterDir = _norm(jsonPath.substring(0, jsonPath.lastIndexOf('/')));
  final comicRoot = _norm(
    chapterDir.substring(0, chapterDir.lastIndexOf('/')),
  );
  check(
    'layout.json_in_chapter_dir',
    jsonPath.contains('/$chapterKey/'),
    'json=$jsonPath',
  );
  check(
    'layout.comic_root_sidecar',
    _isComicLevel(comicRoot),
    'root=$comicRoot',
  );
  check(
    'layout.chapter_sidecar',
    _isChapterLevel(chapterDir),
    'chapterDir=$chapterDir',
  );
  check(
    'layout.cover_borrowed',
    _coverOf(comicRoot) != null,
    'root=$comicRoot',
  );
  final jsonCount = _projectJsonsIn(chapterDir);
  check(
    'layout.single_json_per_chapter',
    jsonCount == 1,
    'jsons=$jsonCount dir=$chapterDir',
  );

  await appdata.flushImplicitData();
  final passed = checks.every((c) => c['passed'] == true);
  final summary = {
    'command': 'project-create-check',
    'comicId': cid,
    'chapter': chapterKey,
    'checks': checks,
    'passed': passed,
  };
  _print(summary);
  _print({
    'status': passed ? 'success' : 'error',
    'message': passed
        ? 'Project create check PASS (${checks.length} checks)'
        : 'Project create check FAIL',
    'data': summary,
  });
  if (outPath.isNotEmpty) {
    final file = File(outPath);
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(summary));
  }
  Log.info('P53 Create', 'passed=$passed');
}

bool _isComicLevel(String dir) {
  final meta = StudioProjectMeta.readFromProjectDir(dir);
  return meta != null && meta.isComicLevel;
}

bool _isChapterLevel(String dir) {
  final meta = StudioProjectMeta.readFromProjectDir(dir);
  return meta != null && !meta.isComicLevel;
}

String? _coverOf(String dir) {
  for (final ext in const ['jpg', 'jpeg', 'png', 'webp']) {
    if (File('$dir/cover.$ext').existsSync()) return 'cover.$ext';
  }
  return null;
}

int _projectJsonsIn(String dir) {
  final target = Directory(dir);
  if (!target.existsSync()) return 0;
  var count = 0;
  for (final entity in target.listSync(followLinks: false)) {
    if (entity is! File) continue;
    final name = entity.path.split(RegExp(r'[/\\]')).last;
    if (!name.startsWith('imgtrans_')) continue;
    if (!name.endsWith('.json')) continue;
    if (name.endsWith('.artifacts.json')) continue;
    count++;
  }
  return count;
}

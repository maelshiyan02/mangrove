// P53 转链：把老工程里 `source/` 的**原件副本**换成指向原件的 junction。
//
// ## 为什么需要这一步
//
// P53 起新建的工程不再复制原件（`source/` = junction）。但**既有工程**的
// `source/` 是当年实打实复制的一份 —— 几十上百张图，每本几百 MB。用户要的
// "减少磁盘空间占用"对这些工程还没兑现。
//
// ## 安全边界（用户明确要求：备份优先、绝不静默删文件）
//
// 1. **默认 dry-run**：不加 `--apply` 只打印计划。
// 2. 只有当**原件目录确实存在、且该工程每一页在原件里都能一一对上**时，才
//    允许替换。页对不上 ⇒ 跳过并如实报出来（宁可多占磁盘，也不丢图）。
// 3. 替换前把副本**改名**成 `source.bak_<时间戳>`（不是删），junction 建好
//    之后再由用户自行处理备份目录 —— 万一原件后来被删了，副本还在。
// 4. junction 目标 = **漫画根目录**（不是章节目录）：工程页键带章节前缀
//    （`1 [Rokari Comics] [comix.to]/001.webp`），根目录才能把前缀解析出来。
//
// ## 依赖
//
// 需要 App 已初始化（本地库 + 绑定表），所以是 **post-init** 命令。
library;

import 'dart:convert';
import 'dart:io';

import 'package:mangrove/foundation/bt_project/bt_project_manager.dart';
import 'package:mangrove/foundation/local.dart';
import 'package:mangrove/foundation/log.dart';
import 'package:mangrove/foundation/translation_project/project_bootstrap.dart';
import 'package:mangrove/foundation/translation_project/studio_project_meta.dart';

void _print(Map<String, dynamic> data) {
  print('[CLI PRINT] ${jsonEncode(data)}');
}

String _norm(String path) =>
    path.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');

/// `--headless project-relink [--apply] [--json out.json]`
Future<void> runProjectRelink(
  List<String> args,
  int commandIndex,
) async {
  final apply = args.contains('--apply');
  final outIndex = args.indexOf('--json');
  final outPath = outIndex >= 0 && outIndex + 1 < args.length
      ? args[outIndex + 1]
      : '';

  final manager = BtProjectManager();
  await manager.scan();

  final report = <Map<String, Object?>>[];
  for (final id in manager.projectIds) {
    final project = manager.projectFor(id);
    if (project == null) continue;
    final sourceDir = _norm(project.directory);
    final type = FileSystemEntity.typeSync(sourceDir, followLinks: false);
    final chapterDir = _norm(project.jsonFile.parent.path);
    final entry = <String, Object?>{
      'project': id,
      'chapterDir': chapterDir,
      'source': sourceDir,
      'type': type.toString(),
    };

    if (type == FileSystemEntityType.link) {
      entry['action'] = 'already-linked';
      report.add(entry);
      continue;
    }
    if (!Directory(sourceDir).existsSync()) {
      entry['action'] = 'no-source-dir';
      report.add(entry);
      continue;
    }

    // 原件目录：从边车的 `originalPath` 拿；拿不到就从本地库按章节键反查。
    final sidecar = StudioProjectMeta.readFromProjectDir(chapterDir);
    final chapterKey = chapterDir.split('/').last;
    var original = sidecar?.originalPath ?? '';
    if (original.isEmpty || !Directory(original).existsSync()) {
      original = _findComicDir(chapterKey);
    }
    if (original.isEmpty || !Directory(original).existsSync()) {
      entry['action'] = 'no-original';
      entry['detail'] = 'originalPath=${sidecar?.originalPath ?? ''}';
      report.add(entry);
      continue;
    }
    // 🔴 每一页都要在原件里对得上 —— 对不上就**不动**（宁可多占磁盘）。
    final missing = <String>[
      for (final key in project.pageOrder)
        if (!File('$original/$key').existsSync()) key,
    ];
    if (missing.isNotEmpty) {
      entry['action'] = 'skipped-missing-pages';
      entry['missing'] = missing.length;
      entry['detail'] = missing.take(3).join(', ');
      report.add(entry);
      continue;
    }

    entry['action'] = apply ? 'relinked' : 'would-relink';
    entry['original'] = _norm(original);
    entry['pages'] = project.pageOrder.length;

    if (apply) {
      try {
        // 副本先改名（不删），junction 建好之后用户再自行清理备份。
        final backup = '$sourceDir.bak_${_stamp()}';
        Directory(sourceDir).renameSync(backup);
        entry['backup'] = backup;
        final created = await Process.run('cmd', [
          '/c',
          'mklink',
          '/J',
          sourceDir.replaceAll('/', '\\'),
          _norm(original).replaceAll('/', '\\'),
        ]);
        if (created.exitCode != 0) {
          // 建链接失败 ⇒ 把副本搬回去，绝不留下"工程没有 source"的中间态。
          Directory(backup).renameSync(sourceDir);
          entry['action'] = 'failed';
          entry['detail'] = 'mklink exit=${created.exitCode}';
        }
      } catch (e, s) {
        Log.error('P53 Relink', 'relink $sourceDir failed: $e', s);
        entry['action'] = 'failed';
        entry['detail'] = '$e';
      }
    }
    report.add(entry);
  }

  final summary = {
    'command': 'project-relink',
    'apply': apply,
    'total': report.length,
    'report': report,
  };
  _print(summary);
  _print({
    'status': 'success',
    'message': apply
        ? 'Relink finished: ${report.length} project(s) processed.'
        : 'Relink dry-run finished: ${report.length} project(s) inspected.',
    'data': summary,
  });
  if (outPath.isNotEmpty) {
    final file = File(outPath);
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(summary));
  }
}

/// 按**章节键**在本地库里找素材漫画的目录。
String _findComicDir(String chapterKey) {
  if (chapterKey.isEmpty) return '';
  try {
    for (final comic in LocalManager().getComics(LocalSortType.defaultSort)) {
      if (BtProjectManager.isBtComic(comic.id)) continue;
      final chapters = comic.chapters;
      if (chapters == null) continue;
      for (final key in chapters.ids) {
        if (key != chapterKey) continue;
        if (!comic.directory.contains('downloads')) continue;
        return comic.baseDir;
      }
    }
  } catch (e, s) {
    Log.warning('P53 Relink', 'find comic dir failed: $e / $s');
  }
  return '';
}

String _stamp() {
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${now.year}${two(now.month)}${two(now.day)}'
      '-${two(now.hour)}${two(now.minute)}${two(now.second)}';
}

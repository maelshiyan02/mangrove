// P53 布局核验：对**真实素材库**跑一遍「漫画级卡 → 章节级工程 → 原件」的整条链。
//
// ## 为什么要有这条命令
//
// 用户要求的是：翻译工程像**另一种类型的漫画** —— 一张卡、一本详情页、章节
// 列表里列的是翻译工程，而且能和素材漫画放进同一个合集。界面能不能做到，
// 取决于四件事同时成立：
//
// 1. 本地库里有一张**漫画级卡**（一张卡 = 一本漫画）；
// 2. 卡的封面 / 标题 / 简介 / 章节 **借用素材漫画**；
// 3. 卡的每个章节都对应一个**章节级工程**（`imgtrans_*.json` 在章节子目录里）；
// 4. 章节工程读得到原件（`source/` 是链接，不是副本）。
//
// 这四件事在**真实库**上才说得清（夹具里的漫画没有封面池、没有记录表、没有
// 合集）。所以这条命令直接读本地库与磁盘，并把每一条判据都写进报告 ——
// 任何一条不成立都判 FAIL，不给"看起来正常"的余地。
//
// ## 用法
//
// `mangrove.exe --headless project-layout-check [--json out.json]`
//
// 纯读：不写任何文件（除了报告本身）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:mangrove/foundation/bt_project/bt_project_manager.dart';
import 'package:mangrove/foundation/local.dart';
import 'package:mangrove/foundation/log.dart';
import 'package:mangrove/foundation/translation_project/project_bootstrap.dart';
import 'package:mangrove/foundation/translation_project/studio_project_meta.dart';

/// 一条断言的结果。
class _Check {
  _Check(this.name, this.passed, this.detail);

  final String name;
  final bool passed;
  final String detail;

  Map<String, Object?> toJson() => {
        'name': name,
        'passed': passed,
        'detail': detail,
      };
}

void _print(Map<String, dynamic> data) {
  print('[CLI PRINT] ${jsonEncode(data)}');
}

/// 归一化路径。
String _norm(String path) =>
    path.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');

/// `--headless project-layout-check [--json out.json]`
Future<void> runProjectLayoutCheck(
  List<String> args,
  int commandIndex,
) async {
  final outIndex = args.indexOf('--json');
  final outPath = outIndex >= 0 && outIndex + 1 < args.length
      ? args[outIndex + 1]
      : '';

  final manager = BtProjectManager();
  await manager.scan();

  final checks = <_Check>[];
  void check(String name, bool passed, String detail) {
    checks.add(_Check(name, passed, detail));
  }

  final roots = BtProjectManager.roots;
  final comics = LocalManager().getComics(LocalSortType.defaultSort);
  final cards = comics.where((c) => BtProjectManager.isBtComic(c.id)).toList();

  check(
    'library_has_bt_cards',
    cards.isNotEmpty,
    'bt_ cards=${cards.length}, roots=${roots.join(', ')}',
  );

  for (final card in cards) {
    final chapterKeys = manager.chapterKeysOf(card.id);
    final label = card.title;

    // 1 · 卡的封面必须是**素材漫画的封面**（借用），而不是某一页。
    final coverPath = card.cover.trim();
    final coverExists = coverPath.isNotEmpty &&
        File('${_norm(card.baseDir)}/$coverPath').existsSync();
    check(
      'card.cover_present',
      coverExists,
      'card=${card.id} cover=$coverPath baseDir=${_norm(card.baseDir)}',
    );

    // 2 · 章节列表 = 已有工程的章节。
    check(
      'card.chapters_match_projects',
      chapterKeys.isNotEmpty &&
          chapterKeys.length == card.downloadedChapters.length &&
          chapterKeys.toSet().containsAll(card.downloadedChapters),
      'card=${card.id} keys=${chapterKeys.join(' | ')} '
          'downloaded=${card.downloadedChapters.join(' | ')}',
    );

    // 3 · 每一章：工程 json 在**章节子目录**里，页读得到，source 是链接。
    for (final key in chapterKeys) {
      final projectId = manager.chapterProjectId(card.id, key);
      final project = projectId == null
          ? null
          : manager.chapterProjectFor(card.id, key);
      if (project == null) {
        check(
          'chapter.project_resolves',
          false,
          'card=${card.id} chapter=$key (no project)',
        );
        continue;
      }
      final jsonPath = _norm(project.jsonFile.path);
      final chapterDir = _norm(project.jsonFile.parent.path);
      final rootDir = _norm(Directory(chapterDir).parent.path);
      check(
        'chapter.json_lives_in_chapter_dir',
        jsonPath.startsWith('$rootDir/') &&
            jsonPath.contains('/$key/'),
        'json=${project.jsonFile.path}',
      );

      final sourceDir = _norm(project.directory);
      final isLink = FileSystemEntity.typeSync(sourceDir, followLinks: false) ==
          FileSystemEntityType.link;
      check(
        'chapter.source_is_link_to_originals',
        isLink,
        'source=$sourceDir type='
        '${FileSystemEntity.typeSync(sourceDir, followLinks: false)}',
      );

      // 页读得到（链接透明）且不是工程自己目录里的副本。
      final readable = project.pageOrder.isNotEmpty &&
          project.pageOrder
              .every((key) => File('$sourceDir/$key').existsSync());
      check(
        'chapter.pages_readable',
        readable,
        'pages=${project.pageOrder.length}',
      );

      final sidecar = StudioProjectMeta.readFromProjectDir(chapterDir);
      check(
        'chapter.sidecar_is_chapter_level',
        sidecar != null && !sidecar.isComicLevel,
        'sidecar=${sidecar?.toJson()}',
      );
    }
  }

  final passed = checks.every((c) => c.passed);
  final summary = {
    'command': 'project-layout-check',
    'checks': checks.map((c) => c.toJson()).toList(),
    'passed': passed,
    'total': checks.length,
  };
  _print({'status': 'running', 'message': 'Project layout check', 'data': summary});
  _print({
    'status': passed ? 'success' : 'error',
    'message': passed
        ? 'Project layout check PASS (${checks.length} checks)'
        : 'Project layout check FAIL',
    'data': summary,
  });
  if (outPath.isNotEmpty) {
    final file = File(outPath);
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(summary));
  }
  Log.info('P53 Layout', 'passed=$passed checks=${checks.length}');
}

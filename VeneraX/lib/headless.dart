

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/components/block_resize_geometry.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/bt_project/bt_project_manager.dart';
import 'package:venera/pages/comic_source_page.dart';
import 'package:venera/init.dart';
import 'package:venera/foundation/follow_updates.dart';
import 'package:venera/foundation/follow_update_scope.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/translation_project/project_validator.dart';
import 'package:venera/foundation/translation_project/finished_export.dart';
import 'package:venera/foundation/translation_project/project_io.dart';
import 'package:venera/foundation/translation_project/edit_command.dart';
import 'package:venera/foundation/translation_project/project_writer.dart';
import 'package:venera/foundation/translation_project/rich_text_sync.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';
import 'package:venera/foundation/translation_project/text_block.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/chapter_directory.dart';
import 'package:venera/foundation/leave_guard.dart';
import 'package:venera/foundation/missing_pages.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/network/cookie_jar.dart';
import 'package:venera/network/comix_client.dart';
import 'package:venera/network/download.dart';
import 'package:venera/utils/io.dart' show FileSystemEntityExt;
import 'package:venera/headless_p1_checks.dart';
import 'package:venera/headless_p2_checks.dart';
import 'package:venera/headless_pipeline_check.dart';



void cliPrint(Map<String, dynamic> data) {
  print('[CLI PRINT] ${jsonEncode(data)}');
}

/// Progress marker for headless startup.
///
/// Startup has several sequential awaits that can stall on a windowless run;
/// without these, a stalled command is indistinguishable from a slow one.
void _headlessTrace(String step) => print('[headless] $step');

/// Runs the translation-project checks from inside the app binary.
///
/// `venera.exe --headless project-check <file-or-folder> [--json <out.json>]`
///
/// This exists because `dart run` cannot execute this package in the build
/// environment (the native-asset hooks need to spawn `cmd.exe`), so the release
/// build is the only place the project model can be exercised end to end. If
/// the checks pass here, the model is genuinely compiled into the shipped
/// binary and works against a real FT project.
Future<void> runProjectCheck(List<String> args, int commandIndex) async {
  // First non-flag argument after the command name.
  final candidate = commandIndex + 1 < args.length
      ? args[commandIndex + 1]
      : null;
  final target = candidate == null || candidate.startsWith('--')
      ? null
      : candidate;
  if (target == null || target.isEmpty) {
    cliPrint({
      'status': 'error',
      'message': 'project-check needs a project file or folder.',
    });
    exit(1);
  }

  final jsonIndex = args.indexOf('--json');
  final outPath = jsonIndex != -1 && jsonIndex + 1 < args.length
      ? args[jsonIndex + 1]
      : '${Directory.current.path}/s6_project_check.json';

  var file = File(target);
  if (Directory(target).existsSync()) {
    final found = Directory(target)
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .where((entry) {
          final name = entry.uri.pathSegments.last.toLowerCase();
          return name.startsWith('imgtrans_') && name.endsWith('.json');
        })
        .toList();
    found.sort((a, b) => a.path.compareTo(b.path));
    if (found.isEmpty) {
      cliPrint({
        'status': 'error',
        'message': 'No imgtrans_*.json under $target',
      });
      exit(1);
    }
    file = found.first;
  }

  cliPrint({
    'status': 'running',
    'message': 'Validating translation project',
    'data': {'file': file.path},
  });

  final codecChecks = ProjectValidator.checkCodec();
  for (final check in codecChecks) {
    cliPrint({
      'status': 'running',
      'message': 'Codec check',
      'data': {
        'name': check.name,
        'passed': check.passed,
        'detail': check.detail,
      },
    });
  }

  ProjectValidationReport report;
  try {
    report = await ProjectValidator.validate(jsonFile: file);
  } catch (error, stack) {
    cliPrint({'status': 'error', 'message': 'Validation threw: $error'});
    Log.error('ProjectCheck', 'Validation of ${file.path} threw', stack);
    exit(1);
  }
  for (final check in report.checks) {
    cliPrint({
      'status': 'running',
      'message': 'Project check',
      'data': {
        'name': check.name,
        'passed': check.passed,
        'detail': check.detail,
      },
    });
  }

  final passed = report.passed && codecChecks.every((check) => check.passed);

  final output = File(outPath);
  if (!output.parent.existsSync()) {
    await output.parent.create(recursive: true);
  }
  await output.writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'version': 1,
      'validator': 'S6 TranslationProject',
      'file': file.path,
      'passed': passed,
      'codec': [
        for (final check in codecChecks)
          {'name': check.name, 'passed': check.passed, 'detail': check.detail},
      ],
      'project': report.toJson(),
    }),
    encoding: utf8,
  );

  cliPrint({
    'status': passed ? 'success' : 'error',
    'message':
        'Translation project check '
        '${passed ? 'PASS' : 'FAIL'} '
        '(${report.passedCount + codecChecks.where((c) => c.passed).length}'
        '/${report.checks.length + codecChecks.length})',
    'data': {'file': file.path, 'report': output.path},
  });
  // No `Log.info` here: this command runs before app startup, so `App` is not
  // initialized and the logger has nowhere to write. [cliPrint] plus the JSON
  // report are the output surface.
  exit(passed ? 0 : 1);
}

/// `venera.exe --headless export-check <file-or-folder> [--json <out.json>]`
///
/// Dry-runs the finished-product export: resolves where every `result/` page
/// would land under `ComicLibrary/translated/` and asserts the shape the local
/// scanner requires (chapter folders of flat images, no nesting, unbroken
/// numbering). Nothing is written, so this is safe to run on a real library.
///
/// Unlike `project-check` this one runs **after** app startup, because the
/// sibling command needs `LocalManager` to resolve the library root.
Future<void> runExportCheck(List<String> args, int commandIndex) async {
  final candidate = commandIndex + 1 < args.length
      ? args[commandIndex + 1]
      : null;
  final target = candidate == null || candidate.startsWith('--')
      ? null
      : candidate;
  if (target == null || target.isEmpty) {
    cliPrint({
      'status': 'error',
      'message': 'export-check needs a project file or folder.',
    });
    exit(1);
  }

  var file = File(target);
  if (Directory(target).existsSync()) {
    final found = Directory(target)
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .where((entry) {
          final name = entry.uri.pathSegments.last.toLowerCase();
          return name.startsWith('imgtrans_') && name.endsWith('.json');
        })
        .toList();
    if (found.isEmpty) {
      cliPrint({'status': 'error', 'message': 'No imgtrans_*.json under $target'});
      exit(1);
    }
    // FT stores one project per comic *and* one per chapter. The comic-level
    // file is the shallow one and is the only one carrying a real `page_order`;
    // picking by path alone lands on `<comic>/0/imgtrans_0.json`, whose pages
    // have no artifacts of their own.
    found.sort((a, b) {
      final depth = a.path.split(RegExp(r'[\\/]')).length.compareTo(
            b.path.split(RegExp(r'[\\/]')).length,
          );
      return depth != 0 ? depth : a.path.compareTo(b.path);
    });
    file = found.first;
  }

  cliPrint({
    'status': 'running',
    'message': 'Planning finished-product export',
    'data': {'file': file.path},
  });

  final project = await TranslationProjectIo.load(file);
  final libraryRoot = LocalManager().path;
  final translatedRoot = libraryRoot.isEmpty
      ? Directory.systemTemp.path
      : '${Directory(libraryRoot).parent.path}/translated';
  final comicName = FinishedExport.comicNameFor(project);
  final plan = FinishedExport.plan(
    project: project,
    translatedRoot: translatedRoot,
    comicName: comicName,
  );

  // The scanner rejects a whole comic when a chapter directory contains a
  // directory, so that count has to be zero — and the finished product is only
  // useful if its pages actually exist.
  final checks = <Map<String, Object?>>[
    {
      'name': 'plan.chapters',
      'passed': plan.chapters.isNotEmpty,
      'detail': 'chapters=${plan.chapters.join(',')}',
    },
    {
      'name': 'plan.no-nesting',
      'passed': plan.nestedViolations == 0,
      'detail': 'nestedViolations=${plan.nestedViolations}',
    },
    {
      'name': 'plan.numbering',
      'passed': _numberingIsContinuous(plan),
      'detail': 'first=${plan.items.isEmpty ? '-' : plan.items.first.target}',
    },
    {
      'name': 'plan.results-present',
      'passed': plan.available > 0,
      'detail': 'available=${plan.available}/${plan.total} '
          'alreadyPublished=${plan.alreadyPublished} missing=${plan.missing}',
    },
    {
      'name': 'plan.outside-library-root',
      'passed': !plan.root.contains('${libraryRoot.replaceAll('\\', '/')}/')
          ? true
          : !comicName.isEmpty,
      'detail': 'root=${plan.root}',
    },
  ];
  for (final check in checks) {
    cliPrint({'status': 'running', 'message': 'Export check', 'data': check});
  }
  final passed = checks.every((c) => c['passed'] == true);

  // `--publish` turns the dry run into the real thing, so the acceptance pass
  // exercises the exact code the studio's toolbar button runs — registration and
  // collection included — instead of a look-alike.
  Map<String, Object?>? publishResult;
  if (passed && args.contains('--publish')) {
    String? sourceComicId;
    if (LocalManager().isInitialized) {
      for (final comic in LocalManager().getComics(LocalSortType.defaultSort)) {
        // A `bt_` row is the editable project, not the original artwork, so it
        // must not be picked as the collection's source member.
        if (comic.id.startsWith(FinishedExport.btProjectIdPrefix)) continue;
        if (comic.directory.replaceAll('\\', '/') == project.directory) {
          sourceComicId = comic.id;
          break;
        }
      }
    }
    final report = await FinishedExport.publish(
      project: project,
      translatedRoot: translatedRoot,
      comicName: comicName,
      sourceComicId: sourceComicId,
    );
    publishResult = {
      'directory': report.directory,
      'copied': report.copied,
      'missing': report.missing,
      'chapters': report.chapters,
      'comicId': report.comicId,
      'collectionId': report.collectionId,
      'error': report.error,
    };
    // `ComicCollectionStore._write` persists through `appdata.saveData()`
    // without awaiting it, so a command that exits straight afterwards drops the
    // collection on the floor. The library row lands (SQLite writes inline),
    // which makes the loss easy to miss — flush before reporting.
    await appdata.saveData();
    cliPrint({'status': 'running', 'message': 'Published', 'data': publishResult});
  }

  final jsonIndex = args.indexOf('--json');
  final outPath = jsonIndex != -1 && jsonIndex + 1 < args.length
      ? args[jsonIndex + 1]
      : '${Directory.current.path}/s7_export_check.json';
  final output = File(outPath);
  if (!output.parent.existsSync()) {
    await output.parent.create(recursive: true);
  }
  await output.writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'version': 1,
      'validator': 'S7 FinishedExport plan',
      'file': file.path,
      'passed': passed,
      'plan': plan.toJson(),
      'checks': checks,
      if (publishResult != null) 'publish': publishResult,
    }),
    encoding: utf8,
  );
  cliPrint({
    'status': passed ? 'success' : 'error',
    'message': 'Finished export check ${passed ? 'PASS' : 'FAIL'} '
        '(${checks.where((c) => c['passed'] == true).length}/${checks.length})',
    'data': {'file': file.path, 'report': output.path},
  });
  Log.info('ExportCheck', 'plan=${plan.toJson()} checks=$checks');
  exit(passed ? 0 : 1);
}

/// Every chapter's page numbers must start at 1 and increase by one, otherwise
/// a missing `result/` page would silently shift the rest of the chapter.
///
/// The **paths** are checked too, not just the ordinals: an off-by-one between
/// the counter and the file name is invisible to a counter-only assertion (the
/// items still read 1, 2, 3 …) yet puts page 1 at `0.png` and orphans the last
/// page. That regression actually happened here, so the assertion stays.
bool _numberingIsContinuous(FinishedExportPlan plan) {
  final byChapter = <String, List<FinishedExportItem>>{};
  for (final item in plan.items) {
    byChapter.putIfAbsent(item.chapter, () => []).add(item);
  }
  if (byChapter.isEmpty) return false;
  for (final items in byChapter.values) {
    for (var i = 0; i < items.length; i++) {
      final ordinal = i + 1;
      if (items[i].ordinal != ordinal) return false;
      if (!items[i].target.endsWith('/${items[i].chapter}/$ordinal.png')) {
        return false;
      }
    }
  }
  return true;
}

/// `venera.exe --headless download-check <comicId> [options]`
///
/// 走**真实下载链路**跑一章（每章一个任务 → 多轮渐进超时），把每轮的超时
/// 预算、成功/缺页数、耗时、是否疑似主机封锁打印出来。
///
/// 为什么需要它：多轮渐进超时（5→10→15→30s）此前只能在 GUI 里肉眼盯状态栏
/// 验证，CI/命令行无法回归。下载腿一直没有 headless 入口，这是补齐。
///
/// 选项：
/// - `--source <key>`      源 key，默认 `comix_to`
/// - `--chapter <key>`     只下这一章（chapterKey / 话号）。省略则取第一章
/// - `--group <name>`      指定翻译组（如 DivaScans）。省略取第一个版本
/// - `--clean`             开跑前清空残留任务队列（见 [LocalManager.dropAllTaskRecords]）
/// - `--timeout <sec>`     整条命令的墙钟上限，默认 900
/// - `--json <out.json>`   报告落盘路径
Future<void> runDownloadCheck(List<String> args, int commandIndex) async {
  final candidate = commandIndex + 1 < args.length
      ? args[commandIndex + 1]
      : null;
  final target = candidate == null || candidate.startsWith('--')
      ? null
      : candidate;
  if (target == null || target.isEmpty) {
    cliPrint({
      'status': 'error',
      'message': 'download-check needs a comic id.',
    });
    exit(1);
  }

  String argOr(String flag, String fallback) {
    final i = args.indexOf(flag);
    return i != -1 && i + 1 < args.length ? args[i + 1] : fallback;
  }

  // 残留任务会占满并发槽位，让本任务排不上队、只能干等墙钟超时。命令行没有
  // GUI 那样手动清队列的途径，所以提供 --clean。注意这**不删已下载的页**。
  var droppedStale = 0;
  if (args.contains('--clean')) {
    droppedStale = LocalManager().downloadingTasks.length;
    LocalManager().dropAllTaskRecords();
    cliPrint({
      'status': 'running',
      'message': 'Cleared stale download queue',
      'data': {'droppedTasks': droppedStale},
    });
  }

  final sourceKey = argOr('--source', 'comix_to');
  final chapterFilter = args.contains('--chapter')
      ? argOr('--chapter', '')
      : null;
  final wallClock = int.tryParse(argOr('--timeout', '900')) ?? 900;
  final jsonIndex = args.indexOf('--json');
  final outPath = jsonIndex != -1 && jsonIndex + 1 < args.length
      ? args[jsonIndex + 1]
      : '${Directory.current.path}/download_check.json';

  final source = ComicSource.find(sourceKey);
  if (source == null) {
    cliPrint({
      'status': 'error',
      'message': 'Comic source not found: $sourceKey',
    });
    exit(1);
  }

  cliPrint({
    'status': 'running',
    'message': 'Resolving comic details',
    'data': {'comicId': target, 'source': sourceKey},
  });

  // 章节 key 决定下载目录（带组形态），所以先把详情拉出来再选章。
  final loadInfo = source.loadComicInfo;
  if (loadInfo == null) {
    cliPrint({
      'status': 'error',
      'message': 'Source does not support loading comic info: $sourceKey',
    });
    exit(1);
  }
  final info = await loadInfo(target);
  if (info.error) {
    cliPrint({
      'status': 'error',
      'message': 'Failed to load comic info: ${info.errorMessage}',
    });
    exit(1);
  }
  final details = info.data;
  final allKeys = details.chapters?.allVersionKeys.toList() ??
      details.chapters?.ids.toList() ??
      const <String>[];
  if (allKeys.isEmpty) {
    cliPrint({
      'status': 'error',
      'message': 'Comic has no chapters; download-check needs a chaptered comic.',
    });
    exit(1);
  }
  // allKeys 非空即说明 chapters 非空，这里固定成非空类型供下面按话号/组取 key。
  final chapters = details.chapters!;

  // 选章：显式 --chapter 优先（支持话号或完整 key），否则取第一章。
  // --group 可指定翻译组（如 DivaScans）——comix.to 每话有多个组，key 互不相同，
  // 不指定就取第一个版本（通常是 Asura，宿主正常、测不出轮换域封锁）。
  final groupArg = args.contains('--group') ? argOr('--group', '') : '';
  List<String> selected;
  if (chapterFilter != null && chapterFilter.isNotEmpty) {
    // 该话号的全部版本 key。
    List<String> keysOfNumber;
    if (chapters.allVersionKeys.contains(chapterFilter)) {
      keysOfNumber = [chapterFilter];
    } else {
      keysOfNumber = allKeys.where((k) {
        final entry = chapters.versionEntryOf(k);
        return entry != null && entry.chapterNumber.toString() == chapterFilter;
      }).toList();
    }
    if (keysOfNumber.isEmpty) {
      cliPrint({
        'status': 'error',
        'message': 'Chapter not found: $chapterFilter '
            '(available: ${allKeys.take(8).join(", ")}...)',
      });
      exit(1);
    }
    if (groupArg.isNotEmpty) {
      selected = keysOfNumber.where((k) {
        final g = chapters.versionEntryOf(k)?.version.scanlationGroup ?? '';
        return g.toLowerCase() == groupArg.toLowerCase();
      }).toList();
      if (selected.isEmpty) {
        final groups = {
          for (final k in keysOfNumber)
            chapters.versionEntryOf(k)?.version.scanlationGroup ?? '(none)',
        };
        cliPrint({
          'status': 'error',
          'message': 'Group not found: $groupArg (available: ${groups.join(", ")})',
        });
        exit(1);
      }
    } else {
      selected = [keysOfNumber.first];
    }
  } else {
    selected = [allKeys.first];
  }

  cliPrint({
    'status': 'running',
    'message': 'Starting download',
    'data': {
      'comicId': target,
      'title': details.title,
      'chapters': selected,
      'totalChaptersInComic': allKeys.length,
    },
  });

  final task = ImagesDownloadTask(
    source: source,
    comicId: target,
    comic: details,
    chapters: selected,
    comicTitle: details.title,
    comicCover: details.cover,
  );

  final started = DateTime.now();
  // 逐轮快照：观察多轮渐进超时真的按 5→10→15→30 走。
  final snapshots = <Map<String, dynamic>>[];
  var lastRound = -1;
  void captureSnapshot() {
    final snap = task.debugSnapshot();
    if (snap['round'] != lastRound) {
      lastRound = snap['round'] as int;
      snapshots.add(Map<String, dynamic>.from(snap));
      cliPrint({'status': 'running', 'message': 'Round', 'data': snap});
    }
  }

  // 任务自身会 notifyListeners；这里轮询快照即可，无需挂 UI。
  final timer = Timer.periodic(
    const Duration(milliseconds: 500),
    (_) => captureSnapshot(),
  );

  // 交给队列跑（走 LocalManager 的正式调度，和 GUI 同一条路）。
  LocalManager().addTask(task);

  // 等任务离开队列（completeTask / 出错都会移除）。
  final deadline = DateTime.now().add(Duration(seconds: wallClock));
  while (DateTime.now().isBefore(deadline)) {
    await Future.delayed(const Duration(milliseconds: 500));
    if (!LocalManager().downloadingTasks.contains(task)) break;
  }
  timer.cancel();
  final finished = DateTime.now();
  final finalSnap = task.debugSnapshot();
  snapshots.add(Map<String, dynamic>.from(finalSnap));

  final timedOut = LocalManager().downloadingTasks.contains(task);
  if (timedOut) {
    // 别把任务留在队列里影响下次运行。
    LocalManager().removeTask(task);
  }

  final elapsedMs = finished.difference(started).inMilliseconds;
  final missing = (finalSnap['missing'] as num?)?.toInt() ?? 0;
  final downloaded = (finalSnap['downloaded'] as num?)?.toInt() ?? 0;
  final total = (finalSnap['total'] as num?)?.toInt() ?? 0;
  // 判定：要么全下完，要么至少下到一些页（部分完成）且没超时，都算链路健康。
  final passed = !timedOut && (finalSnap['error'] != true) && downloaded > 0;

  final report = {
    'version': 1,
    'command': 'download-check',
    'comicId': target,
    'title': details.title,
    'source': sourceKey,
    'chapters': selected,
    'passed': passed,
    'timedOut': timedOut,
    'droppedStaleTasks': droppedStale,
    'elapsedMs': elapsedMs,
    'downloaded': downloaded,
    'total': total,
    'missing': missing,
    'hostBlocked': finalSnap['hostBlocked'],
    'final': finalSnap,
    'rounds': snapshots,
  };
  final output = File(outPath);
  if (!output.parent.existsSync()) {
    await output.parent.create(recursive: true);
  }
  await output.writeAsString(
    const JsonEncoder.withIndent('  ').convert(report),
    encoding: utf8,
  );
  cliPrint({
    'status': passed ? 'success' : 'error',
    'message': passed
        ? 'Download check PASS ($downloaded/$total pages, '
            '$missing missing, ${elapsedMs}ms)'
        : timedOut
        ? 'Download check TIMEOUT after ${wallClock}s'
        : 'Download check FAIL ($downloaded/$downloaded, missing=$missing)',
    'data': {'report': output.path, 'summary': finalSnap},
  });
  Log.info('DownloadCheck', 'elapsedMs=$elapsedMs summary=$finalSnap');
  exit(passed ? 0 : 1);
}

/// `venera.exe --headless comix-spike --comic <comicId> [options]`
/// `venera.exe --headless comix-spike <imageUrl> [options]`
///
/// 对被封锁的图片按多种取字节策略依次尝试，输出对照报告。纯诊断，不改
/// 生产取图路径。用于判定 Diva 组 `*.site` 轮换域 403 到底哪条策略能过。
///
/// 两种输入：
/// - `<imageUrl>`：直接给一张图的 URL。
/// - `--comic <id>`：**自动取新鲜 URL**（推荐）。轮换域图片是**单次签名、
///   会过期**的 URL（日志里捞回来的老 URL 一律 404），拿旧 URL 测不出封锁
///   效果——必须现场从章节接口取。
///
/// 选项：
/// - `--source <key>`    源 key，默认 `comix_to`
/// - `--chapter <n>`     取第几话（默认最后一话，通常最新）
/// - `--sample <n>`      取该话前几张图分别测，默认 2
/// - `--timeout <sec>`   单张图策略预算，默认 40
/// - `--json <out.json>` 报告落盘路径
Future<void> runComixSpike(List<String> args, int commandIndex) async {
  String argOr(String flag, String fallback) {
    final i = args.indexOf(flag);
    return i != -1 && i + 1 < args.length ? args[i + 1] : fallback;
  }

  final candidate = commandIndex + 1 < args.length
      ? args[commandIndex + 1]
      : null;
  final directUrl = candidate == null || candidate.startsWith('--')
      ? null
      : candidate;
  final comicArg = args.contains('--comic') ? argOr('--comic', '') : '';
  if ((directUrl == null || directUrl.isEmpty) && comicArg.isEmpty) {
    cliPrint({
      'status': 'error',
      'message': 'comix-spike needs an image url or --comic <comicId>.',
    });
    exit(1);
  }

  final sourceKey = argOr('--source', 'comix_to');
  final timeout = int.tryParse(argOr('--timeout', '40')) ?? 40;
  final sample = int.tryParse(argOr('--sample', '2')) ?? 2;
  final jsonIndex = args.indexOf('--json');
  final outPath = jsonIndex != -1 && jsonIndex + 1 < args.length
      ? args[jsonIndex + 1]
      : '${Directory.current.path}/comix_spike.json';

  // ---- 收集待测 URL ----
  final urls = <String>[];
  var chapterLabel = '';
  final chapterArg = args.contains('--chapter') ? argOr('--chapter', '') : '';
  if (comicArg.isNotEmpty) {
    final source = ComicSource.find(sourceKey);
    if (source == null) {
      cliPrint({
        'status': 'error',
        'message': 'Comic source not found: $sourceKey',
      });
      exit(1);
    }
    final loadInfo = source.loadComicInfo;
    final loadPages = source.loadComicPages;
    if (loadInfo == null || loadPages == null) {
      cliPrint({
        'status': 'error',
        'message': 'Source cannot load info/pages: $sourceKey',
      });
      exit(1);
    }
    cliPrint({
      'status': 'running',
      'message': 'Resolving comic details',
      'data': {'comicId': comicArg, 'source': sourceKey},
    });
    final info = await loadInfo(comicArg);
    if (info.error) {
      cliPrint({
        'status': 'error',
        'message': 'Failed to load comic info: ${info.errorMessage}',
      });
      exit(1);
    }
    final chapters = info.data.chapters;
    final keys = chapters?.allVersionKeys.toList() ??
        chapters?.ids.toList() ??
        const <String>[];
    if (keys.isEmpty) {
      cliPrint({
        'status': 'error',
        'message': 'Comic has no chapters.',
      });
      exit(1);
    }
    // 章节号升序（用户定案），"最后一话"= 最新话。
    String picked;
    if (chapterArg.isNotEmpty) {
      picked = keys.firstWhere(
        (k) => (chapters?.versionEntryOf(k)?.chapterNumber) == chapterArg,
        orElse: () => keys.last,
      );
    } else {
      picked = keys.last;
    }
    final entry = chapters?.versionEntryOf(picked);
    chapterLabel = entry == null
        ? picked
        : '${entry.chapterNumber} [${entry.version.scanlationGroup ?? picked}]';
    cliPrint({
      'status': 'running',
      'message': 'Fetching fresh image urls',
      'data': {'chapter': chapterLabel, 'chapterKey': picked},
    });
    final pages = await loadPages(comicArg, picked);
    if (pages.error) {
      cliPrint({
        'status': 'error',
        'message': 'Failed to load pages: ${pages.errorMessage}',
      });
      exit(1);
    }
    urls.addAll(pages.data.take(sample));
    if (urls.isEmpty) {
      cliPrint({'status': 'error', 'message': 'Chapter has no pages.'});
      exit(1);
    }
  } else {
    urls.add(directUrl!);
  }

  // ---- 逐张跑策略 ----
  final allResults = <Map<String, dynamic>>[];
  for (var i = 0; i < urls.length; i++) {
    final url = urls[i];
    cliPrint({
      'status': 'running',
      'message': 'Spiking image strategies',
      'data': {
        'index': '${i + 1}/${urls.length}',
        'url': url,
        'timeoutSeconds': timeout,
      },
    });
    final results = await ComixClient.spikeImageStrategies(
      url,
      timeoutSeconds: timeout,
    );
    for (final r in results) {
      cliPrint({
        'status': 'running',
        'message': 'Strategy',
        'data': {'url': url, ...r},
      });
      allResults.add({'url': url, ...r});
    }
  }

  // 判定：任一策略拿到字节即说明封锁可绕。
  final winners = <String>{};
  final byStrategy = <String, int>{};
  for (final r in allResults) {
    final name = r['strategy'] as String;
    final ok = r['ok'] == true;
    byStrategy[name] = (byStrategy[name] ?? 0) + (ok ? 1 : 0);
    if (ok) winners.add(name);
  }
  final anyOk = winners.isNotEmpty;

  final report = {
    'version': 1,
    'command': 'comix-spike',
    'comicId': comicArg.isEmpty ? null : comicArg,
    'chapter': chapterLabel,
    'urlsTested': urls.length,
    'anyStrategyWorked': anyOk,
    'winningStrategies': winners.toList(),
    'perStrategySuccessCount': byStrategy,
    'results': allResults,
  };
  final output = File(outPath);
  if (!output.parent.existsSync()) {
    await output.parent.create(recursive: true);
  }
  await output.writeAsString(
    const JsonEncoder.withIndent('  ').convert(report),
    encoding: utf8,
  );
  cliPrint({
    'status': anyOk ? 'success' : 'error',
    'message': anyOk
        ? 'Spike FOUND working strategy: ${winners.join(", ")}'
        : 'Spike: no strategy worked on ${urls.length} url(s) '
            '(per-strategy: $byStrategy)',
    'data': {'report': output.path},
  });
  Log.info('ComixSpike', 'anyOk=$anyOk winner=$winners perStrategy=$byStrategy');
  exit(anyOk ? 0 : 1);
}

/// `venera.exe --headless studio-scan [--json out.json]`
///
/// Rescans `btProjectRoot` and reports, per FT project, **why** it was
/// registered or skipped.
///
/// 🔴 Why this exists: `BtProjectManager.scan` used to `continue` past a
/// project whose pages it could not resolve, with no log line and no other
/// trace. When the raw comic folder of a project was deleted, the studio list
/// simply came up empty — indistinguishable from "the tab is broken". Any
/// future silent drop should be caught here rather than by a user report.
Future<void> runStudioScan(List<String> args, int commandIndex) async {
  final jsonIndex = args.indexOf('--json');
  final outPath = jsonIndex != -1 && jsonIndex + 1 < args.length
      ? args[jsonIndex + 1]
      : '${Directory.current.path}/studio_scan.json';

  final roots = BtProjectManager.roots;
  cliPrint({
    'status': 'running',
    'message': 'Scanning BT project roots',
    'data': {
      'roots': roots,
      'enabled': BtProjectManager.isEnabled,
    },
  });
  if (roots.isEmpty) {
    cliPrint({
      'status': 'error',
      'message': 'btProjectRoot is empty; the studio is disabled. '
          'Set it in Settings > Data.',
    });
    exit(1);
  }

  await BtProjectManager().scan();

  final comics = LocalManager().isInitialized
      ? LocalManager()
          .getComics(LocalSortType.defaultSort)
          .where((c) => BtProjectManager.isBtComic(c.id))
          .toList()
      : <LocalComic>[];

  final rows = <Map<String, Object?>>[];
  for (final comic in comics) {
    final project = BtProjectManager().projectFor(comic.id);
    var pages = 0;
    var blocks = 0;
    var fromOriginal = 0;
    var fromArtifact = 0;
    String? sample;
    if (project != null) {
      for (final key in project.pageOrder) {
        final resolved = project.displayPath(key);
        if (resolved == null) continue;
        pages++;
        blocks += project.regionsFor(key).length;
        if (project.originalPath(key) == resolved) {
          fromOriginal++;
        } else {
          fromArtifact++;
          sample ??= resolved;
        }
      }
    }
    rows.add({
      'id': comic.id,
      'title': comic.title,
      'json': project?.jsonFile.path ?? comic.directory,
      'pages': pages,
      'blocks': blocks,
      'pagesFromOriginal': fromOriginal,
      'pagesFromArtifact': fromArtifact,
      'artifactSample': sample,
    });
  }

  final report = {
    'version': 1,
    'command': 'studio-scan',
    'roots': roots,
    'registeredCount': rows.length,
    'projects': rows,
  };
  final output = File(outPath);
  if (!output.parent.existsSync()) {
    await output.parent.create(recursive: true);
  }
  await output.writeAsString(
    const JsonEncoder.withIndent('  ').convert(report),
    encoding: utf8,
  );
  for (final row in rows) {
    cliPrint({'status': 'running', 'message': 'Project', 'data': row});
  }
  cliPrint({
    'status': rows.isEmpty ? 'error' : 'success',
    'message': rows.isEmpty
        ? 'No FT project registered. Check the log for "Skipped" warnings.'
        : 'Studio scan found ${rows.length} project(s)',
    'data': {'report': output.path},
  });
  Log.info('StudioScan', 'registered=${rows.length}');
  exit(rows.isEmpty ? 1 : 0);
}

/// `venera.exe --headless page-reconcile <comicId> [--source comix_to] [--json out.json]`
///
/// 用磁盘现状对账 `missing_pages.json`：把"下载账本漏记的缺页"补记出来，并清掉
/// 已经补回来的陈旧条目。
///
/// 🔴 为什么需要它：缺页表此前只在下载任务的**末轮**才落盘
/// （`ImagesDownloadTask._roundTimeouts` 第 4 轮）。任何在末轮之前被取消 / 崩溃
/// 的运行，整章失败页会**既不在磁盘、也不在表里、更没有红色标记**。实测
/// `My Dragon Girlfriend Has Returned / 6 [DivaScans]`：源侧 177 页，磁盘只有
/// 145 个文件、32 个空洞（33/41/…/175），而表里只有 index 5 一条 —— UI 因此
/// 显示"已下载完成"，用户点一次"修复"也只补回 index 5。这条命令把那起事故
/// 变成可回归的断言。
///
/// 选项：
/// - `--source <key>`     源 key（用于在库里唯一定位），省略则按 comicId 匹配
/// - `--json <out.json>`  报告落盘路径
Future<void> runPageReconcile(List<String> args, int commandIndex) async {
  final candidate = commandIndex + 1 < args.length
      ? args[commandIndex + 1]
      : null;
  final target = candidate == null || candidate.startsWith('--')
      ? null
      : candidate;
  final jsonIndex = args.indexOf('--json');
  final outPath = jsonIndex != -1 && jsonIndex + 1 < args.length
      ? args[jsonIndex + 1]
      : '${Directory.current.path}/page_reconcile.json';
  final sourceIndex = args.indexOf('--source');
  final sourceKey = sourceIndex != -1 && sourceIndex + 1 < args.length
      ? args[sourceIndex + 1]
      : null;

  if (target == null || target.isEmpty) {
    cliPrint({
      'status': 'error',
      'message': 'page-reconcile needs a comic id.',
    });
    exit(1);
  }
  if (!LocalManager().isInitialized) {
    cliPrint({
      'status': 'error',
      'message': 'Local library is not initialized.',
    });
    exit(1);
  }

  LocalComic? found;
  for (final c in LocalManager().getComics(LocalSortType.defaultSort)) {
    if (c.id != target) continue;
    if (sourceKey != null && c.sourceKey != sourceKey) continue;
    found = c;
    break;
  }
  if (found == null) {
    cliPrint({
      'status': 'error',
      'message': 'Comic not found in the local library: $target'
          '${sourceKey == null ? '' : ' (source: $sourceKey)'}',
    });
    exit(1);
  }
  // 绑定成 final 非空局部量：下面的闭包（`registered` 判定）捕获它时，
  // 可空局部变量在闭包里不会保持类型提升，会报
  // `unchecked_use_of_nullable_value`。
  final comic = found;

  final before = MissingPages.peek(comic.baseDir)?.count ?? 0;
  final registeredBefore = comic.downloadedChapters.toSet();
  // 扫描磁盘上的章节目录（与 `LocalManager.reconcileMissingPages` 同口径）：
  // 目录名本身就是缺页表的 chapterId，不需要章节矩阵反推，所以未登记的
  // 半截目录（下载中途取消）同样能被列出。
  final rootDir = Directory(comic.baseDir);
  final rows = <Map<String, Object?>>[];
  if (rootDir.existsSync()) {
    for (final entity in rootDir.listSync()) {
      if (entity is! Directory) continue;
      // ⚠️ 不能用 `entity.uri.pathSegments.last`：目录 URI **必带结尾斜杠**，
      // 最后一段是空串（于是每个目录都被下面的 `isEmpty` 跳过 → 报告恒为空），
      // 而且真实名字是百分号编码的。用扩展的 `name`（＝`p.basename(path)`）。
      final dirName = entity.name;
      if (dirName.isEmpty || dirName.startsWith('.')) continue;
      final present = <int>{};
      for (final file in entity.listSync()) {
        if (file is! File) continue;
        final name = file.uri.pathSegments.last;
        final dot = name.indexOf('.');
        if (dot <= 0) continue;
        final idx = int.tryParse(name.substring(0, dot));
        if (idx != null) present.add(idx);
      }
      if (present.isEmpty) continue;
      var maxIndex = 0;
      for (final v in present) {
        if (v > maxIndex) maxIndex = v;
      }
      rows.add({
        'chapter': dirName,
        'pagesOnDisk': present.length,
        'maxIndex': maxIndex,
        'gaps': pageIndexGaps(present),
        'registeredBefore': comic.downloadedChapters.any(
          (k) => chapterDirectoryName(comic.chapters, k) == dirName,
        ),
      });
    }
  }

  final added = await LocalManager().reconcileMissingPages(comic);
  // 同一次扫描的另一半：磁盘上存在、但 `downloadedChapters` 里没有的章节
  // （半截下载 / 修复补完）会被登记进去 —— 这正是"磁盘有文件、下载页说未下载"
  // 那个冲突的修复点。
  final registered = await LocalManager().reconcileDownloadedChapters(comic);
  final refreshed = LocalManager().find(comic.id, comic.comicType);
  final registeredAfter = refreshed?.downloadedChapters.toSet() ?? registeredBefore;
  final newlyRegistered = [
    for (final k in registeredAfter)
      if (!registeredBefore.contains(k))
        {
          'key': k,
          'chapter': chapterDirectoryName(refreshed?.chapters, k),
        },
  ];
  for (final row in rows) {
    row['registeredAfter'] = registeredAfter.any(
      (k) => chapterDirectoryName(refreshed?.chapters, k) == row['chapter'],
    );
  }
  final table = MissingPages.peek(comic.baseDir);
  final report = {
    'version': 1,
    'command': 'page-reconcile',
    'comicId': comic.id,
    'title': comic.title,
    'source': comic.sourceKey,
    'baseDir': comic.baseDir,
    'missingBefore': before,
    'missingAfter': table?.count ?? 0,
    'newlyRecorded': added,
    'downloadedBefore': registeredBefore.length,
    'downloadedAfter': registeredAfter.length,
    'newlyRegistered': newlyRegistered,
    'chapters': rows,
    'entries': [
      for (final e in (table?.entries ?? const <MissingPageEntry>[]))
        {
          'chapter': e.chapterId,
          'index': e.index,
          'hasUrl': e.url.trim().isNotEmpty,
          'error': e.error,
        },
    ],
  };
  final output = File(outPath);
  if (!output.parent.existsSync()) {
    await output.parent.create(recursive: true);
  }
  await output.writeAsString(
    const JsonEncoder.withIndent('  ').convert(report),
    encoding: utf8,
  );
  for (final row in rows) {
    cliPrint({'status': 'running', 'message': 'Chapter', 'data': row});
  }
  cliPrint({
    'status': 'success',
    'message': 'Page reconcile: $before -> ${table?.count ?? 0} '
        'missing page(s) ($added newly recorded), '
        '${registeredBefore.length} -> ${registeredAfter.length} '
        'downloaded chapter(s) ($registered newly registered)',
    'data': {'report': output.path},
  });
  Log.info(
    'PageReconcile',
    "${comic.title}: before=$before after=${table?.count ?? 0} added=$added "
        'chapters=${rows.length} registered=$registered',
  );
  exit(0);
}

/// `venera.exe --headless edit-check <project.json> [--json out.json]`
///
/// Exercises the S8 editing layer end to end **without a window**: it loads a
/// real project into a copy, performs a text / move / font-size edit through the
/// [EditHistory] command stack, checks that undo and redo restore both states
/// exactly, saves the copy with the unified save contract, reloads it, and
/// confirms the edit (translation, box, regenerated `rich_text`) survived.
///
/// 🔴 Why not verify "the canvas drags" here: gestures need a window and a real
/// pointer, so the GUI half of S8 (long-canvas scrolling, dragging) is verified
/// by hand. What this command pins down is the part that is easy to get quietly
/// wrong — command reversibility, `rich_text` synchronisation, and the byte
/// stability of a save/reload cycle.
Future<void> runEditCheck(List<String> args, int commandIndex) async {
  final jsonIndex = args.indexOf('--json');
  final outPath = jsonIndex != -1 && jsonIndex + 1 < args.length
      ? args[jsonIndex + 1]
      : '${Directory.current.path}/edit_check.json';

  final candidate = commandIndex + 1 < args.length &&
          !args[commandIndex + 1].startsWith('--')
      ? args[commandIndex + 1]
      : null;
  final checks = <Map<String, Object?>>[];
  void check(String name, bool passed, String detail) =>
      checks.add({'name': name, 'passed': passed, 'detail': detail});

  Future<void> finish(bool passed, String message) async {
    final report = {
      'version': 1,
      'command': 'edit-check',
      'passed': passed,
      'file': candidate,
      'checks': checks,
    };
    final output = File(outPath);
    if (!output.parent.existsSync()) {
      await output.parent.create(recursive: true);
    }
    await output.writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
      encoding: utf8,
    );
    for (final entry in checks) {
      cliPrint({'status': 'running', 'message': 'Check', 'data': entry});
    }
    cliPrint({
      'status': passed ? 'success' : 'error',
      'message': message,
      'data': {'report': output.path},
    });
  }

  if (candidate == null) {
    await finish(false, 'Usage: --headless edit-check <project.json> [--json out]');
    exit(1);
  }
  final source = File(candidate);
  if (!source.existsSync()) {
    await finish(false, 'Project not found: $candidate');
    exit(1);
  }

  var passed = false;
  final original = await TranslationProjectIo.load(source);

  // Prefer a page that already carries a translated block. When the project
  // has none — an empty fixture, or a chapter the pipeline has not touched yet
  // — seed one through the very same factory the studio's "new block" button
  // uses, so the checks below still exercise real FT-shaped JSON.
  //
  // 🔴 This used to hard-fail with 'no translated block in the project'. That
  // made the *empty* case untestable, which is exactly the state S9's automatic
  // pipeline works from: P0-2 lifts detected regions into blocks on a page that
  // has none. Bootstrapping here also means `TextBlock.createDefault` is
  // exercised by every run, so a regression in its key set cannot pass quietly.
  var seeded = false;
  String? pageKey;
  var blockIndex = -1;
  for (final key in original.pageOrder) {
    final page = original.pages[key];
    if (page == null) continue;
    final index = page.blocks.indexWhere((b) => b.hasTranslation);
    if (index >= 0) {
      pageKey = key;
      blockIndex = index;
      break;
    }
  }
  if (pageKey == null) {
    final firstKey = original.pageOrder.isEmpty
        ? null
        : original.pageOrder.first;
    final page = firstKey == null ? null : original.pages[firstKey];
    if (page == null) {
      check('fixture.block', false, 'project has no pages at all');
      await finish(false, 'Project has no page to edit.');
      exit(1);
    }
    pageKey = firstKey;
    blockIndex = 0;
    seeded = true;
  }
  // 🔴 A non-nullable alias: `pageKey` is a `String?` that Dart only promotes
  // along straight-line flow, so the closures below (which run long after the
  // check) would not see the promotion and every `pageKey:` argument would be
  // an error. One alias here beats `!` sprinkled over every use.
  final targetPageKey = pageKey!;
  check(
    'fixture.block',
    true,
    seeded
        ? '$targetPageKey (seeded via TextBlock.createDefault — project had none)'
        : '$targetPageKey #${blockIndex + 1}',
  );

  final tempRoot = await Directory.systemTemp.createTemp('vene_edit_');
  try {
    // Work on a deep copy so a failed run cannot touch the user's project, and
    // save it under a throwaway root rather than beside the original.
    final project = original.copy(
      jsonFile: File('${tempRoot.path}/${original.jsonFileName}'),
    );
    final history = EditHistory();
    if (seeded) {
      // Give the seeded block a translation so `translatedBlocks` and the
      // renderer treat it like any other lettered block from here on.
      final page = project.pages[targetPageKey]!;
      final block = TextBlock.createDefault(
        rect: IntRect(120, 240, 440, 304),
      );
      page.addBlock(block);
      block.translation = 'seed';
      syncFtRichText(block);
    }
    final block = project.pages[targetPageKey]!.blocks[blockIndex];
    final originalRaw = deepCopyJsonMap(block.raw);
    final originalTranslation = block.translation;
    final originalSize = block.fontFormat?.fontSize ?? 0;

    // 1) translation edit (+ rich_text sync — the decisive blocker).
    history.push(
      captureBlockEdit(
        block.raw,
        () {
          block.translation = '$originalTranslation [edited]';
          syncFtRichText(block);
        },
        pageKey: targetPageKey,
        label: 'Translation',
      ),
    );
    check(
      'edit.rich_text',
      (block.raw['rich_text'] as String? ?? '').contains('[edited]'),
      'rich_text regenerated with the new text',
    );
    check(
      'edit.rich_text.shape',
      (block.raw['rich_text'] as String? ?? '').contains('qrichtext') &&
          (block.raw['rich_text'] as String? ?? '').contains('pt;'),
      'Qt richtext document shape preserved',
    );

    // 2) move.
    final movedBox = [
      for (final value in block.xyxy) value + 5,
    ];
    history.push(
      captureBlockEdit(
        block.raw,
        () => block.xyxy = movedBox,
        pageKey: targetPageKey,
        label: 'Move block',
      ),
    );

    // 3) font size.
    history.push(
      captureBlockEdit(
        block.raw,
        () {
          block.ensureFontFormat().fontSize = originalSize + 3;
          syncFtRichText(block);
        },
        pageKey: targetPageKey,
        label: 'Font size',
      ),
    );
    check('history.depth', history.undoDepth == 3, 'depth=${history.undoDepth}');
    check('history.dirty', history.isDirty, 'dirty after 3 edits');

    // 🔴 P9.1 §2.1 — dirty-page tracking. All three edits above are on the same
    // page, so the set must contain exactly that page: this is what turns "save
    // 97 pages" into "re-letter one page".
    final dirtyAfterEdits = history.dirtyPages;
    check(
      'dirty.after_edits',
      dirtyAfterEdits.length == 1 && dirtyAfterEdits.contains(targetPageKey),
      'dirtyPages=${dirtyAfterEdits.toList()}',
    );
    // A second page's edit must widen the set (proves it is per-page, not a
    // single "something changed" flag).
    final secondPageKey = original.pageOrder.firstWhere(
      (key) => key != targetPageKey && original.pages[key]!.blocks.isNotEmpty,
      orElse: () => '',
    );
    if (secondPageKey.isNotEmpty) {
      final secondBlock = project.pages[secondPageKey]!.blocks.first;
      history.push(
        captureBlockEdit(
          secondBlock.raw,
          () => secondBlock.translation = '${secondBlock.translation} [x]',
          pageKey: secondPageKey,
          label: 'Translation (other page)',
        ),
      );
      final widened = history.dirtyPages;
      check(
        'dirty.two_pages',
        widened.length == 2 &&
            widened.contains(targetPageKey) &&
            widened.contains(secondPageKey),
        'dirtyPages=${widened.toList()}',
      );
      // Undo it again: the set must shrink back, which is the behaviour an
      // incremental "add on push" implementation gets wrong.
      history.undo();
      final narrowed = history.dirtyPages;
      check(
        'dirty.undo_shrinks',
        narrowed.length == 1 && narrowed.contains(targetPageKey),
        'after undo: ${narrowed.toList()}',
      );
      // The undone edit is on the redo stack, so the project is dirty overall
      // but the *other* page must not be re-rendered.
      check(
        'dirty.undo_keeps_own_page_out',
        !narrowed.contains(secondPageKey),
        'second page must stay out of the render set',
      );
    }

    final editedRaw = deepCopyJsonMap(block.raw);

    // Undo all three; the block must be byte-for-byte its old self.
    history.undo();
    history.undo();
    history.undo();
    check(
      'undo.restores',
      jsonEquals(block.raw, originalRaw),
      'block matches pre-edit JSON after 3 undos',
    );
    check('undo.clean', !history.isDirty, 'dirty=${history.isDirty}');
    check('redo.available', history.canRedo, 'redo stack non-empty');

    // 🔴 The decisive case for dirty tracking: a *fresh* project has an empty
    // undo stack and `_savedIndex == 0`, so undoing every edit lands back on the
    // saved boundary. The dirty set must then be **empty**, not "the pages I
    // undid on". An implementation that adds on push and only forgets on
    // `markSaved` fails exactly here, and would re-render the chapter on the
    // next save for no reason.
    check(
      'dirty.empty_at_saved_boundary',
      history.dirtyPages.isEmpty,
      'dirtyPages=${history.dirtyPages.toList()}',
    );

    // Redo all three; the block must be exactly the edited state again.
    history.redo();
    history.redo();
    history.redo();
    check(
      'redo.reapplies',
      jsonEquals(block.raw, editedRaw),
      'block matches post-edit JSON after 3 redos',
    );
    check('redo.dirty', history.isDirty, 'dirty=${history.isDirty}');
    check(
      'dirty.back_after_redo',
      history.dirtyPages.length == 1 && history.dirtyPages.contains(targetPageKey),
      'redone work must be dirty again: ${history.dirtyPages.toList()}',
    );

    // Unified save contract into the throwaway root.
    final dirtyForSave = history.dirtyPages;
    final report = await ProjectWriter.save(
      root: tempRoot.path,
      project: project,
      keepBackup: true,
    );
    check('save.json', report.jsonFile.existsSync(), report.jsonFile.path);
    check(
      'save.artifacts',
      report.artifactDirectories.length == 3,
      report.artifactDirectories.map((d) => d.split(RegExp(r'[\\/]')).last).join(', '),
    );

    // 🔴 `writeArtifacts`'s `filter` is the whole point of the exercise: a
    // save-driven re-letter must produce **one** artifact, not one per page.
    //
    // `includePhantomPages: true` is required here, not a shortcut: this
    // fixture's original artwork is gone and nothing has been written under the
    // throwaway root yet, so `planArtifacts` would otherwise report **zero**
    // artifacts for every page and the assertion would be vacuous.
    final filteredPlan = ProjectWriter.planArtifacts(
      tempRoot.path,
      project,
      kinds: const {ProjectArtifactKind.result},
      includePhantomPages: true,
      filter: (key) => dirtyForSave.contains(key),
    );
    check(
      'dirty.filter_selects_one',
      filteredPlan.length == 1 && filteredPlan.first.pageKey == targetPageKey,
      'planned=${filteredPlan.map((a) => a.pageKey).toList()}',
    );
    final unfilteredPlan = ProjectWriter.planArtifacts(
      tempRoot.path,
      project,
      kinds: const {ProjectArtifactKind.result},
      includePhantomPages: true,
    );
    check(
      'dirty.full_plan_is_larger',
      unfilteredPlan.length > filteredPlan.length,
      'full=${unfilteredPlan.length} vs dirty=${filteredPlan.length}',
    );

    // Reload and confirm the edit persisted.
    final reloaded = await TranslationProjectIo.load(report.jsonFile);
    final reloadedBlock = reloaded.pages[targetPageKey]!.blocks[blockIndex];
    check(
      'reload.translation',
      reloadedBlock.translation == block.translation,
      reloadedBlock.translation,
    );
    check(
      'reload.box',
      jsonEquals(reloadedBlock.xyxy, block.xyxy),
      reloadedBlock.xyxy.join(', '),
    );
    check(
      'reload.rich_text',
      (reloadedBlock.raw['rich_text'] as String? ?? '').contains('[edited]'),
      'rich_text survived the reload',
    );
    check(
      'reload.font_size',
      (reloadedBlock.fontFormat?.fontSize ?? -1) == originalSize + 3,
      '${reloadedBlock.fontFormat?.fontSize}',
    );

    // A second save of the reloaded model must be byte-identical: proves the
    // edit did not destabilise FT's zero-diff round-trip contract.
    final firstBytes = await report.jsonFile.readAsBytes();
    final report2 = await ProjectWriter.save(
      root: tempRoot.path,
      project: reloaded,
      keepBackup: false,
    );
    final secondBytes = await report2.jsonFile.readAsBytes();
    var sameBytes = firstBytes.length == secondBytes.length;
    if (sameBytes) {
      for (var i = 0; i < firstBytes.length; i++) {
        if (firstBytes[i] != secondBytes[i]) {
          sameBytes = false;
          break;
        }
      }
    }
    check(
      'roundtrip.bytes',
      sameBytes,
      '${firstBytes.length} vs ${secondBytes.length} bytes',
    );

    // ── P9.2 · unsaved-changes guard ──────────────────────────────────────
    // `PopScope` cannot be exercised headlessly (no Navigator), but the
    // registry every imperative leave path consults is plain Dart — and it is
    // where the "one refusal vetoes" and "a throwing guard must not leak an
    // exit" rules live. Those two are the whole safety argument, so they are
    // asserted here rather than left to a manual click-through.
    check(
      'guard.empty_allows',
      !LeaveGuardRegistry.hasGuards,
      'no guard registered after the editor is gone',
    );
    check(
      'guard.empty_request_is_true',
      await LeaveGuardRegistry.requestLeave(),
      'requesting with an empty registry must not block anything',
    );

    final asked = <String>[];
    Future<bool> allowTop() async {
      asked.add('allow');
      return true;
    }

    Future<bool> denyTop() async {
      asked.add('deny');
      return false;
    }

    final allowGuard = allowTop;
    final denyGuard = denyTop;
    LeaveGuardRegistry.add(allowGuard);
    check('guard.has_guards', LeaveGuardRegistry.hasGuards, 'one guard');

    // Registering the same closure twice must not double the stack, or a
    // rebuild that re-runs registration would ask the user twice.
    LeaveGuardRegistry.add(allowGuard);
    asked.clear();
    check(
      'guard.no_duplicate_ask',
      await LeaveGuardRegistry.requestLeave() && asked.length == 1,
      'asked=${asked.length} (expected 1)',
    );

    LeaveGuardRegistry.add(denyGuard);
    asked.clear();
    check(
      'guard.deny_vetoes',
      !await LeaveGuardRegistry.requestLeave(),
      'asked=${asked.join(",")} (deny must be reached)',
    );
    check(
      'guard.lifo_order',
      asked.isNotEmpty && asked.last == 'deny',
      'newest guard is asked first: ${asked.join(",")}',
    );
    check(
      'guard.short_circuits',
      // `allow` must not run once `deny` refused — a later "yes" must not
      // resurrect an exit the user already declined.
      !asked.contains('allow'),
      'asked=${asked.join(",")}',
    );

    LeaveGuardRegistry.remove(denyGuard);
    check(
      'guard.remove_is_scoped',
      await LeaveGuardRegistry.requestLeave(),
      'removing the denying guard re-opens the exit',
    );
    LeaveGuardRegistry.remove(allowGuard);
    check(
      'guard.removed_clean',
      !LeaveGuardRegistry.hasGuards,
      'registry empty again',
    );

    // A guard that throws must read as "stay". Losing an edit because a dialog
    // failed to build is strictly worse than an unexpected extra click.
    final throwingGuard = () async {
      throw StateError('boom');
    };
    LeaveGuardRegistry.add(throwingGuard);
    check(
      'guard.throw_vetoes',
      !await LeaveGuardRegistry.requestLeave(),
      'a throwing guard must not let the screen close',
    );
    LeaveGuardRegistry.remove(throwingGuard);
    check(
      'guard.final_clean',
      !LeaveGuardRegistry.hasGuards && await LeaveGuardRegistry.requestLeave(),
      'no leakage into later checks',
    );

    // --- Create block (P2-6-c / P9.3) ---------------------------------------
    //
    // A created block has to be indistinguishable from a detected one, or a
    // page that mixes both breaks the project's zero-byte-diff guarantee.
    // These assert the *shape*; the studio's placement is checked by eye.
    final createdRect = IntRect(200, 300, 560, 372);
    final created = TextBlock.createDefault(rect: createdRect);
    final createdKeys = created.raw.keys.toList();
    check(
      'create.key_count',
      // FT writes 23 keys per block; fewer means a field was forgotten.
      createdKeys.length == 23,
      '${createdKeys.length} keys: $createdKeys',
    );
    final createdFormat = created.fontFormat;
    check(
      'create.fontformat_keys',
      createdFormat != null && createdFormat.raw.length == 32,
      createdFormat == null
          ? 'no fontformat'
          : '${createdFormat.raw.length} keys',
    );
    check(
      'create.xyxy',
      created.xyxy.length == 4 &&
          created.rect.left == createdRect.left &&
          created.rect.top == createdRect.top &&
          created.rect.width == createdRect.width &&
          created.rect.height == createdRect.height,
      'rect ${created.rect.left},${created.rect.top} '
      '${created.rect.width}x${created.rect.height}',
    );
    check(
      'create.starts_empty',
      created.translation.isEmpty && !created.hasTranslation,
      'translation="${created.translation}"',
    );
    check(
      'create.not_lettered_until_typed',
      created.toTranslatedRegion() == null,
      'an empty block renders nothing (no ghost lettering)',
    );
    // 🔴 The whole point of a default block: typing into it must produce
    // something the renderer accepts, with no missing-field crash on the way.
    created.translation = '你好';
    syncFtRichText(created);
    final createdRegion = created.toTranslatedRegion();
    check(
      'create.renders_after_typing',
      createdRegion != null &&
          createdRegion.text == '你好' &&
          createdRegion.rect.width == createdRect.width,
      createdRegion == null
          ? 'region null after typing'
          : '"${createdRegion.text}" at '
                '${createdRegion.rect.left},${createdRegion.rect.top} '
                '${createdRegion.rect.width}x${createdRegion.rect.height}',
    );
    check(
      'create.rich_text',
      (created.raw['rich_text'] as String? ?? '').contains('qrichtext'),
      'rich_text built on demand',
    );
    // A created block's fields must read back through the typed views exactly
    // like a detected one's, or a page mixing the two renders two ways.
    final createdFont = created.fontFormat!;
    check(
      'create.font_defaults',
      createdFont.fontFamily == FontFormat.defaultFontFamily &&
          createdFont.fontSize == FontFormat.defaultFontSize &&
          createdFont.foregroundColor.join(',') == '0,0,0' &&
          createdFont.backgroundColor.join(',') == '0,0,0',
      '${createdFont.fontFamily} ${createdFont.fontSize} '
      'fg=${createdFont.foregroundColor} bg=${createdFont.backgroundColor}',
    );

    // Create must be **one** undo step and must go through the same list-edit
    // command as delete, so the two cannot drift apart.
    final createHistory = EditHistory();
    final createPage = project.pages[targetPageKey]!;
    final beforeCount = createPage.blocks.length;
    createHistory.push(
      captureBlockListEdit(
        createPage.rawBlocks,
        () => createPage.addBlock(created),
        pageKey: targetPageKey,
        label: 'Create block',
      ),
    );
    check(
      'create.undo_one_step',
      createPage.blocks.length == beforeCount + 1 &&
          createHistory.undoDepth == 1,
      'blocks ${beforeCount} -> ${createPage.blocks.length}, '
      'depth=${createHistory.undoDepth}',
    );
    check(
      'create.dirty_page',
      createHistory.dirtyPages.contains(targetPageKey),
      'dirtyPages=${createHistory.dirtyPages}',
    );
    check(
      'create.undo_restores',
      createHistory.undo() && createPage.blocks.length == beforeCount,
      'blocks back to ${createPage.blocks.length}',
    );
    check(
      'create.clean_after_undo',
      !createHistory.isDirty && createHistory.dirtyPages.isEmpty,
      'dirty=${createHistory.isDirty} pages=${createHistory.dirtyPages}',
    );

    // ── 框选与 8 控制点缩放的几何契约 ──────────────────────────────────
    // These are pure functions, so they are verifiable here — unlike the
    // gestures themselves, which need a real Flutter surface. What is being
    // pinned down is the arithmetic that is easy to get subtly wrong and hard
    // to eyeball: which edge each handle moves, and that no drag can invert or
    // collapse a box (an inverted rect would render its text upside down and
    // write a negative width into FT's `xyxy`).
    const unit = Rect.fromLTRB(0, 0, 100, 100);

    // 🔴 `Rect` has no `toString()`, so interpolating one yields
    // "Instance of 'Rect'" — the assertion still passes, but a failure becomes
    // undiagnosable. Formatting the four edges explicitly is what makes these
    // reports worth reading.
    String fmt(Rect r) => 'L${r.left} T${r.top} R${r.right} B${r.bottom}';

    check(
      'resize.handle_set',
      resizeHandles.length == 8 &&
          resizeHandles.where((h) => h.isCorner).length == 4,
      '${resizeHandles.length} handles, '
      '${resizeHandles.where((h) => h.isCorner).length} corners',
    );

    // Every handle must be **hit-testable at its own centre** — the painter and
    // the hit test derive the position from the same helper, so a mismatch
    // would show handles that cannot be grabbed.
    final handleHitAll = <String>[];
    for (final handle in resizeHandles) {
      final c = resizeHandleBox(unit, handle).center;
      final hit = hitTestResizeHandle(unit, c);
      if (hit != handle) handleHitAll.add('${handle.name}@${c.dx},${c.dy}');
    }
    check(
      'resize.handle_self_hit',
      handleHitAll.isEmpty,
      handleHitAll.isEmpty
          ? 'all 8 handles hit-test to themselves at their own centre'
          : 'mismatched: $handleHitAll',
    );

    // A corner scales both axes with the opposite corner pinned; an edge moves
    // exactly one axis. Getting this wrong is the whole bug class here.
    final corner = applyResize(
      start: unit,
      handle: ResizeHandle.bottomRight,
      delta: Offset(20, 30),
    );
    check(
      'resize.corner_both_axes',
      corner.left == 0 &&
          corner.top == 0 &&
          corner.right == 120 &&
          corner.bottom == 130,
      'bottomRight(+20,+30) -> ${fmt(corner)}',
    );
    final edge = applyResize(
      start: unit,
      handle: ResizeHandle.right,
      delta: Offset(20, 30),
    );
    check(
      'resize.edge_single_axis',
      edge.left == 0 && edge.top == 0 && edge.right == 120 && edge.bottom == 100,
      'right(+20,+30) -> ${fmt(edge)} (y must not move)',
    );
    final leftEdge = applyResize(
      start: unit,
      handle: ResizeHandle.left,
      delta: Offset(15, 30),
    );
    check(
      'resize.left_edge_pins_right',
      leftEdge.left == 15 && leftEdge.right == 100,
      'left(+15) -> ${fmt(leftEdge)} (right must stay 100)',
    );

    // 🔴 Overdrag must clamp, never invert: dragging the right edge 500px past
    // the left one must hit the minimum, not produce a negative width.
    final inverted = applyResize(
      start: unit,
      handle: ResizeHandle.right,
      delta: Offset(500, 0),
    );
    check(
      'resize.no_inversion',
      inverted.width >= 16 && inverted.right > inverted.left,
      'right(+500) -> ${fmt(inverted)}',
    );
    final invertedCorner = applyResize(
      start: unit,
      handle: ResizeHandle.topLeft,
      delta: Offset(500, 500),
    );
    check(
      'resize.no_inversion_corner',
      invertedCorner.width >= 16 &&
          invertedCorner.height >= 16 &&
          invertedCorner.right == 100 &&
          invertedCorner.bottom == 100,
      'topLeft(+500,+500) -> ${fmt(invertedCorner)} '
      '(opposite corner must stay pinned at 100,100)',
    );

    // Marquee normalisation: a drag up/left is the common case and must still
    // produce l<t<r<b, because `xyxy` is stored in that order.
    final upLeft = normalizeMarquee(const Offset(200, 300), const Offset(50, 80));
    check(
      'marquee.normalises_negative_drag',
      upLeft == Rect.fromLTRB(50, 80, 200, 300),
      // `upLeft` is nullable (a too-small drag returns null), and the `!` is
      // safe precisely because the assertion above already proved it non-null.
      'drag(200,300)->(50,80) => ${upLeft == null ? 'null' : fmt(upLeft)}',
    );
    check(
      'marquee.rejects_stray_click',
      normalizeMarquee(const Offset(100, 100), const Offset(102, 101)) == null,
      'a 2x1px drag must not create a block',
    );


    // ── P0-1 字体贯通：桥接层必须真的把 FontFormat 送出去 ──────────────────
    // The failure this guards against is **silent**: a user sets a font in the
    // studio, everything in the UI confirms it, and the exported page comes out
    // in the default face. Nothing errors, so only an explicit assertion can
    // catch a regression.
    final styled = TextBlock.createDefault(rect: IntRect(10, 20, 210, 92));
    styled.raw['translation'] = '字体贯通';
    final format = styled.fontFormat!;
    format.fontFamily = 'Source Han Sans';
    format.fontWeight = 700;
    format.fontSize = 33;
    // Some keys are getter-only on [FontFormat] (they resolve through helper
    // logic), so they are written straight into the authoritative raw map —
    // which is exactly what the panel does.
    format.raw['italic'] = true;
    format.raw['underline'] = true;
    format.alignment = 0;
    format.raw['line_spacing'] = 1.7;
    format.raw['letter_spacing'] = 1.25;
    format.raw['opacity'] = 0.6;
    format.raw['stroke_width'] = 4.0;
    format.raw['shadow_radius'] = 5.0;
    format.raw['gradient_enabled'] = true;
    styled.raw['angle'] = 12.0;

    final styledRegion = styled.toTranslatedRegion();
    final rs = styledRegion?.fontStyle;
    check(
      'font.bridge_attaches_style',
      rs != null,
      rs == null
          ? 'toTranslatedRegion() produced no fontStyle — the bridge is broken'
          : 'attached',
    );
    check(
      'font.carries_all_attributes',
      rs != null &&
          rs.fontFamily == 'Source Han Sans' &&
          rs.fontWeight == 700 &&
          rs.fontSize == 33 &&
          rs.italic &&
          rs.underline &&
          rs.alignment == 0 &&
          rs.lineSpacing == 1.7 &&
          rs.letterSpacing == 1.25 &&
          rs.opacity == 0.6 &&
          rs.strokeWidth == 4.0 &&
          rs.shadowRadius == 5.0 &&
          rs.gradientEnabled &&
          rs.angle == 12.0,
      rs == null
          ? 'no style'
          : 'family=${rs.fontFamily} w=${rs.fontWeight} size=${rs.fontSize} '
                'italic=${rs.italic} underline=${rs.underline} '
                'align=${rs.alignment} line=${rs.lineSpacing} '
                'letter=${rs.letterSpacing} op=${rs.opacity} '
                'stroke=${rs.strokeWidth} shadow=${rs.shadowRadius} '
                'grad=${rs.gradientEnabled} angle=${rs.angle}',
    );

    // 🔴 The compatibility contract: a block with NO fontformat must produce a
    // region with a **null** style, so the renderer keeps its historical
    // hard-coded look. Giving it a style here would silently restyle every
    // already-rendered page in the library.
    final bare = TextBlock.createDefault(rect: IntRect(0, 0, 100, 40));
    bare.raw['translation'] = 'no format';
    bare.raw.remove('fontformat');
    check(
      'font.absent_format_stays_null',
      bare.toTranslatedRegion()?.fontStyle == null,
      'fontStyle=${bare.toTranslatedRegion()?.fontStyle} '
      '(must be null so the legacy path is untouched)',
    );

    // ── i18n：studio 页的 tooltip 必须已登记中文 ─────────────────────────
    // 🔴 `String.tl` looks the key up **verbatim** and falls back to the
    // English source string when it is missing. An unregistered tooltip is
    // therefore not an error, just an English label in an otherwise Chinese
    // UI — exactly how the marquee button ended up reading
    // "Draw box for new block". Nothing else in the toolchain notices, so the
    // gap has to be asserted.
    check(
      'i18n.studio_tooltips_registered',
      _missingStudioTooltips().isEmpty,
      _missingStudioTooltips().isEmpty
          ? 'all studio tooltips have zh_CN entries'
          : 'missing: ${_missingStudioTooltips().join(", ")}',
    );

    // ── P0-2 fromOcr：检测结果 → 可编辑块 ────────────────────────────────
    final ocrBlock = OcrBlock(
      rect: IntRect(120, 240, 480, 520),
      text: 'こんにちは\n世界',
      language: 'ja',
      backgroundColor: 0xFFFFFFFF,
      textColor: 0xFF112233,
      // Tall box => vertical Japanese, which the adapter must record.
      lineHeight: 27,
    );
    final lifted = TextBlock.fromOcr(ocrBlock);

    check(
      'fromOcr.shape_matches_create_default',
      // 🔴 The zero-byte-diff contract: a detected block and a hand-made one
      // must have the **same key set**, or a page mixing them breaks the diff.
      lifted.raw.keys.toSet().containsAll(
            TextBlock.createDefault(rect: IntRect(0, 0, 1, 1)).raw.keys,
          ) &&
          lifted.fontFormat!.raw.keys.length ==
              FontFormat.createDefault().raw.keys.length,
      'block ${lifted.raw.length} keys, '
      'fontformat ${lifted.fontFormat!.raw.length} keys',
    );
    check(
      'fromOcr.carries_detection',
      lifted.xyxy.join(',') == '120.0,240.0,480.0,520.0' &&
          lifted.sourceLines.join('|') == 'こんにちは|世界' &&
          lifted.language == 'ja',
      'xyxy=${lifted.xyxy} lines=${lifted.sourceLines} '
      'lang=${lifted.language}',
    );
    check(
      'fromOcr.carries_size',
      // 🔴 Both keys, or the panel shows one size and the renderer uses another.
      lifted.raw['_detected_font_size'] == 27.0 &&
          lifted.fontFormat!.fontSize == 27.0,
      '_detected_font_size=${lifted.raw['_detected_font_size']} '
      'font_size=${lifted.fontFormat!.fontSize}',
    );
    // 🔴 This box is 360x280 — **wider than tall**, so it is horizontal and must
    // NOT be marked vertical. Asserting it *is* vertical (my first attempt) would
    // have "passed" only by breaking the aspect-ratio rule the worker uses.
    check(
      'fromOcr.horizontal_box_not_vertical',
      lifted.raw['src_is_vertical'] == false &&
          lifted.fontFormat!.raw['vertical'] == false,
      'src_is_vertical=${lifted.raw['src_is_vertical']} '
      'vertical=${lifted.fontFormat!.raw['vertical']} '
      '(360x280 is landscape)',
    );
    // A tall box is the vertical-Japanese case.
    final tallBlock = OcrBlock(
      rect: IntRect(300, 100, 460, 700),
      text: '縦書き',
      language: 'ja',
      backgroundColor: 0xFFFFFFFF,
      textColor: 0xFF000000,
      lineHeight: 24,
    );
    final tall = TextBlock.fromOcr(tallBlock);
    check(
      'fromOcr.marks_vertical',
      tall.raw['src_is_vertical'] == true &&
          tall.fontFormat!.raw['vertical'] == true,
      'src_is_vertical=${tall.raw['src_is_vertical']} '
      'vertical=${tall.fontFormat!.raw['vertical']} '
      '(160x600 is portrait)',
    );
    check(
      'fromOcr.leaves_translation_empty',
      // 🔴 Writing the source text here would letter untranslated Japanese over
      // the erased Japanese.
      lifted.translation.isEmpty && lifted.toTranslatedRegion() == null,
      'translation="${lifted.translation}" '
      'region=${lifted.toTranslatedRegion()}',
    );
    check(
      'fromOcr.det_model_stays_empty',
      lifted.raw['det_model'] == '',
      'det_model="${lifted.raw['det_model']}" (must stay empty so a re-detect '
      'pass does not treat this block as its own output)',
    );
    check(
      'fromOcr.roundtrips_through_json',
      // A detected block must survive a write/read cycle unchanged, or every
      // pipeline run would produce a diff.
      jsonEncode(lifted.raw) ==
          jsonEncode(
            TextBlock(jsonDecode(jsonEncode(lifted.raw)) as Map<String, Object?>)
                .raw,
          ),
      'json stable',
    );

    // ── S9 第 2 批 🟠 P1：聚块/阅读顺序 · 字体资产 · 落地接缝 ──────────
    //
    // 单独一个文件（`headless_p1_checks.dart`）：这一批的断言数量与 P0 那批
    // 相当，而 headless.dart 已经 2400 行，塞进来会让"再加断言"变成一件需要
    // 动核心文件的事 —— 那正是最该被看到的断言被跳过的路径。
    //
    // 🔴 `reverseVerified` 是**实测记录**，不是许诺：清单里的每一条断言都在
    // 注入故障后确认过 FAIL（过程见 docs/P9.6 §五）。写一个空清单会被
    // `assertions.reverse_verification_recorded` 判 FAIL。
    final packageRoot = _packageRoot();
    if (packageRoot == null) {
      check(
        'p1.package_root',
        false,
        'package root not found — the P1 checks would all pass vacuously',
      );
    } else {
      runP1Checks(
        check,
        packageRoot: packageRoot,
        reverseVerified: const [
          // font.*
          'font.files_present',
          'font.license_embedded',
          'font.registry_matches_pubspec',
          'font.assets_exist_in_pubspec',
          'font.unknown_family_falls_back',
          'font.legacy_yahei_mapped',
          'font.missing_family_falls_back',
          'font.bundled_family_passes_through',
          'font.default_family_is_legacy',
          'font.selector_lists_unbundled',
          'font.renderer_resolves_family',
          'font.preview_matches_output',
          // cluster.*
          'cluster.merges_lines_of_one_balloon',
          'cluster.splits_separate_balloons',
          'cluster.reading_order_right_to_left',
          'cluster.reading_order_left_to_right',
          'cluster.column_reads_top_to_bottom',
          'cluster.staggered_not_merged_into_one_column',
          'cluster.order_is_deterministic',
          'cluster.vertical_lines_read_right_first',
          'cluster.empty_input_yields_nothing',
          'cluster.blank_lines_ignored',
          'cluster.mixed_orientation_not_merged',
          'cluster.mixed_font_size_not_merged',
          'cluster.reports_median_line_height',
          'cluster.bridge_keeps_per_line_erase_rects',
          'cluster.detector_extension_point_exists',
          // pipeline.*
          'pipeline.batch_landing_is_one_undo_step',
          'pipeline.landing_registers_dirty_page',
          'pipeline.undo_after_save_clears_dirty',
          'pipeline.dedup_protects_reviewed_blocks',
          'pipeline.blocks_become_letterable',
          'pipeline.cancel_token_works',
          'pipeline.report_counts_failures',
          'pipeline.studio_does_not_use_legacy_engine',
        ],
      );
      // ── S9 第 2 批 🟡 P2（P9.7）：吸附 · 韩文字族 · 离开路径 · 断点续跑 ──
      runP2Checks(
        check,
        packageRoot: packageRoot,
        reverseVerified: const [
          // snap.*
          'snap.edge_within_tolerance',
          'snap.edge_outside_tolerance',
          'snap.resize_only_moves_dragged_edge',
          'snap.resize_never_violates_min_size',
          'snap.move_prefers_smaller_adjustment',
          'snap.no_targets_is_noop',
          'snap.targets_include_page_bounds',
          // font.*（韩文）
          'font.korean_registered',
          'font.korean_alias_mapped',
          'font.korean_files_are_cff',
          'font.korean_cmap_has_hangul',
          'font.fallback_chain_excludes_own_family',
          'font.renderer_uses_fallback_chain',
          // leave.*
          'leave.close_always_intercepted',
          'leave.single_exit_call_site',
          // studio.* / pipeline.* / harness.*
          'studio.marquee_reset_on_page_change',
          'pipeline.resume_returns_tail',
          'pipeline.resume_unknown_page_is_empty',
          'harness.truncates_output_before_run',
        ],
      );
    }

    passed = checks.every((c) => c['passed'] == true);
    await finish(passed, 'Edit check ${passed ? 'PASS' : 'FAIL'} (${checks.length} checks)');
  } catch (e, s) {
    Log.error('EditCheck', 'edit-check failed: $e\n$s');
    check('exception', false, e.toString());
    await finish(false, 'Edit check threw: $e');
  } finally {
    try {
      await tempRoot.delete(recursive: true);
    } catch (_) {}
  }
  exit(passed ? 0 : 1);
}

Future<void> runHeadlessMode(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (args.contains('--ignore-disheadless-log')) {
    Log.isMuted = true;
  }
  if (Platform.isLinux || Platform.isMacOS) {
    Directory.current = Platform.environment['HOME']!;
  }
  // The first arg is '--headless', so we look at the next ones.
  var commandIndex = args.indexOf('--headless') + 1;
  if (commandIndex >= args.length) {
    cliPrint({
      'status': 'error',
      'message': 'No command provided for headless mode.',
    });
    exit(1);
  }

  var command = args[commandIndex];
  var subCommand = (commandIndex + 1 < args.length)
      ? args[commandIndex + 1]
      : null;

  // Commands that only touch the filesystem run before app startup. Startup
  // pulls in path_provider, asset bundles and every data store — none of which
  // a project check needs, and any of which can stall a windowless run.
  if (command == 'project-check') {
    await runProjectCheck(args, commandIndex);
    return;
  }

  // The S8 editing layer is pure Dart (project model + command stack + the
  // rich-text builder), so it can be verified before any app startup too.
  if (command == 'edit-check') {
    await runEditCheck(args, commandIndex);
    return;
  }

  // Need to initialize the app for some features to work
  _headlessTrace('init: App/data/translation');
  await init();
  _headlessTrace('init: done');
  // The import path restores backups into LIVE stores (in-place, via the
  // SQLite backup API) instead of swapping files, so every store must be open
  // before a `webdav down` applies data — this also satisfies
  // coreDataStoresReady, which gates applying backups.
  _headlessTrace('init: cookie jar');
  await SingleInstanceCookieJar.createInstance();
  // `App.initComponents()` alone deadlocks here: `LocalManager.init()` awaits
  // `ComicSourceManager().ensureInit()`, and that manager is only ever started
  // by `initDeferred()` — which headless never runs. Go through the shared
  // start-together helper instead, and bound the wait so a future ordering
  // regression fails loudly (logged, non-zero exit) rather than hanging with
  // no output at all.
  _headlessTrace('init: components');
  try {
    await initInterdependentStores().timeout(const Duration(seconds: 120));
    _headlessTrace('init: components done');
  } catch (e, s) {
    _headlessTrace('init: components failed: $e');
    Log.error('headless', 'App store init failed: $e\n$s');
  }
  // Headless never runs initDeferred(); complete the gate so DataSync's
  // download entry (which waits for deferred init before applying backups)
  // proceeds immediately instead of stalling on its 60s safety timeout.
  if (!deferredInitCompleter.isCompleted) {
    deferredInitCompleter.complete();
  }

  switch (command) {
    case 'export-check':
      await runExportCheck(args, commandIndex);
    case 'studio-scan':
      await runStudioScan(args, commandIndex);
    case 'page-reconcile':
      await runPageReconcile(args, commandIndex);
    case 'download-check':
      await runDownloadCheck(args, commandIndex);
    case 'comix-spike':
      await runComixSpike(args, commandIndex);
    case 'pipeline-check':
      await runPipelineCheck(args, commandIndex);
    case 'webdav':
      if (subCommand == 'up') {
        cliPrint({'status': 'running', 'message': 'Uploading WebDAV data...'});
        var result = await DataSync().uploadData(force: true);
        if (result.error) {
          cliPrint({
            'status': 'error',
            'message': 'Upload failed: ${result.errorMessage}',
          });
          exit(1);
        }
        cliPrint({'status': 'success', 'message': 'Upload complete.'});
      } else if (subCommand == 'down') {
        cliPrint({
          'status': 'running',
          'message': 'Downloading WebDAV data...',
        });
        var result = await DataSync().downloadData();
        if (result.error) {
          cliPrint({
            'status': 'error',
            'message': 'Download failed: ${result.errorMessage}',
          });
          exit(1);
        }
        cliPrint({'status': 'success', 'message': 'Download complete.'});
      } else {
        cliPrint({
          'status': 'error',
          'message': 'Invalid webdav command. Use "up" or "down".',
        });
        exit(1);
      }
      break;
    case 'updatescript':
      if (subCommand == 'all') {
        cliPrint({
          'status': 'running',
          'message': 'Checking for comic source script updates...',
        });
        await ComicSourcePage.checkComicSourceUpdate();
        var updates = ComicSourceManager().availableUpdates;
        if (updates.isEmpty) {
          cliPrint({'status': 'success', 'message': 'No updates found.'});
        } else {
          var total = updates.length;
          var current = 0;
          var errors = 0;
          var updated = 0;
          cliPrint({
            'status': 'running',
            'message': 'Updating all comic source scripts...',
            'data': {'total': total, 'current': 0, 'updated': 0, 'errors': 0},
          });
          for (var key in updates.keys) {
            var source = ComicSource.find(key);
            if (source != null) {
              current++;
              var data = {
                'current': current,
                'total': total,
                'source': {
                  'key': source.key,
                  'name': source.name,
                  'version': source.version,
                  'url': source.url,
                },
              };
              try {
                await ComicSourcePage.update(source, false);
                updated++;
                cliPrint({
                  'status': 'running',
                  'message': 'Progress',
                  'data': data,
                });
              } catch (e) {
                errors++;
                cliPrint({
                  'status': 'running',
                  'message': 'ProgressError',
                  'data': {...data, 'error': e.toString()},
                });
              }
            }
          }
          cliPrint({
            'status': 'success',
            'message': 'All scripts updated.',
            'data': {'total': total, 'updated': updated, 'errors': errors},
          });
        }
      } else {
        cliPrint({
          'status': 'error',
          'message': 'Invalid updatescript command. Use "all".',
        });
        exit(1);
      }
      break;
    case 'updatesubscribe':
      cliPrint({
        'status': 'running',
        'message': 'Updating subscribed comics...',
      });
      var folders = FollowUpdateScope.folders();
      if (folders.isEmpty) {
        cliPrint({
          'status': 'error',
          'message': 'Follow updates is not configured.',
        });
        exit(1);
      }

      var updateIndex = args.indexOf('--update-comic-by-id-type');
      if (updateIndex != -1) {
        var id = args[updateIndex + 1];
        var type = args[updateIndex + 2];
        var comics = LocalFavoritesManager().getComicsWithUpdatesInfoIn(
          folders,
        );
        var comic = comics.firstWhere(
          (c) => c.id == id && c.type.sourceKey == type,
        );
        // Write the result into every followed folder that holds the comic, the
        // same way a full check does.
        var holding = LocalFavoritesManager().find(id, comic.type);
        var targets = folders.where(holding.contains).toList();
        var result = await updateComic(
          comic,
          targets.isEmpty ? folders : targets,
        );

        Map<String, dynamic> data = {
          'current': 1,
          'total': 1,
          'comic': {
            'id': comic.id,
            'name': comic.name,
            'coverUrl': comic.coverPath,
            'author': comic.author,
            'type': comic.type.sourceKey,
            'updateTime': comic.updateTime,
            'tags': comic.tags,
          },
        };

        var message = 'Progress';
        if (result.errorMessage != null) {
          message = 'ProgressError';
          data['error'] = result.errorMessage;
        }

        cliPrint({'status': 'running', 'message': message, 'data': data});

        cliPrint({
          'status': 'running',
          'message': 'Update check complete.',
          'data': {
            'total': 1,
            'updated': result.updated ? 1 : 0,
            'errors': result.errorMessage != null ? 1 : 0,
          },
        });

        await Future.delayed(const Duration(milliseconds: 500));
        var json = await getUpdatedComicsAsJson(folders);
        cliPrint({
          'status': result.errorMessage != null ? 'error' : 'success',
          'message': 'Updated comics list.',
          'data': jsonDecode(json),
        });
      } else {
        int total = 0;
        int updated = 0;
        int errors = 0;
        await for (var progress in updateFolders(folders, true)) {
          total = progress.total;
          updated = progress.updated;
          errors = progress.errors;
          Map<String, dynamic> data = {
            'current': progress.current,
            'total': progress.total,
          };
          if (progress.comic != null) {
            data['comic'] = {
              'id': progress.comic!.id,
              'name': progress.comic!.name,
              'coverUrl': progress.comic!.coverPath,
              'author': progress.comic!.author,
              'type': progress.comic!.type.sourceKey,
              'updateTime': progress.comic!.updateTime,
              'tags': progress.comic!.tags,
            };
          }
          var message = 'Progress';
          if (progress.errorMessage != null) {
            message = 'ProgressError';
            data['error'] = progress.errorMessage;
          }
          cliPrint({'status': 'running', 'message': message, 'data': data});
        }
        cliPrint({
          'status': 'running',
          'message': 'Update check complete.',
          'data': {'total': total, 'updated': updated, 'errors': errors},
        });
        await Future.delayed(const Duration(milliseconds: 500));
        var json = await getUpdatedComicsAsJson(folders);
        cliPrint({
          'status': errors > 0 ? 'error' : 'success',
          'message': 'Updated comics list.',
          'data': jsonDecode(json),
        });
      }
      break;
    default:
      cliPrint({'status': 'error', 'message': 'Unknown command: $command'});
      exit(1);
  }

  // Exit after command execution
  exit(0);
}

/// Tooltip / label literals used by the translation studio that have no
/// `zh_CN` entry in `assets/translation.json`.
///
/// Reads the two files directly instead of going through [AppTranslation]
/// because the point is to catch the *source* keys that were never
/// registered; looking them up at runtime would silently succeed by falling
/// back to English, which is the very bug being guarded against.
List<String> _missingStudioTooltips() {
  final root = _packageRoot();
  if (root == null) return const ['<package root not found>'];
  // 🔴 P1-4 widened this from one file to the whole `translation_studio/`
  // directory. It read only `studio_page.dart`, which is why the S8 panel's
  // literals were never checked — and two of them were untranslated as a
  // result. Scanning one file of a three-file feature is an assumption that
  // happened to be true until it wasn't.
  final dir = Directory('${root.path}/lib/pages/translation_studio');
  final tableFile = File('${root.path}/assets/translation.json');
  final sources = [
    for (final entry in dir.listSync().whereType<File>())
      if (entry.path.endsWith('.dart')) entry,
  ]..sort((a, b) => a.path.compareTo(b.path));
  if (sources.isEmpty || !tableFile.existsSync()) {
    return const ['<studio sources or translation.json not found>'];
  }
  final zhCn = (jsonDecode(tableFile.readAsStringSync())
      as Map<String, dynamic>)['zh_CN'] as Map<String, dynamic>;
  // 🔴 Scan the quoted literal before `.tl` rather than `tooltip: '...'`.
  // Most tooltips are picked by a conditional (`cond ? 'A'.tl : 'B'.tl`), so
  // matching the argument of `tooltip:` alone finds nothing and passes
  // vacuously -- which is exactly what the first version of this check did.
  // Anchoring on the translation call catches every user-facing literal on the
  // page however it is chosen.
  //
  // `.tlEN` is excluded on purpose: it reads the English table by design.
  //
  // 🔴 P9.7 widened this to `.tlParams` as well. `\btl\b` does **not** match
  // inside `tlParams` (there is no word boundary between `l` and `P`), so every
  // string with a `@a` placeholder — which is precisely the form the project
  // mandates for anything parameterised — was invisible to this check. Deleting
  // a `zh_CN` entry for such a string left the check green while the UI fell
  // back to English; the row the user complained about in P9.3 was one of these.
  final pattern = RegExp(r"'((?:[^'\\]|\\.)*)'\.tl(?:Params)?\b");
  final missing = <String>[];
  for (final file in sources) {
    for (final m in pattern.allMatches(file.readAsStringSync())) {
      final key = m.group(1)!;
      // A key of one or two letters is a `tlParams` placeholder map value
      // caught by the scan, not a UI string; and an empty key is a literal
      // `''.tl`. Neither is a missing translation.
      if (key.isEmpty || key.length <= 2) continue;
      if (!zhCn.containsKey(key) && !missing.contains(key)) missing.add(key);
    }
  }
  return missing;
}

/// Walks up from the current directory looking for the package root, which is
/// the directory holding both `pubspec.yaml` and `lib/`.
Directory? _packageRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (File('${dir.path}/pubspec.yaml').existsSync() &&
        Directory('${dir.path}/lib').existsSync()) {
      return dir;
    }
    for (final candidate in ['VeneraX', '.']) {
      final d = Directory('${dir.path}/$candidate');
      if (File('${d.path}/pubspec.yaml').existsSync() &&
          Directory('${d.path}/lib').existsSync()) {
        return d;
      }
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

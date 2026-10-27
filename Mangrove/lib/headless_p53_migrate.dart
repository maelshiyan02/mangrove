// P53 迁移：把「平铺的」旧翻译工程搬进「漫画级根 → 章节级」的两级结构。
//
// ## 目标布局
//
// ```
// <projectsRoot>/<漫画名>/                       ← 漫画级根（一张卡，可入合集）
//     mangrove_project.json                      ← 边车 level=comic（+ 封面）
//     <章节键>/                                  ← 章节级工程
//         imgtrans_<章节键>.json
//         mangrove_project.json                  ← 边车 level=chapter
//         source/                                ← junction → 原件（不复制）
//         inpainted/ mask/ result/
// ```
//
// 章节键 = **源章节目录名**（阅读键）。它同时是 json 所在目录、详情页章节列表
// 的键 —— 三者同一个字符串，才不会点错章。
//
// ## 迁移对象
//
// 1. **P53 之前的老工程**：`<projectsRoot>/<漫画名>-<章节名>/`（自成一卡）。
// 2. **P53 早期误建的"整本"工程**：`<projectsRoot>/<漫画名>/` 里直接躺着
//    `imgtrans_<漫画名>.json`（章节工程却没落到子目录）。用户指出这就是
//    "多一个 109[violet scans] 的层级"缺失的那一层。
//
// 两种都是"json 目录 = 漫画级根目录"，搬进两级结构即可。
//
// ## 安全边界（用户明确要求：备份优先、绝不静默删文件）
//
// 1. **默认 dry-run**：不加 `--apply` 只打印计划，一个字节都不写。
// 2. 目标目录已存在 ⇒ 跳过该工程，绝不覆盖。
// 3. 搬运是**改名**（同盘 rename），不复制、不删除；另有 `_p53_backup_<时间戳>/`
//    存一份 json + 边车副本，随时可搬回。
// 4. `source/` 保持原样（老工程里是副本就仍是副本）—— 那可能已经是用户唯一
//    的一份图，不在迁移里冒险换链接。
//
// ## 依赖
//
// 需要 App 已初始化（`LocalManager` 的库 + `appdata` 里的绑定表），所以它是
// **post-init** 命令，与 `create-project` 同类。
library;

import 'dart:convert';
import 'dart:io';

import 'package:mangrove/foundation/appdata.dart';
import 'package:mangrove/foundation/bt_project/bt_project_manager.dart';
import 'package:mangrove/foundation/chapter_directory.dart';
import 'package:mangrove/foundation/comic_type.dart';
import 'package:mangrove/foundation/local.dart';
import 'package:mangrove/foundation/log.dart';
import 'package:mangrove/foundation/translation_project/project.dart';
import 'package:mangrove/foundation/translation_project/project_bootstrap.dart';
import 'package:mangrove/foundation/translation_project/project_io.dart';
import 'package:mangrove/foundation/translation_project/studio_project_meta.dart';
import 'package:mangrove/foundation/translation_project/studio_reader.dart';
import 'package:mangrove/foundation/translation_project/studio_reader_app.dart';

/// 与 `headless.dart` 的 `cliPrint` 同格式的进度输出。
///
/// 🔴 刻意**不** import `headless.dart`：那个库有 `main()`，反向 import 会形成
/// 两个库互相依赖（Dart 允许，但会让"谁是入口"变得含糊）。格式只有一行，
/// 复制比纠缠便宜。
void _cliPrint(Map<String, dynamic> data) {
  print('[CLI PRINT] ${jsonEncode(data)}');
}

/// 一笔待迁移的工程。
class _Pending {
  _Pending({
    required this.jsonFile,
    required this.projectDir,
    required this.meta,
    required this.chapterKey,
    required this.comicName,
    required this.targetDir,
    required this.reason,
    this.identity,
    this.nested = false,
  });

  /// 从本地库找回的素材漫画身份（老工程没有边车时靠章节键反查）。
  final LocalComic? identity;

  /// 已经处于两级结构里（只需修复，不需搬家）。
  final bool nested;

  final File jsonFile;
  final String projectDir;
  final StudioProjectMeta? meta;
  final String chapterKey;
  final String comicName;
  final String targetDir;
  final String reason;

  Map<String, Object?> toJson() => {
        'json': jsonFile.path.replaceAll('\\', '/'),
        'from': projectDir.replaceAll('\\', '/'),
        'to': targetDir.replaceAll('\\', '/'),
        'chapter': chapterKey,
        'comic': comicName,
        'reason': reason,
      };
}

/// 归一化路径（`\` → `/`，去尾斜杠）。
String _norm(String path) =>
    path.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');

String _dirName(String path) {
  final normalized = _norm(path);
  final slash = normalized.lastIndexOf('/');
  return slash < 0 ? normalized : normalized.substring(slash + 1);
}

String _parentOf(String path) {
  final normalized = _norm(path);
  final slash = normalized.lastIndexOf('/');
  return slash <= 0 ? '' : normalized.substring(0, slash);
}

/// 收集工程根下所有 `imgtrans_*.json`（跳过产物目录）。
List<File> _projectJsons(String root) {
  final out = <File>[];
  void walk(Directory dir, int depth) {
    if (depth > 4) return;
    try {
      for (final entity in dir.listSync(followLinks: false)) {
        final name = _dirName(entity.path);
        if (entity is File) {
          if (name.startsWith('imgtrans_') &&
              name.endsWith('.json') &&
              !name.endsWith('.artifacts.json')) {
            out.add(entity);
          }
        } else if (entity is Directory) {
          if (name.startsWith('.') || name.startsWith('_p53_backup')) continue;
          if (const {'mask', 'inpainted', 'result', 'assets', 'source'}
              .contains(name.toLowerCase())) {
            continue;
          }
          walk(entity, depth + 1);
        }
      }
    } catch (e, s) {
      Log.warning('P53 Migrate', 'list ${dir.path} failed: $e / $s');
    }
  }

  walk(Directory(root), 0);
  return out;
}

/// 这一章的**章节键**：优先取 json 里 `chapters` 的章名，其次工程目录名。
String _chapterKeyOf(TranslationProject project, String projectDir) {
  for (final name in project.chapters.keys) {
    if (name.trim().isNotEmpty) return sanitizePathSegment(name);
  }
  return sanitizePathSegment(_dirName(projectDir));
}

/// `--headless migrate-nested [--apply] [--json out.json]`
Future<void> runMigrateNested(
  List<String> args,
  int commandIndex,
) async {
  final apply = args.contains('--apply');
  final outIndex = args.indexOf('--json');
  final outPath =
      outIndex >= 0 && outIndex + 1 < args.length ? args[outIndex + 1] : '';

  final roots = BtProjectManager.roots;
  final pending = <_Pending>[];

  for (final root in roots) {
    for (final json in _projectJsons(root)) {
      final projectDir = _parentOf(json.path);
      if (projectDir.isEmpty) continue;
      // 已经在两级结构里（父目录是漫画级根）⇒ **修复**而不是搬家：json 的
      // `directory` 可能还指着旧路径、边车可能认错了对象、封面可能没落到根。
      final upper = StudioProjectMeta.readFromProjectDir(_parentOf(projectDir));
      final nested = upper != null && upper.isComicLevel;

      final meta = StudioProjectMeta.readFromProjectDir(projectDir);
      TranslationProject project;
      try {
        project = await TranslationProjectIo.load(json);
      } catch (e, s) {
        Log.error('P53 Migrate', 'load ${json.path} failed: $e', s);
        continue;
      }
      final chapterKey = _chapterKeyOf(project, projectDir);
      final comicName = nested
          ? _dirName(_parentOf(projectDir))
          : sanitizePathSegment(
              (meta?.comicTitle.isNotEmpty ?? false)
                  ? meta!.comicTitle
                  : _dirName(projectDir),
            );
      final targetDir = nested
          ? projectDir
          : '${_norm(root)}/$comicName/$chapterKey';
      pending.add(
        _Pending(
          jsonFile: json,
          projectDir: projectDir,
          meta: meta,
          chapterKey: chapterKey,
          comicName: comicName,
          targetDir: targetDir,
          reason: nested
              ? 'repair-nested'
              : (meta == null ? 'no-sidecar' : 'flat-project'),
          identity: _recoverIdentity(meta, chapterKey),
          nested: nested,
        ),
      );
    }
  }

  final report = <Map<String, Object?>>[];
  for (final item in pending) {
    final entry = item.toJson();
    if (!apply) {
      entry['action'] = item.nested ? 'would-repair' : 'would-move';
      report.add(entry);
      continue;
    }
    try {
      // ── 1 · 搬家（平铺工程） ────────────────────────────────────────────
      //
      // 🔴 "把目录搬进它自己的子目录"在文件系统上是**非法**的（Windows 直接
      // 报错）。而这恰恰是最常见的一种：平铺工程叫 `做个恶女好安逸`，目标却是
      // `做个恶女好安逸/109 [Violet Scans] [comix.to]/` —— 目标在源里面。
      // 所以先改个临时名，再把（此时已不存在的）父目录建出来，最后搬到位。
      var chapterDir = _norm(item.projectDir);
      String? backup;
      if (!item.nested) {
        final target = Directory(item.targetDir);
        if (target.existsSync()) {
          entry['action'] = 'skipped';
          entry['detail'] = 'target-exists';
          report.add(entry);
          continue;
        }
        final source = Directory(item.projectDir);
        var staging = source;
        if (item.targetDir.startsWith('${item.projectDir}/')) {
          final temp = '${item.projectDir}.p53tmp_${_stamp()}';
          await source.rename(temp);
          staging = Directory(temp);
        }
        await target.parent.create(recursive: true);
        await staging.rename(item.targetDir);
        chapterDir = item.targetDir;
        // 备份：json 副本（产物跟着目录走，不重复占盘）。
        final backupRoot =
            Directory('${_norm(roots.first)}/_p53_backup_${_stamp()}');
        await backupRoot.create(recursive: true);
        final jsonBackup =
            File('$chapterDir/${_dirName(item.jsonFile.path)}');
        if (jsonBackup.existsSync()) {
          await jsonBackup.copy('${backupRoot.path}/${_dirName(jsonBackup.path)}');
        }
        backup = backupRoot.path;
      }

      // ── 2 · json 的 `directory` 指着**旧**路径 ──────────────────────────
      //
      // 不改的话工程打开后找不到图（`TranslationProject.directory` 会静默回落
      // 到 json 所在目录，界面上看不出来，只表现为"每页都没有原图"）。这里只替换
      // 那一个值，其余字节原样保留（FT 的键序断言锁死了整个文件）。
      final sourceDir = '$chapterDir/${ProjectBootstrap.sourceDirectoryName}';
      final jsonPath = '$chapterDir/${_dirName(item.jsonFile.path)}';
      if (Directory(sourceDir).existsSync()) {
        await _rewriteDirectory(jsonPath, sourceDir);
      }

      // ── 3 · 漫画级边车 + 封面 ──────────────────────────────────────────
      //
      // 统一走 `ensureComicRoot`（封面复制 + 幂等补齐，只有一处实现）。
      //
      // 🔴 边车**必须有 comicId** —— `readFromProjectDir` 读到空 id 会返回 null，
      // 于是这个根认不出自己是漫画级，详情页就退回"每章一张卡"。
      final identity = item.identity;
      final comicId = identity?.id ?? item.meta?.comicId ?? '';
      final comicRoot = _parentOf(chapterDir);
      if (comicId.isNotEmpty) {
        await ProjectBootstrap.ensureComicRoot(
          projectsRoot: roots.first,
          name: _dirName(comicRoot),
          meta: StudioProjectMeta(
            comicId: comicId,
            comicTitle:
                identity?.title ?? item.meta?.comicTitle ?? item.comicName,
            sourceKey: identity?.sourceKey ?? item.meta?.sourceKey ?? '',
            eid: '0',
            level: StudioProjectMeta.levelComic,
            originalPath: identity?.baseDir ?? item.meta?.originalPath ?? '',
          ),
          coverFrom: identity?.coverFile.path,
        );
      }
      // ── 4 · 章节级边车 ─────────────────────────────────────────────────
      await StudioProjectMeta.writeToProjectDir(
        chapterDir,
        StudioProjectMeta(
          comicId: comicId,
          comicTitle:
              identity?.title ?? item.meta?.comicTitle ?? item.comicName,
          sourceKey: identity?.sourceKey ?? item.meta?.sourceKey ?? '',
          eid: item.meta?.eid ?? '0',
          level: StudioProjectMeta.levelChapter,
          originalPath: identity?.baseDir ?? item.meta?.originalPath ?? '',
        ),
      );
      // ── 5 · 绑定表里的 json 路径跟着改（否则工作室读回的还是旧路径）────
      if (!item.nested) {
        await _rebind(item.projectDir, chapterDir);
      } else {
        await _rebindStale(chapterDir);
      }
      entry['action'] = item.nested ? 'repaired' : 'moved';
      if (backup != null) entry['backup'] = backup;
      entry['comicId'] = comicId;
    } catch (e, s) {
      Log.error('P53 Migrate', 'migrate ${item.projectDir} failed: $e', s);
      entry['action'] = 'failed';
      entry['detail'] = '$e';
    }
    report.add(entry);
  }

  // 🔴 绑定表是 fire-and-forget 写的（`appdata.writeImplicitData()` 是
  // `void async`）—— headless 进程马上退出 ⇒ 写没落盘 ⇒ 迁移"成功"了而绑定
  // 还指着旧路径。退出前必须等它落完。
  await appdata.flushImplicitData();

  final summary = {
    'command': 'migrate-nested',
    'apply': apply,
    'roots': roots,
    'pending': pending.length,
    'report': report,
  };
  _cliPrint(summary);
  // 🔴 收尾行必须是 `status: success|error` —— `run_headless_task.py` 的判定
  // 读的是**最后**一条这样的行；没有它，脚本会报 "no closing line"，而命令
  // 其实是成功的。
  _cliPrint({
    'status': 'success',
    'message': apply
        ? 'Migration finished: ${pending.length} project(s) processed.'
        : 'Migration dry-run finished: ${pending.length} project(s) would move.',
    'data': summary,
  });
  if (outPath.isNotEmpty) {
    final file = File(outPath);
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(summary));
  }
}

/// 只替换 json 里的 `directory` 值，其余字节原样保留。
Future<void> _rewriteDirectory(String jsonPath, String newDirectory) async {
  final file = File(jsonPath.replaceAll('\\', '/'));
  if (!file.existsSync()) return;
  final text = await file.readAsString();
  final pattern = RegExp(r'"directory"\s*:\s*"[^"]*"');
  if (!pattern.hasMatch(text)) return;
  final updated = text.replaceFirst(
    pattern,
    '"directory": "${newDirectory.replaceAll('\\', '/')}"',
  );
  await file.writeAsString(updated, flush: true);
}

/// 从本地库找回这个工程的**素材漫画**身份。
///
/// 🔴 老工程（P53 之前）没有边车 ⇒ 不知道"它属于哪一本漫画"。而边车**必须**
/// 有 `comicId` 才读得回来（空 id 一律当 null），所以这一层是迁移能不能
/// 生效的关键。
///
/// 认据 = **章节键**：源漫画的章节目录名（`1 [Rokari Comics] [comix.to]`）在
/// 本地库里是唯一的 —— 拿它去比对每一本本地漫画的章节表，命中即认定。
/// 认不出来的就老实不认（`comicId` 留空），那个工程继续按老布局存在，
/// 不会被塞进别人的漫画名下。
LocalComic? _recoverIdentity(StudioProjectMeta? meta, String chapterKey) {
  if (meta != null && meta.comicId.isNotEmpty) {
    final direct = _findComic(meta.comicId, meta.sourceKey);
    if (direct != null) return direct;
  }
  if (chapterKey.isEmpty) return null;
  LocalComic? fallback;
  try {
    for (final comic in LocalManager().getComics(LocalSortType.defaultSort)) {
      // 🔴 **不能**把工程卡自己认成来源漫画：工程卡（`bt_` 前缀）也带章节表，
      // 而且章节键一模一样（它就是从源章节键建出来的）。认成自己 ⇒ 漫画级
      // 边车的 `comicId` 指向这张卡自己，详情页就成了"工程指向工程"。
      if (BtProjectManager.isBtComic(comic.id)) continue;
      final chapters = comic.chapters;
      if (chapters == null) continue;
      var hit = false;
      for (final key in chapters.ids) {
        if (key == chapterKey) {
          hit = true;
          break;
        }
      }
      if (!hit) continue;
      // 素材漫画的目录在 `downloads/` 下；优先选它。
      if (comic.directory.contains('downloads')) return comic;
      fallback ??= comic;
    }
  } catch (e, s) {
    Log.warning('P53 Migrate', 'identity recovery failed: $e / $s');
  }
  return fallback;
}

LocalComic? _findComic(String comicId, String sourceKey) {
  final manager = LocalManager();
  try {
    if (sourceKey.isNotEmpty) {
      final byKey = manager.find(comicId, ComicType.fromKey(sourceKey));
      if (byKey != null) return byKey;
    }
    return manager.find(comicId, ComicType.local);
  } catch (_) {
    return null;
  }
}

String _stamp() {
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${now.year}${two(now.month)}${two(now.day)}'
      '-${two(now.hour)}${two(now.minute)}${two(now.second)}';
}

/// 把**指向已不存在的 json** 的绑定归位到当前章节工程。
///
/// 🔴 迁移分两步走（先搬目录、再修绑定）时，中间会留下"绑定指着旧路径"的
/// 幽灵条目 —— 工作室读它就会说"工程不在工程根目录下"，而磁盘上明明有。
/// 这里的判据是**文件名相同**（工程 json 的名字在迁移前后不变）。
Future<void> _rebindStale(String chapterDir) async {
  final table = StudioReaderStore.bindings;
  final dir = _norm(chapterDir);
  for (final key in table.keys.toList()) {
    final binding = table[key];
    if (binding == null) continue;
    if (File(binding.jsonPath).existsSync()) continue;
    final name = _dirName(binding.jsonPath);
    final candidate = File('$dir/$name');
    if (!candidate.existsSync()) continue;
    final parts = key.split('@');
    if (parts.length < 3) continue;
    StudioReaderStore.put(
      cid: parts.sublist(0, parts.length - 2).join('@'),
      sourceKey: parts[parts.length - 2],
      eid: parts[parts.length - 1],
      binding: StudioReaderBinding(
        jsonPath: '$dir/$name',
        comicDirectory: binding.comicDirectory,
        projectDirectory: '$dir/${ProjectBootstrap.sourceDirectoryName}',
        originScope: binding.originScope,
        group: binding.group,
      ),
    );
  }
}

/// 绑定表里指向旧工程目录的条目改指向新目录。
Future<void> _rebind(String oldDir, String newDir) async {
  final table = StudioReaderStore.bindings;
  final oldKey = _norm(oldDir).toLowerCase();
  for (final key in table.keys.toList()) {
    final binding = table[key];
    if (binding == null) continue;
    if (!_norm(binding.jsonPath).toLowerCase().startsWith(oldKey)) continue;
    // 🔴 替换必须用**原样大小写**的前缀：`oldKey` 是小写化的，而路径里
    // 有大写（`AI Coding Project Management`）⇒ `replaceFirst` 匹配不上，
    // 绑定被"改"成原样写回，看着像改了其实没改。
    final prefix = binding.jsonPath.substring(0, oldDir.length);
    final moved = StudioReaderBinding(
      jsonPath: _norm(binding.jsonPath).replaceFirst(prefix, _norm(newDir)),
      comicDirectory: binding.comicDirectory,
      projectDirectory:
          '${_norm(newDir)}/${ProjectBootstrap.sourceDirectoryName}',
      originScope: binding.originScope,
      group: binding.group,
    );
    final parts = key.split('@');
    if (parts.length < 3) continue;
    StudioReaderStore.put(
      cid: parts.sublist(0, parts.length - 2).join('@'),
      sourceKey: parts[parts.length - 2],
      eid: parts[parts.length - 1],
      binding: moved,
    );
  }
}

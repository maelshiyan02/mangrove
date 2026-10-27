// 把已下载好的漫画目录登记成**本地漫画**，并（可选）把多本放进同一个**合集**。
//
// ## 为什么要有这条命令
//
// 用户的要求是「这本漫画准备跳过网络阶段，直接转变成本地漫画」—— 于是目录里
// 已经有图，但 App 还不知道有这么一本书：没有本地库记录、没有章节表、没有封面、
// 没有合集。
//
// 这条命令**走 App 自己的写路径**（`LocalManager.add` / `updateComicDirect` /
// `refreshLocalComicChapters` / `ComicCollectionStore`），而不是手写 SQL：
//
// * `LocalManager.add` 会顺带 `ComicStateRepository().mirrorLocalComic(comic)`
//   —— 域库（`data/data/mangrove.db`）的镜像层才跟本地库一致。手写 SQL 只改
//   本地表，域库就会缺行，搜索/关联条目/合集封面全落空。
// * `refreshLocalComicChapters` 是**唯一**知道"章节目录名 = 章节 key、封面池
//   `cover/` 不是章节"的实现；自己拼 `chapters` JSON 迟早与 App 的口径漂移。
//
// ## 用法
//
// ```
// mangrove.exe --headless local-comic-make \
//   --dir "那個大公的華麗婚姻騙局" \
//   --title "那個大公的華麗婚姻騙局" \
//   --tags "愛情,穿越" \
//   --description "..." \
//   --alt-titles "那个大公的华丽婚姻骗局,그 대공의 화려한 결혼은 사기" \
//   --source "拷贝漫画" \
//   --update-time "2025-05-12" \
//   [--cover "cover/[KR][cover]season(3).jpg"] \
//   [--collection "大公的华丽婚骗局" --collection-mode tabs] \
//   [--json out.json]
// ```
library;

import 'dart:convert';
import 'dart:io';

import 'package:mangrove/foundation/appdata.dart';
import 'package:mangrove/foundation/comic_collection_store.dart';
import 'package:mangrove/foundation/comic_type.dart';
import 'package:mangrove/foundation/local.dart';
import 'package:mangrove/foundation/log.dart';
import 'package:mangrove/utils/local_comic_edit.dart';

void _print(Map<String, dynamic> data) {
  print('[CLI PRINT] ${jsonEncode(data)}');
}

List<String> _split(String value) => value
    .split(',')
    .map((e) => e.trim())
    .where((e) => e.isNotEmpty)
    .toList();

/// `--headless local-comic-make [options]`
Future<void> runLocalComicMake(
  List<String> args,
  int commandIndex,
) async {
  String argOr(String flag, String fallback) {
    final i = args.indexOf(flag);
    return i != -1 && i + 1 < args.length ? args[i + 1] : fallback;
  }

  final dir = argOr('--dir', '');
  if (dir.isEmpty) {
    _print({
      'status': 'error',
      'message': 'local-comic-make needs --dir.',
    });
    exit(1);
  }
  final title = argOr('--title', dir);
  final subtitle = argOr('--subtitle', '');
  final tags = _split(argOr('--tags', ''));
  final description = argOr('--description', '');
  final altTitles = _split(argOr('--alt-titles', ''));
  final source = argOr('--source', '');
  final updateTime = argOr('--update-time', '');
  final cover = argOr('--cover', '');
  final collectionName = argOr('--collection', '');
  final collectionMode = argOr('--collection-mode', 'tabs');
  final outIndex = args.indexOf('--json');
  final outPath = outIndex != -1 && outIndex + 1 < args.length
      ? args[outIndex + 1]
      : '';

  final manager = LocalManager();
  final libraryRoot = manager.path;

  // ① 目录必须在库里（App 只认 `<libraryRoot>/<dir>`）。
  final comicDir = Directory('$libraryRoot/$dir');
  if (!comicDir.existsSync()) {
    _print({
      'status': 'error',
      'message': 'Directory not found under library: $comicDir',
    });
    exit(1);
  }

  // ② 复用已有记录（按目录找），否则分配新 id。
  LocalComic? existing;
  for (final comic in manager.getComics(LocalSortType.defaultSort)) {
    if (comic.directory == dir && comic.comicType == ComicType.local) {
      existing = comic;
      break;
    }
  }
  final id = existing?.id ?? manager.findValidId(ComicType.local);

  // ③ 先落一条"只有壳"的记录：`refreshLocalComicChapters` 要读它。
  var comic = LocalComic(
    id: id,
    title: title,
    subtitle: subtitle,
    tags: tags,
    directory: dir,
    chapters: existing?.chapters,
    cover: existing?.cover ?? '',
    comicType: ComicType.local,
    downloadedChapters: existing?.downloadedChapters ?? const [],
    createdAt: existing?.createdAt ?? DateTime.now(),
    description: description,
    source: source,
    updateTime: updateTime,
    altTitles: altTitles,
  );
  manager.add(comic, id);

  // ④ 刷新章节（扫目录 → 章节表）。跑两遍：第一遍建章，第二遍才把标题
  //    清洗成"第N话"（`chapterDisplayName`）—— 只跑一遍的话新章的标题还是
  //    目录名（`1 [copymanga]`），详情页会显示成磁盘路径。
  final added = await refreshLocalComicChapters(comic);
  comic = manager.find(id, ComicType.local) ?? comic;
  await refreshLocalComicChapters(comic);
  comic = manager.find(id, ComicType.local) ?? comic;

  // ⑤ 补齐元信息（刷新章节那步会把 source/updateTime/altTitles 丢掉）。
  comic = LocalComic(
    id: comic.id,
    title: title,
    subtitle: subtitle,
    tags: tags,
    directory: dir,
    chapters: comic.chapters,
    cover: cover.isNotEmpty ? cover : comic.cover,
    comicType: ComicType.local,
    downloadedChapters: comic.downloadedChapters,
    createdAt: comic.createdAt,
    description: description,
    source: source,
    updateTime: updateTime,
    altTitles: altTitles,
  );
  manager.updateComicDirect(comic);

  // ⑥ 合集（可选）：把这一本加进去。
  String? collectionId;
  if (collectionName.isNotEmpty) {
    final mode = CollectionDisplayMode.fromName(collectionMode);
    final existingCollections = ComicCollectionStore.all();
    ComicCollection? target;
    for (final c in existingCollections) {
      if (c.displayName == collectionName) {
        target = c;
        break;
      }
    }
    target ??= ComicCollectionStore.create(name: collectionName);
    // 先清掉**同名但 id 已变**的旧成员：重新登记一本漫画会拿到新的 local id，
    // 而合集里的成员仍指着旧 id ⇒ 合集里会躺着两本一样的书。
    for (final old in List<CollectionMember>.from(target.members)) {
      if (old.cachedTitle == title && old.comicId != comic.id) {
        ComicCollectionStore.removeMember(
          target.id,
          old.sourceKey,
          old.comicId,
        );
      }
    }
    final member = CollectionMember(
      sourceKey: comic.sourceKey,
      comicId: comic.id,
      displayName: '',
      cachedTitle: comic.title,
      cachedSubtitle: comic.subtitle,
      cachedCover: comic.cover,
    );
    ComicCollectionStore.addMembers(target.id, [member]);
    ComicCollectionStore.update(
      target.id,
      displayMode: mode,
    );
    collectionId = target.id;
  }

  // 🔴 合集写盘走 `appdata.saveData()`（**没有 await** 的 fire-and-forget），
  // 而 headless 进程马上就退 ⇒ 写还没落盘进程就没了 ⇒ "命令报告成功、磁盘上
  // 什么都没有"。这里显式等它落完。
  await appdata.saveData();
  await appdata.flushImplicitData();

  final report = {
    'command': 'local-comic-make',
    'id': comic.id,
    'directory': dir,
    'title': comic.title,
    'chapters': comic.chapters?.length ?? 0,
    'downloaded': comic.downloadedChapters.length,
    'cover': comic.cover,
    'addedChapters': added,
    'collectionId': collectionId,
    'collectionName': collectionName,
  };
  _print({'status': 'running', 'message': 'Local comic ready', 'data': report});
  _print({
    'status': 'success',
    'message': 'Local comic ready: ${comic.title} '
        '(${comic.downloadedChapters.length} chapters)',
    'data': report,
  });
  if (outPath.isNotEmpty) {
    final file = File(outPath);
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(report));
  }
  Log.info('LocalComicMake', 'id=${comic.id} dir=$dir');
}

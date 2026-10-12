import 'dart:async' show Future;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mangrove/foundation/bt_project/bt_project_manager.dart';
import 'package:mangrove/foundation/local.dart';
import 'package:mangrove/utils/io.dart';
import 'base_image_provider.dart';
import 'local_comic_image.dart' as image_provider;

class LocalComicImageProvider
    extends BaseImageProvider<image_provider.LocalComicImageProvider> {
  /// Image provider for normal image.
  ///
  /// [url] is the url of the image. Local file path is also supported.
  const LocalComicImageProvider(this.comic);

  final LocalComic comic;

  @override
  Future<Uint8List> load(chunkEvents, checkStop) async {
    // 🔴 `bt_` 工程卡片的封面**不能**走下面的 `comic.coverFile` 兜底。
    //
    // 工程 json 的 `directory` 指向 `<工程根>/source/`（原图副本），而封面
    // `cover.<ext>` 落在**工程根**（与 json 同级）。`comic.coverFile` 只会拼
    // `directory/cover.<ext>` = `source/cover.<ext>` ⇒ 永远 miss，然后回落到
    // "扫 `source/` 里的第一张图" ⇒ 工程卡片一直拿**章节第一页**当封面
    // （实测：AsuraScans 的版权页，而不是漫画封面）。
    //
    // 封面规则只有一个 owner（`BtProjectManager.coverPathFor`：先 `source/`
    // 再工程根，都没有才回落 `pageOrder` 第一页）。这里直接问它，别自己再拼
    // 一条路径 —— 两处各拼一次，下一次改封面落点就会漏掉一处。
    if (BtProjectManager.isBtComic(comic.id)) {
      final cover = await BtProjectManager().loadCover(comic.id);
      if (cover != null && cover.bytes.isNotEmpty) {
        checkStop();
        return cover.bytes;
      }
    }

    // A placeholder for a queued download task (merged into the local comics
    // grid before it is scheduled) has no directory yet. Its `baseDir` would
    // resolve to the downloads root, and the fallback scan below would then
    // return the first downloaded comic's cover for EVERY such placeholder
    // (issue #53). Without a real own directory there is no cover to load.
    if (comic.directory.isEmpty) {
      throw "Error: Cover not found.";
    }
    File? file = comic.coverFile;
    if(! await file.exists()) {
      file = null;
      var dir = Directory(comic.baseDir);
      if (! await dir.exists()) {
        throw "Error: Comic not found.";
      }
      Directory? firstDir;
      await for (var entity in dir.list()) {
        if(entity is File) {
          if(["jpg", "jpeg", "png", "webp", "gif", "jpe", "jpeg"].contains(entity.extension)) {
            file = entity;
            break;
          }
        } else if(entity is Directory) {
          firstDir ??= entity;
        }
      }
      if(file == null && firstDir != null) {
        await for (var entity in firstDir.list()) {
          if(entity is File) {
            if(["jpg", "jpeg", "png", "webp", "gif", "jpe", "jpeg"].contains(entity.extension)) {
              file = entity;
              break;
            }
          }
        }
      }
    }
    if(file == null) {
      throw "Error: Cover not found.";
    }
    checkStop();
    var data = await file.readAsBytes();
    if(data.isEmpty) {
      throw "Exception: Empty file(${file.path}).";
    }
    return data;
  }

  @override
  Future<LocalComicImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  String get key => "local${comic.id}${comic.comicType.value}";
}

import 'dart:async' show Future;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera/foundation/bt_project/bt_project_manager.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/images.dart';
import '../history.dart';
import 'base_image_provider.dart';
import 'history_image_provider.dart' as image_provider;
import 'local_comic_image.dart';

class HistoryImageProvider
    extends BaseImageProvider<image_provider.HistoryImageProvider> {
  /// Image provider for normal image.
  ///
  /// [url] is the url of the image. Local file path is also supported.
  const HistoryImageProvider(this.history);

  final History history;

  @override
  Future<Uint8List> load(chunkEvents, checkStop) async {
    var url = history.cover;
    if (history.type == ComicType.local) {
      if (BtProjectManager.isBtComic(history.id)) {
        // A BT cover is a page key relative to the project dir (e.g.
        // `0/1.webp`), which contains a '/' and used to be handed straight to
        // the HTTP stack ("relative URL without a base"). The files can also
        // be replaced/deleted outside the app (a wrong export batch), so the
        // cover is resolved from the project itself and self-heals.
        final cover = await BtProjectManager().loadCover(history.id);
        checkStop();
        if (cover == null) {
          // Matches the base provider's permanent-error check so the tile
          // shows an error icon right away instead of retrying for 15s.
          throw "Cover not found.";
        }
        if (cover.key != history.cover) {
          history.cover = cover.key;
          HistoryManager().updateHistoryKeepingVisibility(history);
        }
        return cover.bytes;
      }
      var localComic = LocalManager().find(history.id, history.type);
      if (localComic != null) {
        // Delegate to the local provider so a missing/renamed cover file falls
        // back to scanning the comic directory (issue #38) instead of throwing
        // and leaving the history tile blank.
        return LocalComicImageProvider(localComic).load(chunkEvents, checkStop);
      }
      // A local-type history entry whose comic is gone (deleted, or synced
      // from another device — local files never travel with WebDAV sync,
      // issue #139). Only a stored remote URL can still be fetched; otherwise
      // fail cleanly instead of "Comic source not found".
      if (!url.startsWith('http')) {
        throw "Local comic not found.";
      }
    } else if (!url.contains('/')) {
      var comicSource =
          history.type.comicSource ?? (throw "Comic source not found.");
      var comic = await comicSource.loadComicInfo!(history.id);
      checkStop();
      url = comic.data.cover;
      history.cover = url;
      // Keep the row's list visibility: this fetch can land after the user
      // deleted the record, and a plain add would put it back (issue #270).
      HistoryManager().updateHistoryKeepingVisibility(history);
    }
    await for (var progress in ImageDownloader.loadThumbnail(
      url,
      history.type.sourceKey,
      history.id,
    )) {
      checkStop();
      chunkEvents.add(ImageChunkEvent(
        cumulativeBytesLoaded: progress.currentBytes,
        expectedTotalBytes: progress.totalBytes,
      ));
      if (progress.imageBytes != null) {
        return progress.imageBytes!;
      }
    }
    throw "Error: Empty response body.";
  }

  @override
  Future<HistoryImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  String get key => "history${history.id}${history.type.value}";

  /// [load] resolves a missing cover and writes it back to [History.cover]
  /// before downloading, so this matches what was actually fetched.
  @override
  String get diskCacheKey => ImageDownloader.thumbnailCacheKey(
    history.cover,
    history.type.sourceKey,
    history.id,
  );

  @override
  String? get fallbackUrl => history.cover;
}

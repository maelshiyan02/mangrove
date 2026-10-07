import 'dart:async';

import 'package:flutter/material.dart' show ImageChunkEvent;
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/image_provider/local_comic_image.dart';
import 'package:venera/foundation/local.dart';

/// Regression test for issue #53 (批量下载内容时封面显示错误).
///
/// A queued download task is merged into the local comics grid as a placeholder
/// [LocalComic] whose `directory`/`cover` are still empty (the task hasn't been
/// scheduled yet). Its `baseDir` then collapses to the downloads root, and the
/// fallback scan in [LocalComicImageProvider.load] used to return the first
/// downloaded comic's cover for EVERY such placeholder — so the local grid
/// showed one cover tiled across many comics, or comics wearing each other's
/// covers. With no real own directory there is nothing to load, so the provider
/// must short-circuit with "Cover not found" before scanning the downloads root.
///
/// The fix is the early `comic.directory.isEmpty` guard; these tests exercise
/// it. (Loading a real on-disk cover involves async `dart:io` reads that do not
/// settle inside the bare flutter_test isolate, so the legitimate-load paths are
/// not asserted here — the guard is the behavioural change under test.)
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  LocalComic placeholder(String cover) => LocalComic(
        id: 'queued-comic',
        title: 'Queued Comic',
        subtitle: '',
        tags: const [],
        directory: '', // not scheduled yet
        chapters: null,
        cover: cover,
        comicType: const ComicType(123),
        downloadedChapters: const [],
        createdAt: DateTime(2024),
      );

  Future<({Object? thrown, Object? bytes})> loadCover(LocalComic comic) async {
    try {
      final bytes = await LocalComicImageProvider(comic)
          .load(StreamController<ImageChunkEvent>(), () {});
      return (thrown: null, bytes: bytes);
    } catch (e) {
      return (thrown: e as Object?, bytes: null);
    }
  }

  test('placeholder with empty directory reports no cover', () async {
    final result = await loadCover(placeholder(''));
    expect(result.bytes, isNull,
        reason: 'must not resolve to another comic\'s cover bytes');
    expect(result.thrown?.toString() ?? '', contains('Cover not found'));
  });

  test('empty directory is rejected even when a cover filename is present',
      () async {
    final result = await loadCover(placeholder('cover.jpg'));
    expect(result.bytes, isNull);
    expect(result.thrown?.toString() ?? '', contains('Cover not found'));
  });
}

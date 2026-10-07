import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/bt_project/bt_project_manager.dart';

/// Minimal BT layout: `<root>/<comic>/0/{1,2,3}.webp` + imgtrans json with a
/// single chapter named "0" and a page_order that also carries stale jpg keys
/// whose files do not exist (the Error-the-Echo regression shape).
Future<File> writeManagerFixture(Directory root, String comic) async {
  final comicDir = Directory('${root.path}/$comic');
  await Directory('${comicDir.path}/0').create(recursive: true);
  for (final page in ['1.webp', '2.webp', '3.webp']) {
    await File('${comicDir.path}/0/$page').writeAsBytes([1, 2, 3]);
  }
  final json = {
    'directory': comicDir.path.replaceAll('\\', '/'),
    'pages': {
      '0/001.jpg': <dynamic>[],
      '0/002.jpg': <dynamic>[],
      '0/003.jpg': <dynamic>[],
      '0/1.webp': <dynamic>[],
      '0/2.webp': <dynamic>[],
      '0/3.webp': <dynamic>[],
    },
    'page_order': [
      '0/001.jpg',
      '0/1.webp',
      '0/002.jpg',
      '0/2.webp',
      '0/003.jpg',
      '0/3.webp',
    ],
    'chapters': [
      {
        'name': '0',
        'pages': [
          '0/001.jpg',
          '0/1.webp',
          '0/002.jpg',
          '0/2.webp',
          '0/003.jpg',
          '0/3.webp',
        ],
      },
    ],
  };
  final file = File('${comicDir.path}/imgtrans_$comic.json');
  await file.writeAsString(jsonEncode(json));
  return file;
}

/// Replicates [BtProjectManager]'s private path-hash so the test can address
/// the registered project (the production hash is a private static). It is
/// fed the exact path string a directory listing yields on the platform.
String comicIdFor(String jsonPath) {
  var hash = 0x811c9dc5;
  for (final unit in jsonPath.toLowerCase().codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return '${BtProjectManager.idPrefix}${hash.toRadixString(16).padLeft(8, '0')}';
}

void main() {
  setUpAll(() async {
    await appdata.init();
  });

  test(
      'scan caches projects without LocalManager; getImages/cover self-heal '
      'against missing files', () async {
    final tempRoot = await Directory.systemTemp.createTemp('bt_manager_test');
    addTearDown(() async {
      appdata.settings['btProjectRoot'] = '';
      await tempRoot.delete(recursive: true);
    });
    await writeManagerFixture(tempRoot, 'Error the Echo');
    appdata.settings['btProjectRoot'] = tempRoot.path;
    // The registered id hashes the OS-native path from a directory listing.
    String? listedJson;
    await for (final e in tempRoot.list(recursive: true)) {
      if (e is File && e.path.endsWith('.json')) listedJson = e.path;
    }
    final id = comicIdFor(listedJson!);

    final manager = BtProjectManager();
    await manager.scan();

    // No LocalManager().init() ran: the project must still serve pages.
    expect(manager.projectFor(id), isNotNull);
    final images = await manager.getImages(id, 1);
    expect(images.length, 3);
    expect(images.every((u) => u.startsWith('file://')), isTrue);
    expect(images.any((u) => u.endsWith('.jpg')), isFalse,
        reason: 'missing jpg keys are filtered out');

    final cover = await manager.loadCover(id);
    expect(cover, isNotNull);
    expect(cover!.key, '0/1.webp');
    expect(cover.bytes, isNotEmpty);

    // The first page file disappears (a wrong export batch was deleted):
    // cover and page listing move on to the remaining existing files without
    // any database involvement.
    await File('${tempRoot.path}/Error the Echo/0/1.webp').delete();
    expect((await manager.loadCover(id))!.key, '0/2.webp');
    expect((await manager.getImages(id, 1)).length, 2);
  });

  test('getImages throws and ensureProject resolves null under an empty root',
      () async {
    final tempRoot = await Directory.systemTemp.createTemp('bt_manager_empty');
    addTearDown(() async {
      appdata.settings['btProjectRoot'] = '';
      await tempRoot.delete(recursive: true);
    });
    appdata.settings['btProjectRoot'] = tempRoot.path;
    final manager = BtProjectManager();
    await manager.scan();
    expect(await manager.ensureProject('bt_deadbeef'), isNull);
    await expectLater(
      manager.getImages('bt_deadbeef', 1),
      throwsA(anything),
    );
  });
}

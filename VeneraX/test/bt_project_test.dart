import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/bt_project/bt_project.dart';

/// Builds a BT json fixture using the real key names observed in
/// proj_imgtrans.py output (directory/pages/page_order/chapters/workspace and
/// the TextBlock fields xyxy/lines/text/translation/_detected_font_size/
/// fontformat).
Map<String, dynamic> btJsonFixture({
  required String directory,
  String? workspace,
}) {
  return {
    'directory': directory,
    if (workspace != null) 'workspace': workspace,
    'pages': {
      '0/1.webp': [
        {
          'xyxy': [10, 20, 110, 220],
          'lines': [
            [
              [10, 20],
              [110, 20],
              [110, 220],
              [10, 220],
            ],
          ],
          'text': ['元のテキスト'],
          'translation': '第一行\n第二行',
          '_detected_font_size': 24.5,
          'fontformat': {
            'font_family': '',
            'font_size': 24.0,
            'frgb': [255, 0, 0],
            'srgb': [255, 255, 255],
            'alignment': 1,
            'vertical': 0,
          },
        },
        {
          // Untranslated block: must be skipped.
          'xyxy': [200, 20, 300, 120],
          'text': ['未翻訳'],
          'translation': '',
          '_detected_font_size': 18.0,
          'fontformat': {},
        },
      ],
      '0/2.webp': [
        {
          'xyxy': [5, 5, 50, 60],
          'text': ['色'],
          'translation': '颜色',
          '_detected_font_size': 16.0,
          'fontformat': {
            'frgb': [0, 255, 0],
            'srgb': [0, 0, 255],
          },
        },
      ],
      // Page without any translated block.
      '0/3.webp': [
        {'xyxy': [0, 0, 10, 10], 'text': ['x'], 'translation': ''},
      ],
    },
    'page_order': ['0/1.webp', '0/2.webp', '0/3.webp'],
    'image_info': {
      '0/1.webp': {'finish_code': 1},
    },
    'chapters': [
      {
        'name': '第1话',
        'pages': ['0/1.webp', '0/2.webp'],
      },
      {
        'name': '第2话',
        'pages': ['0/3.webp'],
      },
    ],
  };
}

/// Creates `root/<comic>/<chapter>/<page>` image files plus the imgtrans json,
/// mimicking BT's on-disk layout. Returns the json file.
Future<File> writeBtFixture(Directory root) async {
  final comicDir = Directory('${root.path}/Error the Echo');
  await Directory('${comicDir.path}/0').create(recursive: true);
  for (final page in ['1.webp', '2.webp', '3.webp']) {
    await File('${comicDir.path}/0/$page').writeAsBytes([1, 2, 3]);
  }
  final json = btJsonFixture(
    directory: comicDir.path.replaceAll('\\', '/'),
  );
  final file = File('${comicDir.path}/imgtrans_Error the Echo.json');
  await file.writeAsString(jsonEncode(json));
  return file;
}

void main() {
  late Directory tempRoot;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('bt_project_test');
  });

  tearDown(() async {
    await tempRoot.delete(recursive: true);
  });

  test('parses pages, order and chapters with real BT key names', () async {
    final file = await writeBtFixture(tempRoot);
    final project = await BtProject.load(file);

    expect(project.pageOrder, ['0/1.webp', '0/2.webp', '0/3.webp']);
    expect(project.chapters.keys, ['第1话', '第2话']);
    expect(project.chapters['第1话'], ['0/1.webp', '0/2.webp']);
    expect(project.chapters['第2话'], ['0/3.webp']);
  });

  test('blocks without translation are skipped, colors and size map', () async {
    final file = await writeBtFixture(tempRoot);
    final project = await BtProject.load(file);

    final regions = project.regionsFor('0/1.webp');
    expect(regions.length, 1); // the untranslated block is dropped
    final region = regions.single;
    expect(region.text, '第一行\n第二行');
    expect(region.rect.left, 10);
    expect(region.rect.top, 20);
    expect(region.rect.right, 110);
    expect(region.rect.bottom, 220);
    expect(region.lineHeight, 25); // 24.5 rounded
    expect(region.textColor, 0xFFFF0000); // frgb
    expect(region.backgroundColor, 0xFFFFFFFF); // srgb

    final page2 = project.regionsFor('0/2.webp').single;
    expect(page2.textColor, 0xFF00FF00);
    expect(page2.backgroundColor, 0xFF0000FF);

    expect(project.hasTranslation('0/3.webp'), isFalse);
    expect(project.regionsFor('missing.webp'), isEmpty);
  });

  test('falls back to json dir when stored directory is gone', () async {
    final file = await writeBtFixture(tempRoot);
    final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    raw['directory'] = 'Z:/definitely/not/here';
    raw['workspace'] = 'Z:/definitely/not/here/either';
    await file.writeAsString(jsonEncode(raw));

    final project = await BtProject.load(file);
    final expected = file.parent.absolute.path.replaceAll('\\', '/');
    expect(project.directory, expected);
    expect(project.workspace, expected);
  });

  test('pageKeysForChapter filters by existence and chapter pages', () async {
    final file = await writeBtFixture(tempRoot);
    final project = await BtProject.load(file);

    // 1-based chapter indexing, and 3.webp exists so both chapters resolve.
    expect(project.pageKeysForChapter(1), ['0/1.webp', '0/2.webp']);
    expect(project.pageKeysForChapter(2), ['0/3.webp']);
    expect(project.pageKeysForChapter(3), isEmpty);

    await File('${tempRoot.path}/Error the Echo/0/2.webp').delete();
    expect(project.pageKeysForChapter(1), ['0/1.webp']);
  });

  test('inpainted path follows <workspace>/inpainted/<stem>.png', () async {
    final file = await writeBtFixture(tempRoot);
    final project = await BtProject.load(file);

    // No inpainted dir yet.
    expect(project.inpaintedPath('0/1.webp'), isNull);

    final inpaintedDir = Directory(
      '${project.workspace}/inpainted/0'.replaceAll('/', '\\'),
    );
    await inpaintedDir.create(recursive: true);
    final inpainted = File('${inpaintedDir.path}/1.png');
    await inpainted.writeAsBytes([9]);
    expect(
      project.inpaintedPath('0/1.webp')!.replaceAll('\\', '/'),
      endsWith('/inpainted/0/1.png'),
    );
  });

  test('flat project without chapters serves page_order as one chapter',
      () async {
    final comicDir = Directory('${tempRoot.path}/flat');
    await comicDir.create(recursive: true);
    await File('${comicDir.path}/001.webp').writeAsBytes([1]);
    await File('${comicDir.path}/002.webp').writeAsBytes([1]);
    final json = {
      'directory': comicDir.path.replaceAll('\\', '/'),
      'pages': {
        '001.webp': [],
        '002.webp': [],
      },
      'page_order': ['002.webp', '001.webp'],
    };
    final file = File('${comicDir.path}/imgtrans_flat.json');
    await file.writeAsString(jsonEncode(json));

    final project = await BtProject.load(file);
    expect(project.chapters, isEmpty);
    expect(project.pageKeysForChapter(1), ['002.webp', '001.webp']);
    expect(project.pageKeysForChapter('001.webp'), ['002.webp', '001.webp']);
  });
}

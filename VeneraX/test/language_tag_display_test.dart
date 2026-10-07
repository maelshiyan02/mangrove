import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/favorites_meta.dart';
import 'package:venera/utils/translations.dart';

// A `language:` tag used to be classified as metadata and filtered out of the
// displayed tag list, but no view ever rendered it as metadata — so it vanished
// entirely (issue #288). These tests pin that it stays a content tag.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(AppTranslation.init);

  test('a language tag is classified as a content tag, not extra metadata', () {
    expect(classifyTag('language:chinese').bucket, TagBucket.tag);
    expect(classifyTag('Languages:japanese').bucket, TagBucket.tag);
    expect(classifyTag('lang:korean').bucket, TagBucket.tag);
    expect(classifyTag('语言:中文').bucket, TagBucket.tag);
    expect(classifyTag('語言:中文').bucket, TagBucket.tag);
  });

  test('a language tag keeps its value once classified', () {
    expect(classifyTag('language:chinese').value, 'chinese');
  });

  test('neighbouring metadata prefixes still route to extra metadata', () {
    expect(classifyTag('uploader:someone').bucket, TagBucket.extra);
    expect(classifyTag('source:somewhere').bucket, TagBucket.extra);
  });

  test('favoriting keeps a language tag in the tags bucket', () {
    final buckets = splitFavoriteTags([
      'language:chinese',
      'female:sole male',
      'uploader:someone',
    ]);
    expect(buckets.tags, containsAll(['chinese', 'sole male']));
    expect(buckets.extraMeta.containsKey('language'), isFalse);
    expect(buckets.extraMeta['uploader'], 'someone');
  });

  testWidgets('a comic tile shows the language in a row of its own', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 124,
            width: 300,
            child: ComicDescription(
              title: 'Comic',
              subtitle: 'Artist',
              description: '',
              enableTranslate: false,
              tags: ['female:sole male', 'language:chinese'],
            ),
          ),
        ),
      ),
    );

    // Its own labelled row, not merged into the tag row. The height given here
    // is the real default tile's, where only about three rows are drawn — so
    // this also pins that the row sits high enough to be visible at all.
    expect(find.text('Language'), findsOneWidget);
    expect(find.text('chinese'), findsOneWidget);
    expect(find.text('sole male'), findsOneWidget);
  });

  testWidgets('a tile without a language tag shows no language row', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 124,
            width: 300,
            child: ComicDescription(
              title: 'Comic',
              subtitle: 'Artist',
              description: '',
              enableTranslate: false,
              tags: ['female:sole male'],
            ),
          ),
        ),
      ),
    );

    expect(find.text('Language'), findsNothing);
    expect(find.text('sole male'), findsOneWidget);
  });

  testWidgets('an unbounded host draws every row, tags included', (
    tester,
  ) async {
    // The detail page puts this in a scroll view with no height limit, so the
    // row budget must not clip there — a language row plus a rating used to
    // push the tag row out entirely.
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ComicDescription(
              title: 'Comic',
              subtitle: 'Artist',
              description: '',
              enableTranslate: false,
              badge: 'Source',
              rating: 4.2,
              updateText: '2026-01-01',
              pagesText: '30',
              showTitle: false,
              tags: ['female:sole male', 'language:chinese'],
            ),
          ),
        ),
      ),
    );

    expect(find.text('Language'), findsOneWidget);
    expect(find.text('chinese'), findsOneWidget);
    expect(find.text('Tags'), findsOneWidget);
    expect(find.text('sole male'), findsOneWidget);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangrove/components/components.dart';
import 'package:mangrove/foundation/appdata.dart';
import 'package:mangrove/pages/reader/reader.dart';
import 'package:mangrove/utils/sync_skip.dart';
import 'package:mangrove/utils/translations.dart';

/// Guards the three R3 desktop extras. The step tables and the key predicate
/// are pure so they can be asserted without standing up a reader; the dialog
/// gets one widget test because "does it actually open" is the whole point.
void main() {
  group('help key', () {
    test('F1 and "?" open the sheet', () {
      expect(
        isReaderHelpKey(
          logicalKey: LogicalKeyboardKey.f1,
          character: null,
        ),
        isTrue,
      );
      expect(
        isReaderHelpKey(
          logicalKey: LogicalKeyboardKey.slash,
          character: '?',
        ),
        isTrue,
      );
    });

    test('every other key falls through to the page-turn handler', () {
      expect(
        isReaderHelpKey(logicalKey: LogicalKeyboardKey.f12, character: null),
        isFalse,
      );
      expect(
        isReaderHelpKey(logicalKey: LogicalKeyboardKey.slash, character: '/'),
        isFalse,
      );
      expect(
        isReaderHelpKey(logicalKey: LogicalKeyboardKey.keyA, character: 'a'),
        isFalse,
      );
    });
  });

  group('zoom cluster', () {
    test('gallery steps are multipliers, continuous steps are absolute', () {
      expect(zoomStepsFor(false).first, 1.0);
      expect(zoomStepsFor(false).last, kMaxZoomRatio);
      // Continuous is built with minScale 1.0, so no rung below 100%.
      expect(zoomStepsFor(true).every((s) => s >= 1.0), isTrue);
      expect(zoomStepsFor(true).last, kMaxZoomRatio);
    });

    test('steps up and down from the fit scale', () {
      const base = 2.0;
      expect(
        nextZoomTarget(
          current: base,
          base: base,
          continuous: false,
          zoomIn: true,
        ),
        closeTo(3.0, 1e-9),
      );
      expect(
        nextZoomTarget(
          current: base * 2.0,
          base: base,
          continuous: false,
          zoomIn: false,
        ),
        closeTo(base * 1.5, 1e-9),
      );
    });

    test('never leaves the [fit, fit × 2.5] window', () {
      const base = 1.0;
      // Already at the ceiling: zooming in must stay put rather than escape it.
      expect(
        nextZoomTarget(
          current: base * kMaxZoomRatio,
          base: base,
          continuous: false,
          zoomIn: true,
        ),
        closeTo(base * kMaxZoomRatio, 1e-9),
      );
      // A pinch can land off-rung; zooming out from below the first step still
      // clamps to fit instead of shrinking past it.
      expect(
        nextZoomTarget(
          current: base * 0.8,
          base: base,
          continuous: false,
          zoomIn: false,
        ),
        closeTo(base, 1e-9),
      );
    });

    test('labels read as multipliers in gallery and percentages in continuous',
        () {
      expect(formatZoomLabel(1.5, 1.0, false), '1.5x');
      expect(formatZoomLabel(1.0, 1.0, false), '1x');
      expect(formatZoomLabel(2.25, 1.0, false), '2.3x');
      expect(formatZoomLabel(1.25, null, true), '125%');
      // No controller yet (image loading): show the resting value, not a
      // stale one from another page.
      expect(formatZoomLabel(null, null, true), '100%');
      expect(formatZoomLabel(null, null, false), '1x');
    });
  });

  group('chapter end nav', () {
    const cid = 'test-comic';
    const sourceKey = 'test-source';

    tearDown(() {
      appdata.settings['readerShowChapterEndNav'] = true;
    });

    test('on by default in gallery, always off in continuous', () {
      appdata.settings['readerShowChapterEndNav'] = true;
      expect(
        readerChapterEndNavEnabled(
          mode: ReaderMode.galleryLeftToRight,
          cid: cid,
          sourceKey: sourceKey,
        ),
        isTrue,
      );
      // Seamless continuous crosses chapters on its own; a card would
      // interrupt that.
      for (final mode in ReaderMode.values.where((m) => m.isContinuous)) {
        expect(
          readerChapterEndNavEnabled(
            mode: mode,
            cid: cid,
            sourceKey: sourceKey,
          ),
          isFalse,
          reason: mode.key,
        );
      }
    });

    test('the switch turns it off', () {
      appdata.settings['readerShowChapterEndNav'] = false;
      expect(
        readerChapterEndNavEnabled(
          mode: ReaderMode.galleryTopToBottom,
          cid: cid,
          sourceKey: sourceKey,
        ),
        isFalse,
      );
    });
  });

  group('sync classification', () {
    test('both new reader keys belong to the reading category', () {
      final reading = syncSkipCategories.firstWhere((c) => c.id == 'reading');
      expect(reading.keys, contains('readerShowZoomBar'));
      expect(reading.keys, contains('readerShowChapterEndNav'));
    });
  });

  group('help dialog', () {
    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      await AppTranslation.init();
    });

    testWidgets('F1 opens it, F12 does not', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: _KeyHarness()));
      expect(find.byType(ReaderHelpDialog), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.f12);
      await tester.pumpAndSettle();
      expect(find.byType(ReaderHelpDialog), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.f1);
      await tester.pumpAndSettle();
      expect(find.byType(ReaderHelpDialog), findsOneWidget);
      // The key it documents must actually be listed.
      expect(find.text('F12'), findsOneWidget);
    });
  });
}

/// A minimal host that routes key events exactly like the reader does.
class _KeyHarness extends StatelessWidget {
  const _KeyHarness();

  @override
  Widget build(BuildContext context) {
    return KeyboardListener(
      focusNode: FocusNode(),
      autofocus: true,
      onKeyEvent: (event) {
        if (event is KeyDownEvent &&
            isReaderHelpKey(
              logicalKey: event.logicalKey,
              character: event.character,
            )) {
          showReaderHelpDialog(context);
        }
      },
      child: const Scaffold(body: SizedBox.expand()),
    );
  }
}

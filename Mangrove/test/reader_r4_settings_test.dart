import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangrove/foundation/appdata.dart';
import 'package:mangrove/pages/reader/reader.dart';
import 'package:mangrove/utils/sync_skip.dart';

/// Guards the P47 R4 setting batch.
///
/// 这一阶段的五个键全部走"纯逻辑层 + 一处消费点"的形状，所以断言主要打在
/// `reader_filters.dart` 上：默认值、边界钳制、枚举回落、以及三种显隐策略
/// 各自该放行/该拦下的手势组合。再补一条 appdata 默认值表，防止有人只改了
/// 设置页却忘了给新键落默认。
void main() {
  group('chapter capsule', () {
    test('defaults off, and only a literal true turns it on', () {
      expect(readerChapterCapsuleEnabled(null), isFalse);
      expect(readerChapterCapsuleEnabled(false), isFalse);
      expect(readerChapterCapsuleEnabled('true'), isFalse);
      expect(readerChapterCapsuleEnabled(true), isTrue);
    });

    test('narrow windows keep the two-line title', () {
      // The threshold exists to protect the three button groups on the right
      // of the top bar; a capsule squeezed in beside them is a net loss.
      expect(kChapterCapsuleMinWidth, greaterThan(0));
      expect(kChapterCapsuleMinWidth, lessThan(800));
    });
  });

  group('greyscale', () {
    test('defaults off', () {
      expect(readerGreyscaleEnabled(null), isFalse);
      expect(readerGreyscaleEnabled(true), isTrue);
    });

    test('the matrix is a real BT.709 luminance fold with alpha untouched', () {
      // `ColorFilter` keeps its matrix private, so the assertion bites on the
      // source array the filter is built from.
      final matrix = kReaderGreyscaleMatrix;
      expect(matrix.length, 20);
      // All three colour rows use the same luminance weights.
      for (final row in <int>[0, 5, 10]) {
        expect(matrix[row + 0], closeTo(0.2126, 1e-9));
        expect(matrix[row + 1], closeTo(0.7152, 1e-9));
        expect(matrix[row + 2], closeTo(0.0722, 1e-9));
      }
      // Alpha row: 0 0 0 1 0 — saturating would tint transparent regions.
      expect(matrix.sublist(15, 20), <double>[0, 0, 0, 1, 0]);
    });
  });

  group('dim strength', () {
    test('clamps into 0 .. 0.4 and survives junk', () {
      expect(readerDimStrength(null), 0.0);
      expect(readerDimStrength(0), 0.0);
      expect(readerDimStrength(0.25), 0.25);
      expect(readerDimStrength(5), kReaderDimStrengthMax);
      expect(readerDimStrength(-1), 0.0);
      expect(readerDimStrength(double.nan), 0.0);
      expect(readerDimStrength('x'), 0.0);
    });

    test('stays well below the night-mode tint ceiling', () {
      // Two different knobs: the night tint recolours (up to 0.85), dim only
      // lowers brightness. If dim ever reaches the tint's range the pair stops
      // being meaningfully distinct.
      expect(kReaderDimStrengthMax, lessThan(0.85));
    });
  });

  group('chrome hide trigger', () {
    test('unknown values fall back to tapCenter (the current behaviour)', () {
      expect(resolveReaderChromeHideTrigger(null), ReaderChromeHideTrigger.tapCenter);
      expect(
        resolveReaderChromeHideTrigger('nonsense'),
        ReaderChromeHideTrigger.tapCenter,
      );
      expect(
        resolveReaderChromeHideTrigger('singleTapAnywhere'),
        ReaderChromeHideTrigger.singleTapAnywhere,
      );
      expect(
        resolveReaderChromeHideTrigger('doubleTap'),
        ReaderChromeHideTrigger.doubleTap,
      );
    });

    test('tapCenter: single tap toggles the bars and still turns pages', () {
      const t = ReaderChromeHideTrigger.tapCenter;
      expect(readerSingleTapTogglesChrome(t), isTrue);
      expect(readerSingleTapTurnsPage(t), isTrue);
      expect(readerDoubleTapTogglesChrome(t), isFalse);
    });

    test('singleTapAnywhere: single tap owns the toggle, so it stops turning', () {
      const t = ReaderChromeHideTrigger.singleTapAnywhere;
      expect(readerSingleTapTogglesChrome(t), isTrue);
      // The whole point of the mode: page turning moves to swipe/wheel/keys.
      expect(readerSingleTapTurnsPage(t), isFalse);
      expect(readerDoubleTapTogglesChrome(t), isFalse);
    });

    test('doubleTap: single tap is demoted, double tap takes over', () {
      const t = ReaderChromeHideTrigger.doubleTap;
      expect(readerSingleTapTogglesChrome(t), isFalse);
      expect(readerSingleTapTurnsPage(t), isTrue);
      expect(readerDoubleTapTogglesChrome(t), isTrue);
    });

    test('every trigger leaves exactly one way to toggle the bars', () {
      for (final t in ReaderChromeHideTrigger.values) {
        expect(
          readerSingleTapTogglesChrome(t) || readerDoubleTapTogglesChrome(t),
          isTrue,
          reason: '$t leaves no gesture that can bring the bars back',
        );
      }
    });
  });

  group('auto play', () {
    test('defaults to the page timer so existing installs are unchanged', () {
      expect(resolveReaderAutoPlayMode(null), ReaderAutoPlayMode.page);
      expect(resolveReaderAutoPlayMode('scroll'), ReaderAutoPlayMode.scroll);
      expect(resolveReaderAutoPlayMode('weird'), ReaderAutoPlayMode.page);
    });

    test('scroll speed clamps into 20 .. 1200 px/s', () {
      expect(readerAutoScrollSpeed(null), 150.0);
      expect(readerAutoScrollSpeed(0), kReaderAutoScrollSpeedMin);
      expect(readerAutoScrollSpeed(10000), kReaderAutoScrollSpeedMax);
      expect(readerAutoScrollSpeed(double.nan), 150.0);
      expect(readerAutoScrollSpeed(-5), kReaderAutoScrollSpeedMin);
    });

    test('one tick moves less than a screen at the default speed', () {
      final perTick =
          readerAutoScrollSpeed(null) *
          (kReaderAutoScrollTick.inMilliseconds / 1000.0);
      // 15px per 100ms — fine-grained enough to read as motion, not jumps.
      expect(perTick, closeTo(15.0, 1e-9));
      expect(perTick, lessThan(100));
    });
  });

  group('settings keys', () {
    test('every R4 key has the documented default', () {
      final settings = appdata.settings;
      expect(settings['readerChapterCapsule'], false);
      expect(settings['readerGreyscale'], false);
      expect(settings['readerDimStrength'], 0.0);
      expect(settings['readerChromeHideTrigger'], 'tapCenter');
      expect(settings['readerAutoPlayMode'], 'page');
      expect(settings['autoScrollSpeed'], 150.0);
    });

    test('every R4 key is classified for sync', () {
      // Unclassified new keys fail sync_skip_test outright, and unclassified
      // *reading* keys additionally get overwritten across devices.
      final reading = syncSkipCategories.firstWhere((c) => c.id == 'reading');
      for (final key in const <String>[
        'readerChapterCapsule',
        'readerGreyscale',
        'readerDimStrength',
        'readerChromeHideTrigger',
        'readerAutoPlayMode',
        'autoScrollSpeed',
      ]) {
        expect(
          reading.keys,
          contains(key),
          reason: '$key is missing from sync_skip.dart',
        );
      }
    });
  });
}

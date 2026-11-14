import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangrove/foundation/appdata.dart';
import 'package:mangrove/foundation/reader_ux_policy.dart';
import 'package:mangrove/pages/reader/reader.dart';
import 'package:mangrove/utils/sync_skip.dart';

/// Guards the P47 R4 setting batch.
///
/// 这一阶段的键全部走"纯逻辑层 + 一处消费点"的形状，所以断言主要打在
/// `reader_filters.dart` 上：默认值、边界钳制、以及 appdata 默认值表，
/// 防止有人只改了设置页却忘了给新键落默认。
/// P57.x 起顶/底工具栏删除，"显隐触发"整组策略已退役，对应断言随功能一起移除；
/// 作为补充，这里新增缩放百分比读数的断言（标签与输入框预填必须同源）。
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

  // 「chrome hide trigger」整组已随顶/底工具栏退役（P57.x）删除：
  // 工具栏不存在了，三个档位没有可切换的对象。对应的纯函数一并从
  // `reader_filters.dart` 移除；`readerChromeHideTrigger` 这个设置键仍保留在
  // appdata 默认值里（见下方 settings-defaults 组），只为兼容旧配置。

  group('zoom percentage', () {
    test('is measured against the fit scale, not the absolute scale', () {
      // gallery 满屏时绝对 scale 只有 0.42，读数必须仍是 100%。
      expect(zoomPercentOf(0.42, 0.42), 100);
      expect(zoomPercentOf(0.63, 0.42), 150);
      // 连续模式 base = 1.0，两者一致。
      expect(zoomPercentOf(2.5, 1.0), 250);
      // 尚未拿到 controller 时按 1x 报数，不能显示 0%。
      expect(zoomPercentOf(null, 0.42), 100);
      expect(zoomPercentOf(1.0, null), 100);
      // 坏值不许抛 / 不许给出 0。
      expect(zoomPercentOf(double.nan, 1.0), 100);
      expect(zoomPercentOf(1.0, 0.0), 100);
    });

    test('the label and the input box prefill share one formula', () {
      // 这条是回归线：预填值曾经直接用绝对 scale×100，gallery 满屏填成 42。
      for (final base in <double>[0.42, 0.75, 1.0]) {
        for (final scale in <double>[base, base * 1.5, base * 2.5]) {
          expect(
            formatZoomLabel(scale, base, true),
            '${zoomPercentOf(scale, base)}%',
          );
        }
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

  group('side toolbar (R5)', () {
    test('defaults off so existing installs are unchanged', () {
      expect(appdata.settings['readerSideToolbar'], false);
      // Reverse case: a literal true must flip it on (the scaffold gates the
      // slide-in on exactly this value).
      expect(appdata.settings['readerSideToolbar'] == true, isFalse);
    });

    test('the key is classified for sync', () {
      // Same rationale as R4: an unclassified reading key gets overwritten by
      // the web/other-device preference and silently resets the toggle.
      final reading = syncSkipCategories.firstWhere((c) => c.id == 'reading');
      expect(
        reading.keys,
        contains('readerSideToolbar'),
        reason: 'readerSideToolbar is missing from sync_skip.dart',
      );
    });
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangrove/foundation/appdata.dart';
import 'package:mangrove/pages/reader/reader.dart';

void main() {
  const scheme = ColorScheme.light();

  group('pageRailMetrics', () {
    test('splits the rail height evenly with 1dp gaps between segments', () {
      final m = pageRailMetrics(900, 100);
      expect(m.scrollable, isFalse);
      // (900 - 99 gaps) / 100
      expect(m.segmentHeight, closeTo(8.01, 1e-9));
      expect(m.separator, 1.0);
      expect(m.stride, closeTo(9.01, 1e-9));
      // Everything fits: content height equals the rail height exactly.
      expect(m.contentHeight(100), closeTo(900, 1e-9));
    });

    test('single page takes the whole rail', () {
      final m = pageRailMetrics(600, 1);
      expect(m.scrollable, isFalse);
      expect(m.segmentHeight, 600);
      expect(m.contentHeight(1), 600);
    });

    test('falls back to internal scrolling when segments would vanish', () {
      // 500 pages in 900dp is ~0.8dp per page: below the 2dp floor.
      final m = pageRailMetrics(900, 500);
      expect(m.scrollable, isTrue);
      expect(m.segmentHeight, kPageRailMinSegHeight);
      expect(m.contentHeight(500), greaterThan(900));
    });

    test('survives a degenerate rail height before the first layout', () {
      final m = pageRailMetrics(0, 30);
      expect(m.scrollable, isTrue);
      expect(m.segmentHeight, kPageRailMinSegHeight);
    });

    test('a page count of zero behaves like one page', () {
      final m = pageRailMetrics(400, 0);
      expect(m.segmentHeight, 400);
      expect(m.scrollable, isFalse);
    });
  });

  group('pageRailSegmentColor', () {
    Color colorFor({
      required int index,
      required int currentPage,
      required int maxVisited,
      bool hovered = false,
    }) {
      return pageRailSegmentColor(
        index: index,
        currentPage: currentPage,
        maxVisited: maxVisited,
        hovered: hovered,
        colorScheme: scheme,
      );
    }

    test('current page is solid primary', () {
      expect(
        colorFor(index: 7, currentPage: 7, maxVisited: 9),
        scheme.primary,
      );
    });

    test('visited pages are primary at 55%', () {
      expect(
        colorFor(index: 3, currentPage: 7, maxVisited: 9),
        scheme.primary.withValues(alpha: 0.55),
      );
    });

    test('the max-visited page itself still counts as visited', () {
      expect(
        colorFor(index: 9, currentPage: 7, maxVisited: 9),
        scheme.primary.withValues(alpha: 0.55),
      );
    });

    test('unread pages are a faint on-surface-variant', () {
      expect(
        colorFor(index: 12, currentPage: 7, maxVisited: 9),
        scheme.onSurfaceVariant.withValues(alpha: 0.18),
      );
    });

    test('hover promotes any segment to solid primary', () {
      expect(
        colorFor(index: 12, currentPage: 7, maxVisited: 9, hovered: true),
        scheme.primary,
      );
    });

    test('the current page beats the visited colour', () {
      // Regression guard: swapping the two branches would paint the current
      // page translucent while everything around it stays solid.
      final visited = scheme.primary.withValues(alpha: 0.55);
      expect(
        colorFor(index: 7, currentPage: 7, maxVisited: 7),
        isNot(visited),
      );
      expect(colorFor(index: 7, currentPage: 7, maxVisited: 7), scheme.primary);
    });
  });

  test('the rail is opt-in: bottom slider stays the default', () {
    expect(appdata.settings['readerProgressBarPosition'], 'bottom');
  });
}

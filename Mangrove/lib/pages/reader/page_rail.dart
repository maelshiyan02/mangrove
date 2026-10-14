part of 'reader.dart';

/// Width of the edge page rail's hit area (desktop only).
///
/// Wide enough to aim at without precision, narrow enough to stay out of the
/// page. Mirrors comix's `.rpage-progress--left`.
const double kPageRailWidth = 24.0;

/// Segment width while the rail is idle.
const double kPageRailCollapsedSegWidth = 3.0;

/// Gap between segments. It is a real transparent gap, not a drawn line, so
/// whatever the reader background is (white / gray / black / sepia / green)
/// shows through and carves the separation — same trick comix uses with
/// `border-bottom: 1px solid var(--bg)`.
const double kPageRailSeparator = 1.0;

/// Floor for a single segment. Below this the rail scrolls internally instead
/// of shrinking segments into invisibility.
const double kPageRailMinSegHeight = 2.0;

const Duration _kPageRailExpandDuration = Duration(milliseconds: 180);

/// Geometry of the rail for a given available height and page count.
class PageRailMetrics {
  const PageRailMetrics({
    required this.segmentHeight,
    required this.separator,
    required this.scrollable,
  });

  final double segmentHeight;
  final double separator;

  /// True when there are more pages than the height can show at
  /// [kPageRailMinSegHeight]; the rail then scrolls internally, aligned to the
  /// current page.
  final bool scrollable;

  /// Vertical distance from one segment's top to the next one's top.
  double get stride => segmentHeight + separator;

  double contentHeight(int pageCount) =>
      pageCount * segmentHeight + (pageCount - 1) * separator;
}

/// Splits [railHeight] across [pageCount] segments.
PageRailMetrics pageRailMetrics(double railHeight, int pageCount) {
  final count = pageCount < 1 ? 1 : pageCount;
  final height = railHeight.isFinite && railHeight > 0 ? railHeight : 0.0;
  final perPage = (height - (count - 1) * kPageRailSeparator) / count;
  if (perPage >= kPageRailMinSegHeight) {
    return PageRailMetrics(
      segmentHeight: perPage,
      separator: kPageRailSeparator,
      scrollable: false,
    );
  }
  return const PageRailMetrics(
    segmentHeight: kPageRailMinSegHeight,
    separator: kPageRailSeparator,
    scrollable: true,
  );
}

/// Three-state colour of a rail segment.
///
/// comix drives the same trio from one `--accent` variable; here it comes from
/// the active [colorScheme], so a theme change repaints the rail for free.
Color pageRailSegmentColor({
  required int index,
  required int currentPage,
  required int maxVisited,
  required bool hovered,
  required ColorScheme colorScheme,
}) {
  if (hovered || index == currentPage) {
    return colorScheme.primary;
  }
  if (index <= maxVisited) {
    return colorScheme.primary.withValues(alpha: 0.55);
  }
  return colorScheme.onSurfaceVariant.withValues(alpha: 0.18);
}

/// Edge progress rail: collapsed to a hairline, expands on hover, shows a page
/// number bubble, and jumps to any page on click.
///
/// It shares the bottom slider's data source — `context.reader`'s page /
/// `maxPage` — and its refresh path (`readerScaffold.update()`). There is no
/// second copy of reading progress.
class ReaderPageRail extends StatefulWidget {
  const ReaderPageRail({super.key});

  @override
  State<ReaderPageRail> createState() => _ReaderPageRailState();
}

class _ReaderPageRailState extends State<ReaderPageRail> {
  bool _expanded = false;

  /// 1-based hovered segment, or 0 for none.
  int _hoverIndex = 0;

  /// Last pointer position inside the rail, used to place the bubble.
  double _pointerDy = 0;

  /// Highest page reached in the current chapter. Grows monotonically so
  /// flipping back doesn't erase the read run — same semantics as comix's
  /// `.is-visited`.
  int _maxVisited = 0;
  String _visitedChapterKey = '';

  final ScrollController _scrollController = ScrollController();
  String _alignedChapterKey = '';

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  String _chapterKey() => '${context.reader.eid}#${context.reader.chapter}';

  void _syncVisited(String chapterKey, int currentPage) {
    if (chapterKey != _visitedChapterKey) {
      _visitedChapterKey = chapterKey;
      _maxVisited = currentPage;
    } else if (currentPage > _maxVisited) {
      _maxVisited = currentPage;
    }
  }

  /// Brings the current page into view in the scrolling (high density) rail.
  ///
  /// Only runs when the chapter changes or on first build — realigning on every
  /// page change would yank the rail back while the reader is scrolling it by
  /// hand.
  void _scheduleAlign({
    required String chapterKey,
    required double railHeight,
    required PageRailMetrics metrics,
    required int pageCount,
    required int currentPage,
  }) {
    if (_alignedChapterKey == chapterKey) return;
    _alignedChapterKey = chapterKey;
    final maxOffset = metrics.contentHeight(pageCount) - railHeight;
    if (maxOffset <= 0) return;
    final target =
        (currentPage - 1) * metrics.stride -
        railHeight / 2 +
        metrics.segmentHeight / 2;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.jumpTo(target.clamp(0.0, maxOffset));
    });
  }

  @override
  Widget build(BuildContext context) {
    final reader = context.reader;
    // 🔴 maxPage, not totalPages: totalPages counts the chapter-comments page
    // that gallery LTR/RTL can append, which would draw one dead segment past
    // the last image.
    final pageCount = reader.maxPage;
    if (pageCount < 1) return const SizedBox.shrink();

    final currentPage = reader.page.clamp(1, pageCount);
    final chapterKey = _chapterKey();
    _syncVisited(chapterKey, currentPage);
    final colorScheme = context.colorScheme;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        if (!_expanded) setState(() => _expanded = true);
      },
      onExit: (_) {
        if (_expanded || _hoverIndex != 0) {
          setState(() {
            _expanded = false;
            _hoverIndex = 0;
          });
        }
      },
      onHover: (event) {
        if (_hoverIndex != 0) setState(() => _pointerDy = event.localPosition.dy);
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final metrics = pageRailMetrics(constraints.maxHeight, pageCount);
          if (metrics.scrollable) {
            _scheduleAlign(
              chapterKey: chapterKey,
              railHeight: constraints.maxHeight,
              metrics: metrics,
              pageCount: pageCount,
              currentPage: currentPage,
            );
          }

          final children = <Widget>[];
          for (var i = 1; i <= pageCount; i++) {
            children.add(
              _buildSegment(
                index: i,
                metrics: metrics,
                currentPage: currentPage,
                colorScheme: colorScheme,
              ),
            );
            if (i < pageCount) {
              children.add(SizedBox(height: metrics.separator));
            }
          }

          final column = Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: children,
          );

          return Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: metrics.scrollable
                    ? SingleChildScrollView(
                        controller: _scrollController,
                        child: column,
                      )
                    : column,
              ),
              if (_hoverIndex > 0)
                _buildBubble(_hoverIndex, constraints.maxHeight),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSegment({
    required int index,
    required PageRailMetrics metrics,
    required int currentPage,
    required ColorScheme colorScheme,
  }) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hoverIndex = index),
      onExit: (_) {
        if (_hoverIndex == index) setState(() => _hoverIndex = 0);
      },
      child: GestureDetector(
        // Opaque so the 3px collapsed strip and the transparent gaps still win
        // the hit test against the reader's own tap-to-turn-page layer.
        behavior: HitTestBehavior.opaque,
        onTap: () => context.reader.toPage(index),
        child: AnimatedContainer(
          duration: _kPageRailExpandDuration,
          curve: Curves.easeOut,
          width: _expanded ? kPageRailWidth : kPageRailCollapsedSegWidth,
          height: metrics.segmentHeight,
          color: pageRailSegmentColor(
            index: index,
            currentPage: currentPage,
            maxVisited: _maxVisited,
            hovered: _hoverIndex == index,
            colorScheme: colorScheme,
          ),
        ),
      ),
    );
  }

  Widget _buildBubble(int page, double railHeight) {
    final colorScheme = context.colorScheme;
    const bubbleHeight = 22.0;
    final maxTop = railHeight - bubbleHeight;
    final top = (_pointerDy - bubbleHeight / 2).clamp(
      0.0,
      maxTop < 0 ? 0.0 : maxTop,
    );
    return Positioned(
      left: kPageRailWidth + 4,
      top: top,
      child: IgnorePointer(
        child: AnimatedOpacity(
          opacity: 1,
          duration: const Duration(milliseconds: 150),
          child: Container(
            height: bubbleHeight,
            padding: const EdgeInsets.symmetric(horizontal: 5),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: colorScheme.inverseSurface,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              '$page',
              style: TextStyle(
                fontSize: 12,
                height: 1,
                color: colorScheme.onInverseSurface,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

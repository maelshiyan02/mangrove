import 'dart:io';

import 'package:flutter/material.dart';

import 'package:venera/components/text_block_canvas.dart';
import 'package:venera/foundation/translation_project/project.dart';
import 'package:venera/utils/translations.dart';

/// Continuous read-through preview of a whole project (P6 S7, step 6).
///
/// This is FT's `continuous_canvas.py` in miniature: the browsing view is
/// deliberately **not** the editing canvas. It stacks every page top to bottom
/// in one scrollable, and `ListView.builder` gives the virtualisation for free —
/// only the pages near the viewport hold a decoded `ui.Image`, so a 200-page
/// project costs the same as a 3-page one.
///
/// Three decisions are lifted from FT's own long canvas:
/// * show the text-free `inpainted/` page by default, fall back to the original;
/// * keep the boxes hidden — this view is for reading, not for selecting;
/// * lay the pages out with **zero gap** so a webtoon reads as one strip.
class StudioPreviewPage extends StatefulWidget {
  const StudioPreviewPage({
    super.key,
    required this.project,
    required this.pageKeys,
    this.startIndex = 0,
  });

  final TranslationProject project;
  final List<String> pageKeys;
  final int startIndex;

  @override
  State<StudioPreviewPage> createState() => _StudioPreviewPageState();
}

class _StudioPreviewPageState extends State<StudioPreviewPage> {
  final ScrollController _controller = ScrollController();
  bool _showBoxes = false;
  double _width = 640;

  /// Row height per page, in logical pixels, keyed by page key.
  final Map<String, double> _heights = {};

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToStart());
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  void _onScroll() {
    // Rebuilding on every scroll tick would repaint the whole strip; the only
    // thing that changes is the "page N of M" chip, so it waits for the
    // visible index to actually move.
    final index = _currentIndex;
    if (index == _lastReportedIndex) return;
    _lastReportedIndex = index;
    setState(() {});
  }

  int _lastReportedIndex = -1;

  int get _currentIndex {
    if (widget.pageKeys.isEmpty) return 0;
    final position = _controller.hasClients ? _controller.position.pixels : 0.0;
    var acc = 0.0;
    for (var i = 0; i < widget.pageKeys.length; i++) {
      acc += _heights[widget.pageKeys[i]] ?? _fallbackHeight;
      if (position < acc) return i;
    }
    return widget.pageKeys.length - 1;
  }

  double get _fallbackHeight => _width * 1.4;

  void _jumpToStart() {
    if (!_controller.hasClients) return;
    if (widget.startIndex <= 0) return;
    var acc = 0.0;
    for (var i = 0; i < widget.startIndex; i++) {
      acc += _heights[widget.pageKeys[i]] ?? _fallbackHeight;
    }
    _controller.jumpTo(acc);
  }

  /// Page geometry from FT's own `image_info`, so the strip can be laid out
  /// before a single byte of image data is read.
  double _heightFor(String key) {
    final cached = _heights[key];
    if (cached != null) return cached;
    final info = widget.project.imageInfo[key];
    final width = info is Map ? (info['width'] as num?)?.toDouble() : null;
    final height = info is Map ? (info['height'] as num?)?.toDouble() : null;
    final ratio = (width != null && height != null && width > 0)
        ? height / width
        : 1.4;
    // Clamp: a 1px-wide or absurdly tall entry in image_info would otherwise
    // produce a row that is either invisible or eats the whole viewport.
    final resolved = _width * ratio.clamp(0.2, 8.0).toDouble();
    _heights[key] = resolved;
    return resolved;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        title: Text('Continuous preview'.tl),
        actions: [
          IconButton(
            tooltip: (_showBoxes ? 'Hide text boxes' : 'Show text boxes').tl,
            icon: Icon(
              _showBoxes ? Icons.check_box : Icons.check_box_outline_blank,
            ),
            onPressed: () => setState(() => _showBoxes = !_showBoxes),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          // A comic page is read at whatever width the window allows; the cap
          // keeps a 4K monitor from producing unreadable 3000px-wide rows.
          _width = constraints.maxWidth.clamp(240.0, 900.0).toDouble();
          _heights.clear();
          return Center(
            child: SizedBox(
              width: _width,
              child: Stack(
                children: [
                  ListView.builder(
                    controller: _controller,
                    // Pages are butted together with no gap so a webtoon reads
                    // as one strip, which is the point of this view.
                    itemCount: widget.pageKeys.length,
                    itemBuilder: (context, index) {
                      final key = widget.pageKeys[index];
                      return SizedBox(
                        height: _heightFor(key),
                        child: _PreviewPage(
                          project: widget.project,
                          pageKey: key,
                          showBoxes: _showBoxes,
                          onMeasured: (natural) => _applyMeasured(key, natural),
                        ),
                      );
                    },
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 8,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.scrim.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '${_currentIndex + 1} / ${widget.pageKeys.length}',
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onPrimary,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// `image_info` is only a hint — the real aspect ratio comes from the decoded
  /// page, and a mismatch would make the strip jump. Re-layout on the next
  /// frame so the correction never happens mid-build.
  void _applyMeasured(String key, Size? natural) {
    if (!mounted || natural == null) return;
    final resolved =
        _width * (natural.height / natural.width).clamp(0.2, 8.0).toDouble();
    if (((_heights[key] ?? 0) - resolved).abs() <= 1) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _heights[key] = resolved);
    });
  }
}

class _PreviewPage extends StatefulWidget {
  const _PreviewPage({
    required this.project,
    required this.pageKey,
    required this.showBoxes,
    required this.onMeasured,
  });

  final TranslationProject project;
  final String pageKey;
  final bool showBoxes;
  final ValueChanged<Size?> onMeasured;

  @override
  State<_PreviewPage> createState() => _PreviewPageState();
}

class _PreviewPageState extends State<_PreviewPage> {
  DecodedPage? _page;
  bool _loading = true;
  int _token = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_PreviewPage old) {
    super.didUpdateWidget(old);
    if (old.pageKey != widget.pageKey) {
      _page?.dispose();
      _page = null;
      _load();
    }
  }

  @override
  void dispose() {
    _page?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final token = ++_token;
    setState(() => _loading = true);
    final inpainted = File(
      widget.project.artifactPath('inpainted', widget.pageKey),
    );
    final original = File(widget.project.originalPath(widget.pageKey));
    DecodedPage? decoded;
    if (inpainted.existsSync()) {
      decoded = await decodePageFile(inpainted, fromInpainted: true);
    }
    decoded ??= await decodePageFile(original);
    if (!mounted || token != _token) {
      decoded?.dispose();
      return;
    }
    setState(() {
      _page = decoded;
      _loading = false;
    });
    widget.onMeasured(decoded?.originalSize);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surface,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_loading)
            Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else if (_page == null)
            Center(
              child: Icon(Icons.broken_image_outlined, color: scheme.outline),
            )
          else
            TextBlockCanvas(
              blocks: const [],
              selectedIndex: -1,
              onSelect: (_) {},
              base: _page,
              showBoxes: widget.showBoxes,
            ),
          Positioned(
            right: 4,
            bottom: 2,
            child: Text(
              widget.pageKey,
              style: TextStyle(
                fontSize: 10,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

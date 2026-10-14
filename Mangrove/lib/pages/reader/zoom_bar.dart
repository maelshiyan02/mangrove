part of 'reader.dart';

/// Discrete zoom targets for the bottom-right zoom cluster.
///
/// Gallery: multipliers of the page's fit scale (`contained`, or `covered` when
/// "fill screen" is on), so "1x" always means "as laid out".
/// Continuous: absolute scale factors. The long-strip PhotoView is built with
/// `minScale: 1.0, strictScale: true`, so anything below 100% is unreachable —
/// hence the 100% floor instead of a 50/75% rung.
const List<double> kGalleryZoomSteps = [1.0, 1.5, 2.0, 2.5];

const List<double> kContinuousZoomSteps = [1.0, 1.25, 1.5, 2.0, 2.5];

/// Hard ceiling kept from the existing PhotoView configuration (continuous
/// already caps at 2.5; gallery is capped here so the cluster can't out-zoom
/// what a pinch can reach).
const double kMaxZoomRatio = 2.5;

List<double> zoomStepsFor(bool continuous) =>
    continuous ? kContinuousZoomSteps : kGalleryZoomSteps;

/// The next/previous rung from [current], as an absolute scale.
///
/// [base] is the page's fit scale (1x). Pure so the step table can be asserted
/// without a reader instance.
double nextZoomTarget({
  required double current,
  required double base,
  required bool continuous,
  required bool zoomIn,
}) {
  if (base <= 0) return current;
  final steps = zoomStepsFor(continuous);
  final ratio = current / base;
  const epsilon = 0.01;
  if (zoomIn) {
    for (final step in steps) {
      if (step > ratio + epsilon) return step * base;
    }
    return kMaxZoomRatio * base;
  }
  for (final step in steps.reversed) {
    if (step < ratio - epsilon) return step * base;
  }
  return steps.first * base;
}

/// "1.5x" for gallery, "150%" for continuous.
String formatZoomLabel(double? scale, double? base, bool continuous) {
  if (scale == null) return continuous ? '100%' : '1x';
  if (continuous) return '${(scale * 100).round()}%';
  final effectiveBase = (base == null || base <= 0) ? 1.0 : base;
  final ratio = scale / effectiveBase;
  final text = ratio.toStringAsFixed(1);
  return text.endsWith('.0') ? '${text.substring(0, text.length - 2)}x' : '${text}x';
}

/// A small `[fit] [−] [scale] [+]` cluster in the bottom-right corner.
///
/// Desktop only and opt-in (`readerShowZoomBar`, default off): it exists for
/// mouse users who never learn Ctrl+wheel, and must stay out of the way of
/// everyone else. Visibility (fade in on pointer movement, fade out after idle)
/// is owned by the scaffold, which is the only widget that sees every hover.
class ReaderZoomBar extends StatefulWidget {
  const ReaderZoomBar({super.key, required this.visible});

  final bool visible;

  @override
  State<ReaderZoomBar> createState() => _ReaderZoomBarState();
}

class _ReaderZoomBarState extends State<ReaderZoomBar> {
  StreamSubscription<PhotoViewControllerValue>? _subscription;
  PhotoViewController? _controller;
  double? _scale;

  /// Re-binds when the page changes: gallery keeps one controller per page and
  /// drops the others, so identity — not null-ness — is what changes.
  void _bind() {
    final controller = context.reader._imageViewController?.zoomController;
    if (controller == _controller) return;
    _subscription?.cancel();
    _controller = controller;
    _scale = controller?.scale;
    _subscription = controller?.outputStateStream.listen((value) {
      if (!mounted) return;
      setState(() => _scale = value.scale);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bind();
  }

  @override
  void didUpdateWidget(covariant ReaderZoomBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _bind();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  double? get _base => _controller?.getInitialScale?.call();

  void _zoom(bool zoomIn) {
    final base = _base;
    final current = _scale ?? base;
    if (base == null || current == null) return;
    final target = nextZoomTarget(
      current: current,
      base: base,
      continuous: context.reader.mode.isContinuous,
      zoomIn: zoomIn,
    );
    context.reader._imageViewController?.setZoomScale(target);
  }

  @override
  Widget build(BuildContext context) {
    _bind();
    final continuous = context.reader.mode.isContinuous;
    final base = _base;
    // No controller on the comments page or while an image is still loading:
    // show the resting value rather than a stale one from another page.
    final label = formatZoomLabel(_scale ?? base, base, continuous);
    final hasController = _controller != null;
    return AnimatedOpacity(
      opacity: widget.visible ? 1 : 0,
      duration: const Duration(milliseconds: 200),
      child: IgnorePointer(
        ignoring: !widget.visible,
        child: MouseRegion(
          onHover: (_) => context.readerScaffold.pokeZoomBar(),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _ZoomButton(
                  icon: Icons.fit_screen_outlined,
                  tooltip: "Fit width".tl,
                  enabled: hasController,
                  onPressed: () =>
                      context.reader._imageViewController?.resetZoom(),
                ),
                _ZoomButton(
                  icon: Icons.remove,
                  tooltip: "Zoom out".tl,
                  enabled: hasController,
                  onPressed: () => _zoom(false),
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 48),
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                _ZoomButton(
                  icon: Icons.add,
                  tooltip: "Zoom in".tl,
                  enabled: hasController,
                  onPressed: () => _zoom(true),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ZoomButton extends StatelessWidget {
  const _ZoomButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.enabled = true,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 32,
      height: 32,
      child: IconButton(
        padding: EdgeInsets.zero,
        iconSize: 18,
        color: Colors.white,
        disabledColor: Colors.white.withValues(alpha: 0.35),
        tooltip: tooltip,
        icon: Icon(icon),
        onPressed: enabled ? onPressed : null,
      ),
    );
  }
}

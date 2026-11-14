part of 'reader.dart';

/// Discrete zoom targets for the bottom-right zoom cluster.
///
/// Gallery: multipliers of the page's fit scale (`contained`, or `covered` when
/// "fill screen" is on), so "1x" always means "as laid out".
/// Continuous: absolute scale factors. The long-strip PhotoView is built with
/// `minScale: 1.0, strictScale: true`, so anything below 100% is unreachable —
/// hence the 100% floor instead of a 50/75% rung.
const List<double> kGalleryZoomSteps = [1.0, 1.5, 2.0, 2.5];

/// 10% per rung so each tap of [+] / [−] nudges the scale by exactly one tenth
/// (per reader feedback: was 25% per level before). Clamped to the 100% floor
/// and the 250% ceiling in [nextZoomTarget].
const List<double> kContinuousZoomSteps = [
  1.0,
  1.1,
  1.2,
  1.3,
  1.4,
  1.5,
  1.6,
  1.7,
  1.8,
  1.9,
  2.0,
  2.1,
  2.2,
  2.3,
  2.4,
  2.5,
];

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

/// Always a percentage ("100%", "110%", …) for both gallery and continuous.
///
/// Gallery's fit scale is the 100% baseline, so a gallery page at fit reads
/// "100%" and zoomed reads "150%", identical in spirit to comix.to's cluster.
String formatZoomLabel(double? scale, double? base, bool continuous) =>
    '${zoomPercentOf(scale, base)}%';

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
    final colorScheme = Theme.of(context).colorScheme;
    return AnimatedOpacity(
      opacity: widget.visible ? 1 : 0,
      duration: const Duration(milliseconds: 200),
      child: IgnorePointer(
        ignoring: !widget.visible,
        child: MouseRegion(
          onHover: (_) => context.readerScaffold.pokeZoomBar(),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            decoration: BoxDecoration(
              // 纯透明底 + 主题轮廓线：与右上章节胶囊同一套「镂空」样式，
              // 不再用半透明色块遮住画面。
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(17),
              border: Border.all(
                color: colorScheme.outline.withValues(alpha: 0.55),
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 左：放大（+）。布局按反馈：左放大、右缩小、中间可点输入百分比。
                _ZoomButton(
                  icon: Icons.add,
                  tooltip: "Zoom in".tl,
                  enabled: hasController,
                  onPressed: () => _zoom(true),
                ),
                _ZoomPercentLabel(
                  label: label,
                  enabled: hasController,
                  onTap: hasController
                      ? () => _showPercentageDialog(context)
                      : null,
                ),
                // 右：缩小（−）。
                _ZoomButton(
                  icon: Icons.remove,
                  tooltip: "Zoom out".tl,
                  enabled: hasController,
                  onPressed: () => _zoom(false),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 自由百分比输入：点中间读数弹窗输入任意值（夹在 100%–250%），
  /// 取代已删除的"适应宽度"按钮。
  void _showPercentageDialog(BuildContext context) {
    final base = _base ?? 1.0;
    // 预填值必须与标签同一套基准（相对 1x），否则 gallery 满屏会填成 42。
    final current = zoomPercentOf(_scale ?? base, base).clamp(100, 250);
    final controller = TextEditingController(text: current.toString());
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text("Zoom".tl),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: "Percentage".tl,
            hintText: "100 - 250",
          ),
          onSubmitted: (value) =>
              _applyPercentage(value, base, dialogContext),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text("Cancel".tl),
          ),
          TextButton(
            onPressed: () =>
                _applyPercentage(controller.text, base, dialogContext),
            child: Text("Apply".tl),
          ),
        ],
      ),
    );
  }

  void _applyPercentage(
    String value,
    double base,
    BuildContext dialogContext,
  ) {
    final pct = int.tryParse(value.trim());
    if (pct == null) {
      Navigator.of(dialogContext).pop();
      return;
    }
    final clamped = pct.clamp(100, 250);
    final target = (clamped / 100) * base;
    context.reader._imageViewController?.setZoomScale(target);
    Navigator.of(dialogContext).pop();
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
    final colorScheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 32,
      height: 32,
      child: IconButton(
        padding: EdgeInsets.zero,
        iconSize: 18,
        color: colorScheme.onSurface,
        disabledColor: colorScheme.onSurface.withValues(alpha: 0.38),
        tooltip: tooltip,
        icon: Icon(icon),
        onPressed: enabled ? onPressed : null,
      ),
    );
  }
}

/// 中间百分比读数：可点击输入，黑白单色矢量风格。
class _ZoomPercentLabel extends StatelessWidget {
  const _ZoomPercentLabel({
    required this.label,
    required this.enabled,
    this.onTap,
  });

  final String label;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 48),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: enabled
                    ? colorScheme.onSurface
                    : colorScheme.onSurface.withValues(alpha: 0.38),
                fontSize: 13,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

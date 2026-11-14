part of 'components.dart';

/// 完全自绘的下拉菜单，取代原生 `PopupMenuButton`。
///
/// 原生 `PopupMenuButton` 在 Windows 上观感突兀、且无法与全局三档主题 /
/// 护眼纸面协调。这里用一条自定义 `PopupRoute` 绘制圆角面板 + 主题表面 +
/// 自定义淡入，锚定在触发按钮下方（右对齐），点击外部自动关闭。
class MangrovePopupMenuButton<T> extends StatelessWidget {
  const MangrovePopupMenuButton({
    super.key,
    this.tooltip,
    this.icon,
    this.onSelected,
    required this.items,
    this.initialValue,
  });

  final String? tooltip;
  final Widget? icon;
  final ValueChanged<T>? onSelected;
  final List<MangrovePopupItem<T>> items;
  final T? initialValue;

  void _open(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    final rect = box == null
        ? Rect.zero
        : box.localToGlobal(Offset.zero) & box.size;
    Navigator.of(context).push(
      _MangrovePopupRoute<T>(
        anchorRect: rect,
        items: items,
        onSelected: onSelected,
        initialValue: initialValue,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      icon: icon ?? const Icon(Icons.more_vert),
      onPressed: () => _open(context),
    );
  }
}

class MangrovePopupItem<T> {
  const MangrovePopupItem({
    required this.value,
    this.leading,
    this.label,
    this.child,
    this.enabled = true,
    this.selected,
  });

  final T value;
  final IconData? leading;
  final String? label;
  final Widget? child;
  final bool enabled;
  final bool? selected;
}

class _MangrovePopupRoute<T> extends PopupRoute<T> {
  _MangrovePopupRoute({
    required this.anchorRect,
    required this.items,
    this.onSelected,
    this.initialValue,
  });

  final Rect anchorRect;
  final List<MangrovePopupItem<T>> items;
  final ValueChanged<T>? onSelected;
  final T? initialValue;

  @override
  Color? get barrierColor => Colors.black38;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'mangrove-popup';

  @override
  Duration get transitionDuration => const Duration(milliseconds: 160);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return _MangrovePopupPanel<T>(route: this);
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
      child: child,
    );
  }
}

class _MangrovePopupPanel<T> extends StatelessWidget {
  const _MangrovePopupPanel({required this.route});

  final _MangrovePopupRoute<T> route;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final screen = MediaQuery.sizeOf(context);
    return CustomSingleChildLayout(
      delegate: _MangrovePopupLayoutDelegate(
        anchorRect: route.anchorRect,
        screenSize: screen,
      ),
      // 宽度贴合内容：外层约束只给上下限，`Column` 在松约束下按最宽一项
      // 定宽，不再被固定上限撑出一大片留白（三档外观菜单只有两三个短词）。
      // 不用 `IntrinsicWidth`：`ListTile` 之类的自定义项不一定实现内在尺寸。
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 92, maxWidth: 240),
        child: Material(
          type: MaterialType.transparency,
          child: Container(
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.6),
                width: 1,
              ),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x40000000),
                  blurRadius: 18,
                  offset: Offset(0, 6),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final it in route.items)
                    _MangrovePopupRow<T>(item: it, route: route),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MangrovePopupRow<T> extends StatelessWidget {
  const _MangrovePopupRow({required this.item, required this.route});

  final MangrovePopupItem<T> item;
  final _MangrovePopupRoute<T> route;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isSelected = item.selected ??
        (route.initialValue != null && route.initialValue == item.value);
    // 不可用项必须看起来就不可用：原生 PopupMenuItem 会自动置灰，
    // 自绘版如果不显式降透明度，禁用项与可点项长得一模一样。
    final dim = !item.enabled;
    final fg = dim
        ? scheme.onSurface.withValues(alpha: 0.38)
        : (isSelected ? scheme.primary : scheme.onSurface);
    final content = item.child != null
        ? Opacity(opacity: dim ? 0.38 : 1, child: item.child!)
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (item.leading != null) ...[
                Icon(item.leading!, size: 18, color: fg),
                const SizedBox(width: 10),
              ],
              Flexible(
                child: Text(
                  item.label ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ts.s14.withColor(fg),
                ),
              ),
            ],
          );
    return InkWell(
      onTap: item.enabled
          ? () {
              Navigator.of(context).pop();
              route.onSelected?.call(item.value);
            }
          : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        color: isSelected ? scheme.primaryContainer.withValues(alpha: 0.5) : null,
        child: DefaultTextStyle(style: ts.s14, child: content),
      ),
    );
  }
}

class _MangrovePopupLayoutDelegate extends SingleChildLayoutDelegate {
  _MangrovePopupLayoutDelegate({
    required this.anchorRect,
    required this.screenSize,
  });

  final Rect anchorRect;
  final Size screenSize;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(screenSize);

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    const margin = 8.0;
    // 默认右对齐到触发按钮右缘，并优先放在其下方。
    double dx = anchorRect.right - childSize.width;
    if (dx < margin) dx = margin;
    final maxRight = screenSize.width - margin;
    if (dx + childSize.width > maxRight) {
      dx = maxRight - childSize.width;
    }
    final below = anchorRect.bottom + margin;
    final aboveTop = anchorRect.top - margin - childSize.height;
    final dy = below + childSize.height <= screenSize.height
        ? below
        : (aboveTop >= margin ? aboveTop : margin);
    return Offset(dx, dy);
  }

  @override
  bool shouldRelayout(covariant _MangrovePopupLayoutDelegate old) =>
      old.anchorRect != anchorRect || old.screenSize != screenSize;
}

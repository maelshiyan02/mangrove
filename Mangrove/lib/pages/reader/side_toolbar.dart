part of 'reader.dart';

/// R5 可选右缘竖工具栏。
///
/// 默认关闭（`readerSideToolbar` == false）。开启后从右缘滑入一列图标钮：
/// 章节列表 / 评论 / 全屏 / 自动播放 / 设置 / 帮助。
/// 与顶/底栏功能重复但并存，纯布局偏好。
///
/// 「评论」自 P64 起接当前章节的留言区（拷贝漫画 App 端 `roasts` 接口）；
/// 来源不支持时给明确提示，不再只弹「敬请期待」。
class ReaderSideToolbar extends StatelessWidget {
  const ReaderSideToolbar({super.key});

  @override
  Widget build(BuildContext context) {
    final visible = appdata.settings['readerSideToolbar'] == true;
    final reader = context.reader;
    final scaffold = context.readerScaffold;
    final items = <_SideToolItem>[
      _SideToolItem(
        Icons.library_books,
        "Chapters".tl,
        scaffold.openChapterDrawer,
      ),
      // P64：评论不再占位 —— 直接打开**当前章节**的留言区（拷贝 App 端 roasts）。
      _SideToolItem(
        Icons.comment_outlined,
        "Comments".tl,
        reader.openChapterComments,
      ),
      _SideToolItem(Icons.fullscreen, "Fullscreen".tl, reader.fullscreen),
      _SideToolItem(
        reader.isAutoPlaying ? Icons.timer : Icons.timer_sharp,
        "Auto Page Turning".tl,
        () {
          reader.toggleAutoPlay();
          scaffold.update();
        },
      ),
      _SideToolItem(Icons.settings, "Settings".tl, scaffold.openSetting),
      _SideToolItem(
        Icons.help_outline,
        "Help".tl,
        () => showReaderHelpDialog(context),
      ),
    ];
    return AnimatedSlide(
      duration: _readerChromeAnimationDuration,
      curve: Curves.easeOutCubic,
      offset: visible ? Offset.zero : const Offset(1.4, 0),
      child: AnimatedOpacity(
        duration: _readerChromeAnimationDuration,
        opacity: visible ? 1 : 0,
        child: IgnorePointer(
          ignoring: !visible,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              for (var i = 0; i < items.length; i++) ...[
                if (i > 0) const SizedBox(height: 6),
                _SideToolButton(
                  icon: items[i].icon,
                  tooltip: items[i].tooltip,
                  onPressed: items[i].onPressed,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SideToolItem {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  _SideToolItem(this.icon, this.tooltip, this.onPressed);
}

/// 单个右缘图标钮：34–40dp，透明底，半透明悬停背景。
class _SideToolButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  const _SideToolButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  State<_SideToolButton> createState() => _SideToolButtonState();
}

class _SideToolButtonState extends State<_SideToolButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Tooltip(
        message: widget.tooltip,
        child: InkResponse(
          onTap: widget.onPressed,
          radius: 20,
          borderRadius: BorderRadius.circular(10),
          splashColor: onSurface.withValues(alpha: 0.10),
          highlightColor: onSurface.withValues(alpha: 0.06),
          hoverColor: onSurface.withValues(alpha: 0.12),
          child: Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _hover ? onSurface.withValues(alpha: 0.12) : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(widget.icon, size: 22, color: onSurface),
          ),
        ),
      ),
    );
  }
}

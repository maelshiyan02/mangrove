part of 'reader.dart';

/// 顶栏的紧凑章节胶囊：`‹  Ch.12 / 48  ›`。
///
/// 与默认的"双行书名/话名"二选一：胶囊把一整行标题压成一颗 34dp 高的连体
/// 按钮，把顶栏横向空间还给右侧的翻译控件与菜单；完整书名与话名退到 tooltip
/// 里，需要时悬停可见。
///
/// 上一话/下一话的可用性用 [visibleChapterFrom] 判定，而**不用**
/// `isFirstChapterOfGroup` / `isLastChapterOfGroup`：后者只看分组边界，在
/// "目标话存在但落在另一个分组"时会把一个能跳的按钮误置灰。
class ChapterCapsule extends StatelessWidget {
  const ChapterCapsule({super.key});

  @override
  Widget build(BuildContext context) {
    final reader = context.reader;
    final chapters = reader.widget.chapters;
    if (chapters == null) return const SizedBox();

    final total = chapters.titles.length;
    final current = reader.chapter;
    final colorScheme = context.colorScheme;
    final prev = reader.visibleChapterFrom(current, -1);
    final next = reader.visibleChapterFrom(current, 1);

    return Tooltip(
      message: switch (chapters.titles.elementAtOrNull(current - 1)) {
        final title? when title.trim().isNotEmpty =>
          "${reader.widget.name} · $title",
        _ => reader.widget.name,
      },
      child: Container(
        height: 34,
        decoration: BoxDecoration(
          // 纯透明底 + 随主题变化的轮廓线：不再用实心色块压住画布，
          // 夜间 / 护眼档切换时描边自动跟随 `outline`。
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: colorScheme.outline.withValues(alpha: 0.55),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _CapsuleArrow(
              icon: Icons.chevron_left_rounded,
              tooltip: "Previous chapter".tl,
              enabled: prev != null,
              onTap: prev != null &&
                      allowReaderChapterJump(ReaderJumpOrigin.capsule)
                  ? () => reader.toPrevChapter(toLastPage: true)
                  : null,
            ),
            InkWell(
              borderRadius: const BorderRadius.horizontal(
                left: Radius.circular(0),
                right: Radius.circular(0),
              ),
              onTap: () => context.readerScaffold.openChapterDrawer(),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  "Ch.$current / $total",
                  maxLines: 1,
                  style: ts.s14.copyWith(color: colorScheme.onSurface),
                ),
              ),
            ),
            _CapsuleArrow(
              icon: Icons.chevron_right_rounded,
              tooltip: "Next chapter".tl,
              enabled: next != null,
              onTap: next != null &&
                      allowReaderChapterJump(ReaderJumpOrigin.capsule)
                  ? () => reader.toNextChapter()
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _CapsuleArrow extends StatelessWidget {
  const _CapsuleArrow({
    required this.icon,
    required this.tooltip,
    required this.enabled,
    this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final bool enabled;
  // P56：显式跳章守卫未放行时允许为空，InkWell 会自动置灰。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: enabled ? onTap : null,
        child: SizedBox(
          width: 28,
          height: 34,
          child: Icon(
            icon,
            size: 18,
            color: enabled
                ? context.colorScheme.onSurface
                : context.colorScheme.onSurface.toOpacity(0.38),
          ),
        ),
      ),
    );
  }
}

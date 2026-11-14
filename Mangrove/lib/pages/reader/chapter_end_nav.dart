part of 'reader.dart';

/// Two large prev/next chapter cards shown at the end of a gallery chapter.
///
/// Gallery only: continuous (seamless) reading already crosses chapters
/// without a break, and inserting a card there would interrupt it.
bool readerChapterEndNavEnabled({
  required ReaderMode mode,
  required String cid,
  required String sourceKey,
}) {
  if (!mode.isGallery) return false;
  // Opt-out switch: on by default, because gallery readers otherwise have to
  // leave for the chapter list (or swipe into the void) to continue.
  return appdata.settings.getReaderSetting(
        cid,
        sourceKey,
        'readerShowChapterEndNav',
      ) !=
      false;
}

class ChapterEndNavCards extends StatelessWidget {
  const ChapterEndNavCards({super.key});

  @override
  Widget build(BuildContext context) {
    final reader = context.reader;
    final chapters = reader.widget.chapters;
    if (chapters == null) return const SizedBox();
    // P56 / comix.to 实测：两张 355×44 **并排**、间距 10，常驻内容流。
    // 窄窗时两张等比收缩，不溢出。
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final available = constraints.maxWidth;
          final cardWidth = math.min(
            kChapterEndCardWidth,
            (available - kChapterEndCardGap) / 2,
          );
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: cardWidth,
                child: const _ChapterEndNavCard(forward: false),
              ),
              const SizedBox(width: kChapterEndCardGap),
              SizedBox(
                width: cardWidth,
                child: const _ChapterEndNavCard(forward: true),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ChapterEndNavCard extends StatelessWidget {
  const _ChapterEndNavCard({required this.forward});

  final bool forward;

  @override
  Widget build(BuildContext context) {
    final reader = context.reader;
    final chapters = reader.widget.chapters;
    final colorScheme = Theme.of(context).colorScheme;
    final step = forward ? 1 : -1;
    final target = reader.visibleChapterFrom(reader.chapter, step);
    final enabled = target != null;
    final title = target == null
        ? null
        : chapters!.titles.elementAtOrNull(target - 1);
    final label = forward ? "Next chapter".tl : "Previous chapter".tl;
    final text = target == null
        ? label
        : "$label · ${(title == null || title.trim().isEmpty) ? '$target' : title}";
    return Opacity(
      opacity: enabled ? 1 : 0.38,
      child: Material(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: enabled &&
                  allowReaderChapterJump(ReaderJumpOrigin.chapterEndCard)
              ? () {
                  if (forward) {
                    reader.toNextChapter();
                  } else {
                    reader.toPrevChapter(toLastPage: true);
                  }
                }
              : null,
          child: SizedBox(
            height: kChapterEndCardHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Icon(
                    forward
                        ? Icons.arrow_forward_rounded
                        : Icons.arrow_back_rounded,
                    size: 18,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium
                          ?.copyWith(color: colorScheme.onSurface),
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

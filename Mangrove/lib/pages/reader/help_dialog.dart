part of 'reader.dart';

/// Whether [event] is the "show the shortcut sheet" key.
///
/// `?` is shift+slash on most layouts but has its own key on some, so the
/// character is checked instead of the logical key. F1 is the conventional
/// help key and is free in the reader.
///
/// Kept as a pure function of the two fields because the reader's key handler
/// is the only place that can decide, and it must be assertable without
/// building the reader (see `test/reader_desktop_extras_test.dart`).
bool isReaderHelpKey({
  required LogicalKeyboardKey logicalKey,
  String? character,
}) {
  return logicalKey == LogicalKeyboardKey.f1 || character == '?';
}

/// Shows the reader's keyboard / pointer cheat sheet.
///
/// mangrove has far more gestures than most readers and never had a place
/// listing them: this is that place.
void showReaderHelpDialog(BuildContext context) {
  showDialog(
    context: context,
    builder: (context) => const ReaderHelpDialog(),
  );
}

class ReaderHelpDialog extends StatelessWidget {
  const ReaderHelpDialog({super.key});

  static const _groups = <_HelpGroup>[
    _HelpGroup(
      "Pages",
      <_HelpEntry>[
        _HelpEntry("← →", "Turn page (gallery)"),
        _HelpEntry("↑ ↓", "Turn page (top-to-bottom)"),
        _HelpEntry("A D / W S", "Turn page"),
        _HelpEntry("Space", "Turn page"),
      ],
    ),
    _HelpGroup(
      "Chapters",
      <_HelpEntry>[
        _HelpEntry("Shift + ← →", "Previous / next chapter"),
        _HelpEntry("Esc", "Back"),
      ],
    ),
    _HelpGroup(
      "View",
      <_HelpEntry>[
        _HelpEntry("F12", "Toggle fullscreen"),
        _HelpEntry("F1 / ?", "This dialog"),
      ],
    ),
    _HelpGroup(
      "Mouse",
      <_HelpEntry>[
        _HelpEntry("Click", "Turn page / toggle the bars"),
        _HelpEntry("Double click", "Zoom, or collect (if set)"),
        _HelpEntry("Long press", "Zoom while held"),
        _HelpEntry("Ctrl + wheel", "Zoom"),
        _HelpEntry("Drag across axis", "Collect the image"),
      ],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final entries = _groups
        .where((g) => !g.isMobileOnly || App.isAndroid || App.isIOS)
        .toList();
    return ContentDialog(
      title: "Keyboard & Gestures".tl,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final group in entries) ...[
            const SizedBox(height: 12),
            Text(
              group.title.tl,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: context.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 4),
            for (final entry in group.entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    SizedBox(
                      width: 120,
                      child: Text(
                        entry.keys,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        entry.description.tl,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: context.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
      actions: [
        FilledButton(
          onPressed: context.pop,
          child: Text("Close".tl),
        ),
      ],
    );
  }
}

class _HelpGroup {
  final String title;
  final List<_HelpEntry> entries;
  final bool isMobileOnly;

  const _HelpGroup(this.title, this.entries, {this.isMobileOnly = false});
}

class _HelpEntry {
  final String keys;
  final String description;

  const _HelpEntry(this.keys, this.description);
}

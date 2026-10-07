part of 'settings_page.dart';

/// Editor for the translation system prompt. Users shorten it to cut the tokens
/// every request spends, or reword it to change how the model translates; Reset
/// puts the built-in text back.
class TranslationPromptPage extends StatefulWidget {
  const TranslationPromptPage({super.key});

  @override
  State<TranslationPromptPage> createState() => _TranslationPromptPageState();
}

class _TranslationPromptPageState extends State<TranslationPromptPage> {
  late final TextEditingController _controller;

  /// What was on disk when the page opened, to tell an edit from a no-op.
  late final String _initial;

  @override
  void initState() {
    super.initState();
    _initial = LlmPromptStore.template;
    _controller = TextEditingController(text: _initial);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _changed => _controller.text.trim() != _initial.trim();

  bool get _isBlank => _controller.text.trim().isEmpty;

  void _save() {
    LlmPromptStore.save(_controller.text);
    if (!mounted) return;
    context.showMessage(message: "Translation prompt saved".tl);
    context.pop();
  }

  /// Puts the built-in text in the field without persisting: like any other
  /// edit here, it only takes effect on Save, so Cancel still backs out.
  void _reset() {
    showConfirmDialog(
      context: App.rootContext,
      title: "Reset".tl,
      content: "Restore the built-in translation prompt?".tl,
      onConfirm: () =>
          setState(() => _controller.text = LlmPromptStore.builtIn),
    );
  }

  /// Reference for writing a replacement prompt: the one placeholder, the shape
  /// the page's text arrives in, and the reply shape the parser needs. The last
  /// is the part worth spelling out — a shortened prompt that drops the output
  /// contract still gets billed, then fails to parse.
  void _showFormatHelp() {
    // No intrinsic width of its own: ContentDialog measures content through
    // IntrinsicWidth, which an infinite-width child cannot answer.
    Widget code(String text) {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: context.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(text, style: ts.s12.copyWith(fontFamily: 'monospace')),
      );
    }

    Widget section(String title, List<Widget> children) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: ts.bold.s14),
          const SizedBox(height: 4),
          ...children,
          const SizedBox(height: 16),
        ],
      );
    }

    Widget body(String text) => Text(text, style: ts.s14);

    // Sample values are localized; only the field names are literal.
    var src = "original".tl;
    var dst = "translation".tl;

    showDialog(
      context: App.rootContext,
      builder: (context) => ContentDialog(
        title: "Prompt format".tl,
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 520),
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                section("Placeholder".tl, [
                  body(
                    "\$target is replaced with the name of the target language you picked. It is the only placeholder."
                        .tl,
                  ),
                ]),
                section("What is sent".tl, [
                  body(
                    "Your text becomes the system message. The page's recognized lines are sent separately as the user message:"
                        .tl,
                  ),
                  code(
                    '{"glossary":{"$src":"$dst"},\n'
                    ' "lines":[{"id":0,"text":"$src"}]}',
                  ),
                  body(
                    "glossary carries names already agreed for this comic and is omitted until there are some."
                        .tl,
                  ),
                ]),
                section("What must come back".tl, [
                  code(
                    '{"lines":[{"id":0,"text":"$dst"}],\n'
                    ' "names":{"$src":"$dst"}}',
                  ),
                  body(
                    "lines is required: one entry per input id, each id exactly once. A reply without it cannot be read and the page is left untranslated — the request is still billed."
                        .tl,
                  ),
                  const SizedBox(height: 8),
                  body(
                    "names is optional. Leaving it out shortens both the prompt and the reply, but character names then stop matching between pages."
                        .tl,
                  ),
                ]),
              ],
            ),
          ),
        ),
        actions: [Button.filled(onPressed: context.pop, child: Text("OK".tl))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(
        title: Text("Translation prompt".tl),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            tooltip: "Prompt format".tl,
            onPressed: _showFormatHelp,
          ),
          TextButton(onPressed: _reset, child: Text("Reset".tl)),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Text(
              "Sent to the AI model with every request. Shorten it to spend fewer tokens, at the cost of translation quality and consistent character names. Keep \$target where the target language should appear."
                  .tl,
              style: ts.s14.copyWith(color: context.colorScheme.outline),
            ),
          ),
          Expanded(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: context.colorScheme.outlineVariant),
              ),
              child: TextField(
                controller: _controller,
                expands: true,
                maxLines: null,
                minLines: null,
                keyboardType: TextInputType.multiline,
                textAlignVertical: TextAlignVertical.top,
                style: ts.s14,
                decoration: InputDecoration(
                  border: InputBorder.none,
                  hintText: "Translation prompt".tl,
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
          ),
          if (!_isBlank &&
              !LlmPromptStore.hasTargetPlaceholder(_controller.text))
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Row(
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 18,
                    color: context.colorScheme.error,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      "Without \$target the model is not told which language to translate into."
                          .tl,
                      style: ts.s12.copyWith(color: context.colorScheme.error),
                    ),
                  ),
                ],
              ),
            ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              12,
              16,
              12 + context.padding.bottom,
            ),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => context.pop(),
                    child: Text("Cancel".tl),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _changed ? _save : null,
                    child: Text("Save".tl),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

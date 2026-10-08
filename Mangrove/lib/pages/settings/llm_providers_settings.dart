part of 'settings_page.dart';

/// Management page for the user's LLM translation providers: add, edit, delete,
/// and pick which one is active. Each provider is an OpenAI-compatible endpoint
/// with its own name / URL / key / model, so the user can keep several vendors
/// (or a paid account and a LAN gateway) and switch between them without
/// re-typing settings.
class LlmProvidersPage extends StatefulWidget {
  const LlmProvidersPage({super.key});

  @override
  State<LlmProvidersPage> createState() => _LlmProvidersPageState();
}

class _LlmProvidersPageState extends State<LlmProvidersPage> {
  void _refresh() {
    if (mounted) setState(() {});
  }

  void _addProvider() async {
    var provider = await _editProvider(null);
    if (provider != null) {
      LlmProviderStore.add(provider);
      _refresh();
    }
  }

  void _editExisting(LlmProvider provider) async {
    var edited = await _editProvider(provider);
    if (edited != null) {
      LlmProviderStore.update(edited);
      _refresh();
    }
  }

  void _deleteProvider(LlmProvider provider) {
    showConfirmDialog(
      context: App.rootContext,
      title: "Delete".tl,
      content: "Delete this provider?".tl,
      btnColor: context.colorScheme.error,
      onConfirm: () {
        LlmProviderStore.remove(provider.id);
        _refresh();
      },
    );
  }

  /// Opens the add/edit sheet for [existing] (null = new) and returns the
  /// resulting provider, or null if cancelled. The dialog carries its own
  /// working copy so nothing is written until the user confirms.
  Future<LlmProvider?> _editProvider(LlmProvider? existing) {
    return showDialog<LlmProvider>(
      context: App.rootContext,
      builder: (context) => _LlmProviderEditor(existing: existing),
    );
  }

  @override
  Widget build(BuildContext context) {
    var providers = LlmProviderStore.providers;
    var activeId = LlmProviderStore.activeId;
    return Scaffold(
      body: SmoothCustomScrollView(
        scrollbarTopPadding: context.padding.top + 56,
        slivers: [
          SliverAppbar(
            title: Text("LLM providers".tl),
            actions: [
              IconButton(
                icon: const Icon(Icons.add),
                tooltip: "Add provider".tl,
                onPressed: _addProvider,
              ),
            ],
          ),
          if (providers.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 32,
                ),
                child: Text(
                  "No providers yet. Add one to enable AI translation.".tl,
                  style: ts.s14.copyWith(color: context.colorScheme.outline),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          for (var provider in providers)
            _buildProviderTile(context, provider, activeId).toSliver(),
          const SliverPadding(padding: EdgeInsets.only(bottom: 16)),
        ],
      ),
    );
  }

  Widget _buildProviderTile(
    BuildContext context,
    LlmProvider provider,
    String activeId,
  ) {
    var subtitleParts = provider.isPublicFree
        ? <String>["Google Translate (no key)".tl]
        : provider.usesScript
            ? <String>["Custom script".tl]
            : <String>[
                if (provider.url.isNotEmpty) provider.url,
                if (provider.model.isNotEmpty) provider.model,
              ];
    return ListTile(
      leading: RadioGroup<String>(
        groupValue: activeId,
        onChanged: (v) {
          if (v == null) return;
          LlmProviderStore.setActive(v);
          _refresh();
        },
        child: Radio<String>(value: provider.id),
      ),
      title: Text(
        provider.name.isEmpty ? "Unnamed provider".tl : provider.name,
      ),
      subtitle: subtitleParts.isEmpty
          ? Text("Not configured".tl)
          : Text(subtitleParts.join('\n')),
      isThreeLine: subtitleParts.length > 1,
      onTap: () => _editExisting(provider),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        onPressed: () => _deleteProvider(provider),
      ),
    );
  }
}

/// Add/edit dialog for a single [LlmProvider]. Holds a local working copy of
/// the four editable fields and returns a fully-formed provider (preserving the
/// original id when editing) on confirm.
class _LlmProviderEditor extends StatefulWidget {
  const _LlmProviderEditor({this.existing});

  final LlmProvider? existing;

  @override
  State<_LlmProviderEditor> createState() => _LlmProviderEditorState();
}

class _LlmProviderEditorState extends State<_LlmProviderEditor> {
  late final TextEditingController _name;
  late final TextEditingController _url;
  late final TextEditingController _key;
  late final TextEditingController _scriptController;
  late String _model;
  late LlmProviderKind _kind;
  bool _showKey = false;
  bool _testRunning = false;

  @override
  void initState() {
    super.initState();
    var e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _url = TextEditingController(text: e?.url ?? '');
    _key = TextEditingController(text: e?.key ?? '');
    _scriptController =
        TextEditingController(text: e?.script ?? ScriptTranslator.template);
    _model = e?.model ?? '';
    _kind = e?.kind ?? LlmProviderKind.openai;
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _key.dispose();
    _scriptController.dispose();
    super.dispose();
  }

  /// Lets the user pick the model for the values being edited: fetch this
  /// endpoint's `/models` list and choose one, or type it by hand. Uses the URL
  /// and key currently in the fields, not the active provider's, so the list
  /// matches what is being configured.
  void _chooseModel() async {
    var url = _url.text.trim();
    if (url.isNotEmpty) {
      var controller = showLoadingDialog(
        context,
        message: "Loading".tl,
        allowCancel: false,
        barrierDismissible: false,
      );
      List<String>? models;
      try {
        models = await LlmTranslator.fetchModels(
          url: url,
          key: _key.text.trim(),
        );
      } catch (_) {
        models = null;
      }
      controller.close();
      if (!mounted) return;
      if (models != null && models.isNotEmpty) {
        _showModelPicker(models);
        return;
      }
      context.showMessage(message: "Failed to fetch model list".tl);
    }
    _enterModelManually();
  }

  void _enterModelManually() {
    showInputDialog(
      context: context,
      title: "LLM Model".tl,
      initialValue: _model,
      onConfirm: (value) {
        setState(() => _model = value.trim());
        return null;
      },
    );
  }

  void _showModelPicker(List<String> models) {
    var query = '';
    showDialog(
      context: App.rootContext,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            var pickerHeight = (MediaQuery.sizeOf(context).height * 0.55)
                .clamp(260.0, 420.0)
                .toDouble();
            var filtered = query.isEmpty
                ? models
                : models
                      .where(
                        (model) =>
                            model.toLowerCase().contains(query.toLowerCase()),
                      )
                      .toList();
            return ContentDialog(
              title: "Select model".tl,
              content: SizedBox(
                width: 460,
                height: pickerHeight,
                child: Column(
                  children: [
                    TextField(
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.search),
                        hintText: "Search models".tl,
                        border: const OutlineInputBorder(),
                      ),
                      onChanged: (value) {
                        setDialogState(() => query = value.trim());
                      },
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: ListView.builder(
                        itemCount: filtered.length,
                        itemBuilder: (context, index) {
                          var model = filtered[index];
                          return ListTile(
                            title: Text(
                              model,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: model == _model
                                ? Icon(
                                    Icons.check,
                                    color: context.colorScheme.primary,
                                  )
                                : null,
                            onTap: () {
                              context.pop();
                              setState(() => _model = model);
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    context.pop();
                    _enterModelManually();
                  },
                  child: Text("Enter manually".tl),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _confirm() {
    var existing = widget.existing;
    // 自定义脚本：校验脚本非空即可；url/key/model 作为可选凭据交给脚本读取。
    if (_kind == LlmProviderKind.script) {
      final code = _scriptController.text.trim();
      if (code.isEmpty) {
        context.showMessage(message: "Enter a script".tl);
        return;
      }
      context.pop(
        LlmProvider(
          id: existing?.id ?? const Uuid().v4(),
          name: _name.text.trim().isEmpty
              ? "Custom script".tl
              : _name.text.trim(),
          url: _url.text.trim(),
          key: _key.text.trim(),
          model: _model.trim(),
          kind: LlmProviderKind.script,
          script: code,
        ),
      );
      return;
    }
    // The keyless service takes no endpoint, key or model: skip the validation
    // that only applies to a user-supplied endpoint and store empty fields.
    if (_kind == LlmProviderKind.publicFree) {
      context.pop(
        LlmProvider(
          id: existing?.id ?? const Uuid().v4(),
          name: _name.text.trim().isEmpty
              ? "Google Translate (no key)".tl
              : _name.text.trim(),
          url: '',
          key: '',
          model: '',
          kind: LlmProviderKind.publicFree,
        ),
      );
      return;
    }
    var url = _url.text.trim();
    if (!LlmTranslator.isValidBaseUrl(url)) {
      context.showMessage(message: "Enter a valid API URL".tl);
      return;
    }
    if (_model.trim().isEmpty) {
      context.showMessage(message: "Select or enter a model".tl);
      return;
    }
    var provider = LlmProvider(
      id: existing?.id ?? const Uuid().v4(),
      name: _name.text.trim(),
      url: url,
      key: _key.text.trim(),
      model: _model.trim(),
      kind: LlmProviderKind.openai,
    );
    context.pop(provider);
  }

  List<Widget> _buildScriptFields() {
    return [
      Text(
        "自定义脚本在 QuickJS 沙箱里运行（1 秒 CPU 上限、64MB 内存），必须对每个"
        "输入恰好返回一个翻译并保持顺序。模板演示调用一个 OpenAI 兼容接口，按你的"
        "接口修改返回值那一行即可。",
        style: ts.s14.copyWith(color: context.colorScheme.outline),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _scriptController,
        maxLines: 14,
        minLines: 6,
        style: ts.s14,
        decoration: InputDecoration(
          labelText: "Script".tl,
          hintText: "Enter a script".tl,
          alignLabelWithHint: true,
          border: const OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          TextButton(
            onPressed: () {
              setState(
                () => _scriptController.text = ScriptTranslator.template,
              );
            },
            child: Text("Restore template".tl),
          ),
          const SizedBox(width: 8),
          Button.filled(
            onPressed: _testScript,
            child: _testRunning
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text("Test script".tl),
          ),
        ],
      ),
    ];
  }

  void _testScript() async {
    if (_testRunning) return;
    final code = _scriptController.text.trim();
    if (code.isEmpty) {
      context.showMessage(message: "Enter a script".tl);
      return;
    }
    setState(() => _testRunning = true);
    final loading = showLoadingDialog(
      context,
      message: "Testing".tl,
      allowCancel: false,
      barrierDismissible: false,
    );
    try {
      final result = await ScriptTranslator.translate(
        LlmProvider(
          id: const Uuid().v4(),
          name: 'script-test',
          url: 'https://example.com/v1',
          key: '',
          model: '',
          kind: LlmProviderKind.script,
          script: code,
        ),
        ['Hello', 'World'],
        'en',
        'zh',
        timeout: const Duration(seconds: 10),
        client: _mockScriptClient(),
      );
      loading.close();
      if (!mounted) return;
      if (result.texts.length == 2 &&
          result.texts.every((t) => t.isNotEmpty)) {
        context.showMessage(message: "Script works".tl);
      } else {
        context.showMessage(message: "Script returned wrong shape".tl);
      }
    } catch (e) {
      loading.close();
      if (!mounted) return;
      context.showMessage(message: "Script error".tl + ': ' + e.toString());
    } finally {
      if (mounted) setState(() => _testRunning = false);
    }
  }

  Dio _mockScriptClient() {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          var count = 2;
          try {
            final data = jsonDecode(options.data as String? ?? '{}');
            final texts = data['texts'] as List?;
            if (texts != null) count = texts.length;
          } catch (_) {
            count = 2;
          }
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: jsonEncode({
                'translations': List.generate(count, (i) => '测试$i'),
              }),
            ),
          );
        },
      ),
    );
    return dio;
  }

  @override
  Widget build(BuildContext context) {
    return ContentDialog(
      title: widget.existing == null ? "Add provider".tl : "Edit provider".tl,
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 540),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("Service type".tl, style: ts.s14),
              const SizedBox(height: 8),
              SegmentedButton<LlmProviderKind>(
                segments: [
                  ButtonSegment(
                    value: LlmProviderKind.openai,
                    label: Text("AI model".tl),
                  ),
                  ButtonSegment(
                    value: LlmProviderKind.publicFree,
                    label: Text("Google Translate (no key)".tl),
                  ),
                  ButtonSegment(
                    value: LlmProviderKind.script,
                    label: Text("Custom script (JavaScript)".tl),
                  ),
                ],
                selected: {_kind},
                showSelectedIcon: false,
                onSelectionChanged: (selected) {
                  setState(() => _kind = selected.first);
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _name,
                decoration: InputDecoration(
                  labelText: "Name".tl,
                  hintText: _kind == LlmProviderKind.publicFree
                      ? "Optional".tl
                      : "e.g. OpenAI, Local gateway".tl,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              if (_kind == LlmProviderKind.publicFree)
                Text(
                  "Uses Google Translate's free endpoint — no account, no API key, nothing to fill in. Quality is lower than an AI model: each line is translated on its own, so wording and character names may vary between pages. It is not an official API, so it can be rate-limited or stop working at any time."
                      .tl,
                  style: ts.s14.copyWith(color: context.colorScheme.outline),
                )
              else if (_kind == LlmProviderKind.script)
                ..._buildScriptFields()
              else ...[
                TextField(
                  controller: _url,
                  decoration: InputDecoration(
                    labelText: "LLM API URL".tl,
                    hintText: 'https://example.com/v1',
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _key,
                  obscureText: !_showKey,
                  decoration: InputDecoration(
                    labelText: "LLM API Key".tl,
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      tooltip: _showKey ? "Hide".tl : "Show".tl,
                      icon: Icon(
                        _showKey ? Icons.visibility_off : Icons.visibility,
                      ),
                      onPressed: () => setState(() => _showKey = !_showKey),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text("LLM Model".tl),
                  subtitle: Text(_model.isEmpty ? "Not configured".tl : _model),
                  trailing: Button.filled(
                    onPressed: _chooseModel,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.cloud_download_outlined, size: 18),
                        const SizedBox(width: 6),
                        Text("Get models".tl),
                      ],
                    ),
                  ).fixHeight(36),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: _enterModelManually,
                    child: Text("Enter model manually".tl),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => context.pop(), child: Text("Cancel".tl)),
        Button.filled(onPressed: _confirm, child: Text("Save".tl)),
      ],
    );
  }
}

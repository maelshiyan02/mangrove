import 'package:flutter/material.dart';
import 'package:mangrove/components/components.dart';
// `context.pop` / `context.showMessage` / `context.colorScheme` / `ts` 全从这里
// 来（原本也在，删掉它编辑器就编译不过）。
import 'package:mangrove/foundation/app.dart';
import 'package:mangrove/foundation/translation_project/glossary_backend.dart';
import 'package:mangrove/utils/translations.dart';

/// Per-comic glossary editor: lists the name/proper-noun translations the
/// model learned while translating this comic, and lets the user correct a
/// wrong rendering, add a term, or delete one. Edits take effect on the next
/// page/chapter without a full re-translate, so a name established wrongly on
/// an early page can be fixed in place.
///
/// ## 为什么改成接「后端」而不是直接调服务
///
/// 页面原本写死 `ImageTranslationService.instance`（阅读器的旧引擎单例），
/// 于是**工作室打不开它** —— 而工作室也需要维护术语表（A08 §1.1 · C）。现在页面
/// 只认 [GlossaryBackend]，两个调用方各自给实现：
///
/// * 阅读器 → `ServiceGlossaryBackend`（scope = `cid@sourceKey`）
/// * 工作室 → `StoreGlossaryBackend`（scope = `comicId`）
///
/// 见 `foundation/translation_project/glossary_backend.dart`。本文件因此
/// **不 import 任何引擎**，两种打开方式用的是同一份界面代码，不会漂移。
class GlossaryEditorPage extends StatefulWidget {
  const GlossaryEditorPage({super.key, required this.backend});

  final GlossaryBackend backend;

  @override
  State<GlossaryEditorPage> createState() => _GlossaryEditorPageState();
}

class _GlossaryEditorPageState extends State<GlossaryEditorPage> {
  late List<MapEntry<String, String>> _entries;
  late List<String> _blocked;

  GlossaryBackend get _backend => widget.backend;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _entries = _backend.entries().entries.toList();
    _blocked = _backend.blocked();
  }

  Future<void> _editEntry({String? source, String? translation}) async {
    var sourceController = TextEditingController(text: source ?? '');
    var translationController = TextEditingController(text: translation ?? '');
    var isNew = source == null;
    await showDialog(
      context: context,
      builder: (context) => ContentDialog(
        title: isNew ? "Add term".tl : "Edit term".tl,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: sourceController,
              enabled: isNew,
              decoration: InputDecoration(
                labelText: "Original".tl,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: translationController,
              decoration: InputDecoration(
                labelText: "Translation".tl,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ).paddingHorizontal(16),
        actions: [
          FilledButton(
            onPressed: () {
              var src = sourceController.text.trim();
              var dst = translationController.text.trim();
              if (src.isEmpty || dst.isEmpty) {
                context.showMessage(message: "Both fields are required".tl);
                return;
              }
              var ok = _backend.setEntry(src, dst);
              if (!ok) {
                context.showMessage(
                  message: "Term rejected: too long, or the glossary is full"
                      .tl,
                );
                return;
              }
              context.pop();
              setState(_reload);
            },
            child: Text("Save".tl),
          ),
        ],
      ),
    );
  }

  void _removeEntry(String source, {bool block = false}) {
    _backend.removeEntry(source, block: block);
    setState(_reload);
  }

  void _unblock(String source) {
    _backend.unblockEntry(source);
    setState(_reload);
  }

  /// Delete vs block: a plain delete lets the term be re-learned next time the
  /// model reports it; blocking bans it for good. Ask which the user wants.
  Future<void> _confirmRemove(String source) async {
    await showDialog(
      context: context,
      builder: (context) => ContentDialog(
        title: "Remove term".tl,
        content: Text(
          "Delete only, or block it so it's never added again?".tl,
        ).paddingHorizontal(16),
        actions: [
          TextButton(
            onPressed: () {
              context.pop();
              _removeEntry(source);
            },
            child: Text("Delete".tl),
          ),
          FilledButton(
            onPressed: () {
              context.pop();
              _removeEntry(source, block: true);
            },
            child: Text("Block".tl),
          ),
        ],
      ),
    );
  }

  /// 顶部灰色说明行。刻意常驻而不是塞进空态：工作室的作用域提示必须**在表非空
  /// 时也看得见** —— 用户是"发现阅读器里加的术语在这儿找不到"才会去读它。
  Widget _notice(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(text, style: ts.s14.withColor(context.colorScheme.outline)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final inert = _backend.glossaryInert;
    final isEmpty = _entries.isEmpty && _blocked.isEmpty;
    return Scaffold(
      appBar: Appbar(
        title: Text("Glossary".tl),
        actions: [
          Tooltip(
            message: "Add term".tl,
            child: IconButton(
              icon: const Icon(Icons.add),
              onPressed: () => _editEntry(),
            ),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 工作室与阅读器现在读的是**同一份**数据（scope 都是 `cid@sourceKey`），
          // 差别只剩"翻译组那一层"。不说清楚这条边界，comix.to 的用户会看到
          // 两份条数不同的表，然后以为自己加的术语丢了。
          if (_backend.scopeKind == GlossaryScopeKind.studio)
            _notice(
              "This list belongs to the source comic and is shared with the reader. Edits here apply to the translation group of this chapter."
                  .tl,
            )
          else
            _notice(
              "Shared with the studio. Entries added here apply to every translation group of this comic."
                  .tl,
            ),
          if (inert)
            _notice(
              "Google Translate does not use the glossary. Switch to an AI model to keep names consistent."
                  .tl,
            ),
          Expanded(
            child: isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Text(
                        "No glossary terms yet".tl,
                        style: ts.s16.withColor(context.colorScheme.outline),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : ListView(
                    children: [
                      for (var entry in _entries)
                        ListTile(
                          title: Text(entry.key),
                          subtitle: Text(entry.value),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.edit_outlined),
                                onPressed: () => _editEntry(
                                  source: entry.key,
                                  translation: entry.value,
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () => _confirmRemove(entry.key),
                              ),
                            ],
                          ),
                        ),
                      if (_blocked.isNotEmpty) ...[
                        const Divider(),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                          child: Text(
                            "Blocked terms".tl,
                            style:
                                ts.s14.withColor(context.colorScheme.outline),
                          ),
                        ),
                        for (var term in _blocked)
                          ListTile(
                            leading: Icon(
                              Icons.block,
                              size: 20,
                              color: context.colorScheme.outline,
                            ),
                            title: Text(term),
                            trailing: TextButton(
                              onPressed: () => _unblock(term),
                              child: Text("Unblock".tl),
                            ),
                          ),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

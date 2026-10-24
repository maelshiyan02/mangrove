import 'package:flutter/material.dart';
import 'package:mangrove/components/components.dart';
import 'package:mangrove/foundation/app.dart';
import 'package:mangrove/foundation/comic_override_store.dart';
import 'package:mangrove/utils/translations.dart';

/// 编辑「本地覆盖」信息（P11 §5.3）。
///
/// 为什么不是复用 `showEditLocalComicInfoDialog`：那个对话框写的是
/// `LocalComic`（本地层），只对本地创建的漫画有效。网络漫画的信息来自
/// 站点，不能在源头改——能改的只有**盖在网络壳上的那一层**，所以写
/// `comic_field_overrides`，且每个字段都可以单独"恢复网络原文"。
///
/// 返回 true 表示有改动（调用方据此刷新）。
Future<bool> showComicOverrideDialog(
  BuildContext context, {
  required String comicId,
  required String networkTitle,
  String? networkSubtitle,
  String? networkDescription,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => _ComicOverrideDialog(
      comicId: comicId,
      networkTitle: networkTitle,
      networkSubtitle: networkSubtitle,
      networkDescription: networkDescription,
    ),
  );
  return result ?? false;
}

class _ComicOverrideDialog extends StatefulWidget {
  const _ComicOverrideDialog({
    required this.comicId,
    required this.networkTitle,
    this.networkSubtitle,
    this.networkDescription,
  });

  final String comicId;
  final String networkTitle;
  final String? networkSubtitle;
  final String? networkDescription;

  @override
  State<_ComicOverrideDialog> createState() => _ComicOverrideDialogState();
}

class _ComicOverrideDialogState extends State<_ComicOverrideDialog> {
  late final TextEditingController _title;
  late final TextEditingController _subtitle;
  late final TextEditingController _description;

  @override
  void initState() {
    super.initState();
    final store = ComicOverrideStore.instance;
    // 打开时填的是**当前生效值**（覆盖过的就填覆盖值，没覆盖的填网络值），
    // 这样用户看到的就是详情页上正在显示的东西，不会一打开就"回到原文"。
    _title = TextEditingController(
      text: store.resolveText(
        widget.comicId,
        ComicOverrideStore.fieldTitle,
        widget.networkTitle,
      ),
    );
    _subtitle = TextEditingController(
      text: store.resolveText(
        widget.comicId,
        ComicOverrideStore.fieldSubtitle,
        widget.networkSubtitle,
      ),
    );
    _description = TextEditingController(
      text: store.resolveText(
        widget.comicId,
        ComicOverrideStore.fieldDescription,
        widget.networkDescription,
      ),
    );
  }

  @override
  void dispose() {
    _title.dispose();
    _subtitle.dispose();
    _description.dispose();
    super.dispose();
  }

  /// 与网络原文一致 = 不需要覆盖（写回 null 等于清除）。
  ///
  /// 这样"我改了一下又改回去"不会留下一条无意义的覆盖行，否则以后网络侧
  /// 更新标题，用户会莫名其妙地看到旧标题——因为它被一条他以为自己没改过
  /// 的覆盖挡住了。
  Object? _valueOrNull(String text, String? networkValue) {
    final trimmed = text.trim();
    if (trimmed == (networkValue ?? '').trim()) return null;
    return trimmed.isEmpty ? null : trimmed;
  }

  void _save() {
    final store = ComicOverrideStore.instance;
    final fields = <String, Object?>{
      ComicOverrideStore.fieldTitle: _valueOrNull(
        _title.text,
        widget.networkTitle,
      ),
      ComicOverrideStore.fieldSubtitle: _valueOrNull(
        _subtitle.text,
        widget.networkSubtitle,
      ),
      ComicOverrideStore.fieldDescription: _valueOrNull(
        _description.text,
        widget.networkDescription,
      ),
    };
    store.setFields(widget.comicId, fields);
    Navigator.of(context).pop(true);
  }

  void _resetAll() {
    final store = ComicOverrideStore.instance;
    store.setFields(widget.comicId, {
      ComicOverrideStore.fieldTitle: null,
      ComicOverrideStore.fieldSubtitle: null,
      ComicOverrideStore.fieldDescription: null,
    });
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    // 助手文案把「网络原文」标签和值分开拼：整串带插值的话 `.tl` 查不到词条，
    // 翻译会静默退化成原文（中文界面看着没问题，切到其他语言就露馅）。
    final label = "网络原文".tl;
    final networkTitleHint = '$label：${widget.networkTitle}';
    final subtitle = widget.networkSubtitle;
    final networkSubtitleHint = subtitle == null ? null : '$label：$subtitle';
    final description = widget.networkDescription;
    final networkDescriptionHint = description == null
        ? null
        : '$label：$description';
    return ContentDialog(
      title: "本地信息覆盖".tl,
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "这里改的是「本地覆盖层」：网络原文仍然保留，随时可以恢复。"
                    .tl,
                style: TextStyle(
                  fontSize: 12,
                  color: context.colorScheme.onSurfaceVariant,
                ),
              ).paddingBottom(12),
              TextField(
                controller: _title,
                decoration: InputDecoration(
                  labelText: "标题（漫画名）".tl,
                  helperText: networkTitleHint,
                  helperMaxLines: 2,
                  border: const OutlineInputBorder(),
                ),
              ).paddingBottom(12),
              TextField(
                controller: _subtitle,
                decoration: InputDecoration(
                  labelText: "副标题 / 作者".tl,
                  helperText: networkSubtitleHint,
                  helperMaxLines: 2,
                  border: const OutlineInputBorder(),
                ),
              ).paddingBottom(12),
              TextField(
                controller: _description,
                maxLines: 4,
                decoration: InputDecoration(
                  labelText: "简介".tl,
                  helperText: networkDescriptionHint,
                  helperMaxLines: 3,
                  border: const OutlineInputBorder(),
                ),
              ).paddingBottom(12),
            ],
          ),
        ),
      ),
      actions: [
        Button.text(
          onPressed: _resetAll,
          child: Text("全部恢复原文".tl),
        ),
        Button.text(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text("取消".tl),
        ),
        Button.filled(
          onPressed: _save,
          child: Text("保存".tl),
        ),
      ],
    );
  }
}

import 'package:flutter/material.dart';
import 'package:mangrove/components/components.dart';
import 'package:mangrove/foundation/app.dart';
import 'package:mangrove/foundation/local.dart';
import 'package:mangrove/utils/io.dart';
import 'package:mangrove/utils/local_comic_edit.dart';
import 'package:mangrove/utils/translations.dart';

/// 本地漫画"手动自建 / 加章 / 管理章节"的对话框。
///
/// 全部走 [local_comic_edit] 数据层，与网络下载侧无关。界面一律中文。

/// 新建一本空白本地漫画（无网源链接）。返回新建的 [LocalComic]，取消返回 null。
Future<LocalComic?> showCreateLocalComicDialog(BuildContext context) async {
  return showDialog<LocalComic?>(
    context: context,
    builder: (ctx) => const _CreateLocalComicDialog(),
  );
}

/// 给一本漫画新增章节：选图片文件夹 + 话号 + 翻译组。返回更新后的漫画。
Future<LocalComic?> showAddChapterDialog(
  BuildContext context,
  LocalComic comic,
) async {
  return showDialog<LocalComic?>(
    context: context,
    builder: (ctx) => _AddChapterDialog(comic: comic),
  );
}

/// 管理（删除）一本漫画的章节。返回是否有改动。
Future<bool> showManageChaptersDialog(
  BuildContext context,
  LocalComic comic,
) async {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => _ManageChaptersDialog(comic: comic),
  ).then((v) => v ?? false);
}

class _CreateLocalComicDialog extends StatefulWidget {
  const _CreateLocalComicDialog();

  @override
  State<_CreateLocalComicDialog> createState() =>
      _CreateLocalComicDialogState();
}

class _CreateLocalComicDialogState extends State<_CreateLocalComicDialog> {
  final _title = TextEditingController();
  final _group = TextEditingController();
  final _tags = TextEditingController();
  final _desc = TextEditingController();
  File? _coverFile;
  bool _loading = false;

  @override
  void dispose() {
    _title.dispose();
    _group.dispose();
    _tags.dispose();
    _desc.dispose();
    super.dispose();
  }

  Future<void> _pickCover() async {
    final f = await selectFile(
      ext: const ['jpg', 'jpeg', 'png', 'webp', 'gif'],
    );
    if (f != null) {
      setState(() => _coverFile = File(f.path));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ContentDialog(
      title: "新建漫画".tl,
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _title,
                decoration: InputDecoration(
                  labelText: "漫画标题".tl,
                  border: const OutlineInputBorder(),
                ),
              ).paddingBottom(12),
              TextField(
                controller: _group,
                decoration: InputDecoration(
                  labelText: "翻译组 / 作者（可选）".tl,
                  border: const OutlineInputBorder(),
                ),
              ).paddingBottom(12),
              TextField(
                controller: _tags,
                decoration: InputDecoration(
                  labelText: "标签（逗号分隔，可选）".tl,
                  border: const OutlineInputBorder(),
                ),
              ).paddingBottom(12),
              TextField(
                controller: _desc,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: "简介（可选）".tl,
                  border: const OutlineInputBorder(),
                ),
              ).paddingBottom(12),
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: _loading
                  ? null
                  : () async {
                      await _pickCover();
                    },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(color: cs.outline),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.image_outlined),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _coverFile?.name ?? "选择封面图（可选）".tl,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Text(
                "新建后会在本地库目录创建一本空白漫画，可随后在卡片菜单里"
                "「添加章节」把图片导进去。".tl,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
              ).paddingTop(12),
            ],
          ),
        ),
      ),
      actions: [
        Button.text(
          onPressed: () {
            if (_loading) return;
            Navigator.pop(context);
          },
          child: Text("取消".tl),
        ),
        Button.filled(
          isLoading: _loading,
          onPressed: () async {
            final title = _title.text.trim();
            if (title.isEmpty) {
              context.showMessage(message: "请填写漫画标题".tl);
              return;
            }
            setState(() => _loading = true);
            final tags = _tags.text
                .split(RegExp(r'[，,、]'))
                .map((e) => e.trim())
                .where((e) => e.isNotEmpty)
                .toList();
            final comic = await createLocalComic(
              title: title,
              subtitle: _group.text,
              tags: tags,
              description: _desc.text,
            );
            if (comic != null && _coverFile != null) {
              await setCoverFromFile(comic, _coverFile!);
            }
            if (mounted) {
              Navigator.pop(context, comic);
            }
          },
          child: Text("创建".tl),
        ),
      ],
    );
  }
}

class _AddChapterDialog extends StatefulWidget {
  final LocalComic comic;

  const _AddChapterDialog({required this.comic});

  @override
  State<_AddChapterDialog> createState() => _AddChapterDialogState();
}

class _AddChapterDialogState extends State<_AddChapterDialog> {
  final _number = TextEditingController();
  final _group = TextEditingController();
  Directory? _folder;
  bool _loading = false;

  @override
  void dispose() {
    _number.dispose();
    _group.dispose();
    super.dispose();
  }

  Future<void> _pickFolder() async {
    final dir = await DirectoryPicker().pickDirectory();
    if (dir != null) {
      setState(() => _folder = dir);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ContentDialog(
      title: "添加章节".tl,
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _number,
              decoration: InputDecoration(
                labelText: "话号（如 1、6、Extra）".tl,
                border: const OutlineInputBorder(),
              ),
            ).paddingBottom(12),
            TextField(
              controller: _group,
              decoration: InputDecoration(
                labelText: "翻译组（可选，留空则无组名）".tl,
                border: const OutlineInputBorder(),
              ),
            ).paddingBottom(12),
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: _loading
                  ? null
                  : () async {
                      await _pickFolder();
                    },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  border: Border.all(color: cs.outline),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.folder_open_outlined),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _folder?.path ?? "选择图片文件夹".tl,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Text(
              "图片文件夹里平铺的页面图会被导入为一个章节；带翻译组时目录名形如"
              "「6 [Asura Scans]」。".tl,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
            ).paddingTop(12),
          ],
        ),
      ),
      actions: [
        Button.text(
          onPressed: () {
            if (_loading) return;
            Navigator.pop(context);
          },
          child: Text("取消".tl),
        ),
        Button.filled(
          isLoading: _loading,
          onPressed: () async {
            final number = _number.text.trim();
            if (number.isEmpty) {
              context.showMessage(message: "请填写话号".tl);
              return;
            }
            if (_folder == null) {
              context.showMessage(message: "请选择图片文件夹".tl);
              return;
            }
            setState(() => _loading = true);
            final updated = await addChapterToLocalComic(
              widget.comic,
              chapterNumber: number,
              group: _group.text,
              imagesFolder: _folder!,
            );
            if (mounted) {
              Navigator.pop(context, updated);
            }
          },
          child: Text("导入".tl),
        ),
      ],
    );
  }
}

class _ManageChaptersDialog extends StatefulWidget {
  final LocalComic comic;

  const _ManageChaptersDialog({required this.comic});

  @override
  State<_ManageChaptersDialog> createState() => _ManageChaptersDialogState();
}

class _ManageChaptersDialogState extends State<_ManageChaptersDialog> {
  late final List<String> _dirs;
  final Map<String, bool> _selected = {};

  @override
  void initState() {
    super.initState();
    _dirs = listChapterDirectories(widget.comic);
    for (final d in _dirs) {
      _selected[d] = false;
    }
  }

  Future<void> _delete() async {
    final toDelete = _dirs.where((d) => _selected[d] == true).toList();
    if (toDelete.isEmpty) {
      Navigator.pop(context, false);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => ContentDialog(
        title: "删除章节".tl,
        content: Text(
          "确认删除选中的 @n 个章节？磁盘上的图片将被永久删除。".tlParams(
            {'n': toDelete.length},
          ),
        ).paddingHorizontal(16),
        actions: [
          Button.text(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text("取消".tl),
          ),
          Button.filled(
            color: Theme.of(context).colorScheme.error,
            onPressed: () => Navigator.pop(ctx, true),
            child: Text("删除".tl),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final controller = showLoadingDialog(context, barrierDismissible: false);
    await deleteChapters(widget.comic, toDelete);
    controller.close();
    if (mounted) {
      Navigator.pop(context, true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ContentDialog(
      title: "管理章节".tl,
      content: SizedBox(
        width: 480,
        height: 360,
        child: _dirs.isEmpty
            ? Center(child: Text("还没有章节".tl))
            : ListView.builder(
                itemCount: _dirs.length,
                itemBuilder: (ctx, i) {
                  final d = _dirs[i];
                  return CheckboxListTile(
                    value: _selected[d],
                    onChanged: (v) => setState(() => _selected[d] = v ?? false),
                    title: Text(d),
                  );
                },
              ),
      ),
      actions: [
        Button.text(
          onPressed: () => Navigator.pop(context, false),
          child: Text("关闭".tl),
        ),
        Button.filled(
          onPressed: _delete,
          child: Text("删除选中".tl),
        ),
      ],
    );
  }
}

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
  // 导入来源：0 = 图片文件夹，1 = 多张图片文件。
  int _sourceMode = 0;
  Directory? _folder;
  List<String>? _filePaths;
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
      setState(() {
        _folder = dir;
        _filePaths = null;
      });
    }
  }

  Future<void> _pickFiles() async {
    final files = await selectImages(
      ext: const ['jpg', 'jpeg', 'png', 'webp', 'gif', 'jpe'],
    );
    if (files != null) {
      setState(() {
        _filePaths = files;
        _folder = null;
      });
    }
  }

  /// 本次将要导入的图片数量（用于导入后反馈与空校验）。
  int get _imageCount {
    if (_sourceMode == 0 && _folder != null) {
      try {
        return _folder!
            .listSync()
            .whereType<File>()
            .where((f) => isComicImageFile(f.name))
            .length;
      } catch (_) {
        return 0;
      }
    }
    if (_sourceMode == 1 && _filePaths != null) {
      final baseName = (String p) => p.split(RegExp(r'[/\\]')).last;
      return _filePaths!.where((p) => isComicImageFile(baseName(p))).length;
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final pickedLabel = _sourceMode == 0
        ? (_folder?.path ?? "选择图片文件夹".tl)
        : (_filePaths == null
            ? "选择图片文件".tl
            : "已选 @n 张图片".tlParams({'n': _filePaths!.length}));
    return ContentDialog(
      title: "添加章节".tl,
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
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
              Text(
                "导入来源".tl,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
              ).paddingBottom(6),
              Wrap(
                spacing: 8,
                children: [
                  ChoiceChip(
                    label: Text("图片文件夹".tl),
                    selected: _sourceMode == 0,
                    onSelected: (_) => setState(() => _sourceMode = 0),
                  ),
                  ChoiceChip(
                    label: Text("多张图片".tl),
                    selected: _sourceMode == 1,
                    onSelected: (_) => setState(() => _sourceMode = 1),
                  ),
                ],
              ).paddingBottom(12),
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: _loading
                    ? null
                    : () {
                        if (_sourceMode == 0) {
                          _pickFolder();
                        } else {
                          _pickFiles();
                        }
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
                      Icon(_sourceMode == 0
                          ? Icons.folder_open_outlined
                          : Icons.photo_library_outlined),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          pickedLabel,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Text(
                "只识别图片文件，视频 / 压缩包等会被忽略，也不会被删除，保持磁盘"
                "完整。".tl,
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
            final number = _number.text.trim();
            if (number.isEmpty) {
              context.showMessage(message: "请填写话号".tl);
              return;
            }
            if (_sourceMode == 0 && _folder == null) {
              context.showMessage(message: "请选择图片文件夹".tl);
              return;
            }
            if (_sourceMode == 1 &&
                (_filePaths == null || _filePaths!.isEmpty)) {
              context.showMessage(message: "请至少选择一张图片".tl);
              return;
            }
            final count = _imageCount;
            if (count == 0) {
              context.showMessage(
                message: "该文件夹里没有可导入的图片".tl,
              );
              return;
            }
            setState(() => _loading = true);
            final updated = await addChapterToLocalComic(
              widget.comic,
              chapterNumber: number,
              group: _group.text,
              imagesFolder: _sourceMode == 0 ? _folder : null,
              imageFiles: _sourceMode == 1
                  ? _filePaths!.map((p) => File(p)).toList()
                  : null,
            );
            if (mounted) {
              if (updated != null) {
                context.showMessage(
                  message: "已导入 @n 张图片".tlParams({'n': count}),
                );
              }
              Navigator.pop(context, updated);
            }
          },
          child: Text("导入".tl),
        ),
      ],
    );
  }
}

/// 编辑一本本地漫画的「详细记录表」：标题 / 作者 / 来源 / 更新时间 / 标签 /
/// 描述。返回更新后的 [LocalComic]（取消返回 null）。全部走
/// [LocalManager.updateComicDirect]，只改元数据、不动章节与磁盘。
///
/// 用户自建漫画没有源站点提供这些信息，所以需要在这里手动补齐——封面右侧的
/// 信息区（作者 / 来源 / 更新时间 / 标签 / 描述）正是读这些字段。
Future<LocalComic?> showEditLocalComicInfoDialog(
  BuildContext context,
  LocalComic comic,
) async {
  return showDialog<LocalComic?>(
    context: context,
    builder: (ctx) => _EditLocalComicInfoDialog(comic: comic),
  );
}

class _EditLocalComicInfoDialog extends StatefulWidget {
  final LocalComic comic;

  const _EditLocalComicInfoDialog({required this.comic});

  @override
  State<_EditLocalComicInfoDialog> createState() =>
      _EditLocalComicInfoDialogState();
}

class _EditLocalComicInfoDialogState extends State<_EditLocalComicInfoDialog> {
  final _title = TextEditingController();
  final _author = TextEditingController();
  final _source = TextEditingController();
  final _updateTime = TextEditingController();
  final _tags = TextEditingController();
  final _desc = TextEditingController();
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    final c = widget.comic;
    _title.text = c.title;
    _author.text = c.subtitle;
    _source.text = c.source;
    _updateTime.text = c.updateTime;
    _tags.text = c.tags.join('，');
    _desc.text = c.description;
  }

  @override
  void dispose() {
    _title.dispose();
    _author.dispose();
    _source.dispose();
    _updateTime.dispose();
    _tags.dispose();
    _desc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ContentDialog(
      title: "编辑信息".tl,
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
                  labelText: "标题（漫画名）".tl,
                  border: const OutlineInputBorder(),
                ),
              ).paddingBottom(12),
              TextField(
                controller: _author,
                decoration: InputDecoration(
                  labelText: "作者 / 翻译组（可选）".tl,
                  border: const OutlineInputBorder(),
                ),
              ).paddingBottom(12),
              TextField(
                controller: _source,
                decoration: InputDecoration(
                  labelText: "来源（可选，如 Rokari Comics）".tl,
                  border: const OutlineInputBorder(),
                ),
              ).paddingBottom(12),
              TextField(
                controller: _updateTime,
                decoration: InputDecoration(
                  labelText: "更新时间（可选，自由文本）".tl,
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
              context.showMessage(message: "请填写标题".tl);
              return;
            }
            setState(() => _loading = true);
            final tags = _tags.text
                .split(RegExp(r'[，,、]'))
                .map((e) => e.trim())
                .where((e) => e.isNotEmpty)
                .toList();
            final c = widget.comic;
            final updated = LocalComic(
              id: c.id,
              title: title,
              subtitle: _author.text.trim(),
              tags: tags,
              directory: c.directory,
              chapters: c.chapters,
              cover: c.cover,
              comicType: c.comicType,
              downloadedChapters: c.downloadedChapters,
              createdAt: c.createdAt,
              description: _desc.text,
              source: _source.text.trim(),
              updateTime: _updateTime.text.trim(),
            );
            LocalManager().updateComicDirect(updated);
            if (mounted) {
              Navigator.pop(context, updated);
            }
          },
          child: Text("保存".tl),
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

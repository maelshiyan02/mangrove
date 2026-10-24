import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mangrove/components/components.dart';
import 'package:mangrove/foundation/context.dart';
import 'package:mangrove/utils/cover_pool.dart';
import 'package:mangrove/utils/io.dart';
import 'package:mangrove/utils/translations.dart';

/// 从封面池里挑一张作为当前封面（P12，2026-10-24）。
///
/// 返回**相对漫画根目录**的路径（`cover/[cover]season(1).jpg`）；用户取消或
/// 还没有封面池时返回 null。
///
/// 为什么单独一个对话框而不是塞进"编辑信息"：换封面是**看图选图**的操作，
/// 塞进一个全是文本框的表单里，用户得先记住文件名才能选——那不如不给这个功能。
Future<String?> showCoverPickerDialog(
  BuildContext context, {
  required String baseDir,
  String? currentCover,
}) async {
  final candidates = await listCoverCandidates(baseDir);
  if (!context.mounted) return null;
  if (candidates.isEmpty) {
    await showDialog<void>(
      context: context,
      builder: (ctx) => ContentDialog(
        title: "封面候选".tl,
        content: SizedBox(
          width: 460,
          child: Text(
            "这本漫画还没有封面池。在漫画目录下建一个 cover 文件夹，把图片放进去"
                "（按季换的命名 [KR][cover]season(1).jpg，按单行本卷换的命名"
                " [KR][cover]vol(1).jpg，前面的 [KR]/[CN]/[EN]/[JP] 是封面上的"
                "文字语言），再回来就能在这里切换。"
                .tl,
          ),
        ),
        actions: [
          Button.text(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text("好的".tl),
          ),
        ],
      ),
    );
    return null;
  }
  return showDialog<String>(
    context: context,
    builder: (ctx) => _CoverPickerDialog(
      baseDir: baseDir,
      candidates: candidates,
      current: currentCover,
    ),
  );
}

class _CoverPickerDialog extends StatelessWidget {
  const _CoverPickerDialog({
    required this.baseDir,
    required this.candidates,
    this.current,
  });

  final String baseDir;
  final List<String> candidates;
  final String? current;

  @override
  Widget build(BuildContext context) {
    return ContentDialog(
      title: "封面候选".tl,
      content: SizedBox(
        width: 520,
        height: 420,
        child: GridView.builder(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 0.68,
          ),
          itemCount: candidates.length,
          itemBuilder: (ctx, index) {
            final relative = candidates[index];
            final file = File(FilePath.join(baseDir, relative));
            final selected = relative == current;
            return InkWell(
              onTap: () => Navigator.of(ctx).pop(relative),
              borderRadius: BorderRadius.circular(10),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: selected
                        ? ctx.colorScheme.primary
                        : ctx.colorScheme.outlineVariant,
                    width: selected ? 2.5 : 1,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    Expanded(
                      child: Image.file(
                        file,
                        fit: BoxFit.cover,
                        width: double.infinity,
                        errorBuilder: (_, __, ___) => Center(
                          child: Icon(
                            Icons.broken_image_outlined,
                            color: ctx.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 4,
                      ),
                      child: Text(
                        file.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: ctx.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
      actions: [
        Button.text(
          onPressed: () => Navigator.of(context).pop(),
          child: Text("取消".tl),
        ),
      ],
    );
  }
}

// 翻译工作室里的「翻译设置」入口（P1a · 整体搬迁）。
//
// `ReaderSettings` 本来是阅读设置里的一整块（AI 翻译），现在通过 `onlyTranslation`
// 模式把它单独搬进工作室：普通阅读设置里只留「翻译这一章」开关，这一页给出
// 完整的翻译引擎 / LLM 服务商 / 提示词 / 源目标语言 / 性能 / 高级滑块 / 模型 /
// 清空结果。
//
// 🔴 `comicSource` 对本地工程恒为 null（`StudioReaderStore` 的键把
// `sourceKey ?? ''` 归一化，所以 null 与 '' 等价），与工作室其余逻辑（只用
// `widget.comicId`）保持一致。

import 'package:flutter/material.dart';
import 'package:mangrove/pages/settings/settings_page.dart';

class StudioTranslationSettingsPage extends StatelessWidget {
  const StudioTranslationSettingsPage({
    super.key,
    required this.comicId,
  });

  final String comicId;

  @override
  Widget build(BuildContext context) {
    // 工作室只关心 AI 翻译设置，其余阅读设置不显示。
    return ReaderSettings(
      onlyTranslation: true,
      comicId: comicId,
      comicSource: null,
    );
  }
}

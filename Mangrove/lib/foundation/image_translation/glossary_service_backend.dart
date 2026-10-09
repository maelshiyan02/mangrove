// 术语表编辑器的**阅读器后端**：把 `ImageTranslationService`（旧引擎单例）
// 适配成 `GlossaryBackend`。
//
// 为什么单独一个文件、且**留在引擎层**：
//
// * `pages/comic_details_page/glossary_editor.dart` 因此不必 import 旧引擎 ——
//   这正是「让工作室也能用同一个编辑器」的前提（工作室 import 不到、也不该
//   import 旧引擎）。
// * 这里是旧引擎的**适配层**，S9.5-b 下线旧引擎时它跟着一起删；而编辑器本身
//   与 `StoreGlossaryBackend`（工作室）都留在原地不动。
//
// scope 是 `cid@sourceKey`（一本漫画的不同来源各一份）—— 与工作室那一侧
// **同一个 scope**（工作室经绑定表反查回来）。这个后端不带 `group`，落在共用层：
// 阅读器没有"当前是哪一章"的上下文，而人工确认过的名字本就该对整本漫画生效
// （`glossary_scope.dart` 的 `glossaryEntryApplies`）。

import 'package:mangrove/foundation/image_translation/llm_translator.dart';
import 'package:mangrove/foundation/image_translation/translation_service.dart';
import 'package:mangrove/foundation/translation_project/glossary_backend.dart';

class ServiceGlossaryBackend implements GlossaryBackend {
  const ServiceGlossaryBackend({required this.cid, required this.sourceKey});

  final String cid;

  /// 阅读器里的「来源」标识。旧引擎按 `cid@sourceKey` 分表。
  final String sourceKey;

  @override
  GlossaryScopeKind get scopeKind => GlossaryScopeKind.reader;

  /// 公有免费通道（Google）读不到术语表，所以那条提示在阅读器里是对的。
  ///
  /// 刻意做成 getter 而不是 const：用户随时可能换模型，页面下一次 build
  /// 必须拿到新的答案。
  @override
  bool get glossaryInert => LlmTranslator.activeIsPublicFree;

  @override
  Map<String, String> entries() =>
      ImageTranslationService.instance.glossaryOf(cid, sourceKey);

  @override
  List<String> blocked() =>
      ImageTranslationService.instance.blockedTermsOf(cid, sourceKey);

  @override
  bool setEntry(String source, String translation) =>
      ImageTranslationService.instance.setGlossaryEntry(
        cid,
        sourceKey,
        source,
        translation,
      );

  @override
  void removeEntry(String source, {bool block = false}) =>
      ImageTranslationService.instance.removeGlossaryEntry(
        cid,
        sourceKey,
        source,
        block: block,
      );

  @override
  void unblockEntry(String source) =>
      ImageTranslationService.instance.unblockTerm(cid, sourceKey, source);
}

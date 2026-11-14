// 术语表编辑器的**数据后端**抽象。
//
// ## 为什么要有这层
//
// `GlossaryEditorPage` 原本直接调 `ImageTranslationService.instance` ——
// 而那是**阅读器**的旧引擎单例。后果有两个：
//
// 1. 工作室打不开它（工作室碰不到旧引擎，也不该碰：S9.5-b 要把它整个删掉）；
// 2. 编辑器的 scope 被写死成 `cid@sourceKey`，而工作室工程没有 `sourceKey`。
//
// 所以把「读/写/封杀」抽成接口，页面只认这个接口；两个调用方各自给实现：
//
// * 阅读器 → `ServiceGlossaryBackend`（`image_translation/` 下，随旧引擎一起下线）；
// * 工作室 → `StoreGlossaryBackend`（本文件，直接落在 `GlossaryStore` 上）。
//
// ## scope 与 group（S9.5-b 之后）
//
// 两个后端现在指向**同一份数据**：scope 都是 `cid@sourceKey`（规则只有一处
// 实现 —— `glossary_scope.dart`）。差别只在"谁打开编辑器"决定了
// [GlossaryScopeKind]（页面用它选说明文案）与 [group]。
//
// 🔴 上一版工作室的 scope 是 `comicId`（`bt_<hash>`）。那是错的：一个工程 =
// 一章，于是同一本漫画的 20 章各有一份互不相通的术语表。现在工作室经绑定表
// 反查回来源的 `cid@sourceKey`（`studio_reader_app.dart` 的 `originForProject`），
// 拿不到绑定时才回落到 `comicId`（老工程，本来就没人读过它的术语表）。
//
// ## 零 Flutter 依赖
//
// 本文件不 import 任何 `package:flutter/*`：`StoreGlossaryBackend` 只是把
// [GlossaryStore] 的方法按接口转发。⇒ headless 断言可以拿一个假 sink 直接跑
// 真实逻辑，不需要渲染表面。

import 'glossary_store.dart';

/// 术语表的作用域种类。
///
/// 只用来决定页面显示哪句说明 —— 两者**已经指向同一份数据**（scope 都是
/// `cid@sourceKey`），差别只剩"这一组独有的条目会不会一起显示"。
enum GlossaryScopeKind {
  /// 阅读器：不分翻译组，改的是共用层。
  reader,

  /// 工作室：绑定了某一章的翻译组，改的是那一组的桶。
  studio,
}

/// 术语表编辑器要的全部数据操作。
abstract class GlossaryBackend {
  /// 作用域种类（决定说明文案）。
  GlossaryScopeKind get scopeKind;

  /// 当前通道是否**完全用不上**术语表。
  ///
  /// 旧引擎的公有免费通道（Google）没有术语表入参 ⇒ `true`，页面据此提示
  /// "换用 AI 模型"。工作室走 `GlossaryBridge`（译前占位 → 译后还原），
  /// **任何**引擎都生效 ⇒ 恒 `false`。
  ///
  /// 🔴 这条判断必须由后端给：留在页面里写成
  /// `LlmTranslator.activeIsPublicFree`，工作室就会显示一句错话
  /// （它明明生效，却告诉用户"当前引擎不用术语表"）。
  bool get glossaryInert;

  /// 原文 → 约定译法。返回不可修改的副本（合并视图）。
  Map<String, String> entries();

  /// 被用户封杀的原文词。
  List<String> blocked();

  /// 新增或修改一条。返回 false 表示被拒（词条不合法 / 新增时已达上限）。
  bool setEntry(String source, String translation);

  /// 删除一条；[block] 为 true 时同时封杀该原文词（否则模型下一页还会报上来）。
  void removeEntry(String source, {bool block = false});

  /// 解除封杀。
  void unblockEntry(String source);
}

/// 工作室后端：直接落在 [GlossaryStore] 的一个 (scope, group) 上。
///
/// 不缓存、不包装：`GlossaryStore` 自己就不做进程内缓存（导入备份会整体替换
/// `implicitData`），再包一层缓存等于把那个 bug 请回来。
class StoreGlossaryBackend implements GlossaryBackend {
  const StoreGlossaryBackend(
    this.store,
    this.scope, {
    this.group = GlossaryStore.sharedGroup,
  });

  final GlossaryStore store;
  final String scope;

  /// 这一章绑定的翻译组。非版本化源恒为空串（共用层）。
  final String group;

  @override
  GlossaryScopeKind get scopeKind => GlossaryScopeKind.studio;

  /// 恒 false：工作室的术语走 `GlossaryBridge`，离线 NMT 与无 Key 通道同样生效。
  @override
  bool get glossaryInert => false;

  @override
  Map<String, String> entries() => store.of(scope, group: group);

  @override
  List<String> blocked() => store.blockedOf(scope);

  @override
  bool setEntry(String source, String translation) =>
      store.set(scope, source, translation, group: group);

  @override
  void removeEntry(String source, {bool block = false}) =>
      store.remove(scope, source, group: group, block: block);

  @override
  void unblockEntry(String source) => store.unblock(scope, source);
}

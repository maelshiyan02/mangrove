// 术语表的**身份规则**：一条术语算在哪本漫画名下、哪一个翻译组名下。
//
// ## 为什么单独一个 30 行的文件
//
// `GlossaryStore` 只认两个字符串（scope / group），但"这两个字符串该怎么拼"
// 是一条**有四个调用方**的规则：阅读器（手里有 cid + sourceKey）、工作室
// （只有工程 id，要经绑定表反查）、入队端、术语表编辑器。
//
// 四个地方各拼一遍，就必然有一处拼错而没人发现 —— 本仓库上一版的名字就是
// 这个错的活体标本：**工作室用 `comicId`（`bt_<hash>`）当 scope，入队端用
// `cid`，阅读器用 `cid@sourceKey`** ⇒ 同一本漫画的同一批人名，三条路各写进
// 一份互不相通的表里，界面上一切都"正常"。
//
// ## 两段身份，各管一件事
//
// | 段 | 取值 | 为什么不能省 |
// |---|---|---|
// | **scope** | `cid@sourceKey` | 同一本漫画在不同来源是**两份**数据（不同源的标题/分话/译名都可能不同） |
// | **group** | 翻译组名，没有则空串 | 只在 comix.to 这类**版本化源**上存在：同一本漫画会有多个组，而不同组对同一个英文专名的中文译法可能不同 |
//
// ## 三条硬约束
//
// 1. 🔴 **scope 不是 `comicId`**。一个工程 = 一章，拿工程 id 当 scope 会让同一本
//    漫画的 20 章各有一份术语表 —— 与"同一本漫画要共用"直接冲突。工作室因此
//    必须经**绑定表**反查回来源的 `cid@sourceKey`（见 `studio_reader_app.dart`
//    的 `originForProject`）。
// 2. 🔴 **group 是条目的属性，不是 scope 的一部分**。把组拼进 scope 会得到
//    `cid@sourceKey@组A` 与 `cid@sourceKey@组B` 两份**完全独立**的表 —— 两个组
//    都确认过的同一个名字要录两遍，改一处不会同步另一处。现在的形状是
//    `{scope: {group: {原文: 译文}}}`，共用层是 `''`，读的时候合并、组覆盖共用。
// 3. 🔴 **`sourceKey` 为空 ⇒ 键形退化成 `cid`**，与旧数据逐字节相同。
//    绝大多数源没有 sourceKey，它们因此**零迁移**。
//
// ## 零依赖
//
// 本文件只 import `dart:core`：`headless` 断言能在 `init()` 之前直接调它，
// 不需要渲染表面（`A01 §3`）。
library;

/// 术语表的共用层组名：不属于任何翻译组的条目都落在这里。
///
/// 非版本化源（绝大多数）永远拿到这个值 ⇒ 行为与引入 group 之前完全一致。
const String glossarySharedGroup = '';

/// 漫画身份 = `cid@sourceKey`。
///
/// [sourceKey] 为空 / 全空白时退化成 [cid] —— 旧键就是 `cid`（BT 工程）或
/// `cid@sourceKey`，两种都已经在盘上了，两者都必须继续可读。
String glossaryScopeOf({required String cid, String? sourceKey}) {
  final key = (sourceKey ?? '').trim();
  return key.isEmpty ? cid : '$cid@$key';
}

/// 翻译组归一化。
///
/// 🔴 `null` 与 `''` 与 `'   '` 必须是**同一个**值：`scanlationGroup` 在非版本化
/// 源上是 `null`，在版本化源上没有组时是 `null`，而手写调用点很容易传 `''`。
/// 三种写法指向同一条数据，否则同一本漫画会凭空分裂出两个共用层。
String glossaryGroupOf(String? raw) => (raw ?? '').trim();

/// 要不要把这条术语发给翻译引擎。
///
/// [entryGroup] 是条目自己的组，[queryGroup] 是这次运行用的组。共用层条目
/// （[glossarySharedGroup]）对**任何**组都生效 —— 那是"人工确认过的名字"的
/// 归宿，它比某一组的自动学习更权威。
bool glossaryEntryApplies(String entryGroup, String queryGroup) {
  final entry = glossaryGroupOf(entryGroup);
  if (entry == glossarySharedGroup) return true;
  return entry == glossaryGroupOf(queryGroup);
}

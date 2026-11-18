// P67 · 本地库漫画详情页的缓存自愈 / 评论参数纯策略层。
//
// 🔴 本文件零 Flutter 依赖：headless 自检可在 App 初始化前直接跑。
// 背景（2026-11-18 实测）：《第一次告白》(copy_manga:dycgb) 历史记录正常，
// 但详情页首帧走本地视图 —— subId 被置 null（拷贝评论接口拿它当 comic_id，
// 于是请求 comic_id=null → 500），章节只显示本地库里的 63 话，而 details_cache
// 里其实已有 68 话。缓存存在却没人用它合成网络视图，自动刷新又被默认关掉，
// 首帧于是成了终态。这里把三条决策收敛成纯函数，UI 只负责落地。
library;

import 'package:mangrove/foundation/source_platform.dart';

/// 本地模式构造 ComicDetails 时，评论接口需要的源侧 subId。
///
/// 纯本地漫画（没有源站）与 sourceKey=local 一律给 null；下载自源站的漫画
/// 则优先用刚抓到的在线 subId，没有就用同 (sourceKey, comicId) 的缓存值。
/// 绝不在这里伪造一个 id —— 错误的 id 比 null 更难查。
String? commentsSubIdForLocalDetails({
  required String sourceKey,
  required bool pureLocal,
  String? onlineSubId,
}) {
  if (pureLocal || SourcePlatformResolver.isLocalKey(sourceKey)) return null;
  final id = onlineSubId?.trim();
  if (id == null || id.isEmpty) return null;
  return id;
}

/// 缓存章节比本地记录多时才回填；只增不减（已有 63 → 缓存 68 才写）。
///
/// 反向（缓存少于本地）不能写：本地记录里可能含别的翻译组/手动补的话，
/// 被旧缓存覆盖就再也找不回目录名。
bool shouldEnrichFromCachedDetails({
  required int localChapterCount,
  required int cachedChapterCount,
}) => cachedChapterCount > localChapterCount;

/// 缓存存在且不是纯本地漫画时，首帧就该用它合成网络视图。
///
/// 没有这个兜底时，「缓存存在 + 自动刷新关」会让首帧的本地视图成为终态：
/// 章节停在旧的 63 话、subId 为 null、评论必然 500。
bool shouldUseCachedOnlineView({
  required String sourceKey,
  required bool hasCachedDetails,
}) => !SourcePlatformResolver.isLocalKey(sourceKey) && hasCachedDetails;

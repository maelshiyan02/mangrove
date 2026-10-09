// 入队结果 → 用户看到的那句话。**唯一实现**。
//
// ## 为什么单独一个文件
//
// 同一句"排进去了/没排进去"要出现在**四处**：阅读器开关（`pages/settings/
// reader.dart`）、漫画详情页的【预翻译】（`comic_page/actions.dart`）、建工程
// 入口（`studio_project_menu.dart`）、以后还会有别处。
//
// 原先这六句话的内联 `switch` 只有 `reader.dart` 里那一份。再抄第二份的后果不是
// 报错，是加第七种状态时必然只改一处 —— 而症状是**某处点了完全没有反应**
// （`switch` 的 `default` 不在，提示语是空串，`showMessage('')` 什么都不显示）。
//
// 放在 `pages/translation_studio/` 底下还有一个附带好处：这个目录是 i18n 扫描器
// 的白名单（`headless.dart::_missingStudioTooltips`），六句话的登记漏没漏会被
// `edit-check` 直接检查出来；而 `pages/settings/reader.dart` 不在白名单里。
library;

import 'package:mangrove/foundation/translation_project/studio_enqueue.dart';
import 'package:mangrove/utils/translations.dart';

/// 一条入队结果对应的提示语。
String studioEnqueueMessage(StudioEnqueueStatus status) => switch (status) {
  StudioEnqueueStatus.queued => 'Added to translation tasks'.tl,
  StudioEnqueueStatus.alreadyRunning => 'Translation is already running'.tl,
  StudioEnqueueStatus.upToDate => 'This chapter is already translated'.tl,
  StudioEnqueueStatus.noLocalCopy => 'Download this comic before translating it'.tl,
  StudioEnqueueStatus.noPage => 'No page image found for this chapter'.tl,
  StudioEnqueueStatus.failed => 'Could not start translation'.tl,
};

/// 一批章节入队之后的**一句**话。
///
/// 🔴 逐章报一遍会把提示栏刷成一串，用户只看得见最后一条 —— "后面那几章到底排
/// 上没有"就没有答案了。所以必须在这里先聚合。
///
/// 聚合规则：
/// * 只要有章真的排进去 ⇒ 报"已加入"（其余章节各自的失败原因不去淹没这句）；
/// * 一章都没排进去、且**原因唯一** ⇒ 报那个原因；
/// * 原因不止一种 ⇒ 报失败。这时任何单一原因都是**错的**（其中至少有一章不是
///   因为它失败的），而说一句笼统的失败至少不会把人指向错的地方。
///
/// 空列表（用户一位都没选）不算入队，调用方应在此之前拦住；这里按失败处理。
String studioEnqueueBatchMessage(List<StudioEnqueueStatus> statuses) {
  if (statuses.isEmpty) return studioEnqueueMessage(StudioEnqueueStatus.failed);
  if (statuses.contains(StudioEnqueueStatus.queued)) {
    return studioEnqueueMessage(StudioEnqueueStatus.queued);
  }
  final distinct = statuses.toSet();
  return studioEnqueueMessage(
    distinct.length == 1 ? distinct.first : StudioEnqueueStatus.failed,
  );
}

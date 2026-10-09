// 本地库里一张卡片**是什么**——本流水线的唯一判据。
//
// ## 为什么需要它
//
// `ComicLibrary/` 底下有三个互不相通的根（`A03 §1`）：
//
// ```
// ComicLibrary/
// ├── downloads/<漫画>/<章节>/<n>.webp      ← 用户下载/导入的**素材**
// ├── projects/<工程名>/imgtrans_*.json …   ← 工作室**工程**（`bt_<hash>` 卡）
// └── translated/<漫画>/<章节>/<n>.png      ← 发布出来的**成品**（`ft_<hash>` 卡）
// ```
//
// 三者都被 `LocalManager` 登记成 `comics` 表的行，于是**任何**只说"本地库里的
// 漫画"的地方都会把三种混在一起。2026-10-09 实测该表的三行：`ft_` 成品、
// `bt_` 工程、真正下载的素材 —— 而主页「本地」分区把前两张也画了出来，用户看到
// 的是"本地库里有 MDGH-ch1"。
//
// ## 为什么不能用 `comicType` 判
//
// `ComicType.local` 说的是"这本漫画的**来源**是本地"，而 `bt_`/`ft_` 两张产物卡
// 恰恰也是按 `local` 登记的（`BtProjectManager._registerLocal`、
// `FinishedExport`）—— 反过来，从 comix.to 下载到本地的漫画 `comicType` 是源
// 类型（`496108553` 这种）。用它做"是不是素材"的判据，两类都会判反。
//
// 身份只能看 **id 前缀**，而前缀是各条产线写卡时定下的（`bt_` 工程、`ft_` 成品）。
//
// ## 唯一实现
//
// 🔴 前缀在别处各有一份定义（`BtProjectManager.idPrefix` /
// `FinishedExport.idPrefix`），本文件**引用**它们而不是抄一遍：抄一遍之后加第三
// 种产物前缀时必然只改一处，而症状是"某类产物又混进了本地库"。
library;

import 'package:mangrove/foundation/bt_project/bt_project_manager.dart';
import 'package:mangrove/foundation/translation_project/finished_export.dart';

/// 一张卡片属于三个根里的哪一个。
enum ComicCardKind {
  /// 用户下载或本地导入的素材（`downloads/`）。**只有这一类能被当作建工程的
  /// 素材**，也只有这一类该出现在「本地」这个分区里。
  downloaded,

  /// 工作室工程（`bt_<hash>`，磁盘上 `projects/<名>`）。
  project,

  /// 发布出来的成品（`ft_<hash>`，磁盘上 `translated/<名>`）。
  product,
}

/// [id] 这张卡是哪一类。
///
/// 认不出来的前缀一律当 [ComicCardKind.downloaded]：界面上"多列一条素材"是可
/// 解释的（点进去会说这一本没有页图），而"少列一条素材"是静默的（用户找不到
/// 自己下好的漫画）。
ComicCardKind comicCardKindOf(String? id) {
  if (id == null) return ComicCardKind.downloaded;
  if (id.startsWith(BtProjectManager.idPrefix)) return ComicCardKind.project;
  if (id.startsWith(FinishedExport.idPrefix)) return ComicCardKind.product;
  return ComicCardKind.downloaded;
}

/// 这张卡是不是本流水线**产物**派生出来的（工程 / 成品）。
///
/// 建工程素材筛选、导出选源等"只能用用户自己的素材"的地方都该用它 —— 各处各写
/// 一遍 `startsWith('bt_') || startsWith('ft_')` 之后，加第三种产物时必然只改
/// 一处，而症状是"某类产物又混进来了"。
bool isDerivedComicCard(String? id) =>
    comicCardKindOf(id) != ComicCardKind.downloaded;

/// 主页「本地」栏**不收**的产物卡前缀（工程 + 成品）。
///
/// 收录范围与磁盘上的 `ComicLibrary/downloads/` **一一对应** —— 即"我下载/导入
/// 的素材"。两类产物各有各的家：
///
/// * 工程（`bt_<hash>`）→ 主页「翻译工作室」分区 + 工作室画布；
/// * 成品（`ft_<hash>`）→ 本地库页的「成品」段（它是一本可读漫画，不能没有
///   入口，但也不必挤在「本地」里 —— 挤进来就是 2026-10-09 那个"本地库里有
///   `MDGH-ch1`"的同款困惑）。
///
/// 🔴 本地库页**不用**这份清单：它按 [ComicCardKind] 三分展示，工程与成品各有
/// 一段（见 `local_comics_page.dart`）。"隐藏"只对"这一栏只该有素材"的地方成立。
const List<String> hiddenFromHomeLocalPrefixes = [
  BtProjectManager.idPrefix,
  FinishedExport.idPrefix,
];

/// 这一张卡该不该出现在主页「本地」栏。
///
/// 判据**由 [hiddenFromHomeLocalPrefixes] 推出来**，不是另写一遍前缀。
bool isShownInHomeLocal(String? id) {
  if (id == null) return true;
  return !hiddenFromHomeLocalPrefixes.any((p) => id.startsWith(p));
}

/// 本地库页「来源」分段控件的三段——与磁盘上 `ComicLibrary/` 的三个下属文件夹
/// 一一对应。
///
/// 🔴 文案**不放在**这个文件里：它是纯逻辑层，不该持有 UI 字符串（`.tl` 的字面
/// 量也要能被 i18n 扫描器扫到，那要求它在 dart 文件里就地出现）。
const List<ComicCardKind> localLibraryKinds = ComicCardKind.values;


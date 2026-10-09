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

/// 「本地」栏 / 本地库列表**不收**的产物卡前缀。
///
/// 目前只有工程卡（`bt_<hash>`）：它已经有自己的家 —— 主页的「翻译工作室」分区
/// 与工作室画布。再在「本地」里出现一次，用户看到的是"本地库里有 `MDGH-ch1`"，
/// 而那是 `projects/MDGH-ch1` 里的一个**工程**，不是一部下载的漫画。
///
/// 🔴 成品卡（`ft_<hash>`）**不在这里**，这是有意的：它是可读的漫画，而目前没有
/// 任何别的地方能进它 —— 从本地库拿掉等于把用户自己发布的东西藏起来。它该怎么
/// 展示（独立分区 / 角标 / 跟着工程走）是个产品决定。
const List<String> hiddenFromLocalLibraryPrefixes = [BtProjectManager.idPrefix];

/// 这一张卡该不该出现在「本地」栏 / 本地库列表里。
///
/// 判据**由 [hiddenFromLocalLibraryPrefixes] 推出来**，不是另写一遍前缀：
/// 两处各写一遍就会出现"某一栏按 A 规则过滤、另一栏按 B 规则"，而用户看到的
/// 是同一份列表在两个地方不一样长。
bool isShownInLocalLibrary(String? id) {
  if (id == null) return true;
  return !hiddenFromLocalLibraryPrefixes.any((p) => id.startsWith(p));
}


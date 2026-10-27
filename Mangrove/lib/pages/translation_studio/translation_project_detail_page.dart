// 翻译工程的"详情页"入口 —— P53 起它**就是**普通漫画的详情页。
//
// ## 为什么不再有独立页面
//
// 用户的要求很直白：「不要再用这种页面了，我要的详细页就是和普通漫画一样的
// 这种，只不过下面的章节显示的是翻译工程，而不是普通漫画」。于是这里不再维护
// 一套自己的 UI（封面 / 简介 / 章节列表全自己画），而是**直接用** `ComicPage`：
//
// * 封面、标题、作者、标签、简介 —— 全部**借用素材漫画**（创建工程时把封面复制
//   到工程根、把来源漫画的 id 记进边车，登记时再从本地库把信息取回来）；
// * 章节区 —— 列的是**已有翻译工程的章节**（章节键 = 源章节目录名），不是普通
//   章节；
// * 点章节 —— 走工作室（复合多重显示），不是图片扫描阅读器。分流在
//   `comic_details_page/actions.dart::read` 里，判据是 `bt_` 前缀。
//
// 另做一个页面的代价：工程详情页与漫画详情页长得不一样 ⇒ 用户要点两次才能找到
// 同一本书；而且两边的章节语义不同（一边是普通章节、一边是工程），迟早会漂。
import 'package:flutter/material.dart';
import 'package:mangrove/foundation/app.dart';
import 'package:mangrove/foundation/comic_type.dart';
import 'package:mangrove/foundation/local.dart';
import 'package:mangrove/pages/comic_details_page/comic_page.dart';

/// 翻译工程详情页 = 普通漫画详情页（[ComicPage]）。
///
/// 保留这个类名是为了**不改四个调用点**（主页 / 本地漫画页 / 翻译漫画页 /
/// 合集页都调 [openFor]）—— 但它现在只是"把 `bt_` 卡当成一本漫画打开"。
class TranslationProjectDetailPage extends StatelessWidget {
  final String comicId;

  const TranslationProjectDetailPage({super.key, required this.comicId});

  /// 统一入口：传入一张 `bt_` 工程卡的 id，页面按**本地漫画**打开。
  static void openFor(BuildContext context, String comicId) {
    context.to(() => TranslationProjectDetailPage(comicId: comicId));
  }

  /// 工程卡在本地库里就是一条 `ComicType.local` 记录（登记见
  /// `BtProjectManager._registerComicLocal`），所以按本地漫画找它。
  LocalComic? _comic() => LocalManager().find(comicId, ComicType.local);

  @override
  Widget build(BuildContext context) {
    final comic = _comic();
    return ComicPage(
      id: comicId,
      sourceKey: comic?.sourceKey ?? ComicType.local.sourceKey,
      cover: comic?.cover,
      title: comic?.title,
    );
  }
}

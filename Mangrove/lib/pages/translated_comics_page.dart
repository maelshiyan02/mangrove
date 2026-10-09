import 'package:flutter/material.dart';

import 'package:mangrove/components/components.dart';
import 'package:mangrove/foundation/app.dart';
import 'package:mangrove/foundation/bt_project/bt_project_manager.dart';
import 'package:mangrove/foundation/comic_source/comic_source.dart';
import 'package:mangrove/foundation/local.dart';
import 'package:mangrove/foundation/widget_utils.dart';
import 'package:mangrove/utils/translations.dart';

import 'translation_studio/studio_page.dart';
import 'translation_studio/studio_project_menu.dart';

/// Entry point of the translation studio (P6 §2.9(e)①, revised in S7R).
///
/// It replaced the old "translation library" grid, which showed the products of
/// the retired in-reader AI pipeline. What belongs on the home page now is the
/// list of **FT projects** — the things you actually edit — and tapping one
/// opens the read-only canvas.
///
/// The list is sourced from the local-comic database rather than from the
/// manager's private registry on purpose: [BtProjectManager] already writes one
/// `bt_`-prefixed row per project (title, cover, chapters), so reading it back
/// keeps this page consistent with the reader's own view of the same project.
class TranslationStudioLauncherPage extends StatefulWidget {
  const TranslationStudioLauncherPage({super.key});

  @override
  State<TranslationStudioLauncherPage> createState() =>
      _TranslationStudioLauncherPageState();
}

class _TranslationStudioLauncherPageState
    extends State<TranslationStudioLauncherPage> {
  LocalManager? _manager;
  String _error = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    // The manager registers projects during startup; a scan here covers the
    // case where the user opened this page from the home section before the
    // background scan finished, or just changed the workspace root.
    await BtProjectManager().ensureReady();
    if (!mounted) return;
    setState(() {
      _manager = LocalManager();
      _error = _manager!.isInitialized ? '' : 'Local library is not ready yet.'.tl;
    });
  }

  List<LocalComic> _projects() {
    final manager = _manager;
    if (manager == null || !manager.isInitialized) return const [];
    return manager
        .getComics(LocalSortType.defaultSort)
        .where((comic) => BtProjectManager.isBtComic(comic.id))
        .toList();
  }

  Comic _asComic(LocalComic comic) => Comic(
        comic.title,
        comic.cover,
        comic.id,
        null,
        const [],
        '',
        comic.sourceKey,
        null,
        null,
      );

  @override
  Widget build(BuildContext context) {
    final projects = _projects();
    return Scaffold(
      body: SmoothCustomScrollView(
        slivers: [
          SliverAppbar(
            title: Text('Translation Studio'.tl),
            // 右上角：与工作室详细页**同一个**组件，两份入口共用一条创建链路。
            actions: const [StudioProjectMenu()],
          ),
          if (_error.isNotEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: Text(_error, style: ts.s16)),
            )
          else if (projects.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    // 🔴 单字面量（**不要**拆成相邻两行再对第二行调 `.tl`）：
                    // 相邻字面量在解析期就被 Dart 拼好了，而 i18n 扫描器匹配到
                    // 的是后半截 —— 登记表里那个键于是永远不会被查到，界面
                    // 静默显示英文。这一行原先正是那个写法（`run_dialog.dart`
                    // 头部记着同一条坑）。
                    'No translation project found. Use the menu in the top right corner to create one from a downloaded comic.'
                        .tl,
                    style: ts.s16,
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
              sliver: SliverGridComics(
                comics: [for (final comic in projects) _asComic(comic)],
                enableHero: false,
                onTap: (comic, _) => context.to(
                  () => TranslationStudioPage(comicId: comic.id),
                ),
                menuBuilder: (comic) => [
                  MenuEntry(
                    icon: Icons.open_in_new,
                    text: 'Open studio'.tl,
                    onClick: () => context.to(
                      () => TranslationStudioPage(comicId: comic.id),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Kept for callers that still hold the old page class name.
typedef TranslatedComicsPage = TranslationStudioLauncherPage;

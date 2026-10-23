import 'package:flutter/material.dart';
import 'package:mangrove/foundation/appdata.dart';
import 'package:mangrove/network/comix_client.dart';
import 'package:mangrove/pages/categories_page.dart';
import 'package:mangrove/pages/comic_details_page/comic_page.dart';
import 'package:mangrove/pages/random_comic_draw_dialog.dart';
import 'package:mangrove/pages/search_page.dart';
import 'package:mangrove/pages/settings/settings_page.dart';
import 'package:mangrove/pages/tasks_page.dart';
import 'package:mangrove/utils/translations.dart';

import '../components/components.dart';
import '../foundation/app.dart';
import 'explore_page.dart';
import 'favorites/favorites_page.dart';
import 'home_page.dart';

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  late final NaviObserver _observer;

  GlobalKey<NavigatorState>? _navigatorKey;

  void to(Widget Function() widget, {bool preventDuplicate = false}) async {
    if (preventDuplicate) {
      var page = widget();
      if ("/${page.runtimeType}" == _observer.routes.last.toString()) return;
    }
    _navigatorKey!.currentContext!.to(widget);
  }

  void back() {
    _navigatorKey!.currentContext!.pop();
  }

  @override
  void initState() {
    _observer = NaviObserver();
    _navigatorKey = GlobalKey();
    App.mainNavigatorKey = _navigatorKey;
    index = int.tryParse(appdata.settings['initialPage'].toString()) ?? 0;
    super.initState();
  }

  final _pages = [
    const HomePage(),
    const FavoritesPage(key: PageStorageKey('favorites')),
    const ExplorePage(key: PageStorageKey('explore')),
    const CategoriesPage(key: PageStorageKey('categories')),
  ];

  var index = 0;

  @override
  Widget build(BuildContext context) {
    return NaviPane(
      initialPage: index,
      observer: _observer,
      navigatorKey: _navigatorKey!,
      paneItems: [
        PaneItemEntry(
          label: 'Home'.tl,
          icon: Icons.home_outlined,
          activeIcon: Icons.home,
        ),
        PaneItemEntry(
          label: 'Favorites'.tl,
          icon: Icons.local_activity_outlined,
          activeIcon: Icons.local_activity,
        ),
        PaneItemEntry(
          label: 'Explore'.tl,
          icon: Icons.explore_outlined,
          activeIcon: Icons.explore,
        ),
        PaneItemEntry(
          label: 'Categories'.tl,
          icon: Icons.category_outlined,
          activeIcon: Icons.category,
        ),
      ],
      onPageChanged: (i) {
        setState(() {
          index = i;
        });
      },
      paneActions: [
        if (index != 0)
          PaneActionEntry(
            icon: Icons.search,
            label: "Search".tl,
            onTap: () {
              to(() => const SearchPage(), preventDuplicate: true);
            },
          ),
        // P-DL9 (2026-10-17): comix.to 手动 Cloudflare 验证按钮
        // 常驻侧栏，任何时候都可以点 — 特别是在 comix.to 报"需要手动验证"之后。
        PaneActionEntry(
          icon: Icons.shield,
          label: "验证 CF / Verify CF",
          onTap: () async {
            try {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("正在打开 Cloudflare 验证页面...")),
              );
              final ok = await ComixClient.instance.verifyCloudflare();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      ok
                          ? "✅ CF 验证成功！现在可以重新打开 comix.to 漫画了。"
                          : "❌ 验证未完成。如仍报错请再次点击此按钮。",
                    ),
                  ),
                );
              }
            } catch (e) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text("验证失败: $e")),
                );
              }
            }
          },
        ),
        PaneActionEntry(
          icon: Icons.style_outlined,
          label: 'Draw a comic'.tl,
          onTap: () async {
            final comic = await showRandomComicDrawDialog(context);
            if (!mounted || comic == null) return;
            to(
              () => ComicPage(
                id: comic.id,
                sourceKey: comic.sourceKey,
                cover: comic.cover,
                title: comic.title,
              ),
            );
          },
        ),
        PaneActionEntry(
          icon: Icons.assignment_outlined,
          label: "Tasks".tl,
          onTap: () {
            to(() => const TasksPage(), preventDuplicate: true);
          },
        ),
        PaneActionEntry(
          icon: Icons.settings,
          label: "Settings".tl,
          onTap: () {
            to(() => const SettingsPage(), preventDuplicate: true);
          },
        ),
      ],
      pageBuilder: (index) {
        return _pages[index];
      },
    );
  }
}

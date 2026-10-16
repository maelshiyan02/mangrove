part of 'settings_page.dart';

/// 漫画管理设置（2026-10-16，P-DL6 重构）。
///
/// * 「自动更新漫画信息」总开关 `comicInfoAutoUpdate`：开启后打开漫画即
///   自动联网采集/刷新章节信息，**不区分网络/本地来源**，刷新结果统一
///   回写本地记录（章节矩阵 + 「更新」日期）。
/// * 「本地模式」显示开关 `comicDisplayLocalMode`：只影响章节列表显示
///   （详情页 + 阅读器），与联网无关。
///
/// 页面结构与阅读设置等其他子页一致：SmoothCustomScrollView + SliverAppbar
/// 提供顶部标题行（与其他设置页相同的"距顶一行"间距与标题字号）。
class ComicManagementSettings extends StatefulWidget {
  const ComicManagementSettings({super.key});

  @override
  State<ComicManagementSettings> createState() =>
      _ComicManagementSettingsState();
}

class _ComicManagementSettingsState extends State<ComicManagementSettings> {
  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      scrollbarTopPadding: context.padding.top + 56,
      slivers: [
        SliverAppbar(title: Text("Comic Management".tl)),
        _SettingsExpansionTile(
          expansionKey: const PageStorageKey('comicManagementGroup'),
          initiallyExpanded: true,
          icon: Icons.auto_stories,
          title: "Comic Management".tl,
          children: [
            SwitchListTile(
              title: Text("Auto Update Comic Info".tl),
              subtitle: Text(
                "When on, opening a comic auto-collects/updates the latest chapter info and writes it back to the local record, for network and local comics alike. Off by default."
                    .tl,
              ),
              value: comicInfoAutoUpdate,
              onChanged: (v) {
                setComicInfoAutoUpdate(v);
                setState(() {});
              },
            ),
            // 章节「网络/本地显示模式」（P-DL6）：只切换章节列表的显示，
            // 与联网无关。详情页 AppBar 的 wifi/飞行模式按钮读写同一个键。
            SwitchListTile(
              title: Text("Local Mode".tl),
              subtitle: Text(
                "Local mode shows only downloaded, downloading, standby and problem chapters in the detail page and reader; network mode shows all chapters."
                    .tl,
              ),
              value: comicDisplayLocalMode,
              onChanged: (v) {
                setComicDisplayLocalMode(v);
                setState(() {});
              },
            ),
          ],
        ),
      ],
    );
  }
}

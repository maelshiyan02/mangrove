part of 'settings_page.dart';

/// 漫画管理设置（2026-10-16，P-DL6 重构）。
///
/// * 「自动更新漫画信息」总开关 `comicInfoAutoUpdate`：开启后打开漫画即
///   自动联网采集/刷新章节信息，**不区分网络/本地来源**，刷新结果统一
///   回写本地记录（章节矩阵 + 「更新」日期）。
/// * 「本地模式」默认值 `comicDisplayLocalMode`：P11（2026-10-24）起该开关
///   降级为**新漫画的默认模式**，每本漫画可在详情页单独切换（存
///   `comic_field_overrides.display_mode`）。模式语义也从"只影响章节列表"
///   升级为**信息权限**：网络模式看源头内容，本地模式只看已下载内容 +
///   本地覆盖的自定义信息。
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
            // 章节「网络/本地显示模式」（P-DL6，P11 升级）：这个开关现在是
            // **默认值**，只对从未单独设置过模式的漫画生效；每本漫画在详情页
            // AppBar 的 wifi/飞行模式按钮上单独切换，互不影响。
            SwitchListTile(
              title: Text("Default Local Mode".tl),
              subtitle: Text(
                "Default mode for comics that never set one. Local mode shows downloaded content plus your own custom info; network mode follows the source site. Switch each comic separately from its detail page."
                    .tl,
              ),
              value: comicDisplayLocalMode,
              onChanged: (v) {
                setComicDisplayLocalMode(v);
                setState(() {});
              },
            ),
          ],
        ).toSliver(),
      ],
    );
  }
}

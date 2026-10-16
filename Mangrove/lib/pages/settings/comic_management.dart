part of 'settings_page.dart';

/// 漫画管理设置（2026-10-16）：漫画信息采集/章节更新的自动/手动模式。
///
/// 当前阶段只暴露一个总开关 `comicInfoAutoUpdate`（默认关）。下方两条
/// 「网络/本地双重规则」是后续独立特性（网络漫画默认开、本地漫画默认关）
/// 的占位，本场灰置、标注「稍后开放」，点击无效。
class ComicManagementSettings extends StatefulWidget {
  const ComicManagementSettings({super.key});

  @override
  State<ComicManagementSettings> createState() =>
      _ComicManagementSettingsState();
}

class _ComicManagementSettingsState extends State<ComicManagementSettings> {
  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        _SettingsExpansionTile(
          expansionKey: const PageStorageKey('comicManagementGroup'),
          initiallyExpanded: true,
          icon: Icons.auto_stories,
          title: "Comic Management".tl,
          children: [
            SwitchListTile(
              title: Text("Auto Update Comic Info".tl),
              subtitle: Text(
                "When on, opening a comic auto-collects/updates chapter info. Local-library comics stay read-only; network comics refresh. Off by default."
                    .tl,
              ),
              value: comicInfoAutoUpdate,
              onChanged: (v) {
                setComicInfoAutoUpdate(v);
                setState(() {});
              },
            ),
            // 后续开放：网络/本地双重规则占位（灰置，点击无效）。
            const _DisabledRuleTile(
              title: "Network comics: auto refresh on open",
              subtitle:
                  "Planned: network comics refresh chapter info by default. Enabled later.",
            ),
            const _DisabledRuleTile(
              title: "Local comics: read-only on open",
              subtitle:
                  "Planned: local-library comics stay read-only by default. Enabled later.",
            ),
          ],
        ),
      ],
    );
  }
}

/// 灰置、不可交互的规则占位项（2026-10-16）。仅用于「后续开放」的双重规则
/// 展示，不参与任何逻辑。
class _DisabledRuleTile extends StatelessWidget {
  const _DisabledRuleTile({
    required this.title,
    required this.subtitle,
  });

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final disabled = context.colorScheme.onSurface.withValues(alpha: 0.4);
    return ListTile(
      enabled: false,
      title: Text(title.tl, style: ts.s14.copyWith(color: disabled)),
      subtitle: Text(subtitle.tl, style: ts.s12.copyWith(color: disabled)),
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          border: Border.all(color: disabled),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text("Later".tl, style: ts.s10.copyWith(color: disabled)),
      ),
    );
  }
}

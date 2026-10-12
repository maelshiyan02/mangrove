// B-4 · 右栏「组模式」面板。
//
// 一句话被拆进多个气泡（可跨页）时的工作台：
//
// 1. 成员列表（阅读序序号 / 所在页 / 原文预览，可上下重排 = 为倒装做准备）；
// 2. 组合原文（【组合】按成员顺序拼，可手改，保存写回 group.source）；
// 3. 【翻译一次】：整组只发一次翻译请求；
// 4. 断句**建议**（点 chip 追加到当前成员的分配框，绝不自动采纳）；
// 5. 逐成员译文分配（支持任意顺序 = 倒装），【应用到成员】一次写回。
//
// 🔴 纯逻辑（拼接/断句/一次翻译/分配命令）全在 `group_translate.dart`，
// headless 已断言；本文件只做展示与接线。所有写回都进 owner 的撤销栈。
library;

import 'package:flutter/material.dart';

import 'package:mangrove/foundation/translation_project/block_group.dart';
import 'package:mangrove/foundation/translation_project/group_translate.dart';
import 'package:mangrove/foundation/widget_utils.dart';
import 'package:mangrove/utils/translations.dart';

/// 组成员的展示信息（owner 按 `_uid` 反查块后给出）。
class StudioGroupMemberView {
  const StudioGroupMemberView({
    required this.pageLabel,
    required this.sourcePreview,
    required this.exists,
  });

  /// 所在页的人类可读标签（如 "Page 12"）。
  final String pageLabel;

  /// 块原文预览（一行，超长省略）。
  final String sourcePreview;

  /// 块是否还能按 `_uid` 找到（孤儿引用 = false，红色提示，不允许定位）。
  final bool exists;
}

/// 一个文字块小组的编辑面板。
class StudioGroupPanel extends StatefulWidget {
  const StudioGroupPanel({
    super.key,
    required this.group,
    required this.revision,
    required this.members,
    required this.busy,
    required this.onModeChanged,
    required this.onCombine,
    required this.onTranslateOnce,
    required this.onSourceSubmitted,
    required this.onTranslationSubmitted,
    required this.onReorder,
    required this.onRemoveMember,
    required this.onSelectMember,
    required this.onApplyAssignment,
    required this.onDissolve,
  });

  final BlockGroup group;
  final int revision;
  final List<StudioGroupMemberView> members;
  final bool busy;

  final ValueChanged<GroupMode> onModeChanged;
  final VoidCallback onCombine;
  final Future<void> Function() onTranslateOnce;
  final ValueChanged<String> onSourceSubmitted;
  final ValueChanged<String> onTranslationSubmitted;

  /// 成员重排（[from] 移动到 [to]，to 为删除后的下标）。
  final void Function(int from, int to) onReorder;
  final ValueChanged<int> onRemoveMember;
  final ValueChanged<int> onSelectMember;

  /// 应用逐成员分配（键 = `"<page>#<uid>"`）。
  final ValueChanged<Map<String, String>> onApplyAssignment;
  final VoidCallback onDissolve;

  @override
  State<StudioGroupPanel> createState() => _StudioGroupPanelState();
}

class _StudioGroupPanelState extends State<StudioGroupPanel> {
  late final TextEditingController _sourceController;
  late final TextEditingController _translationController;
  final _sourceFocus = FocusNode();
  final _translationFocus = FocusNode();

  /// 成员键 → 分配框控制器 / 焦点。成员集合变化时重建。
  final Map<String, TextEditingController> _assignControllers = {};
  final Map<String, FocusNode> _assignFocuses = {};

  /// 断句 chip 追加的目标成员（点输入框时登记）；默认第一个成员。
  String? _activeAssignKey;

  @override
  void initState() {
    super.initState();
    _sourceController = TextEditingController(text: widget.group.source ?? '');
    _translationController =
        TextEditingController(text: widget.group.translation ?? '');
    _rebuildAssignControllers(initial: true);
  }

  @override
  void didUpdateWidget(covariant StudioGroupPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.revision == oldWidget.revision) return;
    // 外部模型变化（undo/redo / 翻译一次回填 / 换组）：失焦字段跟随模型，
    // 正在编辑的字段不打断。
    if (!_sourceFocus.hasFocus) {
      final text = widget.group.source ?? '';
      if (_sourceController.text != text) _sourceController.text = text;
    }
    if (!_translationFocus.hasFocus) {
      final text = widget.group.translation ?? '';
      if (_translationController.text != text) {
        _translationController.text = text;
      }
    }
    _syncAssignControllers();
  }

  /// 成员集合变化时增删控制器；新成员初值取组里已存的 assignment。
  void _rebuildAssignControllers({bool initial = false}) {
    final keys = <String>{
      for (final member in widget.group.members) member.key,
    };
    _assignControllers.removeWhere((key, controller) {
      if (keys.contains(key)) return false;
      controller.dispose();
      _assignFocuses.remove(key)?.dispose();
      return true;
    });
    for (final member in widget.group.members) {
      _assignControllers.putIfAbsent(
        member.key,
        () {
          final focus = FocusNode();
          focus.addListener(() {
            if (focus.hasFocus) {
              setState(() => _activeAssignKey = member.key);
            }
          });
          _assignFocuses[member.key] = focus;
          return TextEditingController(
            text: widget.group.assignment[member.key] ?? '',
          );
        },
      );
    }
    if (_activeAssignKey == null || !keys.contains(_activeAssignKey)) {
      _activeAssignKey = widget.group.members.isEmpty
          ? null
          : widget.group.members.first.key;
    }
  }

  /// revision 变化后：成员增删则重建，否则把外部 assignment 刷新进失焦字段。
  void _syncAssignControllers() {
    final oldKeys = _assignControllers.keys.toSet();
    final newKeys = {
      for (final member in widget.group.members) member.key,
    };
    if (!_keysEqual(oldKeys, newKeys)) {
      _rebuildAssignControllers();
      return;
    }
    for (final member in widget.group.members) {
      final focus = _assignFocuses[member.key];
      if (focus?.hasFocus ?? false) continue;
      final text = widget.group.assignment[member.key] ?? '';
      final controller = _assignControllers[member.key];
      if (controller != null && controller.text != text) {
        controller.text = text;
      }
    }
  }

  bool _keysEqual(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  @override
  void dispose() {
    _sourceController.dispose();
    _translationController.dispose();
    _sourceFocus.dispose();
    _translationFocus.dispose();
    for (final controller in _assignControllers.values) {
      controller.dispose();
    }
    for (final focus in _assignFocuses.values) {
      focus.dispose();
    }
    super.dispose();
  }

  void _appendToActiveAssign(String segment) {
    final key = _activeAssignKey;
    final controller = key == null ? null : _assignControllers[key];
    if (controller == null) return;
    final existing = controller.text;
    controller.text = existing.trim().isEmpty
        ? segment
        : '$existing\n$segment';
  }

  void _fillInOrder(List<String> segments) {
    for (var i = 0; i < widget.group.members.length; i++) {
      if (i >= segments.length) break;
      _assignControllers[widget.group.members[i].key]?.text = segments[i];
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final group = widget.group;
    final suggestions = suggestSegments(_sourceController.text);
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        // ── 标题 + 形态切换 + 解组 ──────────────────────────────────────
        Row(
          children: [
            Expanded(child: Text('Text group'.tl, style: ts.s16)),
            SegmentedButton<GroupMode>(
              segments: [
                ButtonSegment(
                  value: GroupMode.nest,
                  icon: const Icon(Icons.crop_square, size: 16),
                  label: Text('Nest'.tl),
                ),
                ButtonSegment(
                  value: GroupMode.link,
                  icon: const Icon(Icons.linear_scale, size: 16),
                  label: Text('Connect'.tl),
                ),
              ],
              selected: {group.mode},
              showSelectedIcon: false,
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
              ),
              onSelectionChanged: (selection) =>
                  widget.onModeChanged(selection.first),
            ),
            IconButton(
              tooltip: 'Ungroup'.tl,
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.link_off, color: scheme.error),
              onPressed: widget.busy ? null : widget.onDissolve,
            ),
          ],
        ),
        const Divider(height: 20),

        // ── 成员列表 ───────────────────────────────────────────────────
        Text('Members'.tl, style: ts.s14.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        for (var i = 0; i < group.members.length; i++)
          _memberTile(context, i, group.members[i], widget.members[i]),
        const Divider(height: 20),

        // ── 组合原文 ───────────────────────────────────────────────────
        Row(
          children: [
            Expanded(
              child: Text(
                'Combined source'.tl,
                style: ts.s14.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            TextButton.icon(
              onPressed: widget.busy ? null : widget.onCombine,
              icon: const Icon(Icons.merge_type, size: 18),
              label: Text('Combine'.tl),
            ),
            TextButton(
              onPressed: () =>
                  widget.onSourceSubmitted(_sourceController.text),
              child: Text('Save'.tl),
            ),
          ],
        ),
        const SizedBox(height: 4),
        TextField(
          controller: _sourceController,
          focusNode: _sourceFocus,
          minLines: 2,
          maxLines: 5,
          style: ts.s12,
          decoration: InputDecoration(
            isDense: true,
            border: const OutlineInputBorder(),
            hintText: 'Combine member sources, then edit as needed.'.tl,
          ),
        ),
        const SizedBox(height: 12),

        // ── 翻译一次 ───────────────────────────────────────────────────
        Row(
          children: [
            Expanded(
              child: Text(
                'Group translation'.tl,
                style: ts.s14.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            FilledButton.tonalIcon(
              onPressed: widget.busy ? null : () => widget.onTranslateOnce(),
              icon: widget.busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.translate, size: 18),
              label: Text('Translate once'.tl),
            ),
            TextButton(
              onPressed: () =>
                  widget.onTranslationSubmitted(_translationController.text),
              child: Text('Save'.tl),
            ),
          ],
        ),
        const SizedBox(height: 4),
        TextField(
          controller: _translationController,
          focusNode: _translationFocus,
          minLines: 2,
          maxLines: 5,
          style: ts.s12,
          decoration: InputDecoration(
            isDense: true,
            border: const OutlineInputBorder(),
            hintText: 'One translation for the whole sentence.'.tl,
          ),
        ),
        const SizedBox(height: 12),

        // ── 断句建议（只建议，不自动采纳） ─────────────────────────────
        Text(
          'Suggested segments'.tl,
          style: ts.s14.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        if (suggestions.isEmpty)
          Text(
            'Combine the source text first.'.tl,
            style: ts.s12.copyWith(color: scheme.onSurfaceVariant),
          )
        else
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final segment in suggestions)
                ActionChip(
                  visualDensity: VisualDensity.compact,
                  label: Text(segment, style: ts.s12),
                  onPressed: () => _appendToActiveAssign(segment),
                ),
            ],
          ),
        const SizedBox(height: 12),

        // ── 逐成员分配（倒装 = 任意顺序） ──────────────────────────────
        Row(
          children: [
            Expanded(
              child: Text(
                'Member translations'.tl,
                style: ts.s14.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            TextButton.icon(
              onPressed: suggestions.isEmpty
                  ? null
                  : () => _fillInOrder(suggestions),
              icon: const Icon(Icons.playlist_add, size: 18),
              label: Text('Fill in order'.tl),
            ),
            FilledButton.tonalIcon(
              onPressed: widget.busy
                  ? null
                  : () {
                      final values = <String, String>{
                        for (final member in group.members)
                          member.key:
                              _assignControllers[member.key]?.text ?? '',
                      };
                      widget.onApplyAssignment(values);
                    },
              icon: const Icon(Icons.check, size: 18),
              label: Text('Apply to members'.tl),
            ),
          ],
        ),
        const SizedBox(height: 4),
        for (var i = 0; i < group.members.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: TextField(
              controller: _assignControllers[group.members[i].key],
              focusNode: _assignFocuses[group.members[i].key],
              minLines: 1,
              maxLines: 4,
              style: ts.s12,
              decoration: InputDecoration(
                isDense: true,
                border: const OutlineInputBorder(),
                // 🔴 只能用 @占位：插值写进 .tl 字面量会在查找前就被拼掉，
                // 永远查不到译文（i18n 扫描也会把源码片段当成 key）。
                labelText: '@a · @b'.tlParams({
                  'a': '${i + 1}',
                  'b': widget.members[i].pageLabel,
                }),
              ),
            ),
          ),
      ],
    );
  }

  /// 成员行：上下移 / 序号 / 页+原文（点行定位到画布）/ 移除。
  Widget _memberTile(
    BuildContext context,
    int i,
    GroupMemberRef ref,
    StudioGroupMemberView view,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final canUp = i > 0;
    final canDown = i < widget.group.members.length - 1;
    return Card(
      margin: const EdgeInsets.only(bottom: 4),
      elevation: 0,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Row(
          children: [
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                InkResponse(
                  onTap: canUp ? () => widget.onReorder(i, i - 1) : null,
                  child: Icon(
                    Icons.keyboard_arrow_up,
                    size: 18,
                    color: canUp ? null : scheme.onSurfaceVariant.withValues(alpha: 0.4),
                  ),
                ),
                InkResponse(
                  onTap: canDown ? () => widget.onReorder(i, i + 1) : null,
                  child: Icon(
                    Icons.keyboard_arrow_down,
                    size: 18,
                    color: canDown ? null : scheme.onSurfaceVariant.withValues(alpha: 0.4),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 4),
            CircleAvatar(
              radius: 11,
              backgroundColor: scheme.secondaryContainer,
              child: Text(
                '${i + 1}',
                style: ts.s12.copyWith(color: scheme.onSecondaryContainer),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: InkWell(
                onTap: view.exists ? () => widget.onSelectMember(i) : null,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      view.pageLabel,
                      style: ts.s12.copyWith(color: scheme.primary),
                    ),
                    Text(
                      view.exists
                          ? (view.sourcePreview.trim().isEmpty
                              ? '(no source text)'.tl
                              : view.sourcePreview)
                          : 'missing block'.tl,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ts.s12.copyWith(
                        color: view.exists
                            ? scheme.onSurface
                            : scheme.error,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            IconButton(
              tooltip: 'Remove'.tl,
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              icon: const Icon(Icons.close),
              onPressed: widget.busy ? null : () => widget.onRemoveMember(i),
            ),
          ],
        ),
      ),
    );
  }
}

// B-4 · 「组合原文 → 翻译一次 → 断句分配」的纯逻辑（跨页拼接计划 §4-B4）。
//
// 把组内多个成员的原文组合成完整句 → 翻译**一次** → 断句 → **分配**回各成员；
// 并处理**倒装句**（成员顺序与译文顺序可能错位）。
//
// 🔴 本文件**不含 Flutter 依赖**（只 import 纯逻辑模块），所以组合、切分建议、
// 映射校验、可撤销写回都能 headless 跑完。右栏的"组模式"面板是 UI，另行处理。
//
// ## 手动 vs 自动边界（计划 §4-B4）
//
// * 自动**只做**：组合、一次翻译调用、切分**建议**、映射校验、可撤销写回。
// * 自动**不做**：**不自动采纳**切分；**不按字符比例自动切**；不自动纠错。
library;

import 'block_group.dart';
import 'edit_command.dart';
import 'text_block.dart' show TextBlock;

/// 组合：按成员顺序把原文拼成完整句。
///
/// [sources] 必须**已是成员顺序**（见 `sortMembersReadingOrder`）。空/全空白的
/// 成员不产生片段（那只会往句子里塞一个空段）。
///
/// [separator] 默认换行：截断处常有 OCR 断字/重复/缺字（计划 §4-B4 步骤 2），
/// 换行让"这里原本是分段"可见、便于人工校对；CJK 断字用 `''` 拼接更贴合原句。
///
/// 🔴 不写回任何块 —— `groupconcat.never_mutates_member_source`。
String concatMemberSources(
  List<String> sources, {
  String separator = '\n',
}) {
  final parts = <String>[];
  for (final source in sources) {
    final trimmed = source.trim();
    if (trimmed.isEmpty) continue;
    parts.add(trimmed);
  }
  return parts.join(separator);
}

/// 断句终止符（**建议**用，不自动采纳）。
///
/// 含中日文的句末标点与英文的 `.` / `!` / `?`、分号。`.` 会把小数/缩写也切一刀，
/// 但切分只是**建议**、可人工合并，所以宁可多切不可漏切。
const String segmentTerminators = '。！？!?…；;．.';

/// 按标点/句读给"建议片段"（保留终止符在本段末尾）。
///
/// 只**建议**：调用方负责让人确认/合并/重排，绝不自动写回。
List<String> suggestSegments(String source) {
  final segments = <String>[];
  final buffer = StringBuffer();
  void flush() {
    final text = buffer.toString().trim();
    buffer.clear();
    if (text.isNotEmpty) segments.add(text);
  }

  for (final rune in source.runes) {
    final ch = String.fromCharCode(rune);
    if (ch == '\n' || ch == '\r') {
      flush();
      continue;
    }
    buffer.write(ch);
    if (segmentTerminators.contains(ch)) flush();
  }
  flush();
  return segments;
}

/// 一次组翻译调用（注入用）。返回与入参一一对应的译文列表。
typedef GroupTranslateCall = Future<List<String>> Function(List<String> texts);

/// `source` 缺失/为空时**不调用**翻译的缘由码。
const String groupTranslateSourceMissing = 'source_missing';

/// 一次组翻译的结果。
class GroupTranslationAttempt {
  const GroupTranslationAttempt({
    required this.calls,
    this.text,
    this.reason,
  });

  /// 实际调用翻译的次数（0 或 1）。
  final int calls;

  /// 译出的完整句；[calls] 为 0 时为 null。
  final String? text;

  /// [calls] 为 0 时的缘由码。
  final String? reason;
}

/// 把组的完整原文**翻译一次**。
///
/// 🔴 一组**只调用一次**（入参是长度 1 的列表），而不是每个成员各调一次 ——
/// 那会把一句被截断的话拆成互不知情的碎片，正是本功能要消灭的错
/// （`distribute.one_dispatcher_call_per_group`）。
///
/// 原文缺失/全空白时**不调用**（`distribute.never_runs_when_source_missing`）。
Future<GroupTranslationAttempt> translateGroupOnce({
  required String? source,
  required GroupTranslateCall translate,
}) async {
  final text = source?.trim() ?? '';
  if (text.isEmpty) {
    return const GroupTranslationAttempt(
      calls: 0,
      reason: groupTranslateSourceMissing,
    );
  }
  final results = await translate([text]);
  return GroupTranslationAttempt(
    calls: 1,
    text: results.isNotEmpty ? results.first : '',
  );
}

/// 还没有分配的成员（**孤儿检查**：每个成员都必须拿到一段，哪怕是显式空串
/// = "本块不再出译文"）。
///
/// 🔴 倒装（非顺序映射）**不算**未分配：分配是 `memberKey -> 片段`，谁拿哪段由
/// 人决定（`distribute.allows_non_monotonic_mapping`）。返回空表才是"分配完整"。
List<GroupMemberRef> unmappedMembers(
  BlockGroup group,
  Map<String, String> assignment,
) =>
    [
      for (final member in group.members)
        if (!assignment.containsKey(member.key)) member,
    ];

/// 把分配写回各成员块，返回**可撤销**命令。
///
/// * 未分配 / 已分配但与原译文相同的成员**不产生命令**（空命令会被
///   `EditHistory.push` 丢弃）；
/// * [blockOf] 取不到块（孤儿成员引用）**跳过**，不静默新建块；
/// * 命令逐个 `pageKey` 齐备，脏页跟踪因此仍有效。
///
/// 调用方在拿到命令后 push 进 `EditHistory` 即可撤销（`distribute.is_undoable`）。
List<ProjectEditCommand> applyGroupAssignment({
  required BlockGroup group,
  required Map<String, String> assignment,
  required TextBlock? Function(GroupMemberRef ref) blockOf,
  String label = '组译文分配',
}) {
  final commands = <ProjectEditCommand>[];
  for (final member in group.members) {
    final text = assignment[member.key];
    if (text == null) continue;
    final block = blockOf(member);
    if (block == null) continue;
    if (block.translation == text) continue;
    final command = captureBlockEdit(
      block.raw,
      () => block.translation = text,
      pageKey: member.page,
      label: label,
    );
    if (!command.isEmpty) commands.add(command);
  }
  return commands;
}
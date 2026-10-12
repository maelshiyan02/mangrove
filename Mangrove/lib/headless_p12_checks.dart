// B-3（文字块小组）+ B-4（组合翻译分配）的 headless 断言集
// （跨页拼接计划 §4-B3 / §4-B4 验收）。
//
// 组的模型、成员排序、并集、惰性 `_uid`、工程级读写、组合/切分/映射校验/可撤销
// 写回，全部在纯 Dart 里（`block_group.dart` / `group_translate.dart`），所以这一
// 批能被 headless 跑完。画布上的建组交互与右栏组模式是 UI，本会话没有渲染表面，
// 只能由用户在 GUI 会话验收。
//
// ## 反向验证（M08）
//
// 每条断言跑两遍：绿路径喂**真实现**，故障路径喂一个**故意写错的实现**，两条
// 路径检验的是**同一个命题**。`故障路径=变红` 才说明判据不是装饰品。
library;

import 'dart:io';

import 'package:mangrove/foundation/image_translation/translation_types.dart'
    show IntRect;
import 'package:mangrove/foundation/translation_project/block_group.dart';
import 'package:mangrove/foundation/translation_project/edit_command.dart';
import 'package:mangrove/foundation/translation_project/group_translate.dart';
import 'package:mangrove/foundation/translation_project/project.dart';
import 'package:mangrove/foundation/translation_project/project_io.dart';
import 'package:mangrove/foundation/translation_project/text_block.dart'
    show TextBlock;
import 'package:mangrove/headless_p1_checks.dart' show CheckSink;

// ── 夹具 ────────────────────────────────────────────────────────────────

TextBlock _block(String source, {required int top, int left = 10}) {
  final block = TextBlock.createDefault(
    rect: IntRect(left, top, left + 100, top + 40),
  );
  block.sourceText = source;
  return block;
}

/// 平整页序：`a.webp` 在上、`b.webp` 在下（用于跨页排序用例）。
const _pageOrder = ['a.webp', 'b.webp'];

int _pageIndex(String page) {
  final at = _pageOrder.indexOf(page);
  return at < 0 ? 1 << 30 : at;
}

/// 一个 3 成员的组（同页），成员顺序 m0 → m1 → m2。
BlockGroup _sampleGroup() => BlockGroup(
      id: 'g1',
      members: const [
        GroupMemberRef('a.webp', 'm0'),
        GroupMemberRef('a.webp', 'm1'),
        GroupMemberRef('a.webp', 'm2'),
      ],
      source: '第一段。第二段。第三段。',
    );

/// 3 个带确定 `_uid` 的块（m0 / m1 / m2）。
List<TextBlock> _sampleBlocks() {
  final blocks = <TextBlock>[];
  for (var i = 0; i < 3; i++) {
    final block = _block('原文$i', top: 10 + i * 60);
    ensureBlockUid(block, mint: () => 'm$i');
    blocks.add(block);
  }
  return blocks;
}

Map<String, Object?> _withoutMode(Map<String, Object?> raw) {
  final copy = deepCopyJsonMap(raw);
  copy.remove('mode');
  return copy;
}

bool _listEq(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// ── 1 · 成员按页号 → 阅读序 y 排序 ─────────────────────────────────────

typedef _SortFn = List<GroupMemberRef> Function(
  List<GroupMemberRef> members, {
  required int Function(String page) pageIndex,
  required IntRect? Function(GroupMemberRef ref) rectOf,
});

/// 命题：跨页混排时**页号优先**，同页按 **y 升序**（页顶的块在前 = 阅读序）。
///
/// 分辨点：一个"只看 y 不看页"的实现会把下页靠上的块排到上页靠下的块之前 ——
/// 组合出的句子于是跨页错位。
bool _sortMatches(_SortFn fn) {
  final rects = <String, IntRect>{
    'a.webp#uA1': IntRect(10, 500, 110, 540),
    'a.webp#uA2': IntRect(10, 200, 110, 240),
    'b.webp#uB1': IntRect(10, 100, 110, 140),
    'b.webp#uB2': IntRect(10, 300, 110, 340),
  };
  IntRect? rectOf(GroupMemberRef ref) => rects[ref.key];
  // 输入刻意打乱，结果必须与输入顺序无关。
  final members = [
    const GroupMemberRef('b.webp', 'uB2'),
    const GroupMemberRef('a.webp', 'uA1'),
    const GroupMemberRef('b.webp', 'uB1'),
    const GroupMemberRef('a.webp', 'uA2'),
  ];
  final sorted = fn(members, pageIndex: _pageIndex, rectOf: rectOf);
  return _listEq(
    [for (final m in sorted) m.key],
    const [
      'a.webp#uA2',
      'a.webp#uA1',
      'b.webp#uB1',
      'b.webp#uB2',
    ],
  );
}

/// 故障实现：只看 y，不看页号。
List<GroupMemberRef> _faultySort(
  List<GroupMemberRef> members, {
  required int Function(String page) pageIndex,
  required IntRect? Function(GroupMemberRef ref) rectOf,
}) {
  final sorted = [...members];
  sorted.sort((a, b) {
    final ya = rectOf(a)?.top ?? 0;
    final yb = rectOf(b)?.top ?? 0;
    return ya.compareTo(yb);
  });
  return sorted;
}

// ── 2 · nest / link 只改 mode，不动数据 ────────────────────────────────

/// 命题：把 `nest` 改成 `link`，**除 `mode` 外数据完全一致**（D17 同一数据结构）。
bool _modeChangeKeepsData(BlockGroup Function(BlockGroup) change) {
  final group = _sampleGroup();
  group.assignment['a.webp#m0'] = '片段0';
  group.translation = '整句译文';
  final before = _withoutMode(group.toRaw());
  change(group);
  return group.mode == GroupMode.link &&
      jsonEquals(before, _withoutMode(group.toRaw()));
}

/// 故障实现：切到 link 的同时把 `source` 清掉（两套会漂移的代码路径）。
BlockGroup _faultyModeChange(BlockGroup group) {
  group.mode = GroupMode.link;
  group.source = null;
  return group;
}

// ── 3 · 组边界框 = 成员并集 ─────────────────────────────────────────────

typedef _BoundsFn = IntRect? Function(
  List<GroupMemberRef> members, {
  required IntRect? Function(GroupMemberRef ref) rectOf,
});

/// 命题：并集 = 逐边 min/max，成员矩形之外不多不少。
bool _boundsIsUnion(_BoundsFn fn) {
  final rects = <String, IntRect>{
    'a.webp#m1': IntRect(10, 10, 110, 60),
    'a.webp#m2': IntRect(200, 300, 260, 360),
  };
  final bounds = fn(
    const [GroupMemberRef('a.webp', 'm1'), GroupMemberRef('a.webp', 'm2')],
    rectOf: (ref) => rects[ref.key],
  );
  return bounds != null &&
      bounds.left == 10 &&
      bounds.top == 10 &&
      bounds.right == 260 &&
      bounds.bottom == 360;
}

/// 故障实现：只返回第一个成员的矩形（漏掉了其余成员）。
IntRect? _faultyBounds(
  List<GroupMemberRef> members, {
  required IntRect? Function(GroupMemberRef ref) rectOf,
}) {
  if (members.isEmpty) return null;
  final rect = rectOf(members.first);
  if (rect == null) return null;
  return IntRect(rect.left, rect.top, rect.right, rect.bottom);
}

// ── 4 · 删无关块后成员引用仍指向原块（_uid） ──────────────────────────

typedef _ResolveFn = TextBlock? Function(List<TextBlock> blocks, String uid);

/// 命题：用 `_uid` 引用成员时，删掉**别的**块不会让引用指错块。
bool _refStableAfterDelete(_ResolveFn resolve) {
  final drop = _block('drop-me', top: 10);
  final keep = _block('keep', top: 100);
  final target = _block('target', top: 200);
  ensureBlockUid(target, mint: () => 'u2');
  final blocks = [drop, keep, target];
  blocks.removeAt(0); // 删无关块
  final resolved = resolve(blocks, 'u2');
  return resolved != null && resolved.sourceText == 'target';
}

/// 故障实现：按下标寻址（原下标 2），删块后指到别的块 / 越界。
TextBlock? _faultyResolveByIndex(List<TextBlock> blocks, String uid) {
  const originalIndex = 2;
  return originalIndex < blocks.length ? blocks[originalIndex] : null;
}

// ── 5 · `_uid` 惰性：从不建组的块不长出这个键 ──────────────────────────

typedef _EnsureFn = String Function(TextBlock block, String Function() mint);

/// 命题：① 新建块**没有** `_uid`；② 首次 `ensure` 才写入且**幂等**（已有时不再
/// 铸造）。两条合起来 = "从不建组的工程零字节 diff"。
bool _uidIsLazy(_EnsureFn ensure) {
  final fresh = _block('x', top: 10);
  if (fresh.raw.containsKey(blockUidKey)) return false; // ① 键根本不存在
  var minted = 0;
  final first = ensure(fresh, () => 'u${++minted}');
  if (!fresh.raw.containsKey(blockUidKey) || first != 'u1') return false;
  final second = ensure(fresh, () => 'u${++minted}');
  return second == 'u1' && minted == 1; // ② 幂等
}

/// 故障实现：每次都重新铸造并覆盖（不幂等 ⇒ 组引用会漂移）。
String _faultyEagerEnsure(TextBlock block, String Function() mint) {
  final uid = mint();
  block.raw[blockUidKey] = uid;
  return uid;
}

// ── 6 · `_groups` 写→读→还原（含未知顶层键保留） ───────────────────────

typedef _StoreFn = void Function(
  Map<String, Object?> raw,
  Map<String, BlockGroup> groups,
);

/// 命题：经**真实编解码**往返后组逐条还原，未知顶层键仍在，且空表 ⇒ 键被删除。
bool _groupsRoundTrip(_StoreFn store) {
  final raw = <String, Object?>{
    'directory': 'C:/some/where',
    'a_future_key': <String, Object?>{'nested': 7},
  };
  // 空表 ⇒ 该键根本不出现（不变式 2）。
  store(raw, const {});
  if (raw.containsKey(groupKey)) return false;

  final group = _sampleGroup()
    ..mode = GroupMode.link
    ..seam = 'a.webp|b.webp'
    ..translation = '整句'
    ..assignment['a.webp#m0'] = '片0';
  store(raw, {group.id: group});

  final project = TranslationProject.buildFrom(raw, File('x.json'));
  final text = TranslationProjectIo.encode(project);
  final back = TranslationProjectIo.parse(text, File('x.json')).raw;
  final read = readGroups(back);
  final restored = read[group.id];
  if (restored == null) return false;
  if (restored.mode != GroupMode.link ||
      restored.seam != 'a.webp|b.webp' ||
      restored.members.length != 3 ||
      restored.assignment['a.webp#m0'] != '片0') {
    return false;
  }
  return back['a_future_key'] != null;
}

/// 故障实现：重建整个工程，只留 `_groups`（未知键被抹）。
void _faultyGroupStore(
  Map<String, Object?> raw,
  Map<String, BlockGroup> groups,
) {
  raw
    ..clear()
    ..[groupKey] = <String, Object?>{
      for (final entry in groups.entries) entry.key: entry.value.toRaw(),
    };
}

// ── 7 · 组合顺序 = 成员顺序 ─────────────────────────────────────────────

typedef _ConcatFn = String Function(List<String> sources);

/// 命题：拼接严格按传入（= 成员）顺序，不倒序、不重排。
bool _concatOrderIsMemberOrder(_ConcatFn fn) {
  return fn(const ['one', 'two', 'three']) == 'one\ntwo\nthree';
}

/// 故障实现：倒序拼接。
String _faultyConcatReverse(List<String> sources) =>
    concatMemberSources(sources.reversed.toList());

// ── 8 · 组合不改成员的原文 ──────────────────────────────────────────────

typedef _ConcatBlocksFn = String Function(List<TextBlock> blocks);

/// 命题：跑完组合，成员的 JSON **一个字节都没变**。
bool _concatNeverMutates(_ConcatBlocksFn fn) {
  final blocks = [_block('one', top: 10), _block('two', top: 60)];
  final before = [for (final b in blocks) deepCopyJsonMap(b.raw)];
  fn(blocks);
  return jsonEquals(before[0], blocks[0].raw) &&
      jsonEquals(before[1], blocks[1].raw);
}

/// 故障实现：把组合结果**写回**了成员的译文（顺手改了源数据）。
String _faultyConcatMutating(List<TextBlock> blocks) {
  final combined = concatMemberSources([for (final b in blocks) b.sourceText]);
  for (final block in blocks) {
    block.translation = combined;
  }
  return combined;
}

// ── 9 · 倒装：非顺序映射被接受 ─────────────────────────────────────────

typedef _ValidateFn = List<GroupMemberRef> Function(
  BlockGroup group,
  Map<String, String> assignment,
);

/// 命题：映射允许**乱序**（第 1 段可指派给第 2 个成员）—— 分配是
/// `memberKey -> 片段`，谁拿哪段由人决定。
bool _allowsNonMonotonic(_ValidateFn validate) {
  final group = _sampleGroup();
  final assignment = <String, String>{
    'a.webp#m0': 'seg3',
    'a.webp#m1': 'seg1',
    'a.webp#m2': 'seg2',
  };
  return validate(group, assignment).isEmpty;
}

/// 故障实现：额外要求成员顺序与片段顺序一致（把倒装当错拒掉）。
List<GroupMemberRef> _faultyMonotonicValidate(
  BlockGroup group,
  Map<String, String> assignment,
) {
  final missing = unmappedMembers(group, assignment);
  if (missing.isNotEmpty) return missing;
  final values = [for (final m in group.members) assignment[m.key]!];
  for (var i = 1; i < values.length; i++) {
    if (values[i - 1].compareTo(values[i]) >= 0) return [group.members[i]];
  }
  return const [];
}

// ── 10 · 有成员没分配 ⇒ 不完整 ─────────────────────────────────────────

/// 命题：只要有成员没拿到片段（含"本块不出译文"的显式空串之外），分配不完整。
bool _rejectsUnmapped(_ValidateFn validate) {
  final group = _sampleGroup();
  final assignment = <String, String>{
    'a.webp#m0': 'x',
    'a.webp#m2': 'y',
  };
  final missing = validate(group, assignment);
  return missing.length == 1 && missing.first.uid == 'm1';
}

/// 故障实现：只看"有没有填过东西"，不逐个成员核对。
List<GroupMemberRef> _faultyCountValidate(
  BlockGroup group,
  Map<String, String> assignment,
) =>
    assignment.isEmpty ? group.members : const [];

// ── 11 · 一组只调用一次翻译 ────────────────────────────────────────────

typedef _TranslateFn = Future<GroupTranslationAttempt> Function(
  String? source,
  GroupTranslateCall translate,
);

/// 命题：一次组翻译**恰好调用 1 次**（入参是长度 1 的列表），不是成员数次。
Future<bool> _oneCallPerGroup(_TranslateFn run) async {
  var calls = 0;
  final attempt = await run('完整原文', (texts) async {
    calls++;
    return [for (final _ in texts) 'T'];
  });
  return calls == 1 && attempt.calls == 1;
}

/// 故障实现：每个成员各调一次（把一句被截断的话拆成互不知情的碎片）。
Future<GroupTranslationAttempt> _faultyPerMember(
  String? source,
  GroupTranslateCall translate,
) async {
  const members = ['a', 'b', 'c'];
  final results = <String>[];
  for (final member in members) {
    results.addAll(await translate([member]));
  }
  return GroupTranslationAttempt(calls: members.length, text: results.join());
}

// ── 12 · 无组原文 ⇒ 一次都不调用 ───────────────────────────────────────

/// 命题：组原文缺失/全空白时**不调用**翻译（不产生一次空翻译）。
Future<bool> _neverRunsWithoutSource(_TranslateFn run) async {
  var calls = 0;
  Future<List<String>> fake(List<String> texts) async {
    calls++;
    return ['x'];
  }

  final absent = await run(null, fake);
  final blank = await run('   ', fake);
  return calls == 0 &&
      absent.calls == 0 &&
      absent.reason == groupTranslateSourceMissing &&
      blank.calls == 0;
}

/// 故障实现：无视原文是否为空一律调用。
Future<GroupTranslationAttempt> _faultyAlwaysTranslate(
  String? source,
  GroupTranslateCall translate,
) async {
  final results = await translate([source ?? '']);
  return GroupTranslationAttempt(
    calls: 1,
    text: results.isNotEmpty ? results.first : '',
  );
}

// ── 13 · 分配写回可撤销 ────────────────────────────────────────────────

typedef _ApplyFn = List<ProjectEditCommand> Function(
  BlockGroup group,
  Map<String, String> assignment,
  TextBlock? Function(GroupMemberRef ref) blockOf,
);

/// 命题：分配经**命令**写回（不是直接改），undo 后成员译文逐字还原。
bool _assignmentIsUndoable(_ApplyFn apply) {
  final blocks = _sampleBlocks();
  final group = _sampleGroup();
  TextBlock? blockOf(GroupMemberRef ref) => findBlockByUid(blocks, ref.uid);
  final original = [for (final b in blocks) b.translation];

  final commands = apply(
    group,
    const {'a.webp#m0': 'A', 'a.webp#m1': 'B', 'a.webp#m2': 'C'},
    blockOf,
  );
  final history = EditHistory();
  for (final command in commands) {
    history.push(command);
  }
  final changed = blocks.every((b) => b.translation.isNotEmpty);
  while (history.canUndo) {
    history.undo();
  }
  final restored = [for (final b in blocks) b.translation];
  return changed && commands.length == 3 && _listEq(original, restored);
}

/// 故障实现：直接改成员译文，不返回命令 ⇒ 无法撤销。
List<ProjectEditCommand> _faultyApplyNoCommands(
  BlockGroup group,
  Map<String, String> assignment,
  TextBlock? Function(GroupMemberRef ref) blockOf,
) {
  for (final member in group.members) {
    final block = blockOf(member);
    final text = assignment[member.key];
    if (block == null || text == null) continue;
    block.translation = text;
  }
  return const [];
}

// ── 工具（故障路径抛异常视作判据失效） ─────────────────────────────────

Future<void> _probe(
  CheckSink check,
  String name,
  Future<bool> Function() green,
  Future<bool> Function() red,
  String Function() detail,
) async {
  bool g;
  bool r;
  var err = '';
  try {
    g = await green();
  } catch (e) {
    g = false;
    err = 'green threw: $e';
  }
  try {
    r = await red();
  } catch (e) {
    // 故障路径抛异常 ≠ 断言变红。
    r = true;
    err = '${err.isEmpty ? '' : '$err | '}red threw: $e';
  }
  check(
    name,
    g && !r,
    '${detail()} | 绿路径=${g ? 'true' : 'FALSE'} '
    '故障路径=${r ? '仍绿(装饰品)' : '变红'}${err.isEmpty ? '' : ' | $err'}',
  );
}

/// B-3 / B-4 的 13 条断言（由 `block-ops-check` 汇总）。
Future<void> runP12Checks(CheckSink check) async {
  // ── B-3 ────────────────────────────────────────────────────────────
  await _probe(
    check,
    'group.members_sort_by_page_then_y',
    () async => _sortMatches(sortMembersReadingOrder),
    () async => _sortMatches(_faultySort),
    () => '绿=页号优先 + 同页 y 升序（阅读序）/ 故障=只看 y ⇒ 跨页错位 ⇒ 变红',
  );

  await _probe(
    check,
    'group.mode_does_not_change_data',
    () async => _modeChangeKeepsData((g) => g..mode = GroupMode.link),
    () async => _modeChangeKeepsData(_faultyModeChange),
    () => '绿=nest→link 除 mode 外数据全同 / 故障=顺带清 source ⇒ 变红',
  );

  await _probe(
    check,
    'group.bbox_is_union_of_members',
    () async => _boundsIsUnion(groupBounds),
    () async => _boundsIsUnion(_faultyBounds),
    () => '绿=逐边 min/max 并集 / 故障=只用首个成员 ⇒ 变红',
  );

  await _probe(
    check,
    'group.member_ref_is_stable_after_unrelated_delete',
    () async => _refStableAfterDelete(findBlockByUid),
    () async => _refStableAfterDelete(_faultyResolveByIndex),
    () => '绿=_uid 仍指向原块 / 故障=按下标 ⇒ 删块后指错 ⇒ 变红',
  );

  await _probe(
    check,
    'group.uid_is_lazy',
    () async => _uidIsLazy(
      (block, mint) => ensureBlockUid(block, mint: mint),
    ),
    () async => _uidIsLazy(_faultyEagerEnsure),
    () => '绿=新块无 _uid·首次写入且幂等 / 故障=每次重铸 ⇒ 不幂等 ⇒ 变红',
  );

  await _probe(
    check,
    'group.groups_round_trip',
    () async => _groupsRoundTrip(writeGroups),
    () async => _groupsRoundTrip(_faultyGroupStore),
    () => '绿=组逐条还原 + 未知键仍在 + 空表删键 / '
        '故障=重建工程只留 _groups ⇒ 未知键被抹 ⇒ 变红',
  );

  // ── B-4 ────────────────────────────────────────────────────────────
  await _probe(
    check,
    'groupconcat.order_is_member_order',
    () async => _concatOrderIsMemberOrder(concatMemberSources),
    () async => _concatOrderIsMemberOrder(_faultyConcatReverse),
    () => '绿=按成员顺序拼接 / 故障=倒序 ⇒ 变红',
  );

  await _probe(
    check,
    'groupconcat.never_mutates_member_source',
    () async => _concatNeverMutates(
      (blocks) => concatMemberSources([for (final b in blocks) b.sourceText]),
    ),
    () async => _concatNeverMutates(_faultyConcatMutating),
    () => '绿=组合后成员 JSON 不变 / 故障=把结果写回成员 ⇒ 变红',
  );

  await _probe(
    check,
    'distribute.allows_non_monotonic_mapping',
    () async => _allowsNonMonotonic(unmappedMembers),
    () async => _allowsNonMonotonic(_faultyMonotonicValidate),
    () => '绿=倒装映射被接受 / 故障=要求顺序一致 ⇒ 拒掉倒装 ⇒ 变红',
  );

  await _probe(
    check,
    'distribute.rejects_unmapped_members',
    () async => _rejectsUnmapped(unmappedMembers),
    () async => _rejectsUnmapped(_faultyCountValidate),
    () => '绿=缺一个成员 ⇒ 报出该成员 / 故障=只看是否填过 ⇒ 报空 ⇒ 变红',
  );

  await _probe(
    check,
    'distribute.one_dispatcher_call_per_group',
    () async => _oneCallPerGroup(
      (source, translate) =>
          translateGroupOnce(source: source, translate: translate),
    ),
    () async => _oneCallPerGroup(_faultyPerMember),
    () => '绿=一组恰好 1 次调用 / 故障=按成员数次调用 ⇒ 变红',
  );

  await _probe(
    check,
    'distribute.never_runs_when_source_missing',
    () async => _neverRunsWithoutSource(
      (source, translate) =>
          translateGroupOnce(source: source, translate: translate),
    ),
    () async => _neverRunsWithoutSource(_faultyAlwaysTranslate),
    () => '绿=无原文 ⇒ 0 次调用 + 缘由码 / 故障=照常调用 ⇒ 变红',
  );

  await _probe(
    check,
    'distribute.is_undoable',
    () async => _assignmentIsUndoable(
      (group, assignment, blockOf) => applyGroupAssignment(
        group: group,
        assignment: assignment,
        blockOf: blockOf,
      ),
    ),
    () async => _assignmentIsUndoable(_faultyApplyNoCommands),
    () => '绿=经命令写回·undo 逐字还原 / 故障=直接改·无命令 ⇒ 不可撤销 ⇒ 变红',
  );
}
// B-3 · 「文字块小组」的纯逻辑（跨页拼接计划 §4-B3）。
//
// 一句话被分成几个气泡（可含跨页块）时，把它们组织成**一个组**，作为**翻译
// 单位**：组合原文 → 翻译一次 → 断句 → 分配回各成员。
//
// 🔴 本文件**不含 Flutter 依赖**（只 import `IntRect` 与 `TextBlock`），所以
// 组模型、成员排序、并集、惰性 `_uid`、工程级读写都能 headless 跑完。画布上的
// 建组交互与右栏组模式是 UI，另行处理。
//
// ## 两条不变式（与 L4 持久化层一致，见计划 §4.0.4）
//
// 1. **未知键原样保留**：这里只碰块级 `_uid` 与工程级 `_groups` 两个键，其余
//    一个不动 —— 工程 `raw` 是权威，"读→不改→写"仍是零字节 diff。
// 2. **不存在即 nil**：没有组时 `_groups` **根本不出现**（不是写一个空对象）。
//
// ## `_uid` 是**惰性**的（D9）
//
// 块没有稳定 id，全项目按页内下标寻址；组若用下标引用成员，"删一个块"就会让
// 整组指错块。解法是块加入组时才写一个可选键 `_uid`：**从不建组的工程，块里
// 不出现 `_uid`** ⇒ 零字节 diff 不受影响。
//
// ## 成员顺序 = **阅读序**（用户 2026-10-10 确认）
//
// 先按来源页在阅读序里的下标升序，同页按 **y 升序**（页顶的块在前，与
// `balloon_clustering._orderedLines` 的自上而下约定一致）。
// ⚠️ 计划书 §4-B3 字面写的是"同页 y 降序"，与页漫自上而下的阅读序相反；用户
// 已确认按阅读序（y 升序）—— 组合出的原句顺序全靠它，方向反了句子就反了。
library;

import 'dart:math' as math;

import '../image_translation/translation_types.dart' show IntRect;
import 'text_block.dart' show TextBlock, asObjectList, asObjectMap;

/// 块级的稳定 id 键（惰性写入）。
const String blockUidKey = '_uid';

/// 工程级的组定义键（下划线前缀，与 FT 其余可选键一致）。
const String groupKey = '_groups';

/// 组形态（D17：**同一数据结构**，只影响可视化，不影响数据）。
enum GroupMode {
  /// 大框套小框：气泡贴合/云朵状（距离近）。
  nest('nest'),

  /// 多块连线：成员间隔较远，画大框会圈进无关画面。
  link('link');

  const GroupMode(this.wire);

  /// 落盘/读回用的字符串。
  final String wire;

  /// 由落盘字符串还原；不认识的值返回 null。
  static GroupMode? fromWire(String? value) {
    if (value == null) return null;
    for (final mode in GroupMode.values) {
      if (mode.wire == value) return mode;
    }
    return null;
  }
}

/// 组内一个成员的引用：`(页, 块的 _uid)`。
///
/// 🔴 用 `_uid` 而非页内下标：删掉别的块不会让引用指错（D9 / `group.member_ref_is_stable_after_unrelated_delete`）。
class GroupMemberRef {
  const GroupMemberRef(this.page, this.uid);

  /// 页键（如 `0/1.webp`）。
  final String page;

  /// 该页内块的 `_uid`。
  final String uid;

  /// 落盘键：`"<page>#<uid>"`（`assignment` 的键与之一致）。
  String get key => '$page#$uid';

  /// 由 [key] 还原；形态不对返回 null。
  ///
  /// 在**最后一个** `#` 处切分：uid 由本模块铸造、不含 `#`，而页键理论上可以
  /// 含 `#` —— 从尾部切才能把页键原样留住。
  static GroupMemberRef? parse(String key) {
    final at = key.lastIndexOf('#');
    if (at <= 0 || at == key.length - 1) return null;
    return GroupMemberRef(key.substring(0, at), key.substring(at + 1));
  }

  @override
  bool operator ==(Object other) =>
      other is GroupMemberRef && other.page == page && other.uid == uid;

  @override
  int get hashCode => Object.hash(page, uid);

  @override
  String toString() => key;
}

/// 一个组：有序成员引用 + 组合原文/译文 + 逐成员分配。
///
/// 组边界框**不存**（成员矩形并集是派生值，见 [groupBounds]）；`nest` / `link`
/// 只改 [mode]，其余数据不动。
class BlockGroup {
  BlockGroup({
    required this.id,
    this.mode = GroupMode.nest,
    List<GroupMemberRef> members = const [],
    this.source,
    this.translation,
    Map<String, String> assignment = const {},
    this.seam,
  })  : members = [...members],
        assignment = {...assignment};

  /// 组 id（`_groups` 的键）。
  final String id;

  /// 只影响可视化。
  GroupMode mode;

  /// **有序**成员引用（顺序 = 组合原文的顺序；可人工拖动重排，为倒装句准备）。
  final List<GroupMemberRef> members;

  /// 组合后的**完整原文**（人工校对）。
  String? source;

  /// 完整译文（一次调用得到）。
  String? translation;

  /// 每个成员的译文片段，键 = `"<page>#<uid>"`。
  final Map<String, String> assignment;

  /// 所属缝（`"<上页>|<下页>"`）；非跨页组为 null。
  String? seam;

  /// 浅拷贝（成员/分配各自新表），供"改一份不动原件"的路径使用。
  BlockGroup copy() => BlockGroup(
        id: id,
        mode: mode,
        members: members,
        source: source,
        translation: translation,
        assignment: assignment,
        seam: seam,
      );

  /// 落盘形态。
  Map<String, Object?> toRaw() => <String, Object?>{
        'mode': mode.wire,
        'members': <Object?>[
          for (final member in members)
            <String, Object?>{'page': member.page, 'uid': member.uid},
        ],
        if (source != null) 'source': source,
        if (translation != null) 'translation': translation,
        if (assignment.isNotEmpty)
          'assignment': <String, Object?>{
            for (final entry in assignment.entries) entry.key: entry.value,
          },
        if (seam != null) 'seam': seam,
      };

  /// 由落盘数据还原；形态不对（非对象 / 无有效成员）返回 null —— 调用方据此
  /// **忽略**坏记录，而不是猜一个默认组把数据写坏。
  static BlockGroup? fromRaw(String id, Object? value) {
    final map = asObjectMap(value);
    if (map == null) return null;
    final members = <GroupMemberRef>[];
    for (final entry in asObjectList(map['members']) ?? const []) {
      final member = asObjectMap(entry);
      if (member == null) continue;
      final page = member['page']?.toString() ?? '';
      final uid = member['uid']?.toString() ?? '';
      if (page.isEmpty || uid.isEmpty) continue;
      members.add(GroupMemberRef(page, uid));
    }
    if (members.isEmpty) return null;
    final assignment = <String, String>{};
    final stored = asObjectMap(map['assignment']);
    if (stored != null) {
      for (final entry in stored.entries) {
        final text = entry.value;
        if (text is String) assignment[entry.key] = text;
      }
    }
    return BlockGroup(
      id: id,
      mode: GroupMode.fromWire(map['mode']?.toString()) ?? GroupMode.nest,
      members: members,
      source: map['source']?.toString(),
      translation: map['translation']?.toString(),
      assignment: assignment,
      seam: map['seam']?.toString(),
    );
  }
}

/// 读出工程 `raw` 里的组定义（坏记录被忽略）。
///
/// 返回的是**新的可变表**，改它不会影响 `raw`；要写回请用 [writeGroups]。
Map<String, BlockGroup> readGroups(Map<String, Object?> raw) {
  final result = <String, BlockGroup>{};
  final stored = asObjectMap(raw[groupKey]);
  if (stored == null) return result;
  for (final entry in stored.entries) {
    final group = BlockGroup.fromRaw(entry.key, entry.value);
    if (group != null) result[entry.key] = group;
  }
  return result;
}

/// 把 [groups] 写回工程 `raw`。
///
/// 空表 ⇒ **删除**该键（不变式 2：不存在即 nil，避免每个工程一保存就多出一段
/// 永不消失的 `"_groups": {}`）。
void writeGroups(Map<String, Object?> raw, Map<String, BlockGroup> groups) {
  if (groups.isEmpty) {
    raw.remove(groupKey);
    return;
  }
  raw[groupKey] = <String, Object?>{
    for (final entry in groups.entries) entry.key: entry.value.toRaw(),
  };
}

// ── 块级 `_uid`（惰性） ─────────────────────────────────────────────────

/// 读块的 `_uid`，没有则 null。
String? blockUid(TextBlock block) {
  final value = block.raw[blockUidKey];
  if (value is String && value.isNotEmpty) return value;
  return null;
}

/// 确保块有 `_uid` 并返回它 —— **仅在块加入组/跨页块时调用**。
///
/// 已经有就不再铸造（幂等）；从不建组的工程因此永远不长出这个键。
String ensureBlockUid(TextBlock block, {String Function() mint = mintBlockUid}) {
  final existing = blockUid(block);
  if (existing != null) return existing;
  final uid = mint();
  block.raw[blockUidKey] = uid;
  return uid;
}

/// 删掉块的 `_uid`（解组后回收）。返回是否确实删掉了。
bool clearBlockUid(TextBlock block) => block.raw.remove(blockUidKey) != null;

int _uidSeq = 0;

/// 铸造一个块 `_uid`。UI 路径用它；headless 断言注入**确定性**的铸造器。
String mintBlockUid() {
  _uidSeq++;
  final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  return 'b${_uidSeq}_$stamp';
}

int _groupIdSeq = 0;

/// 铸造一个组 id。
String mintGroupId() {
  _groupIdSeq++;
  final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  return 'g${_groupIdSeq}_$stamp';
}

/// 在一串块里按 `_uid` 找块；找不到返回 null。
TextBlock? findBlockByUid(Iterable<TextBlock> blocks, String uid) {
  for (final block in blocks) {
    if (blockUid(block) == uid) return block;
  }
  return null;
}

// ── 成员排序 / 并集 / 增删（L1 几何层，纯函数） ───────────────────────

/// 按**阅读序**排成员：先按来源页在阅读序里的下标升序，同页按 **y 升序**
/// （页顶的块在前），再依次按 x 升序、uid 定序。
///
/// [pageIndex] 给出页键在阅读序里的下标；[rectOf] 给出成员的块矩形（块已不在
/// 时返回 null，按 y=0 处理，排序仍然确定）。
///
/// 🔴 返回新表，不改入参。
List<GroupMemberRef> sortMembersReadingOrder(
  List<GroupMemberRef> members, {
  required int Function(String page) pageIndex,
  required IntRect? Function(GroupMemberRef ref) rectOf,
}) {
  final indexed = <(int, GroupMemberRef)>[
    for (var i = 0; i < members.length; i++) (i, members[i]),
  ];
  indexed.sort((a, b) {
    final pa = pageIndex(a.$2.page);
    final pb = pageIndex(b.$2.page);
    if (pa != pb) return pa.compareTo(pb);
    final ra = rectOf(a.$2);
    final rb = rectOf(b.$2);
    final ya = ra?.top ?? 0;
    final yb = rb?.top ?? 0;
    if (ya != yb) return ya.compareTo(yb);
    final xa = ra?.left ?? 0;
    final xb = rb?.left ?? 0;
    if (xa != xb) return xa.compareTo(xb);
    final byUid = a.$2.uid.compareTo(b.$2.uid);
    if (byUid != 0) return byUid;
    // List.sort 不保证稳定 ⇒ 用原始下标兜底，保证结果与输入顺序无关。
    return a.$1.compareTo(b.$1);
  });
  return [for (final entry in indexed) entry.$2];
}

/// 组边界框 = 成员矩形**并集**（派生，不落盘）；没有可用矩形时返回 null。
IntRect? groupBounds(
  List<GroupMemberRef> members, {
  required IntRect? Function(GroupMemberRef ref) rectOf,
}) {
  IntRect? bounds;
  for (final member in members) {
    final rect = rectOf(member);
    if (rect == null) continue;
    bounds = bounds == null
        ? IntRect(rect.left, rect.top, rect.right, rect.bottom)
        : IntRect(
            math.min(bounds.left, rect.left),
            math.min(bounds.top, rect.top),
            math.max(bounds.right, rect.right),
            math.max(bounds.bottom, rect.bottom),
          );
  }
  return bounds;
}

/// P31：把一组矩形从 [oldBounds] 坐标系**线性映射**到 [newBounds]（nest 组
/// 外框整体缩放的纯几何核心，无 Flutter 依赖，可 headless 正反断言）。
///
/// 每条边独立按轴缩放：
/// `new.left = newBounds.left + (r.left - oldBounds.left) * sx`（其余三边同），
/// `sx = newBounds.width / oldBounds.width`，`sy` 同理。语义后果（用户 2026-10-11
/// 选定）：**位置与尺寸同因子**，成员块随并集框整体等比缩放，不做文字重排；
/// 恰好压在并集边上的成员，缩放后仍定义同一条边（边各自四舍五入，结果并集
/// 即 [newBounds]，内部相邻块间可能有 ≤1px 的舍入缝，属预期）。
///
/// - 边手柄只动一条轴时另一轴因子恰为 1，公式天然兼容；
/// - [oldBounds] 退化（宽或高 ≤ 0）时无法定因子，返回入参的拷贝（不改入参）；
/// - 返回与 [rects] 等长的新表。
List<IntRect> scaleRectsToBounds({
  required IntRect oldBounds,
  required IntRect newBounds,
  required List<IntRect> rects,
}) {
  final oldW = oldBounds.right - oldBounds.left;
  final oldH = oldBounds.bottom - oldBounds.top;
  if (oldW <= 0 || oldH <= 0) return [for (final r in rects) IntRect(r.left, r.top, r.right, r.bottom)];
  final sx = (newBounds.right - newBounds.left) / oldW;
  final sy = (newBounds.bottom - newBounds.top) / oldH;
  int mapX(int x) => newBounds.left + ((x - oldBounds.left) * sx).round();
  int mapY(int y) => newBounds.top + ((y - oldBounds.top) * sy).round();
  return [
    for (final r in rects) IntRect(mapX(r.left), mapY(r.top), mapX(r.right), mapY(r.bottom)),
  ];
}

/// P32：按成员的**页跨度**建议组形态（建组落盘时自动给初值，用户仍可在组
/// 面板手切）：
///
/// - 成员全在**同一页**（大框套小框）→ [GroupMode.nest]；
/// - 恰好落在**相邻两页**（跨缝断句气泡，大框跨两页套小框）→ nest；
/// - 其余一切（≥3 个不同页的连线，或两页不相邻）→ [GroupMode.link]。
///
/// [pageIndexOf] 给出页键在阅读序里的下标。重复同页只计一次。
GroupMode suggestGroupMode({
  required List<GroupMemberRef> members,
  required int Function(String page) pageIndexOf,
}) {
  final pages = <int>{for (final m in members) pageIndexOf(m.page)}.toList()
    ..sort();
  final adjacentTwo =
      pages.length == 2 && pages[1] - pages[0] == 1;
  if (pages.length == 1 || adjacentTwo) return GroupMode.nest;
  return GroupMode.link;
}

/// 加成员；已存在（同页同 uid）则不动，返回 false。
bool addMember(BlockGroup group, GroupMemberRef ref) {
  if (group.members.contains(ref)) return false;
  group.members.add(ref);
  return true;
}

/// 移除成员，返回是否确实移除了。
bool removeMember(BlockGroup group, GroupMemberRef ref) =>
    group.members.remove(ref);

/// 块已不在的成员（孤儿引用）—— 解组 / 清理时用。
List<GroupMemberRef> orphanMembers(
  BlockGroup group, {
  required bool Function(GroupMemberRef ref) exists,
}) =>
    [
      for (final member in group.members)
        if (!exists(member)) member,
    ];
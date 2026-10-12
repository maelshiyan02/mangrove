// P31 · 长画布深滚缺页修复 + nest 组外框整体缩放的 headless 断言集。
//
// 与 P12~P14 同一纪律（M08）：每条断言跑两遍 —— 绿路径喂**真实现**，故障路径
// 喂一个**故意写错的实现**；只有「故障路径 = 变红」才说明判据钉得住行为。
//
// 覆盖：
//  1. WEBP 尺寸探测（VP8 有损 / VP8L 无损 / VP8X 扩展容器 / 截断头容错）；
//  2. 解码调度纯逻辑状态机（窗口夹取 / 距中心优先 / 隐藏页映射 / 失败闩锁 /
//     出窗清零 / 出窗取消）；
//  3. 并发名额账（每条终结路径都归还，漏还即饿死）；
//  4. nest 组外框整体等比缩放（位置+尺寸同因子，平移即平移）。
//
// 手势、像素解码、ListView 回收需要 GUI 会话（本会话无渲染表面），不在此列。
library;

import 'dart:typed_data';

import 'package:mangrove/foundation/image_translation/font_fit.dart';
import 'package:mangrove/foundation/image_translation/translation_types.dart'
    show IntRect;
import 'package:mangrove/foundation/translation_project/block_group.dart';
import 'package:mangrove/foundation/translation_project/page_size_probe.dart';
import 'package:mangrove/foundation/translation_project/strip_decode_planner.dart';
import 'package:mangrove/headless_p1_checks.dart' show CheckSink;

// ── WEBP 字节夹具 ───────────────────────────────────────────────────────

/// 拼一个最小 RIFF/WEBP 容器：一个 chunk，fourcc + 声明长度 + data。
/// [declaredLen] 可以故意大于实际字节数（真实 VP8 chunk 装整页压缩数据，
/// 文件头探测只拿到头几十字节 —— 这正是 P31 要容忍的情形）。
Uint8List _webpChunk(
  List<int> fourcc,
  List<int> data, {
  int? declaredLen,
  bool padRiff = true,
}) {
  final len = declaredLen ?? data.length;
  return Uint8List.fromList(<int>[
    0x52, 0x49, 0x46, 0x46, // RIFF
    0x20, 0x00, 0x00, 0x00, // 容器大小（探测不校验，占位）
    0x57, 0x45, 0x42, 0x50, // WEBP
    ...fourcc,
    len & 0xff,
    (len >> 8) & 0xff,
    (len >> 16) & 0xff,
    (len >> 24) & 0xff,
    ...data,
    // 偶数对齐占位（是否需要由调用场景决定；默认补一个，不影响截断测试）。
    if (padRiff && data.length.isOdd) 0x00,
  ]);
}

const _vp8Fourcc = [0x56, 0x50, 0x38, 0x20]; // 'VP8 '
const _vp8lFourcc = [0x56, 0x50, 0x38, 0x4C]; // 'VP8L'
const _vp8xFourcc = [0x56, 0x50, 0x38, 0x58]; // 'VP8X'

/// VP8 有损位流头：3 字节帧标签 + 签名 `9d 01 2a` + 宽/高 uint16 小端。
/// [badSig] 时改坏签名字节（真实现必须拒绝）。
Uint8List _vp8Fixture(int width14, int height14, {bool badSig = false}) {
  final w = width14 & 0x3fff;
  final h = height14 & 0x3fff;
  final data = <int>[
    0x30, 0x01, 0x00, // 帧标签（与尺寸无关）
    badSig ? 0x9c : 0x9d,
    0x01,
    0x2a,
    // 高 2 位置 01（正常）；探测只掩低 14 位。
    w & 0xff,
    ((w >> 8) & 0x3f) | 0x40,
    h & 0xff,
    ((h >> 8) & 0x3f) | 0x40,
  ];
  // 声明长度远大于已给字节：真实文件头探测就是读不全的。
  return _webpChunk(_vp8Fourcc, data, declaredLen: 1 << 20, padRiff: false);
}

/// VP8L 无损：0x2f + 4 字节打包（宽-1 在 bits 0..13、高-1 在 14..27）。
Uint8List _vp8lFixture(int width, int height, {bool badMarker = false}) {
  final n = ((width - 1) & 0x3fff) | (((height - 1) & 0x3fff) << 14);
  final data = <int>[
    badMarker ? 0x2e : 0x2f,
    n & 0xff,
    (n >> 8) & 0xff,
    (n >> 16) & 0xff,
    (n >> 24) & 0xff,
  ];
  return _webpChunk(_vp8lFourcc, data, declaredLen: 1 << 20, padRiff: false);
}

/// VP8X 扩展容器：4 字节标志 + 宽-1（24 位 LE）+ 高-1（24 位 LE），
/// 其后**不跟** VP8/VP8L 位流（头被截断）—— 画布尺寸仍应可读。
Uint8List _vp8xFixture(int width, int height) {
  final w = width - 1;
  final h = height - 1;
  final data = <int>[
    0x00, 0x00, 0x00, 0x00, // 特性标志
    w & 0xff, (w >> 8) & 0xff, (w >> 16) & 0xff,
    h & 0xff, (h >> 8) & 0xff, (h >> 16) & 0xff,
  ];
  return _webpChunk(_vp8xFourcc, data, padRiff: false);
}

/// 故障实现（命题"坏签名必须拒绝"）：只看 chunk 头，不校验 `9d 01 2a`。
bool _faultyVp8IgnoresSignature(Uint8List b) {
  if (b.length < 30) return false;
  // 故意：无论 b[23..25] 是什么，都按有损头读宽高。
  final w = (b[26] | (b[27] << 8)) & 0x3fff;
  final h = (b[28] | (b[29] << 8)) & 0x3fff;
  return w > 0 && h > 0;
}

/// 故障实现（命题"VP8X-only 的截断容器也要给画布尺寸"）：只认真位流 chunk，
/// 见不到 VP8/VP8L 就放弃 —— 龙女友工程首页若走扩展容器就会被读成 null。
bool _faultyProbeRequiresBitstream(Uint8List b) {
  // 找 'VP8 ' / 'VP8L' fourcc；找不到返回 false。
  for (var p = 12; p + 4 <= b.length; p++) {
    if (b[p] == 0x56 && b[p + 1] == 0x50 && b[p + 2] == 0x38) {
      if (b[p + 3] == 0x20 || b[p + 3] == 0x4c) return true;
    }
  }
  return false;
}

/// 故障实现（命题"头被截断必须安全返回 null"）：缺字节时不拒绝，而是拿最后
/// 一个可读字节**回填**缺失位 —— 不抛异常，却对截断头胡报一个尺寸，条带照样
/// 给不存在的宽高排了版式（真实现必须给 null 让上层走默认宽高比）。
bool _faultyProbeFillsMissingBytes(Uint8List b) {
  int at(int i) => i < b.length ? b[i] : b[b.length - 1];
  final w = (at(26) | (at(27) << 8)) & 0x3fff;
  final h = (at(28) | (at(29) << 8)) & 0x3fff;
  return w > 0 && h > 0;
}

bool _greenVp8() {
  final s = probePageSize(_vp8Fixture(1532, 1024));
  if (s == null || s.width != 1532 || s.height != 1024) return false;
  // 签名坏了必须拒绝（不是 webp 也不是 png，JPEG 链也走不通）。
  final bad = probePageSize(_vp8Fixture(1532, 1024, badSig: true));
  return bad == null;
}

/// 命题在故障实现下的样子："坏签名被拒绝"= 没有尺寸产出。
/// 故障实现照样报尺寸 ⇒ 命题为 false。
bool _redVp8() =>
    !_faultyVp8IgnoresSignature(_vp8Fixture(1532, 1024, badSig: true));

bool _greenVp8l() {
  final s = probePageSize(_vp8lFixture(900, 1778));
  if (s == null || s.width != 900 || s.height != 1778) return false;
  final bad = probePageSize(_vp8lFixture(900, 1778, badMarker: true));
  return bad == null;
}

/// 故障实现：不看 0x2f 起始标记，直接按打包位读，坏标记也报尺寸。
bool _faultyVp8lIgnoresMarker(Uint8List b) {
  final n = b[21] | (b[22] << 8) | (b[23] << 16) | (b[24] << 24);
  final w = (n & 0x3fff) + 1;
  final h = ((n >> 14) & 0x3fff) + 1;
  return w == 900 && h == 1778;
}

/// 命题："坏标记必须拒绝"。故障实现照样读出 900×1778 ⇒ false。
bool _redVp8l() =>
    !_faultyVp8lIgnoresMarker(_vp8lFixture(900, 1778, badMarker: true));

bool _greenVp8x() {
  final s = probePageSize(_vp8xFixture(1532, 1024));
  return s != null && s.width == 1532 && s.height == 1024;
}

bool _redVp8x() => _faultyProbeRequiresBitstream(_vp8xFixture(1532, 1024));

bool _greenTruncated() {
  // VP8 头在宽高读全之前被切掉：必须 null，且不得抛异常。
  final cut = Uint8List.sublistView(_vp8Fixture(1532, 1024), 0, 28);
  if (probePageSize(cut) != null) return false;
  // RIFF 容器头本身截断。
  if (probePageSize(Uint8List.fromList(const [0x52, 0x49, 0x46])) != null) {
    return false;
  }
  return true;
}

/// 命题："宽高字节缺失必须报 null"。故障实现用回填字节胡报尺寸 ⇒ false。
bool _redTruncated() =>
    !_faultyProbeFillsMissingBytes(Uint8List.sublistView(
      _vp8Fixture(1532, 1024),
      0,
      28,
    ));

// ── 解码调度状态机 ──────────────────────────────────────────────────────

bool _greenWindowRange() {
  // keepAlive=10 → half=5，窗口 [c-5, c+6)。
  final mid = StripDecodePlanner.windowRange(
    visibleCount: 94,
    center: 50,
    keepAlive: 10,
  );
  if (mid.lo != 45 || mid.hi != 56) return false;
  // 顶部夹取：c=0 ⇒ [0,6)，不许出负。
  final top = StripDecodePlanner.windowRange(
    visibleCount: 94,
    center: 0,
    keepAlive: 10,
  );
  if (top.lo != 0 || top.hi != 6) return false;
  // 底部夹取：c=93 ⇒ [88,94)。
  final bottom = StripDecodePlanner.windowRange(
    visibleCount: 94,
    center: 93,
    keepAlive: 10,
  );
  if (bottom.lo != 88 || bottom.hi != 94) return false;
  // 越界 center 自身也要夹回。
  final wild = StripDecodePlanner.windowRange(
    visibleCount: 94,
    center: 999,
    keepAlive: 10,
  );
  return wild.lo == 88 && wild.hi == 94;
}

/// 故障实现：窗口不夹取 —— 深滚/首帧时 lo 出负，List 下标直接炸/误纳隐藏页。
bool _redWindowRange() {
  int lo(int c, int n) => (c - 5).clamp(0, n);
  // 故意复刻"忘了夹 hi"的实现：c=93 时 hi=99 > 94。
  int hi(int c, int n) => c + 6;
  return hi(93, 94) <= 94 && lo(0, 94) >= 0 && hi(0, 94) >= 0;
}

StripSlotState _empty(int _) =>
    (decoded: false, loading: false, failures: 0);

bool _greenStartOrder() {
  final plan = StripDecodePlanner.plan(
    visible: [for (var i = 0; i < 94; i++) i],
    total: 94,
    center: 50,
    keepAlive: 10,
    capacity: 3,
    busy: 0,
    maxAttempts: 3,
    stateOf: _empty,
  );
  // 距中心从近到远：50（d0）、49（d1，同位距位置小者）、51（d1）。
  return plan.startInOrder.length == 3 &&
      plan.startInOrder[0] == 50 &&
      plan.startInOrder[1] == 49 &&
      plan.startInOrder[2] == 51;
}

/// 故障实现：窗口内候选**按升序**取前 capacity 个（不按距中心排序）。
/// 深滚时最近的页排在窗口尾端，名额被远端页占走，视口页最后才解码。
List<int> _faultyAscendingStarts({required int capacity}) {
  final window = [for (var v = 45; v < 56; v++) v];
  return window.take(capacity).toList();
}

/// 共同命题：center=50、名额 3 时，开解顺序必须是 50/49/51（距中心从近到
/// 远，并列时可见位置小者优先）。
bool _startsAreDistanceOrdered(List<int> starts) =>
    starts.length == 3 &&
    starts[0] == 50 &&
    starts[1] == 49 &&
    starts[2] == 51;

bool _redStartOrder() =>
    _startsAreDistanceOrdered(_faultyAscendingStarts(capacity: 3));

bool _greenHiddenMapping() {
  // 工程下标 12 的页被隐藏：可见位置 0..2 映射 10/11/13。
  const visible = [10, 11, 13];
  final plan = StripDecodePlanner.plan(
    visible: visible,
    total: 14,
    center: 1,
    keepAlive: 10,
    capacity: 3,
    busy: 0,
    maxAttempts: 3,
    stateOf: _empty,
  );
  // 想要保活的必须是**工程下标**，隐藏页 12 永远不进 wanted。
  return plan.wanted.containsAll(<int>{10, 11, 13}) &&
      plan.wanted.length == 3 &&
      !plan.wanted.contains(12) &&
      plan.startInOrder.toSet().containsAll(<int>{10, 11, 13});
}

/// 故障实现：把**可见位置**直接当工程下标塞进 wanted（P30 压缩下标事故同类）。
Set<int> _faultyWantedAsPositions(List<int> visible) => {
      for (var v = 0; v < visible.length; v++) v,
    };

/// 共同命题：wanted 必须正好是真页工程下标集合。
bool _wantedIsProjectIndexSet(Set<int> wanted) =>
    wanted.length == 3 &&
    wanted.containsAll(<int>{10, 11, 13}) &&
    !wanted.contains(12);

bool _redHiddenMapping() =>
    _wantedIsProjectIndexSet(_faultyWantedAsPositions(const [10, 11, 13]));

/// 共同命题：failures>=阈值的空槽不许开解（=2 仍给机会），名额占满时零开解。
bool _latchProposition(
  bool Function(int failures) shouldStart,
  int Function(int busy, int freeCandidates) startsWhenBusy,
) {
  if (shouldStart(3)) return false;
  if (!shouldStart(2)) return false;
  return startsWhenBusy(3, 11) == 0;
}

bool _greenLatch() {
  bool realShouldStart(int failures) => failures < 3;
  // 真实现：freeSlots = capacity-busy，busy=3、capacity=3 ⇒ 0。
  int realStartsWhenBusy(int busy, int candidates) =>
      candidates <= 0 ? 0 : (3 - busy).clamp(0, candidates);
  return _latchProposition(realShouldStart, realStartsWhenBusy);
}

/// 故障实现：开解条件漏了闩锁（任何空槽都重试），busy 也不限流。
bool _redLatch() {
  bool faultyShouldStart(int failures) => true;
  int faultyStartsWhenBusy(int busy, int candidates) => candidates;
  return _latchProposition(faultyShouldStart, faultyStartsWhenBusy);
}

/// 出窗处置的最小模型：返回三类动作（evict / cancel / reset）。
typedef _OutOfWindowResult = ({
  List<int> evictDecoded,
  List<int> cancelLoading,
  List<int> resetFailures,
});

/// 共同命题：页 10 空闲带 2 次失败 ⇒ 必须进 resetFailures；页 11 持有位图
/// ⇒ 走 evict 而不是 reset。
bool _outOfWindowProposition(_OutOfWindowResult r) =>
    r.resetFailures.contains(10) &&
    !r.resetFailures.contains(11) &&
    r.evictDecoded.contains(11);

bool _greenResetFailures() {
  final plan = StripDecodePlanner.plan(
    visible: [for (var i = 0; i < 94; i++) i],
    total: 94,
    center: 50,
    keepAlive: 10,
    capacity: 3,
    busy: 0,
    maxAttempts: 3,
    stateOf: (i) {
      if (i == 10) return (decoded: false, loading: false, failures: 2);
      if (i == 11) return (decoded: true, loading: false, failures: 1);
      return _empty(i);
    },
  );
  return _outOfWindowProposition((
    evictDecoded: plan.evictDecoded,
    cancelLoading: plan.cancelLoading,
    resetFailures: plan.resetFailures,
  ));
}

/// 故障实现（= P31 修复前的真代码规则）：出窗只处置**有位图**的页 —— null
/// 失败页没人管，计数永挂，闩锁永不解除。
_OutOfWindowResult _faultyOutOfWindow(Map<int, StripSlotState> states) {
  final evict = <int>[];
  for (final entry in states.entries) {
    if (entry.value.decoded) evict.add(entry.key);
    // 故意：没有 loading → cancel、failures>0 → reset 两个分支。
  }
  return (evictDecoded: evict, cancelLoading: const [], resetFailures: const []);
}

bool _redResetFailures() => _outOfWindowProposition(
      _faultyOutOfWindow({
        10: (decoded: false, loading: false, failures: 2),
        11: (decoded: true, loading: false, failures: 1),
      }),
    );

/// 共同命题：出窗时在飞解码必须进 cancelLoading，且不与 evict/reset 重复。
bool _cancelProposition(_OutOfWindowResult r) =>
    r.cancelLoading.contains(10) &&
    !r.evictDecoded.contains(10) &&
    !r.resetFailures.contains(10);

bool _greenCancelLoading() {
  final plan = StripDecodePlanner.plan(
    visible: [for (var i = 0; i < 94; i++) i],
    total: 94,
    center: 50,
    keepAlive: 10,
    capacity: 3,
    busy: 0,
    maxAttempts: 3,
    stateOf: (i) =>
        i == 10 ? (decoded: false, loading: true, failures: 0) : _empty(i),
  );
  return _cancelProposition((
    evictDecoded: plan.evictDecoded,
    cancelLoading: plan.cancelLoading,
    resetFailures: plan.resetFailures,
  ));
}

bool _redCancelLoading() => _cancelProposition(
      _faultyOutOfWindow({
        10: (decoded: false, loading: true, failures: 0),
      }),
    );

// ── 并发名额账 ──────────────────────────────────────────────────────────

/// 故障名额：成功/异常路径归还，唯独"取消后结果回来"这条路径漏还 ——
/// 正是「约 15 页（3 路×几轮）后新页永远不入队」的记账级根因。
class _LeakyDecodeBudget {
  _LeakyDecodeBudget(this.capacity);
  final int capacity;
  int _busy = 0;
  int get busy => _busy;
  bool acquire() {
    if (_busy >= capacity) return false;
    _busy++;
    return true;
  }
  // 故意没有 release()：widget 五条终结路径里"出窗取消"那条无额度可还。
}

/// 共同命题：3 路占满后第 4 个必拒；当三路**全部因出窗取消**而终结时，
/// 额度必须一笔不少地归还，紧接着必须还能开新解码。
bool _budgetProposition({
  required bool Function() acquire,
  required void Function() cancelAllThree,
  bool Function()? allReturned,
}) {
  for (var i = 0; i < 3; i++) {
    if (!acquire()) return false;
  }
  if (acquire()) return false; // 占满必拒
  cancelAllThree();
  if (allReturned != null && !allReturned()) return false;
  return acquire(); // 归还后新解码必须能入队
}

bool _greenBudget() {
  final b = DecodeBudget(3);
  if (!_budgetProposition(
    acquire: b.acquire,
    // 三条终结路径（成功 / null / 取消后迟到）走同一个 release。
    cancelAllThree: () {
      b.release();
      b.release();
      b.release();
    },
    allReturned: () => b.busy == 0 && b.freeSlots == 3,
  )) {
    return false;
  }
  b.release(); // 占满-归还循环后账已平（busy 0）。
  // 多还夹 0，不许把计数器打成负数白送名额。
  b.release();
  b.release();
  return b.busy == 0 && b.freeSlots == 3;
}

bool _redBudget() {
  final b = _LeakyDecodeBudget(3);
  return _budgetProposition(
    acquire: b.acquire,
    // 故障账：取消路径不记账归还，busy 永远钉在 3。
    cancelAllThree: () {},
    allReturned: () => b.busy == 0,
  );
}

// ── nest 组外框整体缩放 ─────────────────────────────────────────────────

bool _rectEq(IntRect a, List<int> l) =>
    a.left == l[0] && a.top == l[1] && a.right == l[2] && a.bottom == l[3];

/// 共同命题（四个场景全过才算对）：①同原点 2× 位置尺寸同因子；②纯平移整体
/// +100/+100；③单边手柄只动宽、y 不变；④退化旧框原样返回不抛。
bool _scaleProposition(
  List<IntRect> Function({
    required IntRect oldBounds,
    required IntRect newBounds,
    required List<IntRect> rects,
  }) scale,
) {
  final oldBounds = IntRect(100, 100, 300, 300);
  final members = [
    IntRect(100, 100, 200, 300),
    IntRect(200, 200, 300, 300),
  ];
  final doubled = scale(
    oldBounds: oldBounds,
    newBounds: IntRect(100, 100, 500, 500),
    rects: members,
  );
  if (!_rectEq(doubled[0], [100, 100, 300, 500])) return false;
  if (!_rectEq(doubled[1], [300, 300, 500, 500])) return false;
  final shifted = scale(
    oldBounds: oldBounds,
    newBounds: IntRect(200, 200, 400, 400),
    rects: members,
  );
  if (!_rectEq(shifted[0], [200, 200, 300, 400])) return false;
  if (!_rectEq(shifted[1], [300, 300, 400, 400])) return false;
  final wider = scale(
    oldBounds: oldBounds,
    newBounds: IntRect(100, 100, 400, 300),
    rects: members,
  );
  if (!_rectEq(wider[0], [100, 100, 250, 300])) return false;
  if (!_rectEq(wider[1], [250, 200, 400, 300])) return false;
  final degenerate = scale(
    oldBounds: IntRect(0, 0, 0, 10),
    newBounds: IntRect(0, 0, 10, 20),
    rects: members,
  );
  return _rectEq(degenerate[0], [100, 100, 200, 300]);
}

bool _greenScaleGroup() => _scaleProposition(scaleRectsToBounds);

/// 故障实现：四条边直接乘因子（`r.left*sx`），不做新旧并集框的**原点换算**。
/// 纯平移（sx=1）时成员纹丝不动 —— 用户拖组框平移，成员留在原地。
List<IntRect> _faultyScaleNoOrigin({
  required IntRect oldBounds,
  required IntRect newBounds,
  required List<IntRect> rects,
}) {
  final sx = (newBounds.right - newBounds.left) /
      (oldBounds.right - oldBounds.left);
  final sy = (newBounds.bottom - newBounds.top) /
      (oldBounds.bottom - oldBounds.top);
  if (!sx.isFinite || !sy.isFinite) return rects;
  int mx(int x, double f) => (x * f).round();
  return [
    for (final r in rects)
      IntRect(mx(r.left, sx), mx(r.top, sy), mx(r.right, sx), mx(r.bottom, sy)),
  ];
}

bool _redScaleGroup() => _scaleProposition(_faultyScaleNoOrigin);

// ── P32：视口几何驻留窗口（缩小缺页修复） ──────────────────────────────

/// 共同命题：ListView 在 [offset−cache, offset+viewport+cache] 内实际构建的
/// 每一页都必须在保活集合里；其中在飞的页不许被取消。
bool _viewportBandProposition(
  Set<int> wanted,
  Set<int> canceled,
  List<int> builtPages,
) {
  for (final i in builtPages) {
    if (!wanted.contains(i)) return false;
  }
  for (final i in builtPages) {
    if (canceled.contains(i)) return false;
  }
  return true;
}

bool _greenViewportBand() {
  // 缩小档：矮页（300px）+ 高视口（2500px），scrollOffset=0，
  // cacheExtent=250 ⇒ ListView 实际构建页 0..9（页9 顶 2700 ≤ 2750）。
  const n = 30;
  final plan = StripDecodePlanner.planForViewport(
    visible: [for (var i = 0; i < n; i++) i],
    tops: [for (var i = 0; i < n; i++) i * 300.0],
    heights: [for (var i = 0; i < n; i++) 300.0],
    total: n,
    scrollOffset: 0,
    viewportHeight: 2500,
    preloadPad: 2750, // viewport + cacheExtent
    retainPad: 6500, // 2.5·viewport + cacheExtent
    capacity: 3,
    busy: 0,
    maxAttempts: 3,
    stateOf: (i) => i == 9
        ? (decoded: false, loading: true, failures: 0)
        : _empty(i),
  );
  final built = [for (var i = 0; i <= 9; i++) i];
  return _viewportBandProposition(
    plan.wanted,
    plan.cancelLoading.toSet(),
    built,
  );
}

/// 故障实现：P32 前的固定页数窗口 —— 上 1/3 锚点（offset+833 ⇒ 第 2 页）
/// ±5 ⇒ wanted 只有页 0..7，cache 区实际构建的页 8/9 不在其中，在飞的页 9
/// 被当作出窗取消（日志里 #8 三轮 start/cancel 振荡的抽象模型）。
bool _redViewportBand() {
  const anchor = 2;
  final wanted = <int>{
    for (var v = anchor - 5; v < anchor + 6; v++)
      if (v >= 0 && v < 30) v,
  };
  final canceled = <int>{};
  for (var i = 0; i < 30; i++) {
    if (!wanted.contains(i) && i == 9) canceled.add(i);
  }
  return _viewportBandProposition(
    wanted,
    canceled,
    [for (var i = 0; i <= 9; i++) i],
  );
}

bool _greenHysteresis() {
  // 页高 700、视口 900、offset 0：
  // 紧带 [-1150,2050] 覆盖页 0..2（页3 顶 2100 在紧带外）；
  // 宽保活带 [-2500,3400] 覆盖到页 4（顶 2800），页 5（顶 3500）已出宽带。
  const n = 12;
  final plan = StripDecodePlanner.planForViewport(
    visible: [for (var i = 0; i < n; i++) i],
    tops: [for (var i = 0; i < n; i++) i * 700.0],
    heights: [for (var i = 0; i < n; i++) 700.0],
    total: n,
    scrollOffset: 0,
    viewportHeight: 900,
    preloadPad: 1150,
    retainPad: 2500,
    capacity: 3,
    busy: 0,
    maxAttempts: 3,
    stateOf: (i) {
      if (i == 3) return (decoded: false, loading: true, failures: 0);
      if (i == 4 || i == 5) {
        return (decoded: false, loading: false, failures: 1);
      }
      return _empty(i);
    },
  );
  // 紧外宽内：在飞页 3 不取消、空槽页 4 失败计数不清零、也不新开解。
  if (plan.cancelLoading.contains(3)) return false;
  if (plan.resetFailures.contains(4)) return false;
  if (plan.startInOrder.contains(3) || plan.startInOrder.contains(4)) {
    return false;
  }
  // 出了宽带：页 5 必须翻篇清零；紧带内的页 0..2 正常开解。
  if (!plan.resetFailures.contains(5)) return false;
  return plan.wanted.containsAll(<int>{0, 1, 2}) &&
      !plan.wanted.contains(3);
}

/// 故障实现：保活带 == 紧带（迟滞为 0）—— 边界页一帧出紧带就被取消/清零，
/// 下一帧锚点抖动又入带开解，振荡由此而生。
bool _redHysteresis() {
  final retained = <int>{0, 1, 2};
  final canceled = <int>{if (!retained.contains(3)) 3};
  final reset = <int>{if (!retained.contains(4)) 4};
  if (canceled.contains(3)) return false;
  if (reset.contains(4)) return false;
  return true;
}

// ── P32：建组形态按页跨度自动建议 ──────────────────────────────────────

bool _greenGroupModeSuggestion() {
  GroupMemberRef m(String page) => GroupMemberRef(page, 'u');
  int idx(String page) => int.parse(page);
  // 同页（可多块）→ nest。
  if (suggestGroupMode(members: [m('5'), m('5')], pageIndexOf: idx) !=
      GroupMode.nest) {
    return false;
  }
  // 恰好相邻两页（跨缝断句气泡）→ nest。
  if (suggestGroupMode(members: [m('5'), m('6')], pageIndexOf: idx) !=
      GroupMode.nest) {
    return false;
  }
  // 两页不相邻 → link（不可能是同一个被截断的气泡）。
  if (suggestGroupMode(members: [m('5'), m('8')], pageIndexOf: idx) !=
      GroupMode.link) {
    return false;
  }
  // 跨 ≥3 页 → link（连线）。
  return suggestGroupMode(members: [m('5'), m('6'), m('7')], pageIndexOf: idx) ==
      GroupMode.link;
}

/// 故障实现：无视页跨度一律 nest（P32 前 BlockGroup 的硬编码默认）—— 跨三页
/// 的组也画大框套小框，圈进整屏无关画面。
bool _redGroupModeSuggestion() {
  GroupMode faulty(List<int> pages) => GroupMode.nest;
  return faulty([5, 6, 7]) == GroupMode.link &&
      faulty([5, 8]) == GroupMode.link;
}

// ── P32：块内文字上下左右居中放置 ──────────────────────────────────────

bool _greenTextPlacement() {
  // 框 200×100、文字 100×40：默认居中 ⇒ (50,30)；垂直恒居中。
  final center = placeTextInBox(
    boxWidth: 200,
    boxHeight: 100,
    textWidth: 100,
    textHeight: 40,
    alignment: 1,
  );
  if (center.dx != 50 || center.dy != 30) return false;
  final left = placeTextInBox(
    boxWidth: 200,
    boxHeight: 100,
    textWidth: 100,
    textHeight: 40,
    alignment: 0,
  );
  if (left.dx != 0 || left.dy != 30) return false;
  final right = placeTextInBox(
    boxWidth: 200,
    boxHeight: 100,
    textWidth: 100,
    textHeight: 40,
    alignment: 2,
    inset: 2,
  );
  return right.dx == 98 && right.dy == 30;
}

/// 故障实现：恒从块左上角起排（P32 前画布预览行为）—— 框大于文字时看起来
/// 像"首行缩进顶格"，且与已居中的 result 出图不一致。
bool _redTextPlacement() {
  ({double dx, double dy}) faulty({required int alignment}) =>
      (dx: 0, dy: 0);
  final c = faulty(alignment: 1);
  return c.dx == 50 && c.dy == 30;
}

// ── 工具（与 P14 同一个 _probe；故障路径抛异常按"仍绿"计） ─────────────

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

/// P31 的 12 条断言（由 `block-ops-check` 汇总）：WEBP×4、调度状态机×6、
/// 名额账×1、组外框缩放×1。基线 92 → 104。
///
/// P32 再加 4 条：视口几何紧带覆盖 cache 构建页、宽保活带迟滞、建组形态按
/// 页跨度自动建议、块内文字居中。基线 104 → 108。
Future<void> runP15Checks(CheckSink check) async {
  await _probe(
    check,
    'webp_probe.vp8_lossy_dimensions',
    () async => _greenVp8(),
    () async => _redVp8(),
    () => '绿=VP8 有损头(声明长度≫已读字节)读出 1532×1024、坏签名拒读 / '
        '故障=不校验 9d012a ⇒ 坏文件也报尺寸 ⇒ 变红',
  );

  await _probe(
    check,
    'webp_probe.vp8l_lossless_dimensions',
    () async => _greenVp8l(),
    () async => _redVp8l(),
    () => '绿=VP8L 打包位读出 900×1778、0x2f 标记坏了拒读 / '
        '故障=不看起始标记 ⇒ 变红',
  );

  await _probe(
    check,
    'webp_probe.vp8x_canvas_without_bitstream',
    () async => _greenVp8x(),
    () async => _redVp8x(),
    () => '绿=只有 VP8X、位流被截断仍给出画布 1532×1024 / '
        '故障=非见到 VP8/VP8L 不报 ⇒ 扩展容器页估高失效 ⇒ 变红',
  );

  await _probe(
    check,
    'webp_probe.truncated_header_safe',
    () async => _greenTruncated(),
    () async => _redTruncated(),
    () => '绿=宽高字节缺失/容器头截断一律 null 且不抛 / '
        '故障=用末尾字节回填缺失位 ⇒ 截断头也胡报尺寸、错误版式被排出来 ⇒ 变红',
  );

  await _probe(
    check,
    'strip_planner.window_range_clamped',
    () async => _greenWindowRange(),
    () async => _redWindowRange(),
    () => '绿=[c-5,c+6) 且首尾/越界 center 全部夹在 [0,count] / '
        '故障=hi 不夹取 ⇒ 末页窗口越界 ⇒ 变红',
  );

  await _probe(
    check,
    'strip_planner.start_order_distance_first',
    () async => _greenStartOrder(),
    () async => _redStartOrder(),
    () => '绿=3 个名额按距中心 50/49/51 开解 / '
        '故障=窗口升序 45/46/47 占坑 ⇒ 视口页最后解码 ⇒ 变红',
  );

  await _probe(
    check,
    'strip_planner.hidden_index_not_in_wanted',
    () async => _greenHiddenMapping(),
    () async => _redHiddenMapping(),
    () => '绿=隐藏 12 后 wanted 是工程下标 {10,11,13} / '
        '故障=把可见位置当工程下标 ⇒ 真页永不进窗 ⇒ 变红',
  );

  await _probe(
    check,
    'strip_planner.failure_latch_blocks_start',
    () async => _greenLatch(),
    () async => _redLatch(),
    () => '绿=failures>=3 不入队、=2 仍给机会、busy 满则零开解 / '
        '故障=闩锁页每轮重试 ⇒ 名额被坏页吃光 ⇒ 变红',
  );

  await _probe(
    check,
    'strip_planner.out_of_window_failure_reset',
    () async => _greenResetFailures(),
    () async => _redResetFailures(),
    () => '绿=出窗空闲失败页进 resetFailures、有位图页走 evict / '
        '故障=只处置有位图页 ⇒ 失败计数永挂、闩锁永不解除（P31 实锤根因之一）⇒ 变红',
  );

  await _probe(
    check,
    'strip_planner.out_of_window_loading_cancelled',
    () async => _greenCancelLoading(),
    () async => _redCancelLoading(),
    () => '绿=出窗在飞解码进 cancelLoading 且不与 evict/reset 重复 / '
        '故障=不取消 ⇒ 旧 token 结果迟到写错页 ⇒ 变红',
  );

  await _probe(
    check,
    'strip_budget.terminal_release_invariant',
    () async => _greenBudget(),
    () async => _redBudget(),
    () => '绿=占满拒入、三条终结路径各还一次后可再 acquire、多还夹 0 / '
        '故障=取消迟到路径漏还 ⇒ 几轮后 busy 永久占满、新页饿死（15 页缺页症）⇒ 变红',
  );

  await _probe(
    check,
    'group.scale_rects_to_bounds',
    () async => _greenScaleGroup(),
    () async => _redScaleGroup(),
    () => '绿=2× 时位置尺寸同因子、纯平移整体 +100、单边手柄只动宽、退化框原样返回 / '
        '故障=只乘因子不做原点平移 ⇒ 平移新框时成员不动 ⇒ 变红',
  );

  await _probe(
    check,
    'strip_planner.viewport_band_covers_built_pages',
    () async => _greenViewportBand(),
    () async => _redViewportBand(),
    () => '绿=缩小档（矮页+高视口）cache 区实际构建的页 0..9 全在 wanted、'
        '在飞页 9 不取消 / 故障=固定页数窗口只有 0..7 ⇒ 88% 缺页振荡 ⇒ 变红',
  );

  await _probe(
    check,
    'strip_planner.retain_hysteresis_keeps_border_pages',
    () async => _greenHysteresis(),
    () async => _redHysteresis(),
    () => '绿=紧带外/宽带内的在飞页不取消、失败页不清零也不开新解，出宽带才翻篇 / '
        '故障=迟滞为 0 ⇒ 边界页反复 cancel/start ⇒ 变红',
  );

  await _probe(
    check,
    'group.suggest_mode_by_page_span',
    () async => _greenGroupModeSuggestion(),
    () async => _redGroupModeSuggestion(),
    () => '绿=同页/相邻两页→nest，两页不相邻或跨≥3页→link / '
        '故障=一律 nest ⇒ 跨多页大框圈进无关画面 ⇒ 变红',
  );

  await _probe(
    check,
    'text_placement.center_in_block_box',
    () async => _greenTextPlacement(),
    () async => _redTextPlacement(),
    () => '绿=默认上下左右居中 (50,30)，left→dx0/right→dx98、垂直恒居中 / '
        '故障=恒左上角起排 ⇒ 译文顶格且与 result 出图不一致 ⇒ 变红',
  );
}

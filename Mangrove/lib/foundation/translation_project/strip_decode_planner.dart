// P31 · 长画布解码调度的纯逻辑状态机（无 Flutter 依赖，可 headless 断言）。
//
// 为什么要从 widget 里抽出来
// --------------------------
// `StudioScrollCanvasState._loadAround` 曾经把三件事揉在一帧的命令式循环里：
//   ① 围绕视口算"驻留窗口"；
//   ② 在「成功 / 失败 null / 抛异常 / token 过期 / 离窗取消」五条终结路径上
//      维护 3 路并发名额；
//   ③ 失败计数、永久闩锁与"离开窗口翻篇"。
// 用户实测「滚到约 15 页后永久缺页、回顶重载才活」：这类 bug 不靠渲染表面、
// 只靠状态推演就能钉死 —— 但前提是规则是**纯函数**。于是这里只接收每页的
// 状态快照、返回一次调度的全部动作，widget 只负责执行动作；同一份规则在
// headless（`block-ops-check` 的 P15 组）里被正反断言。
//
// 🔴 本文件**不 import Flutter / dart:ui**，保持与 `strip_geometry.dart` 同级的
// 可测性；改窗口/名额/闩锁规则必须同步 P15 断言（含故障路径）。
library;

/// 一个解码槽位在调度瞬间的状态快照（工程下标 → 快照）。
typedef StripSlotState = ({bool decoded, bool loading, int failures});

/// 一次窗口调度产生的全部动作（widget 按序执行）。
///
/// 四个列表两两不交：
/// - [wanted]：本次窗口要保活的**工程下标**集合（解码的/在飞的/空的都算）；
/// - [startInOrder]：名额允许、应立刻开解的工程下标，**已按距窗口中心从近到
///   远排好**，深滚/快滚时视口旁的页先开解，不再被升序窗口的远端页占坑；
/// - [evictDecoded]：出窗且持有位图 —— 释放位图（token 一并作废）；
/// - [cancelLoading]：出窗但解码仍在飞 —— 作废 token、放下 loading，
///   结果回来时自行丢弃，名额在终结回调里归还；
/// - [resetFailures]：出窗且空闲（无位图、不在飞）但带着失败计数 —— 翻篇
///   清零，滚回来时重新计数。🔴 P31 实锤缺陷：旧逻辑只对"有位图"的出窗页
///   调 dispose（清零在其中），失败成 null 的页出窗后计数永远挂着，三连失败
///   的闩锁从此再无自动解除路径。
class StripDecodePlan {
  const StripDecodePlan({
    required this.wanted,
    required this.startInOrder,
    required this.evictDecoded,
    required this.cancelLoading,
    required this.resetFailures,
  });

  final Set<int> wanted;
  final List<int> startInOrder;
  final List<int> evictDecoded;
  final List<int> cancelLoading;
  final List<int> resetFailures;
}

/// 驻留窗口 [lo, hi)（对**可见位置**，已夹取）与并发名额规则。
class StripDecodePlanner {
  /// 窗口半宽取 `keepAlive ~/ 2`，窗口为 `[center-half, center+half+1)`
  /// （keepAlive=10 时中心两侧各 5，含中心至多 11 页）。与 P28 以来的
  /// widget 行为逐位一致 —— 改动它就是改动内存驻留策略，必须连坐测试。
  static ({int lo, int hi}) windowRange({
    required int visibleCount,
    required int center,
    required int keepAlive,
  }) {
    if (visibleCount <= 0) return (lo: 0, hi: 0);
    final c = center.clamp(0, visibleCount - 1);
    final half = keepAlive ~/ 2;
    return (
      lo: (c - half).clamp(0, visibleCount),
      hi: (c + half + 1).clamp(0, visibleCount),
    );
  }

  /// 计算一次调度。
  ///
  /// - [visible]：**可见位置 → 工程下标**的映射（隐藏页已被剔除）；
  /// - [total]：工程总页数（出窗扫描要覆盖所有工程下标，含隐藏页）；
  /// - [busy]：当前在飞解码数（由 [DecodeBudget] 记账，widget 不自己加减）；
  /// - [capacity]：并发上限；[maxAttempts]：闩锁阈值。
  static StripDecodePlan plan({
    required List<int> visible,
    required int total,
    required int center,
    required int keepAlive,
    required int capacity,
    required int busy,
    required int maxAttempts,
    required StripSlotState Function(int projectIndex) stateOf,
  }) {
    final range =
        windowRange(visibleCount: visible.length, center: center, keepAlive: keepAlive);
    final wanted = <int>{
      for (var v = range.lo; v < range.hi; v++) visible[v],
    };

    // 开解候选：窗口内、无位图、不在飞、未闩锁；按距中心从近到远（并列时
    // 可见位置小者优先，保证顺序确定），只取剩余名额数。
    final freeSlots = capacity - busy;
    final candidates = <({int pos, int projectIndex})>[];
    for (var v = range.lo; v < range.hi; v++) {
      final idx = visible[v];
      final s = stateOf(idx);
      if (s.decoded || s.loading || s.failures >= maxAttempts) continue;
      candidates.add((pos: v, projectIndex: idx));
    }
    candidates.sort((a, b) {
      final da = (a.pos - center).abs();
      final db = (b.pos - center).abs();
      if (da != db) return da - db;
      return a.pos - b.pos;
    });
    final startInOrder = <int>[
      for (final c in candidates.take(freeSlots < 0 ? 0 : freeSlots)) c.projectIndex,
    ];

    final evictDecoded = <int>[];
    final cancelLoading = <int>[];
    final resetFailures = <int>[];
    for (var i = 0; i < total; i++) {
      if (wanted.contains(i)) continue;
      final s = stateOf(i);
      if (s.decoded) {
        evictDecoded.add(i);
      } else if (s.loading) {
        cancelLoading.add(i);
      } else if (s.failures > 0) {
        resetFailures.add(i);
      }
    }
    return StripDecodePlan(
      wanted: wanted,
      startInOrder: startInOrder,
      evictDecoded: evictDecoded,
      cancelLoading: cancelLoading,
      resetFailures: resetFailures,
    );
  }

  /// P32 · **视口几何**驱动的调度（[plan] 的固定页数窗口的替代版）。
  ///
  /// 为什么还要一个几何版：P31 的 `[center-half, center+half+1)` 按**页数**
  /// 开窗，而 ListView 实际构建范围由「视口 + cacheExtent」的**像素**决定。
  /// Ctrl+滚轮缩小后每页变矮，一屏 + cache 构建出的页越过窗口下沿：该页
  /// 一帧被出窗取消、下一帧锚点抖动又入窗开解，反复 cancel 后滞留窗外永久
  /// 缺图（用户实测缩小到 ~88% 必现）。几何版让两条边界按同一把尺（像素）
  /// 计算，并引入迟滞：
  ///
  /// - **紧带** `[scrollOffset-preloadPad, scrollOffset+viewport+preloadPad]`：
  ///   与紧带相交的页 = 本次 `wanted`（= ListView 视口/cache 实际会构建的
  ///   超集，保证"被构建的页必被保活"），也是开解候选；
  /// - **宽保活带**（边距 [retainPad] ≥ [preloadPad]）：与宽带相交的页**只
  ///   保活、不开新解** —— 边界抖动时在飞解码不会被立刻 cancel，彻底消除
  ///   "刚入队就取消"的振荡；真正出窗（离开宽带）才 evict/cancel/reset。
  ///
  /// 距离排序改为「页中点到**视口中点**的像素距离」，与固定页数版语义一致。
  /// [tops]/[heights] 是与 [visible] 对齐的每可见页**内容顶 y / 内容高**
  /// （已含布局间隙，widget 按 ListView 的实际缝几何构造）。
  static StripDecodePlan planForViewport({
    required List<int> visible,
    required List<double> tops,
    required List<double> heights,
    required int total,
    required double scrollOffset,
    required double viewportHeight,
    required double preloadPad,
    required double retainPad,
    required int capacity,
    required int busy,
    required int maxAttempts,
    required StripSlotState Function(int projectIndex) stateOf,
  }) {
    final tightLo = scrollOffset - preloadPad;
    final tightHi = scrollOffset + viewportHeight + preloadPad;
    final retainLo = scrollOffset - retainPad;
    final retainHi = scrollOffset + viewportHeight + retainPad;
    final bandMid = scrollOffset + viewportHeight / 2;

    final wanted = <int>{};
    final retained = <int>{};
    final distToBand = <int, double>{};
    for (var v = 0; v < visible.length; v++) {
      final idx = visible[v];
      final top = tops[v];
      final bottom = top + heights[v];
      // 标准矩形相交：页跨在带边界上也算在内（边界页正是振荡来源）。
      if (bottom >= retainLo && top <= retainHi) retained.add(idx);
      if (bottom >= tightLo && top <= tightHi) {
        wanted.add(idx);
        distToBand[idx] = ((top + bottom) / 2 - bandMid).abs();
      }
    }

    final freeSlots = capacity - busy;
    // 按像素距离排序的开解顺序；遇到已解/在飞/闩锁的页只是跳过，不占名额。
    final wantedList = wanted.toList()
      ..sort((a, b) {
        final da = distToBand[a]!;
        final db = distToBand[b]!;
        if (da != db) return da < db ? -1 : 1;
        return a - b;
      });
    final startInOrder = <int>[];
    for (final idx in wantedList) {
      if (startInOrder.length >= freeSlots) break;
      final s = stateOf(idx);
      if (s.decoded || s.loading || s.failures >= maxAttempts) continue;
      startInOrder.add(idx);
    }

    final evictDecoded = <int>[];
    final cancelLoading = <int>[];
    final resetFailures = <int>[];
    for (var i = 0; i < total; i++) {
      if (retained.contains(i)) continue;
      final s = stateOf(i);
      if (s.decoded) {
        evictDecoded.add(i);
      } else if (s.loading) {
        cancelLoading.add(i);
      } else if (s.failures > 0) {
        resetFailures.add(i);
      }
    }
    return StripDecodePlan(
      wanted: wanted,
      startInOrder: startInOrder,
      evictDecoded: evictDecoded,
      cancelLoading: cancelLoading,
      resetFailures: resetFailures,
    );
  }
}

/// 解码并发名额的唯一记账处。
///
/// 🔴 规则只有两条：开解前必须 [acquire] 成功；**每一次**解码无论走哪条终结
/// 路径（成功 / null / 抛异常 / token 过期丢弃 / 出窗取消后结果回来）都必须
/// 恰好 [release] 一次。少还一次 = 名额永久泄漏，3 路占满后全工程再也不会有
/// 新页入队 —— 与「固定页数后永久缺页」同症。P15 有故障实现（漏还）的红灯
/// 断言钉着这条不变量。
class DecodeBudget {
  DecodeBudget(this.capacity) : assert(capacity > 0, 'capacity must be positive');

  final int capacity;
  int _busy = 0;

  int get busy => _busy;
  int get freeSlots => capacity - _busy > 0 ? capacity - _busy : 0;
  bool get hasFreeSlot => _busy < capacity;

  /// 占一个名额；已满则返回 false（调用方放弃本次开解，等下一次 pump）。
  bool acquire() {
    if (_busy >= capacity) return false;
    _busy++;
    return true;
  }

  /// 终结路径归还名额；多还会被夹回 0（防止计数器被打成负数后"白送"名额）。
  void release() {
    if (_busy > 0) _busy--;
  }
}

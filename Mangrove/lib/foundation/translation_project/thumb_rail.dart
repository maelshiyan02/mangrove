// A-1 · 左侧缩略图栏的**门控**与**页筛选**（纯逻辑，可 headless 断言）。
//
// 🔴 为什么单独一个文件：缩略图栏"能不能开"是一张真值表（单页/长画布 × 三个
// 阅读方向 × 页数），而"哪些页要显示"是一条会**改变页号**的过滤规则。这两件事
// 放进 widget 里就只能靠眼睛看 —— 而"隐藏横版页后页码整体错位"正是这类错里
// 最难用肉眼发现的一种。放进这里，它们能被 `run_headless_task.py` 直接断言。
//
// 与 [ReadingDirection] 一样**零 Flutter 依赖**：headless 在 App 启动前就能把
// 这张真值表跑完。
library;

/// 缩略图栏"不可用"的原因码。
///
/// 🔴 一个**枚举**而不是 `bool`：四种不可用各有**自己的**中文 tooltip（用户要
/// 知道"为什么不能开"）。若只返回布尔，界面就只剩一句通用的"不可用"，那等于把
/// "长画布自己能翻页"和"日漫本来没有上下截断"糊成同一句话。
enum ThumbRailGate {
  /// 可用。
  ready,

  /// 长画布模式：长画布自己能翻页，缩略图栏没有意义（D14：联动自动关闭）。
  stripMode,

  /// 只有一页（或没有页）：没有"缝"可检视。
  tooFewPages,

  /// 还没打开工程。
  noProject,
}

/// 缩略图栏的默认开关。**关**。
///
/// 🔴 缩略图栏是为"人眼逐条检查页间截断"服务的**临时视图**，不是翻页手段。
/// 常开会让左栏一直占着 240px，而绝大多数编辑动作并不需要它。把默认值提成
/// 常量，是为了让 `thumbrail.default_is_off` 断言能钉住**界面真正用的那一个**
/// 值，而不是在测试里另写一遍 `false`。
const bool thumbRailDefaultOn = false;

/// 缩略图栏的可用性判定（P30：方向门控已移除）。
///
/// ```
/// 可用 ⇔ 有工程 && 非长画布 && 页数 ≥ 2
/// ```
///
/// 🔴 P30 之前还有一条「阅读方向必须上→下」：一张横版宣传首页会让整本被误判
/// 成日漫，按钮跟着永久置灰 —— 用户拍板：**对所有漫画类别开放**（默认仍关，
/// 只是不再变灰）。横版页在栏内本来就被 [thumbRailVisibleIndices] 滤掉，
/// 日漫用户也可以把这一栏当纯翻页器用。
///
/// 判定顺序**有意义**：先判工程，再判模式，最后判页数 —— 后一个原因只在
/// 前面都通过了才有意义。界面只显示**第一个**不满足的原因，所以这个顺序
/// 就是 tooltip 的优先级。
ThumbRailGate thumbRailGate({
  required bool hasProject,
  required bool stripMode,
  required int pageCount,
}) {
  if (!hasProject) return ThumbRailGate.noProject;
  if (stripMode) return ThumbRailGate.stripMode;
  if (pageCount <= 1) return ThumbRailGate.tooFewPages;
  return ThumbRailGate.ready;
}

/// 门控是否放行。
bool thumbRailAvailable(ThumbRailGate gate) => gate == ThumbRailGate.ready;

/// 横版页判定（D11：`width >= height`）。
///
/// 🔴 正方形页也算横版：它同样不提供可供比对的上下宽度，而用户的原话是
/// "横图缩进缩略图栏没有意义"。用 `>=` 而不是 `>`，是让正方形落在**隐藏**的
/// 一侧 —— 反过来（正方形当竖版显示）会让一张 1:1 的宣传页夹在两条缝中间。
bool isLandscapePage(int width, int height) => width >= height;

/// 缩略图栏要显示的**原始页下标**（升序）。
///
/// 🔴 返回的是**原始下标**，不是过滤后的位置：调用方必须用 `index + 1` 当页号。
/// 若返回压缩后的序号，隐藏一张横图就会把后面所有页号整体前移一格 —— 而用户
/// 正是拿页号去对工程里的页键的（A-1.4 的"页号不错位"）。
///
/// 尺寸未知（`null`）的页**保留显示**：宁可多显示一张，也不能凭"读不出尺寸"
/// 把一页凭空吞掉（读不出可能只是格式不支持，不代表它是横图）。
List<int> thumbRailVisibleIndices({
  required int pageCount,
  required int? Function(int index) widthOf,
  required int? Function(int index) heightOf,
}) {
  final out = <int>[];
  for (var i = 0; i < pageCount; i++) {
    final w = widthOf(i);
    final h = heightOf(i);
    if (w != null && h != null && isLandscapePage(w, h)) continue;
    out.add(i);
  }
  return out;
}

/// 缩略图模式下序号/状态覆盖层的位置。
enum ThumbTileOverlay {
  /// 紧凑模式：序号贴左下、状态点贴右上（现状）。
  edge,

  /// 缩略图模式：序号**居中**、状态改**边框色** —— 不贴边，因为上下边缘正是
  /// 用户要看"缝"的位置（A-1.1 第 5 条）。
  center,
}

/// 覆盖层位置由 [large] 唯一决定。
///
/// 🔴 抽成函数，是为了让 `thumbrail.tile_hides_edge_overlays` 断言的**就是**
/// 界面真正调用的那一个判据，而不是测试里另写一份（两份必然漂移）。
ThumbTileOverlay thumbTileOverlay({required bool large}) =>
    large ? ThumbTileOverlay.center : ThumbTileOverlay.edge;
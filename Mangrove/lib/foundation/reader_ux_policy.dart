// P56 · 阅读器翻页 / 桌面快捷键 / 双布局的纯策略层。
//
// 🔴 本文件**零 Flutter 依赖**：`reader-ux-check` 可以在 App 初始化之前、在没有
// 渲染表面的会话里直接跑（A01 §2/§3）。UI 层只负责把 KeyEvent 换算成 key 字符串，
// 再把这里给出的 action 落到滚动 / 换页 / 切章上。
//
// 参数定案见 `.agent/documents/analysis/P56-ANALYSIS-阅读器翻页与桌面控件实测-20261114.md` §8：
// 空格 = 0.5 视口 + 200ms Curves.ease；↑/↓ 与空格同一套步进；桌面 ←/→ 切前后章；
// 章末双卡是常驻内容节点；章节列表为居中模态。
library;

/// 方案 A：一次翻页 = 半个视口（用户口述「半页左右」）。
const double kReaderTurnFraction = 0.5;

/// 沿用 Mangrove 连续模式原有的动画参数，只改步长，改动面最小。
const int kReaderTurnDurationMs = 200;

// ==== P64：单击 / 长按空格的两种手感 ====
//
// 单击 = 一次半屏 + 200ms 缓动（上面的 kReaderTurnFraction）。
// 长按 = 按住多久滚多久，松手当帧停住。两者必须走**不同**的落地方式：
// 长按若也用 animateTo，每个 tick 都会重启动画、互相打断，实际速度取决于
// 定时器与动画的赛跑，既不可控也做不出「急刹」。
//
// 阈值 180ms 的取法：低于它只可能是点按（人手最短敲击 ~60–120ms），高于它
// 用户已经能感觉到「按住」；与系统按键重复的首次延迟（~250–500ms）错开，
// 保证长按速度曲线由我们自己的 ticker 决定，不受系统重复节奏影响。
const Duration kReaderHoldTriggerDelay = Duration(milliseconds: 180);

/// 长按刚触发时的速度（视口/秒）。略高于一次单击的等效速度
/// （0.5 视口 / 0.2s ≈ 2.5/秒的瞬时值，但单击是一次性位移，按住连点最多
/// 3–4 次/秒 ≈ 1.5 视口/秒），起步取 1.1 可避免一按住就窜出去。
const double kReaderHoldStartSpeed = 1.1;

/// 长按满速（视口/秒）。3.0 ≈ 每秒 3 屏，明显快于连点空格。
const double kReaderHoldMaxSpeed = 3.0;

/// 从起步加速到满速所需时长。
const Duration kReaderHoldRampUp = Duration(milliseconds: 900);

/// 长按推进的节拍。16ms ≈ 60fps，每帧 jumpTo 一小步。
const Duration kReaderHoldTick = Duration(milliseconds: 16);

/// 长按安全上限：焦点被抢走时 KeyUp 可能永远不来，到点必须自己刹车。
const Duration kReaderHoldMaxDuration = Duration(seconds: 12);

/// gallery 没有像素插值，长按退化为「按固定节奏翻页」。
const Duration kReaderHoldPageInterval = Duration(milliseconds: 240);

/// 长按到 [held] 时的速度（视口/秒）。返回 0 表示仍处于单击判定窗口。
double readerHoldSpeed(Duration held) {
  if (held < kReaderHoldTriggerDelay) return 0;
  final ramp = kReaderHoldRampUp.inMicroseconds;
  if (ramp <= 0) return kReaderHoldMaxSpeed;
  final t =
      ((held - kReaderHoldTriggerDelay).inMicroseconds / ramp).clamp(0.0, 1.0);
  // smoothstep：起步平滑、末端收敛到满速，不会在阈值处突然跳一大步。
  final eased = t * t * (3 - 2 * t);
  return kReaderHoldStartSpeed +
      (kReaderHoldMaxSpeed - kReaderHoldStartSpeed) * eased;
}

/// 一个 tick 应推进的像素数（恒为正，方向由调用方给）。
double readerHoldDelta({
  required Duration held,
  required Duration tick,
  required double viewportExtent,
}) {
  final speed = readerHoldSpeed(held);
  if (speed <= 0) return 0;
  if (viewportExtent <= 0 || !viewportExtent.isFinite) return 0;
  return speed *
      viewportExtent *
      (tick.inMicroseconds / Duration.microsecondsPerSecond);
}

/// 键盘焦点自愈守卫（纯函数，零 Flutter 依赖，可被 headless 直接喂真值表）。
///
/// P64 实测的故障面：阅读器的 `KeyboardListener` 只有 [hasFocus] 为真才收键。
/// 弹一次右键菜单 / 设置抽屉 / 章节抽屉之后，焦点落到裸 `FocusScopeNode`
/// （"掉进虚空"），此后空格、↑↓ 全无反应，只有再点一下页面才回来 ——
/// 用户感知到的「用一会儿空格就失效」就是它。
///
/// 判据故意收得很窄，只补「焦点落空」这一种：
/// * 路由不是当前路由 → 不动（用户在别的页面上，抢焦点会打断人家）；
/// * 已有真实控件持有焦点 → 不动（**评论区输入框正在打字时绝不能抢**）；
/// * 只认 `primaryFocus == null` 或裸 `FocusScopeNode` 两种"虚空"态；
/// * 自己已经有焦点 → 不动（避免每次点击都 requestFocus 触发重建）。
///
/// 反向口：把任一条件写成恒真（always restore），headless 的
/// `reader.focus_guard_truth_table` / `reader.focus_guard_keeps_typing_focus`
/// 必须变红 —— 否则「不抢输入框」这条就成了没验证过的口号。
bool shouldReaderRestoreFocus({
  required bool routeIsCurrent,
  required bool hasFocus,
  required bool editableFocused,
  required bool primaryIsBareScope,
}) {
  if (!routeIsCurrent) return false;
  if (hasFocus) return false;
  if (editableFocused) return false;
  return primaryIsBareScope;
}

/// `auto` 模式下按窗口宽度推断桌面布局的下限。
const double kReaderDesktopLayoutMinWidth = 900.0;

/// comix.to 实测章末双卡几何（并排、间距 10）。窄窗由 UI 用 LayoutBuilder 收缩。
const double kChapterEndCardWidth = 355.0;
const double kChapterEndCardHeight = 44.0;
const double kChapterEndCardGap = 10.0;

/// 右下缩放簇占的宽度：时钟/电池整体左移让位时按这个固定宽度预留，
/// 不用负 margin 硬挤（OPENER §5.5）。
const double kReaderZoomClusterReserve = 176.0;

const String kReaderLayoutSettingKey = 'readerLayoutMode';
const String kReaderLayoutSettingDefault = 'auto';

/// 阅读器布局的三种设置值。`auto` 时按平台 + 窗口宽度推断。
enum ReaderLayoutSetting {
  desktop,
  mobile,
  auto,
}

/// 一次按键产生的语义动作。`none` 表示交回各阅读模式原有的方向键映射
/// （移动端布局 / 未接管的按键）。
enum ReaderKeyAction {
  none,
  turnForward,
  turnBackward,
  prevChapter,
  nextChapter,
}

/// 章节跳转的**来源**。P56 硬约束：只有显式点击（章末双卡 / 胶囊 / 章节列表）
/// 才允许换章，滚动到边界、过拉、自动滚动到底一律不允许。
enum ReaderJumpOrigin {
  galleryEdge,
  continuousOverscroll,
  autoScrollEnd,
  chapterEndCard,
  capsule,
  chapterList,
  keyboard,
  unknown,
}

ReaderLayoutSetting parseReaderLayoutSetting(Object? raw) {
  return switch (raw) {
    'desktop' => ReaderLayoutSetting.desktop,
    'mobile' => ReaderLayoutSetting.mobile,
    _ => ReaderLayoutSetting.auto,
  };
}

/// 当前是否采用桌面布局。所有桌面专属控件（右上胶囊、左缘页轨、右下缩放簇、
/// 桌面快捷键）都读这里，不再各自散读 `App.isDesktop`。
bool isDesktopReaderLayout({
  required Object? setting,
  required bool desktopPlatform,
  required double windowWidth,
}) {
  return switch (parseReaderLayoutSetting(setting)) {
    ReaderLayoutSetting.desktop => true,
    ReaderLayoutSetting.mobile => false,
    ReaderLayoutSetting.auto =>
      desktopPlatform && windowWidth >= kReaderDesktopLayoutMinWidth,
  };
}

/// 帮助对话框声称存在的按键。headless 断言逐条喂给 [readerKeyAction]，
/// 保证「帮助写了 = 代码真的接了」，杜绝 P47 那种虚标。
const List<String> kReaderHelpDocumentedKeys = <String>[
  'space',
  'arrowUp',
  'arrowDown',
  'arrowLeft',
  'arrowRight',
  'w',
  's',
  'a',
  'd',
  'shift+arrowLeft',
  'shift+arrowRight',
];

/// 桌面快捷键表。
///
/// - `space` / `↓` / `s` → 向后翻（连续模式滚半屏、gallery 翻下一页）；
/// - `↑` / `w` → 向前翻；
/// - `←` / `a` → 上一章，`→` / `d` → 下一章（T3 改语义，不再是翻页）；
/// - Shift + ←/→ 与不带 Shift 等价（兼容旧帮助写法）；其它 Shift 组合不接管；
/// - 移动端布局返回 `none`，由各阅读模式保留原有的按阅读方向映射。
ReaderKeyAction readerKeyAction({
  required String key,
  required bool desktopLayout,
  bool shiftHeld = false,
}) {
  if (!desktopLayout) return ReaderKeyAction.none;
  final effective = shiftHeld ? 'shift+$key' : key;
  return switch (effective) {
    'space' || 'arrowDown' || 's' => ReaderKeyAction.turnForward,
    'arrowUp' || 'w' => ReaderKeyAction.turnBackward,
    'arrowLeft' || 'a' => ReaderKeyAction.prevChapter,
    'arrowRight' || 'd' => ReaderKeyAction.nextChapter,
    'shift+arrowLeft' => ReaderKeyAction.prevChapter,
    'shift+arrowRight' => ReaderKeyAction.nextChapter,
    _ => ReaderKeyAction.none,
  };
}

/// 一次翻页的像素位移（沿当前阅读主轴的视口长度）。非翻页动作返回 0。
double readerTurnDelta({
  required double viewportExtent,
  required ReaderKeyAction action,
}) {
  if (viewportExtent <= 0 || !viewportExtent.isFinite) return 0;
  return switch (action) {
    ReaderKeyAction.turnForward => viewportExtent * kReaderTurnFraction,
    ReaderKeyAction.turnBackward => -viewportExtent * kReaderTurnFraction,
    _ => 0,
  };
}

/// 缩放百分比读数：**相对当前布局的 1x（适配比例）**，不是绝对 scale。
///
/// gallery 的 base 是「合页宽」后的比例（可能只有 0.42），直接把绝对 scale
/// 乘 100 会把「正好满屏」显示成 42%；连续模式 base = 1.0，两者都归一到 100%。
///
/// 读数与百分比输入框的预填值必须共用这一个函数：两处一旦各算一套，
/// 就会出现「标签写 100%、点开输入框却是 42」的自相矛盾。
int zoomPercentOf(double? scale, double? base) {
  final effectiveBase = (base == null || base <= 0) ? 1.0 : base;
  final s = scale ?? effectiveBase;
  if (!s.isFinite) return 100;
  return (s / effectiveBase * 100).round();
}

/// 章节跳转守卫：只有显式点击的来源放行。
bool allowReaderChapterJump(ReaderJumpOrigin origin) {
  return origin == ReaderJumpOrigin.chapterEndCard ||
      origin == ReaderJumpOrigin.capsule ||
      origin == ReaderJumpOrigin.chapterList ||
      origin == ReaderJumpOrigin.keyboard;
}

/// 连续模式（非无缝）章末常驻双卡是否入内容流。
///
/// 🔴 [imageCount] / [imagesLoaded] **刻意不参与判定**：图片未加载完、只有一页、
/// 甚至空章节，都必须留着这个显式出口，否则删掉三处隐式跳章后用户会被困在章末。
/// 故障注入若让判定依赖加载态，headless 的 `reader.chapter_end_always_reachable`
/// 必须变红。
bool shouldShowChapterEndNavInFlow({
  required bool enabled,
  required bool hasChapters,
  required bool seamless,
  required int imageCount,
  required bool imagesLoaded,
}) {
  if (!enabled || !hasChapters || seamless) return false;
  return true;
}

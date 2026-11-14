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

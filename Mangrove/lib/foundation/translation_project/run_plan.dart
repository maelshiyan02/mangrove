// 工作室「运行确认弹窗」的**纯逻辑**部分（S-N2）。
//
// 🔴 这个文件**零 Flutter 依赖**，理由与 `resumePages`（`studio_pipeline.dart`）
// 完全一样：用户在弹窗里选的页码区间到底换算成哪几页，是本项唯一一处
// "算错了也不报错"的地方 —— 区间算大了就是把整章重跑一遍（几分钟 + 一次
// 翻译请求），算小了就是"点了运行什么都没发生"。放进 widget 里就只能靠眼睛
// 看，而这里能被 headless 直接断言。
//
// 同时它也是 `StudioRunChoice` 的住所：弹窗的产物是一个**纯数据**对象，
// 而不是直接改 `studio_page` 的会话字段 —— 这样"弹窗选了什么都传下去了"
// 可以被断言，而不是靠人工核对。
library;

/// 一次运行的选择：弹窗的产物。
///
/// 🔴 **只作用于本次运行**。它不写 `appdata`、不写工程 json —— 写进设置会把
/// "为这一本临时改的语言"变成所有漫画的默认（`TranslationConfig` 的注释里
/// 记着 #178 就是这么来的），写进工程会立刻破坏零字节 diff。
class StudioRunChoice {
  const StudioRunChoice({
    required this.pages,
    required this.sourceLang,
    required this.targetLang,
    required this.translate,
    required this.rightToLeft,
  });

  /// 要跑的页 key，按**工程顺序**（不是用户拖动的方向）。
  final List<String> pages;

  /// 'auto' 或具体语种；本次运行覆盖 `TranslationConfig`。
  final String sourceLang;

  final String targetLang;

  /// false = 只检测 + 识别 + 建块，不调翻译引擎。
  final bool translate;

  /// true = 日漫右起。影响气泡的阅读顺序（`clusterBalloons`）。
  final bool rightToLeft;
}

/// 把 1 起的页码夹进 `[1, total]`。
///
/// [total] 为 0（工程没有可显示的页）时返回 0，调用方据 0 判"没有可选区间"。
/// 这个 0 是**刻意的**：返回 1 会让"空工程"看起来有一页可选。
int clampPageNumber(int value, int total) {
  if (total <= 0) return 0;
  if (value < 1) return 1;
  if (value > total) return total;
  return value;
}

/// 把 1 起的**闭区间** `[start, end]` 解析成 [pageKeys] 的子列表。
///
/// 三条契约（每一条都对应一个真实的误操作）：
///
/// 1. **越界夹取**，不抛异常：`0` → 第 1 页，`999` → 最后一页。手输页码时
///    多打一个 0 是常态，抛 `RangeError` 会把"点开始"变成崩溃。
/// 2. **倒序交换**，不返回空：`10..3` 是"起止写反了"，不是"想跑一个空区间"。
///    返回空会让用户点了开始却什么都没跑，而且**没有任何提示**。
/// 3. **绝不静默扩大成整章** —— 这是本函数存在的最大理由。`resumePages`
///    （`studio_pipeline.dart`）已经踩过同型的坑（断点不在页集里时返回整份
///    列表 ⇒ "继续"变成整章重跑）。区间越界时夹取、而不是"看不懂就全跑"。
///
/// [pageKeys] 为空 ⇒ 返回空列表，这是唯一合法的空。
List<String> resolvePageRange(List<String> pageKeys, int start, int end) {
  final total = pageKeys.length;
  if (total == 0) return const [];
  var a = clampPageNumber(start, total);
  var b = clampPageNumber(end, total);
  if (a > b) {
    final swap = a;
    a = b;
    b = swap;
  }
  return pageKeys.sublist(a - 1, b);
}

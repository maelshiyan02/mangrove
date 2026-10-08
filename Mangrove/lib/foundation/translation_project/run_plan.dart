// 工作室「运行确认弹窗」的**纯逻辑**部分（S-N2 · P10.15 序4）。
//
// 🔴 这个文件**零 Flutter 依赖**，理由与 `resumePages`（`studio_pipeline.dart`）
// 完全一样：用户在弹窗里选的页码区间、阶段组合到底换算成多少工作量，是本项
// 唯一一处"算错了也不报错"的地方 —— 区间算大了就是把整章重跑一遍（几分钟 +
// 一次翻译请求），算小了就是"点了运行什么都没发生"。放进 widget 里就只能靠
// 眼睛看，而这里能被 headless 直接断言。
//
// 同时它也是 [StudioRunChoice] / [StudioRunStages] / [StudioRunWorkload] 的
// 住所：弹窗的产物是一个**纯数据**对象，而不是直接改 `studio_page` 的会话
// 字段 —— 这样"弹窗选了什么都传下去了"可以被断言，而不是靠人工核对。
library;

import '../image_translation/balloon_clustering.dart';

/// 选中页范围内的块统计，供弹窗做工作量预估。
///
/// * [blocks] —— 已有块总数；
/// * [unrecognized] —— 其中原文为空的块；
/// * [untranslated] —— 其中有原文、还没译文的块。
///
/// 用 record 而不是再定义一个 3 字段的类：它**只是**弹窗与统计之间的一个
/// 中间值，没有行为、没有身份，做成类只会多一个要 import 的名字。
typedef StudioRunCounts = ({int blocks, int unrecognized, int untranslated});

/// 一次运行的三段选择（P10.15 §4.3）。
///
/// ## 次序契约
///
/// ```text
/// 检测（划气泡 → 建空块） → 识别（块内 OCR → 填原文） → 翻译（原文 → 译文）
/// ```
///
/// * 只选 [detect] ⇒ 只建块（版面预检，不花翻译请求）；
/// * 只选 [recognize] / [translate] ⇒ 要求工程**已有块**，否则无输入；
/// * 三段全选 ⇒ 等价于旧的"自动管线"。
class StudioRunStages {
  const StudioRunStages({
    required this.detect,
    required this.recognize,
    required this.translate,
  });

  /// 只建块，不认字、不翻译。
  final bool detect;

  /// 对已有（或本轮新建的）块做 OCR，填原文。
  final bool recognize;

  /// 对已有原文的块调翻译引擎，填译文。
  final bool translate;

  bool get any => detect || recognize || translate;

  StudioRunStages copyWith({bool? detect, bool? recognize, bool? translate}) {
    return StudioRunStages(
      detect: detect ?? this.detect,
      recognize: recognize ?? this.recognize,
      translate: translate ?? this.translate,
    );
  }

  Map<String, Object?> toJson() => {
        'detect': detect,
        'recognize': recognize,
        'translate': translate,
      };

  /// 从持久化值还原。缺失 / 类型不对一律当作"三段全关"，**不猜** ——
  /// 猜一个默认值会让用户下次打开时发现按钮的状态和他上次选的不是一回事。
  static StudioRunStages fromJson(Object? value) {
    final map = value is Map ? value : const <Object?, Object?>{};
    return StudioRunStages(
      detect: map['detect'] == true,
      recognize: map['recognize'] == true,
      translate: map['translate'] == true,
    );
  }

  @override
  String toString() => 'detect=$detect recognize=$recognize '
      'translate=$translate';
}

/// 一次运行的选择：弹窗的产物。
///
/// 🔴 **只作用于本次运行**（页码），而语向 / 阶段 / 阅读方向则由调用方按
/// [StudioRunDefaults] 决定要不要"记住"—— 但记住这件事**不发生在弹窗里**：
/// 本文件与 `run_dialog.dart` 都不碰 `appdata`（`edit-check` 的
/// `wiring.dialog_does_not_persist` 每次都在核对这一条）。持久化由
/// `studio_page.dart` 负责，那是它与设置层唯一应当接触的地方。
class StudioRunChoice {
  const StudioRunChoice({
    required this.pages,
    required this.sourceLang,
    required this.targetLang,
    required this.stages,
    required this.direction,
  });

  /// 要跑的页 key，按**工程顺序**（不是用户拖动的方向）。
  final List<String> pages;

  /// 'auto' 或具体语种；本次运行覆盖 `TranslationConfig`。
  final String sourceLang;

  final String targetLang;

  final StudioRunStages stages;

  /// 阅读方向（P10.15 §4.4：由两值扩为三值）。
  final ReadingDirection direction;

  bool get detect => stages.detect;

  bool get recognize => stages.recognize;

  bool get translate => stages.translate;
}

/// [StudioRunWorkload.blockedReason] 的全部取值。
///
/// 🔴 返回**码**而不是句子：句子要落进 `run_dialog.dart` 的字面量里，
/// `i18n.dialog_strings_registered` 才扫得到它们（漏登记不报错、只显示英文
/// —— 这正是 P9.3 反复栽的那一类）。纯逻辑层不该持有 UI 文案。
const StudioRunBlockReason noStageCode = StudioRunBlockReason('no-stage');
const StudioRunBlockReason noPagesCode = StudioRunBlockReason('no-pages');
const StudioRunBlockReason nothingToRecognizeCode =
    StudioRunBlockReason('nothing-to-recognize');
const StudioRunBlockReason nothingToTranslateCode =
    StudioRunBlockReason('nothing-to-translate');
const StudioRunBlockReason nothingToDoCode =
    StudioRunBlockReason('nothing-to-do');

/// 一个"不能开始"的机器可读原因。
class StudioRunBlockReason {
  const StudioRunBlockReason(this.code);

  final String code;

  @override
  String toString() => code;

  @override
  bool operator ==(Object other) =>
      other is StudioRunBlockReason && other.code == code;

  @override
  int get hashCode => code.hashCode;
}

/// 一次运行的工作量预估（P10.15 §4.3 / P3 选项 ①）。
///
/// 🔴 存在的理由是本项目的硬规矩之一：**绝不让空结果看起来像成功**。
/// "只选识别、但工程根本没有块"这种组合如果放行，跑一遍会报 0 —— 而 0 与
/// "识别了但没认出字"在界面上长得一模一样。所以要**算出来并明确告知**：
/// 无输入就禁用「开始」按钮 + 一行原因。
class StudioRunWorkload {
  const StudioRunWorkload({
    required this.detectPages,
    required this.recognizeBlocks,
    required this.translateBlocks,
    required this.dependsOnDetection,
    this.blockedReason,
  });

  /// 本轮要做检测的页数。
  final int detectPages;

  /// 已知需要识别的块数。检测同时打开时这里是 0（新块还没诞生），
  /// 由 [dependsOnDetection] 表达"实际数量取决于检测结果"。
  final int recognizeBlocks;

  /// 已知需要翻译的条数（含义同 [recognizeBlocks]）。
  final int translateBlocks;

  /// 是否开着检测 —— 打开时上面的块数只是**下界**，界面上必须说明。
  final bool dependsOnDetection;

  /// `null` = 可以开始；否则是不能开始的原因。
  final StudioRunBlockReason? blockedReason;

  bool get canStart => blockedReason == null;

  @override
  String toString() => 'detect=$detectPages recognize=$recognizeBlocks '
      'translate=$translateBlocks depends=$dependsOnDetection '
      'blocked=${blockedReason?.code}';
}

/// 算一次运行的工作量，并决定「开始」按钮能不能按。
///
/// [blocks] / [unrecognized] / [untranslated] 都是**选中页范围内**的统计：
///
/// * [blocks] —— 已有块总数；
/// * [unrecognized] —— 其中原文为空的块（识别阶段的输入）；
/// * [untranslated] —— 其中有原文、还没译文的块（翻译阶段的输入）。
///
/// 🔴 检测打开时**不做**"有没有活可干"的判断：新块的数量在检测跑完之前是
/// 未知的，拿"当前 0 块"去禁用开始会让"对一片空白页做检测"这个最正常的用法
/// 反而按不了。所以那条分支只要求 [selectedPages] > 0。
StudioRunWorkload planStudioRun({
  required int selectedPages,
  required bool detect,
  required bool recognize,
  required bool translate,
  required int blocks,
  required int unrecognized,
  required int untranslated,
}) {
  // 与 [blocks] 的一致性校验：`unrecognized` / `untranslated` 不可能超过总数。
  // 超了说明调用方统计错了（例如把别页的块算进来），此时**夹取**而不是
  // 抛异常 —— 这是弹窗的实时预览，抛异常会把打开弹窗变成崩溃。
  final safeUnrecognized = unrecognized.clamp(0, blocks < 0 ? 0 : blocks);
  final safeUntranslated = untranslated.clamp(0, blocks < 0 ? 0 : blocks);

  final detectPages = detect ? selectedPages : 0;
  // 检测会造出新块，它们的识别/翻译量此刻未知 ⇒ 报 0 并靠 dependsOnDetection
  // 表达"下界"。
  final recognizeBlocks = recognize && !detect ? safeUnrecognized : 0;
  final translateBlocks = translate && !detect
      ? safeUntranslated + (recognize ? safeUnrecognized : 0)
      : 0;

  StudioRunBlockReason? blocked;
  if (!detect && !recognize && !translate) {
    blocked = noStageCode;
  } else if (detect) {
    if (selectedPages <= 0) blocked = noPagesCode;
  } else if (recognize && translate) {
    if (recognizeBlocks == 0 && translateBlocks == 0) {
      blocked = nothingToDoCode;
    }
  } else if (recognize) {
    if (recognizeBlocks == 0) blocked = nothingToRecognizeCode;
  } else if (translate) {
    if (translateBlocks == 0) blocked = nothingToTranslateCode;
  }

  return StudioRunWorkload(
    detectPages: detectPages,
    recognizeBlocks: recognizeBlocks,
    translateBlocks: translateBlocks,
    dependsOnDetection: detect && (recognize || translate),
    blockedReason: blocked,
  );
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

/// [ReadingDirection] ↔ 持久化值（`studioRunDefaults.readingDirection`）。
///
/// 未知 / 缺失一律回落到 [ReadingDirection.leftToRight]（P10.15 §4.2：默认
/// **不勾右起**）。返回 `null` 表示"存储里没有可用的值"，让调用方能区分
/// "没存过"与"存的就是左起"。
ReadingDirection? readingDirectionFromName(Object? value) {
  return switch (value) {
    'rightToLeft' => ReadingDirection.rightToLeft,
    'leftToRight' => ReadingDirection.leftToRight,
    'topToBottom' => ReadingDirection.topToBottom,
    _ => null,
  };
}

/// [ReadingDirection] 的持久化名（枚举名本身，避免再发明一套编号）。
String readingDirectionName(ReadingDirection direction) => direction.name;

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
/// * [untranslated] —— 其中有原文、还没译文的块；
/// * [translatedPages] —— **至少有一个译文块**的页数（第四段「修图」的输入量）。
///
/// 用 record 而不是再定义一个 4 字段的类：它**只是**弹窗与统计之间的一个
/// 中间值，没有行为、没有身份，做成类只会多一个要 import 的名字。
///
/// 🔴 [translatedPages] 与 [blocks] 的口径**不同**（页 vs 块），刻意不放在一起
/// 相加：修图是**按页**落文件的（`inpainted/<页键>.png`），一页里有 8 个块也只
/// 画一次。把它按块报会让用户以为要跑 80 次，实际只有 10 页。
typedef StudioRunCounts =
    ({int blocks, int unrecognized, int untranslated, int translatedPages});

/// 一次运行的四段选择（P10.15 §4.3 + 2026-10-09 用户修订）。
///
/// ## 次序契约
///
/// ```text
/// 检测（划气泡 → 建空块） → 识别（块内 OCR → 填原文）
///   → 翻译（原文 → 译文） → 修图（抹除原文 → 在同一块里填译文）
/// ```
///
/// ## 🔴 为什么「修图」是第四段而不是翻译的收尾（2026-10-09）
///
/// 前三段是**文本层**，产物是工程 json 里的块。第四段是**位图层**，产物是
/// `mask/` + `inpainted/` + `result/`。把两者混在一段里会丢掉一个用户必须
/// 拥有的机会：**在抹字之前亲眼确认 AI 划的文字块范围对不对**。
///
/// 而抹字**不可逆**——`inpainted/` 一旦写出来，原图的字已经被算法抹掉了，
/// 用户想"框歪了，重画一下"就必须重新下载原图。所以 [repair] 默认 **false**：
/// 用户跑完前三段，先在工作室里看块、拖块、调完，再单独跑一次修图。
///
/// 🔴 顺带取消的另一件事：以前 `_save()`（Ctrl+S）末尾会
/// `unawaited(_regenerateResults(...))` 自动出图，所以"自动化跑一次"
/// 会**莫名其妙**连带重渲一遍产物。现在产物只有 [repair] 这一条来路。
class StudioRunStages {
  const StudioRunStages({
    required this.detect,
    required this.recognize,
    required this.translate,
    this.repair = false,
  });

  /// 只建块，不认字、不翻译。
  final bool detect;

  /// 对已有（或本轮新建的）块做 OCR，填原文。
  final bool recognize;

  /// 对已有原文的块调翻译引擎，填译文。
  final bool translate;

  /// 🔴 抹除原文 + 填入译文，产出 `mask/` `inpainted/` `result/`。
  ///
  /// **默认关**（见文件头的"为什么是第四段"）。关着时跑完前三段只有 json 变化，
  /// 盘上图片一动不动 —— 这是刻意的：用户要先核对文字块范围。
  final bool repair;

  bool get any => detect || recognize || translate || repair;

  /// 只做位图层的那一段（`mask/` + `inpainted/` + `result/`）。
  bool get producesArtifacts => repair;

  /// 需要**块范围正确**才能跑的段。用户点它们之前应该已经看过块。
  bool get needsVerifiedBoxes => recognize || translate || repair;

  StudioRunStages copyWith({
    bool? detect,
    bool? recognize,
    bool? translate,
    bool? repair,
  }) {
    return StudioRunStages(
      detect: detect ?? this.detect,
      recognize: recognize ?? this.recognize,
      translate: translate ?? this.translate,
      repair: repair ?? this.repair,
    );
  }

  Map<String, Object?> toJson() => {
        'detect': detect,
        'recognize': recognize,
        'translate': translate,
        'repair': repair,
      };

  /// 从持久化值还原。缺失 / 类型不对一律当作"全部关"，**不猜** ——
  /// 猜一个默认值会让用户下次打开时发现按钮的状态和他上次选的不是一回事。
  ///
  /// 🔴 旧记录（没有 `repair` 键）读出来是 `false` 而不是"跟着 `translate` 开"：
  /// 旧行为是「翻译完自动出图」，若把它解释成 `repair = translate`，等于把已经
  /// 取消的自动出图**又悄悄恢复**。宁可一次都没修图（用户看得见、可以补跑），
  /// 也不要静默回到用户刚拒绝的行为。
  static StudioRunStages fromJson(Object? value) {
    final map = value is Map ? value : const <Object?, Object?>{};
    return StudioRunStages(
      detect: map['detect'] == true,
      recognize: map['recognize'] == true,
      translate: map['translate'] == true,
      repair: map['repair'] == true,
    );
  }

  @override
  String toString() => 'detect=$detect recognize=$recognize '
      'translate=$translate repair=$repair';
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

  /// 🔴 第四段：抹除原文 + 填字修图（2026-10-09 用户修订）。
  bool get repair => stages.repair;
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

/// 「只勾了修图」而工程里还没有译文块 —— 单独一条原因码。
///
/// 🔴 不复用 `nothing-to-translate`：那一条的提示是"没有块有原文"，
/// 而这里的真实情况是"有块、也翻了，但**没打开修图**，所以现在画不了"
/// —— 用户看到前者会以为要去跑翻译，而正确动作是回到弹窗把「修图」勾上，
/// 或者去工作室确认块范围。两句话指向完全不同的下一步，不能共用一条码。
const StudioRunBlockReason nothingToRepairCode = StudioRunBlockReason(
  'nothing-to-repair',
);

/// 一次运行的工作量预估（P10.15 §4.3 / P3 选项 ① + 第四段）。
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
    required this.repairPages,
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

  /// 🔴 本轮要出图的页数（第四段）。
  ///
  /// 与前三段不同，它**不是**"块数"而是"页数"：修图的最小单位是页
  /// （`inpainted/` 与 `result/` 都是按页落的文件），一页里有多少块都只算一次。
  final int repairPages;

  /// 是否开着检测 —— 打开时上面的块数只是**下界**，界面上必须说明。
  final bool dependsOnDetection;

  /// `null` = 可以开始；否则是不能开始的原因。
  final StudioRunBlockReason? blockedReason;

  bool get canStart => blockedReason == null;

  @override
  String toString() => 'detect=$detectPages recognize=$recognizeBlocks '
      'translate=$translateBlocks repair=$repairPages depends=$dependsOnDetection '
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
///
/// 🔴 [repairPages] 只数**已经有译文的页**——一块译文都没有的页画出来是一张
/// 去字的白页，比原图更糟（用户会以为"翻译把字弄没了"），所以那种页在修图段
/// 必须跳过，并在界面上把页数报出来。
StudioRunWorkload planStudioRun({
  required int selectedPages,
  required bool detect,
  required bool recognize,
  required bool translate,
  bool repair = false,
  required int blocks,
  required int unrecognized,
  required int untranslated,
  int pagesWithTranslation = 0,
}) {
  // 与 [blocks] 的一致性校验：`unrecognized` / `untranslated` 不可能超过总数。
  // 超了说明调用方统计错了（例如把别页的块算进来），此时**夹取**而不是
  // 抛异常 —— 这是弹窗的实时预览，抛异常会把打开弹窗变成崩溃。
  final safeBlocks = blocks < 0 ? 0 : blocks;
  final safeUnrecognized = unrecognized.clamp(0, safeBlocks);
  final safeUntranslated = untranslated.clamp(0, safeBlocks);

  final detectPages = detect ? selectedPages : 0;
  // 检测会造出新块，它们的识别/翻译量此刻未知 ⇒ 报 0 并靠 dependsOnDetection
  // 表达"下界"。
  final recognizeBlocks = recognize && !detect ? safeUnrecognized : 0;
  final translateBlocks = translate && !detect
      ? safeUntranslated + (recognize ? safeUnrecognized : 0)
      : 0;
  // 🔴 修图页数**不能**乘 detect：检测会把页数算成"全部选中页"，而检测完
  // 之后那些页未必有译文 —— 那会让弹窗报"修图 94 页"然后真跑只画出 0 张。
  // 报**已知**有译文的页数，宁可少报（用户看到 0 会去勾翻译）也不要虚报。
  final repairPages = repair && !detect ? pagesWithTranslation : 0;

  StudioRunBlockReason? blocked;
  final nothingSelected = !detect && !recognize && !translate && !repair;
  if (nothingSelected) {
    blocked = noStageCode;
  } else if (detect) {
    if (selectedPages <= 0) blocked = noPagesCode;
  } else if (repair && !recognize && !translate) {
    // 🔴 只勾修图：它不产块也不产译文，唯一的前置是"已经有译文可画"。
    // 这里**不**看 recognizeBlocks/translateBlocks —— 用户要的就是"我已经
    // 翻好了，现在只补图"，那两栏本来就该是 0。
    if (repairPages == 0) blocked = nothingToRepairCode;
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
    repairPages: repairPages,
    dependsOnDetection: detect && (recognize || translate || repair),
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

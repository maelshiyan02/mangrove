import 'dart:math' as math;

import 'text_block.dart';

/// 「给一个块做局部识别 / 局部翻译」这件事的**纯逻辑部分**。
///
/// ## 为什么单独抽出来
///
/// 两个按钮都要用到同一批判断：区域要不要**放大**一点（块太小的时候按原框
/// 裁，OCR 在 30×20 的图上什么都认不出来）、裁到多大、结果算不算成功、
/// 失败要不要写回。这些判断一旦散在 widget 的 `onPressed` 里，就只能靠眼睛
/// 验证 —— 而"块太小时识别返回空"恰好是那种**界面上看不出错**的失败。
///
/// 所以规则全部收在这里，`studio_block_panel.dart` 只负责把回调接上。
abstract final class StudioBlockOps {
  /// 单块识别时，OCR 输入的最小边长（像素）。
  ///
  /// 取 96 是有理由的：中日文字形在 20 px 高时已经糊成一团，而把 30×20 的
  /// 块放大到 96 只需要一次双线性插值 —— 放大不会凭空造出信息，但能让
  /// 检测器有机会找到"这里有字"。
  static const minCropSide = 96;

  /// 裁剪窗口在块外框之外额外留的余量（像素）。
  ///
  /// 留边是因为 OCR 检测出来的行框通常**略大于**气泡的形心框；不留边会把
  /// 边缘那半个字切掉。
  static const cropPadding = 12;

  /// 把 [box]（页坐标）扩成裁剪窗口，并夹到 `[0, width) × [0, height)`。
  ///
  /// 返回 null 表示**这个框没法作为 OCR 输入**（退化到零宽/零高，或完全
  /// 落在页外）。🔴 刻意不返回"夹到最角落的 1×1"：那会让 OCR 白跑一趟并
  /// 返回空，用户看到的是"点了没反应"，而真实原因是块坐标坏了。
  static CropWindow? cropWindow(
    List<double> box,
    int width,
    int height, {
    int padding = cropPadding,
    int minSide = minCropSide,
  }) {
    if (width <= 0 || height <= 0) return null;
    final rawLeft = box.isNotEmpty ? box[0].round() : 0;
    final rawTop = box.isNotEmpty ? box[1].round() : 0;
    final rawRight = box.length > 2 ? box[2].round() : rawLeft;
    final rawBottom = box.length > 3 ? box[3].round() : rawTop;
    if (rawRight <= rawLeft || rawBottom <= rawTop) return null;
    // 先在**原坐标系**里放大再夹取：先夹后放大会让贴边的块拿到一个偏心的
    // 窗口（左边贴边、右边被截），而先放后夹保证窗口始终包住整个块。
    //
    // 🔴 放大量必须是**整数**的分配：`grow = (minSide - w) / 2` 在奇数差时
    // 是 .5，两侧各加 .5 会让左右各差一像素，窗口不再对称 —— 那正是
    // "贴边块拿到偏心窗口"的另一种形态。用 `~/` 让两侧分摊同一个奇数。
    var left = rawLeft - padding;
    var top = rawTop - padding;
    var right = rawRight + padding;
    var bottom = rawBottom + padding;
    final w = right - left;
    final h = bottom - top;
    if (w < minSide) {
      final grow = (minSide - w) ~/ 2;
      left -= grow;
      right += grow;
      if (right - left < minSide) right += minSide - (right - left);
    }
    if (h < minSide) {
      final grow = (minSide - h) ~/ 2;
      top -= grow;
      bottom += grow;
      if (bottom - top < minSide) bottom += minSide - (bottom - top);
    }
    final clampedLeft = left.clamp(0, width);
    final clampedTop = top.clamp(0, height);
    final clampedRight = right.clamp(0, width);
    final clampedBottom = bottom.clamp(0, height);
    if (clampedRight - clampedLeft < 4 || clampedBottom - clampedTop < 4) {
      return null;
    }
    return CropWindow(
      clampedLeft,
      clampedTop,
      clampedRight - clampedLeft,
      clampedBottom - clampedTop,
    );
  }

  /// 把裁剪窗口内的坐标换算回页坐标。
  ///
  /// 🔴 局部识别的产物必须**换算回去**再写进块：直接写窗口内坐标会让文字
  /// 落到块的左上角附近而不是原位，而界面不会报错 —— 它只是"文字挪了"。
  static List<int> toPageCoords(CropWindow crop, List<int> localBox) {
    return [
      localBox[0] + crop.left,
      localBox[1] + crop.top,
      (localBox.length > 2 ? localBox[2] : localBox[0]) + crop.left,
      (localBox.length > 3 ? localBox[3] : localBox[1]) + crop.top,
    ];
  }

  /// 识别结果算不算成功。
  ///
  /// 🔴 **空结果判失败**，不判"成功但没文字"：用户点了【识别】却什么都没
  /// 发生时，必须有一句可读的说明，否则他只会以为按钮坏了。
  static bool isRecognised(String text) => text.trim().isNotEmpty;
}

/// 拟声词 / 非标准文字的**默认策略**（P10.15 §4.5 · 序6）。
///
/// ## 为什么要有这一层
///
/// 漫画里 `BAM!!`、`SLAM`、「쿵」这类拟声词**不该被翻译、更不该被改字** ——
/// 它们是画面的一部分。但检测器分不出"拟声词"和"短对白"，而把每一页都送去
/// 问模型既费 token 又会拿到一堆荒唐译文（模型对着 `SLAM` 会给出"猛击"）。
///
/// 所以这里只做一件**保守**的事：把明显属于这一类、且**敢于确认**的块打上
/// `label: 'sfx'`，于是它们
///
/// 1. 不进翻译批次（省 token，也不会得到荒唐译文）；
/// 2. `translation` 保持为空 ⇒ `toTranslatedRegion()` 返回 null ⇒ 既不 letter
///    也不产生 `region` ⇒ **原字原样留在图上**（"不改字"就是这么实现的：
///    抹字的区域来自 `page.regions`，而它只包含有译文的块）；
/// 3. 在 json 里留下可筛的标记（`TextBlock.label`），供人工复核。
///
/// 人工兜底：工作室块面板上的【翻译】是**单块**动作，**不看**这个标记 ——
/// 用户一眼看出被误标，点一下就能翻。所以"默认不译"不是死路。
///
/// ## 🔴 判据刻意收得很窄（误标与漏标的代价不对称）
///
/// 误标 = **一句真对白默认不译**（要人点一下才回来）；漏标 = 多问一次模型。
/// 所以只在下面三条**同时**成立时才判为 SFX：
///
/// * 源语言是拉丁/韩文（[languages]）—— 中日文的短句（「嗯」「你好」）是正常
///   对白，按字符数判会把它们成片误标；
/// * 去掉空白后 ≤ [maxChars] 个字符；
/// * 不含任何中日文字（汉字/假名 —— 那类由竖排启发式管，见 §4.5 第一段），且
///   （韩文）**只有 1 个音节**（[maxHangulChars]），或（拉丁）**全大写**且
///   ≥ 3 个字母。全大写是漫画拟声词的书写惯例（`BAM` / `SLAM`），而 `No` /
///   `Hi` / `Hello` 这类短对白是混合大小写，正好被排除。
///
/// 🔴 韩文刻意只收单音节（「쿵」「쾅」「퍽」）：**两个音节就分不出来了** ——
/// 「두근」（拟声词）与「안녕」（台词）的字数完全一样，靠字数判必然误标，而
/// 误标的代价是"一句真对白默认不译"。这条只有中文/日文词典能解决，现在没有，
/// 所以**宁可漏**：漏了只是多问一次模型。
///
/// 已知的误标形态（可接受，因为一次点击就能翻）：全大写的短问候语，如
/// `HELLO` / `OK!`。
abstract final class StudioSfxOps {
  /// `TextBlock.label` 的取值。
  static const String label = 'sfx';

  /// 去掉空白后的最大字符数。
  static const int maxChars = 5;

  /// 韩文拟声词的音节数上限。**1** —— 见类文档最后一段：2 音节无法与台词区分。
  static const int maxHangulChars = 1;

  /// 判为 SFX 的源语言。**刻意只有这两个** —— 见类文档第一条。
  static const Set<String> languages = {'en', 'ko'};

  static final RegExp _whitespace = RegExp(r'\s+');
  // 🔴 这几条**不用 raw 字符串**：`r'\u3040'` 交给正则引擎的是一段
  // `\u3040` 文本（依赖正则自己解析转义），而普通字符串里的 `\u3040` 由
  // **Dart** 先转成真正的字符。后者只有一种解释，读代码的人不必去查
  // "这个正则引擎支持不支持 `\u`"。
  //
  // 中日文：假名（U+3040–30FF）+ 汉字（含扩展 A 与兼容区）。
  static final RegExp _cjk = RegExp(
    '[\u3040-\u30FF\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF]',
  );
  // 韩文**音节**（U+AC00–D7A3）。刻意不含 Jamo 区：OCR 交出来的是音节。
  static final RegExp _nonLetters = RegExp('[^A-Za-z\uAC00-\uD7A3]');
  static final RegExp _nonHangul = RegExp('[^\uAC00-\uD7A3]');

  /// [text] 是否像拟声词 / 非标准文字。[language] 是 OCR 判定的源语言。
  static bool looksLikeSfx(String text, {required String language}) {
    final compact = text.replaceAll(_whitespace, '');
    if (compact.isEmpty || compact.length > maxChars) return false;
    if (!languages.contains(language.trim().toLowerCase())) return false;
    // 中日文字符一律不判：它们要么是正常对白，要么该走竖排那条路。
    if (_cjk.hasMatch(compact)) return false;
    final letters = compact.replaceAll(_nonLetters, '');
    // 纯符号（`!!` / `???` / `…`）不是拟声词，标了只会让用户以为有东西。
    if (letters.isEmpty) return false;
    final hangul = letters.replaceAll(_nonHangul, '');
    if (hangul.isNotEmpty) return hangul.length <= maxHangulChars;
    return letters.length >= 3 && letters == letters.toUpperCase();
  }

  /// [block] 是否已被本策略标记为拟声词。
  static bool isMarkedSfx(TextBlock block) => block.label == label;
}

/// 一次局部识别的裁剪窗口（页坐标）。
class CropWindow {
  CropWindow(this.left, this.top, this.width, this.height);

  final int left;
  final int top;
  final int width;
  final int height;

  int get right => left + width;
  int get bottom => top + height;

  @override
  String toString() => 'CropWindow($left,$top ${width}x$height)';

  @override
  bool operator ==(Object other) =>
      other is CropWindow &&
      other.left == left &&
      other.top == top &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(left, top, width, height);
}

/// 局部识别的结果，附带足够写日志的信息。
class BlockRecogniseResult {
  const BlockRecogniseResult({
    required this.crop,
    required this.text,
    required this.language,
    this.boxInPage,
  });

  final CropWindow crop;
  final String text;
  final String language;

  /// 识别框（已换算回页坐标）。
  final List<int>? boxInPage;

  bool get ok => StudioBlockOps.isRecognised(text);
}

/// 单块翻译的判定：什么情况下把模型的回答写进块。
///
/// ## 为什么翻译也要判据，而不是"拿到就写」
///
/// 局部翻译最容易出的错是**静默清空**：模型对着一段 OCR 噪声返回空串，
/// 直接写回就等于把用户手工校对好的译文抹掉，而且看不出发生过任何事。
/// 所以空结果一律不写 —— 让旧译文留在那里。
abstract final class StudioTranslateOps {
  /// 是否把 [incoming] 写进块。
  ///
  /// 三条拒绝，其中前两条各堵一个具体的静默数据损失：
  ///
  /// 1. **空结果** —— 模型对着一段 OCR 噪声返回空串，写回就等于把用户
  ///    手工校对好的译文抹掉，而界面上看不出发生过任何事。
  /// 2. **与现有译文逐字相同** —— 这不是"翻译成功"，是模型回声。写回会让
  ///    按钮看上去生效了，实际什么都没变，用户于是以为按钮坏了。
  /// 3. **与原文逐字相同** —— 同上，且这通常意味着原文本来就是目标语。
  static bool shouldApply(
    String incoming, {
    required String currentTranslation,
    String currentSource = '',
  }) {
    final text = incoming.trim();
    if (text.isEmpty) return false;
    if (text == currentTranslation.trim()) return false;
    // 🔴 原文为空时**仍然要求译文非空**（上面已判），并且允许写入：用户
    // 可能手工清空了原文、只想让模型按块的位置猜一次，这时"与原文相同"
    // 必然成立，用它当拒绝条件会把这条唯一的路堵死。
    if (currentSource.trim().isNotEmpty && text == currentSource.trim()) {
      return false;
    }
    return true;
  }

  /// 把多行识别结果合成一块的原文。
  ///
  /// 换行保留：FT 的块是多行的，合成一个空格分隔的长串会让用户没法逐行校对。
  static String joinLines(List<String> lines) =>
      lines.map((l) => l.trim()).where((l) => l.isNotEmpty).join('\n');

  /// 局部识别的文本按行拆开（worker 可能返回整块一段）。
  static List<String> splitLines(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return const [];
    return trimmed.split(RegExp(r'[\r\n]+')).where((l) => l.trim().isNotEmpty).toList();
  }

  /// 单块识别的取词上限：超过这么多行就认为裁剪窗口抓了太多东西，
  /// 多半是**框选错了**而不是页面上真有那么多字。
  static const maxLinesPerBlock = 12;

  static bool looksLikeWrongRegion(List<String> lines) =>
      lines.length > maxLinesPerBlock;

  /// 裁剪窗口的对角线长度，用于日志。
  static int cropDiagonal(CropWindow crop) =>
      math.max(crop.width, crop.height);
}
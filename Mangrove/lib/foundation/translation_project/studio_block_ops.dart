import 'dart:math' as math;

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
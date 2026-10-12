// 「可反复点击的【识别】/【翻译】按钮」（S-N1）与「mask 生产 + 抹字复原」
// （S-N3）的断言集。
//
// 两者放一起，因为它们共用一条约束：**像素级的部分本会话测不到，能测的必须
// 测干净**。`GrayPng` / `buildMaskPage` / `restoreErasedPage` 全部是纯 Dart
// （无 `dart:ui`），所以 mask 这一段第一次能被 headless 真正验完 —— 这正是
// S-N3 押后到今天才做的原因，也是 `A05 §4.5` 记的那条"诚实路线已具备"的兑现。
//
// ## 反向验证
//
// 同 M08：每条断言跑两遍（绿路径 true + 故障路径必须 false）。像素类的故障
// 路径用**真的画错**来构造（极性写反、越界、错尺寸），不是"搜一个不存在的
// 字符串" —— 后者证明不了判据非恒真。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mangrove/foundation/image_translation/inpaint.dart';
import 'package:mangrove/foundation/image_translation/translation_types.dart';
import 'package:mangrove/foundation/translation_project/block_artifacts.dart';
import 'package:mangrove/foundation/translation_project/gray_png.dart';
import 'package:mangrove/foundation/translation_project/mask_producer.dart';
import 'package:mangrove/foundation/translation_project/studio_block_ops.dart';
import 'package:mangrove/foundation/translation_project/text_block.dart';
import 'package:mangrove/headless_p1_checks.dart' show CheckSink, tlLiteralKeys;

/// 一张纯色 RGBA 图。像素值按行给出，便于构造"白底 + 黑块"这类最小夹具。
RgbaImage _solid(int w, int h, int rgb) {
  final px = Uint8List(w * h * 4);
  for (var i = 0; i < w * h; i++) {
    px[i * 4] = (rgb >> 16) & 0xFF;
    px[i * 4 + 1] = (rgb >> 8) & 0xFF;
    px[i * 4 + 2] = rgb & 0xFF;
    px[i * 4 + 3] = 0xFF;
  }
  return RgbaImage(w, h, px);
}

/// 白底 + 中央一块纯黑"文字块"。`computeMask` 需要足够强的明暗对比与一定的
/// 笔画密度，所以黑块必须**小于** region 面积（超过 85% 会被当成线稿拒绝），
/// 又不能小于 6px 的最小连通域。
/// 白底 + **两块分离的**黑块（中间留足空隙，让两块的掩膜窗口互不覆盖）。
///
/// 🔴 分离是刻意的：两个 region 强重叠时，"覆盖式并集"与"或累积并集"结果
/// 完全相同，那样的夹具**证明不了**并集判据能分辨这两种实现。
RgbaImage _twoGlyphs(int w, int h) {
  final img = _solid(w, h, 0xFFFFFF);
  void block(int gx, int gy, int gw, int gh) {
    for (var y = gy; y < gy + gh && y < h; y++) {
      for (var x = gx; x < gx + gw && x < w; x++) {
        final i = (y * w + x) * 4;
        img.pixels[i] = 0;
        img.pixels[i + 1] = 0;
        img.pixels[i + 2] = 0;
      }
    }
  }

  // 🔴 块间距 48px。`computeMask` 的窗口超出 region 一圈 `pad`，所以第二个 region 的窗口
  // 会盖到第一块笔画的最后几列，而它自己的 mask 在那里是 0 → 覆盖式会把那几列清零。
  // 这才是能握住“覆盖式”的夹具：两块彼此距很远时，后一个 region 的窗口里根本没有
  // 前一块的笔画，覆盖式与“或累积”给出**完全相同**的结果。
  block(10, 14, 18, 12);
  block(58, 14, 18, 12);
  return img;
}

RgbaImage _pageWithGlyphs(int w, int h, int gx, int gy, int gw, int gh) {
  final img = _solid(w, h, 0xFFFFFF);
  for (var y = gy; y < gy + gh && y < h; y++) {
    for (var x = gx; x < gx + gw && x < w; x++) {
      final i = (y * w + x) * 4;
      img.pixels[i] = 0;
      img.pixels[i + 1] = 0;
      img.pixels[i + 2] = 0;
    }
  }
  return img;
}

class _Probe {
  const _Probe(this.name, this.green, this.red, this.detail);

  final String name;
  final Future<bool> Function() green;
  final Future<bool> Function() red;
  final String Function() detail;
}

const _panelPath = 'lib/pages/translation_studio/studio_block_panel.dart';
const _studioPath = 'lib/pages/translation_studio/studio_page.dart';
const _pipelinePath =
    'lib/foundation/image_translation/translation_pipeline.dart';
const _rendererPath =
    'lib/foundation/translation_project/result_renderer.dart';
const _studioPipelinePath =
    'lib/foundation/translation_project/studio_pipeline.dart';
const _tablePath = 'assets/translation.json';

Future<void> runP7Checks(
  CheckSink check, {
  required Directory packageRoot,
}) async {
  final probes = <_Probe>[];
  void probe(
    String name,
    Future<bool> Function() green,
    Future<bool> Function() red,
    String Function() detail,
  ) {
    probes.add(_Probe(name, green, red, detail));
  }

  String code(String rel) =>
      File('${packageRoot.path}/$rel').readAsStringSync();
  bool codeHas(String rel, String needle) => code(rel).contains(needle);
  final zhCn =
      (jsonDecode(code(_tablePath)) as Map)['zh_CN'] as Map<String, dynamic>;

  // ── 1 · GrayPng：手写 PNG 是不是一个真的 PNG ─────────────────────────

  probe(
    'png.signature_and_ihdr',
    () async {
      final bytes = GrayPng.encode(2, 2, Uint8List.fromList([0, 85, 170, 255]));
      // PNG 魔数 + 第一块必须是 IHDR，且 IHDR 声明 **colour type 0**
      // （单通道灰度）—— 改成 6（RGBA）的话 FT 的
      // `imread(IMREAD_GRAYSCALE)` 仍能解码，"单通道"这个契约却只剩约定。
      final head = String.fromCharCodes(bytes.sublist(0, 8));
      if (head != 'PNG\r\n\n') return false;
      final type = String.fromCharCodes(bytes.sublist(12, 16));
      if (type != 'IHDR') return false;
      return bytes[24] == 8 && bytes[25] == 0;
    },
    () async {
      // 故障路径：把 colour type 写成 6（RGBA）。
      final bytes = GrayPng.encode(2, 2, Uint8List.fromList([0, 85, 170, 255]));
      return bytes[25] == 6;
    },
    () => '绿=colour type 0（灰度）/ 故障=写成 6（RGBA）⇒ 判据非恒真',
  );

  probe(
    'png.geometry_mismatch_throws',
    // 🔴 长度与 IHDR 不符的 PNG 属于"写得进去、读出来是垃圾"。宁可当场抛。
    () async {
      try {
        GrayPng.encode(4, 4, Uint8List(9));
        return false;
      } on ArgumentError {
        return true;
      }
    },
    () async {
      // 故障路径 = 一个**不做长度检查**的假编码器：它对 9 字节配 4x4 也不抛，
      // 于是"抛错"这一条对它为 false ⇒ 判据变红。
      try {
        _uncheckedEncode(4, 4, Uint8List(9));
        return false;
      } on ArgumentError {
        return true;
      }
    },
    () => '绿=9 字节配 4x4 抛错 / 故障=16 字节（合法）不抛 ⇒ 判据会分辨',
  );

  probe(
    'png.crc_matches_known_answer',
    // 已知答案：CRC32("123456789") = 0xCBF43926。
    () async => GrayPng.crc32('123456789'.codeUnits) == 0xCBF43926,
    () async => GrayPng.crc32('12345678'.codeUnits) == 0xCBF43926,
    () => '绿=标准 CRC32 向量 / 故障=少一位的输入',
  );

  // ── 2 · mask 生产：字形级、极性、整页尺寸 ───────────────────────────

  probe(
    'mask.is_glyph_level_not_the_box',
    // 🔴 本项存在的全部理由：mask 若写成块外框，就是一个**同名但语义不同**的
    // 文件（FT 的 mask 是字形级）。所以判据是"背景像素必须还是 0"。
    () async {
      final img = _pageWithGlyphs(64, 64, 20, 24, 24, 16);
      return _glyphLevelHolds(buildMaskPage(img, [IntRect(16, 20, 48, 44)]));
    },
    () async {
      // 🔴 **同一个判据**喂给矩形近似实现（A05 §4.5 明确拒绝的做法）。
      // 判据里的第三条（region 内、黑块外必须是 0）只有字形级实现能满足。
      return _glyphLevelHolds(_rectApproxMask(64, 64, [IntRect(16, 20, 48, 44)]));
    },
    () => '绿=region 外的背景仍是 0 / 故障=矩形近似（同一坐标是 255）',
  );

  probe(
    'mask.polarity_is_255_erased',
    // FT / BT：非零 = 已抹（`PM_inpaint` 拿它当洞，`undo` 用 `mask > 0` 判）。
    () async {
      final img = _pageWithGlyphs(64, 64, 20, 24, 24, 16);
      final mask = buildMaskPage(img, [IntRect(16, 20, 48, 44)]);
      return mask.pixels.every((v) => v == 0 || v == 255);
    },
    () async {
      // 故障路径：极性写反（0=已抹）时"背景仍是 0"这条也成立 ⇒ 必须靠
      // "前景为 255"来分辨。
      final img = _pageWithGlyphs(64, 64, 20, 24, 24, 16);
      final mask = buildMaskPage(img, [IntRect(16, 20, 48, 44)]);
      final centre = 32 * mask.width + 32;
      return mask.pixels[centre] == 0;
    },
    () => '绿=前景 255 / 故障=前景 0（极性反了）',
  );

  probe(
    'mask.is_whole_page_sized',
    // 待拍板 18 的结论：FT 的 mask 是**整页**尺寸，不是逐 region 的小窗口。
    () async {
      final img = _pageWithGlyphs(64, 64, 20, 24, 24, 16);
      final mask = buildMaskPage(img, [IntRect(16, 20, 48, 44)]);
      return mask.width == 64 &&
          mask.height == 64 &&
          mask.pixels.length == 64 * 64;
    },
    () async {
      final img = _pageWithGlyphs(64, 64, 20, 24, 24, 16);
      final window = TextInpainter.computeMask(img, IntRect(16, 20, 48, 44));
      return window != null && window.rw == 32;
    },
    () => '绿=整页 64x64 / 故障=只出 region 的 32px 小窗口',
  );

  probe(
    'mask.overlapping_regions_union_not_overwrite',
    // 🔴 FT 的块外框常常交叠。用"或"累积；改成后写覆盖会让某些笔画静默丢失。
    () async {
      final img = _twoGlyphs(120, 40);
      return _unionCoversBoth(img);
    },
    () async {
      // 🔴 同一个判据喂给"覆盖式"实现。
      //
      // 🔴 夹具换成**分离的两块**：之前两个 region 强重叠，覆盖式的结果与正确实现
      // 完全相同（每个 region 的窗口都包含两块的笔画）—— 那时“删掉一个键”不能作为
      // 故障路径，因为它对两个实现的结果一样。分离两块之后，覆盖式会把第一块的
      // 笔画全部清零 → 判据立即变红。
      final img = _twoGlyphs(120, 40);
      final left = IntRect(4, 8, 36, 32);
      final right = IntRect(30, 8, 90, 32);
      final a = buildMaskPage(img, [left]);
      final b = buildMaskPage(img, [right]);
      return _unionSelfConsistent(_overwriteUnion(img, [left, right]), a, b);
    },
    () => '绿=并集逐像素都能在单块里找到出处 / 故障=覆盖式实现丢掉笔画',
  );

  probe(
    'mask.all_zero_reports_empty',
    // 空白页上产出全 0 的 mask **是合法图像但是无意义产物**：FT 把"文件存在"
    // 当权威，写一个空的会把"还没产出"变成"没什么可抹"。
    () async {
      final img = _solid(48, 48, 0xFFFFFF);
      final mask = buildMaskPage(img, [IntRect(8, 8, 40, 40)]);
      return mask.isEmpty && mask.strokes == 0 && mask.pixels.every((v) => v == 0);
    },
    () async {
      final img = _pageWithGlyphs(64, 64, 20, 24, 24, 16);
      return buildMaskPage(img, [IntRect(16, 20, 48, 44)]).isEmpty;
    },
    () => '绿=纯白页 strokes=0 / 故障=真有字的页被判成空',
  );

  probe(
    'mask.no_pixels_written_outside_page',
    // 越界 region（用户把框拖到画布外、或工程坐标与图不符）不得让写入越界。
    () async {
      final img = _pageWithGlyphs(64, 64, 20, 24, 24, 16);
      return _maskGeometrySound(buildMaskPage(img, [IntRect(-40, -40, 200, 200)]));
    },
    () async {
      // 🔴 同一个判据喂给"页宽谎报"的一页：像素数与声明的几何不自洽。
      return _maskGeometrySound(
        MaskPage(64, 64, Uint8List(32 * 32), 1, 1),
      );
    },
    () => '绿=越界 region 仍产出 64x64 / 故障=尺寸谎报时判据会说谎',
  );

  probe(
    'mask.encode_roundtrips_geometry',
    // 🔴 **反向验证 PNG 真的能被解码**。用 zlib 之外的最强证据：从流里把
    // IHDR 的宽高读回来，并核对 IDAT 解压后的行数 —— 行数不对就是滤波字节
    // 少写了一行，而那正是手写 PNG 最容易犯的错。
    () async {
      final img = _pageWithGlyphs(64, 64, 20, 24, 24, 16);
      final mask = buildMaskPage(img, [IntRect(16, 20, 48, 44)]);
      final png = mask.encode();
      final w = _be32(png, 16);
      final h = _be32(png, 20);
      if (w != 64 || h != 64) return false;
      // 找 IDAT 并解压，核对总字节数 == h * (w + 1)（每行一个滤波字节）。
      var off = 8;
      while (off < png.length - 8) {
        final len = _be32(png, off);
        final type = String.fromCharCodes(png.sublist(off + 4, off + 8));
        if (type == 'IDAT') {
          final raw = ZLibCodec().decode(
            png.sublist(off + 8, off + 8 + len),
          );
          return raw.length == h * (w + 1);
        }
        off += 12 + len;
      }
      return false;
    },
    () async {
      final png = GrayPng.encode(64, 64, Uint8List(64 * 64));
      // 故障路径：假设"只写 h 行"也能过（即少写滤波字节那一版）。
      var off = 8;
      while (off < png.length - 8) {
        final len = _be32(png, off);
        final type = String.fromCharCodes(png.sublist(off + 4, off + 8));
        if (type == 'IDAT') {
          final raw = ZLibCodec().decode(
            png.sublist(off + 8, off + 8 + len),
          );
          // "少一行"那一版的行数：h * (w + 1) - (w + 1)。若判据对行数不敏感，
          // 这一条就会误判为通过。
          final oneRowShort = 64 * (64 + 1) - (64 + 1);
          return raw.length == oneRowShort;
        }
        off += 12 + len;
      }
      return false;
    },
    () => '绿=IDAT 解压后正好 h*(w+1) 字节 / 故障=少一行也判通过',
  );

  // ── 3 · 抹字复原 ─────────────────────────────────────────────────────

  probe(
    'restore.puts_original_pixels_back',
    () async {
      final original = _pageWithGlyphs(64, 64, 20, 24, 24, 16);
      final img = _pageWithGlyphs(64, 64, 20, 24, 24, 16);
      final mask = buildMaskPage(img, [IntRect(16, 20, 48, 44)]);
      // 模拟"已抹掉"：把掩膜处填成背景色。
      final inpainted = RgbaImage(
        64,
        64,
        Uint8List.fromList(img.pixels),
      );
      for (var i = 0; i < 64 * 64; i++) {
        if (mask.pixels[i] == 0) continue;
        final o = i * 4;
        inpainted.pixels[o] = 0xEE;
        inpainted.pixels[o + 1] = 0xEE;
        inpainted.pixels[o + 2] = 0xEE;
      }
      final out = restoreErasedPage(
        original: original,
        inpainted: inpainted,
        mask: mask.pixels,
      );
      if (out == null) return false;
      // 掩膜处必须回到原图的**黑**。
      final centre = 32 * 64 + 32;
      final o = centre * 4;
      return out[o] == 0 && out[o + 1] == 0 && out[o + 2] == 0;
    },
    () async {
      // 故障路径 = **不**写回（即"复原"什么都没做）。
      final original = _pageWithGlyphs(64, 64, 20, 24, 24, 16);
      final inpainted = _solid(64, 64, 0xEEEEEE);
      final img = _pageWithGlyphs(64, 64, 20, 24, 24, 16);
      final mask = buildMaskPage(img, [IntRect(16, 20, 48, 44)]);
      final out = restoreErasedPage(
        original: original,
        inpainted: inpainted,
        mask: mask.pixels,
      );
      if (out == null) return false;
      final centre = 32 * 64 + 32;
      final o = centre * 4;
      return out[o] == 0xEE;
    },
    () => '绿=掩膜处回到原图的黑 / 故障=原样返回抹过的底图',
  );

  probe(
    'restore.leaves_unmasked_pixels_alone',
    () async {
      final original = _pageWithGlyphs(64, 64, 20, 24, 24, 16);
      final inpainted = _solid(64, 64, 0xEEEEEE);
      final img = _pageWithGlyphs(64, 64, 20, 24, 24, 16);
      final mask = buildMaskPage(img, [IntRect(16, 20, 48, 44)]);
      final out = restoreErasedPage(
        original: original,
        inpainted: inpainted,
        mask: mask.pixels,
      );
      if (out == null) return false;
      // (0,0) 不在掩膜里 ⇒ 必须仍是抹过的底图色。
      return out[0] == 0xEE && out[1] == 0xEE && out[2] == 0xEE;
    },
    () async {
      // 故障路径 = 无脑整张还原（掩膜全 255）：(0,0) 也被换成了原图的白色。
      final original = _pageWithGlyphs(64, 64, 20, 24, 24, 16);
      final out = restoreErasedPage(
        original: original,
        inpainted: _solid(64, 64, 0xEEEEEE),
        mask: Uint8List(64 * 64)..fillRange(0, 64 * 64, 255),
      );
      // 判据：掩膜外**保持原样**。无脑还原让它变成白色 ⇒ false ⇒ 判据变红。
      return out != null && out[0] == 0xEE && out[1] == 0xEE && out[2] == 0xEE;
    },
    () => '绿=掩膜外保持原样 / 故障=整张被覆盖',
  );

  probe(
    'restore.rejects_mismatched_geometry',
    // 🔴 尺寸不符时**返回 null**而不是拉伸：拉伸会产出一张"位置全错却不报错"
    // 的底图，比报错糟得多。
    () async {
      final out = restoreErasedPage(
        original: _solid(64, 64, 0xFFFFFF),
        inpainted: _solid(32, 32, 0xFFFFFF),
        mask: Uint8List(64 * 64),
      );
      return out == null;
    },
    () async {
      return restoreErasedPage(
            original: _solid(64, 64, 0xFFFFFF),
            inpainted: _solid(64, 64, 0xFFFFFF),
            mask: Uint8List(64 * 64),
          ) !=
          null;
    },
    () => '绿=32x32 底图配 64x64 原图 → null / 故障=同尺寸却返回 null',
  );

  probe(
    'restore.all_zero_mask_returns_null',
    // 全 0 掩膜 = 什么都没抹 ⇒ 无可复原，返回 null 让调用方记 skipped。
    () async {
      return restoreErasedPage(
            original: _solid(32, 32, 0xFFFFFF),
            inpainted: _solid(32, 32, 0xEEEEEE),
            mask: Uint8List(32 * 32),
          ) ==
          null;
    },
    () async {
      final m = Uint8List(32 * 32)..[100] = 255;
      return restoreErasedPage(
            original: _solid(32, 32, 0xFFFFFF),
            inpainted: _solid(32, 32, 0xEEEEEE),
            mask: m,
          ) ==
          null;
    },
    () => '绿=全 0 掩膜 → null / 故障=有一个前景像素时也 null',
  );

  probe(
    'restore.does_not_mutate_inputs',
    // 调用方可能还要留着 inpainted/ 做前后对比，函数悄悄改入参会让对比失效。
    () async {
      final inpainted = _solid(16, 16, 0xEEEEEE);
      final before = Uint8List.fromList(inpainted.pixels);
      final m = Uint8List(16 * 16)..[5] = 255;
      restoreErasedPage(
        original: _solid(16, 16, 0xFFFFFF),
        inpainted: inpainted,
        mask: m,
      );
      for (var i = 0; i < before.length; i++) {
        if (inpainted.pixels[i] != before[i]) return false;
      }
      return true;
    },
    () async {
      final inpainted = _solid(16, 16, 0xEEEEEE);
      final m = Uint8List(16 * 16)..[5] = 255;
      restoreErasedPage(
        original: _solid(16, 16, 0xFFFFFF),
        inpainted: inpainted,
        mask: m,
      );
      return inpainted.pixels[5 * 4] == 0xFF;
    },
    () => '绿=入参逐字节不变 / 故障=入参被就地改写',
  );

  // ── 3.5 · buildRestorationMask（2026-10-09 续 · 复原掩膜外扩） ─────────

  probe(
    'restore.mask_dilates_by_default_30_percent',
    // 默认 dilation=1.3 → 宽高各扩 15% → 面积扩 69%（≥30%）。
    // 判据：dilated 版本的前景像素数 ≥ 原块版本的 * 1.1（留余量）。
    () async {
      final img = _pageWithGlyphs(64, 64, 26, 26, 12, 12);
      final rect = IntRect(24, 24, 36, 36);
      final originalMask = buildMaskPage(img, [rect]);
      final dilatedMask = buildRestorationMask(img, rect);
      // 数 dilated 掩膜里前景像素数
      var dilatedCount = 0;
      for (final p in dilatedMask) {
        if (p > 0) dilatedCount++;
      }
      return dilatedCount >= originalMask.strokes * 1.1;
    },
    () async {
      final img = _pageWithGlyphs(64, 64, 26, 26, 12, 12);
      final rect = IntRect(24, 24, 36, 36);
      final originalMask = buildMaskPage(img, [rect]);
      // 故障路径 = dilation 被写成 1.0（根本没扩）
      final noDilateMask = buildRestorationMask(img, rect, dilation: 1.0);
      var count = 0;
      for (final p in noDilateMask) {
        if (p > 0) count++;
      }
      return count >= originalMask.strokes * 1.1;
    },
    () => '绿=dilated 掩膜前景 ≥ 原块 * 1.1 / 故障=dilation=1.0 没扩也被判成≥1.1',
  );

  probe(
    'restore.mask_clamps_to_image_boundary',
    // 块紧贴图像左边缘 → 外扩后左边界被夹到 0，不是负数。
    // 判据：掩膜尺寸正确（= 整页），且前景像素分布在图像内（不是夹取后全空）。
    () async {
      final img = _pageWithGlyphs(32, 32, 0, 14, 8, 4);
      final rect = IntRect(2, 14, 10, 18);
      final m = buildRestorationMask(img, rect);
      // 尺寸必须是整页
      if (m.length != 32 * 32) return false;
      // 必须有前景像素（边界 clamp 不该把所有前景吞掉）
      var hasForeground = false;
      for (final p in m) {
        if (p > 0) { hasForeground = true; break; }
      }
      return hasForeground;
    },
    () async {
      final img = _pageWithGlyphs(32, 32, 0, 14, 8, 4);
      final rect = IntRect(2, 14, 10, 18);
      // 故障路径 = 不 clamp，让外扩越过边界 → 可能抛异常或返回尺寸不对的掩膜
      // 用 dilation=5.0 强制大幅外扩，测试 clamp 是否真的在工作
      final m = buildRestorationMask(img, rect, dilation: 5.0);
      return m.length != 32 * 32;
    },
    () => '绿=尺寸正确 + 有前景 / 故障=外扩越过边界后尺寸不对（clamp 没生效）',
  );

  probe(
    'restore.mask_polarity_is_255',
    // 极性必须与 buildMaskPage 一致：255 = 被掩（需要恢复的像素）。
    () async {
      final img = _pageWithGlyphs(32, 32, 10, 10, 12, 8);
      final rect = IntRect(8, 8, 20, 16);
      final m = buildRestorationMask(img, rect);
      // 至少有一个前景像素是 255（不是 1 或其他值）
      for (final p in m) {
        if (p == 255) return true;
        if (p > 0 && p != 255) return false;
      }
      return false; // 全 0 也算 false，至少要有一点前景
    },
    () async {
      final img = _pageWithGlyphs(32, 32, 10, 10, 12, 8);
      final rect = IntRect(8, 8, 20, 16);
      // 故障路径 = 返回的是反极性（0=被掩，255=保留）
      final m = buildRestorationMask(img, rect);
      var hasForeground = false;
      for (final p in m) {
        if (p == 255) hasForeground = true;
      }
      return !hasForeground; // 反极性的话应该没有 255
    },
    () => '绿=前景像素是 255 / 故障=极性反了（前景不是 255）',
  );

  // ── 3.6 · 单块修图/复原的像素合并（block_artifacts.dart） ────────────
  //
  // 这一层没有 dart:ui，全部可 headless 验。夹具思想：现有底图涂成"蓝色页"
  // （代表同页其他块已抹好的像素），新擦的块给出一个红色哨兵像素 —— 合并只能
  // 在掩膜像素上替换，块外必须保持蓝色。

  /// 造一张纯色 RGBA 图，再把 [paintAt] 里的像素索引涂成 [rgb]。
  RgbaImage painted(
    int w,
    int h,
    int base,
    Map<int, int> paintAt,
  ) {
    final img = _solid(w, h, base);
    paintAt.forEach((idx, rgb) {
      final i = idx * 4;
      img.pixels[i] = (rgb >> 16) & 0xFF;
      img.pixels[i + 1] = (rgb >> 8) & 0xFF;
      img.pixels[i + 2] = rgb & 0xFF;
      img.pixels[i + 3] = 0xFF;
    });
    return img;
  }

  probe(
    'blockrepair.merge_pastes_only_inside_mask',
    // 绿=只在掩膜像素上换成新擦值（红），块外保留现有底图（蓝，=其他块）。
    () async {
      const w = 8, h = 8;
      final erased = painted(w, h, 0xFFFFFF, {10: 0xFF0000});
      final existing = _solid(w, h, 0x0000FF);
      final mask = Uint8List(w * h)..[10] = 255;
      final out = mergeRepairedInpainted(
        erasedBlock: erased,
        blockMask: mask,
        existingInpainted: existing,
      );
      if (out == null) return false;
      final redAtMask = out[10 * 4] == 0xFF &&
          out[10 * 4 + 1] == 0x00 &&
          out[10 * 4 + 2] == 0x00;
      final blueElsewhere = out[11 * 4] == 0x00 &&
          out[11 * 4 + 2] == 0xFF;
      return redAtMask && blueElsewhere;
    },
    // 故障=整页覆盖（直接用 erasedBlock）→ 块外从蓝变白，其他块被抹回来。
    () async {
      const w = 8, h = 8;
      final erased = painted(w, h, 0xFFFFFF, {10: 0xFF0000});
      final existing = _solid(w, h, 0x0000FF);
      final mask = Uint8List(w * h)..[10] = 255;
      // 模拟"覆盖式"错误实现：无视掩膜，整张换成新擦图。
      final out = Uint8List.fromList(erased.pixels);
      final keptOtherBlock = out[11 * 4 + 2] == 0xFF &&
          out[11 * 4] == 0x00;
      return keptOtherBlock; // 错误实现这里应为 false（白底，不是蓝）
    },
    () => '绿=掩膜处换红、块外保蓝（其他块不丢）/ 故障=整页覆盖把其他块抹回原图',
  );

  probe(
    'blockrepair.merge_first_repair_equals_erased_block',
    // 绿=没有现有底图时，输出就是"只擦了这一块"的整页图（逐字节）。
    () async {
      final erased = painted(8, 8, 0xFFFFFF, {10: 0xFF0000});
      final mask = Uint8List(64)..[10] = 255;
      final out = mergeRepairedInpainted(
        erasedBlock: erased,
        blockMask: mask,
      );
      if (out == null || out.length != erased.pixels.length) return false;
      for (var i = 0; i < out.length; i++) {
        if (out[i] != erased.pixels[i]) return false;
      }
      return true;
    },
    // 故障=错误地返回了原图（抹字丢失）：位置 10 的 G 通道，红哨兵=0、
    // 白底原图=255 —— 同一性质（输出必须逐字节等于新擦图）在故障片段上为假。
    () async {
      final erased = painted(8, 8, 0xFFFFFF, {10: 0xFF0000});
      final original = _solid(8, 8, 0xFFFFFF);
      return original.pixels[10 * 4 + 1] == erased.pixels[10 * 4 + 1];
    },
    () => '绿=首次修图输出=新擦图 / 故障=输出原图（抹字白做）',
  );

  probe(
    'blockrepair.merge_rejects_mismatched_geometry',
    // 绿=现有底图尺寸不一致 → null（不许拉伸套图）。
    () async {
      final out = mergeRepairedInpainted(
        erasedBlock: _solid(8, 8, 0xFFFFFF),
        blockMask: Uint8List(64),
        existingInpainted: _solid(4, 4, 0xEEEEEE),
      );
      return out == null;
    },
    // 故障=同尺寸合法输入也返回 null。
    () async {
      final out = mergeRepairedInpainted(
        erasedBlock: _solid(8, 8, 0xFFFFFF),
        blockMask: Uint8List(64),
        existingInpainted: _solid(8, 8, 0xEEEEEE),
      );
      return out == null;
    },
    () => '绿=尺寸不符 → null / 故障=同尺寸也 null',
  );

  probe(
    'blockrepair.union_keeps_existing_only_pixels',
    // 绿=并集保留"只在旧掩膜里"的像素（=其他块的抹字记录）。
    () async {
      final existing = Uint8List(64)
        ..[1] = 255
        ..[2] = 255;
      final added = Uint8List(64)
        ..[2] = 255
        ..[3] = 255;
      final u = unionMasks(added: added, existing: existing);
      return u[1] == 255 && u[2] == 255 && u[3] == 255 && u[4] == 0;
    },
    // 故障=覆盖式并集（后写覆盖）→ 旧块独占的像素 1 被清零。
    () async {
      final existing = Uint8List(64)
        ..[1] = 255
        ..[2] = 255;
      final added = Uint8List(64)
        ..[2] = 255
        ..[3] = 255;
      final overwrite = Uint8List.fromList(added); // 无视 existing
      return overwrite[1] == 255 && overwrite[3] == 255;
    },
    () => '绿=旧块独占像素保留 / 故障=覆盖式把旧块记录清掉',
  );

  probe(
    'blockrepair.subtract_and_intersect_are_scoped',
    // subtract: {1,2} - {2} = {1}；intersect: 外扩检测 ∩ 实际抹除 = 只盖真抹的。
    () async {
      final from = Uint8List(64)
        ..[1] = 255
        ..[2] = 255;
      final removed = Uint8List(64)..[2] = 255;
      final s = subtractMasks(from: from, removed: removed);
      if (s[1] != 255 || s[2] != 0) return false;

      // 复原场景：位置 4 的字形属于交叠的另一个块、没被抹过（不在 existing
      // 里）；位置 5 两者都在。取交后 4 必须为 0，5 必须为 255。
      final dilated = Uint8List(64)
        ..[4] = 255
        ..[5] = 255;
      final erased = Uint8List(64)..[5] = 255;
      final hit = intersectMasks(dilated, erased);
      return hit[4] == 0 && hit[5] == 255;
    },
    // 故障=复原直接用外扩掩膜（不取交）→ 交叠块位置 4 也被盖回。
    () async {
      final dilated = Uint8List(64)
        ..[4] = 255
        ..[5] = 255;
      final erased = Uint8List(64)..[5] = 255;
      final hit = intersectMasks(dilated, erased);
      return hit[4] == 255; // 正确实现下必须为 false
    },
    () => '绿=扣除精准/取交只盖真抹像素 / 故障=误伤交叠块或扣多了',
  );

  // ── 4 · S-N1 · 裁剪窗口 ──────────────────────────────────────────────

  probe(
    'crop.grows_tiny_blocks_to_min_side',
    // 30x20 的块按原框裁，OCR 在上面什么都认不出来。
    () async {
      final c = StudioBlockOps.cropWindow([100, 100, 130, 120], 1000, 1000);
      return c != null && c.width >= StudioBlockOps.minCropSide &&
          c.height >= StudioBlockOps.minCropSide;
    },
    () async {
      // 故障路径 = 不放大（正是早期实现）。
      final c = StudioBlockOps.cropWindow(
        [100, 100, 130, 120],
        1000,
        1000,
        minSide: 0,
      );
      return c != null && c.width >= StudioBlockOps.minCropSide;
    },
    () => '绿=短边被撑到 minSide / 故障=minSide=0 时同样撑大',
  );

  probe(
    'crop.keeps_block_inside_window',
    () async {
      const box = [100.0, 100.0, 130.0, 120.0];
      return _windowCoversBlock(
        StudioBlockOps.cropWindow(box, 1000, 1000),
        box,
      );
    },
    () async {
      // 🔴 同一个判据喂给"先夹后放"的等价物，块选一个**越界**的：
      // 先夹到页内（右边从 1010 被截到 1000），再向两侧放大到 96 —— 左侧有空间、
      // 右侧没有，窗口偏心且右边被截。正确实现（先放后夹）不会。
      const box = [996.0, 400.0, 1010.0, 406.0];
      return _windowCoversBlock(_clampThenGrow(box, 1000, 1000), box);
    },
    () => '绿=窗口包住整个块（含越界块）/ 故障=先夹后放把越界侧截掉',
  );

  probe(
    'crop.stays_inside_the_page',
    () async {
      final c = StudioBlockOps.cropWindow([-40, -40, 500, 500], 200, 200)!;
      return c.left >= 0 &&
          c.top >= 0 &&
          c.right <= 200 &&
          c.bottom <= 200;
    },
    () async {
      // 故障路径：放大时只朝右下长，越界。
      final c = StudioBlockOps.cropWindow([0, 0, 190, 190], 200, 200)!;
      return c.right > 200 || c.bottom > 200;
    },
    () => '绿=窗口不越页 / 故障=越界',
  );

  probe(
    'crop.degenerate_box_is_rejected',
    // 🔴 不能返回"夹到角落的 1x1"：那会让 OCR 白跑一趟，而真实原因是块
    // 坐标坏了 —— 用户只会看到"点了没反应"。
    () async {
      return StudioBlockOps.cropWindow([100, 100, 100, 100], 800, 800) == null &&
          StudioBlockOps.cropWindow([100, 100, 90, 120], 800, 800) == null;
    },
    () async {
      return StudioBlockOps.cropWindow([100, 100, 130, 120], 800, 800) == null;
    },
    () => '绿=零宽/倒序框 → null / 故障=合法框也 null',
  );

  probe(
    'crop.converts_back_to_page_coordinates',
    // 🔴 写窗口内坐标 = 文字被挪到块的左上角，而界面不报错。
    () async {
      const box = [200.0, 300.0, 260.0, 360.0];
      final c = StudioBlockOps.cropWindow(box, 2000, 2000)!;
      final page = StudioBlockOps.toPageCoords(c, [0, 0, 10, 10]);
      return page[0] == c.left &&
          page[1] == c.top &&
          page[2] == c.left + 10 &&
          page[3] == c.top + 10;
    },
    () async {
      // 故障路径 = 原样返回窗口内坐标。
      final c = StudioBlockOps.cropWindow([200, 300, 260, 360], 2000, 2000)!;
      return StudioBlockOps.toPageCoords(c, [0, 0, 10, 10])[0] == 0;
    },
    () => '绿=加回窗口偏移 / 故障=没加（局部坐标直接写进块）',
  );

  // ── 5 · S-N1 · 写回判据 ──────────────────────────────────────────────

  probe(
    'write.empty_translation_never_overwrites',
    // 🔴 本项目最忌讳的静默数据损失：模型回空 ⇒ 把用户手工校对好的译文抹掉。
    () async {
      return !StudioTranslateOps.shouldApply(
        '',
        currentTranslation: '我手工校对过的译文',
      ) && !StudioTranslateOps.shouldApply(
        '   \n ',
        currentTranslation: '我手工校对过的译文',
      );
    },
    () async {
      return !StudioTranslateOps.shouldApply(
        '新译文',
        currentTranslation: '我手工校对过的译文',
      );
    },
    () => '绿=空结果拒绝 / 故障=有内容时也拒绝',
  );

  probe(
    'write.echo_of_current_translation_is_rejected',
    // 模型把原文回声一遍，写回去会让人以为按钮生效了。
    () async {
      return !StudioTranslateOps.shouldApply(
        '我手工校对过的译文',
        currentTranslation: '我手工校对过的译文',
      );
    },
    () async {
      return !StudioTranslateOps.shouldApply(
        '换了内容',
        currentTranslation: '我手工校对过的译文',
      );
    },
    () => '绿=逐字相同拒绝 / 故障=真换了内容也拒绝',
  );

  probe(
    'write.echo_of_source_is_rejected',
    () async {
      return !StudioTranslateOps.shouldApply(
        '今天的天气很好',
        currentTranslation: '',
        currentSource: '今天的天气很好',
      );
    },
    () async {
      return !StudioTranslateOps.shouldApply(
        '今天天气不错',
        currentTranslation: '',
        currentSource: '今天的天气很好',
      );
    },
    () => '绿=与原文逐字相同拒绝 / 故障=真译文也拒绝',
  );

  probe(
    'write.allows_translation_when_source_was_cleared',
    // 用户手工清空原文、只想让模型按位置猜一次 ⇒ 这条路不能被"与原文相同"
    // 堵死（此时两者必然相等）。
    () async {
      return StudioTranslateOps.shouldApply(
        '模型猜的译文',
        currentTranslation: '',
        currentSource: '',
      );
    },
    () async {
      // 故障路径 = 把"与原文相同也拒绝"这条规则**不**做例外：原文为空时
      // incoming 必然等于 currentSource，于是被拒 ⇒ 判据变红。
      final incoming = '模型猜的译文';
      final text = incoming.trim();
      if (text.isEmpty) return true;
      if (text == ''.trim()) return true;
      return false;
    },
    () => '绿=原文为空时允许写入 / 故障=此时空结果也允许',
  );

  probe(
    'write.recognise_empty_text_is_failure',
    // 空结果判 FAIL，不判"成功但没文字" —— 否则用户以为按钮坏了。
    () async {
      return !StudioBlockOps.isRecognised('') && !StudioBlockOps.isRecognised('  \n');
    },
    () async => !StudioBlockOps.isRecognised('こんにちは'),
    () => '绿=空白判失败 / 故障=有字也判失败',
  );

  probe(
    'write.multiline_source_is_preserved',
    // FT 的块是多行的，合成一行就没法逐行校对。
    () async {
      final joined = StudioTranslateOps.joinLines(['  A  ', '', 'B', '   ']);
      return joined == 'A\nB';
    },
    () async => StudioTranslateOps.joinLines(['A', 'B']) == 'A B',
    () => '绿=按行保留换行 / 故障=被压成一行',
  );

  // ── 6 · 接线（静态扫描 + 对照组） ─────────────────────────────────────

  probe(
    'wiring.region_ocr_exists_and_is_not_the_page_path',
    // 🔴 把按钮接到 `ocrPage` 上"能跑但是错的"：重检测全页 + 重投语言票。
    () async =>
        codeHas(_pipelinePath, 'ocrRegion') &&
        !RegExp(
          r'Future<List<OcrBlock>> ocrRegion[\s\S]{0,400}?ocrPage\(',
        ).hasMatch(code(_pipelinePath).replaceAll('ocrRegion(', 'ocrPage(')),
    () async {
      // 对照组：`analyzePage` 确实**内部**调 `ocrPage`，而 `ocrRegion` 不调。
      // 判据反过来问"analyzePage 那一段有没有 ocrPage" —— 它必须为 true，
      // 说明这条正则有能力在该出现的地方匹配出来，因此 ocrRegion 处的
      // 不匹配是真结论而不是正则失灵。
      final src = code(_pipelinePath);
      final m = RegExp(
        r'(Future<PageAnalysis> analyzePage[\s\S]{0,600}?)\n  [A-Za-z]',
      ).firstMatch(src);
      if (m == null) return false;
      return m.group(1)!.contains('ocrPage(');
    },
    () => '绿=ocrRegion 不走 ocrPage / 故障=analyzePage 那个对照组会匹配',
  );

  probe(
    'wiring.buttons_sit_on_the_requested_sides',
    // 用户 2026-10-08 明确：【识别】在原文框**左**、【翻译】在译文框**右**。
    () async {
      final panel = code(_panelPath);
      final recognise = panel.indexOf("Recognise this block again");
      final translate = panel.indexOf("Translate this block again");
      if (recognise < 0 || translate < 0) return false;
      // 两个动作各自在自己的 Row/输入框装饰里出现，且顺序是
      // 识别在前、翻译在后（面板自上而下 = 原文在译文之上）。
      return recognise < translate;
    },
    () async {
      final panel = code(_panelPath);
      return panel.indexOf("Translate this block again") <
          panel.indexOf("Recognise this block again");
    },
    () => '绿=识别在译文之前（原文框左侧 / 译文框右侧） / 故障=顺序颠倒',
  );

  probe(
    'wiring.buttons_use_builtin_icons',
    // 用户要求"借用 flutter 创建图标" ⇒ `Icons.*`，不引第三方字体图标。
    () async {
      final panel = code(_panelPath);
      return panel.contains('Icons.text_fields') && panel.contains('Icons.translate');
    },
    () async => code(_panelPath).contains('Icons.looks_one'),
    () => '绿=用 Icons.text_fields / Icons.translate / 故障=换成别的图标名',
  );

  probe(
    'wiring.both_actions_are_repeatable_not_one_shot',
    // 🔴 定义在 2026-10-08 被修订过：不是"建块自动识别"、不是"二次识别"。
    // 判据钉住"面板从不自动触发 OCR"——即 build() 里没有 onRecognise() 调用。
    () async {
      final panel = code(_panelPath);
      // 出现的是回调**传参**（onRecognise: widget.onRecognise），
      // 而不是调用（onRecognise()）。
      return !RegExp(r'onRecognise\(\)').hasMatch(panel) &&
          !RegExp(r'onTranslate\(\)').hasMatch(panel);
    },
    () async => RegExp(r'onRecognise\(\)').hasMatch(code(_panelPath)),
    () => '绿=面板从不自动调 / 故障=build 里真的调了',
  );

  probe(
    'wiring.mask_is_produced_by_the_save_path',
    // 🔴 S9 的老问题：`mask/` 有目录无内容，且**不报错**。判据是保存链路里
    // 真的有 mask 的产出源，而不是靠"目录建出来了"。
    () async {
      final studio = code(_studioPath);
      return studio.contains('ProjectArtifactKind.mask') &&
          studio.contains('renderMaskPage');
    },
    () async {
      // 对照组：只建目录、不产出内容（这正是 S9 的真实状态）。
      final studio = code(_studioPath);
      return studio.contains('ProjectArtifactKind.mask') &&
          !studio.contains('renderMaskPage');
    },
    () => '绿=保存时产出 mask / 故障=只建目录不产出（S9 的假绿）',
  );

  probe(
    'wiring.result_still_renders_in_a_second_pass',
    // 🔴 顺序契约：`result/` 以 `inpainted/` 为**输入**位图，与它放进同一次
    // 并发调用就会读到还没写出来的底图。这个契约现在有**五处**落点必须同时
    // 成立：整页修图（`_regenerateResults` 的 inLayeredOrder 两阶段）+ 单块
    // 修图 + 单块复原（都是先写 inpainted 再 await _rerenderResultPage）+
    // B-5 跨页块修图 / 跨页块复原（逐页循环，同样先写后画；复原的 inpainted
    // 落盘在 `_restoreSpanParts` 里，调用点仍在其后）。
    () async {
      final studio = code(_studioPath);
      bool basesBeforeResult(String text) {
        final bases = text.indexOf('ProjectArtifactKind.inpainted');
        final result = text.indexOf('ProjectArtifactKind.result');
        return bases > 0 && result > bases;
      }

      // (1) 整页修图：方法体窗口内 inpainted 先于 result。
      final start = studio.indexOf(
        'Future<(int, int)> _regenerateResults',
      );
      final end = studio.indexOf('void _openGlossary()', start);
      if (start < 0 || end < 0) return false;
      if (!basesBeforeResult(studio.substring(start, end))) return false;

      // (2) 块级四条路径（单块修图 / 单块复原 / B-5 跨页修图 / B-5 跨页复原）：
      // 每次重画调用与上一次调用之间必须夹着一次 inpainted 落盘
      //（=底图先写、result 后画），且一共四次调用。
      const call = 'await _rerenderResultPage(project, root, pageKey);';
      var from = 0;
      var calls = 0;
      while (true) {
        final at = studio.indexOf(call, from);
        if (at < 0) break;
        final prevInpainted =
            studio.lastIndexOf('ProjectArtifactKind.inpainted', at);
        final prevCall = studio.lastIndexOf(call, at - 1);
        if (prevInpainted < 0 || prevInpainted < prevCall) return false;
        calls++;
        from = at + call.length;
      }
      return calls == 4;
    },
    // 故障路径 = 合成的反序片段（result 在前、inpainted 在后），同一判据必须
    // 判它为 false —— 否则判据对"写反顺序"毫无分辨力。
    () async {
      final faulty = 'write ProjectArtifactKind.result first, '
          'then ProjectArtifactKind.inpainted';
      final bases = faulty.indexOf('ProjectArtifactKind.inpainted');
      final result = faulty.indexOf('ProjectArtifactKind.result');
      return bases > 0 && result > bases;
    },
    () => '绿=三处落点都是 inpainted 先 / result 后 / 故障=反序片段也判通过',
  );

  probe(
    'wiring.mask_avoids_the_rendering_surface',
    // 🔴 走 `dart:ui` 的 mask 生产在本会话**无法验证**（`Picture.toImage`
    // 需要渲染表面）。纯 Dart 是它能被断言钉住的前提。
    () async {
      return !importsUi(packageRoot,
              'lib/foundation/translation_project/gray_png.dart') &&
          !importsUi(packageRoot,
              'lib/foundation/translation_project/mask_producer.dart');
    },
    () async {
      // 🔴 同一个判据喂给渲染器：它**真的** import 了 `dart:ui`，
      // 于是"这两个文件都不 import"对它为 false ⇒ 判据变红。
      return !importsUi(packageRoot, _rendererPath);
    },
    () => '绿=PNG 编码与 mask 拼装都不碰 dart:ui / 故障=渲染器对照组确实碰',
  );

  probe(
    'i18n.new_strings_are_registered_in_chinese',
    // 用户反复踩过的坑：新按钮显示英文。这里逐条核对**登记的值**是中文，
    // 而不只是"键存在"。
    () async {
      const expected = {
        'Recognise this block again': '重新识别这一块',
        'Translate this block again': '重新翻译这一块',
        'This block has no usable box.': '这一块的边框坐标无效，无法识别。',
        'Recognise failed: no text found.': '识别失败：这一块里没认出文字。',
        'Translate returned nothing new.': '翻译没有返回新内容，原译文已保留。',
        'This block has no source text.': '这一块还没有原文，无法翻译。',
      };
      for (final e in expected.entries) {
        if (zhCn[e.key] != e.value) return false;
      }
      return true;
    },
    () async => zhCn['Recognise this block again'] == 'Recognise this block again',
    () => '绿=逐条中文值一致 / 故障=表里存英文原文',
  );

  probe(
    'i18n.panel_literals_are_all_registered',
    // 空结果判 FAIL（见 M10）：必须确认扫描器**真的扫到了**这个文件。
    //
    // 🔴 判据是两件事的**合取**：① 扫到至少一条（否则扫描器坏了，这条断言会因为“没找到未登记项”而假绿）；② 一条未登记都没有。上一版把①写成了“
    // missing 非空才通过”，于是判据与意图完全相反。
    () async {
      final file = File('${packageRoot.path}/$_panelPath');
      final total = tlLiteralKeys(file.readAsStringSync()).length;
      final missing = tlLiterals(packageRoot, _panelPath, zhCn);
      return total > 0 && missing.isEmpty;
    },
    () async {
      final file = File('${packageRoot.path}/$_panelPath');
      final total = tlLiteralKeys(file.readAsStringSync()).length;
      // 🔴 故障路径 = **同一个判据**喂给一张缺了键的表。删掉面板里真实用到
      // 的任何一个键，那条字面量立刻变成"未登记" ⇒ 判据变红。
      //
      // 上一版写的是"表为空 ⇒ 全部未登记"，那是**另一个命题**：它成立只说明
      // 空表会把所有键报成未登记，而判据（扫到 >0 ∧ 未登记为空）对空表同样
      // 为 false —— 恰好蒙对，但换个表规模就可能不再成立。
      final trimmed = Map<String, dynamic>.from(zhCn)..remove('Apply');
      final missing = <String>[];
      for (final key in tlLiteralKeys(file.readAsStringSync())) {
        if (key.length <= 2) continue;
        if (!trimmed.containsKey(key) && !missing.contains(key)) {
          missing.add(key);
        }
      }
      return total > 0 && missing.isEmpty;
    },
    () => '绿=扫到 >0 条且未登记为空 / 故障=拿掉一个在用的键后判据变红',
  );

  probe(
    'i18n.no_replacement_chars_in_the_table',
    // 本轮真的踩到：写 JSON 时一个「原」字被写成了替换字符 U+FFFD，
    // 界面会显示成"这一页的?图不在"。全表扫一遍比逐条肉眼可靠。
    () async {
      for (final table in (jsonDecode(code(_tablePath)) as Map).values) {
        for (final entry in (table as Map).entries) {
          if ('$entry'.contains('�')) return false;
        }
      }
      return true;
    },
    // 故障路径：把一个替换字符塞进表里（正是本轮真的踩到的那种损坏）。
    () async => zhCn.values.any((v) => '$v'.contains('�')),
    () => '绿=全表无 U+FFFD / 故障=塞一个替换字符',
  );

  // ── 7 · 拟声词标记（P10.15 §4.5 · 序6） ───────────────────────────────
  //
  // 🔴 这一组钉住的是**判据的窄度**，不是"能识别拟声词"。误标的代价是"一句真
  // 对白默认不译"（要人点一下才回来），漏标的代价只是"多问一次模型" —— 两者
  // 不对称，所以每一条断言都在问"它有没有**多标**"。

  probe(
    'sfx.marks_short_uppercase_latin',
    // 漫画拟声词的书写惯例是全大写（`BAM` / `SLAM!` / `THUD`）。
    () async {
      final sfx = StudioSfxOps.looksLikeSfx;
      return sfx('BAM', language: 'en') &&
          sfx('SLAM!', language: 'en') &&
          sfx('THUD', language: 'en') &&
          sfx('KRAK', language: 'EN');
    },
    // 故障：混合大小写的短对白也被标 —— `No` / `Hi` / `Hello` 是**台词**，
    // 标了就永久不译。
    () async {
      final sfx = StudioSfxOps.looksLikeSfx;
      return sfx('No', language: 'en') &&
          sfx('Hi', language: 'en') &&
          sfx('Hello', language: 'en');
    },
    () => '绿=全大写短串判 sfx / 故障=混合大小写的对白也被判 sfx',
  );

  probe(
    'sfx.marks_single_syllable_hangul',
    // 🔴 只收**单音节**：两音节就分不出拟声词与台词（「두근」vs「안녕」字数相同）。
    () async {
      final sfx = StudioSfxOps.looksLikeSfx;
      return sfx('쿵', language: 'ko') &&
          sfx('쾅', language: 'ko') &&
          sfx('퍽', language: 'ko');
    },
    // 故障：把韩文**台词**也当拟声词（2 音节是这条线上最危险的一档）。
    () async {
      final sfx = StudioSfxOps.looksLikeSfx;
      return sfx('안녕', language: 'ko') ||
          sfx('두근', language: 'ko') ||
          sfx('사랑해', language: 'ko');
    },
    () => '绿=单音节韩文拟声词 / 故障=2 音节以上的韩文台词被当成拟声词',
  );

  probe(
    'sfx.never_marks_a_cjk_source',
    // 🔴 中日文的短句（「嗯」「你好」）是正常对白；日语拟声词走的是竖排那条
    // 启发式（§4.5 第一段），不该在这里再抢一次。判据必须**认源语言**。
    () async {
      final sfx = StudioSfxOps.looksLikeSfx;
      return ['你好', '嗯', 'ドン', 'こんにちは', 'SLAM', 'BAM']
          .every((t) => !sfx(t, language: 'zh') && !sfx(t, language: 'ja'));
    },
    // 故障：忽略源语言 ⇒ 中文页上的 `SLAM` 也被标成拟声词。
    () async => StudioSfxOps.looksLikeSfx('SLAM', language: 'zh'),
    () => '绿=zh/ja 源一律不标 / 故障=忽略源语言时中文页的 SLAM 被标',
  );

  probe(
    'sfx.punctuation_only_is_not_sfx',
    // `!!` / `???` / `…` 没有可读的字母，标了只会让用户以为这里有东西。
    () async {
      final sfx = StudioSfxOps.looksLikeSfx;
      return ['!!!', '???', '…', '--', '*'].every(
        (t) => !sfx(t, language: 'en') && !sfx(t, language: 'ko'),
      );
    },
    () async => StudioSfxOps.looksLikeSfx('!!!', language: 'en'),
    () => '绿=纯符号不判 sfx / 故障=纯符号被判 sfx',
  );

  probe(
    'sfx.label_roundtrips_and_starts_unset',
    // 🔴 [createDefault] 本来就写 `label: null`（FT 的 23 键之一），所以"没被
    // 标记"与"标记过又清掉"在 json 里是同一个形状 —— 零字节 diff 不受影响。
    () async {
      final block = TextBlock.createDefault(rect: IntRect(0, 0, 10, 10));
      final keyExists = block.raw.containsKey('label');
      final unset = block.label == null && !StudioSfxOps.isMarkedSfx(block);
      block.label = StudioSfxOps.label;
      final marked = StudioSfxOps.isMarkedSfx(block);
      block.label = null;
      final cleared = block.label == null &&
          !StudioSfxOps.isMarkedSfx(block) &&
          block.raw['label'] == null;
      return keyExists && unset && marked && cleared;
    },
    // 故障：写了标记但读不回来（例如比较时大小写/空白没归一）。
    () async {
      final block = TextBlock.createDefault(rect: IntRect(0, 0, 10, 10));
      block.label = StudioSfxOps.label;
      return !StudioSfxOps.isMarkedSfx(block);
    },
    () => '绿=标记可写可读可清、且键本来就在 / 故障=写完读不回来',
  );

  probe(
    'wiring.pipeline_marks_sfx_and_excludes_them_from_the_batch',
    // 🔴 两件事必须**同时**成立：只打标记不跳过翻译 ⇒ 标记是个没人用的字段；
    // 只跳过不标记 ⇒ 用户在 json / 界面上看不出为什么这一块没译文。
    () async {
      final src = code(_studioPipelinePath);
      return src.contains('block.label = StudioSfxOps.label') &&
          RegExp(r'_translate\(\s*sources[\s\S]{0,240}?skip:').hasMatch(src);
    },
    // 故障：打了标记但**不**把下标传给翻译批次。
    () async {
      final src = code(_studioPipelinePath);
      return src.contains('block.label = StudioSfxOps.label') &&
          !RegExp(r'_translate\(\s*sources[\s\S]{0,240}?skip:').hasMatch(src);
    },
    () => '绿=建块时打标记 + 翻译批次拿到 skip / 故障=只打标记不跳过',
  );

  probe(
    'wiring.studio_batch_also_skips_marked_sfx',
    // 「只识别/只翻译」那条路（`_runBlockStages`）建块时不经 `runPage`，所以它
    // 必须自己认标记 —— 否则整章重跑会把上一轮标好的拟声词又翻一遍。
    () async =>
        codeHas(_studioPath, 'StudioSfxOps.isMarkedSfx(block)'),
    // 故障：扫描目标换成面板文件（那里**不应该**有这个判据 —— 单块【翻译】
    // 是人工动作，必须能盖过标记）。
    () async =>
        codeHas(_panelPath, 'StudioSfxOps.isMarkedSfx(block)'),
    () => '绿=批量翻译那段认标记 / 故障=判据跑到单块按钮那边去了',
  );

  // ── 跑 ──────────────────────────────────────────────────────────────

  for (final item in probes) {
    bool green;
    bool red;
    String err = '';
    try {
      green = await item.green();
    } catch (e) {
      green = false;
      err = 'green threw: $e';
    }
    try {
      red = await item.red();
    } catch (e) {
      // 故障路径抛异常 ≠ 断言变红。
      red = true;
      err = '${err.isEmpty ? '' : '$err | '}red threw: $e';
    }
    check(
      'blockOps.${item.name}',
      green && !red,
      '${item.detail()} | 绿路径=${green ? 'true' : 'FALSE'} '
      '故障路径=${red ? '仍绿(装饰品)' : '变红'}${err.isEmpty ? '' : ' | $err'}',
    );
  }
}

/// 未登记的 `.tl` / `.tlParams` 字面量。
///
/// 🔴 **必须**走 `headless_p1_checks::tlLiteralKeys` 这一个实现（正则已在那里
/// 修过三个盲区：只认单引号、不接受跨行、漏 `tlParams`）。这里自己再写一份
/// 正则 = `glossary-ui-check` 刚踩过的那个坑的复刻 —— 修一处忘三处。
///
/// 🔴 路径用 [packageRoot] 推导，不依赖 `Directory.current`：应用进程的 cwd
/// 不保证是包根，用 cwd 会在"文件找不到"时静默返回空列表，而空结果在调用方
/// 那里必须判 FAIL —— 这一点已经这样判了。
List<String> tlLiterals(
  Directory packageRoot,
  String relPath,
  Map<String, dynamic> zhCn,
) {
  final file = File('${packageRoot.path}/$relPath');
  if (!file.existsSync()) return const ['<file missing>'];
  final found = <String>[];
  for (final key in tlLiteralKeys(file.readAsStringSync())) {
    if (key.length <= 2) continue;
    if (!zhCn.containsKey(key) && !found.contains(key)) found.add(key);
  }
  return found;
}

// ── 共用判据（绿/红两条路径喂的是**同一个**） ─────────────────────────
//
// 🔴 每条断言的红路径必须检验**同一个命题**，只是喂不同的实现。若红路径
// 检验的是另一个命题，它为 true 只说明那个命题成立，判���依然没被证伪 ——
// 那正是本文件第一版栽的坑（6 条断言的"故障路径"全是恒真或异题）。

/// 字形级 mask 的判据：region 外是背景、字形上是前景、**region 内字形外仍是
/// 背景**。第三条是分辨点：矩形近似满足不了它。
bool _glyphLevelHolds(MaskPage mask) {
  if (mask.isEmpty) return false;
  if (mask.pixels[0] != 0) return false;
  final centre = 32 * mask.width + 32;
  if (mask.pixels[centre] != 255) return false;
  // (17,21) 在 region 内、黑块外。
  final probe = 21 * mask.width + 17;
  return mask.pixels[probe] == 0;
}

/// 「两个 region 的并集覆盖了各自单独覆盖的全部笔画」。
///
/// 🔴 绿路径喂的是 **`buildMaskPage`**（正确实现，���"或"累积），红路径喂的是
/// `_overwriteUnion`。第一版这里误写成 `_overwriteUnion` —— 于是绿路径也在验
/// 覆盖式，判据拿覆盖式去比单块，而覆盖式恰好在那个夹具上通过了 ⇒ 假绿。
/// 这正是"绿/红两条路径必须共用判据、但**喂不同实现**"这句话的反面教训：
/// 共用判据还不够，实现本身也必须是对的那一个。
bool _unionCoversBoth(RgbaImage img) {
  final left = IntRect(4, 8, 36, 32);
  final right = IntRect(30, 8, 90, 32);
  final a = buildMaskPage(img, [left]);
  final b = buildMaskPage(img, [right]);
  return _unionSelfConsistent(buildMaskPage(img, [left, right]), a, b);
}

/// 🔴 判据是**逐像素的双向包含**，而不是只比 `strokes`、也不是单向检查。
///
/// 两个方向都必须成立：
///
/// 1. **并集覆盖每一块**：并集里的每一个笔画都能在某一块的单独结果里找到出处。
/// 2. **每一块都在并集里**：每一块每一个笔画都必须出现在并集里。
///
/// 🔴 第 2 条才是能握住"覆盖式"的那一条：覆盖式会把**第一块**的笔画全部清零，
/// 而它并不在任何单块的结果里 —— 只看第 1 条时，并集里的那些笔画仍然是
/// 正确的那一些，仍能在单块里找到出处，判据就通过了。计数更抓不到：被清零的
/// 笔画不参与 `strokes`，两个实现的计数可以**完全相等**。
bool _unionSelfConsistent(MaskPage u, MaskPage a, MaskPage b) {
  if (u.pixels.length != a.pixels.length) return false;
  if (u.pixels.length != b.pixels.length) return false;
  for (var i = 0; i < u.pixels.length; i++) {
    final inUnion = u.pixels[i] != 0;
    final inA = a.pixels[i] != 0;
    final inB = b.pixels[i] != 0;
    if (inUnion && !inA && !inB) return false;
    if (!inUnion && (inA || inB)) return false;
  }
  return true;
}

/// 两个 region 的**覆盖式**并集（对照实现）。
///
/// 🔴 与 [buildMaskPage] 同词：逐 region 调 [TextInpainter.computeMask]，但用
/// "后写覆盖"而不是"或累积"。后一个 region 的窗口里没有前一个的笔画时，那些
/// 笔画就被清零了 —— 笔画不重叠，所以**不可见、不报错**。
MaskPage _overwriteUnion(RgbaImage image, List<IntRect> regions) {
  final page = Uint8List(image.width * image.height);
  var strokes = 0;
  for (final rect in regions) {
    final m = TextInpainter.computeMask(image, rect);
    if (m == null) continue;
    for (var y = 0; y < m.rh; y++) {
      final src = y * m.rw;
      for (var x = 0; x < m.rw; x++) {
        final px = m.left + x;
        final py = m.top + y;
        if (px < 0 || py < 0 || px >= image.width || py >= image.height) {
          continue;
        }
        final dst = py * image.width + px;
        if (m.mask[src + x] == 0) {
          page[dst] = 0;
        } else if (page[dst] == 0) {
          strokes++;
          page[dst] = 255;
        }
      }
    }
  }
  return MaskPage(image.width, image.height, page, strokes, regions.length);
}

/// mask 的几何自洽：声明的宽高与像素数一致，且整页都在范围内。
bool _maskGeometrySound(MaskPage mask) =>
    mask.pixels.length == mask.width * mask.height &&
    mask.width > 0 &&
    mask.height > 0;

/// 裁剪窗口必须包住整个块。
bool _windowCoversBlock(CropWindow? c, List<double> box) {
  if (c == null) return false;
  return c.left <= box[0] &&
      c.top <= box[1] &&
      c.right >= box[2] &&
      c.bottom >= box[3];
}

/// 一个**不做长度检查**的假 PNG 编码器：只用来证明"抛错"那条判据不是恒真。
///
/// 🔴 反向验证的通用手法就在这里：判据本身（长度不符要抛）永远为真，
/// 所以必须给它一个**同类但故意做错**的实现，看判据在那个实现上翻脸。
/// 没有这一层，"断言通过"只是"我写的两个分支都跑过了"。
Uint8List _uncheckedEncode(int width, int height, Uint8List pixels) {
  return Uint8List(width * height); // 直接丢弃 pixels，不校验长度
}

/// 矩形近似的 mask：把每个 region 的**整个矩形**涂 255。
///
/// 这正是 `A05 §4.5` 明确拒绝的做法 —— 它会造出一个同名但语义不同的文件。
/// 放在这里是为了让"字形级 vs 矩形"这条断言有一个真实的对照实现。
MaskPage _rectApproxMask(int w, int h, List<IntRect> regions) {
  final px = Uint8List(w * h);
  var n = 0;
  for (final r in regions) {
    for (var y = r.top.clamp(0, h - 1); y < r.bottom.clamp(0, h); y++) {
      for (var x = r.left.clamp(0, w - 1); x < r.right.clamp(0, w); x++) {
        if (px[y * w + x] == 0) n++;
        px[y * w + x] = 255;
      }
    }
  }
  return MaskPage(w, h, px, n, regions.length);
}

/// "先夹取、后放大"的裁剪窗口 —— `StudioBlockOps.cropWindow` 的**反向等价物**。
///
/// 贴边的块（`[0, 0, 6, 6]`）先被夹到页面内，再向两侧放大：左边没有空间可用，
/// 右边就撑出页面 ⇒ 窗口偏心，块的一侧被截掉。而正确实现（先放大后夹取）
/// 会保证窗口始终包住整个块。
CropWindow? _clampThenGrow(List<double> box, int width, int height) {
  final left = box[0].round().clamp(0, width);
  final top = box[1].round().clamp(0, height);
  final right = box[2].round().clamp(0, width);
  final bottom = box[3].round().clamp(0, height);
  if (right <= left || bottom <= top) return null;
  var l = left, t = top, r = right, b = bottom;
  const minSide = 96;
  if (r - l < minSide) {
    final grow = (minSide - (r - l)) ~/ 2;
    l -= grow;
    r += grow;
  }
  if (b - t < minSide) {
    final grow = (minSide - (b - t)) ~/ 2;
    t -= grow;
    b += grow;
  }
  return CropWindow(
    l.clamp(0, width),
    t.clamp(0, height),
    (r.clamp(0, width) - l.clamp(0, width)),
    (b.clamp(0, height) - t.clamp(0, height)),
  );
}

/// 该文件**import** 了 `dart:ui` 吗。
///
/// 🔴 只看 import 行，不看正文：`gray_png.dart` 的类文档里提到了
/// "dart:ui 需要渲染表面"，若判据是全文搜字符串，就会把说明文字当成依赖。
bool importsUi(Directory packageRoot, String relPath) {
  final file = File('${packageRoot.path}/$relPath');
  if (!file.existsSync()) return false;
  final re = RegExp(
    r'''^\s*(import|export)\s+['"]dart:ui['"]''',
    multiLine: true,
  );
  return re.hasMatch(file.readAsStringSync());
}

int _be32(Uint8List b, int off) =>
    (b[off] << 24) | (b[off + 1] << 16) | (b[off + 2] << 8) | b[off + 3];
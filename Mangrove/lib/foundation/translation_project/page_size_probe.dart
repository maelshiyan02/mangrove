// A-1.4 / B-1 / P31 共用的页尺寸读取：**只读图片文件头**，不整图解码。
//
// 🔴 为什么不用 `dart:ui`：本项目会话没有渲染表面（`A01 §3`），
// `decodeImageFromList` 之类的路径根本跑不起来。PNG 的 IHDR、JPEG 的 SOF 段
// 与 WEBP 的 VP8/VP8L/VP8X chunk 都自带宽高，纯 Dart 读前若干字节即可 ——
// 于是"判断这页是不是横图"（A-1.4）、"缝视图要两页尺寸"（B-1）与
// "长画布未解码页的真高度"（P31）第一次能被 headless 测。
//
// 认 PNG / JPEG / WEBP：其余格式返回 `null`，调用方据此**保留显示**
// （不凭"读不出尺寸"把一页吞掉）。
//
// 🔴 P31 教训：龙女友工程 94 页全是 webp，而这里曾经只认 PNG/JPEG —— 每页
// 读出 null，未解码页只能按 1.4 默认比例估高（真竖版约 1.976），长画布窗口
// 中心随滚动累计错位；文件探测还逐页读满 1MB，94 页 ≈ 94MB 同步 IO 堵死
// UI 线程。WEBP 尺寸固定在前 30 字节内，按格式小读后两件事一起消失。
library;

import 'dart:io';
import 'dart:typed_data';

/// 一张页图的像素尺寸。
class PageSize {
  const PageSize(this.width, this.height);

  final int width;
  final int height;

  @override
  String toString() => '${width}x$height';
}

/// 从内存字节里解析 PNG / JPEG / WEBP 的宽高；
/// 无法识别或**头被截断**时返回 `null`。
PageSize? probePageSize(Uint8List bytes) {
  final png = _probePng(bytes);
  if (png != null) return png;
  final webp = _probeWebp(bytes);
  if (webp != null) return webp;
  return _probeJpeg(bytes);
}

/// PNG：8 字节魔数 + 第一块必须是 IHDR，宽高在固定偏移（16 / 20，大端）。
PageSize? _probePng(Uint8List b) {
  if (b.length < 24) return null;
  const sig = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  for (var i = 0; i < 8; i++) {
    if (b[i] != sig[i]) return null;
  }
  // 块类型在偏移 12..15。
  if (b[12] != 0x49 || b[13] != 0x48 || b[14] != 0x44 || b[15] != 0x52) {
    return null;
  }
  final w = _be32(b, 16);
  final h = _be32(b, 20);
  if (w <= 0 || h <= 0) return null;
  return PageSize(w, h);
}

/// WEBP（RIFF 容器）：`RIFF`(0..3) + 文件大小 + `WEBP`(8..11)，其后一串
/// `fourcc + uint32 小端长度 + 数据` 的 chunk（奇数长度补 1 偶数字节）。
///
/// 尺寸有三种来源，按 RIFF 规范 chunk 顺序遍历后选取：
/// - `VP8X`（扩展格式，第一个 chunk）：数据偏移 4..6 = 宽-1（24 位小端），
///   7..9 = 高-1。有 VP8X 时以画布尺寸为准（动画/ALPH 等也挂在它后面）。
/// - `VP8 `（有损）：数据起 3 字节帧标签，随后必须是签名 `9d 01 2a`，
///   宽高各为 16 位小端后掩 `0x3fff`（在数据偏移 6 / 8）。
/// - `VP8L`（无损）：数据首字节必须是 `0x2f`，随后 4 字节小端打包：
///   宽-1 = bits 0..13，高-1 = bits 14..27。
///
/// 参考：WebP Container Spec / RFC 6386（VP8 bitstream 首帧头布局）。
PageSize? _probeWebp(Uint8List b) {
  if (b.length < 12) return null;
  if (b[0] != 0x52 || // R
      b[1] != 0x49 || // I
      b[2] != 0x46 || // F
      b[3] != 0x46 || // F
      b[8] != 0x57 || // W
      b[9] != 0x45 || // E
      b[10] != 0x42 || // B
      b[11] != 0x50) {
    return null;
  }
  var p = 12;
  PageSize? extended;
  while (p + 8 <= b.length && p + 4 < b.length) {
    final cc = b[p]; // 四个 ASCII 字节分别比较，不引字符串编解码。
    final len = _le32At(b, p + 4);
    final data = p + 8;
    final end = data + len;
    // 🔴 本解析器只拿到"文件头若干字节"：VP8 chunk 声明长度可以远超已读
    // 字节数（整页压缩数据），因此不能要求整个 chunk 在缓冲里 —— 只要尺寸
    // 所需的头几字节在就给结论；只有"继续漫游下一个 chunk"才需要 end 可达。
    final isV = cc == 0x56 /*V*/;
    if (isV &&
        b[p + 1] == 0x50 /*P*/ &&
        b[p + 2] == 0x38 /*8*/ &&
        b[p + 3] == 0x58 /*X*/ &&
        data + 10 <= b.length) {
      // VP8X：需要数据偏移 0..9（10 字节）。
      final w = 1 + _le24At(b, data + 4);
      final h = 1 + _le24At(b, data + 7);
      if (w > 1 && h > 1) extended = PageSize(w, h);
    } else if (isV &&
        b[p + 1] == 0x50 /*P*/ &&
        b[p + 2] == 0x38 /*8*/ &&
        b[p + 3] == 0x20 /*space*/ &&
        data + 10 <= b.length &&
        b[data + 3] == 0x9d &&
        b[data + 4] == 0x01 &&
        b[data + 5] == 0x2a) {
      // 'VP8 ' 有损：签名在 data+3..+5，宽高在 data+6 / data+8。
      final w = _le16At(b, data + 6) & 0x3fff;
      final h = _le16At(b, data + 8) & 0x3fff;
      if (w > 0 && h > 0) return extended ?? PageSize(w, h);
    } else if (isV &&
        b[p + 1] == 0x50 /*P*/ &&
        b[p + 2] == 0x38 /*8*/ &&
        b[p + 3] == 0x4c /*L*/ &&
        data + 5 <= b.length &&
        b[data] == 0x2f) {
      // 'VP8L' 无损：0x2f 后 4 字节打包宽高-1。
      final n = _le32At(b, data + 1);
      final w = (n & 0x3fff) + 1;
      final h = ((n >> 14) & 0x3fff) + 1;
      if (w > 0 && h > 0) return extended ?? PageSize(w, h);
    }
    if (end > b.length) break; // 本 chunk 都没读全，后面更到不了。
    p = end + (len & 1); // chunk 按偶数字节对齐
  }
  return extended; // 只见到 VP8X（后面的位流头被截断）时也给出画布尺寸。
}

/// JPEG：`SOI(FFD8)` 起，逐个 marker 前进；`SOF0`~`SOF15`（除 DHT/JPG/DAC）
/// 段内带宽高。SOF 之前可能排着很长的 EXIF（APP1），所以必须真的走一遍 marker
/// 链，不能只看头 16 字节。
PageSize? _probeJpeg(Uint8List b) {
  if (b.length < 4 || b[0] != 0xFF || b[1] != 0xD8) return null;
  var i = 2;
  while (i + 1 < b.length) {
    if (b[i] != 0xFF) return null; // 结构坏了
    var marker = b[i + 1];
    // 允许填充的连续 FF。
    while (marker == 0xFF && i + 2 < b.length) {
      i++;
      marker = b[i + 1];
    }
    // 无长度字段的独立 marker：SOI / EOI / TEM / RSTn。
    if (marker == 0xD8 ||
        marker == 0xD9 ||
        marker == 0x01 ||
        (marker >= 0xD0 && marker <= 0xD7)) {
      i += 2;
      continue;
    }
    // SOS：其后是压缩数据。尺寸信息（SOF）必须在它之前出现过。
    if (marker == 0xDA) return null;
    if (i + 3 >= b.length) return null;
    final len = (b[i + 2] << 8) | b[i + 3];
    if (len < 2) return null;
    final isSof = (marker >= 0xC0 && marker <= 0xCF) &&
        marker != 0xC4 && // DHT
        marker != 0xC8 && // JPG
        marker != 0xCC; // DAC
    if (isSof) {
      // marker(2) + len(2) + precision(1) + height(2) + width(2)。
      if (i + 8 >= b.length) return null;
      final h = (b[i + 5] << 8) | b[i + 6];
      final w = (b[i + 7] << 8) | b[i + 8];
      if (w <= 0 || h <= 0) return null;
      return PageSize(w, h);
    }
    i += 2 + len;
  }
  return null;
}

int _be32(Uint8List b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

int _le16At(Uint8List b, int o) => b[o] | (b[o + 1] << 8);

int _le24At(Uint8List b, int o) =>
    b[o] | (b[o + 1] << 8) | (b[o + 2] << 16);

int _le32At(Uint8List b, int o) =>
    b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

/// 只读文件头解析页尺寸；文件不存在 / 读不出 / 格式不支持 → `null`。
///
/// 🔴 按格式小读：WEBP / PNG 的尺寸固定在前 30 / 24 字节，读 32 字节即定；
/// 只有 JPEG 的 SOF 可能隔着很长的 EXIF，按 64KB 块沿 marker 链漫游，最多碰
/// [maxHeaderBytes]。曾经这里对所有格式逐页读满 1MB，龙女友 94 页 webp 在
/// 切长画布瞬间产生 ≈ 94MB 同步 IO，把 UI 线程连同解码回调一起堵死（P31）。
PageSize? probePageSizeFromFile(String path, {int maxHeaderBytes = 1 << 20}) {
  final file = File(path);
  if (!file.existsSync()) return null;
  RandomAccessFile? raf;
  try {
    raf = file.openSync();
    const fixedHeaderBytes = 32;
    final head = raf.readSync(fixedHeaderBytes);
    // WEBP：RIFF(4)+size(4)+WEBP(4)；PNG：8 字节魔数。这两种尺寸都在头内。
    final looksWebp = head.length >= 12 &&
        head[0] == 0x52 &&
        head[1] == 0x49 &&
        head[2] == 0x46 &&
        head[3] == 0x46 &&
        head[8] == 0x57 &&
        head[9] == 0x45 &&
        head[10] == 0x42 &&
        head[11] == 0x50;
    final looksPng = head.length >= 8 &&
        head[0] == 0x89 &&
        head[1] == 0x50 &&
        head[2] == 0x4e &&
        head[3] == 0x47;
    if (looksWebp || looksPng) {
      final size = probePageSize(head);
      if (size != null || head.length < fixedHeaderBytes) return size;
      // 32 字节仍不够（极端 WEBP 扩展容器：VP8X 前塞了 chunk —— 规范不允许，
      // 但容错继续按块读），落入下面的通用漫游。
    }
    final buffer = BytesBuilder(copy: false)..add(head);
    const chunk = 64 * 1024;
    while (buffer.length < maxHeaderBytes) {
      final part = raf.readSync(chunk);
      if (part.isEmpty) break;
      buffer.add(part);
      final size = probePageSize(buffer.toBytes());
      if (size != null) return size;
    }
    return probePageSize(buffer.toBytes());
  } catch (_) {
    return null;
  } finally {
    raf?.closeSync();
  }
}
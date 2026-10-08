import 'dart:io';
import 'dart:typed_data';

/// Minimal 8-bit **greyscale** PNG encoder.
///
/// ## 为什么不用 `ui.Image.toByteData(format: png)`（S-N3）
///
/// 那条路要求先有一个 `ui.Image`，而拿到 `ui.Image` 只能走
/// `Picture.toImage` —— 本项目在 headless 会话里**没有渲染表面**
/// （`No Impeller context is available`，见 `A01 §3`），一调用就抛。
/// 于是走 `dart:ui` 的 mask 生产在本环境里**根本无法验证**，只能标"未验证"。
///
/// 手写 PNG 的代价是 CRC32 + zlib，而两者都是 `dart:io` / `dart:typed_data`
/// 的纯 Dart（`ZLibEncoder`），**不需要引擎**。这让 mask 生产第一次成为
/// headless 可测的产物 —— 而"可测"正是本项目对 ✅ 的定义。
///
/// ## 格式（对应 BT 的 `imread(..., IMREAD_GRAYSCALE)`）
///
/// PNG color type **0**（greyscale）、bit depth **8**、无隔行 —— 与 FT / BT
/// 读取 mask 的方式一致。若改成 RGBA（color type 6），`cv2.imread` 虽然会
/// 照样解码出灰度，但"这个文件是单通道"这个契约就只剩约定而无强制，
/// 下一个工具按 `shape[:2]` 取宽度时就会踩到 `(h, w, 3)`。
abstract final class GrayPng {
  /// Encodes [width] × [height] 8-bit greyscale [pixels] (row-major, [length]
  /// must be exactly `width * height`) as a PNG byte stream.
  ///
  /// Throws [ArgumentError] when the buffer length does not match the stated
  /// geometry: a PNG whose IDAT length disagrees with IHDR is one of the
  /// "writes fine, reads back garbage" failures this project treats as worse
  /// than a hard error.
  static Uint8List encode(int width, int height, Uint8List pixels) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError('bad geometry ${width}x$height');
    }
    if (pixels.length != width * height) {
      throw ArgumentError(
        'pixel buffer ${pixels.length} != $width x $height '
        '(${width * height})',
      );
    }
    final out = BytesBuilder();
    out.add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);

    // IHDR: 13 bytes of payload — width, height, depth 8, colour type 0
    // (greyscale), compression 0, filter 0, interlace 0.
    final ihdr = BytesBuilder()
      ..add(_be32(width))
      ..add(_be32(height))
      ..add(const [8, 0, 0, 0, 0]);
    _chunk(out, 'IHDR', ihdr.takeBytes());

    // Raw scanlines: every row is prefixed with filter type 0 (None). Filter 1
    // (Sub) or 2 (Up) would compress flat masks marginally better, but None is
    // the one every decoder handles identically, and mask files are written
    // once and read by external tools (BT / OpenCV) — that is the wrong place
    // to be clever.
    final raw = Uint8List(height * (width + 1));
    var p = 0;
    for (var y = 0; y < height; y++) {
      raw[p++] = 0;
      raw.setRange(p, p + width, pixels, y * width);
      p += width;
    }
    final compressed = Uint8List.fromList(ZLibCodec(level: 6).encode(raw));
    _chunk(out, 'IDAT', compressed);
    _chunk(out, 'IEND', Uint8List(0));
    return out.takeBytes();
  }

  static void _chunk(BytesBuilder out, String type, Uint8List data) {
    out.add(_be32(data.length));
    final body = BytesBuilder()..add(type.codeUnits);
    body.add(data);
    final payload = body.takeBytes();
    out.add(payload);
    out.add(_be32(crc32(payload)));
  }

  static Uint8List _be32(int v) => Uint8List(4)
    ..[0] = (v >> 24) & 0xFF
    ..[1] = (v >> 16) & 0xFF
    ..[2] = (v >> 8) & 0xFF
    ..[3] = v & 0xFF;

  /// 🔴 `late final` 而不是 `const`：`const` 要求整个表在编译期求值，
  /// 那就得在 const 上下文里跑 256×8 次位运算 —— 分析器会直接拒绝
  /// （`const_eval_method_invocation`）。延迟到首次调用时算一次即可，
  /// 而 CRC 表本身与运行时状态无关，late final 的语义完全等价。
  static final _crcTable = _makeCrcTable();

  /// CRC-32 (PNG / zlib polynomial 0xEDB88320, reflected).
  static int crc32(List<int> bytes) {
    var c = 0xFFFFFFFF;
    for (final b in bytes) {
      c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
    }
    return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  static List<int> _makeCrcTable() {
    final table = List<int>.filled(256, 0);
    for (var n = 0; n < 256; n++) {
      var c = n;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
      }
      table[n] = c;
    }
    return table;
  }
}
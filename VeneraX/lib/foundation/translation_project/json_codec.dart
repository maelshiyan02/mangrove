import 'dart:convert';

/// JSON codec that reproduces Python's `json.dumps(obj, ensure_ascii=False)`
/// byte for byte.
///
/// Fan Translation (FT / BallonsTranslator) writes `imgtrans_*.json` with
/// Python's default settings, which differ from Dart's `jsonEncode` in two
/// ways that would otherwise rewrite every byte of a real project file:
///
/// 1. **Separators.** Python inserts `", "` between items and `": "` between a
///    key and its value; Dart emits `,` and `:` with no spaces.
/// 2. **Float layout.** Python uses `repr` formatting — fixed notation for
///    exponents in `[-4, 16)`, otherwise `1e+16` / `1e-07` (sign always
///    present, exponent padded to at least two digits). Dart's `toString`
///    switches to exponent form at different thresholds and writes `1e-7`.
///
/// Everything else already agrees, and that was verified against the real
/// project file, not assumed:
/// * strings (`ensure_ascii=False` keeps non-ASCII and escapes exactly the
///   same control characters),
/// * integers, booleans, nulls,
/// * key order (Dart maps preserve insertion order, as Python dicts do).
///
/// The consequence is what makes the project round-trip safe: reading a file
/// and writing it back without edits produces a zero-byte diff. Any non-zero
/// diff is therefore a real change we made, never codec noise — which is what
/// lets S8's "save" be trusted against real FT workspaces.
///
/// See `docs/P6.1-现状探查报告.md` §3 and `tools/spike/s6_probe_dart_json.dart`
/// for the probe that established these rules.
class PyJson {
  const PyJson._();

  /// Decodes [source]. Numbers keep Python's int/double distinction the same
  /// way Dart's own decoder does (`20.0` -> double, `20` -> int), which is
  /// what [encodeNumber] relies on to reproduce the original text.
  static Object? decode(String source) => jsonDecode(source);

  /// Encodes [value] exactly as `json.dumps(value, ensure_ascii=False)` would.
  static String encode(Object? value) {
    final buffer = StringBuffer();
    _write(buffer, value);
    return buffer.toString();
  }

  static void _write(StringBuffer out, Object? value) {
    if (value == null) {
      out.write('null');
      return;
    }
    if (value is bool) {
      out.write(value ? 'true' : 'false');
      return;
    }
    if (value is num) {
      out.write(encodeNumber(value));
      return;
    }
    if (value is String) {
      // Dart's escaping already matches Python's `ensure_ascii=False` output.
      out.write(jsonEncode(value));
      return;
    }
    if (value is List) {
      out.write('[');
      for (var i = 0; i < value.length; i++) {
        if (i > 0) out.write(', ');
        _write(out, value[i]);
      }
      out.write(']');
      return;
    }
    if (value is Map) {
      out.write('{');
      var first = true;
      value.forEach((key, entry) {
        if (!first) out.write(', ');
        first = false;
        out.write(jsonEncode(key.toString()));
        out.write(': ');
        _write(out, entry);
      });
      out.write('}');
      return;
    }
    // Anything else (e.g. a decoded JSON value that a caller wrapped) is
    // stringified rather than silently dropped, so a write can never lose data
    // without saying so.
    out.write(jsonEncode(value.toString()));
  }

  /// Encodes one number the way Python would.
  ///
  /// Integers pass through unchanged; doubles go through [pythonFloatText].
  static String encodeNumber(num value) {
    if (value is int) return value.toString();
    return pythonFloatText(value.toDouble());
  }

  /// Formats [value] like Python's `repr(float)`.
  ///
  /// Dart's `double.toString()` already produces the shortest decimal string
  /// that round-trips, so this only has to re-lay-out the digits: choose fixed
  /// vs exponential notation by Python's rule, pad the exponent to two digits,
  /// and keep a trailing `.0` on whole numbers.
  static String pythonFloatText(double value) {
    if (value.isNaN) return 'NaN';
    if (value.isInfinite) return value > 0 ? 'Infinity' : '-Infinity';
    if (value == 0.0) return value.isNegative ? '-0.0' : '0.0';

    var text = value.abs().toString();

    // Split off an exponent if Dart used one ("1e+300", "5e-324").
    var exponent = 0;
    final eIndex = text.indexOf('e');
    if (eIndex >= 0) {
      exponent = int.parse(text.substring(eIndex + 1));
      text = text.substring(0, eIndex);
    }

    // Flatten "123.45" into digits plus the position of the decimal point.
    final dotIndex = text.indexOf('.');
    final integerDigits = dotIndex < 0 ? text.length : dotIndex;
    final rawDigits = dotIndex < 0
        ? text
        : text.substring(0, dotIndex) + text.substring(dotIndex + 1);

    // Drop leading zeros, remembering how many were removed: they shift where
    // the first significant digit sits and therefore the exponent.
    var start = 0;
    while (start < rawDigits.length - 1 &&
        rawDigits.codeUnitAt(start) == 0x30) {
      start++;
    }
    var digits = rawDigits.substring(start);
    // Trailing zeros only pad the integer part and are re-added below.
    var end = digits.length;
    while (end > 1 && digits.codeUnitAt(end - 1) == 0x30) {
      end--;
    }
    digits = digits.substring(0, end);

    // value == digits * 10^k, i.e. d[0].d[1..] * 10^k.
    final k = exponent + integerDigits - start - 1;

    final sign = value.isNegative ? '-' : '';

    // Python switches to exponential notation outside (-4, 16).
    if (k >= 16 || k < -4) {
      final mantissa = digits.length == 1
          ? digits
          : '${digits[0]}.${digits.substring(1)}';
      final sign2 = k < 0 ? '-' : '+';
      final magnitude = k.abs().toString().padLeft(2, '0');
      return '$sign${mantissa}e$sign2$magnitude';
    }

    if (k >= 0) {
      final integerLength = k + 1;
      final whole = digits.length >= integerLength
          ? digits.substring(0, integerLength)
          : digits.padRight(integerLength, '0');
      final fraction = digits.length > integerLength
          ? digits.substring(integerLength)
          : '';
      return fraction.isEmpty ? '$sign$whole.0' : '$sign$whole.$fraction';
    }

    return '${sign}0.${'0' * (-k - 1)}$digits';
  }
}

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/reader/reader.dart';

void main() {
  test('reading orientation cycles auto -> portrait -> landscape -> auto', () {
    expect(nextReadingOrientation(null), false);
    expect(nextReadingOrientation(false), true);
    expect(nextReadingOrientation(true), null);
  });

  test('locks resolve to the matching orientation pair', () {
    expect(resolveReadingOrientations(false), [
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    expect(resolveReadingOrientations(true), [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  });

  test('unlocked hands control back instead of forcing all four', () {
    // DeviceOrientation.values here would override the device's rotation lock
    // and the manifest's exclusion of upside-down portrait.
    expect(resolveReadingOrientations(null), isEmpty);
  });
}

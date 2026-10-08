import 'package:flutter_test/flutter_test.dart';
import 'package:mangrove/utils/opencc.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await OpenCC.init();
  });

  // hasChineseSimplified once contained a debug-leftover guard that returned
  // false for every input except the literal probe string, silently disabling
  // simplified→traditional matching in the favorites search.
  test('detects simplified Chinese for arbitrary simplified text', () {
    expect(OpenCC.hasChineseSimplified('监狱'), isTrue);
    expect(OpenCC.hasChineseSimplified('监禁'), isTrue);
    expect(OpenCC.hasChineseSimplified('hello'), isFalse);
  });

  test('detects traditional Chinese', () {
    expect(OpenCC.hasChineseTraditional('監獄'), isTrue);
    expect(OpenCC.hasChineseTraditional('hello'), isFalse);
  });

  test('converts between simplified and traditional', () {
    expect(OpenCC.simplifiedToTraditional('监狱'), '監獄');
    expect(OpenCC.traditionalToSimplified('監獄'), '监狱');
  });
}

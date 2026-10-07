import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/ext.dart';

void main() {
  test('matches a number standing on its own', () {
    expect('20 pages'.containsNumber('20'), isTrue);
    expect('20P'.containsNumber('20'), isTrue);
    expect('全部 20 页'.containsNumber('20'), isTrue);
    expect('20'.containsNumber('20'), isTrue);
  });

  test('does not match a number embedded in a longer one', () {
    expect('2024-05-01'.containsNumber('20'), isFalse);
    expect('120'.containsNumber('20'), isFalse);
    expect('201'.containsNumber('20'), isFalse);
    expect('1201'.containsNumber('20'), isFalse);
  });

  test('finds a standalone occurrence after an embedded one', () {
    expect('2024 / 20 pages'.containsNumber('20'), isTrue);
    expect('120 chapters, 20 pages'.containsNumber('20'), isTrue);
  });

  test('non-digit neighbours do not block a match', () {
    expect('ch.20-end'.containsNumber('20'), isTrue);
    expect('[20]'.containsNumber('20'), isTrue);
  });

  test('absent number and empty query', () {
    expect('no digits here'.containsNumber('20'), isFalse);
    expect(''.containsNumber('20'), isFalse);
    expect('20 pages'.containsNumber(''), isFalse);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_provider/avif_fallback.dart';
import 'package:venera/foundation/image_provider/cached_image.dart';
import 'package:venera/foundation/image_provider/reader_image.dart';
import 'package:venera/foundation/image_translation/translation_config.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';

/// An AVIF whose pixels the engine cannot decode fails *after* the header has
/// parsed and a codec has been produced, so the failure never reaches the code
/// that wraps `decode()`. Once it is reported, the URL must be recorded so the
/// next request asks for the encoding the server also publishes.
void main() {
  setUp(AvifFallbackRegistry.instance.clear);
  tearDown(AvifFallbackRegistry.instance.clear);

  group('fallback registry', () {
    const avif = 'https://img.example.invalid/a/001.avif';

    test('an unrecorded url is returned untouched', () {
      expect(AvifFallbackRegistry.instance.applyFallback(avif), avif);
    });

    test('a recorded url is redirected to the alternative encoding', () {
      AvifFallbackRegistry.instance.markFailed(avif);
      expect(
        AvifFallbackRegistry.instance.applyFallback(avif),
        'https://img.example.invalid/a/001.webp',
      );
    });

    test('a url with no known alternative is never recorded', () {
      const jpg = 'https://img.example.invalid/a/001.jpg';
      AvifFallbackRegistry.instance.markFailed(jpg);
      expect(AvifFallbackRegistry.instance.hasFailed(jpg), isFalse);
      expect(AvifFallbackRegistry.instance.applyFallback(jpg), jpg);
    });

    test('recording one url leaves its siblings alone', () {
      const other = 'https://img.example.invalid/a/002.avif';
      AvifFallbackRegistry.instance.markFailed(avif);
      expect(AvifFallbackRegistry.instance.applyFallback(other), other);
    });

    // A cache key appends fields with '@', the same separator a signed URL uses
    // in its query string. Splitting a key back into a URL truncates it, and the
    // redirect then never matches the url the downloader asks about.
    test('a url carrying @ survives being recorded', () {
      const signed = 'https://img.example.invalid/a/001.avif?token=a@b';
      AvifFallbackRegistry.instance.markFailed(signed);
      expect(
        AvifFallbackRegistry.instance.applyFallback(signed),
        'https://img.example.invalid/a/001.webp?token=a@b',
      );
    });
  });

  group('providers expose the url to redirect', () {
    test('a cover reports its own url', () {
      const url = 'https://img.example.invalid/cover.avif';
      expect(CachedImageProvider(url, sourceKey: 'src').fallbackUrl, url);
    });

    // The downloader is asked about imageKey, so that is what must be recorded —
    // not the cache key, which carries cid/eid the lookup never sees.
    test('a reader page reports imageKey, not the cache key', () {
      const imageKey = 'https://img.example.invalid/p/001.avif';
      final p = ReaderImageProvider(imageKey, 'src', 'cid', 'eid', 1);
      expect(p.fallbackUrl, imageKey);
      expect(p.fallbackUrl, isNot(p.diskCacheKey));
    });

    // A translated page is rendered on device; a decode failure there says
    // nothing about how the server encoded the original.
    test('a translated reader page reports no url', () {
      final p = ReaderImageProvider(
        'https://img.example.invalid/p/001.avif',
        'src',
        'cid',
        'eid',
        1,
        translationKey: 'tr',
        translationConfig: const TranslationConfig(
          sourceLang: 'ja',
          targetLang: 'zh',
          mode: InpaintMode.patch,
        ),
      );
      expect(p.fallbackUrl, isNull);
    });
  });
}

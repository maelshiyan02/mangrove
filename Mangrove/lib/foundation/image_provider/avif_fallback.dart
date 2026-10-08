/// Records image URLs whose bytes could not be turned into a frame, so a later
/// load can ask the server for a different encoding instead of replaying the
/// same failure.
///
/// A frame-level failure is not reported by [ImageDescriptor.encoded]: the
/// header parses, a codec is produced, and only the pixel decode fails. On
/// Impeller that surfaces as "Could not decompress image."; on Skia as "Codec
/// failed to produce an image". Both arrive after the provider has handed the
/// codec to the framework, which is why the failure has to be recorded from
/// around the frame decode rather than around [instantiateImageCodec].
class AvifFallbackRegistry {
  AvifFallbackRegistry._();

  static final instance = AvifFallbackRegistry._();

  /// Suffixes whose server-side alternative is known. Ordered: the first entry
  /// whose extension the URL carries decides the replacement.
  static const _alternatives = <String, String>{'.avif': '.webp'};

  final _failedUrls = <String>{};

  /// True when [url] carries an extension this registry can redirect.
  static bool canFallBack(String url) =>
      _alternatives.keys.any(url.contains);

  /// Record a URL whose bytes failed to decode.
  ///
  /// Takes the URL itself, not a cache key: cache keys append fields with the
  /// same `@` separator that appears in query strings, so splitting one back
  /// into a URL silently truncates it and the later lookup never matches.
  void markFailed(String url) {
    if (canFallBack(url)) {
      _failedUrls.add(url);
    }
  }

  /// Whether [url] has already been recorded as undecodable.
  bool hasFailed(String url) => _failedUrls.contains(url);

  /// Rewrite [url] to its alternative encoding once it has been recorded.
  String applyFallback(String url) {
    if (!_failedUrls.contains(url)) {
      return url;
    }
    for (var entry in _alternatives.entries) {
      if (url.contains(entry.key)) {
        return url.replaceAll(entry.key, entry.value);
      }
    }
    return url;
  }

  void clear() {
    _failedUrls.clear();
  }
}

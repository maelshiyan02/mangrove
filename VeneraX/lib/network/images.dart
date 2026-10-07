import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/image_translation/rate_limiter.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/utils/translations.dart';
import 'package:venera/utils/image.dart';
import 'package:venera/foundation/image_provider/avif_fallback.dart';

import 'app_dio.dart';
import 'comix_client.dart';

const _imageStreamIdleTimeout = Duration(seconds: 30);

abstract class ImageDownloader {
  /// Disk cache key for a thumbnail/cover. Callers that may need to evict a
  /// corrupted entry must build the key through this, not by hand: a key that
  /// differs from the one used to write makes eviction a no-op, and bad bytes
  /// then survive forever because [loadThumbnail] serves the cache first.
  static String thumbnailCacheKey(
    String url,
    String? sourceKey, [
    String? cid,
  ]) => "$url@$sourceKey${cid != null ? '@$cid' : ''}";

  /// Disk cache key for a comic page. Same contract as [thumbnailCacheKey].
  /// Deliberately excludes resize/translation state: those change the provider
  /// identity, not the bytes stored on disk.
  static String imageCacheKey(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid,
  ) => "$imageKey@$sourceKey@$cid@$eid";

  static Stream<ImageDownloadProgress> loadThumbnail(
    String url,
    String? sourceKey, [
    String? cid,
  ]) async* {
    // Apply AVIF fallback if this URL previously failed to decode.
    url = AvifFallbackRegistry.instance.applyFallback(url);

    // A locally stored cover (a collection's custom cover, or one borrowed from
    // a downloaded member) can't go through the HTTP client: it rejects the
    // file scheme, which failed the whole download task (#206).
    if (url.startsWith('file://')) {
      var file = File(url.substring(7));
      if (!await file.exists()) {
        throw "Cover file not found".tl;
      }
      var data = await file.readAsBytes();
      yield ImageDownloadProgress(
        currentBytes: data.length,
        totalBytes: data.length,
        imageBytes: data,
      );
      return;
    }

    final cacheKey = thumbnailCacheKey(url, sourceKey, cid);
    final cache = await CacheManager().findCache(cacheKey);

    if (cache != null) {
      var data = await cache.readAsBytes();
      yield ImageDownloadProgress(
        currentBytes: data.length,
        totalBytes: data.length,
        imageBytes: data,
      );
    }

    var configs = <String, dynamic>{};
    if (sourceKey != null) {
      var comicSource = ComicSource.find(sourceKey);
      configs =
          (await comicSource?.getThumbnailLoadingConfig?.call(url, cid)) ?? {};
    }
    configs['headers'] ??= {};
    if (configs['headers']['user-agent'] == null &&
        configs['headers']['User-Agent'] == null) {
      configs['headers']['user-agent'] = webUA;
    }

    if (((configs['url'] as String?) ?? url).startsWith('cover.') &&
        sourceKey != null) {
      // 相对封面名（本地副本的 "cover.jpg"）必须借源的网络详情反查出真实
      // URL，反查需要 comic id。此前 cid 为 null 时在这里直接 `cid!` 崩掉
      // —— 下载任务的封面步骤就不传 cid，于是"对已下载的漫画再次发起
      // 下载"（详情页把 cover 换成了本地文件名）必定以
      // "Null check operator used on a null value" 失败。
      var comicSource = ComicSource.find(sourceKey);
      if (comicSource == null ||
          comicSource.loadComicInfo == null ||
          cid == null) {
        throw "Cannot resolve relative cover '$url' (source=$sourceKey, "
            "comicId=$cid)";
      }
      var comicInfo = await comicSource.loadComicInfo!(cid);
      yield* loadThumbnail(comicInfo.data.cover, sourceKey, cid);
      return;
    }

    // 源声明 viaWebview 时走离屏 WebView 取字节（comix.to 的封面域
    // static.comix.to 上了 CF managed challenge，dio 指纹被拦）。
    if (configs['viaWebview'] == true) {
      var data = await ComixClient.fetchImageBytes(configs['url'] ?? url);
      yield ImageDownloadProgress(
        currentBytes: data.length,
        totalBytes: data.length,
        imageBytes: data,
      );
      return;
    }

    var dio = AppDio(
      BaseOptions(
        headers: Map<String, dynamic>.from(configs['headers']),
        method: configs['method'] ?? 'GET',
        responseType: ResponseType.stream,
      ),
    );

    String requestUrl = configs['url'] ?? url;
    if (requestUrl.startsWith('//')) {
      requestUrl = 'https:$requestUrl';
    }
    var req = await dio.request<ResponseBody>(
      requestUrl,
      data: configs['data'],
    );
    var stream = req.data?.stream ?? (throw "Error: Empty response body.");
    int? expectedBytes = req.data!.contentLength;
    if (expectedBytes == -1) {
      expectedBytes = null;
    }
    var buffer = <int>[];
    await for (var data in stream.timeout(_imageStreamIdleTimeout)) {
      buffer.addAll(data);
      if (expectedBytes != null) {
        yield ImageDownloadProgress(
          currentBytes: buffer.length,
          totalBytes: expectedBytes,
        );
      }
    }

    // Matches the comic-image path below: an async hook must be awaited, and an
    // unchecked return would cache a Future/JS object as if it were image bytes.
    if (configs['onResponse'] is JSInvokable) {
      dynamic result = (configs['onResponse'] as JSInvokable)([
        Uint8List.fromList(buffer),
      ]);
      if (result is Future) {
        result = await result;
      }
      if (result is List<int>) {
        buffer = result;
      } else {
        throw "Error: Invalid onResponse result.";
      }
      (configs['onResponse'] as JSInvokable).free();
    }

    await CacheManager().writeCache(cacheKey, buffer);
    yield ImageDownloadProgress(
      currentBytes: buffer.length,
      totalBytes: buffer.length,
      imageBytes: Uint8List.fromList(buffer),
    );
  }

  static final _loadingImages =
      <String, _StreamWrapper<ImageDownloadProgress>>{};

  /// Cancel all loading images.
  static void cancelAllLoadingImages() {
    for (var wrapper in _loadingImages.values) {
      wrapper.cancel();
    }
    _loadingImages.clear();
  }

  /// Load a comic image from the network or cache.
  /// The function will prevent multiple requests for the same image.
  static Stream<ImageDownloadProgress> loadComicImage(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid, {
    void Function(Duration? retryAfter)? onRateLimited,
  }) {
    final cacheKey = imageCacheKey(imageKey, sourceKey, cid, eid);
    if (_loadingImages.containsKey(cacheKey)) {
      return _loadingImages[cacheKey]!.stream;
    }
    final stream = _StreamWrapper<ImageDownloadProgress>(
      _loadComicImage(imageKey, sourceKey, cid, eid, false, onRateLimited),
      (wrapper) {
        _loadingImages.remove(cacheKey);
      },
      isReplayable: (progress) => progress.imageBytes != null,
    );
    _loadingImages[cacheKey] = stream;
    return stream.stream;
  }

  static Stream<ImageDownloadProgress> loadComicImageUnwrapped(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid, {
    bool forDownload = false,
    int? downloadTimeoutSeconds,
  }) {
    return _loadComicImage(
      imageKey,
      sourceKey,
      cid,
      eid,
      forDownload,
      null,
      downloadTimeoutSeconds,
    );
  }

  static Stream<ImageDownloadProgress> _loadComicImage(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid, [
    bool forDownload = false,
    void Function(Duration? retryAfter)? onRateLimited,
    int? downloadTimeoutSeconds,
  ]) async* {
    // Apply AVIF fallback if this URL previously failed to decode.
    imageKey = AvifFallbackRegistry.instance.applyFallback(imageKey);

    final cacheKey = imageCacheKey(imageKey, sourceKey, cid, eid);
    final cache = await CacheManager().findCache(cacheKey);

    if (cache != null) {
      var data = await cache.readAsBytes();
      yield ImageDownloadProgress(
        currentBytes: data.length,
        totalBytes: data.length,
        imageBytes: data,
      );
      // A download reuses an already-cached image instead of re-fetching it,
      // and never re-caches (avoids double-writing the bytes to disk and
      // evicting the reader's prefetch cache) — see #4 / #17.
      if (forDownload) return;
    }

    Future<Map<String, dynamic>?> Function()? onLoadFailed;

    var configs = <String, dynamic>{};
    if (sourceKey != null) {
      var comicSource = ComicSource.find(sourceKey);
      configs =
          (await comicSource!.getImageLoadingConfig?.call(
            imageKey,
            cid,
            eid,
          )) ??
          {};
    }
    // 源可声明自己的重试上限：走 WebView 这类慢通道时，重试次数乘以单次
    // 超时就是"这张图多久才放弃"，必须收紧（comix.to 用 2）。
    // ⚠️ 阅读与下载策略必须分开：阅读要快速失败换 UX（短超时×少重试），
    // 下载要成功率（长超时×多重试），跑批时单图等待长一点无感。
    var retryLimit = (configs['retryLimit'] as num?)?.toInt() ?? 5;
    // 下载模式：源声明 downloadRetryLimit 时已经有自己的重签预算（comix=3），
    // 通用 net-retry 再叠 3 次就是三层重试（wrapper × images × net），一张被
    // CDN 限流挂起的图最坏要耗 (3+3+1)×98s ≈ 19 分钟才失败。收紧为 1：
    // 限流类挂起重试无益（节流器 #P4-6b 才是解），快失败尽早记 missing。
    // 下载模式：单图重试预算交给 download.dart 的"多轮渐进超时"统一调度
    // （第 1 轮 5s 快下完能下的，再逐轮放宽到 10/15/30s 攻坚失败页）。这里
    // 不再叠 net-retry 乘数——否则单张被限流的图在每一轮里都要先吃满一整轮
    // 超时再重签/重连，等于把"5s 一轮"又放大成 30s+（用户反馈的根因）。
    // 仅保留 onLoadFailed 一次重签（retryLimit）以覆盖偶发过期签名/坏缓存。
    var netRetries = forDownload ? 0 : 3;
    if (forDownload) {
      retryLimit = 1;
    }
    while (true) {
      try {
        configs['headers'] ??= {'user-agent': webUA};

        if (configs['onLoadFailed'] is JSInvokable) {
          onLoadFailed = () async {
            dynamic result = (configs['onLoadFailed'] as JSInvokable)([]);
            if (result is Future) {
              result = await result;
            }
            if (result is! Map<String, dynamic>) return null;
            return result;
          };
        }

        // 源声明 viaWebview 时走离屏 WebView（真实浏览器 TLS 栈）取字节：
        // 部分站点（comix.to 图片 CDN，2026-10 起）的 Cloudflare WAF 按客户端
        // TLS 指纹拦截，dart:io HttpClient 无论带什么头都 403，WebView2 可过。
        // 失败时同样进入下方的 onLoadFailed / net-retry 重试逻辑。
        if (configs['viaWebview'] == true) {
          // WebView 通道拿不到字节流进度，先发一条 0 进度让阅读页显示
          // "在加载"（否则会一直停在静止的圈上，看起来像卡死）。
          yield const ImageDownloadProgress(currentBytes: 0, totalBytes: null);
          // 阅读默认 30s 快速失败；下载则按 download.dart 多轮渐进超时传入的
          // 本轮预算（5→10→15→30s）走，单次失败不再陪跑整段超时（S12 用户反馈：
          // 单张失败图原要等满 30s 才跳，极反效率）。[downloadTimeoutSeconds]
          // 仅作无覆盖时的兜底。
          var webviewTimeout =
              (configs['timeoutSeconds'] as num?)?.toInt() ?? 30;
          if (forDownload) {
            webviewTimeout =
                (configs['downloadTimeoutSeconds'] as num?)?.toInt() ?? 30;
            if (downloadTimeoutSeconds != null) {
              webviewTimeout = downloadTimeoutSeconds;
            }
          }
          var data = await ComixClient.fetchImageBytes(
            configs['url'] ?? imageKey,
            timeoutSeconds: webviewTimeout,
          );
          if (!forDownload) {
            await CacheManager().writeCache(cacheKey, data);
          }
          yield ImageDownloadProgress(
            currentBytes: data.length,
            totalBytes: data.length,
            imageBytes: data,
          );
          return;
        }

        var dio = AppDio(
          BaseOptions(
            headers: configs['headers'],
            method: configs['method'] ?? 'GET',
            responseType: ResponseType.stream,
          ),
        );

        var req = await dio.request<ResponseBody>(
          configs['url'] ?? imageKey,
          data: configs['data'],
        );
        var stream = req.data?.stream ?? (throw "Error: Empty response body.");
        int? expectedBytes = req.data!.contentLength;
        if (expectedBytes == -1) {
          expectedBytes = null;
        }
        var buffer = <int>[];
        // 源可以声明更长的空闲超时：条漫 CDN（如 comix.to 的 wowpic）在
        // 高负载时单张图响应极慢，30s 会误判为超时——BT 的下载实测用的是
        // 90s 读超时。JS 侧在 onImageLoad 返回里带 `timeoutSeconds` 即可生效。
        final idleTimeout = Duration(
          seconds:
              (configs['timeoutSeconds'] as num?)?.toInt() ??
              _imageStreamIdleTimeout.inSeconds,
        );
        await for (var data in stream.timeout(idleTimeout)) {
          buffer.addAll(data);
          yield ImageDownloadProgress(
            currentBytes: buffer.length,
            totalBytes: expectedBytes,
          );
        }

        if (configs['onResponse'] is JSInvokable) {
          dynamic result = (configs['onResponse'] as JSInvokable)([
            Uint8List.fromList(buffer),
          ]);
          if (result is Future) {
            result = await result;
          }
          if (result is List<int>) {
            buffer = result;
          } else {
            throw "Error: Invalid onResponse result.";
          }
          (configs['onResponse'] as JSInvokable).free();
        }

        Uint8List data;
        if (buffer is Uint8List) {
          data = buffer;
        } else {
          data = Uint8List.fromList(buffer);
          buffer.clear();
        }

        if (configs['modifyImage'] != null) {
          var newData = await modifyImageWithScript(
            data,
            configs['modifyImage'],
          );
          data = newData;
        }

        if (!forDownload) {
          await CacheManager().writeCache(cacheKey, data);
        }
        yield ImageDownloadProgress(
          currentBytes: data.length,
          totalBytes: data.length,
          imageBytes: data,
        );
        return;
      } catch (e) {
        // The source's own recovery hook takes priority over the generic
        // net-retry below: onLoadFailed is how a source re-signs / refreshes an
        // expired image URL, which typically surfaces as a 403/401 (a
        // clientError). Letting the classifier fast-fail those before the hook
        // ran would silently break every source that relies on URL refresh, so
        // the hook gets first crack at ANY error — the original behavior.
        if (retryLimit >= 0 && onLoadFailed != null) {
          var newConfig = await onLoadFailed();
          (configs['onLoadFailed'] as JSInvokable).free();
          onLoadFailed = null;
          if (newConfig == null) {
            rethrow;
          }
          configs = newConfig;
          retryLimit--;
          continue;
        }
        // A hook exists but its retry budget is spent: rethrow, matching the
        // original behavior. (Falling through to net-retry here would re-free
        // and re-wrap the hook's JSInvokable across loops.)
        if (onLoadFailed != null) {
          rethrow;
        }
        // No source-provided recovery: retry transient/rate-limited errors a
        // bounded number of times with backoff (429/503/网络抖动/5xx). This is
        // the only retry chance for sources without an onLoadFailed hook.
        var status = e is DioException ? e.response?.statusCode : null;
        var cls = status != null
            ? classifyStatus(status)
            : HttpErrorClass.transient;
        if ((cls == HttpErrorClass.rateLimited ||
                cls == HttpErrorClass.transient) &&
            netRetries > 0) {
          netRetries--;
          Duration? ra;
          if (cls == HttpErrorClass.rateLimited) {
            ra = e is DioException
                ? parseRetryAfter(e.response?.headers.value('retry-after'))
                : null;
            onRateLimited?.call(ra);
          }
          await Future.delayed(backoff(2 - netRetries, retryAfter: ra));
          continue;
        }
        // 4xx（非 429）或重试次数耗尽：重试无益，快速失败。
        rethrow;
      } finally {
        if (onLoadFailed != null) {
          (configs['onLoadFailed'] as JSInvokable).free();
        }
      }
    }
  }
}

/// A wrapper class for a stream that
/// allows multiple listeners to listen to the same stream.
class _StreamWrapper<T> {
  final Stream<T> _stream;

  final List<StreamController> controllers = [];

  final void Function(_StreamWrapper<T> wrapper) onClosed;

  final bool Function(T data)? isReplayable;

  bool isClosed = false;

  bool _hasReplayableData = false;

  late T _replayableData;

  _StreamWrapper(this._stream, this.onClosed, {this.isReplayable}) {
    _listen();
  }

  void _listen() async {
    try {
      await for (var data in _stream) {
        if (isClosed) {
          break;
        }
        if (isReplayable?.call(data) ?? false) {
          _replayableData = data;
          _hasReplayableData = true;
        }
        for (var controller in controllers) {
          if (!controller.isClosed) {
            controller.add(data);
          }
        }
      }
    } catch (e) {
      for (var controller in controllers) {
        if (!controller.isClosed) {
          controller.addError(e);
        }
      }
    } finally {
      for (var controller in controllers) {
        if (!controller.isClosed) {
          controller.close();
        }
      }
    }
    controllers.clear();
    isClosed = true;
    onClosed(this);
  }

  Stream<T> get stream {
    if (isClosed) {
      throw Exception('Stream is closed');
    }
    var controller = StreamController<T>();
    controllers.add(controller);
    controller.onCancel = () {
      controllers.remove(controller);
    };
    if (_hasReplayableData) {
      controller.add(_replayableData);
    }
    return controller.stream;
  }

  void cancel() {
    for (var controller in controllers) {
      controller.close();
    }
    controllers.clear();
    isClosed = true;
  }
}

class ImageDownloadProgress {
  final int currentBytes;

  final int? totalBytes;

  final Uint8List? imageBytes;

  const ImageDownloadProgress({
    required this.currentBytes,
    required this.totalBytes,
    this.imageBytes,
  });
}

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' hide Cookie;
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/pages/webview.dart';
import 'package:venera/utils/io.dart';

import 'cookie_jar.dart';

class CloudflareException implements DioException {
  final String url;

  final Map<String, String> headers;

  CloudflareException(this.url, [this.headers = const {}]);

  @override
  String toString() {
    return "CloudflareException: $url";
  }

  static CloudflareException? fromString(String message) {
    var match = RegExp(r"CloudflareException: (.+)").firstMatch(message);
    if (match == null) return null;
    var url = match.group(1)!;
    return CloudflareException(url, _cloudflareRequestHeaders[url] ?? const {});
  }

  @override
  DioException copyWith({
    RequestOptions? requestOptions,
    Response<dynamic>? response,
    DioExceptionType? type,
    Object? error,
    StackTrace? stackTrace,
    String? message,
  }) {
    return this;
  }

  @override
  Object? get error => this;

  @override
  String? get message => toString();

  @override
  RequestOptions get requestOptions => RequestOptions();

  @override
  Response? get response => null;

  @override
  StackTrace get stackTrace => StackTrace.empty;

  @override
  DioExceptionType get type => DioExceptionType.badResponse;

  @override
  DioExceptionReadableStringBuilder? stringBuilder;
}

class CloudflareInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    // 簇内已验证过 → 直接把票据 cookie 带上（重定向跳不会重跑拦截器）。
    _injectClusterCookies(options);

    if (options.method.toUpperCase() == 'GET' &&
        options.responseType != ResponseType.stream &&
        options.responseType != ResponseType.bytes) {
      var cachedHtml = _takeVerifiedHtml(options.uri);
      if (cachedHtml != null) {
        handler.resolve(
          Response<dynamic>(
            requestOptions: options,
            data: cachedHtml.html,
            statusCode: 200,
            statusMessage: 'OK',
            headers: Headers.fromMap({
              'content-type': ['text/html; charset=utf-8'],
            }),
          ),
        );
        return;
      }
    }

    var cookieHeader = _readHeaderIgnoreCase(options.headers, 'cookie');
    if (_containsCloudflareCookie(
          _parseCookieHeader(cookieHeader ?? '').keys,
        ) ||
        _isCloudflareVerifiedHost(options.uri.host)) {
      _applyBrowserHeaders(options);
    }
    handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    if (err.response?.statusCode == 403) {
      handler.next(_check(err.response!) ?? err);
    } else {
      handler.next(err);
    }
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    if (response.statusCode == 403) {
      var err = _check(response);
      if (err != null) {
        handler.reject(err);
        return;
      }
    }
    handler.next(response);
  }

  CloudflareException? _check(Response response) {
    if (response.headers['cf-mitigated']?.firstOrNull == "challenge") {
      var uri = response.requestOptions.uri;
      var url = uri.toString();
      _cloudflareRequestHeaders[url] = _headersForBrowser(
        response.requestOptions.headers,
      );
      SingleInstanceCookieJar.instance?.deleteByName(uri, 'cf_clearance');
      _unmarkCloudflareVerifiedHost(uri.host);
      return CloudflareException(url, _cloudflareRequestHeaders[url]!);
    }
    // Gatekeeper 风格 WAF（如 baozimh 系镜像）：403 + JSON
    // `{"error":"challenge_required","challenge_url":"/__gatekeeper_challenge/start?return=..."}`
    // 该挑战是非交互 JS PoW，把 challenge_url 拼成完整 URL 作为验证入口，
    // webview 打开后自动完成并重定向回 return 页，cookie 随之持久化。
    var uri = response.realUri;
    if (!uri.hasScheme || uri.host.isEmpty) {
      uri = response.requestOptions.uri;
    }
    var challengePath = _extractGatekeeperChallengeUrl(response.data);
    if (challengePath != null) {
      var origin = "${uri.scheme}://${uri.host}";
      if (uri.port != 0 && uri.port != (uri.scheme == 'https' ? 443 : 80)) {
        origin += ":${uri.port}";
      }
      var solveUrl = "$origin$challengePath";
      _cloudflareRequestHeaders[solveUrl] = _headersForBrowser(
        response.requestOptions.headers,
      );
      _unmarkCloudflareVerifiedHost(uri.host);
      Log.info("Cloudflare", "Gatekeeper challenge detected: $solveUrl");
      return CloudflareException(
        solveUrl,
        _cloudflareRequestHeaders[solveUrl]!,
      );
    }
    return null;
  }

  /// 从 403 响应体提取 gatekeeper 挑战路径。兼容 dio 已解码的 Map 与原始字符串。
  static String? _extractGatekeeperChallengeUrl(dynamic data) {
    if (data == null) return null;
    if (data is Map) {
      if (data['error'] != 'challenge_required') return null;
      var path = data['challenge_url'];
      return path is String && path.isNotEmpty ? path : null;
    }
    if (data is String && data.contains('"challenge_required"')) {
      var match = RegExp(r'"challenge_url"\s*:\s*"([^"]+)"').firstMatch(data);
      if (match != null) return match.group(1);
    }
    return null;
  }
}

/// 站点簇：同一站点常在多个 host 之间轮换/302（baozimh 系的
/// appcn.baozimh.com / www.baozimh.com / cn.webmota.com …）。挑战 cookie
/// 按 host 下发，而 dio 的重定向跳不会重跑 cookie 拦截器 —— 于是"验证过了
/// 但下个请求还是被挑战"，用户每翻一章就要重跑一次 2 分钟 PoW。
/// 这里把同一可注册域归一成一个簇，验证一次后缓存 cookie 与"已验证"标记，
/// 后续簇内任意 host 的请求都直接带上（[CloudflareInterceptor.onRequest]）。
String _clusterOf(String host) {
  var parts = host.toLowerCase().split('.').where((p) => p.isNotEmpty).toList();
  if (parts.length <= 2) return parts.join('.');
  return parts.sublist(parts.length - 2).join('.');
}

/// 簇 → 验证成功时间。
final _verifiedClusters = <String, DateTime>{};

/// 簇 → 验证拿到的票据 cookie。
final _clusterCookies = <String, Map<String, Cookie>>{};

/// 簇内默认复用窗口：30 分钟内不再跑第二次 PoW（票据有效期通常远长于此，
/// 真过期时用户仍可手动验证）。
const _clusterVerificationTtl = Duration(minutes: 30);

/// 该 host 所在簇最近是否验证过 → loading 层据此跳过自动 headless 验证。
bool isClusterVerified(String host) {
  final at = _verifiedClusters[_clusterOf(host)];
  if (at == null) return false;
  return DateTime.now().difference(at) < _clusterVerificationTtl;
}

void _markClusterVerified(String host, Iterable<Cookie> cookies) {
  final cluster = _clusterOf(host);
  _verifiedClusters[cluster] = DateTime.now();
  final store = _clusterCookies.putIfAbsent(cluster, () => <String, Cookie>{});
  for (final cookie in cookies) {
    if (cookie.name.isEmpty || cookie.value.isEmpty) continue;
    store[cookie.name] = cookie;
  }
  Log.info(
    "Cloudflare",
    "cluster '$cluster' verified (${store.length} cookies cached)",
  );
}

/// 把簇内已验证的票据 cookie 注入请求。
///
/// 为什么必须在请求阶段注入：dio 的 cookie 拦截器只在原始请求上跑一次，
/// 302 到另一个 host 后不会再带 cookie —— 这正是"每章都要重新验证"的直接
/// 原因。这里在 onRequest 统一补上。
void _injectClusterCookies(RequestOptions options) {
  final store = _clusterCookies[_clusterOf(options.uri.host)];
  if (store == null || store.isEmpty) return;
  final existing = _readHeaderIgnoreCase(options.headers, 'cookie') ?? '';
  final have = _parseCookieHeader(
    existing,
  ).keys.map((e) => e.toLowerCase()).toSet();
  final add = <String>[];
  for (final cookie in store.values) {
    if (!_isClearanceCookie(cookie)) continue;
    if (have.contains(cookie.name.toLowerCase())) continue;
    add.add("${cookie.name}=${cookie.value}");
  }
  if (add.isEmpty) return;
  final merged = existing.isEmpty
      ? add.join('; ')
      : "$existing; ${add.join('; ')}";
  _setHeader(options, 'cookie', merged);
  Log.info(
    "Cloudflare",
    "injected ${add.length} verified cookie(s) for ${options.uri.host}",
  );
}

const _cloudflareVerifiedHostsKey = 'cloudflareVerifiedHosts';

final _cloudflareRequestHeaders = <String, Map<String, String>>{};

final _verifiedHtmlCache = <String, _VerifiedHtml>{};

class _VerifiedHtml {
  final String html;

  final DateTime expiresAt;

  _VerifiedHtml(this.html, this.expiresAt);
}

bool _isCloudflareCookieName(String cookieName) {
  var name = cookieName.trim().toLowerCase();
  return name == 'cf_clearance' ||
      name == '__cf_bm' ||
      name == '_cfuvid' ||
      name.startsWith('cf_chl_');
}

/// 挑战"票据"cookie：拿到它才算验证通过。
/// - Cloudflare managed challenge 通过后下发 `cf_clearance`；
/// - baozimh 系 gatekeeper PoW 通过后下发 `__Host-gk_browser_*`。
///
/// ⚠️ 成功判定必须走 cookie 而不能只看"页面是否还有挑战标记"：站点自身
/// 的 JS/HTML 里就引用挑战字符串（baozimh 每个页面都带
/// `__gatekeeper_challenge` 引用），标记永远消不掉 —— 线上表现为 headless
/// 验证无限 "challenge still running" 直到超时、手动验证完原页面也不刷新。
bool _isClearanceCookie(Cookie c) {
  var n = c.name.toLowerCase();
  return n == 'cf_clearance' || n.contains('gk_browser');
}

bool _hasClearanceCookie(Iterable<Cookie> cookies) =>
    cookies.any(_isClearanceCookie);

bool _containsCloudflareCookie(Iterable<String> cookieNames) {
  return cookieNames.any(_isCloudflareCookieName);
}

Map<String, String> _parseCookieHeader(String cookieHeader) {
  var cookies = <String, String>{};
  if (cookieHeader.trim().isEmpty) {
    return cookies;
  }
  for (var segment in cookieHeader.split(';')) {
    var part = segment.trim();
    if (part.isEmpty) {
      continue;
    }
    var idx = part.indexOf('=');
    if (idx <= 0) {
      continue;
    }
    var name = part.substring(0, idx).trim();
    var value = part.substring(idx + 1).trim();
    if (name.isNotEmpty) {
      cookies[name] = value;
    }
  }
  return cookies;
}

String? _readHeaderIgnoreCase(Map<String, dynamic> headers, String name) {
  for (var entry in headers.entries) {
    if (entry.key.toLowerCase() == name.toLowerCase()) {
      return entry.value?.toString();
    }
  }
  return null;
}

Map<String, String> _headersForBrowser(Map<String, dynamic> headers) {
  const skippedHeaders = {
    'accept-encoding',
    'connection',
    'content-length',
    'cookie',
    'host',
  };
  var result = <String, String>{};
  headers.forEach((key, value) {
    var normalizedKey = key.toLowerCase();
    if (value == null || skippedHeaders.contains(normalizedKey)) {
      return;
    }
    var normalizedValue = value.toString().trim();
    if (normalizedValue.isNotEmpty) {
      result[key] = normalizedValue;
    }
  });
  return result;
}

bool _headersNeedInAppWebview(Map<String, String> headers) {
  const browserControlledHeaders = {
    'accept',
    'accept-language',
    'upgrade-insecure-requests',
    'user-agent',
  };
  return headers.keys.any(
    (key) => !browserControlledHeaders.contains(key.toLowerCase()),
  );
}

bool _isCloudflareChallengePage(String head, String body) {
  var content = "$head\n$body".toLowerCase();
  return content.contains('#challenge-success-text') ||
      content.contains("#challenge-error-text") ||
      content.contains("#challenge-form") ||
      content.contains("challenge-platform") ||
      content.contains("/cdn-cgi/challenge-platform/") ||
      content.contains("window._cf_chl_opt") ||
      content.contains("__cf_chl_opt") ||
      content.contains("cf-browser-verification") ||
      content.contains("cf-challenge-running") ||
      content.contains("cf-challenge") ||
      content.contains("cf-turnstile") ||
      content.contains("cf_captcha_kind") ||
      content.contains("cf_chl_") ||
      content.contains("verify you are human") ||
      content.contains("checking your browser before accessing") ||
      content.contains("checking if the site connection is secure") ||
      content.contains("please wait while we verify") ||
      content.contains("<title>just a moment") ||
      content.contains("just a moment...") ||
      // Gatekeeper 风格挑战页（baozimh 系）：非 Cloudflare，但同样是
      // "自动完成的浏览器验证"，出现这些标记时页面尚未通过。
      content.contains("__gatekeeper_challenge") ||
      content.contains("gatekeeper_challenge") ||
      content.contains('data-state="checking"') ||
      content.contains("正在验证浏览器");
}

String _normalizeDesktopWebviewValue(String? raw, String fallback) {
  if (raw == null || raw.isEmpty) {
    return fallback;
  }
  var value = raw.trim();
  try {
    var decoded = jsonDecode(value);
    if (decoded is String) {
      value = decoded;
    } else if (decoded != null) {
      value = decoded.toString();
    }
  } catch (_) {
    if ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))) {
      value = value.substring(1, value.length - 1);
    }
  }
  value = value.trim();
  if (value.isEmpty) {
    return fallback;
  }
  return value;
}

String _verifiedHtmlCacheKey(Uri uri) => uri.toString();

bool _cacheVerifiedHtml(Uri uri, String html) {
  if (html.trim().isEmpty || _isCloudflareChallengePage('', html)) {
    return false;
  }
  _verifiedHtmlCache[_verifiedHtmlCacheKey(uri)] = _VerifiedHtml(
    html,
    DateTime.now().add(const Duration(minutes: 2)),
  );
  Log.info("Cloudflare", "Cached verified WebView HTML for $uri");
  return true;
}

_VerifiedHtml? _takeVerifiedHtml(Uri uri) {
  var cached = _verifiedHtmlCache.remove(_verifiedHtmlCacheKey(uri));
  if (cached == null || cached.expiresAt.isBefore(DateTime.now())) {
    return null;
  }
  Log.info("Cloudflare", "Using cached verified WebView HTML for $uri");
  return cached;
}

bool _sameSiteHost(String a, String b) {
  var left = a.toLowerCase();
  var right = b.toLowerCase();
  String site(String host) {
    var parts = host.split('.');
    if (parts.length <= 2) {
      return host;
    }
    return parts.sublist(parts.length - 2).join('.');
  }

  return left == right ||
      left.endsWith('.$right') ||
      right.endsWith('.$left') ||
      site(left) == site(right);
}

void _applyBrowserHeaders(RequestOptions options) {
  _setHeader(options, 'User-Agent', appdata.implicitData['ua'] ?? webUA);
  _putHeaderIfAbsent(
    options,
    'Accept',
    'text/html,application/xhtml+xml,application/xml;q=0.9,'
        'image/avif,image/webp,image/apng,*/*;q=0.8',
  );
  _putHeaderIfAbsent(options, 'Accept-Language', 'zh-CN,zh;q=0.9,en;q=0.8');
  if (options.method.toUpperCase() == 'GET') {
    _putHeaderIfAbsent(options, 'Upgrade-Insecure-Requests', '1');
  }
}

void _setHeader(RequestOptions options, String name, Object value) {
  var keys = options.headers.keys
      .where((key) => key.toLowerCase() == name.toLowerCase())
      .toList();
  for (var key in keys) {
    options.headers.remove(key);
  }
  options.headers[name] = value;
}

void _putHeaderIfAbsent(RequestOptions options, String name, Object value) {
  var exists = options.headers.keys.any(
    (key) => key.toLowerCase() == name.toLowerCase(),
  );
  if (!exists) {
    options.headers[name] = value;
  }
}

bool _isCloudflareVerifiedHost(String host) {
  var data = appdata.implicitData[_cloudflareVerifiedHostsKey];
  return data is List && data.contains(host);
}

void _markCloudflareVerifiedHost(String host) {
  var data = appdata.implicitData[_cloudflareVerifiedHostsKey];
  var hosts = data is List ? data.whereType<String>().toSet() : <String>{};
  if (hosts.add(host)) {
    appdata.implicitData[_cloudflareVerifiedHostsKey] = hosts.toList();
    appdata.writeImplicitData();
  }
}

void _unmarkCloudflareVerifiedHost(String host) {
  var data = appdata.implicitData[_cloudflareVerifiedHostsKey];
  if (data is! List) {
    return;
  }
  var hosts = data.whereType<String>().toSet();
  if (hosts.remove(host)) {
    appdata.implicitData[_cloudflareVerifiedHostsKey] = hosts.toList();
    appdata.writeImplicitData();
  }
}

String _cloudflareProfilePath(Uri uri) {
  var host = uri.host.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
  return "${App.dataPath}\\cloudflare_webview\\$host";
}

void _resetCloudflareProfile(Uri uri) {
  if (!App.isWindows) {
    return;
  }
  try {
    var dir = Directory(_cloudflareProfilePath(uri));
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  } catch (e, s) {
    Log.warning(
      "Cloudflare",
      "Failed to reset Cloudflare webview profile\n$e\n$s",
    );
  }
}

/// 读取离屏验证 WebView 当前的 cookie（平台 cookie + document.cookie）。
Future<List<Cookie>> _collectHeadlessCookies(
  InAppWebViewController controller,
  String url,
) async {
  var cookies = <Cookie>[];
  try {
    var currentUrl = (await controller.getUrl())?.toString() ?? url;
    var currentUri = Uri.tryParse(currentUrl) ?? Uri.parse(url);
    for (var cookieUrl in {url, currentUrl}) {
      try {
        cookies.addAll(
          cookiesFromPlatformCookies(
            await controller.getCookies(cookieUrl),
            fallbackDomain: currentUri.host,
          ),
        );
      } catch (_) {}
    }
    var rawCookie = await controller.evaluateJavascript(
      source: "document.cookie",
    );
    var jsCookies = _parseCookieHeader(rawCookie?.toString() ?? '');
    cookies.addAll(
      jsCookies.entries.map(
        (e) => Cookie(e.key, e.value)..domain = currentUri.host,
      ),
    );
  } catch (_) {}
  return cookies;
}

/// 尝试用离屏 HeadlessInAppWebView 自动完成非交互挑战（Cloudflare JS 挑战 /
/// gatekeeper PoW——两者都是页面加载后自动跑 JS、无需人工点击）。
///
/// 成功条件：页面加载完成且无挑战标记 → 收集全部 cookie 存入应用 cookie jar
/// 并标记 host 已验证。失败（超时/遇到交互式验证码）返回 false，由调用方
/// 决定是否走可见 webview 的 [passCloudflare] 手动流程。
///
/// 整个过程无窗口、用户无感知，成功后调用 retry 即可恢复加载。
Future<bool> tryHeadlessVerification(CloudflareException e) async {
  HeadlessInAppWebView? webview;
  try {
    webview = HeadlessInAppWebView(
      webViewEnvironment: AppWebview.webViewEnvironment,
      initialUrlRequest: URLRequest(
        url: WebUri(e.url),
        headers: e.headers.isEmpty ? null : e.headers,
      ),
    );
    await webview.run();
    final controller = webview.webViewController!;
    // baozimh 系 gatekeeper 2026-10 起把 PoW 难度提到 difficultyBits:12、
    // computeMs:120000——挑战页自身预期计算约 2 分钟、票据寿命 lifeMs 180s。
    // 原 45s 上限让 headless 验证必败（日志特征：无限 "challenge still
    // running" 后超时）。放宽到 200s 覆盖最坏情况。
    final deadline = DateTime.now().add(const Duration(seconds: 200));
    var solved = false;
    String html = '';
    Uri currentUri = Uri.parse(e.url);
    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 1500));
      String head;
      String body;
      try {
        head =
            (await controller.evaluateJavascript(
              source: "(document.head && document.head.innerHTML) || ''",
            ))?.toString() ??
            '';
        body =
            (await controller.evaluateJavascript(
              source: "(document.body && document.body.innerHTML) || ''",
            ))?.toString() ??
            '';
      } catch (_) {
        continue;
      }
      if (head.isEmpty && body.isEmpty) {
        continue; // 页面尚未加载
      }
      // gatekeeper 挑战失败态（页面显示"重试"按钮）：继续等也不会过，
      // 提前退出让用户走手动验证。
      var normalizedBody = _normalizeDesktopWebviewValue(body, '');
      if (normalizedBody.contains('data-state="failed"')) {
        Log.info("Cloudflare", "headless: challenge entered failed state");
        break;
      }
      if (_isCloudflareChallengePage(head, body)) {
        // 标记仍在不代表没通过：站点自身 JS 常引用挑战字符串，标记永远
        // 消不掉。票据 cookie（cf_clearance / gk_browser）到手即算通过。
        var early = await _collectHeadlessCookies(controller, e.url);
        if (!_hasClearanceCookie(early)) {
          Log.info("Cloudflare", "headless: challenge still running");
          continue;
        }
        Log.info(
          "Cloudflare",
          "headless: clearance cookie present despite challenge markers",
        );
      }
      // 页面已无挑战标记（挑战通过并跳转到 return 页）。收集 cookie。
      var currentUrl = (await controller.getUrl())?.toString() ?? e.url;
      currentUri = Uri.tryParse(currentUrl) ?? Uri.parse(e.url);
      var ua = await controller.getUA();
      if (ua != null && ua.isNotEmpty) {
        appdata.implicitData['ua'] = ua;
        appdata.writeImplicitData();
      }
      html =
          (await controller.evaluateJavascript(
            source:
                "(document.documentElement && document.documentElement.outerHTML) || ''",
          ))?.toString() ??
          '';
      var cookies = <Cookie>[];
      for (var cookieUrl in {e.url, currentUrl}) {
        try {
          cookies.addAll(
            cookiesFromPlatformCookies(
              await controller.getCookies(cookieUrl),
              fallbackDomain: currentUri.host,
            ),
          );
        } catch (err) {
          Log.warning("Cloudflare", "headless: getCookies failed: $err");
        }
      }
      try {
        var rawCookie = await controller.evaluateJavascript(
          source: "document.cookie",
        );
        var jsCookies = _parseCookieHeader(rawCookie?.toString() ?? '');
        cookies.addAll(
          jsCookies.entries.map((e2) {
            var cookie = Cookie(e2.key, e2.value);
            cookie.domain = currentUri.host;
            return cookie;
          }),
        );
      } catch (_) {}
      // 标记消失但既没票据也没内容：可能停在空白页/中间页，别误判成功。
      if (!_hasClearanceCookie(cookies) && html.isEmpty) {
        Log.info(
          "Cloudflare",
          "headless: markers gone but no clearance cookie/content yet",
        );
        continue;
      }
      if (cookies.isNotEmpty) {
        SingleInstanceCookieJar.instance?.saveFromResponse(
          Uri.parse(e.url),
          cookies,
        );
        SingleInstanceCookieJar.instance?.saveFromResponse(currentUri, cookies);
        // 记录簇级验证结果：后续该站点其它 host（302 跳过去的那些）的请求
        // 直接复用 cookie，不再逐个 host 重跑 PoW
        // （用户诉求："验证一次，剩余章节不再验证"）。
        _markClusterVerified(currentUri.host, cookies);
        _markClusterVerified(Uri.parse(e.url).host, cookies);
      }
      Log.info(
        "Cloudflare",
        "headless: solved, saved ${cookies.length} cookies for "
            "${currentUri.host}",
      );
      solved = true;
      break;
    }
    if (solved) {
      // Windows 端 evaluateJavascript 返回值可能带双重 JSON 编码，缓存前解包。
      var normalizedHtml = _normalizeDesktopWebviewValue(html, '');
      if (_sameSiteHost(currentUri.host, Uri.parse(e.url).host)) {
        _cacheVerifiedHtml(currentUri, normalizedHtml);
      }
      _markCloudflareVerifiedHost(Uri.parse(e.url).host);
      _markCloudflareVerifiedHost(currentUri.host);
      _cloudflareRequestHeaders.remove(e.url);
    }
    return solved;
  } catch (err, s) {
    Log.warning("Cloudflare", "headless verification failed\n$err\n$s");
    return false;
  } finally {
    try {
      await webview?.dispose();
    } catch (_) {}
  }
}

void passCloudflare(CloudflareException e, void Function() onFinished) async {
  var url = e.url;
  var uri = Uri.parse(url);
  var requestHeaders = e.headers;
  var completed = false;
  var verificationSucceeded = false;
  SingleInstanceCookieJar.instance?.deleteByName(uri, 'cf_clearance');
  _resetCloudflareProfile(uri);

  void finish() {
    if (completed) {
      return;
    }
    completed = true;
    if (verificationSucceeded) {
      _cloudflareRequestHeaders.remove(url);
      onFinished();
    }
  }

  bool saveCookies(Uri targetUri, Map<String, String> cookies) {
    if (cookies.isEmpty) {
      Log.info("Cloudflare", "Saved 0 cookies, cloudflareCookie=false");
      return false;
    }
    var domain = targetUri.host;
    var splits = domain.split('.');
    if (splits.length > 1) {
      domain = ".${splits[splits.length - 2]}.${splits[splits.length - 1]}";
    }
    var hasCloudflareCookie = _containsCloudflareCookie(cookies.keys);
    SingleInstanceCookieJar.instance?.deleteByName(targetUri, 'cf_clearance');
    final cookieList = List<Cookie>.generate(cookies.length, (index) {
      var cookie = Cookie(
        cookies.keys.elementAt(index),
        cookies.values.elementAt(index),
      );
      cookie.domain = domain;
      return cookie;
    });
    SingleInstanceCookieJar.instance?.saveFromResponse(targetUri, cookieList);
    Log.info(
      "Cloudflare",
      "Saved ${cookies.length} cookies, "
          "cloudflareCookie=$hasCloudflareCookie",
    );
    if (hasCloudflareCookie) {
      _markCloudflareVerifiedHost(targetUri.host);
      // 手动验证同样登记簇级缓存（302 过去的其它 host 也能复用）。
      _markClusterVerified(targetUri.host, cookieList);
    }
    return hasCloudflareCookie;
  }

  // Desktop WebView can read cookies more reliably, but it cannot replay
  // request headers like Referer that some image/CDN challenges require.
  var useDesktopWebview = false;
  if (App.isDesktop && !_headersNeedInAppWebview(requestHeaders)) {
    try {
      useDesktopWebview = await DesktopWebview.isAvailable();
    } catch (e, s) {
      Log.warning(
        "Cloudflare",
        "Desktop webview is unavailable, fallback to AppWebview\n$e\n$s",
      );
    }
  }

  if (useDesktopWebview) {
    var webview = DesktopWebview(
      initialUrl: url,
      userDataFolderWindows: _cloudflareProfilePath(uri),
      onTitleChange: (title, controller) async {
        var currentUrl = _normalizeDesktopWebviewValue(
          await controller.evaluateJavascript("location.href"),
          url,
        );
        var currentUri = Uri.tryParse(currentUrl) ?? uri;
        var head = _normalizeDesktopWebviewValue(
          await controller.evaluateJavascript(
            "(document.head && document.head.innerHTML) || ''",
          ),
          '',
        );
        var body = _normalizeDesktopWebviewValue(
          await controller.evaluateJavascript(
            "(document.body && document.body.innerHTML) || ''",
          ),
          '',
        );
        Log.info("Cloudflare", "Checking head: $head");
        var isChallenging = _isCloudflareChallengePage(head, body);
        // 票据 cookie 先于标记检查：站点 JS 自带挑战字符串时标记永不消失。
        var earlyClearance = false;
        try {
          var earlyCookies = await controller.getCookies(currentUrl);
          earlyClearance = earlyCookies.keys.any(
            (k) =>
                k == 'cf_clearance' || k.toLowerCase().contains('gk_browser'),
          );
        } catch (_) {}
        if (!isChallenging || earlyClearance) {
          if (isChallenging) {
            Log.info(
              "Cloudflare",
              "clearance cookie present despite challenge markers",
            );
          } else {
            Log.info("Cloudflare", "No Cloudflare challenge markers found");
          }
          var ua = controller.userAgent;
          if (ua != null) {
            appdata.implicitData['ua'] = ua;
            appdata.writeImplicitData();
          }
          var html = _normalizeDesktopWebviewValue(
            await controller.evaluateJavascript(
              "(document.documentElement && document.documentElement.outerHTML) || ''",
            ),
            '',
          );
          var hasVerifiedHtml = false;
          if (_sameSiteHost(currentUri.host, uri.host)) {
            hasVerifiedHtml = _cacheVerifiedHtml(uri, html);
            hasVerifiedHtml =
                _cacheVerifiedHtml(currentUri, html) || hasVerifiedHtml;
          }
          var cookiesMap = await controller.getCookies(currentUrl);
          try {
            var rawCookie = await controller.evaluateJavascript(
              "document.cookie",
            );
            cookiesMap.addAll(
              _parseCookieHeader(_normalizeDesktopWebviewValue(rawCookie, '')),
            );
          } catch (e, s) {
            Log.warning("Cloudflare", "Read document.cookie failed\n$e\n$s");
          }
          var hasCloudflareCookie = saveCookies(currentUri, cookiesMap);
          if (hasCloudflareCookie || hasVerifiedHtml) {
            _markCloudflareVerifiedHost(uri.host);
            _markCloudflareVerifiedHost(currentUri.host);
            verificationSucceeded = true;
            controller.close();
            finish();
          } else {
            Log.info("Cloudflare", "Waiting for Cloudflare cookie or HTML");
          }
        }
      },
      onClose: finish,
    );
    webview.open();
  } else {
    bool success = false;
    void check(InAppWebViewController controller) async {
      if (success) {
        return;
      }
      var head =
          (await controller.evaluateJavascript(
            source: "document.head.innerHTML",
          ))?.toString() ??
          "";
      var body =
          (await controller.evaluateJavascript(
            source: "document.body.innerHTML",
          ))?.toString() ??
          "";
      Log.info("Cloudflare", "Checking head: $head");
      var isChallenging = _isCloudflareChallengePage(head, body);
      // 票据 cookie 先于标记检查（站点 JS 自带挑战字符串时标记永不消失）。
      var earlyClearance = false;
      try {
        var currentUrl0 = (await controller.getUrl())?.toString() ?? url;
        var currentUri0 = Uri.tryParse(currentUrl0) ?? uri;
        earlyClearance = _hasClearanceCookie(
          cookiesFromPlatformCookies(
            await controller.getCookies(currentUrl0),
            fallbackDomain: currentUri0.host,
          ),
        );
      } catch (_) {}
      if (!isChallenging || earlyClearance) {
        if (isChallenging) {
          Log.info(
            "Cloudflare",
            "clearance cookie present despite challenge markers",
          );
        } else {
          Log.info("Cloudflare", "No Cloudflare challenge markers found");
        }
        var ua = await controller.getUA();
        if (ua != null) {
          appdata.implicitData['ua'] = ua;
          appdata.writeImplicitData();
        }
        var currentUrl = (await controller.getUrl())?.toString() ?? url;
        var currentUri = Uri.tryParse(currentUrl) ?? uri;
        var htmlText =
            (await controller.evaluateJavascript(
              source:
                  "(document.documentElement && document.documentElement.outerHTML) || ''",
            ))?.toString() ??
            '';
        var hasVerifiedHtml = false;
        if (_sameSiteHost(currentUri.host, uri.host)) {
          hasVerifiedHtml = _cacheVerifiedHtml(uri, htmlText);
          hasVerifiedHtml =
              _cacheVerifiedHtml(currentUri, htmlText) || hasVerifiedHtml;
        }
        var cookies = <Cookie>[];
        for (var cookieUrl in {url, currentUrl}) {
          cookies.addAll(
            cookiesFromPlatformCookies(
              await controller.getCookies(cookieUrl),
              fallbackDomain: currentUri.host,
            ),
          );
        }
        try {
          var rawCookie = await controller.evaluateJavascript(
            source: "document.cookie",
          );
          var jsCookies = _parseCookieHeader(rawCookie?.toString() ?? '');
          cookies.addAll(
            jsCookies.entries.map((e) {
              var cookie = Cookie(e.key, e.value);
              cookie.domain = currentUri.host;
              return cookie;
            }),
          );
        } catch (e, s) {
          Log.warning("Cloudflare", "Read document.cookie failed\n$e\n$s");
        }
        var hasCloudflareCookie = cookies.any(
          (cookie) =>
              cookie.value.isNotEmpty && _isCloudflareCookieName(cookie.name),
        );
        SingleInstanceCookieJar.instance?.deleteByName(
          currentUri,
          'cf_clearance',
        );
        SingleInstanceCookieJar.instance?.saveFromResponse(currentUri, cookies);
        _markClusterVerified(currentUri.host, cookies);
        Log.info(
          "Cloudflare",
          "Saved ${cookies.length} cookies, "
              "cloudflareCookie=$hasCloudflareCookie",
        );
        if (hasCloudflareCookie || hasVerifiedHtml) {
          _markCloudflareVerifiedHost(uri.host);
          _markCloudflareVerifiedHost(currentUri.host);
          success = true;
          verificationSucceeded = true;
          App.rootPop();
        } else {
          Log.info("Cloudflare", "Waiting for Cloudflare cookie or HTML");
        }
      }
    }

    await App.rootContext.to(
      () => AppWebview(
        initialUrl: url,
        initialHeaders: requestHeaders.isEmpty ? null : requestHeaders,
        singlePage: true,
        onTitleChange: (title, controller) async {
          // Keep the webview open until page load stops; title changes can fire
          // before Cloudflare has flushed cookies to the platform store.
        },
        onLoadStop: (controller) async {
          check(controller);
        },
        onStarted: (controller) async {
          var ua = await controller.getUA();
          if (ua != null) {
            appdata.implicitData['ua'] = ua;
            appdata.writeImplicitData();
          }
          var startedUrl = (await controller.getUrl())?.toString() ?? url;
          var startedUri = Uri.tryParse(startedUrl) ?? uri;
          var cookies = cookiesFromPlatformCookies(
            await controller.getCookies(startedUrl),
            fallbackDomain: startedUri.host,
          );
          if (cookies.isNotEmpty) {
            SingleInstanceCookieJar.instance?.saveFromResponse(
              startedUri,
              cookies,
            );
          }
        },
      ),
    );
    finish();
  }
}

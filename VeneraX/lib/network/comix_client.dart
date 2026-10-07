/// comix.to 专用客户端 v2 — 常驻 HeadlessInAppWebView 采集。
///
/// 架构（对比 v1 的弹窗 DesktopWebview）：
/// - **无窗口**：用 flutter_inappwebview 的 HeadlessInAppWebView（WebView2 离屏
///   实例），全程不弹任何窗口，用户无感知。
/// - **常驻**：Worker 单例整个 App 生命周期只创建一次，cookie（含 cf_clearance）
///   持久化在 WebViewEnvironment 的 userDataFolder，后续请求复用，无需反复过
///   Cloudflare。
/// - **API 直采**：document-start 注入 fetch/XHR 钩子，把 SPA 自己发出的
///   `/api/v1/...` JSON 响应截获到 `window.__comixApiLog`，Dart 侧轮询读取。
///   拿到一次真实请求后即可复用其 `__=` token 在页面内直接 fetch 其余分页，
///   不再需要点击分页按钮（v1 要点 16 次翻页、等 SPA 渲染，耗时 ~15s）。
/// - **DOM 兜底**：若钩子未生效（UserScript 被站方改动影响等），回退到 v1 的
///   DOM 采集 + dispatchEvent 翻页方案，逻辑保持可用。
///
/// 已逆向确认的 comix.to API（见 docs/P4-agent-handoff-comix-to.md）：
/// - 章节列表：`GET /api/v1/manga/{hid}/chapters?page=N&...&__=token`
///   → `{status:"ok", result:{items:[{id,url,number,volume,name,group:{id,name},
///   isOfficial,...}], meta:{last_page,...}}}`（axios 拦截器解包 status/result，
///   原始响应带包装层）
/// - 章节图片：`GET /api/v1/chapters/{chapterId}?__=token`
///   → `{..., result:{..., pages:{baseUrl, items:[{width,height,url}]}}}`
///   图片 URL = baseUrl + item.url
/// - `__=` token 由 VMP 混淆的 secure.js 生成（与浏览器指纹绑定），无法在
///   Dart/Node 侧复现，必须在页面上下文内获取（截获或页内 fetch）。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart' show Size;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/log.dart';

class ComixClient {
  static const _baseUrl = "https://comix.to";

  static final ComixClient instance = ComixClient();

  final _worker = _ComixWorker.instance;

  /// 通过离屏 WebView 加载图片字节。
  ///
  /// 背景（2026-10-04 实测）：comix.to 图片 CDN（`*.joshuanotes.site` 等
  /// 轮换域）上了 Cloudflare WAF，对非浏览器 TLS 指纹（dart:io HttpClient、
  /// curl）一律 403（"Sorry, you have been blocked" 1020 页），带 Referer、
  /// 完整浏览器头都没用；真实浏览器内核（Chrome 无头 / WebView2）不需要
  /// Referer 就能直载。所以图片字节必须经 WebView 获取，dio 链路已失效。
  static Future<Uint8List> fetchImageBytes(
    String url, {
    int timeoutSeconds = 30,
  }) => _ComixImageWorker.instance.fetchImageBytes(url, timeoutSeconds);

  /// S12 spike：对同一张被封锁的图片，按多种取字节策略依次尝试，产出对照
  /// 报告（每条策略：是否成功 / 字节数 / 错误），供 `--headless comix-spike`
  /// 打印。**不改变生产取图路径**，纯诊断。
  ///
  /// 背景（Diva 组 `*.site` 轮换域 403）：日志显示"导航能落地但同源 re-fetch
  /// 一律 403"——说明**位图其实已经被浏览器解码并显示出来了**，只是我们没
  /// 办法再发一次请求去取字节。既然如此，最稳的绕法不是继续斗请求，而是
  /// **直接把页面上那张已经画出来的图读出来**（canvas toDataURL）。这条路径
  /// 零网络请求、零签名消耗，天然免疫"单次签名 URL"和"按 Sec-Fetch-Dest 拦
  /// fetch"这两类封锁。
  static Future<List<Map<String, dynamic>>> spikeImageStrategies(
    String url, {
    int timeoutSeconds = 30,
  }) => _ComixImageWorker.instance.spikeImageStrategies(url, timeoutSeconds);

  /// 通过常驻采集 Worker 抓取 comix.to 页面 HTML（导航后直接读 DOM）。
  ///
  /// 背景（2026-10-05）：整站上 CF managed challenge 后，详情页的 SSR HTML
  /// （/title/{hid}，含 initial-data）用 dio 请求一律 403 —— JS 源的
  /// loadInfo 全挂（"all URLs failed"）。
  ///
  /// 实现选择：导航到该 URL 后**同步**读 `document.documentElement.outerHTML`
  /// （不用页内 fetch）—— 既绕开 evaluateJavascript 不 await Promise 的坑
  /// （见 [evalAsyncResult]），又让 CF 挑战由浏览器自己过完再读。
  Future<String> fetchPageHtml(String url) {
    return _worker.enqueue(() async {
      final controller = await _worker.ensure();
      try {
        await controller.stopLoading();
      } catch (_) {}
      await controller.loadUrl(urlRequest: URLRequest(url: WebUri(url)));

      final deadline = DateTime.now().add(const Duration(seconds: 25));
      while (DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(milliseconds: 400));
        final state = unwrapEvalString(
          await controller.evaluateJavascript(source: "document.readyState"),
        );
        if (state == 'complete') break;
      }
      // 挑战可能还在自动跑：页面 complete 但内容仍是挑战页，再等几轮。
      for (var attempt = 0; attempt < 3; attempt++) {
        final html = unwrapEvalString(
          await controller.evaluateJavascript(
            source:
                "(document.documentElement && document.documentElement.outerHTML) || ''",
          ),
        );
        if (html != null && html.isNotEmpty && !looksLikeChallengePage(html)) {
          Log.info(
            "ComixClient",
            "fetchPageHtml: ${html.length} chars from $url",
          );
          return html;
        }
        await Future.delayed(const Duration(milliseconds: 2500));
      }
      throw "fetchPageHtml: no usable HTML for $url";
    }, timeout: const Duration(seconds: 60));
  }

  /// 最后一次匹配到的 API 截获 URL（无论其 body 是否可用）。
  /// 用于"原样重放"兜底——token 绑定完整 query，只能整条复用。
  String? _lastCaptureUrl;

  // ---- 核心方法 ----

  /// 采集章节列表，返回 VeneraX versioned 格式。
  /// 优先 API 直采，失败回退 DOM 采集。
  Future<Map<String, List<Map<String, dynamic>>>> fetchChapters({
    required String hid,
    String slug = '',
  }) async {
    final url = slug.isNotEmpty
        ? "$_baseUrl/title/$hid-$slug"
        : "$_baseUrl/title/$hid";
    Log.info("ComixClient", "fetchChapters(hid=$hid) via headless worker");

    Map<String, List<Map<String, dynamic>>> result = {};
    try {
      result = await _worker.enqueue(
        () => _fetchChaptersViaApi(hid, slug, url),
        timeout: const Duration(seconds: 60),
      );
    } catch (e, s) {
      Log.error("ComixClient", "API path failed: $e\n$s");
    }
    if (result.isNotEmpty) {
      Log.info(
        "ComixClient",
        "fetchChapters(API) returned ${result.length} chapter numbers",
      );
      return result;
    }

    Log.warning("ComixClient", "API path empty — falling back to DOM scraping");
    try {
      result = await _worker.enqueue(
        () => _fetchChaptersByDom(hid, slug, url),
        timeout: const Duration(seconds: 120),
      );
    } catch (e, s) {
      Log.error("ComixClient", "DOM path failed: $e\n$s");
    }
    Log.info(
      "ComixClient",
      "fetchChapters returned ${result.length} chapter numbers",
    );
    return result;
  }

  /// 采集某章节的图片 URL 列表。
  /// [chapterUrl] 是章节 key（comix.to 章节页完整 URL）。
  Future<List<String>> fetchImageUrls({required String chapterUrl}) async {
    Log.info("ComixClient", "fetchImageUrls($chapterUrl) via headless worker");
    List<String> urls = [];
    try {
      urls = await _worker.enqueue(
        () => _fetchPagesViaApi(chapterUrl),
        timeout: const Duration(seconds: 90),
      );
    } catch (e, s) {
      Log.error("ComixClient", "pages API path failed: $e\n$s");
    }
    if (urls.isNotEmpty) return urls;

    Log.warning(
      "ComixClient",
      "pages API empty — falling back to DOM scraping",
    );
    try {
      urls = await _worker.enqueue(
        () => _fetchPagesByDom(chapterUrl),
        timeout: const Duration(seconds: 120),
      );
    } catch (e, s) {
      Log.error("ComixClient", "pages DOM path failed: $e\n$s");
    }
    Log.info("ComixClient", "fetchImageUrls returned ${urls.length} images");
    return urls;
  }

  /// 浏览/搜索漫画（统一入口）。
  ///
  /// [urlQuery] 是 comix.to /browse 页的 URL 参数（如 {q: keyword}、
  /// {types: manhwa}、{statuses: finished}），直接导航到对应 browse 页，
  /// SPA 自己会带 `__=` token 发出 `/api/v1/manga?...` 请求——比等主页截获
  /// 或自己拼 API 参数（数组序列化格式不确定）都可靠。
  /// 返回 `{'items': [...], 'lastPage': N}`，字段映射由 JS 源侧完成。
  ///
  /// 已逆向确认的 URL → API 参数映射（main.js browse 函数）：
  /// URL `q` → API `keyword`；`types`/`statuses`/`genres_in`/`demos`/`sort` 同名。
  Future<Map<String, dynamic>> browseManga({
    Map<String, String> urlQuery = const {},
    int page = 1,
  }) async {
    Log.info("ComixClient", "browseManga($urlQuery, page=$page)");
    try {
      return await _worker.enqueue(
        () => _browseViaApi(urlQuery, page),
        timeout: const Duration(seconds: 90),
      );
    } catch (e, s) {
      Log.error("ComixClient", "browse failed: $e\n$s");
      return {'items': <dynamic>[], 'lastPage': 0};
    }
  }

  /// 关键词搜索（browseManga 的便捷封装）。
  Future<Map<String, dynamic>> searchManga({
    required String keyword,
    int page = 1,
  }) {
    return browseManga(urlQuery: {'q': keyword}, page: page);
  }

  Future<Map<String, dynamic>> _browseViaApi(
    Map<String, String> urlQuery,
    int page,
  ) async {
    final controller = await _worker.ensure();
    await _drainCaptures(controller);

    // page/limit 直接放进 browse URL，SPA 会透传到 API 请求。
    final query = Map<String, String>.from(urlQuery);
    query['page'] = '$page';
    query['limit'] = '28';
    final params = query.entries
        .map(
          (e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
        )
        .join('&');
    final url = params.isEmpty
        ? "$_baseUrl/browse"
        : "$_baseUrl/browse?$params";
    await _navigate(controller, url);

    // 双通道取数据：fetch/XHR 截获（明文）+ JSON.parse 载荷（应对加密响应）。
    await _drainPayloads(controller);
    var body = await _captureOrPayload(
      controller,
      matcher: (u) => u.split('?').first.endsWith("/api/v1/manga"),
      tag: 'list',
      timeout: const Duration(seconds: 60),
      what: 'browse',
    );
    body ??= await _payloadOfTag(controller, 'list');
    if (body == null) {
      Log.warning(
        "ComixClient",
        "browse: no usable manga-list payload for $url",
      );
      return {'items': <dynamic>[], 'lastPage': 0};
    }
    if (body['items'] is! List) {
      Log.warning("ComixClient", "browse: payload has no items list");
      return {'items': <dynamic>[], 'lastPage': 0};
    }
    final items = _extractItems(body);
    final lastPage = _extractLastPage(body);
    Log.info(
      "ComixClient",
      "browse: ${items.length} items, lastPage=$lastPage",
    );
    return {'items': items, 'lastPage': lastPage};
  }

  // ---- API 直采路径 ----

  /// 章节采集（API 路径）。
  ///
  /// ⚠️ 三个血泪教训（v0.5.0 全部实锤，见 docs 日志）：
  /// 1. **token 参数名是 `_` 不是 `__`**。v0.4.x 全程检查 `"__="`，导致所有
  ///    API 路径都被判为"无 token"而降级到又慢又不全的 DOM 采集。
  ///    验证方法：`?_=abc` → "Invalid token."，其它名字都是 "Missing token."。
  /// 2. **token 绑定完整 query string**，改任何一个参数（哪怕只加 `page=2`）
  ///    都会 "Invalid token."。所以**不能复用 token 自己拼分页 URL**——
  ///    必须让 SPA 自己发请求（点分页按钮），我们只截获。
  /// 3. **截获的响应体可能是 WAF 挑战 JSON**，必须校验 HTTP status 与内容。
  Future<Map<String, List<Map<String, dynamic>>>> _fetchChaptersViaApi(
    String hid,
    String slug,
    String pageUrl,
  ) async {
    final controller = await _worker.ensure();
    await _drainCaptures(controller);
    await _drainPayloads(controller);
    await _navigate(controller, pageUrl);

    // 章节列表端点：/api/v1/manga/{hid}/chapters —— 排除 /user/ 下的同名路径。
    bool isChaptersApi(String u) =>
        !u.contains("/user/") &&
        RegExp(r"/api/v\d+/manga/[^/]+/chapters").hasMatch(u.split('?').first);

    Map<String, dynamic>? firstBody = await _captureOrPayload(
      controller,
      matcher: isChaptersApi,
      tag: 'chapters',
      timeout: const Duration(seconds: 30),
      what: 'chapters',
    );
    firstBody ??= await _payloadOfTag(controller, 'chapters');
    if (firstBody == null) {
      Log.warning("ComixClient", "no chapters API capture within 30s");
      return {};
    }

    final items = _extractItems(firstBody);
    final lastPage = _extractLastPage(firstBody);
    Log.info(
      "ComixClient",
      "chapters API page1: ${items.length} items, lastPage=$lastPage",
    );
    if (items.isEmpty) return {};

    final seen = <String>{};
    for (final it in items) {
      seen.add(_itemIdentity(it));
    }

    // 其余分页：token 不能复用，只能点 SPA 的分页按钮让站方自己重签，
    // 然后截获那一次请求。比 DOM 解析快得多（不必等渲染）。
    for (var p = 2; p <= lastPage && p <= 60; p++) {
      await _drainCaptures(controller);
      // 广告浮层可能盖住分页按钮（站方登录后弹广告），点前扫一遍。
      try {
        await controller.evaluateJavascript(source: _adSweepJs);
      } catch (_) {}
      final clickJs = _clickPageJs.replaceFirst('__PAGE__', '$p');
      final clickMap = _parseEvalMap(
        await controller.evaluateJavascript(source: clickJs),
      );
      if (clickMap?['ok'] != true) {
        Log.info("ComixClient", "chapters: no pager button for page $p, stop");
        break;
      }
      final pageBody = await _captureOrPayload(
        controller,
        matcher: isChaptersApi,
        tag: 'chapters',
        timeout: const Duration(seconds: 10),
        what: 'chapters p$p',
      );
      if (pageBody == null) {
        Log.info("ComixClient", "chapters: page $p no API capture, stop");
        break;
      }
      final pageItems = _extractItems(pageBody);
      var added = 0;
      for (final it in pageItems) {
        if (seen.add(_itemIdentity(it))) {
          items.add(it);
          added++;
        }
      }
      Log.info(
        "ComixClient",
        "chapters API page $p: ${pageItems.length} items, $added new, total=${items.length}",
      );
      if (added == 0) break;
    }

    return _buildVersionedMapFromApi(items, hid: hid, slug: slug);
  }

  /// 条目去重键：优先 id，其次 url，最后整条序列化。
  String _itemIdentity(Map<String, dynamic> item) {
    final id = item['id']?.toString();
    if (id != null && id.isNotEmpty) return 'id:$id';
    final url = item['url']?.toString();
    if (url != null && url.isNotEmpty) return 'url:$url';
    return jsonEncode(item);
  }

  /// 等一条匹配的截获（fetch/XHR 钩子）或 JSON.parse 载荷（解密后的明文）。
  /// 两条通道互为备份：站方对部分响应做了加密（原始 body 是 `{"e":"..."}`），
  /// 只有 JSON.parse 通道能看到明文。
  Future<Map<String, dynamic>?> _captureOrPayload(
    InAppWebViewController controller, {
    required bool Function(String url) matcher,
    required String tag,
    required Duration timeout,
    required String what,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final captures = await _drainCaptures(controller);
      for (final capture in captures) {
        final url = capture['url']?.toString() ?? '';
        if (!matcher(url)) continue;
        // 记下最后一次匹配的 URL：即使 body 不可用（WAF 挑战/加密），
        // 调用方仍可原样重放它（token 绑定完整 query，只能整条复用）。
        _lastCaptureUrl = url;
        final bodyText = capture['body']?.toString() ?? '';
        final status = capture['status'];
        Log.info(
          "ComixClient",
          "captured $what (status=$status): ${url.substring(0, url.length.clamp(0, 160))}",
        );
        final body = _decodeApiBody(bodyText);
        if (body != null && _bodyLooksUseful(body)) return body;
        Log.warning(
          "ComixClient",
          "$what: captured body unusable, preview=${bodyText.substring(0, bodyText.length.clamp(0, 160))}",
        );
      }
      final payloads = await _drainPayloads(controller);
      for (final p in payloads) {
        if (p['tag']?.toString() != tag) continue;
        final payload = p['payload'];
        if (payload is Map) {
          Log.info(
            "ComixClient",
            "$what: recovered via JSON.parse payload hook",
          );
          final map = Map<String, dynamic>.from(payload);
          if (map['result'] is Map) {
            return Map<String, dynamic>.from(map['result'] as Map);
          }
          return map;
        }
      }
      await Future.delayed(const Duration(milliseconds: 300));
    }
    return null;
  }

  /// 只看 JSON.parse 载荷通道（不消耗 fetch 截获）。
  Future<Map<String, dynamic>?> _payloadOfTag(
    InAppWebViewController controller,
    String tag,
  ) async {
    final payloads = await _drainPayloads(controller);
    for (final p in payloads) {
      if (p['tag']?.toString() != tag) continue;
      final payload = p['payload'];
      if (payload is Map) {
        Log.info("ComixClient", "payload hook hit for tag=$tag");
        final map = Map<String, dynamic>.from(payload);
        if (map['result'] is Map) {
          return Map<String, dynamic>.from(map['result'] as Map);
        }
        return map;
      }
    }
    return null;
  }

  /// 响应体是否"像真数据"：能解出 items 或 pages。用于排除 WAF 挑战响应。
  bool _bodyLooksUseful(Map<String, dynamic> body) {
    final inner = body['result'] is Map
        ? Map<String, dynamic>.from(body['result'] as Map)
        : body;
    if (inner['items'] is List && (inner['items'] as List).isNotEmpty) {
      return true;
    }
    final pages = inner['pages'];
    if (pages is Map && pages['items'] is List) return true;
    if (pages is List && pages.isNotEmpty) return true;
    return false;
  }

  /// 在页面上下文内按模板 URL 发起 fetch（覆盖若干 query 参数）。
  ///
  /// 页面已加载完成后发起的请求与 SPA 自己的请求同源同 cookie，`__=` token
  /// 有效。带重试：WAF 挑战/瞬时 403 时等 700ms 再试。
  Future<Map<String, dynamic>?> _inPageFetchJson(
    InAppWebViewController controller,
    String templateUrl, {
    Map<String, String> overrides = const {},
    int attempts = 3,
  }) async {
    final escaped = templateUrl.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
    final overridesJs = overrides.entries
        .map(
          (e) =>
              "u.searchParams.set('${e.key}', '${e.value.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}');",
        )
        .join();
    // ⚠️ 必须走 [evalAsyncResult]：直接 eval 一个 async IIFE 拿不到返回值
    // （ExecuteScriptAsync 不 await Promise，返回 {}）。
    final asyncBody =
        """
    var u = new URL('$escaped', location.origin);
    $overridesJs
    var res = await fetch(u, {credentials: 'include', headers: {
      'Accept': 'application/json',
      'X-Requested-With': 'XMLHttpRequest'
    }});
    var text = await res.text();
    return JSON.stringify({status: res.status, body: text});
""";
    for (var attempt = 1; attempt <= attempts; attempt++) {
      if (attempt > 1) {
        await Future.delayed(const Duration(milliseconds: 700));
      }
      try {
        final text = await evalAsyncResult(
          controller,
          asyncBody,
          timeout: const Duration(seconds: 30),
        );
        if (text == null) continue;
        final decoded = jsonDecode(text);
        if (decoded is! Map) continue;
        final parsed = Map<String, dynamic>.from(decoded);
        final status = parsed['status'];
        if (status != 200) {
          Log.warning(
            "ComixClient",
            "in-page fetch attempt #$attempt status=$status error=${parsed['error']}",
          );
          continue;
        }
        final body = _decodeApiBody(parsed['body']?.toString());
        if (body != null) return body;
        Log.warning(
          "ComixClient",
          "in-page fetch attempt #$attempt: body not decodable",
        );
      } catch (e) {
        Log.warning("ComixClient", "in-page fetch attempt #$attempt error: $e");
      }
    }
    return null;
  }

  /// 章节图片采集（API 路径）。
  ///
  /// ⚠️ v0.5.0 根因修复：旧匹配器 `RegExp(r"/chapters/\d+")` 会把
  /// `/api/v1/user/chapters/{id}/state`（阅读进度/点赞状态接口，路径里同样有
  /// `/chapters/<数字>`）当成章节详情接口——它的响应体里没有 pages，于是
  /// "pages API empty"，永远降级到 DOM。DOM 只能拿到 Swiper 虚拟渲染的
  /// 3~5 张（阅读器是 slides 虚拟化，不是懒加载），这就是"只读到 3 页"。
  ///
  /// 正确匹配：`/api/v1/chapters/<纯数字>` 结尾，且排除 `/user/`。
  Future<List<String>> _fetchPagesViaApi(String chapterUrl) async {
    final controller = await _worker.ensure();
    await _drainCaptures(controller);
    await _drainPayloads(controller);
    await _navigate(controller, chapterUrl);

    bool isChapterDetailApi(String u) {
      final path = u.split('?').first;
      return !u.contains("/user/") &&
          RegExp(r"/api/v\d+/chapters/\d+$").hasMatch(path);
    }

    var body = await _captureOrPayload(
      controller,
      matcher: isChapterDetailApi,
      tag: 'pages',
      timeout: const Duration(seconds: 40),
      what: 'chapter pages',
    );
    body ??= await _payloadOfTag(controller, 'pages');

    List<String> urls = [];
    if (body != null) {
      urls = _extractImageUrls(body);
      Log.info("ComixClient", "pages: ${urls.length} images from API payload");
    }
    if (urls.isNotEmpty) return urls;

    // 兜底：原样重放最后一次截获的 URL（token 绑定完整 query，不能改参数）。
    final template = _lastCaptureUrl;
    if (template != null && _hasToken(template)) {
      final retryBody = await _inPageFetchJson(controller, template);
      if (retryBody != null) {
        urls = _extractImageUrls(retryBody);
        if (urls.isNotEmpty) {
          Log.info(
            "ComixClient",
            "pages: recovered via in-page replay, ${urls.length} images",
          );
          return urls;
        }
      }
    }
    return [];
  }

  /// URL 是否带站方的 `_=` 签名 token。
  ///
  /// ⚠️ 参数名是单下划线 `_`，不是 `__`（v0.4.x 写错，导致所有 API 路径失效）。
  /// 判定用 queryParameters 而不是字符串 contains，避免 `__=` 之类的误判。
  bool _hasToken(String url) {
    final params = Uri.tryParse(url)?.queryParameters;
    return params != null && params.containsKey('_');
  }

  // ---- DOM 兜底路径 ----

  /// 章节区域 DOM 探测（v1 生产代码，对齐 BT 项目 _CHAPTERS_PROBE_JS）。
  static const _chaptersProbeJs = r"""
(function(){
  const sec = document.querySelector('SECTION.mpage__chapters');
  if (!sec) return JSON.stringify({ready:false, reason:'no-section'});
  const nums = Array.from(sec.querySelectorAll('button.npager__num'))
    .map(b => parseInt((b.textContent||'').trim(), 10))
    .filter(n => n > 0);
  const activeEl = sec.querySelector('button.npager__num.is-active');
  const rows = Array.from(sec.querySelectorAll('li.mchap-item')).map(li => {
    const a = li.querySelector('a.mchap-row__primary');
    const g = li.querySelector('a.mchap-row__group span');
    return {
      href: a ? a.getAttribute('href') : null,
      text: a ? (a.textContent || '').trim() : '',
      group: g ? (g.textContent || '').trim() : '',
    };
  }).filter(r => r.href);
  return JSON.stringify({
    ready: rows.length > 0,
    pages: nums.length ? Math.max.apply(null, nums) : 1,
    active: activeEl ? (activeEl.textContent || '').trim() : '',
    rows: rows,
    title: document.title,
    url: location.href,
  });
})()
""";

  /// 点分页按钮翻页。用 dispatchEvent 替代 .click() —— SPA 不响应原生 click()。
  /// 点击前先跑一遍广告浮层清扫：comix.to 登录后会弹广告浮层（用户在真实
  /// 浏览器里要手动点掉），浮层若盖在分页按钮上，dispatchEvent 也会被
  /// 覆盖层吞掉。隐藏 worker 里没人点广告，直接移除常见广告容器。
  static const _adSweepJs = r"""
(function(){
  var removed = 0;
  // 已知广告网络容器 / 浮层
  var selectors = [
    'ins.adsbygoogle', 'iframe[src*="adsbygoogle"]',
    'iframe[src*="exoclick"]', 'iframe[src*="juicyads"]',
    'iframe[src*="tsyndicate"]', 'iframe[src*="a-ads"]',
    'div[id*="google_ads"]', 'div[class*="ad-banner"]',
    'div[id*="banner_ad"]', 'div[class*="popup-ad"]',
  ];
  selectors.forEach(function(sel){
    Array.from(document.querySelectorAll(sel)).forEach(function(el){
      el.remove(); removed++;
    });
  });
  // 兜底：铺满视口、挡在最前面的透明/广告浮层（点不到下面按钮的元凶）
  Array.from(document.querySelectorAll('body *')).forEach(function(el){
    var r = el.getBoundingClientRect();
    if (r.width < window.innerWidth * 0.9 || r.height < window.innerHeight * 0.9) return;
    var st = getComputedStyle(el);
    if (st.position !== 'fixed' && st.position !== 'absolute') return;
    if (el.querySelector('button, a, video, iframe') && el.textContent && el.textContent.trim().length > 0 && el.closest('SECTION, MAIN, HEADER')) return; // 别误伤正经 UI
    if (parseFloat(st.zIndex || '0') >= 100 || st.pointerEvents === 'none') {
      el.style.pointerEvents = 'none';
      removed++;
    }
  });
  document.documentElement.style.overflow = '';
  document.body && (document.body.style.overflow = '');
  document.body && (document.body.style.position = '');
  return removed;
})()
""";

  static const _clickPageJs = r"""
(function(){
  const sec = document.querySelector('SECTION.mpage__chapters');
  if (!sec) return JSON.stringify({ok:false, reason:'no-section'});
  const btn = Array.from(sec.querySelectorAll('button.npager__num'))
    .find(b => (b.textContent||'').trim() === '__PAGE__');
  if (!btn) return JSON.stringify({ok:false, reason:'missing-button'});
  btn.dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true, view: window}));
  return JSON.stringify({ok:true});
})()
""";

  /// 翻页后验证：看 active 按钮和第一行 href 是否变了。
  static const _pageVerifyJs = r"""
(function(){
  const sec = document.querySelector('SECTION.mpage__chapters');
  if (!sec) return JSON.stringify({error:'no-section'});
  const firstHref = sec.querySelector('li.mchap-item a.mchap-row__primary')?.getAttribute('href') || null;
  const activeBtn = sec.querySelector('button.npager__num.is-active');
  return JSON.stringify({
    firstHref: firstHref,
    activeBtn: activeBtn ? (activeBtn.textContent||'').trim() : null,
    totalRows: sec.querySelectorAll('li.mchap-item').length,
  });
})()
""";

  /// 阅读页图片 DOM 探测。
  static const _pagesProbeJs = r"""
(function(){
  var imgs = Array.from(document.querySelectorAll(
    'img.rpage-page__img, .rpage-page img, .rpage-view img'));
  var urls = imgs.map(function(img){
    try { img.loading = 'eager'; } catch (e) {}
    return img.getAttribute('src')
      || (img.getAttribute('srcset') || '').split(' ')[0]
      || img.getAttribute('data-src')
      || img.getAttribute('data-original')
      || '';
  }).filter(function(u){ return u && u.indexOf('data:') !== 0; });
  return JSON.stringify({
    ready: urls.length > 0,
    urls: Array.from(new Set(urls)),
    title: document.title,
    url: location.href,
  });
})()
""";

  Future<Map<String, List<Map<String, dynamic>>>> _fetchChaptersByDom(
    String hid,
    String slug,
    String url,
  ) async {
    final controller = await _worker.ensure();
    await _navigate(controller, url);

    final firstSnap = await _evalWithRetry(
      controller,
      _chaptersProbeJs,
      timeoutMs: 30000,
    );
    if (firstSnap == null || firstSnap['ready'] != true) {
      Log.warning(
        "ComixClient",
        "DOM: chapter section not ready: ${firstSnap?['reason']}",
      );
      return {};
    }
    Log.info(
      "ComixClient",
      "DOM: page1 rows=${(firstSnap['rows'] as List?)?.length}, pages=${firstSnap['pages']}",
    );

    final allRows = <Map<String, dynamic>>[];
    allRows.addAll(List<Map<String, dynamic>>.from(firstSnap['rows'] ?? []));
    final pagesHint = (firstSnap['pages'] ?? 1) as int;

    var consecutiveEmpty = 0;
    String? prevFirstHref;
    for (var p = 2; p <= pagesHint && p <= 40; p++) {
      try {
        await controller.evaluateJavascript(source: _adSweepJs);
      } catch (_) {}
      final clickJs = _clickPageJs.replaceFirst('__PAGE__', '$p');
      final clickMap = _parseEvalMap(
        await controller.evaluateJavascript(source: clickJs),
      );
      if (clickMap?['ok'] != true) break;

      // 等 SPA 渲染新页
      await Future.delayed(const Duration(milliseconds: 1200));

      final verifyMap = _parseEvalMap(
        await controller.evaluateJavascript(source: _pageVerifyJs),
      );
      final newFirstHref = verifyMap?['firstHref'] as String?;
      if (prevFirstHref != null &&
          newFirstHref != null &&
          newFirstHref == prevFirstHref) {
        Log.info("ComixClient", "DOM: page $p not effective, stopping");
        break;
      }
      if (newFirstHref != null) prevFirstHref = newFirstHref;

      final snap = await _evalWithRetry(
        controller,
        _chaptersProbeJs,
        timeoutMs: 15000,
      );
      if (snap == null || snap['ready'] != true) {
        consecutiveEmpty++;
        if (consecutiveEmpty >= 2) break;
        continue;
      }
      consecutiveEmpty = 0;
      final rows = List<Map<String, dynamic>>.from(snap['rows'] ?? []);
      final hrefs = allRows.map((r) => r['href']).toSet();
      var newCount = 0;
      for (final r in rows) {
        if (!hrefs.contains(r['href'])) {
          allRows.add(r);
          newCount++;
        }
      }
      Log.info(
        "ComixClient",
        "DOM: page $p ${rows.length} rows, $newCount new, cumulative=${allRows.length}",
      );
      if (newCount == 0) break;
    }

    return _buildVersionedMapFromRows(allRows);
  }

  /// 阅读页 DOM 兜底。
  ///
  /// ⚠️ 阅读器是 **Swiper slides 虚拟化**（同时只渲染 3~5 张 slide），不是
  /// 简单的懒加载——所以"一有图就返回"只能拿到 4 张。这里改成轮询到
  /// **数量连续 3 次不变** 再收，同时把 img 的 loading 强制改成 eager，
  /// 尽可能把已进入 DOM 的图全部触发加载。
  /// 它只是最后兜底：主路径是 API 截获（一章一次响应就有全部页）。
  Future<List<String>> _fetchPagesByDom(String chapterUrl) async {
    final controller = await _worker.ensure();
    await _navigate(controller, chapterUrl);

    final deadline = DateTime.now().add(const Duration(seconds: 25));
    var lastCount = -1;
    var stable = 0;
    List<String> best = const [];
    while (DateTime.now().isBefore(deadline)) {
      final snap = _parseEvalMap(
        await controller.evaluateJavascript(source: _pagesProbeJs),
      );
      if (snap != null && snap['ready'] == true) {
        final urls = (snap['urls'] as List? ?? [])
            .map((u) => u.toString())
            .where((u) => u.isNotEmpty)
            .map((u) => u.startsWith('http') ? u : "$_baseUrl$u")
            .toList();
        if (urls.length > best.length) best = urls;
        if (urls.length == lastCount) {
          stable++;
          if (stable >= 3) break;
        } else {
          stable = 0;
          lastCount = urls.length;
        }
      }
      await Future.delayed(const Duration(milliseconds: 800));
    }
    if (best.isEmpty) {
      Log.warning("ComixClient", "DOM: no reader images found");
    } else {
      Log.info(
        "ComixClient",
        "DOM fallback collected ${best.length} image(s) (virtualised reader, "
            "count may be far below the real page count)",
      );
    }
    return best;
  }

  // ---- 通用工具 ----

  /// 读取并清空页面内的 API 截获日志。
  Future<List<Map<String, dynamic>>> _drainCaptures(
    InAppWebViewController controller,
  ) async {
    try {
      final raw = await controller.evaluateJavascript(
        source: r"""
(function(){
  var log = window.__comixApiLog || [];
  window.__comixApiLog = [];
  return JSON.stringify(log);
})()
""",
      );
      return _parseEvalList(raw);
    } catch (e) {
      Log.warning("ComixClient", "drainCaptures error: $e");
      return [];
    }
  }

  /// 读取并清空页面内的 JSON.parse 明文载荷（站方对部分响应做了加密，
  /// 原始 body 是 `{"e":"..."}`，只有 SPA 解密后经 JSON.parse 的才是明文）。
  Future<List<Map<String, dynamic>>> _drainPayloads(
    InAppWebViewController controller,
  ) async {
    try {
      final raw = await controller.evaluateJavascript(
        source: r"""
(function(){
  var log = window.__comixPayloads || [];
  window.__comixPayloads = [];
  return JSON.stringify(log);
})()
""",
      );
      return _parseEvalList(raw);
    } catch (e) {
      Log.warning("ComixClient", "drainPayloads error: $e");
      return [];
    }
  }

  Future<void> _navigate(InAppWebViewController controller, String url) async {
    Log.info("ComixClient", "navigate → $url");
    try {
      await controller.stopLoading();
    } catch (_) {}
    await controller.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  /// 带超时轮询的 evaluateJavascript（DOM 探测用）。
  Future<Map<String, dynamic>?> _evalWithRetry(
    InAppWebViewController controller,
    String js, {
    int timeoutMs = 30000,
    int intervalMs = 500,
  }) async {
    final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
    var attempt = 0;
    while (DateTime.now().isBefore(deadline)) {
      attempt++;
      try {
        final snap = _parseEvalMap(
          await controller.evaluateJavascript(source: js),
        );
        if (snap != null && snap['ready'] == true) {
          Log.info("ComixClient", "  eval attempt #$attempt: ready=true");
          return snap;
        }
      } catch (e) {
        Log.warning("ComixClient", "  eval attempt #$attempt error: $e");
      }
      await Future.delayed(Duration(milliseconds: intervalMs));
    }
    Log.info("ComixClient", "eval retry loop ended after $attempt attempts");
    return null;
  }

  /// WebView2 的 ExecuteScriptAsync 会对 JS 返回值再做一次 JSON.stringify，
  /// 所以 JS 里 `return JSON.stringify({...})` 时 Dart 拿到的是
  /// JSON-encoded string。循环 jsonDecode 直到拿到目标类型。
  Map<String, dynamic>? _parseEvalMap(dynamic raw) {
    return _decodeEval(raw, (s) => s.startsWith('{'));
  }

  List<Map<String, dynamic>> _parseEvalList(dynamic raw) {
    final list = _decodeEval(raw, (s) => s.startsWith('['));
    if (list is List) {
      return [
        for (final e in list)
          if (e is Map) Map<String, dynamic>.from(e),
      ];
    }
    return [];
  }

  static dynamic _decodeEval(dynamic raw, bool Function(String) check) {
    if (raw == null) return null;
    try {
      String s;
      if (raw is String) {
        s = raw;
      } else {
        s = jsonEncode(raw);
      }
      var depth = 0;
      while (depth < 5) {
        final trimmed = s.trim();
        if (check(trimmed)) {
          return jsonDecode(trimmed);
        }
        if (trimmed.startsWith('"')) {
          s = jsonDecode(trimmed) as String;
          depth++;
          continue;
        }
        if (trimmed.isEmpty || trimmed == 'null' || trimmed == 'undefined') {
          return null;
        }
        Log.warning(
          "ComixClient",
          "_decodeEval: unrecognized format, starts with '${trimmed[0]}'",
        );
        return null;
      }
      return null;
    } catch (e) {
      Log.warning("ComixClient", "_decodeEval error: $e");
      return null;
    }
  }

  /// 解包 API 响应：原始响应可能带 `{status:"ok", result:{...}}` 包装层
  /// （axios 拦截器在页面内做的解包，Dart 侧拿到的是原始 body）。
  Map<String, dynamic>? _decodeApiBody(String? body) {
    if (body == null || body.isEmpty) return null;
    try {
      final json = jsonDecode(body);
      if (json is! Map) return null;
      if (json['result'] is Map) {
        return Map<String, dynamic>.from(json['result'] as Map);
      }
      return Map<String, dynamic>.from(json);
    } catch (e) {
      Log.warning("ComixClient", "decodeApiBody error: $e");
      return null;
    }
  }

  List<Map<String, dynamic>> _extractItems(Map<String, dynamic> body) {
    final items = body['items'];
    if (items is List) {
      return [
        for (final e in items)
          if (e is Map) Map<String, dynamic>.from(e),
      ];
    }
    return [];
  }

  int _extractLastPage(Map<String, dynamic> body) {
    final meta = body['meta'];
    if (meta is Map) {
      final lp = meta['last_page'] ?? meta['lastPage'] ?? 1;
      if (lp is num) return lp.toInt();
      if (lp is String) return int.tryParse(lp) ?? 1;
    }
    return 1;
  }

  /// 从章节图片 API 响应提取图片 URL 列表。
  ///
  /// 兼容三种形态：
  /// - `pages: {baseUrl, items:[{width,height,url}]}`（当前站点形态，
  ///   图片 URL = baseUrl + item.url，前端 ReadPage chunk 里就是这样拼的）；
  /// - `pages` 为数组且元素是 `{url}`（旧形态）；
  /// - 外面还套着 `{status:"ok", result:{...}}` 包装层（axios 拦截器之前）。
  List<String> _extractImageUrls(Map<String, dynamic> body) {
    var inner = body;
    if (inner['result'] is Map) {
      inner = Map<String, dynamic>.from(inner['result'] as Map);
    }
    final pages = inner['pages'];
    final urls = <String>[];
    if (pages is Map) {
      final baseUrl = (pages['baseUrl'] ?? pages['base_url'] ?? '').toString();
      final items = pages['items'];
      if (items is List) {
        for (final item in items) {
          if (item is! Map) continue;
          final u = (item['url'] ?? '').toString();
          if (u.isEmpty) continue;
          urls.add(_absolutizeImageUrl(u, baseUrl));
        }
      }
    } else if (pages is List) {
      for (final item in pages) {
        if (item is! Map) continue;
        final u = (item['url'] ?? '').toString();
        if (u.isEmpty) continue;
        urls.add(_absolutizeImageUrl(u, ''));
      }
    }
    return urls;
  }

  /// 图片 URL 补全：item.url 通常是相对路径，需要拼上 pages.baseUrl；
  /// 再兜底处理协议相对（`//`）与站点相对（`/`）路径。
  String _absolutizeImageUrl(String u, String baseUrl) {
    if (u.startsWith('http')) return u;
    if (u.startsWith('//')) return 'https:$u';
    final base = baseUrl.isNotEmpty ? baseUrl : _baseUrl;
    if (u.startsWith('/')) {
      // baseUrl 可能是 https://cdn.xxx/path/ 形态，此时取 origin
      final m = RegExp(r'^(https?://[^/]+)').firstMatch(base);
      return '${m?.group(1) ?? base}$u';
    }
    return base.endsWith('/') ? '$base$u' : '$base/$u';
  }

  // ---- Versioned map 构建 ----

  /// API 条目 → versioned map。条目字段（从前端 bundle 逆向确认）：
  /// `{id, url, number, volume, name, group:{id,name}, isOfficial, ...}`
  Map<String, List<Map<String, dynamic>>> _buildVersionedMapFromApi(
    List<Map<String, dynamic>> items, {
    required String hid,
    required String slug,
  }) {
    final result = <String, List<Map<String, dynamic>>>{};
    for (final item in items) {
      var number = (item['number'] ?? '').toString();
      if (number.isEmpty) {
        // 兜底：从 url 提取
        final u = (item['url'] ?? '').toString();
        final m = RegExp(
          r'-chapter-(\d+(?:\.\d+)?)',
          caseSensitive: false,
        ).firstMatch(u);
        number = m?.group(1) ?? '';
      }
      if (number.isEmpty) continue;

      String group;
      if (item['group'] is Map) {
        group = (item['group']['name'] ?? '').toString();
      } else if (item['isOfficial'] == true) {
        group = "Official";
      } else {
        group = "";
      }

      final name = (item['name'] ?? '').toString();
      var key = (item['url'] ?? '').toString();
      if (key.isEmpty) {
        key = "/title/$hid-$slug/${item['id']}-chapter-$number";
      }
      if (!key.startsWith('http')) {
        key = "$_baseUrl$key";
      }

      final uploadedAt = _parseTimestamp(item);

      result.putIfAbsent(number, () => []).add({
        'group': group,
        'lang': (item['lang'] ?? 'en').toString(),
        'title': name.isNotEmpty ? name : 'Ch.$number',
        'key': key,
        'uploadedAt': uploadedAt,
      });
    }

    for (final list in result.values) {
      list.sort(
        (a, b) => ((a['group'] as String?) ?? '').compareTo(
          ((b['group'] as String?) ?? ''),
        ),
      );
    }
    final keys = result.keys.toList()
      ..sort((a, b) {
        final na = double.tryParse(a) ?? 0;
        final nb = double.tryParse(b) ?? 0;
        return na.compareTo(nb);
      });
    Log.info(
      "ComixClient",
      "Built versioned(API): ${result.length} chapter numbers from ${items.length} rows",
    );
    return {for (final k in keys) k: result[k]!};
  }

  /// DOM rows → versioned map（v1 逻辑，保持不变）。
  Map<String, List<Map<String, dynamic>>> _buildVersionedMapFromRows(
    List rows,
  ) {
    final result = <String, List<Map<String, dynamic>>>{};
    final numRe = RegExp(r'-chapter-(\d+(?:\.\d+)?)\s*$', caseSensitive: false);

    for (final row in rows) {
      if (row is! Map) continue;
      final r = Map<String, dynamic>.from(row);

      final href = r['href']?.toString() ?? '';
      final text = r['text']?.toString() ?? '';
      final group = r['group']?.toString() ?? '';

      final match = numRe.firstMatch(href);
      String number;
      if (match != null) {
        number = match.group(1)!;
      } else {
        final numMatch = RegExp(r'(\d+(?:\.\d+)?)').firstMatch(text);
        number = numMatch?.group(1) ?? '0';
      }

      var fullHref = href;
      if (fullHref.isNotEmpty && !fullHref.startsWith('http')) {
        fullHref = "$_baseUrl$fullHref";
      }

      final entry = <String, dynamic>{
        'group': group,
        'lang': 'en',
        'title': text.isNotEmpty ? text : 'Ch.$number',
        'key': fullHref,
        'uploadedAt': 0,
      };
      result.putIfAbsent(number, () => []).add(entry);
    }

    for (final list in result.values) {
      list.sort((a, b) {
        final ga = (a['group'] as String?) ?? '';
        final gb = (b['group'] as String?) ?? '';
        return ga.compareTo(gb);
      });
    }
    final keys = result.keys.toList()
      ..sort((a, b) {
        final na = double.tryParse(a) ?? 0;
        final nb = double.tryParse(b) ?? 0;
        return na.compareTo(nb);
      });
    Log.info(
      "ComixClient",
      "Built versioned(DOM): ${result.length} chapter numbers, total rows=${rows.length}",
    );
    return {for (final k in keys) k: result[k]!};
  }

  int _parseTimestamp(Map<String, dynamic> item) {
    for (final key in [
      'createdAt',
      'created_at',
      'uploadedAt',
      'uploaded_at',
    ]) {
      final v = item[key];
      if (v == null) continue;
      if (v is num) return v.toInt();
      final s = v.toString();
      final epoch = int.tryParse(s);
      if (epoch != null) return epoch;
      final dt = DateTime.tryParse(s);
      if (dt != null) return dt.millisecondsSinceEpoch ~/ 1000;
    }
    return 0;
  }
}

/// 常驻 HeadlessInAppWebView Worker。
///
/// - 全 App 只创建一个离屏 WebView2 实例，不弹任何窗口。
/// - cookie 持久化在 `{App.dataPath}\webview`（与可见 Webview 共享，
///   cf_clearance 可复用）。
/// - 所有采集任务通过 [enqueue] 串行执行（同一时刻只做一次导航）。
class _ComixWorker {
  static final _ComixWorker instance = _ComixWorker._();

  _ComixWorker._();

  HeadlessInAppWebView? _webview;
  WebViewEnvironment? _environment;
  Future<void>? _queue;

  bool get _isAlive => _webview != null && _webview!.isRunning();

  /// 串行执行一个采集任务。
  Future<T> enqueue<T>(
    Future<T> Function() task, {
    Duration timeout = const Duration(seconds: 60),
  }) {
    final prev = _queue ?? Future.value();
    final completer = Completer<void>();
    _queue = completer.future;
    return prev
        .then((_) => task().timeout(timeout))
        .whenComplete(() => completer.complete());
  }

  /// 确保 worker 就绪，返回控制器。
  Future<InAppWebViewController> ensure() async {
    if (_isAlive) {
      return _webview!.webViewController!;
    }
    // 先释放旧实例（可能已 stop 但未 dispose）
    try {
      await _webview?.dispose();
    } catch (_) {}
    _webview = null;

    // 共享 Environment + 启动串行化（见 _getSharedWebViewEnvironment 注释）。
    _environment = await _getSharedWebViewEnvironment();
    await _withWebviewStartupLock(() async {
      await applyProxySetting();

      final webview = HeadlessInAppWebView(
        webViewEnvironment: _environment,
        initialSize: const Size(1280, 2000),
        // document-start 注入 API 截获钩子，抢在 SPA 发请求之前。
        initialUserScripts: UnmodifiableListView<UserScript>([
          UserScript(
            source: _captureHookJs,
            injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          ),
        ]),
        initialSettings: InAppWebViewSettings(isInspectable: true),
        initialUrlRequest: URLRequest(url: WebUri("https://comix.to/")),
      );
      _webview = webview;
      await webview.run();
      Log.info("ComixWorker", "headless webview started");
    });
    return _webview!.webViewController!;
  }

  /// document-start 注入的截获钩子：包装 fetch / XMLHttpRequest，
  /// 把所有 /api/ 响应记录到 window.__comixApiLog 供 Dart 侧轮询。
  static const _captureHookJs = r"""
(function(){
  if (window.__comixHookInstalled) return;
  window.__comixHookInstalled = true;
  window.__comixApiLog = [];
  window.__comixPayloads = [];
  function record(url, body, status) {
    try {
      if (!url || String(url).indexOf('/api/') === -1) return;
      window.__comixApiLog.push({
        url: String(url),
        body: body == null ? null : String(body),
        status: status == null ? 0 : status
      });
      if (window.__comixApiLog.length > 60) window.__comixApiLog.shift();
    } catch (e) {}
  }
  var of = window.fetch;
  if (of) {
    window.fetch = function() {
      var args = arguments;
      var u = (typeof args[0] === 'string') ? args[0] : (args[0] && args[0].url) || '';
      var isApi = String(u).indexOf('/api/') !== -1;
      return of.apply(this, args).then(function(res) {
        try {
          if (isApi) {
            res.clone().text().then(function(t) { record(u, t, res.status); }).catch(function(){});
          }
        } catch (e) {}
        return res;
      });
    };
  }
  var oOpen = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function(method, url) {
    this.__comixUrl = url;
    return oOpen.apply(this, arguments);
  };
  var oSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.send = function() {
    var xhr = this;
    xhr.addEventListener('load', function() {
      try { record(xhr.__comixUrl, xhr.responseText, xhr.status); } catch (e) {}
    });
    return oSend.apply(this, arguments);
  };
  // ---- 明文载荷通道 ----
  // 站方对部分 API 响应做了加密（原始 body 形如 {"e":"..."}），只有 SPA
  // 解密后再 JSON.parse 得到的才是明文。这里包一层 JSON.parse，把带
  // pages / items 的结果原样留档，作为 fetch 截获通道的备份。
  // 与 BallonsTranslator 的 scraper/comix_client.py 同一思路（那边抓的是
  // JSON.parse 解密负载）。
  var op = JSON.parse;
  JSON.parse = function(text, reviver) {
    var v = op(text, reviver);
    try {
      if (v && typeof v === 'object' && !Array.isArray(v)) {
        var r = (v.result && typeof v.result === 'object') ? v.result : v;
        var tag = null;
        if (r.pages && !Array.isArray(r.pages) && Array.isArray(r.pages.items)) {
          tag = 'pages';
        } else if (Array.isArray(r.items) && r.items.length &&
                   r.items[0] && typeof r.items[0] === 'object') {
          var i0 = r.items[0];
          tag = (i0.number !== undefined || i0.volume !== undefined) ? 'chapters' : 'list';
        }
        if (tag) {
          window.__comixPayloads.push({tag: tag, payload: v});
          if (window.__comixPayloads.length > 12) window.__comixPayloads.shift();
        }
      }
    } catch (e) {}
    return v;
  };
})();
""";
}

/// comix.to 图片专用离屏 WebView 加载器（v0.6.4：导航优先 + 多通道并行）。
///
/// 为什么不用 dio：图片 CDN 的 Cloudflare WAF 按客户端 TLS 指纹放行，
/// dart:io HttpClient 的指纹必被 1020 拦截（实测 2026-10-04），改什么
/// 请求头都无效。WebView2 是真实浏览器栈，指纹可过。
///
/// 通道演进（全部有线上日志实证）：
/// - v0.6.0 逐张导航：可靠但串行，一章百来张图排队。
/// - v0.6.1 跨域 fetch 为主：当时 CDN 允许 CORS，快。**2026-10-05 下午起
///   WAF 收紧，空白页发起的跨域 fetch 大面积 403/挂起**（日志：403×176、
///   evalAsync 超时×32），每张图先在死路上耗满 30s 才走导航 → 单张 30~90s。
/// - v0.6.4（本版）**导航优先**：导航是浏览器自己的顶级 GET（无 Origin 头、
///   真实 Sec-Fetch 语境），实测每次都成功。跨域 fetch 仅在"最近 10 分钟内
///   成功过"时才作为快路径先试（8s 短预算），失败立即转导航，不再陪跑。
///
/// 并行度：单 WebView 的导航天然互斥，所以开 [laneCount] 条独立通道
/// （各自一个离屏 WebView），轮转分发。阅读（顺序取图）与封面网格都受益。
///
/// 超时契约（用户指定）：单张 webp 10s 内出图是可容忍，30s 即超时。
/// [timeoutSeconds] 是**整张图的硬预算**（导航 + 回读共用），到点抛异常，
/// 由上层进入 onLoadFailed / 错误 UI（带手动重试按钮），不再内部放大。
class _ComixImageWorker {
  static final _ComixImageWorker instance = _ComixImageWorker._();

  _ComixImageWorker._();

  static const laneCount = 3;
  final _lanes = List.generate(laneCount, (_) => _ImageLane());

  /// 主机封锁检测（S12 整体强化）：comix.to 把不同章节的图片分发到不同宿主，
  /// 部分"轮换域"（`*.site`，如 DivaScans 章节）的 WebView 导航直接落地
  /// `null` / `about:blank` 且同源 fetch 一律 403——这是**服务器侧的额外
  /// 反爬/TLS 指纹层**，客户端无法通过重试破解。日志实锤：每章图片 URL 的
  /// `/hi/<token>` 路径段在同一章内完全一致，而不同子域（`447.xxx.site` /
  /// `rxn.yyy.site`）只是轮换——所以以 **token 为键**，而非每图不同的子域。
  ///
  /// 一旦某 token 连续 2 次被 403 / 导航失败，判定该章整批"主机封锁"，
  /// 后续同 token 图片降级为**快失败**（[fastFailSeconds] 短超时、不再叠加
  /// 重签/重试预算），让整章在数秒内以"N missing"收尾，而不是每张图各吃
  /// 30~90s 把队列拖死。正常宿主（static.comix.to）永不 403，不会被误判。
  static const int _hostBlockThreshold = 2;
  static const int _fastFailSeconds = 6;

  /// token -> 连续失败计数（进程内、随会话重置；修复重试时自然解锁）。
  static final Map<String, int> _hostBlockFails = {};

  /// 从图片 URL 抽出"章节 token"（路径 `/hi/<token>` 段），抽不到则退回 host。
  static String _chapterTokenOf(String url) {
    try {
      final u = Uri.parse(url);
      final seg = u.pathSegments;
      for (var i = 0; i < seg.length - 1; i++) {
        if (seg[i] == 'hi' || seg[i] == 'hi2' || seg[i] == 'h') {
          final t = seg[i + 1];
          if (t.isNotEmpty) return t;
        }
      }
      return u.host;
    } catch (_) {
      return url;
    }
  }

  static bool _isHostBlocked(String token) =>
      (_hostBlockFails[token] ?? 0) >= _hostBlockThreshold;

  static void _registerHostBlock(String token) {
    final n = (_hostBlockFails[token] ?? 0) + 1;
    _hostBlockFails[token] = n;
    if (n == _hostBlockThreshold) {
      Log.warning(
        "ComixImageWorker",
        "host blocked detected for token=$token (chapter images on a "
        "blocked rotating CDN, failing fast)",
      );
    }
  }

  static void _resetHostBlock(String token) => _hostBlockFails[token] = 0;
  int _nextLane = 0;

  /// 跨域 fetch 快路径的"黑名单"：上次成功/失败时间。10 分钟内成功过才先试。
  DateTime? _lastCrossOriginSuccess;

  Future<Uint8List> fetchImageBytes(String url, int timeoutSeconds) {
    final lane = _lanes[_nextLane++ % laneCount];
    // ⚠️ 主机封锁快失败（S12）：同一 token 已连续 2 次 403 / 导航失败 →
    // 该章整批降级为 6s 短超时，不再把 30~90s 预算浪费在必然失败的请求上。
    final token = _chapterTokenOf(url);
    final effective = _isHostBlocked(token)
        ? (timeoutSeconds < _fastFailSeconds ? timeoutSeconds : _fastFailSeconds)
        : timeoutSeconds;
    // ⚠️ 整体硬超时（#P5.1）：Lane 内部的 deadline 只覆盖导航后的回读，
    // `_ensure()`（environment 创建 / webview.run）挂在锁上时永远不会
    // 触发它——下载就是卡死在这里（0 B/s 永不推进）。外层再包一层
    // timeout 兜底，超时后丢弃该 Lane 的 WebView，下次取图重建。
    return lane
        .fetch(url, effective, _tryCrossOriginFirst)
        .timeout(Duration(seconds: effective + 8))
        .then((bytes) {
          _resetHostBlock(token);
          return bytes;
        })
        .catchError((e) {
          _registerHostBlock(token);
          Log.warning("ComixImageWorker", "lane hard timeout, resetting: $e");
          return lane.reset().then((_) => Future<Uint8List>.error(e));
        });
  }

  bool get _tryCrossOriginFirst =>
      _lastCrossOriginSuccess != null &&
      DateTime.now().difference(_lastCrossOriginSuccess!) <
          const Duration(minutes: 10);

  /// S12 spike（诊断专用，不进生产路径）：对同一张图按多种策略依次尝试取字节，
  /// 产出可比较的结果列表。给 `--headless comix-spike` 用。
  ///
  /// 策略顺序按"成功率高、成本低"排：
  /// 1. `canvas-read` —— 导航后**直接读页面上已解码的位图**（canvas
  ///    toDataURL）。零网络请求，天然免疫单次签名 URL 与 Sec-Fetch-Dest 拦
  ///    fetch 两类封锁，是 Diva 组 403 的头号候选解法。
  /// 2. `img-natural-wxh` —— 读 `naturalWidth/Height` 佐证位图确实解码成功
  ///    （即使 canvas 因跨域污染失败，也能证明"图已经到了浏览器"）。
  /// 3. `same-origin-fetch` —— 现有生产路径（导航 + 同源 fetch 回读），作为
  ///    对照基线，用来确认它在被封锁域上确实失败。
  Future<List<Map<String, dynamic>>> spikeImageStrategies(
    String url,
    int timeoutSeconds,
  ) async {
    final lane = _lanes[_nextLane++ % laneCount];
    final results = <Map<String, dynamic>>[];
    final deadline = DateTime.now().add(Duration(seconds: timeoutSeconds));

    Future<void> record(String name, Uint8List? bytes, String? error) async {
      results.add({
        'strategy': name,
        'ok': bytes != null && bytes.isNotEmpty,
        'bytes': bytes?.length ?? 0,
        'error': error,
      });
      Log.info(
        "ComixSpike",
        "strategy=$name ok=${bytes != null && bytes.isNotEmpty} "
        "bytes=${bytes?.length ?? 0} error=$error",
      );
    }

    // 导航一次，多策略共用同一个已落地页面（导航是浏览器顶级 GET，最容易过）。
    InAppWebViewController? controller;
    String? landing;
    try {
      controller = await lane.debugEnsure();
      try {
        await controller.stopLoading();
      } catch (_) {}
      await controller.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
      // 等页面 readyState 完成（与生产路径同口径，≤15s 且不越过总预算）。
      final navDeadline = DateTime.now().add(const Duration(seconds: 15));
      while (DateTime.now().isBefore(navDeadline) &&
          DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(milliseconds: 250));
        final state = _ImageLane._unwrapEval(
          await controller
              .evaluateJavascript(source: "document.readyState")
              .timeout(const Duration(seconds: 8)),
        );
        if (state == 'complete') break;
      }
      try {
        landing = (await controller.getUrl())?.toString();
      } catch (_) {}
    } catch (e) {
      // 导航本身就失败（例如落地 null）：三条策略全部无意义，直接记结论。
      await record('navigation', null, 'navigation failed: $e');
      return results;
    }

    // 策略 2（先跑它）：读位图尺寸——这是"图有没有真的到浏览器"的判据。
    // 同时把导航落地 URL 作为独立结论记下来：顶级导航落到 about:blank 说明
    // 请求在 TLS/WAF 层就被拒（连 HTTP 都没到），此时页内任何策略都无从谈起。
    await record(
      'navigation-landing',
      null,
      landing == null || landing.isEmpty
          ? 'landed on null/empty'
          : (landing == 'about:blank'
              ? 'BLOCKED: landed on about:blank (rejected before HTTP layer)'
              : null),
    );
    results.last['landing'] = landing;
    try {
      final text = _ImageLane._unwrapEval(
        await controller
            .evaluateJavascript(
              source:
                  "(function(){var i=document.querySelector('img');"
                  "if(!i) return 'no-img';"
                  "return i.naturalWidth + 'x' + i.naturalHeight;})()",
            )
            .timeout(const Duration(seconds: 10)),
      );
      await record(
        'img-natural-wxh',
        null,
        text == null || text.isEmpty || text == 'no-img'
            ? 'no <img> on landing page (landing=$landing)'
            : null,
      );
      // 把尺寸信息也带进结论（不作为 bytes）。
      results.last['natural'] = text;
    } catch (e) {
      await record('img-natural-wxh', null, 'probe failed: $e');
    }

    // 策略 1（头号候选）：canvas 读已解码位图，零网络请求。
    try {
      final text = await evalAsyncResult(
        controller,
        r"""
        var img = document.querySelector('img');
        if (!img) return JSON.stringify({status: 0, error: 'no-img'});
        if (!img.complete) {
          return JSON.stringify({status: 0, error: 'img-not-complete'});
        }
        if (!img.naturalWidth) {
          return JSON.stringify({status: 0, error: 'decode-failed'});
        }
        try {
          var c = document.createElement('canvas');
          c.width = img.naturalWidth;
          c.height = img.naturalHeight;
          var ctx = c.getContext('2d');
          ctx.drawImage(img, 0, 0);
          var data = c.toDataURL('image/png');
          return JSON.stringify({status: 200, data: data});
        } catch (e) {
          // SecurityError = canvas 被跨域污染；改用服务端 blob 转存不可行时
          // 至少把尺寸带回来，证明位图已在浏览器里。
          return JSON.stringify({
            status: 0,
            error: 'canvas:' + String(e),
            natural: img.naturalWidth + 'x' + img.naturalHeight
          });
        }
        """,
        timeout: Duration(
          seconds: deadline.difference(DateTime.now()).inSeconds.clamp(5, 20),
        ),
      );
      if (text == null) {
        await record('canvas-read', null, 'no result (timeout)');
      } else {
        final decoded = jsonDecode(text);
        final map = Map<String, dynamic>.from(decoded as Map);
        if (map['status'] == 200 && map['data'] is String) {
          final base64 = map['data'] as String;
          final comma = base64.indexOf(',');
          final bytes = base64Decode(
            comma >= 0 ? base64.substring(comma + 1) : base64,
          );
          await record('canvas-read', bytes, null);
        } else {
          await record(
            'canvas-read',
            null,
            'status=${map['status']} error=${map['error']}',
          );
          if (map['natural'] != null) {
            results.last['natural'] = map['natural'];
          }
        }
      }
    } catch (e) {
      await record('canvas-read', null, 'canvas strategy threw: $e');
    }

    // 策略 3（对照基线）：现有生产路径的同源 fetch 回读。
    try {
      final bytes = await lane.debugFetchSameOrigin(controller, deadline);
      await record('same-origin-fetch', bytes, bytes == null ? 'no bytes' : null);
    } catch (e) {
      await record('same-origin-fetch', null, 'fetch threw: $e');
    }

    // 策略 4：先回主站 comix.to"暖身"（拿 cf_clearance / 建立同源上下文），再
    // 用**动态 <img>** 加载轮换域图。动机：spike 实测 Diva 轮换域在**顶级导航**
    // 阶段就落地 about:blank（被 TLS/WAF 层拒），但主站 + 动态 img 是另一条
    // 请求路径（Sec-Fetch-Dest: image、Referer=comix.to），可能不被同一规则拦。
    // 这是"不新建窗口"前提下最接近"有头环境"的尝试。
    try {
      await controller
          .loadUrl(urlRequest: URLRequest(url: WebUri("https://comix.to/")));
      final warmDeadline = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(warmDeadline)) {
        await Future.delayed(const Duration(milliseconds: 400));
        final st = _ImageLane._unwrapEval(
          await controller.evaluateJavascript(
            source: "document.readyState",
          ),
        );
        if (st == 'complete') break;
      }
      final text = await evalAsyncResult(
        controller,
        '''
        var u = ${jsonEncode(url)};
        return await new Promise(function(resolve){
          var img = new Image();
          img.crossOrigin = 'anonymous';
          var done = false;
          var timer = setTimeout(function(){
            if (done) return;
            done = true;
            resolve(JSON.stringify({status: 0, error: 'img-load-timeout'}));
          }, 15000);
          img.onload = function(){
            if (done) return;
            done = true;
            clearTimeout(timer);
            try {
              var c = document.createElement('canvas');
              c.width = img.naturalWidth;
              c.height = img.naturalHeight;
              c.getContext('2d').drawImage(img, 0, 0);
              resolve(JSON.stringify({
                status: 200,
                data: c.toDataURL('image/png'),
                natural: img.naturalWidth + 'x' + img.naturalHeight
              }));
            } catch (e) {
              resolve(JSON.stringify({
                status: 0,
                error: 'canvas:' + String(e),
                natural: img.naturalWidth + 'x' + img.naturalHeight
              }));
            }
          };
          img.onerror = function(){
            if (done) return;
            done = true;
            clearTimeout(timer);
            resolve(JSON.stringify({status: 0, error: 'img-onerror'}));
          };
          img.src = u;
        });
        ''',
        timeout: const Duration(seconds: 25),
      );
      if (text == null) {
        await record('warmup-dynamic-img', null, 'no result (timeout)');
      } else {
        final map = Map<String, dynamic>.from(jsonDecode(text) as Map);
        if (map['status'] == 200 && map['data'] is String) {
          final b64 = map['data'] as String;
          final comma = b64.indexOf(',');
          final bytes = base64Decode(comma >= 0 ? b64.substring(comma + 1) : b64);
          await record('warmup-dynamic-img', bytes, null);
        } else {
          await record(
            'warmup-dynamic-img',
            null,
            'status=${map['status']} error=${map['error']}',
          );
        }
        if (map['natural'] != null) {
          results.last['natural'] = map['natural'];
        }
      }
    } catch (e) {
      await record('warmup-dynamic-img', null, 'warmup strategy threw: $e');
    }

    return results;
  }

  /// 供 [_ImageLane] 回报跨域 fetch 成功（续签快路径资格）。
  void _reportCrossOriginSuccess() {
    _lastCrossOriginSuccess = DateTime.now();
  }
}

/// 一条独立的取图通道：一个离屏 WebView + 自己的导航互斥链。
class _ImageLane {
  final int index;
  _ImageLane() : index = _nextIndex++;

  static int _nextIndex = 0;

  HeadlessInAppWebView? _webview;
  WebViewEnvironment? _environment;
  Future<void>? _starting;

  /// 导航互斥（单 WebView 只有一个导航上下文），链式串行化。
  Future<void> _navChain = Future.value();

  bool get _isAlive => _webview != null && _webview!.isRunning();

  Future<Uint8List> fetch(
    String url,
    int timeoutSeconds,
    bool tryCrossOriginFirst,
  ) async {
    final deadline = DateTime.now().add(Duration(seconds: timeoutSeconds));
    // 1) 快路径：跨域 fetch 仅在近期成功过时先试，短预算（8s 或剩余时间），
    //    失败立刻转导航——绝不在已知的死路上耗满整个预算。
    if (tryCrossOriginFirst) {
      final budget = deadline.difference(DateTime.now()).inSeconds;
      try {
        final controller = await _ensure();
        final bytes = await _fetchOnce(
          controller,
          jsonEncode(url),
          (budget - 2).clamp(3, 8),
        );
        if (bytes != null) {
          _ComixImageWorker.instance._reportCrossOriginSuccess();
          return bytes;
        }
      } catch (e) {
        Log.info("ImageLane$index", "cross-origin probe failed: $e");
      }
    }
    // 2) 主路径：导航 + 同源 fetch。
    return await _fetchByNavigation(url, deadline);
  }

  /// 页面内 fetch → base64。[urlExpr] 是 JS 表达式（字面量或 location.href）。
  /// 失败（非 200 / 解不出字节 / 超时）返回 null，调用方决定下一步。
  Future<Uint8List?> _fetchOnce(
    InAppWebViewController controller,
    String urlExpr,
    int timeoutSeconds,
  ) async {
    // ⚠️ 走 [evalAsyncResult]：直接 eval 这个 async IIFE 拿不到返回值
    // （ExecuteScriptAsync 不 await Promise → 返回 {}）。
    // ⚠️ 第二段 force-cache 兜底：轮换域（1xx.*.site）的图片 URL 带
    // 单次性签名/按 Sec-Fetch-Dest 拦 fetch —— 导航本身能 200 出图，
    // 但同源 re-fetch 一律 403。此时强制读 HTTP 缓存里导航留下的字节。
    final asyncBody =
        """
      async function load(u) {
        var res = await fetch(u, {
          referrer: 'https://comix.to/',
          redirect: 'follow'
        });
        if (!res.ok) {
          res = await fetch(u, {
            referrer: 'https://comix.to/',
            redirect: 'follow',
            cache: 'force-cache'
          });
        }
        if (!res.ok) return JSON.stringify({status: res.status, error: 'http ' + res.status});
        var blob = await res.blob();
        return await new Promise(function(resolve){
          var fr = new FileReader();
          fr.onload = function(){
            var s = String(fr.result || '');
            var i = s.indexOf(',');
            resolve(JSON.stringify({status: 200, data: i >= 0 ? s.substring(i + 1) : s}));
          };
          fr.onerror = function(){ resolve(JSON.stringify({status: 0, error: 'blob-read-failed'})); };
          fr.readAsDataURL(blob);
        });
      }
      return await load($urlExpr);
""";
    try {
      final text = await evalAsyncResult(
        controller,
        asyncBody,
        timeout: Duration(seconds: timeoutSeconds),
      );
      if (text == null) {
        Log.warning(
          "ImageLane$index",
          "fetch no result within ${timeoutSeconds}s",
        );
        return null;
      }
      final decoded = jsonDecode(text);
      if (decoded is! Map) return null;
      final map = Map<String, dynamic>.from(decoded);
      if (map['status'] == 200 && map['data'] is String) {
        final data = base64Decode(map['data'] as String);
        if (data.isNotEmpty) {
          Log.info("ImageLane$index", "fetched ${data.length} bytes");
          return data;
        }
      }
      Log.warning(
        "ImageLane$index",
        "fetch status=${map['status']} error=${map['error']}",
      );
    } catch (e) {
      Log.warning("ImageLane$index", "fetch failed: $e");
    }
    return null;
  }

  /// 主路径：导航到图片 URL（浏览器自己完成 GET 与 CF 挑战），然后同源
  /// fetch 回读字节（命中浏览器缓存，不二次下载）。整个流程受 [deadline]
  /// 硬约束——到点抛异常，让上层尽快进入错误 UI（用户可手动重试单页）。
  Future<Uint8List> _fetchByNavigation(String url, DateTime deadline) async {
    final prev = _navChain;
    final completer = Completer<void>();
    _navChain = completer.future;
    await prev;
    try {
      final controller = await _ensure();
      try {
        await controller.stopLoading();
      } catch (_) {}
      await controller.loadUrl(urlRequest: URLRequest(url: WebUri(url)));

      // 等页面加载完成（≤15s 且不越过总预算）。
      final navDeadline = DateTime.now().add(const Duration(seconds: 15));
      while (DateTime.now().isBefore(navDeadline) &&
          DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(milliseconds: 250));
        try {
          final state = _unwrapEval(
            await controller
                .evaluateJavascript(source: "document.readyState")
                .timeout(const Duration(seconds: 8)),
          );
          if (state == 'complete') break;
        } catch (_) {}
      }
      if (DateTime.now().isAfter(deadline)) {
        throw "image timeout after navigation for "
            "${url.substring(0, url.length.clamp(0, 80))}";
      }
      // 同源 fetch 回读；CF 挑战可能还没过（页面 complete 但挑战在跑），
      // 在剩余预算内每 2.5s 重试一次。每 3 次失败整页重载一次：轮换域的
      // 挑战/签名可能在首次落地后才放行，困在旧页面（挑战 HTML / 已消费
      // 的签名）上反复 fetch 永远 403，重载才有机会拿到真页面。
      var lastLanding = '';
      var failedAttempts = 0;
      while (DateTime.now().isBefore(deadline)) {
        final remaining = deadline.difference(DateTime.now()).inSeconds;
        final bytes = await _fetchOnce(
          controller,
          'location.href',
          remaining > 2 ? remaining - 2 : 2,
        );
        if (bytes != null) return bytes;
        failedAttempts++;
        if (failedAttempts % 3 == 0) {
          try {
            await controller.stopLoading();
            await controller.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
          } catch (_) {}
        }
        if (lastLanding.isEmpty) {
          try {
            final current = await controller.getUrl();
            lastLanding = current.toString();
            Log.info("ImageLane$index", "navigate landed on $lastLanding");
          } catch (_) {}
        }
        await Future.delayed(const Duration(milliseconds: 2500));
      }
      throw "image timeout for ${url.substring(0, url.length.clamp(0, 80))}";
    } finally {
      completer.complete();
    }
  }

  /// 确保本通道的 WebView 就绪（并发调用去重）。
  Future<InAppWebViewController> _ensure() {
    if (_isAlive) {
      return Future.value(_webview!.webViewController!);
    }
    final starting = _starting;
    if (starting != null) {
      return starting.then((_) => _webview!.webViewController!);
    }
    final future = _start();
    _starting = future;
    return future
        .then((_) {
          final controller = _webview?.webViewController;
          if (controller == null) {
            throw "ImageLane$index: webview controller unavailable";
          }
          return controller;
        })
        .catchError((e) {
          // 启动失败要清空，否则后续所有取图都会复用这个失败的 future。
          _starting = null;
          throw e;
        });
  }

  /// spike 专用：拿到本通道的 controller（复用 [_ensure] 的生命周期与去重）。
  Future<InAppWebViewController> debugEnsure() => _ensure();

  /// spike 专用：跑一次**生产同款**同源 fetch 回读（对照基线），用来确认
  /// 它在被封锁域上是否真的失败。不改变 [_ImageLane] 任何生产状态机。
  Future<Uint8List?> debugFetchSameOrigin(
    InAppWebViewController controller,
    DateTime deadline,
  ) async {
    final remaining = deadline.difference(DateTime.now()).inSeconds;
    return await _fetchOnce(
      controller,
      'location.href',
      remaining > 2 ? remaining - 2 : 2,
    );
  }

  Future<void> _start() async {
    try {
      await _webview?.dispose();
    } catch (_) {}
    _webview = null;

    // 共享 Environment + 启动串行化（见 _getSharedWebViewEnvironment 注释：
    // 各 Lane 各自 create 同文件夹 environment 时第 3 条会永久挂起）。
    _environment = await _getSharedWebViewEnvironment();
    await _withWebviewStartupLock(() async {
      // ⚠️ 必须与采集 Worker 一样应用代理，否则走代理的用户根本连不上 CDN。
      await applyProxySetting();

      final webview = HeadlessInAppWebView(
        webViewEnvironment: _environment,
        initialSize: const Size(800, 1200),
        // ⚠️ 常驻页用 about:blank 而不是 comix.to：主站页面状态（挑战循环/
        // 广告浮层）会成为 eval 的隐藏变量。导航路径不受影响。
        initialUrlRequest: URLRequest(url: WebUri("about:blank")),
      );
      _webview = webview;
      await webview.run();
      Log.info("ImageLane$index", "headless image webview started");
    });
  }

  /// 丢弃本 Lane 的 WebView（挂起/异常后调用），下次取图时重建。
  /// 同时重置导航互斥链：卡死的 fetch 永远不会走到 finally，链上会留下
  /// 一个永不完成的 future，后续请求会全部排在它后面。
  Future<void> reset() async {
    try {
      await _webview?.dispose();
    } catch (_) {}
    _webview = null;
    _starting = null;
    _navChain = Future.value();
  }

  /// WebView2 的 ExecuteScriptAsync 会把返回值再做 JSON 序列化
  /// （可能是多层）。循环解码直到拿到目标内容。
  static String? _unwrapEval(dynamic raw) {
    if (raw == null) return null;
    var s = raw is String ? raw : jsonEncode(raw);
    for (var depth = 0; depth < 5; depth++) {
      final trimmed = s.trim();
      if (trimmed == 'null' || trimmed.isEmpty || trimmed == 'undefined') {
        return null;
      }
      if (trimmed.startsWith('"')) {
        try {
          s = jsonDecode(trimmed) as String;
          continue;
        } catch (_) {
          return null;
        }
      }
      return trimmed;
    }
    return null;
  }
}

/// 在页面上下文执行一段**异步** JS 并取回它产生的字符串结果。
///
/// ⚠️ 2026-10-05 实测结论（线上日志 `fetch result missing status: {}`）：
/// 本环境下 `evaluateJavascript` 走 WebView2 的 ExecuteScriptAsync，
/// **不会等待 Promise**——`async function` 的返回值被序列化成 `{}`。
/// 也就是说，任何 "(async function(){ ... return JSON.stringify(x) })()"
/// 的写法在这里**永远不会拿到数据**（静默失败），此前 comix 的页内 fetch
/// 与图片取字节全栽在这上面，章节数据实际全靠截获钩子兜底。
///
/// 因此改成：脚本同步返回 1，把结果写进 `window.__comixAsync[slot]`；
/// Dart 侧轮询同步读取。JS 内部仍可用 await，只是不再依赖 Promise 返回值。
Future<String?> evalAsyncResult(
  InAppWebViewController controller,
  String asyncBody, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final slot =
      "s${DateTime.now().microsecondsSinceEpoch}"
      "_${(DateTime.now().millisecondsSinceEpoch % 100000)}";
  final js =
      """
(function(){
  window.__comixAsync = window.__comixAsync || {};
  window.__comixAsync['$slot'] = null;
  (async function(){
    try {
      window.__comixAsync['$slot'] = await (async function(){ $asyncBody })();
    } catch (e) {
      window.__comixAsync['$slot'] = JSON.stringify({status: 0, error: String(e)});
    }
  })();
  return 1;
})()
""";
  try {
    await controller.evaluateJavascript(source: js);
  } catch (e) {
    Log.warning("ComixClient", "evalAsync: launch failed: $e");
    return null;
  }
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await Future.delayed(const Duration(milliseconds: 250));
    String? raw;
    try {
      raw = (await controller.evaluateJavascript(
        source:
            "(window.__comixAsync && window.__comixAsync['$slot'] !== null && window.__comixAsync['$slot'] !== undefined)"
            " ? String(window.__comixAsync['$slot']) : ''",
      ))?.toString();
    } catch (_) {
      continue;
    }
    if (raw == null) continue;
    final s = unwrapEvalString(raw);
    if (s == null || s.isEmpty) continue;
    try {
      await controller.evaluateJavascript(
        source: "delete window.__comixAsync['$slot']; return 1;",
      );
    } catch (_) {}
    return s;
  }
  Log.warning(
    "ComixClient",
    "evalAsync: timed out after ${timeout.inSeconds}s",
  );
  return null;
}

/// 解包 evaluateJavascript 返回的字符串（WebView2 会再包一层 JSON 引号）。
String? unwrapEvalString(dynamic raw) {
  if (raw == null) return null;
  var s = raw is String ? raw : jsonEncode(raw);
  for (var depth = 0; depth < 5; depth++) {
    final t = s.trim();
    if (t.isEmpty || t == 'null' || t == 'undefined') return null;
    if (!t.startsWith('"')) return t;
    try {
      final v = jsonDecode(t);
      if (v is String) {
        s = v;
        continue;
      }
      return t;
    } catch (_) {
      return t;
    }
  }
  return null;
}

/// HTML 是否还在 CF / 挑战页上（用于决定要不要再等一轮）。
bool looksLikeChallengePage(String html) {
  final lower = html.toLowerCase();
  return lower.contains('cf-challenge') ||
      lower.contains('challenge-platform') ||
      lower.contains('just a moment') ||
      lower.contains('__cf_chl_opt') ||
      lower.contains('cf-browser-verification') ||
      lower.contains('checking your browser') ||
      lower.contains('__gatekeeper_challenge');
}

/// 给离屏 WebView 应用 App 的代理设置。
///
/// ⚠️ 采集 Worker 与图片 Worker 都必须调用：v0.6.0 的图片 Worker 漏了这一步，
/// 走代理（Clash 等）的用户其图片 WebView 直连 CDN → 全部超时，阅读页空白。
Future<void> applyProxySetting() async {
  var proxy = appdata.settings['proxy'].toString();
  if (proxy == "system" || proxy == "direct") return;
  var proxyAvailable = await WebViewFeature.isFeatureSupported(
    WebViewFeature.PROXY_OVERRIDE,
  );
  if (!proxyAvailable) return;
  var proxyController = ProxyController.instance();
  await proxyController.clearProxyOverride();
  if (!proxy.contains("://")) {
    proxy = "http://$proxy";
  }
  await proxyController.setProxyOverride(
    settings: ProxySettings(proxyRules: [ProxyRule(url: proxy)]),
  );
}

/// 全局共享的 WebViewEnvironment（comix 的采集 Worker + 所有图片 Lane 共用）。
///
/// ⚠️ 2026-10-05 排障结论（#P5.1，下载在第 3 张图卡死、0 B/s）：
/// 每条 Lane 各自 `WebViewEnvironment.create` 同一个 userDataFolder，
/// 第三条 Lane 的 create/run 会**永久挂起**（无日志、无异常、无超时）——
/// 日志显示 Lane0/Lane1 各取 1 张后进程再无输出，正与"第 3 张图卡住"吻合。
/// 修复：全部离屏 WebView 共享同一个 Environment 实例（共享 future 去重），
/// 且启动串行化（下方 [_withWebviewStartupLock]）。
WebViewEnvironment? _sharedWebViewEnvironment;
Future<WebViewEnvironment>? _sharedEnvCreate;

Future<WebViewEnvironment> _getSharedWebViewEnvironment() {
  return _sharedEnvCreate ??= () async {
    _sharedWebViewEnvironment ??= await WebViewEnvironment.create(
      settings: WebViewEnvironmentSettings(
        userDataFolder: "${App.dataPath}\\webview",
      ),
    );
    return _sharedWebViewEnvironment!;
  }();
}

/// 离屏 WebView 启动互斥（全局）：WebView2 的 environment 创建与
/// headless run 并发执行不可靠，串行化后各 Lane 依次启动。
Future<void> _webviewStartupLock = Future.value();

Future<T> _withWebviewStartupLock<T>(Future<T> Function() action) async {
  final prev = _webviewStartupLock;
  final completer = Completer<void>();
  _webviewStartupLock = completer.future;
  try {
    await prev;
    return await action();
  } finally {
    completer.complete();
  }
}

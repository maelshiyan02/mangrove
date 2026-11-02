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
/// 已逆向确认的 comix.to API（见 `.agent/documents/handoff/P4-HANDOFF-comix-to源-agent交接-20260929.md`）：
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
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart' show Size, Navigator, showGeneralDialog, Colors;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:mangrove/foundation/app.dart';
import 'package:mangrove/foundation/appdata.dart';
import 'package:mangrove/foundation/consts.dart';
import 'package:mangrove/foundation/js_engine.dart';
import 'package:mangrove/foundation/log.dart';
import 'package:mangrove/network/comix_browser.dart';
import 'package:mangrove/network/proxy.dart';
import 'package:mangrove/pages/webview.dart';

// P-DL9 (2026-10-18)：全文件共享的 Chrome 伪装 headers
// — 覆盖 WebView2 自动追加的 sec-ch-ua: "Edg";v=xxx
const Map<String, String> chromeHeaders = {
  'sec-ch-ua': '"Chromium";v="155", "Not_A Brand";v="24", "Google Chrome";v="155"',
  'sec-ch-ua-mobile': '?0',
  'sec-ch-ua-platform': '"Windows"',
  'sec-fetch-site': 'none',
  'sec-fetch-mode': 'navigate',
  'sec-fetch-user': '?1',
  'sec-fetch-dest': 'document',
  'upgrade-insecure-requests': '1',
  'accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7',
  'accept-language': 'zh-CN,zh;q=0.9,en;q=0.8',
  'cache-control': 'max-age=0',
};

class ComixClient {
  static const _baseUrl = "https://comix.to";

  static final ComixClient instance = ComixClient();

  final _worker = _ComixWorker.instance;

  // P-DL9: 防并发验证 —— 多个请求同时检测到 CF challenge 时，
  // 只有第一个会打开可见 WebView，后续请求 await 同一个 completer。
  static Completer<bool>? _verifyGuard;

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
  /// 通过 headless WebView 抓取 comix.to 页面 HTML（导航后直接读 DOM）。
  ///
  /// 🔴 2026-10-19：CDP 导航已由 [fetchPageSnapshot] 负责（且会在 503 熔断时
  ///    直接返回 blocked，不再回落到这里）。本方法只做 WebView2 兜底，避免对
  ///    同一 URL 二次 Page.navigate（连发文档导航会触发 comix 的第三方判定）。
  Future<String> fetchPageHtml(String url) async {
    // === headless WebView 路径 ===
    return _worker.enqueue(() async {
      final controller = await _worker.ensure();
      try {
        await controller.stopLoading();
      } catch (_) {}

      Future<String?> safeEval(String js) async {
        try {
          return unwrapEvalString(
            await controller.evaluateJavascript(source: js)
                .timeout(const Duration(seconds: 5)),
          );
        } catch (_) {
          return null;
        }
      }

      Log.info("ComixClient", "fetchPageHtml: loading $url");
      try {
        await controller
            .loadUrl(urlRequest: URLRequest(url: WebUri(url)))
            .timeout(const Duration(seconds: 15));
      } catch (e) {
        Log.warning(
          "ComixClient",
          "fetchPageHtml: loadUrl hung for $url → restarting worker: $e",
        );
        await _worker.restart();
        final freshController = await _worker.ensure();
        try {
          await freshController
              .loadUrl(urlRequest: URLRequest(url: WebUri(url)))
              .timeout(const Duration(seconds: 15));
        } catch (e2) {
          await _worker.restart();
          throw "COMIX_IP_BLOCKED: loadUrl hung for $url";
        }
      }

      final readyDeadline = DateTime.now().add(const Duration(seconds: 15));
      String? lastHtml;
      while (DateTime.now().isBefore(readyDeadline)) {
        await Future.delayed(const Duration(milliseconds: 500));
        final state = await safeEval("document.readyState");
        if (state == null) {
          Log.warning(
            "ComixClient",
            "fetchPageHtml: eval timeout (readyState) for $url",
          );
          await _worker.restart();
          throw "COMIX_IP_BLOCKED: eval timeout on $url";
        }
        if (state == 'interactive' || state == 'complete') {
          for (var sample = 0; sample < 2; sample++) {
            await Future.delayed(Duration(milliseconds: sample == 0 ? 200 : 500));
            final href = await safeEval('location.href');
            final html = await safeEval(
              "(document.documentElement && document.documentElement.outerHTML) || ''",
            );
            if (href == null && html == null) {
              Log.warning(
                "ComixClient",
                "fetchPageHtml: both evals timed out (sample=$sample)",
              );
              await _worker.restart();
              throw "COMIX_IP_BLOCKED: eval timeout on $url";
            }
            lastHtml = html;
            final isWafHref = (href ?? '').contains('/@waf/challenge');
            final isCfKeyword = html != null && looksLikeChallengePage(html);
            final isTinyStub = html != null &&
                html.length < 500 &&
                !html.contains('initial-data');
            if (isWafHref || isCfKeyword || isTinyStub) {
              Log.warning(
                "ComixClient",
                "fetchPageHtml: challenge detected for $url "
                "(href=$href, ${html?.length ?? 0} chars)",
              );
              await _worker.restart();
              throw "COMIX_IP_BLOCKED: challenge page for $url";
            }
            if (html != null &&
                html.length > 20000 &&
                html.contains('initial-data')) {
              Log.info(
                "ComixClient",
                "fetchPageHtml: ${html.length} chars from $url",
              );
              return html;
            }
          }
        }
      }

      if (lastHtml != null && lastHtml.isNotEmpty) {
        final isChallenge = looksLikeChallengePage(lastHtml) ||
            (lastHtml.length < 500 && !lastHtml.contains('initial-data'));
        if (isChallenge) {
          Log.warning(
            "ComixClient",
            "fetchPageHtml: timeout → challenge page for $url "
            "(${lastHtml.length} chars)",
          );
          await _worker.restart();
          throw "COMIX_IP_BLOCKED: challenge page for $url";
        }
      }
      await _worker.restart();
      throw "fetchPageHtml: no usable HTML for $url (timeout, last=${lastHtml?.length ?? 0} chars)";
    }, timeout: const Duration(seconds: 60));
  }

  /// 最后一次匹配到的 API 截获 URL（无论其 body 是否可用）。
  /// 用于"原样重放"兜底——token 绑定完整 query，只能整条复用。
  String? _lastCaptureUrl;

  // ---- 核心方法 ----

  /// 采集章节列表，返回 Mangrove versioned 格式。
  /// 优先 API 直采，失败回退 DOM 采集。
  ///
  /// 🔴 2026-10-11 加固（Mangrove P38）：comix.to 现已对大量标题的章节 API
  /// 返回加密体 `{"e":"..."}`，且 headless worker 偶发停在空白页/坏状态，导致
  /// DOM 探针整段抓不到（日志实证 `chapter section not ready: null`）。为空时
  /// 重建 worker（全新 WebView 会话）重试一次，避免"永久空结果"卡死后续串行队列。
  Future<Map<String, List<Map<String, dynamic>>>> fetchChapters({
    required String hid,
    String slug = '',
  }) async {
    final url = slug.isNotEmpty
        ? "$_baseUrl/title/$hid-$slug"
        : "$_baseUrl/title/$hid";

    Map<String, List<Map<String, dynamic>>> result;
    try {
      result = await _tryFetchChapters(hid, slug, url);
    } catch (e) {
      if (_isIpBlocked(e)) {
        // 🟢 自动触发 CF 验证（用户完全无感知）
        Log.info("ComixClient", "fetchChapters: CF detected → auto verifyCloudflare()");
        final verified = await verifyCloudflare(url: url);
        if (verified) {
          Log.info("ComixClient", "fetchChapters: CF passed → retrying...");
          result = await _tryFetchChapters(hid, slug, url);
        } else {
          Log.warning("ComixClient", "fetchChapters: CF not passed → rethrow");
          rethrow;
        }
      } else {
        Log.error("ComixClient", "fetchChapters error: $e");
        result = {};
      }
    }
    if (result.isEmpty) {
      Log.warning(
        "ComixClient",
        "fetchChapters(hid=$hid) empty — restarting worker and retrying once",
      );
      await _worker.restart();
      result = await _tryFetchChapters(hid, slug, url);
    }
    return result;
  }

  /// 用 Chrome CDP 采集章节列表。
  ///
  /// 章节数据源优先级：
  ///   1. **CDP 页面内 fetch API** — 最完整（API 返回所有章节所有 scanlation group）
  ///   2. **DOM 解析 .mchap-row** — 兜底，需要先触发 SPA 加载所有分页才能拿全
  ///
  /// comix.to 站点变更记录：
  ///   - 2026-10-18：initial-data 不再包含 chapters 字段，SSR 方案已废弃
  Future<Map<String, List<Map<String, dynamic>>>> _parseChaptersFromSSR(
    ComixCDPWorker cdp, String hid, String slug,
  ) async {
    // === 方案 A：CDP 页面内 fetch API（最新最完整）===
    // 关键：API 需要 _=token 参数（SPA secure.js 生成），不能自己拼 URL
    // 策略：先让 SPA 自己发请求（navigate 后已自动发），从 performance 里拿完整 URL
    try {
      final apiResult = await cdp.evaluate(r"""
(async function(){
  try {
    var hid = '%s';
    // 1. 先从 performance 找 SPA 已经发过的 chapters API（带 token）
    var entries = performance.getEntriesByType('resource').filter(function(e){
      return e.name.indexOf('/api/v1/manga/' + hid + '/chapters') >= 0 && e.name.indexOf('_=') >= 0;
    });
    var apiUrl = entries.length > 0 ? entries[entries.length-1].name : null;

    // 2. 如果没找到（SPA 还没发请求），触发 SPA 翻页/点 tab
    if(!apiUrl) {
      // 点分页按钮或滚动触发懒加载
      var btn = document.querySelector('[class*="pagination-next"], [class*="nav-pager-next"]');
      if(btn) btn.click();
      // 滚动 chapters section
      var sec = document.querySelector('section.mpage__chapters, [class*="chapters"]');
      if(sec) sec.scrollTop = sec.scrollHeight;
      await new Promise(r => setTimeout(r, 1500));
      entries = performance.getEntriesByType('resource').filter(function(e){
        return e.name.indexOf('/api/v1/manga/' + hid + '/chapters') >= 0 && e.name.indexOf('_=') >= 0;
      });
      apiUrl = entries.length > 0 ? entries[entries.length-1].name : null;
    }

    if(!apiUrl) {
      // 3. 还是没有 token URL — 试试直接 fetch 不带 token（可能返回空或错误）
      apiUrl = '/api/v1/manga/' + hid + '/chapters?page=1&limit=100';
    }

    var allItems = [];
    var seenUrls = new Set();  // 全局按 URL 去重（token invalid 可能返回重复页）
    var page = 1;
    var baseUrl = apiUrl.split('?')[0];
    var qIdx = apiUrl.indexOf('?');
    var queryParams = qIdx >= 0 ? apiUrl.substring(qIdx+1).split('&') : [];
    var tokenPart = '';
    for(var p of queryParams) { if(p.startsWith('_=')) { tokenPart = p; break; } }

    while(true) {
      // 保留原 query 里所有参数，只替换 page 和 limit
      var newParams = [];
      var hasPage = false, hasLimit = false;
      for(var p of queryParams) {
        if(p.startsWith('page=')) { newParams.push('page=' + page); hasPage = true; }
        else if(p.startsWith('limit=')) { newParams.push('limit=100'); hasLimit = true; }
        else { newParams.push(p); }
      }
      if(!hasPage) newParams.push('page=' + page);
      if(!hasLimit) newParams.push('limit=100');
      var url = baseUrl + '?' + newParams.join('&');

      var resp = await fetch(url, {credentials:'include', headers:{'Accept':'application/json'}});
      var text = await resp.text();
      var data;
      try { data = JSON.parse(text); } catch(e) { break; }
      if(!data || !data.result) {
        if(allItems.length > 0) break;
        return JSON.stringify({error: 'API invalid: ' + text.substring(0,200), tokenFound: !!tokenPart, status: resp.status});
      }
      var items = data.result.items || [];
      if(items.length === 0) break;
      
      // 按 URL 去重
      var dupesThisPage = 0;
      items.forEach(function(item){
        var u = item.url || '';
        var fullUrl = u.startsWith('http') ? u : 'https://comix.to' + u;
        if(seenUrls.has(fullUrl)) { dupesThisPage++; return; }
        seenUrls.add(fullUrl);
        allItems.push(item);
      });
      if(dupesThisPage > 0) {
        // 出现重复 = token 可能过期了（返回第一页数据）
        // 继续下一页，但如果连续两页都重复就停
      }
      
      if(!data.result.hasNextPage || items.length < 100) break;
      page++;
      if(page > 10) break;
    }

    var out = {};
    var dupesInGroup = [];
    allItems.forEach(function(item){
      var num = item.number != null ? String(item.number) : '';
      if(!num) return;
      var group = (item.group && item.group.name) || '';
      if(!out[num]) out[num] = [];
      var entry = {
        num: num,
        title: item.name || '',
        group: group,
        url: item.url ? (item.url.startsWith('http') ? item.url : 'https://comix.to' + item.url) : ''
      };
      // 同 number+group+url 三字段完全相同才认为是真重复
      var dupe = out[num].some(function(e){
        return e.group === group && e.url === entry.url;
      });
      if(dupe) { dupesInGroup.push({num:num, group:group, url:entry.url}); return; }
      out[num].push(entry);
    });
    return JSON.stringify({
      totalItems: allItems.length, uniqueNums: Object.keys(out).length,
      data: out, tokenUsed: !!tokenPart, tokenValue: tokenPart.substring(0, Math.min(20, tokenPart.length)),
      pageCount: page, seenUrls: seenUrls.size,
      dupesFiltered: dupesInGroup.length
    });
  } catch(e) {
    return JSON.stringify({error: String(e)});
  }
})()
""".replaceAll('%s', hid));
      if (apiResult != null && apiResult is String) {
        final parsed = jsonDecode(apiResult) as Map<String, dynamic>;
        if (parsed.containsKey('data') && parsed['data'] is Map) {
          final data = parsed['data'] as Map<String, dynamic>;
          Log.info("ComixClient", "CDP API chapters: ${parsed['totalItems']} items → ${parsed['uniqueNums']} nums (token=${parsed['tokenUsed']}) ✅");
          return data.map((k, v) => MapEntry(k, (v as List).cast<Map<String, dynamic>>()));
        } else if (parsed.containsKey('error')) {
          Log.warning("ComixClient", "CDP API fetch: ${parsed['error']}");
        }
      }
    } catch (e) {
      Log.warning("ComixClient", "CDP API fetch failed: $e");
    }

    // === 方案 B：DOM 解析 .mchap-row（兜底，分页采集）===
    // comix.to 章节列表每页 20 条（503jz 全集 371 条 ≈ 19 页）。旧实现只读
    // 当前页 → 371 条只拿到 20 条 → 只有 5 个话号（线上实证）。
    // 这里用 `?page=N` 的**客户端路由**逐页采集：pushState 不触发文档导航，
    // 不会再次触发 comix 的 third-party 拦截，也不消耗 CF 挑战次数。
    const collectJs = r"""
(function(){
  var rows = document.querySelectorAll('.mchap-row');
  var out = {};
  rows.forEach(function(row){
    var link = row.querySelector('.mchap-row__primary');
    var numEl = row.querySelector('.mchap-row__ch');
    var groupEl = row.querySelector('.mchap-row__group');
    if(!link || !numEl) return;
    var num = (numEl.textContent || '').replace(/[^0-9]/g,'');
    var href = link.getAttribute('href') || '';
    var group = groupEl ? (groupEl.textContent || '').trim() : '';
    if(!num || !href) return;
    var url = href.indexOf('http') === 0 ? href : 'https://comix.to' + href;
    if(!out[num]) out[num] = [];
    // 同话同组同 URL 才算重复（多组共存是正常的）
    if(out[num].some(function(e){ return e.url === url; })) return;
    out[num].push({num:num, title:link.textContent.trim(), group:group, url:url});
  });
  var sec = document.querySelector('SECTION.mpage__chapters');
  var nums = sec ? Array.from(sec.querySelectorAll('button.npager__num'))
      .map(function(b){ return parseInt((b.textContent||'').trim(), 10); })
      .filter(function(n){ return n > 0; }) : [];
  var active = sec ? sec.querySelector('button.npager__num.is-active') : null;
  return JSON.stringify({
    path: location.pathname,
    search: location.search,
    rows: rows.length,
    pagerMax: nums.length ? Math.max.apply(null, nums) : 1,
    active: active ? (active.textContent||'').trim() : null,
    blocked: document.body ? document.body.innerText.indexOf('Third-party apps') >= 0 : false,
    data: out
  });
})()
""";

    final out = <String, List<Map<String, dynamic>>>{};
    final seenUrls = <String>{};
    var path = '/';
    var search = '';
    var pagerMax = 1;

    Future<bool> collectOnce() async {
      final raw = await cdp.evaluate(collectJs);
      if (raw is! String) return false;
      final m = jsonDecode(raw) as Map<String, dynamic>;
      if (m['blocked'] == true) {
        Log.warning("ComixClient", "CDP DOM: comix returned Third-party page");
        return false;
      }
      path = (m['path'] as String?) ?? path;
      search = (m['search'] as String?) ?? search;
      pagerMax = (m['pagerMax'] as num?)?.toInt() ?? pagerMax;
      final data = m['data'];
      if (data is Map) {
        data.forEach((k, v) {
          final num = '$k';
          for (final raw in (v as List)) {
            final e = Map<String, dynamic>.from(raw as Map);
            final u = (e['url'] as String?) ?? '';
            if (u.isEmpty || !seenUrls.add(u)) continue;
            (out[num] ??= <Map<String, dynamic>>[]).add(e);
          }
        });
      }
      return true;
    }

    final ok = await collectOnce();
    if (!ok) return {};
    Log.info(
      "ComixClient",
      "CDP DOM: page 1 ${seenUrls.length} rows, pagerMax=$pagerMax",
    );

    if (pagerMax > 1) {
      final deadline = DateTime.now().add(const Duration(seconds: 100));
      var stale = 0;
      for (var p = 2; p <= pagerMax && p <= 40; p++) {
        if (DateTime.now().isAfter(deadline)) {
          Log.info("ComixClient", "CDP DOM: paging budget exhausted at page $p");
          break;
        }
        final before = seenUrls.length;
        final next = Uri(
          scheme: 'https',
          host: 'comix.to',
          path: path,
          queryParameters: {
            ...Uri.splitQueryString(search),
            'page': '$p',
          },
        ).toString();
        await cdp._pushState(next);
        var gained = 0;
        final waitUntil = DateTime.now().add(const Duration(seconds: 8));
        while (DateTime.now().isBefore(waitUntil)) {
          await Future.delayed(const Duration(milliseconds: 700));
          if (!await collectOnce()) return out;
          gained = seenUrls.length - before;
          if (gained > 0) break;
        }
        Log.info(
          "ComixClient",
          "CDP DOM: page $p +$gained (cumulative=${seenUrls.length})",
        );
        if (gained == 0) {
          if (++stale >= 2) break;
        } else {
          stale = 0;
        }
      }
    }

    if (out.isNotEmpty) {
      Log.info(
        "ComixClient",
        "CDP DOM chapters: ${seenUrls.length} rows → ${out.length} chapter numbers",
      );
    }
    return out;
  }

  /// 用 Chrome CDP 采集章节图片 URL — 并行 click seg 按钮 + 轮询 DOM。
  ///
  /// comix.to 章节页是 SPA：虚拟化渲染（同时只显示 3-5 张），
  /// 但 105 个 .rpage-progress__seg 按钮每 click 一个 → SPA 内部预取下一张
  /// → 我们并行 click 所有 seg（10ms 间隔）→ SPA 并行预取 → 2-3 秒收齐。
  Future<List<String>> _fetchChapterImagesViaCDP(
    ComixCDPWorker cdp, String chapterUrl,
  ) async {
    // 1. 导航到章节页
    Log.info("ComixClient", "CDP navigate → $chapterUrl");
    await cdp.navigate(chapterUrl);

    // 2. 检查是否被 third-party 拦截
    final hasThirdParty = await cdp.evaluate(
      "document.body.innerText.indexOf('Third-party apps') >= 0",
    );
    if (hasThirdParty == true) {
      throw Exception("CDP: comix.to blocked this Chrome instance — needs CF");
    }

    // 3. 清理透明广告层 + 装 MutationObserver + 并行 click 所有 seg
    final setupJs = """
(function(){
  // 清广告层
  var adSelectors = '[class*="ad-"],[class*="overlay"],[class*="modal"],[class*="popup"],[class*="interstitial"],[class*="shield"]';
  document.querySelectorAll(adSelectors).forEach(function(el){ if(el.style) el.style.display='none'; });

  // 收集已发现的图片
  if(!window.__comixImgUrls) window.__comixImgUrls = new Set();
  document.querySelectorAll('.rpage-page__img').forEach(function(img){ if(img.src) window.__comixImgUrls.add(img.src); });

  // MutationObserver 监听新 img
  if(!window.__comixImgObs){
    window.__comixImgObs = new MutationObserver(function(mutations){
      mutations.forEach(function(m){
        m.addedNodes.forEach(function(n){
          if(n.querySelectorAll){
            n.querySelectorAll('.rpage-page__img').forEach(function(img){ if(img.src) window.__comixImgUrls.add(img.src); });
          }
          if(n.classList && n.classList.contains && n.classList.contains('rpage-page__img') && n.src){ window.__comixImgUrls.add(n.src); }
        });
      });
    });
    window.__comixImgObs.observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ['src'] });
  }

  // 并行 click 所有 seg（10ms 间隔让 SPA 有时间处理）
  var segs = document.querySelectorAll('.rpage-progress__seg');
  var total = segs.length;
  for(var i=0; i<segs.length; i++){
    (function(seg, idx){ setTimeout(function(){ seg.click(); }, idx*10); })(segs[i], i);
  }
  return total;
})()
""";
    final segTotal = await cdp.evaluate(setupJs);
    Log.info("ComixClient", "CDP segs total: $segTotal");

    // 4. 轮询收齐所有图片
    final stopwatch = Stopwatch()..start();
    var lastCount = 0;
    var stableTicks = 0;
    const maxWait = Duration(seconds: 15);

    while (stopwatch.elapsed < maxWait) {
      final urlsJson = await cdp.evaluate(
        "JSON.stringify(Array.from(window.__comixImgUrls || new Set()))",
      );
      if (urlsJson != null && urlsJson is String) {
        try {
          final list = jsonDecode(urlsJson) as List;
          if (list.length > lastCount) {
            lastCount = list.length;
            stableTicks = 0;
            Log.info("ComixClient", "CDP images: ${list.length}");
          } else {
            stableTicks++;
          }
          // 收齐或连续 3 次没增长
          if (segTotal != null && list.length >= (segTotal as int) - 1) break;
          if (stableTicks >= 3) break;
        } catch (_) {}
      }
      await Future.delayed(const Duration(milliseconds: 500));
    }

    final finalUrls = await cdp.evaluate(
      "JSON.stringify(Array.from(window.__comixImgUrls || new Set()))",
    );
    if (finalUrls != null && finalUrls is String) {
      try {
        final list = jsonDecode(finalUrls) as List;
        Log.info("ComixClient", "CDP final images: ${list.length}");
        return list.cast<String>();
      } catch (_) {}
    }
    return [];
  }

  /// 采集用的页面快照：**一次导航**同时拿到 HTML 与 DOM 元信息。
  ///
  /// 背景（2026-10-19）：详情页在 comix 上是 SPA 客户端路由渲染，**没有 SSR 的
  /// `#initial-data`**（那是服务端渲染才注入的），所以 JS 源 `loadInfo` 会报
  /// `no manga detail`。这里把 `og:*` / `h1` / 章节行数一起交上去，让 JS 源
  /// 退化成「DOM 元信息 + 章节桥」继续建下载任务，而不是整体失败。
  ///
  /// 返回：`{status, blocked, html, meta}`。
  Future<Map<String, dynamic>> fetchPageSnapshot(String url) async {
    final cdp = ComixCDPWorker.instance;
    try {
      await cdp.navigate(url);
    } catch (e) {
      // 命中 503 熔断（COMIX_THIRD_PARTY）或死 CDP 超时：直接按封禁返回，
      // 不再往下走 WebView 兜底——WebView 同样过不了 CF，还会触发自动验证死循环。
      final s = e.toString();
      Log.warning("ComixClient", "fetchPageSnapshot: navigate 失败 ($s) → 返回 blocked");
      return <String, dynamic>{
        'status': 503,
        'blocked': true,
        'html': '',
        'meta': <String, dynamic>{},
      };
    }
    if (cdp.blockedThirdParty) {
      return <String, dynamic>{
        'status': 503,
        'blocked': true,
        'html': '',
        'meta': <String, dynamic>{},
      };
    }
    try {
      final html = await cdp.evaluate(
        "document.documentElement ? document.documentElement.outerHTML : ''",
      );
      final meta = await cdp.pageMeta();
      return <String, dynamic>{
        'status': 200,
        'blocked': false,
        'html': html is String ? html : '',
        'meta': meta,
      };
    } catch (e) {
      Log.warning("ComixClient", "fetchPageSnapshot: 读 DOM 失败 ($e) → 返回 blocked");
      return <String, dynamic>{
        'status': 503,
        'blocked': true,
        'html': '',
        'meta': <String, dynamic>{},
      };
    }
  }

  /// 503 Third-party 的处理策略（2026-10-19 二次取证后重写）。
  ///
  /// 上一轮这里是「清 cookie → 人过 CF → 重载首页 → 重试」，实证是**错的**：
  ///   - 清 cookie 后 comix 仍 503（全新 profile 只导航一次首页就 503）；
  ///   - 恢复流程本身要连发 2 次首页导航 + 2 次路由，直接把 503 从 1 次放大
  ///     到 4 次（线上 16:53:47 成功 → 16:54:29 起全站 503）。
  /// 所以现在只做一件事：**立刻停下**，把可操作信息抛给用户。
  static const comixThirdPartyHint =
      "comix.to 判定本次自动化会话为「第三方应用」（HTTP 503）。"
      "这不是 Cloudflare 挑战，重试/清缓存都没用；请等待约 10 分钟冷却，"
      "或换一个网络出口后，先点「验证 CF」再采集。";

  Future<Map<String, List<Map<String, dynamic>>>> _tryFetchChapters(
    String hid,
    String slug,
    String url,
  ) async {
    // P-DL9 (2026-10-18)：优先走 Chrome CDP（TLS 指纹正确，不被 CF challenge）
    final cdp = ComixCDPWorker.instance;
    if (await cdp.isAvailable()) {
      try {
        Log.info("ComixClient", "fetchChapters(hid=$hid) via Chrome CDP SSR");
        // 🔴 2026-10-19：**不再**把 cf_cookie.json 里的旧 cf_clearance 回注 CfT。
        //    CfT 有自己的持久 profile，cookie 本来就在 jar 里；回注一个**过期/
        //    已被标记**的 clearance 反而会让 comix 直接回 503 Third-party
        //    （线上 16:44 日志：刚 bootstrap 首页就 `comix returned Third-party page`）。
        //    保存 cookie 只服务于 JS 引擎直连路径，与 CfT 无关。
        await cdp.navigate(url, waitForChapters: true);
        if (cdp.blockedThirdParty) {
          // 503 → 立刻停手（不再"清 cookie + 重载首页"放大封禁）。
          Log.warning("ComixClient", "CDP hit Third-party 503 → abort (no retry)");
          await cdp.dispose();
          throw "COMIX_THIRD_PARTY: $comixThirdPartyHint";
        } else {
          final result = await _parseChaptersFromSSR(cdp, hid, slug);
          if (result.isNotEmpty) {
            Log.info("ComixClient", "CDP SSR returned ${result.length} chapters ✅");
            return result;
          }
          Log.warning("ComixClient", "CDP SSR empty — falling back to headless WebView");
          await cdp.dispose();
        }
      } catch (e) {
        // 503 是硬阻断：不降级、不重试，直接把可操作提示抛给 UI。
        if (e is String && e.contains('COMIX_THIRD_PARTY')) rethrow;
        Log.warning("ComixClient", "CDP SSR failed: $e — falling back to headless");
        await cdp.dispose();
      }
    }

    // === 以下是 headless WebView 路径（CDP 不可用时 fallback） ===
    Log.info("ComixClient", "fetchChapters(hid=$hid) via headless worker");

    Map<String, List<Map<String, dynamic>>> result = {};
    try {
      result = await _worker.enqueue(
        () => _fetchChaptersViaApi(hid, slug, url),
        timeout: const Duration(seconds: 60),
      );
    } catch (e, s) {
      if (_isIpBlocked(e)) rethrow; // P45：被封不降级、不空等，直接提示换节点
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
      if (_isIpBlocked(e)) rethrow; // P45：被封不降级、不空等，直接提示换节点
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
  ///
  /// 🔴 2026-10-11 加固（Mangrove P38）：与 `fetchChapters` 同源的"坏 worker
  /// 永久空结果"问题，空结果时重建 worker 重试一次。
  Future<List<String>> fetchImageUrls({required String chapterUrl}) async {
    Log.info("ComixClient", "fetchImageUrls($chapterUrl) via headless worker");
    List<String> urls;
    try {
      urls = await _tryFetchImageUrls(chapterUrl);
    } catch (e) {
      if (_isIpBlocked(e)) {
        // 🟢 自动触发 CF 验证（和 fetchChapters 一致）
        Log.info("ComixClient", "fetchImageUrls: CF detected → auto verifyCloudflare()");
        final verified = await verifyCloudflare(url: chapterUrl);
        if (verified) {
          Log.info("ComixClient", "fetchImageUrls: CF passed → retrying...");
          await _worker.restart();
          urls = await _tryFetchImageUrls(chapterUrl);
        } else {
          Log.warning("ComixClient", "fetchImageUrls: CF not passed → rethrow");
          rethrow;
        }
      } else {
        Log.error("ComixClient", "fetchImageUrls error: $e");
        urls = const [];
      }
    }
    if (urls.isEmpty) {
      Log.warning(
        "ComixClient",
        "fetchImageUrls empty — restarting worker and retrying once",
      );
      await _worker.restart();
      urls = await _tryFetchImageUrls(chapterUrl);
    }
    return urls;
  }

  Future<List<String>> _tryFetchImageUrls(String chapterUrl) async {
    // P-DL9 (2026-10-18)：优先走 Chrome CDP（和 fetchChapters 同方案）
    final cdp = ComixCDPWorker.instance;
    if (await cdp.isAvailable()) {
      try {
        Log.info("ComixClient", "fetchImageUrls via Chrome CDP");
        final urls = await _fetchChapterImagesViaCDP(cdp, chapterUrl);
        if (urls.isNotEmpty) {
          Log.info("ComixClient", "CDP returned ${urls.length} images ✅");
          return urls;
        }
        Log.warning("ComixClient", "CDP images empty — falling back to headless");
        await cdp.dispose();
      } catch (e) {
        Log.warning("ComixClient", "CDP images failed: $e — falling back to headless");
        await cdp.dispose();
      }
    }

    // === 以下是 headless WebView 路径（CDP 不可用时 fallback） ===
    List<String> urls = [];
    try {
      urls = await _worker.enqueue(
        () => _fetchPagesViaApi(chapterUrl),
        timeout: const Duration(seconds: 90),
      );
    } catch (e, s) {
      if (_isIpBlocked(e)) rethrow; // P45：被封不降级、不空等，直接提示换节点
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
      if (_isIpBlocked(e)) rethrow; // P45：被封不降级、不空等，直接提示换节点
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
    final query = Map<String, String>.from(urlQuery);
    query['page'] = '$page';
    query['limit'] = '28';
    final params = query.entries
        .map(
          (e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
        )
        .join('&');
    final url = params.isEmpty ? "$_baseUrl/browse" : "$_baseUrl/browse?$params";

    // P-DL9 (2026-10-18)：Chrome CDP 优先 — 绕过 CF 不被 challenge
    final cdp = ComixCDPWorker.instance;
    if (await cdp.isAvailable()) {
      try {
        Log.info("ComixClient", "browseManga via Chrome CDP → $url");
        final cdpResult = await _browseViaCDP(cdp, url);
        final cdpItems = cdpResult['items'];
        if (cdpItems is List && cdpItems.isNotEmpty) {
          Log.info("ComixClient", "CDP browse returned ${cdpItems.length} items ✅");
          return cdpResult;
        }
        Log.warning("ComixClient", "CDP browse empty → fallback WebView");
      } catch (e) {
        Log.warning("ComixClient", "CDP browse failed: $e → fallback WebView");
      }
    }

    // === headless WebView 路径（CDP 不可用时 fallback） ===
    try {
      var result = await _route(() => _browseViaApi(url), const Duration(seconds: 90));
      final apiItems = result['items'];
      if (apiItems is List && apiItems.isNotEmpty) return result;

      Log.warning("ComixClient", "browse API empty — falling back to DOM scraping");
      final dom = await _route(() => _browseByDom(url), const Duration(seconds: 120));
      final domItems = dom['items'];
      if (domItems is List && domItems.isNotEmpty) return dom;
      return result;
    } catch (e) {
      // P-DL9c (2026-10-18)：browseManga 也要自动 CF 恢复！之前只 fetchChapters 有
      if (_isIpBlocked(e)) {
        Log.info("ComixClient", "browseManga: CF detected → auto verifyCloudflare()");
        final verified = await verifyCloudflare(url: url);
        if (verified) {
          Log.info("ComixClient", "browseManga: CF passed → retrying...");
          // 重启 worker（让新 cookie 生效）
          await _worker.restart();
          var result = await _route(() => _browseViaApi(url), const Duration(seconds: 90));
          final apiItems = result['items'];
          if (apiItems is List && apiItems.isNotEmpty) return result;
          final dom = await _route(() => _browseByDom(url), const Duration(seconds: 120));
          final domItems = dom['items'];
          if (domItems is List && domItems.isNotEmpty) return dom;
          return result;
        } else {
          Log.warning("ComixClient", "browseManga: CF not passed");
          rethrow;
        }
      }
      rethrow;
    }
  }

  /// worker 队列 + 异常归一化：失败时返回空结果而不是把异常抛给调用方。
  Future<Map<String, dynamic>> _route(
    Future<Map<String, dynamic>> Function() task,
    Duration timeout,
  ) async {
    try {
      return await _worker.enqueue(task, timeout: timeout);
    } catch (e, s) {
      if (_isIpBlocked(e)) rethrow; // P45：被封时搜索也立刻提示换节点
      Log.error("ComixClient", "browse route failed: $e\n$s");
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

  Future<Map<String, dynamic>> _browseViaApi(String url) async {
    final controller = await _worker.ensure();
    await _drainCaptures(controller);

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

  /// 浏览/搜索卡片的 DOM 探测。
  ///
  /// 选择器取自站点 bundle 的卡片组件（`sl(...)` 渲染的
  /// `a.card > .card__poster-wrap img` + `.card__title`），
  /// 与 BT 用 DOM 采章节同一思路——读站点自己渲染出来的结果。
  static const _browseProbeJs = r"""
(function(){
  var cards = Array.from(document.querySelectorAll('a.card'));
  var rows = cards.map(function(a){
    var t = a.querySelector('.card__title');
    var img = a.querySelector('.card__poster-wrap img') || a.querySelector('img');
    return {
      href: a.getAttribute('href'),
      title: t ? (t.textContent || '').trim() : (a.getAttribute('title') || ''),
      cover: img ? (img.getAttribute('src') || img.getAttribute('data-src') || '') : ''
    };
  }).filter(function(r){ return r.href && r.href.indexOf('/title/') >= 0; });
  return JSON.stringify({ ready: rows.length > 0, rows: rows, url: location.href });
})()
""";

  /// CDP browse：先到首页让 SPA bootstrap，然后在页面上下文里 fetch browse API。
  ///
  /// ⚠️ 不能直接 Page.navigate 到 /browse — SPA 路由没识别硬刷的 /browse URL，
  ///     main.js 只发首页 API，不会触发 browse 卡片渲染。
  /// 方案：首页 bootstrap → 直接 fetch /api/v1/manga API（SPA 会带 token+cookie）
  /// → 解析 JSON items 返回。
  Future<Map<String, dynamic>> _browseViaCDP(ComixCDPWorker cdp, String browseUrl) async {
    // Step 1: navigate 到首页让 SPA 完整 bootstrap（main.js 加载 + 路由就绪）
    final currentUrl = await cdp.currentUrl();
    if (currentUrl == null || !currentUrl.contains('comix.to')) {
      Log.info("ComixClient", "CDP browse: navigating to homepage first...");
      await cdp.navigate('$_baseUrl/');
      // 等 SPA bootstrap（API 请求出现）
      for (var i = 0; i < 10; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        final ready = await cdp.evaluate(
          "document.querySelectorAll('a.card').length > 0 || !!document.querySelector('#app-root')",
        );
        if (ready == true || ready == 'true') break;
      }
    }

    // Step 2: 在页面上下文里 fetch browse API
    // URL 参数映射：comix.to /browse?q=xxx → API /api/v1/manga?keyword=xxx&sort=xxx...
    // 需要 SPA 的 token（__=），从 performance 里找 SPA 已发的首页 API 拿 token
    final apiResult = await cdp.evaluate(r"""
(async function(){
  try {
    // 从 browse URL 提取筛选参数
    var browseUrl = '%s';
    var qIdx = browseUrl.indexOf('?');
    var params = {};
    if(qIdx >= 0) {
      browseUrl.substring(qIdx+1).split('&').forEach(function(p){
        var kv = p.split('=');
        if(kv.length === 2) params[decodeURIComponent(kv[0])] = decodeURIComponent(kv[1]);
      });
    }
    var page = parseInt(params['page']) || 1;
    var limit = parseInt(params['limit']) || 28;

    // 从 performance 找 SPA 已发的首页 API — 里面有 token
    var entries = performance.getEntriesByType('resource').filter(function(e){
      return e.name.indexOf('/api/v1/manga?') >= 0;
    });
    var token = null;
    if(entries.length > 0) {
      var lastApi = entries[entries.length-1].name;
      var tIdx = lastApi.indexOf('&_=');
      if(tIdx >= 0) token = lastApi.substring(tIdx);  // 包含 '&_=xxx'
    }

    // 构造 API URL
    // comix.to browse → /api/v1/manga?order[xxx]=desc&keyword=xxx&sort=xxx&types=xxx...
    var apiParams = [
      'page=' + page,
      'limit=' + limit,
      'content_rating[]=safe',
      'content_rating[]=suggestive'
    ];
    if(params['q']) apiParams.push('keyword=' + encodeURIComponent(params['q']));
    if(params['sort']) apiParams.push('sort=' + encodeURIComponent(params['sort']));
    if(params['types']) params['types'].split(',').forEach(function(t){ if(t) apiParams.push('types[]=' + encodeURIComponent(t)); });
    if(params['statuses']) params['statuses'].split(',').forEach(function(s){ if(s) apiParams.push('statuses[]=' + encodeURIComponent(s)); });
    if(params['demos']) params['demos'].split(',').forEach(function(d){ if(d) apiParams.push('demos[]=' + encodeURIComponent(d)); });
    if(token) apiParams.push(token);

    var apiUrl = '/api/v1/manga?' + apiParams.join('&');
    var resp = await fetch(apiUrl, {credentials:'include', headers:{'Accept':'application/json'}});
    var data = await resp.json();

    if(!data || !data.result || !data.result.items) {
      return JSON.stringify({error: 'no items', status: resp.status, tokenFound: !!token});
    }
    var items = data.result.items;
    var out = items.map(function(it){
      return {
        url: it.url ? (it.url.startsWith('http') ? it.url : 'https://comix.to' + it.url) : '',
        title: it.title || (it.hid ? (it.slug || it.hid) : ''),
        poster: (it.poster && it.poster.url) || it.poster || ''
      };
    });
    return JSON.stringify({
      items: out,
      total: data.result.total || out.length,
      lastPage: data.result.pages || 1,
      tokenFound: !!token,
      apiUrl: apiUrl.substring(0, 120)
    });
  } catch(e) {
    return JSON.stringify({error: String(e)});
  }
})()
""".replaceAll('%s', browseUrl));

    if (apiResult == null || apiResult is! String) {
      return {'items': <dynamic>[], 'lastPage': 0};
    }
    try {
      final parsed = jsonDecode(apiResult) as Map<String, dynamic>;
      if (parsed.containsKey('error')) {
        Log.warning("ComixClient", "CDP browse API error: ${parsed['error']} (token=${parsed['tokenFound']})");
        return {'items': <dynamic>[], 'lastPage': 0};
      }
      final items = List<Map<String, dynamic>>.from(parsed['items'] ?? []);
      Log.info("ComixClient", "CDP browse API: ${items.length} items (token=${parsed['tokenFound']}) ✅");
      return {
        'items': items,
        'lastPage': parsed['lastPage'] ?? 1,
      };
    } catch (e) {
      Log.warning("ComixClient", "CDP browse parse failed: $e");
      return {'items': <dynamic>[], 'lastPage': 0};
    }
  }

  /// WebView browse DOM 兜底。
  /// 字段与 API 路径对齐（`url`/`title`/`poster`），供 JS 源的 `_comixMapComic` 复用。
  Future<Map<String, dynamic>> _browseByDom(String url) async {
    final controller = await _worker.ensure();
    await _navigate(controller, url);

    final snap = await _evalWithRetry(
      controller,
      _browseProbeJs,
      timeoutMs: 30000,
    );
    if (snap == null || snap['ready'] != true) {
      Log.warning("ComixClient", "browse DOM: no cards rendered");
      return {'items': <dynamic>[], 'lastPage': 0};
    }
    final rows = List<Map<String, dynamic>>.from(snap['rows'] ?? []);
    final items = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final r in rows) {
      final href = r['href']?.toString() ?? '';
      if (href.isEmpty || !href.contains('/title/')) continue;
      if (!seen.add(href)) continue;
      items.add({
        'url': href,
        'title': r['title']?.toString() ?? '',
        'poster': r['cover']?.toString() ?? '',
      });
    }
    Log.info("ComixClient", "browse DOM: ${items.length} cards");
    return {'items': items, 'lastPage': 1};
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

    // P-DL9c (2026-10-18): 诊断 — 等 SPA 发完 API 后检查 __comixApiLog
    try {
      await Future.delayed(const Duration(seconds: 5));
      final diag = await controller.evaluateJavascript(source: r"""
(function(){
  var log = window.__comixApiLog || [];
  var chapters = log.filter(function(e){ return /\/api\/v\d+\/manga\/[^/]+\/chapters/.test(String(e.url).split('?')[0]) && !String(e.url).indexOf('/user/')>=0; });
  var browse = log.filter(function(e){ return /\/api\/v\d+\/manga(\?|$)/.test(String(e.url).split('?')[0]) && !String(e.url).indexOf('/chapters')>=0 && !String(e.url).indexOf('/user/')>=0; });
  return JSON.stringify({
    total: log.length,
    chaptersCount: chapters.length,
    chaptersStatuses: chapters.map(function(e){ return {status:e.status, url:e.url?String(e.url).substring(0,80):''}; }),
    browseCount: browse.length,
    browseStatuses: browse.map(function(e){ return {status:e.status, url:e.url?String(e.url).substring(0,80):''}; }),
    ua: navigator.userAgent.substring(0,50),
    hasWebview: navigator.userAgent.toLowerCase().indexOf('webview')>=0,
    hasEdg: navigator.userAgent.toLowerCase().indexOf('edg')>=0
  });
})()
""");
      Log.info("ComixClient", "🔍 API DIAGNOSTIC: $diag");
      // P-DL9c: 同时写文件（Start-Process 启动的进程 stdout 丢失）
      try {
        final f = File("${App.dataPath}\\comix_diagnostic.txt");
        await f.writeAsString(
          "${DateTime.now().toIso8601String()}\n$diag\n",
          mode: FileMode.write,
        );
      } catch (_) {}
    } catch (e) {
      Log.warning("ComixClient", "🔍 API DIAGNOSTIC eval error: $e");
    }

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
      Log.warning(
        "ComixClient",
        "no usable chapters API capture (encrypted/empty) — DOM fallback next",
      );
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

  /// 加密响应体标记：comix.to 对部分 `/api/v1/*` 响应返回 `{"e":"<base64>"}`
  /// （只有 SPA 自己的解密逻辑能还原成明文）。
  static final _encryptedBodyRe = RegExp(r'^\s*\{\s*"e"\s*:');

  /// 截获到加密体后，额外留给 `JSON.parse` 明文通道的宽限时长。
  ///
  /// 🔴 2026-10-11 (Mangrove P42)：旧实现在"确认是加密体"后仍空等到
  /// timeout（30/60s）——用户看到的就是"搜索转圈卡住"、"详情卡住不出章节"。
  /// 现在只等这一个短窗口，拿不到明文就立刻返回 null，让上层快速走 DOM 兜底。
  static const _encryptedGrace = Duration(milliseconds: 2000);

  bool _looksEncrypted(String bodyText) =>
      _encryptedBodyRe.hasMatch(bodyText.trim());

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
    DateTime? encryptedAt;
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
        if (_looksEncrypted(bodyText)) {
          encryptedAt ??= DateTime.now();
          Log.info(
            "ComixClient",
            "$what: encrypted payload — waiting ${_encryptedGrace.inMilliseconds}ms for plaintext hook",
          );
        } else {
          Log.warning(
            "ComixClient",
            "$what: captured body unusable, preview=${bodyText.substring(0, bodyText.length.clamp(0, 160))}",
          );
        }
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
      if (encryptedAt != null &&
          DateTime.now().difference(encryptedAt) >= _encryptedGrace) {
        await _logHookDiagnostics(controller, what);
        Log.warning(
          "ComixClient",
          "$what: response is encrypted and no plaintext channel fired — bailing out to fallback",
        );
        return null;
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

  /// 点“下一页”控件（数字按钮窗口滚动 / 只剩 Next 时的兜底）。
  /// 找 aria-label / title / 文本里含 "next" 的按钮或链接。
  static const _clickNextPageJs = r"""
(function(){
  const sec = document.querySelector('SECTION.mpage__chapters');
  if (!sec) return JSON.stringify({ok:false, reason:'no-section'});
  const cands = Array.from(sec.querySelectorAll('button, a'));
  const btn = cands.find(el => {
    const s = ((el.getAttribute('aria-label') || '') + ' ' +
               (el.getAttribute('title') || '') + ' ' +
               (el.textContent || '')).toLowerCase();
    return s.indexOf('next') >= 0;
  });
  if (!btn) return JSON.stringify({ok:false, reason:'no-next'});
  btn.dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true, view: window}));
  return JSON.stringify({ok:true, how:'next'});
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

  /// 阅读页 **并行 click + MutationObserver 极速采集**（2026-10-18 实测 105 页/2s）。
  ///
  /// 原理：
  /// - 章节页有 105 个 `.rpage-progress__seg` 按钮（每个代表一页）
  /// - SPA 虚拟化只渲染 3~5 张 `<img class="rpage-page__img">`
  /// - 旧 React fiber/`<img>` 探针都抓不全（fiber 字段漂移+SPA 架构变，探针只有 3~5 张）
  /// - **新方案**：MutationObserver 装上去监听所有 img src 变化 →
  ///   一次性 click 所有 seg（10ms 间隔） → SPA 内部并行预取所有页 →
  ///   MO 被动收集 src → 2s 收齐全量！
  /// - 先清透明广告层（comix.to 有 floating ad overlay 挡 seg click）
  static const _pagesFastCollectSetupJs = r"""
(function(){
  // 先清广告/遮罩/弹窗 (comix.to 透明广告层会挡 seg click)
  var killSelectors = [
    '[class*="ad-"]','[class*="Ad-"]','[class*="advertisement"]',
    '[class*="overlay"]','[class*="Overlay"]','[class*="modal"]',
    '[class*="popup"]','[class*="Popup"]','[class*="interstitial"]',
    '[class*="shield"]','[class*="paywall"]','[id*="ad"]','[id*="popup"]'
  ];
  killSelectors.forEach(function(sel){
    document.querySelectorAll(sel).forEach(function(el){
      try { el.remove(); } catch(e) { el.style.display='none'; el.style.visibility='hidden'; }
    });
  });
  // 清理全屏 fixed/absolute div (广告弹窗)
  document.querySelectorAll('div').forEach(function(d){
    try {
      var cs = getComputedStyle(d);
      if ((cs.position==='fixed'||cs.position==='absolute') &&
          parseFloat(cs.width)>window.innerWidth*0.7 && parseFloat(cs.height)>window.innerHeight*0.5){
        d.remove();
      }
    } catch(e){}
  });

  var collected = new Set();
  document.querySelectorAll('.rpage-page__img').forEach(function(i){ if(i.src) collected.add(i.src); });

  var obs = new MutationObserver(function(mutations){
    mutations.forEach(function(m){
      m.addedNodes.forEach(function(n){
        if(n.nodeType===1){
          if(n.classList && n.classList.contains('rpage-page__img') && n.src) collected.add(n.src);
          if(n.querySelectorAll){
            n.querySelectorAll('.rpage-page__img').forEach(function(img){ if(img.src) collected.add(img.src); });
          }
        }
      });
      if(m.attributeName==='src' && m.target && m.target.classList &&
         m.target.classList.contains('rpage-page__img') && m.target.src){
        collected.add(m.target.src);
      }
    });
    window.__comixFastPages = Array.from(collected);
  });
  obs.observe(document.documentElement, {childList:true, subtree:true, attributes:true, attributeFilter:['src']});

  var segs = document.querySelectorAll('.rpage-progress__seg');
  for(var i=0;i<segs.length;i++){
    (function(idx){
      setTimeout(function(){ segs[idx].click(); }, idx * 10);
    })(i);
  }
  window.__comixFastPages = Array.from(collected);
  return JSON.stringify({ok:true, totalSegs: segs.length, initial: collected.size});
})()
""";

  /// 轮询 `window.__comixFastPages` 直到收齐（20s 上限，稳定 3s 就停）。
  Future<List<String>> _fastCollectPages(InAppWebViewController controller, int expectedTotal) async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    var lastCount = -1, stable = 0;
    List<String> best = const [];
    while (DateTime.now().isBefore(deadline)) {
      final raw = await controller.evaluateJavascript(source: "JSON.stringify({c: window.__comixFastPages?.length || 0})");
      final map = _parseEvalMap(raw);
      final count = (map?['c'] as num?)?.toInt() ?? 0;
      if (count > lastCount) {
        final delta = DateTime.now().difference(deadline).inSeconds.abs();
        Log.info("ComixClient", "fastCollect: $count/$expectedTotal pages (t+${delta}s)");
        lastCount = count; stable = 0;
      } else {
        stable++;
      }
      if (count >= expectedTotal && count > 0) break;
      if (stable >= 6 && count > 0) break; // 3s 不变就停（已稳定）
      await Future.delayed(const Duration(milliseconds: 500));
    }
    // 最终取完整数组
    final raw = await controller.evaluateJavascript(source: "JSON.stringify(window.__comixFastPages || [])");
    dynamic parsed;
    try { parsed = jsonDecode(raw.toString()); } catch(_) {}
    if (parsed is! List) return best;
    final urls = parsed.map((u) => u.toString()).where((u) => u.isNotEmpty).toList();
    Log.info("ComixClient", "fastCollect done: ${urls.length} pages");
    return urls;
  }

  /// 阅读页 **React fiber 挖取**：拿整章全量图片 URL。
  ///
  /// 🔴 为什么需要它（2026-10-11 P43 取证，reader chunk
  /// `tmq6ux-CARftgsC2.js` 实证）：
  /// 阅读器是 Swiper **虚拟化**——同屏只挂 3 张 `<img class="rpage-page__img">`，
  /// 滚动也不补加载，所以 `<img>` 探针永远只拿到 3~5 张。但站方把**整章页数组**
  /// 留在 React 内存里（fiber 的 props），数组元素就是页对象。
  /// 站方 `<img src>` = `builder(页对象, 页序, 重试次数)`，**重试计数 <= 0 时
  /// 原样返回页对象里的完整 URL 字段**（`?r=` 子域轮换只在重试时才拼）。
  /// 所以从任一页 `<img>` 沿 fiber 向上、或从根容器向下扫描，即可一次性拿回
  /// 全部页 URL，与站点虚拟化无关。
  ///
  /// 🔴 **字段名随站方构建漂移**（压缩名，非稳定契约）：
  /// - 2026-10-11（reader chunk `tmq6ux-*`）：URL = `bZ`、页序 = `q2`；
  /// - 2026-10-12 线上再逆（reader chunk `tmqy0z-DcHRFp8b2.js`，`rpage`×252 /
  ///   `swiper`×6 同签名）：URL = **`B0`**、页序 = **`ka`**、高/宽 = `Rh`/`MO`、
  ///   域名数组 = `lk`、备用域 = `NX`、整章页数组 = query 数据的 **`hs`**。
  /// ⇒ 因此 [urlOf] **先认已知名、再退到通用判据**（页对象里任一直接字符串
  ///   属性以 `http` 开头即认，并排除 `/title/`、`/chapter` 导航链接），
  ///   下次改名仍能命中。
  static const _pagesByReactJs = r"""
(function(){
  function fiberOf(el){
    if(!el) return null;
    for(var k in el){
      if(k.indexOf('__reactFiber$')===0 || k.indexOf('__reactInternalInstance$')===0) return el[k];
    }
    return null;
  }
  function urlOf(o){
    if(!o || typeof o!=='object') return null;
    var v = o.B0;                                   // 2026-10-12 线上构建：URL = B0
    if(typeof v==='string' && v.indexOf('http')===0) return v;
    v = o.bZ;                                       // 2026-10-11 构建：URL = bZ
    if(typeof v==='string' && v.indexOf('http')===0) return v;
    // 字段名随站方构建漂移（压缩名，会变）：页对象里**任一直接字符串属性**
    // 以 http 开头即认，并排除站点导航链接（/title/、/chapter），避免把章节
    // 列表 / 关联漫画数组误当页数组（harvest 取最长，撞上就全错了）。
    var ks = Object.keys(o);
    for(var i=0;i<ks.length;i++){
      var t = o[ks[i]];
      if(typeof t==='string' && t.indexOf('http')===0 &&
         t.indexOf('/title/')<0 && t.indexOf('/chapter')<0) return t;
    }
    return null;
  }
  function pushFrom(el, out){
    if(!el || typeof el!=='object') return;
    var u = urlOf(el);
    if(u){ out.push(u); return; }
    if(el.props && el.props.page){ u = urlOf(el.props.page); if(u){ out.push(u); return; } }
    if(el.page){ u = urlOf(el.page); if(u){ out.push(u); return; } }
    if(Array.isArray(el.lj)){
      for(var i=0;i<el.lj.length;i++){ var uu=urlOf(el.lj[i]); if(uu) out.push(uu); }
    }
  }
  var best = null;
  var visited = new Set();
  function harvest(arr){
    if(!arr || arr.length<2) return;
    var urls = [];
    for(var i=0;i<arr.length;i++) pushFrom(arr[i], urls);
    if(urls.length>=2 && (!best || urls.length>best.length)) best = urls;
  }
  function scan(v, d){
    if(!v || typeof v!=='object' || d>7) return;
    if(visited.has(v)) return;
    visited.add(v);
    if(Array.isArray(v)){
      harvest(v);
      if(v.length<=600){ for(var i=0;i<v.length;i++) scan(v[i], d+1); }
      return;
    }
    var ks = Object.keys(v);
    for(var i=0;i<ks.length;i++){
      var k = ks[i];
      if(k==='return'||k==='child'||k==='sibling'||k==='stateNode'||k==='alternate'||k==='_owner') continue;
      scan(v[k], d+1);
    }
  }
  var seeds = [];
  var img = document.querySelector('img.rpage-page__img, .rpage-page img, .rpage-view img');
  if(img) seeds.push(img);
  var extra = document.querySelectorAll('.rpage-main, #root, #__next, main, section');
  for(var e=0;e<extra.length && e<8;e++) seeds.push(extra[e]);
  for(var s=0;s<seeds.length && !best;s++){
    var node = fiberOf(seeds[s]);
    var depth = 0;
    while(node && depth<150 && !best){
      scan(node.memoizedProps, 0);
      if(!best) scan(node.memoizedState, 0);
      node = node.return; depth++;
    }
  }
  var urls = best || [];
  var seen = {}; var uniq = [];
  for(var j=0;j<urls.length;j++){ if(!seen[urls[j]]){ seen[urls[j]]=1; uniq.push(urls[j]); } }
  return JSON.stringify({ ok: uniq.length>=2, count: uniq.length, urls: uniq });
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
    var consecutiveEmpty = 0;
    // 🔴 基准必须是**首页首行的 href**，不能是 null：站方分页控件常是
    //    "数字窗口(1-8) + Next/Last"（见 P4 交接文档），第一跳若拿 null 当基准，
    //    轮询第一拍就会"以为改了"直接收（读到的还是首页）→ 新增为 0 → 立刻 break，
    //    章节仍只采到一页。
    String? prevFirstHref =
        (firstSnap['rows'] as List?)?.isNotEmpty == true
            ? (firstSnap['rows'] as List).first['href'] as String?
            : null;
    // 整个翻页总预算（enqueue timeout 是 120s，留出余量）。
    final chapterDeadline = DateTime.now().add(const Duration(seconds: 100));
    // 🔴 上界给大：`pages` 只是**可见数字按钮的最大值**、不是总页数
    //    （Next-only 时它=1，旧代码 `p <= pagesHint` 循环根本不进 → 只采一页）。
    //    真正终止靠下面四条：控件消失 / 首行不再变化 / 本轮新增为 0 / 预算耗尽。
    for (var p = 2; p <= 200; p++) {
      if (DateTime.now().isAfter(chapterDeadline)) {
        Log.info("ComixClient", "DOM: chapter paging budget exhausted at page $p");
        break;
      }
      try {
        await controller.evaluateJavascript(source: _adSweepJs);
      } catch (_) {}
      final clickJs = _clickPageJs.replaceFirst('__PAGE__', '$p');
      var clickMap = _parseEvalMap(
        await controller.evaluateJavascript(source: clickJs),
      );
      if (clickMap?['ok'] != true) {
        // 数字按钮缺失（分页窗口滚动 / 只剩 Next）→ 退而点“下一页”。
        clickMap = _parseEvalMap(
          await controller.evaluateJavascript(source: _clickNextPageJs),
        );
        if (clickMap?['ok'] != true) {
          Log.info("ComixClient", "DOM: no pager control for page $p, stop");
          break;
        }
      }

      // 等 SPA 渲染新页：轮询到首行变化（最多 ~8s）。
      // 🔴 旧实现只等固定 1.2s——站方对章节接口做了加密，SPA 要先解密再渲染，
      //    1.2s 常读到的还是上一页（线上日志实证 `page 4 not effective`），
      //    于是提前 break，章节只采到一页的量。
      String? newFirstHref;
      final waitUntil = DateTime.now().add(const Duration(seconds: 8));
      while (DateTime.now().isBefore(waitUntil)) {
        final verifyMap = _parseEvalMap(
          await controller.evaluateJavascript(source: _pageVerifyJs),
        );
        final fh = verifyMap?['firstHref'] as String?;
        if (fh != null && fh != prevFirstHref) {
          newFirstHref = fh;
          break;
        }
        await Future.delayed(const Duration(milliseconds: 500));
      }
      if (newFirstHref == null) {
        Log.info(
          "ComixClient",
          "DOM: page $p not effective after wait, stopping",
        );
        break;
      }
      prevFirstHref = newFirstHref;

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

  /// 阅读页 DOM fallback：**并行 click seg + MutationObserver 极速采集（首选，实测 105页/2s）**。
  ///
  /// 优先级：
  /// 1. **并行 click 所有 seg + MO 监听 img src** → 2s 收齐全量（2026-10-18 新方案）
  /// 2. React fiber 挖整章页数组 → 字段漂移常返回空（保留作 fallback）
  /// 3. `<img>` DOM 探针轮询 → 虚拟化下只有 3~5 张（最终兜底）
  Future<List<String>> _fetchPagesByDom(String chapterUrl) async {
    final controller = await _worker.ensure();
    await _navigate(controller, chapterUrl);

    // 1) 极速并行采集（首选）：清广告层 + 装 MO + 并行 click 所有 seg
    try {
      final setup = _parseEvalMap(
        await controller.evaluateJavascript(source: _pagesFastCollectSetupJs),
      );
      final totalSegs = (setup?['totalSegs'] as num?)?.toInt() ?? 0;
      if (totalSegs > 0) {
        Log.info("ComixClient", "DOM fastCollect: $totalSegs seg buttons detected");
        final urls = await _fastCollectPages(controller, totalSegs);
        if (urls.length >= (totalSegs * 0.5).toInt() && urls.length >= 3) {
          Log.info("ComixClient", "DOM fastCollect SUCCESS: ${urls.length}/$totalSegs pages in ~2-3s");
          return urls;
        }
        Log.warning("ComixClient", "DOM fastCollect only got ${urls.length}/$totalSegs, falling back");
      } else {
        Log.warning("ComixClient", "DOM: no seg buttons found (SPA not ready?)");
      }
    } catch (e) {
      Log.warning("ComixClient", "DOM fastCollect error: $e");
    }

    // 2) React fiber（fallback，字段漂移常返回空）。
    final viaReact = await _pagesViaReact(controller);
    if (viaReact.length >= 2) {
      Log.info("ComixClient", "DOM: React fiber recovered ${viaReact.length} image(s)");
      return viaReact;
    }

    // 3) `<img>` DOM 探针（最终兜底，虚拟化下通常只有 3~5 张）。
    final deadline = DateTime.now().add(const Duration(seconds: 25));
    var lastCount = -1, stable = 0;
    List<String> best = const [];
    while (DateTime.now().isBefore(deadline)) {
      final snap = _parseEvalMap(await controller.evaluateJavascript(source: _pagesProbeJs));
      if (snap != null && snap['ready'] == true) {
        final urls = (snap['urls'] as List? ?? [])
            .map((u) => u.toString())
            .where((u) => u.isNotEmpty)
            .map((u) => u.startsWith('http') ? u : "$_baseUrl$u")
            .toList();
        if (urls.length > best.length) best = urls;
        if (urls.length == lastCount) { stable++; if (stable >= 3) break; }
        else { stable = 0; lastCount = urls.length; }
      }
      await Future.delayed(const Duration(milliseconds: 800));
    }
    Log.info("ComixClient", "DOM img probe collected ${best.length} image(s)");
    return best;
  }

  /// 轮询 React fiber 挖取阅读页全量图片 URL（见 [_pagesByReactJs]）。
  ///
  /// 站方的章节图片接口是加密的（明文通道抓不到），页数组只在 SPA 解密后
  /// 落到 React 内存；SPA 渲染需要时间，所以轮询到"数量连续 3 次不变"
  /// 再收，避免拿到半成品。
  Future<List<String>> _pagesViaReact(
    InAppWebViewController controller,
  ) async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    var lastCount = -1;
    var stable = 0;
    List<String> best = const [];
    while (DateTime.now().isBefore(deadline)) {
      Map<String, dynamic>? snap;
      try {
        snap = _parseEvalMap(
          await controller.evaluateJavascript(source: _pagesByReactJs),
        );
      } catch (e) {
        Log.warning("ComixClient", "React fiber probe error: $e");
      }
      if (snap != null && snap['ok'] == true) {
        final urls = (snap['urls'] as List? ?? [])
            .map((u) => u.toString())
            .where((u) => u.startsWith('http'))
            .toList();
        if (urls.length > best.length) best = urls;
        if (urls.length == lastCount) {
          stable++;
          if (stable >= 3 && best.length >= 2) break;
        } else {
          stable = 0;
          lastCount = urls.length;
        }
      }
      await Future.delayed(const Duration(milliseconds: 700));
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

  /// 诊断：明文通道没命中时，把钩子状态、各 sink 调用计数、未识别的原始
  /// 载荷头 dump 出来，判定站方解密到底走的是哪个落点（P43 排查用）。
  Future<void> _logHookDiagnostics(
    InAppWebViewController controller,
    String what,
  ) async {
    try {
      final raw = await controller.evaluateJavascript(
        source: r"""
(function(){
  return JSON.stringify({
    installed: !!window.__comixHookInstalled,
    parsePatched: String(JSON.parse).indexOf('native code') < 0,
    sinks: window.__comixSinks || {},
    payloads: (window.__comixPayloads || []).length,
    raw: (window.__comixRaw || []).slice(-6)
  });
})()
""",
      );
      Log.info("ComixClient", "hook diagnostics ($what): ${_parseEvalMap(raw)}");
    } catch (e) {
      Log.warning("ComixClient", "hook diagnostics error: $e");
    }
  }

  Future<void> _navigate(InAppWebViewController controller, String url) async {
    Log.info("ComixClient", "navigate → $url");
    try {
      await controller.stopLoading();
    } catch (_) {}
    // P-DL9: loadUrl 可能挂起 → 15s timeout 保护
    await controller
        .loadUrl(urlRequest: URLRequest(url: WebUri(url)))
        .timeout(const Duration(seconds: 15));
    await _throwIfOnChallenge(controller, url);
  }

  /// 导航后快速识别「落在 WAF 挑战页」。
  ///
  /// 🔴 2026-10-12 (P45)：被封出口 IP 上，**任何**导航都被服务端直接重定向到
  /// `/@waf/challenge?return=...`（HTTP 200、9.4KB 滑块页，实测导航后 < 0.7s
  /// 就位）。旧代码在这条路上要白等 fiber 20s + `<img>` 探针 25s（章节翻页
  /// 更是 100s 预算），P38 的「空结果重建 worker 再来一遍」再翻倍 ⇒ 用户看到的
  /// 「卡在获取图片列表 30~60s」。这里在全部 6 条采集路径的共同咽喉
  /// [_navigate] 采两个样本（约 700ms / 1600ms）：
  /// - 命中挑战 → 立刻抛 `COMIX_IP_BLOCKED`（上层**不再降级、不重启重试**，
  ///   直接给用户「请切换节点」的可操作提示）；
  /// - 正文已渲染出 >20KB ⇒ 真页，提前返回；
  /// - 其余（SPA bootstrap 小壳）⇒ 交给各路径既有的轮询，不拖慢正常流程。
  Future<void> _throwIfOnChallenge(
    InAppWebViewController controller,
    String url,
  ) async {
    // P-DL9: eval timeout 保护 — CF Turnstile JS 会让 eval 永远不返回
    Future<String?> safeEval(String js) async {
      try {
        return unwrapEvalString(
          await controller.evaluateJavascript(source: js)
              .timeout(const Duration(seconds: 5)),
        );
      } catch (_) {
        return null;
      }
    }

    for (var sample = 0; sample < 2; sample++) {
      await Future.delayed(Duration(milliseconds: sample == 0 ? 700 : 900));
      final href = await safeEval('location.href');
      final html = await safeEval(
        "(document.documentElement && document.documentElement.outerHTML) || ''",
      );
      if (href == null && html == null) {
        Log.warning(
          "ComixClient",
          "navigate → both evals timed out (sample=$sample, $url) → blocked",
        );
        throw "COMIX_IP_BLOCKED: eval timeout on $url";
      }
      final onChallenge =
          (href ?? '').contains('/@waf/challenge') ||
          (html != null && looksLikeChallengePage(html));
      if (onChallenge) {
        Log.warning(
          "ComixClient",
          "navigate → WAF challenge for $url (href=$href, "
          "${html?.length} chars); exit IP banned, failing fast with "
          "COMIX_IP_BLOCKED instead of polling 20~100s",
        );
        throw "COMIX_IP_BLOCKED: WAF challenge page after navigating to $url";
      }
      if ((html?.length ?? 0) > 20000) return;
    }
  }

  /// P38 的「空结果重建 worker 重试」绝不能用在 IP 被封上 —— 被封时重试
  /// 只是把等待翻倍。统一用本判据让 `COMIX_IP_BLOCKED` 一路抛到 JS 源，
  /// 由 `comix_to.js` 翻成中英双语切节点提示。
  static bool _isIpBlocked(Object error) =>
      error.toString().contains('COMIX_IP_BLOCKED');

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
        // P-DL9: per-call 5s timeout，防止单个 eval 挂住整个 loop
        final raw = await controller
            .evaluateJavascript(source: js)
            .timeout(const Duration(seconds: 5));
        final snap = _parseEvalMap(raw);
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

  // ---------------------------------------------------------------------------
  // P-DL9 (2026-10-17)：手动 Cloudflare 验证
  // ---------------------------------------------------------------------------
  // comix.to 的 Turnstile 现在必须真人点击 checkbox，任何自动化浏览器
  // （WebView2 / nodriver headless / headful）都过不了。唯一的办法是
  // 在可见 WebView 里让用户手动验证，然后 cf_clearance cookie 自动被
  // 同 userDataFolder 的 headless worker 共享。
  //
  // 范围：一次验证 = 搜索 + 详情页 + 下载（三者共享 cookie store）。
  // cookie 持久化在 WebView2 的 userDataFolder，重启 App 后仍有效
  // （直到 Cloudflare 过期 cf_clearance）。
  // ---------------------------------------------------------------------------

  /// 手动 Cloudflare 验证总入口。
  ///
  /// 首选 **内置 CfT 窗口**（就是采集用的那个真实 Chrome 窗口）：用户在那个
  /// 窗口里过一次 Turnstile，cookie 直接落在 CfT 的 jar 里，采集侧立刻可用。
  /// 不再用 WebView2 中转 —— 2026-10-19 实测那条路会卡在
  /// `opening AppWebview...` 之后再无回调（onLoadStop 不触发）。
  ///
  /// 返回 true = 已拿到 cf_clearance；false = 超时 / 用户没完成 / 无 CfT。
  Future<bool> verifyCloudflare({
    String url = "https://comix.to/",
    Duration timeout = const Duration(minutes: 5),
  }) async {
    // 并发 guard —— 如果已经在验证，直接 await 已有的 future
    if (_verifyGuard != null) {
      Log.info("ComixClient", "verifyCloudflare: already in progress, awaiting...");
      return _verifyGuard!.future;
    }
    final guard = Completer<bool>();
    _verifyGuard = guard;

    try {
      final hasCft = ComixBrowserManager.instance.resolveChrome() != null;
      bool ok;
      if (hasCft) {
        ok = await _verifyViaCfT(url: url, timeout: timeout);
        if (!ok) {
          Log.warning(
            "ComixClient",
            "verifyCloudflare: CfT path got no cf_clearance (timeout / not solved)",
          );
        }
      } else {
        Log.warning(
          "ComixClient",
          "verifyCloudflare: no bundled CfT → AppWebview fallback",
        );
        ok = await _verifyViaAppWebview(url: url, timeout: timeout);
      }
      if (!guard.isCompleted) guard.complete(ok);
      return ok;
    } catch (e, s) {
      Log.error("ComixClient", "verifyCloudflare failed: $e\n$s");
      if (!guard.isCompleted) guard.complete(false);
      return false;
    } finally {
      if (_verifyGuard == guard) _verifyGuard = null;
    }
  }

  /// 在**内置 CfT 窗口**里完成人机验证（真实 Chrome，用户看得见、点得到）。
  ///
  /// 步骤（顺序不可调换）：
  /// 1. 清 comix cookie —— 503 Third-party 是**会话级标记**，钉在 comix 自己的
  ///    cookie 上，删掉才会退回 CF 挑战（A07c 实验 E）；
  /// 2. `Page.navigate` 硬开首页（首页是唯一允许的文档导航；这时的 403/503
  ///    就是 CF 挑战页，用户可以过）；
  /// 3. `Page.bringToFront` 把浏览器窗口提到最前，并 toast 提示；
  /// 4. 每 2s 读一次 CfT 的 cookie jar，出现 `cf_clearance` 即成功 → 持久化。
  Future<bool> _verifyViaCfT({
    required String url,
    required Duration timeout,
  }) async {
    final cdp = ComixCDPWorker.instance;
    if (!await cdp.isAvailable()) {
      Log.warning("ComixClient", "verifyViaCfT: no CDP / CfT available");
      return false;
    }
    Log.info("ComixClient", "verifyViaCfT: hard-navigate homepage (CF challenge expected)");
    // 🔴 2026-10-19 二次取证：**不再先清 cookie**。清完照样 503，却要额外发一次
    //    文档导航（清 cookie 会连带删掉 __cf_bm / session），反而加重判定。
    // 🔴 死锁修复：forceHome 现在返回 bool —— 若 CDP 已死或首页仍 503（墙没退），
    //    继续在死 / 封页面上轮询 cf_clearance 毫无意义（用户根本过不了 CF，
    //    每个 comixCookies() 还空等），直接放弃，避免对话框卡死数分钟。
    final homeOk = await cdp.forceHome();
    if (!homeOk) {
      Log.warning(
        "ComixClient",
        "verifyViaCfT: forceHome 失败（CDP 死 / 仍 503）—— 放弃验证",
      );
      try {
        App.rootContext.showMessage(
          message: cdp.blockedThirdParty
              ? 'comix.to 仍判定为第三方应用（503）。'
                  '若你平时用本机 Chrome 能正常打开 comix.to，请先用它浏览一页，'
                  '再重启本 App（会自动同步 Chrome 的登录态后再试）。'
              : '内置浏览器不可用，无法完成验证。',
        );
      } catch (_) {}
      return false;
    }
    await cdp.bringToFront();
    try {
      App.rootContext.showMessage(
        message: '请在弹出的内置浏览器窗口中完成人机验证（Cloudflare）',
      );
    } catch (_) {}

    final deadline = DateTime.now().add(timeout);
    var i = 0;
    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(seconds: 2));
      i++;
      final cookies = await cdp.comixCookies();
      // 轮询期间若页面被重定向到 503（墙突然又起）→ 立刻放弃，避免死循环。
      if (cdp.blockedThirdParty) {
        Log.warning("ComixClient", "verifyViaCfT: 轮询中页面翻回 503 → 放弃");
        return false;
      }
      final cf = cookies['cf_clearance'];
      if (cf != null && cf.isNotEmpty) {
        Log.info("ComixClient", "verifyViaCfT: ✅ cf_clearance len=${cf.length}");
        await _saveCfCookie(cf);
        JsEngine.reloadCfClearance();
        // 🔴 取到 cf_clearance 后，**确认 comix 墙是否也退了**：墙退（首页能正常
        //    加载）才是真成功；墙没退（首页仍 503）则如实返回 false + 提示，
        //    不再伪造「验证成功」误导用户（用户原话：「验证 CF 成功却仍 503」）。
        if (cdp.blockedThirdParty) {
          Log.warning(
            "ComixClient",
            "verifyViaCfT: CF 已过但 comix 自家 503 墙仍在 —— 如实返回失败",
          );
          try {
            App.rootContext.showMessage(
              message: 'Cloudflare 已通过，但 comix.to 仍封锁本机（503）。'
                  '请先用本机 Chrome 正常打开 comix.to 浏览一页，再重启本 App 同步登录态。',
            );
          } catch (_) {}
          return false;
        }
        // 墙已退：清掉 503 熔断，标记本次会话可用。
        cdp.clearBreaker();
        return true;
      }
      if (i % 5 == 0) {
        Log.info("ComixClient", "verifyViaCfT: waiting for user... (${i * 2}s)");
      }
    }
    Log.info("ComixClient", "verifyViaCfT: TIMEOUT — no cf_clearance");
    return false;
  }

  /// 【历史方案 / 兜底】打开可见 AppWebview 让用户手动过 CF Turnstile。
  ///
  /// ⚠️ 2026-10-19 实证：本机点「验证 CF」后日志只到 `opening AppWebview...`，
  /// 页面能建出来（UA 探针写入成功）但 **`onLoadStop` 永不触发**，于是
  /// 5 分钟超时定时器根本没启动 → 外层的 `_verifyGuard` 永不释放，
  /// 后续每次点击都只打印 `already in progress, awaiting...`（死锁）。
  /// 现在只在**找不到内置 CfT** 时才走这里，并且超时改为在方法级兜底。
  Future<bool> _verifyViaAppWebview({
    String url = "https://comix.to/",
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final guard = Completer<bool>();

    try {
      // 🔴 必须 dispose 所有 headless WebView 才能打开可见 AppWebview！
      // WebView2 不允许同一进程内 HeadlessInAppWebView 和 InAppWebview 并存
      // （之前 P-DL9 简化代码移除了 dispose，导致 AppWebview 静默失败——
      //  用户点"验证 CF"按钮后什么都没发生！）。
      // dispose 后不立刻重建（避免旧卡死）—— 下次请求 ensure() 会自动重建。
      Log.info("ComixClient", "verifyCloudflare: disposing headless workers first...");
      try { await _ComixImageWorker.instance.disposeAll(); } catch(e) { Log.warning("ComixClient", "disposeAll failed: $e"); }
      try { await _worker.restart(); } catch(e) { Log.warning("ComixClient", "worker restart failed: $e"); }
      try { if (_worker._environment != null) { await _worker._environment!.dispose(); _worker._environment = null; } } catch(e) {}
      // 额外释放 AppWebview 可能残留的 environment
      try { if (AppWebview.webViewEnvironment != null) { await AppWebview.webViewEnvironment!.dispose(); AppWebview.webViewEnvironment = null; } } catch(e) {}
      await Future.delayed(const Duration(milliseconds: 800));
      Log.info("ComixClient", "verifyCloudflare: workers disposed, opening AppWebview...");

      // 不再用 showDialog（PopScope + barrierDismissible: false 会死锁）。
      // 直接 push MaterialPageRoute — 任何页面都能弹出，不卡 UI。
      final completer = Completer<bool>();
      var verified = false;

      print("[CF] verifyCloudflare: opening AppWebview with Chrome UA for $url");

      // 🔴 showGeneralDialog 完全不参与 Hero 动画！
      // MaterialPageRoute / PageRouteBuilder 都会触发 Flutter Hero 检查，
      // 如果主页面上 cover533825623 等 tag 已重复 → nav.push 直接抛异常静默失败。
      // showGeneralDialog 走 OverlayEntry，完全绕过 Hero — CF 验证页秒弹！
      // showGeneralDialog 返回 void（不是 OverlayEntry）。
      // 关闭方式：barrierDismissible=true 让用户点白色背景关闭；
      // 程序关闭用 Navigator.pop（Flutter dialog 内部在 root navigator 注册了 route）
      showGeneralDialog(
          context: App.rootContext,
          barrierColor: Colors.white,
          barrierDismissible: true,
          barrierLabel: "Cloudflare Verification",
          transitionDuration: const Duration(milliseconds: 200),
          pageBuilder: (context, animation, secondaryAnimation) => AppWebview(
            initialUrl: url,
            singlePage: true,
            // 轮询检测 cf_clearance cookie — 用户手动过 Turnstile 后自动触发
            onLoadStop: (controller) async {
              int checks = 0;
              Timer? timer;
              timer = Timer.periodic(const Duration(seconds: 2), (_) async {
                checks++;
                if (checks > 150) { timer?.cancel(); return; } // 最多等 5 分钟
                try {
                  final cookies = await controller.getCookies(url);
                  final hasCf =
                      cookies?.any((c) => c.name.toLowerCase() == 'cf_clearance') ?? false;
                  if (hasCf) {
                    timer?.cancel();
                    final cf = cookies!.firstWhere(
                      (c) => c.name.toLowerCase() == 'cf_clearance',
                    );
                    Log.info(
                      "ComixClient",
                      "verifyCloudflare: ✅ cf_clearance detected (len=${cf.value.length})",
                    );
                    await _saveCfCookie(cf.value);
                    JsEngine.reloadCfClearance();
                    // 同步注入内置 CfT，让采集侧复用这次验证会话。
                    try {
                      await ComixCDPWorker.instance
                          .setCookie(name: 'cf_clearance', value: cf.value);
                    } catch (_) {}
                    verified = true;
                    if (!completer.isCompleted) completer.complete(true);
                    // 自动关闭验证页（showGeneralDialog 走 root navigator route）
                    Future.delayed(const Duration(milliseconds: 500), () {
                      try { Navigator.of(App.rootContext).pop(); } catch(_) {}
                    });
                  } else if (checks % 10 == 0) {
                    Log.info(
                      "ComixClient",
                      "verifyCloudflare: waiting for Turnstile... ($checks checks)",
                    );
                  }
                } catch (e) {
                  Log.warning("ComixClient", "cookie check error: $e");
                }
              });
              // 超时取消 timer
              Future.delayed(timeout).then((_) {
                timer?.cancel();
                if (!completer.isCompleted) completer.complete(verified);
              });
            },
            ),
          );

      // 🔴 方法级超时兜底：旧实现把 5 分钟定时器放在 `onLoadStop` 里，
      //    页面若根本不触发 load stop（本机实测如此），就永远不超时 → 死锁。
      final result = await completer.future.timeout(
        timeout + const Duration(seconds: 15),
        onTimeout: () {
          Log.warning(
            "ComixClient",
            "verifyViaAppWebview: hard timeout, no callback from WebView",
          );
          return verified;
        },
      );

      // 清理 AppWebview 的 environment（让下次重建不冲突）
      try {
        if (AppWebview.webViewEnvironment != null) {
          await AppWebview.webViewEnvironment!.dispose();
          AppWebview.webViewEnvironment = null;
        }
      } catch (_) {}

      if (result) {
        Log.info("ComixClient", "verifyCloudflare: SUCCESS — cookie saved");
      } else {
        Log.info("ComixClient", "verifyCloudflare: TIMEOUT — no cf_clearance detected");
      }

      guard.complete(result);
      return result;
    } catch (e, s) {
      Log.error("ComixClient", "verifyCloudflare failed: $e\n$s");
      guard.complete(false);
      return false;
    } finally {
      if (_verifyGuard == guard) _verifyGuard = null;
    }
  }

  // P-DL9: 把 AppWebview 里拿到的 cf_clearance 存到 cf_cookie.json
  static Future<void> _saveCfCookie(String cfClearance) async {
    try {
      final cookieFile = File("${App.dataPath}\\cf_cookie.json");
      final data = {
        "cf_clearance": cfClearance,
        "domain": ".comix.to",
        "savedAt": DateTime.now().toIso8601String(),
      };
      await cookieFile.writeAsString(jsonEncode(data));
      Log.info("ComixClient", "✅ cf_cookie.json saved (len=${cfClearance.length})");
    } catch (e) {
      Log.warning("ComixClient", "_saveCfCookie failed: $e");
    }
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

  /// 强制释放当前 WebView，下次 `ensure()` 会重建全新会话。
  /// 用于"headless worker 停在空白页/坏状态导致永久空结果"时的自愈重试
  /// （见 `fetchChapters` 的空结果重建分支）。
  Future<void> restart() async {
    try {
      await _webview?.dispose();
    } catch (_) {}
    _webview = null;
  }

  // ---------------------------------------------------------------------------
  // P-DL9: cf_clearance cookie 注入
  // ---------------------------------------------------------------------------

  static Future<void> _injectCfClearance() async {
    Log.info("ComixWorker", "_injectCfClearance() called, App.dataPath=${App.dataPath}");
    try {
      final cookieFile = File("${App.dataPath}\\cf_cookie.json");
      Log.info("ComixWorker", "cookieFile path=${cookieFile.path}, exists=${cookieFile.existsSync()}");
      if (!cookieFile.existsSync()) {
        Log.info("ComixWorker", "cf_cookie.json not found — skip WebView cookie injection (Dio path handles it)");
        return;
      }

      final content = cookieFile.readAsStringSync();
      final Map<String, dynamic> data = jsonDecode(content);
      final cfValue = data["cf_clearance"] as String?;
      Log.info("ComixWorker", "cf_clearance value present: ${cfValue != null && cfValue.isNotEmpty}, len=${cfValue?.length ?? 0}");
      if (cfValue == null || cfValue.isEmpty) {
        Log.info("ComixWorker", "cf_clearance empty — skip");
        return;
      }

      // flutter_inappwebview 的 CookieManager.setCookie 接受 Cookie 类
      final uri = WebUri("https://comix.to");
      Log.info("ComixWorker", "CookieManager.instance().setCookie() for comix.to...");
      await CookieManager.instance().setCookie(
        url: uri,
        name: "cf_clearance",
        value: cfValue,
        domain: ".comix.to",
        path: "/",
        isHttpOnly: true,
        isSecure: true,
      );
      Log.info("ComixWorker", "CookieManager.setCookie cf_clearance done");

      // 同时注入 cf_chl_rc_ni（如果有的话）
      final all = data["all_cookies"] as Map<String, dynamic>?;
      if (all != null) {
        for (final entry in all.entries) {
          if (entry.key == "cf_clearance") continue;
          Log.info("ComixWorker", "injecting extra cookie ${entry.key}...");
          await CookieManager.instance().setCookie(
            url: uri,
            name: entry.key,
            value: entry.value.toString(),
            domain: ".comix.to",
            path: "/",
          );
        }
      }

      Log.info("ComixWorker", "✅ cf_clearance cookie injected into WebView2 (len=${cfValue.length})");
    } catch (e, s) {
      Log.warning("ComixWorker", "_injectCfClearance failed: $e\n$s");
    }
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
        // P-DL9 (2026-10-18)：Chrome 伪装全方案 v2！
        // 核心问题：WebView2 runtime 会在导航请求里自动追加 sec-ch-ua: "Edg";v=xxx
        // 这些 HTTP headers 在 JS 之上，JS 拦截不了 — comix.to 后端看到 Edg 特征
        // 就直接返回 "Third-party apps are not supported" 页面，SPA 根本不加载！
        // 所以：① initialUrlRequest 带假 Chrome sec-ch-ua headers
        //      ② 后续所有 controller.loadUrl(urlRequest: ...) 也手动带 headers
        //      ③ AT_DOCUMENT_START JS 反检测（SPA 加载后第二层防御）
        initialSettings: InAppWebViewSettings(
          isInspectable: true,
          userAgent: _realChromeUA,
        ),
        // document-start 注入反检测 + API 截获钩子
        initialUserScripts: UnmodifiableListView<UserScript>([
          UserScript(
            source: _antiDetectJs,
            injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          ),
          UserScript(
            source: _captureHookJs,
            injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          ),
        ]),
        // 初始导航也带假 Chrome headers（覆盖 WebView2 默认 Edg headers）
        initialUrlRequest: URLRequest(
          url: WebUri("about:blank"),
          headers: chromeHeaders,
        ),
      );
      _webview = webview;
      await webview.run();
      Log.info("ComixWorker", "headless webview started");

      // P-DL9 (2026-10-17)：注入 cf_clearance cookie！
      // 从 App.dataPath 下的 cf_cookie.json 读取（由 grab_cookie.py 或手动
      // 验证流程写入）。绕过 WebView2 TLS 指纹被 CF 识别的问题 — 直接
      // 把 Playwright 过验证拿到的 cookie 注入到 WebView2 的 cookie store。
      await _injectCfClearance();
    });
    return _webview!.webViewController!;
  }

  // ---------------------------------------------------------------------------
  // P-DL9 (2026-10-18)：Chrome 伪装常量 + 反检测 JS
  // ---------------------------------------------------------------------------

  /// 真实 Chrome 155 Windows UA — 不含 Edg / WebView 特征。
  /// P-DL9c (2026-10-18)：从 131 更新到 155，匹配用户当前 Chrome 版本
  static const _realChromeUA =
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/155.0.0.0 Safari/537.36";

  /// AT_DOCUMENT_START 注入的反检测脚本。
  ///
  /// comix.to SPA 反爬 JS 会检测以下 WebView2 特征（实测触发
  /// "Third-party apps are not supported" 弹窗）：
  ///
  /// ① navigator.userAgentData.brands 含 "Edg" / "WebView2"
  ///    → Object.defineProperty 覆盖 brands 数组
  /// ② navigator.webdriver === true
  ///    → Object.defineProperty 强制 false
  /// ③ window.chrome 对象不完整
  ///    → 创建带 runtime / cookies / storage 属性的假 chrome 对象
  /// ④ sec-ch-ua / sec-ch-ua-platform Client Hints 带 Edg 特征
  ///    → 通过 override navigator.userAgentData 的 toJSON
  /// ⑤ WebGL renderer 含 "ANGLE" / "DirectComposition" 标识
  ///    → 在 getParameter 里做二次修改（可选，WebGL 是异步的先跳过）
  ///
  /// ⚠️ 此脚本必须在 AT_DOCUMENT_START 执行，比 comix.to SPA 的反爬 JS 更早！
  static const _antiDetectJs = r"""
(function(){
  if (window.__comixAntiDetectInstalled) return;
  window.__comixAntiDetectInstalled = true;

  // ① navigator.userAgent — 已通过 initialSettings.userAgent 设置，
  //    但还要确保 navigator.userAgent 同步覆盖（部分 WebView2 版本会返回原值）
  try {
    Object.defineProperty(navigator, 'userAgent', {
      get: function(){
        return 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/155.0.0.0 Safari/537.36';
      },
      configurable: true
    });
  } catch(e) {}

  // ② navigator.webdriver — Chrome 131+ 这个值是 false，WebView2 可能是 true
  try {
    Object.defineProperty(navigator, 'webdriver', {
      get: function(){ return false; },
      configurable: true
    });
  } catch(e) {}

  // ③ window.chrome — WebView2 缺少 chrome.runtime / chrome.cookies 等
  try {
    if (!window.chrome) {
      window.chrome = {};
    }
    if (!window.chrome.runtime) {
      window.chrome.runtime = {
        connect: function(){},
        sendMessage: function(){},
        onConnect: { addListener: function(){} },
        onMessage: { addListener: function(){} },
        id: undefined
      };
    }
    if (!window.chrome.cookies) {
      window.chrome.cookies = {
        get: function(details, callback){ if(callback) callback(null); },
        getAll: function(details, callback){ if(callback) callback([]); },
        set: function(details, callback){ if(callback) callback(null); },
        remove: function(details, callback){ if(callback) callback(true); }
      };
    }
    // Chrome devtools detector: 伪造 __REACT_DEVTOOLS_GLOBAL_HOOK__ 不存在即可
  } catch(e) {}

  // ④ navigator.userAgentData.brands — WebView2 这里会带 "Edg" / "WebView2"
  try {
    var fakeBrands = [
      { brand: 'Chromium', version: '131' },
      { brand: 'Not_A Brand', version: '24' },
      { brand: 'Google Chrome', version: '131' }
    ];
    var fakeHighEntropy = {
      brands: fakeBrands,
      mobile: false,
      platform: 'Windows'
    };
    if (navigator.userAgentData) {
      Object.defineProperty(navigator.userAgentData, 'brands', {
        get: function(){ return fakeBrands; },
        configurable: true
      });
      Object.defineProperty(navigator.userAgentData, 'mobile', {
        get: function(){ return false; },
        configurable: true
      });
      Object.defineProperty(navigator.userAgentData, 'platform', {
        get: function(){ return 'Windows'; },
        configurable: true
      });
      // 覆盖 toJSON()（有的反爬用这个）
      navigator.userAgentData.toJSON = function(){
        return fakeHighEntropy;
      };
      // getHighEntropyValues
      navigator.userAgentData.getHighEntropyValues = function(hints){
        return Promise.resolve(fakeHighEntropy);
      };
    }
  } catch(e) {}

  // ⑤ fetch / XHR 的 Client Hints — 由 _captureHookJs 的 fetch/XHR 包装统一处理
  //    （在 _captureHookJs 里去掉 sec-ch-ua / sec-ch-ua-platform 等 headers）

  window.__comixAntiDetectReady = true;
})();
""";

  /// document-start 注入的截获钩子：包装 fetch / XMLHttpRequest，
  /// 把所有 /api/ 响应记录到 window.__comixApiLog 供 Dart 侧轮询。
  /// 同时过滤 sec-ch-ua* Client Hints headers（WebView2 暴露 WebView 特征）
  static const _captureHookJs = r"""
(function(){
  if (window.__comixHookInstalled) return;
  window.__comixHookInstalled = true;
  window.__comixApiLog = [];
  window.__comixPayloads = [];
  window.__comixRaw = [];
  window.__comixSinks = {jsonParse: 0, atob: 0, textDecode: 0, evalRun: 0};
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
      // P-DL9 (2026-10-18)：过滤 sec-ch-ua* Client Hints（WebView2 暴露 WebView 特征）
      try {
        if (args[1] && args[1].headers) {
          var _fh = args[1].headers;
          if (_fh instanceof Headers) {
            var _fh2 = new Headers();
            _fh.forEach(function(v, k){ var lk = k.toLowerCase(); if (lk.indexOf('sec-ch-ua') !== 0) _fh2.set(k, v); });
            args[1].headers = _fh2;
          } else if (typeof _fh === 'object') {
            var _fh3 = {};
            for (var _fk in _fh) { if (_fk.toLowerCase().indexOf('sec-ch-ua') !== 0) _fh3[_fk] = _fh[_fk]; }
            args[1].headers = _fh3;
          }
        }
      } catch(_) {}
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
  // ---- 明文载荷通道（多点截获） ----
  // 站方对部分 API 响应做了加密（原始 body 形如 {"e":"..."}，实测高熵密文，
  // 非 base64 明文），只有 SPA 自己的解密逻辑能还原。解密模块被 VMP 混淆、
  // 模块作用域，注入脚本拿不到 ⇒ 只能"借站方运行时"：把明文落点全包住。
  // 已知/可能的落点：JSON.parse（BallonsTranslator 用这个）、atob 输出、
  // TextDecoder.decode 输出、eval 源码。凡产出 pages/items/chapters 形状的
  // 一律留档到 window.__comixPayloads；形状不认识的原样留 __comixRaw 供诊断。
  var nativeParse = JSON.parse;
  function ingest(sink, text) {
    try {
      if (typeof text !== 'string' || text.length < 16) return;
      if (text.indexOf('"pages"') < 0 && text.indexOf('"items"') < 0 &&
          text.indexOf('"chapters"') < 0 && text.indexOf('"result"') < 0) return;
      var v = null;
      try { v = nativeParse(text); } catch (e) {
        var a = text.indexOf('{'), b = text.lastIndexOf('}');
        if (a >= 0 && b > a) {
          try { v = nativeParse(text.slice(a, b + 1)); } catch (e2) {}
        }
      }
      if (!v || typeof v !== 'object' || Array.isArray(v)) {
        window.__comixRaw.push({sink: sink, tag: 'none', head: text.slice(0, 240)});
      } else {
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
          window.__comixPayloads.push({tag: tag, payload: v, via: sink});
        } else {
          window.__comixRaw.push({sink: sink, tag: 'unknown', head: text.slice(0, 240)});
        }
      }
      if (window.__comixPayloads.length > 16) window.__comixPayloads.shift();
      if (window.__comixRaw.length > 12) window.__comixRaw.shift();
    } catch (e) {}
  }
  JSON.parse = function(text, reviver) {
    var v = nativeParse(text, reviver);
    try {
      window.__comixSinks.jsonParse++;
      if (typeof text === 'string') ingest('json.parse', text);
    } catch (e) {}
    return v;
  };
  try {
    var oAtob = window.atob;
    if (oAtob) {
      window.atob = function(s) {
        var r = oAtob(s);
        try { window.__comixSinks.atob++; ingest('atob', r); } catch (e) {}
        return r;
      };
    }
  } catch (e) {}
  try {
    if (window.TextDecoder && TextDecoder.prototype && TextDecoder.prototype.decode) {
      var oDecode = TextDecoder.prototype.decode;
      TextDecoder.prototype.decode = function() {
        var r = oDecode.apply(this, arguments);
        try { window.__comixSinks.textDecode++; ingest('TextDecoder', r); } catch (e) {}
        return r;
      };
    }
  } catch (e) {}
  try {
    var oEval = window.eval;
    if (oEval) {
      window.eval = function(src) {
        try {
          window.__comixSinks.evalRun++;
          if (typeof src === 'string') ingest('eval', src);
        } catch (e) {}
        return oEval.apply(this, arguments);
      };
    }
  } catch (e) {}
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

  // P-DL9: dispose 所有 ImageLane（verifyCloudflare 需要释放 WebView2 environment lock）
  Future<void> disposeAll() async {
    Log.info("ComixImageWorker", "disposeAll() — disposing ${_lanes.length} lanes...");
    for (final lane in _lanes) {
      try {
        await lane.reset();
      } catch (e) {
        Log.warning("ComixImageWorker", "lane reset failed: $e");
      }
    }
    Log.info("ComixImageWorker", "disposeAll() done");
  }

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

/// HTML 是否还在 CF / 挑战页**或封禁页**上（用于决定要不要再等一轮，
/// 以及不要把封禁页当正常内容返回）。
///
/// 🔴 P39：之前只认「挑战中」关键字，漏了 CF 的**硬封禁页**
/// （`Attention Required! | Cloudflare` / `cf-error-details` /
/// `blocked_why_headline`）——于是 `fetchPageHtml` 把 403 封禁页当正常 HTML
/// 返回，上层拿 `no initial-data in page` 这种误导性报错。
bool looksLikeChallengePage(String html) {
  final lower = html.toLowerCase();
  return lower.contains('cf-challenge') ||
      // 🔴 2026-10-12 (P45)：**不能**只认 `challenge-platform` —— CF 的 jsd
      // 探针（`/cdn-cgi/challenge-platform/scripts/jsd/main.js`）**全站注入**，
      // 正常 SSR 页（实测 27,513 字符真页）也含此串 ⇒ 会把好页面误判成挑战页。
      // 真·CF 托管挑战走 `/cdn-cgi/challenge-platform/h/...`，用带 `/h/` 的形式。
      lower.contains('challenge-platform/h/') ||
      lower.contains('just a moment') ||
      lower.contains('__cf_chl_opt') ||
      lower.contains('cf-browser-verification') ||
      lower.contains('checking your browser') ||
      lower.contains('__gatekeeper_challenge') ||
      // 🔴 2026-10-12 (P45)：comix 自家 WAF 挑战页（非 CF 标准页）——
      // HTTP **200**、`<title>Security check</title>`、9.4KB 滑块页，
      // 导航落到 `/@waf/challenge?return=...`。被封出口 IP（随时间漂移：
      // 美国/印度 → 法国/澳大利亚/香港Y01 先后被封）任何导航都落这里。
      lower.contains('@waf/challenge') ||
      lower.contains('<title>security check') ||
      // 硬封禁页（403 / error 1020）：
      lower.contains('attention required') ||
      lower.contains('cf-error-details') ||
      lower.contains('blocked_why_headline') ||
      lower.contains('you have been blocked') ||
      lower.contains('error 1020');
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
    // 代理透传（P41 修订）：给共享 WebView2 传与系统/App 设置等价的
    // --proxy-server，使离屏 WebView 与 dio 走向一致。P39 曾在此把 comix
    // 全域加入 --proxy-bypass-list 强制直连，但 P41 实测家宽 IP 也已被
    // Cloudflare 封、港日等代理节点可用（34 节点逐个实测 31 个 200），
    // kDirectProxyHostSuffixes 默认已清空；白名单非空时仍拼 bypass，
    // 为空则只保留 <local>。代理解析不到（direct/无代理）时不加参数。
    String? extraArgs;
    try {
      final proxy = await getProxy();
      if (proxy != null && proxy.isNotEmpty) {
        final server = proxy.contains('://') ? proxy : 'http://$proxy';
        final suffixRules = buildProxyBypassList();
        final bypass = suffixRules.isEmpty
            ? '<local>'
            : '$suffixRules;<local>';
        extraArgs =
            '--proxy-server=$server --proxy-bypass-list=$bypass';
        Log.info("ComixClient", "webview proxy: $server bypass=$bypass");
      }
    } catch (e) {
      Log.warning("ComixClient", "webview proxy args failed: $e");
    }

    // P-DL9 (2026-10-18)：关键！禁用 WebView2 自动追加的 Client Hints headers
    // (sec-ch-ua: "Edg";v=xxx / sec-ch-ua-platform / sec-ch-ua-mobile 等)
    // comix.to 后端看到这些 Edg 特征 → 直接返回 "Third-party apps are not supported"
    // Chrome flag: --disable-features=SecCHUserAgent 禁用 UA Client Hints
    extraArgs = '${extraArgs ?? ''}--disable-features=SecCHUserAgent,EnableClientHintsUserAgentHeaders';
    Log.info("ComixClient", "webview extraBrowserArgs: $extraArgs");

    _sharedWebViewEnvironment ??= await WebViewEnvironment.create(
      settings: WebViewEnvironmentSettings(
        userDataFolder: "${App.dataPath}\\webview",
        additionalBrowserArguments: extraArgs,
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

// ============================================================================
// P-DL9 (2026-10-18)：Chrome CDP 客户端 — 替代 headless WebView2
// ============================================================================

/// HttpOverrides 让所有 HttpClient 跳过环境变量代理（HTTP_PROXY），
/// 直接连接目标主机。用于 CDP localhost 请求（不能走 Clash）。
class _DirectHttpOverrides extends HttpOverrides {
  static final instance = _DirectHttpOverrides();
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)..findProxy = (_) => 'DIRECT';
  }
}

class ComixCDPWorker {
  static const _cdpPort = 9222;
  static const _cdpHost = 'localhost';

  WebSocket? _ws;
  int _nextId = 0;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  String? _pageWsUrl;

  /// 上一次 navigate 结束时页面是否是 comix 的 Third-party 拦截页。
  ///
  /// 2026-10-19 二次取证修正（推翻上一轮的「cookie 会话标记」结论）：
  ///   - 全新 profile + 只导航一次首页 → 立刻 503（cookie 不是变量）；
  ///   - 换代理出口 → 仍 503（IP 不是唯一变量）；
  ///   - 连 `Sec-CH-UA` 一起伪装成正式版 Chrome → 仍 503（品牌不是变量）；
  ///   - 16:53:47 单次导航成功，16:54:29 起**连发 4 次**文档导航后全站 503。
  /// 唯一能复现的规律是「短时间多次文档导航 → 进 503」。所以对策是
  /// **少发请求 + 命中即熔断**，而不是清 cookie 后反复重试（那只会延长封禁）。
  bool blockedThirdParty = false;

  /// 熔断截止时间：命中 Third-party 后这段时间内不再发任何 comix 请求。
  DateTime? _blockedUntil;

  /// 上一次**首页硬导航**的时间，用于限速（避免重载风暴触发 comix 的判定）。
  DateTime? _lastHomeNavAt;

  static final ComixCDPWorker instance = ComixCDPWorker._();
  ComixCDPWorker._();

  /// 检查 Chrome CDP 是否可用
  ///
  /// 关键：必须禁用环境变量代理（HTTP_PROXY/HTTPS_PROXY），
  /// 否则 Dart HttpClient 会把 localhost 请求发给 Clash 代理，
  /// 导致 isAvailable() 永远返回 false，CDP 路径被跳过。
  Future<bool> isAvailable() async {
    // 2026-10-19：优先复用已监听的 CDP；没有则拉起随 App 分发的内置
    // Chrome for Testing（绿色版，不依赖系统 Chrome）。外部手动 Chrome
    // 仍然兼容：只要 9222 上已有 CDP，ensureRunning 会直接探活成功。
    if (await ComixBrowserManager.instance.ensureRunning()) return true;
    Log.warning(
      "ComixCDP",
      "isAvailable failed: no CDP on $_cdpHost:$_cdpPort and no bundled chrome",
    );
    return false;
  }

  /// 把 cf_clearance 注入内置浏览器（CDP Network.setCookie）。
  ///
  /// 背景：`verifyCloudflare` 用 AppWebview 拿到 cookie 后只存在文件/JS 引擎里，
  /// 内置 CfT 的 cookie jar 并不知道它。这里通过 CDP 把同一个 cf_clearance
  /// 写进 CfT（同一 UA/IP 下 Cloudflare 认可），采集才能复用验证会话。
  Future<bool> setCookie({
    required String name,
    required String value,
    String domain = '.comix.to',
    String path = '/',
  }) async {
    try {
      await _send('Network.enable', {});
      final resp = await _send('Network.setCookie', {
        'name': name,
        'value': value,
        'domain': domain,
        'path': path,
        'secure': true,
        'httpOnly': false,
        'sameSite': 'None',
      });
      final ok = resp['result']?['success'] == true;
      Log.info("ComixCDP", "setCookie $name -> $ok");
      return ok;
    } catch (e) {
      Log.warning("ComixCDP", "setCookie failed: $e");
      return false;
    }
  }

  /// 从 `cf_cookie.json` 读取 cf_clearance 并注入内置浏览器。
  Future<void> injectSavedCfCookie() async {
    try {
      final f = File("${App.dataPath}\\cf_cookie.json");
      if (!f.existsSync()) return;
      final data = jsonDecode(f.readAsStringSync());
      final v = data is Map ? data['cf_clearance'] as String? : null;
      if (v != null && v.isNotEmpty) {
        await setCookie(name: 'cf_clearance', value: v);
      }
    } catch (e) {
      Log.warning("ComixCDP", "injectSavedCfCookie failed: $e");
    }
  }

  /// 连接 CDP WebSocket
  Future<WebSocket> _connect() async {
    // 🔴 2026-10-19（第十一轮）：浏览器被 ComixBrowserManager.closeExisting()
    //    重启后，旧 `_ws` 虽然非 null 但已 closed。若直接返回它，第一次导航
    //    会往死 socket 写命令 → 超时/异常 → 被上层误判成 comix 503。
    //    这里必须按 readyState 判定，并把陈旧连接彻底丢弃后重连新 target。
    if (_ws != null && _ws!.readyState == WebSocket.open) return _ws!;
    if (_ws != null) {
      try {
        await _ws!.close();
      } catch (_) {}
      _ws = null;
      _pageWsUrl = null;
      _pending.clear();
    }

    // 1. 获取 page target 的 WS URL（同样禁用代理）
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    final req = await client.getUrl(Uri.parse('http://$_cdpHost:$_cdpPort/json'));
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    client.close();

    final targets = jsonDecode(body) as List;
    // 优先找 comix.to 的 page，否则找第一个 page
    final pageTarget = targets.firstWhere(
      (t) => t['type'] == 'page',
      orElse: () => throw Exception('No page target in CDP'),
    );
    _pageWsUrl = pageTarget['webSocketDebuggerUrl'] as String?;
    if (_pageWsUrl == null) throw Exception('No webSocketDebuggerUrl');

    // 2. 连 WebSocket
    // WebSocket.connect 内部也用 HttpClient，同样被 HTTP_PROXY 环境变量拦截。
    // 临时设置 HttpOverrides.global 让所有 HttpClient 直连，连完恢复。
    final oldOverrides = HttpOverrides.current;
    HttpOverrides.global = _DirectHttpOverrides.instance;
    try {
      _ws = await WebSocket.connect(_pageWsUrl!);
    } finally {
      if (oldOverrides != null) HttpOverrides.global = oldOverrides;
    }
    _ws!.listen((raw) {
      try {
        final msg = jsonDecode(raw as String) as Map<String, dynamic>;
        final id = msg['id'];
        if (id != null && _pending.containsKey(id)) {
          final c = _pending.remove(id)!;
          c.complete(msg);
        }
      } catch (_) {}
    });

    return _ws!;
  }

  /// 发 CDP 命令，等响应。
  ///
  /// 🔴 2026-10-19 死锁修复：旧实现固定 `c.future.timeout(15s)` 且往死 socket
  /// 写不抛错 —— 浏览器被杀 / 页面 target 卡死时，每个命令空等 15s、连发多条
  /// （forceHome / bringToFront / comixCookies）把「创建下载任务」对话框卡死
  /// 数分钟。现在：短超时（8s）+ 发送前检查 socket 是否仍 open + 写失败立即抛。
  static const _sendTimeout = Duration(seconds: 8);

  Future<Map<String, dynamic>> _send(
    String method,
    Map<String, dynamic> params, {
    Duration? timeout,
  }) async {
    final t = timeout ?? _sendTimeout;
    WebSocket ws;
    try {
      ws = await _connect();
    } catch (e) {
      Log.warning("ComixCDP", "_send($method): connect failed — $e");
      rethrow;
    }
    if (ws.readyState != WebSocket.open) {
      Log.warning(
        "ComixCDP",
        "_send($method): socket not open (state=${ws.readyState}) — fail fast",
      );
      _ws = null;
      _pending.clear();
      throw StateError("CDP socket not open");
    }
    _nextId++;
    final id = _nextId;
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    try {
      ws.add(jsonEncode({'id': id, 'method': method, 'params': params}));
    } catch (e) {
      _pending.remove(id);
      Log.warning("ComixCDP", "_send($method): write failed — $e");
      rethrow;
    }
    return c.future.timeout(t, onTimeout: () {
      _pending.remove(id);
      throw TimeoutException("CDP $method 超时 ${t.inSeconds}s", t);
    });
  }

  /// Runtime.evaluate — 在 Chrome 里执行 JS
  Future<dynamic> evaluate(String expression, {bool awaitPromise = true}) async {
    final resp = await _send('Runtime.evaluate', {
      'expression': expression,
      'returnByValue': true,
      'awaitPromise': awaitPromise,
    });
    final result = resp['result'] as Map<String, dynamic>?;
    final value = result?['result']?['value'];
    return value;
  }

  /// Page.navigate — 导航
  ///
  /// 关键：Chrome navigate 后可能重建 page target（特别是跨域或新 URL），
  /// 旧 WebSocket 连接会变成 stale（收不到消息或直接断连）。
  /// 所以 navigate 后必须断开旧 WS，下次 evaluate 会自动重连新 target。
  // P-DL9b: CDP 反检测 —— 极简、可逆、不破坏原生指纹。
  //
  // 🔴 2026-10-19（第十一轮）修正：旧实现把 navigator.plugins 覆盖成
  // `[1,2,3,4,5]`（数字数组，非真实 Plugin 对象）、并改写 languages/platform/
  // hardwareConcurrency/deviceMemory —— 在正式版 Chrome 里反而是**明显的指纹
  // 异常**（真实 Chrome 的 plugins 是带 name 的 Plugin 列表）。既然现在改用
  // 正式版 Chrome + 用户真实 profile，**最好的反检测就是不动原生值**：只把
  // navigator.webdriver 收敛为 false（与未被自动化控制的 Chrome 一致），其余一概不动。
  static const _antiDetectJs = r'''
(function(){
  try { Object.defineProperty(navigator, 'webdriver', {get: () => false, configurable: true}); } catch(e){}
})();
''';

  /// P-DL9b: 智能导航
  ///
  /// comix.to 服务器对所有非首页的 Page.navigate 返回 Third-party 页面，
  /// 只能用客户端路由 history.pushState + PopStateEvent 触发 SPA 内部跳转。
  /// 对 comix.to URL：pushState 方案；对外部 URL：Page.navigate 方案。
  Future<void> navigate(String url, {bool waitForChapters = false}) async {
    if (url.contains('comix.to')) blockedThirdParty = false;
    if (!url.contains('comix.to')) {
      // 外部 URL — Page.navigate
      await _doPageNavigate(url);
      await Future.delayed(const Duration(seconds: 4));
      try { await evaluate(_antiDetectJs); } catch (_) {}
      return;
    }

    // 熔断：命中 503 后短期内不再发任何 comix 请求。
    final until = _blockedUntil;
    if (until != null && DateTime.now().isBefore(until)) {
      blockedThirdParty = true;
      final left = until.difference(DateTime.now()).inSeconds;
      throw "COMIX_THIRD_PARTY: comix 判定本次自动化会话为第三方应用（503）。"
          "请 ${left}s 后再试（越重试冷却越久），或换一个网络出口";
    }

    // 反检测注入（每次 evaluate 前都做）
    try { await evaluate(_antiDetectJs); } catch (_) {}

    final cur = await _currentHref();
    if (!cur.contains('comix.to')) {
      // 还没连接到有效的 comix.to 页面 — 先硬开首页 bootstrap。
      // 🔴 首页是唯一「允许的文档导航」；之后所有跳转一律走 pushState。
      Log.info("ComixCDP", "navigate: bootstrapping homepage first");
      await _homeNavigate();
      try { await evaluate(_antiDetectJs); } catch (_) {}
    }

    // 🔴 pushState 到**同一个 URL** 是 no-op：SPA 不会重新渲染，
    //    章节区仍是上一次的（或空的）。
    final hrefNow = await _currentHref();
    if (_samePath(hrefNow, url)) {
      Log.info("ComixCDP", "navigate: same url — bounce via home to force re-render");
      await _pushState('https://comix.to/');
      await Future.delayed(const Duration(seconds: 2));
    }

    Log.info("ComixCDP", "navigate: pushState → $url");
    final ready = await _waitRoute(url, expectChapters: waitForChapters);
    try { await evaluate(_antiDetectJs); } catch (_) {}

    // 🔴 2026-10-19：Round 9 实证 —— comix 墙退后，直接 Page.navigate 到干净详情
    //    URL（不带 ?page）3 秒即可完整渲染；pushState 在个别情况下不触发 SPA
    //    重渲染（旧 `no manga detail` 病根）。若 pushState 后路由仍未就绪且未处
    //    503 熔断，则补一次直接文档导航（仅一次，避免连发导航触发 comix 判定）。
    if (!ready && !blockedThirdParty) {
      final want = Uri.tryParse(url);
      final clean = (want != null && want.query.isNotEmpty)
          ? 'https://comix.to${want.path}'
          : url;
      Log.info("ComixCDP", "navigate: pushState 未就绪，补直接文档导航 → $clean");
      await _doPageNavigate(clean);
      await _waitRoute(clean, expectChapters: waitForChapters);
      try { await evaluate(_antiDetectJs); } catch (_) {}
    }
  }

  /// 当前页面 href（失败返回空串）。
  Future<String> _currentHref() async {
    try {
      final v = await evaluate('location.href');
      return v is String ? v : '';
    } catch (_) {
      return '';
    }
  }

  /// 硬导航到首页，并做**限速**：45s 内已经刷过就复用当前页面。
  ///
  /// comix 的 503 只和「短时间内的文档导航次数」相关（同一次运行里连发 4 次
  /// 首页导航就被全站 503），所以绝不能一失败就重刷首页。
  Future<void> _homeNavigate() async {
    final last = _lastHomeNavAt;
    final now = DateTime.now();
    if (last != null && now.difference(last) < const Duration(seconds: 45)) {
      Log.info("ComixCDP", "navigate: homepage loaded ${now.difference(last).inSeconds}s ago — reuse (throttled)");
      return;
    }
    _lastHomeNavAt = now;
    await _doPageNavigate('https://comix.to/');
    await _waitRoute('https://comix.to/');
  }

  /// 两个 URL 是否指向同一路径 + 同一 query。
  bool _samePath(String a, String b) {
    final ua = Uri.tryParse(a);
    final ub = Uri.tryParse(b);
    if (ua == null || ub == null) return false;
    return ua.path == ub.path && ua.query == ub.query;
  }

  /// 客户端路由跳转（comix.to 对直接文档导航返回 Third-party 页）。
  Future<void> _pushState(String url) async {
    final jsonUrl = jsonEncode(url);
    try {
      await _send('Runtime.evaluate', {
        'expression': '''
(function(){
  try {
    history.pushState({spa:true}, '', $jsonUrl);
    window.dispatchEvent(new PopStateEvent('popstate', {state:{spa:true}}));
    return 'ok';
  } catch(e) { return 'error: ' + e.message; }
})()
''',
        'returnByValue': true,
        'awaitPromise': true,
      });
    } catch (e) {
      Log.warning("ComixCDP", "pushState failed: $e");
    }
  }

  /// 单次探针：页面关键状态一次读齐（避免多次 evaluate 拉长时序）。
  Future<Map<String, dynamic>?> _pageProbe() async {
    try {
      final s = await evaluate(r"""JSON.stringify({
  href: location.href,
  t: document.title || '',
  body: document.body ? document.body.innerText.slice(0,200) : '',
  rows: document.querySelectorAll('.mchap-row').length,
  sec: !!document.querySelector('SECTION.mpage__chapters, section.mpage__chapters'),
  detail: !!document.querySelector('meta[property="og:title"]'),
  ready: document.readyState
})""");
      if (s is! String) return null;
      return jsonDecode(s) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// 等客户端路由**真正生效**；顺带识别 CF 挑战页 / Third-party 拦截页。
  ///
  /// 🔴 2026-10-19 修：旧实现只要 `document.readyState === 'complete'` 就返回。
  /// 但 pushState 之后旧文档的 readyState 本来就是 complete，于是 855ms 就
  /// 把**首页 DOM**（620KB）当成详情页交出去 → JS 源报 `no manga detail`。
  /// 现在必须同时满足「location 的 path/query 已经切到目标」+「内容确实换了」。
  Future<bool> _waitRoute(
    String url, {
    bool expectChapters = false,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    final want = Uri.tryParse(url);
    final wantPath = want?.path ?? '';
    final wantQuery = want?.query ?? '';
    var prevTitle = '';
    try {
      final t = await evaluate('document.title');
      if (t is String) prevTitle = t;
    } catch (_) {}

    final deadline = DateTime.now().add(timeout);
    var sawChallenge = false;
    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 700));
      final m = await _pageProbe();
      if (m == null) continue;
      final body = (m['body'] ?? '') as String;
      final title = (m['t'] ?? '') as String;
      final ready = (m['ready'] ?? '') as String;
      final rows = (m['rows'] as num? ?? 0).toInt();
      final sec = m['sec'] == true;

      if (body.contains('Third-party apps')) {
        Log.warning("ComixCDP", "navigate: comix returned Third-party page");
        blockedThirdParty = true;
        final before = _blockedUntil;
        final until = DateTime.now().add(const Duration(minutes: 10));
        if (before == null || until.isAfter(before)) _blockedUntil = until;
        Log.warning(
          "ComixCDP",
          "navigate: 熔断 10 分钟 —— 连续重试只会延长 comix 的判定，请不要反复点",
        );
        return false;
      }
      if (title.contains('请稍候') ||
          title.contains('Just a moment') ||
          body.contains('正在进行安全验证')) {
        if (!sawChallenge) {
          Log.info("ComixCDP", "navigate: CF challenge in page, waiting…");
          sawChallenge = true;
        }
        continue;
      }

      // 首页：只要加载完且不是挑战/拦截页即可。
      if (wantPath == '/' || wantPath.isEmpty) {
        if (ready == 'complete') return true;
        continue;
      }

      final href = (m['href'] ?? '') as String;
      final u = Uri.tryParse(href);
      final pathOk = u != null &&
          u.path == wantPath &&
          (wantQuery.isEmpty || u.query == wantQuery);
      if (!pathOk) continue; // 客户端路由还没生效

      if (expectChapters) {
        if (rows > 0 || sec) return true;
        continue;
      }
      // 非章节场景（详情页 HTML 快照）：等内容真的换掉再读。
      if (title != prevTitle || rows > 0 || sec) return true;
    }
    Log.warning(
      "ComixCDP",
      "navigate: route not ready within ${timeout.inSeconds}s (path=$wantPath)",
    );
    return false;
  }

  /// 读详情页 DOM 元信息（`og:*` 在 Nuxt 客户端路由后会同步更新）。
  ///
  /// 用途：客户端路由出来的详情页**没有 SSR 的 `#initial-data`**，JS 源的
  /// `loadInfo` 因此报 `no manga detail`。把 og 元信息一并交给 JS 源，
  /// 让它能退化成「DOM 元信息 + 章节桥」继续建任务。
  Future<Map<String, dynamic>> pageMeta() async {
    try {
      final s = await evaluate(r"""(function(){
  var og = function(p){
    var el = document.querySelector('meta[property="' + p + '"]')
          || document.querySelector('meta[name="' + p + '"]');
    return el ? (el.getAttribute('content') || '') : '';
  };
  var h1 = document.querySelector('h1');
  return JSON.stringify({
    href: location.href,
    path: location.pathname || '',
    title: og('og:title') || (h1 ? (h1.innerText || '').trim() : '') || document.title || '',
    image: og('og:image'),
    desc: og('og:description'),
    docTitle: document.title || '',
    rows: document.querySelectorAll('.mchap-row').length,
    sec: !!document.querySelector('SECTION.mpage__chapters, section.mpage__chapters')
  });
})()""");
      if (s is String) return jsonDecode(s) as Map<String, dynamic>;
    } catch (e) {
      Log.warning("ComixCDP", "pageMeta failed: $e");
    }
    return <String, dynamic>{};
  }

  Future<void> _doPageNavigate(String url) async {
    await _send('Page.navigate', {'url': url});
    await Future.delayed(const Duration(milliseconds: 500));
    await _ws?.close();
    _ws = null;
    _pageWsUrl = null;
    _pending.clear();
  }

  /// 获取当前 Chrome tab 的 URL（从 /json/list）。
  Future<String?> currentUrl() async {
    try {
      final client = HttpClient()..findProxy = (_) => 'DIRECT';
      final req = await client.getUrl(Uri.parse('http://$_cdpHost:$_cdpPort/json/list'));
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      client.close();
      final pages = jsonDecode(body) as List;
      for (final p in pages) {
        if (p is Map && p['type'] == 'page') {
          return p['url'] as String?;
        }
      }
      return null;
    } catch (e) {
      Log.warning("ComixCDP", "currentUrl failed: $e");
      return null;
    }
  }

  /// 断开连接
  Future<void> dispose() async {
    await _ws?.close();
    _ws = null;
    _pending.clear();
  }

  /// 清空 comix.to 的所有 cookie（含 cf_clearance）。
  ///
  /// ⚠️ 2026-10-19 二次取证后**不建议在失败重试里调用**：全新 profile 只导航
  ///    一次首页依然 503，说明 503 并不是「钉在 cookie 上的标记」；清 cookie
  ///    反而要多发一次文档导航，加剧 comix 的判定。保留此方法仅作手动排障。
  ///
  /// 🔴 CDP 的 `Network.deleteCookies` **必须带 `name`**，只给 domain 会报
  ///    "Invalid parameters"（旧实现就是这样，全程删不掉任何 cookie）。
  ///    这里先 `Network.getCookies` 枚举，再逐个 name+domain+path 删。
  Future<bool> clearComixCookies() async {
    try {
      await _send('Network.enable', {});
      final resp = await _send('Network.getCookies', {
        'urls': ['https://comix.to/', 'https://comix.to'],
      });
      final list = resp['result']?['cookies'];
      var deleted = 0;
      if (list is List) {
        for (final c in list) {
          if (c is! Map) continue;
          final name = c['name'];
          final domain = c['domain'];
          if (name is! String || domain is! String) continue;
          final path = (c['path'] as String?) ?? '/';
          try {
            await _send('Network.deleteCookies', {
              'name': name,
              'domain': domain,
              'path': path,
            });
            deleted++;
          } catch (_) {}
        }
      }
      Log.info("ComixCDP", "clearComixCookies: deleted $deleted comix cookies");
      return true;
    } catch (e) {
      Log.warning("ComixCDP", "clearComixCookies failed: $e");
      return false;
    }
  }

  /// 硬导航回首页（`Page.navigate`，不是 pushState）。
  ///
  /// 为什么不能复用 [navigate]：CF 挑战页 / 503 页**没有 SPA 运行时**，
  /// pushState 在那种页面上是纯 no-op，页面不会重新请求服务器，挑战页也不会
  /// 出现。人机验证必须真正重新发一次首页文档请求。
  ///
  /// 返回 `true` = 首页成功加载（非 503、CDP 可用）；`false` = 仍 503 或 CDP 不可用。
  /// 🔴 2026-10-19：旧实现返回 void，调用方无法区分「CDP 死」与「首页正常」，
  ///    导致 `_verifyViaCfT` 在死 CDP 上傻等 5 分钟。现在用 bool 让上层快速放弃。
  Future<bool> forceHome() async {
    blockedThirdParty = false;
    _blockedUntil = null;
    _lastHomeNavAt = DateTime.now();
    try {
      await _doPageNavigate('https://comix.to/');
      await _waitRoute('https://comix.to/');
      try {
        await evaluate(_antiDetectJs);
      } catch (_) {}
      return !blockedThirdParty;
    } catch (e) {
      Log.warning("ComixCDP", "forceHome failed: $e");
      return false;
    }
  }

  /// 清除 503 熔断（验证成功 / 探测到墙已退时调用）。
  void clearBreaker() {
    _blockedUntil = null;
    blockedThirdParty = false;
  }

  /// 硬刷回 comix.to 首页（应用当前 cookie、清掉停留在 503 页的停滞 DOM）。
  Future<void> resetToHome() async {
    blockedThirdParty = false;
    _lastHomeNavAt = DateTime.now();
    try {
      await _doPageNavigate('https://comix.to/');
      await _waitRoute('https://comix.to/');
    } catch (e) {
      Log.warning("ComixCDP", "resetToHome failed: $e");
    }
  }

  /// 读取 CfT cookie jar 里 comix.to 的全部 cookie（小写名 → 值）。
  ///
  /// 用途：人在 CfT 窗口里过完 CF 后，**cookie 本来就已经在同一个 jar 里**，
  /// 不需要再用 `Network.setCookie` 回注；只要把它读出来存到 `cf_cookie.json`，
  /// 供 JS 引擎 / WebView 路径复用即可。
  Future<Map<String, String>> comixCookies() async {
    final out = <String, String>{};
    try {
      await _send('Network.enable', {});
      final resp = await _send('Network.getCookies', {
        'urls': ['https://comix.to/', 'https://comix.to'],
      });
      final list = resp['result']?['cookies'];
      if (list is List) {
        for (final c in list) {
          if (c is Map && c['name'] is String && c['value'] is String) {
            out[(c['name'] as String).toLowerCase()] = c['value'] as String;
          }
        }
      }
    } catch (e) {
      Log.warning("ComixCDP", "comixCookies failed: $e");
    }
    return out;
  }

  /// 把内置浏览器窗口提到最前（人机验证必须让用户看见那个窗口）。
  Future<void> bringToFront() async {
    try {
      await _send('Page.bringToFront', {});
    } catch (e) {
      Log.warning("ComixCDP", "bringToFront failed: $e");
    }
  }
}

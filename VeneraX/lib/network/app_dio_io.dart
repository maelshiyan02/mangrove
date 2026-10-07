import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
// import 'package:rhttp/rhttp.dart' as rhttp; // 暂时禁用 —— 未使用且需要 Rust 工具链
import 'package:venera/foundation/appdata.dart';
import 'package:venera/network/proxy.dart';

// ---- rhttp 适配层暂时禁用（pubspec.yaml 注释了 rhttp 依赖）----
// 所有 HTTP 请求走 dart:io 路径（_IOProxyAdapter）
Future<void> nativeInitRhttp() async {
  // 空操作：rhttp 已禁用，无需初始化
}

HttpClientAdapter createAppHttpClientAdapter({
  bool enableProxy = true,
  Duration? timeout,
}) => createIOAdapter(enableProxy: enableProxy);

HttpClientAdapter createIOAdapter({bool enableProxy = true}) =>
    _IOProxyAdapter(enableProxy: enableProxy);

/// A `dart:io` client wired to the app's network settings.
///
/// Paths that deliberately bypass [AppDio] (ranged file downloads, scripts
/// asking for `http_client: dart:io`) must still go through this: `dart:io`
/// trusts only Flutter's built-in root list, never the system store, so a
/// MITM proxy's own root — which the rhttp path accepts — otherwise fails
/// on those paths alone.
HttpClient createIOHttpClient({String? proxy}) {
  final client = HttpClient();
  client.findProxy = (uri) => proxy == null ? 'DIRECT' : 'PROXY $proxy';
  // ignoreBadCertificate 设置开启时放行所有证书错误。
  // 另外：只要走代理就放行——dart:io 只信 Flutter 内置根证书列表，
  // 不认系统证书库。代理软件（Clash 等）的根证书装在系统库里，
  // 且部分站点（如 ZeroSSL 签发的 *.baozimhcn.com）的根也不在内置列表中，
  // 这两种情况在原 rhttp 路径下都能过（rhttp 用系统库），dart:io 路径
  // 必须靠 badCertificateCallback 才能等价工作。
  if (appdata.settings['ignoreBadCertificate'] == true || proxy != null) {
    client.badCertificateCallback = (_, __, ___) => true;
  }
  return client;
}

Map<String, List<String>> buildRhttpDnsOverrides({
  required bool enabled,
  required Object? config,
}) {
  // rhttp 暂未启用，返回空
  // TODO: 恢复 rhttp 依赖后迁移完整实现
  return {};
}

// ---- 以下 rhttp 适配层暂未启用，保持占位供后续恢复 ----
/*
rhttp.ClientSettings buildRhttpClientSettings({...}) { ... }
完整的 rhttp RHttpAdapter 类在恢复 Rust 依赖后替换回来
*/

/// 简化版 RHttpAdapter —— 内部走 dart:io（_IOProxyAdapter），API 兼容原始 rhttp 版本。
/// 恢复 rhttp 依赖后可替换成完整实现。
class RHttpAdapter implements HttpClientAdapter {
  RHttpAdapter({this.enableProxy = true, this.timeout});

  final bool enableProxy;
  final Duration? timeout;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    return _IOProxyAdapter(
      enableProxy: enableProxy,
    ).fetch(options, requestStream, cancelFuture);
  }
}

class _IOProxyAdapter implements HttpClientAdapter {
  final bool enableProxy;

  _IOProxyAdapter({this.enableProxy = true});

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final proxy = enableProxy ? await getProxy() : null;
    final adapter = IOHttpClientAdapter(
      createHttpClient: () => createIOHttpClient(proxy: proxy),
    );
    return adapter.fetch(options, requestStream, cancelFuture);
  }
}

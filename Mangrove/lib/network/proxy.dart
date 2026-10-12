import 'package:flutter/services.dart';
import 'package:mangrove/foundation/app.dart';
import 'package:mangrove/foundation/appdata.dart';
import 'package:mangrove/utils/ext.dart';

String? _cachedProxy;

DateTime? _cachedProxyTime;

Future<String?> getProxy() async {
  if (_cachedProxyTime != null &&
      DateTime.now().difference(_cachedProxyTime!).inSeconds < 1) {
    return _cachedProxy;
  }
  String? proxy = await _getProxy();
  _cachedProxy = proxy;
  _cachedProxyTime = DateTime.now();
  return proxy;
}

Future<String?> _getProxy() async {
  if ((appdata.settings['proxy'] as String).removeAllBlank == "direct") {
    return null;
  }
  if (appdata.settings['proxy'] != "system") return appdata.settings['proxy'];

  String res;
  if (!App.isLinux) {
    const channel = MethodChannel("mangrove/method_channel");
    try {
      res = await channel.invokeMethod("getProxy");
    } catch (e) {
      return null;
    }
  } else {
    res = "No Proxy";
  }
  if (res == "No Proxy") return null;

  if (res.contains(";")) {
    var proxies = res.split(";");
    for (String proxy in proxies) {
      proxy = proxy.removeAllBlank;
      if (proxy.startsWith('https=')) {
        return proxy.substring(6);
      }
    }
  }

  final RegExp regex = RegExp(
    r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}:\d+$',
    caseSensitive: false,
    multiLine: false,
  );
  if (!regex.hasMatch(res)) {
    return null;
  }

  return res;
}

/// 强制直连（绕过代理）的主机后缀白名单。
///
/// 背景与结论翻转（2026-10-11，Mangrove P39 → P41）：
/// - P39 时取证：comix.to 的 Cloudflare WAF 按**出口 IP/ASN** 封禁，用户
///   当时的美国代理节点 403、同机家宽直连 200 ⇒ 曾把 comix.to 全域钉死
///   DIRECT（dio findProxy + WebView2 `--proxy-bypass-list`）。
/// - P41 时实测（34 个 SS 节点逐个切）：封禁名单随时间变化且**家宽 IP 也
///   已被封**（南京电信 58.209.131.5 直连同样 403）；同期香港/日本/新加坡/
///   英国/加拿大/澳洲/法国等 31 个节点 **200**，仅美国 Y01/Y02、印度 403。
///   ⇒ 钉死任何一个方向（直连/代理）都会在下一轮 WAF 调整后失效。
///
/// 结论：默认列表清空，comix 流量**跟随用户的代理设置/节点选择**——
/// 节点被封时在 Clash 切香港/日本等节点即可（App 会在硬封禁页给出提示），
/// 直连可用时把 App 代理设为直连即可。机制保留为空安全，以后若再出现
/// 「该域确定直连优于代理」的站点可重新加入：
/// - dio：`createIOHttpClient.findProxy` 命中即返回 `DIRECT`；
/// - 离屏 WebView2：`_getSharedWebViewEnvironment` 把它们并入
///   `--proxy-bypass-list`。
const List<String> kDirectProxyHostSuffixes = <String>[];

/// [host] 是否属于「强制直连」白名单（自身或以 `.后缀` 结尾）。
bool isDirectProxyHost(String host) {
  final h = host.toLowerCase().trim();
  for (final s in kDirectProxyHostSuffixes) {
    if (h == s || h.endsWith('.$s')) return true;
  }
  return false;
}

/// 生成 Chromium `--proxy-bypass-list` 片段（每条后缀同时给裸域与通配子域）。
String buildProxyBypassList() {
  final rules = <String>[];
  for (final s in kDirectProxyHostSuffixes) {
    rules.add(s);
    rules.add('*.$s');
  }
  return rules.join(';');
}

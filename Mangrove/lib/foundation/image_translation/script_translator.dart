import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:mangrove/foundation/image_translation/llm_translator.dart';
import 'package:mangrove/network/app_dio.dart';
import 'package:mangrove/utils/translations.dart';

/// 用户在 Flutter 沙箱（flutter_qjs）里写的自定义翻译脚本的运行时。
///
/// 契约（与上游 VeneraX v2.3.5 一致，也正好是我们 `studio_pipeline._translate`
/// 已有的契约）：脚本定义
/// `async function translate({texts, sourceLang, targetLang, glossary, provider})`
/// 并返回 `{texts: string[], glossary?: {source: translation}}`，**等长同序**。
///
/// 每个调用独占一个 QuickJS 运行时；失败/超时必须抛异常，由调用方
/// （`translation_dispatcher.dart` 的 `_viaScript`）回退到内置引擎，不能卡死或丢文本。
abstract class ScriptTranslator {
  /// 新建脚本时的脚手架：演示如何借 `Network.sendRequest` 打一个 OpenAI 兼容端点。
  /// 只作起点，用户按自己的接口改 `return` 那一行即可。
  static const template = '''
// 输入：texts (string[])、sourceLang、targetLang、glossary、provider。
// 输出：{texts: string[], glossary?: {source: translation}}。
// 必须对每个输入恰好返回一个翻译，且保持顺序。
async function translate({texts, sourceLang, targetLang, glossary, provider}) {
    const response = await Network.sendRequest(
        'POST', provider.url,
        {'Content-Type': 'application/json',
         'Authorization': 'Bearer ' + provider.key},
        JSON.stringify({texts, source: sourceLang, target: targetLang})
    );
    if (response.status !== 200) throw new Error('HTTP ' + response.status);
    const data = JSON.parse(response.body);
    // 把这一行改成你的接口返回字段。
    return {texts: data.translations};
}
''';

  /// 在 QuickJS 沙箱里跑一次 [provider.script]，把 [texts] 翻成 [targetLang]。
  ///
  /// 沙箱参数与上游一致：**1s 执行超时 + 64MB 内存上限**（仅约束 JS 同步执行；
  /// 真正的墙钟上限由 Dart 层的 [timeout] 兜底，默认 3 分钟）。脚本若发起
  /// `Network.sendRequest`，会经 Dart 侧的 `request` 桥走 `AppDio`，从而使
  /// 超时/取消/凭据遮蔽都按宿主的 HTTP 栈生效。
  ///
  /// 返回形状校验（等长同序 + glossary 合法性）在 [parse] 里；任何不符都抛异常，
  /// 由 `TranslationDispatcher._viaScript` 捕获并回退内置引擎。
  static Future<LlmTranslationResult> translate(
    LlmProvider provider,
    List<String> texts,
    String sourceLang,
    String targetLang, {
    Map<String, String> glossary = const {},
    Duration timeout = LlmTranslator.requestTimeout,
    Dio? client,
  }) async {
    if (texts.isEmpty) return const LlmTranslationResult([], {});
    final init = await rootBundle.loadString('assets/init.js');
    final engine = FlutterQjs(
      timeout: 1000,
      memoryLimit: 64 * 1024 * 1024,
      // 脚本里未处理的 Promise rejection 不应把脚本内容打到日志。
      hostPromiseRejectionHandler: (_) {},
    );
    final dio = client ??
        AppDio(
          BaseOptions(
            responseType: ResponseType.plain,
            connectTimeout: const Duration(seconds: 20),
            receiveTimeout: timeout,
            validateStatus: (_) => true,
          ),
          timeout,
        );
    final cancel = CancelToken();
    final stop = Completer<void>();
    final requests = <Future<void>>[];
    Future<dynamic>? result;
    engine.dispatch();
    try {
      Future<Map<String, dynamic>> request(dynamic message) async {
        if (message is! Map || message['method'] != 'http') {
          throw Exception('脚本里只允许发起翻译网络的 HTTP 请求'.tl);
        }
        final url = message['url']?.toString() ?? '';
        if (!LlmTranslator.isValidBaseUrl(url)) {
          throw Exception('请输入有效的 API 地址'.tl);
        }
        try {
          final response = await dio.request<dynamic>(
            url,
            data: message['data'],
            cancelToken: cancel,
            options: Options(
              method: message['http_method']?.toString() ?? 'GET',
              headers: Map<String, dynamic>.from(message['headers'] ?? {}),
              responseType: message['bytes'] == true
                  ? ResponseType.bytes
                  : ResponseType.plain,
            ),
          );
          return {
            'status': response.statusCode,
            'headers': response.headers.map,
            'body': message['bytes'] == true
                ? Uint8List.fromList(List<int>.from(response.data))
                : response.data,
          };
        } on DioException {
          // 不要把请求头/请求体暴露进脚本错误里。
          throw Exception('翻译接口请求失败'.tl);
        }
      }

      final setter =
          engine.evaluate('(send) => { globalThis.sendMessage = send; }')
              as JSInvokable;
      try {
        setter([
          (dynamic message) {
            final future = request(message);
            requests.add(future.then<void>((_) {}, onError: (Object _) {}));
            return future;
          },
        ]);
      } finally {
        setter.free();
      }
      engine.evaluate(init, name: '<init>');
      final function = engine.evaluate('''
        (() => {
          ${provider.script}
          if (typeof translate !== 'function') throw new Error(${jsonEncode('请定义函数 translate(input)'.tl)});
          return (input, stop) => Promise.race([
            Promise.resolve().then(() => translate(input)), stop
          ]).then(value => JSON.stringify(value));
        })()
      ''', name: '<translation>') as JSInvokable;
      try {
        result = Future<dynamic>.value(
          function([
            {
              'texts': texts,
              'sourceLang': sourceLang,
              'targetLang': targetLang,
              'glossary': glossary,
              'provider': {
                'url': provider.url,
                'key': provider.key,
                'model': provider.model,
              },
            },
            stop.future,
          ]),
        );
      } finally {
        function.free();
      }
      final output = await result.timeout(timeout);
      if (output is! String) throw const FormatException();
      return parse(jsonDecode(output), texts.length);
    } on TimeoutException {
      throw Exception('自定义翻译脚本超时'.tl);
    } on FormatException {
      throw Exception('自定义翻译脚本返回了非法结果'.tl);
    } finally {
      // 在释放原生运行时前，先让 Dart 侧托管的 Promise 落定。
      cancel.cancel();
      stop.complete();
      await Future.wait(requests);
      try {
        await result;
      } catch (_) {}
      dio.close(force: true);
      try {
        engine.close();
      } finally {
        engine.port.close();
      }
    }
  }

  /// 把沙箱吐出的 `output` 校验成 [LlmTranslationResult]。
  ///
  /// 允许 `{texts}` 或裸数组两种形状；长度必须正好等于 [count]（等长同序），
  /// 每个元素必须是字符串；`glossary` 若存在且合法则收下（经
  /// [LlmTranslator.isValidGlossaryTerm] 过滤，与工作室 store 同一规则）。
  static LlmTranslationResult parse(dynamic output, int count) {
    final texts = output is List
        ? output
        : (output is Map ? output['texts'] : null);
    if (texts is! List ||
        texts.length != count ||
        texts.any((item) => item is! String)) {
      throw Exception('自定义翻译脚本必须为每个输入返回一个字符串'.tl);
    }
    final names = output is Map ? output['glossary'] : null;
    if (names != null &&
        (names is! Map ||
            names.entries.any(
              (e) => e.key is! String || e.value is! String,
            ))) {
      throw Exception('自定义翻译脚本返回了非法的术语表'.tl);
    }
    return LlmTranslationResult(texts.cast<String>(), {
      if (names is Map)
        for (final entry in names.entries)
          if (LlmTranslator.isValidGlossaryTerm(entry.key, entry.value))
            (entry.key as String).trim(): (entry.value as String).trim(),
    });
  }
}

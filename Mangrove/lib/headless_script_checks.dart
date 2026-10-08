import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mangrove/foundation/appdata.dart';
import 'package:mangrove/foundation/image_translation/llm_translator.dart';
import 'package:mangrove/foundation/image_translation/script_translator.dart';
import 'package:mangrove/foundation/image_translation/translation_dispatcher.dart';
import 'package:mangrove/foundation/image_translation/translation_engines.dart';
import 'package:mangrove/foundation/log.dart';

/// 与 headless.dart 中同签名的收尾打印；本文件自包含，避免循环依赖。
void cliPrint(Map<String, dynamic> data) {
  print('[CLI PRINT] ${jsonEncode(data)}');
}

/// `mangrove.exe --headless script-check [--json out.json]`
///
/// 验证 P10.10 ① 自定义翻译脚本（flutter_qjs 沙箱）：
///   1. 沙箱能跑通用户的 JS、返回等长同序译文；
///   2. 术语表（glossary）正向透传、非法项被过滤；
///   3. 长度不符（少返回）必须被拒 —— 反向验证"等长同序"契约；
///   4. 超时（永不 resolve 的 Promise）被截断，不卡死；
///   5. 路由：脚本可用时走脚本、脚本抛错时回退到内置引擎（离线标记接缝）。
///
/// 每条断言都在同一次运行里做反向验证：正确输入必须为 true，故意改错的输入
/// 必须为 false。回退链路不依赖外网 —— 通过临时替换 [TranslationDispatcher.builtInFallback]
/// 成确定性离线实现来验证。
Future<void> runScriptCheck(List<String> args, int commandIndex) async {
  final jsonIndex = args.indexOf('--json');
  final outPath = jsonIndex != -1 && jsonIndex + 1 < args.length
      ? args[jsonIndex + 1]
      : '${Directory.current.path}/script_check.json';

  final checks = <Map<String, Object?>>[];
  void check(String name, bool passed, String detail) =>
      checks.add({'name': name, 'passed': passed, 'detail': detail});

  Future<void> finish(bool passed, String message) async {
    final report = {
      'version': 1,
      'command': 'script-check',
      'passed': passed,
      'checks': checks,
    };
    final output = File(outPath);
    if (!output.parent.existsSync()) {
      await output.parent.create(recursive: true);
    }
    await output.writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
      encoding: utf8,
    );
    for (final entry in checks) {
      cliPrint({'status': 'running', 'message': 'Check', 'data': entry});
    }
    cliPrint({
      'status': passed ? 'success' : 'error',
      'message': message,
      'data': {'report': output.path},
    });
  }

  // 脚本设置键（与 LlmProviderStore 私有常量同值），headless 里直接改内存，不落盘。
  const providersKey = 'imageTranslationProviders';
  const activeKey = 'imageTranslationActiveProviderId';

  // 测试用的 JS：纯计算，不发网络请求。
  const workingScript = '''
async function translate({texts, sourceLang, targetLang, glossary, provider}) {
    return {
        texts: texts.map(function (t) { return t + '_S'; }),
        glossary: { 'Hero': '英雄' }
    };
}
''';

  const shortScript = '''
async function translate({texts}) {
    return { texts: ['only-one'] };
}
''';

  const hangScript = '''
async function translate({texts}) {
    return new Promise(function () {});
}
''';

  const throwingScript = '''
async function translate({texts}) {
    throw new Error('boom');
}
''';

  const mixedGlossaryScript = '''
async function translate({texts}) {
    return { texts: texts, glossary: { '': 'x', 'Hero': '英雄' } };
}
''';

  var passed = false;
  // 保存现场，验证后还原，避免污染真实设置。
  final prevEngine = appdata.settings[TranslationEngines.settingKey];
  final prevProviders = appdata.settings[providersKey];
  final prevActive = appdata.settings[activeKey];
  final prevFallback = TranslationDispatcher.builtInFallback;
  try {
    // 强制走"在线 LLM / 脚本"这条线：本地 NMT 没有脚本通道，会绕过路由断言。
    appdata.settings[TranslationEngines.settingKey] = TranslationEngines.cloudLlmId;

    // 1) 沙箱跑通 + 等长同序。
    final workingProvider = LlmProvider(
      id: 'script-check-working',
      name: 'working',
      url: '',
      key: '',
      model: '',
      kind: LlmProviderKind.script,
      script: workingScript,
    );
    final r = await ScriptTranslator.translate(
      workingProvider,
      ['A', 'B', 'C'],
      'en',
      'zh',
    );
    check(
      'sandbox.runs',
      r.texts.length == 3 && r.texts[0] == 'A_S' && r.texts[2] == 'C_S',
      'texts=${r.texts}',
    );

    // 2) 术语表正向透传（反向验证见 glossary.invalidFiltered）。
    check(
      'glossary.passthrough',
      r.glossary['Hero'] == '英雄',
      'glossary=${r.glossary}',
    );

    // 3) 非法术语被过滤（反向验证 glossary.passthrough）。
    final rg = await ScriptTranslator.translate(
      LlmProvider(
        id: 'script-check-mixed',
        name: 'mixed',
        url: '',
        key: '',
        model: '',
        kind: LlmProviderKind.script,
        script: mixedGlossaryScript,
      ),
      ['A'],
      'en',
      'zh',
    );
    check(
      'glossary.invalidFiltered',
      rg.glossary.containsKey('Hero') && !rg.glossary.containsKey(''),
      'glossary=${rg.glossary}',
    );

    // 4) 长度不符必须被拒（反向验证 sandbox.runs 的等长同序契约）。
    var shortThrew = false;
    try {
      await ScriptTranslator.translate(
        LlmProvider(
          id: 'script-check-short',
          name: 'short',
          url: '',
          key: '',
          model: '',
          kind: LlmProviderKind.script,
          script: shortScript,
        ),
        ['A', 'B', 'C'],
        'en',
        'zh',
      );
    } on Exception catch (_) {
      shortThrew = true;
    }
    check(
      'length.mismatch.rejected',
      shortThrew,
      shortThrew ? 'short script rejected' : 'short script accepted (BUG)',
    );

    // 5) 超时（永不 resolve）被截断，不卡死。
    final sw = Stopwatch()..start();
    var timeoutThrew = false;
    try {
      await ScriptTranslator.translate(
        LlmProvider(
          id: 'script-check-hang',
          name: 'hang',
          url: '',
          key: '',
          model: '',
          kind: LlmProviderKind.script,
          script: hangScript,
        ),
        ['A'],
        'en',
        'zh',
        timeout: const Duration(milliseconds: 500),
      );
    } on Exception catch (_) {
      timeoutThrew = true;
    }
    final elapsed = sw.elapsed;
    check(
      'timeout.truncated',
      timeoutThrew && elapsed < const Duration(seconds: 5),
      'timeoutThrew=$timeoutThrew elapsed=${elapsed.inMilliseconds}ms',
    );

    // 6) + 7) 路由：脚本可用时走脚本；脚本抛错时回退内置引擎（离线标记接缝）。
    TranslationDispatcher.builtInFallback =
        (List<String> texts, String targetLang,
            {Map<String, String> glossary = const {}}) async {
      return LlmTranslationResult(
        texts.map((t) => 'FB:$t').toList(),
        {},
      );
    };

    // 6) 脚本可用 → 走脚本，不用回退标记。
    appdata.settings[providersKey] = [workingProvider.toJson()];
    appdata.settings[activeKey] = workingProvider.id;
    final routed = await TranslationDispatcher.translateBatch(
      ['X', 'Y'],
      'zh',
      sourceLang: 'en',
    );
    check(
      'routing.usesScript',
      routed.texts.length == 2 && routed.texts[0] == 'X_S',
      'routed=${routed.texts}',
    );

    // 7) 脚本抛错 → 回退到内置引擎（标记出现即证明走通回退链路）。
    final throwingProvider = LlmProvider(
      id: 'script-check-throwing',
      name: 'throwing',
      url: '',
      key: '',
      model: '',
      kind: LlmProviderKind.script,
      script: throwingScript,
    );
    appdata.settings[providersKey] = [throwingProvider.toJson()];
    appdata.settings[activeKey] = throwingProvider.id;
    final fallback = await TranslationDispatcher.translateBatch(
      ['X', 'Y'],
      'zh',
      sourceLang: 'en',
    );
    check(
      'routing.fallback',
      fallback.texts.length == 2 && fallback.texts[0] == 'FB:X',
      'fallback=${fallback.texts}',
    );

    passed = checks.every((c) => c['passed'] == true);
    await finish(
      passed,
      'Script check ${passed ? 'PASS' : 'FAIL'} '
      '(${checks.where((c) => c['passed'] == true).length}/${checks.length})',
    );
  } catch (e, s) {
    Log.error('ScriptCheck', 'script-check failed: $e\n$s');
    check('exception', false, e.toString());
    await finish(false, 'Script check threw: $e');
  } finally {
    // 还原现场。
    TranslationDispatcher.builtInFallback = prevFallback;
    appdata.settings[providersKey] = prevProviders;
    appdata.settings[activeKey] = prevActive;
    appdata.settings[TranslationEngines.settingKey] = prevEngine;
  }
  exit(passed ? 0 : 1);
}

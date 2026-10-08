import 'package:mangrove/foundation/image_translation/llm_translator.dart';
import 'package:mangrove/foundation/image_translation/local_nmt_translator.dart';
import 'package:mangrove/foundation/image_translation/script_translator.dart';
import 'package:mangrove/foundation/image_translation/translation_engines.dart';
import 'package:mangrove/foundation/log.dart';
import 'package:mangrove/foundation/translation_project/glossary_bridge.dart';

/// Single translation call site for the whole app: picks the configured
/// engine (an online LLM provider or one of the offline NMT engines) and
/// routes one batch of bubble texts to it.
///
/// Keeping this one door means the reader's per-page path and the
/// pre-translation manager's grouped path can never drift apart, and adding
/// another engine never touches pipeline/service code again.
abstract class TranslationDispatcher {
  /// See [LocalNmtTranslator.translateBatch] / [LlmTranslator.translateBatch]
  /// for the parameters. [sourceLangs] are the OCR-detected per-line
  /// languages; [sourceLang] is the comic-level effective source.
  ///
  /// ## 🔴 术语表有两条投递通路，别只用一条
  ///
  /// 只有**真正的 LLM** 有"术语表"这个概念（塞进 prompt）。另外两类引擎
  /// **根本没有通道**，术语表会被静默丢弃 —— 用户看不出区别：译文照常出来，
  /// 只是人名一页一个样。这两类走 [_bridged] 的"译前占位 → 译后还原"：
  ///
  /// * **免 Key 公共端点**（`PublicTranslator`，谷歌翻译）：一行一个请求，
  ///   没有 prompt 可塞；
  /// * **本地 NMT**（NLLB / Opus-MT）：seq2seq，没有术语表参数。
  static Future<LlmTranslationResult> translateBatch(
    List<String> texts,
    String targetLang, {
    required String sourceLang,
    List<String>? sourceLangs,
    Map<String, String> glossary = const {},
  }) async {
    if (texts.isEmpty) return const LlmTranslationResult([], {});
    var engine = TranslationEngines.activeLocal;
    if (engine == null) {
      final active = LlmProviderStore.active;
      // 自定义脚本：经 QuickJS 沙箱跑用户的 JS，失败/超时回退内置引擎。
      if (active != null && active.usesScript) {
        return _viaScript(texts, sourceLang, targetLang, glossary, active);
      }
      if (!LlmTranslator.activeIsPublicFree) {
        // 真 LLM：术语表进 prompt，不需要桥接。
        return LlmTranslator.translateBatch(
          texts,
          targetLang,
          glossary: glossary,
        );
      }
      return _bridged(
        texts,
        glossary,
        (protected) => LlmTranslator.translateBatch(protected, targetLang),
      );
    }
    return _bridged(
      texts,
      glossary,
      (protected) => LocalNmtTranslator.translateBatch(
        protected,
        targetLang,
        engine: engine,
        sourceLang: sourceLang,
        sourceLangs: sourceLangs,
      ),
    );
  }

  /// 测试/回退接缝：脚本失败时要调用的"内置引擎"翻译。生产代码默认走
  /// [LlmTranslator.translateBatch]（真实端点）；headless 的 `script-check`
  /// 会临时换成确定性离线实现，从而在不依赖外网的情况下验证"脚本失败 → 回退
  /// 到内置引擎"这条链路真的被走通。
  static Future<LlmTranslationResult> Function(
    List<String> texts,
    String targetLang, {
    Map<String, String> glossary,
  }) builtInFallback = _defaultBuiltInFallback;

  static Future<LlmTranslationResult> _defaultBuiltInFallback(
    List<String> texts,
    String targetLang, {
    Map<String, String> glossary = const {},
  }) =>
      LlmTranslator.translateBatch(texts, targetLang, glossary: glossary);

  /// 走自定义脚本路径；任何异常（沙箱抛错、超时、返回形状非法）都回退内置引擎，
  /// 不让一次坏脚本卡死整页翻译或吞掉原文。
  static Future<LlmTranslationResult> _viaScript(
    List<String> texts,
    String sourceLang,
    String targetLang,
    Map<String, String> glossary,
    LlmProvider provider,
  ) async {
    try {
      return await ScriptTranslator.translate(
        provider,
        texts,
        sourceLang,
        targetLang,
        glossary: glossary,
      );
    } catch (e) {
      // 🔴 回退必须可见：脚本为什么挂、回退到了哪条路径，都要留下痕迹。
      Log.warning(
        'Script Translator',
        '自定义翻译脚本失败（$e）；回退到内置引擎',
      );
      // 走 builtInFallback 接缝：生产默认是真实 LLM 端点；headless 的
      // `script-check` 会临时换成确定性离线实现，从而在不依赖外网的情况下
      // 验证"脚本失败 → 回退到内置引擎"这条链路真的被走通。
      return builtInFallback(texts, targetLang, glossary: glossary);
    }
  }

  /// 给"不吃术语表"的引擎套一层占位/还原。
  ///
  /// [call] 拿到的是**已插入哨兵**的文本，所以引擎内部完全不必知道术语表存在。
  static Future<LlmTranslationResult> _bridged(
    List<String> texts,
    Map<String, String> glossary,
    Future<LlmTranslationResult> Function(List<String> protected) call,
  ) async {
    final plan = GlossaryBridge.protect(texts, glossary);
    if (plan.isUnused) return call(texts);
    final raw = await call(plan.texts);
    final restored = GlossaryBridge.restore(raw.texts, plan);
    // 🔴 失败必须可见：哨兵可能被分词器切碎或吞掉，而这在本会话无法实机跑
    // NMT 验证。落地了几个、丢了几个都要说出来 —— 否则"人名不一致"会被当成
    // 模型的问题，而真正的原因是术语表根本没送到。
    if (restored.lost > 0 || restored.residue > 0) {
      Log.warning(
        'Glossary Bridge',
        '${restored.restored}/${plan.placeholders} terms landed'
        '${restored.lost > 0 ? ', lost=${restored.lost}' : ''}'
        '${restored.residue > 0 ? ', residue swept=${restored.residue}' : ''}'
        ' — this engine has no glossary channel; a mismatch here means the '
        'sentinel did not survive tokenisation',
      );
    }
    return LlmTranslationResult(restored.texts, raw.glossary);
  }
}

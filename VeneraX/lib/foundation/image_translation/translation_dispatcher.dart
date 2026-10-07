import 'package:venera/foundation/image_translation/llm_translator.dart';
import 'package:venera/foundation/image_translation/local_nmt_translator.dart';
import 'package:venera/foundation/image_translation/translation_engines.dart';

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
      return LlmTranslator.translateBatch(
        texts,
        targetLang,
        glossary: glossary,
      );
    }
    return LocalNmtTranslator.translateBatch(
      texts,
      targetLang,
      engine: engine,
      sourceLang: sourceLang,
      sourceLangs: sourceLangs,
    );
  }
}

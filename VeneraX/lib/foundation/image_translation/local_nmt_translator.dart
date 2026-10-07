import 'package:venera/foundation/image_translation/llm_translator.dart';
import 'package:venera/foundation/image_translation/translation_engines.dart';
import 'package:venera/foundation/image_translation/translation_worker.dart';

/// Main-isolate facade for offline neural translation. Mirrors
/// [LlmTranslator.translateBatch]'s contract (aligned texts, no glossary)
/// so callers can switch engines without special-casing the result type.
///
/// Inference itself runs in the dedicated worker isolate (see
/// [TranslationWorker.translateLines]); this class only resolves the active
/// engine and forwards the batch.
abstract class LocalNmtTranslator {
  /// Translates [texts] into [targetLang].
  ///
  /// [sourceLang] is the comic-level effective source ('auto' when the
  /// language lock has not fired); [sourceLangs] optionally carries the
  /// OCR-detected language of each line and takes precedence, which is what
  /// lets an 'auto' comic translate a multilingual page line by line.
  ///
  /// Lines the engine cannot translate (unsupported pair, e.g. Classical
  /// Latin through NLLB) come back as empty strings.
  static Future<LlmTranslationResult> translateBatch(
    List<String> texts,
    String targetLang, {
    required LocalEngineDescriptor engine,
    required String sourceLang,
    List<String>? sourceLangs,
  }) async {
    if (texts.isEmpty) return const LlmTranslationResult([], {});
    var langs = List<String?>.generate(
      texts.length,
      (i) => sourceLangs != null && i < sourceLangs.length
          ? sourceLangs[i]
          : null,
    );
    var results = await TranslationWorker.instance.translateLines(
      engine: engine,
      texts: texts,
      sourceLangs: langs,
      fallbackSourceLang: sourceLang,
      targetLang: targetLang,
    );
    // Local engines learn no glossary — same contract as the keyless public
    // endpoint.
    return LlmTranslationResult(results, const {});
  }
}

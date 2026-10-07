import 'package:venera/foundation/appdata.dart';

/// Architecture of an offline neural machine-translation engine. The two
/// share the encoder/decoder greedy-decoding loop but differ in how the
/// encoder input is framed and how decoding starts:
///
/// - [nllb]:  encoder `[<src-lang-token>, ...pieces, eos(2)]`;
///            decoding starts at the *forced* target-language token and
///            stops at eos token 2.
/// - [marian] (Opus-MT): encoder `[...pieces, eos(0)]`;
///            decoding starts at the fixed decoder-start/pad token (60715)
///            and stops at eos token 0.
enum LocalNmtKind { nllb, marian }

/// Description of one selectable offline translation engine.
///
/// Everything inference needs (model component, framing constants, language
/// matrix) lives here so the worker isolate — which cannot read appdata or
/// touch UI singletons — only receives the descriptor id plus file paths.
class LocalEngineDescriptor {
  const LocalEngineDescriptor({
    required this.id,
    required this.displayName,
    required this.componentId,
    required this.kind,
    required this.encoderEosId,
    required this.decoderEosId,
    this.decoderStartId,
    required this.maxTokens,
    required this.sources,
    required this.targets,
    this.note = '',
  });

  /// Stable settings value (stored under [TranslationEngines.settingKey]).
  final String id;

  final String displayName;

  /// Id of the downloadable [ModelComponent] holding this engine's files.
  final String componentId;

  final LocalNmtKind kind;

  /// Token appended after the source pieces in the encoder input.
  final int encoderEosId;

  /// Token that terminates greedy decoding.
  final int decoderEosId;

  /// First decoder token for [LocalNmtKind.marian]; NLLB derives its first
  /// token from the target language instead.
  final int? decoderStartId;

  /// Per-line generation cap (bubbles are short; this only bounds loops).
  final int maxTokens;

  /// Source language codes this engine accepts ('auto' is always accepted
  /// and resolved at runtime from the per-block OCR language).
  final Set<String> sources;

  /// Target language codes this engine can produce.
  final Set<String> targets;

  /// Free-form limitation shown in the engine picker.
  final String note;

  /// Whether a concrete [src]→[tgt] pair is translatable. 'auto' defers the
  /// decision to the detected per-block language, so it is accepted here;
  /// unsupported blocks are then dropped individually at inference time.
  bool supports(String src, String tgt) {
    if (src == 'auto') return true;
    if (!sources.contains(src) || !targets.contains(tgt)) return false;
    // zh / zh-TW share one written language for this purpose: zh→zh-TW is
    // handled by the OpenCC conversion path, never by the NMT engine.
    return _langBase(src) != _langBase(tgt);
  }

  /// Whether a single detected block language is usable (the per-block
  /// predicate used when the comic is in 'auto' mode).
  bool supportsBlock(String src, String tgt) =>
      src != 'auto' && supports(src, tgt);

  static String _langBase(String lang) =>
      lang == 'zh-TW' ? 'zh' : lang;
}

/// Static facts and pure helpers shared by the engine picker, the worker
/// inference code and unit tests.
abstract class TranslationEngines {
  /// Pseudo-id for the existing online path (configured LLM providers,
  /// including the keyless Google Translate endpoint).
  static const cloudLlmId = 'llm';

  /// Settings key holding the active engine id.
  static const settingKey = 'imageTranslationEngine';

  // --- NLLB language-token names (must match tokenizer.json added_tokens).
  // Note that NLLB's FLORES-200 vocabulary has NO Classical Latin entry:
  // Latin text therefore cannot use an NLLB engine and stays on the online
  // path. Spanish is `spa_Latn`.
  static const nllbTokenNames = <String, String>{
    'ja': 'jpn_Jpan',
    'ko': 'kor_Hang',
    'en': 'eng_Latn',
    'es': 'spa_Latn',
    'zh': 'zho_Hans',
    'zh-TW': 'zho_Hant',
  };

  static const _nllbSources = {'ja', 'ko', 'en', 'es', 'zh'};
  static const _nllbTargets = {'zh', 'zh-TW', 'en', 'ja', 'ko', 'es'};

  /// Quality tier: NLLB-200 distilled 1.3B, dynamic int8 (~1.9 GB).
  static const nllb13b = LocalEngineDescriptor(
    id: 'nllb_1_3b',
    displayName: 'NLLB-200 1.3B (offline, best quality)',
    componentId: 'mt_nllb_1_3b',
    kind: LocalNmtKind.nllb,
    encoderEosId: 2,
    decoderEosId: 2,
    maxTokens: 200,
    sources: _nllbSources,
    targets: _nllbTargets,
    note: '~1.9 GB download. Slower on CPU; best offline quality.',
  );

  /// Light tier: NLLB-200 distilled 600M, dynamic int8 (~0.9 GB).
  static const nllb600m = LocalEngineDescriptor(
    id: 'nllb_600m',
    displayName: 'NLLB-200 600M (offline, lightweight)',
    componentId: 'mt_nllb_600m',
    kind: LocalNmtKind.nllb,
    encoderEosId: 2,
    decoderEosId: 2,
    maxTokens: 200,
    sources: _nllbSources,
    targets: _nllbTargets,
    note: '~0.9 GB download. Faster, slightly lower quality than 1.3B.',
  );

  /// Tiny ja→en specialist: Helsinki-NLP Opus-MT (Marian), int8 (~110 MB).
  static const opusJaEn = LocalEngineDescriptor(
    id: 'opus_ja_en',
    displayName: 'Opus-MT Japanese → English (offline)',
    componentId: 'mt_opus_ja_en',
    kind: LocalNmtKind.marian,
    encoderEosId: 0,
    decoderStartId: 60715,
    decoderEosId: 0,
    maxTokens: 200,
    sources: {'ja'},
    targets: {'en'},
    note: '~110 MB download. One pair only: Japanese to English.',
  );

  /// Offline engines in picker order.
  static const localEngines = [nllb13b, nllb600m, opusJaEn];

  /// Every selectable id (online first, then offline tiers).
  static const choiceIds = [
    cloudLlmId,
    'nllb_1_3b',
    'nllb_600m',
    'opus_ja_en',
  ];

  static LocalEngineDescriptor? find(String? id) {
    if (id == null) return null;
    for (var engine in localEngines) {
      if (engine.id == id) return engine;
    }
    return null;
  }

  /// The currently active engine id; falls back to the online path for
  /// missing/legacy settings.
  static String get activeId {
    var value = appdata.settings[settingKey];
    if (value is String && value.isNotEmpty) return value;
    return cloudLlmId;
  }

  /// Descriptor of the active engine when it is an offline one, else null
  /// (caller routes to the online LLM translator).
  static LocalEngineDescriptor? get activeLocal => find(activeId);

  static bool isLocalId(String? id) => find(id) != null;

  // ----------------------------------------------------------------------
  // Pure framing helpers (also unit tested)
  // ----------------------------------------------------------------------

  /// Encoder input ids for one already-tokenized source line.
  static List<int> buildEncoderIds(
    LocalEngineDescriptor engine,
    List<int> pieces,
    int? sourceLangTokenId,
  ) {
    switch (engine.kind) {
      case LocalNmtKind.nllb:
        if (sourceLangTokenId == null) {
          throw ArgumentError(
            'NLLB encoder input needs a source-language token',
          );
        }
        return [sourceLangTokenId, ...pieces, engine.encoderEosId];
      case LocalNmtKind.marian:
        return [...pieces, engine.encoderEosId];
    }
  }

  /// First decoder ids: the forced target-language token for NLLB, the
  /// fixed start token for Marian.
  static List<int> initialDecoderIds(
    LocalEngineDescriptor engine,
    int? targetLangTokenId,
  ) {
    switch (engine.kind) {
      case LocalNmtKind.nllb:
        if (targetLangTokenId == null) {
          throw ArgumentError(
            'NLLB decoding needs a target-language token',
          );
        }
        return [targetLangTokenId];
      case LocalNmtKind.marian:
        return [engine.decoderStartId!];
    }
  }
}

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/translation_engines.dart';
import 'package:venera/foundation/image_translation/translation_models.dart';
import 'package:venera/foundation/image_translation/translation_worker.dart';

void main() {
  group('TranslationEngines registry', () {
    test('choice ids resolve: online pseudo-id plus every local engine', () {
      expect(TranslationEngines.choiceIds.first, TranslationEngines.cloudLlmId);
      for (var id in TranslationEngines.choiceIds.skip(1)) {
        expect(TranslationEngines.find(id), isNotNull, reason: id);
      }
      expect(
        TranslationEngines.localEngines.map((e) => e.id).toList(),
        TranslationEngines.choiceIds.skip(1).toList(),
      );
    });

    test('find returns null for unknown and null ids', () {
      expect(TranslationEngines.find(null), isNull);
      expect(TranslationEngines.find('does_not_exist'), isNull);
      expect(TranslationEngines.find(TranslationEngines.cloudLlmId), isNull);
      expect(TranslationEngines.isLocalId('nllb_600m'), isTrue);
      expect(TranslationEngines.isLocalId('llm'), isFalse);
    });

    test('every local engine maps to an installed-model component', () {
      for (var engine in TranslationEngines.localEngines) {
        var component = TranslationModels.find(engine.componentId);
        expect(component, isNotNull, reason: engine.componentId);
        expect(
          TranslationModels.machineTranslation.contains(component),
          isTrue,
          reason: '${engine.id} should live in the MT section',
        );
        expect(TranslationModels.all.contains(component), isTrue);
      }
    });
  });

  group('NLLB language matrix', () {
    for (var engine in const [
      TranslationEngines.nllb13b,
      TranslationEngines.nllb600m,
    ]) {
      test('${engine.id} accepts the documented source/target pairs', () {
        expect(engine.supports('ja', 'zh'), isTrue);
        expect(engine.supports('ko', 'en'), isTrue);
        expect(engine.supports('en', 'zh'), isTrue);
        expect(engine.supports('es', 'zh'), isTrue);
        expect(engine.supports('es', 'ja'), isTrue);
        expect(engine.supports('ja', 'zh-TW'), isTrue);
        expect(engine.supports('zh', 'en'), isTrue);
      });

      test('${engine.id} rejects same-language, Latin, and unknown pairs', () {
        // Same base language never reaches the NMT engine.
        expect(engine.supports('zh', 'zh'), isFalse);
        expect(engine.supports('zh', 'zh-TW'), isFalse);
        expect(engine.supports('en', 'en'), isFalse);
        // FLORES-200 has no Classical Latin token.
        expect(engine.supports('la', 'zh'), isFalse);
        expect(engine.supports('ja', 'la'), isFalse);
      });

      test('${engine.id} always accepts auto at the descriptor level', () {
        expect(engine.supports('auto', 'zh'), isTrue);
        expect(engine.supportsBlock('auto', 'zh'), isFalse);
        expect(engine.supportsBlock('ja', 'zh'), isTrue);
      });
    }

    test('NLLB token table covers every concrete source and target', () {
      var names = TranslationEngines.nllbTokenNames;
      for (var code in const {'ja', 'ko', 'en', 'es', 'zh', 'zh-TW'}) {
        expect(names.containsKey(code), isTrue, reason: code);
      }
      expect(names.containsKey('la'), isFalse);
      expect(names['ja'], 'jpn_Jpan');
      expect(names['es'], 'spa_Latn');
      expect(names['zh-TW'], 'zho_Hant');
    });
  });

  group('Opus-MT ja->en specialist', () {
    const engine = TranslationEngines.opusJaEn;

    test('supports only Japanese to English', () {
      expect(engine.supports('ja', 'en'), isTrue);
      expect(engine.supports('ko', 'en'), isFalse);
      expect(engine.supports('ja', 'zh'), isFalse);
      expect(engine.supports('en', 'ja'), isFalse);
      expect(engine.supports('auto', 'en'), isTrue);
    });

    test('uses Marian framing constants', () {
      expect(engine.kind, LocalNmtKind.marian);
      expect(engine.encoderEosId, 0);
      expect(engine.decoderEosId, 0);
      expect(engine.decoderStartId, 60715);
    });
  });

  group('encoder/decoder framing', () {
    test('NLLB frames source token + pieces + eos(2)', () {
      expect(
        TranslationEngines.buildEncoderIds(TranslationEngines.nllb600m, [10, 11], 256079),
        [256079, 10, 11, 2],
      );
      expect(
        TranslationEngines.initialDecoderIds(TranslationEngines.nllb600m, 256200),
        [256200],
      );
    });

    test('NLLB requires language tokens', () {
      expect(
        () => TranslationEngines.buildEncoderIds(
          TranslationEngines.nllb600m,
          [10],
          null,
        ),
        throwsArgumentError,
      );
      expect(
        () => TranslationEngines.initialDecoderIds(
          TranslationEngines.nllb600m,
          null,
        ),
        throwsArgumentError,
      );
    });

    test('Marian frames pieces + eos(0) and starts at its fixed token', () {
      expect(
        TranslationEngines.buildEncoderIds(TranslationEngines.opusJaEn, [10, 11], null),
        [10, 11, 0],
      );
      expect(
        TranslationEngines.initialDecoderIds(TranslationEngines.opusJaEn, null),
        [60715],
      );
    });
  });

  group('OCR language mapping', () {
    test('Spanish and Latin reuse the English OCR model', () {
      expect(TranslationModels.ocrFor('en').id, 'ocr_en');
      expect(TranslationModels.ocrFor('es').id, 'ocr_en');
      expect(TranslationModels.ocrFor('la').id, 'ocr_en');
      expect(TranslationModels.ocrFor('ja').id, 'ocr_ja');
      expect(TranslationModels.ocrFor('ko').id, 'ocr_ko');
      expect(TranslationModels.ocrFor('zh').id, 'ocr_zh');
    });
  });

  group('hasRepetitionLoop', () {
    test('short or normal tails do not loop', () {
      expect(hasRepetitionLoop([]), isFalse);
      expect(hasRepetitionLoop([7]), isFalse);
      expect(hasRepetitionLoop([1, 1, 1]), isFalse);
      expect(hasRepetitionLoop([1, 2, 3, 4]), isFalse);
      expect(hasRepetitionLoop([5, 5, 5, 6]), isFalse);
      expect(hasRepetitionLoop([1, 2, 1, 2, 1, 3]), isFalse);
    });

    test('four identical tail tokens loop', () {
      expect(hasRepetitionLoop([9, 9, 9, 9]), isTrue);
      expect(hasRepetitionLoop([1, 2, 3, 7, 7, 7, 7]), isTrue);
    });

    test('a three-token repeating tail cycle loops', () {
      expect(hasRepetitionLoop([1, 2, 3, 1, 2, 3]), isTrue);
      expect(hasRepetitionLoop([9, 9, 4, 5, 6, 4, 5, 6]), isTrue);
    });
  });
}

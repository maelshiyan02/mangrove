import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/image_translation/llm_translator.dart';

void main() {
  const key = LlmPromptStore.settingKey;

  setUp(() => appdata.settings[key] = '');

  test('empty setting means the built-in prompt', () {
    expect(LlmPromptStore.isCustom, isFalse);
    expect(LlmPromptStore.template, LlmPromptStore.builtIn);
  });

  test('resolve substitutes every target placeholder', () {
    appdata.settings[key] = r'to $target, only $target';
    expect(LlmPromptStore.resolve('简体中文'), 'to 简体中文, only 简体中文');
  });

  test('built-in prompt carries the placeholder and the JSON contract', () {
    var resolved = LlmPromptStore.resolve('English');
    expect(LlmPromptStore.builtIn, contains(r'$target'));
    expect(resolved, contains('English'));
    expect(resolved, isNot(contains(r'$target')));
    expect(resolved, contains('lines'));
    expect(resolved, contains('names'));
  });

  test('a custom prompt is used verbatim', () {
    appdata.settings[key] = '  translate to \$target  ';
    expect(LlmPromptStore.isCustom, isTrue);
    expect(LlmPromptStore.template, 'translate to \$target');
  });

  // Storing the built-in text as a "custom" value would freeze that device on
  // this release's wording; it must fall back to the live built-in instead.
  test('the built-in text and blank input both normalize to empty', () {
    expect(LlmPromptStore.normalize(LlmPromptStore.builtIn), '');
    expect(LlmPromptStore.normalize('   '), '');
    expect(LlmPromptStore.normalize('  mine  '), 'mine');
  });

  test('prompt is not in the sync denylist', () {
    expect(Appdata.syncDisabledFields(const []), isNot(contains(key)));
  });
}

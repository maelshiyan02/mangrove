// 术语表条目的合法性判定。
//
// 🔴 为什么单独一个文件：这条规则有两个主人 ——
//
// * `LlmTranslator`（引擎层）：模型回报"新出现的专名"时要过滤；
// * `translation_project/glossary_store.dart`（工作室）：读写术语表时也要过滤。
//
// 放在 `image_translation/` 下是为了让依赖方向保持单向（工作室依赖引擎层的
// 原语，而不是反过来 —— `translation_types.dart:44` 记的就是这条约定）。
//
// 只收**短专名**（人名、地名、招式/组织名）：术语表随每个请求原样发出去，
// 太大既费 token 又可能撑爆上下文。模型偶尔会把整句、URL、数字当成"专名"
// 回报，这里挡掉 —— 它同时是提示词指令的兜底。
class GlossaryTerm {
  GlossaryTerm._();

  /// 专名都很短，超过这个长度几乎肯定是句子。
  static const int maxLength = 16;

  static bool isValid(String source, String translation) {
    if (source.isEmpty || translation.isEmpty) return false;
    if (source.length > maxLength || translation.length > maxLength) {
      return false;
    }
    for (var s in [source, translation]) {
      // URL / 邮箱 / 路径 —— 不是专名，还长。
      if (_urlLike.hasMatch(s)) return false;
      // 句子样：有句读标点，或"空格-内容-空格"这种从句特征。
      if (_sentenceLike.hasMatch(s)) return false;
    }
    // 纯数字（页码、计数）没有需要保持一致的"叫法"。
    if (_numericOnly.hasMatch(source)) return false;
    return true;
  }

  static final RegExp _urlLike = RegExp(
    r'https?://|www\.|@|[./\\][a-zA-Z]{2,}|\.(com|net|org|io|cn|jp)\b',
    caseSensitive: false,
  );

  static final RegExp _sentenceLike = RegExp(r'[。！？.!?、,，；;]|\s{1,}\S+\s');

  static final RegExp _numericOnly = RegExp(r'^[0-9\s.,]+$');
}

// Which font families ship with the app, and what to do with a family name the
// app does **not** ship (S9 · P1-4).
//
// 🔴 **这个文件是 P1-4 的核心契约，不是配置表。** P9.0 §7.3 登记过一条风险：
// 「P1-4 与 P0-1 若被排开，会产生假绿」—— P0-1 让渲染器认 `font_family`，
// 而没有注册字体时，改字族**没有任何反应**，于是"P0-1 已完成"这个结论是
// 假的。所以本文件必须同时回答两个问题：
//
// 1. 打包了哪些 family（→ `pubspec.yaml` 的 `fonts:`）；
// 2. 请求了一个**没有打包**的 family 时怎么办（→ [resolveFamily]）。
//
// P33（2026-10-11）：用户拍板「**不打包新字体，改用系统字体探测**」——
// 零包体增长、可选字体极多。本文件因此从「二档」扩成「三档」：
//   打包字体 → 机器里装着的字体 → 打包字体（回退终点）
// 🔴 **回退终点与别名表都还在**，所以旧工程的行为一个字节都没变；系统字体
// 只在机器上真有、且用户主动选中时才生效。详见 [resolveFamily] 的注释。
//
// 答案不是"交给 Flutter 自己 fallback"，而是**显式落到打包字体**。理由：
// Flutter 的默认 fallback 是平台 UI 字体，在没装中文字体的机器上会画出
// 豆腐块，而这种情况在发行版上一定会出现（Steam 包的 Windows 机器什么
// 字体都有，Linux 发行版则未必）。显式 fallback 让"字体缺失"这件事
// 在开发期就暴露成一次断言失败，而不是在用户机器上暴露成一片方块。
library;

import 'package:mangrove/foundation/system_fonts.dart';

/// 一个打包进 `assets/fonts/` 的字族。
class BundledFont {
  const BundledFont({
    required this.family,
    required this.file,
    required this.weight,
    required this.script,
    required this.license,
  });

  /// Flutter 侧的 family 名（= `pubspec.yaml` 里 `family:` 的值）。
  ///
  /// 🔴 必须是**稳定的 ASCII 名**，不能是 `思源黑体` 这类本地化名字：它会
  /// 同时出现在 `pubspec.yaml`、`FontFormat.font_family`（写进 FT 工程 json）
  /// 和翻译表里，任何一处改名都会让历史工程里的字族名指向不存在的字体。
  final String family;

  /// 相对 `assets/` 的路径。
  final String file;

  /// 100..900。
  final int weight;

  /// 该字族覆盖的文种（用于面板上的说明，不参与匹配）。
  final String script;

  /// 内嵌 LICENSE 文件（相对 `assets/`），SIL OFL 1.1 要求随字体分发。
  final String license;
}

/// 打包字族表。
///
/// 🔴 与 `pubspec.yaml` 的 `fonts:` 段**必须一致**，由 `font.registry_matches_pubspec`
/// 断言锁住。两处不一致时症状是"面板能选、渲染找不到字"或反之 —— 静默的。
///
/// ⚠️ 文件是 **`.otf` 而不是 `.ttf`**：读 sfnt 头验证过，这些二进制是
/// `OTTO`（CFF 轮廓）。内容一样，但扩展名要诚实 —— 改回 `.ttf` 会让
/// "这是什么格式"这件事只能靠猜。
const bundledFonts = <BundledFont>[
  BundledFont(
    family: 'Noto Sans SC',
    file: 'fonts/NotoSansSC-Regular.otf',
    weight: 400,
    script: 'Simplified Chinese / Japanese kana / Latin',
    license: 'fonts/LICENSE-NotoSansSC.txt',
  ),
  BundledFont(
    family: 'Noto Sans SC',
    file: 'fonts/NotoSansSC-Bold.otf',
    weight: 700,
    script: 'Simplified Chinese / Japanese kana / Latin',
    license: 'fonts/LICENSE-NotoSansSC.txt',
  ),
  // 🔴 S9 · P9.7: Hangul. Registered as its **own family** rather than merged
  // into the SC entry above, and deliberately **not** made the fallback
  // endpoint: `primaryBundledFamily` decides what an unknown family renders
  // as, and moving that endpoint would change the appearance of every existing
  // project — the silent change P9.4 §6 warned about.
  BundledFont(
    family: 'Noto Sans KR',
    file: 'fonts/NotoSansKR-Regular.otf',
    weight: 400,
    script: 'Korean (Hangul) / Hanja / Latin',
    license: 'fonts/LICENSE-NotoSansKR.txt',
  ),
  BundledFont(
    family: 'Noto Sans KR',
    file: 'fonts/NotoSansKR-Bold.otf',
    weight: 700,
    script: 'Korean (Hangul) / Hanja / Latin',
    license: 'fonts/LICENSE-NotoSansKR.txt',
  ),
];

/// 打包字体里的**常规字重**家族，作为一切回退的终点。
///
/// 只有这一个 family 是"回退终点"而不是"某个候选"：加第二个中文字族时，
/// 必须让它自己声明"我的常规字重是哪个"（[fallbackFor]），而不是让这里
/// 变成一个按插入顺序取第一个的列表 —— 那会让"新增字体改变了旧工程的
/// 外观"，而这正是 P9.4 §六警告过的那类静默改动。
const String primaryBundledFamily = 'Noto Sans SC';

/// 所有打包 family 的名字（去重，保持 [bundledFonts] 的声明顺序）。
List<String> get bundledFamilies {
  final seen = <String>{};
  return [
    for (final font in bundledFonts)
      if (seen.add(font.family)) font.family,
  ];
}

/// [resolveFamily] 的结果：真正该用的 family，以及**为什么**。
class ResolvedFamily {
  const ResolvedFamily({
    required this.family,
    required this.fallback,
    required this.reason,
  });

  /// 交给 `TextStyle.fontFamily` 的名字。
  final String family;

  /// True 表示 [family] 不是 FT 原本请求的那个，而是我们替换上去的。
  final bool fallback;

  /// 人可读的判定理由 —— 面板与断言都靠它说话，避免"静默改样式"。
  final String reason;
}

/// FT 面板里那些"其实指同一个字体"的历史名字。
///
/// 🔴 这些映射**不是**审美选择，而是历史包袱的具体形态：`FontFormat`
/// 的默认值就是 `'Microsoft YaHei UI'`（见 `FontFormat.defaultFontFamily`），
/// 而 `S9Fixture` / `Error the Echo` 这类 FT 工程里到处是这个值。若不认识它，
/// 打开工程的用户看到的就是"字族设了雅黑，但哪里都找不到雅黑"。
///
/// 只映射**确实等价**的：雅黑 UI 与 Noto Sans SC 都是无衬线 CJK，视觉差
/// 在可接受范围。**不**映射任何衬线/手写体 —— 那是真的不同字体，悄悄替换
/// 等于伪造用户的意图。
const Map<String, String> _aliasToBundled = {
  'Microsoft YaHei UI': primaryBundledFamily,
  'Microsoft YaHei': primaryBundledFamily,
  '微软雅黑': primaryBundledFamily,
  'Source Han Sans SC': primaryBundledFamily,
  '思源黑体': primaryBundledFamily,
  'Noto Sans CJK SC': primaryBundledFamily,
  // 🔴 P9.7: the same reasoning for Korean. Without these, a Korean project
  // whose json says "Malgun Gothic" (the Windows default, i.e. the exact
  // analogue of the YaHei case above) would fall through to the *Chinese*
  // face and lose every Hangul syllable to a platform font.
  'Malgun Gothic': 'Noto Sans KR',
  '맑은 고딕': 'Noto Sans KR',
  'NanumGothic': 'Noto Sans KR',
  'Nanum Gothic': 'Noto Sans KR',
  '나눔고딕': 'Noto Sans KR',
  'Noto Sans CJK KR': 'Noto Sans KR',
  'Apple SD Gothic Neo': 'Noto Sans KR',
};

/// The bundled families a [TextStyle] should try when [requested]'s family has
/// no glyph for some character, in order. **Never** includes [requested]'s own
/// resolved family (Flutter already tries it first).
///
/// ## Why a fallback chain, and why it is not a contradiction of [resolveFamily]
///
/// [resolveFamily] answers "this project asks for a face the app does not
/// have — which one face do we use instead?". That question has to be answered
/// with a **single** family: it is what gets written into the panel, and
/// letting Flutter pick per glyph is exactly the silent substitution the whole
/// file exists to prevent.
///
/// This function answers a different question: "the face we chose is correct,
/// but it is a *subset* — which other **bundled** faces may supply the
/// characters this one lacks?". Noto Sans SC has no Hangul; Noto Sans KR has
/// no simplified-only Han shapes. Falling back to each other keeps the chain
/// inside `assets/fonts/`, which is what makes acceptance criterion ③
/// ("Chinese text does not depend on a system font") survive a Korean project
/// on a machine with no CJK fonts installed at all.
///
/// The distinction matters: **bundled-to-bundled fallback is fine,
/// requested-to-something-else is not.**
List<String> bundledFamilyFallbacks(String? requested) {
  final primary = resolveFamily(requested).family;
  return [
    for (final family in bundledFamilies)
      if (family != primary) family,
  ];
}

/// 解析 FT 请求的字族，返回真正该用的 family。
///
/// 五条规则，按顺序：
///
/// 1. **空名** → 打包字体。FT 里 `font_family` 缺失是常态（老工程），而
///    "缺失"绝不等于"用系统默认"。
/// 2. **打包过的 family** → 原样返回。
/// 3. **机器里装着的字体**（P33 · 系统字体探测） → 原样返回。
/// 4. **已知别名**（历史遗留的雅黑/思源） → 映射到打包字体，`fallback`
///    为 true。
/// 5. **完全未知** → 落到 [primaryBundledFamily]，`fallback` 为 true。
///
/// 🔴 第 3 条压过第 4 条的理由：别名表是「打包字体时代」的权宜之计 ——
/// 它的存在前提是"雅黑没被打进包里"，而系统字体探测落地后这个前提不成立
/// 了。机器上真有雅黑却仍换成思源黑，等于**静默替换用户意图**，正是本文件
/// 开头反对的那类事。第 5 条（回退终点）**没动**：扫描表为空或机器上没有
/// 该字体时，行为与 P33 之前逐字节一致。
///
/// 第 5 条是本文件存在的理由。Flutter 自己在 `fontFamily` 不存在时会
/// 静默回退到平台默认（Windows 上通常是 Times New Roman / 雅黑），于是
/// 用户设一个没打包的字体名 → 渲染出来像"生效了"，实际字形已经换了。
/// 显式落到打包字体后，那条路径至少**在视觉上是可预期的**（中文一定出字），
/// 并且由 `font.unknown_family_falls_back` 断言在开发期就被看见。
ResolvedFamily resolveFamily(String? requested) {
  final name = (requested ?? '').trim();
  if (name.isEmpty) {
    return ResolvedFamily(
      family: primaryBundledFamily,
      fallback: true,
      reason: 'no font_family in the block — using the bundled family',
    );
  }
  final key = name.toLowerCase();
  for (final font in bundledFonts) {
    if (font.family.toLowerCase() == key) {
      return ResolvedFamily(
        family: font.family,
        fallback: false,
        reason: 'bundled family "$name"',
      );
    }
  }
  // P33: 系统字体探测。两个前提缺一不可 —— 机器上装着，**且**它能显示中文
  // （[hasCjk] 的门槛就是 A05 §3 的底线：绝不能因为"装了 Arial"就让译文
  // 变成豆腐块）。空表（未扫描 / 非 Windows）直接落空，不改变旧行为。
  final installed = systemFonts.byFamily[key];
  if (installed != null && systemFonts.hasCjk(name)) {
    return ResolvedFamily(
      family: installed.first.family,
      fallback: false,
      reason: 'system font "$name" (installed on this machine)',
    );
  }
  final alias = _aliasToBundled[name];
  if (alias != null) {
    return ResolvedFamily(
      family: alias,
      fallback: true,
      reason: '"$name" is a system font that is not bundled; '
          'mapped to "$alias"',
    );
  }
  return ResolvedFamily(
    family: primaryBundledFamily,
    fallback: true,
    reason: '"$name" is neither bundled nor installed; '
        'fell back to "$primaryBundledFamily"',
  );
}

/// 面板字族选择器的候选：一个字族 + 它从哪来 + 能显示什么。
class FontFamilyChoice {
  const FontFamilyChoice({
    required this.family,
    required this.bundled,
    required this.label,
    required this.scripts,
  });

  final String family;

  /// True = 打进 `assets/fonts/`；false = 机器里装着的 / 工程 json 里写的
  /// 但我们没有的。
  final bool bundled;

  /// 下拉里显示的一行。
  final String label;

  /// 能显示的文种说明（打包字体写死，系统字体由 cmap 实测）。空串表示未知。
  final String scripts;
}

/// 面板字族选择器的候选项：打包 family + 系统字体 + 当前块用的名字。
///
/// 🔴 当前块的名字即使不在打包表里也要**列出来**（作为"当前（未打包）"一项）：
/// 不列的话，用户打开一个 FT 工程会看到面板显示的是打包字体，而 json 里写的
/// 是另一个名字 —— 于是"我明明有那个字体"变成了一个看起来像 bug 的现象，
/// 而真相是他选的那个字体根本没进这个应用。
///
/// 🔴 系统字体**只列能显示 CJK/假名/谚文**的那些（见
/// `SystemFontIndex.choices`）：一台 Windows 上躺着上百个西文字体，全列出来
/// 会把真正能用来嵌字的十几个中文字体淹没掉。
List<FontFamilyChoice> fontFamilyChoices(String? current) {
  final result = <FontFamilyChoice>[];
  final seen = <String>{};
  for (final font in bundledFonts) {
    if (!seen.add(font.family.toLowerCase())) continue;
    result.add(
      FontFamilyChoice(
        family: font.family,
        bundled: true,
        label: font.family,
        scripts: font.script,
      ),
    );
  }
  for (final info in systemFonts.choices) {
    if (!seen.add(info.family.toLowerCase())) continue;
    result.add(
      FontFamilyChoice(
        family: info.family,
        bundled: false,
        label: info.family,
        scripts: info.scriptLabel,
      ),
    );
  }
  final name = (current ?? '').trim();
  if (name.isNotEmpty && !seen.contains(name.toLowerCase())) {
    final installed = systemFonts.has(name);
    result.add(
      FontFamilyChoice(
        family: name,
        bundled: false,
        label: installed ? '$name (installed)' : '$name (not bundled)',
        scripts: '',
      ),
    );
  }
  return result;
}
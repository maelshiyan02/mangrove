// P56 · 阅读器翻页 / 桌面快捷键 / 双布局的 headless 断言集。
//
// 与 P12~P15 同一纪律（A02 §7）：每条断言跑两遍 —— 绿路径喂**真实现**或真源码，
// 故障路径喂一个**故意写错的实现/文本**；只有「故障路径喂进同一判据会不通过」
// 才说明这条判据真能钉住行为，而不是装饰品。
//
// 覆盖：① 0.5 视口步长与 200ms 动画常量；② 桌面快捷键表（含帮助声明逐条对齐）；
// ③ 章节跳转守卫（三处隐式来源一律拒绝）；④ 章末双卡「始终可达」；
// ⑤ readerLayoutMode 三值推断；⑥ 源码接线（空格接管、删净隐式跳章与浮动按钮、
// 桌面控件重排、帮助无虚标）；⑦ i18n 与设置四件套。
//
// 🔴 不能覆盖：实际滚动手感、像素布局、模态遮罩外观 —— 这些要 GUI 会话（A01 §3）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:mangrove/foundation/reader_ux_policy.dart';

// 私有别名：headless.dart 同时 import 了 headless_p1_checks.dart，
// 那边也导出 `CheckSink`，这里不导出同名类型以免引用时歧义。
typedef _CheckSink = void Function(String name, bool passed, String detail);

/// 一条断言 = 绿路径通过 且 故障路径不通过。
void _pair(
  _CheckSink check,
  String name,
  bool green,
  bool brokenWouldPass,
  String detail,
) {
  check(
    name,
    green && !brokenWouldPass,
    'green=$green broken_would_pass=$brokenWouldPass | $detail',
  );
}

/// 剥掉 Dart 注释后再扫源码，避免注释里的字样把判据喂绿（A02 §7 第 3 条）。
String _stripComments(String src) {
  final noBlocks = src.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), ' ');
  return noBlocks
      .split('\n')
      .map((line) => line.replaceAll(RegExp(r'//.*$'), ''))
      .join('\n');
}

String _read(Directory root, String relative) {
  try {
    return File('${root.path}/$relative').readAsStringSync();
  } catch (_) {
    return '';
  }
}

// ── 故意写坏的实现：只用于「同一判据会不通过」的反向对照 ──────────────
const double _badFraction = 0.25;
const int _badDurationMs = 0;

bool _badAllowJump(ReaderJumpOrigin origin) => true;

bool _badEndNav({
  required bool enabled,
  required bool hasChapters,
  required bool seamless,
  required int imageCount,
  required bool imagesLoaded,
}) {
  if (!enabled || !hasChapters || seamless) return false;
  // 「图片没加载完 / 空章节就不给出口」= 删掉隐式跳章后把用户困在章末。
  return imagesLoaded && imageCount > 0;
}

bool _badLayout({
  required Object? setting,
  required bool desktopPlatform,
  required double windowWidth,
}) {
  // 无视设置值，一律按平台硬判断 = T2 明确禁止的写法。
  return desktopPlatform;
}

bool _near(double a, double b) => (a - b).abs() < 1e-9;

/// 供 `reader-ux-check` 调用。返回断言数由调用方从 sink 统计。
void runP56Checks(_CheckSink check, {required Directory packageRoot}) {
  // ── 1. 步长 / 动画 ────────────────────────────────────────────────
  bool jFraction(double v) => _near(v, 0.5);
  _pair(
    check,
    'reader.turn_fraction',
    jFraction(kReaderTurnFraction),
    jFraction(_badFraction),
    'P56 方案 A：0.5 视口；故障值 0.25 必须被判据拒绝',
  );
  _pair(
    check,
    'reader.turn_duration_ms',
    kReaderTurnDurationMs == 200,
    _badDurationMs == 200,
    '200ms Curves.ease；故障值 0ms 必须被拒绝',
  );
  bool jDelta(double v) => _near(v, 379.0); // 758 * 0.5（comix 实测视口）
  _pair(
    check,
    'reader.turn_delta_forward',
    jDelta(
      readerTurnDelta(
        viewportExtent: 758,
        action: ReaderKeyAction.turnForward,
      ),
    ),
    jDelta(758 * _badFraction),
    '空格/↓ 在 758 视口下位移 +379',
  );
  _pair(
    check,
    'reader.turn_delta_backward',
    _near(
      readerTurnDelta(
        viewportExtent: 758,
        action: ReaderKeyAction.turnBackward,
      ),
      -379.0,
    ),
    _near(-758 * _badFraction, -379.0),
    '↑ 在 758 视口下位移 -379',
  );
  bool jInert(double v) => v == 0;
  _pair(
    check,
    'reader.turn_delta_inert',
    jInert(
      readerTurnDelta(
        viewportExtent: 758,
        action: ReaderKeyAction.nextChapter,
      ),
    ),
    jInert(379.0),
    '切章动作不产生滚动位移；坏实现若滚了半屏必须被拒绝',
  );
  bool jInvalidExtent(List<double> xs) =>
      xs.length == 2 && xs.every((v) => v == 0);
  _pair(
    check,
    'reader.turn_delta_invalid_extent',
    jInvalidExtent(<double>[
      readerTurnDelta(
        viewportExtent: 0,
        action: ReaderKeyAction.turnForward,
      ),
      readerTurnDelta(
        viewportExtent: double.nan,
        action: ReaderKeyAction.turnForward,
      ),
    ]),
    jInvalidExtent(<double>[379.0, 0]),
    '视口为 0 / NaN 时不得产生 NaN 位移',
  );

  // ── 2. 桌面快捷键表 ──────────────────────────────────────────────
  ReaderKeyAction real(String key, {bool shift = false}) => readerKeyAction(
    key: key,
    desktopLayout: true,
    shiftHeld: shift,
  );
  // 🔴 键表的反向对照**不能**用「P56 之前的旧实现」：↑↓/W/S 在旧实现里
  // 本来就是翻页，喂给判据与真实现同值，区分不出判据是不是装饰品。
  // 改成把判据显式函数化，再喂一个「确定不等于期望」的错误值。
  bool jKey(ReaderKeyAction got, ReaderKeyAction want) => got == want;
  ReaderKeyAction wrongFor(ReaderKeyAction want) =>
      want == ReaderKeyAction.none
          ? ReaderKeyAction.turnForward
          : ReaderKeyAction.none;

  void keyPair(String name, String key, ReaderKeyAction want, {bool shift = false}) {
    _pair(
      check,
      name,
      jKey(real(key, shift: shift), want),
      jKey(wrongFor(want), want),
      '$key → $want (shift=$shift)',
    );
  }

  keyPair('reader.key_space', 'space', ReaderKeyAction.turnForward);
  keyPair('reader.key_arrow_down', 'arrowDown', ReaderKeyAction.turnForward);
  keyPair('reader.key_arrow_up', 'arrowUp', ReaderKeyAction.turnBackward);
  keyPair('reader.key_w', 'w', ReaderKeyAction.turnBackward);
  keyPair('reader.key_s', 's', ReaderKeyAction.turnForward);
  keyPair('reader.key_arrow_left', 'arrowLeft', ReaderKeyAction.prevChapter);
  keyPair('reader.key_arrow_right', 'arrowRight', ReaderKeyAction.nextChapter);
  keyPair('reader.key_a', 'a', ReaderKeyAction.prevChapter);
  keyPair('reader.key_d', 'd', ReaderKeyAction.nextChapter);
  keyPair(
    'reader.key_shift_left',
    'arrowLeft',
    ReaderKeyAction.prevChapter,
    shift: true,
  );
  keyPair(
    'reader.key_shift_right',
    'arrowRight',
    ReaderKeyAction.nextChapter,
    shift: true,
  );
  const inert = ReaderKeyAction.none;
  _pair(
    check,
    'reader.key_shift_other_inert',
    jKey(real('arrowDown', shift: true), inert),
    jKey(wrongFor(inert), inert),
    'Shift+↓ 不接管，交回原映射',
  );
  _pair(
    check,
    'reader.key_mobile_falls_back',
    jKey(readerKeyAction(key: 'arrowLeft', desktopLayout: false), inert),
    jKey(wrongFor(inert), inert),
    '移动端布局返回 none，由原阅读方向映射接管',
  );
  _pair(
    check,
    'reader.key_unknown_inert',
    jKey(real('f7'), inert),
    jKey(wrongFor(inert), inert),
    '未登记按键不接管',
  );

  bool helpSupported(List<String> keys) {
    if (keys.isEmpty) return false; // 空结果判 FAIL（A02 §7 第 1 条）
    for (final key in keys) {
      final action = key.startsWith('shift+')
          ? real(key.substring(6), shift: true)
          : real(key);
      if (action == ReaderKeyAction.none) return false;
    }
    return true;
  }

  _pair(
    check,
    'reader.help_documented_keys_supported',
    helpSupported(kReaderHelpDocumentedKeys),
    helpSupported(<String>[...kReaderHelpDocumentedKeys, 'ctrl+z']),
    '帮助声明的 ${kReaderHelpDocumentedKeys.length} 个按键逐个喂真映射；'
        '混入未接管键必须被拒绝',
  );

  // ── 3. 章节跳转守卫 ──────────────────────────────────────────────
  const implicitOrigins = <ReaderJumpOrigin>[
    ReaderJumpOrigin.galleryEdge,
    ReaderJumpOrigin.continuousOverscroll,
    ReaderJumpOrigin.autoScrollEnd,
    ReaderJumpOrigin.unknown,
  ];
  const explicitOrigins = <ReaderJumpOrigin>[
    ReaderJumpOrigin.chapterEndCard,
    ReaderJumpOrigin.capsule,
    ReaderJumpOrigin.chapterList,
    ReaderJumpOrigin.keyboard,
  ];
  bool allDenied(List<bool> xs) => xs.isNotEmpty && xs.every((x) => !x);
  bool allAllowed(List<bool> xs) => xs.isNotEmpty && xs.every((x) => x);
  _pair(
    check,
    'reader.jump_implicit_denied',
    allDenied(implicitOrigins.map(allowReaderChapterJump).toList()),
    allDenied(implicitOrigins.map(_badAllowJump).toList()),
    'gallery 哨兵页 / 连续过拉 / 自动滚动到底 三处一律不自动跳章',
  );
  _pair(
    check,
    'reader.jump_explicit_allowed',
    allAllowed(explicitOrigins.map(allowReaderChapterJump).toList()),
    allAllowed(explicitOrigins.map((_) => false).toList()),
    '章末双卡 / 右上胶囊 / 章节列表 点击才换章',
  );

  // ── 4. 章末双卡「始终可达」 ──────────────────────────────────────
  final combos = <List<bool>>[];
  for (final count in <int>[0, 1, 17]) {
    for (final loaded in <bool>[false, true]) {
      combos.add(<bool>[
        shouldShowChapterEndNavInFlow(
          enabled: true,
          hasChapters: true,
          seamless: false,
          imageCount: count,
          imagesLoaded: loaded,
        ),
        _badEndNav(
          enabled: true,
          hasChapters: true,
          seamless: false,
          imageCount: count,
          imagesLoaded: loaded,
        ),
      ]);
    }
  }
  bool allReachable(int column) =>
      combos.length == 6 && combos.every((row) => row[column]);
  _pair(
    check,
    'reader.chapter_end_always_reachable',
    allReachable(0),
    allReachable(1),
    '图片 0/1/17 页 × 已加载/未加载 共 6 组，真实现必须全 true；'
        '依赖加载态的故障实现必须至少一组 false',
  );
  const baseEnd = <String, Object>{
    'enabled': true,
    'hasChapters': true,
    'seamless': false,
    'imageCount': 3,
    'imagesLoaded': true,
  };
  _pair(
    check,
    'reader.chapter_end_switch_off',
    !shouldShowChapterEndNavInFlow(
      enabled: false,
      hasChapters: true,
      seamless: false,
      imageCount: 3,
      imagesLoaded: true,
    ),
    _badEndNav(
      enabled: false,
      hasChapters: true,
      seamless: false,
      imageCount: 3,
      imagesLoaded: true,
    ),
    '设置关掉后不插入卡片',
  );
  _pair(
    check,
    'reader.chapter_end_no_chapters',
    !shouldShowChapterEndNavInFlow(
      enabled: true,
      hasChapters: false,
      seamless: false,
      imageCount: 3,
      imagesLoaded: true,
    ),
    _badEndNav(
      enabled: true,
      hasChapters: false,
      seamless: false,
      imageCount: 3,
      imagesLoaded: true,
    ),
    '单话漫画没有章节列表时不插入卡片',
  );
  _pair(
    check,
    'reader.chapter_end_seamless_off',
    !shouldShowChapterEndNavInFlow(
      enabled: true,
      hasChapters: true,
      seamless: true,
      imageCount: 3,
      imagesLoaded: true,
    ),
    _badEndNav(
      enabled: true,
      hasChapters: true,
      seamless: true,
      imageCount: 3,
      imagesLoaded: true,
    ),
    '无缝跨章模式不打断内容流（出口由右上胶囊提供）',
  );
  // 防「参数根本没被读到」的假绿：真实现必须对所有 imageCount 给出同一答案。
  bool jIndependent(bool Function(int count, bool loaded) fn) =>
      fn(0, false) == fn(999, true);
  bool realEnd(int count, bool loaded) => shouldShowChapterEndNavInFlow(
    enabled: true,
    hasChapters: true,
    seamless: false,
    imageCount: count,
    imagesLoaded: loaded,
  );
  bool brokenEnd(int count, bool loaded) => _badEndNav(
    enabled: true,
    hasChapters: true,
    seamless: false,
    imageCount: count,
    imagesLoaded: loaded,
  );
  _pair(
    check,
    'reader.chapter_end_independent_of_image_state',
    jIndependent(realEnd),
    jIndependent(brokenEnd),
    'base=$baseEnd；结果必须与图片数/加载态无关',
  );

  // ── 5. readerLayoutMode 三值推断 ─────────────────────────────────
  _pair(
    check,
    'reader.layout_parse',
    parseReaderLayoutSetting('desktop') == ReaderLayoutSetting.desktop &&
        parseReaderLayoutSetting('mobile') == ReaderLayoutSetting.mobile &&
        parseReaderLayoutSetting('auto') == ReaderLayoutSetting.auto &&
        parseReaderLayoutSetting(null) == ReaderLayoutSetting.auto &&
        parseReaderLayoutSetting('garbage') == ReaderLayoutSetting.auto,
    parseReaderLayoutSetting('mobile') == ReaderLayoutSetting.desktop,
    'desktop/mobile/auto/未知值 → auto',
  );
  bool layout(Object? s, bool platform, double width) => isDesktopReaderLayout(
    setting: s,
    desktopPlatform: platform,
    windowWidth: width,
  );
  _pair(
    check,
    'reader.layout_auto_desktop',
    layout('auto', true, 1488),
    false,
    'auto + Windows 桌面 + 1488 宽 → 桌面布局',
  );
  _pair(
    check,
    'reader.layout_auto_narrow',
    !layout('auto', true, 600),
    layout('auto', true, 600),
    'auto + 600 宽 → 移动布局（避免窄窗控件互挤）',
  );
  _pair(
    check,
    'reader.layout_auto_mobile_platform',
    !layout('auto', false, 1488),
    layout('auto', false, 1488),
    'auto + 非桌面平台 → 移动布局',
  );
  _pair(
    check,
    'reader.layout_force_desktop',
    layout('desktop', false, 600),
    !layout('desktop', false, 600),
    '显式 desktop 不受平台/窗宽覆盖',
  );
  _pair(
    check,
    'reader.layout_force_mobile',
    !layout('mobile', true, 1488),
    layout('mobile', true, 1488),
    '显式 mobile 不受平台/窗宽覆盖',
  );
  // 期望「显式 mobile 时不是桌面布局」；故障实现只看平台会给出相反答案。
  _pair(
    check,
    'reader.layout_platform_hardcode_rejected',
    !layout('mobile', true, 1488),
    !_badLayout(
      setting: 'mobile',
      desktopPlatform: true,
      windowWidth: 1488,
    ),
    '故障实现「只看 App.isDesktop」必须被判据拒绝',
  );

  // ── 5b. 缩放百分比读数 ──────────────────────────────────────────
  // 判据取「同一 ph 标下 1x 必须报 100%」：gallery 的 base 是合页宽后的
  // 比例（0.42），一旦有人把绝对 scale 直接当百分比，满屏会报 42%。
  bool zoomPercentReadsFit(num Function(double?, double?) f) =>
      f(0.42, 0.42) == 100 &&
      f(0.63, 0.42) == 150 &&
      f(2.5, 1.0) == 250 &&
      f(null, 0.42) == 100;
  _pair(
    check,
    'reader.zoom_percent_relative_to_fit',
    zoomPercentReadsFit(zoomPercentOf),
    // 故障实现 = 旧写法：绝对 scale × 100（也就是输入框预填用的那个错值）。
    zoomPercentReadsFit((s, b) => ((s ?? 1.0) * 100).roundToDouble()),
    '缩放读数必须相对 1x：0.42/0.42→100%、0.63/0.42→150%；'
        '用绝对 scale 的写法在 gallery 满屏时只报 42%',
  );

  // ── 6. 源码接线（剥注释后扫描） ──────────────────────────────────
  final readerSrc = _stripComments(_read(packageRoot, 'lib/pages/reader/reader.dart'));
  final imagesSrc = _stripComments(_read(packageRoot, 'lib/pages/reader/images.dart'));
  final scaffoldSrc = _stripComments(
    _read(packageRoot, 'lib/pages/reader/scaffold.dart'),
  );
  final helpSrc = _stripComments(
    _read(packageRoot, 'lib/pages/reader/help_dialog.dart'),
  );
  final gestureSrc = _stripComments(
    _read(packageRoot, 'lib/pages/reader/gesture.dart'),
  );
  final appdataSrc = _stripComments(_read(packageRoot, 'lib/foundation/appdata.dart'));
  final syncSrc = _stripComments(_read(packageRoot, 'lib/utils/sync_skip.dart'));
  final settingsSrc = _stripComments(
    _read(packageRoot, 'lib/pages/settings/reader.dart'),
  );
  final translationSrc = _read(packageRoot, 'assets/translation.json');

  final sources = <String, String>{
    'reader.dart': readerSrc,
    'images.dart': imagesSrc,
    'scaffold.dart': scaffoldSrc,
    'help_dialog.dart': helpSrc,
    'gesture.dart': gestureSrc,
    'appdata.dart': appdataSrc,
    'sync_skip.dart': syncSrc,
    'settings/reader.dart': settingsSrc,
    'translation.json': translationSrc,
  };
  bool jSources(Map<String, String> m) =>
      m.length == 9 && m.values.every((s) => s.length > 1000);
  _pair(
    check,
    'reader.wiring_sources_present',
    jSources(sources),
    jSources(<String, String>{...sources, 'reader.dart': ''}),
    '9 份源文件必须真实读到且非空；缺一份的故障副本必须被拒绝',
  );

  bool jKeyPolicy(String r, String i) =>
      r.contains('readerKeyAction(') &&
      r.contains('allowReaderChapterJump') &&
      i.contains('readerTurnDelta(');
  _pair(
    check,
    'reader.wiring_key_policy_used',
    jKeyPolicy(readerSrc, imagesSrc),
    jKeyPolicy('library;', 'library;'),
    '纯策略层必须被键盘总入口与连续模式真实调用，不能是摆设',
  );
  bool jSpaceWired(String r, String i) =>
      r.contains('LogicalKeyboardKey.space') &&
      r.contains("'space'") &&
      i.contains('handleReaderAction(');
  _pair(
    check,
    'reader.wiring_space_explicit',
    jSpaceWired(readerSrc, imagesSrc),
    jSpaceWired(
      readerSrc.replaceAll('LogicalKeyboardKey.space', 'LogicalKeyboardKey.f7'),
      imagesSrc,
    ),
    '空格必须显式接管（P56 前 lib/ 全库零命中）',
  );
  bool noImplicitJump(String images, String gesture) =>
      images.length > 1000 &&
      gesture.length > 1000 &&
      images.contains('_ContinuousModeState') &&
      gesture.contains('onMouseWheel') &&
      !images.contains('reader.toNextChapter(') &&
      !images.contains('reader.toPrevChapter(') &&
      !gesture.contains('reader.toNextChapter(') &&
      !gesture.contains('reader.toPrevChapter(');
  _pair(
    check,
    'reader.wiring_no_implicit_jump',
    noImplicitJump(imagesSrc, gestureSrc),
    noImplicitJump(
      '$imagesSrc\n    reader.toNextChapter();\n',
      gestureSrc,
    ),
    'gallery 哨兵页 / 连续过拉 / 自动滚动到底 / 滚轮越界 四处隐式跳章'
        '调用必须清零；注入一行即须变红',
  );
  bool jNoFloating(String src) =>
      src.length > 1000 &&
      !src.contains('buildEpChangeButton') &&
      !src.contains('showFloatingButtonValue');
  _pair(
    check,
    'reader.wiring_no_floating_button',
    jNoFloating(scaffoldSrc),
    jNoFloating('$scaffoldSrc\nWidget buildEpChangeButton() {}\n'),
    '右下 58×58 浮动箭头按钮与其驱动状态必须删除',
  );
  bool jChapterEndFlow(String src) =>
      src.contains('isChapterEnd') &&
      src.contains('shouldShowChapterEndNavInFlow(') &&
      src.contains('ChapterEndNavCards');
  _pair(
    check,
    'reader.wiring_chapter_end_flow',
    jChapterEndFlow(imagesSrc),
    jChapterEndFlow('library;'),
    '连续模式章末双卡必须是内容流条目（Sliver），不是 Overlay/浮层',
  );
  bool jDesktopControls(String src) =>
      src.contains('isDesktopReaderLayout(') &&
      src.contains('ChapterCapsule()') &&
      src.contains('ReaderZoomBar(') &&
      src.contains('showDialog(');
  _pair(
    check,
    'reader.wiring_desktop_controls',
    jDesktopControls(scaffoldSrc),
    jDesktopControls('library;'),
    '右上胶囊 / 右下缩放簇 / 居中模态章节列表都挂到桌面布局开关上',
  );
  bool jHelpAligned(String src) =>
      src.contains('kReaderHelpDocumentedKeys') &&
      src.contains('Scroll down half a viewport') &&
      src.contains('Turn page (gallery)') &&
      !src.contains('A D / W S') &&
      !src.contains('Shift + ← →');
  _pair(
    check,
    'reader.wiring_help_aligned',
    jHelpAligned(helpSrc),
    jHelpAligned('$helpSrc\n_HelpEntry("A D / W S", "Turn page"),\n'),
    '帮助与实现逐条对齐；P47 的 A D / W S 虚标必须清掉',
  );

  // ── 7. i18n 与设置四件套 ────────────────────────────────────────
  const newI18nKeys = <String>[
    'Reader layout',
    'Desktop layout',
    'Mobile layout',
    'Scroll down half a viewport',
    'Chapter list',
  ];
  Map<String, dynamic>? translations;
  try {
    translations = jsonDecode(translationSrc) as Map<String, dynamic>;
  } catch (_) {
    translations = null;
  }
  bool i18nRegistered(dynamic raw) {
    if (raw is! Map || newI18nKeys.isEmpty) return false;
    for (final locale in <String>['zh_CN', 'zh_TW']) {
      final table = raw[locale];
      if (table is! Map) return false;
      for (final key in newI18nKeys) {
        final value = table[key];
        if (value is! String || value.trim().isEmpty) return false;
      }
    }
    return true;
  }

  dynamic brokenTranslations;
  if (translations != null && translations['zh_TW'] is Map) {
    final tw = Map<String, dynamic>.from(translations['zh_TW'] as Map);
    tw.remove(newI18nKeys.first);
    brokenTranslations = <String, dynamic>{...translations, 'zh_TW': tw};
  }
  _pair(
    check,
    'reader.i18n_keys_registered',
    i18nRegistered(translations),
    i18nRegistered(brokenTranslations),
    '${newI18nKeys.length} 条新文案必须在 zh_CN + zh_TW 双语登记；'
        '删掉任一条的故障副本必须被拒绝',
  );
  bool jSetting(String src, String needle) =>
      src.length > 1000 && src.contains(needle);
  _pair(
    check,
    'reader.setting_default_registered',
    jSetting(appdataSrc, "'readerLayoutMode': 'auto'"),
    jSetting('library;', "'readerLayoutMode': 'auto'"),
    'appdata 默认值 auto（不硬绑平台）',
  );
  _pair(
    check,
    'reader.setting_sync_skip',
    jSetting(syncSrc, '"readerLayoutMode"'),
    jSetting('library;', '"readerLayoutMode"'),
    '新 key 进 sync_skip 白名单（reading 分类）',
  );
  _pair(
    check,
    'reader.setting_ui_entry',
    jSetting(settingsSrc, 'settingKey: "readerLayoutMode"'),
    jSetting('library;', 'settingKey: "readerLayoutMode"'),
    '阅读设置界面有可切换的三值下拉',
  );
}

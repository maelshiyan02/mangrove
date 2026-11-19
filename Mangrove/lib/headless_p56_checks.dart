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

import 'package:mangrove/foundation/chapter_directory.dart';
import 'package:mangrove/foundation/chapter_title_parser.dart';
import 'package:mangrove/foundation/comment_order_policy.dart';
import 'package:mangrove/foundation/comic_source/comic_source.dart';
import 'package:mangrove/foundation/local_details_policy.dart';
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

/// 从（已剥注释的）源码里取出一个顶层类的整段正文，找不到返回空串。
///
/// 用于「同一文件里有多个同类页面」的逐类断言：文件级 `contains` 会被
/// 一个接好的类喂绿，掩盖另一个没接的类（P66 实证：章节评论页接了排序，
/// 内嵌评论页没接，文件级断言却 PASS）。切分锚点只认行首的顶层声明关键字，
/// 类体内的缩进 `class` 不会被误当成边界。
String _topLevelClassBody(String src, String name) {
  final start = RegExp('^class $name\\b', multiLine: true).firstMatch(src);
  if (start == null) return '';
  final from = start.start;
  final rest = src.substring(start.end);
  final next = RegExp(r'^class \w', multiLine: true).firstMatch(rest);
  return next == null
      ? src.substring(from)
      : src.substring(from, start.end + next.start);
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

// ==== P64：单击 / 长按空格 + 焦点自愈 + 评论接线 ====
//
// 这几条判据的共同前提：**手感**（真滚起来顺不顺、急刹是否跟手）只能在 GUI
// 会话里目视确认（A01 §3）；这里钉住的是「参数与接线」，即"改动真的落地了、
// 而且落地的是这个策略"——源码被改回旧行为、或参数被换成不分单击长按的一档，
// 对应断言必须变红。

/// 故意写坏的长按速度：没有单击窗口，且恒定 —— 用它证明判据真能区分两种手感。
double _badHoldSpeed(Duration held) => 2.0;

double _holdDistance(Duration total, {double viewport = 1000}) {
  const tick = Duration(milliseconds: 16);
  var sum = 0.0;
  for (var t = Duration.zero; t < total; t += tick) {
    sum += readerHoldDelta(held: t, tick: tick, viewportExtent: viewport);
  }
  return sum;
}

void runP64Checks(_CheckSink check, {required Directory packageRoot}) {
  const tick = Duration(milliseconds: 16);

  // ── 1. 单击窗口内不许有长按位移 ────────────────────────────────
  final tapWindow = kReaderHoldTriggerDelay - const Duration(milliseconds: 1);
  _pair(
    check,
    'reader.hold_zero_within_tap_window',
    readerHoldSpeed(tapWindow) == 0 && _holdDistance(tapWindow) == 0,
    _badHoldSpeed(tapWindow) == 0,
    '阈值前推 0px（单击仍是"一次半屏缓动"，不是"按住 1px 也算长按"）',
  );

  // ── 2. 越过阈值立刻起速，且单调不减 ────────────────────────────
  final samples = <double>[
    for (var ms = 0; ms <= 1600; ms += 40)
      readerHoldSpeed(kReaderHoldTriggerDelay + Duration(milliseconds: ms)),
  ];
  bool nonDecreasing(List<double> values) {
    for (var i = 1; i < values.length; i++) {
      if (values[i] + 1e-9 < values[i - 1]) return false;
    }
    return true;
  }

  // 🔴 「单调不减」对恒定速度也成立 —— 必须再要求**至少一处真增**，否则
  // 把速度写成一个常数照样能骗过判据（第一版就是这么假绿的）。
  bool strictIncrease(List<double> values) {
    for (var i = 1; i < values.length; i++) {
      if (values[i] > values[i - 1] + 1e-9) return true;
    }
    return false;
  }

  final badSamples = <double>[
    for (var ms = 0; ms <= 1600; ms += 40) _badHoldSpeed(Duration(milliseconds: ms)),
  ];
  _pair(
    check,
    'reader.hold_speed_monotonic',
    nonDecreasing(samples) && strictIncrease(samples) && samples.first > 0,
    nonDecreasing(badSamples) && strictIncrease(badSamples),
    '2s 内单调不减 + 至少一处真增 + 起步 > 0；恒定速度必须被拒',
  );

  // ── 3. 加速到满速后封顶 ────────────────────────────────────────
  final capped = readerHoldSpeed(
    kReaderHoldTriggerDelay + kReaderHoldRampUp + const Duration(seconds: 2),
  );
  _pair(
    check,
    'reader.hold_speed_capped',
    (capped - kReaderHoldMaxSpeed).abs() < 1e-9 && capped > kReaderHoldStartSpeed,
    (_badHoldSpeed(const Duration(seconds: 3)) - kReaderHoldMaxSpeed).abs() < 1e-9,
    '满速 = $kReaderHoldMaxSpeed 视口/秒，且严格快于起步 $kReaderHoldStartSpeed',
  );

  // ── 4. 长按比单击快：1 秒长按 > 2 次单击 ───────────────────────
  final oneSecondHold = _holdDistance(const Duration(seconds: 1));
  final twoTaps = 2 * (1000 * kReaderTurnFraction);
  _pair(
    check,
    'reader.hold_faster_than_taps',
    oneSecondHold > twoTaps,
    _holdDistance(const Duration(seconds: 1)) <= 0,
    '1s 长按推进 ${oneSecondHold.toStringAsFixed(0)}px > 2 次单击 ${twoTaps.toStringAsFixed(0)}px',
  );

  // ── 5. 速度与视口成比例（不同窗口尺寸不改变手感） ───────────────
  final wide = _holdDistance(const Duration(seconds: 1), viewport: 2000);
  _pair(
    check,
    'reader.hold_scales_with_viewport',
    (wide - oneSecondHold * 2).abs() < 1e-6,
    (wide - oneSecondHold).abs() < 1e-6,
    '2000 视口的位移恰为 1000 视口的两倍（步长按视口比例给，不写死像素）',
  );

  // ── 6. 源码接线：按下起算、松开判定，且不再直接吃系统重复 ─────────
  final readerSrc = _stripComments(
    _read(packageRoot, 'lib/pages/reader/reader.dart'),
  );
  final gestureSrc = _stripComments(
    _read(packageRoot, 'lib/pages/reader/gesture.dart'),
  );
  final toolbarSrc = _stripComments(
    _read(packageRoot, 'lib/pages/reader/side_toolbar.dart'),
  );
  final hubSrc = _stripComments(
    _read(packageRoot, 'lib/pages/comic_details_page/comments_hub.dart'),
  );
  final commentsSrc = _stripComments(
    _read(packageRoot, 'lib/pages/comic_details_page/comments_page.dart'),
  );
  final actionsSrc = _stripComments(
    _read(packageRoot, 'lib/pages/comic_details_page/actions.dart'),
  );

  bool wired(String src, String needle) => src.length > 500 && src.contains(needle);

  _pair(
    check,
    'reader.hold_keydown_keyup_split',
    wired(readerSrc, '_beginHold(action)') &&
        wired(readerSrc, '_endHold();') &&
        wired(readerSrc, 'Timer.periodic(kReaderHoldTick'),
    wired('library;', '_beginHold(action)'),
    'KeyDown 只起算（_beginHold），KeyUp 才判定单击/长按（_endHold），推进由 16ms ticker 负责',
  );
  _pair(
    check,
    'reader.hold_ignores_os_repeat',
    !wired(readerSrc, 'event is KeyDownEvent || event is KeyRepeatEvent'),
    wired(readerSrc, 'event is KeyDownEvent || event is KeyRepeatEvent'),
    '旧的"KeyDown/KeyRepeat 直接翻页"必须删净：系统重复与自己的 ticker 叠加会忽快忽慢',
  );
  _pair(
    check,
    'reader.hold_self_brake_on_focus_loss',
    wired(readerSrc, 'if (!focusNode.hasFocus) {') &&
        wired(readerSrc, 'kReaderHoldMaxDuration'),
    wired('library;', 'kReaderHoldMaxDuration'),
    '焦点被抢走 / 超过安全上限时自己刹车，避免 KeyUp 丢失后页面一路滚到底',
  );

  // ── 7. 焦点自愈真的接在指针上 ─────────────────────────────────
  _pair(
    check,
    'reader.focus_self_heal_wired',
    wired(readerSrc, 'FocusManager.instance.addListener(_onFocusManagerChanged)') &&
        wired(readerSrc, 'void ensureReaderFocus()') &&
        wired(gestureSrc, 'reader.ensureReaderFocus();'),
    wired('library;', 'void ensureReaderFocus()'),
    '弹层关闭后焦点落空必须自动归还：FocusManager 监听 + 指针按下两处都接上',
  );

  // ── 7b. 焦点自愈守卫的真值表（纯函数，直接喂四种"焦点现场"） ────────
  // 只验源码接线是不够的：条件写反了照样能通过 contains。这里把 4 种现场
  // 直接喂进纯函数，并要求"该补的补、不该补的一律不动"。
  bool guard({
    bool routeIsCurrent = true,
    bool hasFocus = false,
    bool editableFocused = false,
    bool primaryIsBareScope = true,
  }) =>
      shouldReaderRestoreFocus(
        routeIsCurrent: routeIsCurrent,
        hasFocus: hasFocus,
        editableFocused: editableFocused,
        primaryIsBareScope: primaryIsBareScope,
      );

  // 故障实现：只看"我自己有没有焦点"，其余全忽略（最容易写出来的那种）。
  bool badGuard({
    bool routeIsCurrent = true,
    bool hasFocus = false,
    bool editableFocused = false,
    bool primaryIsBareScope = true,
  }) =>
      !hasFocus;

  final truthTableOk = guard() &&
      !guard(hasFocus: true) &&
      !guard(routeIsCurrent: false) &&
      !guard(primaryIsBareScope: false) &&
      !guard(editableFocused: true);
  final badTruthTableOk = badGuard() &&
      !badGuard(hasFocus: true) &&
      !badGuard(routeIsCurrent: false) &&
      !badGuard(primaryIsBareScope: false) &&
      !badGuard(editableFocused: true);
  _pair(
    check,
    'reader.focus_guard_truth_table',
    truthTableOk,
    badTruthTableOk,
    '只在「路由当前 + 自己没焦点 + 不是输入框 + primary 是裸 Scope」时补；'
        '其余四种一律不动（少一个条件就是抢焦点）',
  );
  _pair(
    check,
    'reader.focus_guard_wired',
    wired(readerSrc, 'shouldReaderRestoreFocus('),
    !wired(readerSrc, 'shouldReaderRestoreFocus('),
    'ensureReaderFocus 必须走这个纯函数，不能在 widget 里另写一套条件',
  );

  // ── 8. 右缘工具栏评论 = 当前章节，不再是占位 ────────────────────
  _pair(
    check,
    'reader.comments_toolbar_wired',
    wired(toolbarSrc, 'reader.openChapterComments') &&
        !wired(toolbarSrc, 'Comments coming soon'),
    wired(toolbarSrc, 'Comments coming soon'),
    '评论按钮接 openChapterComments，占位提示必须消失',
  );
  _pair(
    check,
    'reader.comments_uses_current_chapter',
    wired(readerSrc, 'chapterCommentsLoader == null') &&
        wired(readerSrc, 'chapters.ids.elementAt(chapter - 1)') &&
        wired(readerSrc, 'ChapterCommentsPage('),
    wired('library;', 'chapters.ids.elementAt(chapter - 1)'),
    '进门就取当前话的 epId（不是作品 id，也不是第 1 话）',
  );

  // ── 9. 详情页评论中心：双分类 + 章节选择 ───────────────────────
  _pair(
    check,
    'detail.comments_hub_has_two_tabs',
    wired(hubSrc, 'ButtonSegment(') &&
        wired(hubSrc, 'epId: current.id') &&
        wired(actionsSrc, 'CommentsHubPage(data: comic, source: source)'),
    wired('library;', 'CommentsHubPage(data: comic, source: source)'),
    '作品评论 / 章节评论两个分栏，章节分栏把 epId 透给同一套列表渲染',
  );
  _pair(
    check,
    'detail.comments_hub_chapter_picker',
    wired(hubSrc, 'showDialog<int>') && wired(hubSrc, 'controller.text.trim()'),
    wired('library;', 'showDialog<int>'),
    '章节选择器可搜索（上百话时纯下拉不可用）',
  );
  _pair(
    check,
    'detail.comments_page_supports_ep',
    wired(commentsSrc, 'chapterCommentsLoader') &&
        wired(commentsSrc, 'sendChapterCommentFunc') &&
        wired(commentsSrc, 'if (widget.embedded) return body;'),
    wired('library;', 'if (widget.embedded) return body;'),
    '同一套列表既能独立成页、也能嵌进分栏；发送按钮按模式选 sendChapterCommentFunc',
  );

  // ── 10. 拷贝侧：章节留言走 App 接口，不是网页端 ─────────────────
  final copySrc = _read(packageRoot, '../comic_source/copy_manga(5).js');
  final copyRuntime = _read(packageRoot, '../data/comic_source/copy_manga(5).js');
  // 只看「loadChapterComments 这个函数体内用的是哪种通道」——整份文件里同时存在
  // 网页端接口（详情/章节的降级通道），拿全文 contains 当反向口会把两条通道混读。
  String between(String src, String from, String to) {
    final a = src.indexOf(from);
    if (a < 0) return '';
    final b = src.indexOf(to, a + from.length);
    if (b < 0) return '';
    return src.substring(a, b);
  }

  final chapterCommentsBody = between(
    copySrc,
    'loadChapterComments:',
    'sendChapterComment:',
  );
  _pair(
    check,
    'copy.chapter_comments_app_api',
    chapterCommentsBody.contains('/api/v3/roasts?chapter_id=') &&
        !chapterCommentsBody.contains('webBase'),
    chapterCommentsBody.isEmpty ||
        chapterCommentsBody.contains('/api/kb/web/'),
    '章节留言函数体里只有 App 端 roasts（网页端评论区是关的，只有手机 App 能看）',
  );
  _pair(
    check,
    'copy.runtime_copy_in_sync',
    copyRuntime.isNotEmpty && copyRuntime == copySrc,
    copyRuntime.isNotEmpty && copyRuntime != copySrc,
    'data/comic_source 是运行时真正加载的副本，必须与源文件逐字节一致',
  );
}

// ==== P65：章号胶囊实时刷新 + 评论时间排序 ====
//
// 章号 bug 的现场：点下一话后左下角已是「第163话」，右上角仍停在
// `Ch.162 / 229`。根因不是没切章，而是 const 胶囊只在父级碰巧 rebuild 时
// 才读一次章号 ⇒ 这里钉住「setter 推进 revision + 显示方订阅」这条契约。
void runP65Checks(_CheckSink check, {required Directory packageRoot}) {
  final cap162 = readerChapterCaption(162, 229);
  final cap163 = readerChapterCaption(163, 229);
  _pair(
    check,
    'reader.chapter_caption_tracks_number',
    cap162 == 'Ch.162 / 229' && cap163 == 'Ch.163 / 229' && cap162 != cap163,
    cap162 == cap163,
    '章号 162→163 时胶囊文案必须不同（故障=写死章号）',
  );

  final readerSrc = _stripComments(
    _read(packageRoot, 'lib/pages/reader/reader.dart'),
  );
  final capsuleSrc = _stripComments(
    _read(packageRoot, 'lib/pages/reader/chapter_capsule.dart'),
  );
  bool notifierWired(String src) =>
      src.contains('set chapter(int value)') &&
      src.contains('chapterRevision.value++') &&
      src.contains('chapterRevision.dispose()');
  bool capsuleWired(String src) =>
      src.contains('ValueListenableBuilder<int>') &&
      src.contains('chapterRevision') &&
      src.contains('readerChapterCaption(current, total)');
  _pair(
    check,
    'reader.chapter_revision_subscription',
    notifierWired(readerSrc) && capsuleWired(capsuleSrc),
    notifierWired('class Fake { int chapter = 1; }') &&
        capsuleWired('Text(chapter)'),
    '章号 setter 推进 revision、dispose 回收、胶囊订阅；故障=任一环节断开',
  );

  bool timeKeysOk(int? Function(String?) f) =>
      f('2026-11-11 13:05:48') != null &&
      f('1762851948') == 1762851948 * 1000000 &&
      f('1700000000123') == 1700000000123 * 1000 &&
      f('') == null &&
      f('not-a-time') == null;
  int? brokenTimeKey(String? _) => null;
  _pair(
    check,
    'comments.time_key_formats',
    timeKeysOk(commentTimeKey),
    timeKeysOk(brokenTimeKey),
    'ISO/秒/毫秒都要能比较，空串与非时间判未知; '
    'iso=${commentTimeKey('2026-11-11 13:05:48')} '
    'sec=${commentTimeKey('1762851948')} '
    'ms=${commentTimeKey('1700000000123')} '
    'empty=${commentTimeKey('')} bad=${commentTimeKey('not-a-time')}',
  );

  final times = [
    '2026-11-16 10:00:00',
    '2026-11-11 13:05:48',
    '2026-11-14 09:00:00',
  ];
  bool orderOk(List<int> Function(List<String?>, CommentOrder) f) {
    final old = f(times, CommentOrder.oldestFirst);
    final neu = f(times, CommentOrder.newestFirst);
    return old.length == 3 &&
        old[0] == 1 &&
        old[1] == 2 &&
        old[2] == 0 &&
        neu[0] == 0 &&
        neu[1] == 2 &&
        neu[2] == 1;
  }

  List<int> brokenOrder(List<String?> t, CommentOrder _) =>
      List<int>.generate(t.length, (i) => i);
  _pair(
    check,
    'comments.order_oldest_and_newest',
    orderOk(orderedCommentIndices),
    orderOk(brokenOrder),
    '三条真时间必须给出旧→新 [1,2,0] 与新→旧 [0,2,1]（故障=原序不动）',
  );

  final tieTimes = ['2026-11-11 10:00:00', 'not-a-time', '2026-11-11 10:00:00'];
  final stable = orderedCommentIndices(tieTimes, CommentOrder.oldestFirst);
  _pair(
    check,
    'comments.order_stable_when_unknown',
    stable.length == 3 && stable[0] == 0 && stable[1] == 2 && stable[2] == 1,
    brokenOrder(tieTimes, CommentOrder.oldestFirst).join(',') == stable.join(','),
    '同秒保原序、未知时间沉底；故障=原样返回 [0,1,2]',
  );

  bool firstPageOk(
    int Function({required int? maxPage, required CommentOrder order}) f,
  ) =>
      f(maxPage: 3, order: CommentOrder.oldestFirst) == 3 &&
      f(maxPage: 3, order: CommentOrder.newestFirst) == 1 &&
      f(maxPage: null, order: CommentOrder.oldestFirst) == 1;
  int brokenFirstPage({required int? maxPage, required CommentOrder order}) => 1;
  _pair(
    check,
    'comments.first_page_from_oldest',
    firstPageOk(commentFirstPage),
    firstPageOk(brokenFirstPage),
    '旧→新首屏从服务端最后一页开始（故障=永远 offset 0）',
  );

  bool nextPageOk(
    int? Function({
      required int page,
      required int? maxPage,
      required CommentOrder order,
    }) f,
  ) {
    final old = [
      f(page: 3, maxPage: 3, order: CommentOrder.oldestFirst),
      f(page: 2, maxPage: 3, order: CommentOrder.oldestFirst),
      f(page: 1, maxPage: 3, order: CommentOrder.oldestFirst),
    ];
    final neu = [
      f(page: 1, maxPage: 3, order: CommentOrder.newestFirst),
      f(page: 2, maxPage: 3, order: CommentOrder.newestFirst),
      f(page: 3, maxPage: 3, order: CommentOrder.newestFirst),
    ];
    final asText = (int? v) => v?.toString() ?? 'null';
    return old.map(asText).join(',') == '2,1,null' &&
        neu.map(asText).join(',') == '2,3,null';
  }

  int? brokenNextPage({
    required int page,
    required int? maxPage,
    required CommentOrder order,
  }) =>
      null;
  _pair(
    check,
    'comments.next_page_direction',
    nextPageOk(commentNextPage),
    nextPageOk(brokenNextPage),
    '旧→新往回翻页、新→旧往前翻页；故障=永远无下一页',
  );

  final detailSrc = _stripComments(
    _read(packageRoot, 'lib/pages/comic_details_page/comments_page.dart'),
  );
  final chapterSrc = _stripComments(
    _read(packageRoot, 'lib/pages/reader/chapter_comments.dart'),
  );
  bool commentPageWired(String src) =>
      src.contains('CommentOrder') &&
      src.contains('orderComments') &&
      src.contains('commentFirstPage') &&
      src.contains('commentNextPage') &&
      // 方法定义 + build() 里真实调用，两处都要在；只定义不挂等于没有排序条。
      'buildOrderBar'.allMatches(src).length >= 2 &&
      src.contains('_order = CommentOrder.oldestFirst');
  // P66：逐**类**取值，不再整份文件 contains —— 否则同一个文件里一个页面接好
  // 排序就会把没接的另一个页面喂绿。三处评论区任一没接都必须红。
  final detailState = _topLevelClassBody(detailSrc, '_CommentsPageState');
  final chapterState = _topLevelClassBody(chapterSrc, '_ChapterCommentsPageState');
  final embeddedState =
      _topLevelClassBody(chapterSrc, '_EmbeddedChapterCommentsPageState');
  _pair(
    check,
    'comments.both_pages_use_order_policy',
    commentPageWired(detailState) &&
        commentPageWired(chapterState) &&
        commentPageWired(embeddedState),
    commentPageWired('class Fake {}'),
    '作品/独立章节/章末内嵌三处评论页都接排序条与反向分页、默认旧→新'
    '（故障=空源码）; bodies=${[detailState.length, chapterState.length, embeddedState.length].join(",")}',
  );

  final tr = _read(packageRoot, 'assets/translation.json');
  _pair(
    check,
    'comments.order_labels_localized',
    tr.contains('"Oldest first"') &&
        tr.contains('"Newest first"') &&
        tr.contains('"从旧到新"') &&
        tr.contains('"从新到旧"'),
    !tr.contains('"Oldest first"'),
    '排序条两条文案必须进 translation.json（故障=缺键时界面露英文）; trLen=${tr.length}',
  );
}

/// P67 · 本地库漫画的旧章节列表与评论 500 修复（2026-11-18）。
///
/// 三条判据各自都是「纯策略真值 + 故障输入被拒」，并额外扫源码确认策略
/// 真的接到了详情页（防止只定义不调用）。故障注入只改策略函数体时，
/// 必须只红对应的一条，其余两条保持绿。
void runP67Checks(_CheckSink check, {required Directory packageRoot}) {
  const realSubId = '43415875-7d6d-11f0-9acf-fa163e4baef8';
  final detailSrc = _stripComments(
    _read(packageRoot, 'lib/pages/comic_details_page/comic_page.dart'),
  );

  // ① 本地模式评论参数：下载自源站的漫画必须带上在线 subId；纯本地不给。
  bool subIdWired(String src) =>
      src.contains("'subId': commentsSubIdForLocalDetails(");
  _pair(
    check,
    'local.comments_subid_from_online',
    commentsSubIdForLocalDetails(
          sourceKey: 'copy_manga',
          pureLocal: false,
          onlineSubId: realSubId,
        ) ==
        realSubId &&
        commentsSubIdForLocalDetails(
              sourceKey: 'copy_manga',
              pureLocal: false,
              onlineSubId: '  $realSubId  ',
            ) ==
            realSubId &&
        subIdWired(detailSrc),
    commentsSubIdForLocalDetails(
          sourceKey: 'copy_manga',
          pureLocal: true,
          onlineSubId: realSubId,
        ) ==
        realSubId ||
        commentsSubIdForLocalDetails(
              sourceKey: 'local',
              pureLocal: false,
              onlineSubId: realSubId,
            ) ==
            realSubId ||
        !subIdWired(detailSrc),
    '本地视图评论须带源站 subId（拷贝 comic_id），纯本地恒 null；'
    '故障=永远 null 或没接进 _localDetails',
  );

  // ② 缓存章节只增不减：本地 63 / 缓存 68 → 回填；反向不得覆盖。
  bool enrichWired(String src) =>
      'enrichFromCache'.allMatches(src).length >= 2;
  _pair(
    check,
    'local.cache_chapter_enrich',
    shouldEnrichFromCachedDetails(
          localChapterCount: 63,
          cachedChapterCount: 68,
        ) &&
        !shouldEnrichFromCachedDetails(
          localChapterCount: 68,
          cachedChapterCount: 63,
        ) &&
        enrichWired(detailSrc),
    !shouldEnrichFromCachedDetails(
          localChapterCount: 63,
          cachedChapterCount: 68,
        ) ||
        shouldEnrichFromCachedDetails(
          localChapterCount: 68,
          cachedChapterCount: 63,
        ) ||
        !enrichWired(detailSrc),
    '缓存比本地多才回填（63→68）；少则绝不覆盖本地；'
    '故障=永远不回填/反向覆盖/没接进 loadData',
  );

  // ③ 首帧缓存视图：缓存存在且非纯本地时用它合成网络视图。
  bool cachedViewWired(String src) =>
      'shouldUseCachedOnlineView'.allMatches(src).length >= 2;
  _pair(
    check,
    'local.cached_view_first_frame',
    shouldUseCachedOnlineView(
          sourceKey: 'copy_manga',
          hasCachedDetails: true,
        ) &&
        !shouldUseCachedOnlineView(
          sourceKey: 'local',
          hasCachedDetails: true,
        ) &&
        cachedViewWired(detailSrc),
    !shouldUseCachedOnlineView(
          sourceKey: 'copy_manga',
          hasCachedDetails: true,
        ) ||
        shouldUseCachedOnlineView(
          sourceKey: 'local',
          hasCachedDetails: true,
        ) ||
        !cachedViewWired(detailSrc),
    '缓存存在时首帧就给网络视图（否则 63 话+null subId 成终态）；'
    '纯本地不走；故障=缓存存在也拒绝/没接进 _composeDetails',
  );
}

/// P68：章节评论区「一直转圈」的根因（第 182 话：40 条吐槽 = 页大小的整数倍）。
///
/// 症状是三件事叠加出来的，少一条都不成立：
///   ① 源站 maxPage 用 `(total - total % 20) / 20 + 1`，总数整除 20 时**多算一页**
///      （40 条 → 3 页，实际只有 2 页）；
///   ② 旧→新首屏按 maxPage 请求尾页 → `offset=40` → 服务端返回空列表；
///   ③ 空列表让尾部加载指示器成为唯一可见项，它触发 loadMore，而 orderComments
///      当时返回定长列表，`addAll` 在 setState 回调里抛异常 → 页码不推进 →
///      每次重建再触发一次 → 无限请求 + 永久转圈。
///
/// 相邻章节（17/4/16 条）maxPage 都是 1，走不到②③，所以"只有这一话坏"。
void runP68Checks(_CheckSink check, {required Directory packageRoot}) {
  // ① 源脚本不得再用高估公式。
  final copyJs = _read(packageRoot, '../comic_source/copy_manga(5).js');
  final ceilHits = 'Math.ceil(total / 20)'.allMatches(copyJs).length;
  final staleFormula = copyJs.contains('(total - (total % 20)) / 20 + 1');
  _pair(
    check,
    'comments.maxpage_no_overestimate',
    copyJs.isNotEmpty && ceilHits >= 2 && !staleFormula,
    ceilHits == 0 || staleFormula,
    '作品评论与章节吐槽的 maxPage 都必须 ceil(total/20)；旧式 …/20 + 1 在 '
    'total%20==0 时多算一页（40→3 而实际 2），尾页请求必空。'
    'ceil=$ceilHits stale=$staleFormula',
  );

  // ② 排序产物必须可增长（loadMore 往尾部追加）。
  bool canAppend(List<String> list) {
    try {
      list.add('x');
      return true;
    } catch (_) {
      return false;
    }
  }

  final orderedSample = orderComments(
    <String>['newer', 'older'],
    CommentOrder.oldestFirst,
    (s) => s == 'older' ? '2026-01-01 00:00:00' : '2026-01-02 00:00:00',
  );
  _pair(
    check,
    'comments.order_list_growable',
    canAppend(orderedSample) &&
        orderedSample.length == 3 &&
        orderedSample.first == 'older',
    canAppend(<String>['a'].toList(growable: false)),
    'orderComments 的产物必须可增长；定长列表会让第二页 addAll 抛 '
    'fixed-length，异常发生在 setState 里 → 页码不推进 → 无限请求',
  );

  // ③ 尾页空时逐页回退。
  bool fallbackOk(int? Function(int, int) f) =>
      f(3, 0) == 2 &&
      f(2, 0) == 1 &&
      f(1, 0) == null &&
      f(9, kCommentPageFallbackLimit) == null;
  _pair(
    check,
    'comments.first_page_fallback',
    fallbackOk(
      (page, attempts) =>
          commentFallbackPage(page: page, attempts: attempts),
    ),
    fallbackOk((page, attempts) => null),
    '尾页拿回空列表时逐页回退（3→2→1），到第 1 页或超出预算即停；'
    '故障=永不回退（停在空列表+转圈）或无视预算一路退',
  );

  // ④ 空页之后必须停止再翻。
  bool nextPageOk(int? Function(int, int?, CommentOrder, bool) f) =>
      f(2, 5, CommentOrder.oldestFirst, true) == null &&
      f(2, 5, CommentOrder.oldestFirst, false) == 1 &&
      f(3, 3, CommentOrder.newestFirst, false) == null &&
      f(3, 5, CommentOrder.newestFirst, false) == 4;
  _pair(
    check,
    'comments.exhausted_stops_paging',
    nextPageOk(
      (page, maxPage, order, exhausted) => commentNextPage(
        page: page,
        maxPage: maxPage,
        order: order,
        exhausted: exhausted,
      ),
    ),
    nextPageOk(
      (page, maxPage, order, exhausted) =>
          commentNextPage(page: page, maxPage: maxPage, order: order),
    ),
    '确认到头之后 commentNextPage 必须返回 null；故障=忽略 exhausted 继续请求',
  );

  // ⑤ 到头的判据：旧→新只有退到第 1 页仍空才算到头。
  bool endOk(bool Function(int, CommentOrder, int) f) =>
      !f(3, CommentOrder.oldestFirst, 20) &&
      f(1, CommentOrder.oldestFirst, 0) &&
      !f(3, CommentOrder.oldestFirst, 0) &&
      f(4, CommentOrder.newestFirst, 0);
  _pair(
    check,
    'comments.paging_end_detection',
    endOk(
      (page, order, rawCount) => commentPagingExhausted(
        page: page,
        order: order,
        rawCount: rawCount,
      ),
    ),
    endOk((page, order, rawCount) => rawCount == 0),
    '旧→新中途的空页只是 maxPage 高估（还要继续往下退），退到第 1 页仍空才算'
    '整话没评论；新→旧空页即到头；故障=见空就停会丢掉前面所有页',
  );

  // ⑥ 三个评论区（详情页 / 独立章节页 / 章末内嵌页）都要接上。
  final detailCommentsSrc = _stripComments(
    _read(packageRoot, 'lib/pages/comic_details_page/comments_page.dart'),
  );
  final readerCommentsSrc = _stripComments(
    _read(packageRoot, 'lib/pages/reader/chapter_comments.dart'),
  );
  bool pagingWired(String body) =>
      body.contains('commentFallbackPage(') &&
      body.contains('commentPagingExhausted(') &&
      body.contains('exhausted: _exhausted') &&
      !body.contains('_comments!.addAll(');
  final bodies = [
    _topLevelClassBody(detailCommentsSrc, '_CommentsPageState'),
    _topLevelClassBody(readerCommentsSrc, '_ChapterCommentsPageState'),
    _topLevelClassBody(
      readerCommentsSrc,
      '_EmbeddedChapterCommentsPageState',
    ),
  ];
  _pair(
    check,
    'comments.paging_wired_in_all_pages',
    bodies.every((b) => b.isNotEmpty && pagingWired(b)),
    pagingWired('class Fake {}'),
    '三处评论列表都要：首屏空页回退 + 到头停翻 + 不再对排序产物 addAll；'
    '故障=任一页漏接（bodyLens=${bodies.map((b) => b.length).join(",")}）',
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// P69 · 章节矩阵跨形态合并（版本化 / 分组式 / 扁平）。
//
// 🔴 为什么这组断言必须用**真实形态**而不是手搓的干净样例：P67 的三条断言只测
//    「策略函数返回值」，全部是理想数据（`{1: [...]}` + `{1: ...}`），于是
//    `mergedWith` 在模式不同时 `return this` 这条死路一次都没被碰到 —— 用户实测
//    「第一次告白」本地 63 话、站点 68 话，刷新一百次也不补章。真实形态是：
//    - 拷贝漫画（分组式）：`{"默認": {"230c97f8-…": "第01话"}}`，话号只在标题里；
//    - 本地库版本化矩阵（P52 重建）：外层键 `1 [copymanga]`；
//    - comix.to：外层键 `1 [Rokari Comics] [comix.to]`，多组一话多版本。
//    下面每组都按这三类真实写法构造，并且反向对照组喂「旧行为产物」。
// ─────────────────────────────────────────────────────────────────────────────

/// 本地库版本化矩阵（P52 手工重建后的拷贝漫画记录形态）。
ComicChapters _p69LocalVersioned(int chapters) {
  final map = <String, List<ComicChapterVersion>>{};
  for (var i = 1; i <= chapters; i++) {
    final key = '$i [copymanga]';
    map[key] = [
      ComicChapterVersion(title: '第$i话', chapterKey: key),
    ];
  }
  return ComicChapters.versioned(map);
}

/// 拷贝漫画源返回的分组式矩阵：单组「默認」，key 是章节 UUID，话号只在标题。
ComicChapters _p69OnlineGrouped(int chapters, {String group = '默認'}) {
  final inner = <String, String>{};
  for (var i = 1; i <= chapters; i++) {
    inner['230c97f8-632e-11ee-9733-d3d228a7${i.toString().padLeft(4, '0')}'] =
        '第$i话';
  }
  return ComicChapters.grouped({group: inner});
}

void runP69Checks(_CheckSink check, {required Directory packageRoot}) {
  // ① 版本化本地记录 + 分组式源 → 新章节必须并进来（P67 那条死路的正面）。
  bool growsOk(ComicChapters c) =>
      c.isVersioned &&
      c.length == 68 &&
      c.allChapters.length == 68 &&
      c.allChapters.values.contains('第68话');
  final localV63 = _p69LocalVersioned(63);
  final grown = localV63.mergedWith(_p69OnlineGrouped(68));
  _pair(
    check,
    'chapters.cross_mode_merge_grows',
    growsOk(grown),
    growsOk(localV63),
    '本地 versioned 63 话 + 源 grouped 68 话 ⇒ 必须 68 话；故障=模式不同就 '
    'return this（P67 实测：刷新一百次仍停在 63，只能删历史重识别）',
  );

  // ② 反方向：分组式本地记录 + 版本化源 → 并进来且**保住分组形态**。
  bool keepsShape(ComicChapters c) =>
      c.isGrouped &&
      c.groupCount == 1 &&
      c.length == 70 &&
      c.getGroup('默認').length == 70;
  final localG68 = _p69OnlineGrouped(68);
  _pair(
    check,
    'chapters.cross_mode_keeps_local_shape',
    keepsShape(localG68.mergedWith(_p69LocalVersioned(70))),
    keepsShape(_p69LocalVersioned(70)),
    '本地 grouped 68 话 + 源 versioned 70 话 ⇒ 仍是单组「默認」70 话；'
    '故障=把本地形态换成源的版本化形态（分组页签、下载目录名全按本地形态算）',
  );

  // ③ 只增不减：源比本地少时不得缩水（本地可能有源上已下架的旧话）。
  bool noShrinkOk(ComicChapters c) =>
      c.isVersioned &&
      c.length == 68 &&
      _p69LocalVersioned(68).ids.every((k) => c.allVersionKeys.contains(k));
  final localV68 = _p69LocalVersioned(68);
  _pair(
    check,
    'chapters.cross_mode_never_shrinks',
    noShrinkOk(localV68.mergedWith(_p69OnlineGrouped(63))),
    noShrinkOk(_p69OnlineGrouped(63)),
    '本地 68 话 + 源 63 话 ⇒ 仍是 68 话且本地每个版本 key 都还在；'
    '故障=拿源整体替换本地（已下载的 key 会变成孤儿）',
  );

  // ④ 身份判定要能从标题里读话号：UUID 键的两种形态是同一话，不能各留一格。
  const uuid = '230c97f8-632e-11ee-9733-d3d228a7ffff';
  final uuidLocal = ComicChapters.versioned({
    uuid: [ComicChapterVersion(title: '第01话', chapterKey: uuid)],
  });
  final numberedOnline = ComicChapters.versioned({
    '1 [copymanga]': [
      ComicChapterVersion(title: '第01话', chapterKey: '1 [copymanga]'),
    ],
  });
  bool identityOk(ComicChapters c) => c.length == 1;
  final oldIdentityProduct = ComicChapters.versioned({
    uuid: [ComicChapterVersion(title: '第01话', chapterKey: uuid)],
    '1 [copymanga]': [
      ComicChapterVersion(title: '第01话', chapterKey: '1 [copymanga]'),
    ],
  });
  _pair(
    check,
    'chapters.merge_identity_reads_title_number',
    identityOk(uuidLocal.mergedWith(numberedOnline)),
    identityOk(oldIdentityProduct),
    '本地键是 UUID、源键是「1 [copymanga]」，两边标题都是「第01话」⇒ 必须判同'
    '一章（1 格）；故障=只看章节 key 的话号，同一话各建一格（整本翻倍）',
  );

  // ⑤ 三种形态可互转，且转换不丢话、不丢 key。
  final versioned = _p69LocalVersioned(63);
  final asGrouped = versioned.toGrouped();
  final backToVersioned = asGrouped.toVersioned();
  final asFlat = versioned.toFlat();
  _pair(
    check,
    'chapters.mode_conversion_roundtrip',
    asGrouped.isGrouped &&
        asGrouped.groupCount == 1 &&
        asGrouped.length == 63 &&
        backToVersioned.isVersioned &&
        backToVersioned.length == 63 &&
        backToVersioned.allVersionKeys.toSet().containsAll(versioned.ids) &&
        asFlat.length == 63,
    asGrouped.isGrouped == false && backToVersioned.isVersioned == false,
    'versioned → grouped → versioned 必须保住 63 话与全部 key；'
    '故障=互转时丢版本（toGrouped 直接 return this 或漏写 key）',
  );

  // ⑥ 三个回填入口都还得走 mergedWith（防止哪天被改回「直接返回源矩阵」）。
  final modelsSrc = _stripComments(
    _read(packageRoot, 'lib/foundation/comic_source/models.dart'),
  );
  final localSrc = _stripComments(_read(packageRoot, 'lib/foundation/local.dart'));
  final detailSrc = _stripComments(
    _read(packageRoot, 'lib/pages/comic_details_page/comic_page.dart'),
  );
  bool wiredOk(String models, String local, String page) =>
      // 只认**代码**锚点（`_stripComments` 已把注释剥掉，写注释里的标记会假绿）：
      // 规范格摊平 + 按本地形态落盘这两步必须在 models.dart 里真的存在。
      models.contains('_canonicalCells()') &&
      models.contains('_emitCells(') &&
      models.contains('final union = <_ChapterCell>[...mine];') &&
      local.contains('mergedWith(online)') &&
      'mergedWith('.allMatches(page).length >= 2;
  _pair(
    check,
    'chapters.cross_mode_wired_in_backfill',
    wiredOk(modelsSrc, localSrc, detailSrc),
    wiredOk('class Fake {}', 'class Fake {}', 'class Fake {}'),
    '跨形态分支必须在 models.dart；local.enrichComicChapters 与详情页两处回填'
    '都必须走 mergedWith；故障=任一处改成直接取源矩阵（会丢本地旧章）',
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// P70 · 编号 key ↔ UUID key 的同一话归一（大公华丽婚姻实测）。
//
// 真实形态（不是手搓的干净样例）：
//   网源 chapters = {"默認": {"230c97f8-…": "第01话"}}
//   磁盘目录     = `1 [copymanga]`（agent 辅助下载，没走下载器通道）
//   本地记录     = versioned，同时含 `1 [copymanga]` 与 UUID 两个版本 key
// 旧口径下 `parseChapterTitle('1 [copymanga]') == null`，于是同一话既叫
// `k:1 [copymanga]` 又叫 `n:1`：合并翻倍、蓝色标志只认 5 个 UUID、刷新
// 每点一次都把 69 个目录当新章。这里三条断言分别钉住归一、反查、接线。
// ─────────────────────────────────────────────────────────────────────────────
void runP70Checks(_CheckSink check, {required Directory packageRoot}) {
  // ① 真实 DB 形态：「1 [copymanga]」标题不是「第1话」，也必须判成同一话。
  const uuid = '230c97f8-632e-11ee-9733-d3d228a76de6';
  final numberedLocal = ComicChapters.versioned({
    '1 [copymanga]': [
      ComicChapterVersion(title: '1 [copymanga]', chapterKey: '1 [copymanga]'),
    ],
  });
  final uuidOnline = ComicChapters.grouped({
    '默認': {uuid: '第01话'},
  });
  final merged = numberedLocal.mergedWith(uuidOnline);
  bool dedupedOk(ComicChapters c) => c.length == 1;
  final oldProduct = ComicChapters.versioned({
    '1 [copymanga]': [
      ComicChapterVersion(title: '1 [copymanga]', chapterKey: '1 [copymanga]'),
    ],
    uuid: [ComicChapterVersion(title: '第01话', chapterKey: uuid)],
  });
  _pair(
    check,
    'chapters.merge_dedupes_numbered_key_form',
    dedupedOk(merged),
    dedupedOk(oldProduct),
    '本地标题是「1 [copymanga]」、源 key 是 UUID 标题「第01话」⇒ 必须同为第1话'
    '只留一格；故障=只用 parseChapterTitle 认话号，两格并存的整本翻倍形态',
  );

  // ② 磁盘目录反查要返回**所有**等价 key，而不是只认字面命中的那一个。
  final both = chapterKeysForDirectoryName(bothFormsMatrix(), '1 [copymanga]');
  bool allKeysOk(List<String> keys) =>
      keys.length == 2 && keys.contains('1 [copymanga]') && keys.contains(uuid);
  _pair(
    check,
    'chapters.disk_dir_maps_to_all_equivalent_keys',
    allKeysOk(both),
    allKeysOk(both.take(1).toList()),
    '目录 `1 [copymanga]` 同时对应编号 key 与 UUID key ⇒ 磁盘对账要把两个都标'
    '已下载，网络视图才会全蓝；故障=只返回第一个字面命中的 key',
  );

  // ③ 两个消费端都必须走这条共用映射（防止改回逐字 chapterDirectoryName）。
  final localSrc = _stripComments(
    _read(packageRoot, 'lib/foundation/local.dart'),
  );
  final editSrc = _stripComments(
    _read(packageRoot, 'lib/utils/local_comic_edit.dart'),
  );
  bool wiredOk(String local, String edit) =>
      local.contains('chapterKeysForDirectoryName(chapters, name)') &&
      edit.contains('chapterKeysForDirectoryName(existing, entry.name)');
  _pair(
    check,
    'chapters.equivalent_key_mapping_wired',
    wiredOk(localSrc, editSrc),
    wiredOk('class Fake {}', 'class Fake {}'),
    '磁盘对账与「刷新章节」都必须走共用等价键映射；故障=任一处改回逐字匹配'
    '（表现为日志 69 个目录 unmapped + 每次刷新都报新增）',
  );
}

/// 同一话的两种真实表示并存（P70 故障注入夹具）。
ComicChapters bothFormsMatrix() {
  const uuid = '230c97f8-632e-11ee-9733-d3d228a76de6';
  return ComicChapters.versioned({
    '1 [copymanga]': [
      ComicChapterVersion(title: '1 [copymanga]', chapterKey: '1 [copymanga]'),
    ],
    uuid: [ComicChapterVersion(title: '第01话', chapterKey: uuid)],
  });
}

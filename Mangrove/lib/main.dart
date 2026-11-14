import 'dart:async';
import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:mangrove/foundation/app_theme.dart';
import 'package:mangrove/foundation/color_scheme_preset.dart';
import 'package:mangrove/foundation/log.dart';
import 'package:mangrove/pages/auth_page.dart';
import 'package:mangrove/pages/disclaimer.dart';
import 'package:mangrove/pages/main_page.dart';
import 'package:mangrove/utils/io.dart';
import 'package:window_manager/window_manager.dart';
import 'components/components.dart';
import 'components/window_frame.dart';
import 'foundation/app.dart';
import 'foundation/appdata.dart';
import 'foundation/launcher_icon.dart';
import 'foundation/download_keepalive.dart';
import 'foundation/tray.dart';
import 'headless.dart';
import 'init.dart';

Future<void> main(List<String> args) async {
  if (args.contains('--headless')) {
    // Awaited: headless commands do real async work (file IO, network). With a
    // bare `runHeadlessMode(args)` the call returned to a `main` that
    // immediately finished, and the command never got past its first plugin
    // call — every headless command other than the synchronous "no command"
    // guard appeared to hang forever.
    await runHeadlessMode(args);
    return;
  }
  if (runWebViewTitleBarWidget(args)) return;
  overrideIO(() {
    runZonedGuarded(
      () async {
        WidgetsFlutterBinding.ensureInitialized();
        await init();
        runApp(const MyApp());
        if (App.isDesktop) {
          await windowManager.ensureInitialized();
          windowManager.waitUntilReadyToShow().then((_) async {
            await windowManager.setTitleBarStyle(
              TitleBarStyle.hidden,
              windowButtonVisibility: App.isMacOS,
            );
            if (App.isLinux) {
              await windowManager.setBackgroundColor(Colors.transparent);
            }
            await windowManager.setMinimumSize(const Size(500, 600));
            var placement = await WindowPlacement.loadFromFile();
            if (App.isLinux) {
              await windowManager.show();
              await placement.applyToWindow();
            } else {
              await placement.applyToWindow();
              await windowManager.show();
            }

            WindowPlacement.loop();
            await TrayController.instance.init();
            // WM_SETICON is per-process; re-apply the stored icon each launch so
            // the window/taskbar icon follows the user's choice (issue #134).
            await LauncherIconService.applyForStartup();
          });
        }
      },
      (error, stack) {
        Log.error("Unhandled Exception", error, stack);
      },
    );
  });
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    App.registerForceRebuild(forceRebuild);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    WidgetsBinding.instance.addObserver(this);
    _migrateLegacyThemeMode();
    initDeferred().then((_) {
      checkUpdates();
      if (mounted) setState(() {});
    });
    super.initState();
  }

  bool isAuthPageActive = false;

  /// 三档外观（白天 / 夜间 / 护眼）不再有「跟随系统」这一档。
  ///
  /// 旧安装里 `theme_mode` 可能是 `system`：如果原样保留，运行时按系统明暗走、
  /// 设置界面却把它显示成「白天」，出现「界面写着白天、界面本身是夜间」的
  /// 自相矛盾。这里一次性落成当时的具体档位（深色系统的用户不会被莫名切亮），
  /// 之后 UI 与 themeMode 永远一致。
  void _migrateLegacyThemeMode() {
    final raw = appdata.settings['theme_mode'];
    if (raw == 'light' || raw == 'dark' || raw == 'sepia') return;
    final isDark =
        WidgetsBinding.instance.platformDispatcher.platformBrightness ==
        Brightness.dark;
    appdata.settings['theme_mode'] = isDark ? 'dark' : 'light';
    appdata.saveData();
  }

  OverlayEntry? hideContentOverlay;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && App.isMobile) {
      DownloadKeepAlive.instance.onResume();
    }
    // Logs are buffered and flushed on a timer to avoid a disk write per
    // network request; push them out now, before the process can be suspended
    // or killed with lines still in memory. Must stay above the early return
    // below, which skips everything when app-lock is off.
    if (state != AppLifecycleState.resumed) {
      Log.flush();
    }
    if (!App.isMobile || !appdata.settings['authorizationRequired']) {
      return;
    }
    if (state == AppLifecycleState.inactive && hideContentOverlay == null) {
      hideContentOverlay = OverlayEntry(
        builder: (context) {
          return Positioned.fill(
            child: Container(
              width: double.infinity,
              height: double.infinity,
              color: App.rootContext.colorScheme.surface,
            ),
          );
        },
      );
      Overlay.of(App.rootContext).insert(hideContentOverlay!);
    } else if (hideContentOverlay != null &&
        state == AppLifecycleState.resumed) {
      hideContentOverlay!.remove();
      hideContentOverlay = null;
    }
    if (state == AppLifecycleState.hidden &&
        !isAuthPageActive &&
        !IO.isSelectingFiles) {
      isAuthPageActive = true;
      App.rootContext.to(
        () => AuthPage(
          onSuccessfulAuth: () {
            App.rootContext.pop();
            isAuthPageActive = false;
          },
        ),
      );
    }
    super.didChangeAppLifecycleState(state);
  }

  void forceRebuild() {
    void rebuild(Element el) {
      el.markNeedsBuild();
      el.visitChildren(rebuild);
    }

    (context as Element).visitChildren(rebuild);
    setState(() {});
  }

  /// The seed colour for the current `colorSchemePreset`.
  ///
  /// Replaces the pre-P47 switch over the legacy `color` key. `system` still
  /// means "let the platform decide", which the caller handles with the
  /// [DynamicColorBuilder] colours.
  Color translateColorSetting() {
    return seedColorForPreset(
          appdata.settings['colorSchemePreset'] as String?,
          customSeed: parseHexColor(
            appdata.settings['customSeedColor'] as String?,
          ),
        ) ??
        kDefaultSeedColor;
  }

  ThemeData getTheme(
    Color primary,
    Color? secondary,
    Color? tertiary,
    Brightness brightness, {
    bool sepia = false,
  }) {
    return buildAppTheme(
      primary: primary,
      secondary: secondary,
      tertiary: tertiary,
      brightness: brightness,
      sepia: sepia,
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget home;
    if (!deferredInitCompleter.isCompleted) {
      home = const Scaffold(body: Center(child: CircularProgressIndicator()));
    } else if (appdata.settings['requireDisclaimerConsent'] == true &&
        appdata.settings['disclaimerConsented'] != true) {
      home = const DisclaimerConsentPage();
    } else if (appdata.settings['authorizationRequired']) {
      home = AuthPage(
        onSuccessfulAuth: () {
          App.rootContext.toReplacement(() => const MainPage());
        },
      );
    } else {
      home = const MainPage();
    }
    return DynamicColorBuilder(
      builder: (light, dark) {
        Color? primary, secondary, tertiary;
        if (appdata.settings['colorSchemePreset'] != kPresetSystem ||
            light == null ||
            dark == null) {
          primary = translateColorSetting();
        } else {
          primary = light.primary;
          secondary = light.secondary;
          tertiary = light.tertiary;
        }
        final sepia = appdata.settings['theme_mode'] == 'sepia';
        return MaterialApp(
          title: "Mangrove",
          home: home,
          debugShowCheckedModeBanner: false,
          theme: getTheme(
            primary,
            secondary,
            tertiary,
            Brightness.light,
            sepia: sepia,
          ),
          navigatorKey: App.rootNavigatorKey,
          navigatorObservers: [App.rootRouteObserver],
          darkTheme: getTheme(
            primary,
            secondary,
            tertiary,
            sepia ? Brightness.light : Brightness.dark,
            sepia: sepia,
          ),
          themeMode: sepia
              ? ThemeMode.light
              : switch (appdata.settings['theme_mode']) {
                  'light' => ThemeMode.light,
                  'dark' => ThemeMode.dark,
                  _ => ThemeMode.system,
                },
          color: Colors.transparent,
          localizationsDelegates: [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          locale: () {
            var lang = appdata.settings['language'];
            if (lang == 'system') {
              return null;
            }
            return switch (lang) {
              'zh-CN' => const Locale('zh', 'CN'),
              'zh-TW' => const Locale('zh', 'TW'),
              'en-US' => const Locale('en'),
              _ => null,
            };
          }(),
          supportedLocales: const [
            Locale('zh', 'CN'),
            Locale('zh', 'TW'),
            Locale('en'),
          ],
          builder: (context, widget) {
            ErrorWidget.builder = (details) {
              Log.error(
                "Unhandled Exception",
                "${details.exception}\n${details.stack}",
              );
              return Material(
                child: Center(child: Text(details.exception.toString())),
              );
            };
            if (widget != null) {
              /// 如果无法检测到状态栏高度设定指定高度
              /// https://github.com/flutter/flutter/issues/161086
              var viewPaddingTop = MediaQuery.viewPaddingOf(context).top;
              var isPaddingCheckError =
                  viewPaddingTop <= 0 || viewPaddingTop > 200;

              if (isPaddingCheckError && Platform.isAndroid) {
                widget = MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    viewPadding: const EdgeInsets.only(top: 15, bottom: 15),
                    padding: const EdgeInsets.only(top: 15, bottom: 15),
                  ),
                  child: widget,
                );
              }

              widget = OverlayWidget(widget);
              if (App.isDesktop) {
                widget = Shortcuts(
                  shortcuts: {
                    LogicalKeySet(LogicalKeyboardKey.escape):
                        VoidCallbackIntent(App.pop),
                  },
                  child: MouseBackDetector(
                    onTapDown: App.pop,
                    child: WindowFrame(widget),
                  ),
                );
              }
              return _SystemUiProvider(
                Material(
                  color: App.isLinux ? Colors.transparent : null,
                  child: widget,
                ),
              );
            }
            throw ('widget is null');
          },
        );
      },
    );
  }
}

class _SystemUiProvider extends StatelessWidget {
  const _SystemUiProvider(this.child);

  final Widget child;

  @override
  Widget build(BuildContext context) {
    var brightness = Theme.of(context).brightness;
    SystemUiOverlayStyle systemUiStyle;
    if (brightness == Brightness.light) {
      systemUiStyle = SystemUiOverlayStyle.dark.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.dark,
        systemNavigationBarContrastEnforced: false,
      );
    } else {
      systemUiStyle = SystemUiOverlayStyle.light.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
        systemNavigationBarContrastEnforced: false,
      );
    }
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: systemUiStyle,
      child: child,
    );
  }
}

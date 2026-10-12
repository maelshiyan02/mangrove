import 'dart:async';

import 'package:display_mode/display_mode.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_saf/flutter_saf.dart';
import 'package:mangrove/foundation/app.dart';
import 'package:mangrove/foundation/bt_project/bt_project_manager.dart';
import 'package:mangrove/foundation/cache_manager.dart';
import 'package:mangrove/foundation/comic_source/comic_source.dart';
import 'package:mangrove/foundation/history.dart';
import 'package:mangrove/foundation/image_enhance_shader.dart';
import 'package:mangrove/foundation/image_translation/pre_translation_tasks.dart';
import 'package:mangrove/foundation/translation_project/studio_enqueue.dart';
import 'package:mangrove/foundation/js_engine.dart';
import 'package:mangrove/foundation/log.dart';
import 'package:mangrove/foundation/related_source_tasks.dart';
import 'package:mangrove/foundation/system_fonts.dart';
import 'package:mangrove/network/app_dio_io.dart';
import 'package:mangrove/network/cookie_jar.dart';
import 'package:mangrove/network/repair_download.dart';
import 'package:mangrove/pages/comic_source_page.dart';
import 'package:mangrove/pages/follow_updates_page.dart';
import 'package:mangrove/pages/settings/settings_page.dart';
import 'package:mangrove/utils/app_links.dart';
import 'package:mangrove/utils/handle_notification_route.dart';
import 'package:mangrove/utils/handle_text_share.dart';
import 'package:mangrove/utils/opencc.dart';
import 'package:mangrove/utils/sync_protocol.dart';
import 'package:mangrove/utils/tags_translation.dart';
import 'package:mangrove/utils/translations.dart';
import 'foundation/appdata.dart';

extension _FutureInit<T> on Future<T> {
  /// Prevent unhandled exception
  ///
  /// A unhandled exception occurred in init() will cause the app to crash.
  Future<void> wait() async {
    try {
      await this;
    } catch (e, s) {
      Log.error("init", "$e\n$s");
    }
  }
}

/// Critical initialization that must complete before UI renders.
/// Only includes what's needed for theme, locale, and basic app state.
Future<void> init() async {
  await App.init().wait();
  if (App.isAndroid) {
    startAppLinkCapture();
  }
  await appdata.init().wait();
  await AppTranslation.init().wait();
  if (App.isWindows) {
    Timer.periodic(const Duration(seconds: 1), (_) {
      const methodChannel = MethodChannel('mangrove/method_channel');
      methodChannel.invokeMethod("heartBeat");
    });
  }
}

/// Heavy initialization that runs after UI is visible.
final Completer<void> deferredInitCompleter = Completer<void>();

/// Stores that only resolve when started **together**.
///
/// The dependency chain is real and circular-looking at the call site:
/// `LocalManager.init()` awaits `ComicSourceManager().ensureInit()`, and
/// `ComicSourceManager.doInit()` awaits `JsEngine().ensureInit()`. Each
/// `ensureInit()` just parks on a completer that only [Init.init] completes, so
/// awaiting them one after another deadlocks forever. This is the single place
/// that starts the trio concurrently — every caller (GUI startup, headless CLI)
/// must go through here so the ordering can never drift again.
Future<void> initInterdependentStores() {
  return Future.wait([
    App.initComponents().wait(),
    JsEngine().init().wait(),
    ComicSourceManager().init().wait(),
  ]);
}

Future<void> initDeferred() async {
  try {
    // Every step is individually guarded: one component failing must not skip
    // the rest. A corrupt cookie.db once threw here before App.initComponents
    // ever ran — yet the finally still completed the gate, so the app carried
    // on believing init had succeeded: the startup sync applied a backup over
    // uninitialized stores and the follow-update checker hit
    // LateInitializationError inside widget builds. The completer only means
    // "init finished attempting"; callers that need working stores must check
    // [coreDataStoresReady].
    await SingleInstanceCookieJar.createInstance().wait();
    await initPlatformServices().wait();
    // Register the repair task type before saved download tasks are restored,
    // otherwise an interrupted S4 repair run is silently dropped on launch.
    registerRepairDownloadTaskType();
    var futures = [
      // The three interdependent stores (app stores / JS engine / comic
      // sources) must be started together — see [initInterdependentStores].
      initInterdependentStores().wait(),
      TagsTranslation.readData().wait(),
      OpenCC.init().wait(),
      ImageEnhanceShader.instance.preload().wait(),
      // P33：系统字体探测（读几百个字体文件头）。启动后尽早跑，这样用户
      // 打开工作室时表已经填好 —— 扫描没完成时 `systemFonts` 是空表，行为
      // 与探测功能上线前一致（不会在启动头一秒里突然换掉旧工程的字体）。
      ensureSystemFontsScanned(),
    ];
    await Future.wait(futures);
    CacheManager().setLimitSize(appdata.settings['cacheSize']);
    // Index BallonsTranslator projects once the local-comic store is ready so
    // history tiles, favorites and readers resolve before the user ever opens
    // the local comics tab. Fire and forget: a reader open concurrently awaits
    // the same shared scan via BtProjectManager.ensureProject.
    if (BtProjectManager.isEnabled) {
      unawaited(
        BtProjectManager().scan().catchError((Object e, StackTrace s) {
          Log.error("BT Project", "Startup scan failed: $e", s);
        }),
      );
    }
    RelatedSourceTaskManager.instance;
    _checkOldConfigs();
    _autoCleanHistory();
    if (App.isAndroid) {
      initAndroidExtras();
      await trySetHighRefreshRate();
    }
    FlutterError.onError = (details) {
      Log.error(
        "Unhandled Exception",
        "${details.exception}\n${details.stack}",
      );
    };
  } catch (e, s) {
    Log.error("init", "$e\n$s");
  } finally {
    deferredInitCompleter.complete();
  }
}

void _checkOldConfigs() {
  if (appdata.settings['searchSources'] == null) {
    appdata.settings['searchSources'] = ComicSource.all()
        .where((e) => e.searchPageData != null)
        .map((e) => e.key)
        .toList();
  }

  if (appdata.implicitData['webdavAutoSync'] == null) {
    var webdavConfig = appdata.settings['webdav'];
    if (webdavConfig is List &&
        webdavConfig.length == 3 &&
        webdavConfig.whereType<String>().length == 3) {
      appdata.implicitData['webdavAutoSync'] = true;
    } else {
      appdata.implicitData['webdavAutoSync'] = false;
    }
    appdata.writeImplicitData();
  }

  // One-time stamp of the sync tier (#114). The legacy-boolean fallback in
  // DataSync.syncMode cannot tell a user's explicit "auto-sync off" apart
  // from the shim above writing `false` on an unconfigured fresh install —
  // only here, with the config at hand, can that be decided: an explicit
  // opt-out (false + configured) keeps its "nothing automatic" intent as
  // manual; everything else gets the historical default, realtime.
  if (appdata.implicitData['webdavSyncMode'] == null) {
    var webdavConfig = appdata.settings['webdav'];
    var configured =
        webdavConfig is List &&
        webdavConfig.length == 3 &&
        webdavConfig.whereType<String>().length == 3;
    appdata.implicitData['webdavSyncMode'] =
        (appdata.implicitData['webdavAutoSync'] == false && configured)
        ? WebdavSyncMode.manual.name
        : WebdavSyncMode.realtime.name;
    appdata.writeImplicitData();
  }
}

/// Removes reading history older than the user-selected retention window.
/// Driven by the `autoCleanHistoryDays` setting (0 = keep forever). Runs once
/// per startup after the history DB is ready; failures are swallowed so they
/// never block app launch.
void _autoCleanHistory() {
  var raw = appdata.settings['autoCleanHistoryDays'];
  var days = raw is num
      ? raw.toInt()
      : int.tryParse(raw?.toString() ?? '') ?? 0;
  if (days <= 0) return;
  try {
    var removed = HistoryManager().cleanHistoryOlderThan(Duration(days: days));
    if (removed > 0) {
      Log.info(
        "History",
        "Auto-cleaned $removed history record(s) older "
            "than $days day(s).",
      );
    }
  } catch (e, s) {
    Log.error("History", "Auto-clean failed: $e", s);
  }
}

Future<void> _checkAppUpdates() async {
  final now = DateTime.now().millisecondsSinceEpoch;

  // Comic source update check remains daily.
  final lastSourceCheck =
      (appdata.implicitData['lastCheckUpdate'] as num?)?.toInt() ?? 0;
  if (now - lastSourceCheck >= 24 * 60 * 60 * 1000) {
    appdata.implicitData['lastCheckUpdate'] = now;
    appdata.writeImplicitData();
    unawaited(ComicSourcePage.checkComicSourceUpdate());
  }

  // App update check runs on each startup when enabled.
  if (appdata.settings['checkUpdateOnStart'] == true) {
    await checkUpdateUi(false, false);
  }
}

void checkUpdates() {
  // Delay to make sure navigator context is ready for update dialogs.
  Future.delayed(const Duration(seconds: 2), _checkAppUpdates).wait();
  FollowUpdatesService.initChecker();
  // 🔴 顺序不可换：先给任务框架装上工作室执行体，再让它去续跑。反过来的话，
  // 上一次会话遗留的 studio 任务会因为 `studioRunner is null` 被标成 failed
  // （`pre_translation_tasks.dart::_runStudio` 明写这条），而用户看到的是
  // "翻译失败了"——一个由启动顺序制造出来的、没有任何线索的失败。
  registerStudioTaskRunner();
  PreTranslationTaskManager.instance.resumePendingTasks();
}

Future<void> initPlatformServices() async {
  await Future.wait([_initRhttp(), SAFTaskWorker().init()]);
}

Future<void> _initRhttp() async {
  try {
    await nativeInitRhttp();
  } catch (e, s) {
    Log.error("Rhttp", "Failed to initialize rhttp/RustLib: $e\n$s");
  }
}

void initAndroidExtras() {
  handleLinks();
  handleTextShare();
  handleNotificationRoute();
}

Future<void> trySetHighRefreshRate() async {
  try {
    await FlutterDisplayMode.setHighRefreshRate();
  } catch (e) {
    Log.error("Display Mode", "Failed to set high refresh rate: $e");
  }
}

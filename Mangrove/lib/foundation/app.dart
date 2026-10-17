import 'dart:ui';

import 'package:flutter/foundation.dart'
    show kIsWeb, TargetPlatform, defaultTargetPlatform;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:mangrove/foundation/download_network_guard.dart';
import 'package:mangrove/foundation/history.dart';
import 'package:mangrove/foundation/log.dart';
import 'package:mangrove/foundation/image_translation/translation_store.dart';
import 'package:mangrove/foundation/read_later.dart';

import 'appdata.dart';
import 'bt_project/bt_project_manager.dart';
import 'domain_database.dart';
import 'favorites.dart';
import 'local.dart';

export "widget_utils.dart";
export "context.dart";

class _App {
  String _version = "0.0.0";

  String get version => _version;

  bool get isWeb => kIsWeb;

  bool get isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  bool get isIOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  bool get isWindows =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  bool get isLinux => !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;

  bool get isMacOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  bool get isDesktop => !kIsWeb && (isWindows || isLinux || isMacOS);

  bool get isMobile => !kIsWeb && (isAndroid || isIOS);

  // Whether the app has been initialized.
  // If current Isolate is main Isolate, this value is always true.
  bool isInitialized = false;

  Locale get locale {
    Locale deviceLocale = PlatformDispatcher.instance.locale;
    if (deviceLocale.languageCode == "zh" &&
        deviceLocale.scriptCode == "Hant") {
      deviceLocale = const Locale("zh", "TW");
    }
    if (appdata.settings['language'] != 'system') {
      return Locale(
        appdata.settings['language'].split('-')[0],
        appdata.settings['language'].split('-')[1],
      );
    }
    return deviceLocale;
  }

  String dataPath = '/mangrove/data';
  String cachePath = '/mangrove/cache';
  String? externalStoragePath;

  final rootNavigatorKey = GlobalKey<NavigatorState>();

  final rootRouteObserver = RouteObserver<PageRoute<dynamic>>();

  GlobalKey<NavigatorState>? mainNavigatorKey;

  BuildContext get rootContext => rootNavigatorKey.currentContext!;

  final Appdata data = appdata;

  final HistoryManager history = HistoryManager();

  final ReadLaterManager readLater = ReadLaterManager();

  final LocalFavoritesManager favorites = LocalFavoritesManager();

  final LocalManager local = LocalManager();

  final DomainDatabase domain = DomainDatabase();

  void rootPop() {
    rootNavigatorKey.currentState?.maybePop();
  }

  void pop() {
    if (rootNavigatorKey.currentState?.canPop() ?? false) {
      rootNavigatorKey.currentState?.pop();
    } else if (mainNavigatorKey?.currentState?.canPop() ?? false) {
      mainNavigatorKey?.currentState?.pop();
    }
  }

  /// Pointer file (in the fixed AppData root, independent of [dataPath]) that
  /// stores an explicit data-directory override. Kept OUTSIDE [dataPath] so
  /// reading it has no circular dependency on the very directory it selects.
  static const String _dataPathPointerFile = '.mangrove_datapath';

  /// Explicitly-set data directory (e.g. the project folder on this machine),
  /// or null when running with the portable default (next to the executable).
  String? _dataDirectoryOverride;

  /// The explicit data-directory override, or null.
  String? get dataDirectoryOverride => _dataDirectoryOverride;

  /// Reads the override pointer from the fixed AppData root (sync, for [init]).
  String? _readDataDirectoryOverrideSync() {
    final env = Platform.environment['LOCALAPPDATA'];
    if (env == null || env.isEmpty) return null;
    final file = File(p.join(env, _dataPathPointerFile));
    if (!file.existsSync()) return null;
    final raw = file.readAsStringSync().trim();
    return raw.isEmpty ? null : raw;
  }

  /// Persists or clears the data-directory override. Takes effect on restart.
  Future<void> setDataDirectoryOverride(String? path) async {
    final env = Platform.environment['LOCALAPPDATA'];
    final root = env != null && env.isNotEmpty
        ? env
        : p.dirname((await getApplicationSupportDirectory()).path);
    final file = File(p.join(root, _dataPathPointerFile));
    final trimmed = path?.trim() ?? '';
    if (trimmed.isEmpty) {
      if (file.existsSync()) file.deleteSync();
      _dataDirectoryOverride = null;
    } else {
      file.writeAsStringSync(trimmed);
      _dataDirectoryOverride = trimmed;
    }
  }

  Future<void> init() async {
    // Effective data directory:
    //   1. explicit override (project folder) from a fixed pointer file;
    //   2. portable default: a `data` folder next to the executable so the
    //      app's data travels with the build.
    final override = _readDataDirectoryOverrideSync();
    String resolved;
    if (override != null && override.isNotEmpty && Directory(override).existsSync()) {
      resolved = override;
      _dataDirectoryOverride = override;
    } else {
      final exeDir = p.dirname(Platform.resolvedExecutable);
      resolved = p.join(exeDir, 'data');
      try {
        Directory(resolved).createSync(recursive: true);
      } catch (_) {
        resolved = (await getApplicationSupportDirectory()).path;
      }
      _dataDirectoryOverride = null;
    }
    dataPath = resolved;
    cachePath = resolved;
    if (isAndroid) {
      externalStoragePath = (await getExternalStorageDirectory())!.path;
    }
    try {
      final info = await PackageInfo.fromPlatform();
      _version = info.version;
    } catch (_) {}
    isInitialized = true;
  }

  Future<void> initComponents() async {
    final futures = <Future<void>>[
      data.init(),
      history.init(),
      readLater.init(),
      favorites.init(),
      domain.init(dataPath),
      local.init(),
      TranslationStore().init(),
    ];
    // One store failing must not abort its siblings: an unguarded Future.wait
    // rejected on the first error and left every later store uninitialized —
    // the "init failed but the app carried on" startup chain.
    await Future.wait(
      futures.map((future) async {
        try {
          await future;
        } catch (e, s) {
          Log.error("init", "$e\n$s");
        }
      }),
    );
    // Begin watching connectivity so "WiFi only" downloads pause on metered
    // networks. No-op while the setting is off (#15).
    DownloadNetworkGuard.instance.start();
    // Persist the portable self-heal once stores are loaded: rewrites a
    // btProjectRoot that pointed at the old folder location (or was empty in
    // a fresh portable checkout) into the resolved/portable-relative form.
    try {
      await BtProjectManager.persistPortableSelfHeal();
    } catch (e, s) {
      Log.error("init", "btProjectRoot self-heal failed: $e\n$s");
    }
  }

  Function? _forceRebuildHandler;

  void registerForceRebuild(Function handler) {
    _forceRebuildHandler = handler;
  }

  void forceRebuild() {
    _forceRebuildHandler?.call();
  }
}

// ignore: non_constant_identifier_names
final App = _App();

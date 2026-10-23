// comix.to 采集用的「内置独立浏览器」管理器。
//
// 背景（2026-10-19 用户拍板）：
//   comix.to 的 Cloudflare 只认真实浏览器；WebView2 的无头/可见实例既不能
//   稳定冒充 Chrome，又受「headless 与可见实例不能并存」限制。因此改为
//   **随 App 分发一个独立的 Chrome for Testing（CfT）**：
//     - CfT 是 Google 官方的绿色版 Chrome，解压即用，不依赖系统 Chrome；
//     - App 自己拉起它（独立进程 + 独立 user-data-dir + 独立调试端口），
//       通过 CDP 驱动，和用户日常 Chrome 完全隔离；
//     - 移植到别的电脑时，只要把 App 目录整体拷过去即可，机器上只有 Edge
//       也能用（CfT 自带 Chromium/Chrome 运行时）。
//
// 目录约定（按优先级）：
//   1. <exeDir>/chrome-win64/chrome.exe          —— 随 App 分发的 CfT
//   2. <exeDir>/browser/chrome.exe               —— 兼容旧布局
//   3. %APPDATA%/Mangrove/browser/chrome-win64/chrome.exe —— 运行时下载缓存
//   4. Playwright 的 chromium-*/chrome-win64      —— 仅开发机兜底
//
// 本文件只负责「找到 / 拉起 / 探活 / 停止」，不负责压测和采集逻辑；
// 采集仍由 `ComixCDPWorker` 通过 CDP 完成。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:dio/dio.dart';
import 'package:mangrove/foundation/log.dart';
import 'package:path/path.dart' as p;

/// 内置浏览器管理器（单例）。
class ComixBrowserManager {
  ComixBrowserManager._();

  static final ComixBrowserManager instance = ComixBrowserManager._();

  /// 调试端口。与 `ComixCDPWorker._cdpPort` 保持一致。
  static const int cdpPort = 9222;

  Process? _proc;

  /// App 可执行文件所在目录（release 下即 mangrove.exe 所在目录）。
  String get _exeDir => p.dirname(Platform.resolvedExecutable);

  /// %APPDATA%/Mangrove（Windows）；其他平台退回 HOME/.config/Mangrove。
  String get _appDataDir {
    final env = Platform.environment;
    final base = env['APPDATA'] ??
        (env['HOME'] != null
            ? p.join(env['HOME']!, '.config')
            : Directory.systemTemp.path);
    return p.join(base, 'Mangrove');
  }

  /// 专用 profile 目录：绝不与用户日常 Chrome 共用。
  String get profileDir => p.join(_appDataDir, 'comix_cdp_profile');

  /// 从用户真实 Chrome「借」来的 profile 副本目录（含真实登录态 cookie）。
  ///
  /// 🔴 2026-10-19（第十一轮）：comix 的 503 是**会话级**判定——同一台机器、
  /// 同一个出口，用户自己的 Chrome 能正常访问，而 App 拉起的浏览器吃 503。
  /// 差的就是「真实会话」：`session` / `cf_clearance` / `__cf_bm` 这些只在
  /// 用户正常浏览后才有。副本目录用**同一份 chrome.exe** 打开，DPAPI 能解密，
  /// comix 看到的就等价于用户自己的浏览器。
  String get realProfileDir => p.join(_appDataDir, 'comix_real_profile');

  /// 系统安装的正式版 Chrome（不是 Chrome for Testing）。
  ///
  /// comix 对「Chrome for Testing」更敏感（CfT 窗口顶部还挂着"仅适用于自动
  /// 测试"的横幅）。优先用正式版 Chrome，最接近「人自己开的浏览器」。
  String? systemChromePath() {
    final local = Platform.environment['LOCALAPPDATA'];
    final candidates = <String>[
      r'C:\Program Files\Google\Chrome\Application\chrome.exe',
      r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
      if (local != null)
        p.join(local, 'Google', 'Chrome', 'Application', 'chrome.exe'),
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  /// 用户真实 Chrome 的 User Data 根目录（不存在返回 null）。
  String? get _systemUserDataDir {
    final local = Platform.environment['LOCALAPPDATA'];
    if (local == null) return null;
    final d = p.join(local, 'Google', 'Chrome', 'User Data');
    return Directory(d).existsSync() ? d : null;
  }

  /// 真实 profile 副本里是否已经有了 Cookies 库。
  bool get hasRealProfileSeed =>
      File(p.join(realProfileDir, 'Default', 'Network', 'Cookies'))
          .existsSync();


  /// 候选 chrome.exe 路径（按优先级）。
  List<String> _candidatePaths() {
    final list = <String>[
      p.join(_exeDir, 'chrome-win64', 'chrome.exe'),
      p.join(_exeDir, 'browser', 'chrome.exe'),
      p.join(_appDataDir, 'browser', 'chrome-win64', 'chrome.exe'),
      p.join(_appDataDir, 'browser', 'chrome.exe'),
    ];

    // 开发机兜底：Playwright 下载的 Chromium（仅当存在时）。
    final local = Platform.environment['LOCALAPPDATA'];
    if (local != null) {
      final pw = Directory(p.join(local, 'ms-playwright'));
      if (pw.existsSync()) {
        try {
          for (final e in pw.listSync()) {
            if (e is Directory) {
              final c = p.join(e.path, 'chrome-win64', 'chrome.exe');
              if (File(c).existsSync()) list.add(c);
            }
          }
        } catch (_) {}
      }
    }
    return list;
  }

  /// 找到可用的 chrome.exe；找不到返回 null。
  ///
  /// 优先级：**系统正式版 Chrome** → 随 App 分发的 CfT → Playwright 兜底。
  String? resolveChrome() {
    final sys = systemChromePath();
    if (sys != null) return sys;
    for (final path in _candidatePaths()) {
      if (File(path).existsSync()) return path;
    }
    return null;
  }

  /// 从用户真实 Chrome 的 profile **复制**一份 cookie 到 [realProfileDir]。
  ///
  /// 返回 true = 副本可用（已有或复制成功）。
  ///
  /// 复制而非移动：绝不影响用户自己的浏览器。只取解密 cookie 必需的
  /// `Local State`（含 DPAPI 包裹的 os_crypt key）+ `Default/Network/Cookies`
  /// （+ journal/wal），不拷贝整个 profile（动辄数百 MB）。
  Future<bool> seedRealProfile({bool force = false}) async {
    final src = _systemUserDataDir;
    if (src == null) {
      Log.info('ComixBrowser', 'seedRealProfile: no system Chrome user-data dir');
      return hasRealProfileSeed;
    }
    final srcCookies = File(p.join(src, 'Default', 'Network', 'Cookies'));
    if (!srcCookies.existsSync()) {
      Log.info('ComixBrowser', 'seedRealProfile: source Cookies not found');
      return hasRealProfileSeed;
    }
    try {
      // 已有副本且源不比副本新 → 直接复用，避免每次启动都拷贝。
      if (!force && hasRealProfileSeed) {
        final dst = File(
          p.join(realProfileDir, 'Default', 'Network', 'Cookies'),
        );
        final srcTime = srcCookies.lastModifiedSync();
        final dstTime = dst.lastModifiedSync();
        if (!srcTime.isAfter(dstTime.add(const Duration(minutes: 2)))) {
          return true;
        }
      }
      Directory(
        p.join(realProfileDir, 'Default', 'Network'),
      ).createSync(recursive: true);

      void copyIfExists(String from, String to) {
        final f = File(from);
        if (!f.existsSync()) return;
        try {
          f.copySync(to);
        } catch (e) {
          // 真实 Chrome 正在运行时个别文件可能被短暂占用：重试一次。
          try {
            f.copySync(to);
          } catch (_) {
            Log.warning('ComixBrowser', 'copy failed: $from — $e');
          }
        }
      }

      copyIfExists(
        p.join(src, 'Local State'),
        p.join(realProfileDir, 'Local State'),
      );
      for (final name in const ['Cookies', 'Cookies-journal', 'Cookies-wal']) {
        copyIfExists(
          p.join(src, 'Default', 'Network', name),
          p.join(realProfileDir, 'Default', 'Network', name),
        );
      }
      copyIfExists(
        p.join(src, 'Default', 'Preferences'),
        p.join(realProfileDir, 'Default', 'Preferences'),
      );

      final ok = hasRealProfileSeed;
      Log.info(
        'ComixBrowser',
        'seedRealProfile: copied real Chrome cookies → $ok',
      );
      return ok;
    } catch (e) {
      Log.warning('ComixBrowser', 'seedRealProfile failed: $e');
      return hasRealProfileSeed;
    }
  }

  /// 关闭当前监听 [cdpPort] 的浏览器实例（只影响这个 CDP 实例）。
  ///
  /// 用途：App 重启后上次拉起的 CfT 进程通常还在（Chrome 不随父进程退出），
  /// 会以「被 comix 标记过的 profile」继续占用 9222。这里用 `Browser.close`
  /// 干净地关掉它，再用正式版 Chrome + 真实 profile 副本重新拉起。
  Future<void> closeExisting() async {
    try {
      final client = HttpClient()..findProxy = (_) => 'DIRECT';
      final req = await client.getUrl(
        Uri.parse('http://127.0.0.1:$cdpPort/json/version'),
      );
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      client.close();
      final j = jsonDecode(body) as Map<String, dynamic>;
      final wsUrl = j['webSocketDebuggerUrl'] as String?;
      if (wsUrl == null) return;
      final ws = await WebSocket.connect(wsUrl);
      ws.add(jsonEncode({'id': 1, 'method': 'Browser.close'}));
      await Future.delayed(const Duration(milliseconds: 300));
      await ws.close();
      Log.info('ComixBrowser', 'closeExisting: closed browser on :$cdpPort');
    } catch (e) {
      Log.warning('ComixBrowser', 'closeExisting failed: $e');
    }
  }


  /// 探测端口上是否已有可用的 CDP（探活不依赖 Dart 的全局代理）。
  Future<bool> isHealthy({Duration timeout = const Duration(seconds: 2)}) async {
    try {
      final client = HttpClient()..findProxy = (_) => 'DIRECT';
      final req = await client
          .getUrl(Uri.parse('http://127.0.0.1:$cdpPort/json/version'))
          .timeout(timeout);
      final res = await req.close().timeout(timeout);
      await res.drain();
      client.close();
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// 本次 App 运行内是否已经检查过「上次遗留的浏览器实例」。
  bool _relaunchChecked = false;

  /// 确保内置浏览器可用：
  ///   - 已有进程在监听 → 直接返回 true；
  ///   - 找到 chrome.exe → 拉起并等待端口就绪；
  ///   - 找不到 → 返回 false（由调用方回落 WebView2）。
  Future<bool> ensureRunning({bool visible = true}) async {
    final chrome = resolveChrome();
    final sys = systemChromePath();

    if (await isHealthy()) {
      // App 重启后，上次拉起的 CfT 进程通常还活着并占用 9222（Chrome 不随
      // 父进程退出）。它用的是被 comix 标记过的独立 profile，继续复用只会
      // 一直 503。这里在每次 App 运行内**只做一次**切换：关掉旧实例，
      // 改用正式版 Chrome + 真实 profile 副本重新拉起。
      if (!_relaunchChecked && chrome != null) {
        _relaunchChecked = true;
        Log.info(
          'ComixBrowser',
          'healthy CDP found — restarting with system Chrome + real profile',
        );
        await closeExisting();
        // 等端口真正释放（最多 6s），否则新实例可能绑不上 9222。
        final releaseDeadline = DateTime.now().add(const Duration(seconds: 6));
        while (DateTime.now().isBefore(releaseDeadline)) {
          if (!await isHealthy()) break;
          await Future.delayed(const Duration(milliseconds: 300));
        }
        // 关闭后重新走下面的拉起流程。
      } else {
        _relaunchChecked = true;
        return true;
      }
    }

    if (chrome == null) {
      Log.warning(
        'ComixBrowser',
        'no chrome found (system or bundled) under $_exeDir',
      );
      return false;
    }

    // 正式版 Chrome → 借用真实 profile 的 cookie 副本；否则退回 CfT + 独立 profile。
    var useProfile = profileDir;
    var usingRealProfile = false;
    if (sys != null && chrome == sys) {
      if (await seedRealProfile()) {
        useProfile = realProfileDir;
        usingRealProfile = true;
      }
    }
    Log.info(
      'ComixBrowser',
      'profile select: ${usingRealProfile ? "real-profile(copy)" : "isolated cdp profile"} → $useProfile',
    );

    try {
      Directory(useProfile).createSync(recursive: true);
      final args = <String>[
        '--remote-debugging-port=$cdpPort',
        '--user-data-dir=$useProfile',
        '--no-first-run',
        '--no-default-browser-check',
        '--disable-blink-features=AutomationControlled',
        '--disable-features=Translate,BackForwardCache',
        // 🔴 不要加 --no-sandbox：本机不是容器环境，加它没有任何收益，
        //    却会在窗口顶部挂一条"不受支持的命令行标记"警告条，
        //    既是明显的非正常启动信号，也干扰用户手动过验证。
      ];
      if (!visible) args.add('--headless=new');
      // 🔴 启动页用 about:blank，**不要**直接开 comix.to：
      //    每启动一次 App 就是一次 comix 文档导航，会持续喂给 comix 的
      //    「短时间多次导航」判定。真正需要时再由 navigate() 做一次首页 bootstrap。
      args.add('about:blank');

      Log.info('ComixBrowser', 'launching chrome: $chrome');
      _proc = await Process.start(
        chrome,
        args,
        workingDirectory: p.dirname(chrome),
      );
      // 排空输出，避免管道缓冲塞满导致浏览器卡住。
      _proc!.stdout.drain<void>();
      _proc!.stderr.drain<void>();
      _proc!.exitCode.then((code) {
        Log.info('ComixBrowser', 'bundled chrome exited: $code');
      }).catchError((_) {});

      // 等待 CDP 端口就绪（首次启动约 2–8s）。
      final deadline = DateTime.now().add(const Duration(seconds: 25));
      while (DateTime.now().isBefore(deadline)) {
        if (await isHealthy()) {
          Log.info('ComixBrowser', 'cdp ready on 127.0.0.1:$cdpPort');
          return true;
        }
        await Future.delayed(const Duration(milliseconds: 500));
      }
      Log.warning('ComixBrowser', 'cdp not ready after 25s');
      return false;
    } catch (e) {
      Log.warning('ComixBrowser', 'launch failed: $e');
      return false;
    }
  }

  /// 主动停止本次拉起的浏览器（不影响用户自己的 Chrome）。
  Future<void> stop() async {
    try {
      _proc?.kill();
    } catch (_) {}
    _proc = null;
  }

  /// 首次运行时下载 Chrome for Testing 到 appdata 缓存。
  ///
  /// 仅在「App 目录没有随包分发 CfT」时需要调用；下载失败不抛异常，
  /// 返回 false 交由调用方提示用户手动放置。
  Future<bool> provision({
    void Function(int received, int total)? onProgress,
  }) async {
    if (resolveChrome() != null) return true;
    try {
      final dio = Dio();
      // 官方版本清单
      final meta = await dio.get<Map<String, dynamic>>(
        'https://googlechromelabs.github.io/chrome-for-testing/'
        'last-known-good-versions-with-downloads.json',
      );
      final stable = meta.data?['channels']?['Stable'];
      final downloads = stable?['downloads']?['chrome'] as List?;
      String? url;
      for (final d in (downloads ?? const [])) {
        if (d is Map && d['platform'] == 'win64') {
          url = d['url'] as String?;
          break;
        }
      }
      if (url == null) {
        Log.warning('ComixBrowser', 'cft win64 url not found');
        return false;
      }
      Log.info('ComixBrowser', 'downloading cft: $url');
      final tmpZip = p.join(Directory.systemTemp.path, 'cft-win64.zip');
      await dio.download(url, tmpZip, onReceiveProgress: onProgress);

      final dest = p.join(_appDataDir, 'browser');
      Directory(dest).createSync(recursive: true);
      final bytes = File(tmpZip).readAsBytesSync();
      final archive = ZipDecoder().decodeBytes(bytes);
      for (final f in archive) {
        final out = p.join(dest, f.name);
        if (f.isFile) {
          File(out)
            ..createSync(recursive: true)
            ..writeAsBytesSync(f.content);
        } else {
          Directory(out).createSync(recursive: true);
        }
      }
      try {
        File(tmpZip).deleteSync();
      } catch (_) {}
      Log.info('ComixBrowser', 'cft extracted to $dest');
      return resolveChrome() != null;
    } catch (e) {
      Log.warning('ComixBrowser', 'cft download failed: $e');
      return false;
    }
  }
}

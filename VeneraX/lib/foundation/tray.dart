import 'dart:async';
import 'dart:io';

import 'package:tray_manager/tray_manager.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/launcher_icon.dart';
import 'package:venera/foundation/leave_guard.dart';
import 'package:venera/utils/translations.dart';
import 'package:window_manager/window_manager.dart';

/// 系统托盘控制器（仅 Windows）。
///
/// 开启「最小化到托盘」后：常驻一个托盘图标，并接管窗口关闭——点关闭按钮或
/// Alt+F4 时把窗口藏进托盘而非退出进程；通过托盘菜单或左键点击恢复，或显式退出。
/// 关闭该设置时移除托盘，但**仍然接管关闭**（见 [setEnabled] 的说明）。
/// 其它平台所有方法均为空操作。
///
/// ## 🔴 S9 · P9.7：为什么 `setPreventClose` 现在**永远**开着
///
/// 原实现把「是否拦截关闭」和「是否最小化到托盘」绑成同一件事：
/// `setEnabled(false)` 里调 `setPreventClose(false)`，于是**关闭键被交还给原生**。
/// 后果是「关闭窗口」这条离开路径在**没有托盘**时完全不经过 Dart：
/// `window_manager` 不再发 `onWindowClose`，`LeaveGuardRegistry` 没有机会说话，
/// 工作室里一批未保存的自动检测块随进程一起消失，且**不报错**。
///
/// 判据不是「有没有托盘」，而是「有没有东西可能丢」——所以拦截常开，
/// 由 [onWindowClose] 逐种情况决定藏托盘、问守卫、还是退出。
class TrayController with TrayListener, WindowListener {
  TrayController._();

  static final TrayController instance = TrayController._();

  static const _menuShow = 'show';
  static const _menuQuit = 'quit';

  bool get _supported => App.isWindows;

  bool _enabled = false;
  bool _wired = false;

  /// 启动时调用（需在窗口就绪后）。按当前设置决定是否启用托盘。
  Future<void> init() async {
    if (!_supported) return;
    _wire();
    // 🔴 顺序：先立好关闭拦截，再决定托盘。反过来的话，托盘关闭的机器上
    // `setEnabled(false)` 会早退（`enabled == _enabled`），`setPreventClose`
    // 便一次都没被调到 —— 于是 Alt+F4 直接退出进程（P9.7 修的正是这条）。
    await windowManager.setPreventClose(true);
    await setEnabled(appdata.settings['minimizeToTray'] == true);
  }

  void _wire() {
    if (_wired) return;
    _wired = true;
    trayManager.addListener(this);
    windowManager.addListener(this);
    // Keep the tray icon in step when the user switches the app icon preset
    // (issue #134); no-op while the tray is disabled.
    LauncherIconService.onWindowsIconChanged = (icoAsset) async {
      if (_enabled) await trayManager.setIcon(icoAsset);
    };
  }

  /// 切换开关时调用。启用即建立托盘；关闭即移除托盘。
  ///
  /// 🔴 **不再在这里碰 `setPreventClose`**。关闭拦截与「是否最小化到托盘」
  /// 是两件独立的事：前者是「别让未保存的东西静默消失」，后者是「关窗去哪」。
  /// 把它们绑在一起，就是 P9.2 登记、P9.7 修掉的那条缺口。
  Future<void> setEnabled(bool enabled) async {
    if (!_supported || enabled == _enabled) return;
    _wire();
    if (enabled) {
      // 先把托盘图标/菜单准备好，最后才置 _enabled=true。
      // 否则窗口可能在托盘尚未建好时就被隐藏，出现“窗口消失却没有托盘图标”
      // 的情况，只能重启恢复。
      // Follow the chosen app-icon preset so the tray matches the window.
      await trayManager.setIcon(LauncherIconService.current.windowsIcoAsset);
      await trayManager.setToolTip('VeneraX');
      await trayManager.setContextMenu(_buildMenu());
      _enabled = true;
    } else {
      _enabled = false;
      await trayManager.destroy();
      await windowManager.show();
    }
  }

  /// 把窗口收进托盘。供窗口关闭按钮路径调用。
  Future<void> hideToTray() async {
    if (!_supported) return;
    // 开关可能刚开启、setEnabled 尚未跑完；先确保托盘已就绪再隐藏。
    if (!_enabled) await setEnabled(true);
    await windowManager.hide();
  }

  Menu _buildMenu() => Menu(
        items: [
          MenuItem(key: _menuShow, label: 'Show VeneraX'.tl),
          MenuItem.separator(),
          MenuItem(key: _menuQuit, label: 'Exit'.tl),
        ],
      );

  Future<void> _restoreWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  void onTrayIconMouseDown() => _restoreWindow();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case _menuShow:
        _restoreWindow();
        break;
      case _menuQuit:
        // 🔴 不直接 `exit(0)`：托盘退出既不经过 `Navigator`、也不经过
        // `PopScope`、也不经过窗口关闭监听，直接退出等于"点退出 = 放弃编辑"。
        unawaited(_quitThroughGuards());
    }
  }

  /// 原生关闭（Alt+F4 / 任务栏关闭）。
  ///
  /// `setPreventClose(true)` 自 [init] 起**常开**，所以这条路径总是会到达
  /// Dart（P9.7 之前它在没开托盘的机器上根本不会触发）。
  @override
  void onWindowClose() {
    if (_enabled) {
      // 最小化到托盘：进程活着，未保存的编辑还在 —— P9.2 已说明为何豁免它。
      hideToTray();
      return;
    }
    unawaited(_quitThroughGuards());
  }

  /// 退出前的**唯一**出口：先问离开守卫，再退出。
  ///
  /// 两个调用方（托盘「退出」与原生关闭）共用它，所以"要不要问守卫"这件事
  /// 只写一次 —— 各写一次的话，改一处就会漏另一处。
  Future<void> _quitThroughGuards() async {
    if (LeaveGuardRegistry.hasGuards &&
        !await LeaveGuardRegistry.requestLeave()) {
      // 守卫拒绝（用户选了"留下"）：什么都不做，窗口还在。
      return;
    }
    exit(0);
  }
}

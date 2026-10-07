import 'package:flutter/services.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/utils/translations.dart';

/// 电池优化豁免（仅 Android）。
///
/// 前台服务 + CPU 唤醒锁只能挡住系统冻结的一部分：OEM ROM（尤其国产定制系统）的
/// 省电策略仍会在应用切到后台约十几秒后冻结进程，导致追更/同步/导入导出/下载等后台
/// 任务卡死（见 issue #84）。把本应用加入电池优化白名单是官方推荐的根治手段。
///
/// 本类只负责查询状态、拉起系统请求对话框，以及在被 ROM 屏蔽时兜底跳转到设置列表。
/// 其它平台（iOS/桌面）全部为无操作。
class BatteryOptimization {
  BatteryOptimization._();

  static final BatteryOptimization instance = BatteryOptimization._();

  static const _channel = MethodChannel('venera/battery_optimization');

  /// 是否已在本次会话内提示过用户。持久化到设置，避免每次启动后台任务都打扰。
  static const _promptedKey = 'batteryOptimizationPrompted';

  bool get _supported => App.isAndroid;

  /// 当前是否已被系统豁免电池优化。非 Android 恒为 true（无此限制）。
  Future<bool> isIgnoring() async {
    if (!_supported) return true;
    final r = await _invoke('isIgnoring');
    return r == true;
  }

  /// 拉起系统「忽略电池优化」请求对话框。返回用户操作后是否已豁免。
  /// 被 ROM 屏蔽时原生侧会兜底跳转设置列表并返回 false。
  Future<bool> request() async {
    if (!_supported) return true;
    final r = await _invoke('request');
    return r == true;
  }

  /// 跳转到系统电池优化设置列表，供用户手动处理。返回是否成功打开。
  Future<bool> openSettings() async {
    if (!_supported) return false;
    final r = await _invoke('openSettings');
    return r == true;
  }

  /// 后台任务启动前调用：若尚未豁免且本机未提示过，返回 true 表示调用方应提示用户。
  /// 只判定「是否该提示」，不弹任何 UI——UI 由调用方（页面）负责，以复用其对话框风格。
  /// 每台设备最多提示一次；用户之后可在设置里随时手动开启。
  Future<bool> shouldPrompt() async {
    if (!_supported) return false;
    if (appdata.settings[_promptedKey] == true) return false;
    return !await isIgnoring();
  }

  /// 标记已提示过，之后 [shouldPrompt] 不再返回 true。
  void markPrompted() {
    if (!_supported) return;
    if (appdata.settings[_promptedKey] == true) return;
    appdata.settings[_promptedKey] = true;
    appdata.saveData();
  }

  Future<Object?> _invoke(String method, [Object? args]) async {
    try {
      return await _channel.invokeMethod(method, args);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}

/// 后台任务启动时的一次性引导：仅当尚未豁免且本机未提示过时，弹一次对话框解释
/// 为什么后台任务会卡死并提供一键请求豁免。无论用户是否同意都标记为已提示，
/// 之后不再打扰——用户可在「设置 → 后台」里随时手动开启。非 Android 无操作。
Future<void> maybePromptBatteryOptimization() async {
  if (!await BatteryOptimization.instance.shouldPrompt()) return;
  BatteryOptimization.instance.markPrompted();
  final context = App.rootContext;
  showConfirmDialog(
    context: context,
    title: "Keep Background Tasks Running".tl,
    content:
        "System battery optimization may freeze background tasks (follow-up checks, sync, import/export, downloads) shortly after the app leaves the foreground. Allow ignoring battery optimization to keep them running."
            .tl,
    confirmText: "Allow".tl,
    onConfirm: () {
      BatteryOptimization.instance.request();
    },
  );
}

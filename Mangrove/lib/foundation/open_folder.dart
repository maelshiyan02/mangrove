// 用系统文件管理器打开一个文件夹。
//
// ## 🔴 平台分支**只有这一份**
//
// 调用方至少两处，彼此还不在同一层：
//
// | 调用方 | 场景 |
// |---|---|
// | `pages/local_comics_page.dart` | 本地库卡片的「打开文件夹」 |
// | `pages/translation_studio/studio_project_menu.dart` | 「创建成功」弹窗的【打开文件夹】 |
//
// 两处各写一遍 `explorer` / `open` / `xdg-open` 的后果是改一处漏一处 —— 而漏掉的
// 那一处只在**别的平台**上才看得出来，本机构建永远绿。
//
// ## 为什么放在 `foundation/` 而不是某个 page 里
//
// `pages/local_comics_page.dart` 已经导入了
// `pages/translation_studio/studio_project_menu.dart`（工程段空状态卡片的加号走
// 它的创建向导）。让后者反过来导入前者就成了环。放到最底层，两个调用方都朝下
// 依赖，环自然消失 —— 这是"抽公共函数"唯一正确的落点，抽到任一侧都还是环。
library;

import 'dart:io';

import 'package:url_launcher/url_launcher_string.dart';

import 'package:mangrove/foundation/app.dart';
import 'package:mangrove/foundation/context.dart';
import 'package:mangrove/foundation/log.dart';

/// Opens [folderPath] in the system file explorer.
///
/// 失败**不抛**：打开资源管理器失败只是"没反应"，抛出去会让调用方（一个按钮）
/// 把整条创建流程打断。错误进日志，并给一句能看见的提示。
Future<void> openFolderPath(String folderPath) async {
  try {
    if (App.isWindows) {
      await Process.run('explorer', [folderPath]);
    } else if (App.isMacOS) {
      await Process.run('open', [folderPath]);
    } else if (App.isLinux) {
      // Try different file managers commonly found on Linux
      try {
        await Process.run('xdg-open', [folderPath]);
      } catch (e) {
        // Fallback to other common file managers
        try {
          await Process.run('nautilus', [folderPath]);
        } catch (e) {
          try {
            await Process.run('dolphin', [folderPath]);
          } catch (e) {
            try {
              await Process.run('thunar', [folderPath]);
            } catch (e) {
              // Last resort: use the URL launcher with file:// protocol
              await launchUrlString('file://$folderPath');
            }
          }
        }
      }
    } else {
      // For mobile platforms, use the URL launcher with file:// protocol
      await launchUrlString('file://$folderPath');
    }
  } catch (e, s) {
    Log.error("Open Folder", "Failed to open folder: $e", s);
    // Show error message to user
    if (App.rootContext.mounted) {
      App.rootContext.showMessage(message: "Failed to open folder: $e");
    }
  }
}

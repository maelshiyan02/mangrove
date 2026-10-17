part of 'settings_page.dart';

/// Settings for local application data and WebDAV synchronization.
class DataSyncSettings extends StatefulWidget {
  const DataSyncSettings({super.key});

  @override
  State<DataSyncSettings> createState() => _DataSyncSettingsState();
}

class _DataSyncSettingsState extends State<DataSyncSettings> {
  String _importTaskMessage(ImportTask task) {
    if (task.phase == ImportPhase.extracting) {
      if (task.extractedBytes <= 0) return "Extracting".tl;
      return "${"Extracting".tl} · "
          "${"Extracted @size".tlParams({'size': bytesToReadableString(task.extractedBytes)})}";
    }
    var key = task.phase == ImportPhase.applying && task.message != null
        ? task.message!
        : importPhaseLabelKey(task.phase);
    return key.tl;
  }

  Future<void> _openFolder(String path) async {
    final uri = Uri.file(path);
    if (await canLaunchUrlString(uri.toString())) {
      await launchUrlString(uri.toString());
    }
  }

  void _showSyncLogsDialog(BuildContext context) {
    final logs = DataSync().syncLogs;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text("Sync Logs".tl),
        content: SizedBox(
          width: double.maxFinite,
          height: 400,
          child: logs.isEmpty
              ? Center(child: Text("No logs".tl))
              : ListView.builder(
                  itemCount: logs.length,
                  itemBuilder: (_, i) {
                    final log = logs[i];
                    final time = DateTime.fromMillisecondsSinceEpoch(
                      log['time'] as int? ?? 0,
                    );
                    final action = log['action'] as String? ?? '';
                    final success = log['success'] as bool? ?? false;
                    final error = log['error'] as String?;
                    final fileName = log['fileName'] as String?;
                    return ListTile(
                      dense: true,
                      leading: Icon(
                        success ? Icons.check_circle : Icons.error,
                        color: success ? Colors.green : Colors.red,
                        size: 20,
                      ),
                      title: Text(
                        action == 'upload'
                            ? 'Upload'.tl
                            : action == 'download'
                            ? 'Download'.tl
                            : action,
                        style: const TextStyle(fontSize: 14),
                      ),
                      subtitle: Text(
                        '${time.toString().substring(0, 19)}${fileName != null ? '\n$fileName' : ''}${error != null ? '\n$error' : ''}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text("Close".tl),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      scrollbarTopPadding: context.padding.top + 56,
      slivers: [
        SliverAppbar(title: Text("Data & Sync".tl)),
        _SettingsExpansionTile(
          expansionKey: const PageStorageKey('dataSyncDataGroup'),
          initiallyExpanded: true,
          icon: Icons.storage,
          title: "Data".tl,
          children: [
            ListTile(
              title: Text("Storage Path for local comics".tl),
              subtitle: Text(LocalManager().path, softWrap: false),
              trailing: IconButton(
                icon: const Icon(Icons.copy),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: LocalManager().path));
                  context.showMessage(message: "Path copied to clipboard".tl);
                },
              ),
            ),
            _CallbackSetting(
              title: "Set New Storage Path".tl,
              actionTitle: "Set".tl,
              callback: () async {
                String? result;
                if (App.isAndroid) {
                  var picker = DirectoryPicker();
                  result = (await picker.pickDirectory())?.path;
                } else if (App.isIOS) {
                  result = await selectDirectoryIOS();
                } else {
                  result = await selectDirectory();
                }
                if (result == null) return;
                Future<void> apply({bool allowNonEmpty = false}) async {
                  var loadingDialog = showLoadingDialog(
                    App.rootContext,
                    barrierDismissible: false,
                    allowCancel: false,
                  );
                  var res = await LocalManager().setNewPath(
                    result!,
                    allowNonEmpty: allowNonEmpty,
                  );
                  loadingDialog.close();
                  if (res == LocalManager.dirNotEmptySignal) {
                    showConfirmDialog(
                      context: App.rootContext,
                      title: "Directory is not empty".tl,
                      content:
                          "The selected directory is not empty. Continue to merge local comics into it?"
                              .tl,
                      confirmText: "Continue".tl,
                      onConfirm: () => apply(allowNonEmpty: true),
                    );
                  } else if (res != null) {
                    context.showMessage(message: res);
                  } else {
                    context.showMessage(message: "Path set successfully".tl);
                    setState(() {});
                  }
                }

                await apply();
              },
            ),
            ListTile(
              title: Text("BallonsTranslator 工程根目录"),
              subtitle: Text(
                BtProjectManager.root.isEmpty
                    ? "未设置（翻译工程功能关闭）"
                    : BtProjectManager.root,
                softWrap: false,
              ),
              trailing: IconButton(
                icon: const Icon(Icons.copy),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: BtProjectManager.root));
                  context.showMessage(message: "Path copied to clipboard".tl);
                },
              ),
            ),
            _CallbackSetting(
              title: "设置翻译工作室 / BallonsTranslator 工程根目录",
              actionTitle: "Set".tl,
              callback: () async {
                String? result;
                if (App.isAndroid) {
                  var picker = DirectoryPicker();
                  result = (await picker.pickDirectory())?.path;
                } else if (App.isIOS) {
                  result = await selectDirectoryIOS();
                } else {
                  result = await selectDirectory();
                }
                if (result == null) return;
                appdata.settings['btProjectRoot'] = result;
                appdata.saveData();
                var loadingDialog = showLoadingDialog(
                  App.rootContext,
                  barrierDismissible: false,
                  allowCancel: false,
                );
                await BtProjectManager().scan();
                loadingDialog.close();
                context.showMessage(message: "Path set successfully".tl);
                setState(() {});
              },
            ),
            _CallbackSetting(
              title: "清除翻译工作室 / BallonsTranslator 工程根目录",
              actionTitle: "Clear".tl,
              callback: () async {
                appdata.settings['btProjectRoot'] = '';
                appdata.saveData();
                await BtProjectManager().scan();
                setState(() {});
              },
            ),
            ListTile(
              title: Text("Cache Size".tl),
              subtitle: Text(bytesToReadableString(CacheManager().currentSize)),
            ),
            _CallbackSetting(
              title: "Clear Cache".tl,
              actionTitle: "Clear".tl,
              callback: () async {
                var loadingDialog = showLoadingDialog(
                  App.rootContext,
                  barrierDismissible: false,
                  allowCancel: false,
                );
                await CacheManager().clear();
                loadingDialog.close();
                context.showMessage(message: "Cache cleared".tl);
                setState(() {});
              },
            ),
            _SettingsExpansionTile(
              expansionKey: const PageStorageKey('appDataStorageGroup'),
              initiallyExpanded: true,
              icon: Icons.folder,
              title: "App Data Storage Location".tl,
              children: [
                ListTile(
                  title: Text("Data Directory".tl),
                  subtitle: Text(
                    App.dataDirectoryOverride != null
                        ? '${App.dataPath} (${"Custom".tl})'
                        : '${App.dataPath} (${"Portable".tl})',
                    softWrap: false,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.folder_open),
                        tooltip: "Open Folder".tl,
                        onPressed: () => _openFolder(App.dataPath),
                      ),
                      IconButton(
                        icon: const Icon(Icons.copy),
                        tooltip: "Copy".tl,
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: App.dataPath));
                          context.showMessage(
                            message: "Path copied to clipboard".tl,
                          );
                        },
                      ),
                    ],
                  ),
                ),
                ListTile(
                  title: Text("Comic Cache Directory".tl),
                  subtitle: Text(CacheManager.configuredPath, softWrap: false),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.folder_open),
                        tooltip: "Open Folder".tl,
                        onPressed: () => _openFolder(CacheManager.configuredPath),
                      ),
                      IconButton(
                        icon: const Icon(Icons.copy),
                        tooltip: "Copy".tl,
                        onPressed: () {
                          Clipboard.setData(
                            ClipboardData(text: CacheManager.configuredPath),
                          );
                          context.showMessage(
                            message: "Path copied to clipboard".tl,
                          );
                        },
                      ),
                    ],
                  ),
                ),
                _CallbackSetting(
                  title: "Change Data Directory".tl,
                  actionTitle: "Change".tl,
                  callback: () async {
                    final result = await selectDirectory();
                    if (result == null || result.isEmpty) return;
                    final dir = Directory(result);
                    if (!dir.existsSync()) {
                      try {
                        dir.createSync(recursive: true);
                      } catch (e) {
                        if (mounted) {
                          context.showMessage(
                            message: "Cannot create directory: $e".tl,
                          );
                        }
                        return;
                      }
                    }
                    await App.setDataDirectoryOverride(result);
                    if (mounted) {
                      context.showMessage(
                        message:
                            "Data directory set, please restart the app to apply".tl,
                      );
                      setState(() {});
                    }
                  },
                ),
                _CallbackSetting(
                  title: "Change Comic Cache Directory".tl,
                  actionTitle: "Change".tl,
                  callback: () async {
                    final result = await selectDirectory();
                    if (result == null || result.isEmpty) return;
                    try {
                      await CacheManager.setCustomDirectory(result);
                      if (mounted) {
                        context.showMessage(
                          message:
                              "Comic cache directory set, please restart the app to apply"
                                  .tl,
                        );
                        setState(() {});
                      }
                    } catch (e) {
                      if (mounted) {
                        context.showMessage(message: e.toString().tl);
                      }
                    }
                  },
                ),
                ListTile(
                  title: Text(
                    "Changing the directory takes effect after restarting the app."
                        .tl,
                  ),
                  subtitle: Text(
                    "History, settings, cache and cookies are all stored under the data directory."
                        .tl,
                  ),
                ),
              ],
            ),
            _CallbackSetting(
              title: "Cache Limit".tl,
              subtitle: "${appdata.settings['cacheSize']} MB",
              callback: () {
                showInputDialog(
                  context: context,
                  title: "Set Cache Limit".tl,
                  hintText: "Size in MB".tl,
                  inputValidator: RegExp(r"^\d+$"),
                  onConfirm: (value) {
                    appdata.settings['cacheSize'] = int.parse(value);
                    appdata.saveData();
                    setState(() {});
                    CacheManager().setLimitSize(appdata.settings['cacheSize']);
                    return null;
                  },
                );
              },
              actionTitle: 'Set'.tl,
            ),
            SelectSetting(
              title: "Auto clean reading history".tl,
              settingKey: "autoCleanHistoryDays",
              help:
                  "Automatically delete reading history older than the selected period when the app starts."
                      .tl,
              optionTranslation: {
                "0": "Never".tl,
                "7": "7 days".tl,
                "30": "30 days".tl,
                "90": "90 days".tl,
                "180": "180 days".tl,
                "365": "365 days".tl,
              },
            ),
            _CallbackSetting(
              title: "Export App Data".tl,
              callback: () async {
                var controller = showLoadingDialog(context);
                var file = await exportAppData(sync: false);
                await saveFile(filename: "data.mangrove", file: file);
                controller.close();
              },
              actionTitle: 'Export'.tl,
            ),
            _CallbackSetting(
              title: "Import App Data".tl,
              callback: () async {
                var file = await selectFile(ext: ['mangrove', 'picadata']);
                if (file == null) return;
                var manager = ImportTaskManager.instance;
                var task = manager.startImport(
                  filePath: file.path,
                  fileName: file.name,
                  isPica: file.name.endsWith('picadata'),
                );
                if (task == null) {
                  context.showMessage(
                    message: "An import task is already running".tl,
                  );
                  return;
                }
                var controller = showLoadingDialog(
                  context,
                  withProgress: true,
                  barrierDismissible: false,
                  message: _importTaskMessage(task),
                  secondaryButtonText: "Background",
                  onSecondary: () {},
                  cancelButtonText: "Cancel",
                  onCancel: () => manager.cancel(task.id),
                );
                void listener() {
                  if (controller.closed) {
                    manager.removeListener(listener);
                    return;
                  }
                  controller.setProgress(task.indicatorValue);
                  controller.setMessage(_importTaskMessage(task));
                  if (!task.isRunning) {
                    manager.removeListener(listener);
                    controller.close();
                    if (task.status == ImportTaskStatus.completed) {
                      App.rootContext.showMessage(
                        message: "Import completed".tl,
                      );
                    } else if (task.status == ImportTaskStatus.failed) {
                      App.rootContext.showMessage(
                        message: (task.error ?? "Import failed").tl,
                      );
                    }
                  }
                }

                manager.addListener(listener);
                listener();
              },
              actionTitle: 'Import'.tl,
            ),
          ],
        ).toSliver(),
        // 「下载管理」（2026-10-16 从「数据与同步」拆出第三类）：目前只放
        // 自动缺页修复开关，图标与主页下载管理分区统一。
        _SettingsExpansionTile(
          expansionKey: const PageStorageKey('dataSyncDownloadManagerGroup'),
          initiallyExpanded: true,
          icon: Icons.download_for_offline,
          title: "Download Management".tl,
          children: [
            ListTile(
              title: Text("Auto Repair Missing Pages".tl),
              subtitle: Text(
                "Automatically create per-chapter repair tasks when a download finishes with missing pages."
                    .tl,
              ),
              trailing: const RepairModeDropdown(),
            ),
          ],
        ).toSliver(),
        _SettingsExpansionTile(
          expansionKey: const PageStorageKey('dataSyncWebdavGroup'),
          initiallyExpanded: true,
          icon: Icons.cloud_sync_outlined,
          title: "WebDAV Sync".tl,
          children: [
            _CallbackSetting(
              title: "Data Sync".tl,
              callback: () async {
                showPopUpWidget(context, const _WebdavSetting());
              },
              actionTitle: 'Set'.tl,
            ),
            const _WebdavSyncOptions(),
            _CallbackSetting(
              title: "Sync Logs".tl,
              callback: () async {
                _showSyncLogsDialog(context);
              },
              actionTitle: 'View'.tl,
            ),
            _CallbackSetting(
              title: "WebDAV Comic Library".tl,
              callback: () async {
                App.rootContext.to(() => const WebdavLibrariesPage());
              },
              actionTitle: 'Set'.tl,
            ),
          ],
        ).toSliver(),
      ],
    );
  }
}

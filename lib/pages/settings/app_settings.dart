// ignore_for_file: no_leading_underscores_for_local_identifiers

part of 'settings_page.dart';

void _showSettingMessage(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  messenger?.hideCurrentSnackBar();
  messenger?.showSnackBar(
    SnackBar(
      content: Text(message),
      duration: const Duration(seconds: 2),
    ),
  );
}

Future<void> _refreshLocalComics(BuildContext context) async {
  _showSettingMessage(context, '正在刷新本地漫画'.tl);
  refreshLocalDataCaches();
  await appdata.readData();
  await DownloadManager().init();
  await LocalFavoritesManager().init();
  App.notifyLocalDataChanged();
  if (context.mounted) {
    _showSettingMessage(context, '已刷新本地漫画'.tl);
  }
}

Future<void> _rescanLocalComics(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('重新扫描'.tl),
      content: Text('将按当前下载目录重新扫描漫画文件并更新数据库。'.tl),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text('取消'.tl),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text('确定'.tl),
        ),
      ],
    ),
  );
  if (!context.mounted || confirmed != true) {
    return;
  }
  await _runRescanLocalComics(context);
}

Future<void> _runRescanLocalComics(BuildContext context) async {
  _showSettingMessage(context, '正在扫描...'.tl);
  refreshLocalDataCaches();
  await DownloadManager().init();
  final count = DownloadManager().scanDirectoryForComics();
  await LocalFavoritesManager().init();
  App.notifyLocalDataChanged();
  if (context.mounted) {
    _showSettingMessage(context, '扫描完成，共发现 $count 个漫画');
  }
}

Widget buildAppSettings(double width, BuildContext context) {
  return buildTwoColumnLayout(width, [
    SettingsTitle('日志'.tl),
    ListTile(
      leading: const Icon(Icons.bug_report),
      title: const Text('Logs'),
      trailing: const Icon(Icons.arrow_right),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const LogSetting()),
        );
      },
    ),
    SettingsTitle('数据'.tl),
    const _DownloadDirTile(),
    ListTile(
      leading: const Icon(Icons.refresh),
      title: Text('数据管理-刷新本地漫画'.tl),
      subtitle: Text('重新加载下载目录和本地收藏数据'.tl),
      onTap: () => _refreshLocalComics(context),
    ),
    ListTile(
      leading: const Icon(Icons.sd_storage_rounded),
      title: Text('重新扫描磁盘'.tl),
      subtitle: Text('从下载目录重新扫描漫画文件并更新数据库'.tl),
      onTap: () => _rescanLocalComics(context),
    ),
    SettingsTitle('权限'.tl),
    ListTile(
      leading: const Icon(Icons.security),
      title: Text('权限管理'.tl),
      trailing: const Icon(Icons.arrow_right),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const PermissionSetting()),
        );
      },
    ),
    SettingsTitle('其它'.tl),
    ListTile(
      leading: const Icon(Icons.language),
      title: Text('语言'.tl),
      trailing: SizedBox(
        width: 140,
        child: Select(
          initialValue: appdata.settings[50],
          values: const ['', 'cn', 'tw', 'en'],
          titles: const ['System', '中文(简体)', '中文(繁體)', 'English'],
          onChanged: (value) {
            appdata.settings[50] = value;
            appdata.updateSettings();
            App.updater?.call();
          },
        ),
      ),
    ),
  ]);
}

class _DownloadDirTile extends StatefulWidget {
  const _DownloadDirTile();

  @override
  State<_DownloadDirTile> createState() => _DownloadDirTileState();
}

class _DownloadDirTileState extends State<_DownloadDirTile> {
  Future<String?> _pickFolder() async {
    try {
      return await FilePicker.platform.getDirectoryPath();
    } catch (_) {
      return null;
    }
  }

  void _openCurrentDirectory(String path) {
    if (Platform.isWindows) {
      Process.run('explorer', [path]);
    } else if (Platform.isMacOS) {
      Process.run('open', [path]);
    } else if (Platform.isLinux) {
      Process.run('xdg-open', [path]);
    }
  }

  void _showBrowseDialog() {
    final controller = TextEditingController(text: appdata.settings[22]);
    final isDesktop =
        Platform.isWindows || Platform.isMacOS || Platform.isLinux;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('设置下载目录'.tl),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    decoration: InputDecoration(
                      hintText: '请输入下载目录路径'.tl,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: () async {
                    final picked = await _pickFolder();
                    if (picked != null) {
                      controller.text = picked;
                    }
                  },
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: Text('浏览'.tl),
                ),
              ],
            ),
            if (isDesktop && controller.text.isNotEmpty) ...[
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () {
                    _openCurrentDirectory(controller.text.trim());
                  },
                  icon: const Icon(Icons.launch, size: 18),
                  label: Text('打开当前目录'.tl),
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('取消'.tl),
          ),
          TextButton(
            onPressed: () async {
              final newPath = controller.text.trim();
              final changed = newPath != appdata.settings[22];
              appdata.settings[22] = newPath;
              await appdata.updateSettings();
              if (!ctx.mounted || !mounted) {
                return;
              }
              Navigator.of(ctx).pop();
              setState(() {});
              if (changed) {
                await _runRescanLocalComics(context);
              }
            },
            child: Text('确定'.tl),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final path = appdata.settings[22];
    final display = path.isEmpty ? '未设置'.tl : path;
    return ListTile(
      leading: const Icon(Icons.folder),
      title: Text('下载目录'.tl),
      trailing: GestureDetector(
        onTap: _showBrowseDialog,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 160),
          height: 40,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Theme.of(context).colorScheme.outline),
          ),
          child: Text(
            display,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14),
          ),
        ),
      ),
    );
  }
}

class LogSetting extends StatefulWidget {
  const LogSetting({super.key});

  @override
  State<LogSetting> createState() => _LogSettingState();
}

class _LogSettingState extends State<LogSetting> {
  Future<void> _exportLogs() async {
    final directory = Directory('${App.dataPath}/logs');
    if (!directory.existsSync()) {
      directory.createSync(recursive: true);
    }
    final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final file = File('${directory.path}/picakeep-log-$timestamp.txt');
    await file.writeAsString(LogManager().toString());

    if (App.isDesktop) {
      final location =
          await getSaveLocation(suggestedName: file.uri.pathSegments.last);
      if (location == null) {
        return;
      }
      await XFile(file.path).saveTo(location.path);
      if (mounted) {
        _showSettingMessage(context, '日志已导出'.tl);
      }
      return;
    }

    await Share.shareXFiles([XFile(file.path)], text: 'PicaKeep Logs');
  }

  Color _levelColor(ColorScheme scheme, LogLevel level) {
    return switch (level) {
      LogLevel.error => scheme.error,
      LogLevel.warning => scheme.errorContainer,
      LogLevel.info => scheme.primaryContainer,
    };
  }

  Color _levelTextColor(LogLevel level) {
    return level == LogLevel.error ? Colors.white : Colors.black;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Logs'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) async {
              if (value == 'clear') {
                setState(LogManager.clear);
              } else if (value == 'ignore') {
                LogManager.ignoreLimitation = true;
                _showSettingMessage(context, '仅在本次运行时有效'.tl);
              } else if (value == 'export') {
                await _exportLogs();
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem<String>(
                value: 'clear',
                child: Text('清空'.tl),
              ),
              PopupMenuItem<String>(
                value: 'ignore',
                child: Text('禁用长度限制'.tl),
              ),
              PopupMenuItem<String>(
                value: 'export',
                child: Text('导出'.tl),
              ),
            ],
          ),
        ],
      ),
      body: LogManager.logs.isEmpty
          ? Center(child: Text('暂无日志'.tl))
          : ListView.builder(
              reverse: true,
              itemCount: LogManager.logs.length,
              itemBuilder: (context, index) {
                final log = LogManager.logs[LogManager.logs.length - index - 1];
                final colorScheme = Theme.of(context).colorScheme;
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: SelectionArea(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              decoration: BoxDecoration(
                                color: colorScheme.surfaceContainerHighest,
                                borderRadius: const BorderRadius.all(
                                  Radius.circular(16),
                                ),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(5, 0, 5, 1),
                                child: Text(log.title),
                              ),
                            ),
                            const SizedBox(width: 3),
                            Container(
                              decoration: BoxDecoration(
                                color: _levelColor(colorScheme, log.level),
                                borderRadius: const BorderRadius.all(
                                  Radius.circular(16),
                                ),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(5, 0, 5, 1),
                                child: Text(
                                  log.level.name,
                                  style: TextStyle(
                                    color: _levelTextColor(log.level),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(log.content),
                        const SizedBox(height: 4),
                        Text(
                          log.time
                              .toString()
                              .replaceAll(RegExp(r'\.\w+'), ''),
                        ),
                        TextButton(
                          onPressed: () async {
                            await Clipboard.setData(
                              ClipboardData(text: log.content),
                            );
                            if (context.mounted) {
                              _showSettingMessage(context, '已复制'.tl);
                            }
                          },
                          child: Text('复制'.tl),
                        ),
                        const Divider(),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class PermissionSetting extends StatefulWidget {
  const PermissionSetting({super.key});

  @override
  State<PermissionSetting> createState() => _PermissionSettingState();
}

class _PermissionSettingState extends State<PermissionSetting> {
  final LocalAuthentication _localAuthentication = LocalAuthentication();

  Future<bool> _isAuthSupported() async {
    try {
      final isDeviceSupported = await _localAuthentication.isDeviceSupported();
      final canCheckBiometrics =
          await _localAuthentication.canCheckBiometrics;
      final availableBiometrics =
          await _localAuthentication.getAvailableBiometrics();
      return isDeviceSupported ||
          canCheckBiometrics ||
          availableBiometrics.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<void> _setScreenshotProtection(bool value) async {
    setState(() {
      appdata.settings[12] = value ? '1' : '0';
    });
    await appdata.updateSettings();
    if (value) {
      await blockScreenshot();
    }
    if (mounted) {
      _showSettingMessage(context, '需要重启App以应用更改'.tl);
    }
  }

  Future<void> _setAuthenticationRequired(bool value) async {
    if (value) {
      final supported = await _isAuthSupported();
      if (!supported) {
        if (mounted) {
          _showSettingMessage(context, '当前设备未配置可用的身份验证方式'.tl);
        }
        return;
      }
    }

    setState(() {
      appdata.settings[13] = value ? '1' : '0';
    });
    await appdata.updateSettings();

    if (value && mounted) {
      AuthPage.initial = false;
      AuthPage.lock = true;
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const AuthPage()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopUpWidgetScaffold(
      title: '权限管理'.tl,
      child: ListView(
        children: [
          SettingsTitle('隐私'.tl),
          if (App.isAndroid)
            ListTile(
              leading: const Icon(Icons.screenshot),
              title: Text('阻止屏幕截图'.tl),
              subtitle: Text('需要重启App以应用更改'.tl),
              trailing: Switch(
                value: appdata.settings[12] == '1',
                onChanged: _setScreenshotProtection,
              ),
            ),
          ListTile(
            leading: const Icon(Icons.security),
            title: Text('需要身份验证'.tl),
            subtitle: Text('如果系统中未设置任何认证方法请勿开启'.tl),
            trailing: Switch(
              value: appdata.settings[13] == '1',
              onChanged: _setAuthenticationRequired,
            ),
          ),
        ],
      ),
    );
  }
}
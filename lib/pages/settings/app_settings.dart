// ignore_for_file: no_leading_underscores_for_local_identifiers

part of 'settings_page.dart';

void _showSettingMessage(BuildContext context, String message) {
  LogManager.addLog(LogLevel.info, 'SettingsMessage', message);

  if (Scaffold.maybeOf(context) == null) {
    return;
  }

  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) {
    return;
  }

  try {
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
      ),
    );
  } catch (e, s) {
    LogManager.addLog(
      LogLevel.warning,
      'SettingsMessage',
      'Failed to show snack bar for "$message": $e\n$s',
    );
  }
}

void _notifyManagedDataViews() {
  try {
    App.notifyLocalDataChanged();
  } catch (e, s) {
    LogManager.addLog(
      LogLevel.error,
      'ManagedDataReload',
      'Failed to notify app local data change: $e\n$s',
    );
  }

  try {
    StateController.findOrNull<SimpleController>(tag: 'image_favorites_page')
        ?.update();
  } catch (e, s) {
    LogManager.addLog(
      LogLevel.error,
      'ManagedDataReload',
      'Failed to update image favorites page: $e\n$s',
    );
  }
}

Future<int?> _reloadManagedDataManagers({bool rescanLocalComics = false}) async {
  LogManager.addLog(
    LogLevel.info,
    'ManagedDataReload',
    'start rescan=$rescanLocalComics',
  );
  refreshLocalDataCaches();

  LogManager.addLog(LogLevel.info, 'ManagedDataReload', 'appdata.readData:start');
  await appdata.readData().timeout(const Duration(seconds: 5));
  LogManager.addLog(LogLevel.info, 'ManagedDataReload', 'appdata.readData:ok');

  LogManager.addLog(
    LogLevel.info,
    'ManagedDataReload',
    'HistoryManager.init:start',
  );
  await HistoryManager().init().timeout(const Duration(seconds: 10));
  LogManager.addLog(LogLevel.info, 'ManagedDataReload', 'HistoryManager.init:ok');

  LogManager.addLog(
    LogLevel.info,
    'ManagedDataReload',
    'DownloadManager.init:start',
  );
  await DownloadManager().init().timeout(const Duration(seconds: 10));
  LogManager.addLog(LogLevel.info, 'ManagedDataReload', 'DownloadManager.init:ok');

  int? scanCount;
  if (rescanLocalComics) {
    LogManager.addLog(
      LogLevel.info,
      'ManagedDataReload',
      'LocalLibraryManager.rescan:start',
    );
    scanCount = await LocalLibraryManager().rescan();
    LogManager.addLog(
      LogLevel.info,
      'ManagedDataReload',
      'LocalLibraryManager.rescan:ok count=$scanCount',
    );
  } else {
    LogManager.addLog(
      LogLevel.info,
      'ManagedDataReload',
      'LocalLibraryManager.refresh:start',
    );
    await LocalLibraryManager().refresh();
    LogManager.addLog(
      LogLevel.info,
      'ManagedDataReload',
      'LocalLibraryManager.refresh:ok',
    );
  }

  LogManager.addLog(
    LogLevel.info,
    'ManagedDataReload',
    'LocalFavoritesManager.init:start',
  );
  await LocalFavoritesManager().init().timeout(const Duration(seconds: 15));
  LogManager.addLog(
    LogLevel.info,
    'ManagedDataReload',
    'LocalFavoritesManager.init:ok',
  );

  _notifyManagedDataViews();
  LogManager.addLog(LogLevel.info, 'ManagedDataReload', 'notifyViews:ok');
  return scanCount;
}

Future<void> _refreshLocalComics(BuildContext context) async {
  _showSettingMessage(context, '正在刷新本地漫画'.tl);
  await _reloadManagedDataManagers();
  if (context.mounted) {
    _showSettingMessage(context, '已刷新本地漫画'.tl);
  }
}

  Future<void> _changeManagedDataSourceMode(
  BuildContext context,
  String value,
) async {
  final nextValue = normalizeManagedDataSourceMode(value);
  final previousValue = appdata.settings[managedDataSourceModeSettingIndex];
  LogManager.addLog(
    LogLevel.info,
    'ManagedDataSourceMode',
    'switch request $previousValue -> $nextValue',
  );
  if (nextValue == previousValue) {
    return;
  }
  _showSettingMessage(context, '正在切换数据库路径'.tl);
  appdata.settings[managedDataSourceModeSettingIndex] = nextValue;
  setManagedDataSourceMode(nextValue);
  await appdata.updateSettings().timeout(const Duration(seconds: 5));
  try {
    await _reloadManagedDataManagers().timeout(const Duration(seconds: 20));
    LogManager.addLog(
      LogLevel.info,
      'ManagedDataSourceMode',
      'switch success $previousValue -> $nextValue',
    );
    if (context.mounted) {
      _showSettingMessage(context, '已切换数据库路径'.tl);
    }
  } catch (e, s) {
    LogManager.addLog(
      LogLevel.error,
      'ManagedDataSourceMode',
      'Failed to switch managed data source mode from $previousValue to $nextValue: $e\n$s',
    );
    appdata.settings[managedDataSourceModeSettingIndex] = previousValue;
    setManagedDataSourceMode(previousValue);
    await appdata.updateSettings().timeout(const Duration(seconds: 5));
    try {
      await _reloadManagedDataManagers().timeout(const Duration(seconds: 20));
    } catch (rollbackError, rollbackStack) {
      LogManager.addLog(
        LogLevel.error,
        'ManagedDataSourceMode',
        'Rollback failed for managed data source mode $nextValue -> $previousValue: $rollbackError\n$rollbackStack',
      );
    }
    if (context.mounted) {
      _showSettingMessage(context, '切换失败，已恢复原设置'.tl);
    }
    return;
  }
}

Future<void> _rescanLocalComics(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('重新扫描'.tl),
      content: Text('将按当前设置重新扫描本应用下载目录、原应用下载目录与自定义本地漫画路径。'.tl),
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
  final count = await _reloadManagedDataManagers(rescanLocalComics: true) ?? 0;
  if (context.mounted) {
    _showSettingMessage(context, '扫描完成，当前共 $count 个本地项目'.tl);
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
    const _OriginalDownloadDirTile(),
    const _LocalComicPathsTile(),
    const _LocalAlbumImageSortTile(),
    const _LocalLibraryListSortTile(),
    _ManagedDataSourceModeTile(
      width: width,
      onRefresh: () => _refreshLocalComics(context),
      onChanged: (value) => _changeManagedDataSourceMode(context, value),
    ),
    ListTile(
      leading: const Icon(Icons.sd_storage_rounded),
      title: Text('重新扫描磁盘'.tl),
      subtitle: Text('按当前设置重新扫描本应用下载目录、原应用下载目录与自定义本地漫画路径'.tl),
      onTap: () => _rescanLocalComics(context),
    ),
    SettingsTitle('隐私'.tl),
    if (App.isAndroid)
      SwitchSetting(
        leading: const Icon(Icons.screenshot),
        title: '阻止屏幕截图'.tl,
        subTitle: '需要重启App以应用更改'.tl,
        settingsIndex: 12,
      ),
    SwitchSetting(
      leading: const Icon(Icons.security),
      title: '需要身份验证'.tl,
      subTitle: '如果系统中未设置任何认证方法请勿开启'.tl,
      settingsIndex: 13,
    ),
    SettingsTitle('其它'.tl),
    const _LanguageSettingTile(),
  ]);
}

class _ManagedDataSourceModeTile extends StatefulWidget {
  const _ManagedDataSourceModeTile({
    required this.width,
    required this.onRefresh,
    required this.onChanged,
  });

  final double width;
  final VoidCallback onRefresh;
  final Future<void> Function(String value) onChanged;

  @override
  State<_ManagedDataSourceModeTile> createState() =>
      _ManagedDataSourceModeTileState();
}

class _ManagedDataSourceModeTileState extends State<_ManagedDataSourceModeTile> {
  String? _pendingValue;
  bool _busy = false;

  String get _currentValue => normalizeManagedDataSourceMode(
        _pendingValue ?? appdata.settings[managedDataSourceModeSettingIndex],
      );

  Future<void> _selectValue(String value) async {
    LogManager.addLog(
      LogLevel.info,
      'ManagedDataSourceMode',
      'tap current=$_currentValue target=$value busy=$_busy pending=${_pendingValue ?? ''}',
    );
    if (_busy || value == _currentValue) {
      return;
    }
    setState(() {
      _busy = true;
      _pendingValue = value;
    });
    try {
      await widget.onChanged(value).timeout(const Duration(seconds: 20));
    } catch (e, s) {
      LogManager.addLog(
        LogLevel.error,
        'ManagedDataSourceMode',
        'selectValue failed for target=$value: $e\n$s',
      );
      rethrow;
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _pendingValue = null;
        });
      }
    }
  }

  Widget _buildSegment(
    BuildContext context, {
    required String value,
    required String label,
    required bool isFirst,
    required bool isLast,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final selected = _currentValue == value;
    final radius = BorderRadius.only(
      topLeft: isFirst ? const Radius.circular(999) : Radius.zero,
      bottomLeft: isFirst ? const Radius.circular(999) : Radius.zero,
      topRight: isLast ? const Radius.circular(999) : Radius.zero,
      bottomRight: isLast ? const Radius.circular(999) : Radius.zero,
    );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _busy ? null : () => _selectValue(value),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color:
              selected ? colorScheme.primaryContainer : Colors.transparent,
          border: Border(
            left: isFirst
                ? BorderSide.none
                : BorderSide(color: colorScheme.outlineVariant),
          ),
          borderRadius: radius,
        ),
        child: SizedBox(
          height: 36,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(
                label.tl,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: widget.width >= 900 ? 13 : 12,
                  fontWeight: FontWeight.w500,
                  color: selected
                      ? colorScheme.onPrimaryContainer
                      : colorScheme.onSurface,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSelector(BuildContext context) {
    const options = <MapEntry<String, String>>[
      MapEntry(managedDataSourceModeCurrentOnly, '仅本应用'),
      MapEntry(managedDataSourceModeCurrentAndOriginal, '本+原应用'),
      MapEntry(managedDataSourceModeOriginalOnly, '仅原应用'),
    ];
    return Opacity(
      opacity: _busy ? 0.7 : 1,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Theme.of(context).colorScheme.outline),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: Row(
            children: [
              for (int i = 0; i < options.length; i++)
                Expanded(
                  child: _buildSegment(
                    context,
                    value: options[i].key,
                    label: options[i].value,
                    isFirst: i == 0,
                    isLast: i == options.length - 1,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selectorMaxWidth = widget.width >= 900 ? 330.0 : 270.0;
    const minimumSelectorWidth = 120.0;
    const reservedRefreshWidth = 180.0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final availableSelectorWidth =
              constraints.maxWidth - reservedRefreshWidth;
          final selectorWidth = availableSelectorWidth < minimumSelectorWidth
              ? minimumSelectorWidth
              : (availableSelectorWidth < selectorMaxWidth
                  ? availableSelectorWidth
                  : selectorMaxWidth);
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.refresh),
                  title: Text('数据管理-刷新本地漫画'.tl),
                  subtitle: Text(
                    '重新加载下载目录；数据库路径仅作用于本地收藏、图片收藏和历史数据'.tl,
                  ),
                  onTap: widget.onRefresh,
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: selectorWidth,
                child: _buildSelector(context),
              ),
            ],
          );
        },
      ),
    );
  }
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
        title: Text('设置本应用下载目录'.tl),
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
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(0, 48),
                  ),
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
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 48),
                  ),
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

  Widget _buildPathDisplay(BuildContext context, String display) {
    return GestureDetector(
      onTap: _showBrowseDialog,
      child: Container(
        width: double.infinity,
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
    );
  }

  @override
  Widget build(BuildContext context) {
    final path = appdata.settings[22];
    final display = path.isEmpty ? '未设置'.tl : path;
    return buildResponsiveSettingTile(
      leading: const Icon(Icons.folder),
      title: Text('本应用下载目录'.tl),
      trailingWidth: 220,
      onTap: _showBrowseDialog,
      trailing: _buildPathDisplay(context, display),
    );
  }
}

class _OriginalDownloadDirTile extends StatefulWidget {
  const _OriginalDownloadDirTile();

  @override
  State<_OriginalDownloadDirTile> createState() => _OriginalDownloadDirTileState();
}

class _OriginalDownloadDirTileState extends State<_OriginalDownloadDirTile> {
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
    final controller =
        TextEditingController(text: appdata.settings[originalDownloadDirSettingIndex]);
    final isDesktop =
        Platform.isWindows || Platform.isMacOS || Platform.isLinux;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('设置原应用下载目录'.tl),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    decoration: InputDecoration(
                      hintText: '请输入原应用下载目录路径'.tl,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(0, 48),
                  ),
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
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 48),
                  ),
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
              final changed =
                  newPath != appdata.settings[originalDownloadDirSettingIndex];
              appdata.settings[originalDownloadDirSettingIndex] = newPath;
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

  Widget _buildPathDisplay(BuildContext context, String display) {
    return GestureDetector(
      onTap: _showBrowseDialog,
      child: Container(
        width: double.infinity,
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
    );
  }

  @override
  Widget build(BuildContext context) {
    final path = appdata.settings[originalDownloadDirSettingIndex];
    final display = path.isEmpty ? '未设置'.tl : path;
    return buildResponsiveSettingTile(
      leading: const Icon(Icons.folder_shared),
      title: Text('原应用下载目录'.tl),
      subtitle: Text('三档切换会决定该目录是否参与扫描'.tl),
      trailingWidth: 220,
      onTap: _showBrowseDialog,
      trailing: _buildPathDisplay(context, display),
    );
  }
}

class _LocalComicPathsTile extends StatelessWidget {
  const _LocalComicPathsTile();

  @override
  Widget build(BuildContext context) {
    final paths = decodeLocalComicPathList(
      appdata.settings[localComicPathsSettingIndex],
    );
    return ListTile(
      leading: const Icon(Icons.photo_library_outlined),
      title: Text('本地漫画路径'.tl),
      subtitle: Text(
        '已配置 @a 个自定义路径；这些路径始终参与扫描'.tlParams(
          {'a': paths.length.toString()},
        ),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const LocalLibraryFilesPage()),
        );
      },
    );
  }
}

class _LocalAlbumImageSortTile extends StatelessWidget {
  const _LocalAlbumImageSortTile();

  Future<void> _changeSort(String value) async {
    appdata.settings[localAlbumImageSortSettingIndex] =
        normalizeLocalAlbumImageSort(value);
    await appdata.updateSettings();
    await LocalLibraryManager().refresh();
    App.notifyLocalDataChanged();
  }

  @override
  Widget build(BuildContext context) {
    return buildResponsiveSettingTile(
      leading: const Icon(Icons.sort_by_alpha),
      title: Text('本地图集图片排序'.tl),
      subtitle: Text('作用于普通本地图集的阅读图片顺序'.tl),
      trailingWidth: 180,
      trailing: Select(
        width: 180,
        initialValue: normalizeLocalAlbumImageSort(
          appdata.settings[localAlbumImageSortSettingIndex],
        ),
        values: const [
          localAlbumImageSortNameAsc,
          localAlbumImageSortNameDesc,
          localAlbumImageSortTimeAsc,
          localAlbumImageSortTimeDesc,
        ],
        titles: const [
          '名称正序',
          '名称倒序',
          '时间正序',
          '时间倒序',
        ],
        onChanged: (value) async {
          await _changeSort(value);
        },
      ),
    );
  }
}

class _LocalLibraryListSortTile extends StatelessWidget {
  const _LocalLibraryListSortTile();

  Future<void> _changeSort(String value) async {
    appdata.settings[localLibraryListSortSettingIndex] =
        normalizeLocalLibraryListSort(value);
    await appdata.updateSettings();
    App.notifyLocalDataChanged();
  }

  @override
  Widget build(BuildContext context) {
    return buildResponsiveSettingTile(
      leading: const Icon(Icons.view_module_outlined),
      title: Text('本地图集列表排序'.tl),
      trailingWidth: 180,
      trailing: Select(
        width: 180,
        initialValue: normalizeLocalLibraryListSort(
          appdata.settings[localLibraryListSortSettingIndex],
        ),
        values: const [
          'time_desc',
          'time_asc',
          'name_asc',
          'name_desc',
          'size_desc',
          'size_asc',
        ],
        titles: const [
          '最近更新优先',
          '最早更新优先',
          '名称 A-Z',
          '名称 Z-A',
          '体积从大到小',
          '体积从小到大',
        ],
        onChanged: (value) async {
          await _changeSort(value);
        },
      ),
    );
  }
}

class _LanguageSettingTile extends StatelessWidget {
  const _LanguageSettingTile();

  @override
  Widget build(BuildContext context) {
    return buildResponsiveSettingTile(
      leading: const Icon(Icons.language),
      title: Text('语言'.tl),
      trailingWidth: 140,
      trailing: Select(
        width: 140,
        initialValue: appdata.settings[50],
        values: const ['', 'cn', 'tw', 'en'],
        titles: const ['System', '中文(简体)', '中文(繁體)', 'English'],
        onChanged: (value) {
          appdata.settings[50] = value;
          appdata.updateSettings();
          App.updater?.call();
        },
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
// ignore_for_file: no_leading_underscores_for_local_identifiers

part of 'settings_page.dart';

void _showSettingMessage(BuildContext context, String message) {
  if (_suppressNextManagedDataSourceBusyMessage) {
    _suppressNextManagedDataSourceBusyMessage = false;
    return;
  }
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

OverlayEntry? _managedDataModeHintEntry;
Timer? _managedDataModeHintTimer;
bool _suppressNextManagedDataSourceBusyMessage = false;

void _showManagedDataModeHint(BuildContext context, String message) {
  print('[PicaKeep][ManagedDataSourceMode] show hint: $message');
  final contexts = <BuildContext>[
    context,
    if (App.globalContext != null) App.globalContext!,
  ];
  OverlayState? overlay;
  for (final candidate in contexts) {
    overlay = Overlay.maybeOf(candidate, rootOverlay: true);
    if (overlay != null) {
      break;
    }
  }
  if (overlay == null) {
    LogManager.addLog(
      LogLevel.warning,
      'ManagedDataSourceMode',
      'Failed to show hint because no Overlay was found: $message',
    );
    return;
  }

  _managedDataModeHintTimer?.cancel();
  _managedDataModeHintEntry?.remove();

  final theme = Theme.of(context);
  _managedDataModeHintEntry = OverlayEntry(
    builder: (overlayContext) {
      final media =
          MediaQuery.maybeOf(overlayContext) ?? MediaQuery.of(context);
      final bottom = media.viewPadding.bottom + 16;
      return Positioned(
        left: 12,
        right: 12,
        bottom: bottom,
        child: IgnorePointer(
          child: Material(
            color: Colors.transparent,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: theme.colorScheme.inverseSurface,
                borderRadius: BorderRadius.circular(4),
                boxShadow: const [
                  BoxShadow(
                    blurRadius: 10,
                    color: Color(0x33000000),
                    offset: Offset(0, 4),
                  ),
                ],
              ),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                child: Text(
                  message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onInverseSurface,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
  overlay.insert(_managedDataModeHintEntry!);
  _managedDataModeHintTimer = Timer(const Duration(seconds: 5), () {
    _managedDataModeHintEntry?.remove();
    _managedDataModeHintEntry = null;
  });
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
    LocalServerRuntime.instance.markResourceStateDirty();
  } catch (e, s) {
    LogManager.addLog(
      LogLevel.error,
      'ManagedDataReload',
      'Failed to notify local server runtime resource change: $e\n$s',
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

Future<int?> _reloadManagedDataManagers(
    {bool rescanLocalComics = false}) async {
  LogManager.addLog(
    LogLevel.info,
    'ManagedDataReload',
    'start rescan=$rescanLocalComics',
  );
  refreshLocalDataCaches();

  LogManager.addLog(
      LogLevel.info, 'ManagedDataReload', 'appdata.readData:start');
  await appdata.readData().timeout(const Duration(seconds: 5));
  LogManager.addLog(LogLevel.info, 'ManagedDataReload', 'appdata.readData:ok');

  LogManager.addLog(
    LogLevel.info,
    'ManagedDataReload',
    'HistoryManager.init:start',
  );
  await HistoryManager().init().timeout(const Duration(seconds: 10));
  LogManager.addLog(
      LogLevel.info, 'ManagedDataReload', 'HistoryManager.init:ok');

  LogManager.addLog(
    LogLevel.info,
    'ManagedDataReload',
    'prepare current download access:start',
  );
  final localLibraryManager = LocalLibraryManager();
  final mode = normalizeManagedDataSourceMode(
    appdata.settings[managedDataSourceModeSettingIndex],
  );
  final currentDownloadParticipates = mode != managedDataSourceModeOriginalOnly;
  final bypassDirectDownloadManager = await localLibraryManager
      .shouldBypassDirectDownloadManagerForCurrentDownloads();
  if (!currentDownloadParticipates) {
    DownloadManager().dispose();
    LogManager.addLog(
      LogLevel.info,
      'ManagedDataReload',
      'prepare current download access:skip DownloadManager because mode=original_only',
    );
  } else if (bypassDirectDownloadManager) {
    DownloadManager().dispose();
    LogManager.addLog(
      LogLevel.info,
      'ManagedDataReload',
      'prepare current download access:skip DownloadManager for privileged fallback',
    );
  } else {
    await DownloadManager().init().timeout(const Duration(seconds: 10));
    LogManager.addLog(
      LogLevel.info,
      'ManagedDataReload',
      'prepare current download access:DownloadManager.init:ok',
    );
  }

  int? scanCount;
  final privilegedManagedHandling =
      await localLibraryManager.shouldUsePrivilegedManagedDownloadHandling();
  if (rescanLocalComics) {
    if (currentDownloadParticipates && bypassDirectDownloadManager) {
      LogManager.addLog(
        LogLevel.info,
        'ManagedDataReload',
        'LocalLibraryManager.refresh:start (privileged fallback rescan)',
      );
      await localLibraryManager.refresh();
      scanCount = await localLibraryManager
          .refreshCurrentDownloadsWithShizukuFallback();
      LogManager.addLog(
        LogLevel.info,
        'ManagedDataReload',
        'LocalLibraryManager.refresh:ok count=$scanCount (privileged fallback)',
      );
    } else if (privilegedManagedHandling) {
      LogManager.addLog(
        LogLevel.info,
        'ManagedDataReload',
        'LocalLibraryManager.refresh:start (managed privileged refresh)',
      );
      await localLibraryManager.refresh();
      scanCount = (await localLibraryManager.getManagedDownloads()).length;
      LogManager.addLog(
        LogLevel.info,
        'ManagedDataReload',
        'LocalLibraryManager.refresh:ok count=$scanCount (managed privileged refresh)',
      );
    } else {
      LogManager.addLog(
        LogLevel.info,
        'ManagedDataReload',
        'LocalLibraryManager.rescan:start',
      );
      scanCount = await localLibraryManager.rescan();
      LogManager.addLog(
        LogLevel.info,
        'ManagedDataReload',
        'LocalLibraryManager.rescan:ok count=$scanCount',
      );
    }
  } else {
    LogManager.addLog(
      LogLevel.info,
      'ManagedDataReload',
      'LocalLibraryManager.refresh:start',
    );
    await localLibraryManager.refresh();
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

class _AndroidShizukuStatus {
  const _AndroidShizukuStatus({
    required this.installed,
    required this.running,
    required this.permissionGranted,
  });

  final bool installed;
  final bool running;
  final bool permissionGranted;
}

class _AndroidStorageAccessController {
  _AndroidStorageAccessController._();

  static final _AndroidStorageAccessController instance =
      _AndroidStorageAccessController._();

  static const MethodChannel _channel =
      MethodChannel('lingxue.picakeep/storage_access');

  Future<bool> hasManageAllFilesAccess() async {
    if (!App.isAndroid) {
      return true;
    }
    try {
      return await _channel.invokeMethod<bool>('hasManageAllFilesAccess') ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<void> openManageAllFilesAccessSettings() async {
    if (!App.isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('openManageAllFilesAccessSettings');
    } catch (_) {}
  }

  Future<_AndroidShizukuStatus> getShizukuStatus({
    bool forceRefresh = false,
  }) async {
    if (!App.isAndroid) {
      return const _AndroidShizukuStatus(
        installed: false,
        running: false,
        permissionGranted: false,
      );
    }
    try {
      final result = await _channel.invokeMethod<Object>(
        'getShizukuStatus',
        {'forceRefresh': forceRefresh},
      );
      final map = (result as Map?)?.cast<Object?, Object?>() ?? const {};
      return _AndroidShizukuStatus(
        installed: map['installed'] == true,
        running: map['running'] == true,
        permissionGranted: map['permissionGranted'] == true,
      );
    } catch (_) {
      return const _AndroidShizukuStatus(
        installed: false,
        running: false,
        permissionGranted: false,
      );
    }
  }

  Future<bool> isShizukuAvailable() async {
    if (!App.isAndroid) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>('isShizukuAvailable') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> hasShizukuPermission({bool forceRefresh = false}) async {
    if (!App.isAndroid) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>(
            'hasShizukuPermission',
            {'forceRefresh': forceRefresh},
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> requestShizukuPermission() async {
    if (!App.isAndroid) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>('requestShizukuPermission') ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<void> openShizukuApp() async {
    if (!App.isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('openShizukuApp');
    } catch (_) {}
  }

  Future<bool> hasRootAccess({bool forceRefresh = false}) async {
    if (!App.isAndroid) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>(
            'hasRootAccess',
            {'forceRefresh': forceRefresh},
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<List<String>> listDirectoriesWithRoot(String path) async {
    if (!App.isAndroid) {
      return const <String>[];
    }
    try {
      final result = await _channel.invokeListMethod<Object>(
        'listDirectoriesWithRoot',
        {'path': path},
      );
      return (result ?? const <Object>[])
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
    } on PlatformException catch (e) {
      throw Exception((e.message ?? e.code).trim());
    }
  }

  Future<List<Map<String, String>>> listDirectoryEntriesWithRoot(
    String path,
  ) async {
    if (!App.isAndroid) {
      return const <Map<String, String>>[];
    }
    try {
      final result = await _channel.invokeListMethod<Object>(
        'listDirectoryEntriesWithRoot',
        {'path': path},
      );
      return (result ?? const <Object>[])
          .whereType<Map>()
          .map((item) {
            final name = item['name']?.toString().trim() ?? '';
            if (name.isEmpty) {
              return const <String, String>{};
            }
            final type = item['type']?.toString().trim() ?? 'file';
            return <String, String>{
              'name': name,
              'type': type,
            };
          })
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
    } on PlatformException catch (e) {
      throw Exception((e.message ?? e.code).trim());
    }
  }

  Future<List<String>> listDirectoriesWithShizuku(String path) async {
    if (!App.isAndroid) {
      return const <String>[];
    }
    try {
      final result = await _channel.invokeListMethod<Object>(
        'listDirectoriesWithShizuku',
        {'path': path},
      );
      return (result ?? const <Object>[])
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
    } on PlatformException catch (e) {
      throw Exception((e.message ?? e.code).trim());
    }
  }

  Future<List<Map<String, String>>> listDirectoryEntriesWithShizuku(
    String path,
  ) async {
    if (!App.isAndroid) {
      return const <Map<String, String>>[];
    }
    try {
      final result = await _channel.invokeListMethod<Object>(
        'listDirectoryEntriesWithShizuku',
        {'path': path},
      );
      return (result ?? const <Object>[])
          .whereType<Map>()
          .map((item) {
            final name = item['name']?.toString().trim() ?? '';
            if (name.isEmpty) {
              return const <String, String>{};
            }
            final type = item['type']?.toString().trim() ?? 'file';
            return <String, String>{
              'name': name,
              'type': type,
            };
          })
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
    } on PlatformException catch (e) {
      throw Exception((e.message ?? e.code).trim());
    }
  }
}

bool _isAndroidRootModeEnabled() {
  return normalizeAndroidRootMode(
          appdata.settings[androidRootModeSettingIndex]) ==
      '1';
}

bool _isAndroidShizukuModeEnabled() {
  return normalizeAndroidShizukuMode(
        appdata.settings[androidShizukuModeSettingIndex],
      ) ==
      '1';
}

Future<void> _setAndroidShizukuModeEnabled(bool value) async {
  appdata.settings[androidShizukuModeSettingIndex] = value ? '1' : '0';
  await appdata.updateSettings();
}

Future<bool> _requestAndroidRootAccess({bool forceRefresh = false}) async {
  if (!App.isAndroid) {
    return false;
  }
  return _AndroidStorageAccessController.instance.hasRootAccess(
    forceRefresh: forceRefresh,
  );
}

class _AndroidManageAllFilesAccessTile extends StatefulWidget {
  const _AndroidManageAllFilesAccessTile();

  @override
  State<_AndroidManageAllFilesAccessTile> createState() =>
      _AndroidManageAllFilesAccessTileState();
}

class _AndroidManageAllFilesAccessTileState
    extends State<_AndroidManageAllFilesAccessTile>
    with WidgetsBindingObserver {
  bool? _granted;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(_load());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _load();
    }
  }

  Future<void> _load() async {
    final granted = await _AndroidStorageAccessController.instance
        .hasManageAllFilesAccess();
    if (!mounted) {
      return;
    }
    setState(() {
      _granted = granted;
    });
  }

  Future<void> _openSettings() async {
    await _AndroidStorageAccessController.instance
        .openManageAllFilesAccessSettings();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final granted = _granted;
    return ListTile(
      leading: const Icon(Icons.folder_copy_outlined),
      title: Text('安卓全部文件访问权限'.tl),
      subtitle: Text(
        granted == null
            ? '正在检测权限状态'.tl
            : granted
                ? '已授权；长按“浏览”可进入内置文件夹浏览页'.tl
                : '未授权；点击这里跳转系统设置页申请权限'.tl,
      ),
      trailing: Icon(
        granted == true ? Icons.check_circle_outline : Icons.chevron_right,
      ),
      onTap: _openSettings,
    );
  }
}

class _AndroidShizukuModeTile extends StatefulWidget {
  const _AndroidShizukuModeTile();

  @override
  State<_AndroidShizukuModeTile> createState() =>
      _AndroidShizukuModeTileState();
}

class _AndroidShizukuModeTileState extends State<_AndroidShizukuModeTile>
    with WidgetsBindingObserver {
  bool _busy = false;
  bool _enabled = _isAndroidShizukuModeEnabled();
  bool? _installed;
  bool? _running;
  bool? _granted;
  bool _wasBackgrounded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(_load(forceRefresh: true));
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _wasBackgrounded = true;
      return;
    }
    if (state == AppLifecycleState.resumed) {
      if (!_wasBackgrounded || !(ModalRoute.of(context)?.isCurrent ?? false)) {
        return;
      }
      _wasBackgrounded = false;
      unawaited(_load(forceRefresh: true));
    }
  }

  Future<void> _load({bool forceRefresh = false}) async {
    final controller = _AndroidStorageAccessController.instance;
    final status = await controller.getShizukuStatus(
      forceRefresh: forceRefresh,
    );
    var nextEnabled = _isAndroidShizukuModeEnabled();
    if (nextEnabled && !(status.running && status.permissionGranted)) {
      await _setAndroidShizukuModeEnabled(false);
      nextEnabled = false;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _enabled = nextEnabled;
      _installed = status.installed;
      _running = status.running;
      _granted = status.permissionGranted;
    });
  }

  Future<String?> _askEnableAction() {
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('启用 Shizuku'.tl),
        content: Text('是否先打开 Shizuku 检查服务和授权状态？也可以直接发起授权请求。'.tl),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text('取消'.tl),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop('open'),
            child: Text('打开 Shizuku'.tl),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop('request'),
            child: Text('直接授权'.tl),
          ),
        ],
      ),
    );
  }

  Future<void> _setValue(bool value) async {
    if (_busy || value == _enabled) {
      return;
    }
    setState(() {
      _busy = true;
      _enabled = value;
    });
    try {
      final controller = _AndroidStorageAccessController.instance;
      if (value) {
        final action = await _askEnableAction();
        if (!mounted || action == null) {
          setState(() {
            _enabled = _isAndroidShizukuModeEnabled();
          });
          await _load(forceRefresh: true);
          return;
        }
        if (action == 'open') {
          setState(() {
            _enabled = _isAndroidShizukuModeEnabled();
          });
          await controller.openShizukuApp();
          if (mounted) {
            _showSettingMessage(context, '已打开 Shizuku；回到本应用后会自动重新检测服务和授权状态'.tl);
          }
          return;
        }

        final running = _running ??
            (await controller.getShizukuStatus(forceRefresh: true)).running;
        if (!running) {
          await controller.openShizukuApp();
          if (mounted) {
            _showSettingMessage(
                context, '当前未连接到 Shizuku 服务，已为你打开 Shizuku；启动服务后再返回授权'.tl);
          }
          return;
        }

        final granted = await controller.requestShizukuPermission();
        if (!granted) {
          if (mounted) {
            _showSettingMessage(context, '未获取到 Shizuku 授权'.tl);
          }
          await _setAndroidShizukuModeEnabled(false);
          if (mounted) {
            setState(() {
              _enabled = false;
            });
          }
          await _load(forceRefresh: true);
          return;
        }
        await _setAndroidShizukuModeEnabled(true);
      } else {
        await _setAndroidShizukuModeEnabled(false);
      }
      await _load(forceRefresh: true);
      if (mounted && value) {
        _showSettingMessage(context, 'Shizuku 授权已开启，可用于长按“浏览”的受限目录访问'.tl);
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _enabled;
    final subtitle = switch ((_installed, _running, _granted)) {
      (null, _, _) => '正在检测 Shizuku 状态'.tl,
      (false, _, _) => '未安装 Shizuku；点击开关后会尝试打开 Shizuku'.tl,
      (true, null, _) => '正在检测 Shizuku 状态'.tl,
      (true, false, _) => '已安装但当前未连接到 Shizuku 服务；点击开关可直接打开 Shizuku'.tl,
      (true, true, null) => '正在检测 Shizuku 状态'.tl,
      (true, true, false) => '服务已连接但未授权；点击开关时可选择打开 Shizuku 或直接请求授权'.tl,
      (true, true, true) => '已授权；返回本应用时会自动刷新状态，并用于长按“浏览”的受限目录访问'.tl,
    };
    return buildResponsiveSettingTile(
      leading: const Icon(Icons.verified_user_outlined),
      title: Text('Shizuku 授权'.tl),
      subtitle: Text(subtitle),
      trailingWidth: 60,
      trailing: Switch(
        value: enabled,
        onChanged: _busy ? null : _setValue,
      ),
    );
  }
}

class _AndroidRootModeTile extends StatefulWidget {
  const _AndroidRootModeTile();

  @override
  State<_AndroidRootModeTile> createState() => _AndroidRootModeTileState();
}

class _AndroidRootModeTileState extends State<_AndroidRootModeTile>
    with WidgetsBindingObserver {
  bool _busy = false;
  bool _enabled = _isAndroidRootModeEnabled();
  bool _wasBackgrounded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(_load(forceRefresh: true));
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _wasBackgrounded = true;
      return;
    }
    if (state == AppLifecycleState.resumed) {
      if (!_wasBackgrounded || !(ModalRoute.of(context)?.isCurrent ?? false)) {
        return;
      }
      _wasBackgrounded = false;
      unawaited(_load(forceRefresh: true));
    }
  }

  Future<void> _load({bool forceRefresh = false}) async {
    var nextEnabled = _isAndroidRootModeEnabled();
    if (nextEnabled &&
        !await _requestAndroidRootAccess(forceRefresh: forceRefresh)) {
      appdata.settings[androidRootModeSettingIndex] = '0';
      await appdata.updateSettings();
      nextEnabled = false;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _enabled = nextEnabled;
    });
  }

  Future<void> _setValue(bool value) async {
    if (_busy || value == _enabled) {
      return;
    }
    setState(() {
      _busy = true;
    });
    try {
      if (value) {
        final granted = await _requestAndroidRootAccess(forceRefresh: true);
        if (!granted) {
          appdata.settings[androidRootModeSettingIndex] = '0';
          await appdata.updateSettings();
          if (mounted) {
            setState(() {
              _enabled = false;
            });
            _showSettingMessage(context, '未获取到 Root 授权，Root 模式未开启'.tl);
          }
          return;
        }
      }

      appdata.settings[androidRootModeSettingIndex] = value ? '1' : '0';
      await appdata.updateSettings();
      if (mounted) {
        setState(() {
          _enabled = value;
        });
        if (value) {
          _showSettingMessage(context, 'Root 模式已开启，可长按“浏览”进入内置文件夹浏览页'.tl);
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _enabled;
    return buildResponsiveSettingTile(
      leading: const Icon(Icons.admin_panel_settings_outlined),
      title: Text('Root 模式'.tl),
      subtitle: Text(
        enabled
            ? 'Root 模式已开启；仅在访问受限目录时使用已授权的 su 权限'.tl
            : '关闭状态；只有手动开启这个开关时才会尝试申请 su 权限'.tl,
      ),
      trailingWidth: 60,
      trailing: Switch(
        value: enabled,
        onChanged: _busy ? null : _setValue,
      ),
    );
  }
}

Widget buildAppSettings(double width, BuildContext context) {
  return buildTwoColumnLayout(width, [
    const _AppServiceSettingsSection(),
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
    if (App.isAndroid) const _AndroidManageAllFilesAccessTile(),
    if (App.isAndroid) const _AndroidShizukuModeTile(),
    if (App.isAndroid) const _AndroidRootModeTile(),
    const _LocalAlbumImageSortTile(),
    const _LocalLibraryListSortTile(),
    _ManagedDataSourceModeTile(
      width: width,
      onRefresh: () => _refreshLocalComics(context),
      onChanged: (value) => _changeManagedDataSourceMode(context, value),
    ),
    const _LocalLibraryShowAllDatabaseRecordsTile(),
    ListTile(
      leading: const Icon(Icons.sd_storage_rounded),
      title: Text('重新扫描磁盘'.tl),
      subtitle: Text('按当前设置重新扫描本应用下载目录、原应用下载目录与自定义本地漫画路径'.tl),
      onTap: () => _rescanLocalComics(context),
    ),
    const _DeleteBehaviorTile(),
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

class _DeleteBehaviorTile extends StatefulWidget {
  const _DeleteBehaviorTile();

  @override
  State<_DeleteBehaviorTile> createState() => _DeleteBehaviorTileState();
}

class _DeleteBehaviorTileState extends State<_DeleteBehaviorTile> {
  bool _busy = false;

  Future<void> _setValue(String value) async {
    final normalized = normalizeDeleteBehavior(value);
    if (_busy || normalized == appdata.settings[deleteBehaviorSettingIndex]) {
      return;
    }
    setState(() {
      _busy = true;
    });
    try {
      appdata.settings[deleteBehaviorSettingIndex] = normalized;
      await appdata.updateSettings();
      if (mounted) {
        _showSettingMessage(
          context,
          normalized == 'trash' ? '默认将删除项目放进回收站'.tl : '默认直接删除项目'.tl,
        );
      }
    } catch (_) {
      if (mounted) {
        _showSettingMessage(context, '切换失败，已恢复原设置'.tl);
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final value = normalizeDeleteBehavior(
      appdata.settings[deleteBehaviorSettingIndex],
    );
    return buildResponsiveSettingTile(
      leading: const Icon(Icons.delete_outline),
      title: Text('删除行为'.tl),
      subtitle: Text('删除整部漫画时，默认放进回收站或直接删除'.tl),
      trailingWidth: 320,
      trailing: SegmentedButton<String>(
        showSelectedIcon: false,
        segments: [
          ButtonSegment<String>(
            value: 'trash',
            label: Text('放进回收站'.tl),
          ),
          ButtonSegment<String>(
            value: 'permanent',
            label: Text('直接删除'.tl),
          ),
        ],
        selected: {value},
        onSelectionChanged: _busy
            ? null
            : (selection) {
                if (selection.isEmpty) {
                  return;
                }
                unawaited(_setValue(selection.first));
              },
      ),
    );
  }
}

class _LocalLibraryShowAllDatabaseRecordsTile extends StatefulWidget {
  const _LocalLibraryShowAllDatabaseRecordsTile();

  @override
  State<_LocalLibraryShowAllDatabaseRecordsTile> createState() =>
      _LocalLibraryShowAllDatabaseRecordsTileState();
}

class _LocalLibraryShowAllDatabaseRecordsTileState
    extends State<_LocalLibraryShowAllDatabaseRecordsTile> {
  bool _busy = false;

  Future<void> _setValue(bool value) async {
    if (_busy) {
      return;
    }
    final previousValue =
        appdata.settings[localLibraryShowAllDatabaseRecordsSettingIndex];
    setState(() {
      _busy = true;
      appdata.settings[localLibraryShowAllDatabaseRecordsSettingIndex] =
          value ? '1' : '0';
    });
    try {
      await appdata.updateSettings();
      await _reloadManagedDataManagers();
    } catch (e, s) {
      LogManager.addLog(
        LogLevel.error,
        'LocalLibraryShowAllDatabaseRecords',
        'Failed to switch value to $value: $e\n$s',
      );
      appdata.settings[localLibraryShowAllDatabaseRecordsSettingIndex] =
          previousValue;
      if (mounted) {
        _showSettingMessage(context, '切换失败，已恢复原设置'.tl);
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return buildResponsiveSettingTile(
      leading: const Icon(Icons.storage_outlined),
      title: Text('无论有无漫画按照数据库文件显示已下载漫画列表'.tl),
      subtitle: Text(
        '无论（源数据库有没有漫画/漫画文件夹）数据库，始终按照漫画已下载的数据库进行显示'.tl,
      ),
      trailingWidth: 60,
      trailing: Switch(
        value:
            appdata.settings[localLibraryShowAllDatabaseRecordsSettingIndex] ==
                '1',
        onChanged: _busy ? null : _setValue,
      ),
    );
  }
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

class _ManagedDataSourceModeTileState
    extends State<_ManagedDataSourceModeTile> {
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
    if (_busy) {
      return;
    }
    final accessRequirement =
        await LocalLibraryManager().getManagedSourceAccessRequirement(
      value,
      refreshAccess: true,
    );
    if (!mounted) {
      return;
    }
    LogManager.addLog(
      LogLevel.info,
      'ManagedDataSourceMode',
      'access requirement current=$_currentValue target=$value result=$accessRequirement',
    );
    print(
      '[PicaKeep][ManagedDataSourceMode] access current=$_currentValue target=$value result=$accessRequirement',
    );
    String? hintMessage;
    switch (accessRequirement) {
      case ManagedSourceAccessRequirement.rootRequired:
        hintMessage = '该档位的路径需要root权限才能访问'.tl;
        break;
      case ManagedSourceAccessRequirement.shizukuPermissionMissing:
        hintMessage = '权限不足请检查shizuku授权情况'.tl;
        break;
      case ManagedSourceAccessRequirement.ok:
        break;
    }
    if (hintMessage != null) {
      _showManagedDataModeHint(context, hintMessage);
    }
    if (value == _currentValue) {
      return;
    }
    _suppressNextManagedDataSourceBusyMessage =
        accessRequirement != ManagedSourceAccessRequirement.ok;
    setState(() {
      _busy = true;
      _pendingValue = value;
    });
    try {
      await widget.onChanged(value).timeout(const Duration(seconds: 20));
      if (mounted && hintMessage != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _showManagedDataModeHint(context, hintMessage!);
          }
        });
      }
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
    required bool vertical,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final selected = _currentValue == value;
    final radius = vertical
        ? BorderRadius.only(
            topLeft: isFirst ? const Radius.circular(20) : Radius.zero,
            topRight: isFirst ? const Radius.circular(20) : Radius.zero,
            bottomLeft: isLast ? const Radius.circular(20) : Radius.zero,
            bottomRight: isLast ? const Radius.circular(20) : Radius.zero,
          )
        : BorderRadius.only(
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
          color: selected ? colorScheme.primaryContainer : Colors.transparent,
          border: Border(
            left: !vertical && !isFirst
                ? BorderSide(color: colorScheme.outlineVariant)
                : BorderSide.none,
            top: vertical && !isFirst
                ? BorderSide(color: colorScheme.outlineVariant)
                : BorderSide.none,
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final vertical = constraints.maxWidth < 210;
        final radius = BorderRadius.circular(vertical ? 20 : 999);
        return Opacity(
          opacity: _busy ? 0.7 : 1,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(color: Theme.of(context).colorScheme.outline),
            ),
            child: ClipRRect(
              borderRadius: radius,
              child: vertical
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (int i = 0; i < options.length; i++)
                          SizedBox(
                            width: double.infinity,
                            child: _buildSegment(
                              context,
                              value: options[i].key,
                              label: options[i].value,
                              isFirst: i == 0,
                              isLast: i == options.length - 1,
                              vertical: true,
                            ),
                          ),
                      ],
                    )
                  : Row(
                      children: [
                        for (int i = 0; i < options.length; i++)
                          Expanded(
                            child: _buildSegment(
                              context,
                              value: options[i].key,
                              label: options[i].value,
                              isFirst: i == 0,
                              isLast: i == options.length - 1,
                              vertical: false,
                            ),
                          ),
                      ],
                    ),
            ),
          ),
        );
      },
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
          final narrowLayout = constraints.maxWidth < 560;
          final availableSelectorWidth =
              constraints.maxWidth - reservedRefreshWidth;
          final selectorWidth = narrowLayout
              ? constraints.maxWidth
              : (availableSelectorWidth < minimumSelectorWidth
                  ? minimumSelectorWidth
                  : (availableSelectorWidth < selectorMaxWidth
                      ? availableSelectorWidth
                      : selectorMaxWidth));
          if (narrowLayout) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.refresh),
                  title: Text('数据管理-刷新本地漫画'.tl),
                  subtitle: Text(
                    '重新加载下载目录；数据库路径仅作用于本地收藏、图片收藏和历史数据'.tl,
                  ),
                  onTap: widget.onRefresh,
                ),
                const SizedBox(height: 8),
                _buildSelector(context),
              ],
            );
          }
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

class _DirectoryPathDialog extends StatelessWidget {
  const _DirectoryPathDialog({
    required this.title,
    required this.hintText,
    required this.helperText,
    required this.controller,
    required this.onBrowse,
    required this.onLongPressBrowse,
    required this.onConfirm,
    required this.onCancel,
    required this.onOpenCurrentDirectory,
  });

  final String title;
  final String hintText;
  final String helperText;
  final TextEditingController controller;
  final Future<void> Function() onBrowse;
  final Future<void> Function() onLongPressBrowse;
  final Future<void> Function() onConfirm;
  final VoidCallback onCancel;
  final VoidCallback onOpenCurrentDirectory;

  bool get _isDesktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final stackedActions = screenWidth < 560;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 20),
              if (stackedActions) ...[
                TextField(
                  controller: controller,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    hintText: hintText,
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => onConfirm(),
                ),
                const SizedBox(height: 12),
                GestureDetector(
                  onLongPress: onLongPressBrowse,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(double.infinity, 48),
                    ),
                    onPressed: onBrowse,
                    icon: const Icon(Icons.folder_open, size: 18),
                    label: Text('浏览'.tl),
                  ),
                ),
              ] else ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: controller,
                        textInputAction: TextInputAction.done,
                        decoration: InputDecoration(
                          hintText: hintText,
                          border: const OutlineInputBorder(),
                        ),
                        onSubmitted: (_) => onConfirm(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onLongPress: onLongPressBrowse,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 48),
                        ),
                        onPressed: onBrowse,
                        icon: const Icon(Icons.folder_open, size: 18),
                        label: Text('浏览'.tl),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 10),
              Text(
                helperText,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (_isDesktop) ...[
                const SizedBox(height: 12),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: controller,
                  builder: (context, value, _) {
                    final currentPath = value.text.trim();
                    return OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(double.infinity, 48),
                      ),
                      onPressed:
                          currentPath.isEmpty ? null : onOpenCurrentDirectory,
                      icon: const Icon(Icons.launch, size: 18),
                      label: Text('打开当前目录'.tl),
                    );
                  },
                ),
              ],
              const SizedBox(height: 20),
              OverflowBar(
                alignment: MainAxisAlignment.end,
                spacing: 8,
                overflowSpacing: 8,
                children: [
                  TextButton(
                    onPressed: onCancel,
                    child: Text('取消'.tl),
                  ),
                  TextButton(
                    onPressed: onConfirm,
                    child: Text('确定'.tl),
                  ),
                ],
              ),
            ],
          ),
        ),
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
    showDialog<void>(
      context: context,
      builder: (ctx) => _DirectoryPathDialog(
        title: '设置本应用下载目录'.tl,
        hintText: '请输入下载目录路径'.tl,
        helperText:
            '提示：点按“浏览”调用系统目录选择；长按“浏览”打开内置文件夹浏览，支持安卓全部文件访问权限、Shizuku 授权或 Root 模式。'
                .tl,
        controller: controller,
        onBrowse: () async {
          final picked = await _pickFolder();
          if (picked != null) {
            controller.text = picked;
          }
        },
        onLongPressBrowse: () async {
          Navigator.of(ctx).pop();
          final browsed = await _openInternalDirectoryBrowser(
            context,
            title: '选择本应用下载目录'.tl,
            initialPath: controller.text,
          );
          if (!mounted || browsed == null) {
            return;
          }
          controller.text = browsed;
          appdata.settings[22] = browsed;
          await appdata.updateSettings();
          if (!mounted) {
            return;
          }
          setState(() {});
          await _runRescanLocalComics(context);
        },
        onOpenCurrentDirectory: () {
          _openCurrentDirectory(controller.text.trim());
        },
        onCancel: () => Navigator.of(ctx).pop(),
        onConfirm: () async {
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
      ),
    );
  }

  Widget _buildPathDisplay(BuildContext context, String display) {
    return Container(
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
  State<_OriginalDownloadDirTile> createState() =>
      _OriginalDownloadDirTileState();
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
    final controller = TextEditingController(
        text: appdata.settings[originalDownloadDirSettingIndex]);
    showDialog<void>(
      context: context,
      builder: (ctx) => _DirectoryPathDialog(
        title: '设置原应用下载目录'.tl,
        hintText: '请输入原应用下载目录路径'.tl,
        helperText:
            '提示：点按“浏览”调用系统目录选择；长按“浏览”打开内置文件夹浏览，支持安卓全部文件访问权限、Shizuku 授权或 Root 模式。'
                .tl,
        controller: controller,
        onBrowse: () async {
          final picked = await _pickFolder();
          if (picked != null) {
            controller.text = picked;
          }
        },
        onLongPressBrowse: () async {
          Navigator.of(ctx).pop();
          final browsed = await _openInternalDirectoryBrowser(
            context,
            title: '选择原应用下载目录'.tl,
            initialPath: controller.text,
          );
          if (!mounted || browsed == null) {
            return;
          }
          controller.text = browsed;
          appdata.settings[originalDownloadDirSettingIndex] = browsed;
          await appdata.updateSettings();
          if (!mounted) {
            return;
          }
          setState(() {});
          await _runRescanLocalComics(context);
        },
        onOpenCurrentDirectory: () {
          _openCurrentDirectory(controller.text.trim());
        },
        onCancel: () => Navigator.of(ctx).pop(),
        onConfirm: () async {
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
      ),
    );
  }

  Widget _buildPathDisplay(BuildContext context, String display) {
    return Container(
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
                          log.time.toString().replaceAll(RegExp(r'\.\w+'), ''),
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
      final canCheckBiometrics = await _localAuthentication.canCheckBiometrics;
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

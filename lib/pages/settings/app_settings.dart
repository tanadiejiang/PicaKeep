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

  Future<List<Map<String, String>>>
      listAndroidDataDirectoryWithShizuku() async {
    if (!App.isAndroid) {
      return const <Map<String, String>>[];
    }
    try {
      final result = await _channel.invokeListMethod<Object>(
        'listAndroidDataDirectoryWithShizuku',
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

  /// 在 Root 权限下创建目录（含缺失的父目录）。目录已存在时视为成功。
  Future<void> createDirectoryWithRoot(String path) async {
    if (!App.isAndroid) {
      return;
    }
    await _invokeCreateDirectory('createDirectoryWithRoot', path);
  }

  /// 在 Shizuku 权限下创建目录（含缺失的父目录）。目录已存在时视为成功。
  Future<void> createDirectoryWithShizuku(String path) async {
    if (!App.isAndroid) {
      return;
    }
    await _invokeCreateDirectory('createDirectoryWithShizuku', path);
  }

  Future<void> _invokeCreateDirectory(String method, String path) async {
    try {
      await _channel.invokeMethod<void>(method, {'path': path});
    } on PlatformException catch (e) {
      throw Exception((e.message ?? e.code).trim());
    }
  }

  Future<bool> existsWithRoot(String path) async {
    if (!App.isAndroid) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>(
            'existsWithRoot',
            {'path': path},
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> existsWithShizuku(String path) async {
    if (!App.isAndroid) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>(
            'existsWithShizuku',
            {'path': path},
          ) ??
          false;
    } catch (_) {
      return false;
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

class _AndroidPermissionSectionTitle extends StatefulWidget {
  const _AndroidPermissionSectionTitle();

  @override
  State<_AndroidPermissionSectionTitle> createState() =>
      _AndroidPermissionSectionTitleState();
}

class _AndroidPermissionSectionTitleState
    extends State<_AndroidPermissionSectionTitle> {
  String? _warningText;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    if (!App.isAndroid) return;
    String? warning;
    if (_isAndroidShizukuModeEnabled()) {
      final ok =
          await _AndroidStorageAccessController.instance.hasShizukuPermission();
      if (!ok) warning = 'Shizuku 未授权';
    }
    if (warning == null && _isAndroidRootModeEnabled()) {
      final ok = await _AndroidStorageAccessController.instance.hasRootAccess();
      if (!ok) warning = 'Root 未授权';
    }
    if (mounted && warning != _warningText) {
      setState(() => _warningText = warning);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SettingsTitle(
      '访问权限（Android）'.tl,
      trailing: _warningText == null
          ? null
          : Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: cs.errorContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _warningText!,
                style: TextStyle(fontSize: 11, color: cs.onErrorContainer),
              ),
            ),
    );
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
    const NewPageSetting(
      title: '待翻译标签',
      page: UntranslatedTagsPage(),
    ),
    SettingsTitle('存储位置'.tl),
    const _DownloadDirTile(),
    const _LowStorageMigrationTile(),
    const _PendingDownloadMigrationTile(),
    const _OriginalDownloadDirTile(),
    const _LocalComicPathsTile(),
    SettingsTitle('数据管理'.tl),
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
    const _UserDataTransferTiles(),
    if (App.isAndroid) const _AndroidPermissionSectionTitle(),
    if (App.isAndroid) const _AndroidManageAllFilesAccessTile(),
    if (App.isAndroid) const _AndroidShizukuModeTile(),
    if (App.isAndroid) const _AndroidRootModeTile(),
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

class _DirectoryPathDialog extends StatefulWidget {
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
    required this.initialPath,
    required this.hasExistingDownloads,
    this.extraSectionBuilder,
  });

  final String title;
  final String hintText;
  final String helperText;
  final TextEditingController controller;
  final Future<void> Function() onBrowse;
  final Future<void> Function() onLongPressBrowse;
  final Future<void> Function(bool migrateDownloads) onConfirm;
  final VoidCallback onCancel;
  final VoidCallback onOpenCurrentDirectory;

  /// 打开弹窗时的下载目录配置值，用于判断路径是否真的被改动。
  final String initialPath;

  /// 当前下载目录里是否有可迁移的内容（漫画或 download.db）。
  final bool hasExistingDownloads;

  /// 额外插入的自定义区块（例如「原应用下载目录」的使用方式选择）。
  ///
  /// 之所以是 builder 而不是直接传 Widget：弹窗是**独立路由**，外层的
  /// `setState` 不会重建它。builder 拿到的 `setState` 属于弹窗内部，
  /// 区块里的开关/单选改动时用它刷新，外层只需持有取值。
  final Widget Function(BuildContext context, StateSetter setState)?
      extraSectionBuilder;

  @override
  State<_DirectoryPathDialog> createState() => _DirectoryPathDialogState();
}

class _DirectoryPathDialogState extends State<_DirectoryPathDialog> {
  /// 默认不勾选：转移是有副作用的写操作，必须由用户主动选择。
  bool _migrateDownloads = false;

  bool get _isDesktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  /// 路径没变就没什么可转移的，此时不出现这个选项。
  bool get _pathChanged =>
      widget.controller.text.trim() != widget.initialPath.trim();

  bool get _showMigrateOption => widget.hasExistingDownloads && _pathChanged;

  @override
  void initState() {
    super.initState();
    // 路径由输入框和「浏览」共同改写，勾选项的显隐要跟着实时变。
    widget.controller.addListener(_handlePathChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handlePathChanged);
    super.dispose();
  }

  void _handlePathChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Widget _buildMigrateOption(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => setState(() => _migrateDownloads = !_migrateDownloads),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Checkbox(
              value: _migrateDownloads,
              onChanged: (value) =>
                  setState(() => _migrateDownloads = value ?? false),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
            const SizedBox(width: 4),
            Text(
              '转移已下载的数据'.tl,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final browseButtonWidth = screenWidth < 420 ? 96.0 : 120.0;
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
              Text(widget.title,
                  style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 20),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      controller: controller,
                      textInputAction: TextInputAction.done,
                      decoration: InputDecoration(
                        hintText: widget.hintText,
                        border: const OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => widget.onConfirm(_migrateDownloads),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: browseButtonWidth,
                    child: GestureDetector(
                      onLongPress: widget.onLongPressBrowse,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 56),
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                        ),
                        onPressed: widget.onBrowse,
                        icon: const Icon(Icons.folder_open, size: 18),
                        label: Text('浏览'.tl),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                widget.helperText,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (widget.extraSectionBuilder != null) ...[
                const SizedBox(height: 12),
                widget.extraSectionBuilder!(context, setState),
              ],
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
                      onPressed: currentPath.isEmpty
                          ? null
                          : widget.onOpenCurrentDirectory,
                      icon: const Icon(Icons.launch, size: 18),
                      label: Text('打开当前目录'.tl),
                    );
                  },
                ),
              ],
              const SizedBox(height: 20),
              // 勾选项与「取消 / 确定」同一行，位于按钮左侧；用 Wrap 保证
              // 窄屏（勾选项文案 + 两个按钮）放不下时能换行而不是溢出。
              Wrap(
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 4,
                children: [
                  if (_showMigrateOption) _buildMigrateOption(context),
                  TextButton(
                    onPressed: widget.onCancel,
                    child: Text('取消'.tl),
                  ),
                  TextButton(
                    onPressed: () => widget.onConfirm(_migrateDownloads),
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

/// 进度文案里的阶段名。
String _migrationPhaseLabel(DownloadMigrationPhase phase) => switch (phase) {
      DownloadMigrationPhase.copying => '正在复制'.tl,
      DownloadMigrationPhase.cleaningUp => '正在清理旧目录'.tl,
      DownloadMigrationPhase.moving => '正在转移'.tl,
    };

/// 迁移进度弹窗：显示"一本本搬"的进度，可退到后台继续。
///
/// 对话框只是进度的一层皮：真正的任务由 [DownloadMigrationController] 持有，
/// 所以点「后台运行」关掉它不会中断搬移。
class _MigrationProgressDialog extends StatefulWidget {
  const _MigrationProgressDialog({
    required this.task,
    this.title = '正在转移下载数据',
    this.hint = '新目录已经可以使用，没搬完的部分之后可以继续。',
  });

  /// 正在跑的迁移任务；null 表示已有任务在跑（不会并发搬同一批文件）。
  final Future<DownloadMigrationResult?>? task;

  /// 弹窗标题；复制场景与迁移场景用词不同，所以做成参数。
  final String title;

  /// 标题下方的一句说明。
  final String hint;

  @override
  State<_MigrationProgressDialog> createState() =>
      _MigrationProgressDialogState();
}

class _MigrationProgressDialogState extends State<_MigrationProgressDialog> {
  @override
  void initState() {
    super.initState();
    // 任务结束后自动收起进度框。用户若已点过「后台运行」，这里已经 unmounted。
    widget.task?.whenComplete(() {
      if (mounted) {
        Navigator.of(context).pop();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: Row(
          children: [
            Icon(
              Icons.drive_file_move_outline,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(widget.title.tl)),
          ],
        ),
        content: AnimatedBuilder(
          animation: DownloadMigrationController.instance,
          builder: (context, _) {
            final progress = DownloadMigrationController.instance.progress;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: progress?.fraction,
                    minHeight: 8,
                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  progress == null
                      ? '正在准备...'.tl
                      : '${_migrationPhaseLabel(progress.phase)} '
                          '${progress.completed} / ${progress.total} 项 · '
                          '${(progress.fraction * 100).round()}%',
                  style: theme.textTheme.bodyMedium,
                ),
                if (progress != null && progress.currentEntry.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    progress.currentEntry,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Text(
                  widget.hint.tl,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('后台运行'.tl),
          ),
        ],
      ),
    );
  }
}

/// 打开进度框并等待这一轮搬完；点「后台运行」只是关掉 UI，任务继续跑。
///
/// 抽成顶层函数是为了让「继续转移」入口（设置页里的独立条目）也能复用，
/// 而不必把整套对话框逻辑挂在某一个 tile 的 State 上。
Future<void> _startDownloadMigrationTask(
  BuildContext context, {
  required String from,
  required String to,
}) async {
  final controller = DownloadMigrationController.instance;
  final task = controller.start(from: from, to: to);
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _MigrationProgressDialog(task: task),
  );
  final result = await task;
  if (!context.mounted || result == null) {
    return;
  }
  // 漫画是这一轮才落到新目录里的，重扫一次下载页才能立刻看到。
  await _runRescanLocalComics(context);
  if (!context.mounted) {
    return;
  }
  await _reportDownloadMigrationResult(context, result, from: from, to: to);
}

Future<void> _reportDownloadMigrationResult(
  BuildContext context,
  DownloadMigrationResult result, {
  required String from,
  required String to,
}) async {
  // 以文件系统的实际状态为准：旧目录还有东西就是没搬完。
  final remaining = await hasPendingDownloadEntries(from);
  if (!context.mounted) {
    return;
  }
  if (!remaining) {
    _showSettingMessage(
      context,
      result.movedEntries > 0
          ? '已转移 ${result.movedEntries} 项数据到新目录'
          : '下载数据已全部在新目录',
    );
    return;
  }
  await _showDownloadMigrationIncomplete(context, result, from: from, to: to);
}

Future<void> _showDownloadMigrationIncomplete(
  BuildContext context,
  DownloadMigrationResult result, {
  required String from,
  required String to,
}) async {
  final lines = <String>['旧目录里还有未转移的内容。'];
  if (result.movedEntries > 0) {
    lines.add('本次已转移 ${result.movedEntries} 项。');
  }
  if (result.skippedEntries > 0) {
    lines.add('另有 ${result.skippedEntries} 项此前已经转移。');
  }
  if (result.failures.isNotEmpty) {
    lines.add('');
    lines.add('以下条目转移失败（仍保留在旧目录）：');
    for (final failure in result.failures.take(5)) {
      lines.add('· $failure');
    }
    if (result.failures.length > 5) {
      lines.add('· …以及另外 ${result.failures.length - 5} 项');
    }
  }
  lines.add('');
  lines.add('新目录已经在用，可以稍后继续搬剩下的部分。');

  final again = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('转移未完成'.tl),
      content: SingleChildScrollView(child: Text(lines.join('\n').tl)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text('稍后继续'.tl),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text('继续转移'.tl),
        ),
      ],
    ),
  );
  if (again == true && context.mounted) {
    await _startDownloadMigrationTask(context, from: from, to: to);
  }
}

/// 「存储紧张时的迁移」开关：只影响迁移方式，其余行为一概不变。
class _LowStorageMigrationTile extends StatefulWidget {
  const _LowStorageMigrationTile();

  @override
  State<_LowStorageMigrationTile> createState() =>
      _LowStorageMigrationTileState();
}

class _LowStorageMigrationTileState extends State<_LowStorageMigrationTile> {
  @override
  void initState() {
    super.initState();
    unawaited(DownloadMigrationController.instance.loadPreferences());
  }

  @override
  Widget build(BuildContext context) {
    final controller = DownloadMigrationController.instance;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => SwitchListTile(
        secondary: const Icon(Icons.sd_storage_outlined),
        title: Text('存储紧张时的迁移'.tl),
        subtitle: Text(
          controller.lowStorageMode
              ? '搬一本删一本，峰值占用最小；转移过程中旧目录会逐步变空'.tl
              : '先把全部内容复制过去，确认没失败后再清理旧目录'.tl,
        ),
        value: controller.lowStorageMode,
        onChanged: controller.setLowStorageMode,
      ),
    );
  }
}

/// 用户数据导入 / 导出，**格式与原项目 PicaComic 的 `.picadata` 互通**。
///
/// 导出走系统分享（与日志导出同一套做法），用户可存到任意位置；导入用系统文件
/// 选择器挑包。范围是**设置 + 账号 + 历史 + 本地收藏**，不含下载数据 ——
/// 下载库实测几百 MB，且体积与内容都不适合塞进这个包。
class _UserDataTransferTiles extends StatefulWidget {
  const _UserDataTransferTiles();

  @override
  State<_UserDataTransferTiles> createState() => _UserDataTransferTilesState();
}

class _UserDataTransferTilesState extends State<_UserDataTransferTiles> {
  bool _busy = false;

  Future<void> _showDetails(String title, UserDataTransferResult result) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title.tl),
        content: SingleChildScrollView(
          child: Text(
            '${result.message}\n\n${result.details.join('\n')}',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('知道了'.tl),
          ),
        ],
      ),
    );
  }

  Future<void> _export() async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('导出用户数据'.tl),
        content: Text(
          '将导出设置、账号（含登录状态）、历史记录与本地收藏。\n\n'
                  '不含已下载的漫画与下载记录。导出的文件可以被原项目导入，反之亦然。'
              .tl,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消'.tl),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('导出'.tl),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      // 先落到缓存目录，再交给系统分享 —— 用户可以把文件存到任意位置。
      final out = '${App.cachePath}${Platform.pathSeparator}'
          '$kUserDataDefaultFileName';
      final result = await UserDataTransfer.export(outFile: out);
      if (!mounted) return;
      if (!result.ok) {
        await _showDetails('导出失败', result);
        return;
      }
      await Share.shareXFiles(
        [XFile(out)],
        text: 'PicaKeep 用户数据',
      );
    } catch (e) {
      if (mounted) {
        _showSettingMessage(context, '导出失败：$e');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _import() async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('导入用户数据'.tl),
        content: Text(
          '将导入设置、账号（含登录状态）、历史记录与本地收藏。\n\n'
                  '· 设置与账号：**以后导入包为准**（设置只覆盖与原项目一致的部分，'
                  '本应用新增的选项保持不动）；\n'
                  '· 历史与本地收藏：**合并**，本应用已有的记录不会被删除。\n\n'
                  '导入完成后需要重启应用才会生效。'
              .tl,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消'.tl),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('选择文件'.tl),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    FilePickerResult? picked;
    try {
      picked = await FilePicker.platform.pickFiles();
    } catch (e) {
      if (mounted) {
        _showSettingMessage(context, '打开文件选择器失败：$e');
      }
      return;
    }
    final path = picked?.files.singleOrNull?.path;
    if (path == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final result = await UserDataTransfer.import(path);
      if (!mounted) return;
      if (result.ok) {
        await _showDetails('导入完成', result);
        if (!mounted) return;
        _showSettingMessage(context, '导入完成，重启应用后生效');
      } else {
        await _showDetails('导入失败', result);
      }
    } catch (e) {
      if (mounted) {
        _showSettingMessage(context, '导入失败：$e');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.sim_card_download),
          title: Text('导出用户数据'.tl),
          subtitle: Text('设置、账号、历史与本地收藏（不含下载数据）'.tl),
          trailing: _busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.arrow_right),
          onTap: _busy ? null : _export,
        ),
        ListTile(
          leading: const Icon(Icons.data_object),
          title: Text('导入用户数据'.tl),
          subtitle: Text('从原项目导出的数据包或本应用的备份导入'.tl),
          trailing: const Icon(Icons.arrow_right),
          onTap: _busy ? null : _import,
        ),
      ],
    );
  }
}

/// 未完成的迁移入口。没有待续任务时整条不渲染。
class _PendingDownloadMigrationTile extends StatefulWidget {
  const _PendingDownloadMigrationTile();

  @override
  State<_PendingDownloadMigrationTile> createState() =>
      _PendingDownloadMigrationTileState();
}

class _PendingDownloadMigrationTileState
    extends State<_PendingDownloadMigrationTile> {
  PendingDownloadMigration? _pending;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final controller = DownloadMigrationController.instance;
    final pending = await controller.loadPending();
    if (pending == null) {
      if (mounted) {
        setState(() => _pending = null);
      }
      return;
    }
    // 记录可能已经过期（用户自己把旧目录内容搬走/删了），以文件系统为准。
    final stillPending = await hasPendingDownloadEntries(pending.from);
    if (!mounted) {
      return;
    }
    setState(() => _pending = stillPending ? pending : null);
  }

  @override
  Widget build(BuildContext context) {
    final pending = _pending;
    if (pending == null) {
      return const SizedBox.shrink();
    }
    return ListTile(
      leading: Icon(
        Icons.drive_file_move_outline,
        color: Theme.of(context).colorScheme.primary,
      ),
      title: Text('继续转移下载数据'.tl),
      subtitle: Text(
        '上次没搬完，旧目录：${pending.from}'.tl,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(Icons.arrow_right),
      onTap: () async {
        await _startDownloadMigrationTask(
          context,
          from: pending.from,
          to: pending.to,
        );
        if (mounted) {
          await _refresh();
        }
      },
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

  /// 当前下载根目录的解析见文件末尾的顶层函数 [_resolveCurrentDownloadRoot]。
  /// 提到顶层是因为「原应用下载目录 → 复制到本应用」也要用同一个结果。

  Future<void> _showBrowseDialog() async {
    final configuredPath = appdata.settings[22];
    final currentRoot = await _resolveCurrentDownloadRoot();
    final hasExistingDownloads = currentRoot == null
        ? false
        : await hasMigratableDownloadContent(currentRoot);
    if (!mounted) {
      return;
    }
    final controller = TextEditingController(text: configuredPath);
    await showDialog<void>(
      context: context,
      builder: (ctx) => _DirectoryPathDialog(
        title: '设置本应用下载目录'.tl,
        hintText: '请输入下载目录路径'.tl,
        helperText:
            '提示：点按“浏览”调用系统目录选择；长按“浏览”打开内置文件夹浏览，支持安卓全部文件访问权限、Shizuku 授权或 Root 模式。'
                .tl,
        controller: controller,
        initialPath: configuredPath,
        hasExistingDownloads: hasExistingDownloads,
        onBrowse: () async {
          final picked = await _pickFolder();
          if (picked != null) {
            controller.text = picked;
          }
        },
        onLongPressBrowse: () async {
          Navigator.of(ctx).pop();
          final browsed = await openInternalDirectoryBrowser(
            context,
            title: '选择本应用下载目录'.tl,
            initialPath: controller.text,
          );
          if (!mounted || browsed == null) {
            return;
          }
          // 长按浏览是"浏览即应用"的入口，这里同样要经过转移确认，
          // 否则这条路径会绕过上面的勾选框静默切换目录。
          await _applyBrowsedDownloadPath(
            browsed,
            currentRoot: currentRoot,
            hasExistingDownloads: hasExistingDownloads,
          );
        },
        onOpenCurrentDirectory: () {
          _openCurrentDirectory(controller.text.trim());
        },
        onCancel: () => Navigator.of(ctx).pop(),
        onConfirm: (migrateDownloads) => _applyDownloadPathChange(
          dialogContext: ctx,
          newConfiguredPath: controller.text.trim(),
          currentRoot: currentRoot,
          hasExistingDownloads: hasExistingDownloads,
          migrateDownloads: migrateDownloads,
        ),
      ),
    );
  }

  /// 「确定」按钮：按是否勾选转移走不同分支。
  Future<void> _applyDownloadPathChange({
    required BuildContext dialogContext,
    required String newConfiguredPath,
    required String? currentRoot,
    required bool hasExistingDownloads,
    required bool migrateDownloads,
  }) async {
    if (newConfiguredPath == appdata.settings[22].trim()) {
      // 路径没变，直接关掉；不重扫、不动数据。
      if (dialogContext.mounted) {
        Navigator.of(dialogContext).pop();
      }
      return;
    }

    if (migrateDownloads && currentRoot != null) {
      if (dialogContext.mounted) {
        Navigator.of(dialogContext).pop();
      }
      await _runDownloadMigration(from: currentRoot, to: newConfiguredPath);
      return;
    }

    // 没勾选：旧目录还有数据时先说清楚"数据不会跟着走"。
    if (hasExistingDownloads) {
      final proceed = await _confirmSwitchWithoutMigration();
      if (!proceed || !mounted) {
        return;
      }
    }
    if (dialogContext.mounted) {
      Navigator.of(dialogContext).pop();
    }
    await _setDownloadPath(newConfiguredPath);
  }

  /// 长按浏览选完目录后的应用逻辑，与勾选框路径保持一致。
  Future<void> _applyBrowsedDownloadPath(
    String browsedPath, {
    required String? currentRoot,
    required bool hasExistingDownloads,
  }) async {
    final newPath = browsedPath.trim();
    if (newPath.isEmpty || newPath == appdata.settings[22].trim()) {
      return;
    }
    if (hasExistingDownloads && currentRoot != null) {
      final migrate = await _askMigrateDownloads();
      if (migrate == null || !mounted) {
        return;
      }
      if (migrate) {
        await _runDownloadMigration(from: currentRoot, to: newPath);
        return;
      }
    }
    await _setDownloadPath(newPath);
  }

  /// 长按浏览时的三选一：转移 / 不转移 / 取消。返回 null 表示取消。
  Future<bool?> _askMigrateDownloads() {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('转移已下载的数据'.tl),
        content: Text(
          '新目录与当前目录不同。是否把已下载的漫画与记录一起转移到新目录？\n\n'
                  '选择“不转移”：新目录里不会出现这些内容，旧目录的数据仍然完整保留在原位置。'
              .tl,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('取消'.tl),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('不转移'.tl),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('转移'.tl),
          ),
        ],
      ),
    );
  }

  /// 未勾选转移时的提示。返回 true 表示用户确认继续切换。
  Future<bool> _confirmSwitchWithoutMigration() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('已下载的数据不会转移'.tl),
        content: Text(
          '新目录里不会出现旧目录中已下载的漫画和记录，需要重新下载。\n\n'
                  '旧目录里的数据不会被删除，仍然保留在原位置，之后可以手动搬过去。'
              .tl,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('返回'.tl),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('仍要切换'.tl),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  /// 勾选转移后的完整流程：**先让新目录可用，再搬旧数据**。
  ///
  /// 1. 复制 `download.db` 到新目录（源库保留一份）；
  /// 2. 立刻把下载目录切到新路径 —— 记录已经在新目录里，它马上就可用；
  /// 3. 逐个把旧目录的漫画搬过去，带进度、可中断、可续。
  ///
  /// 这样安排的好处：即使第 3 步整体失败或被系统杀掉，**记录不会丢**，
  /// 新目录也始终是一个能用的下载目录，剩下的只是"有些漫画还没搬过来"。
  Future<void> _runDownloadMigration({
    required String from,
    required String to,
  }) async {
    try {
      await seedDownloadDatabase(from: from, to: to);
    } catch (e) {
      if (!mounted) {
        return;
      }
      await _showMessageDialog(
        context,
        '无法转移下载记录',
        '复制下载记录到新目录失败，下载目录保持不变。\n\n${_describeError(e)}',
      );
      return;
    }
    final switched = await _setDownloadPath(to);
    if (!switched || !mounted) {
      return;
    }
    await _startDownloadMigrationTask(context, from: from, to: to);
  }

  String _describeError(Object error) {
    if (error is DownloadMigrationException) {
      return error.message;
    }
    return error.toString().trim();
  }

  /// 切换下载目录：先更新配置，再让下载库切到新目录，最后重扫。
  /// 顺序不能反 —— 反了会拿旧库去扫新目录。返回是否切换成功。
  Future<bool> _setDownloadPath(String newPath) async {
    final previousPath = appdata.settings[22];
    appdata.settings[22] = newPath;
    await appdata.updateSettings();
    try {
      await downloadManager.init();
    } catch (_) {
      // 新目录打不开就退回原设置，别让应用停在一个不可用的下载目录上。
      appdata.settings[22] = previousPath;
      await appdata.updateSettings();
      try {
        await downloadManager.init();
      } catch (_) {}
      if (mounted) {
        setState(() {});
        _showSettingMessage(context, '下载目录不可用，已恢复原设置'.tl);
      }
      return false;
    }
    if (!mounted) {
      return true;
    }
    setState(() {});
    await _runRescanLocalComics(context);
    return true;
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
    final display = path.isEmpty ? '未设置 (应用内)'.tl : path;
    return buildResponsiveSettingTile(
      leading: const Icon(Icons.folder),
      title: Text('本应用下载目录'.tl),
      subtitle: path.isEmpty
          ? Text('将使用应用私有目录 (文件管理器不可见)'.tl,
              style: const TextStyle(fontSize: 12))
          : null,
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
  /// 使用方式：`true` = 复制一份到本应用，`false` = 直接原地读取（默认）。
  ///
  /// 弹窗是独立路由，这份状态由本 State 持有，弹窗内靠 `setSectionState` 刷新。
  bool _copyMode =
      appdata.settings[originalDirUsageModeSettingIndex] ==
          originalDirUsageModeCopy;

  Future<String?> _pickFolder() async {
    try {
      return await FilePicker.platform.getDirectoryPath();
    } catch (_) {
      return null;
    }
  }

  /// 弹窗里的「使用方式」区块。
  Widget _buildUsageModeSection(StateSetter setSectionState) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 1),
        const SizedBox(height: 8),
        Text('使用方式'.tl, style: theme.textTheme.titleSmall),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: _copyMode,
          title: Text('复制到本应用'.tl),
          subtitle: Text(
            _copyMode
                ? '会把原目录内容复制进本应用下载目录，之后不再依赖原目录与权限；'
                    '同一份漫画会占双倍空间。只复制、不动原应用的数据。'
                    .tl
                : '直接原地读取，不复制文件、不占额外空间。原应用目录在它自己的'
                    '私有存储里，读取需要 Shizuku 或 Root 授权。'.tl,
          ),
          onChanged: (value) {
            setSectionState(() {});
            _copyMode = value;
          },
        ),
      ],
    );
  }

  /// 把原应用下载目录的内容复制一份到本应用下载目录。
  ///
  /// 复用下载目录迁移那套进度广播与「后台运行」按钮；关键区别是
  /// [DownloadMigrationController.startCopy] **绝不删除源** —— 那是原应用的数据。
  /// 重复执行是安全的：目标已存在同名条目会被跳过。
  Future<void> _copyOriginalDirIntoApp(String from) async {
    final target = await _resolveCurrentDownloadRoot();
    if (!mounted) {
      return;
    }
    if (target == null) {
      _showSettingMessage(context, '无法确定本应用下载目录，已取消复制'.tl);
      return;
    }
    if (target == from) {
      _showSettingMessage(context, '两边指向同一个目录，无需复制'.tl);
      return;
    }

    final controller = DownloadMigrationController.instance;
    final task = controller.startCopy(from: from, to: target);
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _MigrationProgressDialog(
        task: task,
        title: '正在复制原应用数据',
        hint: '只复制、不删除原应用的文件；中断后重新执行会跳过已复制的内容。',
      ),
    );
    final result = await task;
    if (!mounted || result == null) {
      return;
    }
    if (result.failures.isNotEmpty) {
      await _showMessageDialog(
        context,
        '复制未完成',
        '已复制 ${result.movedEntries} 项，跳过 ${result.skippedEntries} 项。\n\n'
            '以下条目失败：\n${result.failures.take(5).join('\n')}',
      );
    } else {
      _showSettingMessage(
        context,
        result.movedEntries > 0
            ? '已复制 ${result.movedEntries} 项到本应用下载目录'
            : '没有需要复制的内容',
      );
    }
    if (!mounted) {
      return;
    }
    await _runRescanLocalComics(context);
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
        // 「原应用下载目录」只是扫描来源，不是本应用的下载目的地，
        // 换它不涉及搬数据，因此不出现下载转移选项。
        initialPath: appdata.settings[originalDownloadDirSettingIndex],
        hasExistingDownloads: false,
        extraSectionBuilder: (_, setSectionState) =>
            _buildUsageModeSection(setSectionState),
        onBrowse: () async {
          final picked = await _pickFolder();
          if (picked != null) {
            controller.text = picked;
          }
        },
        onLongPressBrowse: () async {
          Navigator.of(ctx).pop();
          final browsed = await openInternalDirectoryBrowser(
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
        onConfirm: (migrateDownloads) async {
          final newPath = controller.text.trim();
          final oldPath = appdata.settings[originalDownloadDirSettingIndex];
          final pathChanged = newPath != oldPath;
          final wasCopyMode =
              appdata.settings[originalDirUsageModeSettingIndex] ==
                  originalDirUsageModeCopy;
          final modeChanged = _copyMode != wasCopyMode;

          appdata.settings[originalDownloadDirSettingIndex] = newPath;
          appdata.settings[originalDirUsageModeSettingIndex] = _copyMode
              ? originalDirUsageModeCopy
              : originalDirUsageModeDirect;
          await appdata.updateSettings();
          if (!ctx.mounted || !mounted) {
            return;
          }
          Navigator.of(ctx).pop();
          setState(() {});

          // 选了"复制到本应用"、且目录非空时执行一次复制。
          // 重复执行安全：目标已存在同名条目会被跳过。
          if (_copyMode && newPath.isNotEmpty && (pathChanged || modeChanged)) {
            await _copyOriginalDirIntoApp(newPath);
            return;
          }
          if (pathChanged) {
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


/// 一个只有「知道了」按钮的提示弹窗。
///
/// 提到顶层是因为"下载目录迁移"与"原应用数据复制"两处都要用；留在某个 tile 的
/// State 里，另一个 State 就调不到（私有成员是库级可见，但 State 的方法是实例方法）。
Future<void> _showMessageDialog(
  BuildContext context,
  String title,
  String message,
) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title.tl),
      content: SingleChildScrollView(child: Text(message.tl)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text('知道了'.tl),
        ),
      ],
    ),
  );
}

/// 当前下载根目录（配置为空时解析为应用私有默认目录）。
///
/// 直接采用 DownloadManager 解析后的 path，避免在设置页里重复一份"默认目录"
/// 规则 —— 两处规则一旦漂移，就会把数据搬到错误的目录。
/// 解析失败（例如当前路径不可访问）返回 null，调用方据此跳过相关操作。
///
/// 提到顶层而不是留在某个 tile 的 State 里：下载目录迁移与「原应用下载目录
/// 复制到本应用」都要用同一个结果。
Future<String?> _resolveCurrentDownloadRoot() async {
  final manager = DownloadManager();
  try {
    await manager.init();
  } catch (_) {
    return null;
  }
  final resolved = manager.path?.trim() ?? '';
  if (resolved.isNotEmpty) {
    return resolved;
  }
  final configured = appdata.settings[22].trim();
  return configured.isEmpty ? null : configured;
}
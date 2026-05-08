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
    'DownloadManager.init:start',
  );
  await DownloadManager().init().timeout(const Duration(seconds: 10));
  LogManager.addLog(
      LogLevel.info, 'ManagedDataReload', 'DownloadManager.init:ok');

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
      MethodChannel('com.example.picakeep/storage_access');

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

  Future<_AndroidShizukuStatus> getShizukuStatus() async {
    if (!App.isAndroid) {
      return const _AndroidShizukuStatus(
        installed: false,
        running: false,
        permissionGranted: false,
      );
    }
    try {
      final result = await _channel.invokeMethod<Object>('getShizukuStatus');
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

  Future<bool> hasShizukuPermission() async {
    if (!App.isAndroid) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>('hasShizukuPermission') ?? false;
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

  Future<bool> hasRootAccess() async {
    if (!App.isAndroid) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>('hasRootAccess') ?? false;
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
}

bool _isAndroidRootModeEnabled() {
  return normalizeAndroidRootMode(appdata.settings[androidRootModeSettingIndex]) ==
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

enum _AndroidDirectoryBrowseMode {
  manageAllFiles,
  shizuku,
  root,
}

Future<bool> _requestAndroidRootAccess() async {
  if (!App.isAndroid) {
    return false;
  }
  return _AndroidStorageAccessController.instance.hasRootAccess();
}

String _joinDirectoryPath(String parent, String child) {
  if (parent.isEmpty || parent == '/') {
    return '/$child';
  }
  if (parent.endsWith('/')) {
    return '$parent$child';
  }
  return '$parent/$child';
}

String? _parentDirectoryPath(String path) {
  final normalized = path.trim();
  if (normalized.isEmpty || normalized == '/') {
    return null;
  }
  final segments = normalized.split('/')..removeWhere((e) => e.isEmpty);
  if (segments.isEmpty) {
    return '/';
  }
  segments.removeLast();
  if (segments.isEmpty) {
    return '/';
  }
  return '/${segments.join('/')}';
}

Future<List<String>> _listDirectoriesWithDartIo(String path) async {
  final directory = Directory(path);
  if (!await directory.exists()) {
    throw Exception('目录不存在或当前应用不可访问'.tl);
  }
  final directories = <String>{};
  await for (final entity in directory.list(followLinks: false)) {
    if (entity is! Directory) {
      continue;
    }
    final segments = entity.uri.pathSegments
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    if (segments.isEmpty) {
      continue;
    }
    final name = segments.last.trim();
    if (name.isNotEmpty) {
      directories.add(name);
    }
  }
  final sortedDirectories = directories.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return sortedDirectories;
}

Future<List<String>> _listDirectoriesWithRoot(String path) async {
  final rawPath = path.trim().replaceAll('\\', '/');
  final normalizedPath = rawPath.isEmpty
      ? '/'
      : (() {
          var value = rawPath.startsWith('/') ? rawPath : '/$rawPath';
          while (value.length > 1 && value.endsWith('/')) {
            value = value.substring(0, value.length - 1);
          }
          return value.isEmpty ? '/' : value;
        })();
  return _AndroidStorageAccessController.instance
      .listDirectoriesWithRoot(normalizedPath);
}

Future<List<String>> _listDirectoriesWithShizuku(String path) {
  return _AndroidStorageAccessController.instance.listDirectoriesWithShizuku(
    path,
  );
}

Future<String?> _openInternalDirectoryBrowser(
  BuildContext context, {
  required String title,
  String? initialPath,
}) async {
  if (!App.isAndroid) {
    return null;
  }
  final controller = _AndroidStorageAccessController.instance;
  final hasAllFilesAccess = await controller.hasManageAllFilesAccess();
  final hasShizukuAccess = _isAndroidShizukuModeEnabled() &&
      await controller.hasShizukuPermission();
  final hasRootAccess =
      _isAndroidRootModeEnabled() && await _requestAndroidRootAccess();
  if (!hasAllFilesAccess && !hasShizukuAccess && !hasRootAccess) {
    if (context.mounted) {
      _showSettingMessage(
        context,
        '长按“浏览”前，请先授予安卓全部文件访问权限，或开启 Shizuku 授权 / Root 模式'.tl,
      );
    }
    return null;
  }
  if (!context.mounted) {
    return null;
  }
  final browseMode = hasRootAccess
      ? _AndroidDirectoryBrowseMode.root
      : hasShizukuAccess
          ? _AndroidDirectoryBrowseMode.shizuku
          : _AndroidDirectoryBrowseMode.manageAllFiles;
  return Navigator.of(context).push<String>(
    MaterialPageRoute(
      builder: (_) => _InternalDirectoryBrowserPage(
        title: title,
        initialPath: initialPath,
        browseMode: browseMode,
      ),
    ),
  );
}

class _InternalDirectoryBrowserPage extends StatefulWidget {
  const _InternalDirectoryBrowserPage({
    required this.title,
    required this.initialPath,
    required this.browseMode,
  });

  final String title;
  final String? initialPath;
  final _AndroidDirectoryBrowseMode browseMode;

  @override
  State<_InternalDirectoryBrowserPage> createState() =>
      _InternalDirectoryBrowserPageState();
}

class _InternalDirectoryBrowserPageState
    extends State<_InternalDirectoryBrowserPage> {
  static const _androidPresetRoots = <String>[
    '/',
    '/storage',
    '/storage/emulated',
    '/storage/emulated/0',
    '/data/user/0/com.github.pacalini.pica_comic',
    '/data/data/com.github.pacalini.pica_comic',
    '/storage/emulated/0/Android/data/com.github.pacalini.pica_comic',
    '/storage/emulated/0/Android/data',
    '/sdcard',
  ];

  late final TextEditingController _pathController;
  late String _currentPath;
  bool _loading = true;
  bool _showPresetRoots = false;
  int _pathLoadToken = 0;
  String? _errorText;
  List<String> _children = const <String>[];

  @override
  void initState() {
    super.initState();
    _currentPath = _normalizeInitialPath(widget.initialPath);
    _pathController = TextEditingController(text: _currentPath);
    _loadCurrentPath();
  }

  @override
  void dispose() {
    _pathController.dispose();
    super.dispose();
  }

  String _normalizeInitialPath(String? path) {
    final value = path?.trim() ?? '';
    if (value.isNotEmpty) {
      return value;
    }
    return widget.browseMode == _AndroidDirectoryBrowseMode.root
        ? '/'
        : '/storage/emulated/0';
  }

  String _normalizePathInput(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) {
      return _currentPath;
    }
    var normalized = trimmed.replaceAll('\\', '/');
    if (!normalized.startsWith('/')) {
      normalized = '/$normalized';
    }
    while (normalized.length > 1 && normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized.isEmpty ? '/' : normalized;
  }

  void _updatePathController() {
    _pathController.value = TextEditingValue(
      text: _currentPath,
      selection: TextSelection.collapsed(offset: _currentPath.length),
    );
  }

  Future<void> _loadCurrentPath() async {
    final loadToken = ++_pathLoadToken;
    final targetPath = _currentPath;
    if (mounted) {
      setState(() {
        _loading = true;
        _errorText = null;
      });
    }
    try {
      final children = switch (widget.browseMode) {
        _AndroidDirectoryBrowseMode.root =>
          await _listDirectoriesWithRoot(targetPath),
        _AndroidDirectoryBrowseMode.shizuku =>
          await _listDirectoriesWithShizuku(targetPath),
        _AndroidDirectoryBrowseMode.manageAllFiles =>
          await _listDirectoriesWithDartIo(targetPath),
      };
      if (!mounted || loadToken != _pathLoadToken || targetPath != _currentPath) {
        return;
      }
      setState(() {
        _children = children;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || loadToken != _pathLoadToken || targetPath != _currentPath) {
        return;
      }
      setState(() {
        _children = const <String>[];
        _errorText = e.toString().trim();
        _loading = false;
      });
    }
  }

  void _setCurrentPath(String path) {
    final nextPath = _normalizePathInput(path);
    if (nextPath == _currentPath) {
      _updatePathController();
      _loadCurrentPath();
      return;
    }
    setState(() {
      _currentPath = nextPath;
    });
    _updatePathController();
    _loadCurrentPath();
  }

  void _jumpToTypedPath() {
    _setCurrentPath(_pathController.text);
  }

  void _openChild(String name) {
    _setCurrentPath(_joinDirectoryPath(_currentPath, name));
  }

  void _openParent() {
    final parent = _parentDirectoryPath(_currentPath);
    if (parent == null) {
      return;
    }
    _setCurrentPath(parent);
  }

  Widget _buildPathJumpBar(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _pathController,
            onTap: () {
              if (!_showPresetRoots) {
                setState(() {
                  _showPresetRoots = true;
                });
              }
            },
            onSubmitted: (_) => _jumpToTypedPath(),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.route_outlined),
              hintText: '输入路径后可直接跳转'.tl,
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                onPressed: () {
                  setState(() {
                    _showPresetRoots = !_showPresetRoots;
                  });
                },
                icon: Icon(
                  _showPresetRoots ? Icons.expand_less : Icons.expand_more,
                ),
                tooltip: _showPresetRoots ? '收起快捷路径'.tl : '展开快捷路径'.tl,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: _jumpToTypedPath,
          child: Text('跳转'.tl),
        ),
      ],
    );
  }

  Widget _buildPresetRoots() {
    return AnimatedCrossFade(
      duration: const Duration(milliseconds: 180),
      crossFadeState: _showPresetRoots
          ? CrossFadeState.showFirst
          : CrossFadeState.showSecond,
      firstChild: Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final path in _androidPresetRoots)
                ActionChip(
                  label: Text(path),
                  onPressed: () => _setCurrentPath(path),
                ),
            ],
          ),
        ),
      ),
      secondChild: const SizedBox.shrink(),
    );
  }

  int get _listHeaderCount {
    var count = 0;
    if (_parentDirectoryPath(_currentPath) != null) {
      count++;
    }
    if (_errorText != null) {
      count++;
    }
    if (_children.isEmpty && _errorText == null) {
      count++;
    }
    return count;
  }

  Widget _buildListItem(BuildContext context, int index) {
    var cursor = 0;
    if (_parentDirectoryPath(_currentPath) != null) {
      if (index == cursor) {
        return ListTile(
          leading: const Icon(Icons.arrow_upward),
          title: Text('上一级'.tl),
          onTap: _openParent,
        );
      }
      cursor++;
    }
    if (_errorText != null) {
      if (index == cursor) {
        return ListTile(
          leading: const Icon(Icons.error_outline),
          title: Text('目录读取失败'.tl),
          subtitle: Text(_errorText!),
        );
      }
      cursor++;
    }
    if (_children.isEmpty && _errorText == null) {
      if (index == cursor) {
        return ListTile(
          leading: const Icon(Icons.folder_off_outlined),
          title: Text('当前目录下没有可浏览的子文件夹'.tl),
        );
      }
      cursor++;
    }
    final child = _children[index - cursor];
    return ListTile(
      leading: const Icon(Icons.folder_outlined),
      title: Text(child),
      subtitle: Text(_joinDirectoryPath(_currentPath, child)),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _openChild(child),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadCurrentPath,
            tooltip: '刷新'.tl,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  switch (widget.browseMode) {
                    _AndroidDirectoryBrowseMode.root => '当前使用 Root 模式浏览目录'.tl,
                    _AndroidDirectoryBrowseMode.shizuku => '当前使用 Shizuku 授权浏览目录'.tl,
                    _AndroidDirectoryBrowseMode.manageAllFiles =>
                      '当前使用安卓全部文件访问权限浏览目录'.tl,
                  },
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 8),
                _buildPathJumpBar(context),
                _buildPresetRoots(),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () => Navigator.of(context).pop(_currentPath),
                    icon: const Icon(Icons.check),
                    label: Text('选择当前文件夹'.tl),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : SmoothScrollProvider(
                    builder: (context, controller, physics) => ListView.builder(
                      controller: controller,
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      physics: physics,
                      cacheExtent: 480,
                      itemCount: _listHeaderCount + _children.length,
                      itemBuilder: (context, index) =>
                          _buildListItem(context, index),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
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
    _load();
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
    final granted =
        await _AndroidStorageAccessController.instance.hasManageAllFilesAccess();
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
  State<_AndroidShizukuModeTile> createState() => _AndroidShizukuModeTileState();
}

class _AndroidShizukuModeTileState extends State<_AndroidShizukuModeTile>
    with WidgetsBindingObserver {
  bool _busy = false;
  bool? _installed;
  bool? _running;
  bool? _granted;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
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
    final controller = _AndroidStorageAccessController.instance;
    final status = await controller.getShizukuStatus();
    final nextEnabled = status.running && status.permissionGranted;
    if (_isAndroidShizukuModeEnabled() != nextEnabled) {
      unawaited(_setAndroidShizukuModeEnabled(nextEnabled));
    }
    if (!mounted) {
      return;
    }
    setState(() {
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
    if (_busy) {
      return;
    }
    setState(() {
      _busy = true;
    });
    try {
      final controller = _AndroidStorageAccessController.instance;
      if (value) {
        final action = await _askEnableAction();
        if (!mounted || action == null) {
          await _load();
          return;
        }
        if (action == 'open') {
          await controller.openShizukuApp();
          if (mounted) {
            _showSettingMessage(context, '已打开 Shizuku；回到本应用后会自动重新检测服务和授权状态'.tl);
          }
          return;
        }

        final running = _running ?? (await controller.getShizukuStatus()).running;
        if (!running) {
          await controller.openShizukuApp();
          if (mounted) {
            _showSettingMessage(context, '当前未连接到 Shizuku 服务，已为你打开 Shizuku；启动服务后再返回授权'.tl);
          }
          return;
        }

        final granted = await controller.requestShizukuPermission();
        if (!granted) {
          if (mounted) {
            _showSettingMessage(context, '未获取到 Shizuku 授权'.tl);
          }
          await _setAndroidShizukuModeEnabled(false);
          await _load();
          return;
        }
      } else {
        await _setAndroidShizukuModeEnabled(false);
      }
      await _load();
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
    final enabled = _granted ?? false;
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

class _AndroidRootModeTileState extends State<_AndroidRootModeTile> {
  bool _busy = false;
  bool _enabled = _isAndroidRootModeEnabled();

  Future<void> _setValue(bool value) async {
    if (_busy || value == _enabled) {
      return;
    }
    setState(() {
      _busy = true;
    });
    try {
      if (value) {
        final granted = await _requestAndroidRootAccess();
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
    if (_busy ||
        normalized == appdata.settings[deleteBehaviorSettingIndex]) {
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
                GestureDetector(
                  onLongPress: () async {
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
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
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
                ),
              ],
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '提示：点按“浏览”调用系统目录选择；长按“浏览”打开内置文件夹浏览，支持安卓全部文件访问权限、Shizuku 授权或 Root 模式。'.tl,
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
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
                GestureDetector(
                  onLongPress: () async {
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
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
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
                ),
              ],
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '提示：点按“浏览”调用系统目录选择；长按“浏览”打开内置文件夹浏览，支持安卓全部文件访问权限、Shizuku 授权或 Root 模式。'.tl,
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
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

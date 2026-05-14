part of 'settings_page.dart';

enum _AndroidDirectoryBrowseMode {
  manageAllFiles,
  shizuku,
  root,
}

class _DirectoryQuickPath {
  const _DirectoryQuickPath({
    required this.label,
    required this.path,
  });

  final String label;
  final String path;
}

class _DirectoryBrowserEntry {
  const _DirectoryBrowserEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
  });

  final String name;
  final String path;
  final bool isDirectory;
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

String _normalizeDirectoryPath(String path) {
  final rawPath = path.trim().replaceAll('\\', '/');
  if (rawPath.isEmpty) {
    return '/';
  }
  var normalized = rawPath.startsWith('/') ? rawPath : '/$rawPath';
  while (normalized.length > 1 && normalized.endsWith('/')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return normalized.isEmpty ? '/' : normalized;
}

Future<List<_DirectoryBrowserEntry>> _listEntriesWithDartIo(String path) async {
  final directory = Directory(path);
  if (!await directory.exists()) {
    throw Exception('目录不存在或当前应用不可访问'.tl);
  }
  final entries = <_DirectoryBrowserEntry>[];
  await for (final entity in directory.list(followLinks: false)) {
    if (entity is! Directory && entity is! File) {
      continue;
    }
    final segments = entity.uri.pathSegments
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    if (segments.isEmpty) {
      continue;
    }
    final name = segments.last.trim();
    if (name.isEmpty) {
      continue;
    }
    entries.add(
      _DirectoryBrowserEntry(
        name: name,
        path: entity.path.replaceAll('\\', '/'),
        isDirectory: entity is Directory,
      ),
    );
  }
  entries.sort((a, b) {
    if (a.isDirectory != b.isDirectory) {
      return a.isDirectory ? -1 : 1;
    }
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return entries;
}

Future<List<_DirectoryBrowserEntry>> _listEntriesWithRoot(String path) async {
  final items = await _AndroidStorageAccessController.instance
      .listDirectoryEntriesWithRoot(_normalizeDirectoryPath(path));
  return items
      .map(
        (item) => _DirectoryBrowserEntry(
          name: item['name'] ?? '',
          path: _joinDirectoryPath(path, item['name'] ?? ''),
          isDirectory: item['type'] == 'directory',
        ),
      )
      .where((item) => item.name.trim().isNotEmpty)
      .toList(growable: false);
}

Future<List<_DirectoryBrowserEntry>> _listEntriesWithShizuku(String path) async {
  final items = await _AndroidStorageAccessController.instance
      .listDirectoryEntriesWithShizuku(_normalizeDirectoryPath(path));
  return items
      .map(
        (item) => _DirectoryBrowserEntry(
          name: item['name'] ?? '',
          path: _joinDirectoryPath(path, item['name'] ?? ''),
          isDirectory: item['type'] == 'directory',
        ),
      )
      .where((item) => item.name.trim().isNotEmpty)
      .toList(growable: false);
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
  final hasShizukuAccess =
      _isAndroidShizukuModeEnabled() && await controller.hasShizukuPermission();
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
    '/data/user/0',
    '/storage/emulated/0',
    '/sdcard',
    '/storage/emulated/0/Android/data',
    '/data/user/0/com.github.pacalini.pica_comic',
    '/data/data/com.github.pacalini.pica_comic',
    '/storage/emulated/0/Android/data/com.github.pacalini.pica_comic',
  ];

  static const _quickPaths = <_DirectoryQuickPath>[
    _DirectoryQuickPath(label: 'Root/应用目录', path: '/data/user/0'),
    _DirectoryQuickPath(
      label: 'Shizuku/应用目录',
      path: '/storage/emulated/0/Android/data/',
    ),
    _DirectoryQuickPath(
      label: '原应用目录',
      path: '/data/user/0/com.github.pacalini.pica_comic',
    ),
    _DirectoryQuickPath(label: '普通目录', path: '/storage/emulated/0'),
  ];

  late final TextEditingController _searchController;
  late String _currentPath;
  bool _loading = true;
  bool _showPresetRoots = false;
  int _pathLoadToken = 0;
  String? _errorText;
  List<_DirectoryBrowserEntry> _children = const <_DirectoryBrowserEntry>[];

  @override
  void initState() {
    super.initState();
    _currentPath = _normalizeInitialPath(widget.initialPath);
    _searchController = TextEditingController();
    _searchController.addListener(() {
      if (mounted) {
        setState(() {});
      }
    });
    _loadCurrentPath();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  String _normalizeInitialPath(String? path) {
    final value = path?.trim() ?? '';
    if (value.isNotEmpty) {
      return _normalizeDirectoryPath(value);
    }
    return widget.browseMode == _AndroidDirectoryBrowseMode.root
        ? '/'
        : '/storage/emulated/0';
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
          await _listEntriesWithRoot(targetPath),
        _AndroidDirectoryBrowseMode.shizuku =>
          await _listEntriesWithShizuku(targetPath),
        _AndroidDirectoryBrowseMode.manageAllFiles =>
          await _listEntriesWithDartIo(targetPath),
      };
      if (!mounted ||
          loadToken != _pathLoadToken ||
          targetPath != _currentPath) {
        return;
      }
      setState(() {
        _children = children;
        _loading = false;
      });
    } catch (e) {
      if (!mounted ||
          loadToken != _pathLoadToken ||
          targetPath != _currentPath) {
        return;
      }
      setState(() {
        _children = const <_DirectoryBrowserEntry>[];
        _errorText = e.toString().trim();
        _loading = false;
      });
    }
  }

  void _setCurrentPath(String path) {
    final nextPath = _normalizeDirectoryPath(path);
    if (nextPath == _currentPath) {
      _loadCurrentPath();
      return;
    }
    setState(() {
      _currentPath = nextPath;
    });
    _searchController.clear();
    _loadCurrentPath();
  }

  void _openEntry(_DirectoryBrowserEntry entry) {
    if (!entry.isDirectory) {
      return;
    }
    _setCurrentPath(entry.path);
  }

  void _openParent() {
    final parent = _parentDirectoryPath(_currentPath);
    if (parent == null) {
      return;
    }
    _setCurrentPath(parent);
  }

  IconData get _browseModeIcon => switch (widget.browseMode) {
        _AndroidDirectoryBrowseMode.root => Icons.bolt,
        _AndroidDirectoryBrowseMode.shizuku => Icons.bolt,
        _AndroidDirectoryBrowseMode.manageAllFiles => Icons.folder_open,
      };

  String get _searchKeyword => _searchController.text.trim().toLowerCase();

  List<String> get _pathSegments {
    if (_currentPath == '/') {
      return const <String>['/'];
    }
    final segments = _currentPath
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    return <String>['/', ...segments];
  }

  List<_DirectoryBrowserEntry> get _filteredChildren {
    final keyword = _searchKeyword;
    if (keyword.isEmpty) {
      return _children;
    }
    return _children
        .where((child) => child.name.toLowerCase().contains(keyword))
        .toList(growable: false);
  }

  String _pathForSegmentIndex(int index) {
    if (index <= 0) {
      return '/';
    }
    final segments = _pathSegments.skip(1).take(index).toList(growable: false);
    if (segments.isEmpty) {
      return '/';
    }
    return '/${segments.join('/')}';
  }

  Widget _buildBreadcrumbBar(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: theme.colorScheme.surfaceContainerLow,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (var i = 0; i < _pathSegments.length; i++) ...[
              ActionChip(
                avatar: i == 0
                    ? const Icon(Icons.home_outlined, size: 16)
                    : null,
                label: Text(_pathSegments[i]),
                visualDensity: VisualDensity.compact,
                onPressed: () => _setCurrentPath(_pathForSegmentIndex(i)),
              ),
              if (i != _pathSegments.length - 1)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Icon(
                    Icons.chevron_right,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSearchBar() {
    return TextField(
      controller: _searchController,
      decoration: InputDecoration(
        hintText: '过滤文件/目录...'.tl,
        prefixIcon: const Icon(Icons.search, size: 20),
        suffixIcon: _searchController.text.isNotEmpty
            ? IconButton(
                tooltip: '清空'.tl,
                onPressed: _searchController.clear,
                icon: const Icon(Icons.clear, size: 18),
              )
            : null,
        filled: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
      ),
    );
  }

  Widget _buildHorizontalPathChips({
    required List<_DirectoryQuickPath> items,
    bool useModeIcon = false,
  }) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            ActionChip(
              avatar: Icon(
                useModeIcon && i == 0 ? _browseModeIcon : Icons.bolt,
                size: 16,
              ),
              label: Text(
                items[i].label,
                style: const TextStyle(fontSize: 11),
              ),
              onPressed: () => _setCurrentPath(items[i].path),
              visualDensity: VisualDensity.compact,
            ),
            if (i != items.length - 1) const SizedBox(width: 6),
          ],
        ],
      ),
    );
  }

  Widget _buildQuickPaths() {
    return _buildHorizontalPathChips(
      items: _quickPaths,
      useModeIcon: true,
    );
  }

  Widget _buildExpandedPresetRoots() {
    return Align(
      alignment: Alignment.centerLeft,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final path in _androidPresetRoots)
            ActionChip(
              label: Text(
                path,
                style: const TextStyle(fontSize: 11),
              ),
              onPressed: () => _setCurrentPath(path),
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
    );
  }

  Widget _buildPresetRoots() {
    return AnimatedCrossFade(
      duration: const Duration(milliseconds: 180),
      crossFadeState: _showPresetRoots
          ? CrossFadeState.showFirst
          : CrossFadeState.showSecond,
      firstChild: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: _buildExpandedPresetRoots(),
      ),
      secondChild: const SizedBox.shrink(),
    );
  }

  Widget _buildSelectCurrentFolderButton() {
    return FilledButton.tonalIcon(
      onPressed: () => Navigator.of(context).pop(_currentPath),
      icon: const Icon(Icons.check, size: 18),
      label: Text('选择当前文件夹'.tl),
      style: FilledButton.styleFrom(
        visualDensity: VisualDensity.compact,
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
    );
  }

  Widget _buildTogglePresetButton() {
    return SizedBox(
      height: 48,
      child: ActionChip(
        avatar: Icon(
          _showPresetRoots ? Icons.expand_less : Icons.expand_more,
          size: 16,
        ),
        label: Text(
          _showPresetRoots ? '收起预设路径'.tl : '展开预设路径'.tl,
          style: const TextStyle(fontSize: 11),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        onPressed: () {
          setState(() {
            _showPresetRoots = !_showPresetRoots;
          });
        },
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  Widget _buildEntryTile(
    BuildContext context, {
    required IconData icon,
    required Color backgroundColor,
    required Color foregroundColor,
    required String title,
    required String subtitle,
    required bool tappable,
    VoidCallback? onTap,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Material(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: tappable ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: backgroundColor,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(icon, color: foregroundColor),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  tappable ? Icons.chevron_right : Icons.insert_drive_file_outlined,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildErrorState(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Card.outlined(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Center(
                  child: Icon(Icons.error_outline, size: 48, color: Colors.red),
                ),
                const SizedBox(height: 12),
                Text(
                  '目录读取失败'.tl,
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                SelectableText(
                  _errorText ?? '',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.center,
                  child: ElevatedButton(
                    onPressed: _loadCurrentPath,
                    child: Text('刷新'.tl),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    final hasFilter = _searchKeyword.isNotEmpty;
    return Center(
      child: Text(
        hasFilter ? '当前目录下没有匹配的文件/目录'.tl : '当前目录下没有可显示的文件/目录'.tl,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final parentPath = _parentDirectoryPath(_currentPath);
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
          _buildBreadcrumbBar(context),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            child: _buildSearchBar(),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Column(
              children: [
                _buildQuickPaths(),
                _buildPresetRoots(),
                const SizedBox(height: 6),
                Row(
                  children: [
                    _buildTogglePresetButton(),
                    const Spacer(),
                    _buildSelectCurrentFolderButton(),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          if (parentPath != null)
            _buildEntryTile(
              context,
              icon: Icons.arrow_upward,
              backgroundColor: theme.colorScheme.tertiaryContainer,
              foregroundColor: theme.colorScheme.onTertiaryContainer,
              title: '上一层'.tl,
              subtitle: parentPath,
              tappable: true,
              onTap: _openParent,
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _errorText != null
                    ? SingleChildScrollView(child: _buildErrorState(context))
                    : _filteredChildren.isEmpty
                        ? _buildEmptyState()
                        : SmoothScrollProvider(
                            builder: (context, controller, physics) =>
                                ListView.builder(
                              controller: controller,
                              keyboardDismissBehavior:
                                  ScrollViewKeyboardDismissBehavior.onDrag,
                              physics: physics,
                              cacheExtent: 480,
                              itemCount: _filteredChildren.length,
                              itemBuilder: (context, index) {
                                final entry = _filteredChildren[index];
                                return _buildEntryTile(
                                  context,
                                  icon: entry.isDirectory
                                      ? Icons.folder_outlined
                                      : Icons.insert_drive_file_outlined,
                                  backgroundColor: entry.isDirectory
                                      ? theme.colorScheme.primaryContainer
                                      : theme.colorScheme.secondaryContainer,
                                  foregroundColor: entry.isDirectory
                                      ? theme.colorScheme.primary
                                      : theme.colorScheme.onSecondaryContainer,
                                  title: entry.name,
                                  subtitle: entry.path,
                                  tappable: entry.isDirectory,
                                  onTap: () => _openEntry(entry),
                                );
                              },
                            ),
                          ),
          ),
        ],
      ),
    );
  }
}

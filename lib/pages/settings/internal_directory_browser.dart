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
    this.browseMode,
  });

  final String label;
  final String path;
  final _AndroidDirectoryBrowseMode? browseMode;
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

bool _prefersManageAllFilesMode(String? path) {
  final normalized = _normalizeDirectoryPath(path ?? '');
  if (normalized == '/' || normalized.isEmpty) {
    return false;
  }
  if (_requiresPrivilegedDirectoryAccess(normalized)) {
    return false;
  }
  return normalized.startsWith('/storage/') || normalized.startsWith('/sdcard');
}

bool _isAndroidDataLikePath(String path) {
  final normalized = _normalizeDirectoryPath(path);
  return normalized == '/storage/emulated/0/Android/data' ||
      normalized.startsWith('/storage/emulated/0/Android/data/') ||
      normalized == '/sdcard/Android/data' ||
      normalized.startsWith('/sdcard/Android/data/');
}

bool _isAndroidDataRootPath(String path) {
  final normalized = _normalizeDirectoryPath(path);
  return normalized == '/storage/emulated/0/Android/data' ||
      normalized == '/sdcard/Android/data';
}

bool _requiresPrivilegedDirectoryAccess(String path) {
  final normalized = _normalizeDirectoryPath(path);
  return normalized.startsWith('/data/') ||
      normalized == '/data' ||
      normalized.startsWith('/data_mirror/') ||
      normalized == '/data_mirror' ||
      _isAndroidDataLikePath(normalized);
}

String _directoryNameFromPath(String path) {
  final normalized = _normalizeDirectoryPath(path);
  if (normalized == '/') {
    return '/';
  }
  final segments = normalized.split('/')..removeWhere((e) => e.isEmpty);
  return segments.isEmpty ? '/' : segments.last;
}

/// 校验“新建文件夹”的输入名称。
///
/// 合法时返回 `null`，否则返回可直接展示给用户的错误文案。
///
/// 只做与文件系统语义相关的必要校验：空名、路径分隔符、`.`/`..`、控制字符
/// 以及单个路径段的字节上限。重名与“同名文件”由调用方结合当前目录列表判断，
/// 因为那需要一次目录枚举，放在这里会导致弹窗与列表状态不同步。
String? validateNewDirectoryName(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) {
    return '文件夹名称不能为空';
  }
  if (trimmed == '.' || trimmed == '..') {
    return '文件夹名称不能是 . 或 ..';
  }
  if (trimmed.contains('/') || trimmed.contains('\\')) {
    return '文件夹名称不能包含 / 或 \\';
  }
  if (trimmed.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
    return '文件夹名称不能包含控制字符';
  }
  // ext4 / f2fs 的单个路径段上限是 255 字节，中文按 UTF-8 算 3 字节。
  if (utf8.encode(trimmed).length > 255) {
    return '文件夹名称过长';
  }
  return null;
}

/// 在 [parentPath] 下拼接新建文件夹的完整路径。
String resolveNewDirectoryPath(String parentPath, String name) {
  return _joinDirectoryPath(
    _normalizeDirectoryPath(parentPath),
    name.trim(),
  );
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

Future<List<_DirectoryBrowserEntry>> _listEntriesWithShizuku(
    String path) async {
  final normalizedPath = _normalizeDirectoryPath(path);
  final controller = _AndroidStorageAccessController.instance;
  List<Map<String, String>> items;
  if (_isAndroidDataRootPath(normalizedPath)) {
    try {
      items = await controller.listAndroidDataDirectoryWithShizuku();
    } catch (_) {
      items = await controller.listDirectoryEntriesWithShizuku(normalizedPath);
    }
  } else {
    items = await controller.listDirectoryEntriesWithShizuku(normalizedPath);
  }
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

Future<String?> openInternalDirectoryBrowser(
  BuildContext context, {
  required String title,
  String? initialPath,
  bool rootNavigator = true,
}) async {
  if (!App.isAndroid) {
    return null;
  }
  final controller = _AndroidStorageAccessController.instance;
  final hasAllFilesAccess = await controller.hasManageAllFilesAccess();
  final preferManageAllFiles = _prefersManageAllFilesMode(initialPath);
  final hasShizukuAccess =
      !preferManageAllFiles && _isAndroidShizukuModeEnabled()
          ? await controller.hasShizukuPermission()
          : false;
  final hasRootAccess = !preferManageAllFiles && _isAndroidRootModeEnabled()
      ? await _requestAndroidRootAccess()
      : false;
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
  return Navigator.of(context, rootNavigator: rootNavigator).push<String>(
    MaterialPageRoute(
      builder: (_) => _InternalDirectoryBrowserPage(
        title: title,
        initialPath: initialPath,
        browseMode: browseMode,
        allowManageAllFiles: hasAllFilesAccess,
        allowShizuku: hasShizukuAccess,
        allowRoot: hasRootAccess,
      ),
    ),
  );
}

/// “新建文件夹”输入弹窗。
///
/// 只负责收集名称、做格式校验与提交中状态；真正的创建（重名判断 + 落盘）
/// 由 [onSubmit] 回调完成，成功后弹窗 pop 出新建目录的完整路径。
class _CreateFolderDialog extends StatefulWidget {
  const _CreateFolderDialog({
    required this.parentPath,
    required this.onSubmit,
  });

  final String parentPath;

  /// 返回 `null` 表示创建成功，否则返回给用户看的错误文案。
  final Future<String?> Function(String name) onSubmit;

  @override
  State<_CreateFolderDialog> createState() => _CreateFolderDialogState();
}

class _CreateFolderDialogState extends State<_CreateFolderDialog> {
  late final TextEditingController _controller;
  String? _errorText;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) {
      return;
    }
    final name = _controller.text.trim();
    final validationError = validateNewDirectoryName(name);
    if (validationError != null) {
      setState(() => _errorText = validationError.tl);
      return;
    }
    setState(() {
      _submitting = true;
      _errorText = null;
    });
    final error = await widget.onSubmit(name);
    if (!mounted) {
      return;
    }
    if (error != null) {
      setState(() {
        _submitting = false;
        _errorText = error;
      });
      return;
    }
    Navigator.of(context).pop(resolveNewDirectoryPath(widget.parentPath, name));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text('新建文件夹'.tl),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            enabled: !_submitting,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: '文件夹名称'.tl,
              hintText: '例如 PicaKeep',
              errorText: _errorText,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '创建位置：${_normalizeDirectoryPath(widget.parentPath)}',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: Text('取消'.tl),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text('创建'.tl),
        ),
      ],
    );
  }
}

/// 文件夹浏览页底部的三个操作按钮：展开预设路径 / 新建文件夹 / 选择当前文件夹。
///
/// 单独抽成公开组件，是因为**这一行在窄屏上极易挤到换行**：三个按钮的文案、
/// 字号与内边距共同决定放不放得下。集中在一处才好调，也才能把它单独渲染出来
/// 量实际宽度、出预览图（见 `test/ui_preview/directory_browser_actions_preview_test.dart`），
/// 不必每次都装到手机上用眼睛判断。
class DirectoryBrowserActionRow extends StatelessWidget {
  const DirectoryBrowserActionRow({
    super.key,
    required this.showPresetRoots,
    required this.actionsEnabled,
    required this.onTogglePresetRoots,
    required this.onCreateFolder,
    required this.onSelectCurrentFolder,
  });

  /// 预设路径是否已展开（决定第一个按钮的图标与文案）。
  final bool showPresetRoots;

  /// 目录尚未加载完时禁用"新建"与"选择"。
  final bool actionsEnabled;

  final VoidCallback onTogglePresetRoots;
  final VoidCallback onCreateFolder;
  final VoidCallback onSelectCurrentFolder;

  /// 按钮统一高度：三个按钮等高，换行后两行间距才整齐。
  static const double buttonHeight = 48;

  /// 按钮之间的间隔（水平与垂直共用）。
  static const double buttonSpacing = 8;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: buttonSpacing,
      runSpacing: buttonSpacing,
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _buildTogglePresetButton(),
        _buildCreateFolderButton(),
        _buildSelectCurrentFolderButton(),
      ],
    );
  }

  Widget _buildTogglePresetButton() {
    // 文案从「展开预设路径」收到「预设路径」：展开/收起由图标表达，
    // 状态语义不丢，但省下的两个字是这一行能不能单行放下的关键。
    return SizedBox(
      height: buttonHeight,
      child: Tooltip(
        message: (showPresetRoots ? '收起预设路径' : '展开预设路径').tl,
        child: ActionChip(
          avatar: Icon(
            showPresetRoots ? Icons.expand_less : Icons.expand_more,
            size: 16,
          ),
          label: Text(
            '预设路径'.tl,
            style: const TextStyle(fontSize: 11),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          onPressed: onTogglePresetRoots,
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }

  Widget _buildCreateFolderButton() {
    return SizedBox(
      height: buttonHeight,
      child: Tooltip(
        message: '新建文件夹'.tl,
        child: ActionChip(
          avatar: const Icon(Icons.create_new_folder_outlined, size: 16),
          label: Text(
            '新建'.tl,
            style: const TextStyle(fontSize: 11),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          onPressed: actionsEnabled ? onCreateFolder : null,
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }

  Widget _buildSelectCurrentFolderButton() {
    // 外层 SizedBox 是必要的：`visualDensity: compact` 会把
    // `minimumSize` 的高度抵消掉 8 dp（实测 48 → 40），
    // 按钮会比另外两个矮一截。这里统一钉到 buttonHeight。
    return SizedBox(
      height: buttonHeight,
      child: Tooltip(
        message: '选择当前文件夹'.tl,
        child: FilledButton.tonalIcon(
          onPressed: onSelectCurrentFolder,
          icon: const Icon(Icons.check, size: 18),
          label: Text('选择文件夹'.tl),
          style: FilledButton.styleFrom(
            visualDensity: VisualDensity.compact,
            minimumSize: const Size(0, buttonHeight),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
        ),
      ),
    );
  }
}

class _InternalDirectoryBrowserPage extends StatefulWidget {
  const _InternalDirectoryBrowserPage({
    required this.title,
    required this.initialPath,
    required this.browseMode,
    required this.allowManageAllFiles,
    required this.allowShizuku,
    required this.allowRoot,
  });

  final String title;
  final String? initialPath;
  final _AndroidDirectoryBrowseMode browseMode;
  final bool allowManageAllFiles;
  final bool allowShizuku;
  final bool allowRoot;

  @override
  State<_InternalDirectoryBrowserPage> createState() =>
      _InternalDirectoryBrowserPageState();
}

class _InternalDirectoryBrowserPageState
    extends State<_InternalDirectoryBrowserPage> {
  static const String _shizukuFuseHintPrefsKey =
      'shizuku_fuse_limit_hint_dismissed';
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
    _DirectoryQuickPath(
      label: 'Root/应用目录',
      path: '/data/user/0',
      browseMode: _AndroidDirectoryBrowseMode.root,
    ),
    _DirectoryQuickPath(
      label: 'Shizuku/应用目录',
      path: '/storage/emulated/0/Android/data/',
      browseMode: _AndroidDirectoryBrowseMode.shizuku,
    ),
    _DirectoryQuickPath(
      label: '原应用目录',
      path: '/data/user/0/com.github.pacalini.pica_comic',
      browseMode: _AndroidDirectoryBrowseMode.root,
    ),
    _DirectoryQuickPath(
      label: '普通目录',
      path: '/storage/emulated/0',
      browseMode: _AndroidDirectoryBrowseMode.manageAllFiles,
    ),
  ];

  late final TextEditingController _searchController;
  late String _currentPath;
  late _AndroidDirectoryBrowseMode _browseMode;
  bool _loading = true;
  bool _showPresetRoots = false;
  bool _shizukuFuseHintDismissed = false;
  int _pathLoadToken = 0;
  String? _errorText;
  List<_DirectoryBrowserEntry> _children = const <_DirectoryBrowserEntry>[];

  @override
  void initState() {
    super.initState();
    _currentPath = _normalizeInitialPath(widget.initialPath);
    _browseMode = _resolveBrowseModeForPath(
      _currentPath,
      preferred: widget.browseMode,
    );
    _searchController = TextEditingController();
    _searchController.addListener(() {
      if (mounted) {
        setState(() {});
      }
    });
    SharedPreferences.getInstance().then((prefs) {
      if (!mounted) {
        return;
      }
      final dismissed = prefs.getBool(_shizukuFuseHintPrefsKey) ?? false;
      if (dismissed != _shizukuFuseHintDismissed) {
        setState(() => _shizukuFuseHintDismissed = dismissed);
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
    return '/storage/emulated/0';
  }

  _AndroidDirectoryBrowseMode _resolveBrowseModeForPath(
    String path, {
    _AndroidDirectoryBrowseMode? preferred,
  }) {
    final normalized = _normalizeDirectoryPath(path);
    if (_requiresPrivilegedDirectoryAccess(normalized)) {
      if (preferred == _AndroidDirectoryBrowseMode.shizuku &&
          widget.allowShizuku) {
        return _AndroidDirectoryBrowseMode.shizuku;
      }
      if (preferred == _AndroidDirectoryBrowseMode.root && widget.allowRoot) {
        return _AndroidDirectoryBrowseMode.root;
      }
      if (_isAndroidDataLikePath(normalized) && widget.allowShizuku) {
        return _AndroidDirectoryBrowseMode.shizuku;
      }
      if (widget.allowRoot) {
        return _AndroidDirectoryBrowseMode.root;
      }
      if (widget.allowShizuku) {
        return _AndroidDirectoryBrowseMode.shizuku;
      }
    }
    if (widget.allowManageAllFiles) {
      return _AndroidDirectoryBrowseMode.manageAllFiles;
    }
    if (widget.allowRoot) {
      return _AndroidDirectoryBrowseMode.root;
    }
    if (widget.allowShizuku) {
      return _AndroidDirectoryBrowseMode.shizuku;
    }
    return preferred ?? widget.browseMode;
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
      var children = switch (_browseMode) {
        _AndroidDirectoryBrowseMode.root =>
          await _listEntriesWithRoot(targetPath),
        _AndroidDirectoryBrowseMode.shizuku =>
          await _listEntriesWithShizuku(targetPath),
        _AndroidDirectoryBrowseMode.manageAllFiles =>
          await _listEntriesWithDartIo(targetPath),
      };
      children = await _injectKnownMissingEntries(
        targetPath,
        children,
      );
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

  Future<List<_DirectoryBrowserEntry>> _injectKnownMissingEntries(
    String targetPath,
    List<_DirectoryBrowserEntry> children,
  ) async {
    if (_browseMode == _AndroidDirectoryBrowseMode.manageAllFiles ||
        !_isAndroidDataLikePath(targetPath)) {
      return children;
    }

    final existingPaths =
        children.map((entry) => _normalizeDirectoryPath(entry.path)).toSet();
    final injected = <_DirectoryBrowserEntry>[];

    for (final candidatePath in _androidPresetRoots) {
      final normalizedCandidate = _normalizeDirectoryPath(candidatePath);
      if (_parentDirectoryPath(normalizedCandidate) !=
          _normalizeDirectoryPath(targetPath)) {
        continue;
      }
      if (existingPaths.contains(normalizedCandidate)) {
        continue;
      }
      final exists = switch (_browseMode) {
        _AndroidDirectoryBrowseMode.root =>
          await _AndroidStorageAccessController.instance
              .existsWithRoot(normalizedCandidate),
        _AndroidDirectoryBrowseMode.shizuku =>
          await _AndroidStorageAccessController.instance
              .existsWithShizuku(normalizedCandidate),
        _AndroidDirectoryBrowseMode.manageAllFiles => false,
      };
      if (!exists) {
        continue;
      }
      injected.add(
        _DirectoryBrowserEntry(
          name: _directoryNameFromPath(normalizedCandidate),
          path: normalizedCandidate,
          isDirectory: true,
        ),
      );
    }

    if (injected.isEmpty) {
      return children;
    }

    final merged = <_DirectoryBrowserEntry>[
      ...children,
      ...injected,
    ];
    merged.sort((a, b) {
      if (a.isDirectory != b.isDirectory) {
        return a.isDirectory ? -1 : 1;
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return merged;
  }

  void _setCurrentPath(String path) {
    _setCurrentPathWithMode(path);
  }

  void _setCurrentPathWithMode(
    String path, {
    _AndroidDirectoryBrowseMode? preferredMode,
  }) {
    final nextPath = _normalizeDirectoryPath(path);
    final nextMode = _resolveBrowseModeForPath(
      nextPath,
      preferred: preferredMode ?? _browseMode,
    );
    if (nextPath == _currentPath) {
      if (nextMode != _browseMode) {
        setState(() {
          _browseMode = nextMode;
        });
      }
      _loadCurrentPath();
      return;
    }
    setState(() {
      _currentPath = nextPath;
      _browseMode = nextMode;
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

  /// 在当前目录下新建文件夹，成功后进入该目录。
  Future<void> _showCreateFolderDialog() async {
    final createdPath = await showDialog<String>(
      context: context,
      builder: (dialogContext) => _CreateFolderDialog(
        parentPath: _currentPath,
        onSubmit: _submitNewDirectory,
      ),
    );
    if (createdPath == null || !mounted) {
      return;
    }
    // 弹窗已经关闭，此时提示才不会被对话框盖住。
    _setCurrentPath(createdPath);
    _showSettingMessage(
        context, '已创建文件夹 ${_directoryNameFromPath(createdPath)}');
  }

  /// 返回 `null` 表示创建成功，否则返回展示给用户的错误文案。
  Future<String?> _submitNewDirectory(String name) async {
    final validationError = validateNewDirectoryName(name);
    if (validationError != null) {
      return validationError.tl;
    }
    final trimmed = name.trim();
    // 先用已枚举的列表拦截重名，避免把底层 "File exists" 直接抛给用户。
    for (final child in _children) {
      if (child.name == trimmed) {
        return (child.isDirectory ? '该文件夹已存在' : '同名文件已存在').tl;
      }
    }
    final targetPath = resolveNewDirectoryPath(_currentPath, trimmed);
    try {
      await _createDirectoryAt(targetPath);
    } catch (e) {
      final message = e.toString().replaceFirst('Exception: ', '').trim();
      return message.isEmpty ? '创建文件夹失败'.tl : message;
    }
    return null;
  }

  /// 按当前浏览模式选择落盘方式。
  ///
  /// 优先用 dart:io：在「全部文件访问权限」模式下这样建出来的目录属主是应用
  /// 自己，后续下载走 dart:io 写入不会碰到属主/权限问题。只有在 dart:io
  /// 明确不可用时（`/data` 等受限路径）才回退到 Root / Shizuku 通道。
  ///
  /// 注意两者失败信息不同源：dart:io 抛的是 `FileSystemException`，
  /// 特权通道抛的是原生的中文文案，调用方统一按"展示 message"处理。
  Future<void> _createDirectoryAt(String path) async {
    try {
      final directory = Directory(path);
      if (await directory.exists()) {
        return;
      }
      await directory.create(recursive: true);
      // scoped storage 下 dart:io 存在"调用成功但实际被静默拦截"的情况
      // （见 PrivilegedStorageAccess 的同类处理），回查一次确认。
      // 误判也无害：特权通道对已存在的目录是幂等成功的。
      if (await directory.exists()) {
        return;
      }
    } catch (_) {
      // 交给下面的特权通道。
    }
    final controller = _AndroidStorageAccessController.instance;
    switch (_browseMode) {
      case _AndroidDirectoryBrowseMode.root:
        await controller.createDirectoryWithRoot(path);
      case _AndroidDirectoryBrowseMode.shizuku:
        await controller.createDirectoryWithShizuku(path);
      case _AndroidDirectoryBrowseMode.manageAllFiles:
        throw Exception('当前目录不可写，请先授予安卓全部文件访问权限'.tl);
    }
  }

  IconData get _browseModeIcon => switch (_browseMode) {
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
                avatar:
                    i == 0 ? const Icon(Icons.home_outlined, size: 16) : null,
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

  Widget _buildShizukuFuseLimitHint(BuildContext context) {
    final theme = Theme.of(context);
    final hintText =
        'Shizuku 模式下 Android/data 受 FUSE 限制，可能少 1-2 项；完整结果需要 Root'.tl;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: _showShizukuFuseLimitDialog,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(
                  Icons.info_outline,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    hintText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showShizukuFuseLimitDialog() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Shizuku 模式下 Android/data 显示上限'.tl),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('当前模式：仅 Shizuku 授权（uid=2000 shell）。'.tl),
              const SizedBox(height: 12),
              Text(
                '/storage/emulated/0/Android/data 在 MIUI FUSE 下被过滤，dirent 与 java.io.File.listFiles() 都拿不到完整列表。'
                    .tl,
              ),
              const SizedBox(height: 12),
              Text(
                '已通过 IPackageManager.getInstalledPackages 与 dirent 做并集回退，能补回绝大多数包名目录。'
                    .tl,
              ),
              const SizedBox(height: 12),
              Text(
                '剩余 1-2 项通常是：getInstalledPackages 不会返回的孤儿包目录，以及 Android/data/.nomedia 这类非包名顶层文件。'
                    .tl,
              ),
              const SizedBox(height: 12),
              Text(
                '要拿到完整结果，需要切换到 Root 模式。Root 模式与普通 manageAllFiles 模式不会出现本提示。'.tl,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text('关闭'.tl),
          ),
          TextButton(
            onPressed: () async {
              final prefs = await SharedPreferences.getInstance();
              await prefs.setBool(_shizukuFuseHintPrefsKey, true);
              if (!mounted) {
                return;
              }
              setState(() => _shizukuFuseHintDismissed = true);
              if (dialogContext.mounted) {
                Navigator.of(dialogContext).pop();
              }
            },
            child: Text('不再提示'.tl),
          ),
        ],
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
              onPressed: () => _setCurrentPathWithMode(
                items[i].path,
                preferredMode: items[i].browseMode,
              ),
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
              onPressed: () => _setCurrentPathWithMode(path),
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

  Widget _buildEntryTile(
    BuildContext context, {
    required IconData icon,
    required Color backgroundColor,
    required Color foregroundColor,
    required String title,
    required String subtitle,
    required bool tappable,
    Widget? titleTrailing,
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
                      LayoutBuilder(
                        builder: (context, constraints) {
                          return Wrap(
                            spacing: 8,
                            runSpacing: 2,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxWidth: titleTrailing == null
                                      ? constraints.maxWidth
                                      : constraints.maxWidth * 0.52,
                                ),
                                child: Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              if (titleTrailing != null)
                                DefaultTextStyle.merge(
                                  style: theme.textTheme.bodySmall?.copyWith(
                                        color:
                                            theme.colorScheme.onSurfaceVariant,
                                      ) ??
                                      const TextStyle(),
                                  child: titleTrailing,
                                ),
                            ],
                          );
                        },
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
                  tappable
                      ? Icons.chevron_right
                      : Icons.insert_drive_file_outlined,
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

  String? _currentPathCountsText() {
    if (_loading || _errorText != null) {
      return null;
    }
    final directoryCount = _children.where((entry) => entry.isDirectory).length;
    final fileCount = _children.length - directoryCount;
    return '$directoryCount 个文件夹 · $fileCount 个文件';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final parentPath = _parentDirectoryPath(_currentPath);
    final countsText = _currentPathCountsText();
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
          if (_browseMode == _AndroidDirectoryBrowseMode.shizuku &&
              _isAndroidDataRootPath(_currentPath) &&
              !_shizukuFuseHintDismissed)
            _buildShizukuFuseLimitHint(context),
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
                DirectoryBrowserActionRow(
                  showPresetRoots: _showPresetRoots,
                  actionsEnabled: !_loading,
                  onTogglePresetRoots: () {
                    setState(() {
                      _showPresetRoots = !_showPresetRoots;
                    });
                  },
                  onCreateFolder: _showCreateFolderDialog,
                  onSelectCurrentFolder: () =>
                      Navigator.of(context).pop(_currentPath),
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
              titleTrailing: countsText == null
                  ? null
                  : Text(
                      countsText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
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

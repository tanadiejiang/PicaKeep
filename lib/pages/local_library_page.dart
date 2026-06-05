import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/components/comic_tile.dart';
import 'package:picakeep/components/components.dart';
import 'package:picakeep/components/layout.dart';
import 'package:picakeep/components/scrollable.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/app_runtime_mode.dart';
import 'package:picakeep/foundation/archive/archive_password_store.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/local_library_settings.dart';
import 'package:picakeep/foundation/remote_library_event_channel.dart';
import 'package:picakeep/foundation/remote_library_data_source.dart';
import 'package:picakeep/foundation/service_data_source.dart';
import 'package:picakeep/foundation/trash.dart';
import 'package:picakeep/foundation/ui_mode.dart';
import 'package:picakeep/pages/settings/settings_page.dart';
import 'package:picakeep/tools/read_history_helper.dart';
import 'package:picakeep/tools/translations.dart';

import 'download_page.dart' show DownloadedComicInfoView, DownloadPageLogic;
import 'package:picakeep/components/archive_password_dialog.dart';
import 'package:picakeep/components/side_bar.dart' show showSideBar;
import 'local_comic_detail_page.dart';

String _formatLocalLibrarySize(double sizeMb) {
  if (sizeMb >= 1024) {
    return '${(sizeMb / 1024).toStringAsFixed(1)} GB';
  }
  return '${sizeMb.toStringAsFixed(1)} MB';
}

String _localLibrarySourceLabel(LocalLibrarySource source) {
  switch (source.kind) {
    case LocalLibrarySourceKind.currentDownload:
      return '本应用下载目录'.tl;
    case LocalLibrarySourceKind.originalDownload:
      return '原应用下载目录'.tl;
    case LocalLibrarySourceKind.customPath:
      return '自定义路径'.tl;
  }
}

IconData _localLibrarySourceIcon(LocalLibrarySource source) {
  switch (source.kind) {
    case LocalLibrarySourceKind.currentDownload:
      return Icons.download_for_offline;
    case LocalLibrarySourceKind.originalDownload:
      return Icons.drive_folder_upload;
    case LocalLibrarySourceKind.customPath:
      return Icons.photo_library;
  }
}

Future<void> _openDirectoryPath(BuildContext context, String path) async {
  if (path.trim().isEmpty) {
    return;
  }
  if (Platform.isWindows) {
    await Process.run('explorer', [path]);
  } else if (Platform.isMacOS) {
    await Process.run('open', [path]);
  } else if (Platform.isLinux) {
    await Process.run('xdg-open', [path]);
  } else if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('当前平台不支持直接打开目录'.tl)),
    );
  }
}

Future<void> _copyPath(BuildContext context, String path) async {
  await Clipboard.setData(ClipboardData(text: path));
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已复制路径'.tl)),
    );
  }
}

Future<void> _refreshLocalLibrary({bool rescan = false}) async {
  final localLibraryManager = LocalLibraryManager();
  if (rescan) {
    if (await localLibraryManager
        .shouldBypassDirectDownloadManagerForCurrentDownloads()) {
      await localLibraryManager.refresh();
    } else if (await localLibraryManager
        .shouldUsePrivilegedManagedDownloadHandling()) {
      await localLibraryManager.refresh();
    } else {
      await localLibraryManager.rescan();
    }
  } else {
    await localLibraryManager.refresh();
  }
  App.notifyLocalDataChanged();
}

class _LocalLibraryComicTile extends DownloadedComicTile {
  const _LocalLibraryComicTile({
    required this.comicId,
    required this.enableLongPress,
    required super.name,
    required super.author,
    required super.imagePath,
    super.imageProvider,
    required super.type,
    required super.tag,
    required super.size,
    required super.onTap,
    required super.onLongTap,
    required super.onSecondaryTap,
    super.optimizeCoverDecode,
  });

  final String comicId;
  final bool enableLongPress;

  @override
  String? get comicID => comicId;

  @override
  bool get enableLongPressed => enableLongPress;
}

class _RemoteRootCollage extends StatelessWidget {
  const _RemoteRootCollage({required this.item});

  final RemoteLibraryRootItem item;

  @override
  Widget build(BuildContext context) {
    final visibleUrls = item.previewCoverUrls
        .map((entry) => entry.trim())
        .where((entry) => entry.isNotEmpty)
        .take(6)
        .toList(growable: false);
    if (visibleUrls.isEmpty) {
      return const Center(child: Icon(Icons.image_not_supported));
    }
    return GridView.builder(
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 1.5,
        crossAxisSpacing: 1.5,
        childAspectRatio: 1.12,
      ),
      itemCount: visibleUrls.length,
      itemBuilder: (context, index) {
        final provider =
            item.client.coverImageProviderForUrl(visibleUrls[index]);
        return provider == null
            ? Container(
                color: Theme.of(context).colorScheme.secondaryContainer,
                child: const Icon(Icons.broken_image_outlined, size: 18),
              )
            : Image(
                image: provider,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) => Container(
                  color: Theme.of(context).colorScheme.secondaryContainer,
                  child: const Icon(Icons.broken_image_outlined, size: 18),
                ),
              );
      },
    );
  }
}

class _LocalLibraryRemoteRootCard extends StatelessWidget {
  const _LocalLibraryRemoteRootCard({
    required this.item,
    required this.sizeText,
    required this.onTap,
    required this.onLongPress,
    required this.onSecondaryTap,
  });

  final RemoteLibraryRootItem item;
  final String sizeText;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final void Function(TapDownDetails details) onSecondaryTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        elevation: 1,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          onSecondaryTapDown: onSecondaryTap,
          borderRadius: BorderRadius.circular(8),
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 92,
                    height: 124,
                    child: Container(
                      color: Theme.of(context).colorScheme.secondaryContainer,
                      child: _RemoteRootCollage(item: item),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        item.subTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        sizeText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).colorScheme.outline,
                            ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Theme.of(context)
                                  .colorScheme
                                  .secondaryContainer,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              item.sourceDisplayName,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LocalLibraryRootItem extends DownloadedItem {
  _LocalLibraryRootItem({required this.entry}) {
    comicSize = entry.sizeMb;
  }

  final LocalLibraryStorageEntry entry;

  LocalLibrarySource get source => entry.source;

  @override
  DownloadType get type => DownloadType.other;

  @override
  String get name => entry.title;

  @override
  List<String> get eps => const [];

  @override
  List<int> get downloadedEps => const [];

  @override
  String get id => 'local_root::${entry.path}';

  @override
  String get subTitle => '${entry.comicCount} 个项目';

  @override
  double? comicSize;

  @override
  List<String> get tags => const [];

  @override
  String get sourceDisplayName => _localLibrarySourceLabel(source);

  @override
  bool get canDelete => false;

  @override
  String? get fileSystemPath => entry.path;

  @override
  String? get localCoverPath => null;

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': name,
        'path': entry.path,
        'itemCount': entry.comicCount,
        'sizeMb': entry.sizeMb,
        'collectionShellEnabled': source.collectionShellEnabled,
      };

  @override
  Widget createReadingPage({int? ep, int? page}) {
    throw StateError('本地目录不支持直接阅读');
  }
}

class _LocalLibraryLocalRootCard extends StatelessWidget {
  const _LocalLibraryLocalRootCard({
    required this.item,
    required this.sizeText,
    required this.onTap,
    required this.onLongPress,
    required this.onSecondaryTap,
  });

  final _LocalLibraryRootItem item;
  final String sizeText;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final void Function(TapDownDetails details) onSecondaryTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      child: Material(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        elevation: 1,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          onSecondaryTapDown: onSecondaryTap,
          borderRadius: BorderRadius.circular(8),
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 92,
                    height: 124,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: colorScheme.secondaryContainer,
                      ),
                      child: Icon(
                        Icons.photo_library_outlined,
                        size: 42,
                        color: colorScheme.onSecondaryContainer,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        item.subTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        sizeText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: colorScheme.outline,
                            ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: colorScheme.secondaryContainer,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              item.sourceDisplayName,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                          if (item.source.collectionShellEnabled)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: colorScheme.primaryContainer,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                '合集'.tl,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class LocalLibraryPage extends StatefulWidget {
  const LocalLibraryPage({
    super.key,
    this.albumOnly = false,
    this.preferRemoteView = false,
    this.title,
    this.localRootPath,
    this.remoteRootId,
  });

  final bool albumOnly;
  final bool preferRemoteView;
  final String? title;
  final String? localRootPath;
  final String? remoteRootId;

  @override
  State<LocalLibraryPage> createState() => _LocalLibraryPageState();
}

enum _LocalLibraryView {
  local,
  aggregate,
  remote,
}

String _localLibraryViewLabel(_LocalLibraryView view,
    {required bool albumOnly}) {
  switch (view) {
    case _LocalLibraryView.local:
      return albumOnly ? '本地图集' : '本地资源';
    case _LocalLibraryView.aggregate:
      return '聚合';
    case _LocalLibraryView.remote:
      return albumOnly ? '远程 · 图集' : '远程 · 资源库';
  }
}

_LocalLibraryView _localLibraryViewFromSetting(String value) {
  switch (normalizeLocalLibraryView(value)) {
    case 'aggregate':
      return _LocalLibraryView.aggregate;
    case 'remote':
      return _LocalLibraryView.remote;
    case 'local':
    default:
      return _LocalLibraryView.local;
  }
}

String _localLibraryViewToSetting(_LocalLibraryView view) {
  switch (view) {
    case _LocalLibraryView.aggregate:
      return 'aggregate';
    case _LocalLibraryView.remote:
      return 'remote';
    case _LocalLibraryView.local:
      return 'local';
  }
}

class _LocalLibraryPageState extends State<LocalLibraryPage> {
  final _manager = LocalLibraryManager();
  final _remoteDataSource = const RemoteLibraryDataSource();
  final _searchController = TextEditingController();
  final Set<String> _selectedItemIds = <String>{};
  bool _loading = true;
  bool _searchMode = false;
  bool _remoteAvailable = false;
  bool _selecting = false;
  String? _errorText;
  bool _isDeleteOperationRunning = false;
  int _deleteProgressCurrent = 0;
  int _deleteProgressTotal = 0;
  String _deleteProgressActionLabel = '';
  bool _forceRemoteRefreshOnNextLoad = false;
  bool _localDataRefreshRunning = false;
  bool _localDataRefreshRequested = false;
  DateTime? _lastManualRemoteRefreshAt;
  List<DownloadedItem> _items = const <DownloadedItem>[];
  LocalLibrarySource? _localRootSource;
  RemoteLibraryRootSummary? _remoteRootSummary;
  late _LocalLibraryView _view = widget.preferRemoteView || _isRemoteRootPage
      ? _LocalLibraryView.remote
      : _isLocalRootPage
          ? _LocalLibraryView.local
          : _localLibraryViewFromSetting(
              appdata.settings[localLibraryViewSettingIndex],
            );

  bool get _isClientMode =>
      normalizeAppRuntimeMode(appdata.settings[appRuntimeModeSettingIndex]) ==
      appRuntimeModeClient;

  bool get _isAlbumOnly =>
      widget.albumOnly ||
      appdata.settings[localLibraryAlbumOnlySettingIndex] != '0';

  bool get _isRemoteRootPage => widget.remoteRootId?.trim().isNotEmpty == true;

  bool get _isLocalRootPage => widget.localRootPath?.trim().isNotEmpty == true;

  bool get _shouldStrictlyUseRemoteData => _isRemoteRootPage;

  bool get _canToggleCollectionShell {
    if (!_isAlbumOnly || _searchMode || _selecting) {
      return false;
    }
    if (_isLocalRootPage) {
      return _localRootSource?.supportsCollectionShell == true;
    }
    if (_isRemoteRootPage) {
      return _remoteRootSummary?.supportsCollectionShell == true;
    }
    return false;
  }

  bool get _collectionShellEnabled {
    if (_isLocalRootPage) {
      return _localRootSource?.collectionShellEnabled == true;
    }
    if (_isRemoteRootPage) {
      return _remoteRootSummary?.collectionShellEnabled == true;
    }
    return false;
  }

  bool get _showSourceSelector =>
      _remoteAvailable && !_isRemoteRootPage && !_isLocalRootPage;

  int get _selectedCount => _selectedItemIds.length;

  List<DownloadedItem> get _selectedDeleteItems => _items
      .where(
          (item) => _selectedItemIds.contains(item.id) && _canSelectItem(item))
      .toList(growable: false);

  bool _canSelectItem(DownloadedItem item) {
    if (item is RemoteLibraryRootItem) {
      return false;
    }
    if (item is RemoteLibraryComicItem) {
      return true;
    }
    if (item is LocalLibraryComicItem) {
      return item.fileSystemPath?.trim().isNotEmpty == true;
    }
    return item.canDelete;
  }

  bool get _isOperationRunning => _isDeleteOperationRunning;

  String get _deleteProgressHint => '请不要退出，强制退出可能导致操作异常';

  bool _isItemSelected(DownloadedItem item) {
    return _selectedItemIds.contains(item.id);
  }

  void _clearSelectionState() {
    _selectedItemIds.clear();
    _selecting = false;
  }

  void _exitSelectionMode() {
    if (!_selecting && _selectedItemIds.isEmpty) {
      return;
    }
    setState(_clearSelectionState);
  }

  void _toggleItemSelection(DownloadedItem item) {
    if (!_canSelectItem(item)) {
      return;
    }
    setState(() {
      _selecting = true;
      if (!_selectedItemIds.add(item.id)) {
        _selectedItemIds.remove(item.id);
      }
      if (_selectedItemIds.isEmpty) {
        _selecting = false;
      }
    });
  }

  String _operationErrorText(Object error) {
    final message = error is StateError
        ? error.message.toString()
        : error.toString().replaceFirst('Exception: ', '');
    if (message.contains(deleteFailurePermissionDenied) ||
        message.toLowerCase().contains('permission denied')) {
      return deleteFailureMessage(deleteFailurePermissionDenied).tl;
    }
    if (message.contains(deleteFailureLocalPathNotFound)) {
      return deleteFailureMessage(deleteFailureLocalPathNotFound).tl;
    }
    return message.replaceFirst('Bad state: ', '');
  }

  Future<String?> _runDeleteOperation(
    List<DownloadedItem> items,
  ) async {
    if (_isDeleteOperationRunning || items.isEmpty) {
      return null;
    }
    final optimisticRemovedIds = items.map((item) => item.id).toSet();
    setState(() {
      _isDeleteOperationRunning = true;
      _deleteProgressCurrent = 0;
      _deleteProgressTotal = items.length;
      _deleteProgressActionLabel =
          TrashManager.instance.useTrashByDefault ? '正在放进回收站' : '正在删除';
      _items = _items
          .where((item) => !optimisticRemovedIds.contains(item.id))
          .toList(growable: false);
      _selectedItemIds.removeAll(optimisticRemovedIds);
      if (_selectedItemIds.isEmpty) {
        _selecting = false;
      }
    });
    App.beginNavigationLock();
    App.temporaryDisablePopGesture = true;
    String? errorText;
    try {
      final remoteTargets = items.whereType<RemoteLibraryComicItem>().toList();
      final canUseRemoteBatch =
          remoteTargets.length == items.length && remoteTargets.length > 1;
      if (canUseRemoteBatch) {
        if (mounted) {
          setState(() {
            _deleteProgressCurrent = items.length;
          });
        } else {
          _deleteProgressCurrent = items.length;
        }
        await TrashManager.instance.deleteRemoteItems(remoteTargets);
      } else {
        for (int i = 0; i < items.length; i++) {
          if (mounted) {
            setState(() {
              _deleteProgressCurrent = i + 1;
            });
          } else {
            _deleteProgressCurrent = i + 1;
          }
          final result = await TrashManager.instance.deleteItem(items[i]);
          if (!result.ok) {
            errorText = deleteFailureMessage(result.error).tl;
            break;
          }
        }
      }
    } catch (e) {
      errorText = _operationErrorText(e);
    } finally {
      try {
        await _load(forceLocalRefresh: true);
      } catch (e) {
        errorText ??= _operationErrorText(e);
      }
      App.temporaryDisablePopGesture = false;
      App.endNavigationLock();
      if (mounted) {
        setState(() {
          _isDeleteOperationRunning = false;
          _deleteProgressCurrent = 0;
          _deleteProgressTotal = 0;
          _deleteProgressActionLabel = '';
        });
        if (_localDataRefreshRequested) {
          unawaited(_reloadAfterLocalDataChanged());
        }
      } else {
        _isDeleteOperationRunning = false;
        _deleteProgressCurrent = 0;
        _deleteProgressTotal = 0;
        _deleteProgressActionLabel = '';
      }
    }
    return errorText;
  }

  Future<void> _setView(_LocalLibraryView nextView) async {
    if (_view == nextView) {
      return;
    }
    setState(() {
      _view = nextView;
      _clearSelectionState();
    });
    appdata.settings[localLibraryViewSettingIndex] =
        _localLibraryViewToSetting(nextView);
    await appdata.updateSettings();
    await _load();
  }

  @override
  void initState() {
    super.initState();
    App.localDataVersion.addListener(_handleLocalDataChanged);
    App.serviceConfigVersion.addListener(_handleServiceConfigChanged);
    App.serviceRuntimeVersion.addListener(_handleServiceRuntimeChanged);
    _searchController.addListener(() {
      if (mounted) {
        setState(() {});
      }
    });
    _load();
  }

  @override
  void dispose() {
    App.localDataVersion.removeListener(_handleLocalDataChanged);
    App.serviceConfigVersion.removeListener(_handleServiceConfigChanged);
    App.serviceRuntimeVersion.removeListener(_handleServiceRuntimeChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _handleLocalDataChanged() {
    unawaited(_reloadAfterLocalDataChanged());
  }

  Future<void> _reloadAfterLocalDataChanged() async {
    if (_isDeleteOperationRunning) {
      _localDataRefreshRequested = true;
      return;
    }
    if (_localDataRefreshRunning) {
      _localDataRefreshRequested = true;
      return;
    }
    _localDataRefreshRunning = true;
    try {
      do {
        _localDataRefreshRequested = false;
        await _load(forceLocalRefresh: true);
      } while (_localDataRefreshRequested && mounted);
    } finally {
      _localDataRefreshRunning = false;
      _localDataRefreshRequested = false;
    }
  }

  void _handleServiceConfigChanged() {
    _load();
  }

  void _handleServiceRuntimeChanged() {
    _load();
  }

  Future<void> _refreshCurrentLibrary({bool rescan = false}) async {
    await _refreshLocalLibrary(rescan: rescan);
    await _load();
  }

  void _triggerManualRemoteRefresh() {
    final now = DateTime.now();
    final lastTriggeredAt = _lastManualRemoteRefreshAt;
    if (lastTriggeredAt != null &&
        now.difference(lastTriggeredAt) < const Duration(milliseconds: 1500)) {
      return;
    }
    _lastManualRemoteRefreshAt = now;
    _forceRemoteRefreshOnNextLoad = true;
    unawaited(_load());
  }

  Future<void> _setCollectionShellEnabled(bool enabled) async {
    if (!_canToggleCollectionShell) {
      return;
    }
    if (mounted) {
      setState(() {
        _loading = true;
        _errorText = null;
      });
    }
    try {
      if (_isLocalRootPage) {
        final path = widget.localRootPath?.trim() ?? '';
        if (path.isEmpty) {
          return;
        }
        await _manager.setCollectionShellEnabledForLocalComicPath(path, enabled);
        await _load(forceLocalRefresh: true);
        App.notifyLocalDataChanged();
        return;
      }
      if (_isRemoteRootPage) {
        final rootId = widget.remoteRootId?.trim() ?? '';
        if (rootId.isEmpty) {
          return;
        }
        await _remoteDataSource.setCollectionShellEnabledForRoot(rootId, enabled);
        _forceRemoteRefreshOnNextLoad = true;
        await _load();
      }
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorText = e.toString().trim();
        _loading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_errorText ?? '切换失败'.tl)),
      );
    }
  }

  Future<bool> _checkRemoteAvailability() async {
    if (!_isClientMode) {
      return false;
    }
    try {
      final snapshot =
          await RuntimeServiceDataSourceResolver.current().fetchSnapshot();
      return snapshot.connectionState == ServiceConnectionState.online;
    } catch (_) {
      return false;
    }
  }

  Future<List<DownloadedItem>> _loadLocalItems({
    bool forceRefresh = false,
  }) async {
    if (forceRefresh) {
      await _manager.refresh();
    }
    _localRootSource = null;
    _remoteRootSummary = null;
    final rootPath = widget.localRootPath?.trim() ?? '';
    final allItems = await _manager.getAll();
    if (rootPath.isNotEmpty) {
      final entries = await _manager.getStorageEntries();
      final entry = _findLocalStorageEntry(entries, rootPath);
      if (entry == null) {
        return const <DownloadedItem>[];
      }
      _localRootSource = entry.source;
      final childIds = entry.children.map((child) => child.id).toSet();
      final childItems = allItems
          .where((item) => childIds.contains(item.id))
          .cast<DownloadedItem>()
          .toList(growable: false);
      return _sortItems(childItems);
    }

    if (_isAlbumOnly) {
      final entries = await _manager.getStorageEntries();
      final rootItems = entries
          .where((entry) => entry.source.supportsCollectionShell)
          .map((entry) => _LocalLibraryRootItem(entry: entry))
          .cast<DownloadedItem>()
          .toList(growable: false);
      return _sortItems(rootItems);
    }

    return _sortItems(allItems.cast<DownloadedItem>().toList(growable: false));
  }

  LocalLibraryStorageEntry? _findLocalStorageEntry(
    List<LocalLibraryStorageEntry> entries,
    String rootPath,
  ) {
    final key = normalizeLocalCollectionShellPathKey(rootPath);
    if (key.isEmpty) {
      return null;
    }
    for (final entry in entries) {
      if (normalizeLocalCollectionShellPathKey(entry.path) == key) {
        return entry;
      }
    }
    return null;
  }

  Future<List<DownloadedItem>> _loadRemoteItems() async {
    RemoteLibraryEventChannel.instance.onRemotePageActivated();
    final rootId = widget.remoteRootId?.trim() ?? '';
    final forceRemoteRefresh = _forceRemoteRefreshOnNextLoad;
    _forceRemoteRefreshOnNextLoad = false;
    if (rootId.isNotEmpty) {
      final summary = await _remoteDataSource.fetchRootSummary(
        rootId,
        forceRefresh: forceRemoteRefresh,
      );
      _remoteRootSummary = summary;
      final items = await _remoteDataSource.fetchItemsForRoot(rootId);
      return _sortItems(items.toList());
    }
    _remoteRootSummary = null;
    final roots = await _remoteDataSource.fetchRootItems(
      customLibraryOnly: true,
      forceRefresh: forceRemoteRefresh,
    );
    return _sortItems(roots.cast<DownloadedItem>().toList());
  }

  Future<void> _load({bool forceLocalRefresh = false}) async {
    if (mounted) {
      setState(() {
        _loading = true;
        _errorText = null;
      });
    }
    try {
      final remoteAvailable = await _checkRemoteAvailability();
      if (!remoteAvailable &&
          _view != _LocalLibraryView.local &&
          !_shouldStrictlyUseRemoteData) {
        _view = _LocalLibraryView.local;
        appdata.settings[localLibraryViewSettingIndex] = 'local';
        await appdata.updateSettings();
      }
      final localItems = await _loadLocalItems(
        forceRefresh: forceLocalRefresh,
      );
      List<DownloadedItem> items;
      switch (_view) {
        case _LocalLibraryView.local:
          items = localItems;
          break;
        case _LocalLibraryView.aggregate:
          if (!remoteAvailable) {
            items = localItems;
            break;
          }
          try {
            final remoteItems = await _loadRemoteItems();
            items = _sortItems([...localItems, ...remoteItems]);
          } catch (_) {
            items = localItems;
          }
          break;
        case _LocalLibraryView.remote:
          items = remoteAvailable
              ? await _loadRemoteItems()
              : throw const RemoteLibraryDataSourceException('远程服务当前不可用');
          break;
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _items = items;
        _remoteAvailable = remoteAvailable;
        _clearSelectionState();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _items = const <DownloadedItem>[];
        _remoteAvailable = false;
        _clearSelectionState();
        _errorText = e.toString().trim();
        _loading = false;
      });
    }
  }

  List<DownloadedItem> get _filteredItems {
    final keyword = _searchController.text.trim().toLowerCase();
    if (keyword.isEmpty) {
      return List<DownloadedItem>.from(_items, growable: false);
    }
    return _items.where((item) {
      return item.name.toLowerCase().contains(keyword) ||
          item.subTitle.toLowerCase().contains(keyword) ||
          item.sourceDisplayName.toLowerCase().contains(keyword) ||
          item.tags.any((tag) => tag.toLowerCase().contains(keyword)) ||
          (item.fileSystemPath?.toLowerCase().contains(keyword) ?? false);
    }).toList(growable: false);
  }

  List<DownloadedItem> _sortItems(List<DownloadedItem> items) {
    final sorted = List<DownloadedItem>.from(items);
    switch (normalizeLocalLibraryListSort(
      appdata.settings[localLibraryListSortSettingIndex],
    )) {
      case 'time_asc':
        sorted.sort(
          (a, b) => (a.time ?? DateTime.fromMillisecondsSinceEpoch(0))
              .compareTo(b.time ?? DateTime.fromMillisecondsSinceEpoch(0)),
        );
        break;
      case 'name_asc':
        sorted.sort((a, b) => a.name.compareTo(b.name));
        break;
      case 'name_desc':
        sorted.sort((a, b) => b.name.compareTo(a.name));
        break;
      case 'size_asc':
        sorted.sort((a, b) => (a.comicSize ?? 0).compareTo(b.comicSize ?? 0));
        break;
      case 'size_desc':
        sorted.sort((a, b) => (b.comicSize ?? 0).compareTo(a.comicSize ?? 0));
        break;
      case 'time_desc':
      default:
        sorted.sort(
          (a, b) => (b.time ?? DateTime.fromMillisecondsSinceEpoch(0))
              .compareTo(a.time ?? DateTime.fromMillisecondsSinceEpoch(0)),
        );
        break;
    }
    return sorted;
  }

  File _coverFile(DownloadedItem item) {
    if (item is LocalLibraryComicItem) {
      return resolveLocalComicCover(item);
    }
    final path = item.localCoverPath?.trim();
    if (path != null && path.isNotEmpty) {
      return File(path);
    }
    return File('');
  }

  ImageProvider<Object>? _coverImageProvider(DownloadedItem item) {
    if (item is RemoteLibraryComicItem) {
      return item.coverImageProvider;
    }
    return null;
  }

  Future<void> _showSortDialog() async {
    final selected = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        final current = normalizeLocalLibraryListSort(
          appdata.settings[localLibraryListSortSettingIndex],
        );
        return SimpleDialog(
          title: Text('排序'.tl),
          children: [
            for (final entry in const <MapEntry<String, String>>[
              MapEntry('time_desc', '最近更新优先'),
              MapEntry('time_asc', '最早更新优先'),
              MapEntry('name_asc', '名称 A-Z'),
              MapEntry('name_desc', '名称 Z-A'),
              MapEntry('size_desc', '体积从大到小'),
              MapEntry('size_asc', '体积从小到大'),
            ])
              ListTile(
                leading: Icon(
                  entry.key == current
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                ),
                title: Text(entry.value.tl),
                onTap: () {
                  Navigator.of(dialogContext).pop(entry.key);
                },
              ),
          ],
        );
      },
    );
    if (selected == null) {
      return;
    }
    appdata.settings[localLibraryListSortSettingIndex] = selected;
    await appdata.updateSettings();
    await _load();
  }

  Future<void> _showFilterDialog() async {
    var albumOnly = appdata.settings[localLibraryAlbumOnlySettingIndex] != '0';
    await showDialog<void>(
      context: context,
      barrierColor: Colors.transparent,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return Dialog(
              insetPadding: const EdgeInsets.only(top: 72, right: 12, left: 80),
              alignment: Alignment.topRight,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 280),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: SwitchListTile(
                    value: albumOnly,
                    title: Text('仅显示图集'.tl),
                    subtitle: Text('隐藏下载目录来源，只看普通本地图集'.tl),
                    secondary: const Icon(Icons.photo_library_outlined),
                    onChanged: (value) async {
                      setDialogState(() {
                        albumOnly = value;
                      });
                      appdata.settings[localLibraryAlbumOnlySettingIndex] =
                          value ? '1' : '0';
                      await appdata.updateSettings();
                      await _load();
                    },
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _openItem(DownloadedItem item) {
    if (item is RemoteLibraryRootItem) {
      App.pushInner(
        () => LocalLibraryPage(
          albumOnly: true,
          preferRemoteView: true,
          title: item.name,
          remoteRootId: item.root.id,
        ),
      );
      return;
    }
    if (item is _LocalLibraryRootItem) {
      App.pushInner(
        () => LocalLibraryPage(
          albumOnly: true,
          title: item.name,
          localRootPath: item.entry.path,
        ),
      );
      return;
    }
    App.pushInner(() => LocalComicDetailPage(comic: item));
  }

  void _showItemInfo(DownloadedItem item) {
    if (item is RemoteLibraryRootItem) {
      _openItem(item);
      return;
    }
    if (item is _LocalLibraryRootItem) {
      _openItem(item);
      return;
    }
    final logic = DownloadPageLogic(
      pageTitle: _isAlbumOnly ? '图集'.tl : '资源库'.tl,
    )
      ..loading = false
      ..baseComics = [item]
      ..comics = [item]
      ..selected = [false];
    if (UiMode.m1(context)) {
      final screenHeight = MediaQuery.of(context).size.height;
      final maxSize = screenHeight > 0
          ? math.min(0.8, math.max(0.5, (screenHeight - 92) / screenHeight))
          : 0.8;
      const minSize = 0.3;
      final sheetController = DraggableScrollableController();
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        showDragHandle: false,
        useSafeArea: false,
        backgroundColor: Colors.transparent,
        builder: (context) {
          return DraggableScrollableSheet(
            controller: sheetController,
            initialChildSize: 0.6,
            minChildSize: minSize,
            maxChildSize: maxSize,
            expand: false,
            builder: (context, scrollController) {
              return Material(
                color: Theme.of(context).colorScheme.surface,
                surfaceTintColor: Theme.of(context).colorScheme.surfaceTint,
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.vertical(
                    top: Radius.circular(16),
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: DownloadedComicInfoView(
                  item,
                  logic,
                  scrollController: scrollController,
                  sheetController: sheetController,
                  sheetMaxSize: maxSize,
                  sheetMinSize: minSize,
                ),
              );
            },
          );
        },
      ).whenComplete(sheetController.dispose);
    } else {
      showSideBar(
        App.globalContext ?? context,
        DownloadedComicInfoView(item, logic),
        useSurfaceTintColor: true,
      );
    }
  }

  Future<void> _showActions(DownloadedItem item) async {
    final path = item.fileSystemPath?.trim() ?? '';
    final isRootItem = item is RemoteLibraryRootItem || item is _LocalLibraryRootItem;
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: Text(isRootItem ? '打开列表'.tl : '查看详情'.tl),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _openItem(item);
                },
              ),
              if (!isRootItem)
                ListTile(
                  leading: const Icon(Icons.menu_book),
                  title: Text('继续阅读'.tl),
                  onTap: () async {
                    Navigator.of(sheetContext).pop();
                    await ensureHistoryBeforeRead(item);
                    await App.openReader(() => item.createReadingPage());
                  },
                ),
              if (path.isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.folder_open),
                  title: Text('打开目录'.tl),
                  onTap: () async {
                    Navigator.of(sheetContext).pop();
                    await _openDirectoryPath(context, path);
                  },
                ),
              if (path.isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.copy),
                  title: Text('复制路径'.tl),
                  onTap: () async {
                    Navigator.of(sheetContext).pop();
                    await _copyPath(context, path);
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  void _showDesktopMenu(DownloadedItem item, TapDownDetails details) {
    final path = item.fileSystemPath?.trim() ?? '';
    final isRootItem = item is RemoteLibraryRootItem || item is _LocalLibraryRootItem;
    showMenu(
      context: context,
      position: RelativeRect.fromLTRB(
        details.globalPosition.dx,
        details.globalPosition.dy,
        details.globalPosition.dx + 1,
        details.globalPosition.dy + 1,
      ),
      items: [
        PopupMenuItem<void>(
          child: Text(isRootItem ? '打开列表'.tl : '查看详情'.tl),
          onTap: () {
            Future.delayed(const Duration(milliseconds: 120), () {
              if (mounted) {
                _openItem(item);
              }
            });
          },
        ),
        if (!isRootItem)
          PopupMenuItem<void>(
            child: Text('继续阅读'.tl),
            onTap: () {
              Future.delayed(const Duration(milliseconds: 120), () async {
                await ensureHistoryBeforeRead(item);
                await App.openReader(() => item.createReadingPage());
              });
            },
          ),
        if (path.isNotEmpty)
          PopupMenuItem<void>(
            child: Text('打开目录'.tl),
            onTap: () {
              Future.delayed(const Duration(milliseconds: 120), () async {
                if (mounted) {
                  await _openDirectoryPath(context, path);
                }
              });
            },
          ),
        if (path.isNotEmpty)
          PopupMenuItem<void>(
            child: Text('复制路径'.tl),
            onTap: () {
              Future.delayed(const Duration(milliseconds: 120), () async {
                if (mounted) {
                  await _copyPath(context, path);
                }
              });
            },
          ),
      ],
    );
  }

  void _handleItemTap(DownloadedItem item) {
    if (_selecting && _canSelectItem(item)) {
      _toggleItemSelection(item);
      return;
    }
    if (item is LocalLibraryComicItem && item.needsArchivePassword) {
      _handleArchivePasswordTap(item);
      return;
    }
    if (item is RemoteLibraryComicItem && item.needsArchivePassword) {
      _handleRemoteArchivePasswordTap(item);
      return;
    }
    _showItemInfo(item);
  }

  Future<void> _handleArchivePasswordTap(LocalLibraryComicItem item) async {
    final archivePath = item.fileSystemPath ?? '';
    if (archivePath.isEmpty) return;
    final result = await showArchivePasswordDialog(
      context: context,
      archivePath: archivePath,
      archiveFileName: item.name,
      format: item.archiveFormat,
    );
    if (result == null) return;
    item.markArchiveUnlocked(result.password);
    if (result.addToDefaults) {
      await ArchivePasswordStore.instance.addDefaultPassword(result.password);
    }
    await LocalLibraryManager.instance.refreshArchiveCoverFor(item);
    if (mounted) setState(() {});
    _showItemInfo(item);
  }

  Future<void> _handleRemoteArchivePasswordTap(
    RemoteLibraryComicItem item,
  ) async {
    final result = await showArchivePasswordDialog(
      context: context,
      archivePath: item.remotePath,
      archiveFileName: item.name,
      format: item.archiveFormat,
      allowAddToDefaults: false,
      onVerify: (password) => item.client.unlockArchive(item.id, password),
    );
    if (result == null) return;
    item.archivePasswordMatched = true;
    await _load();
    if (!mounted) return;
    final refreshed = _items.whereType<RemoteLibraryComicItem>().where(
          (candidate) => candidate.id == item.id,
        );
    _showItemInfo(refreshed.isEmpty ? item : refreshed.first);
  }

  void _handleItemLongPress(DownloadedItem item) {
    if (_canSelectItem(item)) {
      _toggleItemSelection(item);
      return;
    }
    _showActions(item);
  }

  void _handleItemSecondaryTap(DownloadedItem item, TapDownDetails details) {
    if (_selecting && _canSelectItem(item)) {
      _toggleItemSelection(item);
      return;
    }
    _showDesktopMenu(item, details);
  }

  Future<void> _deleteSelectedItems() async {
    if (_selectedCount == 0) {
      return;
    }
    final texts = buildDeleteActionTexts(
      count: _selectedCount,
      itemLabel: _isAlbumOnly ? '图集' : '项目',
    );
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(texts.title.tl),
          content: Text(texts.content.tl),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text('取消'.tl),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(texts.confirmLabel.tl),
            ),
          ],
        );
      },
    );
    if (confirmed != true) {
      return;
    }

    final error = await _runDeleteOperation(_selectedDeleteItems);
    if (error != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error)),
      );
    }
  }

  Widget _buildSelectionFrame({
    required DownloadedItem item,
    required Widget child,
  }) {
    if (!_canSelectItem(item)) {
      return child;
    }
    final colorScheme = Theme.of(context).colorScheme;
    final selected = _isItemSelected(item);
    return Padding(
      padding: const EdgeInsets.all(2),
      child: ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(16)),
        child: Stack(
          children: [
            Positioned.fill(child: child),
            if (selected)
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colorScheme.primary.withValues(alpha: 0.22),
                      border: Border.all(
                        color: colorScheme.primary,
                        width: 1.6,
                      ),
                      borderRadius: const BorderRadius.all(Radius.circular(16)),
                    ),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            colorScheme.primary.withValues(alpha: 0.14),
                            colorScheme.primary.withValues(alpha: 0.28),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildItem(DownloadedItem item) {
    if (item is RemoteLibraryRootItem) {
      return Padding(
        padding: const EdgeInsets.all(2),
        child: _LocalLibraryRemoteRootCard(
          item: item,
          sizeText: item.comicSize == null
              ? '未知大小'.tl
              : _formatLocalLibrarySize(item.comicSize!),
          onTap: () => _handleItemTap(item),
          onLongPress: () => _handleItemLongPress(item),
          onSecondaryTap: (details) => _handleItemSecondaryTap(item, details),
        ),
      );
    }
    if (item is _LocalLibraryRootItem) {
      return Padding(
        padding: const EdgeInsets.all(2),
        child: _LocalLibraryLocalRootCard(
          item: item,
          sizeText: item.comicSize == null
              ? '未知大小'.tl
              : _formatLocalLibrarySize(item.comicSize!),
          onTap: () => _handleItemTap(item),
          onLongPress: () => _handleItemLongPress(item),
          onSecondaryTap: (details) => _handleItemSecondaryTap(item, details),
        ),
      );
    }
    final tile = _LocalLibraryComicTile(
      comicId: item.id,
      enableLongPress: true,
      name: item.name,
      author: item.subTitle,
      imagePath: _coverFile(item),
      imageProvider: _coverImageProvider(item),
      optimizeCoverDecode: true,
      type: item.sourceDisplayName,
      tag: item.tags,
      size: item.comicSize == null
          ? '未知大小'.tl
          : _formatLocalLibrarySize(item.comicSize!),
      onTap: () => _handleItemTap(item),
      onLongTap: () => _handleItemLongPress(item),
      onSecondaryTap: (details) => _handleItemSecondaryTap(item, details),
    );
    return _buildSelectionFrame(item: item, child: tile);
  }

  Widget _buildEmptyState() {
    final hasKeyword = _searchController.text.trim().isNotEmpty;
    final viewLabel = _localLibraryViewLabel(_view, albumOnly: _isAlbumOnly).tl;
    final emptyTitle = hasKeyword
        ? '没有匹配的$viewLabel'
        : (_errorText?.trim().isNotEmpty == true
            ? '$viewLabel暂不可用'
            : '暂无$viewLabel');
    final emptyDescription = hasKeyword
        ? '尝试调整搜索关键词'.tl
        : (_errorText?.trim().isNotEmpty == true
            ? _errorText!
            : _view == _LocalLibraryView.remote ||
                    _view == _LocalLibraryView.aggregate
                ? (_isAlbumOnly
                    ? '请确认服务端地址和服务状态后再刷新远程图集'.tl
                    : '请确认服务端地址和服务状态后再刷新远程资源库'.tl)
                : _isAlbumOnly
                    ? '可在工具-本地文件管理中添加图集目录'.tl
                    : '可在工具-本地文件管理中添加本地漫画路径'.tl);
    final isRemoteRefreshView = (_view == _LocalLibraryView.remote ||
            _view == _LocalLibraryView.aggregate) &&
        _remoteAvailable;
    final refreshLabel = isRemoteRefreshView
        ? (_isAlbumOnly ? '刷新远程图集'.tl : '刷新远程资源库'.tl)
        : (_isAlbumOnly ? '刷新图集'.tl : '刷新资源库'.tl);
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.photo_library_outlined,
                size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            Text(
              emptyTitle.tl,
              style: const TextStyle(fontSize: 18, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            Text(
              emptyDescription,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.outline,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: isRemoteRefreshView
                  ? _triggerManualRemoteRefresh
                  : () async {
                      await _refreshCurrentLibrary();
                    },
              icon: const Icon(Icons.refresh),
              label: Text(refreshLabel),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTitle() {
    if (_searchMode) {
      return TextField(
        controller: _searchController,
        autofocus: true,
        decoration: InputDecoration(
          border: InputBorder.none,
          hintText: '搜索'.tl,
        ),
      );
    }
    if (_selecting) {
      return Text('已选择 @num 个项目'.tlParams({'num': _selectedCount.toString()}));
    }
    return Text((widget.title ?? (_isAlbumOnly ? '图集' : '资源库')).tl);
  }

  Widget _buildSourceSelector() {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Align(
          alignment: Alignment.centerLeft,
          child: SegmentedButton<_LocalLibraryView>(
            showSelectedIcon: false,
            segments: [
              for (final view in _LocalLibraryView.values)
                ButtonSegment<_LocalLibraryView>(
                  value: view,
                  label: Text(
                    _localLibraryViewLabel(view, albumOnly: _isAlbumOnly).tl,
                  ),
                ),
            ],
            selected: {_view},
            onSelectionChanged: (selection) {
              if (selection.isEmpty || selection.first == _view) {
                return;
              }
              _setView(selection.first);
            },
          ),
        ),
      ),
    );
  }

  Widget _buildCollectionShellAction() {
    final enabled = _collectionShellEnabled;
    return Tooltip(
      message: enabled ? '关闭合集识别'.tl : '开启合集识别'.tl,
      child: Padding(
        padding: const EdgeInsets.only(left: 2, right: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '合集'.tl,
              style: Theme.of(context).textTheme.labelMedium,
            ),
            Switch.adaptive(
              value: enabled,
              onChanged: _setCollectionShellEnabled,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeleteProgressOverlay() {
    final theme = Theme.of(context);
    final progressText = '$_deleteProgressCurrent/$_deleteProgressTotal';
    final isDesktop = App.isDesktop;
    final barrierColor = Color.alphaBlend(
      theme.colorScheme.primary.withValues(alpha: 0.06),
      Colors.white.withValues(alpha: 0.76),
    );
    final panelColor = Color.alphaBlend(
      theme.colorScheme.primary.withValues(alpha: 0.04),
      theme.colorScheme.surface.withValues(alpha: 0.97),
    );
    return Stack(
      children: [
        ModalBarrier(
          dismissible: false,
          color: barrierColor,
        ),
        Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: isDesktop ? 440 : 300,
              minWidth: isDesktop ? 340 : 260,
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: panelColor,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: theme.colorScheme.shadow.withValues(alpha: 0.08),
                    blurRadius: 24,
                    offset: const Offset(0, 10),
                  ),
                ],
                border: Border.all(
                  color:
                      theme.colorScheme.outlineVariant.withValues(alpha: 0.45),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 22,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 36,
                      height: 36,
                      child: CircularProgressIndicator(
                        strokeWidth: 3.2,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (isDesktop)
                      Text(
                        '$_deleteProgressActionLabel $progressText',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.onSurface,
                        ),
                      )
                    else ...[
                      Text(
                        _deleteProgressActionLabel,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        progressText,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.primary,
                          height: 1.25,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Text(
                      _deleteProgressHint.tl,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget? _buildMultiSelectFab(List<DownloadedItem> items) {
    if (items.where(_canSelectItem).isEmpty) {
      return null;
    }
    return FloatingActionButton(
      enableFeedback: true,
      onPressed: _isOperationRunning
          ? null
          : () {
              if (!_selecting) {
                setState(() {
                  _selecting = true;
                });
                return;
              }
              if (_selectedCount == 0) {
                return;
              }
              _deleteSelectedItems();
            },
      child: _selecting
          ? const Icon(Icons.delete_forever_outlined)
          : const Icon(Icons.checklist_outlined),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = _filteredItems;
    final isRemoteRefreshView = (_view == _LocalLibraryView.remote ||
            _view == _LocalLibraryView.aggregate) &&
        _remoteAvailable;
    final refreshTooltip = isRemoteRefreshView
        ? (_isAlbumOnly ? '刷新远程图集'.tl : '刷新远程资源库'.tl)
        : (_isAlbumOnly ? '刷新图集'.tl : '刷新资源库'.tl);
    Widget page = Scaffold(
      floatingActionButton: _buildMultiSelectFab(items),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SmoothCustomScrollView(
              cacheExtent: MediaQuery.of(context).size.height,
              slivers: [
                SliverAppbar(
                  title: _buildTitle(),
                  color: _selecting
                      ? Theme.of(context).colorScheme.primaryContainer
                      : null,
                  leading: _selecting
                      ? IconButton(
                          onPressed: _exitSelectionMode,
                          icon: const Icon(Icons.close),
                        )
                      : null,
                  actions: _selecting
                      ? [
                          IconButton(
                            icon: const Icon(Icons.delete_outline),
                            tooltip: '删除'.tl,
                            onPressed: _selectedCount == 0
                                ? null
                                : _deleteSelectedItems,
                          ),
                        ]
                      : [
                          IconButton(
                            icon: const Icon(Icons.refresh),
                            tooltip: refreshTooltip,
                            onPressed: isRemoteRefreshView
                                ? _triggerManualRemoteRefresh
                                : () async {
                                    await _refreshCurrentLibrary();
                                  },
                          ),
                          if (_canToggleCollectionShell)
                            _buildCollectionShellAction(),
                          if (!widget.albumOnly)
                            IconButton(
                              icon: Icon(
                                appdata.settings[
                                            localLibraryAlbumOnlySettingIndex] !=
                                        '0'
                                    ? Icons.tune
                                    : Icons.tune_outlined,
                              ),
                              tooltip: '资源库显示设置'.tl,
                              onPressed: _showFilterDialog,
                            ),
                          IconButton(
                            icon: const Icon(Icons.sort),
                            tooltip: '排序'.tl,
                            onPressed: _showSortDialog,
                          ),
                          IconButton(
                            icon:
                                Icon(_searchMode ? Icons.close : Icons.search),
                            tooltip: _searchMode ? '关闭搜索'.tl : '搜索'.tl,
                            onPressed: () {
                              setState(() {
                                _searchMode = !_searchMode;
                                if (!_searchMode) {
                                  _searchController.clear();
                                }
                              });
                            },
                          ),
                        ],
                ),
                if (_showSourceSelector) _buildSourceSelector(),
                if (items.isEmpty)
                  _buildEmptyState()
                else
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(2, 0, 2, 24),
                    sliver: SliverGrid(
                      delegate: SliverChildBuilderDelegate(
                        (context, index) {
                          final item = items[index];
                          return _buildItem(item);
                        },
                        childCount: items.length,
                      ),
                      gridDelegate: SliverGridDelegateWithComics(),
                    ),
                  ),
              ],
            ),
    );
    if (_isOperationRunning) {
      page = Stack(
        fit: StackFit.expand,
        children: [
          page,
          Positioned.fill(
            child: _buildDeleteProgressOverlay(),
          ),
        ],
      );
    }
    return PopScope(
      canPop: !_isOperationRunning,
      child: page,
    );
  }
}

class LocalLibraryFilesPage extends StatefulWidget {
  const LocalLibraryFilesPage({super.key});

  @override
  State<LocalLibraryFilesPage> createState() => _LocalLibraryFilesPageState();
}

class _LocalLibraryFilesPageState extends State<LocalLibraryFilesPage> {
  final _manager = LocalLibraryManager();
  bool _loading = true;
  List<LocalLibrarySource> _sources = const <LocalLibrarySource>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
      });
    }
    final sources = await _manager.getSources();
    if (!mounted) {
      return;
    }
    setState(() {
      _sources = sources;
      _loading = false;
    });
  }

  Future<String?> _pickFolder() async {
    try {
      return await FilePicker.platform.getDirectoryPath();
    } catch (_) {
      return null;
    }
  }

  Future<String?> _browsePath(String initialPath) async {
    if (App.isAndroid) {
      return openInternalDirectoryBrowser(
        context,
        title: '选择本地漫画路径'.tl,
        initialPath: initialPath,
      );
    }
    return _pickFolder();
  }

  Future<void> _addPathAndReload(String path) async {
    final normalized = path.trim();
    if (normalized.isEmpty) {
      return;
    }
    await _manager.addConfiguredLocalComicPath(normalized);
    if (!mounted) {
      return;
    }
    await _load();
    await _refreshLocalLibrary();
    if (!mounted) {
      return;
    }
    await _load();
  }

  Future<void> _showAddPathDialog() async {
    final controller = TextEditingController();
    final isDesktop = App.isDesktop;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text('添加本地漫画路径'.tl),
          content: StatefulBuilder(
            builder: (context, setStateDialog) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: controller,
                    decoration: InputDecoration(
                      hintText: '支持选择下载目录、单个图集目录或总目录'.tl,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () async {
                            if (App.isAndroid) {
                              final initialPath = controller.text.trim();
                              Navigator.of(dialogContext).pop();
                              await Future<void>.delayed(Duration.zero);
                              if (!mounted) {
                                return;
                              }
                              final path = await _browsePath(initialPath);
                              if (path == null) {
                                return;
                              }
                              await _addPathAndReload(path);
                              return;
                            }
                            final path =
                                await _browsePath(controller.text.trim());
                            if (path != null) {
                              controller.text = path;
                              setStateDialog(() {});
                            }
                          },
                          icon: const Icon(Icons.folder_open),
                          label: Text('浏览'.tl),
                        ),
                      ),
                    ],
                  ),
                  if (isDesktop && controller.text.trim().isNotEmpty) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () =>
                            _openDirectoryPath(context, controller.text.trim()),
                        icon: const Icon(Icons.launch),
                        label: Text('打开当前目录'.tl),
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text('取消'.tl),
            ),
            TextButton(
              onPressed: () async {
                final path = controller.text.trim();
                if (path.isEmpty) {
                  return;
                }
                await _addPathAndReload(path);
                if (!dialogContext.mounted) {
                  return;
                }
                Navigator.of(dialogContext).pop();
              },
              child: Text('确定'.tl),
            ),
          ],
        );
      },
    );
  }

  Future<void> _removeCustomPath(LocalLibrarySource source) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text('移除路径'.tl),
          content: Text('确定要移除这个本地漫画路径吗？'.tl),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text('取消'.tl),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text('移除'.tl),
            ),
          ],
        );
      },
    );
    if (confirmed != true) {
      return;
    }
    await _manager.removeConfiguredLocalComicPath(source.path);
    await _refreshLocalLibrary();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('本地文件管理'.tl),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新本地漫画'.tl,
            onPressed: () async {
              await _refreshLocalLibrary();
              await _load();
            },
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '添加路径'.tl,
            onPressed: _showAddPathDialog,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: Text('本地漫画路径说明'.tl),
                  subtitle: Text(
                    '自定义路径始终参与扫描；可添加下载目录、单个图集目录或递归总目录。'.tl,
                  ),
                ),
                if (App.isAndroid) ...[
                  Card.outlined(
                    margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '安卓目录访问'.tl,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '这里会打开与设置页一致的内置文件夹浏览器，支持安卓全部文件访问权限、Shizuku 授权或 Root 模式。'
                                .tl,
                          ),
                          const SizedBox(height: 12),
                          FilledButton.icon(
                            onPressed: _showAddPathDialog,
                            icon: const Icon(Icons.folder_open),
                            label: Text('选择目录'.tl),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                const Divider(height: 1),
                for (final source in _sources) ...[
                  ListTile(
                    leading: Icon(_localLibrarySourceIcon(source)),
                    title: Text(source.title),
                    subtitle: Text(
                      '${_localLibrarySourceLabel(source)}\n${source.path}',
                    ),
                    isThreeLine: true,
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.folder_open),
                          tooltip: '打开目录'.tl,
                          onPressed: () =>
                              _openDirectoryPath(context, source.path),
                        ),
                        if (source.isCustom)
                          IconButton(
                            icon: const Icon(Icons.delete_outline),
                            tooltip: '移除'.tl,
                            onPressed: () => _removeCustomPath(source),
                          ),
                      ],
                    ),
                    onLongPress: () => _copyPath(context, source.path),
                  ),
                  const Divider(height: 1),
                ],
              ],
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddPathDialog,
        icon: const Icon(Icons.add),
        label: Text('添加路径'.tl),
      ),
    );
  }
}

class LocalLibraryStoragePage extends StatefulWidget {
  const LocalLibraryStoragePage({super.key});

  @override
  State<LocalLibraryStoragePage> createState() =>
      _LocalLibraryStoragePageState();
}

class _LocalLibraryStoragePageState extends State<LocalLibraryStoragePage> {
  final _manager = LocalLibraryManager();
  bool _loading = true;
  List<LocalLibraryStorageEntry> _entries = const <LocalLibraryStorageEntry>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
      });
    }
    final entries = await _manager.getStorageEntries();
    entries.sort((a, b) => b.sizeMb.compareTo(a.sizeMb));
    if (!mounted) {
      return;
    }
    setState(() {
      _entries = entries;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('存储空间'.tl),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新本地漫画'.tl,
            onPressed: () async {
              await _refreshLocalLibrary();
              await _load();
            },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView.separated(
              itemCount: _entries.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final entry = _entries[index];
                return ListTile(
                  leading: Icon(_localLibrarySourceIcon(entry.source)),
                  title: Text(entry.title),
                  subtitle: Text(
                    '${_formatLocalLibrarySize(entry.sizeMb)} · ${'共 @a 个图集'.tlParams({
                          'a': entry.comicCount.toString()
                        })}\n${entry.path}',
                  ),
                  isThreeLine: true,
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            _LocalLibraryStorageDetailPage(entry: entry),
                      ),
                    );
                  },
                );
              },
            ),
    );
  }
}

class _LocalLibraryStorageDetailPage extends StatelessWidget {
  const _LocalLibraryStorageDetailPage({required this.entry});

  final LocalLibraryStorageEntry entry;

  @override
  Widget build(BuildContext context) {
    final children = entry.children.toList()
      ..sort((a, b) => b.sizeMb.compareTo(a.sizeMb));
    return Scaffold(
      appBar: AppBar(
        title: Text(entry.title),
      ),
      body: ListView(
        children: [
          ListTile(
            leading: Icon(_localLibrarySourceIcon(entry.source)),
            title: Text(_formatLocalLibrarySize(entry.sizeMb)),
            subtitle: Text(entry.path),
            isThreeLine: false,
            trailing:
                Text('共 @a 个图集'.tlParams({'a': entry.comicCount.toString()})),
          ),
          const Divider(height: 1),
          for (final child in children) ...[
            ListTile(
              leading: const Icon(Icons.folder_copy_outlined),
              title: Text(child.title),
              subtitle: Text('${child.sourceDisplayName} · ${child.path}'),
              trailing: Text(_formatLocalLibrarySize(child.sizeMb)),
              onLongPress: () => _copyPath(context, child.path),
              onTap: () => _openDirectoryPath(context, child.path),
            ),
            const Divider(height: 1),
          ],
        ],
      ),
    );
  }
}

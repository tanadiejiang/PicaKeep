import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_reorderable_grid_view/widgets/reorderable_builder.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/components/comic_tile.dart';
import 'package:picakeep/components/local_favorite_update_dialog.dart';
import 'package:picakeep/components/layout.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/app_runtime_mode.dart';
import 'package:picakeep/foundation/download.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/foundation/local_favorites_update.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/local_library_settings.dart';
import 'package:picakeep/foundation/remote_library_data_source.dart';
import 'package:picakeep/foundation/service_data_source.dart';
import 'package:picakeep/tools/translations.dart';

import '../../components/scrollable.dart';
import '../local_search_page.dart';
import 'local_favorites.dart';
import 'network_favorites_page.dart';

const _kSecondaryTopBarHeight = 48.0;
const _kDrawerAnimationDuration = Duration(milliseconds: 220);

enum FavoritesView { local, remote }

String _favoritesViewLabel(FavoritesView view) {
  switch (view) {
    case FavoritesView.local:
      return '本地';
    case FavoritesView.remote:
      return '远程';
  }
}

FavoritesView _favoritesViewFromSetting(String value) {
  return normalizeTwoWayLibraryView(value) == 'remote'
      ? FavoritesView.remote
      : FavoritesView.local;
}

String _favoritesViewToSetting(FavoritesView view) {
  return view == FavoritesView.remote ? 'remote' : 'local';
}

class _FavoritesPageSession {
  static String? currentFolder;
  static bool foldersExpanded = true;
}

class MainFavoritesPage extends StatefulWidget {
  const MainFavoritesPage({super.key});

  @override
  State<MainFavoritesPage> createState() => _MainFavoritesPageState();
}

class _MainFavoritesPageState extends State<MainFavoritesPage> {
  final _favoritesManager = LocalFavoritesManager();
  final _selectedComics = <FavoriteItem>[];
  final _foldersScrollController = ScrollController();
  final RemoteLibraryClient? _remoteClient =
      RemoteLibraryClient.tryFromCurrentSettings();

  StreamSubscription<List<FavGroup>>? _foldersSubscription;

  bool _loading = true;
  bool _foldersExpanded = true;
  String? _currentFolder;
  ComicSource? _selectedNetworkSource;
  List<String> _folders = [];
  final Map<String, int> _folderCounts = {};
  final Map<String, List<RemoteFavoriteItem>> _remoteFolderItems = {};
  int _contentVersion = 0;
  FavoritesView _view = _favoritesViewFromSetting(
    appdata.settings[favoritesLibraryViewSettingIndex],
  );
  String? _loadIssue;
  DateTime? _lastManualRemoteRefreshAt;

  // 后台静默刷新进行中的计数。localDataVersion 等触发 _loadFolders(quiet: true)
  // 期间，LocalFavoritesManager.init() 会无条件经 allFoldersStream 发出旁路通知
  // （_handleFoldersChanged），该路径同样必须以 quiet 语义处理，否则本地视图浏览
  // 网络收藏（currentFolder==null）时抽屉仍会被强制展开遮盖内容。
  int _silentRefreshDepth = 0;

  bool get _isRemoteView => _view == FavoritesView.remote;

  @override
  void initState() {
    super.initState();
    App.localDataVersion.addListener(_handleLocalDataRefresh);
    App.serviceConfigVersion.addListener(_handleLocalDataRefresh);
    App.serviceRuntimeVersion.addListener(_handleLocalDataRefresh);
    _foldersSubscription = _favoritesManager.allFoldersStream.listen(
      _handleFoldersChanged,
    );
    _loadFolders();
  }

  @override
  void dispose() {
    App.localDataVersion.removeListener(_handleLocalDataRefresh);
    App.serviceConfigVersion.removeListener(_handleLocalDataRefresh);
    App.serviceRuntimeVersion.removeListener(_handleLocalDataRefresh);
    _foldersSubscription?.cancel();
    _foldersScrollController.dispose();
    super.dispose();
  }

  void _handleLocalDataRefresh() {
    _silentRefreshDepth++;
    unawaited(
      _loadFolders(quiet: true).whenComplete(() {
        _silentRefreshDepth--;
      }),
    );
  }

  void _handleFoldersChanged(List<FavGroup> groups) {
    if (!mounted || _isRemoteView) {
      return;
    }
    final folders = groups.map((group) => group.name).toList();
    setState(() {
      _loading = false;
      _loadIssue = null;
      _cacheFolderCounts(folders);
      // 后台静默刷新期间（如下载完成触发 localDataVersion 变化）经
      // allFoldersStream 发出的旁路通知同样不重置抽屉展开状态。
      _applyFolders(folders, quiet: _silentRefreshDepth > 0);
    });
  }

  void _cacheFolderCounts(List<String> folders) {
    _folderCounts
      ..clear()
      ..addEntries(
        folders.map(
          (folder) => MapEntry(folder, _favoritesManager.count(folder)),
        ),
      );
  }

  Future<void> _loadFolders({
    String? preferredFolder,
    bool collapseDrawer = false,
    bool forceRemoteRefresh = false,
    bool quiet = false, // 静默刷新时跳过展开状态重置
  }) async {
    if (_isRemoteView) {
      await _loadRemoteFolders(
        preferredFolder: preferredFolder,
        collapseDrawer: collapseDrawer,
        forceRemoteRefresh: forceRemoteRefresh,
        quiet: quiet,
      );
      return;
    }
    await _favoritesManager.init();
    if (await LocalLibraryManager().shouldUseDirectCurrentDownloadManager()) {
      await DownloadManager().init();
    }
    if (!mounted) {
      return;
    }
    final folders = List<String>.from(_favoritesManager.folderNames);
    setState(() {
      _loading = false;
      _loadIssue = null;
      _cacheFolderCounts(folders);
      _applyFolders(
        folders,
        preferredFolder: preferredFolder,
        collapseDrawer: collapseDrawer,
        quiet: quiet,
      );
    });
  }

  Future<void> _loadRemoteFolders({
    String? preferredFolder,
    bool collapseDrawer = false,
    bool forceRemoteRefresh = false,
    bool quiet = false, // 静默刷新时跳过展开状态重置
  }) async {
    final remoteAvailable = await _checkRemoteAvailability();
    if (!remoteAvailable) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _folders = const <String>[];
        _remoteFolderItems.clear();
        _folderCounts.clear();
        _currentFolder = null;
        _loadIssue = '远程加载失败'.tl;
        _contentVersion++;
      });
      return;
    }
    final client = _remoteClient;
    if (client == null) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _loadIssue = '远程加载失败'.tl;
      });
      return;
    }
    try {
      final folders = await client.fetchFavoriteFolders();
      final nextItems = <String, List<RemoteFavoriteItem>>{};
      for (final folder in folders) {
        nextItems[folder.name] =
            await client.fetchFavoritesInFolder(folder.name);
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _loadIssue = null;
        _remoteFolderItems
          ..clear()
          ..addAll(nextItems);
        _folderCounts
          ..clear()
          ..addEntries(
            folders.map((folder) => MapEntry(folder.name, folder.count)),
          );
        _applyFolders(
          folders.map((folder) => folder.name).toList(growable: false),
          preferredFolder: preferredFolder,
          collapseDrawer: collapseDrawer,
          quiet: quiet,
        );
      });
    } on RemoteLibraryRequestException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _loadIssue = e.statusCode == 404 ? '服务端不支持'.tl : '远程加载失败'.tl;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _loadIssue = '远程加载失败'.tl;
      });
    }
  }

  Future<bool> _checkRemoteAvailability() async {
    final normalizedAddress = normalizeRemoteServerAddressValue(
      appdata.settings[remoteServerAddressSettingIndex],
    );
    if (normalizedAddress.isEmpty) {
      return false;
    }
    try {
      final snapshot = await RemoteRuntimeServiceDataSource().fetchSnapshot();
      return snapshot.connectionState == ServiceConnectionState.online;
    } catch (_) {
      return false;
    }
  }

  Future<void> _setView(FavoritesView nextView) async {
    if (_view == nextView) {
      return;
    }
    setState(() {
      _view = nextView;
      _loading = true;
      _loadIssue = null;
    });
    appdata.settings[favoritesLibraryViewSettingIndex] =
        _favoritesViewToSetting(nextView);
    await appdata.updateSettings();
    await _loadFolders();
  }

  void _triggerManualRemoteRefresh() {
    final now = DateTime.now();
    final lastTriggeredAt = _lastManualRemoteRefreshAt;
    if (lastTriggeredAt != null &&
        now.difference(lastTriggeredAt) < const Duration(milliseconds: 1500)) {
      return;
    }
    _lastManualRemoteRefreshAt = now;
    setState(() {
      _loading = true;
    });
    unawaited(_loadFolders(forceRemoteRefresh: true));
  }

  void _applyFolders(
    List<String> folders, {
    String? preferredFolder,
    bool collapseDrawer = false,
    bool quiet = false, // 静默刷新时跳过展开状态重置
  }) {
    _folders = folders;

    final candidateFolder =
        preferredFolder ?? _FavoritesPageSession.currentFolder;
    if (candidateFolder != null && folders.contains(candidateFolder)) {
      _currentFolder = candidateFolder;
    } else {
      _currentFolder = null;
    }

    // quiet=true 时（后台静默刷新）：完全保留当前展开状态，不重置。
    if (!quiet) {
      if (_currentFolder == null) {
        _foldersExpanded = true;
      } else if (collapseDrawer || preferredFolder != null) {
        _foldersExpanded = false;
      } else {
        _foldersExpanded = _FavoritesPageSession.foldersExpanded;
      }
    }

    _FavoritesPageSession.currentFolder = _currentFolder;
    _FavoritesPageSession.foldersExpanded = _foldersExpanded;
    _selectedComics.clear();
    _contentVersion++;
  }

  bool get _hasAnyItems =>
      _folders.isNotEmpty ||
      ComicSource.sources.any((s) => s.favoriteData != null);

  void _toggleFolders() {
    if (!_hasAnyItems) return;
    setState(() {
      _foldersExpanded = !_foldersExpanded;
      _FavoritesPageSession.foldersExpanded = _foldersExpanded;
    });
  }

  void _selectFolder(String folder) {
    if (_currentFolder == folder && !_foldersExpanded) {
      return;
    }
    setState(() {
      _currentFolder = folder;
      _selectedNetworkSource = null;
      _foldersExpanded = false;
      _FavoritesPageSession.currentFolder = folder;
      _FavoritesPageSession.foldersExpanded = false;
      _selectedComics.clear();
      _contentVersion++;
    });
  }

  void _createFolder() {
    if (_isRemoteView) {
      final controller = TextEditingController();
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('新建文件夹'.tl),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: '名称'.tl,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('取消'.tl),
            ),
            TextButton(
              onPressed: () async {
                final name = controller.text.trim();
                if (name.isEmpty) {
                  return;
                }
                Navigator.pop(ctx);
                await _remoteClient?.createRemoteFolder(name);
                await _loadFolders(preferredFolder: name, collapseDrawer: true);
              },
              child: Text('确认'.tl),
            ),
          ],
        ),
      );
      return;
    }
    showDialog(
      context: context,
      builder: (_) => CreateFolderDialog(
        onCreated: (folderName) {
          _loadFolders(preferredFolder: folderName, collapseDrawer: true);
        },
      ),
    );
  }

  void _renameFolder(String folder) {
    final isCurrentFolder = folder == _currentFolder;
    if (_isRemoteView) {
      final controller = TextEditingController(text: folder);
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('重命名'.tl),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: '名称'.tl,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('取消'.tl),
            ),
            TextButton(
              onPressed: () async {
                final newName = controller.text.trim();
                if (newName.isEmpty) {
                  return;
                }
                Navigator.pop(ctx);
                await _remoteClient?.renameRemoteFolder(folder, newName);
                await _loadFolders(
                  preferredFolder: isCurrentFolder ? newName : null,
                  collapseDrawer: isCurrentFolder,
                );
              },
              child: Text('确认'.tl),
            ),
          ],
        ),
      );
      return;
    }
    showDialog(
      context: context,
      builder: (_) => RenameFolderDialog(
        oldName: folder,
        onRenamed: (newName) {
          _loadFolders(
            preferredFolder: isCurrentFolder ? newName : null,
            collapseDrawer: isCurrentFolder,
          );
        },
      ),
    );
  }

  Future<void> _deleteFolder(String folder) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('删除文件夹'.tl),
            content: Text('确定要删除文件夹 "$folder" 吗？'.tl),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text('取消'.tl),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text('删除'.tl),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) {
      return;
    }
    if (_isRemoteView) {
      await _remoteClient?.deleteRemoteFolder(folder);
    } else {
      _favoritesManager.deleteFolder(folder);
    }
    await _loadFolders();
  }

  Future<void> _showFolderMenu(String folder, Offset position) async {
    final action = await showMenu<_FolderMenuAction>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: [
        PopupMenuItem(
          value: _FolderMenuAction.rename,
          child: Text('重命名'.tl),
        ),
        PopupMenuItem(
          value: _FolderMenuAction.updateCards,
          child: Text('更新卡片信息'.tl),
        ),
        PopupMenuItem(
          value: _FolderMenuAction.delete,
          child: Text('删除'.tl),
        ),
      ],
    );

    if (!mounted || action == null) {
      return;
    }

    switch (action) {
      case _FolderMenuAction.rename:
        _renameFolder(folder);
        return;
      case _FolderMenuAction.updateCards:
        await _updateCardInfoFor(folder);
        return;
      case _FolderMenuAction.delete:
        await _deleteFolder(folder);
        return;
    }
  }

  void _openFavoritesSearch() {
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => const LocalSearchPage(
              searchType: LocalSearchType.favoritesOnly,
            ),
          ),
        )
        .then((_) => _loadFolders());
  }

  void _openDownloadedSearch() {
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => const LocalSearchPage(
              searchType: LocalSearchType.downloadsOnly,
            ),
          ),
        )
        .then((_) => _loadFolders());
  }

  void _openReorderPage() {
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => _FoldersReorderPage(
              folders: List<String>.from(_folders),
            ),
          ),
        )
        .then((_) => _loadFolders());
  }

  /// 「更新卡片信息」入口（操作区）。
  ///
  /// 操作区在文件夹列表页（`_currentFolder == null`），所以这里先让用户选一个
  /// 收藏夹；已在夹子内时则直接更新它。真正干活的是 [_updateCardInfoFor]，
  /// 文件夹卡片菜单也走同一个方法。
  Future<void> _updateCardInfo() async {
    final current = _currentFolder;
    if (current != null) {
      await _updateCardInfoFor(current);
      return;
    }
    final folder = await _pickFolderForUpdate();
    if (folder == null || !mounted) return;
    await _updateCardInfoFor(folder);
  }

  /// 选一个收藏夹（「更新卡片信息」在操作区触发时用）。
  Future<String?> _pickFolderForUpdate() {
    final candidates = _isRemoteView ? const <String>[] : List<String>.of(_folders);
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('还没有收藏夹'.tl)),
      );
      return Future.value();
    }
    return showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('更新哪个收藏夹的卡片信息？'.tl),
        children: [
          for (final folder in candidates)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, folder),
              child: Text(folder),
            ),
        ],
      ),
    );
  }

  /// 对指定收藏夹逐条拉取来源详情并回写本地库。
  Future<void> _updateCardInfoFor(String folder) async {
    final report = await showDialog<LocalFavoriteUpdateReport>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: LocalFavoriteUpdateDialog(folder: folder),
      ),
    );
    if (!mounted) return;
    if (report != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(buildLocalFavoriteUpdateSummary(report).tl)),
      );
    }
    // 兜底刷新：批量流程也会经文件夹流通知一次，这里保证界面一定拿到新值。
    unawaited(_loadFolders());
  }

  Widget _buildTopBar(BuildContext context) {
    final iconColor = Theme.of(context).colorScheme.primary;
    final networkSource = _selectedNetworkSource;
    final displayName = networkSource != null
        ? networkSource.favoriteData!.title
        : (_currentFolder ?? '未选择'.tl);

    return Material(
      elevation: 1,
      child: InkWell(
        hoverColor: Colors.transparent,
        onTap: _hasAnyItems ? _toggleFolders : null,
        child: SizedBox(
          height: _kSecondaryTopBarHeight,
          child: Row(
            children: [
              Icon(
                networkSource != null
                    ? Icons.cloud
                    : (_currentFolder == null
                        ? Icons.folder_outlined
                        : Icons.folder),
                color: iconColor,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16),
                ),
              ),
              const SizedBox(width: 8),
              if (_hasAnyItems)
                Icon(
                  _foldersExpanded
                      ? Icons.keyboard_arrow_up
                      : Icons.keyboard_arrow_down,
                ),
            ],
          ).paddingHorizontal(16),
        ),
      ),
    );
  }

  Widget _buildFoldersDrawer(BuildContext context, double height) {
    final networkSources = ComicSource.sources
        .where((s) => s.favoriteData != null)
        .toList(growable: false);

    return Material(
      elevation: 1,
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: DesktopScrollbarDragBehavior(
          child: Scrollbar(
            controller: _foldersScrollController,
            interactive: true,
            child: CustomScrollView(
              controller: _foldersScrollController,
              slivers: [
                const SliverToBoxAdapter(child: SizedBox(height: 8)),

                // ── 网络收藏区 ──────────────────────────────────────────────
                if (networkSources.isNotEmpty) ...[
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
                      child: Text('网络'.tl,
                          style: Theme.of(context).textTheme.labelMedium),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    sliver: SliverGrid(
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 320,
                        mainAxisExtent: 48,
                        mainAxisSpacing: 6,
                        crossAxisSpacing: 12,
                      ),
                      delegate: SliverChildBuilderDelegate(
                        (context, index) {
                          final src = networkSources[index];
                          final selected =
                              _selectedNetworkSource?.key == src.key;
                          return _NetworkSourceTile(
                            source: src,
                            selected: selected,
                            onTap: () {
                              setState(() {
                                _selectedNetworkSource = src;
                                _currentFolder = null;
                                _foldersExpanded = false;
                                _FavoritesPageSession.foldersExpanded = false;
                              });
                            },
                          );
                        },
                        childCount: networkSources.length,
                      ),
                    ),
                  ),
                  const SliverToBoxAdapter(child: Divider(height: 1)),
                  const SliverToBoxAdapter(child: SizedBox(height: 8)),
                ],

                // ── 本地/远程工具栏行 ───────────────────────────────────────
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                    child: Row(
                      children: [
                        SegmentedButton<FavoritesView>(
                          showSelectedIcon: false,
                          segments: [
                            for (final view in FavoritesView.values)
                              ButtonSegment<FavoritesView>(
                                value: view,
                                label: Text(_favoritesViewLabel(view).tl),
                              ),
                          ],
                          selected: {_view},
                          onSelectionChanged: (selection) {
                            if (selection.isEmpty) return;
                            unawaited(_setView(selection.first));
                          },
                        ),
                        const Spacer(),
                        if (_isRemoteView)
                          IconButton(
                            tooltip: '重新加载'.tl,
                            onPressed: _triggerManualRemoteRefresh,
                            icon: const Icon(Icons.refresh),
                          ),
                      ],
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: FavoritesActionRow(
                      actions: [
                        if (!_isRemoteView) ...[
                          FavoritesActionItem(
                            icon: Icons.create_new_folder_outlined,
                            label: '新建'.tl,
                            onTap: _createFolder,
                          ),
                          FavoritesActionItem(
                            icon: Icons.search,
                            label: '搜索收藏'.tl,
                            onTap: _openFavoritesSearch,
                          ),
                          FavoritesActionItem(
                            icon: Icons.manage_search,
                            label: '搜索全部'.tl,
                            onTap: _openDownloadedSearch,
                          ),
                          FavoritesActionItem(
                            icon: Icons.reorder,
                            label: '排序'.tl,
                            onTap: _openReorderPage,
                          ),
                          FavoritesActionItem(
                            icon: Icons.cloud_sync_outlined,
                            // 五个条目均分后每个只有 60 dp 左右，6 个字的
                            // 「更新卡片信息」（12 dp 字号要 72 dp）会折成两行，
                            // 图标与同排其它按钮错位；收成 4 个字后单行放得下，
                            // 完整语义由 tooltip 兜底。
                            label: '更新信息'.tl,
                            tooltip: '更新卡片信息'.tl,
                            onTap: _updateCardInfo,
                          ),
                        ] else ...[
                          FavoritesActionItem(
                            icon: Icons.create_new_folder_outlined,
                            label: '新建'.tl,
                            onTap: _createFolder,
                          ),
                          FavoritesActionItem(
                            icon: Icons.refresh,
                            label: '重新加载'.tl,
                            onTap: _triggerManualRemoteRefresh,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 8)),

                // ── 本地/远程文件夹格子 ─────────────────────────────────────
                // 加载中只让**这一块**转圈：抽屉上方的操作区（新建/搜索/排序/
                // 更新信息）与页面顶栏必须保持可用，否则远程库不响应时整页没法操作。
                if (_loading)
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 40),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  )
                else if (_loadIssue != null)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.cloud_off_outlined,
                              size: 56, color: Colors.grey),
                          const SizedBox(height: 12),
                          Text(_loadIssue!),
                          const SizedBox(height: 12),
                          FilledButton.icon(
                            onPressed: _triggerManualRemoteRefresh,
                            icon: const Icon(Icons.refresh),
                            label: Text('重新加载'.tl),
                          ),
                        ],
                      ),
                    ),
                  )
                else if (_folders.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(child: Text('这里什么都没有'.tl)),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                    sliver: SliverGrid(
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 320,
                        mainAxisExtent: 48,
                        mainAxisSpacing: 6,
                        crossAxisSpacing: 12,
                      ),
                      delegate: SliverChildBuilderDelegate(
                        (context, index) {
                          final folder = _folders[index];
                          return _FolderTile(
                            folder: folder,
                            count: _folderCounts[folder] ?? 0,
                            selected: folder == _currentFolder,
                            onTap: () => _selectFolder(folder),
                            onMenu: (position) =>
                                _showFolderMenu(folder, position),
                          );
                        },
                        childCount: _folders.length,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent() {
    // 收藏夹列表还没回来时，内容区没有可展示的收藏夹内容 —— 只有这一块转圈，
    // 顶栏与操作区照常可用可点。
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    // 网络收藏视图
    final networkSource = _selectedNetworkSource;
    if (networkSource != null) {
      return NetworkFavoriteWidget(
        key: ValueKey('network:${networkSource.key}'),
        source: networkSource,
      );
    }

    if (_currentFolder == null) {
      return Center(
        child: Text(
          _folders.isEmpty ? '这里什么都没有'.tl : '选择收藏夹'.tl,
        ),
      );
    }

    if (_isRemoteView) {
      return _RemoteFavoritesComicsPageView(
        key: ValueKey('remote:$_currentFolder:$_contentVersion'),
        folder: _currentFolder!,
        items:
            _remoteFolderItems[_currentFolder!] ?? const <RemoteFavoriteItem>[],
        client: _remoteClient,
        onDelete: (item) async {
          await _remoteClient?.deleteRemoteFavorite(_currentFolder!, item);
          await _loadFolders(preferredFolder: _currentFolder);
        },
      );
    }

    return ComicsPageView(
      key: ValueKey('$_currentFolder:$_contentVersion'),
      folder: _currentFolder!,
      selectedComics: _selectedComics,
    );
  }

  @override
  Widget build(BuildContext context) {
    // **不要**因为 _loading 就替换整页。
    //
    // _loading 的语义是"正在加载收藏夹列表"（只在切换本地/远程视图与手动刷新
    // 远程时置位），所以它只该影响**内容区与收藏夹区域**。早先这里是
    // `if (_loading) return Center(CircularProgressIndicator())`，于是远程库响应慢
    // 时整页变成一个转圈：顶栏、本地/远程切换、操作区全部不可用，网络一直不返回
    // 就永远转下去，用户只能断开连接 —— 真机反馈正是这个现象。
    return LayoutBuilder(
      builder: (context, constraints) {
        final drawerHeight = constraints.maxHeight > _kSecondaryTopBarHeight
            ? constraints.maxHeight - _kSecondaryTopBarHeight
            : 0.0;

        return Stack(
          children: [
            Positioned(
              top: _kSecondaryTopBarHeight,
              left: 0,
              right: 0,
              bottom: 0,
              child: _buildContent(),
            ),
            Positioned(
              top: _kSecondaryTopBarHeight,
              left: 0,
              right: 0,
              height: drawerHeight,
              child: ClipRect(
                child: IgnorePointer(
                  ignoring: !_foldersExpanded,
                  child: AnimatedOpacity(
                    duration: _kDrawerAnimationDuration,
                    curve: Curves.easeInOutCubic,
                    opacity: _foldersExpanded ? 1 : 0,
                    child: AnimatedSlide(
                      duration: _kDrawerAnimationDuration,
                      curve: Curves.easeInOutCubic,
                      offset:
                          _foldersExpanded ? Offset.zero : const Offset(0, -1),
                      child: _buildFoldersDrawer(context, drawerHeight),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: _buildTopBar(context),
            ),
          ],
        );
      },
    );
  }
}

class _RemoteFavoritesComicsPageView extends StatelessWidget {
  const _RemoteFavoritesComicsPageView({
    super.key,
    required this.folder,
    required this.items,
    required this.client,
    required this.onDelete,
  });

  final String folder;
  final List<RemoteFavoriteItem> items;
  final RemoteLibraryClient? client;
  final Future<void> Function(RemoteFavoriteItem item) onDelete;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return Center(child: Text('这里什么都没有'.tl));
    }
    return GridView.builder(
      physics: const ClampingScrollPhysics(),
      gridDelegate: SliverGridDelegateWithComics(),
      itemCount: items.length,
      padding: const EdgeInsets.only(bottom: 80, left: 4, right: 4, top: 4),
      itemBuilder: (context, index) {
        final item = items[index];
        return Padding(
          padding: const EdgeInsets.all(2),
          child: _RemoteFavoriteTile(
            item: item,
            client: client,
            onDelete: () => onDelete(item),
          ),
        );
      },
    );
  }
}

class _RemoteFavoriteTile extends StatelessWidget {
  const _RemoteFavoriteTile({
    required this.item,
    required this.client,
    required this.onDelete,
  });

  final RemoteFavoriteItem item;
  final RemoteLibraryClient? client;
  final Future<void> Function() onDelete;

  Future<void> _open(BuildContext context) async {
    final remoteClient = client;
    if (remoteClient == null) {
      return;
    }
    RemoteLibraryComicItem? resolved;
    try {
      final itemId = item.itemId.trim();
      if (itemId.isNotEmpty) {
        resolved = await remoteClient.fetchItemDetail(itemId);
      } else {
        resolved = await remoteClient.findItemByCandidates(
          item.toLocalFavoriteItem().candidateDownloadIds(),
          fetchDetail: true,
        );
      }
    } on RemoteLibraryDataSourceException catch (e) {
      // Without this catch a lookup timeout escapes as an unhandled exception,
      // which tears down the current route — the user sees "tap does nothing,
      // then bounced to the me-page". Surface the real reason instead.
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)),
        );
      }
      return;
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('打开失败：$e')),
        );
      }
      return;
    }
    final resolvedItem = resolved;
    if (resolvedItem == null) {
      // Use the tile's BuildContext (which has a Scaffold ancestor) — the
      // global root context does not, and ScaffoldMessenger.of would assert.
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('该漫画在服务端不可定位'.tl)),
        );
      }
      return;
    }
    App.pushInner(() => resolvedItem.createReadingPage());
  }

  @override
  Widget build(BuildContext context) {
    final provider = item.coverUrl.trim().isEmpty || client == null
        ? null
        : client!.coverImageProviderForUrl(item.coverUrl);
    return DownloadedComicTile(
      name: item.name,
      author: item.author,
      imagePath: File(''),
      imageProvider: provider,
      type: item.type.name,
      tag: item.tags,
      size: item.time,
      onTap: () => _open(context),
      onLongTap: () {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('删除'.tl),
            content: Text('要删除这个收藏吗？'.tl),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text('取消'.tl),
              ),
              TextButton(
                onPressed: () async {
                  Navigator.pop(ctx);
                  await onDelete();
                },
                child: Text('删除'.tl),
              ),
            ],
          ),
        );
      },
      onSecondaryTap: (_) {},
    );
  }
}

enum _FolderMenuAction { rename, updateCards, delete }

class _NetworkSourceTile extends StatelessWidget {
  const _NetworkSourceTile({
    required this.source,
    required this.selected,
    required this.onTap,
  });

  final ComicSource source;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: selected ? cs.surfaceContainerHigh : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(Icons.cloud_outlined, size: 24, color: cs.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                source.favoriteData!.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 15),
              ),
            ),
            Icon(Icons.chevron_right, size: 20, color: cs.outline),
          ],
        ),
      ),
    );
  }
}

/// 收藏页操作区的一排按钮（本地视图 5 个、远程视图 2 个共用）。
///
/// 抽成公开组件是为了能被单独渲染后按手机逻辑宽度量一次：这一行**会在窄屏
/// 挤到换行**（真机反馈「更新卡片信息」掉到第二行），而换行与否取决于条目
/// 宽度与可用宽度的算术关系，靠看代码估宽度不可靠（见
/// `test/favorites_action_row_layout_test.dart`）。
class FavoritesActionRow extends StatelessWidget {
  const FavoritesActionRow({super.key, required this.actions});

  final List<FavoritesActionItem> actions;

  /// 条目之间的间隔（水平与垂直共用）。
  static const double spacing = 8;

  /// 条目统一高度：等高排在一行才整齐。
  static const double itemHeight = 82;

  /// 条目宽度上限（原来写死的宽度）。
  static const double itemMaxWidth = 72;

  /// 条目宽度下限：宽度也是触控区域的一边（高度固定 82 dp），
  /// 52 dp 保证可点区域仍远大于 40 dp 的可用下限。
  static const double itemMinWidth = 52;

  @override
  Widget build(BuildContext context) {
    if (actions.isEmpty) {
      return const SizedBox.shrink();
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        // 换行的真正原因不是文案长，而是条目宽度写死 72 dp：5 个条目固定要
        // 5×72+4×8=392 dp 内容宽，加上页面左右各 12 dp 内边距就是 416 dp，
        // 而主流手机只有 360~414 dp —— 第 5 个必然被挤到第二行。
        // 所以这里按可用宽度均分条目：宽度以 itemMaxWidth 封顶（远程视图只有
        // 2 个条目，不该被拉宽），向下取整以留出余量（刚好卡住时浮点误差会把
        // 最后一个挤下去）。
        final available = constraints.maxWidth - spacing * (actions.length - 1);
        final itemWidth = (available / actions.length)
            .clamp(itemMinWidth, itemMaxWidth)
            .floorToDouble();
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final action in actions)
              SizedBox(
                width: itemWidth,
                height: itemHeight,
                child: action,
              ),
          ],
        );
      },
    );
  }
}

/// 操作区里的一个按钮：图标在上、文字在下。
///
/// 宽度由 [FavoritesActionRow] 按可用宽度分配，这里只描述内容。
class FavoritesActionItem extends StatelessWidget {
  const FavoritesActionItem({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.tooltip,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// 文案为放下一行而被缩短时，用完整语义兜底（长按/悬停可见）。
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final item = InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            icon,
            size: 28,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 10),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
    final tip = tooltip;
    return tip == null ? item : Tooltip(message: tip, child: item);
  }
}

class _FolderTile extends StatelessWidget {
  const _FolderTile({
    required this.folder,
    required this.count,
    required this.selected,
    required this.onTap,
    required this.onMenu,
  });
  final String folder;
  final int count;
  final bool selected;
  final VoidCallback onTap;
  final void Function(Offset position) onMenu;

  @override
  Widget build(BuildContext context) {
    final selectedColor = selected
        ? Theme.of(context).colorScheme.surfaceContainerHigh
        : Colors.transparent;

    return GestureDetector(
      onLongPressStart: (details) => onMenu(details.globalPosition),
      onSecondaryTapDown: (details) => onMenu(details.globalPosition),
      behavior: HitTestBehavior.opaque,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: selectedColor,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Icon(
                Icons.folder,
                size: 24,
                color: Theme.of(context).colorScheme.secondary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  folder,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 15),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                constraints: const BoxConstraints(minWidth: 28),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '$count',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FoldersReorderPage extends StatefulWidget {
  const _FoldersReorderPage({required this.folders});

  final List<String> folders;

  @override
  State<_FoldersReorderPage> createState() => _FoldersReorderPageState();
}

class _FoldersReorderPageState extends State<_FoldersReorderPage> {
  late List<String> folders = List<String>.from(widget.folders);
  final _scrollController = ScrollController();
  bool changed = false;

  void _saveOrder() {
    if (!changed) {
      return;
    }
    final order = <String, int>{};
    for (int i = 0; i < folders.length; i++) {
      order[folders[i]] = i;
    }
    LocalFavoritesManager().updateOrder(order);
    changed = false;
  }

  @override
  void dispose() {
    _saveOrder();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('排序'.tl),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            _saveOrder();
            Navigator.of(context).pop();
          },
        ),
      ),
      body: ReorderableBuilder(
        scrollController: _scrollController,
        longPressDelay: const Duration(milliseconds: 150),
        onReorder: (reorderFunc) {
          changed = true;
          setState(() {
            folders = reorderFunc(folders) as List<String>;
          });
        },
        dragChildBoxDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
        ),
        builder: (children) {
          return GridView(
            controller: _scrollController,
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 360,
              mainAxisExtent: 64,
              mainAxisSpacing: 8,
              crossAxisSpacing: 16,
            ),
            children: children,
          );
        },
        children: List.generate(
          folders.length,
          (index) => Material(
            key: ValueKey(folders[index]),
            color: Colors.transparent,
            child: Row(
              children: [
                const SizedBox(width: 16),
                Icon(
                  Icons.folder,
                  color: Theme.of(context).colorScheme.secondary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    folders[index],
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

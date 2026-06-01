import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_reorderable_grid_view/widgets/reorderable_builder.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/components/comic_tile.dart';
import 'package:picakeep/components/layout.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/app_runtime_mode.dart';
import 'package:picakeep/foundation/download.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/local_library_settings.dart';
import 'package:picakeep/foundation/remote_library_data_source.dart';
import 'package:picakeep/foundation/service_data_source.dart';
import 'package:picakeep/tools/translations.dart';

import '../../components/scrollable.dart';
import '../local_search_page.dart';
import 'local_favorites.dart';

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
  List<String> _folders = [];
  final Map<String, int> _folderCounts = {};
  final Map<String, List<RemoteFavoriteItem>> _remoteFolderItems = {};
  int _contentVersion = 0;
  FavoritesView _view = _favoritesViewFromSetting(
    appdata.settings[favoritesLibraryViewSettingIndex],
  );
  String? _loadIssue;
  DateTime? _lastManualRemoteRefreshAt;

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
    _loadFolders();
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
      _applyFolders(folders);
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
  }) async {
    if (_isRemoteView) {
      await _loadRemoteFolders(
        preferredFolder: preferredFolder,
        collapseDrawer: collapseDrawer,
        forceRemoteRefresh: forceRemoteRefresh,
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
      );
    });
  }

  Future<void> _loadRemoteFolders({
    String? preferredFolder,
    bool collapseDrawer = false,
    bool forceRemoteRefresh = false,
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
        nextItems[folder.name] = await client.fetchFavoritesInFolder(folder.name);
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
  }) {
    _folders = folders;

    final candidateFolder =
        preferredFolder ?? _FavoritesPageSession.currentFolder;
    if (candidateFolder != null && folders.contains(candidateFolder)) {
      _currentFolder = candidateFolder;
    } else {
      _currentFolder = null;
    }

    if (_currentFolder == null) {
      _foldersExpanded = true;
    } else if (collapseDrawer || preferredFolder != null) {
      _foldersExpanded = false;
    } else {
      _foldersExpanded = _FavoritesPageSession.foldersExpanded;
    }

    _FavoritesPageSession.currentFolder = _currentFolder;
    _FavoritesPageSession.foldersExpanded = _foldersExpanded;
    _selectedComics.clear();
    _contentVersion++;
  }

  void _toggleFolders() {
    if (_folders.isEmpty) {
      return;
    }
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

  Widget _buildTopBar(BuildContext context) {
    final iconColor = Theme.of(context).colorScheme.primary;

    return Material(
      elevation: 1,
      child: InkWell(
        hoverColor: Colors.transparent,
        onTap: _folders.isEmpty ? null : _toggleFolders,
        child: SizedBox(
          height: _kSecondaryTopBarHeight,
          child: Row(
            children: [
              Icon(
                _currentFolder == null ? Icons.folder_outlined : Icons.folder,
                color: iconColor,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _currentFolder ?? '未选择'.tl,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16),
                ),
              ),
              const SizedBox(width: 8),
              if (_folders.isNotEmpty)
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
                            if (selection.isEmpty) {
                              return;
                            }
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
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (!_isRemoteView) ...[
                          _ActionItem(
                            icon: Icons.create_new_folder_outlined,
                            label: '新建'.tl,
                            onTap: _createFolder,
                          ),
                          _ActionItem(
                            icon: Icons.search,
                            label: '搜索收藏'.tl,
                            onTap: _openFavoritesSearch,
                          ),
                          _ActionItem(
                            icon: Icons.manage_search,
                            label: '搜索全部'.tl,
                            onTap: _openDownloadedSearch,
                          ),
                          _ActionItem(
                            icon: Icons.reorder,
                            label: '排序'.tl,
                            onTap: _openReorderPage,
                          ),
                        ] else ...[
                          _ActionItem(
                            icon: Icons.create_new_folder_outlined,
                            label: '新建'.tl,
                            onTap: _createFolder,
                          ),
                          _ActionItem(
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
                if (_loadIssue != null)
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
                    child: Center(
                      child: Text('这里什么都没有'.tl),
                    ),
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
        items: _remoteFolderItems[_currentFolder!] ?? const <RemoteFavoriteItem>[],
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
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

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
      resolved = await remoteClient.findItemByCandidates(
        item.toLocalFavoriteItem().candidateDownloadIds(),
        fetchDetail: true,
      );
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

enum _FolderMenuAction { rename, delete }

class _ActionItem extends StatelessWidget {
  const _ActionItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: SizedBox(
        width: 72,
        height: 82,
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
      ),
    );
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

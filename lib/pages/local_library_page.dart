import 'dart:io';

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
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/local_library_settings.dart';
import 'package:picakeep/foundation/remote_library_data_source.dart';
import 'package:picakeep/foundation/service_data_source.dart';
import 'package:picakeep/tools/read_history_helper.dart';
import 'package:picakeep/tools/translations.dart';

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
  if (rescan) {
    await LocalLibraryManager().rescan();
  } else {
    await LocalLibraryManager().refresh();
  }
  App.notifyLocalDataChanged();
}

class _LocalLibraryComicTile extends DownloadedComicTile {
  const _LocalLibraryComicTile({
    required this.comicId,
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
  });

  final String comicId;

  @override
  String? get comicID => comicId;

  @override
  bool get enableLongPressed => false;
}

class _RemoteRootCollage extends StatelessWidget {
  const _RemoteRootCollage({required this.urls});

  final List<String> urls;

  @override
  Widget build(BuildContext context) {
    final visibleUrls = urls
        .map((entry) => entry.trim())
        .where((entry) => entry.isNotEmpty)
        .take(4)
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
      ),
      itemCount: visibleUrls.length,
      itemBuilder: (context, index) {
        return Image.network(
          visibleUrls[index],
          fit: BoxFit.cover,
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
    required this.onSecondaryTap,
  });

  final RemoteLibraryRootItem item;
  final String sizeText;
  final VoidCallback onTap;
  final void Function(TapDownDetails details) onSecondaryTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        elevation: 1,
        child: InkWell(
          onTap: onTap,
          onSecondaryTapDown: onSecondaryTap,
          borderRadius: BorderRadius.circular(8),
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
                      child: _RemoteRootCollage(urls: item.previewCoverUrls),
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

class LocalLibraryPage extends StatefulWidget {
  const LocalLibraryPage({
    super.key,
    this.albumOnly = false,
    this.preferRemoteView = false,
    this.title,
    this.remoteRootId,
  });

  final bool albumOnly;
  final bool preferRemoteView;
  final String? title;
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
  bool _loading = true;
  bool _searchMode = false;
  bool _remoteAvailable = false;
  String? _errorText;
  List<DownloadedItem> _items = const <DownloadedItem>[];
  late _LocalLibraryView _view = widget.preferRemoteView || _isRemoteRootPage
      ? _LocalLibraryView.remote
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

  bool get _showSourceSelector => _remoteAvailable && !_isRemoteRootPage;

  Future<void> _setView(_LocalLibraryView nextView) async {
    if (_view == nextView) {
      return;
    }
    setState(() {
      _view = nextView;
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
    _load();
  }

  void _handleServiceConfigChanged() {
    _load();
  }

  void _handleServiceRuntimeChanged() {
    _load();
  }

  Future<void> _refreshCurrentLibrary({bool rescan = false}) async {
    if (_view == _LocalLibraryView.remote && _remoteAvailable) {
      await _load();
      return;
    }
    await _refreshLocalLibrary(rescan: rescan);
    await _load();
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

  Future<List<DownloadedItem>> _loadLocalItems() async {
    final items = await _manager.getAll();
    final visibleItems = _isAlbumOnly
        ? items.where((item) => item.isAlbum).toList(growable: false)
        : items.cast<DownloadedItem>().toList(growable: false);
    return _sortItems(visibleItems);
  }

  Future<List<DownloadedItem>> _loadRemoteItems() async {
    final rootId = widget.remoteRootId?.trim() ?? '';
    if (rootId.isNotEmpty) {
      final items = await _remoteDataSource.fetchItemsForRoot(rootId);
      return _sortItems(items.toList());
    }
    final roots = await _remoteDataSource.fetchRootItems(
      customLibraryOnly: true,
    );
    return _sortItems(roots.cast<DownloadedItem>().toList());
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _errorText = null;
      });
    }
    try {
      final remoteAvailable = await _checkRemoteAvailability();
      if (!remoteAvailable && _view != _LocalLibraryView.local) {
        _view = _LocalLibraryView.local;
        appdata.settings[localLibraryViewSettingIndex] = 'local';
        await appdata.updateSettings();
      }
      final localItems = await _loadLocalItems();
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
          items = remoteAvailable ? await _loadRemoteItems() : localItems;
          break;
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _items = items;
        _remoteAvailable = remoteAvailable;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _items = const <DownloadedItem>[];
        _remoteAvailable = false;
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
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => LocalLibraryPage(
            albumOnly: widget.albumOnly,
            preferRemoteView: true,
            title: item.name,
            remoteRootId: item.root.id,
          ),
        ),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => LocalComicDetailPage(comic: item)),
    );
  }

  Future<void> _showActions(DownloadedItem item) async {
    final path = item.fileSystemPath?.trim() ?? '';
    final isRootItem = item is RemoteLibraryRootItem;
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
    final isRootItem = item is RemoteLibraryRootItem;
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

  Widget _buildItem(DownloadedItem item) {
    if (item is RemoteLibraryRootItem) {
      return Padding(
        padding: const EdgeInsets.all(2),
        child: _LocalLibraryRemoteRootCard(
          item: item,
          sizeText: item.comicSize == null
              ? '未知大小'.tl
              : _formatLocalLibrarySize(item.comicSize!),
          onTap: () => _openItem(item),
          onSecondaryTap: (details) => _showDesktopMenu(item, details),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(2),
      child: _LocalLibraryComicTile(
        comicId: item.id,
        name: item.name,
        author: item.subTitle,
        imagePath: _coverFile(item),
        imageProvider: _coverImageProvider(item),
        type: item.sourceDisplayName,
        tag: item.tags,
        size: item.comicSize == null
            ? '未知大小'.tl
            : _formatLocalLibrarySize(item.comicSize!),
        onTap: () => _openItem(item),
        onLongTap: () {},
        onSecondaryTap: (details) => _showDesktopMenu(item, details),
      ),
    );
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
    final refreshLabel = (_view == _LocalLibraryView.remote && _remoteAvailable)
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
              onPressed: () async {
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

  @override
  Widget build(BuildContext context) {
    final items = _filteredItems;
    final refreshTooltip =
        (_view == _LocalLibraryView.remote && _remoteAvailable)
            ? (_isAlbumOnly ? '刷新远程图集'.tl : '刷新远程资源库'.tl)
            : (_isAlbumOnly ? '刷新图集'.tl : '刷新资源库'.tl);
    return Scaffold(
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SmoothCustomScrollView(
              slivers: [
                SliverAppbar(
                  title: _buildTitle(),
                  actions: [
                    IconButton(
                      icon: const Icon(Icons.refresh),
                      tooltip: refreshTooltip,
                      onPressed: () async {
                        await _refreshCurrentLibrary();
                      },
                    ),
                    if (!widget.albumOnly)
                      IconButton(
                        icon: Icon(
                          appdata.settings[localLibraryAlbumOnlySettingIndex] !=
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
                      icon: Icon(_searchMode ? Icons.close : Icons.search),
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
                  SliverGrid(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final item = items[index];
                        return GestureDetector(
                          onLongPress: () => _showActions(item),
                          child: _buildItem(item),
                        );
                      },
                      childCount: items.length,
                    ),
                    gridDelegate: SliverGridDelegateWithComics(),
                  ),
              ],
            ),
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

  static const _androidCommonPaths = <String>[
    '/storage/emulated/0/Download',
    '/storage/emulated/0/Android/data',
    '/storage/emulated/0/Pictures',
    '/sdcard/Download',
  ];

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
                            final path = await _pickFolder();
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
                  if (App.isAndroid) ...[
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '安卓常用目录'.tl,
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final path in _androidCommonPaths)
                          ActionChip(
                            label: Text(path),
                            onPressed: () {
                              controller.text = path;
                              setStateDialog(() {});
                            },
                          ),
                      ],
                    ),
                  ],
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
                await _manager.addConfiguredLocalComicPath(path);
                await _refreshLocalLibrary();
                if (!dialogContext.mounted) {
                  return;
                }
                Navigator.of(dialogContext).pop();
                await _load();
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
                            '这里仅保留普通目录选择与路径管理；受限目录请到设置页的下载目录弹窗中长按“浏览”处理。'.tl,
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

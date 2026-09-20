import 'dart:io';

import 'package:flutter/material.dart';

import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/comic_source/favorite_data.dart';
import 'package:picakeep/components/comic_tile.dart';
import 'package:picakeep/components/layout.dart';
import 'package:picakeep/foundation/app_page_route.dart';
import 'package:picakeep/foundation/comic_tile_display_config.dart';
import 'package:picakeep/foundation/download_author_resolver.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/network/base_comic.dart';
import 'package:picakeep/tools/translations.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  NetworkFavoriteWidget — 可内嵌的网络收藏内容（无 Scaffold）
// ─────────────────────────────────────────────────────────────────────────────

class NetworkFavoriteWidget extends StatefulWidget {
  const NetworkFavoriteWidget({super.key, required this.source});

  final ComicSource source;

  @override
  State<NetworkFavoriteWidget> createState() => _NetworkFavoriteWidgetState();
}

class _NetworkFavoriteWidgetState extends State<NetworkFavoriteWidget> {
  // ── 文件夹层 ────────────────────────────────────────────────────────────────
  Map<String, String>? _folders;
  bool _loadingFolders = false;
  String? _foldersError;
  String? _currentFolderId; // null = 文件夹列表; 非null = 漫画列表

  // ── 漫画层 ──────────────────────────────────────────────────────────────────
  final _items = <BaseComic>[];
  int _page = 0;
  int? _maxPage;
  bool _loading = false;
  String? _error;

  FavoriteData get _favoriteData => widget.source.favoriteData!;

  bool get _multiFolder => _favoriteData.multiFolder;

  @override
  void initState() {
    super.initState();
    if (_multiFolder) {
      _loadFolders();
    } else {
      _load(reset: true);
    }
  }

  @override
  void didUpdateWidget(NetworkFavoriteWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source.key != widget.source.key) {
      _folders = null;
      _currentFolderId = null;
      _foldersError = null;
      _items.clear();
      _page = 0;
      _maxPage = null;
      _error = null;
      if (_multiFolder) {
        _loadFolders();
      } else {
        _load(reset: true);
      }
    }
  }

  // ── 文件夹加载 ──────────────────────────────────────────────────────────────

  Future<void> _loadFolders() async {
    if (_loadingFolders) return;
    if (!widget.source.isLoggedIn) {
      setState(() => _foldersError = '请先登录该在线源');
      return;
    }
    setState(() {
      _loadingFolders = true;
      _foldersError = null;
    });
    final loader = _favoriteData.loadFolders;
    if (loader == null) {
      // 没有 loadFolders 则直接进漫画列表
      setState(() {
        _loadingFolders = false;
        _currentFolderId = _favoriteData.allFavoritesId;
      });
      _load(reset: true);
      return;
    }
    final res = await loader();
    if (!mounted) return;
    if (res.error) {
      setState(() {
        _loadingFolders = false;
        _foldersError = res.errorMessageWithoutNull;
      });
      return;
    }
    final allId = _favoriteData.allFavoritesId;
    final map = <String, String>{};
    if (allId != null && !res.data.containsKey(allId)) {
      map[allId] = '全部';
    }
    map.addAll(res.data);
    setState(() {
      _loadingFolders = false;
      _folders = map;
    });
  }

  // ── 漫画加载 ────────────────────────────────────────────────────────────────

  Future<void> _load({bool reset = false}) async {
    if (_loading) return;
    if (!widget.source.isLoggedIn) {
      setState(() => _error = '请先登录该在线源');
      return;
    }
    final nextPage = reset ? 1 : _page + 1;
    if (!reset && _maxPage != null && _page >= _maxPage!) return;
    setState(() {
      _loading = true;
      _error = null;
      if (reset) {
        _items.clear();
        _page = 0;
        _maxPage = null;
      }
    });
    final res = await _favoriteData.loadComic(nextPage, _currentFolderId);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (res.error) {
        _error = res.errorMessageWithoutNull;
        return;
      }
      _page = nextPage;
      final sub = res.subData;
      _maxPage = sub is int ? sub : int.tryParse('$sub');
      _items.addAll(res.data);
    });
  }

  // ── 文件夹选择 ──────────────────────────────────────────────────────────────

  void _selectFolder(String folderId) {
    setState(() {
      _currentFolderId = folderId;
      _items.clear();
      _page = 0;
      _maxPage = null;
      _error = null;
    });
    _load(reset: true);
  }

  void _backToFolders() {
    setState(() {
      _currentFolderId = null;
      _items.clear();
      _page = 0;
      _maxPage = null;
      _error = null;
    });
    // 如果文件夹列表需要刷新（如首次进入时 loader 返回错误）可在此重新调用
  }

  // ── 其他操作 ────────────────────────────────────────────────────────────────

  void _openComic(BaseComic comic) {
    final builder = widget.source.comicPageBuilder;
    if (builder == null) return;
    Navigator.of(context).push(AppPageRoute(builder: (_) => builder(comic)));
  }

  Future<void> _copyToLocal(BuildContext parentCtx, BaseComic comic) async {
    await LocalFavoritesManager().init();
    if (!parentCtx.mounted) return;
    final folders = LocalFavoritesManager().folderNames;
    String? folder = folders.isEmpty ? null : folders.first;
    await showDialog<void>(
      context: parentCtx,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('转存本地'.tl),
          content: folders.isEmpty
              ? Text('请先创建本地收藏夹'.tl)
              : DropdownButtonFormField<String>(
                  initialValue: folder,
                  decoration: const InputDecoration(
                    labelText: '收藏夹',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final name in folders)
                      DropdownMenuItem(value: name, child: Text(name)),
                  ],
                  onChanged: (v) => setDialogState(() => folder = v),
                ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: Text('取消'.tl),
            ),
            FilledButton(
              onPressed: folder == null
                  ? null
                  : () {
                      final item = FavoriteItem(
                        target: comic.id,
                        name: comic.title,
                        coverPath: comic.cover,
                        author: resolveSourceAuthors(
                          source: widget.source.key,
                          flatTags: comic.tags,
                          fallbackAuthor: comic.subTitle,
                        ).join(', '),
                        type: _favoriteTypeForSource(widget.source.key),
                        tags: comic.tags,
                      );
                      LocalFavoritesManager().addComic(folder!, item);
                      Navigator.pop(dialogCtx);
                      ScaffoldMessenger.of(parentCtx).showSnackBar(
                        SnackBar(content: Text('已转存本地'.tl)),
                      );
                    },
              child: Text('确认'.tl),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _removeFavorite(BaseComic comic) async {
    final del = _favoriteData.addOrDelFavorite;
    if (del == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('取消收藏'.tl),
        content: Text('确定要取消收藏「${comic.title}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消'.tl),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('确认'.tl),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final res = await del(comic, false);
    if (!mounted) return;
    if (res.success) {
      setState(() => _items.remove(comic));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('操作失败：${res.errorMessageWithoutNull}')),
      );
    }
  }

  // ── 构建 ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_multiFolder && _currentFolderId == null) {
      return _buildFolderList();
    }
    return _buildComicList();
  }

  Widget _buildFolderList() {
    if (_foldersError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_foldersError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _loadFolders,
              icon: const Icon(Icons.refresh),
              label: Text('重试'.tl),
            ),
          ],
        ),
      );
    }

    if (_loadingFolders || _folders == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final folders = _folders!;
    if (folders.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('暂无收藏夹'.tl),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _loadFolders,
              icon: const Icon(Icons.refresh),
              label: Text('刷新'.tl),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 80, top: 8),
      itemCount: folders.length,
      itemBuilder: (context, index) {
        final entry = folders.entries.elementAt(index);
        return ListTile(
          leading: Icon(
            Icons.folder_outlined,
            color: Theme.of(context).colorScheme.primary,
          ),
          title: Text(entry.value),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _selectFolder(entry.key),
        );
      },
    );
  }

  Widget _buildComicList() {
    final folderName = _multiFolder
        ? (_folders?[_currentFolderId] ?? _currentFolderId ?? '')
        : null;

    if (_error != null) {
      return Column(
        children: [
          if (_multiFolder && folderName != null)
            _FolderHeader(
              name: folderName,
              onBack: _backToFolders,
            ),
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: () => _load(reset: true),
                    icon: const Icon(Icons.refresh),
                    label: Text('重试'.tl),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    if (_items.isEmpty && !_loading) {
      return Column(
        children: [
          if (_multiFolder && folderName != null)
            _FolderHeader(
              name: folderName,
              onBack: _backToFolders,
            ),
          Expanded(
            child: Center(
              child: FilledButton.icon(
                onPressed: () => _load(reset: true),
                icon: const Icon(Icons.refresh),
                label: Text('加载收藏'.tl),
              ),
            ),
          ),
        ],
      );
    }

    final canRemove = _favoriteData.addOrDelFavorite != null;

    return Column(
      children: [
        if (_multiFolder && folderName != null)
          _FolderHeader(name: folderName, onBack: _backToFolders),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: (n) {
              if (n is ScrollEndNotification &&
                  n.metrics.pixels >= n.metrics.maxScrollExtent - 200) {
                _load();
              }
              return false;
            },
            child: RefreshIndicator(
              onRefresh: () => _load(reset: true),
              child: GridView.builder(
                padding: const EdgeInsets.only(
                    bottom: 80, left: 4, right: 4, top: 4),
                gridDelegate: SliverGridDelegateWithComics(),
                itemCount: _items.length + (_loading ? 1 : 0),
                itemBuilder: (context, index) {
                  if (index >= _items.length) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final comic = _items[index];
                  final headers =
                      widget.source.imageHeadersBuilder?.call(comic) ?? {};
                  final imageProvider = headers.isEmpty
                      ? NetworkImage(comic.cover)
                      : NetworkImage(comic.cover, headers: headers);
                  // 在线收藏只读「online」这一套（不区分源）：同一页面里 source
                  // 固定，逐条读取没有额外信息量。
                  final cardConfig = readOnlineComicTileDisplayConfig();
                  return Padding(
                    padding: const EdgeInsets.all(2),
                    child: DownloadedComicTile(
                      cardDisplayConfig: cardConfig,
                      name: comic.title,
                      author: resolveSourceAuthors(
                        source: widget.source.key,
                        flatTags: comic.tags,
                        fallbackAuthor: comic.subTitle,
                      ).join(', '),
                      imagePath: File(''),
                      imageProvider: imageProvider,
                      type: null,
                      tag: comic.tags,
                      size: displaySourceInfoLine(
                        source: widget.source.key,
                        comicId: comic.id,
                        description: comic.description,
                        showId: cardConfig.showId,
                      ),
                      onTap: () => _openComic(comic),
                      onLongTap: () {
                        showModalBottomSheet<void>(
                          context: context,
                          builder: (ctx) => SafeArea(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ListTile(
                                  leading: const Icon(Icons.playlist_add),
                                  title: Text('转存本地'.tl),
                                  onTap: () {
                                    Navigator.pop(ctx);
                                    _copyToLocal(context, comic);
                                  },
                                ),
                                if (canRemove)
                                  ListTile(
                                    leading: const Icon(
                                        Icons.bookmark_remove_outlined),
                                    title: Text('取消收藏'.tl),
                                    onTap: () {
                                      Navigator.pop(ctx);
                                      _removeFavorite(comic);
                                    },
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                      onSecondaryTap: (_) {},
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ── 文件夹标题行（含返回按钮）──────────────────────────────────────────────────

class _FolderHeader extends StatelessWidget {
  const _FolderHeader({required this.name, required this.onBack});

  final String name;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: InkWell(
        onTap: onBack,
        child: SizedBox(
          height: 44,
          child: Row(
            children: [
              const SizedBox(width: 4),
              const Icon(Icons.arrow_back_ios_new, size: 18),
              const SizedBox(width: 8),
              Icon(
                Icons.folder,
                size: 20,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 15),
                ),
              ),
              const SizedBox(width: 12),
            ],
          ),
        ),
      ),
    );
  }
}

FavoriteType _favoriteTypeForSource(String? key) {
  switch (key) {
    case 'jm':
      return FavoriteType.jm;
    case 'ehentai':
      return FavoriteType.ehentai;
    case 'nhentai':
      return FavoriteType.nhentai;
    case 'picacg':
    default:
      return FavoriteType.picacg;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  NetworkFavoritesPage — 独立页（保留，用于原有入口 push）
// ─────────────────────────────────────────────────────────────────────────────

class NetworkFavoritesPage extends StatefulWidget {
  const NetworkFavoritesPage({super.key});

  @override
  State<NetworkFavoritesPage> createState() => _NetworkFavoritesPageState();
}

class _NetworkFavoritesPageState extends State<NetworkFavoritesPage> {
  late ComicSource? _source;

  Iterable<ComicSource> get _favoriteSources =>
      ComicSource.sources.where((s) => s.favoriteData != null);

  @override
  void initState() {
    super.initState();
    final sources = _favoriteSources.toList(growable: false);
    _source = sources.isEmpty ? null : sources.first;
  }

  @override
  Widget build(BuildContext context) {
    final sources = _favoriteSources.toList(growable: false);
    if (sources.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('网络收藏')),
        body: const Center(child: Text('暂无网络收藏源')),
      );
    }
    final source = _source;
    return Scaffold(
      appBar: AppBar(
        title: const Text('网络收藏'),
        bottom: sources.length > 1
            ? PreferredSize(
                preferredSize: const Size.fromHeight(48),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Row(
                    children: [
                      for (final s in sources) ...[
                        ChoiceChip(
                          label: Text(s.favoriteData!.title),
                          selected: source?.key == s.key,
                          onSelected: (_) => setState(() => _source = s),
                        ),
                        const SizedBox(width: 8),
                      ],
                    ],
                  ),
                ),
              )
            : null,
      ),
      body: source == null
          ? const SizedBox.shrink()
          : NetworkFavoriteWidget(key: ValueKey(source.key), source: source),
    );
  }
}

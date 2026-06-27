import 'package:flutter/material.dart';

import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app_page_route.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/network/base_comic.dart';
import 'package:picakeep/tools/translations.dart';

class NetworkFavoritesPage extends StatefulWidget {
  const NetworkFavoritesPage({super.key});

  @override
  State<NetworkFavoritesPage> createState() => _NetworkFavoritesPageState();
}

class _NetworkFavoritesPageState extends State<NetworkFavoritesPage> {
  ComicSource? _source;
  final _items = <BaseComic>[];
  int _page = 0;
  int? _maxPage;
  bool _loading = false;
  String? _error;

  Iterable<ComicSource> get _favoriteSources =>
      ComicSource.sources.where((source) => source.favoriteData != null);

  @override
  void initState() {
    super.initState();
    final sources = _favoriteSources.toList(growable: false);
    if (sources.isNotEmpty) {
      _source = sources.first;
      _load(reset: true);
    }
  }

  Future<void> _load({bool reset = false}) async {
    final source = _source;
    if (source == null || _loading) {
      return;
    }
    if (!source.isLoggedIn) {
      setState(() {
        _error = '请先登录该在线源';
      });
      return;
    }
    final nextPage = reset ? 1 : _page + 1;
    if (!reset && _maxPage != null && _page >= _maxPage!) {
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      if (reset) {
        _items.clear();
        _page = 0;
        _maxPage = null;
      }
    });
    final res = await source.favoriteData!.loadComic(nextPage);
    if (!mounted) {
      return;
    }
    setState(() {
      _loading = false;
      if (res.error) {
        _error = res.errorMessageWithoutNull;
        return;
      }
      _page = nextPage;
      final subData = res.subData;
      _maxPage = subData is int ? subData : int.tryParse('$subData');
      _items.addAll(res.data);
    });
  }

  void _openComic(BaseComic comic) {
    final builder = _source?.comicPageBuilder;
    if (builder == null) {
      return;
    }
    Navigator.of(context).push(AppPageRoute(builder: (_) => builder(comic)));
  }

  Future<void> _copyToLocal(BaseComic comic) async {
    await LocalFavoritesManager().init();
    if (!mounted) {
      return;
    }
    final folders = LocalFavoritesManager().folderNames;
    String? folder = folders.isEmpty ? null : folders.first;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
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
                  onChanged: (value) {
                    setDialogState(() {
                      folder = value;
                    });
                  },
                ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
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
                        author: comic.subTitle,
                        type: FavoriteType.picacg,
                        tags: comic.tags,
                      );
                      LocalFavoritesManager().addComic(folder!, item);
                      Navigator.pop(ctx);
                      ScaffoldMessenger.of(context).showSnackBar(
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

  @override
  Widget build(BuildContext context) {
    final sources = _favoriteSources.toList(growable: false);
    return Scaffold(
      appBar: AppBar(title: const Text('网络收藏')),
      body: sources.isEmpty
          ? const Center(child: Text('暂无网络收藏源'))
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: DropdownButtonFormField<ComicSource>(
                    initialValue: _source,
                    decoration: const InputDecoration(
                      labelText: '在线源',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      for (final source in sources)
                        DropdownMenuItem(
                          value: source,
                          child: Text(source.favoriteData!.title),
                        ),
                    ],
                    onChanged: (source) {
                      if (source == null) return;
                      setState(() {
                        _source = source;
                      });
                      _load(reset: true);
                    },
                  ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                Expanded(
                  child: _items.isEmpty && !_loading
                      ? Center(
                          child: FilledButton.icon(
                            onPressed: () => _load(reset: true),
                            icon: const Icon(Icons.refresh),
                            label: const Text('加载收藏'),
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.all(12),
                          itemCount: _items.length + 1,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 8),
                          itemBuilder: (context, index) {
                            if (index == _items.length) {
                              if (_loading) {
                                return const Center(
                                  child: Padding(
                                    padding: EdgeInsets.all(20),
                                    child: CircularProgressIndicator(),
                                  ),
                                );
                              }
                              if (_maxPage != null && _page >= _maxPage!) {
                                return const SizedBox.shrink();
                              }
                              return Center(
                                child: TextButton.icon(
                                  onPressed: _load,
                                  icon: const Icon(Icons.expand_more),
                                  label: const Text('加载更多'),
                                ),
                              );
                            }
                            final comic = _items[index];
                            return ListTile(
                              leading: ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: Image.network(
                                  comic.cover,
                                  width: 48,
                                  height: 64,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => const SizedBox(
                                    width: 48,
                                    height: 64,
                                    child: Icon(Icons.broken_image_outlined),
                                  ),
                                ),
                              ),
                              title: Text(comic.title),
                              subtitle: Text(comic.subTitle),
                              onTap: () => _openComic(comic),
                              trailing: IconButton(
                                tooltip: '转存本地',
                                onPressed: () => _copyToLocal(comic),
                                icon: const Icon(Icons.playlist_add),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}

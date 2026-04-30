import 'package:flutter/material.dart';
import 'package:picakeep/foundation/download.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'local_comic_detail_page.dart';
import 'favorites/local_favorites.dart';

class _SearchResult {
  final String title;
  final String author;
  final String sourceLabel;
  final List<String> tags;
  final String? targetId;
  final FavoriteType? favType;
  final DownloadedItem? downloadItem;
  final FavoriteItemWithFolderInfo? favoriteItem;
  _SearchResult(
      {required this.title,
      required this.author,
      required this.sourceLabel,
      this.tags = const [],
      this.targetId,
      this.favType,
      this.downloadItem,
      this.favoriteItem});
}

class LocalSearchPage extends StatefulWidget {
  const LocalSearchPage({super.key});
  @override
  State<LocalSearchPage> createState() => _LocalSearchPageState();
}

class _LocalSearchPageState extends State<LocalSearchPage> {
  final _controller = TextEditingController();
  List<_SearchResult> _results = [];
  bool _hasSearched = false;
  bool _isSearching = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search(String keyword) async {
    if (keyword.trim().isEmpty) {
      setState(() {
        _results = [];
        _hasSearched = false;
      });
      return;
    }
    setState(() => _isSearching = true);
    final results = <_SearchResult>[];
    final seenIds = <String>{};
    final favManager = LocalFavoritesManager();
    await favManager.init();
    final favResults = favManager.search(keyword);
    for (final fav in favResults) {
      final c = fav.comic;
      final idKey = 'fav_${c.type.key}_${c.target}';
      if (seenIds.contains(idKey)) continue;
      seenIds.add(idKey);
      results.add(_SearchResult(
          title: c.name,
          author: c.author,
          sourceLabel: '${c.type.name} · ${fav.folder}',
          tags: c.tags,
          targetId: c.toDownloadId(),
          favType: c.type,
          favoriteItem: fav));
    }
    try {
      final dlManager = DownloadManager();
      await dlManager.init();
      for (final item in dlManager.getAll()) {
        final idKey = 'dl_${item.id}';
        if (seenIds.contains(idKey)) continue;
        if (_matches(item, keyword)) {
          seenIds.add(idKey);
          results.add(_SearchResult(
              title: item.name,
              author: item.subTitle,
              sourceLabel: _downloadLabel(item.type),
              tags: item.tags,
              targetId: item.id,
              downloadItem: item));
        }
      }
    } catch (_) {}
    setState(() {
      _results = results;
      _hasSearched = true;
      _isSearching = false;
    });
  }

  bool _matches(DownloadedItem item, String keyword) {
    final k = keyword.trim().toLowerCase();
    for (final kw in k.split(' ')) {
      if (kw.isEmpty) continue;
      if (!item.name.toLowerCase().contains(kw) &&
          !item.subTitle.toLowerCase().contains(kw) &&
          !item.tags.any((t) => t.toLowerCase().contains(kw))) return false;
    }
    return true;
  }

  String _downloadLabel(DownloadType type) {
    switch (type) {
      case DownloadType.picacg:
        return 'Picacg · 下载';
      case DownloadType.ehentai:
        return 'E-Hentai · 下载';
      case DownloadType.jm:
        return '禁漫 · 下载';
      case DownloadType.hitomi:
        return 'Hitomi · 下载';
      case DownloadType.htmanga:
        return '绅士漫画 · 下载';
      case DownloadType.nhentai:
        return 'NHentai · 下载';
      case DownloadType.copyManga:
        return '拷贝漫画 · 下载';
      case DownloadType.komiic:
        return 'Komiic · 下载';
      default:
        return '下载';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
            controller: _controller,
            autofocus: true,
            decoration: const InputDecoration(
                hintText: '搜索本地漫画...',
                border: InputBorder.none,
                prefixIcon: Icon(Icons.search)),
            textInputAction: TextInputAction.search,
            onSubmitted: _search,
            onChanged: (v) {
              if (v.isEmpty)
                setState(() {
                  _results = [];
                  _hasSearched = false;
                });
            }),
        actions: [
          if (_controller.text.isNotEmpty)
            IconButton(
                icon: const Icon(Icons.clear),
                onPressed: () {
                  _controller.clear();
                  setState(() {
                    _results = [];
                    _hasSearched = false;
                  });
                }),
        ],
      ),
      body: _isSearching
          ? const Center(child: CircularProgressIndicator())
          : !_hasSearched
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.search,
                      size: 64, color: Theme.of(context).colorScheme.outline),
                  const SizedBox(height: 16),
                  Text('输入关键词搜索本地收藏和下载',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.outline)),
                ]))
              : _results.isEmpty
                  ? const Center(child: Text('未找到匹配的漫画'))
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: _results.length,
                      itemBuilder: (ctx, i) => _buildCard(_results[i])),
    );
  }

  Widget _buildCard(_SearchResult r) {
    return Card(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
        child: InkWell(
            onTap: () {
              if (r.downloadItem != null) {
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => LocalComicDetailPage(comic: r.downloadItem!),
                ));
              } else if (r.favoriteItem != null) {
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) =>
                      LocalFavoritesPage(folderName: r.favoriteItem!.folder),
                ));
              }
            },
            borderRadius: BorderRadius.circular(12),
            child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(r.title,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w500),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis),
                      if (r.author.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(r.author,
                            style: TextStyle(
                                fontSize: 13,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant))
                      ],
                      const SizedBox(height: 6),
                      Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                              color: Theme.of(context)
                                  .colorScheme
                                  .secondaryContainer,
                              borderRadius: BorderRadius.circular(4)),
                          child: Text(r.sourceLabel,
                              style: TextStyle(
                                  fontSize: 11,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSecondaryContainer))),
                      if (r.tags.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(r.tags.take(3).join(' · '),
                            style: TextStyle(
                                fontSize: 11,
                                color: Theme.of(context).colorScheme.outline),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis)
                      ],
                    ]))));
  }
}

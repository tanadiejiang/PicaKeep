import 'dart:io';
import 'package:flutter/material.dart';

import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/components/comic_tile.dart';
import 'package:picakeep/foundation/app_page_route.dart';
import 'package:picakeep/foundation/image_loader/stream_image_provider.dart';
import 'package:picakeep/network/base_comic.dart';
import 'package:picakeep/network/online_image/online_image_manager.dart';

import 'online_search_logic.dart';

class OnlineSearchResultPage extends StatefulWidget {
  const OnlineSearchResultPage({
    super.key,
    required this.source,
    required this.keyword,
    required this.option,
  });

  final ComicSource source;
  final String keyword;
  final String option;

  @override
  State<OnlineSearchResultPage> createState() => _OnlineSearchResultPageState();
}

class _OnlineSearchResultPageState extends State<OnlineSearchResultPage> {
  final _logic = OnlineSearchLogic();
  final _scrollController = ScrollController();
  late final _keywordController =
      TextEditingController(text: widget.keyword);
  final _items = <BaseComic>[];

  late String _keyword = widget.keyword;
  int _page = 1;
  int? _maxPage;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScroll);
    _search();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_handleScroll);
    _scrollController.dispose();
    _keywordController.dispose();
    super.dispose();
  }

  void _handleScroll() {
    if (_loading || _items.isEmpty) return;
    if (_maxPage != null && _page >= _maxPage!) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 420) {
      _search(loadMore: true);
    }
  }

  Future<void> _search({bool loadMore = false}) async {
    if (_loading) return;
    final nextPage = loadMore ? _page + 1 : 1;
    setState(() {
      _loading = true;
      _error = null;
      if (!loadMore) {
        _items.clear();
        _maxPage = null;
      }
    });
    final res = await _logic.search(
      source: widget.source,
      keyword: _keyword,
      page: nextPage,
      option: widget.option,
    );
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

  void _submitSearch(String keyword) {
    final kw = keyword.trim();
    if (kw.isEmpty) return;
    _logic.addSearchHistory(kw);
    setState(() {
      _keyword = kw;
      _page = 1;
      _maxPage = null;
      _items.clear();
      _error = null;
    });
    _search();
  }

  void _openComic(BaseComic comic) {
    final builder = widget.source.comicPageBuilder;
    if (builder == null) return;
    Navigator.of(context).push(
      AppPageRoute(builder: (_) => builder(comic)),
    );
  }

  /// 构造封面 imageProvider。
  /// - 源未提供 [imageHeadersBuilder](picacg / jm)→ 走裸 `NetworkImage`,与改造前完全一致。
  /// - 钩子返回 `null` 或空 header → 同样回退 `NetworkImage`。
  /// - 钩子返回非空 header → 走带 header 的 `StreamImageProvider`,header 透传到图片请求。
  ImageProvider _coverProvider(BaseComic comic) {
    final builder = widget.source.imageHeadersBuilder;
    if (builder == null) {
      return NetworkImage(comic.cover);
    }
    final headers = builder(comic);
    if (headers == null || headers.isEmpty) {
      return NetworkImage(comic.cover);
    }
    return StreamImageProvider.withProgress(
      () => OnlineImageManager.instance.getImage(comic.cover, headers: headers),
      comic.cover,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Container(
          height: 40,
          margin: const EdgeInsets.only(right: 16),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(20),
          ),
          child: TextField(
            controller: _keywordController,
            textInputAction: TextInputAction.search,
            onSubmitted: _submitSearch,
            decoration: InputDecoration(
              hintText: '关键词',
              prefixIcon: const Icon(Icons.search, size: 20),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
              suffixIcon: IconButton(
                icon: const Icon(Icons.search, size: 20),
                onPressed: () => _submitSearch(_keywordController.text),
              ),
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _error!,
                      style: TextStyle(color: colorScheme.error),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => _search(),
                    icon: const Icon(Icons.refresh),
                    label: const Text('重试'),
                  ),
                ],
              ),
            ),
          Expanded(
            child: _items.isEmpty && !_loading && _error == null
                ? const Center(child: Text('无结果'))
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _items.length + (_loading ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index >= _items.length) {
                        return const Padding(
                          padding: EdgeInsets.all(16),
                          child: Center(child: CircularProgressIndicator()),
                        );
                      }
                      final comic = _items[index];
                      return SizedBox(
                        height: 164,
                        child: DownloadedComicTile(
                          name: comic.title,
                          author: comic.subTitle,
                          imagePath: File(''),
                          imageProvider: _coverProvider(comic),
                          type: null,
                          tag: comic.tags,
                          size: comic.description,
                          onTap: () => _openComic(comic),
                          onLongTap: () {},
                          onSecondaryTap: (_) {},
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

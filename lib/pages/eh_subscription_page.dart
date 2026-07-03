import 'dart:io';

import 'package:flutter/material.dart';
import 'package:picakeep/components/comic_tile.dart';
import 'package:picakeep/foundation/app_page_route.dart';
import 'package:picakeep/foundation/image_loader/stream_image_provider.dart';
import 'package:picakeep/network/eh_network/eh_main_network.dart';
import 'package:picakeep/network/eh_network/eh_models.dart';
import 'package:picakeep/network/online_image/online_image_manager.dart';
import 'package:picakeep/pages/online_comic/eh_comic_page_v2.dart';
import 'package:picakeep/pages/online_comic/eh_login_page.dart';
import 'package:picakeep/tools/translations.dart';

class EhSubscriptionPage extends StatelessWidget {
  const EhSubscriptionPage({super.key});

  void _showManageHint(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('EH订阅'.tl),
        content: Text('请在网页端管理订阅'.tl),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('确定'.tl),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('EH订阅'.tl),
        actions: [
          IconButton(
            onPressed: () => _showManageHint(context),
            icon: const Icon(Icons.more_vert),
          ),
        ],
      ),
      body: const EhSubscriptionComics(),
    );
  }
}

class EhSubscriptionComics extends StatefulWidget {
  const EhSubscriptionComics({super.key});

  @override
  State<EhSubscriptionComics> createState() => _EhSubscriptionComicsState();
}

class _EhSubscriptionComicsState extends State<EhSubscriptionComics> {
  final _items = <EhGalleryBrief>[];
  final _scrollController = ScrollController();

  String? _nextUrl;
  bool _initialLoading = true;
  bool _refreshing = false;
  bool _loadingMore = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScroll);
    _loadFirstPage();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_handleScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _handleScroll() {
    if (!_scrollController.hasClients || _nextUrl == null) {
      return;
    }
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 420) {
      _loadMore();
    }
  }

  Future<void> _loadFirstPage({bool keepOldItems = false}) async {
    if (!mounted) return;
    setState(() {
      _initialLoading = !keepOldItems;
      _refreshing = keepOldItems;
      _error = null;
      if (!keepOldItems) {
        _items.clear();
        _nextUrl = null;
      }
    });

    final res = await EhNetwork().getGalleries('${EhNetwork().ehBaseUrl}/watched');
    if (!mounted) return;

    if (res.error) {
      final message = res.errorMessageWithoutNull;
      setState(() {
        _initialLoading = false;
        _refreshing = false;
        _error = message;
      });
      if (keepOldItems && _items.isNotEmpty) {
        _showSnackBar('${'刷新失败'.tl}: $message');
      }
      return;
    }

    setState(() {
      _items
        ..clear()
        ..addAll(res.data.galleries);
      _nextUrl = res.data.next;
      _initialLoading = false;
      _refreshing = false;
      _error = null;
    });
  }

  Future<void> _refresh() async {
    await _loadFirstPage(keepOldItems: _items.isNotEmpty);
  }

  Future<void> _loadMore() async {
    final nextUrl = _nextUrl;
    if (nextUrl == null || _loadingMore || _initialLoading || _refreshing) {
      return;
    }
    setState(() {
      _loadingMore = true;
    });

    final res = await EhNetwork().getGalleries(nextUrl);
    if (!mounted) return;

    if (res.error) {
      setState(() {
        _loadingMore = false;
      });
      _showSnackBar('${'加载更多失败'.tl}: ${res.errorMessageWithoutNull}');
      return;
    }

    setState(() {
      _items.addAll(res.data.galleries);
      _nextUrl = res.data.next;
      _loadingMore = false;
    });
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  bool _isAuthError(String message) {
    return message.contains('未登录') ||
        message.contains('登录到期') ||
        message.contains('Cookie 已失效') ||
        message.contains('No permission') ||
        message.contains('bounce_login') ||
        message.contains('Redirect loop');
  }

  void _openLogin() {
    Navigator.of(context).push(
      AppPageRoute(builder: (_) => const EhLoginPage()),
    ).then((_) => _loadFirstPage());
  }

  void _openComic(EhGalleryBrief gallery) {
    Navigator.of(context).push(
      AppPageRoute(builder: (_) => EhentaiComicPageV2(gallery.link)),
    );
  }

  ImageProvider? _coverProvider(EhGalleryBrief gallery) {
    if (gallery.cover.isEmpty) {
      return null;
    }
    final headers = {
      'Cookie': EhNetwork().cookiesStr,
      'User-Agent': EhNetwork.ehUA,
      'Referer': EhNetwork().ehBaseUrl,
    };
    return StreamImageProvider.withProgress(
      () => OnlineImageManager.instance.getImage(gallery.cover, headers: headers),
      gallery.cover,
    );
  }

  Widget _buildErrorView(BuildContext context, String message) {
    final colorScheme = Theme.of(context).colorScheme;
    final authError = _isAuthError(message);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              authError ? Icons.lock_outline : Icons.error_outline,
              size: 56,
              color: authError ? colorScheme.primary : colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(
              authError ? '请先登录 E-Hentai'.tl : '加载失败'.tl,
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 12,
              runSpacing: 8,
              children: [
                if (authError)
                  FilledButton.icon(
                    onPressed: _openLogin,
                    icon: const Icon(Icons.login),
                    label: Text('去登录'.tl),
                  ),
                OutlinedButton.icon(
                  onPressed: () => _loadFirstPage(),
                  icon: const Icon(Icons.refresh),
                  label: Text('重试'.tl),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyView(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.subscriptions_outlined,
              size: 56,
              color: colorScheme.primary.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 16),
            Text(
              '暂无 EH订阅内容'.tl,
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              '请在网页端管理订阅'.tl,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList() {
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.builder(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _items.length + (_loadingMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= _items.length) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final gallery = _items[index];
          final pages = gallery.pages;
          return SizedBox(
            height: 164,
            child: DownloadedComicTile(
              name: gallery.title,
              author: gallery.uploader,
              imagePath: File(''),
              imageProvider: _coverProvider(gallery),
              type: gallery.type,
              tag: gallery.tags,
              size: pages == null ? gallery.time : '$pages pages',
              onTap: () => _openComic(gallery),
              onLongTap: () {},
              onSecondaryTap: (_) {},
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_initialLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final error = _error;
    if (error != null && _items.isEmpty) {
      return _buildErrorView(context, error);
    }

    if (_items.isEmpty) {
      return RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.62,
              child: _buildEmptyView(context),
            ),
          ],
        ),
      );
    }

    return _buildList();
  }
}

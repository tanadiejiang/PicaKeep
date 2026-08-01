import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';

import 'package:picakeep/foundation/app_page_route.dart';
import 'package:picakeep/foundation/download.dart';
import 'package:picakeep/foundation/history.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/online_download_manager.dart';
import 'package:picakeep/network/base_comic.dart';
import 'package:picakeep/network/picacg_network/picacg_network.dart';
import 'package:picakeep/pages/reader/comic_reading_page.dart';
import 'package:picakeep/tools/translations.dart';

import 'online_comic_detail_logic.dart';

class OnlineComicDetailPage extends StatefulWidget {
  const OnlineComicDetailPage({super.key, required this.comic});

  final BaseComic comic;

  @override
  State<OnlineComicDetailPage> createState() => _OnlineComicDetailPageState();
}

class _OnlineComicDetailPageState extends State<OnlineComicDetailPage> {
  late final OnlineComicDetailLogic _logic =
      OnlineComicDetailLogic(widget.comic);
  late Future<PicacgComicItem> _future = _load();

  bool _favoriteBusy = false;
  bool _downloadBusy = false;
  bool _localFavBusy = false;
  bool _downloaded = false;

  Future<PicacgComicItem> _load() async {
    final res = await _logic.loadPicacgDetail();
    if (res.error) throw res.errorMessageWithoutNull;
    final comic = res.data;
    // 异步查询不阻塞，加载完毕再更新状态
    _checkDownloaded([comic.id]);
    return comic;
  }

  Future<void> _toggleFavorite() async {
    if (_favoriteBusy) return;
    setState(() => _favoriteBusy = true);
    final res = await _logic.toggleFavorite();
    if (!mounted) return;
    setState(() => _favoriteBusy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(res.error ? res.errorMessageWithoutNull : '操作完成')),
    );
  }

  Future<void> _read(PicacgComicItem comic, {int ep = 1}) async {
    await History.ensureForLocalRead(
      target: comic.id,
      type: HistoryType.picacg,
      title: comic.title,
      subtitle: comic.subTitle,
      cover: comic.cover,
      ep: ep,
    );
    if (!mounted) return;
    Navigator.of(context).push(
      AppPageRoute(
        builder: (_) => ComicReadingPage(PicacgReadingData(comic: comic), 1, ep),
      ),
    );
  }

  Future<void> _download(PicacgComicItem comic) async {
    if (_downloadBusy) return;
    setState(() => _downloadBusy = true);
    final res = await OnlineDownloadManager.instance.enqueuePicacg(comic);
    if (!mounted) return;
    setState(() => _downloadBusy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(res.error ? res.errorMessageWithoutNull : '已加入下载队列'),
      ),
    );
  }

  void _checkDownloaded(List<String> candidates) {
    try {
      final localItem =
          LocalLibraryManager().findCachedByCandidates(candidates);
      final downloaded = localItem != null ||
          DownloadManager().resolveExistingId(candidates) != null;
      if (mounted) setState(() => _downloaded = downloaded);
    } catch (_) {}
  }

  Future<void> _localFavorite(PicacgComicItem comic) async {
    if (_localFavBusy) return;
    setState(() => _localFavBusy = true);
    try {
      final mgr = LocalFavoritesManager();
      var folders = mgr.folderNames;
      if (folders.isEmpty) {
        mgr.createFolder('默认收藏夹');
        folders = mgr.folderNames;
      }
      final folder = folders.first;
      mgr.addComic(
        folder,
        FavoriteItem(
          target: comic.id,
          name: comic.title,
          coverPath: comic.cover,
          author: comic.author,
          type: FavoriteType.picacg,
          tags: comic.tags,
        ),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已收藏到本地')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('收藏失败: $e')),
      );
    } finally {
      if (mounted) setState(() => _localFavBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PicacgComicItem>(
      future: _future,
      builder: (context, snapshot) {
        final comic = snapshot.data;
        return Scaffold(
          appBar: AppBar(
            title: Text(comic?.title ?? widget.comic.title),
          ),
          body: switch (snapshot.connectionState) {
            ConnectionState.done when snapshot.hasError => _ErrorView(
                error: snapshot.error.toString(),
                onRetry: () => setState(() => _future = _load()),
              ),
            ConnectionState.done when comic != null => _DetailView(
                comic: comic,
                favoriteBusy: _favoriteBusy,
                downloadBusy: _downloadBusy,
                localFavBusy: _localFavBusy,
                onRead: (ep) => _read(comic, ep: ep),
                onDownload: () => _download(comic),
                onFavorite: _toggleFavorite,
                onLocalFavorite: () => _localFavorite(comic),
                downloaded: _downloaded,
              ),
            _ => const Center(child: CircularProgressIndicator()),
          },
        );
      },
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.onRetry});

  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48),
            const SizedBox(height: 12),
            Text(error, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailView extends StatelessWidget {
  const _DetailView({
    required this.comic,
    required this.favoriteBusy,
    required this.downloadBusy,
    required this.localFavBusy,
    required this.onRead,
    required this.onDownload,
    required this.onFavorite,
    required this.onLocalFavorite,
    required this.downloaded,
  });

  final PicacgComicItem comic;
  final bool favoriteBusy;
  final bool downloadBusy;
  final bool localFavBusy;
  final ValueChanged<int> onRead;
  final VoidCallback onDownload;
  final VoidCallback onFavorite;
  final VoidCallback onLocalFavorite;
  final bool downloaded;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // ── 封面 + 信息区 ──
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: () {
                final heroTag = 'picacg-cover-${comic.id}';
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => _CoverPreviewPage(
                    imageProvider: NetworkImage(comic.cover),
                    heroTag: heroTag,
                  ),
                ));
              },
              child: Hero(
                tag: 'picacg-cover-${comic.id}',
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.network(
                    comic.cover,
                    width: 120,
                    height: 168,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      width: 120,
                      height: 168,
                      color: colorScheme.surfaceContainerHighest,
                      child: const Icon(Icons.broken_image_outlined),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(comic.title, style: textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(Icons.person_outline, size: 16),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          comic.author,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const Icon(Icons.menu_book_outlined, size: 16),
                      const SizedBox(width: 4),
                      Text(
                        '${comic.epsCount} 章 · ${comic.pagesCount} 页',
                        style: textTheme.bodySmall
                            ?.copyWith(color: colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),

        const SizedBox(height: 20),

        // ── 动作按钮区 ──
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _ActionButton(
              icon: Icons.menu_book_outlined,
              label: '阅读',
              onTap: () => onRead(1),
            ),
            _ActionButton(
              icon: downloaded ? Icons.download_done : Icons.download_outlined,
              label: downloaded ? '已下载' : '下载',
              busy: downloadBusy,
              onTap: downloaded ? () {} : onDownload,
            ),
            _ActionButton(
              icon: Icons.favorite_outline,
              label: '收藏',
              busy: favoriteBusy,
              onTap: onFavorite,
            ),
            _ActionButton(
              icon: Icons.bookmark_add_outlined,
              label: '本地收藏',
              busy: localFavBusy,
              onTap: onLocalFavorite,
            ),
          ],
        ),

        const SizedBox(height: 20),
        const Divider(),

        // ── 分类 + 标签区 ──
        if (comic.categories.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text('分类', style: textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final cat in comic.categories)
                _InfoChip(label: cat, color: colorScheme.primaryContainer,
                    textColor: colorScheme.onPrimaryContainer),
            ],
          ),
        ],

        if (comic.tags.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text('标签', style: textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final tag in comic.tags.take(30))
                _InfoChip(label: tag, color: colorScheme.secondaryContainer,
                    textColor: colorScheme.onSecondaryContainer),
            ],
          ),
        ],

        const SizedBox(height: 16),
        const Divider(),

        // ── 简介区 ──
        const SizedBox(height: 12),
        Text('简介', style: textTheme.titleSmall),
        const SizedBox(height: 8),
        Text(
          comic.description.isEmpty ? '暂无简介' : comic.description,
          style: textTheme.bodyMedium,
        ),

        const SizedBox(height: 16),
        const Divider(),

        // ── 章节区 ──
        const SizedBox(height: 12),
        Text('章节 (${comic.eps.length})', style: textTheme.titleSmall),
        const SizedBox(height: 4),
        for (var i = 0; i < comic.eps.length; i++)
          ListTile(
            dense: true,
            leading: Text(
              '${i + 1}',
              style: textTheme.bodySmall
                  ?.copyWith(color: colorScheme.onSurfaceVariant),
            ),
            title: Text(comic.eps[i]),
            trailing: const Icon(Icons.play_circle_outline, size: 20),
            onTap: () => onRead(i + 1),
          ),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: busy ? null : onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 80,
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            busy
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(icon, size: 22),
            const SizedBox(height: 6),
            Text(
              label,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({
    required this.label,
    required this.color,
    required this.textColor,
  });

  final String label;
  final Color color;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: textColor),
      ),
    );
  }
}

class _CoverPreviewPage extends StatelessWidget {
  const _CoverPreviewPage({
    required this.imageProvider,
    required this.heroTag,
  });

  final ImageProvider<Object> imageProvider;
  final String heroTag;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('图片'.tl),
      ),
      body: Hero(
        tag: heroTag,
        child: PhotoView(
          minScale: PhotoViewComputedScale.contained * 0.9,
          imageProvider: imageProvider,
          filterQuality: FilterQuality.medium,
          loadingBuilder: (context, event) {
            return const ColoredBox(
              color: Colors.black,
              child: Center(child: CircularProgressIndicator()),
            );
          },
          errorBuilder: (context, error, stackTrace, retry) {
            return ColoredBox(
              color: Colors.black,
              child: Center(
                child: IconButton(
                  tooltip: '重试'.tl,
                  color: Colors.white,
                  icon: const Icon(Icons.refresh),
                  onPressed: retry,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

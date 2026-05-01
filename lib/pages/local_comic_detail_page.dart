import 'package:flutter/material.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/download.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/tools/read_history_helper.dart';
import 'package:picakeep/tools/translations.dart';
import 'package:picakeep/tools/tags_translation.dart';
import 'package:picakeep/foundation/app.dart';
import 'reader/comic_reading_page.dart';

class LocalComicDetailPage extends StatefulWidget {
  final DownloadedItem comic;

  const LocalComicDetailPage({super.key, required this.comic});

  @override
  State<LocalComicDetailPage> createState() => _LocalComicDetailPageState();
}

class _LocalComicDetailPageState extends State<LocalComicDetailPage> {
  bool _reverseEpsOrder = false;

  String get _sourceLabel {
    switch (widget.comic.type) {
      case DownloadType.picacg:
        return '哔咔';
      case DownloadType.ehentai:
        return 'E-Hentai';
      case DownloadType.jm:
        return '禁漫';
      case DownloadType.hitomi:
        return 'Hitomi';
      case DownloadType.htmanga:
        return '绅士漫画';
      case DownloadType.nhentai:
        return 'NHentai';
      case DownloadType.copyManga:
        return '拷贝漫画';
      case DownloadType.komiic:
        return 'Komiic';
      default:
        return widget.comic.type.name;
    }
  }

  String _formatSize(double? size) {
    if (size == null) return '未知';
    if (size > 1024) return '${(size / 1024).toStringAsFixed(1)} GB';
    return '${size.toStringAsFixed(1)} MB';
  }

  String _formatTime(DateTime? time) {
    if (time == null) return '';
    return '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')} ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }

  Widget _buildCover() {
    try {
      final f = DownloadManager().getCover(widget.comic.id);
      if (f.existsSync()) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.file(
            f,
            fit: BoxFit.cover,
            width: 160,
            height: 220,
            errorBuilder: (_, __, ___) => _placeholderCover(),
          ),
        );
      }
    } catch (_) {}
    return _placeholderCover();
  }

  Widget _placeholderCover() {
    return Container(
      width: 160,
      height: 220,
      decoration: BoxDecoration(
        color: Colors.grey[300],
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Icon(Icons.image_not_supported, size: 48),
    );
  }

  Future<void> _onRead({int? ep, int? page}) async {
    await ensureHistoryBeforeRead(widget.comic);
    final hasEp = widget.comic.eps.isNotEmpty;
    final epsMap = <String, String>{};
    if (hasEp) {
      for (int i = 0; i < widget.comic.eps.length; i++) {
        epsMap['${i + 1}'] = widget.comic.eps[i];
      }
    }
    final readingData = LocalReadingData(
      title: widget.comic.name,
      id: widget.comic.id,
      downloadId: widget.comic.id,
      sourceKey: _extractSourceKey(widget.comic.id),
      hasEp: hasEp,
      comicType: comicTypeForDownloadType(widget.comic.type),
      eps: hasEp ? epsMap : null,
      favoriteType: _downloadTypeToFavoriteType(widget.comic.type),
    );
    readingData.downloadedEps = widget.comic.downloadedEps;

    await App.pushInner(() => ComicReadingPage(
          readingData,
          page ?? 1,
          ep ?? (hasEp ? 1 : 0),
        ));
  }

  void _onDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('确认删除'.tl),
        content: Text('确定要删除"${widget.comic.name}"吗？'),
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
    );
    if (confirmed == true) {
      await DownloadManager().delete([widget.comic.id]);
      if (mounted) Navigator.of(context).pop();
    }
  }

  void _onDeleteEpisode(int ep) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除章节'.tl),
        content: Text('确定要删除"${widget.comic.eps[ep]}"吗？'),
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
    );
    if (confirmed == true) {
      final error = await DownloadManager().deleteEpisode(widget.comic, ep);
      if (error != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error)),
        );
      }
      setState(() {});
    }
  }

  String? _getDescription() {
    try {
      final json = widget.comic.toJson();
      if (json['description'] != null && json['description'].toString().isNotEmpty) {
        return json['description'].toString();
      }
      if (json['comicItem']?['description'] != null) {
        return json['comicItem']['description'].toString();
      }
    } catch (_) {}
    return null;
  }

  String _translateTagIfNeeded(String tag) {
    if (App.locale.languageCode != 'zh') return tag;
    final translated = tagTranslations.values
        .expand((m) => m.entries)
        .firstWhere(
          (e) => e.key.toLowerCase() == tag.toLowerCase(),
          orElse: () => MapEntry(tag, [tag, '']),
        )
        .value
        .first;
    return translated;
  }

  @override
  Widget build(BuildContext context) {
    final comic = widget.comic;
    final description = _getDescription();
    final history = appdata.history.find(comic.id);

    return Scaffold(
      appBar: AppBar(
        title: Text(comic.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '删除下载'.tl,
            onPressed: _onDelete,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: cover + info
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildCover(),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        comic.name,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (comic.subTitle.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          comic.subTitle,
                          style: TextStyle(
                            fontSize: 15,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .primaryContainer
                              .withAlpha(120),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          _sourceLabel,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _formatSize(comic.comicSize),
                        style: TextStyle(
                          fontSize: 14,
                          color: Theme.of(context).colorScheme.outline,
                        ),
                      ),
                      Text(
                        _formatTime(comic.time),
                        style: TextStyle(
                          fontSize: 13,
                          color: Theme.of(context).colorScheme.outline,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),

            const SizedBox(height: 20),

            // Action buttons
            Row(
              children: [
                if (history != null && history.ep > 0) ...[
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => _onRead(ep: history.ep, page: history.page),
                      icon: const Icon(Icons.menu_book),
                      label: Text('继续阅读'.tl),
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _onRead(ep: comic.eps.isNotEmpty ? 1 : 0),
                    icon: const Icon(Icons.not_started_outlined),
                    label: Text('从头开始'.tl),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 20),

            // Tags
            if (comic.tags.isNotEmpty) ...[
              Text(
                '标签'.tl,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: comic.tags.map((t) {
                  final display = _translateTagIfNeeded(t);
                  return Chip(
                    label: Text(display, style: const TextStyle(fontSize: 12)),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    backgroundColor: Theme.of(context)
                        .colorScheme
                        .secondaryContainer
                        .withAlpha(120),
                  );
                }).toList(),
              ),
              const SizedBox(height: 20),
            ],

            // Description
            if (description != null && description.isNotEmpty) ...[
              Text(
                '简介'.tl,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                description,
                style: TextStyle(
                  fontSize: 14,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 20),
            ],

            // Chapters
            Row(
              children: [
                Text(
                  '章节'.tl,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Tooltip(
                  message: '排序'.tl,
                  child: IconButton(
                    icon: const Icon(Icons.swap_vert),
                    onPressed: () {
                      setState(() {
                        _reverseEpsOrder = !_reverseEpsOrder;
                      });
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                childAspectRatio: 2.5,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
              ),
              itemCount: comic.eps.length,
              itemBuilder: (ctx, i) {
                int index = _reverseEpsOrder ? comic.eps.length - i - 1 : i;
                final isDownloaded = comic.downloadedEps.contains(index);
                return GestureDetector(
                  onLongPress: isDownloaded ? () => _onDeleteEpisode(index) : null,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isDownloaded
                          ? Theme.of(context).colorScheme.primaryContainer
                          : Theme.of(context).colorScheme.surfaceContainerHighest,
                      foregroundColor: isDownloaded
                          ? Theme.of(context).colorScheme.onPrimaryContainer
                          : Theme.of(context).colorScheme.outline,
                      padding: EdgeInsets.zero,
                    ),
                    onPressed: isDownloaded
                        ? () => _onRead(ep: index)
                        : null,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (isDownloaded) ...[
                          Icon(
                            Icons.download_done,
                            size: 14,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(width: 4),
                        ],
                        Flexible(
                          child: Text(
                            comic.eps[index],
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: isDownloaded
                                  ? Theme.of(context).colorScheme.onPrimaryContainer
                                  : Theme.of(context).colorScheme.outline,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),

            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }
}

String _extractSourceKey(String id) {
  if (id.contains('copy_manga')) return 'copy_manga';
  if (id.contains('Komiic')) return 'Komiic';
  if (id.startsWith('jm')) return 'jm';
  if (id.startsWith('nhentai')) return 'nhentai';
  if (id.startsWith('hitomi')) return 'hitomi';
  if (id.startsWith('Ht')) return 'htmanga';
  if (RegExp(r'^\d+$').hasMatch(id)) return 'ehentai';
  return 'picacg';
}

FavoriteType _downloadTypeToFavoriteType(DownloadType type) {
  switch (type) {
    case DownloadType.picacg:
      return FavoriteType.picacg;
    case DownloadType.ehentai:
      return FavoriteType.ehentai;
    case DownloadType.jm:
      return FavoriteType.jm;
    case DownloadType.hitomi:
      return FavoriteType.hitomi;
    case DownloadType.htmanga:
      return FavoriteType.htManga;
    case DownloadType.nhentai:
      return FavoriteType.nhentai;
    case DownloadType.copyManga:
      return FavoriteType.copyManga;
    case DownloadType.komiic:
      return FavoriteType.komiic;
    default:
      return const FavoriteType(0);
  }
}

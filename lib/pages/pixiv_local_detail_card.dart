import 'dart:async';

import 'package:flutter/material.dart';
import 'package:picakeep/components/comic_tag_wrap.dart';
import 'package:picakeep/foundation/comic_tile_display_config.dart';
import 'package:picakeep/foundation/download_author_resolver.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/local_library_illust_view.dart';
import 'package:picakeep/foundation/pixiv_local_detail.dart';
import 'package:picakeep/foundation/remote_library_data_source.dart';

/// Provider-based cards preserve local/ZIP/privileged and remote access.
class PixivLocalDetailCard extends StatefulWidget {
  const PixivLocalDetailCard(
      {super.key,
      required this.item,
      required this.onTap,
      this.onFavorite,
      this.compact = false,
      this.tagConfig = WaterfallTagDisplayConfig.recommendDefaults});

  final DownloadedItem item;
  final VoidCallback onTap;
  final VoidCallback? onFavorite;
  final bool compact;
  final WaterfallTagDisplayConfig tagConfig;

  @override
  State<PixivLocalDetailCard> createState() => _PixivLocalDetailCardState();
}

class _PixivLocalDetailCardState extends State<PixivLocalDetailCard> {
  ImageProvider<Object>? _provider;

  @override
  void initState() {
    super.initState();
    final item = widget.item;
    if (item is RemoteLibraryComicItem) {
      _provider = item.coverImageProvider;
    } else if (item is LocalLibraryComicItem) {
      _provider = LocalLibraryManager().coverImageProviderForItem(item);
    } else {
      final path = PixivLocalIdentity.fromItem(item)?.record.cover;
      if (path?.isNotEmpty == true) {
        _provider = LocalLibraryManager().imageProviderForLocalPath(path!);
      }
    }
    if (_provider == null && item is LocalLibraryComicItem) {
      unawaited(_resolve(item));
    }
  }

  Future<void> _resolve(LocalLibraryComicItem item) async {
    final path = await LocalLibraryManager().resolveCoverPathForItem(item);
    if (mounted && path?.isNotEmpty == true) {
      setState(() =>
          _provider = LocalLibraryManager().imageProviderForLocalPath(path!));
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final identity = PixivLocalIdentity.fromItem(item);
    final record = identity?.record;
    final ratio = illustAspectRatioForSize(record?.width, record?.height);
    final pages = record?.pageCount;
    final author = record == null
        ? resolveDownloadedAuthors(item).join(', ')
        : resolveDownloadedAuthors(record).join(', ');
    final config = widget.tagConfig;
    final color = Theme.of(context).colorScheme;
    return InkWell(
      onTap: widget.onTap,
      borderRadius: BorderRadius.circular(4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: AspectRatio(
              aspectRatio: ratio,
              child: Stack(fit: StackFit.expand, children: [
                ColoredBox(
                  color: color.surfaceContainerHighest,
                  child: _provider == null
                      ? const Icon(Icons.image_not_supported_outlined)
                      : LayoutBuilder(
                          builder: (context, size) => Image(
                                image: ResizeImage.resizeIfNeeded(
                                    (size.maxWidth *
                                            MediaQuery.devicePixelRatioOf(
                                                context) *
                                            1.35)
                                        .ceil(),
                                    null,
                                    _provider!),
                                fit: BoxFit.contain,
                                errorBuilder: (_, __, ___) =>
                                    const Icon(Icons.broken_image_outlined),
                              )),
                ),
                if (pages != null && pages > 1)
                  Positioned(
                      left: 4,
                      top: 4,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(4)),
                        child: Padding(
                            padding: const EdgeInsets.all(4),
                            child: Text('$pages',
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 12))),
                      )),
                if (widget.onFavorite != null)
                  Positioned(
                      right: 0,
                      bottom: 0,
                      child: IconButton(
                        tooltip: '本地收藏',
                        onPressed: widget.onFavorite,
                        iconSize: 22,
                        icon: Icon(
                            pixivLocalFavoriteFolders(item).isNotEmpty
                                ? Icons.favorite
                                : Icons.favorite_border,
                            color: const Color(0xE6E0245E)),
                      )),
              ])),
        ),
        if (!widget.compact) ...[
          const SizedBox(height: 4),
          Text(item.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(fontWeight: FontWeight.w600)),
          if (author.isNotEmpty)
            Text(author,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: color.onSurfaceVariant)),
          if (config.showTags)
            ComicTagWrap(
                tags: item.tags,
                maxRows: config.maxTagRows,
                reserveRows: config.maxTagRows != null,
                fontSize: tagChipBaseFontSizeFor(config.maxTagRows)),
        ],
      ]),
    );
  }
}

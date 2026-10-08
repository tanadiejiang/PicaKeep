/// 在线作品的**瀑布流卡片**（36 号）：与图集页插画卡片同一套视觉。
///
/// ## 为什么新建而不是复用 `IllustCard`
///
/// `IllustCard` 绑定的是**本地**条目（`IllustLibraryEntry` → `LocalLibraryComicItem`），
/// 它的信息区还支持用户自定义字段模板；而这里的数据是**在线** `BaseComic`
/// （封面走网络、没有本地路径、没有可配置字段）。硬套会为了一个"看起来一样"
/// 而把本地侧的模型渗进在线链路。
///
/// 所以这里只**复用视觉常量**（[illustCardGap]）与
/// 页数文案函数（`illustCardInfoPageText`），排版数值与插画卡片保持一致 ——
/// 用户看到的是同一个设计语言，而不是两套"长得像"的东西。
library;

import 'package:flutter/material.dart';
import 'package:picakeep/components/pixiv_bookmark_button.dart';
import 'package:picakeep/components/comic_tag_wrap.dart';
import 'package:picakeep/foundation/comic_tile_display_config.dart';

import 'package:picakeep/foundation/illust_card_info_config.dart'
    show illustCardInfoPageText;
import 'package:picakeep/foundation/local_library_illust_view.dart'
    show illustAspectRatioForSize;
import 'package:picakeep/pages/local_library_illust_card.dart'
    show illustCardGap;

import 'online_comic_list_item.dart' show onlineCoverProvider;

/// 解码宽度的冗余系数（与 `IllustCard` 同口径）。
const double _decodeQualityScale = 1.35;
const double onlineWaterfallImageRadius = 8;

/// 在线作品的瀑布流卡片：**近无边框大图 + 底部标题/作者/页数**。
///
/// [aspectRatio] 由调用方按作品的 `width/height` 算好传进来（缺失时走
/// [illustAspectRatioForSize] 的 3:4 占位）—— 这样瀑布流在图片加载完之前
/// 就能排好版，不会出现"先按占位比例渲染、图到位后再跳一下"。
class OnlineWaterfallCard extends StatelessWidget {
  const OnlineWaterfallCard({
    super.key,
    required this.title,
    required this.cover,
    this.fallbackCover,
    required this.imageHeaders,
    required this.onTap,
    this.author = '',
    this.pageCount = 0,
    this.width,
    this.height,
    this.tags = const <String>[],
    this.tagConfig = WaterfallTagDisplayConfig.defaults,
    this.authorAvatarUrl = '',
    this.showAuthorAvatar = false,
    this.onAuthorTap,
    this.isFavorited = false,
    this.favoriteStateKnown = true,
    this.onToggleFavorite,
    this.favoriteEnabled = true,
    this.favoriteBusy = false,
    this.favoriteStyle = WaterfallFavoriteStyle.defaults,
    this.pixivBookmarkAnimations = false,
    this.favoriteIdentity,
    this.favoriteVisualEpoch,
    this.favoriteFeedbackCurrent = true,
    this.favoriteEvent,
  });

  final String title;

  /// 封面 URL。**调用方应已用 `pixivProportionalThumbUrl` 换成保持比例的版本**，
  /// 否则方图会被 `contain` 缩在格子中间（四周留白）。
  final String cover;

  /// Original API thumbnail, tried once if a derived proportional URL fails.
  final String? fallbackCover;

  /// 防盗链头（Pixiv 的 `i.pximg.net` 缺 Referer 会直接 403）。
  final Map<String, String> imageHeaders;

  final VoidCallback onTap;
  final String author;

  /// 页数；`<= 1` 或 `0` 时**不显示**（与图集页卡片同一规则）。
  final int pageCount;

  /// 原图宽高；用于算真实比例（缺失时按 3:4 占位）。
  final int? width;
  final int? height;
  final List<String> tags;
  final WaterfallTagDisplayConfig tagConfig;
  final String authorAvatarUrl;
  final bool showAuthorAvatar;
  final VoidCallback? onAuthorTap;
  final bool isFavorited;
  final bool favoriteStateKnown;
  final VoidCallback? onToggleFavorite;
  final bool favoriteEnabled;
  final bool favoriteBusy;
  final WaterfallFavoriteStyle favoriteStyle;
  final bool pixivBookmarkAnimations;
  final Object? favoriteIdentity;
  final Object? favoriteVisualEpoch;
  final bool favoriteFeedbackCurrent;
  final PixivBookmarkEvent? favoriteEvent;

  /// 格子比例（恒为正有限数）。
  double get aspectRatio => illustAspectRatioForSize(width, height);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pagesText = illustCardInfoPageText(pageCount);
    return Padding(
      padding: const EdgeInsets.all(illustCardGap),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _imageArea(context),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (title.trim().isNotEmpty)
                    Text(
                      title.trim(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        height: 1.2,
                      ),
                    ),
                  // 作者与页数合并成一行（用 `_` 连接，与下载产物名的记号一致）：
                  // 在线列表的宽度只有半屏，两行文字会把卡片撑得比图还高。
                  if (showAuthorAvatar)
                    _authorRow(context, pagesText)
                  else if (author.trim().isNotEmpty || pagesText.isNotEmpty)
                    Text(
                      <String>[
                        if (author.trim().isNotEmpty) author.trim(),
                        if (pagesText.isNotEmpty) pagesText,
                      ].join('_'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        height: 1.2,
                      ),
                    ),
                  if (tagConfig.showTags)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: ComicTagWrap(
                        tags: tags
                            .map((tag) => tag.trim())
                            .where((tag) => tag.isNotEmpty)
                            .toSet()
                            .toList(),
                        maxRows: tagConfig.maxTagRows,
                        reserveRows: tagConfig.maxTagRows != null,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _imageArea(BuildContext context) {
    final radius = BorderRadius.circular(onlineWaterfallImageRadius);
    final stack = Stack(
      fit: StackFit.expand,
      clipBehavior: pixivBookmarkAnimations ? Clip.none : Clip.hardEdge,
      children: [
        if (pixivBookmarkAnimations)
          ClipRRect(borderRadius: radius, child: _buildImage(context))
        else
          _buildImage(context),
        if (onToggleFavorite != null)
          Positioned(right: 0, bottom: 0, child: _favoriteButton(context)),
      ],
    );
    return AspectRatio(
      aspectRatio: aspectRatio,
      child: pixivBookmarkAnimations
          ? stack
          : ClipRRect(borderRadius: radius, child: stack),
    );
  }

  Widget _favoriteButton(BuildContext context) {
    if (pixivBookmarkAnimations) {
      return PixivBookmarkButton(
        key: const ValueKey('waterfall-favorite'),
        isBookmarked: isFavorited,
        stateKnown: favoriteStateKnown,
        busy: favoriteBusy,
        enabled: favoriteEnabled,
        active: favoriteFeedbackCurrent,
        identity: favoriteIdentity,
        visualEpoch: favoriteVisualEpoch,
        event: favoriteEvent,
        onPressed: onToggleFavorite,
        activeColor: favoriteStyle.favoriteColor(context),
        inactiveColor: favoriteStyle.inactiveColor,
        shadows: [
          Shadow(color: Colors.black.withValues(alpha: .6), blurRadius: 2)
        ],
      );
    }
    return _staticFavoriteButton(context);
  }

  Widget _staticFavoriteButton(BuildContext context) => Semantics(
        key: const ValueKey('waterfall-favorite'),
        container: true,
        button: true,
        enabled: favoriteEnabled && !favoriteBusy,
        toggled: favoriteStateKnown ? isFavorited : null,
        label: favoriteBusy
            ? favoriteStateKnown
                ? '正在更新收藏'
                : '正在读取收藏状态'
            : !favoriteStateKnown
                ? '切换平台收藏'
                : isFavorited
                    ? '取消平台收藏'
                    : '加入平台收藏',
        onTap: favoriteBusy || !favoriteEnabled ? null : onToggleFavorite,
        child: ExcludeSemantics(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            // A disabled heart still consumes taps so they cannot open details.
            onTap: favoriteBusy || !favoriteEnabled ? () {} : onToggleFavorite,
            child: SizedBox(
              width: 48,
              height: 48,
              child: Icon(
                favoriteBusy || isFavorited
                    ? Icons.favorite
                    : Icons.favorite_border,
                key: favoriteBusy
                    ? const ValueKey('waterfall-favorite-progress')
                    : null,
                size: 22,
                color: favoriteBusy
                    ? favoriteStyle.favoriteColor(context).withValues(alpha: .5)
                    : isFavorited
                        ? favoriteStyle.favoriteColor(context)
                        : favoriteStyle.inactiveColor,
                shadows: [
                  Shadow(
                    color:
                        Colors.black.withValues(alpha: favoriteBusy ? .3 : .6),
                    blurRadius: 2,
                  ),
                ],
              ),
            ),
          ),
        ),
      );

  Widget _authorRow(BuildContext context, String pagesText) {
    final name = author.trim().isEmpty ? '未知作者' : author.trim();
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          ExcludeSemantics(child: _avatar(context, name)),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    height: 1.2,
                  ),
            ),
          ),
          if (pagesText.isNotEmpty)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 4),
              child: Text(pagesText,
                  style: Theme.of(context).textTheme.labelSmall),
            ),
        ],
      ),
    );
    if (onAuthorTap == null) return row;
    return Semantics(
      key: const ValueKey('waterfall-author'),
      label: '查看作者 $name',
      button: true,
      onTap: onAuthorTap,
      child: ExcludeSemantics(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onAuthorTap,
          child: row,
        ),
      ),
    );
  }

  Widget _avatar(BuildContext context, String name) {
    final fallback = ColoredBox(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Center(
        child: Text(name.characters.first,
            style: Theme.of(context).textTheme.labelSmall),
      ),
    );
    final url = authorAvatarUrl.trim();
    final decodeSize =
        (20 * MediaQuery.devicePixelRatioOf(context)).round().clamp(20, 60);
    return SizedBox(
      key: const ValueKey('waterfall-avatar'),
      width: 20,
      height: 20,
      child: ClipOval(
        child: url.isEmpty
            ? fallback
            : Image(
                image: ResizeImage.resizeIfNeeded(
                  decodeSize,
                  decodeSize,
                  onlineCoverProvider(url: url, headers: imageHeaders),
                ),
                fit: BoxFit.cover,
                frameBuilder: (context, child, frame, synchronous) =>
                    frame != null || synchronous ? child : fallback,
                errorBuilder: (context, error, stackTrace) => fallback,
              ),
      ),
    );
  }

  Widget _buildImage(BuildContext context) {
    if (cover.trim().isEmpty) {
      return _placeholder(context);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final devicePixelRatio =
            MediaQuery.of(context).devicePixelRatio.clamp(1.0, 3.0).toDouble();
        final width = constraints.maxWidth;
        final cacheWidth = width.isFinite && width > 0
            ? (width * devicePixelRatio * _decodeQualityScale).round()
            : null;
        Widget imageFor(String url, {bool allowFallback = false}) {
          final provider = onlineCoverProvider(url: url, headers: imageHeaders);
          return Image(
            image: cacheWidth == null
                ? provider
                : ResizeImage.resizeIfNeeded(cacheWidth, null, provider),
            fit: BoxFit.contain,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
            frameBuilder: (context, child, frame, wasSynchronouslyLoaded) =>
                frame != null || wasSynchronouslyLoaded
                    ? child
                    : _placeholder(context, loading: true),
            errorBuilder: (context, error, stackTrace) {
              final fallback = fallbackCover?.trim() ?? '';
              return allowFallback && fallback.isNotEmpty && fallback != url
                  ? imageFor(fallback)
                  : _placeholder(context);
            },
          );
        }

        return imageFor(cover, allowFallback: true);
      },
    );
  }

  Widget _placeholder(BuildContext context, {bool loading = false}) {
    final colorScheme = Theme.of(context).colorScheme;
    return Semantics(
      label: loading ? '正在加载封面' : '封面加载失败',
      child: ColoredBox(
        color: colorScheme.secondaryContainer,
        child: Icon(
          loading ? Icons.image_outlined : Icons.image_not_supported_outlined,
          size: 22,
          color: colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }
}

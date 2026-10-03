/// 在线作品的**瀑布流卡片**（36 号）：与图集页插画卡片同一套视觉。
///
/// ## 为什么新建而不是复用 `IllustCard`
///
/// `IllustCard` 绑定的是**本地**条目（`IllustLibraryEntry` → `LocalLibraryComicItem`），
/// 它的信息区还支持用户自定义字段模板；而这里的数据是**在线** `BaseComic`
/// （封面走网络、没有本地路径、没有可配置字段）。硬套会为了一个"看起来一样"
/// 而把本地侧的模型渗进在线链路。
///
/// 所以这里只**复用视觉常量**（[illustCardGap] / [illustCardImageRadius]）与
/// 页数文案函数（`illustCardInfoPageText`），排版数值与插画卡片保持一致 ——
/// 用户看到的是同一个设计语言，而不是两套"长得像"的东西。
library;

import 'package:flutter/material.dart';

import 'package:picakeep/foundation/illust_card_info_config.dart'
    show illustCardInfoPageText;
import 'package:picakeep/foundation/local_library_illust_view.dart'
    show illustAspectRatioForSize;
import 'package:picakeep/pages/local_library_illust_card.dart'
    show illustCardGap, illustCardImageRadius;

import 'online_comic_list_item.dart' show onlineCoverProvider;

/// 解码宽度的冗余系数（与 `IllustCard` 同口径）。
const double _decodeQualityScale = 1.35;

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
    required this.imageHeaders,
    required this.onTap,
    this.author = '',
    this.pageCount = 0,
    this.width,
    this.height,
  });

  final String title;

  /// 封面 URL。**调用方应已用 `pixivProportionalThumbUrl` 换成保持比例的版本**，
  /// 否则方图会被 `contain` 缩在格子中间（四周留白）。
  final String cover;

  /// 防盗链头（Pixiv 的 `i.pximg.net` 缺 Referer 会直接 403）。
  final Map<String, String> imageHeaders;

  final VoidCallback onTap;
  final String author;

  /// 页数；`<= 1` 或 `0` 时**不显示**（与图集页卡片同一规则）。
  final int pageCount;

  /// 原图宽高；用于算真实比例（缺失时按 3:4 占位）。
  final int? width;
  final int? height;

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
            ClipRRect(
              borderRadius: BorderRadius.circular(illustCardImageRadius),
              child: AspectRatio(
                aspectRatio: aspectRatio,
                child: _buildImage(context),
              ),
            ),
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
                  if (author.trim().isNotEmpty || pagesText.isNotEmpty)
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
                ],
              ),
            ),
          ],
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
        final provider = onlineCoverProvider(
          url: cover,
          headers: imageHeaders,
        );
        return Image(
          image: cacheWidth == null
              ? provider
              : ResizeImage.resizeIfNeeded(cacheWidth, null, provider),
          fit: BoxFit.contain,
          gaplessPlayback: true,
          filterQuality: FilterQuality.medium,
          errorBuilder: (context, error, stackTrace) => _placeholder(context),
        );
      },
    );
  }

  Widget _placeholder(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: colorScheme.secondaryContainer,
      child: Icon(
        Icons.image_not_supported_outlined,
        size: 22,
        color: colorScheme.onSecondaryContainer,
      ),
    );
  }
}

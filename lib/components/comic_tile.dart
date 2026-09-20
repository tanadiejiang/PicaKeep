import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/history.dart';
import 'package:picakeep/foundation/local_favorites.dart';

class DownloadedComicTile extends StatelessWidget {
  const DownloadedComicTile({
    super.key,
    required this.name,
    required this.author,
    required this.imagePath,
    this.imageProvider,
    this.readingHistoryOverride,
    this.isFavoriteOverride,
    this.optimizeCoverDecode = false,
    this.maxTagRows,
    required this.type,
    required this.tag,
    required this.size,
    required this.onTap,
    required this.onLongTap,
    required this.onSecondaryTap,
  }) : assert(maxTagRows == null || maxTagRows > 0);

  final String size;
  final File imagePath;
  final ImageProvider<Object>? imageProvider;
  final History? readingHistoryOverride;
  final bool? isFavoriteOverride;
  final bool optimizeCoverDecode;

  /// Limits the number of visual tag rows when set. Other callers keep the
  /// historical unrestricted tag layout by leaving this null.
  final int? maxTagRows;
  final String author;
  final String name;
  final void Function() onTap;
  final void Function() onLongTap;
  final void Function(TapDownDetails details) onSecondaryTap;
  final String? type;
  final List<String> tag;

  List<String>? get tags => tag;

  String get description => size;

  String get subTitle => author;

  String get title => name;

  bool get enableLongPressed => true;

  String? get badge => type;

  String? get comicID => null;

  bool get showFavorite => appdata.settings[72] == '1';

  bool get showReadingPosition => appdata.settings[73] == '1';

  History? get readingHistory => readingHistoryOverride ??
      (comicID == null ? null : HistoryManager().findSync(comicID!));

  @override
  Widget build(BuildContext context) {
    var typeSetting = appdata.settings[44].split(',').first;
    Widget child;
    bool detailedMode;
    if (typeSetting == "0" || typeSetting == "3") {
      detailedMode = true;
      child = _buildDetailedMode(context);
    } else {
      detailedMode = false;
      child = _buildBriefMode(context);
    }

    final isFavorite = showFavorite ? _resolveFavoriteState() : false;

    if (!isFavorite) {
      return child;
    }

    return Stack(
      children: [
        Positioned.fill(child: child),
        Positioned(
          left: detailedMode ? 16 : 6,
          top: 8,
          child: Container(
            height: 24,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(4)),
            clipBehavior: Clip.antiAlias,
            child: Row(children: [
              Container(
                height: 24,
                width: 24,
                color: Colors.green,
                child: const Icon(Icons.bookmark_rounded,
                    size: 16, color: Colors.white),
              ),
            ]),
          ),
        )
      ],
    );
  }

  bool _resolveFavoriteState() {
    final override = isFavoriteOverride;
    if (override != null) {
      return override;
    }
    final target = comicID;
    return target == null ? _checkFavorite() : LocalFavoritesManager().isExist(target);
  }

  bool _checkFavorite() {
    try {
      final fav = LocalFavoritesManager();
      final types = [
        FavoriteType.picacg,
        FavoriteType.ehentai,
        FavoriteType.jm,
        FavoriteType.hitomi,
        FavoriteType.htManga,
        FavoriteType.nhentai,
        FavoriteType.copyManga,
        FavoriteType.komiic,
      ];
      for (final folder in fav.folderNames) {
        for (final ft in types) {
          if (fav.comicExists(folder, name, ft.key)) {
            return true;
          }
        }
      }
    } catch (_) {}
    return false;
  }

  Widget _buildDetailedMode(BuildContext context) {
    return LayoutBuilder(builder: (context, constrains) {
      final height = constrains.maxHeight - 16;
      return InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        onLongPress: enableLongPressed ? onLongTap : null,
        onSecondaryTapDown: onSecondaryTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 24, 8),
          child: Row(
            children: [
              Container(
                width: height * 0.68,
                height: double.infinity,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                clipBehavior: Clip.antiAlias,
                child: _buildImage(context),
              ),
              SizedBox.fromSize(size: const Size(16, 5)),
              Expanded(
                child: _ComicDescription(
                  title: title.replaceAll("\n", ""),
                  user: subTitle,
                  description: description,
                  subDescription: _buildReadingPosition(),
                  badge: badge,
                  tags: tags,
                  maxLines: 2,
                  maxTagRows: maxTagRows,
                ),
              ),
            ],
          ),
        ),
      );
    });
  }

  Widget _buildBriefMode(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        elevation: 1,
        child: Stack(
          children: [
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                clipBehavior: Clip.antiAlias,
                child: _buildImage(context),
              ),
            ),
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.3),
                      Colors.black.withValues(alpha: 0.5),
                    ],
                  ),
                  borderRadius: const BorderRadius.only(
                    bottomLeft: Radius.circular(8),
                    bottomRight: Radius.circular(8),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                  child: Text(
                    title.replaceAll("\n", ""),
                    style: const TextStyle(
                      fontWeight: FontWeight.w500,
                      fontSize: 14.0,
                      color: Colors.white,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: onTap,
                  onLongPress: enableLongPressed ? onLongTap : null,
                  onSecondaryTapDown: onSecondaryTap,
                  borderRadius: BorderRadius.circular(8),
                  child: const SizedBox.expand(),
                ),
              ),
            )
          ],
        ),
      ),
    );
  }

  Widget _buildReadingPosition() {
    if (!showReadingPosition) {
      return const SizedBox.shrink();
    }
    final history = readingHistory;
    if (history == null) {
      return const SizedBox.shrink();
    }

    final page = history.page <= 0 ? 1 : history.page;
    final ep = history.ep <= 0 ? null : history.ep;
    final text = ep == null ? 'P$page' : 'E$ep · P$page';
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          color: Colors.orange.shade700,
          fontWeight: FontWeight.w500,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _buildImage(BuildContext context) {
    final provider = imageProvider;
    final resolvedProvider = provider ??
        (imagePath.path.isEmpty ? null : FileImage(imagePath) as ImageProvider<Object>);
    if (resolvedProvider == null) {
      return const Center(child: Icon(Icons.image_not_supported));
    }
    if (!optimizeCoverDecode) {
      return Image(
        image: resolvedProvider,
        fit: BoxFit.cover,
        height: double.infinity,
        gaplessPlayback: false,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, __, ___) =>
            const Center(child: Icon(Icons.image_not_supported)),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final devicePixelRatio =
            MediaQuery.of(context).devicePixelRatio.clamp(1.0, 3.0).toDouble();
        const qualityScale = 1.35;
        final cacheWidth = constraints.maxWidth.isFinite
            ? (constraints.maxWidth * devicePixelRatio * qualityScale).round()
            : null;
        final displayProvider = ResizeImage.resizeIfNeeded(
          cacheWidth,
          null,
          resolvedProvider,
        );
        return Image(
          image: displayProvider,
          fit: BoxFit.cover,
          height: double.infinity,
          gaplessPlayback: true,
          filterQuality: FilterQuality.medium,
          errorBuilder: (_, __, ___) =>
              const Center(child: Icon(Icons.image_not_supported)),
        );
      },
    );
  }
}

class _ComicDescription extends StatelessWidget {
  const _ComicDescription({
    required this.title,
    required this.user,
    required this.description,
    this.subDescription,
    this.badge,
    this.maxLines = 2,
    this.maxTagRows,
    this.tags,
  });

  final String title;
  final String user;
  final String description;
  final Widget? subDescription;
  final String? badge;
  final List<String>? tags;
  final int maxLines;
  final int? maxTagRows;

  @override
  Widget build(BuildContext context) {
    final visibleTags = tags
        ?.map((element) => element.trim())
        .where((element) => element.isNotEmpty)
        .toList(growable: false);
    if (maxTagRows != null) {
      return _buildLimitedLayout(context, visibleTags);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14.0),
          maxLines: maxLines,
          overflow: TextOverflow.ellipsis,
        ),
        if (user.isNotEmpty)
          Text(user, style: const TextStyle(fontSize: 10.0), maxLines: 1),
        const SizedBox(height: 4),
        if (visibleTags != null)
          // Flexible 而非 Expanded：Expanded 会抢占全部剩余高度，把后面的
          // SizedBox(2) + footer 顶出卡片。列表用 childMainAxisExtent 定死
          // 卡片高度，超出的部分会落到卡片外。
          // 本分支是网络收藏/搜索结果页实际走的路径（它们不传 maxTagRows）。
          Flexible(
            child: Wrap(
              runAlignment: WrapAlignment.start,
              clipBehavior: Clip.antiAlias,
              crossAxisAlignment: WrapCrossAlignment.end,
              children: [
                for (var s in visibleTags)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(0, 0, 4, 3),
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(3, 1, 3, 3),
                      decoration: BoxDecoration(
                        color: s == "Unavailable"
                            ? Theme.of(context).colorScheme.errorContainer
                            : Theme.of(context).colorScheme.secondaryContainer,
                        borderRadius:
                            const BorderRadius.all(Radius.circular(8)),
                      ),
                      child: Text(s, style: const TextStyle(fontSize: 12)),
                    ),
                  )
              ],
            ),
          ),
        const SizedBox(height: 2),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (subDescription != null) subDescription!,
                  Text(description, style: const TextStyle(fontSize: 12.0)),
                ],
              ),
            ),
            if (badge != null && badge!.isNotEmpty)
              Container(
                padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.tertiaryContainer,
                  borderRadius: const BorderRadius.all(Radius.circular(8)),
                ),
                child: Text(badge!, style: const TextStyle(fontSize: 12)),
              )
          ],
        ),
      ],
    );
  }

  Widget _buildLimitedLayout(
    BuildContext context,
    List<String>? visibleTags,
  ) {
    final hasTags = visibleTags != null && visibleTags.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Flexible(
          fit: FlexFit.loose,
          child: Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14.0),
            maxLines: maxLines,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (user.isNotEmpty)
          Text(
            user,
            style: const TextStyle(fontSize: 10.0),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        if (hasTags) ...[
          const SizedBox(height: 4),
          // Flexible 而非 Expanded：Expanded 会抢占全部剩余高度，把后面的
          // SizedBox(2) + footer 挤出固定卡片高度（列表用 childMainAxisExtent
          // 定死 164dp，超出部分落在卡片外）。
          //
          // 这里**不能**再套 Align：Align 未设 heightFactor 时会撑满父级给的
          // 高度，等于把 Flexible 的收缩效果抵消掉（实测与 Expanded 完全同高）。
          // 直接给 _LimitedTagWrap，它内部的 Wrap 自然会贴内容高度。
          // 高度限制仍由 maxRows 与约束共同决定（maxHeight 有界时继续参与裁剪）。
          Flexible(
            child: _LimitedTagWrap(
              tags: visibleTags,
              maxRows: maxTagRows!,
            ),
          ),
        ],
        const SizedBox(height: 2),
        _buildLimitedFooter(context),
      ],
    );
  }

  Widget _buildLimitedFooter(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (subDescription != null) subDescription!,
              Text(
                description,
                style: const TextStyle(fontSize: 12.0),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        if (badge != null && badge!.isNotEmpty)
          Container(
            padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.tertiaryContainer,
              borderRadius: const BorderRadius.all(Radius.circular(8)),
            ),
            child: Text(badge!, style: const TextStyle(fontSize: 12)),
          )
      ],
    );
  }
}

const _tagChipHorizontalPadding = 3.0;
const _tagChipTopPadding = 1.0;
const _tagChipBottomPadding = 3.0;
const _tagChipTrailingGap = 4.0;
const _tagChipRunGap = 3.0;
const _tagChipTextStyle = TextStyle(fontSize: 12);

class _LimitedTagWrap extends StatelessWidget {
  const _LimitedTagWrap({
    required this.tags,
    required this.maxRows,
  });

  final List<String> tags;
  final int maxRows;

  @override
  Widget build(BuildContext context) {
    final textStyle =
        DefaultTextStyle.of(context).style.merge(_tagChipTextStyle);
    return LayoutBuilder(
      builder: (context, constraints) {
        final visibleTags = _visibleTagPrefix(
          tags: tags,
          maxRows: maxRows,
          maxWidth: constraints.maxWidth,
          maxHeight: constraints.maxHeight,
          textStyle: textStyle,
          textScaler: MediaQuery.textScalerOf(context),
          textDirection: Directionality.of(context),
          locale: Localizations.maybeLocaleOf(context),
        );
        if (visibleTags.isEmpty) {
          return const SizedBox.shrink();
        }

        final maxChipWidth =
            math.max(0.0, constraints.maxWidth - _tagChipTrailingGap);
        return Wrap(
          runAlignment: WrapAlignment.start,
          crossAxisAlignment: WrapCrossAlignment.end,
          children: [
            for (final tag in visibleTags)
              _LimitedTagChip(
                tag: tag,
                maxWidth: maxChipWidth,
              ),
          ],
        );
      },
    );
  }
}

class _LimitedTagChip extends StatelessWidget {
  const _LimitedTagChip({
    required this.tag,
    required this.maxWidth,
  });

  final String tag;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding:
          const EdgeInsets.fromLTRB(0, 0, _tagChipTrailingGap, _tagChipRunGap),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Container(
          padding: const EdgeInsets.fromLTRB(
            _tagChipHorizontalPadding,
            _tagChipTopPadding,
            _tagChipHorizontalPadding,
            _tagChipBottomPadding,
          ),
          decoration: BoxDecoration(
            color: tag == "Unavailable"
                ? Theme.of(context).colorScheme.errorContainer
                : Theme.of(context).colorScheme.secondaryContainer,
            borderRadius: const BorderRadius.all(Radius.circular(8)),
          ),
          child: Text(
            tag,
            style: _tagChipTextStyle,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}

List<String> _visibleTagPrefix({
  required List<String> tags,
  required int maxRows,
  required double maxWidth,
  required double maxHeight,
  required TextStyle textStyle,
  required TextScaler textScaler,
  required TextDirection textDirection,
  required Locale? locale,
}) {
  if (maxRows <= 0 ||
      !maxWidth.isFinite ||
      maxWidth <= _tagChipTrailingGap ||
      maxHeight <= 0) {
    return const <String>[];
  }

  final maxChipWidth = maxWidth - _tagChipTrailingGap;
  final maxTextWidth = math.max(
    0.0,
    maxChipWidth - _tagChipHorizontalPadding * 2,
  );
  final visibleTags = <String>[];
  var completedRowsHeight = 0.0;
  var currentRowWidth = 0.0;
  var currentRowHeight = 0.0;
  var row = 0;

  for (final tag in tags) {
    final metrics = _measureTagChip(
      tag,
      textStyle: textStyle,
      textScaler: textScaler,
      textDirection: textDirection,
      locale: locale,
      maxChipWidth: maxChipWidth,
      maxTextWidth: maxTextWidth,
    );
    final startsNewRow =
        currentRowWidth > 0 && currentRowWidth + metrics.width > maxWidth;
    if (startsNewRow) {
      completedRowsHeight += currentRowHeight;
      currentRowWidth = 0;
      currentRowHeight = 0;
      row++;
    }
    if (row >= maxRows) {
      break;
    }

    final candidateRowHeight = math.max(currentRowHeight, metrics.height);
    if (maxHeight.isFinite &&
        completedRowsHeight + candidateRowHeight > maxHeight) {
      break;
    }

    visibleTags.add(tag);
    currentRowWidth += metrics.width;
    currentRowHeight = candidateRowHeight;
  }
  return visibleTags;
}

_TagChipMetrics _measureTagChip(
  String tag, {
  required TextStyle textStyle,
  required TextScaler textScaler,
  required TextDirection textDirection,
  required Locale? locale,
  required double maxChipWidth,
  required double maxTextWidth,
}) {
  final textPainter = TextPainter(
    text: TextSpan(text: tag, style: textStyle),
    textDirection: textDirection,
    textScaler: textScaler,
    locale: locale,
    maxLines: 1,
    ellipsis: '...',
  )..layout(maxWidth: maxTextWidth);
  final metrics = _TagChipMetrics(
    width: math.min(
          maxChipWidth,
          textPainter.width + _tagChipHorizontalPadding * 2,
        ) +
        _tagChipTrailingGap,
    height: textPainter.height +
        _tagChipTopPadding +
        _tagChipBottomPadding +
        _tagChipRunGap,
  );
  textPainter.dispose();
  return metrics;
}

class _TagChipMetrics {
  const _TagChipMetrics({
    required this.width,
    required this.height,
  });

  final double width;
  final double height;
}

import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/comic_tile_display_config.dart';
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
    this.favoriteTarget,
    this.favoriteType,
    this.optimizeCoverDecode = false,
    this.maxTagRows,
    this.cardDisplayConfig,
    this.descriptionLeading,
    this.idColorKey = comicTileDisplayDefaultIdColor,
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

  /// Explicit online identity; titles are not stable favorite identifiers.
  final String? favoriteTarget;
  final FavoriteType? favoriteType;
  final bool optimizeCoverDecode;

  /// Limits the number of visual tag rows when set. Other callers keep the
  /// historical unrestricted tag layout by leaving this null.
  ///
  /// 只有 [cardDisplayConfig] 为空时才生效；配置存在时以配置为准。
  final int? maxTagRows;

  /// 「卡片信息显示」配置（本地收藏 / 在线收藏 / 搜索页-该源各一套）。
  ///
  /// 调用方按页面维度取一次配置传进来，卡片据此决定标签行数与标签区显隐。
  /// 为空表示"不使用可配置的卡片显示"，退回 [maxTagRows] 与默认显隐。
  final ComicTileDisplayConfig? cardDisplayConfig;

  /// 标签区最多渲染几行；不限行时为 null。
  int? get effectiveMaxTagRows => cardDisplayConfig?.maxTagRows ?? maxTagRows;

  /// 是否渲染标签区。
  bool get showTags => cardDisplayConfig?.showTags ?? true;

  /// 「标签显示行数」是否选了**不限**（`tagRows == 0`）。
  ///
  /// 需要与"没有配置"区分开：两者 `maxTagRows` 都是 null，但"不限"是用户主动
  /// 选了"尽量多显示"，要配小字号；而网络收藏/搜索页等"没传配置"的调用方应
  /// 保持默认字号。
  bool get unlimitedTagRows => cardDisplayConfig?.tagRows == 0;

  /// 描述区最上方的一行附加内容（如本地收藏卡片的「来源标识号」`jm<id>`）。
  ///
  /// 为空表示该卡片没有这一行；调用方负责按配置决定是否给出 Widget，卡片不做判断。
  final Widget? descriptionLeading;

  /// 该行颜色键（见 `comicTileDisplayIdColorOptions`），默认橙色。
  ///
  /// 传键而不是 `Color`：`black` 在深色模式下要变成纯白，必须在 build 时按
  /// 当前主题解析，预先算好的 `Color` 做不到。
  final String idColorKey;

  final String author;
  final String name;
  final void Function() onTap;
  final void Function() onLongTap;
  final void Function(TapDownDetails details) onSecondaryTap;
  final String? type;
  final List<String> tag;

  /// 标签列表；「显示标签」关闭时直接返回 null，标签区随之不渲染。
  ///
  /// 走 null 而不是空列表，是为了复用 [tags] 既有语义（null = 该卡片没有
  /// 标签区），避免为了显隐再引入一条并行的分支。
  List<String>? get tags => showTags ? tag : null;

  String get description => size;

  String get subTitle => author;

  String get title => name;

  bool get enableLongPressed => true;

  String? get badge => type;

  String? get comicID => null;

  bool get showFavorite => appdata.settings[72] == '1';

  bool get showReadingPosition => appdata.settings[73] == '1';

  History? get readingHistory =>
      readingHistoryOverride ??
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

    if (!showFavorite) return child;
    if (isFavoriteOverride != null) {
      return _withFavoriteBadge(child, detailedMode, isFavoriteOverride!);
    }
    // Keep the expensive card content intact when only membership changes.
    return StreamBuilder<List<FavGroup>>(
      stream: LocalFavoritesManager().allFoldersStream,
      builder: (context, snapshot) =>
          _withFavoriteBadge(child, detailedMode, _resolveFavoriteState()),
    );
  }

  Widget _withFavoriteBadge(Widget child, bool detailedMode, bool isFavorite) {
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
    if (favoriteTarget != null && favoriteType != null) {
      return LocalFavoritesManager()
          .isComicFavorited(favoriteTarget!, favoriteType!);
    }
    final target = comicID;
    return target == null
        ? _checkFavorite()
        : LocalFavoritesManager().isExist(target);
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
      for (final ft in types) {
        if (fav.isComicFavorited(name, ft)) {
          return true;
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
                  descriptionLeading: descriptionLeading,
                  idColorKey: idColorKey,
                  compactTags: unlimitedTagRows,
                  badge: badge,
                  tags: tags,
                  maxLines: 2,
                  maxTagRows: effectiveMaxTagRows,
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
        (imagePath.path.isEmpty
            ? null
            : FileImage(imagePath) as ImageProvider<Object>);
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
    this.descriptionLeading,
    this.idColorKey = comicTileDisplayDefaultIdColor,
    this.compactTags = false,
    this.badge,
    this.maxLines = 2,
    this.maxTagRows,
    this.tags,
  });

  final String title;
  final String user;
  final String description;
  final Widget? subDescription;

  /// 描述区最上方的附加行（来源标识号等）；为空不占任何高度。
  ///
  /// 传入的 Widget 不要自带颜色/字号：本组件会用 `idColorKey` 与 12pt 包一层
  /// [DefaultTextStyle]，自带样式会把它盖掉。
  final Widget? descriptionLeading;

  /// [descriptionLeading] 的颜色键。
  final String idColorKey;

  /// 标签区是否用"紧凑字号"（「标签显示行数」选了不限时）。
  final bool compactTags;
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
    return _withBottomInfo(
        context,
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              title,
              style:
                  const TextStyle(fontWeight: FontWeight.w500, fontSize: 14.0),
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
            ),
            if (user.isNotEmpty)
              Text(user, style: const TextStyle(fontSize: 10.0), maxLines: 1),
            const SizedBox(height: 4),
            if (visibleTags != null)
              // 外面套 Align(heightFactor: 1)：Flexible 给的是 loose 约束，但 Wrap
              // 在**有界高度**下会被拉满（实测每个标签之间被撑到 90+dp，表现为标签
              // 之间出现巨大空隙、卡片内容整体溢出）。heightFactor: 1 让 Wrap 贴内容
              // 高度收缩；项目里 `_buildLimitedLayout` 踩过同一个坑（那里选了"不套
              // Align"，因为它需要被 maxHeight 裁剪，这里不需要）。
              Flexible(
                child: Align(
                  alignment: Alignment.topLeft,
                  heightFactor: 1,
                  child: Wrap(
                    runAlignment: WrapAlignment.start,
                    clipBehavior: Clip.antiAlias,
                    crossAxisAlignment: WrapCrossAlignment.end,
                    children: [
                      for (var s in visibleTags)
                        _LimitedTagChip(
                          tag: s,
                          maxWidth: 1e6,
                          // 用户选了"不限"就配小字号（想多看点标签）；其余调用方
                          // （网络收藏 / 搜索页）保持默认字号。
                          fontSize: compactTags
                              ? _tagChipCompactFontSize
                              : _tagChipBaseFontSize,
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
        limited: false);
  }

  Widget _buildLimitedLayout(
    BuildContext context,
    List<String>? visibleTags,
  ) {
    final hasTags = visibleTags != null && visibleTags.isNotEmpty;
    return _withBottomInfo(
        context,
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // flex 2 : 3 —— 高度不够时**标题先让位**，标签区拿大头。
            // 定高卡片里"标签实际显示几行"由可用高度决定（不是只看 tagRows 配置），
            // 标题多占一行就等于标签少显示一行；实测用户样本：标题 2 行 + id 行会把
            // 标签区压到只剩 1 行，于是"设 2 行/3 行都只显示 1 行"。
            Flexible(
              flex: 2,
              fit: FlexFit.loose,
              child: Text(
                title,
                style: const TextStyle(
                    fontWeight: FontWeight.w500, fontSize: 14.0),
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
              // Keep the existing title/tag flex budget and row fitting inside the
              // upper area. The footer has already reserved its own height.
              Flexible(
                flex: 3,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final maxTagWidth = math.max(
                      0.0,
                      constraints.maxWidth - _tagChipTrailingGap,
                    );
                    final textScaler = MediaQuery.textScalerOf(context);
                    final textDirection = Directionality.of(context);
                    final locale = Localizations.maybeLocaleOf(context);
                    final tagStyle = DefaultTextStyle.of(context).style;

                    final baseFontSize = tagChipBaseFontSizeFor(maxTagRows);
                    // 自适应："显示不全就调小字号"——缩小字号本身就能让更多标签挤进
                    // 同一空间，所以直接对**完整标签列表**求解，取"不减少可见标签数"
                    // 前提下能放下的最小字号。
                    final fontSize = _fitTagFontSize(
                      tags: visibleTags,
                      baseFontSize: baseFontSize,
                      maxRows: maxTagRows!,
                      maxWidth: constraints.maxWidth,
                      maxHeight: constraints.maxHeight,
                      maxTagWidth: maxTagWidth,
                      tagStyle: tagStyle,
                      textScaler: textScaler,
                      textDirection: textDirection,
                      locale: locale,
                    );
                    return _LimitedTagWrap(
                      tags: visibleTags,
                      maxRows: maxTagRows!,
                      fontSize: fontSize,
                    );
                  },
                ),
              ),
            ],
          ],
        ),
        limited: true);
  }

  /// Reserve the footer's height first. The remaining space belongs to the
  /// title/author/tags, so empty or hidden tags never pull the footer upward.
  Widget _withBottomInfo(BuildContext context, Widget content,
      {required bool limited}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: content),
        if (descriptionLeading != null) ...[
          const SizedBox(height: 2),
          DefaultTextStyle.merge(
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: resolveComicTileIdColor(context, idColorKey),
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            child: descriptionLeading!,
          ),
        ],
        const SizedBox(height: 2),
        _buildFooter(limited: limited),
      ],
    );
  }

  Widget _buildFooter({required bool limited}) {
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
                maxLines: limited ? 1 : null,
                overflow: limited ? TextOverflow.ellipsis : null,
              ),
            ],
          ),
        ),
        if (badge != null && badge!.isNotEmpty) _ComicBadge(text: badge!),
      ],
    );
  }
}

/// 卡片上的角标（「已下载」等）。
///
/// **两条布局分支（有限/无限）必须共用这一个实现**：它们原先各写一份，改小
/// 时只改了一处，于是「不限」档的卡片角标仍是旧的大尺寸（用户实测发现）。
class _ComicBadge extends StatelessWidget {
  const _ComicBadge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      // 紧凑角标：原来的 6/4 padding + 12pt 文字高约 23dp，是 footer 中最高的
      // 元素，而 footer 与标签区在**抢同一段高度**（定高卡片）。压到约 15dp
      // 把行高还给标签区。
      padding: const EdgeInsets.fromLTRB(5, 1, 5, 2),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.tertiaryContainer,
        borderRadius: const BorderRadius.all(Radius.circular(8)),
      ),
      child: Text(text, style: const TextStyle(fontSize: 10)),
    );
  }
}

const _tagChipHorizontalPadding = 3.0;
const _tagChipTopPadding = 1.0;
const _tagChipBottomPadding = 3.0;
const _tagChipTrailingGap = 4.0;
const _tagChipRunGap = 3.0;

/// 标签 chip 的默认字号。
const _tagChipBaseFontSize = 12.0;

/// 缩小后的字号下限。
///
/// 再小就难读了；到了下限还放不下就**接受截断**，不做无限制缩放
/// （用户要的是"显示不全时缩一点"，不是"缩到看不清也要塞完"）。
const _tagChipMinFontSize = 9.5;

/// 自适应时每次缩小的步长。
const _tagChipFontStep = 1.5;

/// 「标签显示行数」为 3 行或不限时的基准字号：比默认小一档，给内容让位。
const _tagChipCompactFontSize = 10.5;

/// 该显示几行时用哪个基准字号。
///
/// - 2 行（默认）：12pt，与改动前完全一致；
/// - 3 行 / 不限：10.5pt —— 这两档本就是"想多看点标签"，小一档换更多内容。
double tagChipBaseFontSizeFor(int? maxTagRows) {
  if (maxTagRows == null || maxTagRows >= 3) {
    return _tagChipCompactFontSize;
  }
  return _tagChipBaseFontSize;
}

class _LimitedTagWrap extends StatelessWidget {
  const _LimitedTagWrap({
    required this.tags,
    required this.maxRows,
    this.fontSize = _tagChipBaseFontSize,
  });

  final List<String> tags;
  final int maxRows;

  /// chip 字号；由调用方按"显示几行 / 是否还能放下"决定。
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final textStyle =
        DefaultTextStyle.of(context).style.merge(TextStyle(fontSize: fontSize));
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
                fontSize: fontSize,
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
    this.fontSize = _tagChipBaseFontSize,
  });

  final String tag;
  final double maxWidth;
  final double fontSize;

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
            style: TextStyle(fontSize: fontSize),
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}

/// 自适应标签字号："显示不全就把字号调小"。
///
/// 语义：
/// - 先算基准字号下能显示多少标签（[baseCount]）；
/// - 再逐步缩小字号，只要"可见标签数 **不少于** 基准"就继续缩 ——
///   缩小后能塞进更多标签（数量可能超过基准，那是白赚的）；
/// - 到达 [minFontSize] 下限即停；再小就难读，剩下的一律截断。
///
/// 只缩不放：不会出现"比默认字号还大"的情况。
double _fitTagFontSize({
  required List<String> tags,
  required double baseFontSize,
  required int maxRows,
  required double maxWidth,
  required double maxHeight,
  required double maxTagWidth,
  required TextStyle tagStyle,
  required TextScaler textScaler,
  required TextDirection textDirection,
  required Locale? locale,
}) {
  if (tags.isEmpty) {
    return baseFontSize;
  }
  int visibleCount(double fontSize) {
    return _visibleTagPrefix(
      tags: tags,
      maxRows: maxRows,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      textStyle: tagStyle.merge(TextStyle(fontSize: fontSize)),
      textScaler: textScaler,
      textDirection: textDirection,
      locale: locale,
      maxChipWidthOverride: maxTagWidth,
    ).length;
  }

  final baseCount = visibleCount(baseFontSize);
  if (baseCount >= tags.length) {
    return baseFontSize;
  }
  final candidates = <double>[];
  for (var size = baseFontSize - _tagChipFontStep;
      size >= _tagChipMinFontSize - 0.001;
      size -= _tagChipFontStep) {
    candidates.add(size);
  }
  if (candidates.isEmpty) {
    return baseFontSize;
  }
  var best = baseFontSize;
  var bestCount = baseCount;
  // 从大到小试：优先保住可读性，只在"可见数不减少"时接受更小字号。
  for (final size in candidates) {
    final count = visibleCount(size);
    if (count >= bestCount) {
      best = size;
      bestCount = count;
    } else {
      break;
    }
  }
  return best;
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

  /// 覆盖芯片最大宽度（用于"按实际渲染宽度"复核；默认由 maxWidth 推导）。
  double? maxChipWidthOverride,
}) {
  if (maxRows <= 0 ||
      !maxWidth.isFinite ||
      maxWidth <= _tagChipTrailingGap ||
      maxHeight <= 0) {
    return const <String>[];
  }

  // 复核时用"实际渲染宽度"（chips 外面还有 trailingGap），避免低估占位。
  final maxChipWidth = maxChipWidthOverride ?? (maxWidth - _tagChipTrailingGap);
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

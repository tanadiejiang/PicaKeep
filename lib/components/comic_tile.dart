import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'comic_tag_wrap.dart';

export 'comic_tag_wrap.dart' show tagChipBaseFontSizeFor;
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/comic_tile_display_config.dart';
import 'package:picakeep/foundation/history.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/foundation/image_pipeline/cover_decode_target.dart';
import 'package:picakeep/foundation/image_pipeline/cover_thumbnail_size.dart';
import 'package:picakeep/foundation/image_loader/base_image_provider.dart';
import 'package:picakeep/foundation/image_loader/stream_image_provider.dart';

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
      return _buildCoverImage(resolvedProvider, resolvedProvider,
          gaplessPlayback: false);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final target = constraints.maxWidth.isFinite &&
                constraints.maxHeight.isFinite &&
                constraints.maxHeight > 0
            ? coverFramePhysicalTarget(
                Size(constraints.maxWidth, constraints.maxHeight),
                MediaQuery.devicePixelRatioOf(context))
            : null;
        final displayProvider = target != null
            ? CoverDecodeTarget(resolvedProvider,
                frameWidth: target.width,
                frameHeight: target.height,
                fit: BoxFit.cover)
            : resolvedProvider;
        return _buildCoverImage(resolvedProvider, displayProvider,
            gaplessPlayback: true);
      },
    );
  }

  Widget _buildCoverImage(ImageProvider<Object> sourceProvider,
      ImageProvider<Object> displayProvider,
      {required bool gaplessPlayback}) {
    final isLocal = sourceProvider is FileImage ||
        (sourceProvider is StreamImageProvider &&
            (sourceProvider.imageKey.startsWith('local_cover::') ||
                sourceProvider.imageKey.startsWith('local_file::')));
    if (isLocal) {
      return _RecoverableLocalComicCover(
          sourceProvider: sourceProvider,
          displayProvider: displayProvider,
          gaplessPlayback: gaplessPlayback);
    }
    return Image(
      image: displayProvider,
      fit: BoxFit.cover,
      height: double.infinity,
      gaplessPlayback: gaplessPlayback,
      filterQuality: FilterQuality.medium,
      errorBuilder: (_, __, ___) =>
          const Center(child: Icon(Icons.image_not_supported)),
    );
  }
}

/// Evicting an error from ImageCache does not detach an already failed Image.
/// A local storage read may recover after the provider's transient-cache TTL,
/// so remount that Image once, without retrying network covers or every rebuild.
class _RecoverableLocalComicCover extends StatefulWidget {
  const _RecoverableLocalComicCover({
    required this.sourceProvider,
    required this.displayProvider,
    required this.gaplessPlayback,
  });

  final ImageProvider<Object> sourceProvider, displayProvider;
  final bool gaplessPlayback;

  @override
  State<_RecoverableLocalComicCover> createState() =>
      _RecoverableLocalComicCoverState();
}

class _RecoverableLocalComicCoverState
    extends State<_RecoverableLocalComicCover> with WidgetsBindingObserver {
  static const _retryDelay = Duration(seconds: 5);
  Timer? _retryTimer;
  bool _failed = false, _retryUsed = false, _retrying = false;
  bool _routeActive = true, _appActive = true;
  int _revision = 0, _sourceGeneration = 0;
  late ImageProvider<Object> _displayProvider;

  bool get _canRetry => mounted && _routeActive && _appActive;

  @override
  void initState() {
    super.initState();
    _displayProvider = widget.displayProvider;
    _appActive = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _routeActive = TickerMode.valuesOf(context).enabled;
    if (!_routeActive) {
      _cancelRetry();
    } else {
      _queueRetry();
    }
  }

  @override
  void didUpdateWidget(covariant _RecoverableLocalComicCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sourceProvider != widget.sourceProvider) {
      _cancelRetry();
      _sourceGeneration++;
      _revision++;
      _failed = _retryUsed = _retrying = false;
    }
    if (!_sameDisplayTarget(_displayProvider, widget.displayProvider)) {
      _displayProvider = widget.displayProvider;
    }
  }

  bool _sameDisplayTarget(
      ImageProvider<Object> before, ImageProvider<Object> after) {
    if (before is CoverDecodeTarget && after is CoverDecodeTarget) {
      return before.imageProvider == after.imageProvider &&
          before.frameWidth == after.frameWidth &&
          before.frameHeight == after.frameHeight &&
          before.fit == after.fit &&
          before.maximumEdge == after.maximumEdge &&
          before.maximumPixels == after.maximumPixels;
    }
    return before == after;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final wasActive = _appActive;
    _appActive = state == AppLifecycleState.resumed;
    if (!_appActive) {
      _cancelRetry();
    } else if (!wasActive && _failed) {
      // Permission helpers can recover while the application is backgrounded.
      // Only failed cards get one new opportunity in this foreground session.
      _retryUsed = false;
      _queueRetry();
    }
  }

  void _cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  void _queueRetry() {
    if (!_canRetry ||
        !_failed ||
        _retryUsed ||
        _retrying ||
        _retryTimer != null) {
      return;
    }
    _retryTimer = Timer(_retryDelay, () {
      _retryTimer = null;
      unawaited(_retry());
    });
  }

  Future<void> _retry() async {
    if (!_canRetry || !_failed || _retryUsed || _retrying) return;
    final generation = _sourceGeneration;
    final source = widget.sourceProvider;
    final display = widget.displayProvider;
    _retrying = true;
    if (source is BaseImageProvider) {
      // A codec failure may have cached malformed bytes before decoding failed.
      BaseImageProvider.evictKey(source.key);
    }
    try {
      await display.evict(
          configuration: createLocalImageConfiguration(context));
    } catch (_) {
      // A provider that cannot obtain its key still receives only one retry.
    }
    if (!mounted || generation != _sourceGeneration) return;
    _retrying = false;
    if (!_canRetry) return;
    setState(() {
      _retryUsed = true;
      _failed = false;
      _displayProvider = widget.displayProvider;
      _revision++;
    });
  }

  @override
  void dispose() {
    _cancelRetry();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Image(
        key: ValueKey(_revision),
        image: _displayProvider,
        fit: BoxFit.cover,
        height: double.infinity,
        gaplessPlayback: widget.gaplessPlayback,
        filterQuality: FilterQuality.medium,
        frameBuilder: (_, child, frame, __) {
          if (frame != null) {
            _failed = false;
            _cancelRetry();
          }
          return child;
        },
        errorBuilder: (_, __, ___) {
          _failed = true;
          _queueRetry();
          return const Center(child: Icon(Icons.image_not_supported));
        },
      );
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
                        ComicTagChip(
                          tag: s,
                          maxWidth: 1e6,
                          // 用户选了"不限"就配小字号（想多看点标签）；其余调用方
                          // （网络收藏 / 搜索页）保持默认字号。
                          fontSize: compactTags
                              ? tagChipBaseFontSizeFor(null)
                              : tagChipBaseFontSizeFor(2),
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
                      constraints.maxWidth - comicTagTrailingGap,
                    );
                    final textScaler = MediaQuery.textScalerOf(context);
                    final textDirection = Directionality.of(context);
                    final locale = Localizations.maybeLocaleOf(context);
                    final tagStyle = DefaultTextStyle.of(context).style;

                    final baseFontSize = tagChipBaseFontSizeFor(maxTagRows);
                    // 自适应："显示不全就调小字号"——缩小字号本身就能让更多标签挤进
                    // 同一空间，所以直接对**完整标签列表**求解，取"不减少可见标签数"
                    // 前提下能放下的最小字号。
                    final fontSize = fitComicTagFontSize(
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
                    return ComicTagWrap(
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

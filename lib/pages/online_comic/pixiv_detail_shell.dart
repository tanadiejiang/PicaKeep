import 'dart:math' as math;

import 'package:flutter/material.dart';

class PixivDetailImage {
  const PixivDetailImage({
    required this.key,
    required this.provider,
    required this.aspectRatio,
    required this.onRead,
    this.aspectRatioKnown = true,
  });

  final String key;
  final ImageProvider<Object>? provider;
  final double aspectRatio;
  final bool aspectRatioKnown;
  final VoidCallback onRead;
}

typedef PixivDetailSliversBuilder = List<Widget> Function(BuildContext context);

/// Reports when the author area reaches the floating button's occupied band.
class PixivDetailFavoriteBoundary extends StatelessWidget {
  const PixivDetailFavoriteBoundary({super.key});

  @override
  Widget build(BuildContext context) => SliverLayoutBuilder(
        builder: (context, constraints) {
          final top = constraints.viewportMainAxisExtent -
              constraints.remainingPaintExtent;
          final scope = context
              .dependOnInheritedWidgetOfExactType<_FavoriteBoundaryScope>();
          scope?.report(top <=
              constraints.viewportMainAxisExtent - scope.bottomExclusion);
          return const SliverToBoxAdapter(child: SizedBox.shrink());
        },
      );
}

class _FavoriteBoundaryScope extends InheritedWidget {
  const _FavoriteBoundaryScope({
    required this.report,
    required this.bottomExclusion,
    required super.child,
  });
  final ValueChanged<bool> report;
  final double bottomExclusion;
  @override
  bool updateShouldNotify(_FavoriteBoundaryScope oldWidget) =>
      bottomExclusion != oldWidget.bottomExclusion;
}

/// Starts deferred author loading when its sliver enters the main viewport.
class PixivDetailViewportTrigger extends StatefulWidget {
  const PixivDetailViewportTrigger({super.key, this.onVisible});

  final VoidCallback? onVisible;

  @override
  State<PixivDetailViewportTrigger> createState() =>
      _PixivDetailViewportTriggerState();
}

class _PixivDetailViewportTriggerState
    extends State<PixivDetailViewportTrigger> {
  bool _triggered = false;

  @override
  Widget build(BuildContext context) => SliverLayoutBuilder(
        builder: (context, constraints) {
          if (!_triggered &&
              widget.onVisible != null &&
              constraints.remainingPaintExtent > 0) {
            _triggered = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) widget.onVisible?.call();
            });
          }
          return const SliverToBoxAdapter(child: SizedBox.shrink());
        },
      );
}

/// A work owns one vertical detail scroll; an entry pager owns work navigation.
class PixivDetailShell extends StatefulWidget {
  const PixivDetailShell({
    super.key,
    required this.title,
    required this.author,
    required this.images,
    required this.actionLabel,
    required this.actionIcon,
    required this.sliversBuilder,
    this.onAction,
    this.onActionLongPress,
    this.actionBusy = false,
    this.isFavorited = false,
    this.favoriteBusy = false,
    this.favoriteLabel = '收藏',
    this.onFavorite,
    this.onFavoriteLongPress,
    this.onShare,
    this.menuItems = const [],
    this.onMenu,
    this.imageError,
    this.onRetryImages,
    this.imagesLoading = false,
  });

  final String title;
  final String author;
  final List<PixivDetailImage> images;
  final String actionLabel;
  final IconData actionIcon;
  final VoidCallback? onAction;
  final VoidCallback? onActionLongPress;
  final bool actionBusy;
  final bool isFavorited;
  final bool favoriteBusy;
  final String favoriteLabel;
  final VoidCallback? onFavorite;
  final VoidCallback? onFavoriteLongPress;
  final PixivDetailSliversBuilder sliversBuilder;
  final VoidCallback? onShare;
  final List<PopupMenuEntry<String>> menuItems;
  final ValueChanged<String>? onMenu;
  final String? imageError;
  final VoidCallback? onRetryImages;
  final bool imagesLoading;

  @override
  State<PixivDetailShell> createState() => _PixivDetailShellState();
}

class _PixivDetailShellState extends State<PixivDetailShell> {
  final _scrollController = ScrollController();
  final ValueNotifier<bool> _favoriteVisible = ValueNotifier(true);
  double _width = 0;
  int _imageIndex = 0;
  List<double> _pageEnds = const [];
  final Map<String, double> _ratios = {};
  bool _boundaryReached = false;
  bool _counterSyncPending = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_scrollChanged);
  }

  @override
  void didUpdateWidget(covariant PixivDetailShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.images, widget.images)) {
      _measureImages();
      _imageIndex =
          math.min(_imageIndex, math.max(0, widget.images.length - 1));
    }
  }

  void _measureImages() {
    var end = 0.0;
    _pageEnds = widget.images.map((image) {
      final value = _ratios[image.key] ?? image.aspectRatio;
      final ratio = value.isFinite && value > 0 ? value : .75;
      end += _width / ratio;
      return end;
    }).toList(growable: false);
    if (!_counterSyncPending) {
      _counterSyncPending = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _counterSyncPending = false;
        if (mounted) _scrollChanged();
      });
    }
  }

  void _scrollChanged() {
    if (!_scrollController.hasClients || _pageEnds.isEmpty) return;
    final focus = _scrollController.position.pixels + 48;
    var low = 0;
    var high = _pageEnds.length - 1;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (_pageEnds[mid] <= focus) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    if (low != _imageIndex) setState(() => _imageIndex = low);
  }

  void _jumpToNextImage() {
    if (!_scrollController.hasClients || widget.images.length < 2) return;
    final next = (_imageIndex + 1) % widget.images.length;
    final target = next == 0 ? 0.0 : _pageEnds[next - 1];
    if (MediaQuery.disableAnimationsOf(context)) {
      _scrollController.jumpTo(target);
    } else {
      _scrollController.animateTo(target,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic);
    }
  }

  void _reportFavoriteBoundary(bool reached) {
    if (_boundaryReached == reached) return;
    _boundaryReached = reached;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _favoriteVisible.value = !reached;
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _favoriteVisible.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: colors.surface,
      body: SafeArea(
        child: LayoutBuilder(builder: (context, constraints) {
          if (_width != constraints.maxWidth) {
            _width = constraints.maxWidth;
            _measureImages();
          }
          final favoriteBottom = math.min(80.0, constraints.maxHeight * .15);
          return _FavoriteBoundaryScope(
              report: _reportFavoriteBoundary,
              bottomExclusion: favoriteBottom + 56 + 12,
              child: Stack(children: [
                Positioned.fill(
                  child: CustomScrollView(
                    key: const ValueKey('pixiv-detail-page-scroll'),
                    controller: _scrollController,
                    slivers: [
                      if (widget.images.isNotEmpty)
                        SliverList(
                          key: const ValueKey('pixiv-detail-images'),
                          delegate: SliverChildBuilderDelegate(
                            (context, index) =>
                                _image(context, widget.images[index], index),
                            childCount: widget.images.length,
                          ),
                        )
                      else
                        SliverToBoxAdapter(
                          child: SizedBox(
                            height: constraints.maxWidth,
                            child: Center(
                              child: widget.imagesLoading
                                  ? const CircularProgressIndicator()
                                  : const Icon(
                                      Icons.image_not_supported_outlined,
                                      size: 48),
                            ),
                          ),
                        ),
                      SliverToBoxAdapter(child: _header(context)),
                      ...widget.sliversBuilder(context),
                      const SliverToBoxAdapter(child: SizedBox(height: 88)),
                    ],
                  ),
                ),
                Positioned(
                  left: 64,
                  right: 160,
                  top: 16,
                  child: IgnorePointer(
                    child: Text(
                      widget.imagesLoading && widget.images.isEmpty
                          ? '…'
                          : widget.images.isEmpty
                              ? ''
                              : '${_imageIndex + 1} / ${widget.images.length}',
                      key: const ValueKey('pixiv-image-counter'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.white,
                        shadows: [Shadow(color: Colors.black, blurRadius: 2)],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  child: Row(children: [
                    _toolbarButton(Icons.arrow_back, '返回',
                        () => Navigator.of(context).maybePop()),
                    const Spacer(),
                    if (widget.images.length > 1)
                      IconButton(
                        key: const ValueKey('pixiv-image-browse-toggle'),
                        tooltip: '下一张图片',
                        onPressed: _jumpToNextImage,
                        icon: const Icon(Icons.collections_outlined,
                            color: Colors.white,
                            shadows: [
                              Shadow(color: Colors.black, blurRadius: 3)
                            ]),
                      ),
                    if (widget.onShare != null)
                      _toolbarButton(
                          Icons.share_outlined, '分享', widget.onShare!),
                    if (widget.menuItems.isNotEmpty)
                      PopupMenuButton<String>(
                        tooltip: '更多',
                        icon: const Icon(Icons.more_vert,
                            color: Colors.white,
                            shadows: [
                              Shadow(color: Colors.black, blurRadius: 3)
                            ]),
                        itemBuilder: (_) => widget.menuItems,
                        onSelected: widget.onMenu,
                      ),
                  ]),
                ),
                Positioned(
                  right: 16,
                  bottom: favoriteBottom,
                  child: ValueListenableBuilder<bool>(
                      valueListenable: _favoriteVisible,
                      builder: (context, visible, _) => IgnorePointer(
                            key: const ValueKey(
                                'pixiv-detail-favorite-hit-test'),
                            ignoring: !(visible || widget.favoriteBusy),
                            child: AbsorbPointer(
                                absorbing: widget.favoriteBusy,
                                child: AnimatedOpacity(
                                  key: const ValueKey(
                                      'pixiv-detail-favorite-opacity'),
                                  opacity:
                                      visible || widget.favoriteBusy ? 1 : 0,
                                  duration:
                                      MediaQuery.disableAnimationsOf(context)
                                          ? Duration.zero
                                          : const Duration(milliseconds: 200),
                                  child: AnimatedScale(
                                    key: const ValueKey(
                                        'pixiv-detail-favorite-scale'),
                                    scale:
                                        visible || widget.favoriteBusy ? 1 : 0,
                                    alignment: Alignment.center,
                                    duration:
                                        MediaQuery.disableAnimationsOf(context)
                                            ? Duration.zero
                                            : const Duration(milliseconds: 200),
                                    curve: Curves.easeInOutCubic,
                                    child: ExcludeSemantics(
                                        excluding:
                                            !(visible || widget.favoriteBusy),
                                        child: Semantics(
                                          button: true,
                                          toggled: widget.isFavorited,
                                          label: widget.favoriteLabel,
                                          enabled: !widget.favoriteBusy &&
                                              widget.onFavorite != null,
                                          child: Tooltip(
                                            message: widget.favoriteLabel,
                                            child: Material(
                                              color: Colors.white,
                                              elevation: 4,
                                              shape: const CircleBorder(),
                                              child: InkWell(
                                                key: const ValueKey(
                                                    'pixiv-detail-favorite'),
                                                customBorder:
                                                    const CircleBorder(),
                                                onTap: widget.favoriteBusy
                                                    ? null
                                                    : widget.onFavorite,
                                                onLongPress: widget.favoriteBusy
                                                    ? null
                                                    : widget
                                                        .onFavoriteLongPress,
                                                child: SizedBox.square(
                                                  dimension: 56,
                                                  child: Icon(
                                                    widget.favoriteBusy ||
                                                            widget.isFavorited
                                                        ? Icons.favorite
                                                        : Icons.favorite_border,
                                                    size: 28,
                                                    color: widget.favoriteBusy
                                                        ? const Color(
                                                                0xFFE0245E)
                                                            .withValues(
                                                                alpha: .5)
                                                        : const Color(
                                                            0xE6E0245E),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        )),
                                  ),
                                )),
                          )),
                ),
              ]));
        }),
      ),
    );
  }

  Widget _toolbarButton(IconData icon, String label, VoidCallback action) =>
      IconButton(
        tooltip: label,
        onPressed: action,
        icon: Icon(icon,
            color: Colors.white,
            shadows: const [Shadow(color: Colors.black, blurRadius: 3)]),
      );

  Widget _image(BuildContext context, PixivDetailImage image, int index) {
    final value = _ratios[image.key] ?? image.aspectRatio;
    final ratio = value.isFinite && value > 0 ? value : .75;
    Widget fallback(BuildContext context, Object? error, StackTrace? trace) =>
        Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.broken_image_outlined, size: 40),
            Text('第${index + 1}张图片暂不可用'),
            if (widget.onRetryImages != null)
              IconButton(
                tooltip: '重试图片',
                onPressed: widget.onRetryImages,
                icon: const Icon(Icons.refresh),
              ),
          ]),
        );
    return Semantics(
      label: '第${index + 1}张图片，阅读',
      button: true,
      child: GestureDetector(
        key: ValueKey('pixiv-image-${image.key}'),
        onTap: image.onRead,
        child: AspectRatio(
          aspectRatio: ratio,
          child: image.provider == null
              ? fallback(context, null, null)
              : _MeasuredDetailImage(
                  provider: ResizeImage.resizeIfNeeded(
                    (_width * MediaQuery.devicePixelRatioOf(context) * 1.2)
                        .round(),
                    null,
                    image.provider!,
                  ),
                  errorBuilder: fallback,
                  onDimensions: image.aspectRatioKnown
                      ? null
                      : (ratio) {
                          if (!mounted || _ratios[image.key] == ratio) return;
                          setState(() {
                            _ratios[image.key] = ratio;
                            _measureImages();
                          });
                        },
                ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context) => Container(
        color: Theme.of(context).colorScheme.surface,
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Row(children: [
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
                Text(widget.author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Tooltip(
            message: widget.actionLabel,
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: widget.actionBusy ? null : widget.onAction,
              onLongPress: widget.actionBusy ? null : widget.onActionLongPress,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
                child: Center(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 5),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(
                            widget.actionBusy
                                ? Icons.hourglass_top
                                : widget.actionIcon,
                            size: 18),
                        const SizedBox(width: 4),
                        Text(widget.actionLabel,
                            style: const TextStyle(fontSize: 12)),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ]),
      );
}

class _MeasuredDetailImage extends StatefulWidget {
  const _MeasuredDetailImage(
      {required this.provider, required this.errorBuilder, this.onDimensions});
  final ImageProvider<Object> provider;
  final ImageErrorWidgetBuilder errorBuilder;
  final ValueChanged<double>? onDimensions;
  @override
  State<_MeasuredDetailImage> createState() => _MeasuredDetailImageState();
}

class _MeasuredDetailImageState extends State<_MeasuredDetailImage> {
  ImageStream? _stream;
  late final ImageStreamListener _listener = ImageStreamListener((info, sync) {
    if (info.image.width <= 0 || info.image.height <= 0) return;
    final ratio = info.image.width / info.image.height;
    info.dispose();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onDimensions?.call(ratio);
    });
  }, onError: (Object error, StackTrace? trace) {});

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant _MeasuredDetailImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.provider != widget.provider) _resolve();
  }

  void _resolve() {
    _stream?.removeListener(_listener);
    _stream = null;
    if (widget.onDimensions != null) {
      _stream = widget.provider.resolve(createLocalImageConfiguration(context));
      _stream!.addListener(_listener);
    }
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Image(
      image: widget.provider,
      fit: BoxFit.contain,
      alignment: Alignment.topCenter,
      errorBuilder: widget.errorBuilder);
}

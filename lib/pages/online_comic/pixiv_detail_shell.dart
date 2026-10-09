import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:picakeep/foundation/pixiv_detail_session.dart';
import 'package:picakeep/components/pixiv_bookmark_button.dart';
import 'package:picakeep/network/pixiv_network/pixiv_network.dart';
import 'package:picakeep/pages/online_common/online_comic_list_item.dart';

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
    this.onlineBookmarkAnimations = false,
    this.favoriteActive = true,
    this.favoriteIdentity,
    this.favoriteVisualEpoch,
    this.favoriteEvent,
    this.favoriteLabel = '收藏',
    this.onFavorite,
    this.onFavoriteLongPress,
    this.onShare,
    this.menuItems = const [],
    this.onMenu,
    this.imageError,
    this.onRetryImages,
    this.imagesLoading = false,
    this.galleryCollapsible = false,
    this.authorAvatarUrl = '',
    this.onGalleryExpansionChanged,
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
  final bool onlineBookmarkAnimations;
  final bool favoriteActive;
  final Object? favoriteIdentity;
  final Object? favoriteVisualEpoch;
  final PixivBookmarkEvent? favoriteEvent;
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

  /// Online multipage works defer details until the user reaches the gallery
  /// end, and expose an optional detail panel. The gallery is never collapsed.
  /// Local and single-image details keep their original inline layout.
  final bool galleryCollapsible;
  final String authorAvatarUrl;

  /// Compatibility with the online entry: false while the detail panel is
  /// open, true in image/inline browsing. The entry omits recommendations from
  /// [sliversBuilder] while this panel is open. No initial callback is emitted.
  final ValueChanged<bool>? onGalleryExpansionChanged;

  @override
  State<PixivDetailShell> createState() => _PixivDetailShellState();
}

class _PixivDetailShellState extends State<PixivDetailShell> {
  final _scrollController = ScrollController();
  final _galleryHeaderKey = GlobalKey(debugLabel: 'pixiv-gallery-header');
  final _detailsKey = GlobalKey(debugLabel: 'pixiv-single-details-group');
  final _panelScrollController = ScrollController();
  bool _panelOpen = false;
  bool _detailsCreated = false;
  bool _detailsHandedOff = false;
  bool _userScroll = false;
  bool _handoffQueued = false;
  bool _handoffAlignPending = false;
  double _detailsExtent = 0;
  bool _panelOpenedFromHandoff = false;
  bool _handoffCurrentPageLocked = false;
  double _galleryRestorePadding = 0;
  int _galleryEpoch = 0;
  String? _galleryIdentity;
  final ValueNotifier<bool> _favoriteVisible = ValueNotifier(true);
  double _width = 0;
  int _imageIndex = 0;
  List<double> _pageEnds = const [];
  final Map<String, double> _ratios = {};
  bool _boundaryReached = false;
  bool _counterSyncPending = false;
  bool _favoriteSyncPending = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_scrollChanged);
    if (widget.images.isNotEmpty) _galleryIdentity = widget.images.first.key;
  }

  bool get _entryActive =>
      PixivDetailEntryScope.isActiveOf(context) &&
      TickerMode.valuesOf(context).enabled;

  @override
  void didUpdateWidget(covariant PixivDetailShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    final identity = widget.images.isEmpty ? null : widget.images.first.key;
    final replaced = _galleryIdentity != null &&
        identity != null &&
        identity != _galleryIdentity;
    if (replaced ||
        (oldWidget.galleryCollapsible && !widget.galleryCollapsible)) {
      final notify = _panelOpen;
      _panelOpen = false;
      _detailsCreated = false;
      _detailsHandedOff = false;
      _userScroll = false;
      _handoffQueued = false;
      _handoffAlignPending = false;
      _panelOpenedFromHandoff = false;
      _handoffCurrentPageLocked = false;
      _galleryRestorePadding = 0;
      _detailsExtent = 0;
      _galleryEpoch++;
      _imageIndex = 0;
      if (replaced) _ratios.clear();
      if (notify) {
        final epoch = _galleryEpoch;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && epoch == _galleryEpoch) {
            widget.onGalleryExpansionChanged?.call(true);
          }
        });
      }
    }
    if (identity != null) _galleryIdentity = identity;
    if (!identical(oldWidget.images, widget.images)) {
      _measureImages();
      _imageIndex =
          math.min(_imageIndex, math.max(0, widget.images.length - 1));
    }
  }

  double _galleryRestorePaddingFor(ScrollPosition position) {
    if (_pageEnds.isEmpty || widget.images.isEmpty) return 0;
    final index = _imageIndex.clamp(0, _pageEnds.length - 1);
    final start = index == 0 ? 0.0 : _pageEnds[index - 1];
    final pageHeight = math.max(0.0, _pageEnds[index] - start);
    return math.max(0.0, position.viewportDimension - pageHeight - 88.0);
  }

  void _setDetailsPanel(bool open) {
    if (!widget.galleryCollapsible ||
        open == _panelOpen ||
        (open && !_entryActive)) {
      return;
    }
    final openedFromHandoff = _detailsHandedOff;
    final render = _detailsKey.currentContext?.findRenderObject();
    if (render is RenderSliver) {
      _detailsExtent = render.geometry?.scrollExtent ?? _detailsExtent;
    }
    final restorePadding =
        !open && _panelOpenedFromHandoff && _scrollController.hasClients
            ? _galleryRestorePaddingFor(_scrollController.position)
            : 0.0;
    setState(() {
      _panelOpen = open;
      _detailsCreated = true;
      _panelOpenedFromHandoff = openedFromHandoff;
      _handoffCurrentPageLocked = false;
      _galleryRestorePadding = open ? 0 : restorePadding;
      _userScroll = false;
      _handoffQueued = false;
      _handoffAlignPending = false;
      if (!open) {
        _detailsHandedOff = false;
        _detailsExtent = 0;
        _boundaryReached = false;
      }
      _galleryEpoch++;
    });
    widget.onGalleryExpansionChanged?.call(!open);
    _scheduleFavoriteVisibilitySync();
    if (!open && restorePadding > 0) {
      final epoch = _galleryEpoch;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            epoch != _galleryEpoch ||
            !_scrollController.hasClients ||
            !_entryActive ||
            _panelOpen ||
            !_panelOpenedFromHandoff) {
          return;
        }
        final position = _scrollController.position;
        final index = _imageIndex.clamp(0, _pageEnds.length - 1);
        final target = index == 0 ? 0.0 : _pageEnds[index - 1];
        final bounded =
            target.clamp(position.minScrollExtent, position.maxScrollExtent);
        if (position.pixels >= bounded - 1) return;
        if (MediaQuery.disableAnimationsOf(context)) {
          _scrollController.jumpTo(bounded);
        } else {
          _scrollController.animateTo(bounded,
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic);
        }
      });
    }
  }

  bool _galleryScroll(ScrollNotification notification) {
    if (!widget.galleryCollapsible ||
        notification.depth != 0 ||
        notification.metrics.axis != Axis.vertical) {
      return false;
    }
    if (notification is ScrollStartNotification) {
      _userScroll = notification.dragDetails != null && _entryActive;
    }
    if (!_entryActive || _panelOpen) {
      _userScroll = false;
      return false;
    }
    final down = notification is ScrollUpdateNotification &&
            (notification.scrollDelta ?? 0) > 0 ||
        notification is OverscrollNotification && notification.overscroll > 0;
    final up = notification is ScrollUpdateNotification &&
            (notification.scrollDelta ?? 0) < 0 ||
        notification is OverscrollNotification && notification.overscroll < 0;
    if (_userScroll &&
        _detailsHandedOff &&
        up &&
        !_handoffQueued &&
        _pageEnds.isNotEmpty &&
        _scrollController.hasClients &&
        notification.metrics.pixels + notification.metrics.viewportDimension <=
            _pageEnds.last - 24) {
      _handoffQueued = true;
      final epoch = _galleryEpoch;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || epoch != _galleryEpoch) return;
        _handoffQueued = false;
        if (!_entryActive || _panelOpen || !_detailsHandedOff) return;
        final restorePadding =
            _galleryRestorePaddingFor(_scrollController.position);
        setState(() {
          _detailsHandedOff = false;
          _detailsExtent = 0;
          _galleryRestorePadding = restorePadding;
          _boundaryReached = false;
          _handoffAlignPending = false;
          _handoffCurrentPageLocked = false;
          _galleryEpoch++;
        });
        widget.onGalleryExpansionChanged?.call(false);
        _scheduleFavoriteVisibilitySync();
      });
    }
    if (_userScroll &&
        down &&
        !_detailsHandedOff &&
        !_handoffQueued &&
        _pageEnds.isNotEmpty &&
        _scrollController.hasClients &&
        notification.metrics.pixels + notification.metrics.viewportDimension >=
            _pageEnds.last + 24) {
      _handoffQueued = true;
      final epoch = _galleryEpoch;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || epoch != _galleryEpoch) return;
        _handoffQueued = false;
        if (!_entryActive || _panelOpen || _detailsHandedOff) return;
        setState(() {
          _detailsCreated = true;
          _detailsHandedOff = true;
          _galleryRestorePadding = 0;
          _imageIndex = math.max(0, widget.images.length - 1);
          _handoffCurrentPageLocked = true;
          _handoffAlignPending = true;
        });
        widget.onGalleryExpansionChanged?.call(true);
        if (!_scrollController.position.isScrollingNotifier.value) {
          _alignGalleryHandoff();
        }
      });
    }
    if (notification is ScrollEndNotification) {
      _userScroll = false;
      if (_handoffAlignPending) _alignGalleryHandoff();
    }
    return false;
  }

  void _alignGalleryHandoff() {
    final epoch = _galleryEpoch;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          epoch != _galleryEpoch ||
          !_handoffAlignPending ||
          !_entryActive ||
          _panelOpen ||
          !_scrollController.hasClients) {
        return;
      }
      void unlockCurrentPage() {
        if (mounted && epoch == _galleryEpoch) {
          _handoffCurrentPageLocked = false;
        }
      }

      _handoffAlignPending = false;
      final box = _galleryHeaderKey.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) {
        unlockCurrentPage();
        return;
      }
      final position = _scrollController.position;
      if (position.isScrollingNotifier.value) {
        _handoffAlignPending = true;
        return;
      }
      final top =
          box.localToGlobal(Offset.zero).dy - MediaQuery.paddingOf(context).top;
      final delta = top - position.viewportDimension * .45;
      // One small handoff after the user's first gallery-end gesture. Further
      // scrolling/idle/layout never snaps; a continued drag can pass it freely.
      if (delta <= 8 ||
          delta > math.min(720, position.viewportDimension * .65)) {
        unlockCurrentPage();
        return;
      }
      final target = (position.pixels + delta)
          .clamp(position.minScrollExtent, position.maxScrollExtent);
      if (MediaQuery.disableAnimationsOf(context)) {
        _scrollController.jumpTo(target);
        unlockCurrentPage();
      } else {
        _scrollController
            .animateTo(target,
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic)
            .whenComplete(unlockCurrentPage);
      }
    });
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
    _scheduleFavoriteVisibilitySync();
    if (_handoffCurrentPageLocked) return;
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
    _scheduleFavoriteVisibilitySync();
  }

  void _scheduleFavoriteVisibilitySync() {
    if (_favoriteSyncPending) return;
    _favoriteSyncPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _favoriteSyncPending = false;
      if (!mounted) return;
      // A short work can put its author in the button's band on the first
      // screen. Keep the action reachable at the top, including overscroll.
      // Read the latest position/boundary so layout and scroll reports in one
      // frame cannot restore an obsolete visibility value.
      final atTop = !_scrollController.hasClients ||
          _scrollController.position.pixels <=
              _scrollController.position.minScrollExtent;
      _favoriteVisible.value = atTop || !_boundaryReached || _panelOpen;
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _panelScrollController.dispose();
    _favoriteVisible.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final scaffold = Scaffold(
      backgroundColor: colors.surface,
      body: SafeArea(
        child: LayoutBuilder(builder: (context, constraints) {
          if (_width != constraints.maxWidth) {
            _width = constraints.maxWidth;
            _measureImages();
          }
          final baseFavoriteBottom =
              math.min(80.0, constraints.maxHeight * .15);
          final favoriteBottom = widget.galleryCollapsible && !_detailsHandedOff
              ? math.max(baseFavoriteBottom, 88.0)
              : baseFavoriteBottom;
          final details = widget.galleryCollapsible && _detailsCreated
              ? SliverMainAxisGroup(
                  key: _detailsKey, slivers: widget.sliversBuilder(context))
              : null;
          return _FavoriteBoundaryScope(
              report: _reportFavoriteBoundary,
              bottomExclusion: favoriteBottom + 56 + 12,
              child: Stack(children: [
                Positioned.fill(
                  child: NotificationListener<ScrollNotification>(
                    onNotification: _galleryScroll,
                    child: CustomScrollView(
                      key: const ValueKey('pixiv-detail-page-scroll'),
                      controller: _scrollController,
                      slivers: [
                        if (widget.images.isNotEmpty)
                          _gallerySliver(context)
                        else
                          SliverToBoxAdapter(
                              child: SizedBox(
                                  height: constraints.maxWidth,
                                  child: Center(
                                      child: widget.imagesLoading
                                          ? const CircularProgressIndicator()
                                          : const Icon(
                                              Icons
                                                  .image_not_supported_outlined,
                                              size: 48)))),
                        if (!widget.galleryCollapsible || _detailsHandedOff)
                          SliverToBoxAdapter(
                              child: KeyedSubtree(
                                  key: _galleryHeaderKey,
                                  child: _header(context))),
                        if (widget.galleryCollapsible &&
                            !_detailsHandedOff &&
                            _galleryRestorePadding > 0)
                          SliverToBoxAdapter(
                              child: SizedBox(height: _galleryRestorePadding)),
                        if (!widget.galleryCollapsible)
                          ...widget.sliversBuilder(context)
                        else if (_detailsHandedOff)
                          if (_panelOpen)
                            SliverToBoxAdapter(
                                child: SizedBox(height: _detailsExtent))
                          else if (details != null)
                            details,
                        const SliverToBoxAdapter(child: SizedBox(height: 88)),
                      ],
                    ),
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
                if (widget.galleryCollapsible &&
                    !_detailsHandedOff &&
                    !_panelOpen)
                  Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: _galleryHeader(context, compact: true)),
                if (details != null && !_detailsHandedOff && !_panelOpen)
                  Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      height: 0,
                      child: TickerMode(
                          enabled: false,
                          child: IgnorePointer(
                              child: CustomScrollView(
                                  key: const ValueKey(
                                      'pixiv-detail-parked-scroll'),
                                  controller: _panelScrollController,
                                  cacheExtent: 0,
                                  slivers: [details])))),
                if (_panelOpen && details != null)
                  _detailsPanel(context, constraints, details),
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
                                        child: widget.onlineBookmarkAnimations
                                            ? _onlineFavorite(visible)
                                            : Semantics(
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
                                                      onLongPress: widget
                                                              .favoriteBusy
                                                          ? null
                                                          : widget
                                                              .onFavoriteLongPress,
                                                      child: SizedBox.square(
                                                        dimension: 56,
                                                        child: Icon(
                                                          widget.favoriteBusy ||
                                                                  widget
                                                                      .isFavorited
                                                              ? Icons.favorite
                                                              : Icons
                                                                  .favorite_border,
                                                          size: 28,
                                                          color: widget
                                                                  .favoriteBusy
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
    if (!widget.galleryCollapsible) return scaffold;
    return PopScope(
      canPop: !_panelOpen,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _panelOpen) _setDetailsPanel(false);
      },
      child: scaffold,
    );
  }

  Widget _onlineFavorite(bool visible) => Material(
        color: Colors.white,
        elevation: 4,
        shape: const CircleBorder(),
        child: PixivBookmarkButton(
          key: const ValueKey('pixiv-detail-favorite'),
          isBookmarked: widget.isFavorited,
          busy: widget.favoriteBusy,
          enabled: widget.onFavorite != null,
          active: widget.favoriteActive && (visible || widget.favoriteBusy),
          identity: widget.favoriteIdentity,
          visualEpoch: widget.favoriteVisualEpoch,
          event: widget.favoriteEvent,
          onPressed: widget.onFavorite,
          onLongPress: widget.onFavoriteLongPress,
          size: 56,
          iconSize: 28,
          activeColor: const Color(0xE6E0245E),
          inactiveColor: const Color(0xE6E0245E),
          circularBackground: true,
        ),
      );

  Widget _toolbarButton(IconData icon, String label, VoidCallback action) =>
      IconButton(
        tooltip: label,
        onPressed: action,
        icon: Icon(icon,
            color: Colors.white,
            shadows: const [Shadow(color: Colors.black, blurRadius: 3)]),
      );

  Widget _gallerySliver(BuildContext context) => SliverList(
        key: const ValueKey('pixiv-detail-images'),
        delegate: SliverChildBuilderDelegate(
          (context, index) => _image(context, widget.images[index], index),
          childCount: widget.images.length,
        ),
      );

  Widget _detailsPanel(
      BuildContext context, BoxConstraints constraints, Widget details) {
    final colors = Theme.of(context).colorScheme;
    return Positioned.fill(
        child: Stack(children: [
      Positioned.fill(
          child: Semantics(
        button: true,
        label: '点图片返回看图',
        child: GestureDetector(
          key: const ValueKey('pixiv-detail-panel-background'),
          behavior: HitTestBehavior.opaque,
          onTap: () => _setDetailsPanel(false),
          child: ColoredBox(color: Colors.black.withValues(alpha: .24)),
        ),
      )),
      Align(
        alignment: Alignment.bottomCenter,
        child: SizedBox(
          key: const ValueKey('pixiv-detail-panel'),
          height: constraints.maxHeight * .75,
          child: Semantics(
            scopesRoute: true,
            explicitChildNodes: true,
            namesRoute: true,
            label: '作品详情',
            child: Material(
              color: colors.surface,
              elevation: 8,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(24)),
              clipBehavior: Clip.antiAlias,
              child: Column(children: [
                const SizedBox(height: 8),
                Container(
                    width: 32,
                    height: 4,
                    decoration: BoxDecoration(
                        color: colors.onSurfaceVariant.withValues(alpha: .45),
                        borderRadius: BorderRadius.circular(4))),
                _galleryHeader(context, panel: true),
                Expanded(
                    child: CustomScrollView(
                  key: const ValueKey('pixiv-detail-panel-scroll'),
                  controller: _panelScrollController,
                  slivers: [
                    details,
                    const SliverToBoxAdapter(child: SizedBox(height: 24))
                  ],
                )),
              ]),
            ),
          ),
        ),
      ),
    ]));
  }

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

  Widget _galleryHeader(BuildContext context,
          {bool compact = false, bool panel = false}) =>
      Container(
        key: ValueKey(panel
            ? 'pixiv-details-panel-header'
            : compact
                ? 'pixiv-detail-entry-bar'
                : 'pixiv-gallery-header'),
        color: Theme.of(context).colorScheme.surface,
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: LayoutBuilder(builder: (context, constraints) {
          final separateAction = constraints.maxWidth < 320 ||
              MediaQuery.textScalerOf(context).scale(12) > 18;
          return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!compact) ...[
                  Text(widget.title,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                ],
                Row(children: [
                  _authorAvatar(context),
                  const SizedBox(width: 4),
                  Semantics(
                    button: true,
                    expanded: _panelOpen,
                    child: IconButton(
                      key: ValueKey(panel
                          ? 'pixiv-detail-panel-toggle'
                          : 'pixiv-gallery-expansion-toggle'),
                      tooltip: panel ? '收起详情' : '展开详情',
                      constraints:
                          const BoxConstraints(minWidth: 48, minHeight: 48),
                      onPressed:
                          _entryActive ? () => _setDetailsPanel(!panel) : null,
                      icon: Icon(panel ? Icons.expand_more : Icons.expand_less),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(widget.author,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12)),
                  ),
                  if (!separateAction) ...[
                    const SizedBox(width: 8),
                    _galleryAction(context),
                  ],
                ]),
                if (separateAction)
                  Align(
                      alignment: Alignment.centerRight,
                      child: _galleryAction(context)),
              ]);
        }),
      );

  Widget _authorAvatar(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    Widget fallback() => CircleAvatar(
        key: const ValueKey('pixiv-gallery-author-avatar'),
        radius: 16,
        backgroundColor: colors.secondaryContainer,
        child: const Icon(Icons.person_outline, size: 20));
    if (widget.authorAvatarUrl.isEmpty) return fallback();
    return ClipOval(
      key: const ValueKey('pixiv-gallery-author-avatar'),
      child: Image(
        image: onlineCoverProvider(url: widget.authorAvatarUrl, headers: const {
          'Referer': 'https://www.pixiv.net/',
          'User-Agent': PixivNetwork.pixivWebUA,
        }),
        width: 32,
        height: 32,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => fallback(),
      ),
    );
  }

  Widget _galleryAction(BuildContext context) => Tooltip(
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
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
      );

  Widget _header(BuildContext context) => widget.galleryCollapsible
      ? _galleryHeader(context)
      : Container(
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
                onLongPress:
                    widget.actionBusy ? null : widget.onActionLongPress,
                child: ConstrainedBox(
                  constraints:
                      const BoxConstraints(minHeight: 48, minWidth: 48),
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

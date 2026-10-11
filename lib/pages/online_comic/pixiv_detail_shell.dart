import 'dart:math' as math;

import 'package:flutter/gestures.dart';
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
    this.previewProvider,
    this.previewFallbackProvider,
    this.contentIdentity,
  });

  final String key;
  final ImageProvider<Object>? provider;

  /// Already displayed cover providers retain their original resize/cache keys.
  final ImageProvider<Object>? previewProvider;
  final ImageProvider<Object>? previewFallbackProvider;

  /// A retry/content epoch independent of the stable geometry key.
  final Object? contentIdentity;
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
    this.showDetailsForShortGallery = false,
    this.authorAvatarUrl = '',
    this.authorAvatarFallbackUrl = '',
    this.authorAvatarLoading = false,
    this.authorAvatarError,
    this.onRetryAuthorAvatar,
    this.onGalleryExpansionChanged,
    this.deferHeaderUntilImageReady = false,
    this.showSingleAuthorAvatar = false,
    this.imageReadinessIdentity,
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
  final bool showDetailsForShortGallery;
  final String authorAvatarUrl;
  final String authorAvatarFallbackUrl;
  final bool authorAvatarLoading;
  final String? authorAvatarError;
  final VoidCallback? onRetryAuthorAvatar;

  /// Compatibility with the online entry: false while the detail panel is
  /// open, true in image/inline browsing. The entry omits recommendations from
  /// [sliversBuilder] while this panel is open. No initial callback is emitted.
  final ValueChanged<bool>? onGalleryExpansionChanged;

  /// Online-only opt-in: preserve header layout while waiting for usable pixels.
  final bool deferHeaderUntilImageReady;
  final bool showSingleAuthorAvatar;
  final Object? imageReadinessIdentity;

  @override
  State<PixivDetailShell> createState() => _PixivDetailShellState();
}

class _PixivDetailShellState extends State<PixivDetailShell>
    with SingleTickerProviderStateMixin {
  final _scrollController = _GeometryScrollController();
  late final AnimationController _panelAnimation;
  bool _panelTargetOpen = false;
  final _galleryHeaderKey = GlobalKey(debugLabel: 'pixiv-gallery-header');
  final _detailsKey = GlobalKey(debugLabel: 'pixiv-single-details-group');
  final _panelScrollController = ScrollController();
  bool _panelOpen = false;
  bool _detailsCreated = false;
  bool _detailsHandedOff = false;
  Drag? _headerDrag;
  bool _userScroll = false;
  bool _handoffQueued = false;
  int? _shortDetailsScheduledEpoch;
  double _headerExtent = 72;
  double _viewportExtent = 0;
  double _favoriteBottom = 80;
  double _detailsExtent = 0;
  bool _panelOpenedFromHandoff = false;
  int _galleryEpoch = 0;
  String? _galleryIdentity;
  final ValueNotifier<bool> _favoriteVisible = ValueNotifier(true);
  double _width = 0;
  int _imageIndex = 0;
  List<double> _pageEnds = const [];
  final Map<String, double> _ratios = {};
  bool _boundaryReached = false;
  bool _counterSyncPending = false;
  bool _geometryStateSyncPending = false;
  bool _favoriteSyncPending = false;
  int _imageReadinessEpoch = 0;
  final Map<String, Object> _readyImageTokens = {};

  Object _contentToken(PixivDetailImage image) => (
        image.key,
        image.contentIdentity,
        image.provider,
        image.previewProvider,
        image.previewFallbackProvider,
      );

  bool get _headerContentReady {
    if (!widget.deferHeaderUntilImageReady) return true;
    if (widget.imageError != null) return true;
    if (widget.images.isEmpty) return !widget.imagesLoading;
    final first = widget.images.first;
    return _readyImageTokens[first.key] == _contentToken(first);
  }

  void _imageContentReady(
      String key, Object token, int epoch, Object? readinessIdentity) {
    if (!mounted ||
        epoch != _imageReadinessEpoch ||
        readinessIdentity != widget.imageReadinessIdentity) {
      return;
    }
    final index = widget.images.indexWhere((image) => image.key == key);
    if (index < 0 ||
        _contentToken(widget.images[index]) != token ||
        _readyImageTokens[key] == token) {
      return;
    }
    setState(() => _readyImageTokens[key] = token);
  }

  Widget _gateHeader(Widget child, {bool panel = false}) {
    if (!widget.deferHeaderUntilImageReady) return child;
    final ready = _headerContentReady;
    final host = panel ? 'panel' : 'main';
    return IgnorePointer(
      key: ValueKey('pixiv-header-ready-hit-test-$host'),
      ignoring: !ready,
      child: ExcludeSemantics(
        excluding: !ready,
        child: Opacity(
          key: ValueKey('pixiv-header-ready-opacity-$host'),
          opacity: ready ? 1 : 0,
          child: child,
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _panelAnimation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      reverseDuration: const Duration(milliseconds: 200),
    )..addStatusListener((status) {
        if (status == AnimationStatus.dismissed &&
            _panelOpen &&
            !_panelTargetOpen) {
          _finishPanelClose();
        }
      });
    _scrollController.addListener(_scrollChanged);
    _scrollController.geometry.addListener(_geometryStateChanged);
    if (widget.images.isNotEmpty) _galleryIdentity = widget.images.first.key;
  }

  bool get _entryActive =>
      PixivDetailEntryScope.isActiveOf(context) &&
      TickerMode.valuesOf(context).enabled;

  @override
  void didUpdateWidget(covariant PixivDetailShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageReadinessIdentity != widget.imageReadinessIdentity) {
      _imageReadinessEpoch++;
      _readyImageTokens.clear();
    } else {
      _readyImageTokens.removeWhere((key, token) => !widget.images
          .any((image) => image.key == key && _contentToken(image) == token));
    }
    final identity = widget.images.isEmpty ? null : widget.images.first.key;
    final replaced = _galleryIdentity != null &&
        identity != null &&
        identity != _galleryIdentity;
    if (replaced ||
        (oldWidget.galleryCollapsible && !widget.galleryCollapsible)) {
      final notify = _panelOpen;
      _panelTargetOpen = false;
      _panelOpen = false;
      _panelAnimation.stop();
      _panelAnimation.value = 0;
      _detailsCreated = false;
      _detailsHandedOff = false;
      _userScroll = false;
      _handoffQueued = false;
      _panelOpenedFromHandoff = false;
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

  bool get _shortGalleryNeedsDetails =>
      widget.showDetailsForShortGallery &&
      widget.galleryCollapsible &&
      _entryActive &&
      (ModalRoute.of(context)?.isCurrent ?? true) &&
      !widget.imagesLoading &&
      _headerContentReady &&
      !_panelOpen &&
      !_detailsHandedOff &&
      _pageEnds.isNotEmpty &&
      _pageEnds.last + _headerExtent + 88 < _viewportExtent;

  void _scheduleShortGalleryDetails() {
    if (!_shortGalleryNeedsDetails ||
        _shortDetailsScheduledEpoch == _galleryEpoch) {
      return;
    }
    final epoch = _galleryEpoch;
    _shortDetailsScheduledEpoch = epoch;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _shortDetailsScheduledEpoch != epoch) return;
      _shortDetailsScheduledEpoch = null;
      if (epoch != _galleryEpoch || !_shortGalleryNeedsDetails) return;
      setState(() {
        _detailsCreated = true;
        _detailsHandedOff = true;
        _boundaryReached = false;
        _galleryEpoch++;
      });
      widget.onGalleryExpansionChanged?.call(true);
      _scheduleFavoriteVisibilitySync();
    });
  }

  void _setDetailsPanel(bool open) {
    if (!widget.galleryCollapsible ||
        open == _panelTargetOpen ||
        (open && !_entryActive)) {
      return;
    }
    if (open && !_panelOpen) {
      _cancelHeaderDrag();
      if (_scrollController.hasClients) {
        final position = _scrollController.position;
        if (position is ScrollPositionWithSingleContext) position.goIdle();
        final render = _detailsKey.currentContext?.findRenderObject();
        final measured =
            render is RenderSliver ? render.geometry?.scrollExtent ?? 0.0 : 0.0;
        final galleryEnd = _pageEnds.isEmpty ? _width : _pageEnds.last;
        _detailsExtent = math.max(
            measured,
            position.maxScrollExtent +
                position.viewportDimension -
                galleryEnd -
                _headerExtent -
                88);
      }
      setState(() {
        _panelOpenedFromHandoff = _detailsHandedOff;
        _panelOpen = true;
        _panelTargetOpen = true;
        _detailsCreated = true;
        _userScroll = false;
        _handoffQueued = false;
        _galleryEpoch++;
      });
      widget.onGalleryExpansionChanged?.call(false);
    } else {
      setState(() => _panelTargetOpen = open);
    }
    if (MediaQuery.disableAnimationsOf(context)) {
      _panelAnimation.value = open ? 1 : 0;
      if (!open && _panelOpen) _finishPanelClose();
    } else {
      if (open) {
        _panelAnimation.animateTo(1,
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic);
      } else {
        _panelAnimation.animateBack(0,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInCubic);
      }
    }
    _scheduleFavoriteVisibilitySync();
  }

  void _finishPanelClose() {
    if (!mounted || !_panelOpen || _panelTargetOpen) return;
    setState(() {
      _panelOpen = false;
      _detailsHandedOff = _panelOpenedFromHandoff;
      _detailsExtent = 0;
      if (!_detailsHandedOff) _boundaryReached = false;
      _galleryEpoch++;
    });
    widget.onGalleryExpansionChanged?.call(true);
    _scheduleFavoriteVisibilitySync();
  }

  void _startHeaderDrag(DragStartDetails details) {
    if (!_entryActive || !_scrollController.hasClients) return;
    _headerDrag?.cancel();
    _headerDrag = _scrollController.position.drag(details, () {
      _headerDrag = null;
    });
  }

  void _updateHeaderDrag(DragUpdateDetails details) {
    _headerDrag?.update(details);
  }

  void _endHeaderDrag(DragEndDetails details) {
    _headerDrag?.end(details);
    _headerDrag = null;
  }

  void _cancelHeaderDrag() {
    _headerDrag?.cancel();
    _headerDrag = null;
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
    final input = notification is ScrollUpdateNotification &&
            (notification.dragDetails != null ||
                _scrollController.hasClients &&
                    _scrollController.position.isScrollingNotifier.value) ||
        notification is OverscrollNotification &&
            (notification.dragDetails != null ||
                _scrollController.hasClients &&
                    _scrollController.position.isScrollingNotifier.value);
    if (_userScroll &&
        input &&
        !_handoffQueued &&
        _pageEnds.isNotEmpty &&
        _scrollController.hasClients) {
      final bottom =
          notification.metrics.pixels + notification.metrics.viewportDimension;
      // Prepare just before the stable author anchor leaves its dock. This
      // adds content only BELOW that anchor; its visual position never changes.
      final enter = down &&
          !_detailsHandedOff &&
          bottom >= _pageEnds.last + _headerExtent - 24;
      // Park only when all details are below the viewport again. Removing a
      // visible tail would clamp the position and turn a reverse drag into a jump.
      final leave = up && _detailsHandedOff && bottom <= _pageEnds.last;
      if (enter || leave) {
        _handoffQueued = true;
        final epoch = _galleryEpoch;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || epoch != _galleryEpoch) return;
          _handoffQueued = false;
          if (!_entryActive || _panelOpen) return;
          setState(() {
            _detailsCreated = true;
            _detailsHandedOff = enter;
            _boundaryReached = false;
            if (leave) _detailsExtent = 0;
            _galleryEpoch++;
          });
          widget.onGalleryExpansionChanged?.call(enter);
          _scheduleFavoriteVisibilitySync();
        });
      }
    }
    if (notification is ScrollEndNotification) _userScroll = false;
    return false;
  }

  void _imageDimensionsChanged(String key, double ratio) {
    final index = widget.images.indexWhere((image) => image.key == key);
    if (!mounted || index < 0 || _ratios[key] == ratio) return;
    var correction = 0.0;
    if (_scrollController.hasClients &&
        _pageEnds.length == widget.images.length) {
      final position = _scrollController.position;
      final pixels = position.pixels;
      final oldStart = index == 0 ? 0.0 : _pageEnds[index - 1];
      final oldEnd = _pageEnds[index];
      final delta = _width / ratio - (oldEnd - oldStart);
      final headerTop = _pageEnds.last - pixels;
      final headerFollowing =
          headerTop <= position.viewportDimension - _headerExtent;
      if (headerFollowing || oldEnd <= pixels) {
        correction = delta;
      } else if (oldStart < pixels) {
        correction = delta * ((pixels - oldStart) / (oldEnd - oldStart));
      }
      // Geometry correction is not a user jump and must not restart activity,
      // activate deferred details, or notify listeners against the old extent.
      if (correction.abs() > .01) position.correctBy(correction);
    }
    setState(() {
      _ratios[key] = ratio;
      _measureImages();
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

  void _geometryStateChanged() {
    if (_geometryStateSyncPending) return;
    _geometryStateSyncPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _geometryStateSyncPending = false;
      if (mounted) _scrollChanged();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _scrollChanged() {
    _scheduleFavoriteVisibilitySync();
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
      final naturalHeaderTop =
          _pageEnds.isEmpty || !_scrollController.hasClients
              ? double.infinity
              : _pageEnds.last - _scrollController.position.pixels;
      final dockTop = _viewportExtent - _headerExtent;
      final headerTop = math.min(naturalHeaderTop, dockTop);
      // Parked details can still report an author boundary. Neither that report
      // nor the docked header's exclusion band hides the gallery's fixed action.
      // Handoff is prepared 24dp BEFORE the header leaves its dock; programmatic
      // scrolls can also undock it WITHOUT handoff. Only the physical dock gets
      // this override; all undocked headers keep the old boundary/overlap rules.
      final browsingGallery = widget.galleryCollapsible &&
          !_panelOpen &&
          naturalHeaderTop >= dockTop;
      final overlapsHeader = widget.galleryCollapsible &&
          !_panelOpen &&
          headerTop < _viewportExtent - _favoriteBottom + 12 &&
          headerTop + _headerExtent >
              _viewportExtent - _favoriteBottom - 56 - 12;
      _favoriteVisible.value = browsingGallery ||
          ((atTop || !_boundaryReached || _panelOpen) && !overlapsHeader);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    _cancelHeaderDrag();
    _panelAnimation.dispose();
    _scrollController.geometry.removeListener(_geometryStateChanged);
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
          final oldWidth = _width;
          final oldEnd = _pageEnds.isEmpty ? 0.0 : _pageEnds.last;
          final oldHeader = _headerExtent;
          final position =
              _scrollController.hasClients ? _scrollController.position : null;
          final oldPixels = position?.pixels ?? 0.0;
          final followingHeader = oldWidth > 0 &&
              position != null &&
              oldEnd - oldPixels <= _viewportExtent - oldHeader;
          if (_width != constraints.maxWidth) {
            _width = constraints.maxWidth;
            _measureImages();
          }
          _headerExtent = _galleryHeaderExtent(context, constraints.maxWidth);
          if (position != null && oldWidth > 0 && widget.galleryCollapsible) {
            var corrected = oldPixels;
            if (oldWidth != _width) {
              corrected = followingHeader && _pageEnds.isNotEmpty
                  ? oldPixels + _pageEnds.last - oldEnd
                  : oldPixels * _width / oldWidth;
            }
            if (oldPixels >= oldEnd + oldHeader) {
              corrected += _headerExtent - oldHeader;
            }
            if ((corrected - oldPixels).abs() > .01) {
              position.correctBy(corrected - oldPixels);
            }
          }
          final baseFavoriteBottom =
              math.min(80.0, constraints.maxHeight * .15);
          final favoriteBottom = widget.galleryCollapsible
              ? math.max(baseFavoriteBottom, _headerExtent + 8)
              : baseFavoriteBottom;
          _viewportExtent = constraints.maxHeight;
          _favoriteBottom = favoriteBottom;
          _scheduleShortGalleryDetails();
          _scheduleFavoriteVisibilitySync();
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
                        if (widget.galleryCollapsible)
                          SliverToBoxAdapter(
                            key: const ValueKey('pixiv-author-header-anchor'),
                            child: SizedBox(height: _headerExtent),
                          )
                        else
                          SliverToBoxAdapter(
                              child: _gateHeader(_header(context))),
                        if (!widget.galleryCollapsible)
                          ...widget.sliversBuilder(context)
                        else if (_detailsHandedOff)
                          if (_panelOpen)
                            SliverToBoxAdapter(
                                child: SizedBox(height: _detailsExtent))
                          else if (details != null)
                            SliverMainAxisGroup(
                                key: const ValueKey('pixiv-inline-details'),
                                slivers: [details]),
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
                      widget.imagesLoading
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
                if (widget.galleryCollapsible && !_panelOpen)
                  Positioned.fill(
                    child: ClipRect(
                      child: _DockedAuthorHeader(
                        controller: _scrollController,
                        galleryExtent:
                            _pageEnds.isEmpty ? _width : _pageEnds.last,
                        child: _gateHeader(GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onVerticalDragStart: _startHeaderDrag,
                          onVerticalDragUpdate: _updateHeaderDrag,
                          onVerticalDragEnd: _endHeaderDrag,
                          onVerticalDragCancel: _cancelHeaderDrag,
                          child: KeyedSubtree(
                            key: _galleryHeaderKey,
                            child: _galleryHeader(context),
                          ),
                        )),
                      ),
                    ),
                  ),
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

  Widget _gallerySliver(BuildContext context) => SliverVariedExtentList(
        key: const ValueKey('pixiv-detail-images'),
        itemExtentBuilder: (index, dimensions) {
          if (index >= _pageEnds.length) return null;
          return _pageEnds[index] - (index == 0 ? 0 : _pageEnds[index - 1]);
        },
        delegate: _GalleryChildrenDelegate(
          (context, index) => _image(context, widget.images[index], index),
          childCount: widget.images.length,
          extent: _pageEnds.isEmpty ? 0 : _pageEnds.last,
        ),
      );

  Widget _detailsPanel(
      BuildContext context, BoxConstraints constraints, Widget details) {
    final colors = Theme.of(context).colorScheme;
    return Positioned.fill(
      child: AnimatedBuilder(
        animation: _panelAnimation,
        builder: (context, child) => Stack(children: [
          Positioned.fill(
            child: Semantics(
              button: true,
              label: '点图片返回看图',
              child: GestureDetector(
                key: const ValueKey('pixiv-detail-panel-background'),
                behavior: HitTestBehavior.opaque,
                onTap: () => _setDetailsPanel(false),
                child: ColoredBox(
                  key: const ValueKey('pixiv-detail-panel-scrim'),
                  color: Colors.black
                      .withValues(alpha: .24 * _panelAnimation.value),
                ),
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Transform.translate(
              offset: Offset(
                  0, constraints.maxHeight * .75 * (1 - _panelAnimation.value)),
              child: child,
            ),
          ),
        ]),
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
                _gateHeader(_galleryHeader(context, panel: true), panel: true),
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
    );
  }

  Widget _image(BuildContext context, PixivDetailImage image, int index) {
    final value = _ratios[image.key] ?? image.aspectRatio;
    final ratio = value.isFinite && value > 0 ? value : .75;
    final token = _contentToken(image);
    final readinessEpoch = _imageReadinessEpoch;
    final readinessIdentity = widget.imageReadinessIdentity;
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
          child: _MeasuredDetailImage(
            key:
                ValueKey((_contentToken(image), widget.imageReadinessIdentity)),
            provider: image.provider == null
                ? null
                : ResizeImage.resizeIfNeeded(
                    (_width * MediaQuery.devicePixelRatioOf(context) * 1.2)
                        .round(),
                    null,
                    image.provider!,
                  ),
            previewProvider: image.previewProvider,
            previewFallbackProvider: image.previewFallbackProvider,
            loading: widget.imagesLoading,
            errorBuilder: fallback,
            onRetry: widget.onRetryImages,
            onReady: widget.deferHeaderUntilImageReady
                ? () => _imageContentReady(
                    image.key, token, readinessEpoch, readinessIdentity)
                : null,
            onDimensions: image.aspectRatioKnown
                ? null
                : (ratio) => _imageDimensionsChanged(image.key, ratio),
          ),
        ),
      ),
    );
  }

  TextStyle _headerTitleStyle(BuildContext context) => Theme.of(context)
      .textTheme
      .titleSmall!
      .copyWith(fontSize: 14, fontWeight: FontWeight.w600);

  TextStyle _headerAuthorStyle(BuildContext context) =>
      Theme.of(context).textTheme.bodySmall!.copyWith(fontSize: 12);

  bool _separateGalleryAction(BuildContext context, double innerWidth) =>
      innerWidth < 320 || MediaQuery.textScalerOf(context).scale(12) > 18;

  int _headerTextLines(BuildContext context) =>
      MediaQuery.textScalerOf(context).scale(12) > 18 ? 2 : 1;

  double _galleryHeaderExtent(BuildContext context, double width) {
    final innerWidth = math.max(1.0, width - 28);
    final separateAction = _separateGalleryAction(context, innerWidth);
    final textScaler = MediaQuery.textScalerOf(context);
    double measure(String text, TextStyle style, double width,
        {int? maxLines}) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: Directionality.of(context),
        textScaler: textScaler,
        maxLines: maxLines,
        ellipsis: maxLines == null ? null : '…',
      )..layout(maxWidth: width);
      final result = maxLines == null ? painter.width : painter.height;
      painter.dispose();
      return result;
    }

    final actionWidth = math.max(
        48.0,
        38 +
            measure(
                widget.actionLabel,
                Theme.of(context).textTheme.bodyMedium!.copyWith(fontSize: 12),
                double.infinity));
    final textWidth = math.max(1.0,
        innerWidth - 48 - 4 - 48 - 8 - (separateAction ? 0 : actionWidth + 8));
    final lines = _headerTextLines(context);
    final textHeight = measure(
            widget.title, _headerTitleStyle(context), textWidth,
            maxLines: lines) +
        2 +
        measure(widget.author, _headerAuthorStyle(context), textWidth,
            maxLines: lines);
    return 24 + math.max(48.0, textHeight) + (separateAction ? 48 : 0);
  }

  Widget _galleryHeader(BuildContext context, {bool panel = false}) =>
      Container(
        key: ValueKey(
            panel ? 'pixiv-details-panel-header' : 'pixiv-gallery-header'),
        color: Theme.of(context).colorScheme.surface,
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: LayoutBuilder(builder: (context, constraints) {
          final separateAction =
              _separateGalleryAction(context, constraints.maxWidth);
          final lines = _headerTextLines(context);
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _AuthorHeaderRow(
                controller: panel ? null : _scrollController,
                galleryExtent: _pageEnds.isEmpty ? _width : _pageEnds.last,
                viewportExtent: _viewportExtent,
                headerExtent: _headerExtent,
                children: [
                  _HeaderArrowSlot(
                    key: const ValueKey('pixiv-author-header-arrow'),
                    child: Semantics(
                      button: true,
                      expanded: _panelTargetOpen,
                      child: IconButton(
                        key: ValueKey(panel
                            ? 'pixiv-detail-panel-toggle'
                            : 'pixiv-gallery-expansion-toggle'),
                        tooltip: panel && _panelTargetOpen ? '收起详情' : '展开详情',
                        constraints:
                            const BoxConstraints(minWidth: 48, minHeight: 48),
                        onPressed: _entryActive
                            ? () => _setDetailsPanel(!_panelTargetOpen)
                            : null,
                        icon: Icon(panel && _panelTargetOpen
                            ? Icons.expand_more
                            : Icons.expand_less),
                      ),
                    ),
                  ),
                  MergeSemantics(
                    child: Semantics(
                      button: true,
                      expanded: _panelTargetOpen,
                      enabled: _entryActive,
                      child: Tooltip(
                        message: panel && _panelTargetOpen ? '收起详情' : '展开详情',
                        child: InkWell(
                          key: const ValueKey('pixiv-author-header-cluster'),
                          onTap: _entryActive
                              ? () => _setDetailsPanel(!_panelTargetOpen)
                              : null,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 48),
                            child: Row(children: [
                              _authorAvatar(context),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Semantics(
                                  label: '${widget.title}，作者：${widget.author}',
                                  excludeSemantics: true,
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(widget.title,
                                          key: const ValueKey(
                                              'pixiv-author-header-title'),
                                          maxLines: lines,
                                          overflow: TextOverflow.ellipsis,
                                          style: _headerTitleStyle(context)),
                                      const SizedBox(height: 2),
                                      Text(widget.author,
                                          key: const ValueKey(
                                              'pixiv-author-header-name'),
                                          maxLines: lines,
                                          overflow: TextOverflow.ellipsis,
                                          style: _headerAuthorStyle(context)),
                                    ],
                                  ),
                                ),
                              ),
                            ]),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (!separateAction) _galleryAction(context),
                ],
              ),
              if (separateAction)
                Align(
                    alignment: Alignment.centerRight,
                    child: _galleryAction(context)),
            ],
          );
        }),
      );

  Widget _authorAvatar(BuildContext context, {bool single = false}) {
    final colors = Theme.of(context).colorScheme;
    Widget fallback(String label, {bool retry = false}) {
      final avatar = Semantics(
        label: label,
        image: true,
        child: CircleAvatar(
            radius: 16,
            backgroundColor: colors.secondaryContainer,
            child: const Icon(Icons.person_outline, size: 20)),
      );
      return retry && widget.onRetryAuthorAvatar != null
          ? InkWell(
              onTap: _entryActive ? widget.onRetryAuthorAvatar : null,
              customBorder: const CircleBorder(),
              child: Center(child: avatar),
            )
          : Center(child: avatar);
    }

    Widget imageFor(String url, {bool allowFallback = true}) => ClipOval(
          child: Image(
            image: onlineCoverProvider(url: url, headers: const {
              'Referer': 'https://www.pixiv.net/',
              'User-Agent': PixivNetwork.pixivWebUA,
            }),
            width: 32,
            height: 32,
            fit: BoxFit.cover,
            excludeFromSemantics: true,
            gaplessPlayback: true,
            frameBuilder: (context, child, frame, synchronous) =>
                frame != null || synchronous
                    ? Semantics(label: '作者头像', image: true, child: child)
                    : fallback('作者头像加载中'),
            errorBuilder: (_, __, ___) {
              final other = widget.authorAvatarFallbackUrl.trim();
              if (allowFallback && other.isNotEmpty && other != url) {
                return imageFor(other, allowFallback: false);
              }
              return fallback('作者头像加载失败，重试作者信息', retry: true);
            },
          ),
        );
    final url = widget.authorAvatarUrl.trim();
    return SizedBox.square(
      key: ValueKey(single
          ? 'pixiv-single-author-avatar'
          : 'pixiv-gallery-author-avatar'),
      dimension: 48,
      child: url.isNotEmpty
          ? Center(child: imageFor(url))
          : fallback(
              widget.authorAvatarLoading
                  ? '作者头像资料加载中'
                  : widget.authorAvatarError != null
                      ? '作者头像资料加载失败：${widget.authorAvatarError}'
                      : '作者尚未提供头像',
              retry: widget.authorAvatarError != null),
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
            if (widget.showSingleAuthorAvatar) ...[
              _authorAvatar(context, single: true),
              const SizedBox(width: 8),
            ],
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

// Silent viewport corrections use a paint/semantics signal, not a scroll event.
// Fixed-size author content reads the final position for all spatial transforms.
class _GeometryScrollController extends ScrollController {
  final geometry = ChangeNotifier();

  @override
  ScrollPosition createScrollPosition(ScrollPhysics physics,
          ScrollContext context, ScrollPosition? oldPosition) =>
      _GeometryScrollPosition(
        physics: physics,
        context: context,
        initialPixels: initialScrollOffset,
        keepScrollOffset: keepScrollOffset,
        oldPosition: oldPosition,
        geometryChanged: geometry.notifyListeners,
      );

  @override
  void dispose() {
    super.dispose();
    geometry.dispose();
  }
}

class _GeometryScrollPosition extends ScrollPositionWithSingleContext {
  _GeometryScrollPosition({
    required super.physics,
    required super.context,
    required super.initialPixels,
    required super.keepScrollOffset,
    required super.oldPosition,
    required this.geometryChanged,
  });
  final VoidCallback geometryChanged;

  @override
  void correctPixels(double value) {
    final changed = !hasPixels || pixels != value;
    super.correctPixels(value);
    if (changed) geometryChanged();
  }

  @override
  void correctBy(double correction) {
    super.correctBy(correction);
    if (correction != 0) geometryChanged();
  }
}

class _HeaderArrowSlot extends SingleChildRenderObjectWidget {
  const _HeaderArrowSlot({super.key, required super.child});
  @override
  _RenderHeaderArrow createRenderObject(BuildContext context) =>
      _RenderHeaderArrow();
}

class _RenderHeaderArrow extends RenderProxyBox {
  double get opacity => 1 - (parent! as _RenderAuthorHeaderRow).progress;
  double get visibleWidth => 52 * opacity;

  @override
  bool get alwaysNeedsCompositing => child != null;

  @override
  void performLayout() {
    child!.layout(const BoxConstraints.tightFor(width: 48, height: 48));
    size = constraints.constrain(const Size(52, 48));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (opacity <= 0) return;
    context.pushClipRect(needsCompositing, offset,
        Rect.fromLTWH(0, 0, visibleWidth, size.height), (context, offset) {
      context.pushOpacity(offset, (255 * opacity).round(),
          (context, offset) => context.paintChild(child!, offset));
    });
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) =>
      visibleWidth >= 48 &&
      position.dx < visibleWidth &&
      super.hitTest(result, position: position);

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    if (visibleWidth >= 48) super.visitChildrenForSemantics(visitor);
  }
}

class _AuthorHeaderRow extends MultiChildRenderObjectWidget {
  const _AuthorHeaderRow({
    required this.controller,
    required this.galleryExtent,
    required this.viewportExtent,
    required this.headerExtent,
    required super.children,
  });
  final _GeometryScrollController? controller;
  final double galleryExtent, viewportExtent, headerExtent;

  @override
  _RenderAuthorHeaderRow createRenderObject(BuildContext context) =>
      _RenderAuthorHeaderRow(
          controller, galleryExtent, viewportExtent, headerExtent);

  @override
  void updateRenderObject(BuildContext context, _RenderAuthorHeaderRow object) {
    object.update(controller, galleryExtent, viewportExtent, headerExtent);
  }
}

class _AuthorHeaderParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderAuthorHeaderRow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox,
            ContainerBoxParentData<RenderBox>>,
        RenderBoxContainerDefaultsMixin<RenderBox,
            ContainerBoxParentData<RenderBox>> {
  _RenderAuthorHeaderRow(this._controller, this._galleryExtent,
      this._viewportExtent, this._headerExtent);
  _GeometryScrollController? _controller;
  double _galleryExtent, _viewportExtent, _headerExtent;

  double get progress {
    final pixels =
        _controller?.hasClients == true ? _controller!.position.pixels : 0.0;
    return _controller == null
        ? 0.0
        : ((_viewportExtent - _headerExtent - (_galleryExtent - pixels)) /
                _headerExtent)
            .clamp(0.0, 1.0);
  }

  void _positionChanged() {
    markNeedsPaint();
    markNeedsSemanticsUpdate();
    firstChild?.markNeedsSemanticsUpdate();
  }

  void _listen(bool add) {
    if (add) {
      _controller?.addListener(_positionChanged);
      _controller?.geometry.addListener(_positionChanged);
    } else {
      _controller?.removeListener(_positionChanged);
      _controller?.geometry.removeListener(_positionChanged);
    }
  }

  void update(_GeometryScrollController? controller, double galleryExtent,
      double viewportExtent, double headerExtent) {
    if (_controller != controller) {
      if (attached) _listen(false);
      _controller = controller;
      if (attached) _listen(true);
    }
    _galleryExtent = galleryExtent;
    _viewportExtent = viewportExtent;
    _headerExtent = headerExtent;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! ContainerBoxParentData<RenderBox>) {
      child.parentData = _AuthorHeaderParentData();
    }
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _listen(true);
  }

  @override
  void detach() {
    _listen(false);
    super.detach();
  }

  @override
  void performLayout() {
    final arrow = firstChild! as _RenderHeaderArrow;
    final cluster = childAfter(arrow)!;
    final action = childAfter(cluster);
    action?.layout(const BoxConstraints(), parentUsesSize: true);
    final actionSpace = action == null ? 0.0 : action.size.width + 8;
    cluster.layout(
        BoxConstraints.tightFor(
            width: math.max(1, constraints.maxWidth - 52 - actionSpace)),
        parentUsesSize: true);
    arrow.layout(const BoxConstraints.tightFor(width: 52, height: 48),
        parentUsesSize: true);
    size = constraints.constrain(Size(constraints.maxWidth,
        math.max(48, math.max(cluster.size.height, action?.size.height ?? 0))));
    void place(RenderBox box, double left) {
      (box.parentData! as ContainerBoxParentData<RenderBox>).offset =
          Offset(left, (size.height - box.size.height) / 2);
    }

    place(arrow, 0);
    place(cluster, arrow.size.width);
    if (action != null) place(action, size.width - action.size.width);
  }

  Offset _childOffset(RenderBox child) {
    final base = (child.parentData! as BoxParentData).offset;
    return child == childAfter(firstChild!)
        ? Offset(52 * (1 - progress), base.dy)
        : base;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    RenderBox? child = firstChild;
    while (child != null) {
      context.paintChild(child, offset + _childOffset(child));
      child = childAfter(child);
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    RenderBox? child = lastChild;
    while (child != null) {
      final current = child;
      if (result.addWithPaintOffset(
          offset: _childOffset(current),
          position: position,
          hitTest: (result, position) =>
              current.hitTest(result, position: position))) {
        return true;
      }
      child = childBefore(current);
    }
    return false;
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final offset = _childOffset(child);
    transform.translateByDouble(offset.dx, offset.dy, 0, 1);
  }
}

class _GalleryChildrenDelegate extends SliverChildBuilderDelegate {
  const _GalleryChildrenDelegate(super.builder,
      {required super.childCount, required this.extent});

  final double extent;

  @override
  double estimateMaxScrollOffset(int firstIndex, int lastIndex,
          double leadingScrollOffset, double trailingScrollOffset) =>
      extent;
}

class _DockedAuthorHeader extends SingleChildRenderObjectWidget {
  const _DockedAuthorHeader({
    required this.controller,
    required this.galleryExtent,
    required super.child,
  });
  final _GeometryScrollController controller;
  final double galleryExtent;

  @override
  _RenderDockedAuthorHeader createRenderObject(BuildContext context) =>
      _RenderDockedAuthorHeader(controller, galleryExtent);

  @override
  void updateRenderObject(
      BuildContext context, _RenderDockedAuthorHeader renderObject) {
    renderObject
      ..controller = controller
      ..galleryExtent = galleryExtent;
  }
}

class _RenderDockedAuthorHeader extends RenderShiftedBox {
  _RenderDockedAuthorHeader(this._controller, this._galleryExtent)
      : super(null);
  _GeometryScrollController _controller;
  double _galleryExtent;

  set controller(_GeometryScrollController value) {
    if (identical(_controller, value)) return;
    if (attached) {
      _controller.removeListener(_positionChanged);
      _controller.geometry.removeListener(_positionChanged);
    }
    _controller = value;
    if (attached) {
      _controller.addListener(_positionChanged);
      _controller.geometry.addListener(_positionChanged);
    }
    markNeedsLayout();
  }

  set galleryExtent(double value) {
    if (_galleryExtent == value) return;
    _galleryExtent = value;
    markNeedsLayout();
  }

  void _positionChanged() {
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _controller.addListener(_positionChanged);
    _controller.geometry.addListener(_positionChanged);
  }

  @override
  void detach() {
    _controller.removeListener(_positionChanged);
    _controller.geometry.removeListener(_positionChanged);
    super.detach();
  }

  @override
  void performLayout() {
    size = constraints.biggest;
    child!.layout(BoxConstraints.tightFor(width: size.width),
        parentUsesSize: true);
  }

  Offset get _childOffset {
    final pixels = _controller.hasClients ? _controller.position.pixels : 0.0;
    return Offset(
        0, math.min(_galleryExtent - pixels, size.height - child!.size.height));
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      context.paintChild(child!, offset + _childOffset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      result.addWithPaintOffset(
          offset: _childOffset,
          position: position,
          hitTest: (result, position) =>
              child!.hitTest(result, position: position));

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final offset = _childOffset;
    transform.translateByDouble(offset.dx, offset.dy, 0, 1);
  }
}

class _MeasuredDetailImage extends StatefulWidget {
  const _MeasuredDetailImage({
    super.key,
    required this.provider,
    required this.errorBuilder,
    this.previewProvider,
    this.previewFallbackProvider,
    this.loading = false,
    this.onDimensions,
    this.onReady,
    this.onRetry,
  });
  final ImageProvider<Object>? provider;
  final ImageProvider<Object>? previewProvider;
  final ImageProvider<Object>? previewFallbackProvider;
  final bool loading;
  final ImageErrorWidgetBuilder errorBuilder;
  final ValueChanged<double>? onDimensions;
  final VoidCallback? onReady;
  final VoidCallback? onRetry;
  @override
  State<_MeasuredDetailImage> createState() => _MeasuredDetailImageState();
}

class _MeasuredDetailImageState extends State<_MeasuredDetailImage> {
  ImageStream? _stream;
  bool _readyReported = false;
  int _contentEpoch = 0;
  late final ImageStreamListener _listener = ImageStreamListener((info, sync) {
    final width = info.image.width;
    final height = info.image.height;
    info.dispose();
    if (width <= 0 || height <= 0) return;
    final ratio = width / height;
    final epoch = _contentEpoch;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && epoch == _contentEpoch) widget.onDimensions?.call(ratio);
    });
  }, onError: (Object error, StackTrace? trace) {});

  void _reportReady() {
    if (_readyReported || widget.onReady == null) return;
    _readyReported = true;
    final epoch = _contentEpoch;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && epoch == _contentEpoch) widget.onReady?.call();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant _MeasuredDetailImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.provider != widget.provider ||
        oldWidget.previewProvider != widget.previewProvider ||
        oldWidget.previewFallbackProvider != widget.previewFallbackProvider) {
      _contentEpoch++;
      _readyReported = false;
    }
    if (oldWidget.provider != widget.provider ||
        oldWidget.onDimensions != widget.onDimensions) {
      _resolve();
    }
  }

  void _resolve() {
    _stream?.removeListener(_listener);
    _stream = null;
    // Dimension correction stays independent of pixel readiness. Preview pixels
    // must never change the gallery's natural high-resolution image geometry.
    if (widget.onDimensions != null && widget.provider != null) {
      _stream =
          widget.provider!.resolve(createLocalImageConfiguration(context));
      _stream!.addListener(_listener);
    }
  }

  Widget _preview(BuildContext context, {Widget? unavailable}) {
    final primary = widget.previewProvider ?? widget.previewFallbackProvider;
    if (primary == null) {
      return unavailable ?? const Center(child: CircularProgressIndicator());
    }
    Widget previewImage(ImageProvider<Object> provider, bool allowFallback) =>
        Image(
          key: ValueKey(('pixiv-detail-preview', provider)),
          // Deliberately no ResizeImage: this is the cover's exact warm key.
          image: provider,
          fit: BoxFit.contain,
          alignment: Alignment.topCenter,
          excludeFromSemantics: true,
          frameBuilder: (context, child, frame, synchronous) {
            if (frame != null || synchronous) {
              _reportReady();
              return child;
            }
            return unavailable ??
                const Center(child: CircularProgressIndicator());
          },
          errorBuilder: (context, error, trace) {
            final other = widget.previewFallbackProvider;
            if (allowFallback && other != null && other != provider) {
              return previewImage(other, false);
            }
            return unavailable ??
                const Center(child: CircularProgressIndicator());
          },
        );
    return previewImage(primary, true);
  }

  Widget _highFailure(BuildContext context, Object? error, StackTrace? trace) {
    _reportReady(); // Explicit high-resolution failure is a recoverable terminal.
    final failure = widget.errorBuilder(
        context, error ?? StateError('Missing detail image'), trace);
    if (widget.previewProvider == null &&
        widget.previewFallbackProvider == null) {
      return failure;
    }
    return Stack(fit: StackFit.expand, children: [
      _preview(context, unavailable: failure),
      Align(
        alignment: Alignment.bottomCenter,
        child: Material(
          color: Theme.of(context).colorScheme.surface.withValues(alpha: .92),
          child: Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Row(children: [
              const Icon(Icons.broken_image_outlined, size: 18),
              const SizedBox(width: 8),
              const Expanded(
                  child: Text('高清图片加载失败',
                      maxLines: 2, overflow: TextOverflow.ellipsis)),
              if (widget.onRetry != null)
                IconButton(
                  tooltip: '重试高清图片',
                  constraints:
                      const BoxConstraints(minWidth: 48, minHeight: 48),
                  style:
                      IconButton.styleFrom(minimumSize: const Size.square(48)),
                  onPressed: widget.onRetry,
                  icon: const Icon(Icons.refresh),
                ),
            ]),
          ),
        ),
      ),
    ]);
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final high = widget.provider;
    if (high == null) {
      if (widget.loading) return _preview(context);
      return _highFailure(context, null, null);
    }
    return Image(
      key: ValueKey(('pixiv-detail-high', high)),
      image: high,
      fit: BoxFit.contain,
      alignment: Alignment.topCenter,
      frameBuilder: (context, child, frame, synchronous) {
        if (frame != null || synchronous) {
          _reportReady();
          return child;
        }
        if (widget.previewProvider != null ||
            widget.previewFallbackProvider != null ||
            widget.onReady != null) {
          return _preview(context);
        }
        return child;
      },
      errorBuilder: _highFailure,
    );
  }
}

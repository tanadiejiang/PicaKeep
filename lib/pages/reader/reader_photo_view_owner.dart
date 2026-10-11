import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';

// The pinned PhotoView delegate adds controller listener A, then scale-state
// listener B, but removes only B in dispose. Pairing that real B removal to A
// also handles ImageWrapper loading/error gaps, not just whole-widget exits.
// The root remains stable; leases never own image IO or replace its state.
final _registries = Expando<_Registry>('reader-photo-view-owners');
final _coreZoneKey = Object();

_Registry _registry(PhotoViewController root) =>
    _registries[root] ??= _Registry(root);

class ReaderPhotoViewController extends PhotoViewController {
  ReaderPhotoViewController() {
    outputStateStream.listen((_) {}, onDone: () => _actuallyDisposed = true);
  }
  bool _disposeRequested = false,
      _notifierDisposed = false,
      _actuallyDisposed = false;
  @visibleForTesting
  bool get debugDisposeRequested => _disposeRequested;
  @visibleForTesting
  bool get debugActuallyDisposed => _actuallyDisposed;
  @visibleForTesting
  int get debugOwnerCount => _registry(this).owners.length;
  @visibleForTesting
  int get debugCoreCount =>
      _registry(this).owners.fold(0, (n, o) => n + o._pairs.length);
  @visibleForTesting
  int get debugScaleStateCount =>
      _registry(this).owners.where((o) => !o._scaleClosed).length;
  @visibleForTesting
  int get debugListenerCount => _registry(this).owners.fold(
      0,
      (n, o) =>
          n +
          o._pairs.values.fold(
              0,
              (m, pair) =>
                  m + (pair.aAttached ? 1 : 0) + (pair.bAttached ? 1 : 0)));

  @override
  void resetWithNewBoxFit(BoxFit fit) {
    // Settings still persist the fit. A future mounted owner applies it; there
    // is no valid Core/geometry callback to invoke during loading/error gaps.
    if (!_disposeRequested && getScaleWithFit != null) {
      super.resetWithNewBoxFit(fit);
    }
  }

  @override
  void dispose() {
    if (_disposeRequested) return;
    _disposeRequested = true;
    final registry = _registry(this);
    registry.active = null;
    for (final owner in registry.owners.toList()) {
      owner._clearActions();
    }
    _finishDisposal();
  }

  void _finishDisposal() {
    if (!_disposeRequested ||
        _notifierDisposed ||
        _registry(this).owners.isNotEmpty) {
      return;
    }
    _notifierDisposed = true;
    // Owner scale streams and real Core retirements have already completed.
    super.dispose();
  }
}

class _Registry {
  _Registry(this.root);
  final PhotoViewController root;
  final owners = <_Lease>{};
  _Lease? active;
  bool get closing =>
      root is ReaderPhotoViewController &&
      (root as ReaderPhotoViewController)._disposeRequested;
  void activate(_Lease owner) {
    if (closing || owner._closing) return;
    if (!identical(active, owner)) active?._clearActions();
    active = owner;
  }

  void finished(_Lease owner) {
    owners.remove(owner);
    if (identical(active, owner)) active = null;
    if (root is ReaderPhotoViewController) {
      (root as ReaderPhotoViewController)._finishDisposal();
    }
  }
}

enum _Action { doubleClick, position, state, scale, initial, fit }

class _Pair {
  _Pair(this.originalA);
  final VoidCallback originalA;
  late VoidCallback wrappedA;
  VoidCallback? originalB, wrappedB;
  bool aAttached = false, bAttached = false;
  final published = <_Action, Object>{};
}

// Implements (not extends) avoids constructing/resetting a second notifier,
// output stream, initial or prevValue. It retains the public controller type
// for PhotoView's getScaleWithFit capability test.
class _Lease implements PhotoViewController {
  _Lease(this.root) : registry = _registry(root) {
    if (registry.closing) {
      throw StateError('Reader photo controller is closing');
    }
    scaleState = _OwnedScaleState(this);
    registry.owners.add(this);
    registry.activate(this);
  }
  final PhotoViewController root;
  final _Registry registry;
  late final _OwnedScaleState scaleState;
  final _pairs = <VoidCallback, _Pair>{};
  final _pending = <_Pair>[];
  _Pair? _current;
  ({Size child, Size outer})? _customGeometry;
  bool _active = true,
      _closing = false,
      _scaleClosing = false,
      _scaleClosed = false;

  bool _valid(_Pair? pair) =>
      pair != null &&
      _active &&
      !_closing &&
      !registry.closing &&
      identical(registry.active, this) &&
      identical(_current, pair) &&
      _pairs[pair.originalA] == pair;
  bool get _canWrite {
    final origin = Zone.current[_coreZoneKey];
    return _valid(_current) && (origin == null || identical(origin, _current));
  }

  void _invoke(_Pair pair, VoidCallback call) {
    if (_valid(pair)) runZoned(call, zoneValues: {_coreZoneKey: pair});
  }

  T? _query<T>(_Pair pair, T? Function() call) =>
      _valid(pair) ? runZoned(call, zoneValues: {_coreZoneKey: pair}) : null;

  @override
  void addIgnorableListener(VoidCallback callback) {
    if (_closing || registry.closing) {
      throw StateError('Reader photo owner is closing');
    }
    final pair = _Pair(callback);
    pair.wrappedA = () => _invoke(pair, callback);
    _pairs[callback] = pair;
    _pending.add(pair);
    _current = pair;
    root.addIgnorableListener(pair.wrappedA);
    pair.aAttached = true;
  }

  @override
  void removeIgnorableListener(VoidCallback callback) {
    final pair = _pairs[callback];
    if (pair != null && pair.aAttached) {
      root.removeIgnorableListener(pair.wrappedA);
      pair.aAttached = false;
    }
  }

  void _retire(_Pair pair) {
    removeIgnorableListener(pair.originalA);
    _clearPairActions(pair);
    _pairs.remove(pair.originalA);
    _pending.remove(pair);
    if (identical(_current, pair)) _current = null;
    _finishClose();
  }

  Object? _readAction(_Action slot) => switch (slot) {
        _Action.doubleClick => root.onDoubleClick,
        _Action.position => root.animatePosition,
        _Action.state => root.updateState,
        _Action.scale => root.animateScale,
        _Action.initial => root.getInitialScale,
        _Action.fit => root.getScaleWithFit,
      };
  void _writeAction(_Action slot, Object? value) {
    switch (slot) {
      case _Action.doubleClick:
        root.onDoubleClick = value as void Function()?;
      case _Action.position:
        root.animatePosition = value as void Function(Offset, Offset)?;
      case _Action.state:
        root.updateState = value as void Function(PhotoViewScaleState?)?;
      case _Action.scale:
        root.animateScale = value as void Function(double, [Offset?])?;
      case _Action.initial:
        root.getInitialScale = value as double? Function()?;
      case _Action.fit:
        root.getScaleWithFit = value as double? Function(BoxFit)?;
    }
  }

  void _publish(_Action slot, Object? callback) {
    final pair = _current;
    if (!_valid(pair)) return;
    if (callback == null) {
      final previous = pair!.published.remove(slot);
      if (previous != null && identical(_readAction(slot), previous)) {
        _writeAction(slot, null);
      }
      return;
    }
    pair!.published[slot] = callback;
    _writeAction(slot, callback);
  }

  void _clearPairActions(_Pair pair, {bool forget = true}) {
    for (final entry in pair.published.entries) {
      if (identical(_readAction(entry.key), entry.value)) {
        _writeAction(entry.key, null);
      }
    }
    if (forget) pair.published.clear();
  }

  void _clearActions() {
    for (final pair in _pairs.values) {
      _clearPairActions(pair, forget: false);
    }
  }

  void deactivate() {
    _active = false;
    _clearActions();
    if (identical(registry.active, this)) registry.active = null;
  }

  void activate() {
    _active = true;
    registry.activate(this);
    if (_valid(_current)) {
      for (final action in _current!.published.entries) {
        _writeAction(action.key, action.value);
      }
    }
  }

  @override
  void dispose() {
    if (_closing) return;
    _closing = true;
    deactivate();
    // Do not dispose a notifier still used by a real Core. B removal closes
    // the final pair, including when controller replacement precedes unmount.
    _finishClose();
  }

  void _finishClose() {
    if (!_closing || _pairs.isNotEmpty || _scaleClosing) return;
    _scaleClosing = true;
    scaleState.dispose();
    unawaited(scaleState.drained.then((_) {
      _scaleClosed = true;
      registry.finished(this);
    }));
  }

  @override
  Stream<PhotoViewControllerValue> get outputStateStream =>
      root.outputStateStream;
  @override
  PhotoViewControllerValue get value => root.value;
  @override
  set value(PhotoViewControllerValue v) {
    if (_canWrite) root.value = v;
  }

  @override
  PhotoViewControllerValue get prevValue => root.prevValue;
  @override
  set prevValue(PhotoViewControllerValue v) {
    if (_canWrite) root.prevValue = v;
  }

  @override
  PhotoViewControllerValue get initial => root.initial;
  @override
  set initial(PhotoViewControllerValue v) {
    if (_canWrite) root.initial = v;
  }

  @override
  Offset get position => root.position;
  @override
  set position(Offset v) {
    if (_canWrite) root.position = v;
  }

  @override
  double? get scale => root.scale;
  @override
  set scale(double? v) {
    if (_canWrite) root.scale = v;
  }

  @override
  double get rotation => root.rotation;
  @override
  set rotation(double v) {
    if (_canWrite) root.rotation = v;
  }

  @override
  Offset? get rotationFocusPoint => root.rotationFocusPoint;
  @override
  set rotationFocusPoint(Offset? v) {
    if (_canWrite) root.rotationFocusPoint = v;
  }

  @override
  void setScaleInvisibly(double? v) {
    if (_canWrite) root.setScaleInvisibly(v);
  }

  @override
  void reset() {
    if (_canWrite) root.reset();
  }

  @override
  void resetWithNewBoxFit(BoxFit fit) {
    if (_canWrite && root.getScaleWithFit != null) root.resetWithNewBoxFit(fit);
  }

  @override
  void updateMultiple(
      {Offset? position,
      double? scale,
      double? rotation,
      Offset? rotationFocusPoint}) {
    if (_canWrite) {
      root.updateMultiple(
          position: position,
          scale: scale,
          rotation: rotation,
          rotationFocusPoint: rotationFocusPoint);
    }
  }

  @override
  void Function()? get onDoubleClick => _canWrite ? root.onDoubleClick : null;
  @override
  set onDoubleClick(void Function()? callback) {
    final pair = _current;
    _publish(
        _Action.doubleClick,
        callback == null || pair == null
            ? null
            : () => _invoke(pair, callback));
  }

  @override
  void Function(Offset, Offset)? get animatePosition =>
      _canWrite ? root.animatePosition : null;
  @override
  set animatePosition(void Function(Offset, Offset)? callback) {
    final pair = _current;
    _publish(
        _Action.position,
        callback == null || pair == null
            ? null
            : (Offset from, Offset to) =>
                _invoke(pair, () => callback(from, to)));
  }

  @override
  void Function(PhotoViewScaleState?)? get updateState =>
      _canWrite ? root.updateState : null;
  @override
  set updateState(void Function(PhotoViewScaleState?)? callback) {
    final pair = _current;
    _publish(
        _Action.state,
        callback == null || pair == null
            ? null
            : (PhotoViewScaleState? state) =>
                _invoke(pair, () => callback(state)));
  }

  @override
  void Function(double, [Offset?])? get animateScale =>
      _canWrite ? root.animateScale : null;
  @override
  set animateScale(void Function(double, [Offset?])? callback) {
    final pair = _current;
    _publish(
        _Action.scale,
        callback == null || pair == null
            ? null
            : (double scale, [Offset? position]) =>
                _invoke(pair, () => callback(scale, position)));
  }

  @override
  double? Function()? get getInitialScale =>
      _canWrite ? root.getInitialScale : null;
  @override
  set getInitialScale(double? Function()? callback) {
    final pair = _current;
    _publish(_Action.initial,
        callback == null || pair == null ? null : () => _query(pair, callback));
  }

  // CustomChild Core never initializes its imageSize/imageScale fields, so its
  // published getScaleWithFit would throw. Use the actual public child/viewport
  // geometry instead: the same contained/width/height ratios used by PhotoView
  // ScaleBoundaries. Image-provider owners retain their original codec callback.
  double? _fitCustomChild(BoxFit fit) {
    final geometry = _customGeometry!;
    final child = geometry.child, outer = geometry.outer;
    if (child.isEmpty ||
        outer.isEmpty ||
        !child.width.isFinite ||
        !child.height.isFinite ||
        !outer.width.isFinite ||
        !outer.height.isFinite) {
      return null;
    }
    final width = outer.width / child.width,
        height = outer.height / child.height;
    return switch (fit) {
      BoxFit.fitWidth => width,
      BoxFit.fitHeight => height,
      _ => math.min(width, height),
    };
  }

  @override
  double? Function(BoxFit)? get getScaleWithFit =>
      _canWrite ? root.getScaleWithFit : null;
  @override
  set getScaleWithFit(double? Function(BoxFit)? callback) {
    final pair = _current;
    _publish(
        _Action.fit,
        callback == null || pair == null
            ? null
            : (BoxFit fit) => _query(
                pair,
                () => _customGeometry == null
                    ? callback(fit)
                    : _fitCustomChild(fit)));
  }
}

class _OwnedScaleState extends PhotoViewScaleStateController {
  _OwnedScaleState(this.owner) {
    outputScaleStateStream.listen((_) {}, onDone: () => _drained.complete());
  }
  final _Lease owner;
  final _pairs = <VoidCallback, _Pair>{};
  final _drained = Completer<void>();
  Future<void> get drained => _drained.future;
  @override
  void addIgnorableListener(VoidCallback callback) {
    if (owner._pending.isEmpty) {
      throw StateError('PhotoView delegate registration order changed');
    }
    final pair = owner._pending.removeLast();
    pair.originalB = callback;
    pair.wrappedB = () => owner._invoke(pair, callback);
    _pairs[callback] = pair;
    super.addIgnorableListener(pair.wrappedB!);
    pair.bAttached = true;
  }

  @override
  void removeIgnorableListener(VoidCallback callback) {
    final pair = _pairs.remove(callback);
    if (pair == null) return; // exact pair already retired, not a new owner
    super.removeIgnorableListener(pair.wrappedB!);
    pair.bAttached = false;
    owner._retire(pair);
  }
}

/// Owns one PhotoView's external scale controller, never the stable reader root.
/// Child Core disposal releases its exact A/B pair even if this owner stays
/// mounted while the provider is loading/error. Independent scale streams close
/// with their owner rather than accumulating old PhotoViewState subscriptions.
class ReaderPhotoViewOwner extends StatefulWidget {
  const ReaderPhotoViewOwner(
      {super.key, required this.controller, required this.builder});
  final PhotoViewController controller;
  final PhotoView Function(
      BuildContext, PhotoViewController, PhotoViewScaleStateController) builder;
  @override
  State<ReaderPhotoViewOwner> createState() => _ReaderPhotoViewOwnerState();
}

class _ReaderPhotoViewOwnerState extends State<ReaderPhotoViewOwner> {
  late _Lease _lease;
  @override
  void initState() {
    super.initState();
    _lease = _Lease(widget.controller);
  }

  @override
  void didUpdateWidget(ReaderPhotoViewOwner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      _lease.dispose();
      _lease = _Lease(widget.controller);
    }
  }

  @override
  void deactivate() {
    _lease.deactivate();
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _lease.activate();
  }

  @override
  void dispose() {
    _lease.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) {
        final photo = widget.builder(context, _lease, _lease.scaleState);
        final outer = photo.customSize ?? constraints.biggest;
        _lease._customGeometry = photo.child == null
            ? null
            : (child: photo.childSize ?? outer, outer: outer);
        return KeyedSubtree(key: ObjectKey(_lease), child: photo);
      });
}

/// Reader-only custom-child gallery shell. Mirrors the pinned dependency's
/// public _buildItem/PageView contract; the sole addition is a true per-item
/// PhotoView owner above (not inside) the Core, so parent scale state is never
/// disposed early by a child Row. The reader does not use image-provider pages.
class ReaderPhotoViewGallery extends StatelessWidget {
  const ReaderPhotoViewGallery.builder(
      {super.key,
      required this.pageController,
      required this.itemCount,
      required this.builder,
      this.backgroundDecoration,
      this.reverse = false,
      this.onPageChanged,
      this.scrollPhysics,
      this.scrollDirection = Axis.horizontal,
      this.allowImplicitScrolling = false,
      this.wantKeepAlive = false,
      this.enableRotation = false,
      this.customSize,
      this.scaleStateChangedCallback});
  final PageController pageController;
  final int itemCount;
  final PhotoViewGalleryPageOptions Function(BuildContext, int) builder;
  final BoxDecoration? backgroundDecoration;
  final bool reverse, allowImplicitScrolling, wantKeepAlive, enableRotation;
  final ValueChanged<int>? onPageChanged;
  final ScrollPhysics? scrollPhysics;
  final Axis scrollDirection;
  final Size? customSize;
  final ValueChanged<PhotoViewScaleState>? scaleStateChangedCallback;
  @override
  Widget build(BuildContext context) => PhotoViewGestureDetectorScope(
      axis: scrollDirection,
      child: PageView.builder(
          reverse: reverse,
          controller: pageController,
          onPageChanged: onPageChanged,
          itemCount: itemCount,
          scrollDirection: scrollDirection,
          physics: scrollPhysics,
          allowImplicitScrolling: allowImplicitScrolling,
          itemBuilder: (context, index) {
            final option = builder(context, index);
            assert(option.child != null,
                'Reader gallery only supports its existing custom-child pages');
            PhotoView photo(PhotoViewControllerBase? controller,
                    PhotoViewScaleStateController? scaleState) =>
                PhotoView.customChild(
                    key: ObjectKey(index),
                    childSize: option.childSize,
                    backgroundDecoration: backgroundDecoration,
                    wantKeepAlive: wantKeepAlive,
                    controller: controller,
                    scaleStateController: scaleState,
                    customSize: customSize,
                    heroAttributes: option.heroAttributes,
                    scaleStateChangedCallback: scaleStateChangedCallback,
                    enableRotation: enableRotation,
                    initialScale: option.initialScale,
                    minScale: option.minScale,
                    maxScale: option.maxScale,
                    scaleStateCycle: option.scaleStateCycle,
                    onTapUp: option.onTapUp,
                    onTapDown: option.onTapDown,
                    onScaleEnd: option.onScaleEnd,
                    gestureDetectorBehavior: option.gestureDetectorBehavior,
                    tightMode: option.tightMode,
                    filterQuality: option.filterQuality,
                    basePosition: option.basePosition,
                    disableGestures: option.disableGestures,
                    child: option.child);
            final controller = option.controller;
            return ClipRect(
                child: controller is PhotoViewController
                    ? ReaderPhotoViewOwner(
                        controller: controller,
                        builder: (_, lease, scaleState) =>
                            photo(lease, scaleState))
                    : photo(controller, option.scaleStateController));
          }));
}

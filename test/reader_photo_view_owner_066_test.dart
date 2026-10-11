// 066 reader-local PhotoView ownership regression. The original failing F4
// sequence remains unchanged in reader_real_format_matrix_066_test.dart.
// This companion exercises real PhotoView/PhotoViewCore lifecycle, including
// an actual provider waiting/error gap, not fake delegate listener callbacks.

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:photo_view/src/core/photo_view_gesture_detector.dart';
import 'package:picakeep/pages/reader/reader_photo_view_owner.dart';

class _PendingImage extends ImageProvider<_PendingImage> {
  final result = Completer<ImageInfo>();
  @override
  Future<_PendingImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);
  @override
  ImageStreamCompleter loadImage(
          _PendingImage key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(result.future);
}

Future<void> _flush(WidgetTester tester, [int turns = 4]) async {
  for (var i = 0; i < turns; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 2)));
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> _until(
    WidgetTester tester, bool Function() ready, String reason) async {
  for (var i = 0; i < 200 && !ready(); i++) {
    await _flush(tester, 1);
  }
  expect(ready(), isTrue, reason: reason);
}

Widget _host(Widget child) => MaterialApp(
    home: Scaffold(
        body: Center(child: SizedBox(width: 200, height: 200, child: child))));

Widget _custom(ReaderPhotoViewController root, String key, Size size,
        {void Function(PhotoViewController)? capture}) =>
    ReaderPhotoViewOwner(
        key: ValueKey(key),
        controller: root,
        builder: (context, controller, scaleState) {
          capture?.call(controller);
          return PhotoView.customChild(
              controller: controller,
              scaleStateController: scaleState,
              childSize: size,
              minScale: 1.0,
              initialScale: 1.0,
              maxScale: 16.0,
              child: const ColoredBox(color: Colors.blue));
        });

void _noActions(ReaderPhotoViewController root) {
  expect(root.onDoubleClick, isNull);
  expect(root.animatePosition, isNull);
  expect(root.updateState, isNull);
  expect(root.animateScale, isNull);
  expect(root.getInitialScale, isNull);
  expect(root.getScaleWithFit, isNull);
}

void _allActions(ReaderPhotoViewController root) {
  expect(root.onDoubleClick, isNotNull);
  expect(root.animatePosition, isNotNull);
  expect(root.updateState, isNotNull);
  expect(root.animateScale, isNotNull);
  expect(root.getInitialScale, isNotNull);
  expect(root.getScaleWithFit, isNotNull);
}

void _emptyOwnership(ReaderPhotoViewController root) {
  expect(root.debugOwnerCount, 0);
  expect(root.debugCoreCount, 0);
  expect(root.debugScaleStateCount, 0);
  expect(root.debugListenerCount, 0);
  _noActions(root);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      '066 new owner initializes before old dispose without old clamp/actions or async writes',
      (tester) async {
    final root = ReaderPhotoViewController();
    final identity = root;
    PhotoViewController? oldLease;
    await tester.pumpWidget(_host(Stack(children: [
      Positioned.fill(
          key: const ValueKey('old-position'),
          child: _custom(root, 'old', const Size(100, 100),
              capture: (value) => oldLease = value)),
    ])));
    await _flush(tester);
    final oldDouble = root.onDoubleClick!;
    final oldPosition = root.animatePosition!;
    final oldUpdate = root.updateState!;
    final oldScale = root.animateScale!;
    final oldInitial = root.getInitialScale!;
    final oldFit = root.getScaleWithFit!;
    await tester.pumpWidget(_host(Stack(children: [
      Positioned.fill(
          key: const ValueKey('old-position'),
          child: _custom(root, 'old', const Size(100, 100))),
      Positioned.fill(
          key: const ValueKey('new-position'),
          child: _custom(root, 'new', const Size(800, 200))),
    ])));
    await _flush(tester);
    expect(root.debugOwnerCount, 2,
        reason:
            'explicit overlap: successor already initialized, predecessor not disposed');
    _allActions(root);
    root.updateMultiple(
        scale: 2, position: const Offset(650, 0), rotation: 0.2);
    expect(root.position, const Offset(650, 0),
        reason:
            'new 800px child permits x650; old 100px child would clamp to zero');
    expect(root.rotation, 0.2);
    final before = root.value;
    oldDouble();
    oldPosition(Offset.zero, const Offset(1, 2));
    oldUpdate(PhotoViewScaleState.initial);
    oldScale(1, Offset.zero);
    expect(oldInitial(), isNull);
    expect(oldFit(BoxFit.contain), isNull);
    await Future<void>.microtask(() => oldLease!.updateMultiple(
        scale: 8, rotation: 1, position: const Offset(-99, -99)));
    await _flush(tester);
    expect(root.value, before,
        reason:
            'captured retired commands and async old-lease writes cannot enter old Core or mutate successor');
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(_host(Stack(children: [
      Positioned.fill(
          key: const ValueKey('new-position'),
          child: _custom(root, 'new', const Size(800, 200))),
    ])));
    await _flush(tester);
    expect(identical(root, identity), isTrue);
    expect(root.debugOwnerCount, 1);
    expect(root.debugCoreCount, 1);
    _allActions(root);
    root.updateMultiple(scale: 2, position: const Offset(660, 0));
    expect(root.position, const Offset(660, 0));
    expect(root.getScaleWithFit!(BoxFit.contain), 0.25);
    expect(tester.takeException(), isNull);

    root.dispose();
    expect(root.debugDisposeRequested, isTrue);
    expect(root.debugActuallyDisposed, isFalse,
        reason: 'live Core still owns the real controller notifier/stream');
    await tester.pumpWidget(const SizedBox());
    await _flush(tester);
    _emptyOwnership(root);
    expect(root.debugActuallyDisposed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      '066 true PhotoView image loading and error gaps retire exact Core listeners and actions',
      (tester) async {
    final root = ReaderPhotoViewController();
    final bytes = (await tester.runAsync(
        () => File('test/fixtures/reader_066/png_alpha.png').readAsBytes()))!;
    final codec =
        (await tester.runAsync(() => ui.instantiateImageCodec(bytes)))!;
    final frame = (await tester.runAsync(codec.getNextFrame))!;
    codec.dispose();
    final first = _PendingImage(),
        pending = _PendingImage(),
        failed = _PendingImage(),
        recovered = _PendingImage();
    first.result.complete(ImageInfo(image: frame.image.clone()));
    Future<void> mount(_PendingImage provider) =>
        tester.pumpWidget(_host(ReaderPhotoViewOwner(
            key: const ValueKey('same-image-owner'),
            controller: root,
            builder: (context, controller, scaleState) => PhotoView(
                controller: controller,
                scaleStateController: scaleState,
                imageProvider: provider,
                minScale: 1.0,
                initialScale: 1.0,
                maxScale: 16.0,
                loadingBuilder: (_, __) => const Text('066 pending'),
                errorBuilder: (_, __, ___, ____) => const Text('066 error')))));
    try {
      await mount(first);
      await _until(tester, () => root.debugCoreCount == 1,
          'initial actual PhotoViewCore');
      _allActions(root);
      final oldDouble = root.onDoubleClick!;
      final oldScale = root.animateScale!;
      final oldFit = root.getScaleWithFit!;
      await mount(pending);
      await _until(
          tester,
          () =>
              find.text('066 pending').evaluate().isNotEmpty &&
              root.debugCoreCount == 0,
          'ImageWrapper keeps the PhotoView owner but removes its old Core while pending');
      expect(root.debugOwnerCount, 1);
      expect(root.debugScaleStateCount, 1);
      expect(root.debugListenerCount, 0);
      _noActions(root);
      root.updateMultiple(
          scale: 3, position: const Offset(9999, -9876), rotation: 0.3);
      final waiting = root.value;
      oldDouble();
      oldScale(1);
      expect(oldFit(BoxFit.contain), isNull);
      root.resetWithNewBoxFit(BoxFit.fitWidth);
      await _flush(tester);
      expect(root.value, waiting,
          reason:
              'no old bounds clamp, animation or forced transform reset during loading gap');
      expect(tester.takeException(), isNull);

      await mount(failed);
      failed.result.completeError(
          StateError('066 controlled local provider failure'),
          StackTrace.current);
      await _until(tester, () => find.text('066 error').evaluate().isNotEmpty,
          'actual provider error branch');
      expect(root.debugCoreCount, 0);
      expect(root.debugListenerCount, 0);
      _noActions(root);
      root.updateMultiple(scale: 4, position: const Offset(5555, -4444));
      expect(root.position, const Offset(5555, -4444));
      expect(tester.takeException(), isNull);

      recovered.result.complete(ImageInfo(image: frame.image.clone()));
      await mount(recovered);
      await _until(tester, () => root.debugCoreCount == 1,
          'recovered fresh Core under same outer owner');
      _allActions(root);
      root.updateMultiple(scale: 4, position: const Offset(9999, 9999));
      expect(root.position.dx, lessThan(9999));
      expect(root.position.dy, lessThan(9999));
      final recoveredValue = root.value;
      oldDouble();
      oldScale(1);
      await _flush(tester);
      expect(root.value, recoveredValue);
      expect(tester.takeException(), isNull);
    } finally {
      // Release the retired pending provider's actual frame future as well.
      if (!pending.result.isCompleted) {
        pending.result.complete(ImageInfo(image: frame.image.clone()));
      }
      await tester.pumpWidget(const SizedBox());
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      await _flush(tester);
      _emptyOwnership(root);
      root.dispose();
      await _until(tester, () => root.debugActuallyDisposed,
          'root stream really closes after final owner');
      frame.image.dispose();
    }
  });

  testWidgets(
      '066 customChild reading-settings fit command uses real geometry without image-only fields',
      (tester) async {
    final root = ReaderPhotoViewController();
    final identity = root;
    await tester.pumpWidget(_host(ReaderPhotoViewOwner(
        controller: root,
        builder: (_, controller, scaleState) => PhotoView.customChild(
            controller: controller,
            scaleStateController: scaleState,
            childSize: const Size(400, 800),
            minScale: PhotoViewComputedScale.contained,
            initialScale: PhotoViewComputedScale.contained,
            maxScale: PhotoViewComputedScale.covered * 8,
            child: const ColoredBox(color: Colors.green)))));
    await _until(
        tester, () => root.debugCoreCount == 1, 'actual customChild Core');
    // Same public command and switch used by the main reading-settings fit UI.
    for (final setting in [1, 2, 0]) {
      root.resetWithNewBoxFit(switch (setting) {
        0 => BoxFit.contain,
        1 => BoxFit.fitWidth,
        2 => BoxFit.fitHeight,
        _ => BoxFit.contain,
      });
      await _flush(tester);
      expect(root.scale, setting == 1 ? 0.5 : 0.25);
      expect(identical(root, identity), isTrue);
      expect(root.debugCoreCount, 1);
      expect(tester.takeException(), isNull,
          reason:
              'customChild never initializes dependency imageSize/imageScale');
    }
    await tester.pumpWidget(const SizedBox());
    await _flush(tester);
    _emptyOwnership(root);
    root.dispose();
    await _until(
        tester, () => root.debugActuallyDisposed, 'actual root stream closes');
  });

  testWidgets(
      '066 direct gesture scaleEnd awaiting 200ms cannot touch a retired Core',
      (tester) async {
    final root = ReaderPhotoViewController();
    try {
      await tester.pumpWidget(
          _host(_custom(root, 'old-scale-end', const Size(800, 400))));
      await _flush(tester);
      root.updateMultiple(scale: 2, position: Offset.zero);
      final gesture = tester.widget<PhotoViewGestureDetector>(
          find.byType(PhotoViewGestureDetector));
      // These are the real callbacks installed on the real recognizer, not
      // wrapped root actions. This deterministically reaches Core.onScaleEnd's
      // actual 200ms await without depending on platform gesture arena timing.
      gesture
          .onScaleStart!(ScaleStartDetails(focalPoint: const Offset(100, 100)));
      root.updateState!(null); // actual Core publishes stateChanged=true
      gesture.onScaleEnd!(ScaleEndDetails());
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpWidget(
          _host(_custom(root, 'new-scale-end', const Size(400, 800))));
      await _flush(tester, 1);
      root.updateMultiple(scale: 0.25, position: Offset.zero);
      final replacement = root.value;
      await tester.pump(const Duration(milliseconds: 250));
      expect(root.value, replacement,
          reason: 'retired gesture continuation cannot mutate successor');
      expect(tester.takeException(), isNull,
          reason:
              'retired Core must not use disposed private AnimationControllers after its await');
    } finally {
      await tester.pumpWidget(const SizedBox());
      await _flush(tester);
      _emptyOwnership(root);
      root.dispose();
      await _until(tester, () => root.debugActuallyDisposed,
          'late-gesture root closes after actual owners');
    }
  });

  for (final layout in ['single', 'double', 'continuous']) {
    testWidgets(
        '066 $layout owner scopes release real listeners and independent scale states',
        (tester) async {
      final roots = [ReaderPhotoViewController(), ReaderPhotoViewController()];
      final pageController = PageController();
      Widget content;
      if (layout == 'double') {
        content = ReaderPhotoViewGallery.builder(
            pageController: pageController,
            itemCount: 2,
            builder: (_, index) => PhotoViewGalleryPageOptions.customChild(
                controller: roots[index],
                childSize: const Size(200, 200),
                minScale: 1.0,
                initialScale: 1.0,
                maxScale: 64.0,
                child: const Row(children: [
                  Expanded(child: ColoredBox(color: Colors.red)),
                  Expanded(child: ColoredBox(color: Colors.blue))
                ])));
      } else {
        content = _custom(roots[0], layout,
            layout == 'single' ? const Size(300, 400) : const Size(200, 1000));
      }
      await tester.pumpWidget(_host(content));
      await _flush(tester);
      expect(roots[0].debugCoreCount, 1);
      expect(roots[0].debugScaleStateCount, 1);
      final identity = roots[0];
      roots[0].updateMultiple(scale: 2, rotation: 0.1);
      await _flush(tester);
      expect(identical(roots[0], identity), isTrue);
      if (layout == 'double') {
        pageController.jumpToPage(1);
        await _flush(tester, 8);
        expect(roots[1].debugCoreCount, 1);
        _allActions(roots[1]);
      }
      await tester.pumpWidget(const SizedBox());
      await _flush(tester);
      for (final root in roots) {
        _emptyOwnership(root);
        root.dispose();
        await _until(tester, () => root.debugActuallyDisposed,
            'root stream really closes after final owner');
      }
      pageController.dispose();
      expect(tester.takeException(), isNull);
    });
  }
}

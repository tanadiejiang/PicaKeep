import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_view/photo_view.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/image_pipeline/image_work_scheduler.dart';
import 'package:picakeep/foundation/image_pipeline/reader_page_source.dart';
import 'package:picakeep/foundation/image_pipeline/reader_raster_backend.dart';
import 'package:picakeep/foundation/image_pipeline/reader_viewport.dart';
import 'package:picakeep/foundation/reader_image_quality.dart';
import 'package:picakeep/pages/reader/reader_image_surface.dart';

const _sourceSize = Size(8000, 12000);

class _Source extends FileReaderPageSource {
  _Source()
      : super(
            identity: const ReaderPageIdentity(
                sourceKey: 'single-pan-regression',
                workId: 'isolated',
                downloadId: 'isolated',
                episode: 1,
                page: 0,
                sourceVersion: '1'),
            file: File('unused'));
  @override
  Future<File> openOriginalFile({ReaderPageCancellation? cancellation}) async {
    cancellation?.throwIfCancelled();
    return File('unused');
  }
}

class _Backend extends ReaderRasterBackend {
  final requests = <ReaderTileDemand>[];
  @override
  bool get requiresFileBacking => false;
  @override
  Future<ReaderRasterMetadata> probe(File file) async =>
      const ReaderRasterMetadata(
          size: _sourceSize, animated: false, format: 'test', workingBytes: 1);
  @override
  Future<ui.Image> decode(File file, ReaderTileDemand demand,
      {required String backingPath,
      required int memoryBudgetBytes,
      required bool Function() isCancelled,
      Future<void>? cancelled}) async {
    requests.add(demand);
    if (isCancelled()) throw const ImageWorkCancelled();
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawColor(const Color(0xff0000ff), BlendMode.src);
    final picture = recorder.endRecording();
    try {
      return picture.toImageSync(demand.outputWidth, demand.outputHeight);
    } finally {
      picture.dispose();
    }
  }
}

Future<void> _advance(WidgetTester tester, {int frames = 200}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 2)));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('reader-postframe-pan-');
    App.dataPath = root.path;
    App.cachePath = '${root.path}/cache';
  });
  tearDownAll(() async => root.delete(recursive: true));

  for (final dpr in [1.0, 3.5]) {
    for (final asyncContinuation in [false, true]) {
      testWidgets(
          'one pan after native onPresented updates source ROI '
          '(${asyncContinuation ? 'await continuation' : 'synchronous callback'}, DPR $dpr)',
          (tester) async {
        tester.view.devicePixelRatio = dpr;
        tester.view.physicalSize = Size(1600 * dpr, 1000 * dpr);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final controller = PhotoViewController();
        final changes = ValueNotifier<int>(0);
        final subscription =
            controller.outputStateStream.listen((_) => changes.value++);
        final viewport = GlobalKey();
        final surface = GlobalKey();
        final backend = _Backend();
        final source = _Source();
        final frames = <ReaderPresentedFrame>[];
        var upgraded = false;
        var panned = false;
        Rect? beforePan;
        final target =
            dpr == 1 ? const Offset(3600, 5700) : const Offset(1200, 1440);
        final nativeFrame = Completer<ReaderPresentedFrame>();
        void pan(ReaderPresentedFrame frame) {
          panned = true;
          beforePan = frame.sourceRect;
          controller.updateMultiple(
              scale: 1 / dpr,
              position: controller.position +
                  (frame.sourceRect.center - target) / dpr);
        }

        if (asyncContinuation) {
          unawaited(() async {
            final frame = await nativeFrame.future;
            pan(frame);
          }());
        }

        try {
          await tester.pumpWidget(MaterialApp(
              home: Scaffold(
                  body: Center(
                      child: SizedBox(
                          key: viewport,
                          width: dpr == 1 ? 400 : 1440 / dpr,
                          height: dpr == 1 ? 600 : 2821 / dpr,
                          child: PhotoView.customChild(
                              controller: controller,
                              childSize: _sourceSize,
                              initialScale: 0.05,
                              minScale: 0.05,
                              maxScale: 4.0,
                              child: ReaderImageSurface(
                                  key: surface,
                                  source: source,
                                  sourceSize: _sourceSize,
                                  viewportKey: viewport,
                                  mode: ReaderDisplayMode.sharpFirst,
                                  transformChanges: changes,
                                  backend: backend,
                                  onPresented: (frame) {
                                    frames.add(frame);
                                    if (!upgraded) {
                                      upgraded = true;
                                      controller.scale = 1 / dpr;
                                    } else if (frame.nativePixels && !panned) {
                                      // This is the exact production callback phase:
                                      // one controller update, with no extra frame,
                                      // changes notification or synthetic callback.
                                      if (asyncContinuation) {
                                        if (!nativeFrame.isCompleted) {
                                          nativeFrame.complete(frame);
                                        }
                                      } else {
                                        pan(frame);
                                      }
                                    }
                                  })))))));
          await _advance(tester);
          expect(upgraded, isTrue);
          expect(panned, isTrue);
          expect(beforePan, isNotNull);
          expect(
              (controller.position - (beforePan!.center - target) / dpr)
                  .distance,
              lessThan(0.00001));

          final viewportRender =
              viewport.currentContext!.findRenderObject()! as RenderBox;
          final surfaceRender =
              surface.currentContext!.findRenderObject()! as RenderBox;
          final actualCentre = surfaceRender.globalToLocal(viewportRender
              .localToGlobal(viewportRender.size.center(Offset.zero)));
          expect((actualCentre - target).distance, lessThanOrEqualTo(2),
              reason: 'PhotoView should apply the requested legal position');
          final moved = frames.where((frame) =>
              frame.nativePixels &&
              (frame.sourceRect.center - target).distance <= 2);
          expect(ImageWorkScheduler.shared.pendingCount, 0,
              reason:
                  'all requested tile work must finish before assessing the pan');
          expect(moved, isNotEmpty,
              reason:
                  'the first pan must publish a complete current original ROI; '
                  'callbacks=${frames.map((frame) => frame.sourceRect).toList()}');
        } finally {
          await tester.pumpWidget(const SizedBox());
          await _advance(tester, frames: 12);
          await tester.runAsync(() async {
            await subscription.cancel();
            controller.dispose();
            changes.dispose();
            await source.dispose();
          });
          expect(ReaderSurfaceDiagnostics.residentBytes, 0);
          expect(ImageWorkScheduler.shared.pendingCount, 0);
          expect(ReaderPageFileLease.activeLeaseCount, 0);
        }
      });
    }
  }
}

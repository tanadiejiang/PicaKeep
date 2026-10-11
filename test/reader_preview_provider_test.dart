import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:photo_view/photo_view.dart';
import 'package:picakeep/foundation/image_loader/base_image_provider.dart';
import 'package:picakeep/foundation/image_loader/reader_image_retry.dart';
import 'package:picakeep/foundation/image_loader/reader_preview_preloader.dart';
import 'package:picakeep/foundation/image_loader/reader_preview_provider.dart';
import 'package:picakeep/foundation/image_loader/stream_image_provider.dart';
import 'package:picakeep/network/managed_image_retry.dart';
import 'package:picakeep/pages/reader/comic_reading_page.dart';
import 'package:picakeep/pages/reader/reader_image_surface.dart';

class _Provider extends BaseImageProvider<_Provider> {
  _Provider(this.callback, this.key);
  final Future<Uint8List> Function() callback;
  @override
  final String key;
  @override
  bool get cacheRawBytes => false;
  // This fixture only returns preconstructed bounded test bytes/errors; it is
  // not evidence that arbitrary third-party Base loaders enforce input limits.
  @override
  bool get supportsReaderInputLimits => true;
  @override
  Future<_Provider> obtainKey(ImageConfiguration configuration) async => this;
  @override
  Future<Uint8List> load(StreamController<ImageChunkEvent> events) =>
      callback();
}

class _OpaqueProvider extends ImageProvider<_OpaqueProvider> {
  _OpaqueProvider(this.bytes, this.onLoad, {this.onKey});
  final Uint8List bytes;
  final void Function() onLoad;
  final VoidCallback? onKey;
  @override
  Future<_OpaqueProvider> obtainKey(ImageConfiguration configuration) async {
    onKey?.call();
    return this;
  }

  @override
  ImageStreamCompleter loadImage(
      _OpaqueProvider key, ImageDecoderCallback decode) {
    onLoad();
    final memory = MemoryImage(bytes);
    return memory.loadImage(memory, decode);
  }
}

class _DelayedInvalidationPool extends ReaderPreviewImagePool {
  _DelayedInvalidationPool(this.gate);
  final Future<void> gate;
  @override
  Future<void> invalidate(String resourceKey) async {
    await gate;
    await super.invalidate(resourceKey);
  }
}

Uint8List _largeHeader(Uint8List png) {
  final bytes = Uint8List.fromList(png);
  final view = ByteData.sublistView(bytes);
  view.setUint32(16, 16384);
  view.setUint32(20, 16384);
  var crc = 0xffffffff;
  for (var i = 12; i < 29; i++) {
    crc ^= bytes[i];
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
    }
  }
  view.setUint32(29, crc ^ 0xffffffff);
  return bytes;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final png = img.encodePng(
      img.Image(width: 40, height: 60)..clear(img.ColorRgb8(30, 80, 120)));

  Future<void> flush(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
          () async => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  var inRealImageTest = false;
  Future<void> cacheFrame() async {
    final binding = TestWidgetsFlutterBinding.instance;
    for (var i = 0; i < 3; i++) {
      if (inRealImageTest) {
        await Future<void>.delayed(Duration.zero);
      } else {
        await binding.runAsync(() async => Future<void>.delayed(Duration.zero));
      }
      await binding.pump();
      binding.scheduleFrame();
      await binding.pump();
    }
  }

  // Native static codecs need real async; ImageCache retires handles on the
  // next frame, so these provider-only tests still require a widget binding.
  void imageTest(String name, Future<void> Function() body) {
    testWidgets(name, (tester) async {
      inRealImageTest = true;
      try {
        await tester.runAsync(() async {
          try { await body(); } finally { await cacheFrame(); }
        });
      } finally { inRealImageTest = false; }
      expect(tester.takeException(), isNull);
      expect(ReaderPreviewImagePool.globalReservedWorkingBytes, 0,
          reason: 'each provider fixture drains its actual native/cache work');
    });
  }

  Widget page(
          {required ReaderPreviewImagePool pool,
          required ReaderPreviewProviderLoader load,
          bool continuous = true,
          String key = 'page',
          Future<void> Function()? invalidate,
          PhotoViewController? controller,
          Size? hint,
          ValueChanged<Size>? onSize}) =>
      MaterialApp(
          home: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                  width: 300,
                  height: continuous ? null : 400,
                  child: ReaderPreviewPageImage(
                      resourceKey: key,
                      pool: pool,
                      loadProvider: load,
                      onInvalidate: invalidate,
                      controller: controller,
                      continuousWidth: continuous ? 300 : null,
                      sizeHint: hint,
                      onSourceSize: onSize))));

  test('retry classification is finite and respects Retry-After', () {
    final options = RequestOptions(path: 'offline');
    DioException response(int code, {String? after}) => DioException(
        requestOptions: options,
        type: DioExceptionType.badResponse,
        response: Response(
            requestOptions: options,
            statusCode: code,
            headers: Headers.fromMap({
              if (after != null) 'retry-after': [after]
            })));
    expect([
      for (var i = 1; i <= 4; i++)
        readerImageRetryDelay(const SocketException('offline'), i)
    ], [
      const Duration(seconds: 2),
      const Duration(seconds: 4),
      const Duration(seconds: 8),
      null
    ]);
    for (final code in [400, 401, 403, 404, 501, 505]) {
      expect(readerImageRetryDelay(response(code), 1), isNull);
    }
    expect(readerImageRetryDelay(response(429, after: '11'), 1),
        const Duration(seconds: 11));
    expect(readerImageRetryDelay(response(429, after: '300'), 1), isNull);
    expect(
        readerImageRetryDelay(response(429, after: '9223372036854775807'), 1),
        isNull);
    final repeated = response(429);
    repeated.response!.headers.set('retry-after', ['5', '10']);
    expect(readerImageRetryDelay(repeated, 1), isNull);
    final now = DateTime.utc(2026, 1, 1);
    expect(
        readerImageRetryDelay(
            response(429,
                after: HttpDate.format(now.add(const Duration(seconds: 9)))),
            1,
            now: now),
        const Duration(seconds: 9));
    for (final error in <Object>[
      const HandshakeException('tls'),
      const FormatException('bad image'),
      StateError('budget'),
      const ReaderImageCancelled()
    ]) {
      expect(readerImageRetryDelay(error, 1), isNull);
    }
    expect(readerImageRetryDelay(response(503), 3), const Duration(seconds: 8));
  });

  testWidgets('retry wait is cancelled without waiting for backoff',
      (tester) async {
    final abort = StreamImageAbortSignal();
    final expected = expectLater(
        waitForReaderImageRetry(const Duration(seconds: 8), abort),
        throwsA(isA<ReaderImageCancelled>()));
    abort.abort();
    await tester.pump();
    await expected;
  });

  imageTest('provider wrapper retries 2/4/8 exactly, managed only during reads',
      () async {
    final delays = <Duration>[];
    final pool = ReaderPreviewImagePool(waitForRetry: (delay, abort) async {
      delays.add(delay);
    });
    addTearDown(pool.dispose);
    var calls = 0;
    final lease = pool.acquire(
        resourceKey: 'retry',
        loadProvider: (_) => _Provider(() async {
              expect(isManagedImageRetry, isTrue);
              if (++calls < 4) throw const SocketException('offline');
              return png;
            }, 'retry'));
    final stream = lease.provider.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener((info, _) => info.dispose(),
        onError: (Object error, StackTrace? stack) {
      fail('unexpected failure type ${error.runtimeType}');
    });
    stream.addListener(listener);
    try {
      expect(await lease.firstFrame, const Size(40, 60));
      expect(calls, 4);
      expect(delays.map((d) => d.inSeconds), [2, 4, 8]);
      expect(isManagedImageRetry, isFalse);
    } finally {
      stream.removeListener(listener);
      lease.release();
    }
  });

  imageTest(
      'permanent failures have no automatic retry and terminal attempts cap at four',
      () async {
    for (final error in <Object>[
      const FormatException('bad'),
      const SocketException('offline')
    ]) {
      var calls = 0;
      final pool = ReaderPreviewImagePool(waitForRetry: (_, __) async {});
      final lease = pool.acquire(
          resourceKey: 'terminal',
          loadProvider: (_) => _Provider(() async {
                calls++;
                throw error;
              }, 'terminal'));
      final stream = lease.provider.resolve(ImageConfiguration.empty);
      final listener = ImageStreamListener((info, _) => info.dispose(),
          onError: (Object _, StackTrace? __) {});
      stream.addListener(listener);
      await expectLater(lease.firstFrame, throwsA(same(error)));
      expect(calls, error is SocketException ? 4 : 1);
      stream.removeListener(listener);
      lease.release();
      pool.dispose();
    await cacheFrame();
    }
  });

  testWidgets(
      'continuous preview uses ComicImage original dimensions without ROI',
      (tester) async {
    final pool = ReaderPreviewImagePool();
    var reads = 0;
    final sizes = <Size>[];
    await tester.pumpWidget(page(
        pool: pool,
        load: (_) => _Provider(() async {
              reads++;
              return png;
            }, 'full'),
        onSize: sizes.add));
    await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 20)));
    await flush(tester);
    expect(reads, 1);
    expect(find.byType(ComicImage), findsOneWidget);
    expect(find.byType(ReaderImageSurface), findsNothing);
    final raw = tester.widget<RawImage>(find.byType(RawImage).first);
    expect(raw.image!.width, 40);
    expect(raw.image!.height, 60);
    expect(tester.getSize(find.byType(ReaderPreviewPageImage)).height, 450);
    expect(sizes, contains(const Size(40, 60)));
    await tester.pumpWidget(const SizedBox());
    pool.dispose();
    await cacheFrame();
  });

  testWidgets(
      'single preview uses original PhotoView provider and zoom never opens tiles',
      (tester) async {
    final pool = ReaderPreviewImagePool();
    var reads = 0;
    final controller = PhotoViewController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(page(
        pool: pool,
        continuous: false,
        controller: controller,
        load: (_) => _Provider(() async {
              reads++;
              return png;
            }, 'photo')));
    await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 20)));
    await flush(tester);
    expect(find.byType(PhotoView), findsOneWidget);
    expect(find.byType(ReaderImageSurface), findsNothing);
    final view = tester.widget<PhotoView>(find.byType(PhotoView));
    expect(view.imageProvider, isNot(isA<ResizeImage>()));
    await tester.tap(find.byType(PhotoView));
    await tester.pump(const Duration(milliseconds: 30));
    await tester.tap(find.byType(PhotoView));
    await flush(tester);
    expect(reads, 1);
    await tester.pumpWidget(const SizedBox());
    pool.dispose();
    await cacheFrame();
  });

  testWidgets(
      'known size lays out before provider completes, switch ignores old generation',
      (tester) async {
    final pool = ReaderPreviewImagePool();
    final old = Completer<ImageProvider>();
    StreamImageAbortSignal? oldAbort;
    await tester.pumpWidget(page(
        pool: pool,
        hint: const Size(400, 300),
        key: 'old',
        load: (abort) {
          oldAbort = abort;
          return old.future;
        }));
    expect(tester.getSize(find.byType(ReaderPreviewPageImage)).height, 225);
    await tester.pumpWidget(
        page(pool: pool, key: 'new', load: (_) => MemoryImage(png)));
    expect(oldAbort!.isAborted, isTrue);
    old.complete(MemoryImage(png));
    await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 20)));
    await flush(tester);
    expect(find.text('图片暂时无法打开，请重试'), findsNothing);
    expect(tester.getSize(find.byType(ReaderPreviewPageImage)).height, 450);
    await tester.pumpWidget(const SizedBox());
    pool.dispose();
    await cacheFrame();
  });

  testWidgets(
      'decode failure manual retry evicts only page raw key and creates new operation',
      (tester) async {
    final pool = ReaderPreviewImagePool();
    var reads = 0, invalidations = 0;
    await tester.pumpWidget(page(
        pool: pool,
        key: 'decode-retry',
        invalidate: () async {
          invalidations++;
        },
        load: (abort) => StreamImageProvider(() {
              reads++;
              return Stream<List<int>>.value(reads == 1 ? [1, 2, 3] : png);
            }, 'unique-decode-retry', abortSignal: abort)));
    await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 30)));
    await flush(tester);
    expect(reads, 1);
    expect(find.text('图片暂时无法打开，请重试'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 30)));
    await flush(tester);
    expect(invalidations, 1);
    expect(reads, 2);
    expect(find.text('图片暂时无法打开，请重试'), findsNothing);
    expect(tester.widgetList<RawImage>(find.byType(RawImage))
        .any((image) => image.image != null), isTrue,
        reason: 'retry recovered actual pixels, not just a cleared error/loading state');
    await tester.pumpWidget(const SizedBox());
    pool.dispose();
    await cacheFrame();
  });

  testWidgets('switching during manual retry never invalidates the new page',
      (tester) async {
    final gate = Completer<void>();
    final pool = _DelayedInvalidationPool(gate.future);
    var oldInvalidations = 0, newInvalidations = 0;
    await tester.pumpWidget(page(
        pool: pool,
        key: 'manual-old',
        invalidate: () async {
          oldInvalidations++;
        },
        load: (_) => _Provider(() async {
              throw const FormatException('terminal');
            }, 'manual-old')));
    await flush(tester);
    await tester.tap(find.text('重试'));
    await tester.pumpWidget(page(
        pool: pool,
        key: 'manual-new',
        invalidate: () async {
          newInvalidations++;
        },
        load: (_) => MemoryImage(png)));
    gate.complete();
    await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 20)));
    await flush(tester);
    expect(oldInvalidations, 0);
    expect(newInvalidations, 0);
    expect(find.text('图片暂时无法打开，请重试'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    pool.dispose();
    await cacheFrame();
  });

  testWidgets('double page delegates gestures to its outer gallery',
      (tester) async {
    final pool = ReaderPreviewImagePool();
    await tester.pumpWidget(
        page(pool: pool, continuous: false, load: (_) => MemoryImage(png)));
    await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 20)));
    await flush(tester);
    expect(find.byType(PhotoView), findsNothing);
    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(ReaderImageSurface), findsNothing);
    await tester.pumpWidget(const SizedBox());
    pool.dispose();
    await cacheFrame();
  });

  testWidgets(
      'default clock retries only at 2/4/8s and leaving cancels the next timer',
      (tester) async {
    final waits = <Duration>[];
    final pool = ReaderPreviewImagePool(waitForRetry: (delay, abort) {
      waits.add(delay);
      return waitForReaderImageRetry(delay, abort);
    });
    var attempts = 0;
    await tester.pumpWidget(page(
        pool: pool,
        load: (_) => _Provider(() async {
              attempts++;
              throw const SocketException('transient');
            }, 'timed-retry')));
    await tester.pump();
    for (var i = 0; i < 8 && waits.isEmpty; i++) {
      await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
      await tester.pump();
    }
    expect(attempts, 1);
    expect(waits, [const Duration(seconds: 2)]);
    expect(pool.reservedWorkingBytes, 0, reason: 'backoff cannot keep an input loan');
    await tester.pump(const Duration(milliseconds: 1999));
    expect(attempts, 1);
    await tester.pump(const Duration(milliseconds: 1));
    expect(attempts, 2);
    for (var i = 0; i < 8 && waits.length < 2; i++) {
      await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
      await tester.pump();
    }
    expect(waits, [const Duration(seconds: 2), const Duration(seconds: 4)]);
    await tester.pump(const Duration(milliseconds: 3999));
    expect(attempts, 2);
    await tester.pump(const Duration(milliseconds: 1));
    expect(attempts, 3);
    for (var i = 0; i < 8 && waits.length < 3; i++) {
      await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
      await tester.pump();
    }
    expect(waits, [const Duration(seconds: 2), const Duration(seconds: 4), const Duration(seconds: 8)]);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 30));
    expect(attempts, 3, reason: 'exit must cancel the pending 8-second retry');
    pool.dispose();
    await cacheFrame();
  });

  imageTest(
      'oversized valid header preloads zero frames; visible starts a fresh original attempt',
      () async {
    var loads = 0, decodes = 0;
    final pool = ReaderPreviewImagePool(onDecodeStarted: () => decodes++);
    ImageProvider load(StreamImageAbortSignal _) => _Provider(() async {
          return ++loads == 1 ? _largeHeader(png) : png;
        }, 'oversized-header');
    final preload =
        pool.acquire(resourceKey: 'huge', loadProvider: load, visible: false);
    final stream = preload.provider.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener((info, _) {
      info.dispose();
      fail('preload decoded an oversized frame');
    }, onError: (Object _, StackTrace? __) {});
    stream.addListener(listener);
    await expectLater(
        preload.firstFrame,
        throwsA(isA<ReaderImageLimit>()
            .having((e) => e.reason, 'reason', 'source-pixels')));
    expect(decodes, 0);
    expect(pool.reservedPreloadBytes, 0);
    final visible = pool.acquire(resourceKey: 'huge', loadProvider: load);
    expect(visible.provider, isNot(same(preload.provider)));
    final visibleStream = visible.provider.resolve(ImageConfiguration.empty);
    final visibleListener = ImageStreamListener((info, _) => info.dispose(),
        onError: (Object _, StackTrace? __) {});
    visibleStream.addListener(visibleListener);
    expect(await visible.firstFrame, const Size(40, 60));
    expect(loads, 2);
    expect(decodes, 1);
    stream.removeListener(listener);
    preload.release();
    visibleStream.removeListener(visibleListener);
    visible.release();
    pool.dispose();
    await cacheFrame();
  });

  imageTest(
      'opaque providers never bypass input/decoder admission, including visible pages',
      () async {
    var loads = 0, keys = 0;
    final pool = ReaderPreviewImagePool();
    ImageProvider load(StreamImageAbortSignal _) =>
        _OpaqueProvider(png, () => loads++, onKey: () => keys++);
    final preload =
        pool.acquire(resourceKey: 'opaque', loadProvider: load, visible: false);
    final stream = preload.provider.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener((info, _) => info.dispose(),
        onError: (Object _, StackTrace? __) {});
    stream.addListener(listener);
    await expectLater(
        preload.firstFrame,
        throwsA(isA<ReaderPreviewPreloadRejected>()
            .having((e) => e.reason, 'reason', 'opaque-provider')));
    expect(loads, 0);
    expect(keys, 0);
    final visible = pool.acquire(resourceKey: 'opaque', loadProvider: load);
    final visibleStream = visible.provider.resolve(ImageConfiguration.empty);
    visibleStream.addListener(listener);
    await expectLater(visible.firstFrame, throwsA(isA<ReaderImageLimit>()
        .having((error) => error.reason, 'reason', 'unbounded-provider')));
    expect(loads, 0);
    expect(keys, 0);
    stream.removeListener(listener);
    preload.release();
    visibleStream.removeListener(listener);
    visible.release();
    pool.dispose();
    await cacheFrame();
  });

  imageTest(
      'preload decoded and work reservations are checked before decode and released',
      () async {
    var decodes = 0;
    final pool = ReaderPreviewImagePool(
        maximumPreloadDecodedBytes: 10000,
        maximumPreloadWorkingBytes: 30000,
        onDecodeStarted: () => decodes++);
    expect(ReaderPreviewImagePool.globalReservedWorkingBytes, 0);
    final first = pool.acquire(
        resourceKey: 'budget-one',
        loadProvider: (_) => MemoryImage(png),
        visible: false);
    final firstStream = first.provider.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener((info, _) => info.dispose(),
        onError: (Object _, StackTrace? __) {});
    firstStream.addListener(listener);
    await expectLater(first.firstFrame, completion(const Size(40, 60)),
        reason: 'first bounded PNG must fit: encoded=${png.length}');
    expect(pool.reservedPreloadBytes, greaterThan(0));
    final second = pool.acquire(
        resourceKey: 'budget-two',
        loadProvider: (_) => MemoryImage(png),
        visible: false);
    final secondStream = second.provider.resolve(ImageConfiguration.empty);
    secondStream.addListener(listener);
    await expectLater(
        second.firstFrame, throwsA(isA<ReaderPreviewPreloadRejected>()));
    expect(decodes, 1);
    firstStream.removeListener(listener);
    first.release();
    secondStream.removeListener(listener);
    second.release();
    await cacheFrame();
    expect(pool.reservedPreloadBytes, 0);
    pool.dispose();
    await cacheFrame();
  });

  imageTest(
      'idle extras require explicit real budget permission and never exceed three',
      () async {
    final pool = ReaderPreviewImagePool();
    final preload = ReaderPreviewPreloader(pool: pool);
    final calls = <int>[];
    final done = Completer<void>();
    preload.update(
        currentPage: 0,
        pageCount: 30,
        preloadCount: 2,
        canAddIdleExtras: () => true,
        resourceKeyForPage: (p) => 'idle-$p',
        loadProvider: (p, _) {
          calls.add(p);
          if (calls.length == 5) done.complete();
          return MemoryImage(png);
        });
    await done.future;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(calls, [1, 2, 3, 4, 5]);
    preload.dispose();
    pool.dispose();
    await cacheFrame();
  });

  testWidgets(
      'preloaded animation pauses offscreen and resumes for a visible consumer',
      (tester) async {
    img.Image frame(int red, int blue) {
      final image = img.Image(width: 2, height: 2, withPalette: true);
      image.palette!.setRgb(1, red, 0, blue);
      for (var y = 0; y < 2; y++) {
        for (var x = 0; x < 2; x++) {
          image.setPixelIndex(x, y, 1);
        }
      }
      return image;
    }

    final gif = (img.GifEncoder(repeat: 100)
          ..addFrame(frame(255, 0), duration: 80)
          ..addFrame(frame(0, 255), duration: 80))
        .finish()!;
    var frames = 0;
    final pool = ReaderPreviewImagePool(onFrameDecodeStarted: () => frames++);
    final preload = ReaderPreviewPreloader(pool: pool);
    preload.update(
        currentPage: 0,
        pageCount: 2,
        preloadCount: 1,
        resourceKeyForPage: (_) => 'animated',
        loadProvider: (_, __) => MemoryImage(gif));
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
          () async => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(preload.retainedDecodedBytes, 16);
    final pausedAt = frames;
    expect(pausedAt, inInclusiveRange(1, 2));
    await tester.pump(const Duration(seconds: 5));
    expect(frames, pausedAt);
    await tester.pumpWidget(
        page(pool: pool, key: 'animated', load: (_) => MemoryImage(gif)));
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
          () async => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(frames, greaterThan(pausedAt));
    await tester.pumpWidget(const SizedBox());
    preload.dispose();
    pool.dispose();
    await cacheFrame();
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(
          () async => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(pool.reservedPreloadBytes, 0);
  });

  testWidgets(
      'leaving during a byte stream absorbs the old cancellation without leaking',
      (tester) async {
    final pool = ReaderPreviewImagePool();
    final body = StreamController<List<int>>();
    StreamImageAbortSignal? abort;
    await tester.pumpWidget(page(
        pool: pool,
        key: 'cancel-bytes',
        load: (signal) {
          abort = signal;
          return StreamImageProvider(() => body.stream, 'cancel-bytes',
              abortSignal: signal);
        }));
    await flush(tester);
    expect(body.hasListener, isTrue,
        reason: 'fixture must enter the real provider byte subscription');
    await tester.pumpWidget(const SizedBox());
    await flush(tester);
    expect(abort!.isAborted, isTrue);
    expect(pool.activeEntryCount, 0);
    expect(tester.takeException(), isNull);
    await tester.runAsync(() => body.close());
    await flush(tester);
    expect(body.hasListener, isFalse);
    expect(body.isClosed, isTrue);
    expect(tester.takeException(), isNull);
    pool.dispose();
    await cacheFrame();
  }, timeout: const Timeout(Duration(seconds: 10)));

  imageTest(
      'preload window clamps count, de-duplicates, and defaults to no idle extras',
      () async {
    final pool = ReaderPreviewImagePool();
    final preloader = ReaderPreviewPreloader(pool: pool);
    final calls = <int>[];
    final done = Completer<void>();
    preloader.update(
        currentPage: 2,
        pageCount: 8,
        preloadCount: 2,
        resourceKeyForPage: (page) => 'window-$page',
        loadProvider: (page, _) {
          calls.add(page);
          if (calls.length == 2) done.complete();
          return MemoryImage(png);
        });
    await done.future;
    expect(calls, [3, 4]);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    preloader.update(
        currentPage: 2,
        pageCount: 8,
        preloadCount: 2,
        resourceKeyForPage: (page) => 'window-$page',
        loadProvider: (page, _) {
          calls.add(page);
          return MemoryImage(png);
        });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(calls, [3, 4]);
    preloader.update(
        currentPage: -1,
        pageCount: 8,
        preloadCount: 999,
        resourceKeyForPage: (page) => '$page',
        loadProvider: (_, __) => MemoryImage(png));
    expect(preloader.retainedKeys, isEmpty);
    preloader.dispose();
    pool.dispose();
    await cacheFrame();
  });

  imageTest(
      'preloader cancellation cannot abort the visible consumer sharing its image',
      () async {
    final pool = ReaderPreviewImagePool(
        maximumPreloadDecodedBytes: 1, maximumPreloadWorkingBytes: 1);
    final preloader = ReaderPreviewPreloader(pool: pool);
    final gate = Completer<Uint8List>();
    final entered = Completer<void>();
    StreamImageAbortSignal? operationAbort;
    var loads = 0;
    ImageProvider load(StreamImageAbortSignal abort) {
      operationAbort = abort;
      return _Provider(() {
        loads++;
        if (!entered.isCompleted) entered.complete();
        return gate.future;
      }, 'shared');
    }

    preloader.update(
        currentPage: 0,
        pageCount: 3,
        preloadCount: 1,
        resourceKeyForPage: (_) => 'shared',
        loadProvider: (_, abort) => load(abort));
    await entered.future;
    final visible = pool.acquire(resourceKey: 'shared', loadProvider: load);
    final stream = visible.provider.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener((info, _) => info.dispose(),
        onError: (Object _, StackTrace? __) {});
    stream.addListener(listener);
    preloader.dispose();
    expect(operationAbort!.isAborted, isFalse);
    gate.complete(png);
    expect(await visible.firstFrame, const Size(40, 60));
    expect(loads, 1);
    stream.removeListener(listener);
    visible.release();
    expect(operationAbort!.isAborted, isTrue);
    pool.dispose();
    await cacheFrame();
  });

  imageTest(
      'foreground priority postpones neighbours; retained decoded bytes remain capped',
      () async {
    final pool = ReaderPreviewImagePool();
    final foreground = pool.acquire(
        resourceKey: 'foreground', loadProvider: (_) => MemoryImage(png));
    final preloader =
        ReaderPreviewPreloader(pool: pool, maximumDecodedBytes: 1);
    var calls = 0;
    preloader.update(
        currentPage: 0,
        pageCount: 500,
        preloadCount: 999,
        resourceKeyForPage: (page) => 'cap-$page',
        loadProvider: (_, __) {
          calls++;
          return MemoryImage(png);
        });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(calls, 0);
    foreground.release();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(calls, 8);
    expect(preloader.retainedDecodedBytes, lessThanOrEqualTo(1));
    expect(preloader.retainedKeys, isEmpty);
    preloader.dispose();
    pool.dispose();
    await cacheFrame();
  });
}

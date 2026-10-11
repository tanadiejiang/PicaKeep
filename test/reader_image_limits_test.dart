import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:picakeep/foundation/image_loader/reader_image_limits.dart';
import 'package:picakeep/foundation/image_loader/jm_image_recombine.dart';
import 'package:picakeep/foundation/image_loader/reader_image_retry.dart';
import 'package:picakeep/foundation/image_loader/reader_preview_provider.dart';
import 'package:picakeep/foundation/image_loader/stream_image_provider.dart';
import 'package:picakeep/pages/reader/comic_reading_page.dart';
import 'package:picakeep/pages/reader/reader_image_surface.dart';

class _ObservedFile implements File {
  _ObservedFile(this.file, {this.afterStat});
  final File file;
  final Future<void> Function()? afterStat;
  var reads = 0;
  @override
  Future<int> length() async {
    final size = await file.length();
    await afterStat?.call();
    return size;
  }

  @override
  Stream<List<int>> openRead([int? start, int? end]) {
    reads++;
    return file.openRead(start, end);
  }

  @override
  Future<Uint8List> readAsBytes() => file.readAsBytes();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// A genuine, complete 10000x10000 grayscale PNG: rows are compressed
// incrementally, so the fixture itself never allocates a 400 MB raster.
Uint8List _largePng() {
  final encoded = BytesBuilder(copy: false);
  final sink = ZLibEncoder()
      .startChunkedConversion(ByteConversionSink.withCallback(encoded.add));
  final row = Uint8List(10001);
  for (var y = 0; y < 10000; y++) {
    sink.add(row);
  }
  sink.close();
  Uint8List chunk(String type, List<int> data) {
    final output = Uint8List(data.length + 12);
    final view = ByteData.sublistView(output);
    view.setUint32(0, data.length);
    output.setRange(4, 8, ascii.encode(type));
    output.setRange(8, 8 + data.length, data);
    var crc = 0xffffffff;
    for (var i = 4; i < output.length - 4; i++) {
      crc ^= output[i];
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
      }
    }
    view.setUint32(output.length - 4, crc ^ 0xffffffff);
    return output;
  }

  final header = Uint8List(13);
  ByteData.sublistView(header)
    ..setUint32(0, 10000)
    ..setUint32(4, 10000);
  header[8] = 8;
  return (BytesBuilder(copy: false)
        ..add([137, 80, 78, 71, 13, 10, 26, 10])
        ..add(chunk('IHDR', header))
        ..add(chunk('IDAT', encoded.takeBytes()))
        ..add(chunk('IEND', const [])))
      .takeBytes();
}

class _Frame implements ui.FrameInfo {
  _Frame(this.image);
  @override
  final ui.Image image;
  @override
  Duration get duration => const Duration(milliseconds: 100);
}

class _ControlledCodec implements ui.Codec {
  _ControlledCodec(this.image);
  final ui.Image image;
  final pending = <Completer<ui.FrameInfo>>[];
  var calls = 0;
  bool disposed = false;
  @override
  int get frameCount => 2;
  @override
  int get repetitionCount => -1;
  @override
  Future<ui.FrameInfo> getNextFrame() {
    calls++;
    if (calls == 1) return Future.value(_Frame(image.clone()));
    final gate = Completer<ui.FrameInfo>();
    pending.add(gate);
    return gate.future;
  }

  ui.Image completeNext() {
    final frame = _Frame(image.clone());
    pending.removeAt(0).complete(frame);
    return frame.image;
  }

  void stopPending() {
    for (final gate in pending) {
      if (!gate.isCompleted) gate.completeError(StateError('fixture cleanup'));
    }
    pending.clear();
  }

  @override
  void dispose() {
    disposed = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final png = img.encodePng(
      img.Image(width: 40, height: 60)..clear(img.ColorRgb8(20, 80, 120)));
  late Directory root;
  late Uint8List giant;
  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('reader_input_limits_057_');
    giant = _largePng();
  });
  tearDownAll(() async {
    expect(ReaderPreviewImagePool.globalReservedWorkingBytes, 0);
    expect(root.path.split(Platform.pathSeparator).last,
        startsWith('reader_input_limits_057_'));
    await root.delete(recursive: true);
  });

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

  void imageTest(String name, Future<void> Function() body) {
    testWidgets(name, (tester) async {
      inRealImageTest = true;
      try {
        await tester.runAsync(() async {
          try {
            await body();
          } finally {
            await cacheFrame();
          }
        });
      } finally {
        inRealImageTest = false;
      }
      expect(tester.takeException(), isNull);
      expect(ReaderPreviewImagePool.globalReservedWorkingBytes, 0);
    });
  }

  testWidgets(
      'paused slow animation resumes single-flight and retires late frame without starting another',
      (tester) async {
    final original = (await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(png);
      final frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    }))!;
    final codec = _ControlledCodec(original);
    final pool = ReaderPreviewImagePool();
    final lease = pool.acquire(
        resourceKey: 'slow-animation',
        visible: false,
        loadProvider: (_) => MemoryImage(png));
    // Inject only the slow codec after actual encoded-header admission.
    // ignore: invalid_use_of_protected_member
    final completer = lease.provider.loadImage(lease.provider, (buffer,
        {getTargetSize}) async {
      buffer.dispose();
      return codec;
    });
    final stream = ImageStream()..setCompleter(completer);
    final listener = ImageStreamListener((info, _) => info.dispose(),
        onError: (Object _, StackTrace? __) {});
    var attached = true;
    stream.addListener(listener);
    try {
      await flush(tester);
      expect(codec.calls, 2);
      stream.removeListener(listener);
      attached = false;
      stream.addListener(listener);
      attached = true;
      await flush(tester);
      expect(codec.calls, 2,
          reason: 'resuming cannot start G2 beside pending G1');
      final resumed = codec.completeNext();
      await flush(tester);
      expect(resumed.debugDisposed, isTrue);
      expect(codec.calls, 3);
      stream.removeListener(listener);
      attached = false;
      lease.release();
      pool.dispose();
      await tester.pump();
      expect(codec.calls, 3,
          reason: 'retirement cannot reactivate another native frame');
      expect(codec.disposed, isFalse);
      expect(ReaderPreviewImagePool.globalReservedWorkingBytes, greaterThan(0));
      final late = codec.completeNext();
      await flush(tester);
      expect(late.debugDisposed, isTrue);
      expect(codec.disposed, isTrue);
      expect(ReaderPreviewImagePool.globalReservedWorkingBytes, 0);
      expect(tester.takeException(), isNull);
    } finally {
      if (attached) stream.removeListener(listener);
      lease.release();
      pool.dispose();
      codec.stopPending();
      await flush(tester);
      original.dispose();
    }
  });

  imageTest(
      'pool dispose retains static pixels while an external listener still owns the proxy',
      () async {
    final pool = ReaderPreviewImagePool();
    final lease = pool.acquire(
        resourceKey: 'external-static', loadProvider: (_) => MemoryImage(png));
    final listener = ImageStreamListener((info, _) => info.dispose(),
        onError: (Object _, StackTrace? __) {});
    final stream = lease.provider.resolve(ImageConfiguration.empty)
      ..addListener(listener);
    await lease.firstFrame;
    pool.dispose();
    await cacheFrame();
    expect(ReaderPreviewImagePool.globalReservedWorkingBytes, greaterThan(0));
    stream.removeListener(listener);
    lease.release();
    await cacheFrame();
    expect(ReaderPreviewImagePool.globalReservedWorkingBytes, 0);
  });

  imageTest(
      'silent optional-signal stream stops from reader Zone and only releases after real cancellation',
      () async {
    final cancelEntered = Completer<void>(), cancelReleased = Completer<void>();
    final body = StreamController<List<int>>(onCancel: () {
      cancelEntered.complete();
      return cancelReleased.future;
    });
    final firstPool = ReaderPreviewImagePool(),
        nextPool = ReaderPreviewImagePool();
    final first = firstPool.acquire(
        resourceKey: 'silent-no-signal',
        loadProvider: (_) =>
            StreamImageProvider(() => body.stream, 'silent-no-signal-raw'));
    final listener = ImageStreamListener((info, _) => info.dispose(),
        onError: (Object _, StackTrace? __) {});
    final firstStream = first.provider.resolve(ImageConfiguration.empty)
      ..addListener(listener);
    await Future<void>.delayed(Duration.zero);
    final cancelled =
        expectLater(first.firstFrame, throwsA(isA<ReaderImageCancelled>()));
    firstStream.removeListener(listener);
    first.release();
    await cancelEntered.future;
    await cancelled;
    var nextCalls = 0;
    final next = nextPool.acquire(
        resourceKey: 'after-silent',
        loadProvider: (_) {
          nextCalls++;
          return MemoryImage(png);
        });
    final nextStream = next.provider.resolve(ImageConfiguration.empty)
      ..addListener(listener);
    await Future<void>.delayed(Duration.zero);
    expect(nextCalls, 0);
    expect(ReaderPreviewImagePool.globalReservedWorkingBytes, 128 << 20);
    cancelReleased.complete();
    await next.firstFrame;
    expect(nextCalls, 1);
    nextStream.removeListener(listener);
    next.release();
    firstPool.dispose();
    nextPool.dispose();
    await body.close();
    await cacheFrame();
    expect(ReaderPreviewImagePool.globalReservedWorkingBytes, 0);
  });

  testWidgets(
      'very short continuous failures keep 48dp actions; JM source limits do not offer policy bypass',
      (tester) async {
    for (final error in <ReaderImageLimit>[
      const ReaderImageLimit('source-pixels'),
      const JmRecombineLimit('jm-recombine-budget', encodedBytes: 1),
      const JmRecombineLimit('jm-recombine-animation', encodedBytes: 1),
    ]) {
      final pool = ReaderPreviewImagePool();
      var safeClicks = 0;
      await tester.pumpWidget(MaterialApp(
          home: SingleChildScrollView(
              child: ReaderPreviewPageImage(
                  key: ValueKey(error.reason),
                  pool: pool,
                  resourceKey: error.reason,
                  sizeHint: const Size(1000000, 50),
                  continuousWidth: 360,
                  onUseSafeWhole: () => safeClicks++,
                  loadProvider: (_) => throw error))));
      await flush(tester);
      final retry = find.widgetWithText(TextButton, '重试');
      expect(tester.getSize(retry).height, greaterThanOrEqualTo(48));
      final safe = find.widgetWithText(TextButton, '改用清晰优先（安全整图）');
      if (error is JmRecombineLimit) {
        expect(safe, findsNothing);
      } else {
        expect(tester.getSize(safe).height, greaterThanOrEqualTo(48));
        await tester.tap(safe);
        expect(safeClicks, 1);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      pool.dispose();
      await flush(tester);
    }
  });

  testWidgets(
      'real GIF keeps durations and finite repetition, then retains pixels for an external listener',
      (tester) async {
    img.Image frame(int red, int blue) {
      final value = img.Image(width: 2, height: 2, withPalette: true);
      value.palette!.setRgb(1, red, 0, blue);
      for (var y = 0; y < 2; y++) {
        for (var x = 0; x < 2; x++) {
          value.setPixelIndex(x, y, 1);
        }
      }
      return value;
    }

    final gif = (img.GifEncoder(repeat: 1)
          ..addFrame(frame(255, 0), duration: 1000)
          ..addFrame(frame(0, 255), duration: 1000))
        .finish()!;
    final timing = (await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(gif);
      final frame = await codec.getNextFrame();
      final result =
          (frame.duration, codec.frameCount * (codec.repetitionCount + 1));
      frame.image.dispose();
      codec.dispose();
      return result;
    }))!;
    expect(timing.$2, greaterThanOrEqualTo(2));
    final pool = ReaderPreviewImagePool();
    final lease = pool.acquire(
        resourceKey: 'finite-real-gif', loadProvider: (_) => MemoryImage(gif));
    var observed = 0;
    final listener = ImageStreamListener((info, _) {
      observed++;
      info.dispose();
    }, onError: (Object _, StackTrace? __) {});
    final stream = lease.provider.resolve(ImageConfiguration.empty)
      ..addListener(listener);
    await flush(tester);
    expect(observed, 1);
    await tester.pump(timing.$1 ~/ 4);
    expect(observed, 1, reason: 'not an ASAP frame loop');
    for (var i = 0; i < timing.$2 + 2; i++) {
      await tester.pump(timing.$1 + const Duration(milliseconds: 1));
      await tester.runAsync(
          () async => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(observed, timing.$2);
    pool.dispose();
    await cacheFrame();
    expect(ReaderPreviewImagePool.globalReservedWorkingBytes, greaterThan(0));
    stream.removeListener(listener);
    lease.release();
    await flush(tester);
    expect(ReaderPreviewImagePool.globalReservedWorkingBytes, 0);
    expect(tester.takeException(), isNull);
  });

  test('file stat rejects before opening an oversized body', () async {
    final actual =
        await File('${root.path}/large.bin').writeAsBytes(Uint8List(4096));
    final file = _ObservedFile(actual);
    await expectLater(
        runWithReaderImageReadLimits(
            const ReaderImageReadLimits(maximumBytes: 1024),
            () => readReaderImageFile(file)),
        throwsA(isA<ReaderImageLimit>()));
    expect(file.reads, 0);
    expect((await readReaderImageFile(file)).length, 4096,
        reason: 'non-reader callers keep their original behavior');
  });

  test('file growth after stat is bounded by actual chunks', () async {
    final actual =
        await File('${root.path}/growing.bin').writeAsBytes(Uint8List(100));
    final file = _ObservedFile(actual, afterStat: () async {
      await actual.writeAsBytes(Uint8List(300), mode: FileMode.append);
    });
    await expectLater(
        runWithReaderImageReadLimits(
            const ReaderImageReadLimits(maximumBytes: 200),
            () => readReaderImageFile(file)),
        throwsA(isA<ReaderImageLimit>()));
    expect(file.reads, 1);
  });

  test('stream limit is before accumulation and waits for actual cancellation',
      () async {
    final cancelStarted = Completer<void>(), cancelFinished = Completer<void>();
    final body = StreamController<List<int>>(onCancel: () {
      cancelStarted.complete();
      return cancelFinished.future;
    });
    final progress = StreamController<ImageChunkEvent>.broadcast();
    final provider = StreamImageProvider(() => body.stream, 'bounded-stream');
    var finished = false;
    final checked = expectLater(
        runWithReaderImageReadLimits(
            const ReaderImageReadLimits(maximumBytes: 300),
            () => provider.load(progress)),
        throwsA(isA<ReaderImageLimit>()));
    unawaited(checked.then((_) => finished = true));
    body
      ..add(Uint8List(200))
      ..add(Uint8List(200));
    await cancelStarted.future;
    expect(finished, isFalse);
    cancelFinished.complete();
    await checked;
    await body.close();
    await progress.close();
  });

  test('known oversized headers discard response without consuming its body',
      () async {
    var listened = false, cancelled = 0;
    final body = StreamController<List<int>>(onListen: () => listened = true);
    final progress = StreamController<ImageChunkEvent>.broadcast();
    final provider = StreamImageProvider.withProgress(
        () => StreamImageLoadResult(
            stream: body.stream,
            expectedTotalBytes: 4096,
            cancel: () async {
              cancelled++;
            }),
        'bounded-header');
    await expectLater(
        runWithReaderImageReadLimits(
            const ReaderImageReadLimits(maximumBytes: 1024),
            () => provider.load(progress)),
        throwsA(isA<ReaderImageLimit>()));
    expect(listened, isFalse);
    expect(cancelled, 1);
    unawaited(body.close());
    await progress.close();
  });

  testWidgets(
      'actual huge PNG visible path rejects before any codec/frame and explains safe whole',
      (tester) async {
    var codecs = 0, frames = 0, retries = 0;
    final pool = ReaderPreviewImagePool(
        onDecodeStarted: () => codecs++,
        onFrameDecodeStarted: () => frames++,
        waitForRetry: (_, __) async {
          retries++;
        });
    await tester.pumpWidget(MaterialApp(
        home: SizedBox(
            width: 400,
            height: 600,
            child: ReaderPreviewPageImage(
                resourceKey: 'actual-large-png',
                pool: pool,
                loadProvider: (_) => MemoryImage(giant),
                continuousWidth: 400))));
    await flush(tester);
    expect(codecs, 0);
    expect(frames, 0);
    expect(retries, 0);
    expect(find.textContaining('清晰优先'), findsOneWidget);
    expect(find.byType(ReaderImageSurface), findsNothing);
    expect(pool.reservedWorkingBytes, 0);
    await tester.pumpWidget(const SizedBox());
    pool.dispose();
    await flush(tester);
    expect(tester.takeException(), isNull);
  });

  imageTest('visible joining an oversized preload cannot bypass source safety',
      () async {
    var frames = 0;
    final pool = ReaderPreviewImagePool(onFrameDecodeStarted: () => frames++);
    final entered = Completer<void>(), release = Completer<void>();
    final preload = pool.acquire(
        resourceKey: 'promoted-large',
        visible: false,
        loadProvider: (_) async {
          entered.complete();
          await release.future;
          return MemoryImage(giant);
        });
    final stream = preload.provider.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener((info, _) => info.dispose(),
        onError: (Object _, StackTrace? __) {});
    stream.addListener(listener);
    await entered.future;
    final visible = pool.acquire(
        resourceKey: 'promoted-large', loadProvider: (_) => MemoryImage(giant));
    final checked =
        expectLater(visible.firstFrame, throwsA(isA<ReaderImageLimit>()));
    release.complete();
    await checked;
    expect(frames, 0);
    expect(pool.reservedWorkingBytes, 0);
    stream.removeListener(listener);
    visible.release();
    preload.release();
    pool.dispose();
    await Future<void>.delayed(Duration.zero);
  });

  imageTest(
      'all pools share input admission and queued cancellation does not start a provider',
      () async {
    final firstPool = ReaderPreviewImagePool(),
        secondPool = ReaderPreviewImagePool();
    final entered = Completer<void>(), release = Completer<void>();
    var secondCalls = 0;
    final first = firstPool.acquire(
        resourceKey: 'first-pool',
        loadProvider: (_) async {
          entered.complete();
          await release.future;
          return MemoryImage(png);
        });
    final listener = ImageStreamListener((info, _) => info.dispose(),
        onError: (Object _, StackTrace? __) {});
    final firstStream = first.provider.resolve(ImageConfiguration.empty)
      ..addListener(listener);
    await entered.future;
    final second = secondPool.acquire(
        resourceKey: 'second-pool',
        loadProvider: (_) {
          secondCalls++;
          return MemoryImage(png);
        });
    final secondStream = second.provider.resolve(ImageConfiguration.empty)
      ..addListener(listener);
    await Future<void>.delayed(Duration.zero);
    expect(secondCalls, 0);
    expect(ReaderPreviewImagePool.globalReservedWorkingBytes, 128 << 20);
    final checked =
        expectLater(second.firstFrame, throwsA(isA<ReaderImageCancelled>()));
    secondStream.removeListener(listener);
    second.release();
    await checked;
    release.complete();
    await first.firstFrame;
    expect(secondCalls, 0);
    firstStream.removeListener(listener);
    first.release();
    firstPool.dispose();
    secondPool.dispose();
    await cacheFrame();
    expect(ReaderPreviewImagePool.globalReservedWorkingBytes, 0);
  });
}

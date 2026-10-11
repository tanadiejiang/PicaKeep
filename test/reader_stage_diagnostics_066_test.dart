import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/image_loader/base_image_provider.dart';
import 'package:picakeep/foundation/image_loader/jm_page_loader.dart';
import 'package:picakeep/foundation/image_loader/reader_image_retry.dart';
import 'package:picakeep/foundation/image_loader/reader_preview_provider.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';
import 'package:picakeep/foundation/image_pipeline/reader_failure_diagnostics.dart';
import 'package:picakeep/foundation/log.dart';
import 'package:picakeep/network/http_image_body.dart';
import 'package:picakeep/network/online_image/online_image_cache.dart';
import 'package:picakeep/network/online_image/online_image_manager.dart';
import 'package:picakeep/pages/reader/comic_reading_page.dart';

import 'support/http_image_fixture.dart';
import 'support/image_disk_quota_fixture.dart';

/// A deliberately reusable marker error object. The same instance is thrown at
/// distinct real boundaries to prove the recorded stage is positional.
class _Boom implements Exception {
  const _Boom(this.marker);
  final String marker;
  @override
  String toString() => 'Boom($marker)';
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.handle);
  final Future<ResponseBody> Function(RequestOptions) handle;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
          Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      handle(options);

  @override
  void close({bool force = false}) {}
}

/// A bounded Base loader returning controlled bytes/errors. It only proves the
/// provider wrapper wiring, never third-party input-limit transparency.
class _ProbeProvider extends BaseImageProvider<_ProbeProvider> {
  _ProbeProvider(this.callback, this.key);
  final Future<Uint8List> Function() callback;
  @override
  final String key;
  @override
  bool get cacheRawBytes => false;
  @override
  bool get supportsReaderInputLimits => true;
  @override
  Future<_ProbeProvider> obtainKey(ImageConfiguration configuration) async =>
      this;
  @override
  Future<Uint8List> load(StreamController<ImageChunkEvent> events) =>
      callback();
}

class _RawProvider extends _ProbeProvider {
  _RawProvider(super.callback, super.key);
  @override
  bool get cacheRawBytes => true;
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

Future<({Uint8List bytes, String extension})> _throws(
    Object error, Uint8List bytes,
    {required String epsId,
    required String scrambleId,
    required String pictureName,
    String originalExtension = '.png'}) async {
  throw error;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final png = syntheticHttpPng();
  late Directory root;
  late ImageDiskQuota quota;
  final savedQuota = ImageDiskQuota.overrideForTesting;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('reader_stage_066_');
    App.cachePath = root.path;
    quota = installTaskDiskQuota(() => [root.path]);
  });
  tearDownAll(() async {
    await quota.drain();
    ImageDiskQuota.overrideForTesting = savedQuota;
    await root.delete(recursive: true);
  });
  setUp(() => LogManager.recordingEnabled = true);
  tearDown(() => LogManager.recordingEnabled = true);

  Future<HttpImageFixture> serve(
      HttpImageReply Function(Uri, String) response) async {
    final fixture = await HttpImageFixture.start(response);
    addTearDown(fixture.close);
    return fixture;
  }

  Dio realDio() {
    final value = directImageDio();
    addTearDown(() => value.close(force: true));
    return value;
  }

  OnlineImageManager managerFor(
      Future<ResponseBody> Function(RequestOptions) get) {
    final dio = Dio()..httpClientAdapter = _Adapter(get);
    addTearDown(() => dio.close(force: true));
    return OnlineImageManager.forTesting(dio);
  }

  Future<void> flush(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
          () async => Future<void>.delayed(const Duration(milliseconds: 5)));
      // Provider-only resolutions have no mounted render object to schedule a
      // frame. ImageCache retires its actual keepAlive handles post-frame.
      tester.binding.scheduleFrame();
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  test('observation unit contract: bounded, positional, explicitly forwarded',
      () async {
    // Positional stage: the same error type at two operations keeps its stage.
    final first = ReaderImageObservation();
    const fetchError = _Boom('fetch');
    expect(
        ReaderImageObservation.run(first, () {
          observeReaderImageFailure(ReaderImageStage.fetch, fetchError,
              StackTrace.fromString('fetch-stack'));
          return first.stageFor(fetchError);
        }),
        ReaderImageStage.fetch);
    final second = ReaderImageObservation();
    expect(
        ReaderImageObservation.run(second, () {
          observeReaderImageFailure(ReaderImageStage.transform, fetchError,
              StackTrace.fromString('transform-stack'));
          return second.stageFor(fetchError);
        }),
        ReaderImageStage.transform);

    // Inner (real) boundary wins: an outer catch must not overwrite it.
    final inner = ReaderImageObservation();
    const cause = _Boom('cause');
    ReaderImageObservation.run(inner, () {
      observeReaderImageFailure(
          ReaderImageStage.fetch, cause, StackTrace.fromString('fetch-stack'));
      observeReaderImageFailure(
          ReaderImageStage.cache, cause, StackTrace.fromString('cache-stack'));
    });
    expect(inner.stageFor(cause), ReaderImageStage.fetch);
    expect(inner.recentFailures.single.stage, ReaderImageStage.fetch);

    // Shared producers never bind the creating consumer. Each actual consumer
    // forwards the immutable cause at its own future error boundary.
    final parent = ReaderImageObservation();
    const forwarded = _Boom('forwarded');
    late ReaderImageObservation child;
    ReaderImageObservation.run(parent, () {
      child = ReaderImageObservation();
      expect(child.executionId, isNot(parent.executionId));
      ReaderImageObservation.run(child, () {
        observeReaderImageFailure(
            ReaderImageStage.decode, forwarded, StackTrace.fromString('x'));
      });
    });
    expect(parent.stageFor(forwarded), isNull);
    ReaderImageObservation.run(
        parent,
        () => forwardReaderImageStage(
            child, forwarded, child.latestFailure!.stackTrace));
    expect(parent.stageFor(forwarded), ReaderImageStage.decode);

    // Bounds: unbounded distinct failures keep a small fixed history.
    final bounded = ReaderImageObservation();
    for (var i = 0; i < 200; i++) {
      bounded.record(ReaderImageStage.decode, _Boom('$i'), StackTrace.current);
    }
    expect(bounded.recentFailures.length,
        lessThanOrEqualTo(ReaderImageObservation.maximumFailures));

    // A throwing sink never changes the operation result.
    final sinking = ReaderImageObservation();
    sinking.attachSink((_) => throw StateError('sink'));
    expect(
        () => sinking.record(
            ReaderImageStage.cache, const _Boom('s'), StackTrace.current),
        returnsNormally);

    // close() drops history and detaches; late records are ignored.
    final closing = ReaderImageObservation();
    closing.record(
        ReaderImageStage.fetch, const _Boom('c'), StackTrace.current);
    closing.close();
    closing.record(
        ReaderImageStage.fetch, const _Boom('late'), StackTrace.current);
    expect(closing.recentFailures, isEmpty);
  });

  test('actual cache root initialization IOException is cache, not unknown',
      () async {
    final path = '${root.path}${Platform.pathSeparator}online_images';
    final obstruction = File(path);
    expect(await FileSystemEntity.type(path), FileSystemEntityType.notFound);
    await obstruction.writeAsString('test-owned root obstruction');
    final observation = ReaderImageObservation();
    Object? caught;
    try {
      await ReaderImageObservation.run(observation, () async {
        try {
          await OnlineImageCache.instance.putStream(
              'root-failure', Stream<List<int>>.value([1]),
              expectedBytes: 1, maximumBytes: 64);
        } catch (error) {
          caught = error;
        }
      });
      expect(caught, isA<FileSystemException>());
      expect(observation.stageFor(caught!), ReaderImageStage.cache);
    } finally {
      expect(obstruction.path, startsWith(root.path));
      await obstruction.delete();
    }
  });

  test('actual cache body sink IOException is cache', () async {
    const identity = 'stage066-disk-sink';
    final key = OnlineImageCache.instance.keyForUrl(identity);
    final blocked = Directory('${root.path}${Platform.pathSeparator}'
        'online_images${Platform.pathSeparator}$key.png.part');
    await blocked.create(recursive: true);
    final observation = ReaderImageObservation();
    Object? caught;
    try {
      await ReaderImageObservation.run(observation, () async {
        try {
          await OnlineImageCache.instance.putStream(
              identity, Stream<List<int>>.value(png),
              contentType: 'image/png',
              expectedBytes: png.length,
              maximumBytes: 1 << 20);
        } catch (error) {
          caught = error;
        }
      });
      expect(caught, isA<FileSystemException>());
      expect(observation.stageFor(caught!), ReaderImageStage.cache);
    } finally {
      expect(blocked.path, startsWith(root.path));
      await blocked.delete();
    }
  });

  test(
      'real body-contract failure retains fetch origin and retry classification',
      () async {
    // Declared length (4) is smaller than the delivered identity body, so the
    // real body contract rejects it mid-stream while the cache writer sinks it.
    final manager = managerFor((_) async =>
        ResponseBody(Stream<Uint8List>.value(png), 200, headers: const {
          Headers.contentLengthHeader: ['4'],
          Headers.contentTypeHeader: ['image/png'],
        }));
    final observation = ReaderImageObservation();
    Object? caught;
    StackTrace? caughtStack;
    await ReaderImageObservation.run(observation, () async {
      try {
        final result = await manager.getImage(
            'https://fixture.invalid/short.png',
            maximumBytes: png.length);
        await result.stream.expand((chunk) => chunk).toList();
      } catch (error, stack) {
        caught = error;
        caughtStack = stack;
      }
    });
    expect(caught, isA<HttpImageBodyException>());
    expect((caught! as HttpImageBodyException).reason, 'body-length-mismatch');
    expect(caughtStack, isNotNull);
    // Fetch, never cache: the body contract failed while the cache writer sank.
    expect(observation.stageFor(caught!), ReaderImageStage.fetch);
    expect(
        observation.recentFailures
            .where((f) => f.stage == ReaderImageStage.cache),
        isEmpty);
    // The retry classifier receives the exact original object.
    expect(readerImageRetryDelay(caught!, 1), const Duration(seconds: 2));
    expect(readerImageRetryDelay(caught!, 2), const Duration(seconds: 4));
    expect(readerImageRetryDelay(caught!, 3), const Duration(seconds: 8));
    expect(readerImageRetryDelay(caught!, 4), isNull);
    expect(readerImageRetryDelay(caught!, 5), isNull);
  });

  test('A: disconnecting before headers is a fetch failure, not cache',
      () async {
    final fixture = await serve(
        (_, __) => HttpImageReply([], disconnectBeforeHeaders: true));
    final manager = OnlineImageManager.forTesting(realDio());
    final observation = ReaderImageObservation();
    Object? caught;
    await ReaderImageObservation.run(observation, () async {
      try {
        await manager.getImage(fixture.url('/headers.png'));
      } catch (error) {
        caught = error;
      }
    });
    expect(caught, isNotNull);
    expect(observation.stageFor(caught!), ReaderImageStage.fetch);
  });

  test('same error stays positional at fetch, opaque input, and transform',
      () async {
    const boom = _Boom('same-object');

    // fetch: an actual transport body error delivered through the manager.
    final fetchObservation = ReaderImageObservation();
    final manager = managerFor(
        (_) async => ResponseBody(Stream<Uint8List>.error(boom), 200));
    Object? fetchCaught;
    await ReaderImageObservation.run(fetchObservation, () async {
      try {
        final result = await manager.getImage('https://fixture.invalid/a.png');
        await result.stream.expand((chunk) => chunk).toList();
      } catch (error) {
        fetchCaught = error;
      }
    });
    expect(identical(fetchCaught, boom), isTrue);
    expect(fetchObservation.stageFor(boom), ReaderImageStage.fetch);

    // Opaque input: a generic upstream stream failure is NOT a cache I/O
    // failure merely because addStream is consuming it.
    final cacheObservation = ReaderImageObservation();
    Object? cacheCaught;
    await ReaderImageObservation.run(cacheObservation, () async {
      try {
        await OnlineImageCache.instance.putStream(
            'stage066-cache-${DateTime.now().microsecondsSinceEpoch}',
            Stream<List<int>>.error(boom),
            expectedBytes: 8,
            maximumBytes: 64);
      } catch (error) {
        cacheCaught = error;
      }
    });
    expect(identical(cacheCaught, boom), isTrue);
    expect(cacheObservation.stageFor(boom), ReaderImageStage.unknown);

    // transform: a real JM recombine invocation throwing the same object.
    final fixture = await serve((_, __) => HttpImageReply(png));
    final transformObservation = ReaderImageObservation();
    final loader = JmPageLoader.forTesting(
        images: OnlineImageManager.forTesting(realDio()),
        recombine: (bytes,
                {required epsId,
                required scrambleId,
                required pictureName,
                originalExtension = '.png'}) =>
            _throws(boom, bytes,
                epsId: epsId,
                scrambleId: scrambleId,
                pictureName: pictureName,
                originalExtension: originalExtension));
    Object? transformCaught;
    await ReaderImageObservation.run(transformObservation, () async {
      try {
        await loader.load(
            url: fixture.url('/recombine.png'),
            cacheIdentity: 'stage066-transform',
            headers: const {},
            episodeId: 'ep',
            scrambleId: 'scramble',
            pictureName: 'page');
      } catch (error) {
        transformCaught = error;
      }
    });
    expect(identical(transformCaught, boom), isTrue);
    expect(transformObservation.stageFor(boom), ReaderImageStage.transform);
    // The shared transfer also recorded it for a joining consumer.
    expect(
        transformObservation.recentFailures
            .where((f) => f.stage == ReaderImageStage.transform),
        isNotEmpty);
    // Retry ownership sees the original object despite nested boundaries.
    expect(readerImageRetryDelay(boom, 1), isNull);
  });

  test('B: corrupt/missing cache metadata is a miss, never a page failure',
      () async {
    final identity = 'stage066-b',
        urlKey = OnlineImageCache.instance.keyForUrl(identity);
    final file = await OnlineImageCache.instance.putStream(
        identity, Stream<List<int>>.value(png),
        contentType: 'image/png',
        expectedBytes: png.length,
        maximumBytes: 1 << 20);
    expect(file.existsSync(), isTrue);
    final observation = ReaderImageObservation();
    final entry = await ReaderImageObservation.run(
        observation, () => OnlineImageCache.instance.get(identity));
    expect(entry, isNotNull);
    expect(observation.recentFailures, isEmpty,
        reason: 'a warm hit is not a failure');

    // Corrupt the metadata record: the reader falls back to a miss instead of
    // turning a corrupt record into a page failure.
    final meta = File('${root.path}${Platform.pathSeparator}online_images'
        '${Platform.pathSeparator}$urlKey.json');
    final json = jsonDecode(await meta.readAsString()) as Map<String, dynamic>;
    json['length'] = png.length + 7;
    await meta.writeAsString(jsonEncode(json));
    final missObservation = ReaderImageObservation();
    final missed = await ReaderImageObservation.run(
        missObservation, () => OnlineImageCache.instance.get(identity));
    expect(missed, isNull);
    expect(missObservation.recentFailures, isEmpty,
        reason: 'corrupt-record fallback must not be logged as a page failure');
    expect(missObservation.facts.reasonHint, isNull);
    expect(missObservation.factsFor(const _Boom('later-decode')).reasonHint,
        isNull);
    await OnlineImageCache.instance.invalidate(identity);
  });

  test('E: a reused error object still counts four physical attempts',
      () async {
    const reused = SocketException('offline');
    final lines = <String>[];
    final session = ReaderFailureDiagnosticsSession(writer: lines.add);
    final attempt = session
        .page(
            logicalIdentity: 'stage066-retry',
            chapter: 1,
            page: 1,
            readingMode: 'continuous')
        .beginAttempt(generation: 0, qualityMode: 'previewFirst');
    final delays = <Duration>[];
    final retries = <int>[];
    final pool = ReaderPreviewImagePool(waitForRetry: (delay, abort) async {
      delays.add(delay);
    });
    var calls = 0;
    final lease = pool.acquire(
        resourceKey: 'retry-stage066',
        loadProvider: (_) => _ProbeProvider(() async {
              calls++;
              throw reused;
            }, 'retry-stage066'));
    final subscription = lease.retries.listen((event) {
      retries.add(event.retry);
      attempt.failure(
          stage: ReaderImageStage.unknown.token,
          error: event.error,
          stackTrace: event.stack,
          terminal: false);
      attempt.retry(stage: ReaderImageStage.unknown.token, retry: event.retry);
    });
    final stream = lease.provider.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener((info, _) => info.dispose(),
        onError: (Object _, StackTrace? __) {});
    stream.addListener(listener);
    Object? terminal;
    try {
      await lease.firstFrame.then<void>((_) {}, onError: (Object e) {
        terminal = e;
      });
      expect(identical(terminal, reused), isTrue);
      expect(calls, 4, reason: 'three retries plus a terminal fourth attempt');
      expect(delays.map((d) => d.inSeconds), [2, 4, 8]);
      expect(retries, [1, 2, 3]);
      attempt.failure(
          stage: ReaderImageStage.unknown.token,
          error: terminal!,
          stackTrace: StackTrace.current);
      attempt.close();
      final events = lines.map((line) => jsonDecode(line) as Map).toList();
      final counts = events
          .map((event) => event['failureCount'])
          .whereType<int>()
          .toList();
      expect(counts.last, 4);
      expect(events.where((event) => event['event'] == 'failureSummary'),
          hasLength(1));
    } finally {
      await subscription.cancel();
      stream.removeListener(listener);
      lease.release();
      pool.dispose();
      session.dispose();
    }
  });

  test('F: a second JM consumer with an observer gets the first load stage',
      () async {
    final fixture = await serve((_, __) => HttpImageReply(png));
    const boom = _Boom('shared');
    final gate = Completer<void>();
    final entered = Completer<void>();
    var recombines = 0;
    final loader = JmPageLoader.forTesting(
        images: OnlineImageManager.forTesting(realDio()),
        recombine: (bytes,
            {required epsId,
            required scrambleId,
            required pictureName,
            originalExtension = '.png'}) async {
          recombines++;
          if (!entered.isCompleted) entered.complete();
          await gate.future;
          throw boom;
        });
    Future<JmLoadedPage> load() => loader.load(
        url: fixture.url('/shared.png'),
        cacheIdentity: 'stage066-shared',
        headers: const {},
        episodeId: 'ep',
        scrambleId: 'scramble',
        pictureName: 'page');

    // First consumer has no observer at all.
    Object? firstError;
    final first =
        load().then<void>((page) => page.release(), onError: (Object error) {
      firstError = error;
    });
    await entered.future;
    // A second consumer joins inside a real observation operation while the
    // first consumer's recombine is still pending.
    final observation = ReaderImageObservation();
    Object? secondError;
    final second = ReaderImageObservation.run(observation, () async {
      try {
        await load();
      } catch (error) {
        secondError = error;
      }
    });
    // load registers its consumer synchronously before awaiting the transfer.
    gate.complete();
    await Future.wait([first, second]).timeout(const Duration(seconds: 5));
    expect(identical(secondError, boom), isTrue);
    expect(observation.stageFor(boom), ReaderImageStage.transform);
    expect(fixture.requests, hasLength(1),
        reason: 'two consumers must share one fetch');
    expect(recombines, 1, reason: 'two consumers must share one recombine');
    expect(identical(firstError, boom), isTrue);
  });

  test('online body failure reaches a late observer after headers', () async {
    const failure = _Boom('shared-body-secret');
    final body = StreamController<Uint8List>();
    var requests = 0;
    final manager = managerFor((_) async {
      requests++;
      return ResponseBody(body.stream, 200);
    });
    Future<Object?> consume(Stream<List<int>> stream) async {
      try {
        await stream.drain<void>();
        return null;
      } catch (error) {
        return error;
      }
    }

    final first = await manager.getImage('https://fixture.invalid/shared-body');
    final firstFailure = consume(first.stream);
    final observation = ReaderImageObservation();
    final second = await ReaderImageObservation.run(observation,
        () => manager.getImage('https://fixture.invalid/shared-body'));
    final secondFailure =
        ReaderImageObservation.run(observation, () => consume(second.stream));
    body.addError(failure);
    await body.close();
    final failures = await Future.wait([firstFailure, secondFailure]);
    expect(failures.every((error) => identical(error, failure)), isTrue);
    expect(observation.stageFor(failure), ReaderImageStage.fetch);
    expect(requests, 1);
  });

  test('one reused error changes real stage across pool retry executions',
      () async {
    const reused = SocketException('same-instance');
    final fetch = managerFor(
        (_) async => ResponseBody(Stream<Uint8List>.error(reused), 200));
    var rawRequests = 0;
    final raw = managerFor((_) async {
      rawRequests++;
      return ResponseBody(Stream<Uint8List>.value(png), 200, headers: {
        Headers.contentTypeHeader: ['image/png']
      });
    });
    var recombinations = 0;
    final jm = JmPageLoader.forTesting(
        images: raw,
        recombine: (bytes,
            {required epsId,
            required scrambleId,
            required pictureName,
            originalExtension = '.png'}) async {
          recombinations++;
          throw reused;
        });
    final pool = ReaderPreviewImagePool(waitForRetry: (_, __) async {});
    var calls = 0;
    final lease = pool.acquire(
        resourceKey: 'stage-changing-retry',
        loadProvider: (_) => _ProbeProvider(() async {
              if (++calls == 1) {
                final response =
                    await fetch.getImage('https://fixture.invalid/once');
                return Uint8List.fromList(
                    await response.stream.expand((c) => c).toList());
              }
              final page = await jm.load(
                  url: 'https://fixture.invalid/recombined',
                  cacheIdentity: 'stage-changing-raw',
                  headers: const {},
                  episodeId: 'episode',
                  scrambleId: 'scramble',
                  pictureName: 'page');
              try {
                return await page.file.readAsBytes();
              } finally {
                page.release();
              }
            }, 'stage-changing-retry'));
    final events = <ReaderPreviewRetryEvent>[];
    final subscription = lease.retries.listen(events.add);
    final stream = lease.provider.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener((info, _) => info.dispose(),
        onError: (Object _, StackTrace? __) {});
    stream.addListener(listener);
    Object? terminal;
    try {
      await lease.firstFrame.then<void>((_) {}, onError: (Object error) {
        terminal = error;
      });
      expect(identical(terminal, reused), isTrue);
      expect(events.map((e) => e.stage), [
        ReaderImageStage.fetch,
        ReaderImageStage.transform,
        ReaderImageStage.transform
      ]);
      expect(lease.lastFailure!.stage, ReaderImageStage.transform);
      expect(
          {...events.map((e) => e.executionId), lease.lastFailure!.executionId},
          hasLength(4));
      expect(calls, 4);
      expect(recombinations, 3);
      expect(rawRequests, 1,
          reason: 'diagnostics cannot cause extra raw fetches');
      expect(lease.retryHistory, hasLength(3));
      expect(events[1].facts.processedCacheHit, isFalse);
      expect(events[1].facts.onlineCacheHit, isFalse);
      expect(events[1].facts.httpStatusClass, ReaderHttpStatusClass.success);
      expect(events[1].facts.encodingContract, ReaderEncodingContract.identity);
      expect(events[2].facts.processedCacheHit, isFalse);
      expect(events[2].facts.onlineCacheHit, isTrue);
      expect(events[2].facts.httpStatusClass, ReaderHttpStatusClass.unknown);
      expect(events[2].facts.encodingContract, ReaderEncodingContract.unknown);
      expect(lease.lastFailure!.facts.onlineCacheHit, isTrue);
      expect(lease.lastFailure!.facts.processedCacheHit, isFalse);
      // The earlier failure remains an immutable cold execution snapshot.
      expect(events[1].facts.onlineCacheHit, isFalse);
    } finally {
      await subscription.cancel();
      stream.removeListener(listener);
      lease.release();
      pool.dispose();
    }
  });

  test(
      'facts-v3: real HTTP status rejection has a class but no guessed encoding',
      () async {
    final classes = <int, ReaderHttpStatusClass>{
      401: ReaderHttpStatusClass.auth,
      403: ReaderHttpStatusClass.auth,
      429: ReaderHttpStatusClass.rateLimited,
      404: ReaderHttpStatusClass.clientError,
      500: ReaderHttpStatusClass.serverError,
      503: ReaderHttpStatusClass.serverError,
    };
    for (final item in classes.entries) {
      var requests = 0;
      final manager = managerFor((_) async {
        requests++;
        return ResponseBody.fromString('planted-private-body', item.key,
            headers: {
              'authorization': ['planted-private-header']
            });
      });
      final observation = ReaderImageObservation();
      Object? caught;
      await ReaderImageObservation.run(observation, () async {
        try {
          await manager.getImage('https://fixture.invalid/status-${item.key}');
        } catch (error) {
          caught = error;
        }
      });
      expect(caught, isA<DioException>());
      final cause = observation.failureFor(caught!)!;
      expect(cause.stage, ReaderImageStage.fetch);
      expect(cause.facts.httpStatusClass, item.value);
      expect(cause.facts.encodingContract, ReaderEncodingContract.unknown);
      expect(cause.facts.onlineCacheHit, isFalse);
      expect(cause.facts.rawCacheHit, isNull);
      expect(cause.facts.processedCacheHit, isNull);
      expect(requests, 1);
    }
  });

  test(
      'facts-v3: real identity/gzip contracts and cold publication versus warm hit',
      () async {
    for (final compressed in [false, true]) {
      final fixture = await serve((_, __) => compressed
          ? HttpImageReply(gzip.encode(png), encoding: 'gzip')
          : HttpImageReply(png));
      final manager = OnlineImageManager.forTesting(realDio());
      final url = fixture.url('/facts-${compressed ? 'gzip' : 'identity'}.png');
      Future<List<int>> consume() async {
        final result = await manager.getImage(url);
        return result.stream.expand((c) => c).toList();
      }

      final cold = ReaderImageObservation();
      expect(
          await ReaderImageObservation.run(cold, consume), orderedEquals(png));
      expect(cold.facts.httpStatusClass, ReaderHttpStatusClass.success);
      expect(
          cold.facts.encodingContract,
          compressed
              ? ReaderEncodingContract.gzipDecoded
              : ReaderEncodingContract.identity);
      expect(cold.facts.onlineCacheHit, isFalse,
          reason: 'reading the just-published file is still a cold execution');
      final warm = ReaderImageObservation();
      expect(
          await ReaderImageObservation.run(warm, consume), orderedEquals(png));
      expect(warm.facts.onlineCacheHit, isTrue);
      expect(warm.facts.httpStatusClass, ReaderHttpStatusClass.unknown);
      expect(warm.facts.encodingContract, ReaderEncodingContract.unknown);
      expect(warm.facts.reasonHint, isNull);
      expect(fixture.requests, hasLength(1));
      expect(cold.facts.onlineCacheHit, isFalse);
    }
    final unsupported = await serve(
        (_, __) => HttpImageReply(png, encoding: 'planted-private-encoding'));
    final manager = OnlineImageManager.forTesting(realDio());
    final observation = ReaderImageObservation();
    Object? caught;
    await ReaderImageObservation.run(observation, () async {
      try {
        await manager.getImage(unsupported.url('/unsupported.png'));
      } catch (error) {
        caught = error;
      }
    });
    expect(caught, isA<HttpImageBodyException>());
    expect(observation.failureFor(caught!)!.facts.encodingContract,
        ReaderEncodingContract.unsupported);
    expect(observation.facts.httpStatusClass, ReaderHttpStatusClass.success);
    expect(observation.facts.toSnapshot().toString(),
        isNot(contains('planted-private')));
  });

  test(
      'facts-v3: unobserved JM producer shares successful facts then warm resets',
      () async {
    final fixture = await serve((_, __) => HttpImageReply(png));
    final entered = Completer<void>(), release = Completer<void>();
    var recombinations = 0;
    final loader = JmPageLoader.forTesting(
        images: OnlineImageManager.forTesting(realDio()),
        recombine: (bytes,
            {required epsId,
            required scrambleId,
            required pictureName,
            originalExtension = '.png'}) async {
          recombinations++;
          if (!entered.isCompleted) entered.complete();
          await release.future;
          return (bytes: bytes, extension: '.png');
        });
    Future<JmLoadedPage> load() => loader.load(
        url: fixture.url('/shared-facts.png'),
        cacheIdentity: 'facts-v3-jm',
        headers: const {},
        episodeId: 'ep',
        scrambleId: 'scramble',
        pictureName: 'page');
    final first = load();
    await entered.future;
    final cold = ReaderImageObservation();
    final second = ReaderImageObservation.run(cold, load);
    release.complete();
    final pages = await Future.wait([first, second]);
    for (final page in pages) {
      page.release();
    }
    expect(cold.facts.processedCacheHit, isFalse);
    expect(cold.facts.onlineCacheHit, isFalse);
    expect(cold.facts.rawCacheHit, isNull);
    expect(cold.facts.httpStatusClass, ReaderHttpStatusClass.success);
    expect(cold.facts.encodingContract, ReaderEncodingContract.identity);
    final warm = ReaderImageObservation();
    final page = await ReaderImageObservation.run(warm, load);
    page.release();
    expect(warm.facts.processedCacheHit, isTrue);
    expect(warm.facts.onlineCacheHit, isNull);
    expect(warm.facts.rawCacheHit, isNull);
    expect(warm.facts.httpStatusClass, ReaderHttpStatusClass.unknown);
    expect(warm.facts.encodingContract, ReaderEncodingContract.unknown);
    expect(recombinations, 1);
    expect(fixture.requests, hasLength(1));
  });

  test('facts-v3: actual disk guard binds reason without poisoning next error',
      () async {
    final observation = ReaderImageObservation();
    Object? caught;
    await ReaderImageObservation.run(observation, () async {
      try {
        await OnlineImageCache.instance.putStream(
            'facts-v3-disk-bound', Stream<List<int>>.value([1, 2]),
            expectedBytes: 2, maximumBytes: 1);
      } catch (error) {
        caught = error;
      }
    });
    expect(caught, isA<StateError>());
    expect(observation.failureFor(caught!)!.facts.reasonHint,
        ReaderImageReason.diskBudget);
    expect(observation.facts.reasonHint, isNull,
        reason: 'there is no mutable last reason for successful work');
    expect(observation.factsFor(const _Boom('different')).reasonHint, isNull);
    expect(observation.failureFor(caught!)!.stage, ReaderImageStage.cache);
  });

  test('facts-v3 reason serialization unit uses exact value whitelists', () {
    const secret = 'OnlyLettersSecretToken';
    final lines = <String>[];
    final session = ReaderFailureDiagnosticsSession(writer: lines.add);
    final page = session.page(
        logicalIdentity: 'facts-serialization',
        chapter: 1,
        page: 1,
        readingMode: 'single');
    final cases = <(Object, String)>[
      (const ReaderImageLimit('encoded-input'), 'encodedInputLimit'),
      (const ReaderImageLimit('source-pixels'), 'sourcePixelLimit'),
      (const ReaderImageLimit('codec-work'), 'workBudget'),
      (const ReaderImageLimit('input-residency'), 'residentBudget'),
      (const ReaderImageLimit('unbounded-provider'), 'unboundedProvider'),
      (const ReaderImageLimit('jm-recombine-budget'), 'transformBudget'),
      (
        const ReaderImageLimit('jm-recombine-animation'),
        'unsupportedTransform'
      ),
      (const ReaderImageLimit(secret), 'imageLimit'),
      (const HttpImageBodyException('body-length-mismatch'), 'lengthMismatch'),
      (
        const HttpImageBodyException('unsupported-content-encoding'),
        'unsupportedEncoding'
      ),
      (const HttpImageBodyException(secret), 'bodyContract'),
      (const ImageDiskQuotaExceeded(secret, 100, 0), 'diskAdmission'),
    ];
    for (var i = 0; i < cases.length; i++) {
      final attempt =
          page.beginAttempt(generation: i, qualityMode: 'previewFirst');
      attempt.failure(stage: 'unknown', error: cases[i].$1, snapshot: {
        'httpStatusClass': secret,
        'encodingContract': secret,
        'rawCacheHit': secret,
        'onlineCacheHit': secret,
        'processedCacheHit': secret,
      });
      final event = jsonDecode(lines.last) as Map;
      expect(event['reason'], cases[i].$2);
      expect(event['snapshot']['httpStatusClass'], 'unknown');
      expect(event['snapshot']['encodingContract'], 'unknown');
      expect(event['snapshot']['rawCacheHit'], isNull);
      expect(event['snapshot']['onlineCacheHit'], isNull);
      expect(event['snapshot']['processedCacheHit'], isNull);
    }
    expect(lines.join(), isNot(contains(secret)));
    expect(lines.every((line) => line.length <= 3000), isTrue);
    session.dispose();
  });

  testWidgets('raw-hit-v2: real Base raw hit retains cache origin and input',
      (tester) async {
    const key = 'reader066-raw-cache-hit';
    var loads = 0;
    final original = List<int>.of(png);
    _RawProvider source() => _RawProvider(() async {
          loads++;
          return png;
        }, key);
    final results = <({
      Size? size,
      Object? error,
      StackTrace? stack,
      ReaderImageObservedFailure? cause,
      ReaderImageFacts facts,
    })>[];
    Future<void> load(int maximumInputBytes, String resource) async {
      final pool = ReaderPreviewImagePool(maximumInputBytes: maximumInputBytes);
      final lease =
          pool.acquire(resourceKey: resource, loadProvider: (_) => source());
      final stream = lease.provider.resolve(ImageConfiguration.empty);
      final listener = ImageStreamListener((info, _) => info.dispose(),
          onError: (Object _, StackTrace? __) {});
      stream.addListener(listener);
      Size? size;
      Object? error;
      StackTrace? stack;
      try {
        try {
          size = await lease.firstFrame;
        } catch (caught, trace) {
          error = caught;
          stack = trace;
        }
        results.add((
          size: size,
          error: error,
          stack: stack,
          cause: lease.observation.latestFailure,
          facts: lease.facts,
        ));
      } finally {
        stream.removeListener(listener);
        lease.release();
        pool.dispose();
      }
    }

    try {
      await tester.runAsync(() => load(png.length, 'raw-cold'));
      await flush(tester);
      expect(results[0].size, const Size(24, 32));
      expect(results[0].error, isNull);
      expect(loads, 1);
      await tester.runAsync(() => load(png.length - 1, 'raw-refused'));
      await flush(tester);
      expect(results[1].error, same(const ReaderImageLimit('encoded-input')));
      expect(results[1].cause!.error, same(results[1].error));
      expect(results[1].cause!.stage, ReaderImageStage.cache);
      expect(
          results[1].stack.toString(), results[1].cause!.stackTrace.toString());
      expect(loads, 1, reason: 'refusal must use the existing raw entry');
      await tester.runAsync(() => load(png.length, 'raw-recovered'));
      await flush(tester);
      expect(results[2].size, const Size(24, 32));
      expect(results[2].error, isNull);
      expect(results[0].facts.rawCacheHit, isFalse);
      expect(results[1].cause!.facts.rawCacheHit, isTrue);
      expect(results[2].facts.rawCacheHit, isTrue);
      for (final result in results) {
        expect(result.facts.httpStatusClass, ReaderHttpStatusClass.unknown);
        expect(result.facts.encodingContract, ReaderEncodingContract.unknown);
        expect(result.facts.onlineCacheHit, isNull);
        expect(result.facts.processedCacheHit, isNull);
      }
      expect(loads, 1, reason: 'diagnostics never invalidates raw bytes');
      expect(source().key, key);
      expect(png, orderedEquals(original));
      expect(ReaderPreviewImagePool.globalReservedWorkingBytes, 0);
      expect(ReaderPreviewImagePool.globalReservedDecodedBytes, 0);
      expect(tester.takeException(), isNull);
    } finally {
      BaseImageProvider.evictKey(key);
    }
  });

  testWidgets('facts-v3: successful HTTP facts survive real decoder rejection',
      (tester) async {
    await tester.runAsync(() async {
      var requests = 0;
      final manager = managerFor((_) async {
        requests++;
        return ResponseBody(
            Stream<Uint8List>.value(Uint8List.fromList([1, 2, 3, 4])), 200,
            headers: {
              Headers.contentTypeHeader: ['image/png']
            });
      });
      final snapshots = <ReaderImageFacts>[];
      for (var round = 0; round < 2; round++) {
        final pool = ReaderPreviewImagePool();
        final lease = pool.acquire(
            resourceKey: 'facts-decode-$round',
            loadProvider: (_) => _ProbeProvider(() async {
                  final result = await manager
                      .getImage('https://fixture.invalid/facts-bad.png');
                  return Uint8List.fromList(
                      await result.stream.expand((c) => c).toList());
                }, 'facts-decode-$round'));
        final stream = lease.provider.resolve(ImageConfiguration.empty);
        final listener = ImageStreamListener((info, _) => info.dispose(),
            onError: (Object _, StackTrace? __) {});
        stream.addListener(listener);
        Object? failure;
        try {
          await lease.firstFrame.then<void>((_) {}, onError: (Object error) {
            failure = error;
          });
          expect(failure, isNotNull);
          expect(lease.lastFailure!.stage, ReaderImageStage.decode);
          snapshots.add(lease.lastFailure!.facts);
        } finally {
          stream.removeListener(listener);
          lease.release();
          pool.dispose();
        }
      }
      expect(snapshots[0].httpStatusClass, ReaderHttpStatusClass.success);
      expect(snapshots[0].encodingContract, ReaderEncodingContract.identity);
      expect(snapshots[0].onlineCacheHit, isFalse);
      expect(snapshots[1].httpStatusClass, ReaderHttpStatusClass.unknown);
      expect(snapshots[1].encodingContract, ReaderEncodingContract.unknown);
      expect(snapshots[1].onlineCacheHit, isTrue);
      expect(requests, 1);
    });
    await flush(tester);
    expect(ReaderPreviewImagePool.globalReservedWorkingBytes, 0);
    expect(ReaderPreviewImagePool.globalReservedDecodedBytes, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('D: corrupted encoded bytes fail at the real decode boundary',
      (tester) async {
    final pool = ReaderPreviewImagePool();
    await tester.runAsync(() async {
      final lease = pool.acquire(
          resourceKey: 'decode-stage066',
          loadProvider: (_) => _ProbeProvider(
              () async => Uint8List.fromList([1, 2, 3, 4]), 'decode-stage066'));
      final stream = lease.provider.resolve(ImageConfiguration.empty);
      final listener = ImageStreamListener((info, _) => info.dispose(),
          onError: (Object _, StackTrace? __) {});
      stream.addListener(listener);
      Object? failure;
      await lease.firstFrame.then<void>((_) {}, onError: (Object error) {
        failure = error;
      });
      expect(failure, isNotNull);
      expect(lease.stageFor(failure!), ReaderImageStage.decode);
      expect(lease.observation.latestFailure!.stage, ReaderImageStage.decode);
      stream.removeListener(listener);
      lease.release();
    });
    pool.dispose();
  });

  testWidgets('E: opaque third-party provider stays unknown with zero key/load',
      (tester) async {
    final pool = ReaderPreviewImagePool();
    await tester.runAsync(() async {
      var loads = 0, keys = 0;
      final lease = pool.acquire(
          resourceKey: 'opaque-stage066',
          loadProvider: (_) =>
              _OpaqueProvider(png, () => loads++, onKey: () => keys++));
      final stream = lease.provider.resolve(ImageConfiguration.empty);
      final listener = ImageStreamListener((info, _) => info.dispose(),
          onError: (Object _, StackTrace? __) {});
      stream.addListener(listener);
      Object? failure;
      await lease.firstFrame.then<void>((_) {}, onError: (Object error) {
        failure = error;
      });
      expect(failure,
          anyOf(isA<ReaderImageLimit>(), isA<ReaderPreviewPreloadRejected>()));
      expect(loads, 0);
      expect(keys, 0);
      expect(lease.observation.recentFailures, isEmpty,
          reason: 'admission refusal must not invent a fetch/decode stage');
      stream.removeListener(listener);
      lease.release();
    });
    pool.dispose();
  });

  testWidgets('E/F3: real page counts retries once and never leaks secrets',
      (tester) async {
    const secret = 'https://secret.test/page?token=planted-secret';
    final lines = <String>[];
    final session = ReaderFailureDiagnosticsSession(writer: lines.add);
    final pool = ReaderPreviewImagePool(waitForRetry: (_, __) async {});
    final page = session.page(
        logicalIdentity: 'stage066-widget',
        chapter: 1,
        page: 1,
        readingMode: 'continuous');
    var loads = 0;
    await tester.pumpWidget(MaterialApp(
        home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
                width: 300,
                height: 300,
                child: ReaderPreviewPageImage(
                    resourceKey: 'widget-stage066',
                    pool: pool,
                    loadProvider: (_) => _ProbeProvider(() async {
                          loads++;
                          throw const SocketException(secret);
                        }, 'widget-stage066'),
                    continuousWidth: 300,
                    failureDiagnostics: page)))));
    await flush(tester);
    expect(find.text('图片暂时无法打开，请重试'), findsOneWidget);
    expect(loads, 4);
    final failures = lines
        .map((line) => jsonDecode(line) as Map)
        .where((event) => event['event'] == 'failure')
        .toList();
    // One detail per distinct signature plus a truthful counter.
    expect(failures.isNotEmpty, isTrue);
    expect(failures.last['failureCount'], 4,
        reason: 'three retryable plus one terminal failure');
    expect(lines.join(), isNot(contains('secret')));
    expect(lines.join(), isNot(contains('token')));
    // No UI double count: at most one terminal delivery for this generation.
    final terminals = failures.where((event) => event['terminal'] == true);
    expect(terminals, hasLength(1));
    session.dispose();
    await tester.pumpWidget(const SizedBox());
    pool.dispose();
  });

  testWidgets('F3: throwing writer and disabled logging never change the page',
      (tester) async {
    final pool = ReaderPreviewImagePool(waitForRetry: (_, __) async {});
    final throwing = ReaderFailureDiagnosticsSession(
        writer: (_) => throw StateError('sink'));
    final page = throwing.page(
        logicalIdentity: 'stage066-writer',
        chapter: 1,
        page: 2,
        readingMode: 'continuous');
    await tester.pumpWidget(MaterialApp(
        home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
                width: 300,
                height: 300,
                child: ReaderPreviewPageImage(
                    resourceKey: 'writer-stage066',
                    pool: pool,
                    loadProvider: (_) => _ProbeProvider(() async {
                          throw const SocketException('boom');
                        }, 'writer-stage066'),
                    continuousWidth: 300,
                    failureDiagnostics: page)))));
    await flush(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('图片暂时无法打开，请重试'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());

    // Logging disabled: a successful real load still delivers pixels and logs
    // nothing.
    final lines = <String>[];
    LogManager.recordingEnabled = false;
    final disabled = ReaderFailureDiagnosticsSession(writer: lines.add);
    final disabledPage = disabled.page(
        logicalIdentity: 'stage066-disabled',
        chapter: 1,
        page: 3,
        readingMode: 'continuous');
    await tester.pumpWidget(MaterialApp(
        home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
                width: 300,
                height: 300,
                child: ReaderPreviewPageImage(
                    resourceKey: 'disabled-stage066',
                    pool: pool,
                    loadProvider: (_) =>
                        _ProbeProvider(() async => png, 'disabled-stage066'),
                    continuousWidth: 300,
                    failureDiagnostics: disabledPage)))));
    await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 30)));
    await flush(tester);
    final pixels = tester
        .widgetList<RawImage>(find.byType(RawImage))
        .map((widget) => widget.image)
        .whereType<ui.Image>()
        .toList();
    expect(pixels, isNotEmpty);
    expect(
        pixels.any((image) => image.width == 24 && image.height == 32), isTrue);
    expect(lines, isEmpty);
    LogManager.recordingEnabled = true;
    await tester.pumpWidget(const SizedBox());
    throwing.dispose();
    disabled.dispose();
    pool.dispose();
  });
}

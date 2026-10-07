import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:picakeep/foundation/image_pipeline/derived_image_store.dart';
import 'package:picakeep/foundation/image_pipeline/image_server_protocol.dart';
import 'package:picakeep/foundation/image_pipeline/image_work_scheduler.dart';
import 'package:picakeep/foundation/image_pipeline/reader_page_source.dart';
import 'package:picakeep/foundation/image_pipeline/reader_viewport.dart';
import 'package:picakeep/foundation/image_pipeline/server_reader_page_source.dart';
import 'package:picakeep_image_engine/picakeep_image_engine.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';
import 'support/image_disk_quota_fixture.dart';

const _identity = ReaderPageIdentity(
    sourceKey: 'remote-test',
    workId: '1',
    downloadId: '1',
    episode: 0,
    page: 0,
    sourceVersion: 'v1');

ImagePageManifest _manifest(int width, int height) => ImagePageManifest(
        pageIdentity: 'page1',
        sourceVersion: 'v1',
        width: width,
        height: height,
        originalUrl: '/original',
        tilesAvailable: true,
        levels: [
          ImageManifestLevel(
              index: 0,
              width: width,
              height: height,
              density: 1,
              url: '/level',
              tileUrlTemplate: '/tile/{x}/{y}')
        ]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async {
    final base = Platform.isWindows
        ? Directory(r'E:\picakeep-image-pipeline-022-runtime')
        : Directory.systemTemp;
    await base.create(recursive: true);
    root = await base.createTemp('server-reader-boundary-');
    installTaskDiskQuota(() => [root.path]);
  });
  tearDown(() async {
    await PicakeepImageEngine.shutdownIdleWorkers();
    if (await root.exists()) await root.delete(recursive: true);
    ImageDiskQuota.overrideForTesting = null;
  });

  for (final scenario in ['old oversized cache', 'corruption', 'replacement']) {
    test(
        'conditional body $scenario falls back before loading unverified bytes',
        () async {
      final bytes =
          Uint8List.fromList(img.encodePng(img.Image(width: 16, height: 16)));
      final store = DerivedImageStore(p.join(root.path, 'cache'));
      const key = DerivedImageKey(
          namespace: 'remote-reader:http://task',
          resourceId: 'page1',
          sourceVersion: 'v1',
          algorithmVersion: 2,
          usage: DerivedImageUsage.readerTile,
          variant: '0:0:0:png');
      final padded = scenario == 'old oversized cache'
          ? Uint8List.fromList([...bytes, ...List.filled(96 * 1024, 0)])
          : bytes;
      final cached = (await store.put(
          key: key,
          content: Stream.value(padded),
          mimeType: 'image/png',
          width: 16,
          height: 16,
          lossless: true,
          maximumBytes: padded.length,
          canPublish: () => true))!;
      final original =
          await File(p.join(root.path, 'original.png')).writeAsBytes(bytes);
      var bodiesLoaded = 0;
      final source = ServerReaderPageSource(
          original: FileReaderPageSource(identity: _identity, file: original),
          manifest: _manifest(16, 16),
          cacheRoot: store.root,
          serverScope: 'http://task',
          request: (url,
              {etag, maximumBodyBytes, localBody, abortSignal}) async {
            expect(maximumBodyBytes, 16 * 16 * 5 + 64 * 1024);
            expect(etag, cached.etag);
            if (scenario == 'corruption') {
              final damaged = await File(cached.path).readAsBytes();
              damaged[damaged.length - 1] ^= 1;
              await File(cached.path).writeAsBytes(damaged);
            } else if (scenario == 'replacement') {
              final replacement = img.Image(width: 16, height: 16)
                ..setPixelRgba(0, 0, 255, 0, 0, 255);
              final changed = img.encodePng(replacement);
              await store.put(
                  key: key,
                  content: Stream.value(changed),
                  mimeType: 'image/png',
                  width: 16,
                  height: 16,
                  lossless: true,
                  maximumBytes: changed.length,
                  canPublish: () => true);
            }
            expect(await localBody!(), isNull);
            bodiesLoaded++;
            return ImageDerivativeResponse(
                statusCode: 200,
                headers: {
                  'content-type': 'image/png',
                  'x-image-source-version': 'v1',
                  'x-image-width': '16',
                  'x-image-height': '16'
                },
                body: bytes);
          },
          refreshManifest: () async {});
      try {
        final image = await source.rasterBackend.decode(source.rasterLocator,
            const ReaderTileDemand(ui.Rect.fromLTWH(0, 0, 16, 16), 1, 0, 0),
            backingPath: p.join(root.path, 'unused'),
            memoryBudgetBytes: 1 << 20,
            isCancelled: () => false);
        expect((image.width, image.height), (16, 16));
        image.dispose();
        expect(bodiesLoaded, 1);
      } finally {
        await source.dispose();
        store.dispose();
      }
    });
  }

  final nativeEnabled = Platform.isWindows &&
      Platform.environment['PICAKEEP_IMAGE_ENGINE_LIBRARY'] != null;
  for (final cancel in [false, true]) {
    test(
        'tile 404 ${cancel ? 'cancelled queued fallback releases leased original' : 'fallback reserves actual native decode budget'}',
        () async {
      expect(PicakeepImageEngine.isAvailable, isTrue);
      final original = await File(p.join(root.path, 'original.png'))
          .writeAsBytes(img.encodePng(img.Image(width: 700, height: 650)));
      final page = DeferredReaderPageSource(
          identity: _identity, opener: (_) async => original);
      final source = ServerReaderPageSource(
          original: page,
          manifest: _manifest(700, 650),
          cacheRoot: p.join(root.path, 'cache'),
          serverScope: 'http://task',
          request: (url,
                  {etag, maximumBodyBytes, localBody, abortSignal}) async =>
              ImageDerivativeResponse(
                  statusCode: 404, headers: const {}, body: Uint8List(0)),
          refreshManifest: () async {});
      final blockers = <ImageWorkTicket<void>>[];
      final releaseBlockers = Completer<void>();
      if (cancel) {
        for (var i = 0; i < 2; i++) {
          blockers.add(ImageWorkScheduler.shared.submit<void>(
              key: 'fallback-blocker-$i',
              priority: ImageWorkPriority.visible,
              estimatedBytes: 1,
              run: (_) => releaseBlockers.future));
        }
        await Future<void>.delayed(Duration.zero);
      }
      final baselineLease = ReaderPageFileLease.activeLeaseCount;
      final baselineMemory = ImageWorkScheduler.shared.reservedBytes;
      final decoding = source.rasterBackend.decode(source.rasterLocator,
          const ReaderTileDemand(ui.Rect.fromLTWH(0, 0, 512, 512), 1, 0, 0),
          backingPath: p.join(root.path, 'original.rgba'),
          memoryBudgetBytes: 8 << 20,
          isCancelled: () => false);
      Future<void>? cancelled;
      if (cancel) {
        cancelled = expectLater(decoding, throwsA(isA<ImageWorkCancelled>()));
      }
      if (cancel) {
        for (var i = 0;
            i < 1000 && ReaderPageFileLease.activeLeaseCount == baselineLease;
            i++) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        expect(ReaderPageFileLease.activeLeaseCount, baselineLease + 1);
        var disposed = false;
        final disposal = source.dispose().then((_) => disposed = true);
        expect(disposed, isFalse);
        expect(await original.exists(), isTrue);
        await cancelled;
        await disposal;
        expect(await original.exists(), isFalse);
        releaseBlockers.complete();
        await Future.wait(blockers.map((ticket) => ticket.future));
      } else {
        final image = await decoding;
        expect((image.width, image.height), (512, 512));
        image.dispose();
        await source.dispose();
        expect(await original.exists(), isFalse);
      }
      expect(ReaderPageFileLease.activeLeaseCount, baselineLease);
      expect(
          ImageWorkScheduler.shared.reservedBytes, cancel ? 0 : baselineMemory);
      expect(ImageTemporaryPool.shared.reservedBytes, 0);
    }, skip: !nativeEnabled);
  }
  final largeFixture =
      File(r'E:\picakeep-image-pipeline-022-fixtures\4000x6000.png');
  test(
      'leaving a running native 404 fallback retains original until native cleanup',
      () async {
    final original =
        await largeFixture.copy(p.join(root.path, 'large-original.png'));
    final source = ServerReaderPageSource(
        original: DeferredReaderPageSource(
            identity: _identity, opener: (_) async => original),
        manifest: _manifest(4000, 6000),
        cacheRoot: p.join(root.path, 'cache'),
        serverScope: 'http://task',
        request: (url,
                {etag, maximumBodyBytes, localBody, abortSignal}) async =>
            ImageDerivativeResponse(
                statusCode: 404, headers: const {}, body: Uint8List(0)),
        refreshManifest: () async {});
    final beforeLeases = ReaderPageFileLease.activeLeaseCount;
    final decoding = source.rasterBackend.decode(source.rasterLocator,
        const ReaderTileDemand(ui.Rect.fromLTWH(0, 0, 512, 512), 1, 0, 0),
        backingPath: p.join(root.path, 'large-original.rgba'),
        memoryBudgetBytes: 8 << 20,
        isCancelled: () => false);
    final cancelled = expectLater(decoding, throwsA(isA<ImageWorkCancelled>()));
    for (var i = 0;
        i < 1000 && ImageWorkScheduler.shared.activeExecutionCount == 0;
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(ImageWorkScheduler.shared.activeExecutionCount, 1);
    expect(ReaderPageFileLease.activeLeaseCount, beforeLeases + 1);
    var finished = false;
    final disposing = source.dispose().then((_) => finished = true);
    expect(finished, isFalse);
    expect(original.existsSync(), isTrue,
        reason: 'ticket cancellation cannot delete a running native input');
    expect(ImageWorkScheduler.shared.reservedBytes, greaterThan(0));
    await cancelled;
    await disposing;
    expect(await original.exists(), isFalse);
    expect(ReaderPageFileLease.activeLeaseCount, beforeLeases);
    expect(ImageWorkScheduler.shared.reservedBytes, 0);
    expect(ImageTemporaryPool.shared.reservedBytes, 0);
  }, skip: !(nativeEnabled && largeFixture.existsSync()));
}

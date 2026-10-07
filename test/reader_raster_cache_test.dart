import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/image_pipeline/reader_raster_cache.dart';
import 'package:picakeep/foundation/image_pipeline/reader_raster_diagnostics.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';
import 'package:picakeep/foundation/image_pipeline/reader_viewport.dart';

class _FailSecondStatFile implements File {
  _FailSecondStatFile(this.delegate);
  final File delegate;
  int stats = 0;
  @override
  String get path => delegate.path;
  @override
  Future<FileStat> stat() async {
    if (++stats == 2) {
      throw FileSystemException('Injected source verification failure', path);
    }
    return delegate.stat();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late File source;
  final savedDiskQuota = ImageDiskQuota.overrideForTesting;
  const demand = ReaderTileDemand(ui.Rect.fromLTWH(0, 0, 4, 3), 1, 0, 0);
  setUpAll(() async {
    final parent = Platform.isWindows
        ? Directory(r'E:\picakeep-image-pipeline-022-work')
        : Directory.systemTemp;
    await parent.create(recursive: true);
    root = await parent.createTemp('pk022-local-raster-');
    App.dataPath = root.path;
    App.cachePath = p.join(root.path, 'cache');
    source = File(p.join(root.path, 'original.png'));
    ImageDiskQuota.overrideForTesting = ImageDiskQuota(
        roots: () => [App.cachePath],
        idleLimitBytes: () => 512 << 20,
        space: (_) async => const ImageDiskSpace(100 << 30, 'cache-test'));
  });
  setUp(() async {
    final image = img.Image(width: 4, height: 3);
    for (var y = 0; y < 3; y++) {
      for (var x = 0; x < 4; x++) {
        image.setPixelRgb(x, y, x * 40, y * 70, 90);
      }
    }
    await source.writeAsBytes(img.encodePng(image));
  });
  tearDownAll(() async {
    await ReaderRasterCache.drain();
    ImageDiskQuota.overrideForTesting = savedDiskQuota;
    await root.delete(recursive: true);
  });
  Future<ui.Image> decode() async {
    final codec = await ui.instantiateImageCodec(await source.readAsBytes());
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  }

  testWidgets(
      'lossless cache starts after frame and retains exact RGBA; geometry/color keys stay separate',
      (tester) async {
    final image = (await tester.runAsync(decode))!;
    final reference = (await tester
        .runAsync(() => image.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
    final identity = (await tester
        .runAsync(() => ReaderRasterCache.capture(source, demand)))!;
    ReaderRasterDiagnostics.drainSamples();
    await tester.runAsync(() async {
      ReaderRasterCache.save(source, demand, image,
          backingPath: 'unused', identity: identity);
    });
    expect(ReaderRasterCache.pendingBytes, 48);
    expect(
        await tester.runAsync(() =>
            ReaderRasterCache.load(source, demand, backingPath: 'unused')),
        isNull);
    await tester.pumpWidget(RawImage(image: image));
    await tester.runAsync(ReaderRasterCache.drain);
    expect(ReaderRasterCache.pendingBytes, 0);
    final encodeDiagnostics = ReaderRasterDiagnostics.drainSamples();
    final started = encodeDiagnostics.singleWhere(
        (sample) => sample.containsKey('rasterCachePngEncodeStartedUs'));
    final ended = encodeDiagnostics.singleWhere(
        (sample) => sample.containsKey('rasterCachePngEncodeEndedUs'));
    expect(ended['rasterCachePngEncodeEndedUs'],
        greaterThanOrEqualTo(started['rasterCachePngEncodeStartedUs']!));
    expect(ended['rasterCachePngEncodeBytes'], greaterThan(0));
    image.dispose();
    final warm = await tester.runAsync(
        () => ReaderRasterCache.load(source, demand, backingPath: 'unused'));
    expect(warm, isNotNull);
    try {
      final actual = (await tester.runAsync(
          () => warm!.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
      expect(actual.buffer.asUint8List(), reference.buffer.asUint8List());
    } finally {
      warm?.dispose();
    }
    expect(
        await tester.runAsync(() => ReaderRasterCache.load(source,
            const ReaderTileDemand(ui.Rect.fromLTWH(1, 0, 3, 3), 1, 0, 0),
            backingPath: 'unused')),
        isNull);
    expect(
        await tester.runAsync(() => ReaderRasterCache.load(source, demand,
            backingPath: 'unused',
            pixelVersion: 'different-color-normalization')),
        isNull);
  });

  testWidgets(
      'replacement before persistence never stamps old pixels with the new source',
      (tester) async {
    final image = (await tester.runAsync(decode))!;
    final identity = (await tester
        .runAsync(() => ReaderRasterCache.capture(source, demand)))!;
    await tester.runAsync(() async {
      await source.writeAsBytes(img.encodePng(
          img.Image(width: 4, height: 3)..setPixelRgb(0, 0, 255, 0, 0)));
      await source
          .setLastModified(DateTime.now().add(const Duration(seconds: 2)));
      ReaderRasterCache.save(source, demand, image,
          backingPath: 'unused', identity: identity);
    });
    await tester.pumpWidget(RawImage(image: image));
    await tester.runAsync(ReaderRasterCache.drain);
    image.dispose();
    expect(
        await tester.runAsync(() =>
            ReaderRasterCache.load(source, demand, backingPath: 'unused')),
        isNull);
  });

  testWidgets('cache codec image is disposed when final source stat throws',
      (tester) async {
    final image = (await tester.runAsync(decode))!;
    final identity = (await tester
        .runAsync(() => ReaderRasterCache.capture(source, demand)))!;
    await tester.runAsync(() async {
      ReaderRasterCache.save(source, demand, image,
          backingPath: 'unused', identity: identity);
    });
    await tester.pumpWidget(RawImage(image: image));
    await tester.runAsync(ReaderRasterCache.drain);
    await tester.pumpWidget(const SizedBox.shrink());
    image.dispose();
    final cachedImages = <ui.Image>[];
    final savedOnCreate = ui.Image.onCreate;
    ui.Image.onCreate = cachedImages.add;
    final faultySource = _FailSecondStatFile(source);
    try {
      expect(
          await tester.runAsync(() => ReaderRasterCache.load(
              faultySource, demand,
              backingPath: 'unused')),
          isNull);
      expect(faultySource.stats, 2);
      expect(cachedImages, hasLength(1),
          reason: 'a true encoded cache codec must finish before injected IO');
      expect(cachedImages.single.debugDisposed, isTrue);
    } finally {
      ui.Image.onCreate = savedOnCreate;
    }
  });

  testWidgets(
      'corrupted completed PNG is ignored instead of displaying wrong cached pixels',
      (tester) async {
    final image = (await tester.runAsync(decode))!;
    final identity = (await tester
        .runAsync(() => ReaderRasterCache.capture(source, demand)))!;
    await tester.runAsync(() async {
      ReaderRasterCache.save(source, demand, image,
          backingPath: 'unused', identity: identity);
    });
    await tester.pumpWidget(RawImage(image: image));
    await tester.runAsync(ReaderRasterCache.drain);
    image.dispose();
    await tester.runAsync(() async {
      final cached = await Directory(p.join(
              App.dataPath, 'cache', 'image_pipeline_v1', 'local_reader'))
          .list(recursive: true)
          .where((entry) =>
              entry is File &&
              entry.path.endsWith('.png') &&
              p.basename(entry.path).startsWith('${identity.key.token}.'))
          .single;
      await File(cached.path).writeAsBytes([1, 2, 3]);
    });
    expect(
        await tester.runAsync(() =>
            ReaderRasterCache.load(source, demand, backingPath: 'unused')),
        isNull);
  });
}

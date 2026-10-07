import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/cover_thumbnail_cache.dart';
import 'package:picakeep/foundation/image_pipeline/cover_decode_target.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';
import 'package:picakeep/foundation/image_pipeline/image_work_scheduler.dart';
import 'package:picakeep/foundation/image_pipeline/ordinary_jpeg_cover_policy.dart';
import 'package:picakeep_image_engine/picakeep_image_engine.dart';

class _AfterStage extends CoverThumbnailTrace {
  _AfterStage(this.after);
  final Future<void> Function(String stage) after;

  @override
  Future<T> measure<T>(String stage, Future<T> Function() action) async {
    final value = await super.measure(stage, action);
    await after(stage);
    return value;
  }
}

// Every MCU carries a zero DC difference and the AC end-of-block code. This is
// a complete grayscale JPEG, not a header patched onto too little pixel data.
// Large original geometry costs only a small entropy stream in the fixture.
Uint8List _baselineJpeg(int width, int height,
    {int components = 1,
    int sof = 0xc0,
    List<int> prefix = const [],
    bool scan = true}) {
  List<int> segment(int marker, List<int> payload) => [
        0xff,
        marker,
        (payload.length + 2) >> 8,
        (payload.length + 2) & 255,
        ...payload
      ];
  final huffman = [1, ...List<int>.filled(15, 0), 0];
  final blocks = ((width + 7) ~/ 8) * ((height + 7) ~/ 8) * components;
  final bits = blocks * 2;
  final entropy = Uint8List((bits + 7) ~/ 8);
  if (bits % 8 != 0) entropy.last = (1 << (8 - bits % 8)) - 1;
  return Uint8List.fromList([
    0xff,
    0xd8,
    ...prefix,
    ...segment(0xdb, [0, ...List<int>.filled(64, 1)]),
    ...segment(sof, [
      8,
      height >> 8,
      height & 255,
      width >> 8,
      width & 255,
      components,
      for (var component = 1; component <= components; component++) ...[
        component,
        0x11,
        0
      ]
    ]),
    ...segment(0xc4, [0, ...huffman, 0x10, ...huffman]),
    if (scan) ...[
      ...segment(0xda, [
        components,
        for (var component = 1; component <= components; component++) ...[
          component,
          0
        ],
        0,
        63,
        0
      ]),
      ...entropy,
      0xff,
      0xd9
    ]
  ]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory workspace;
  final savedQuota = ImageDiskQuota.overrideForTesting;
  var serial = 0;

  ImageMetadata metadata(
          {int width = 4096,
          int height = 4352,
          int orientation = 1,
          bool profile = false,
          int bitDepth = 8,
          bool animated = false,
          String format = 'jpeg'}) =>
      ImageMetadata(
          width: width,
          height: height,
          encodedWidth: width,
          encodedHeight: height,
          format: format,
          orientation: orientation,
          animated: animated,
          bitDepth: bitDepth,
          hasColorProfile: profile,
          estimatedWorkingBytes: 32 << 20);

  setUpAll(() async {
    final parent = Platform.isWindows
        ? Directory(r'D:\picakeep-image-pipeline-022-work')
        : Directory.systemTemp;
    await parent.create(recursive: true);
    workspace = await parent.createTemp('ordinary-jpeg-cover-');
    App.dataPath = p.join(workspace.path, 'app');
    App.cachePath = p.join(workspace.path, 'cache');
    ImageDiskQuota.overrideForTesting = ImageDiskQuota(
        roots: () =>
            [App.cachePath, p.join(App.dataPath, 'local_library_cache')],
        idleLimitBytes: () => 512 << 20,
        space: (_) async => const ImageDiskSpace(100 << 30, 'cover-test'));
  });

  setUp(() {
    CoverThumbnailCache.nativeAvailableForTesting = true;
    CoverThumbnailCache.nativeProbeForTesting = (_) async => metadata();
    CoverThumbnailCache.maintenanceForTesting = (_) async {};
    OrdinaryJpegCoverPlan.availableMemoryForTesting = 4 << 30;
  });

  tearDown(() async {
    CoverThumbnailCache.beforeProviderPersistenceForTesting = null;
    await CoverThumbnailCache.waitForProviderPersistenceForTesting();
    await CoverThumbnailCache.waitForMaintenanceForTesting();
    CoverThumbnailCache.nativeProbeForTesting = null;
    CoverThumbnailCache.nativeAvailableForTesting = null;
    CoverThumbnailCache.maintenanceForTesting = null;
    OrdinaryJpegCoverPlan.availableMemoryForTesting = null;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  tearDownAll(() async {
    ImageDiskQuota.overrideForTesting = savedQuota;
    await workspace.delete(recursive: true);
  });

  Future<File> source({int width = 4096, int height = 4352}) =>
      File(p.join(workspace.path, 'gray-${serial++}.jpg'))
          .writeAsBytes(_baselineJpeg(width, height));

  Future<OrdinaryJpegCoverPlan?> inspect(File file, ImageMetadata info,
          {int outputWidth = 768,
          int outputHeight = 816,
          bool Function()? canContinue}) async =>
      OrdinaryJpegCoverPlan.inspect(file,
          snapshot: await file.stat(),
          metadata: info,
          outputWidth: outputWidth,
          outputHeight: outputHeight,
          canContinue: canContinue ?? () => true);

  Future<void> pumpUntil(WidgetTester tester, bool Function() done,
      {required String reason}) async {
    for (var attempt = 0; !done() && attempt < 400; attempt++) {
      await tester.pump(const Duration(milliseconds: 10));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    expect(done(), isTrue, reason: reason);
  }

  Future<void> drain(WidgetTester tester) async {
    var done = false;
    Object? error;
    await tester.runAsync(() async {
      unawaited(() async {
        await CoverThumbnailCache.waitForProviderPersistenceForTesting();
        await CoverThumbnailCache.waitForMaintenanceForTesting();
      }()
          .then((_) => done = true, onError: (Object failure, StackTrace _) {
        error = failure;
        done = true;
      }));
    });
    await pumpUntil(tester, () => done,
        reason: 'bounded cover jobs and fake event Futures must drain');
    if (error != null) throw error!;
  }

  test('baseline header accepts ordinary gray and RGB complete first scans',
      () {
    for (final components in [1, 3]) {
      expect(
          OrdinaryJpegCoverPlan.hasOrdinaryBaselineHeader(
              _baselineJpeg(4096, 4352, components: components),
              expectedWidth: 4096,
              expectedHeight: 4352),
          isTrue);
    }
  });

  test('special, malformed and incomplete JPEG headers keep the native route',
      () {
    final ordinary = _baselineJpeg(4096, 4352);
    final icc = [0xff, 0xe2, 0, 16, ...'ICC_PROFILE'.codeUnits, 0, 1, 1];
    final adobeYcck = [
      0xff,
      0xee,
      0,
      14,
      ...'Adobe'.codeUnits,
      0,
      100,
      0,
      0,
      0,
      0,
      2
    ];
    for (final bytes in [
      _baselineJpeg(4096, 4352, sof: 0xc2),
      _baselineJpeg(4096, 4352, sof: 0xc1),
      _baselineJpeg(4096, 4352, components: 4),
      _baselineJpeg(4096, 4352, prefix: icc),
      _baselineJpeg(4096, 4352, prefix: adobeYcck),
      _baselineJpeg(4096, 4352, scan: false),
      Uint8List.fromList([0xff, 0xd8, 0xff, 0xdb, 0, 1]),
      Uint8List.sublistView(ordinary, 0, 20),
      Uint8List.fromList([0x89, 0x50, 0x4e, 0x47]),
      _baselineJpeg(4095, 4352),
    ]) {
      expect(
          OrdinaryJpegCoverPlan.hasOrdinaryBaselineHeader(bytes,
              expectedWidth: 4096, expectedHeight: 4352),
          isFalse);
    }
  });

  test('eligibility preserves source, output and available-memory limits',
      () async {
    final file = await source();
    final plan = (await inspect(file, metadata()))!;
    expect(
        plan.estimatedWorkingBytes, greaterThan(4096 * 4352 * 8 + (64 << 20)));
    expect(plan.fitsAvailableMemory(4 << 30), isTrue);
    expect(plan.fitsAvailableMemory(512 << 20), isFalse);
    expect(plan.fitsAvailableMemory(0), isFalse);
    for (final info in [
      metadata(profile: true),
      metadata(orientation: 6),
      metadata(bitDepth: 12),
      metadata(animated: true),
      metadata(format: 'png'),
      metadata(width: 2000, height: 3000),
      metadata(width: 8000, height: 12000),
      metadata(width: 17000, height: 4352),
    ]) {
      expect(await inspect(file, info), isNull);
    }
    expect(await inspect(file, metadata(), outputWidth: 4097), isNull);
    expect(
        await inspect(file, metadata(), outputWidth: 4096, outputHeight: 4096),
        isNull);
    expect(await inspect(file, metadata(), canContinue: () => false), isNull);
    final handle = await file.open(mode: FileMode.append);
    try {
      await handle.truncate(OrdinaryJpegCoverPlan.maximumEncodedBytes + 1);
    } finally {
      await handle.close();
    }
    expect(await inspect(file, metadata()), isNull);
  });

  testWidgets('large ordinary JPEG decodes at cover target without raw backing',
      (tester) async {
    final file = (await tester.runAsync(source))!;
    final snapshot = (await tester.runAsync(file.stat))!;
    final original = (await tester.runAsync(file.readAsBytes))!;
    final trace = CoverThumbnailTrace();
    final provider = await tester.runAsync(() =>
        CoverThumbnailCache.prepareProvider(file.path, 768,
            canContinue: () => true, trace: trace));
    expect(provider, isNotNull,
        reason: 'details=${trace.details}; stages=${trace.stages}');
    try {
      expect(trace.details['ordinaryJpegScaledFit'], isTrue);
      expect(trace.details['backend'], 'flutter');
      expect(
          trace.stages.where((s) => s['stage'] == 'nativeEstimate'), isEmpty);
      expect(trace.stages.where((s) => s['stage'] == 'nativeRaster'), isEmpty);
      expect(trace.stages.where((s) => s['stage'] == 'flutterFirstFrame'),
          hasLength(1));
      await tester.pumpWidget(MaterialApp(
          home: Image(
              image: CoverDecodeTarget(provider!,
                  frameWidth: 384, frameHeight: 408, fit: BoxFit.contain))));
      await pumpUntil(tester, () {
        final found = find.byType(RawImage);
        return found.evaluate().isNotEmpty &&
            tester.widget<RawImage>(found).image != null;
      },
          reason: 'bounded cover must paint; '
              'details=${trace.details}; stages=${trace.stages}');
      expect(tester.takeException(), isNull,
          reason: 'details=${trace.details}; stages=${trace.stages}');
      final shown = tester.widget<RawImage>(find.byType(RawImage)).image!;
      expect((shown.width, shown.height), (768, 816));
      final pixels = (await tester.runAsync(
          () => shown.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
      expect(pixels.buffer.asUint8List().take(4), [128, 128, 128, 255]);
      await tester.pumpWidget(const SizedBox.shrink());
      await drain(tester);
      expect(await tester.runAsync(file.readAsBytes), original);
      final after = (await tester.runAsync(file.stat))!;
      expect(after.size, snapshot.size);
      expect(after.modified, snapshot.modified);
      expect(
          await tester.runAsync(() => Directory(
                  p.join(App.cachePath, 'image_pipeline', 'cover_backing'))
              .exists()),
          isFalse);
      expect(ImageWorkScheduler.shared.activeCount, 0);
      expect(ImageWorkScheduler.shared.reservedBytes, 0);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await drain(tester);
    }
  });

  for (final stage in [
    'ordinaryJpegEligibility',
    'flutterDescriptor',
    'flutterCodec',
    'flutterFirstFrame'
  ]) {
    testWidgets('large JPEG cancellation after $stage releases its work',
        (tester) async {
      final file = (await tester.runAsync(source))!;
      var active = true;
      final trace = _AfterStage((current) async {
        if (current == stage) active = false;
      });
      final provider = await tester.runAsync(() =>
          CoverThumbnailCache.prepareProvider(file.path, 768,
              canContinue: () => active, trace: trace));
      expect(provider, isNull);
      await drain(tester);
      expect(ImageWorkScheduler.shared.activeCount, 0);
      expect(ImageWorkScheduler.shared.reservedBytes, 0);
      expect((await tester.runAsync(file.stat))!.size, greaterThan(0));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'source replaced after JPEG eligibility cannot publish old pixels',
      (tester) async {
    final file = (await tester.runAsync(source))!;
    final trace = _AfterStage((stage) async {
      if (stage == 'ordinaryJpegEligibility') {
        await file.writeAsString('changed source');
      }
    });
    final provider = await tester.runAsync(() =>
        CoverThumbnailCache.prepareProvider(file.path, 768,
            canContinue: () => true, trace: trace));
    expect(provider, isNull);
    expect(trace.stages.where((s) => s['stage'] == 'flutterBuffer'), isEmpty);
    await drain(tester);
    expect(ImageWorkScheduler.shared.reservedBytes, 0);
  });

  testWidgets('memory headroom is rechecked after JPEG work queues',
      (tester) async {
    final file = (await tester.runAsync(source))!;
    final trace = CoverThumbnailTrace();
    final block = (await tester.runAsync(() async {
      final release = Completer<void>();
      final started = Completer<void>();
      final ticket = ImageWorkScheduler.shared.submit<void>(
          key: 'ordinary-jpeg-test-blocker',
          priority: ImageWorkPriority.cover,
          estimatedBytes: 0,
          run: (_) async {
            started.complete();
            await release.future;
          });
      await started.future;
      return (release: release, ticket: ticket);
    }))!;
    try {
      Future<ImageProvider<Object>?>? preparation;
      await tester.runAsync(() async {
        preparation = CoverThumbnailCache.prepareProvider(file.path, 768,
            canContinue: () => true, trace: trace);
      });
      await pumpUntil(tester, () => ImageWorkScheduler.shared.pendingCount > 1,
          reason: 'the cover must wait behind the bounded execution slot');
      OrdinaryJpegCoverPlan.availableMemoryForTesting = 512 << 20;
      block.release.complete();
      final provider = await tester.runAsync(() => preparation!);
      expect(provider, isNull);
      expect(trace.details['ordinaryJpegScaledFit'], isTrue);
      expect(trace.stages.where((s) => s['stage'] == 'flutterBuffer'), isEmpty);
      await tester.runAsync(() => block.ticket.future);
      await drain(tester);
      expect(ImageWorkScheduler.shared.reservedBytes, 0);
    } finally {
      if (!block.release.isCompleted) block.release.complete();
      await tester.runAsync(() => block.ticket.future);
    }
  });
}

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/image_pipeline/image_work_scheduler.dart';
import 'package:picakeep/foundation/image_pipeline/reader_page_source.dart';
import 'package:picakeep/foundation/image_pipeline/reader_raster_backend.dart';
import 'package:picakeep/foundation/image_pipeline/reader_viewport.dart';
import 'package:picakeep/foundation/reader_image_quality.dart';
import 'package:picakeep/pages/reader/reader_whole_image.dart';

class _RasterSpy extends ReaderRasterBackend {
  _RasterSpy(this.size, {this.estimate, this.firstDecodeGate});
  final Size size;
  final int Function(ReaderTileDemand)? estimate;
  final Completer<void>? firstDecodeGate;
  final estimates = <ReaderTileDemand>[];
  final demands = <ReaderTileDemand>[];
  final budgets = <int>[];
  final images = <ui.Image>[];
  final cancellationChecks = <bool Function()>[];

  ReaderRasterMetadata get metadata => ReaderRasterMetadata(
      size: size, animated: false, format: 'fixture', workingBytes: 4 << 20);
  @override
  bool get requiresFileBacking => false;
  @override
  Future<ReaderRasterMetadata> probe(File file) async => metadata;
  @override
  Future<int> estimateWorkingBytes(File file, ReaderTileDemand demand,
      {required String backingPath}) async {
    estimates.add(demand);
    return estimate?.call(demand) ?? 4 << 20;
  }

  @override
  Future<ui.Image> decode(File file, ReaderTileDemand demand,
      {required String backingPath,
      required int memoryBudgetBytes,
      required bool Function() isCancelled,
      Future<void>? cancelled}) async {
    final index = demands.length;
    demands.add(demand);
    budgets.add(memoryBudgetBytes);
    cancellationChecks.add(isCancelled);
    // Deliberately non-preemptible: a real native call may finish after cancel.
    if (index == 0) await firstDecodeGate?.future;
    final recorder = ui.PictureRecorder();
    Canvas(recorder)
        .drawColor(index == 0 ? Colors.blue : Colors.green, BlendMode.src);
    final picture = recorder.endRecording();
    try {
      final result =
          picture.toImageSync(demand.outputWidth, demand.outputHeight);
      images.add(result);
      return result;
    } finally {
      picture.dispose();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late File file;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('reader_whole_render_057_');
    App.cachePath = '${root.path}/cache';
    await Directory(App.cachePath).create();
    file = File('${root.path}/original-fixture');
    await file.writeAsBytes([1, 2, 3]);
  });
  tearDownAll(() async {
    expect(ReaderPageFileLease.activeLeaseCount, 0);
    expect(root.path.split(Platform.pathSeparator).last,
        startsWith('reader_whole_render_057_'));
    await root.delete(recursive: true);
  });

  test('small whole plans keep exact original pixels in both policies', () {
    for (final policy in ReaderLargeImagePolicy.values) {
      final plan = ReaderWholeImagePlan.create(
          sourceSize: const Size(320, 480), policy: policy);
      expect(plan.demand.sourceRect, const Rect.fromLTWH(0, 0, 320, 480));
      expect(plan.demand.rasterRect, plan.demand.sourceRect);
      expect(plan.demand.column, -1);
      expect(plan.demand.row, -1);
      expect(plan.demand.density, 1);
      expect(plan.downsampled, isFalse);
      expect(plan.rasterBytes, 320 * 480 * 4);
    }
  });

  test(
      'safe whole respects both texture and raster limits without partial rects',
      () {
    for (final size in [const Size(20000, 4000), const Size(1, 100000)]) {
      final plan = ReaderWholeImagePlan.create(
          sourceSize: size,
          policy: ReaderLargeImagePolicy.safeWhole,
          textureEdge: 256,
          rasterBudgetBytes: 32768);
      expect(plan.demand.sourceRect, Offset.zero & size);
      expect(plan.demand.rasterRect, Offset.zero & size);
      expect(plan.demand.outputWidth, inInclusiveRange(1, 256));
      expect(plan.demand.outputHeight, inInclusiveRange(1, 256));
      expect(plan.rasterBytes, lessThanOrEqualTo(32768));
      expect(plan.downsampled, isTrue);
      expect(
          plan.demand.outputWidth, (size.width * plan.demand.density).ceil());
      expect(
          plan.demand.outputHeight, (size.height * plan.demand.density).ceil());
    }
  });

  test(
      'strict never substitutes reduced targets for texture or raster overflow',
      () {
    for (final limits in [
      (edge: 64, budget: 1 << 20),
      (edge: 4096, budget: 1024)
    ]) {
      expect(
          () => ReaderWholeImagePlan.create(
              sourceSize: const Size(128, 128),
              policy: ReaderLargeImagePolicy.strictOriginal,
              textureEdge: limits.edge,
              rasterBudgetBytes: limits.budget),
          throwsA(isA<ReaderWholeImageLimit>()
              .having((e) => e.kind, 'kind', 'original-limit')));
    }
  });

  test('invalid dimensions and invalid density are rejected before decoding',
      () {
    for (final size in [
      Size.zero,
      const Size(-1, 100),
      const Size(1.5, 100),
      const Size(double.infinity, 100),
      const Size(double.nan, 100)
    ]) {
      expect(
          () => ReaderWholeImagePlan.create(
              sourceSize: size, policy: ReaderLargeImagePolicy.safeWhole),
          throwsA(isA<ReaderWholeImageLimit>()));
    }
    final plan = ReaderWholeImagePlan.create(
        sourceSize: const Size(100, 100),
        policy: ReaderLargeImagePolicy.safeWhole);
    for (final density in [0.0, -1.0, 1.1, double.nan, double.infinity]) {
      expect(() => plan.atDensity(density), throwsArgumentError);
    }
    expect(plan.atDensity(0.25).demand.sourceRect, plan.demand.sourceRect);
  });

  test('resident output reservation enforces overlap and releases idempotently',
      () {
    final residency = ReaderWholeImageResidency(maximumBytes: 100);
    final first = residency.reserve(60);
    expect(
        () => residency.reserve(41), throwsA(isA<ImageWorkBudgetExceeded>()));
    final second = residency.reserve(40);
    expect(residency.bytes, 100);
    first();
    first();
    expect(residency.bytes, 40);
    second();
    expect(residency.bytes, 0);
  });

  Future<void> flush(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump();
    }
  }

  Future<void> mount(WidgetTester tester, _RasterSpy spy,
      ImageWorkScheduler scheduler, ReaderWholeImageResidency residency,
      {ReaderLargeImagePolicy policy = ReaderLargeImagePolicy.safeWhole,
      int edge = 4096,
      VoidCallback? onSafe,
      Size viewport = const Size(400, 600)}) async {
    await tester.pumpWidget(MaterialApp(
        home: Center(
            child: SizedBox(
      width: viewport.width,
      height: viewport.height,
      child: ReaderWholeImage(
          key: const ValueKey('same-whole-page'),
          file: file,
          resourceKey: 'same-source',
          metadata: spy.metadata,
          backend: spy,
          policy: policy,
          scheduler: scheduler,
          residency: residency,
          textureEdge: edge,
          onUseSafeWhole: onSafe),
    ))));
    await flush(tester);
  }

  Future<void> unmount(WidgetTester tester, ImageWorkScheduler scheduler,
      ReaderWholeImageResidency residency) async {
    await tester.pumpWidget(const SizedBox());
    await flush(tester);
    expect(scheduler.activeCount, 0);
    expect(scheduler.pendingCount, 0);
    expect(scheduler.reservedBytes, 0);
    expect(residency.bytes, 0);
    expect(ReaderPageFileLease.activeLeaseCount, 0);
  }

  testWidgets('integer-rounded thin raster keeps the original painted aspect ratio',
      (tester) async {
    final spy = _RasterSpy(const Size(3, 1000));
    final scheduler = ImageWorkScheduler(memoryBudgetBytes: 8 << 20);
    final residency = ReaderWholeImageResidency();
    await mount(tester, spy, scheduler, residency, edge: 32);
    final demand = spy.demands.single;
    expect(demand.outputWidth, 1);
    expect(demand.outputHeight, 32);
    expect(demand.sourceRect, const Rect.fromLTWH(0, 0, 3, 1000));
    final raw = find.byType(RawImage);
    expect(tester.widget<RawImage>(raw).fit, BoxFit.fill);
    final box = tester.renderObject<RenderBox>(raw);
    final top = box.localToGlobal(Offset.zero);
    final bottom = box.localToGlobal(Offset(box.size.width, box.size.height));
    final painted = bottom - top;
    expect(painted.dx / painted.dy, closeTo(3 / 1000, 0.000000001));
    expect(painted.dy, closeTo(600, 0.00001));
    await unmount(tester, scheduler, residency);
  });

  for (final policy in ReaderLargeImagePolicy.values) {
    testWidgets(
        '$policy issues one full original request and viewport changes do not retile',
        (tester) async {
      final spy = _RasterSpy(const Size(64, 96));
      final scheduler = ImageWorkScheduler(memoryBudgetBytes: 8 << 20);
      final residency = ReaderWholeImageResidency();
      await mount(tester, spy, scheduler, residency, policy: policy);
      expect(find.byType(RawImage), findsOneWidget);
      expect(spy.demands, hasLength(1));
      expect(spy.demands.single.sourceRect, const Rect.fromLTWH(0, 0, 64, 96));
      expect(spy.demands.single.density, 1);
      expect(spy.demands.single.column, -1);
      expect(spy.demands.single.row, -1);
      expect(residency.bytes, 64 * 96 * 4);
      await mount(tester, spy, scheduler, residency,
          policy: policy, viewport: const Size(250, 300));
      expect(spy.demands, hasLength(1));
      expect(spy.images.single.debugDisposed, isFalse);
      await unmount(tester, scheduler, residency);
      expect(spy.images.single.debugDisposed, isTrue);
    });
  }

  testWidgets(
      'safe codec admission reduces full target, not original source bounds',
      (tester) async {
    final spy = _RasterSpy(const Size(256, 128),
        estimate: (d) => (2 << 20) + d.outputWidth * d.outputHeight * 1024);
    final scheduler = ImageWorkScheduler(memoryBudgetBytes: 4 << 20);
    final residency = ReaderWholeImageResidency();
    await mount(tester, spy, scheduler, residency, edge: 128);
    expect(spy.demands, hasLength(1));
    expect(spy.estimates.length, greaterThan(1));
    expect(
        spy.estimates
            .every((d) => d.sourceRect == const Rect.fromLTWH(0, 0, 256, 128)),
        isTrue);
    final request = spy.demands.single;
    expect(request.sourceRect, const Rect.fromLTWH(0, 0, 256, 128));
    expect(request.outputWidth, lessThanOrEqualTo(128));
    expect(request.outputHeight, lessThanOrEqualTo(128));
    expect(spy.budgets.single, lessThanOrEqualTo(4 << 20));
    expect(find.byTooltip('已按安全上限整图显示，原文件未修改'), findsOneWidget);
    await unmount(tester, scheduler, residency);
  });

  for (final policy in ReaderLargeImagePolicy.values) {
    testWidgets(
        '$policy rejects source-sized working set without any decode fallback',
        (tester) async {
      final spy = _RasterSpy(const Size(128, 64), estimate: (_) => 64 << 20);
      final scheduler = ImageWorkScheduler(memoryBudgetBytes: 8 << 20);
      final residency = ReaderWholeImageResidency();
      var switches = 0;
      await mount(tester, spy, scheduler, residency,
          policy: policy, onSafe: () => switches++);
      expect(spy.demands, isEmpty);
      expect(find.byType(RawImage), findsNothing);
      expect(find.textContaining('安全内存预算'), findsOneWidget);
      if (policy == ReaderLargeImagePolicy.strictOriginal) {
        expect(spy.estimates, hasLength(1));
        await tester.tap(find.text('改为安全整图显示'));
        expect(switches, 1);
        expect(spy.demands, isEmpty,
            reason: 'only the explicit owner callback may change policy');
      }
      await unmount(tester, scheduler, residency);
    });
  }

  testWidgets(
      'cancelling a non-preemptible decoder keeps actual file and residency leases',
      (tester) async {
    final gate = Completer<void>();
    final spy = _RasterSpy(const Size(64, 32), firstDecodeGate: gate);
    final scheduler = ImageWorkScheduler(memoryBudgetBytes: 8 << 20);
    final residency = ReaderWholeImageResidency();
    await mount(tester, spy, scheduler, residency);
    expect(spy.demands, hasLength(1));
    expect(scheduler.activeCount, 1);
    expect(residency.bytes, 64 * 32 * 4);
    await tester.pumpWidget(const SizedBox());
    await flush(tester);
    expect(spy.cancellationChecks.single(), isTrue);
    expect(scheduler.activeCount, 1);
    expect(scheduler.reservedBytes, 4 << 20);
    expect(residency.bytes, 64 * 32 * 4);
    expect(ReaderPageFileLease.activeLeaseCount, 1,
        reason:
            'admission lease may leave, but active decoder lease must remain');
    var drained = false;
    final drain =
        ReaderPageFileLease.waitForDrain(file).then((_) => drained = true);
    await flush(tester);
    expect(drained, isFalse);
    gate.complete();
    await flush(tester);
    await drain;
    expect(spy.images.single.debugDisposed, isTrue);
    await unmount(tester, scheduler, residency);
  });

  testWidgets('policy generation change never presents the stale raster',
      (tester) async {
    final gate = Completer<void>();
    final spy = _RasterSpy(const Size(64, 32), firstDecodeGate: gate);
    final scheduler =
        ImageWorkScheduler(maxConcurrent: 2, memoryBudgetBytes: 16 << 20);
    final residency = ReaderWholeImageResidency();
    await mount(tester, spy, scheduler, residency);
    await mount(tester, spy, scheduler, residency,
        policy: ReaderLargeImagePolicy.strictOriginal);
    expect(spy.demands, hasLength(2));
    expect(spy.cancellationChecks.first(), isTrue);
    final current = spy.images.single;
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, same(current));
    gate.complete();
    await flush(tester);
    expect(spy.images.last.debugDisposed, isTrue);
    expect(current.debugDisposed, isFalse);
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, same(current));
    expect(residency.bytes, 64 * 32 * 4);
    await unmount(tester, scheduler, residency);
    expect(current.debugDisposed, isTrue);
  });
}

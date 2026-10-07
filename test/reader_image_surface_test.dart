import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/image_pipeline/image_work_scheduler.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';
import 'package:picakeep/foundation/image_pipeline/reader_page_source.dart';
import 'package:picakeep/foundation/image_pipeline/reader_raster_backend.dart';
import 'package:picakeep/foundation/image_pipeline/reader_viewport.dart';
import 'package:picakeep/foundation/reader_image_quality.dart';
import 'package:picakeep/pages/reader/reader_image_surface.dart';

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.root);
  final Directory root;
  @override
  Future<String?> getApplicationCachePath() async => root.path;
  @override
  Future<String?> getApplicationSupportPath() async => root.path;
}

Color _coordinateColor(int x, int y, bool alpha) => Color.fromARGB(
    alpha && ((x ~/ 8) + (y ~/ 8)) % 3 == 0 ? 128 : 255,
    (x ~/ 8) & 255,
    (y ~/ 8) & 255,
    ((x ~/ 8) ^ (y ~/ 8)) & 255);

class _PixelCaptureBoundary extends SingleChildRenderObjectWidget {
  const _PixelCaptureBoundary({super.key, required super.child});
  @override
  _PixelCaptureRenderObject createRenderObject(BuildContext context) =>
      _PixelCaptureRenderObject();
}

class _PixelCaptureRenderObject extends RenderRepaintBoundary {
  Future<ui.Image> captureNativePixels(double dpr) => (layer! as OffsetLayer)
      .toImage(Rect.fromLTWH(0, 0, (400 - 1e-7) / dpr, (600 - 1e-7) / dpr),
          pixelRatio: dpr);
}

class _Source extends FileReaderPageSource {
  _Source(String name)
      : super(
            identity: ReaderPageIdentity(
                sourceKey: 'test',
                workId: name,
                downloadId: name,
                episode: 1,
                page: 0,
                sourceVersion: '1'),
            file: File('unused-$name'));
  int opens = 0;
  @override
  Future<File> openOriginalFile({ReaderPageCancellation? cancellation}) async {
    opens++;
    cancellation?.throwIfCancelled();
    return File('unused');
  }
}

class _Backend extends ReaderRasterBackend {
  final requests = <ReaderTileDemand>[];
  final gates = <Completer<void>>[];
  final cancellations = <bool Function()>[];
  bool hold = false;
  bool coordinatePattern = false;
  bool alphaPattern = false;
  bool samplingPattern = false;
  bool returnCancelledImage = false;
  Color? solidColor;
  Size metadataSize = const Size(8000, 12000);
  int lateCancelledImages = 0;
  final actualImages = <(ReaderTileDemand, int, int)>[];
  final decodedImages = <ui.Image>[];
  @override
  bool get requiresFileBacking => false;
  @override
  Future<ReaderRasterMetadata> probe(File file) async => ReaderRasterMetadata(
      size: metadataSize, animated: false, format: 'fake', workingBytes: 1);
  @override
  Future<ui.Image> decode(
    File file,
    ReaderTileDemand demand, {
    required String backingPath,
    required int memoryBudgetBytes,
    required bool Function() isCancelled,
    Future<void>? cancelled,
  }) async {
    requests.add(demand);
    cancellations.add(isCancelled);
    if (hold) {
      final gate = Completer<void>();
      gates.add(gate);
      await gate.future;
    }
    if (isCancelled()) {
      if (!returnCancelledImage) throw const ImageWorkCancelled();
      lateCancelledImages++;
    }
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      Rect.fromLTWH(
          0, 0, demand.outputWidth.toDouble(), demand.outputHeight.toDouble()),
      Paint()
        ..color = solidColor ??
            (demand.density < 0.5
                ? const Color(0xffff0000)
                : const Color(0xff0000ff)),
    );
    if (coordinatePattern || samplingPattern) {
      canvas.drawColor(const Color(0x00000000), BlendMode.src);
      if (coordinatePattern && demand.density != 1) {
        throw StateError('Coordinate fixture needs 1:1');
      }
      final left = demand.rasterRect.left.toInt();
      final top = demand.rasterRect.top.toInt();
      final right = demand.rasterRect.right.toInt();
      final bottom = demand.rasterRect.bottom.toInt();
      if (samplingPattern) {
        canvas.scale(demand.density);
        canvas.translate(-left.toDouble(), -top.toDouble());
      }
      final unit = samplingPattern ? (demand.density < 1 ? 4 : 1) : 8;
      for (var y = (top ~/ unit) * unit; y < bottom; y += unit) {
        for (var x = (left ~/ unit) * unit; x < right; x += unit) {
          final x0 = math.max(left, x), y0 = math.max(top, y);
          final x1 = math.min(right, x + unit);
          final y1 = math.min(bottom, y + unit);
          canvas.drawRect(
              samplingPattern
                  ? Rect.fromLTRB(x0.toDouble(), y0.toDouble(), x1.toDouble(),
                      y1.toDouble())
                  : Rect.fromLTRB((x0 - left).toDouble(), (y0 - top).toDouble(),
                      (x1 - left).toDouble(), (y1 - top).toDouble()),
              Paint()
                ..blendMode = BlendMode.src
                ..color = samplingPattern
                    ? Color.fromARGB(
                        255,
                        (x ~/ unit).isEven ? 0 : 255,
                        (y ~/ unit).isEven ? 0 : 255,
                        ((x ~/ unit) + (y ~/ unit)).isEven ? 0 : 255)
                    : _coordinateColor(x, y, alphaPattern));
        }
      }
    }
    final picture = recorder.endRecording();
    try {
      // Synchronous raster creation keeps the widget test's fake async clock
      // independent of a native picture callback. Dimensions match the exact
      // demand; no tiny bitmap can masquerade as a sharp 512-pixel tile.
      final image =
          picture.toImageSync(demand.outputWidth, demand.outputHeight);
      actualImages.add((demand, image.width, image.height));
      decodedImages.add(image);
      return image;
    } finally {
      picture.dispose();
    }
  }

  void releaseHeld() {
    hold = false;
    for (final gate in gates) {
      if (!gate.isCompleted) gate.complete();
    }
    gates.clear();
  }
}

class _RemoteLocator extends _Source implements RasterReaderPageSource {
  _RemoteLocator({ReaderRasterBackend? backend})
      : rasterBackend = backend ?? _Backend(),
        super('remote-placeholder');
  @override
  final ReaderRasterBackend rasterBackend;
  @override
  File get rasterLocator => File('remote-placeholder-not-original');
  @override
  Future<ReaderRasterMetadata> openRasterMetadata() =>
      rasterBackend.probe(rasterLocator);
}

class _PreparedAdmissionBackend extends _Backend {
  int estimates = 0, preparedReads = 0, coldReads = 0;
  bool miss = false;
  void Function()? beforeMiss;
  Completer<void>? preparedGate;
  final reservationsAtEstimate = <int>[];
  final leaseCountsAtEstimate = <int>[];
  final memoryBudgets = <int>[];
  final metadataAtAdmission = <ReaderRasterMetadata>[];
  @override
  int? preparedWorkingBytes(
      ReaderRasterMetadata metadata, ReaderTileDemand demand) {
    metadataAtAdmission.add(metadata);
    return 32 << 20;
  }

  @override
  Future<int> estimateWorkingBytes(File file, ReaderTileDemand demand,
      {required String backingPath}) async {
    estimates++;
    reservationsAtEstimate.add(ImageWorkScheduler.shared.reservedBytes);
    leaseCountsAtEstimate.add(ReaderPageFileLease.activeLeaseCount);
    return 64 << 20;
  }

  @override
  Future<ui.Image> decodePrepared(File file, ReaderTileDemand demand,
      {required String backingPath,
      required int memoryBudgetBytes,
      required bool Function() isCancelled,
      Future<void>? cancelled}) async {
    preparedReads++;
    memoryBudgets.add(memoryBudgetBytes);
    if (preparedGate != null) await preparedGate!.future;
    if (isCancelled()) throw const ImageWorkCancelled();
    if (miss) {
      beforeMiss?.call();
      throw const ReaderPreparedReadMiss();
    }
    return super.decode(file, demand,
        backingPath: backingPath,
        memoryBudgetBytes: memoryBudgetBytes,
        isCancelled: isCancelled,
        cancelled: cancelled);
  }

  @override
  Future<ui.Image> decode(File file, ReaderTileDemand demand,
      {required String backingPath,
      required int memoryBudgetBytes,
      required bool Function() isCancelled,
      Future<void>? cancelled}) {
    coldReads++;
    memoryBudgets.add(memoryBudgetBytes);
    return super.decode(file, demand,
        backingPath: backingPath,
        memoryBudgetBytes: memoryBudgetBytes,
        isCancelled: isCancelled,
        cancelled: cancelled);
  }
}

class _AlphaCompositeBackend extends _Backend {
  final heldVariants = <String, Completer<void>>{};
  String? heldVariant;
  Color? previewColor;
  Color? tileColor;
  bool transparentTileCells = true;

  @override
  Future<ui.Image> decode(File file, ReaderTileDemand demand,
      {required String backingPath,
      required int memoryBudgetBytes,
      required bool Function() isCancelled,
      Future<void>? cancelled}) async {
    requests.add(demand);
    if (demand.variant == heldVariant) {
      final gate =
          heldVariants.putIfAbsent(demand.variant, Completer<void>.new);
      await gate.future;
    }
    if (isCancelled()) throw const ImageWorkCancelled();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.scale(demand.density);
    canvas.translate(-demand.rasterRect.left, -demand.rasterRect.top);
    _paintAlphaChecker(canvas, demand.rasterRect,
        isTile: demand.column >= 0,
        transparentTileCells: transparentTileCells,
        color: demand.column < 0 ? previewColor : tileColor);
    final picture = recorder.endRecording();
    try {
      return picture.toImageSync(demand.outputWidth, demand.outputHeight);
    } finally {
      picture.dispose();
    }
  }

  void releaseVariant(String variant) {
    final gate = heldVariants[variant]!;
    if (!gate.isCompleted) gate.complete();
  }

  void releaseAlphaWork() {
    for (final gate in heldVariants.values) {
      if (!gate.isCompleted) gate.complete();
    }
  }
}

void _paintAlphaChecker(Canvas canvas, Rect rect,
    {required bool isTile,
    required bool transparentTileCells,
    required Color? color}) {
  for (var y = (rect.top / 32).floor() * 32; y < rect.bottom; y += 32) {
    for (var x = (rect.left / 32).floor() * 32; x < rect.right; x += 32) {
      final cell = ((x ~/ 32) + (y ~/ 32)) % 3;
      canvas.drawRect(
          Rect.fromLTWH(x.toDouble(), y.toDouble(), 32, 32),
          Paint()
            ..blendMode = BlendMode.src
            ..color = transparentTileCells && isTile && cell == 0
                ? const Color(0x00000000)
                : color ?? const Color(0x80ff8040));
    }
  }
}

class _SingleTileFailureBackend extends _Backend {
  _SingleTileFailureBackend({required this.failEstimate});
  final bool failEstimate;
  String? failedVariant;
  int failures = 0;
  @override
  Future<int> estimateWorkingBytes(File file, ReaderTileDemand demand,
      {required String backingPath}) async {
    if (failEstimate && failedVariant == null && demand.density == 1) {
      failedVariant = demand.variant;
      failures++;
      throw StateError('Injected single-tile estimate failure');
    }
    return 1;
  }

  @override
  Future<ui.Image> decode(File file, ReaderTileDemand demand,
      {required String backingPath,
      required int memoryBudgetBytes,
      required bool Function() isCancelled,
      Future<void>? cancelled}) async {
    if (!failEstimate && failedVariant == null && demand.density == 1) {
      failedVariant = demand.variant;
      failures++;
      throw StateError('Injected single-tile decode failure');
    }
    return super.decode(file, demand,
        backingPath: backingPath,
        memoryBudgetBytes: memoryBudgetBytes,
        isCancelled: isCancelled,
        cancelled: cancelled);
  }
}

class _AdmissionRaceFile implements File {
  _AdmissionRaceFile(this.delegate);
  final File delegate;
  bool holdPostDecodeStats = false;
  final stats = <Completer<FileStat>>[];
  @override
  String get path => delegate.path;
  @override
  File get absolute => delegate.absolute;
  @override
  Future<FileStat> stat() {
    if (!holdPostDecodeStats) return delegate.stat();
    final gate = Completer<FileStat>();
    stats.add(gate);
    return gate.future;
  }

  void releaseStat(int index) => stats[index].complete(delegate.statSync());
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _AdmissionRaceBackend extends _Backend {
  _AdmissionRaceBackend(this.file);
  final _AdmissionRaceFile file;
  bool race = false;
  int decoded = 0;
  final bothDecoded = Completer<void>();
  @override
  Future<ui.Image> decode(File file, ReaderTileDemand demand,
      {required String backingPath,
      required int memoryBudgetBytes,
      required bool Function() isCancelled,
      Future<void>? cancelled}) async {
    final image = await super.decode(file, demand,
        backingPath: backingPath,
        memoryBudgetBytes: memoryBudgetBytes,
        isCancelled: isCancelled,
        cancelled: cancelled);
    if (race) {
      decoded++;
      if (decoded == 2) {
        this.file.holdPostDecodeStats = true;
        bothDecoded.complete();
      }
      await bothDecoded.future;
    }
    return image;
  }
}

class _TouchFailureFile implements File {
  _TouchFailureFile(this.delegate, this.failTouch);
  final File delegate;
  final void Function() failTouch;
  @override
  String get path => delegate.path;
  @override
  File get absolute => delegate.absolute;
  @override
  Directory get parent => delegate.parent;
  @override
  Future<bool> exists() => delegate.exists();
  @override
  Future<int> length() => delegate.length();
  @override
  Future<FileStat> stat() => delegate.stat();
  @override
  Future<File> writeAsBytes(List<int> bytes,
          {FileMode mode = FileMode.write, bool flush = false}) =>
      delegate.writeAsBytes(bytes, mode: mode, flush: flush);
  @override
  Future<File> setLastModified(DateTime time) async {
    failTouch();
    throw FileSystemException('Injected backing touch failure', path);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _TouchFailureOverrides extends IOOverrides {
  int touches = 0;
  @override
  File createFile(String path) {
    final file = super.createFile(path);
    return path.endsWith('.rgba')
        ? _TouchFailureFile(file, () => touches++)
        : file;
  }
}

class _MaintenanceFailureBackend extends _Backend {
  ui.Image? created;
  @override
  bool get requiresFileBacking => true;
  @override
  Future<ui.Image> decode(File file, ReaderTileDemand demand,
      {required String backingPath,
      required int memoryBudgetBytes,
      required bool Function() isCancelled,
      Future<void>? cancelled}) async {
    final image = await super.decode(file, demand,
        backingPath: backingPath,
        memoryBudgetBytes: memoryBudgetBytes,
        isCancelled: isCancelled,
        cancelled: cancelled);
    created = image;
    await File(backingPath).writeAsBytes([1]);
    return image;
  }
}

class _BoundedFitBackend extends BoundedPngFitReaderRasterBackend {
  _BoundedFitBackend(this.delegate)
      : super(
            const ReaderRasterMetadata(
                size: Size(4000, 6000),
                animated: false,
                format: 'png',
                workingBytes: 96000000),
            textureEdgeLowerBound: 8192,
            persistRaster: false);
  final _Backend delegate;
  @override
  bool get requiresFileBacking => false;
  @override
  bool get supportsIdlePreparation => false;
  @override
  Future<int> estimateWorkingBytes(File file, ReaderTileDemand demand,
          {required String backingPath}) async =>
      1;
  @override
  Future<ui.Image> decode(File file, ReaderTileDemand demand,
          {required String backingPath,
          required int memoryBudgetBytes,
          required bool Function() isCancelled,
          Future<void>? cancelled}) =>
      delegate.decode(file, demand,
          backingPath: backingPath,
          memoryBudgetBytes: memoryBudgetBytes,
          isCancelled: isCancelled,
          cancelled: cancelled);
}

class _NativeJpegFitBackend extends NativeReaderRasterBackend {
  _NativeJpegFitBackend(this.delegate, {this.profile = false});
  final _Backend delegate;
  final bool profile;
  @override
  bool get requiresFileBacking => false;
  @override
  bool get supportsIdlePreparation => false;
  @override
  Future<ReaderRasterMetadata> probe(File file) async => ReaderRasterMetadata(
      size: const Size(4000, 6000),
      animated: false,
      format: 'jpeg',
      workingBytes: 96000000,
      hasColorProfile: profile);
  @override
  Future<int> estimateWorkingBytes(File file, ReaderTileDemand demand,
          {required String backingPath}) async =>
      1;
  @override
  Future<ui.Image> decode(File file, ReaderTileDemand demand,
          {required String backingPath,
          required int memoryBudgetBytes,
          required bool Function() isCancelled,
          Future<void>? cancelled}) =>
      delegate.decode(file, demand,
          backingPath: backingPath,
          memoryBudgetBytes: memoryBudgetBytes,
          isCancelled: isCancelled,
          cancelled: cancelled);
}

Widget _harness(
    {required ReaderPageSource source,
    required ReaderRasterBackend backend,
    required ValueNotifier<double> zoom,
    required ValueNotifier<ReaderDisplayMode> mode,
    required GlobalKey viewport,
    required GlobalKey screenshot,
    ValueNotifier<int>? tilePixels,
    ReaderResolvedOriginal? resolvedOriginal,
    bool viewportRegion = false,
    bool nativeLargeFit = false,
    bool preparedReadAdmission = false,
    int textureEdgeLowerBound = 0,
    Size sourceSize = const Size(8000, 12000),
    Size viewportSize = const Size(400, 600),
    bool topLeftProjection = false,
    double rotation = 0,
    ValueNotifier<Offset>? pan,
    ValueChanged<ReaderPresentedFrame>? onPresented}) {
  final transformChanges = pan == null ? zoom : Listenable.merge([zoom, pan]);
  Widget surface(ReaderDisplayMode displayMode, int pixels) =>
      ReaderImageSurface(
          source: source,
          sourceSize: sourceSize,
          viewportKey: viewport,
          mode: displayMode,
          transformChanges: transformChanges,
          backend: backend,
          resolvedOriginal: resolvedOriginal,
          tilePixels: pixels,
          viewportRegion: viewportRegion,
          nativeLargeFit: nativeLargeFit,
          preparedReadAdmission: preparedReadAdmission,
          textureEdgeLowerBound: textureEdgeLowerBound,
          onPresented: onPresented);
  Widget pixels(double scale) => Transform.scale(
      scale: scale,
      alignment: topLeftProjection ? Alignment.topLeft : Alignment.center,
      child: ValueListenableBuilder<ReaderDisplayMode>(
          valueListenable: mode,
          builder: (_, displayMode, __) => SizedBox(
              width: sourceSize.width,
              height: sourceSize.height,
              child: tilePixels == null
                  ? surface(displayMode, 512)
                  : ValueListenableBuilder<int>(
                      valueListenable: tilePixels,
                      builder: (_, pixels, __) =>
                          surface(displayMode, pixels)))));
  Widget rotatedPixels(double scale) => rotation == 0
      ? pixels(scale)
      : Transform.rotate(angle: rotation, child: pixels(scale));
  final content = ValueListenableBuilder<double>(
      valueListenable: zoom,
      builder: (_, scale, __) => pan == null
          ? rotatedPixels(scale)
          : ValueListenableBuilder<Offset>(
              valueListenable: pan,
              builder: (_, offset, __) => Transform.translate(
                  offset: offset, child: rotatedPixels(scale))));
  return MaterialApp(
      home: Scaffold(
          body: Center(
              child: _PixelCaptureBoundary(
                  key: screenshot,
                  child: SizedBox(
                      key: viewport,
                      width: viewportSize.width,
                      height: viewportSize.height,
                      child: ColoredBox(
                          color: Colors.black,
                          child: ClipRect(
                              child: OverflowBox(
                                  minWidth: sourceSize.width,
                                  maxWidth: sourceSize.width,
                                  minHeight: sourceSize.height,
                                  maxHeight: sourceSize.height,
                                  alignment: topLeftProjection
                                      ? Alignment.topLeft
                                      : Alignment.center,
                                  child: content))))))));
}

Future<void> _settle(WidgetTester tester, {int frames = 12}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 3)));
  }
}

List<ImageWorkTicket<void>> _fillReaderExecutionQueue() {
  final scheduler = ImageWorkScheduler.shared;
  return List.generate(scheduler.maxExecutionPending, (index) {
    final ticket = scheduler.submit<void>(
        key: 'surface-queue-blocker-$index',
        priority: ImageWorkPriority.visible,
        estimatedBytes: 1,
        run: (cancel) async {
          await cancel.cancelled;
          cancel.throwIfCancelled();
        });
    unawaited(ticket.future.then<void>((_) {}, onError: (Object error) {
      if (error is! ImageWorkCancelled) throw error;
    }));
    return ticket;
  });
}

Future<void> _waitForResidentVariant(
    WidgetTester tester, String variant) async {
  for (var i = 0; i < 80; i++) {
    final surface = ReaderSurfaceDiagnostics.snapshot().single;
    if ((surface['residentVariants'] as List).contains(variant)) return;
    await _settle(tester, frames: 4);
  }
  fail(
      'Tile never became resident: $variant; ${ReaderSurfaceDiagnostics.snapshot()}');
}

Future<List<int>> _sample(WidgetTester tester, GlobalKey key) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await tester.runAsync(() => boundary.toImage(pixelRatio: 1));
  final bytes = await tester
      .runAsync(() => image!.toByteData(format: ui.ImageByteFormat.rawRgba));
  image!.dispose();
  final offset = (40 * image.width + 40) * 4;
  return bytes!.buffer.asUint8List().sublist(offset, offset + 3);
}

Future<List<int>> _sampleAt(
    WidgetTester tester, GlobalKey key, int x, int y) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await tester.runAsync(() => boundary.toImage(pixelRatio: 1));
  try {
    final bytes = (await tester.runAsync(
        () => image!.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
    final offset = (y * image!.width + x) * 4;
    return bytes.buffer.asUint8List().sublist(offset, offset + 4);
  } finally {
    image!.dispose();
  }
}

Future<List<int>> _captureRgba(WidgetTester tester, GlobalKey key) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await tester.runAsync(() => boundary.toImage(pixelRatio: 1));
  try {
    final bytes = (await tester.runAsync(
        () => image!.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
    return bytes.buffer
        .asUint8List(bytes.offsetInBytes, bytes.lengthInBytes)
        .toList();
  } finally {
    image!.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  final savedDiskQuota = ImageDiskQuota.overrideForTesting;
  setUp(() async {
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.devicePixelRatio = 1;
    view.physicalSize = const Size(800, 600);
    await TestWidgetsFlutterBinding.instance.runAsync(() async {
      ImageDiskQuota.overrideForTesting = ImageDiskQuota(
          roots: () => [App.cachePath],
          idleLimitBytes: () => 512 << 20,
          space: (_) async => const ImageDiskSpace(100 << 30, 'surface-test'));
    });
  });
  tearDown(() {
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.resetDevicePixelRatio();
    view.resetPhysicalSize();
  });
  setUpAll(() async {
    final parent = Platform.isWindows
        ? Directory(r'E:\picakeep-image-pipeline-022-work')
        : Directory.systemTemp;
    await parent.create(recursive: true);
    root = await parent.createTemp('surface-test-');
    PathProviderPlatform.instance = _TestPaths(root);
    await App.init();
  });
  tearDownAll(() async {
    ImageDiskQuota.overrideForTesting = savedDiskQuota;
    if (await root.exists()) await root.delete(recursive: true);
  });

  testWidgets(
      'fit to zoom requests original ROI at higher density without reopening source',
      (tester) async {
    final source = _Source('one');
    final backend = _Backend();
    final zoom = ValueNotifier(0.05);
    final mode = ValueNotifier(ReaderDisplayMode.sharpFirst);
    final viewport = GlobalKey();
    final screenshot = GlobalKey();
    await tester.pumpWidget(_harness(
        source: source,
        backend: backend,
        zoom: zoom,
        mode: mode,
        viewport: viewport,
        screenshot: screenshot));
    await _settle(tester);
    expect(backend.requests, isNotEmpty);
    expect(
        backend.requests.every((request) => request.density == 0.0625), isTrue);
    final before = backend.requests.length;
    zoom.value = 0.5;
    await _settle(tester);
    final upgraded = backend.requests.skip(before).toList();
    expect(upgraded, isNotEmpty);
    expect(upgraded.every((request) => request.density == 0.5), isTrue);
    expect(
        upgraded.any((request) =>
            request.sourceRect.left > 0 && request.sourceRect.top > 0),
        isTrue);
    expect(source.opens, 1);
    await tester.pumpWidget(const SizedBox());
    await _settle(tester);
    expect(ImageWorkScheduler.shared.activeCount, 0);
    zoom.dispose();
    mode.dispose();
  });

  testWidgets(
      'preview and equal-density tiles compose each source cell exactly once',
      (tester) async {
    final source = _Source('alpha-layer-coverage');
    final backend = _AlphaCompositeBackend()
      ..metadataSize = const Size(1024, 1024)
      ..previewColor = const Color(0x80ff0000)
      ..tileColor = const Color(0x8000ff00)
      ..heldVariant =
          const ReaderTileDemand(Rect.fromLTWH(256, 256, 256, 256), 1, 1, 1)
              .variant;
    final zoom = ValueNotifier(1.0);
    final mode = ValueNotifier(ReaderDisplayMode.previewFirst);
    final screenshot = GlobalKey();
    final tilePixels = ValueNotifier(256);
    List<int>? previewPixels;
    try {
      await tester.pumpWidget(_harness(
          source: source,
          backend: backend,
          zoom: zoom,
          mode: mode,
          viewport: GlobalKey(),
          screenshot: screenshot,
          tilePixels: tilePixels,
          sourceSize: const Size(1024, 1024),
          viewportSize: const Size(512, 512),
          topLeftProjection: false));
      await _settle(tester, frames: 20);
      final requests = backend.requests.where((d) => d.column >= 0).toList();
      expect(requests, hasLength(4));
      final targetTile =
          requests.firstWhere((d) => d.column == 1 && d.row == 1);
      expect(targetTile.variant, backend.heldVariant);
      final targetPixel = await _sampleAt(tester, screenshot, 24, 24);
      expect(targetPixel, [128, 0, 0, 255],
          reason: 'an absent tile must leave the whole preview visible once');
      expect(backend.heldVariants, contains(targetTile.variant));
      backend.releaseVariant(targetTile.variant);
      await _settle(tester, frames: 20);
      expect(await _sampleAt(tester, screenshot, 24, 24), [0, 128, 0, 255],
          reason:
              'a loaded tile must replace, rather than blend with, preview');
      expect(await _sampleAt(tester, screenshot, 44, 44), [0, 0, 0, 255],
          reason: 'transparent pixels in a tile must reveal page background');
      previewPixels = await _captureRgba(tester, screenshot);
      mode.value = ReaderDisplayMode.sharpFirst;
      await _settle(tester, frames: 4);
      expect(await _captureRgba(tester, screenshot), previewPixels,
          reason: 'complete preview/sharp layers must have identical pixels');
      final surface = ReaderSurfaceDiagnostics.snapshot().single;
      expect(surface['ticketVariants'], isEmpty);
      expect(surface['estimating'], isEmpty);
      expect(surface['residentVariants'], contains(targetTile.variant));
      expect(tester.takeException(), isNull);
    } finally {
      backend.releaseAlphaWork();
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      zoom.dispose();
      mode.dispose();
      tilePixels.dispose();
    }
    expect(ReaderSurfaceDiagnostics.residentBytes, 0);
    expect(ImageWorkScheduler.shared.reservedBytes, 0);
    expect(ReaderPageFileLease.activeLeaseCount, 0);
  });

  testWidgets('higher-density semi-transparent ROI replaces whole preview',
      (tester) async {
    final source = _Source('alpha-multidensity-coverage');
    final backend = _AlphaCompositeBackend()
      ..metadataSize = const Size(4096, 4096)
      ..previewColor = const Color(0x80ff0000)
      ..tileColor = const Color(0x8000ff00);
    final zoom = ValueNotifier(0.5);
    final mode = ValueNotifier(ReaderDisplayMode.previewFirst);
    final screenshot = GlobalKey();
    final tilePixels = ValueNotifier(256);
    try {
      await tester.pumpWidget(_harness(
          source: source,
          backend: backend,
          zoom: zoom,
          mode: mode,
          viewport: GlobalKey(),
          screenshot: screenshot,
          tilePixels: tilePixels,
          sourceSize: const Size(4096, 4096),
          textureEdgeLowerBound: 1024,
          viewportSize: const Size(512, 512),
          topLeftProjection: false));
      await _settle(tester, frames: 24);
      final requests = backend.requests;
      final preview = requests.firstWhere((d) => d.column < 0);
      final tiles = requests.where((d) => d.column >= 0).toList();
      expect(preview.density, 0.25);
      expect(tiles, hasLength(4));
      expect(tiles.every((d) => d.density == 0.5), isTrue);
      expect(await _sampleAt(tester, screenshot, 24, 24), [0, 128, 0, 255],
          reason: 'a higher-density tile replaces the lower-density preview');
      expect(await _sampleAt(tester, screenshot, 48, 48), [0, 0, 0, 255],
          reason: 'a transparent tile pixel must not expose the preview');
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      zoom.dispose();
      mode.dispose();
      tilePixels.dispose();
    }
    expect(ReaderSurfaceDiagnostics.residentBytes, 0);
    expect(ImageWorkScheduler.shared.reservedBytes, 0);
    expect(ReaderPageFileLease.activeLeaseCount, 0);
  });

  testWidgets('fractional DPR and zoom leave no coverage line at tile edges',
      (tester) async {
    tester.view.devicePixelRatio = 1.25;
    tester.view.physicalSize = const Size(1000, 750);
    final source = _Source('alpha-fractional-coverage');
    final backend = _AlphaCompositeBackend()
      ..metadataSize = const Size(4096, 4096)
      ..previewColor = const Color(0x80ff0000)
      ..tileColor = const Color(0x80ff0000)
      ..transparentTileCells = false;
    final zoom = ValueNotifier(0.53);
    final pan = ValueNotifier(const Offset(0.37, -0.29));
    final mode = ValueNotifier(ReaderDisplayMode.previewFirst);
    final screenshot = GlobalKey();
    final tilePixels = ValueNotifier(256);
    try {
      await tester.pumpWidget(_harness(
          source: source,
          backend: backend,
          zoom: zoom,
          pan: pan,
          mode: mode,
          viewport: GlobalKey(),
          screenshot: screenshot,
          tilePixels: tilePixels,
          sourceSize: const Size(4096, 4096),
          viewportSize: const Size(512, 512)));
      await _settle(tester, frames: 24);
      final tiles = backend.requests.where((d) => d.column >= 0).toList();
      expect(tiles.map((demand) => demand.variant).toSet(), hasLength(16));
      final pixels = await _captureRgba(tester, screenshot);
      var different = 0;
      final mismatchSamples = <String>[];
      for (var i = 0; i < pixels.length; i += 4) {
        if (pixels[i] != 128 ||
            pixels[i + 1] != 0 ||
            pixels[i + 2] != 0 ||
            pixels[i + 3] != 255) {
          different++;
          if (mismatchSamples.length < 16) {
            mismatchSamples.add('${(i ~/ 4) % 512},${(i ~/ 4) ~/ 512}:'
                '${pixels[i]},${pixels[i + 1]},${pixels[i + 2]},${pixels[i + 3]}');
          }
        }
      }
      expect(different, 0,
          reason: 'tile/preview coverage must partition a fractional canvas; '
              'samples=$mismatchSamples');
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      zoom.dispose();
      pan.dispose();
      mode.dispose();
      tilePixels.dispose();
    }
    expect(ReaderSurfaceDiagnostics.residentBytes, 0);
    expect(ImageWorkScheduler.shared.reservedBytes, 0);
    expect(ReaderPageFileLease.activeLeaseCount, 0);
  });

  testWidgets(
      'filtered source sampling is continuous across fractional tile seams',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    final source = _Source('filtered-tile-seams');
    final backend = _Backend()
      ..metadataSize = const Size(2048, 2048)
      ..samplingPattern = true;
    final zoom = ValueNotifier(0.4);
    final pan = ValueNotifier(const Offset(0.37, -0.29));
    final mode = ValueNotifier(ReaderDisplayMode.sharpFirst);
    final viewport = GlobalKey();
    final screenshot = GlobalKey();
    final tilePixels = ValueNotifier(256);
    List<int>? tiledPixels;
    try {
      await tester.pumpWidget(_harness(
          source: source,
          backend: backend,
          zoom: zoom,
          pan: pan,
          mode: mode,
          viewport: viewport,
          screenshot: screenshot,
          tilePixels: tilePixels,
          sourceSize: const Size(2048, 2048),
          textureEdgeLowerBound: 512,
          viewportSize: const Size(512, 512)));
      await _settle(tester, frames: 24);
      final tiledRequests =
          backend.requests.where((demand) => demand.column >= 0).toList();
      expect(tiledRequests.length, greaterThan(1),
          reason:
              'requests=${backend.requests.map((d) => d.variant).toList()} surface=${ReaderSurfaceDiagnostics.snapshot()} exception=${tester.takeException()}');
      expect(tiledRequests.every((demand) => demand.density == 0.5), isTrue,
          reason:
              'densities=${tiledRequests.map((demand) => demand.density).toSet()}');
      final tiledSurface = ReaderSurfaceDiagnostics.snapshot().single;
      expect((tiledSurface['residentVariants'] as List),
          containsAll(tiledSurface['desired'] as List));
      tiledPixels = await _captureRgba(tester, screenshot);

      final previousRequestCount = backend.requests.length;
      tilePixels.value = 2048;
      await tester.pumpWidget(_harness(
          source: source,
          backend: backend,
          zoom: zoom,
          pan: pan,
          mode: mode,
          viewport: viewport,
          screenshot: screenshot,
          tilePixels: tilePixels,
          sourceSize: const Size(2048, 2048),
          textureEdgeLowerBound: 2048,
          viewportSize: const Size(512, 512)));
      await _settle(tester, frames: 24);
      final wholeRequests = backend.requests
          .skip(previousRequestCount)
          .where((demand) => demand.column < 0)
          .toList();
      expect(wholeRequests, hasLength(1));
      expect(wholeRequests.single.density, 0.5);
      final wholeSurface = ReaderSurfaceDiagnostics.snapshot().single;
      expect((wholeSurface['residentVariants'] as List),
          containsAll(wholeSurface['desired'] as List));
      final wholePixels = await _captureRgba(tester, screenshot);
      expect(wholePixels, tiledPixels,
          reason:
              'whole and tiled layers must present the same filtered source pixels');
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      zoom.dispose();
      pan.dispose();
      mode.dispose();
      tilePixels.dispose();
    }
    expect(ReaderSurfaceDiagnostics.residentBytes, 0);
    expect(ImageWorkScheduler.shared.reservedBytes, 0);
    expect(ReaderPageFileLease.activeLeaseCount, 0);
  });

  testWidgets(
      'sharpFirst retains the visible raster until the same sharp upgrade arrives',
      (tester) async {
    final source = _Source('policy');
    final backend = _Backend();
    final zoom = ValueNotifier(0.05);
    final mode = ValueNotifier(ReaderDisplayMode.sharpFirst);
    final viewport = GlobalKey();
    final screenshot = GlobalKey();
    await tester.pumpWidget(_harness(
        source: source,
        backend: backend,
        zoom: zoom,
        mode: mode,
        viewport: viewport,
        screenshot: screenshot));
    await _settle(tester);
    expect(backend.requests, isNotEmpty,
        reason: ReaderSurfaceDiagnostics.snapshot().toString());
    expect(await _sample(tester, screenshot), [255, 0, 0]);
    backend.hold = true;
    zoom.value = 0.5;
    await _settle(tester);
    expect(await _sample(tester, screenshot), [255, 0, 0],
        reason: 'a density upgrade must not blank an already visible image');
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: 'upgrading an already visible image needs no central spinner');
    mode.value = ReaderDisplayMode.previewFirst;
    await _settle(tester);
    expect(await _sample(tester, screenshot), [255, 0, 0]);
    backend.releaseHeld();
    await _settle(tester, frames: 20);
    expect(await _sample(tester, screenshot), [0, 0, 255]);
    await tester.pumpWidget(const SizedBox());
    await _settle(tester);
    zoom.dispose();
    mode.dispose();
  });

  testWidgets(
      'partial continuous pages keep one bounded whole layer then retain it across ROI upgrade',
      (tester) async {
    final source = _Source('partial-whole-continuity');
    final backend = _Backend();
    final zoom = ValueNotifier(0.125);
    final pan = ValueNotifier(Offset.zero);
    final mode = ValueNotifier(ReaderDisplayMode.sharpFirst);
    final screenshot = GlobalKey();
    final presented = <ReaderPresentedFrame>[];
    try {
      await tester.pumpWidget(_harness(
          source: source,
          backend: backend,
          zoom: zoom,
          pan: pan,
          mode: mode,
          viewport: GlobalKey(),
          screenshot: screenshot,
          onPresented: presented.add));
      await _settle(tester);
      expect(backend.requests, hasLength(1));
      final whole = backend.requests.single;
      expect((whole.column, whole.row), (-1, -1));
      expect(whole.sourceRect, const Rect.fromLTWH(0, 0, 8000, 12000));
      expect((whole.outputWidth, whole.outputHeight), (1000, 1500));
      expect(presented.last.sourceRect.width * presented.last.sourceRect.height,
          lessThan(8000 * 12000 * 0.75));
      expect(whole.outputWidth * whole.outputHeight * 4, lessThan(16 << 20));
      pan.value = const Offset(12, 10);
      await _settle(tester);
      expect(backend.requests, hasLength(1),
          reason:
              'scrolling within a retained whole page must not decode again');

      backend
        ..hold = true
        ..solidColor = const Color(0xff0000ff);
      zoom.value = 0.25;
      await _settle(tester);
      expect(backend.requests.skip(1), isNotEmpty);
      expect(backend.requests.skip(1).every((tile) => tile.column >= 0), isTrue,
          reason: 'the 24 MB whole output exceeds the 16 MiB fit budget');
      expect(await _sample(tester, screenshot), [255, 0, 0],
          reason: 'the bounded whole layer must fill pending ROI pixels');
      backend.releaseHeld();
      await _settle(tester, frames: 24);
      expect(await _sample(tester, screenshot), [0, 0, 255]);
      expect(source.opens, 1);
      expect(tester.takeException(), isNull);
    } finally {
      backend.releaseHeld();
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      zoom.dispose();
      pan.dispose();
      mode.dispose();
    }
    expect(ReaderSurfaceDiagnostics.residentBytes, 0);
    expect(ImageWorkScheduler.shared.reservedBytes, 0);
    expect(ReaderPageFileLease.activeLeaseCount, 0);
  });

  testWidgets(
      'sharp upgrade keeps alpha fallback only in missing cells and replaces transparent pixels',
      (tester) async {
    final source = _Source('sharp-alpha-upgrade');
    final heldTile = const ReaderViewportDemand(
            visibleSourceRect: Rect.fromLTWH(1536, 1536, 1024, 1024),
            physicalPixelsPerSourcePixel: 0.5)
        .tiles(const Size(4096, 4096), tilePixels: 256, samplingGutterPixels: 2)
        .first;
    final backend = _AlphaCompositeBackend()
      ..metadataSize = const Size(4096, 4096)
      ..previewColor = const Color(0x80ff0000)
      ..tileColor = const Color(0x8000ff00)
      ..heldVariant = heldTile.variant;
    final zoom = ValueNotifier(0.125);
    final mode = ValueNotifier(ReaderDisplayMode.sharpFirst);
    final screenshot = GlobalKey();
    final tilePixels = ValueNotifier(256);
    try {
      await tester.pumpWidget(_harness(
          source: source,
          backend: backend,
          zoom: zoom,
          mode: mode,
          viewport: GlobalKey(),
          screenshot: screenshot,
          tilePixels: tilePixels,
          sourceSize: const Size(4096, 4096),
          textureEdgeLowerBound: 1024,
          viewportSize: const Size(512, 512)));
      await _settle(tester);
      expect(backend.requests, hasLength(1));
      zoom.value = 0.5;
      await _settle(tester, frames: 24);
      expect(backend.heldVariants, contains(heldTile.variant));
      expect(await _sampleAt(tester, screenshot, 24, 24), [128, 0, 0, 255],
          reason: 'the missing sharp tile keeps its old alpha layer once');
      expect(await _sampleAt(tester, screenshot, 300, 24), [0, 128, 0, 255],
          reason:
              'arrived sharp cells replace, rather than blend with, fallback');
      backend.releaseVariant(heldTile.variant);
      await _settle(tester, frames: 24);
      expect(await _sampleAt(tester, screenshot, 24, 24), [0, 128, 0, 255]);
      expect(await _sampleAt(tester, screenshot, 48, 48), [0, 0, 0, 255],
          reason: 'transparent sharp cells reveal background, not old pixels');
      expect(tester.takeException(), isNull);
    } finally {
      backend.releaseAlphaWork();
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      zoom.dispose();
      mode.dispose();
      tilePixels.dispose();
    }
    expect(ReaderSurfaceDiagnostics.residentBytes, 0);
    expect(ImageWorkScheduler.shared.reservedBytes, 0);
    expect(ReaderPageFileLease.activeLeaseCount, 0);
  });

  testWidgets(
      'source replacement discards old fallback and late upgrade pixels',
      (tester) async {
    final oldBackend = _Backend()..returnCancelledImage = true;
    final newBackend = _Backend()
      ..hold = true
      ..solidColor = const Color(0xff00ff00);
    final zoom = ValueNotifier(0.05);
    final mode = ValueNotifier(ReaderDisplayMode.sharpFirst);
    final viewport = GlobalKey();
    final screenshot = GlobalKey();
    Widget harness(ReaderPageSource source, ReaderRasterBackend backend) =>
        _harness(
            source: source,
            backend: backend,
            zoom: zoom,
            mode: mode,
            viewport: viewport,
            screenshot: screenshot);
    try {
      await tester.pumpWidget(harness(_Source('old-visible'), oldBackend));
      await _settle(tester);
      expect(await _sample(tester, screenshot), [255, 0, 0]);
      oldBackend.hold = true;
      zoom.value = 0.5;
      await _settle(tester);
      expect(await _sample(tester, screenshot), [255, 0, 0]);
      await tester.pumpWidget(harness(_Source('new-visible'), newBackend));
      await _settle(tester);
      expect(await _sample(tester, screenshot), [0, 0, 0],
          reason: 'a new source must never inherit the old visible fallback');
      oldBackend.releaseHeld();
      await _settle(tester);
      expect(oldBackend.lateCancelledImages, greaterThan(0));
      expect(await _sample(tester, screenshot), [0, 0, 0],
          reason: 'late cancelled output must not fill the new source');
      newBackend.releaseHeld();
      await _settle(tester, frames: 24);
      expect(await _sample(tester, screenshot), [0, 255, 0]);
      expect(tester.takeException(), isNull);
    } finally {
      oldBackend.releaseHeld();
      newBackend.releaseHeld();
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      zoom.dispose();
      mode.dispose();
    }
    expect(
        oldBackend.decodedImages.every((image) => image.debugDisposed), isTrue);
    expect(
        newBackend.decodedImages.every((image) => image.debugDisposed), isTrue);
    expect(ReaderSurfaceDiagnostics.residentBytes, 0);
    expect(ImageWorkScheduler.shared.reservedBytes, 0);
    expect(ReaderPageFileLease.activeLeaseCount, 0);
  });

  testWidgets(
      'replacing source cancels old work without removing same-variant new requests',
      (tester) async {
    final backend = _Backend()..hold = true;
    final zoom = ValueNotifier(0.05);
    final mode = ValueNotifier(ReaderDisplayMode.sharpFirst);
    final viewport = GlobalKey();
    final screenshot = GlobalKey();
    final old = _Source('old');
    await tester.pumpWidget(_harness(
        source: old,
        backend: backend,
        zoom: zoom,
        mode: mode,
        viewport: viewport,
        screenshot: screenshot));
    await _settle(tester);
    final oldCancellation = List<bool Function()>.of(backend.cancellations);
    final replacement = _Source('new');
    await tester.pumpWidget(_harness(
        source: replacement,
        backend: backend,
        zoom: zoom,
        mode: mode,
        viewport: viewport,
        screenshot: screenshot));
    await _settle(tester);
    expect(oldCancellation.every((cancelled) => cancelled()), isTrue);
    backend.releaseHeld();
    await _settle(tester, frames: 24);
    expect(replacement.opens, 1);
    expect(await _sample(tester, screenshot), [255, 0, 0]);
    await tester.pumpWidget(const SizedBox());
    await _settle(tester);
    expect(ImageWorkScheduler.shared.activeCount, 0);
    expect(ImageWorkScheduler.shared.reservedBytes, 0);
    zoom.dispose();
    mode.dispose();
  });

  testWidgets('a temporarily full reader queue recovers without manual reload',
      (tester) async {
    final blockers = _fillReaderExecutionQueue();
    final backend = _Backend();
    final zoom = ValueNotifier(0.05);
    final mode = ValueNotifier(ReaderDisplayMode.sharpFirst);
    final presented = <ReaderPresentedFrame>[];
    try {
      await tester.pumpWidget(_harness(
          source: _Source('queue-recovery'),
          backend: backend,
          zoom: zoom,
          mode: mode,
          viewport: GlobalKey(),
          screenshot: GlobalKey(),
          onPresented: presented.add));
      await _settle(tester, frames: 4);
      expect(backend.requests, isEmpty,
          reason: 'the real scheduler must reject the initial request');
      expect(find.byType(TextButton), findsNothing,
          reason: 'queue saturation is temporary, not a failed source');
      for (final ticket in blockers) {
        ticket.cancel();
      }
      await _settle(tester, frames: 32);
      expect(presented.last.complete, isTrue);
      expect(backend.requests, hasLength(1));
      expect(
          ReaderSurfaceDiagnostics.snapshot().single['tileFailures'], isEmpty);
    } finally {
      for (final ticket in blockers) {
        ticket.cancel();
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      zoom.dispose();
      mode.dispose();
    }
    expect(ImageWorkScheduler.shared.activeCount, 0);
    expect(ImageWorkScheduler.shared.reservedBytes, 0);
    expect(ReaderPageFileLease.activeLeaseCount, 0);
  });

  testWidgets('reader queue recovery is bounded and explicit retry resets it',
      (tester) async {
    final blockers = _fillReaderExecutionQueue();
    final backend = _Backend();
    final zoom = ValueNotifier(0.05);
    final mode = ValueNotifier(ReaderDisplayMode.sharpFirst);
    final presented = <ReaderPresentedFrame>[];
    try {
      await tester.pumpWidget(_harness(
          source: _Source('queue-still-full'),
          backend: backend,
          zoom: zoom,
          mode: mode,
          viewport: GlobalKey(),
          screenshot: GlobalKey(),
          onPresented: presented.add));
      await _settle(tester, frames: 64);
      final surface = ReaderSurfaceDiagnostics.snapshot().single;
      expect(surface['tileFailures'], isNotEmpty);
      expect((surface['tileQueueRetries'] as Map).values, [2]);
      expect(surface['retryVariants'], isEmpty);
      expect(find.byType(TextButton), findsOneWidget);
      for (final ticket in blockers) {
        ticket.cancel();
      }
      await tester.pump(const Duration(seconds: 2));
      await _settle(tester);
      expect(backend.requests, isEmpty,
          reason: 'persistent saturation must not cause unlimited polling');
      await tester.tap(find.byType(TextButton));
      await _settle(tester, frames: 24);
      expect(presented.last.complete, isTrue);
      expect(backend.requests, hasLength(1));
      expect(ReaderSurfaceDiagnostics.snapshot().single['tileQueueRetries'],
          isEmpty);
    } finally {
      for (final ticket in blockers) {
        ticket.cancel();
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      zoom.dispose();
      mode.dispose();
    }
    expect(ReaderSurfaceDiagnostics.residentBytes, 0);
    expect(ReaderSurfaceDiagnostics.pendingBytes, 0);
    expect(ImageWorkScheduler.shared.activeCount, 0);
    expect(ImageWorkScheduler.shared.reservedBytes, 0);
  });

  testWidgets('disposing a page cancels its pending reader queue recovery',
      (tester) async {
    final blockers = _fillReaderExecutionQueue();
    final backend = _Backend();
    final zoom = ValueNotifier(0.05);
    final mode = ValueNotifier(ReaderDisplayMode.sharpFirst);
    try {
      await tester.pumpWidget(_harness(
          source: _Source('queue-disposed'),
          backend: backend,
          zoom: zoom,
          mode: mode,
          viewport: GlobalKey(),
          screenshot: GlobalKey()));
      await _settle(tester, frames: 4);
      expect(ReaderSurfaceDiagnostics.snapshot().single['retryVariants'],
          isNotEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      for (final ticket in blockers) {
        ticket.cancel();
      }
      await tester.pump(const Duration(seconds: 2));
      await _settle(tester);
      expect(backend.requests, isEmpty);
      expect(ReaderSurfaceDiagnostics.activeSurfaces, 0);
      expect(ImageWorkScheduler.shared.pendingCount, 0);
      expect(ImageWorkScheduler.shared.reservedBytes, 0);
      expect(ReaderPageFileLease.activeLeaseCount, 0);
    } finally {
      for (final ticket in blockers) {
        ticket.cancel();
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      zoom.dispose();
      mode.dispose();
    }
  });

  for (final failEstimate in [true, false]) {
    testWidgets(
        'single-tile ${failEstimate ? 'estimate' : 'decode'} failure stays visible after neighbour success and retries explicitly',
        (tester) async {
      final backend = _SingleTileFailureBackend(failEstimate: failEstimate);
      final zoom = ValueNotifier(1.0);
      final mode = ValueNotifier(ReaderDisplayMode.sharpFirst);
      final presented = <ReaderPresentedFrame>[];
      try {
        await tester.pumpWidget(_harness(
            source: _Source('failure-$failEstimate'),
            backend: backend,
            zoom: zoom,
            mode: mode,
            viewport: GlobalKey(),
            screenshot: GlobalKey(),
            onPresented: presented.add));
        await _settle(tester, frames: 24);
        final surface = ReaderSurfaceDiagnostics.snapshot().single;
        final desired = (surface['desired'] as List).cast<String>().toSet();
        final resident =
            (surface['residentVariants'] as List).cast<String>().toSet();
        expect(desired.difference(resident), {backend.failedVariant});
        expect(surface['ticketVariants'], isEmpty);
        expect(surface['estimating'], isEmpty);
        expect(
            surface['tileFailures'],
            containsPair(
                backend.failedVariant, contains('Injected single-tile')),
            reason: 'a successful neighbour must not hide a missing tile');
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(presented, isEmpty);
        expect(backend.failures, 1,
            reason: 'terminal errors do not create an automatic retry loop');
        await tester.tap(find.byType(TextButton));
        await _settle(tester, frames: 24);
        expect(presented.last.complete, isTrue);
        expect(presented.last.nativePixels, isTrue);
        expect(ReaderSurfaceDiagnostics.snapshot().single['tileFailures'],
            isEmpty);
        expect(backend.failures, 1);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await _settle(tester);
        zoom.dispose();
        mode.dispose();
      }
      expect(ReaderSurfaceDiagnostics.residentBytes, 0);
      expect(ReaderSurfaceDiagnostics.pendingBytes, 0);
      expect(ImageWorkScheduler.shared.activeCount, 0);
      expect(ImageWorkScheduler.shared.reservedBytes, 0);
      expect(ReaderPageFileLease.activeLeaseCount, 0);
    });
  }

  testWidgets(
      'post-decode source stat race admits both visible tiles after retiring old residents',
      (tester) async {
    final source = _Source('post-decode-admission-race');
    final original = File('${root.path}/admission-race-original')
      ..writeAsBytesSync([1]);
    final file = _AdmissionRaceFile(original);
    final backend = _AdmissionRaceBackend(file);
    final metadata = await backend.probe(file);
    final resolved = ReaderResolvedOriginal(
        source: source,
        file: file,
        metadata: metadata,
        fileSnapshot: original.statSync());
    final zoom = ValueNotifier(1.0);
    final pan = ValueNotifier(const Offset(-4096, 0));
    final tiles = ValueNotifier(2048);
    final mode = ValueNotifier(ReaderDisplayMode.sharpFirst);
    final presented = <ReaderPresentedFrame>[];
    try {
      await tester.pumpWidget(_harness(
          source: source,
          backend: backend,
          zoom: zoom,
          pan: pan,
          mode: mode,
          tilePixels: tiles,
          viewport: GlobalKey(),
          screenshot: GlobalKey(),
          resolvedOriginal: resolved,
          viewportSize: const Size(400, 512),
          topLeftProjection: true,
          onPresented: presented.add));
      await _settle(tester);
      var surface = ReaderSurfaceDiagnostics.snapshot().single;
      var resident =
          (surface['residentVariants'] as List).cast<String>().single;
      await _waitForResidentVariant(tester, resident);
      for (final offset in [
        const Offset(-4096, -2048),
        const Offset(-4096, -4096),
      ]) {
        pan.value = offset;
        await _settle(tester, frames: 4);
        surface = ReaderSurfaceDiagnostics.snapshot().single;
        final wanted = (surface['desired'] as List).cast<String>().single;
        await _waitForResidentVariant(tester, wanted);
      }
      expect(ReaderSurfaceDiagnostics.residentBytes, 48 << 20,
          reason:
              'requests=${backend.requests.map((item) => item.variant).toList()} surface=${ReaderSurfaceDiagnostics.snapshot()}');
      backend.race = true;
      pan.value = const Offset(-1840, 0);
      await _settle(tester, frames: 16);
      expect(file.stats, hasLength(2),
          reason: 'two independently decoded images await source revalidation');
      file.releaseStat(0);
      await _settle(tester, frames: 4);
      expect(
          ReaderSurfaceDiagnostics.residentBytes, lessThanOrEqualTo(64 << 20));
      file.holdPostDecodeStats = false;
      file.releaseStat(1);
      await _settle(tester, frames: 32);
      surface = ReaderSurfaceDiagnostics.snapshot().single;
      final desired = (surface['desired'] as List).cast<String>().toSet();
      final actualResident =
          (surface['residentVariants'] as List).cast<String>().toSet();
      expect(actualResident.containsAll(desired), isTrue,
          reason:
              'the second output must retry capacity admission after stat: $surface');
      expect(surface['error'], isNull);
      expect(surface['ticketVariants'], isEmpty);
      expect(surface['estimating'], isEmpty);
      expect(presented.last.sourceRect, const Rect.fromLTWH(1840, 0, 400, 512));
      expect(presented.last.complete, isTrue);
      expect(ReaderSurfaceDiagnostics.residentBytes, 32 << 20);
    } finally {
      file.holdPostDecodeStats = false;
      for (final gate in file.stats) {
        if (!gate.isCompleted) gate.complete(original.statSync());
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      zoom.dispose();
      pan.dispose();
      mode.dispose();
      tiles.dispose();
    }
    expect(ReaderSurfaceDiagnostics.residentBytes, 0);
    expect(ReaderSurfaceDiagnostics.pendingBytes, 0);
    expect(ImageWorkScheduler.shared.activeCount, 0);
    expect(ImageWorkScheduler.shared.reservedBytes, 0);
    expect(ReaderPageFileLease.activeLeaseCount, 0);
  });

  testWidgets('cancelled same-variant completion cannot remove its replacement',
      (tester) async {
    final backend = _Backend()..hold = true;
    final zoom = ValueNotifier(1.0);
    final pan = ValueNotifier(Offset.zero);
    final tiles = ValueNotifier(2048);
    final mode = ValueNotifier(ReaderDisplayMode.sharpFirst);
    final presented = <ReaderPresentedFrame>[];
    try {
      await tester.pumpWidget(_harness(
          source: _Source('same-variant-cancel-reentry'),
          backend: backend,
          zoom: zoom,
          pan: pan,
          mode: mode,
          tilePixels: tiles,
          viewport: GlobalKey(),
          screenshot: GlobalKey(),
          topLeftProjection: true,
          onPresented: presented.add));
      await _settle(tester);
      var surface = ReaderSurfaceDiagnostics.snapshot().single;
      var desired = (surface['desired'] as List).cast<String>().single;
      final originalVariant = desired;
      final originalCall =
          backend.requests.lastIndexWhere((item) => item.variant == desired);
      expect(originalCall, greaterThanOrEqualTo(0));
      pan.value = const Offset(-4096, 0);
      await _settle(tester);
      final awayCall = backend.requests.length - 1;
      expect(awayCall, greaterThan(originalCall),
          reason:
              'requests=${backend.requests.map((item) => item.variant).toList()} surface=${ReaderSurfaceDiagnostics.snapshot()}');
      expect(backend.requests[awayCall].variant, isNot(originalVariant));
      expect(backend.cancellations[originalCall](), isTrue);
      pan.value = Offset.zero;
      await _settle(tester);
      surface = ReaderSurfaceDiagnostics.snapshot().single;
      desired = (surface['desired'] as List).cast<String>().single;
      expect(desired, originalVariant);
      expect(surface['ticketVariants'], contains(originalVariant),
          reason: 'replacement waits behind the two cancelled worker calls');
      backend.releaseHeld();
      await _settle(tester, frames: 32);
      expect(backend.requests.length, greaterThan(awayCall + 1));
      expect(backend.requests.last.variant, originalVariant);
      surface = ReaderSurfaceDiagnostics.snapshot().single;
      final desiredVariants =
          (surface['desired'] as List).cast<String>().toSet();
      final resident =
          (surface['residentVariants'] as List).cast<String>().toSet();
      expect(desiredVariants, {originalVariant});
      expect(resident, desiredVariants);
      expect(surface['ticketVariants'], isEmpty);
      expect(surface['estimating'], isEmpty);
      expect(presented.last.complete, isTrue);
      expect(presented.last.nativePixels, isTrue);
      expect(tester.takeException(), isNull);
    } finally {
      backend.releaseHeld();
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      zoom.dispose();
      pan.dispose();
      tiles.dispose();
      mode.dispose();
    }
    expect(ReaderSurfaceDiagnostics.residentBytes, 0);
    expect(ReaderSurfaceDiagnostics.pendingBytes, 0);
    expect(ImageWorkScheduler.shared.activeCount, 0);
    expect(ImageWorkScheduler.shared.pendingCount, 0);
    expect(ImageWorkScheduler.shared.reservedBytes, 0);
    expect(ReaderPageFileLease.activeLeaseCount, 0);
  });

  testWidgets(
      'changing tile grid cancels late old work and keeps every native viewport pixel',
      (tester) async {
    final source = _Source('changing-grid');
    final backend = _Backend()
      ..hold = true
      ..coordinatePattern = true
      ..returnCancelledImage = true;
    final zoom = ValueNotifier(1.0);
    final mode = ValueNotifier(ReaderDisplayMode.sharpFirst);
    final tiles = ValueNotifier(512);
    final viewport = GlobalKey();
    final screenshot = GlobalKey();
    final presented = <ReaderPresentedFrame>[];
    try {
      await tester.pumpWidget(_harness(
          source: source,
          backend: backend,
          zoom: zoom,
          mode: mode,
          viewport: viewport,
          screenshot: screenshot,
          tilePixels: tiles,
          onPresented: presented.add));
      await _settle(tester);
      expect(backend.requests, isNotEmpty);
      final oldCancellation = List<bool Function()>.of(backend.cancellations);
      final originalSurface = ReaderSurfaceDiagnostics.snapshot().single;
      expect(originalSurface['desired'], isNotEmpty);
      tiles.value = 256;
      await _settle(tester);
      expect(oldCancellation.every((cancelled) => cancelled()), isTrue);
      expect(source.opens, 1,
          reason: 'grid updates retain the original source');
      backend.releaseHeld();
      await _settle(tester, frames: 32);
      expect(backend.lateCancelledImages, greaterThan(0),
          reason:
              'old native calls actually finish after the grid is replaced');
      expect(backend.requests.any((demand) => demand.sourceRect.width == 256),
          isTrue);
      await _verifyGrid(256, tester, screenshot, presented, backend);

      // Replacing a complete resident grid must evict its images as well as
      // change the demand. Full pixel comparison checks seams and coordinates.
      tiles.value = 1024;
      await _settle(tester, frames: 24);
      await _verifyGrid(1024, tester, screenshot, presented, backend);
      expect(source.opens, 1);
      expect(tester.takeException(), isNull);
    } finally {
      backend.releaseHeld();
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      zoom.dispose();
      mode.dispose();
      tiles.dispose();
    }
    expect(ReaderSurfaceDiagnostics.residentBytes, 0);
    expect(ReaderSurfaceDiagnostics.activeSurfaces, 0);
    expect(ImageWorkScheduler.shared.activeCount, 0);
    expect(ImageWorkScheduler.shared.pendingCount, 0);
    expect(ImageWorkScheduler.shared.reservedBytes, 0);
    expect(ReaderPageFileLease.activeLeaseCount, 0);
  });

  testWidgets(
      'viewport crop cancels a late pan and preserves every pixel at odd source edges',
      (tester) async {
    final source = _Source('viewport-region-odd');
    final backend = _Backend()
      ..metadataSize = const Size(8001, 12001)
      ..hold = true
      ..coordinatePattern = true
      ..returnCancelledImage = true;
    final zoom = ValueNotifier(1.0);
    final pan = ValueNotifier(const Offset(-3800, -5700));
    final mode = ValueNotifier(ReaderDisplayMode.sharpFirst);
    final screenshot = GlobalKey();
    final presented = <ReaderPresentedFrame>[];
    try {
      await tester.pumpWidget(_harness(
          source: source,
          backend: backend,
          zoom: zoom,
          pan: pan,
          mode: mode,
          viewport: GlobalKey(),
          screenshot: screenshot,
          viewportRegion: true,
          sourceSize: const Size(8001, 12001),
          topLeftProjection: true,
          onPresented: presented.add));
      await _settle(tester);
      expect(backend.requests, hasLength(1));
      expect(backend.requests.single.sourceRect,
          const Rect.fromLTWH(3800, 5700, 400, 600));
      expect((backend.requests.single.column, backend.requests.single.row),
          (-2, -2));
      final oldCancelled = backend.cancellations.single;

      // Move to the right/bottom source boundary before the first native call
      // finishes. The odd original extent must remain an exact integer crop.
      pan.value = const Offset(-7601, -11401);
      await _settle(tester);
      expect(oldCancelled(), isTrue);
      backend.releaseHeld();
      await _settle(tester, frames: 24);
      expect(backend.lateCancelledImages, 1);
      expect(backend.requests, hasLength(2));
      final demand = backend.requests.last;
      expect(demand.sourceRect, const Rect.fromLTWH(7601, 11401, 400, 600));
      expect(demand.density, 1);
      expect((demand.outputWidth, demand.outputHeight), (400, 600));
      expect(backend.actualImages.last.$2, 400);
      expect(backend.actualImages.last.$3, 600);
      final surface = ReaderSurfaceDiagnostics.snapshot().single;
      expect(surface['residentVariants'], [demand.variant],
          reason: 'cancelled old crop must never become resident');
      expect(surface['ticketVariants'], isEmpty);
      expect(presented.last.sourceRect, demand.sourceRect);
      expect(presented.last.complete, isTrue);
      expect(presented.last.nativePixels, isTrue);
      await _verifyOriginalPixels(tester, screenshot,
          sourceLeft: 7601, sourceTop: 11401);
      expect(source.opens, 1);
      expect(tester.takeException(), isNull);
    } finally {
      backend.releaseHeld();
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      zoom.dispose();
      pan.dispose();
      mode.dispose();
    }
    expect(ReaderSurfaceDiagnostics.residentBytes, 0);
    expect(ImageWorkScheduler.shared.activeCount, 0);
    expect(ImageWorkScheduler.shared.pendingCount, 0);
    expect(ImageWorkScheduler.shared.reservedBytes, 0);
    expect(ReaderPageFileLease.activeLeaseCount, 0);
  });

  testWidgets(
      'viewport crop fits exactly 4MP and falls back to a grid above it',
      (tester) async {
    tester.view.physicalSize = const Size(3000, 3000);
    final backend = _Backend();
    final source = _Source('viewport-region-cap');
    final zoom = ValueNotifier(1.0);
    final pan = ValueNotifier(const Offset(-3000, -4000));
    final mode = ValueNotifier(ReaderDisplayMode.sharpFirst);
    final viewport = GlobalKey();
    final screenshot = GlobalKey();
    final presented = <ReaderPresentedFrame>[];
    Widget harness(Size size) => _harness(
        source: source,
        backend: backend,
        zoom: zoom,
        pan: pan,
        mode: mode,
        viewport: viewport,
        screenshot: screenshot,
        viewportRegion: true,
        viewportSize: size,
        topLeftProjection: true,
        onPresented: presented.add);
    try {
      await tester.pumpWidget(harness(const Size(2048, 2048)));
      await _settle(tester, frames: 20);
      expect(backend.requests, hasLength(1));
      final crop = backend.requests.single;
      expect((crop.column, crop.row), (-2, -2));
      expect(crop.sourceRect, const Rect.fromLTWH(3000, 4000, 2048, 2048));
      expect((backend.actualImages.single.$2, backend.actualImages.single.$3),
          (2048, 2048));
      expect(presented.last.complete, isTrue);
      final before = backend.requests.length;

      await tester.pumpWidget(harness(const Size(2049, 2048)));
      await _settle(tester, frames: 32);
      final grid = backend.requests.skip(before).toList();
      expect(grid.length, greaterThan(1));
      expect(grid.every((demand) => demand.column >= 0 && demand.row >= 0),
          isTrue);
      expect(
          grid.every((demand) =>
              demand.outputWidth <= 512 && demand.outputHeight <= 512),
          isTrue);
      expect(presented.last.sourceRect,
          const Rect.fromLTWH(3000, 4000, 2049, 2048));
      expect(presented.last.complete, isTrue);
      expect(presented.last.nativePixels, isTrue);
      expect(source.opens, 1);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      zoom.dispose();
      pan.dispose();
      mode.dispose();
    }
    expect(ReaderSurfaceDiagnostics.residentBytes, 0);
    expect(ImageWorkScheduler.shared.reservedBytes, 0);
    expect(ReaderPageFileLease.activeLeaseCount, 0);
  });

  testWidgets(
      'viewport crop retains a whole fit and the remote negotiated grid',
      (tester) async {
    final zoom = ValueNotifier(0.25);
    final mode = ValueNotifier(ReaderDisplayMode.sharpFirst);
    final backend = _Backend()..metadataSize = const Size(1200, 1800);
    final source = _Source('viewport-region-small-fit');
    final viewport = GlobalKey();
    final screenshot = GlobalKey();
    final tiles = ValueNotifier(256);
    final presented = <ReaderPresentedFrame>[];
    try {
      await tester.pumpWidget(_harness(
          source: source,
          backend: backend,
          zoom: zoom,
          mode: mode,
          viewport: viewport,
          screenshot: screenshot,
          viewportRegion: true,
          sourceSize: const Size(1200, 1800)));
      await _settle(tester);
      expect(backend.requests, hasLength(1));
      final whole = backend.requests.single;
      expect((whole.column, whole.row), (-1, -1));
      expect(whole.sourceRect, const Rect.fromLTWH(0, 0, 1200, 1800));
      expect((whole.outputWidth, whole.outputHeight), (300, 450));

      final remoteBackend = _Backend()..coordinatePattern = true;
      final remote = _RemoteLocator(backend: remoteBackend);
      zoom.value = 1;
      await tester.pumpWidget(_harness(
          source: remote,
          backend: remoteBackend,
          zoom: zoom,
          mode: mode,
          viewport: viewport,
          screenshot: screenshot,
          tilePixels: tiles,
          viewportRegion: true,
          onPresented: presented.add));
      await _settle(tester, frames: 24);
      expect(remote.opens, 0,
          reason: 'raster locators never open the authoritative original');
      expect(remoteBackend.requests.length, greaterThan(1));
      expect(
          remoteBackend.requests.every((demand) =>
              demand.column >= 0 &&
              demand.row >= 0 &&
              demand.outputWidth <= 256 &&
              demand.outputHeight <= 256),
          isTrue);
      await _verifyGrid(256, tester, screenshot, presented, remoteBackend);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      zoom.dispose();
      mode.dispose();
      tiles.dispose();
    }
    expect(ReaderSurfaceDiagnostics.residentBytes, 0);
    expect(ImageWorkScheduler.shared.reservedBytes, 0);
    expect(ReaderPageFileLease.activeLeaseCount, 0);
  });

  testWidgets(
      'partial remote pages retain the negotiated grid even when a whole layer fits',
      (tester) async {
    const sourceSize = Size(6000, 8000);
    final backend = _Backend()..metadataSize = sourceSize;
    final source = _RemoteLocator(backend: backend);
    final zoom = ValueNotifier(0.25);
    final pan = ValueNotifier(Offset.zero);
    final mode = ValueNotifier(ReaderDisplayMode.sharpFirst);
    final presented = <ReaderPresentedFrame>[];
    try {
      await tester.pumpWidget(_harness(
          source: source,
          backend: backend,
          sourceSize: sourceSize,
          zoom: zoom,
          pan: pan,
          mode: mode,
          viewport: GlobalKey(),
          screenshot: GlobalKey(),
          viewportRegion: true,
          onPresented: presented.add));
      await _settle(tester, frames: 24);
      // 1500 x 2000 RGBA fits the local 16 MiB whole-layer limit. This must
      // exercise the remote visibility guard rather than pass on bytes alone.
      expect(sourceSize.width * sourceSize.height * 0.25 * 0.25 * 4,
          lessThan(16 << 20));
      expect(backend.requests.length, greaterThan(1));
      expect(presented, isNotEmpty);
      expect(presented.last.sourceRect.width * presented.last.sourceRect.height,
          lessThan(sourceSize.width * sourceSize.height * 0.75));
      final firstRequests = backend.requests.length;
      pan.value = const Offset(256, 128);
      await _settle(tester, frames: 24);
      expect(backend.requests.length, greaterThan(firstRequests),
          reason: 'new visible cells must still use the negotiated tile grid');
      expect(
          backend.requests.every((demand) =>
              demand.column >= 0 &&
              demand.row >= 0 &&
              demand.density == 0.25 &&
              demand.outputWidth <= 512 &&
              demand.outputHeight <= 512),
          isTrue,
          reason: 'partial remote views must not request a full level URL');
      expect(source.opens, 0,
          reason: 'remote locators never open the authoritative original');
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      zoom.dispose();
      pan.dispose();
      mode.dispose();
    }
    expect(ReaderSurfaceDiagnostics.residentBytes, 0);
    expect(ImageWorkScheduler.shared.reservedBytes, 0);
    expect(ReaderPageFileLease.activeLeaseCount, 0);
  });

  testWidgets(
      'bounded PNG fit covers a partial continuous view then uses native ROI',
      (tester) async {
    final source = _Source('bounded-whole-fit');
    final delegate = _Backend();
    final backend = _BoundedFitBackend(delegate);
    final zoom = ValueNotifier(0.5);
    final mode = ValueNotifier(ReaderDisplayMode.sharpFirst);
    final presented = <ReaderPresentedFrame>[];
    try {
      await tester.pumpWidget(_harness(
          source: source,
          backend: backend,
          zoom: zoom,
          mode: mode,
          viewport: GlobalKey(),
          screenshot: GlobalKey(),
          sourceSize: const Size(4000, 6000),
          onPresented: presented.add));
      await _settle(tester, frames: 20);
      expect(delegate.requests, hasLength(1));
      final fit = delegate.requests.single;
      expect(fit.sourceRect, const Rect.fromLTWH(0, 0, 4000, 6000));
      expect((fit.outputWidth, fit.outputHeight), (2000, 3000));
      expect((delegate.actualImages.single.$2, delegate.actualImages.single.$3),
          (2000, 3000));
      expect(presented.last.sourceRect,
          const Rect.fromLTWH(1600, 2400, 800, 1200));
      expect(presented.last.complete, isTrue);
      expect(presented.last.nativePixels, isFalse);
      expect(presented.last.density, 0.5);
      final before = delegate.requests.length;
      zoom.value = 1;
      await _settle(tester, frames: 24);
      final upgraded = delegate.requests.skip(before).toList();
      expect(upgraded, isNotEmpty);
      expect(
          upgraded.every((demand) =>
              demand.density == 1 && demand.column >= 0 && demand.row >= 0),
          isTrue);
      expect(presented.last.nativePixels, isTrue);
      expect(presented.last.complete, isTrue);
      expect(source.opens, 1);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      zoom.dispose();
      mode.dispose();
    }
    expect(ReaderSurfaceDiagnostics.residentBytes, 0);
    expect(ImageWorkScheduler.shared.reservedBytes, 0);
    expect(ReaderPageFileLease.activeLeaseCount, 0);
  });

  testWidgets(
      'native JPEG larger fit is opt in and returns to exact ROI at 1:1',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(2000, 3000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final source = _Source('native-jpeg-whole');
    final delegate = _Backend();
    final backend = _NativeJpegFitBackend(delegate);
    final zoom = ValueNotifier(0.5);
    final mode = ValueNotifier(ReaderDisplayMode.sharpFirst);
    final presented = <ReaderPresentedFrame>[];
    try {
      await tester.pumpWidget(_harness(
          source: source,
          backend: backend,
          zoom: zoom,
          mode: mode,
          viewport: GlobalKey(),
          screenshot: GlobalKey(),
          sourceSize: const Size(4000, 6000),
          viewportSize: const Size(2000, 3000),
          nativeLargeFit: true,
          textureEdgeLowerBound: 8192,
          onPresented: presented.add));
      await _settle(tester, frames: 20);
      expect(delegate.requests, hasLength(1));
      final fit = delegate.requests.single;
      expect(fit.sourceRect, const Rect.fromLTWH(0, 0, 4000, 6000));
      expect((fit.outputWidth, fit.outputHeight), (2000, 3000));
      expect((delegate.actualImages.single.$2, delegate.actualImages.single.$3),
          (2000, 3000));
      expect(presented.last.complete, isTrue);
      expect(presented.last.nativePixels, isFalse);
      final before = delegate.requests.length;
      zoom.value = 1;
      await _settle(tester, frames: 24);
      final upgraded = delegate.requests.skip(before).toList();
      expect(upgraded, isNotEmpty);
      expect(
          upgraded.every((demand) =>
              demand.density == 1 && demand.column >= 0 && demand.row >= 0),
          isTrue);
      expect(presented.last.nativePixels, isTrue);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      zoom.dispose();
      mode.dispose();
    }
    expect(ReaderSurfaceDiagnostics.residentBytes, 0);
    expect(ImageWorkScheduler.shared.reservedBytes, 0);
    expect(ReaderPageFileLease.activeLeaseCount, 0);
  });

  testWidgets('native JPEG larger fit rejects unverified capacity and ICC',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(2000, 3000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    for (final configuration in [
      (false, 8192, false),
      (true, 0, false),
      (true, 2000, false),
      (true, 8192, true),
    ]) {
      final source = _Source('jpeg-guard-${configuration.toString()}');
      final delegate = _Backend();
      final backend =
          _NativeJpegFitBackend(delegate, profile: configuration.$3);
      final zoom = ValueNotifier(0.5);
      final mode = ValueNotifier(ReaderDisplayMode.sharpFirst);
      try {
        await tester.pumpWidget(_harness(
            source: source,
            backend: backend,
            zoom: zoom,
            mode: mode,
            viewport: GlobalKey(),
            screenshot: GlobalKey(),
            sourceSize: const Size(4000, 6000),
            viewportSize: const Size(2000, 3000),
            nativeLargeFit: configuration.$1,
            textureEdgeLowerBound: configuration.$2));
        await _settle(tester, frames: 20);
        expect(delegate.requests, isNotEmpty);
        expect(
            delegate.requests
                .every((demand) => demand.column >= 0 && demand.row >= 0),
            isTrue,
            reason: 'Unadmitted large whole JPEG must retain its grid');
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await _settle(tester);
        zoom.dispose();
        mode.dispose();
      }
    }
    expect(ReaderSurfaceDiagnostics.residentBytes, 0);
    expect(ImageWorkScheduler.shared.reservedBytes, 0);
    expect(ReaderPageFileLease.activeLeaseCount, 0);
  });

  testWidgets('native JPEG larger fit keeps a partial view bounded to its grid',
      (tester) async {
    final delegate = _Backend();
    final zoom = ValueNotifier(0.5);
    final mode = ValueNotifier(ReaderDisplayMode.sharpFirst);
    try {
      await tester.pumpWidget(_harness(
          source: _Source('jpeg-partial-guard'),
          backend: _NativeJpegFitBackend(delegate),
          zoom: zoom,
          mode: mode,
          viewport: GlobalKey(),
          screenshot: GlobalKey(),
          sourceSize: const Size(4000, 6000),
          nativeLargeFit: true,
          textureEdgeLowerBound: 8192));
      await _settle(tester, frames: 20);
      expect(delegate.requests, isNotEmpty);
      expect(
          delegate.requests
              .every((demand) => demand.column >= 0 && demand.row >= 0),
          isTrue);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      zoom.dispose();
      mode.dispose();
    }
  });

  testWidgets(
      'DPR 2.75 native alpha pixels remain exact across tiles and odd edges',
      (tester) async {
    const dpr = 2.75;
    tester.view.devicePixelRatio = dpr;
    tester.view.physicalSize = const Size(1100, 1650);
    final source = _Source('native-alpha-dpr');
    final backend = _Backend()
      ..metadataSize = const Size(8001, 12001)
      ..coordinatePattern = true
      ..alphaPattern = true;
    final zoom = ValueNotifier(1 / dpr);
    final pan = ValueNotifier(const Offset(-3800 / dpr, -5700 / dpr));
    final mode = ValueNotifier(ReaderDisplayMode.sharpFirst);
    final screenshot = GlobalKey();
    final presented = <ReaderPresentedFrame>[];
    try {
      await tester.pumpWidget(_harness(
          source: source,
          backend: backend,
          zoom: zoom,
          pan: pan,
          mode: mode,
          viewport: GlobalKey(),
          screenshot: screenshot,
          sourceSize: const Size(8001, 12001),
          viewportSize: const Size(400 / dpr, 600 / dpr),
          topLeftProjection: true,
          onPresented: presented.add));
      await _settle(tester, frames: 24);
      expect(presented.last.complete, isTrue);
      expect(presented.last.nativePixels, isTrue);
      await _verifyOriginalPixels(tester, screenshot,
          sourceLeft: 3800, sourceTop: 5700, dpr: dpr, alpha: true);
      pan.value = const Offset(-7601 / dpr, -11401 / dpr);
      await _settle(tester, frames: 24);
      expect(presented.last.complete, isTrue);
      expect(presented.last.nativePixels, isTrue);
      await _verifyOriginalPixels(tester, screenshot,
          sourceLeft: 7601, sourceTop: 11401, dpr: dpr, alpha: true);
      expect(source.opens, 1);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      zoom.dispose();
      pan.dispose();
      mode.dispose();
    }
    expect(ReaderSurfaceDiagnostics.residentBytes, 0);
    expect(ImageWorkScheduler.shared.reservedBytes, 0);
    expect(ReaderPageFileLease.activeLeaseCount, 0);
  });

  testWidgets('native bitmap stays filtered when its actual projection shrinks',
      (tester) async {
    final backend = _Backend()..samplingPattern = true;
    final source = _Source('native-projection-shrinks');
    final zoom = ValueNotifier(0.9);
    final pan = ValueNotifier(const Offset(-3800.2, -5700.2));
    final mode = ValueNotifier(ReaderDisplayMode.sharpFirst);
    final screenshot = GlobalKey();
    try {
      await tester.pumpWidget(_harness(
          source: source,
          backend: backend,
          zoom: zoom,
          pan: pan,
          mode: mode,
          viewport: GlobalKey(),
          screenshot: screenshot,
          viewportSize: const Size(64, 64),
          topLeftProjection: true));
      await _settle(tester, frames: 24);
      expect(backend.requests.every((demand) => demand.density == 1), isTrue);
      final boundary = screenshot.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
      final image =
          (await tester.runAsync(() => boundary.toImage(pixelRatio: 1)))!;
      try {
        final data = (await tester.runAsync(
            () => image.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
        final bytes = data.buffer.asUint8List();
        var interpolated = 0;
        for (var i = 0; i < bytes.length; i += 4) {
          if (bytes[i] > 0 && bytes[i] < 255) interpolated++;
        }
        expect(interpolated, greaterThan(0),
            reason:
                'a density1 tile projected below 1:1 must retain filtering');
      } finally {
        image.dispose();
      }
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      zoom.dispose();
      pan.dispose();
      mode.dispose();
    }
  });

  testWidgets('rotated native pixels keep filtering even above physical 1:1',
      (tester) async {
    final backend = _Backend()
      ..metadataSize = const Size(80, 80)
      ..samplingPattern = true;
    final source = _Source('native-rotated-projection');
    final zoom = ValueNotifier(1.2);
    final mode = ValueNotifier(ReaderDisplayMode.sharpFirst);
    final screenshot = GlobalKey();
    try {
      await tester.pumpWidget(_harness(
          source: source,
          backend: backend,
          zoom: zoom,
          mode: mode,
          viewport: GlobalKey(),
          screenshot: screenshot,
          sourceSize: const Size(80, 80),
          viewportSize: const Size(64, 64),
          rotation: 0.12));
      await _settle(tester, frames: 20);
      expect(backend.requests.every((demand) => demand.density == 1), isTrue);
      final boundary = screenshot.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
      final image =
          (await tester.runAsync(() => boundary.toImage(pixelRatio: 1)))!;
      try {
        final data = (await tester.runAsync(
            () => image.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
        final bytes = data.buffer.asUint8List();
        var interpolated = 0;
        for (var i = 0; i < bytes.length; i += 4) {
          if (bytes[i] > 0 && bytes[i] < 255) interpolated++;
        }
        expect(interpolated, greaterThan(0),
            reason: 'non-axis-aligned native pixels must retain filtering');
      } finally {
        image.dispose();
      }
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      zoom.dispose();
      mode.dispose();
    }
    expect(ReaderSurfaceDiagnostics.residentBytes, 0);
    expect(ImageWorkScheduler.shared.reservedBytes, 0);
    expect(ReaderPageFileLease.activeLeaseCount, 0);
  });

  testWidgets(
      'resolved original skips reopening and remains leased until disposal',
      (tester) async {
    final original = File('${root.path}/resolved-file')
      ..writeAsBytesSync([1, 2, 3]);
    final source = _Source('resolved-once');
    final metadata = await _Backend().probe(original);
    final resolved = ReaderResolvedOriginal(
        source: source,
        file: original,
        metadata: metadata,
        fileSnapshot: original.statSync());
    final backend = _Backend();
    final zoom = ValueNotifier(0.05);
    final mode = ValueNotifier(ReaderDisplayMode.sharpFirst);
    try {
      await tester.pumpWidget(_harness(
          source: source,
          backend: backend,
          zoom: zoom,
          mode: mode,
          viewport: GlobalKey(),
          screenshot: GlobalKey(),
          resolvedOriginal: resolved));
      await _settle(tester);
      expect(source.opens, 0);
      expect(backend.requests, isNotEmpty);
      var drained = false;
      unawaited(ReaderPageFileLease.waitForDrain(original)
          .then((_) => drained = true));
      await _settle(tester);
      expect(drained, isFalse,
          reason:
              'opened original remains alive even when no decoder is running');
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      expect(drained, isTrue);
      expect(ReaderPageFileLease.activeLeaseCount, 0);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      zoom.dispose();
      mode.dispose();
    }
  });

  testWidgets('resolved source identity mismatch is rejected before decoding',
      (tester) async {
    final file = File('${root.path}/identity-file')
      ..writeAsBytesSync([1, 2, 3]);
    final oldSource = _Source('old-identity');
    final current = _Source('new-identity');
    final backend = _Backend();
    final metadata = await backend.probe(file);
    final resolved = ReaderResolvedOriginal(
        source: oldSource,
        file: file,
        metadata: metadata,
        fileSnapshot: file.statSync());
    final zoom = ValueNotifier(0.05);
    final mode = ValueNotifier(ReaderDisplayMode.sharpFirst);
    try {
      await tester.pumpWidget(_harness(
          source: current,
          backend: backend,
          zoom: zoom,
          mode: mode,
          viewport: GlobalKey(),
          screenshot: GlobalKey(),
          resolvedOriginal: resolved));
      await _settle(tester);
      expect(current.opens, 0);
      expect(backend.requests, isEmpty);
      expect(ReaderSurfaceDiagnostics.snapshot().single['error'],
          contains('no longer matches'));
      expect(find.text('图片暂时无法显示，请重试或重新打开此页'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      zoom.dispose();
      mode.dispose();
    }
  });

  testWidgets(
      'source replacement during a resolved decode cannot publish old metadata pixels',
      (tester) async {
    final file = File('${root.path}/replaced-file')
      ..writeAsBytesSync([1, 2, 3]);
    final source = _Source('changed-version');
    final backend = _Backend()..hold = true;
    final metadata = await backend.probe(file);
    final resolved = ReaderResolvedOriginal(
        source: source,
        file: file,
        metadata: metadata,
        fileSnapshot: file.statSync());
    final zoom = ValueNotifier(0.05);
    final mode = ValueNotifier(ReaderDisplayMode.sharpFirst);
    try {
      await tester.pumpWidget(_harness(
          source: source,
          backend: backend,
          zoom: zoom,
          mode: mode,
          viewport: GlobalKey(),
          screenshot: GlobalKey(),
          resolvedOriginal: resolved));
      await _settle(tester);
      expect(backend.gates, isNotEmpty);
      await tester.runAsync(() => file.writeAsBytes([3, 2, 1, 4]));
      backend.releaseHeld();
      await _settle(tester);
      expect(ReaderSurfaceDiagnostics.residentBytes, 0);
      expect(ReaderSurfaceDiagnostics.snapshot().single['error'],
          contains('changed after'));
    } finally {
      backend.releaseHeld();
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      zoom.dispose();
      mode.dispose();
    }
    expect(ReaderPageFileLease.activeLeaseCount, 0);
    expect(ImageWorkScheduler.shared.reservedBytes, 0);
  });

  for (final scenario in [
    'warm',
    'miss',
    'source-change',
    'cancel',
    'default'
  ]) {
    testWidgets(
        'prepared admission $scenario keeps separate source and budget ownership',
        (tester) async {
      final original = File('${root.path}/prepared-admission-$scenario')
        ..writeAsBytesSync([1, 2, 3]);
      final source = _Source('prepared-admission-$scenario');
      final backend = _PreparedAdmissionBackend()
        ..metadataSize = const Size(400, 400)
        ..miss = scenario == 'miss' || scenario == 'source-change';
      if (scenario == 'source-change') {
        backend.beforeMiss = () => original.writeAsBytesSync([3, 2, 1, 4]);
      }
      if (scenario == 'cancel') backend.preparedGate = Completer<void>();
      final metadata = await backend.probe(original);
      final resolved = ReaderResolvedOriginal(
          source: source,
          file: original,
          metadata: metadata,
          fileSnapshot: original.statSync());
      final zoom = ValueNotifier(1.0);
      final mode = ValueNotifier(ReaderDisplayMode.sharpFirst);
      try {
        await tester.pumpWidget(_harness(
            source: source,
            backend: backend,
            zoom: zoom,
            mode: mode,
            viewport: GlobalKey(),
            screenshot: GlobalKey(),
            sourceSize: const Size(400, 400),
            viewportSize: const Size(400, 400),
            preparedReadAdmission: scenario != 'default',
            resolvedOriginal: resolved));
        await _settle(tester);
        if (scenario == 'cancel') {
          expect(backend.preparedReads, 1);
          expect(ImageWorkScheduler.shared.reservedBytes, greaterThan(0));
          await tester.pumpWidget(const SizedBox.shrink());
          backend.preparedGate!.complete();
          await _settle(tester);
          expect(backend.estimates, 0);
          expect(backend.coldReads, 0);
        } else if (scenario == 'source-change') {
          expect(backend.preparedReads, 1);
          expect(backend.estimates, 0);
          expect(backend.coldReads, 0);
          expect(ReaderSurfaceDiagnostics.residentBytes, 0);
          expect(ReaderSurfaceDiagnostics.snapshot().single['error'],
              contains('changed after'));
        } else if (scenario == 'warm') {
          expect(backend.preparedReads, 1);
          expect(backend.estimates, 0);
          expect(backend.coldReads, 0);
          expect(backend.memoryBudgets, [32 << 20]);
          expect(backend.metadataAtAdmission, [same(metadata)]);
          expect(ReaderSurfaceDiagnostics.residentBytes, 400 * 400 * 4);
        } else {
          expect(backend.preparedReads, scenario == 'miss' ? 1 : 0);
          expect(backend.estimates, 1);
          expect(backend.coldReads, 1);
          expect(backend.reservationsAtEstimate, [0],
              reason:
                  'Old warm job reservation must be released before cold estimate');
          expect(backend.leaseCountsAtEstimate.single, greaterThan(0));
          expect(backend.memoryBudgets,
              scenario == 'miss' ? [32 << 20, 64 << 20] : [64 << 20]);
        }
      } finally {
        if (backend.preparedGate?.isCompleted == false) {
          backend.preparedGate!.complete();
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await _settle(tester);
        zoom.dispose();
        mode.dispose();
      }
      expect(ReaderPageFileLease.activeLeaseCount, 0);
      expect(ImageWorkScheduler.shared.reservedBytes, 0);
      expect(ImageWorkScheduler.shared.activeCount, 0);
      expect(ReaderSurfaceDiagnostics.residentBytes, 0);
    });
  }

  for (final exit in ['acceptance', 'cancel']) {
    final disposeDuringWait = exit == 'cancel';
    testWidgets(
        'simultaneous completed tiles keep budget until eviction and $exit',
        (tester) async {
      TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
          .physicalSize = const Size(4096, 4096);
      final backend = _Backend()..metadataSize = const Size(4096, 4096);
      final zoom = ValueNotifier(1.0);
      final mode = ValueNotifier(ReaderDisplayMode.sharpFirst);
      final tilePixels = ValueNotifier(2048);
      try {
        await tester.pumpWidget(_harness(
            source: _Source('pending-budget-$disposeDuringWait'),
            backend: backend,
            zoom: zoom,
            mode: mode,
            tilePixels: tilePixels,
            viewport: GlobalKey(),
            screenshot: GlobalKey(),
            sourceSize: const Size(4096, 4096),
            viewportSize: const Size(4096, 4096)));
        await _settle(tester, frames: 24);
        expect(backend.actualImages, hasLength(4));
        expect(ReaderSurfaceDiagnostics.residentBytes, 64 << 20);
        backend.hold = true;
        tilePixels.value = 1024;
        await _settle(tester);
        expect(backend.gates, hasLength(2));
        backend.gates[0].complete();
        backend.gates[1].complete();
        await tester.runAsync(() async {
          for (var i = 0; i < 150 && backend.actualImages.length < 6; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 2));
          }
        });
        expect(backend.actualImages, hasLength(6));
        expect(ImageWorkScheduler.shared.reservedBytes, greaterThan(0),
            reason:
                'the first returned tile waits for the retired paint frame');
        expect(
            ReaderSurfaceDiagnostics.residentBytes +
                ReaderSurfaceDiagnostics.pendingBytes,
            lessThanOrEqualTo(192 << 20));
        backend.releaseHeld();
        if (disposeDuringWait) {
          await tester.pumpWidget(const SizedBox.shrink());
        }
        await _settle(tester, frames: 32);
        if (!disposeDuringWait) {
          expect(ReaderSurfaceDiagnostics.residentBytes, 64 << 20);
          expect(ReaderSurfaceDiagnostics.pendingBytes, 0);
          expect(backend.decodedImages.take(4).every((i) => i.debugDisposed),
              isTrue);
        }
      } finally {
        backend.releaseHeld();
        await tester.pumpWidget(const SizedBox.shrink());
        await _settle(tester);
        zoom.dispose();
        mode.dispose();
        tilePixels.dispose();
      }
      expect(backend.decodedImages.every((i) => i.debugDisposed), isTrue);
      expect(ReaderSurfaceDiagnostics.residentBytes, 0);
      expect(ReaderSurfaceDiagnostics.pendingBytes, 0);
      expect(ReaderPageFileLease.activeLeaseCount, 0);
      expect(ImageWorkScheduler.shared.reservedBytes, 0);
    });
  }

  testWidgets('backing touch failure disposes a successfully decoded image',
      (tester) async {
    final overrides = _TouchFailureOverrides();
    final backend = _MaintenanceFailureBackend();
    final zoom = ValueNotifier(0.05);
    final mode = ValueNotifier(ReaderDisplayMode.sharpFirst);
    final savedOverrides = IOOverrides.current;
    IOOverrides.global = overrides;
    try {
      await tester.pumpWidget(_harness(
          source: _Source('maintenance-failure'),
          backend: backend,
          zoom: zoom,
          mode: mode,
          viewport: GlobalKey(),
          screenshot: GlobalKey()));
      await _settle(tester, frames: 60);
      expect(backend.requests, hasLength(1),
          reason: '${ReaderSurfaceDiagnostics.snapshot()} '
              '${ImageDiskQuota.shared.operationStage}');
      expect(backend.created, isNotNull);
      expect(overrides.touches, 1);
      expect(backend.created!.debugDisposed, isTrue);
      expect(ReaderSurfaceDiagnostics.residentBytes, 0);
      expect(ReaderSurfaceDiagnostics.snapshot().single['error'],
          contains('Injected backing touch failure'));
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      IOOverrides.global = savedOverrides;
      zoom.dispose();
      mode.dispose();
    }
    expect(ReaderPageFileLease.activeLeaseCount, 0);
    expect(ImageWorkScheduler.shared.reservedBytes, 0);
  });

  test('remote raster placeholder cannot be handed off as an original file',
      () async {
    final file = File('${root.path}/remote-model')..writeAsBytesSync([1]);
    expect(
        () => ReaderResolvedOriginal(
            source: _RemoteLocator(),
            file: file,
            metadata: const ReaderRasterMetadata(
                size: Size(8000, 12000),
                animated: false,
                format: 'fake',
                workingBytes: 1),
            fileSnapshot: file.statSync()),
        throwsArgumentError);
    expect(ReaderPageFileLease.activeLeaseCount, 0);
  });
}

Future<void> _verifyGrid(
    int tilePixels,
    WidgetTester tester,
    GlobalKey screenshot,
    List<ReaderPresentedFrame> presented,
    _Backend backend) async {
  final frame = presented.last;
  expect(frame.complete, isTrue);
  expect(frame.nativePixels, isTrue);
  expect(frame.density, 1);
  expect(frame.sourceRect, const Rect.fromLTWH(3800, 5700, 400, 600));
  final surface = ReaderSurfaceDiagnostics.snapshot().single;
  final desired = (surface['desired'] as List).cast<String>().toSet();
  final resident = (surface['residentVariants'] as List).cast<String>().toSet();
  expect(resident, desired, reason: 'no old grid image remains resident');
  expect(surface['ticketVariants'], isEmpty);
  expect(surface['estimating'], isEmpty);
  final expected = ReaderViewportDemand(
          visibleSourceRect: frame.sourceRect, physicalPixelsPerSourcePixel: 1)
      .tiles(const Size(8000, 12000), tilePixels: tilePixels);
  expect(desired, expected.map((demand) => demand.variant).toSet());
  for (final demand in expected) {
    final actual = backend.actualImages
        .lastWhere((image) => image.$1.variant == demand.variant);
    expect((actual.$2, actual.$3), (demand.outputWidth, demand.outputHeight));
  }
  await _verifyOriginalPixels(tester, screenshot,
      sourceLeft: 3800, sourceTop: 5700);
}

Future<void> _verifyOriginalPixels(WidgetTester tester, GlobalKey screenshot,
    {required int sourceLeft,
    required int sourceTop,
    double dpr = 1,
    bool alpha = false}) async {
  final boundary =
      screenshot.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  // Keep an integer capture extent at DPR2.75 without changing sampling.
  final image = (await tester.runAsync(() => dpr == 1
      ? boundary.toImage(pixelRatio: dpr)
      : (boundary as _PixelCaptureRenderObject).captureNativePixels(dpr)))!;
  ui.Image? reference;
  try {
    expect((image.width, image.height), (400, 600));
    final data = (await tester
        .runAsync(() => image.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
    final bytes =
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    if (alpha) {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawColor(Colors.black, BlendMode.src);
      for (var y = (sourceTop ~/ 8) * 8; y < sourceTop + 600; y += 8) {
        for (var x = (sourceLeft ~/ 8) * 8; x < sourceLeft + 400; x += 8) {
          canvas.drawRect(
              Rect.fromLTWH((x - sourceLeft).toDouble(),
                  (y - sourceTop).toDouble(), 8, 8),
              Paint()..color = _coordinateColor(x, y, true));
        }
      }
      final picture = recorder.endRecording();
      try {
        reference = picture.toImageSync(400, 600);
        final expected = (await tester.runAsync(
            () => reference!.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
        final referenceBytes = expected.buffer.asUint8List();
        var different = 0;
        for (var i = 0; i < bytes.length; i += 4) {
          if (bytes[i] != referenceBytes[i] ||
              bytes[i + 1] != referenceBytes[i + 1] ||
              bytes[i + 2] != referenceBytes[i + 2] ||
              bytes[i + 3] != referenceBytes[i + 3]) {
            different++;
          }
        }
        expect(different, 0,
            reason: 'all 240000 original alpha pixels must be exact on black');
      } finally {
        picture.dispose();
      }
      return;
    }
    var mismatches = 0;
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        final sourceX = (sourceLeft + x) ~/ 8;
        final sourceY = (sourceTop + y) ~/ 8;
        final offset = (y * image.width + x) * 4;
        if (bytes[offset] != (sourceX & 255) ||
            bytes[offset + 1] != (sourceY & 255) ||
            bytes[offset + 2] != ((sourceX ^ sourceY) & 255) ||
            bytes[offset + 3] != 255) {
          mismatches++;
        }
      }
    }
    expect(mismatches, 0,
        reason: 'every one of the 240000 original viewport pixels must match');
  } finally {
    reference?.dispose();
    image.dispose();
  }
}

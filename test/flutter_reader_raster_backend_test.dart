import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/image_pipeline/image_work_scheduler.dart';
import 'package:picakeep/foundation/image_pipeline/reader_raster_backend.dart';
import 'package:picakeep/foundation/image_pipeline/reader_viewport.dart';

class _FailPublishFile implements File {
  _FailPublishFile(this.delegate);
  final File delegate;
  bool failPublish = false;
  @override
  String get path {
    if (failPublish) {
      throw const FileSystemException('Injected raster publication failure');
    }
    return delegate.path;
  }

  @override
  Future<FileStat> stat() => delegate.stat();
  @override
  Future<int> length() => delegate.length();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<File> _makeOddPng(Directory directory) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawColor(const ui.Color(0x00000000), ui.BlendMode.src);
  for (var y = 0; y < 5; y++) {
    for (var x = 0; x < 7; x++) {
      final alpha = ((x + y) % 3 == 0) ? 0x80 : 0xff;
      final color = ui.Color.fromARGB(alpha, 17 * x, 29 * y, 41 + x * 3);
      canvas.drawRect(ui.Rect.fromLTWH(x.toDouble(), y.toDouble(), 1, 1),
          ui.Paint()..color = color);
    }
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(7, 5);
  picture.dispose();
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) throw StateError('PNG encoding returned no bytes');
    final file = File('${directory.path}/odd-alpha.png');
    await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
    return file;
  } finally {
    image.dispose();
  }
}

Future<Uint8List> _rgba(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (data == null) throw StateError('RGBA conversion returned no bytes');
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

class _NativeProbe extends ReaderRasterBackend {
  final requests = <ReaderTileDemand>[];
  @override
  Future<ReaderRasterMetadata> probe(File file) async =>
      const ReaderRasterMetadata(
          size: ui.Size(7, 5),
          animated: false,
          format: 'png',
          workingBytes: 140);
  @override
  Future<int> estimateWorkingBytes(File file, ReaderTileDemand demand,
          {required String backingPath}) async =>
      1;
  @override
  Future<ui.Image> decode(File file, ReaderTileDemand demand,
      {required String backingPath,
      required int memoryBudgetBytes,
      required bool Function() isCancelled,
      Future<void>? cancelled}) async {
    requests.add(demand);
    if (isCancelled()) throw const ImageWorkCancelled();
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawColor(const ui.Color(0xff123456), ui.BlendMode.src);
    final picture = recorder.endRecording();
    try {
      return await picture.toImage(demand.outputWidth, demand.outputHeight);
    } finally {
      picture.dispose();
    }
  }
}

Future<Directory> _testDirectory() async {
  final parent = Platform.isWindows
      ? Directory(r'E:\picakeep-image-pipeline-022-work')
      : Directory.systemTemp;
  await parent.create(recursive: true);
  return parent.createTemp('reader-raster-');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Flutter backend disposes its raster when persistence setup throws',
      () async {
    final directory = await _testDirectory();
    addTearDown(() => directory.delete(recursive: true));
    App.dataPath = directory.path;
    App.cachePath = '${directory.path}/cache';
    final file = _FailPublishFile(await _makeOddPng(directory));
    final images = <ui.Image>[];
    final savedOnCreate = ui.Image.onCreate;
    ui.Image.onCreate = (image) {
      images.add(image);
      file.failPublish = true;
    };
    try {
      await expectLater(
          const FlutterReaderRasterBackend(ReaderRasterMetadata(
                  size: ui.Size(7, 5),
                  animated: false,
                  format: 'png',
                  workingBytes: 140))
              .decode(
                  file,
                  const ReaderTileDemand(
                      ui.Rect.fromLTWH(0, 0, 7, 5), 1, -1, -1),
                  backingPath: 'unused',
                  memoryBudgetBytes: 64 << 20,
                  isCancelled: () => false),
          throwsA(isA<FileSystemException>()));
      expect(images, hasLength(1));
      expect(images.single.debugDisposed, isTrue);
    } finally {
      ui.Image.onCreate = savedOnCreate;
    }
  });

  test('Flutter raster backend keeps odd source geometry and crop pixels',
      () async {
    final directory = await _testDirectory();
    addTearDown(() => directory.delete(recursive: true));
    final file = await _makeOddPng(directory);
    const metadata = ReaderRasterMetadata(
        size: ui.Size(7, 5),
        animated: false,
        format: 'png',
        workingBytes: 7 * 5 * 4);
    const backend = FlutterReaderRasterBackend(metadata, persistRaster: false);

    final full = await backend.decode(
        file, const ReaderTileDemand(ui.Rect.fromLTWH(0, 0, 7, 5), 1, -1, -1),
        backingPath: 'unused',
        memoryBudgetBytes: 64 << 20,
        isCancelled: () => false);
    addTearDown(full.dispose);
    expect(full.width, 7);
    expect(full.height, 5);

    final crop = await backend.decode(
        file, const ReaderTileDemand(ui.Rect.fromLTWH(1, 1, 3, 2), 1, -1, -1),
        backingPath: 'unused',
        memoryBudgetBytes: 64 << 20,
        isCancelled: () => false);
    addTearDown(crop.dispose);
    expect(crop.width, 3);
    expect(crop.height, 2);
    final fullRgba = await _rgba(full);
    final cropRgba = await _rgba(crop);
    for (var y = 0; y < 2; y++) {
      for (var x = 0; x < 3; x++) {
        final source = ((y + 1) * 7 + (x + 1)) * 4;
        final output = (y * 3 + x) * 4;
        expect(cropRgba.sublist(output, output + 4),
            fullRgba.sublist(source, source + 4),
            reason: 'source crop changed pixel ($x,$y)');
      }
    }

    const gutteredDemand = ReaderTileDemand(
        ui.Rect.fromLTWH(1, 1, 3, 2), 1, 0, 0,
        rasterRect: ui.Rect.fromLTWH(0, 0, 5, 4));
    const colorManagedBackend = FlutterReaderRasterBackend(
        ReaderRasterMetadata(
            size: ui.Size(7, 5),
            animated: false,
            format: 'png',
            workingBytes: 140,
            hasColorProfile: true),
        persistRaster: false);
    final guttered = await colorManagedBackend.decode(file, gutteredDemand,
        backingPath: 'unused',
        memoryBudgetBytes: 64 << 20,
        isCancelled: () => false);
    addTearDown(guttered.dispose);
    expect((guttered.width, guttered.height), (5, 4));
    final gutteredRgba = await _rgba(guttered);
    for (var y = 0; y < 4; y++) {
      for (var x = 0; x < 5; x++) {
        final source = (y * 7 + x) * 4;
        final output = (y * 5 + x) * 4;
        expect(gutteredRgba.sublist(output, output + 4),
            fullRgba.sublist(source, source + 4),
            reason: 'sampling gutter changed source pixel ($x,$y)');
      }
    }
  });

  test('Flutter raster backend cancellation does not publish an image',
      () async {
    final directory = await _testDirectory();
    addTearDown(() => directory.delete(recursive: true));
    final file = await _makeOddPng(directory);
    const backend = FlutterReaderRasterBackend(
        ReaderRasterMetadata(
            size: ui.Size(7, 5),
            animated: false,
            format: 'png',
            workingBytes: 140),
        persistRaster: false);
    await expectLater(
        backend.decode(file,
            const ReaderTileDemand(ui.Rect.fromLTWH(0, 0, 7, 5), 1, -1, -1),
            backingPath: 'unused',
            memoryBudgetBytes: 64 << 20,
            isCancelled: () => true),
        throwsA(isA<ImageWorkCancelled>()));
  });

  test('bounded PNG fit keeps exact odd alpha output from the original codec',
      () async {
    final directory = await _testDirectory();
    addTearDown(() => directory.delete(recursive: true));
    final file = await _makeOddPng(directory);
    const metadata = ReaderRasterMetadata(
        size: ui.Size(7, 5), animated: false, format: 'png', workingBytes: 140);
    const demand = ReaderTileDemand(ui.Rect.fromLTWH(0, 0, 7, 5), 0.5, -1, -1);
    const backend = BoundedPngFitReaderRasterBackend(metadata,
        textureEdgeLowerBound: 8192, persistRaster: false);
    final working =
        await backend.estimateWorkingBytes(file, demand, backingPath: 'unused');
    final actual = await backend.decode(file, demand,
        backingPath: 'unused',
        memoryBudgetBytes: working,
        isCancelled: () => false);
    addTearDown(actual.dispose);
    final buffer = await ui.ImmutableBuffer.fromFilePath(file.path);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final codec =
        await descriptor.instantiateCodec(targetWidth: 4, targetHeight: 3);
    ui.Image? reference;
    try {
      reference = (await codec.getNextFrame()).image;
      expect((actual.width, actual.height), (4, 3));
      expect(actual.colorSpace, ui.ColorSpace.sRGB);
      expect(await _rgba(actual), await _rgba(reference),
          reason: 'bounded fit must remain a sample of the exact original');
    } finally {
      reference?.dispose();
      codec.dispose();
      descriptor.dispose();
      buffer.dispose();
    }
  });

  test('bounded PNG native zoom and an unverified texture use native decoding',
      () async {
    final directory = await _testDirectory();
    addTearDown(() => directory.delete(recursive: true));
    final file = await _makeOddPng(directory);
    const metadata = ReaderRasterMetadata(
        size: ui.Size(7, 5), animated: false, format: 'png', workingBytes: 140);
    final native = _NativeProbe();
    final verified = BoundedPngFitReaderRasterBackend(metadata,
        textureEdgeLowerBound: 8192,
        persistRaster: false,
        nativeBackend: native);
    final missing = BoundedPngFitReaderRasterBackend(metadata,
        textureEdgeLowerBound: 0, persistRaster: false, nativeBackend: native);
    const roi = ReaderTileDemand(ui.Rect.fromLTWH(1, 1, 3, 2), 1, 0, 0);
    const fit = ReaderTileDemand(ui.Rect.fromLTWH(0, 0, 7, 5), 0.5, -1, -1);
    for (final request in [(verified, roi), (missing, fit)]) {
      final image = await request.$1.decode(file, request.$2,
          backingPath: 'unused',
          memoryBudgetBytes: 1024,
          isCancelled: () => false);
      try {
        final raw = await _rgba(image);
        expect(raw.sublist(0, 4), [0x12, 0x34, 0x56, 255]);
      } finally {
        image.dispose();
      }
    }
    expect(native.requests, [roi, fit]);
  });

  test('bounded PNG refuses an insufficient budget before starting its codec',
      () async {
    final directory = await _testDirectory();
    addTearDown(() => directory.delete(recursive: true));
    final file = await _makeOddPng(directory);
    const backend = BoundedPngFitReaderRasterBackend(
        ReaderRasterMetadata(
            size: ui.Size(7, 5),
            animated: false,
            format: 'png',
            workingBytes: 140),
        textureEdgeLowerBound: 8192,
        persistRaster: false);
    const fit = ReaderTileDemand(ui.Rect.fromLTWH(0, 0, 7, 5), 0.5, -1, -1);
    final working =
        await backend.estimateWorkingBytes(file, fit, backingPath: 'unused');
    await expectLater(
        backend.decode(file, fit,
            backingPath: 'unused',
            memoryBudgetBytes: working - 1,
            isCancelled: () => false),
        throwsA(isA<ImageWorkBudgetExceeded>()));
  });

  test('bounded PNG excludes non-ICC color chunks before any whole codec',
      () async {
    final directory = await _testDirectory();
    addTearDown(() => directory.delete(recursive: true));
    final original = await _makeOddPng(directory);
    final bytes = await original.readAsBytes();
    // Inject a cHRM chunk after IHDR. Native metadata only flags ICC, so the
    // explicit candidate must inspect this before trusting its RGBA8 estimate.
    final chunk = Uint8List(44);
    chunk[3] = 32;
    chunk.setRange(4, 8, 'cHRM'.codeUnits);
    final file = File('${directory.path}/non-icc-color.png');
    await file.writeAsBytes([...bytes.take(33), ...chunk, ...bytes.skip(33)]);
    const backend = BoundedPngFitReaderRasterBackend(
        ReaderRasterMetadata(
            size: ui.Size(7, 5),
            animated: false,
            format: 'png',
            workingBytes: 140),
        textureEdgeLowerBound: 8192,
        persistRaster: false);
    await expectLater(
        backend.decode(file,
            const ReaderTileDemand(ui.Rect.fromLTWH(0, 0, 7, 5), 0.5, -1, -1),
            backingPath: 'unused',
            memoryBudgetBytes: 64 << 20,
            isCancelled: () => false),
        throwsA(isA<StateError>().having((error) => error.message, 'message',
            contains('color/orientation'))));
  });
}

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/image_pipeline/derived_image_store.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';
import 'package:picakeep/foundation/image_pipeline/reader_raster_backend.dart';
import 'package:picakeep/foundation/image_pipeline/reader_raster_cache.dart';
import 'package:picakeep/foundation/image_pipeline/reader_viewport.dart';

// Same sRGB ICC profile as the fixed 022 fixtures; image pixels are generated
// here so the regression does not depend on an external fixture drive.
const _srgbIcc =
    'c1JHQgAAKJF1kTtLA0EUhb9EQ8REUmghYrFFFAsFUVBLiWAatUgi+GqSNQ8hmyy7CRJsBRsLwUK08VX4D7QVbBUEQRFErC19NRLWO0kgQZJZZu/HmTmXu2fBPZfVDbt9GoxcwYqEQ9rS8ormfacTDz4mCcZ125yPzsZouX4ecan6MKJ6tb7XdPnWk7YOrg7hCd20CsIyDXObBVPxrnCPnomvC58ID1syoPCt0hNVflOcrvKXYisWmQG36qmlGzjRwHrGMoSHhINGtqjX5lFf4k/mFqNS+2T3YxMhTAiNBEU2yFJgRGpOMmvuG634FsiLR5e3SQlLHGky4h0WtShdk1JToiflyVJSuf/P006Nj1W7+0PgeXWczwHw7kN5z3F+Tx2nfAZtL3Cdq/vzktPUt+h7dS14DIFtuLypa4kDuNqB3mczbsUrUptsdyoFHxfQtQzd99C5Ws2qds75E8S25BfdweERDMr9wNofU2xoMA==';

Uint8List _png16({required bool grayscale, bool icc = true}) {
  const width = 67, height = 73;
  final channels = grayscale ? 2 : 4;
  final rowBytes = width * channels * 2 + 1;
  final pixels = ByteData(rowBytes * height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final offset = y * rowBytes + 1 + x * channels * 2;
      final gray = (x * 883 + y * 499 + 127) & 0xffff;
      final alpha = (x * 997 + y * 811 + 13) & 0xffff;
      final values = grayscale
          ? [gray, alpha]
          : [gray, (x * 491 + y * 1301) & 0xffff, 32769, alpha];
      for (var channel = 0; channel < channels; channel++) {
        pixels.setUint16(offset + channel * 2, values[channel]);
      }
    }
  }
  final result = BytesBuilder(copy: false)
    ..add([137, 80, 78, 71, 13, 10, 26, 10]);
  void chunk(String type, List<int> data) {
    final payload = Uint8List.fromList([...ascii.encode(type), ...data]);
    var crc = 0xffffffff;
    for (final value in payload) {
      crc ^= value;
      for (var bit = 0; bit < 8; bit++) {
        crc = crc & 1 != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
      }
    }
    final length = ByteData(4)..setUint32(0, data.length);
    final checksum = ByteData(4)..setUint32(0, crc ^ 0xffffffff);
    result
      ..add(length.buffer.asUint8List())
      ..add(payload)
      ..add(checksum.buffer.asUint8List());
  }

  final header = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 16)
    ..setUint8(9, grayscale ? 4 : 6);
  chunk('IHDR', header.buffer.asUint8List());
  if (icc) chunk('iCCP', base64Decode(_srgbIcc));
  chunk('IDAT', ZLibEncoder().convert(pixels.buffer.asUint8List()));
  chunk('IEND', const []);
  return result.takeBytes();
}

Future<ui.Image> _decodeOriginal(File file) async {
  final buffer = await ui.ImmutableBuffer.fromFilePath(file.path);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    codec = await descriptor.instantiateCodec();
    return (await codec.getNextFrame()).image;
  } finally {
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}

Future<Uint8List> _blackRoi(ui.Image image, ui.Rect source) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder)
    ..drawColor(const ui.Color(0xff000000), ui.BlendMode.src)
    ..translate(-source.left, -source.top)
    ..drawImage(image, ui.Offset.zero,
        ui.Paint()..filterQuality = ui.FilterQuality.none);
  final picture = recorder.endRecording();
  ui.Image? output;
  try {
    output = await picture.toImage(source.width.toInt(), source.height.toInt());
    final bytes = await output.toByteData(format: ui.ImageByteFormat.rawRgba);
    return Uint8List.fromList(
        bytes!.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes));
  } finally {
    output?.dispose();
    picture.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final grayscale in [false, true]) {
    test('integer 16-bit ${grayscale ? 'gray' : 'RGB'} ICC alpha crop is exact',
        () async {
      final directory = await Directory.systemTemp.createTemp('022-precision-');
      addTearDown(() => directory.delete(recursive: true));
      final encoded = _png16(grayscale: grayscale);
      final file = File('${directory.path}/source.png');
      await file.writeAsBytes(encoded, flush: true);
      const metadata = ReaderRasterMetadata(
          size: ui.Size(67, 73),
          animated: false,
          format: 'png',
          workingBytes: 67 * 73 * 12,
          bitDepth: 16,
          hasColorProfile: true);
      final original = await _decodeOriginal(file);
      addTearDown(original.dispose);
      const source = ui.Rect.fromLTWH(5, 7, 53, 59);
      final crop =
          await const FlutterReaderRasterBackend(metadata, persistRaster: false)
              .decode(file, const ReaderTileDemand(source, 1, 0, 0),
                  backingPath: 'unused',
                  memoryBudgetBytes: 64 << 20,
                  isCancelled: () => false);
      addTearDown(crop.dispose);
      expect([crop.width, crop.height], [53, 59]);
      expect(await _blackRoi(crop, const ui.Rect.fromLTWH(0, 0, 53, 59)),
          orderedEquals(await _blackRoi(original, source)));
      expect(await file.readAsBytes(), orderedEquals(encoded));
    });
  }
  test('Flutter crop rejects a persisted raster from the previous sampler',
      () async {
    // The derived PNG filename contains two SHA-256 hashes. Flutter's Windows
    // file codec can reject its path when a long full-suite TEMP pushes it
    // beyond MAX_PATH. Keep this fixture short without changing production.
    final directory =
        await (Platform.isWindows ? Directory.current : Directory.systemTemp)
            .createTemp('.pkc-');
    addTearDown(() => directory.delete(recursive: true));
    App.dataPath = directory.path;
    App.cachePath = '${directory.path}/cache';
    final oldQuota = ImageDiskQuota.overrideForTesting;
    ImageDiskQuota.overrideForTesting = ImageDiskQuota(
        roots: () => [App.cachePath],
        idleLimitBytes: () => 512 << 20,
        space: (_) async => const ImageDiskSpace(100 << 30, 'precision-test'));
    addTearDown(() async {
      await ReaderRasterCache.drain();
      ImageDiskQuota.overrideForTesting = oldQuota;
    });
    final file = File('${directory.path}/source.png');
    await file.writeAsBytes(_png16(grayscale: false, icc: false), flush: true);
    const source = ui.Rect.fromLTWH(5, 7, 53, 59);
    const demand = ReaderTileDemand(source, 1, -1, -1);
    final oldIdentity = await ReaderRasterCache.capture(file, demand,
        pixelVersion: 'flutter-srgb-rgba8-adaptive-v2');
    final store = DerivedImageStore(
        '${App.dataPath}/cache/image_pipeline_v1/local_reader');
    addTearDown(store.dispose);
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const ui.Color(0xffff00ff), ui.BlendMode.src);
    final picture = recorder.endRecording();
    final obsolete = await picture.toImage(53, 59);
    picture.dispose();
    final bytes = await obsolete.toByteData(format: ui.ImageByteFormat.png);
    obsolete.dispose();
    expect(
        await store.put(
            key: oldIdentity!.key,
            content: Stream.value(bytes!.buffer
                .asUint8List(bytes.offsetInBytes, bytes.lengthInBytes)),
            mimeType: 'image/png',
            width: 53,
            height: 59,
            lossless: true,
            maximumBytes: 1 << 20,
            canPublish: () => true),
        isNotNull);
    final inherited = await ReaderRasterCache.load(file, demand,
        backingPath: 'unused', pixelVersion: 'flutter-srgb-rgba8-adaptive-v2');
    final currentIdentity = await ReaderRasterCache.capture(file, demand,
        pixelVersion: 'flutter-srgb-rgba8-adaptive-v2');
    final persisted = await store.lookup(oldIdentity.key);
    expect(currentIdentity?.key.token, oldIdentity.key.token,
        reason: 'The poison raster fixture must retain the source stamp');
    expect(persisted, isNotNull,
        reason: 'The old-version poison raster must remain fully published');
    expect(inherited, isNotNull,
        reason:
            'A valid old-version raster is required to prove new-version rejection');
    inherited?.dispose();
    const metadata = ReaderRasterMetadata(
        size: ui.Size(67, 73),
        animated: false,
        format: 'png',
        workingBytes: 67 * 73 * 12,
        bitDepth: 16);
    final original = await _decodeOriginal(file);
    addTearDown(original.dispose);
    final crop = await const FlutterReaderRasterBackend(metadata).decode(
        file, demand,
        backingPath: 'unused',
        memoryBudgetBytes: 64 << 20,
        isCancelled: () => false);
    addTearDown(crop.dispose);
    expect(await _blackRoi(crop, const ui.Rect.fromLTWH(0, 0, 53, 59)),
        orderedEquals(await _blackRoi(original, source)));
  });
}

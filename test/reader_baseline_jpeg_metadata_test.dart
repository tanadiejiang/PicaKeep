import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/image_pipeline/native_image_disk_plan.dart';
import 'package:picakeep/foundation/image_pipeline/reader_raster_backend.dart';
import 'package:picakeep_image_engine/picakeep_image_engine.dart';

List<int> _header(int marker, {int width = 643, int height = 967}) => [
      0xff,
      0xd8,
      0xff,
      marker,
      0,
      17,
      8,
      height >> 8,
      height & 255,
      width >> 8,
      width & 255,
      3,
      1,
      0x22,
      0,
      2,
      0x11,
      0,
      3,
      0x11,
      0,
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(() async {
    directory =
        await Directory.systemTemp.createTemp('reader-baseline-metadata-');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
    await PicakeepImageEngine.shutdownIdleWorkers();
  });

  test('grouping metadata defaults to unclassified', () {
    const metadata = ReaderRasterMetadata(
        size: ui.Size(643, 967),
        animated: false,
        format: 'jpeg',
        workingBytes: 32 << 20);
    expect(metadata.baselineJpeg, isNull);
  });

  test('classifier admits only valid SOF0 and checks encoded axes', () async {
    final file = File('${directory.path}/source.jpg');
    for (final marker in [0xc0, 0xc2, 0xc1, 0xc3]) {
      await file.writeAsBytes(_header(marker));
      expect(
          await NativeImageDiskPlan.isBaselineJpeg(file,
              encodedWidth: 643, encodedHeight: 967),
          marker == 0xc0);
    }
    await file.writeAsBytes(_header(0xc0));
    expect(
        await NativeImageDiskPlan.isBaselineJpeg(file,
            encodedWidth: 967, encodedHeight: 643),
        isFalse);
  });

  test('classifier rejects malformed, missing and changed source stamps',
      () async {
    final file = File('${directory.path}/source.jpg');
    await file.writeAsBytes(_header(0xc0));
    final selected = await file.stat();
    final damaged = _header(0xc0)..removeLast();
    await file.writeAsBytes(damaged);
    expect(
        await NativeImageDiskPlan.isBaselineJpeg(file,
            encodedWidth: 643, encodedHeight: 967),
        isFalse);
    await file.writeAsBytes([..._header(0xc0), 0]);
    expect(
        await NativeImageDiskPlan.isBaselineJpeg(file,
            encodedWidth: 643, encodedHeight: 967, expectedSnapshot: selected),
        isFalse);
    expect(
        await NativeImageDiskPlan.isBaselineJpeg(
            File('${directory.path}/missing.jpg'),
            encodedWidth: 643,
            encodedHeight: 967),
        isFalse);
  });

  final fixtureRoot = Platform.environment['PICAKEEP_IMAGE_ENGINE_FIXTURES'];
  final nativeEnabled = fixtureRoot != null && PicakeepImageEngine.isAvailable;
  test('native probe classifies actual baseline/progressive and rotated JPEG',
      () async {
    const backend = NativeReaderRasterBackend();
    final baseline =
        await backend.probe(File('$fixtureRoot/640x960-baseline.jpg'));
    final progressive =
        await backend.probe(File('$fixtureRoot/8000x12000-progressive.jpg'));
    final rotated =
        await backend.probe(File('$fixtureRoot/640x960-orientation-6.jpg'));
    final png = await backend.probe(File('$fixtureRoot/640x960.png'));
    expect(baseline.baselineJpeg, isTrue);
    expect(progressive.baselineJpeg, isFalse);
    expect(rotated.size, const ui.Size(960, 640));
    expect(rotated.baselineJpeg, isTrue,
        reason:
            'header checks encoded axes rather than orientation-normalized axes');
    expect(png.baselineJpeg, isNull);
  }, skip: !nativeEnabled);
}

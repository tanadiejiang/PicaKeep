import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:picakeep/foundation/image_pipeline/native_image_disk_plan.dart';
import 'package:picakeep_image_engine/picakeep_image_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixtures = Platform.environment['PICAKEEP_022_THIN_JPEG_FIXTURES'];
  final long = Platform.environment['PICAKEEP_022_THIN_JPEG_LONG'] == '1';
  for (final dimensions
      in long ? ['1x30000', '30000x1'] : ['1x3000', '3000x1']) {
    for (final sampling in [0, 2]) {
      test(
          'thin progressive $dimensions sampling $sampling reserves padded coefficients before writing',
          () async {
        final input =
            File(p.join(fixtures!, '$dimensions-s$sampling-progressive.jpg'));
        final before = await input.stat();
        final digest = sha256.convert(await input.readAsBytes());
        final task = await Directory(fixtures).createTemp('native-plan-');
        try {
          final path = p.join(task.path, 'test.pixels');
          final plan = await NativeImageDiskPlan.inspect(input,
              backingPath: path, prepare: true);
          // 4:4:4 alone needs ceil(1/8)*ceil(3000/8)*3*128.
          if (sampling == 0) {
            expect(
                plan.additionalBytes,
                plan.finalBackingBytes +
                    (long ? 1440000 : 144000) +
                    256 * 1024);
          }
          final result = await const PicakeepImageEngine().prepareBacking(
              input.path,
              backingPath: path,
              memoryBudgetBytes: 64 << 20,
              diskBudgetBytes: plan.nativeDiskBudgetBytes);
          expect(result.diskPeakBytes,
              lessThanOrEqualTo(plan.nativeDiskBudgetBytes));
          print(
              'THIN_PLAN ${input.uri.pathSegments.last} raw=${plan.finalBackingBytes} admitted=${plan.additionalBytes} nativePeak=${result.diskPeakBytes}');
          expect(await File(path).length(), plan.finalBackingBytes);
          expect(
              await task.list().any((file) =>
                  file.path.contains('.coeff-') || file.path.endsWith('.part')),
              isFalse);
          expect((await input.stat()).modified, before.modified);
          expect(sha256.convert(await input.readAsBytes()), digest);
        } finally {
          await task.delete(recursive: true);
          await PicakeepImageEngine.shutdownIdleWorkers();
        }
      }, skip: fixtures == null || !PicakeepImageEngine.isAvailable);
    }
  }
  final normalFixtures =
      Platform.environment['PICAKEEP_022_NORMAL_JPEG_FIXTURES'];
  test('ordinary 4:2:0 progressive covers the native physical-space guard',
      () async {
    final input = File(p.join(normalFixtures!, '3000x3000-s2-progressive.jpg'));
    final before = await input.stat();
    final digest = sha256.convert(await input.readAsBytes());
    final task = await Directory(normalFixtures).createTemp('native-plan-');
    try {
      final path = p.join(task.path, 'test.pixels');
      final metadata = await const PicakeepImageEngine().probe(input.path);
      expect(metadata.format, 'jpeg');
      expect(metadata.encodedWidth, 3000);
      expect(metadata.encodedHeight, 3000);
      expect(
          _progressiveSampling(await input.readAsBytes()), [0x22, 0x11, 0x11]);
      final plan = await NativeImageDiskPlan.inspect(input,
          backingPath: path, prepare: true);
      const nativeGuard = 3000 * 3000 * 6;
      expect(plan.additionalBytes,
          plan.finalBackingBytes + nativeGuard + 256 * 1024);
      final result = await const PicakeepImageEngine().prepareBacking(
          input.path,
          backingPath: path,
          memoryBudgetBytes: 64 << 20,
          diskBudgetBytes: plan.nativeDiskBudgetBytes);
      expect(
          result.diskPeakBytes, lessThanOrEqualTo(plan.nativeDiskBudgetBytes));
      print('NORMAL_PLAN ${input.uri.pathSegments.last} '
          'raw=${plan.finalBackingBytes} admitted=${plan.additionalBytes} '
          'nativePeak=${result.diskPeakBytes} guard=$nativeGuard');
      expect(await File(path).length(), plan.finalBackingBytes);
      expect((await input.stat()).modified, before.modified);
      expect(sha256.convert(await input.readAsBytes()), digest);
    } finally {
      await task.delete(recursive: true);
      await PicakeepImageEngine.shutdownIdleWorkers();
    }
  }, skip: normalFixtures == null || !PicakeepImageEngine.isAvailable);
}

List<int>? _progressiveSampling(List<int> bytes) {
  var offset = 2;
  while (offset + 4 <= bytes.length && bytes[offset] == 0xff) {
    final marker = bytes[offset + 1];
    final length = bytes[offset + 2] * 256 + bytes[offset + 3];
    if (length < 2 || offset + length + 2 > bytes.length) return null;
    if (marker == 0xc2) {
      final components = bytes[offset + 9];
      return [
        for (var index = 0; index < components; index++)
          bytes[offset + 11 + index * 3]
      ];
    }
    if (marker == 0xda || marker == 0xd9) return null;
    offset += length + 2;
  }
  return null;
}

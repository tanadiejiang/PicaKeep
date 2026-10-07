import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/image_pipeline/original_image_operations.dart';
import 'package:picakeep/foundation/privileged_storage_access_flutter.dart'
    as flutter_access;
import 'package:picakeep/foundation/privileged_storage_access_io.dart'
    as io_access;

typedef _Copy = Future<File> Function(String source, File destination,
    {int maxBytes, bool Function()? isCancelled, Future<void>? cancelled});

void main() {
  for (final entry in <String, _Copy>{
    'io': io_access.PrivilegedStorageAccess.copyFileToManagedFile,
    'flutter IO fallback':
        flutter_access.PrivilegedStorageAccess.copyFileToManagedFile,
  }.entries) {
    group(entry.key, () {
      late Directory task;
      late File source;
      setUp(() async {
        task = await Directory.systemTemp.createTemp('022-copy-test-');
        source = File('${task.path}/source.bin');
        final output = await source.open(mode: FileMode.write);
        try {
          final chunk = Uint8List(64 * 1024);
          for (var index = 0; index < chunk.length; index++) {
            chunk[index] = index % 251;
          }
          for (var index = 0; index < 64; index++) {
            await output.writeFrom(chunk);
          }
        } finally {
          await output.close();
        }
      });
      tearDown(() async {
        if (await task.exists()) await task.delete(recursive: true);
      });

      test('64 KiB chunk input retains exact original bytes', () async {
        final target = File('${task.path}/managed/output.bin');
        await entry.value(source.path, target, maxBytes: await source.length());
        expect(await target.length(), 4 * 1024 * 1024);
        expect(await originalImageDigest(target),
            await originalImageDigest(source));
      });

      test('preflight bound does not truncate an existing target', () async {
        final target =
            await File('${task.path}/output.bin').writeAsBytes([7, 8]);
        await expectLater(entry.value(source.path, target, maxBytes: 65536),
            throwsStateError);
        expect(await target.readAsBytes(), [7, 8]);
      });

      test('cancelled future during stat prevents opening the target',
          () async {
        final target = File('${task.path}/output.bin');
        final cancelled = Completer<void>()..complete();
        await expectLater(
            entry.value(source.path, target, cancelled: cancelled.future),
            throwsStateError);
        expect(await target.exists(), isFalse);
      });

      test('mid-stream cancellation deletes partial output and keeps source',
          () async {
        final target = File('${task.path}/output.bin');
        var checks = 0;
        await expectLater(
            entry.value(source.path, target, isCancelled: () => ++checks > 8),
            throwsStateError);
        expect(checks, greaterThan(8));
        expect(await target.exists(), isFalse);
        expect(await source.length(), 4 * 1024 * 1024);
      });
    });
  }
}

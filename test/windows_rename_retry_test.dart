import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:picakeep/foundation/windows_rename_retry.dart';
import 'package:test/test.dart';

import 'support/windows_rename_lock.dart';

void main() {
  group('Windows atomic rename with a real non-delete-sharing handle', () {
    late Directory workspace;
    late Directory staging;
    late String target;
    late WindowsRenameLock lock;

    setUp(() async {
      workspace = await Directory.systemTemp.createTemp('pk_rename_lock_');
      staging = await Directory(p.join(workspace.path, 'staging')).create();
      target = p.join(workspace.path, 'published');
      await File(p.join(staging.path, 'original.txt'))
          .writeAsString('complete source bytes', flush: true);
      lock = WindowsRenameLock(p.join(staging.path, 'original.txt'));
    });

    tearDown(() async {
      lock.close();
      await workspace.delete(recursive: true);
    });

    test('a single rename reproduces access denial and preserves staging',
        () async {
      await expectLater(
          staging.rename(target),
          throwsA(isA<FileSystemException>().having(
              (error) => error.osError?.errorCode,
              'Windows error code',
              isIn([5, 32, 33]))));
      expect(await staging.exists(), isTrue);
      expect(await Directory(target).exists(), isFalse);
    });

    test('publication succeeds when the actual handle releases during retries',
        () async {
      final release = Timer(const Duration(milliseconds: 60), lock.close);
      try {
        await retryWindowsRename(() => staging.rename(target));
      } finally {
        release.cancel();
      }
      expect(await staging.exists(), isFalse);
      expect(await File(p.join(target, 'original.txt')).readAsString(),
          'complete source bytes');
    });

    test('persistent denial still fails and leaves the complete staging copy',
        () async {
      await expectLater(
          retryWindowsRename(() => staging.rename(target)),
          throwsA(isA<FileSystemException>().having(
              (error) => error.osError?.errorCode,
              'Windows error code',
              isIn([5, 32, 33]))));
      expect(await Directory(target).exists(), isFalse);
      expect(await File(p.join(staging.path, 'original.txt')).readAsString(),
          'complete source bytes');
    });

    test('a missing source is not retried', () async {
      var attempts = 0;
      await expectLater(retryWindowsRename(() {
        attempts++;
        return Directory(p.join(workspace.path, 'missing')).rename(target);
      }), throwsA(isA<FileSystemException>()));
      expect(attempts, 1);
      expect(await Directory(target).exists(), isFalse);
    });
  }, skip: !Platform.isWindows);
}

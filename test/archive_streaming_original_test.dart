import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/archive/archive_errors.dart';
import 'package:picakeep/foundation/archive/backends/dart_zip_backend.dart';

void main() {
  final expected =
      List<int>.generate(192 * 1024 + 7, (i) => (i * 31 + i ~/ 251) & 255);
  final expectedDigest = sha256.convert(expected).toString();
  late Directory temporary;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('reader-archive-test-');
  });
  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  for (final fixture in [
    'stored.zip',
    'deflate.zip',
    'zipcrypto.zip',
    'aes256.zip',
    'zipcrypto-deflate.zip',
    'aes256-deflate.zip',
    'aes256-ae1.zip',
  ]) {
    test(
        'bounded $fixture extraction preserves member bytes across 64 KiB chunks',
        () async {
      final output = File('${temporary.path}/original.png');
      await DartZipBackend().materializeEntry(
        'test/fixtures/image-pipeline-022/$fixture',
        '1.png',
        output,
        password: 'fixture-password',
        maxBytes: expected.length,
      );
      expect(await output.length(), expected.length);
      expect((await sha256.bind(output.openRead()).first).toString(),
          expectedDigest);
    });
  }

  test('wrong encrypted password never publishes a member file', () async {
    for (final fixture in ['zipcrypto.zip', 'aes256.zip']) {
      final output = File('${temporary.path}/wrong.png');
      await expectLater(
          DartZipBackend().materializeEntry(
            'test/fixtures/image-pipeline-022/$fixture',
            '1.png',
            output,
            password: 'wrong',
          ),
          throwsA(isA<ArchiveFailure>().having((failure) => failure.code,
              'code', ArchiveErrorCode.wrongPassword)));
      expect(await output.exists(), isFalse);
    }
  });

  test('CRC failure and byte reservation failure leave no partial output',
      () async {
    final source = File('test/fixtures/image-pipeline-022/stored.zip');
    final damaged = await source.readAsBytes();
    // Python-generated fixture has 30-byte header + 5-byte filename.
    damaged[35 + 1000] ^= 1;
    final archive =
        await File('${temporary.path}/damaged.zip').writeAsBytes(damaged);
    final output = File('${temporary.path}/damaged.png');
    await expectLater(
        DartZipBackend().materializeEntry(archive.path, '1.png', output),
        throwsA(isA<ArchiveFailure>().having((failure) => failure.code, 'code',
            ArchiveErrorCode.corruptedArchive)));
    expect(await output.exists(), isFalse);
    await expectLater(
        DartZipBackend().materializeEntry(source.path, '1.png', output,
            maxBytes: 64 * 1024),
        throwsStateError);
    expect(await output.exists(), isFalse);
  });

  test('cancellation terminates extraction and deletes partial member',
      () async {
    var polls = 0;
    final output = File('${temporary.path}/cancelled.png');
    await expectLater(
        DartZipBackend().materializeEntry(
          'test/fixtures/image-pipeline-022/stored.zip',
          '1.png',
          output,
          isCancelled: () => ++polls > 2,
        ),
        throwsStateError);
    expect(await output.exists(), isFalse);
  });
}

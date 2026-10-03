import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/download_stream_file.dart';

void main() {
  late Directory dir;
  late File target;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('picakeep_download_stream_');
    target = File('${dir.path}/image.jpg');
  });
  tearDown(() async {
    await dir.delete(recursive: true);
  });

  test('complete stream publishes once, and reports every received byte',
      () async {
    var count = 0;
    await writeDownloadStreamFile(
        target: target,
        stream: Stream.fromIterable([
          [1, 2],
          [3, 4]
        ]),
        checkCancelled: () {},
        onChunk: (n) => count += n,
        expectedLength: 4);
    expect(await target.readAsBytes(), [1, 2, 3, 4]);
    expect(count, 4);
    expect(File('${target.path}.part').existsSync(), isFalse);
  });

  test('network failure leaves no falsely completed final file', () async {
    final stream = Stream<List<int>>.multi((sink) {
      sink.add([1, 2]);
      sink.addError(const SocketException('offline'));
      sink.close();
    });
    await expectLater(
        writeDownloadStreamFile(
            target: target, stream: stream, checkCancelled: () {}),
        throwsA(isA<SocketException>()));
    expect(target.existsSync(), isFalse);
    expect(File('${target.path}.part').existsSync(), isFalse);
  });

  test('cancellation before publish never exposes partial content', () async {
    var checks = 0;
    await expectLater(
        writeDownloadStreamFile(
            target: target,
            stream: Stream.value([1, 2]),
            checkCancelled: () {
              if (++checks >= 2) throw StateError('paused');
            }),
        throwsStateError);
    expect(target.existsSync(), isFalse);
    expect(File('${target.path}.part').existsSync(), isFalse);
  });

  test('short response cannot be treated as a downloaded page', () async {
    await expectLater(
        writeDownloadStreamFile(
            target: target,
            stream: Stream.value([1, 2]),
            checkCancelled: () {},
            expectedLength: 5),
        throwsFormatException);
    expect(target.existsSync(), isFalse);
  });

  test('a stale partial from process death is replaced on retry', () async {
    await File('${target.path}.part').writeAsBytes([9, 9, 9]);
    await writeDownloadStreamFile(
        target: target,
        stream: Stream.value([1, 2]),
        checkCancelled: () {},
        expectedLength: 2);
    expect(await target.readAsBytes(), [1, 2]);
  });

  test('failed replacement preserves a pre-existing complete target', () async {
    await target.writeAsBytes([8, 8]);
    await expectLater(
        writeDownloadStreamFile(
            target: target,
            stream: Stream.value([1]),
            checkCancelled: () {},
            expectedLength: 2),
        throwsFormatException);
    expect(await target.readAsBytes(), [8, 8]);
  });
}

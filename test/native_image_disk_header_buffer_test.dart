import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/image_pipeline/native_image_disk_plan.dart';

class _TrackingHandle implements RandomAccessFile {
  _TrackingHandle(this.delegate);
  final RandomAccessFile delegate;
  int reads = 0, bytesRead = 0, maximumRequest = 0;
  final List<int> seeks = [];

  @override
  Future<Uint8List> read(int count) async {
    reads++;
    if (count > maximumRequest) maximumRequest = count;
    final value = await delegate.read(count);
    bytesRead += value.length;
    return value;
  }

  @override
  Future<RandomAccessFile> setPosition(int position) async {
    seeks.add(position);
    await delegate.setPosition(position);
    return this;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
      'Unexpected file operation: ${invocation.memberName}');
}

List<int> _app(int payloadBytes) => [
      0xff,
      0xe1,
      (payloadBytes + 2) >> 8,
      (payloadBytes + 2) & 0xff,
      ...List.filled(payloadBytes, 0x42),
    ];

List<int> _sof(
        {bool progressive = false,
        int width = 3000,
        int height = 3000,
        List<int> sampling = const [0x22, 0x11, 0x11]}) =>
    [
      0xff,
      progressive ? 0xc2 : 0xc0,
      0,
      8 + sampling.length * 3,
      8,
      height >> 8,
      height & 0xff,
      width >> 8,
      width & 0xff,
      sampling.length,
      for (var i = 0; i < sampling.length; i++) ...[i + 1, sampling[i], 0],
    ];

void main() {
  late Directory temporary;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('reader-header-buffer-');
  });
  tearDown(() async {
    await temporary.delete(recursive: true);
  });

  Future<({bool progressive, int coefficientBytes})> inspect(List<int> bytes,
      {int width = 3000,
      int height = 3000,
      void Function(_TrackingHandle)? checkIo}) async {
    final file = File('${temporary.path}/source.jpg');
    await file.writeAsBytes(bytes);
    final original = await file.open();
    final tracked = _TrackingHandle(original);
    try {
      final result = await NativeImageDiskPlan.readJpegCodecForTesting(tracked,
          encodedWidth: width, encodedHeight: height);
      checkIo?.call(tracked);
      return result;
    } finally {
      await original.close();
    }
  }

  test('many ordinary APP markers need one bounded header read', () async {
    final result = await inspect([
      0xff,
      0xd8,
      for (var i = 0; i < 100; i++) ..._app(5),
      ..._sof(),
    ], checkIo: (handle) {
      expect(handle.reads, 1);
      expect(handle.maximumRequest, 64 << 10);
      expect(handle.seeks, isEmpty);
    });
    expect(result.progressive, isFalse);
    expect(result.coefficientBytes, 188 * 188 * 6 * 128);
  });

  test('SOF crossing a header block preserves progressive sampling', () async {
    final result = await inspect([
      0xff,
      0xd8,
      ..._app(65526),
      ..._sof(
          progressive: true,
          width: 1,
          height: 3000,
          sampling: const [0x11, 0x11, 0x11]),
    ], width: 1, height: 3000, checkIo: (handle) {
      expect(handle.reads, 2);
      expect(handle.maximumRequest, 64 << 10);
      expect(handle.seeks, isEmpty);
    });
    expect(result.progressive, isTrue);
    expect(result.coefficientBytes, 144000);
  });

  test('large metadata segments skip payloads without tiny I/O', () async {
    final result = await inspect([
      0xff,
      0xd8,
      ..._app(65533),
      ..._app(65533),
      ..._sof(progressive: true),
    ], checkIo: (handle) {
      expect(handle.reads, 3);
      expect(handle.seeks, [65539, 131076]);
      expect(handle.maximumRequest, 64 << 10);
    });
    expect(result.progressive, isTrue);
    expect(result.coefficientBytes, 188 * 188 * 6 * 128);
  });

  test('thin subsampled progressive charges padded MCUs', () async {
    final result = await inspect([
      0xff,
      0xd8,
      ..._sof(progressive: true, width: 1, height: 3000),
    ], width: 1, height: 3000);
    expect(result.progressive, isTrue);
    expect(result.coefficientBytes, 188 * 6 * 128);
  });

  test('truncated or malformed baseline SOF cannot select quick decode',
      () async {
    final valid = [0xff, 0xd8, ..._sof(width: 1, height: 3000)];
    final invalidSampling = [
      0xff,
      0xd8,
      ..._sof(width: 1, height: 3000, sampling: const [0x51, 0x11, 0x11]),
    ];
    final invalidLength = [...valid]..[5] = 16;
    for (final bytes in [
      valid.sublist(0, valid.length - 1),
      invalidSampling,
      invalidLength,
      [0xff, 0xd8, ..._sof(width: 2, height: 3000)],
      [0xff, 0xd8, 0xff, 0xda],
    ]) {
      final result = await inspect(bytes, width: 1, height: 3000);
      expect(result.progressive, isTrue);
      expect(result.coefficientBytes, 32 * 3008 * 8);
    }
  });

  test('marker fill bytes work but unsupported SOF stays conservative',
      () async {
    final filled = await inspect([
      0xff,
      0xd8,
      0xff,
      ..._sof(),
    ]);
    expect(filled.progressive, isFalse);
    final unsupported = [..._sof()]..[1] = 0xc9;
    final unknown = await inspect([
      0xff,
      0xd8,
      ...unsupported,
      ..._sof(),
    ]);
    expect(unknown.progressive, isTrue);
    expect(unknown.coefficientBytes, 3008 * 3008 * 8);
  });

  test('headers beyond eight MiB retain a conservative bounded plan', () async {
    final result = await inspect([
      0xff,
      0xd8,
      for (var i = 0; i < 130; i++) ..._app(65533),
      ..._sof(),
    ], checkIo: (handle) {
      expect(handle.maximumRequest, 64 << 10);
      expect(handle.bytesRead, lessThanOrEqualTo(8 << 20));
      expect(handle.reads, lessThanOrEqualTo(129));
      expect(handle.seeks.every((offset) => offset < 8 << 20), isTrue);
    });
    expect(result.progressive, isTrue);
    expect(result.coefficientBytes, 3008 * 3008 * 8);
  });

  test('rewriting the same source path does not reuse old baseline headers',
      () async {
    final first = await inspect([0xff, 0xd8, ..._sof()]);
    final replacement = await inspect([0xff, 0xd8, ..._sof(progressive: true)]);
    expect(first.progressive, isFalse);
    expect(replacement.progressive, isTrue);
  });
}

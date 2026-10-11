import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:picakeep/foundation/image_loader/jm_image_recombine.dart';
import 'package:picakeep/foundation/image_loader/reader_image_limits.dart';

Uint8List _gif({required bool animated}) {
  img.Image frame(int red, int blue) {
    final image = img.Image(width: 2, height: 20, withPalette: true);
    image.palette!.setRgb(1, red, 0, blue);
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        image.setPixelIndex(x, y, 1);
      }
    }
    return image;
  }

  final encoder = img.GifEncoder(repeat: 3)
    ..addFrame(frame(255, 0), duration: 80);
  if (animated) encoder.addFrame(frame(0, 255), duration: 130);
  return encoder.finish()!;
}

Future<({Uint8List bytes, String extension})> _reorder(
        Uint8List bytes, String extension) =>
    JmRecombine.recombine(bytes,
        // This interval selects exactly ten row segments, independent of hash.
        epsId: '220981',
        scrambleId: kJmScrambleId,
        pictureName: 'offline-fixture',
        originalExtension: extension);

Future<({Uint8List rgba, int width, int height})> _flutterStraightPixels(
    Uint8List bytes) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    codec = await descriptor.instantiateCodec();
    image = (await codec.getNextFrame()).image;
    final data =
        await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    if (data == null) throw StateError('Missing Flutter reference pixels');
    return (
      rgba: Uint8List.fromList(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes)),
      width: image.width,
      height: image.height
    );
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('admission keeps raw64/work128 and counts both encoded buffers', () {
    expect(JmRecombineLimits.maximumEncodedBytes, 64 << 20);
    expect(JmRecombineLimits.maximumWorkingBytes, 128 << 20);
    expect(JmRecombineLimits.admit(encodedBytes: 100, width: 2, height: 3),
        2 * 100 + 2 * 3 * 24);
  });

  test('encoded-copy boundary rejects before any buffer allocation', () {
    const maximum = JmRecombineLimits.maximumWorkingBytes;
    const largestPossibleEncoded = (maximum - 24) ~/ 2;
    expect(
        JmRecombineLimits.admitEncodedBytes(largestPossibleEncoded), maximum);
    expect(
        () => JmRecombineLimits.admitEncodedBytes(largestPossibleEncoded + 1),
        throwsA(isA<JmRecombineLimit>()
            .having((e) => e.reason, 'reason', 'jm-recombine-budget')
            .having((e) => e.width, 'unknown width', isNull)
            .having((e) => e.estimatedWorkingBytes, 'minimum estimate',
                maximum + 2)));
    expect(() => JmRecombineLimits.admitEncodedBytes(64 << 20),
        throwsA(isA<JmRecombineLimit>()));
    // These are integers only; this test does not allocate 64/128 MiB fixtures.
  });

  test('high encoded small raster obeys the full descriptor budget boundary',
      () {
    const width = 4, height = 4;
    const maximum = JmRecombineLimits.maximumWorkingBytes;
    const encoded = (maximum - width * height * 24) ~/ 2;
    expect(
        JmRecombineLimits.admit(
            encodedBytes: encoded, width: width, height: height),
        maximum);
    expect(
        () => JmRecombineLimits.admit(
            encodedBytes: encoded + 1, width: width, height: height),
        throwsA(isA<JmRecombineLimit>()
            .having(
                (e) => e.estimatedWorkingBytes, 'full estimate', maximum + 2)
            .having((e) => e.encodedBytes, 'encoded length', encoded + 1)
            .having((e) => e.width, 'width', width)
            .having((e) => e.height, 'height', height)));
  });

  test('untrusted dimension and encoded products cannot wrap into admission',
      () {
    expect(
        () =>
            JmRecombineLimits.admit(encodedBytes: 0, width: 1 << 62, height: 4),
        throwsA(isA<JmRecombineLimit>().having(
            (e) => e.estimatedWorkingBytes, 'oversized diagnostic', isNull)));
    expect(() => JmRecombineLimits.admitEncodedBytes(1 << 62),
        throwsA(isA<JmRecombineLimit>()));
    expect(() => JmRecombineLimits.admit(encodedBytes: 1, width: 0, height: 1),
        throwsArgumentError);
    expect(() => JmRecombineLimits.admitEncodedBytes(-1), throwsArgumentError);
  });

  test(
      'typed refusal has safe scalar diagnostics and no display-policy workaround',
      () {
    const limit = JmRecombineLimit('jm-recombine-budget',
        encodedBytes: 12, width: 20, height: 30, estimatedWorkingBytes: 14424);
    expect(limit, isA<ReaderImageLimit>());
    expect(limit.message, contains('重组超出安全内存预算'));
    expect(limit.message, contains('原文件未修改'));
    expect(limit.message, isNot(contains('切换')));
    expect(
        jsonDecode(jsonEncode({
          'encodedBytes': limit.encodedBytes,
          'width': limit.width,
          'height': limit.height,
          'estimatedWorkingBytes': limit.estimatedWorkingBytes,
          'maximumWorkingBytes': limit.maximumWorkingBytes,
        }))['maximumWorkingBytes'],
        128 << 20);
  });

  test('real two-frame GIF needing reordering is explicitly rejected',
      () async {
    final bytes = _gif(animated: true);
    final original = Uint8List.fromList(bytes);
    expect(img.decodeGif(bytes)!.numFrames, 2);
    await expectLater(
        _reorder(bytes, '.gif'),
        throwsA(isA<JmRecombineLimit>()
            .having((e) => e.reason, 'reason', 'jm-recombine-animation')
            .having((e) => e.width, 'width', 2)
            .having((e) => e.height, 'height', 20)
            .having((e) => e.message, 'message', contains('无法保持完整动画'))
            .having((e) => e.message, 'original preservation',
                contains('原文件未修改'))));
    expect(bytes, original);
  });

  test(
      'zero-segment animated GIF passes through all original bytes and extension',
      () async {
    final bytes = _gif(animated: true);
    final original = Uint8List.fromList(bytes);
    final result = await JmRecombine.recombine(bytes,
        epsId: '100',
        scrambleId: kJmScrambleId,
        pictureName: 'offline-fixture',
        originalExtension: '.gif');
    expect(identical(result.bytes, bytes), isTrue);
    expect(result.bytes, original);
    expect(result.extension, '.gif');
    expect(img.decodeGif(result.bytes)!.numFrames, 2);
  });

  test(
      'semitransparent PNG stripes keep Flutter straight RGBA without double alpha',
      () async {
    final image = img.Image(width: 3, height: 21, numChannels: 4);
    const alpha = [64, 128, 192, 255];
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        image.setPixelRgba(x, y, 240, y * 11, x * 73, alpha[y % alpha.length]);
      }
    }
    final bytes = img.encodePng(image);
    final original = Uint8List.fromList(bytes);
    // Compare against actual Flutter 8-bit decoding, not a claim about source
    // ICC/16-bit fidelity or reversible engine premultiplication quantization.
    final reference = await _flutterStraightPixels(bytes);
    expect(reference.rgba[3], 64);
    expect(reference.rgba[0], greaterThan(200));
    final result = await _reorder(bytes, '.png');
    expect(result.extension, '.png');
    expect(bytes, original);
    final decoded = img.decodePng(result.bytes)!;
    expect(decoded.width, reference.width);
    expect(decoded.height, reference.height);
    final expectedRows = [
      18,
      19,
      20,
      for (var segment = 8; segment >= 0; segment--) ...[
        segment * 2,
        segment * 2 + 1
      ]
    ];
    for (var y = 0; y < decoded.height; y++) {
      for (var x = 0; x < decoded.width; x++) {
        final offset = (expectedRows[y] * reference.width + x) * 4;
        final pixel = decoded.getPixel(x, y);
        expect([pixel.r, pixel.g, pixel.b, pixel.a],
            reference.rgba.sublist(offset, offset + 4),
            reason: 'straight RGBA must survive reordering at ($x, $y)');
      }
    }
  });

  test('single-frame GIF still supports lossless reordering', () async {
    final result = await _reorder(_gif(animated: false), '.gif');
    expect(result.extension, '.png');
    final decoded = img.decodePng(result.bytes)!;
    expect(decoded.width, 2);
    expect(decoded.height, 20);
    expect(decoded.getPixel(0, 0).r, 255);
    expect(decoded.getPixel(0, 0).b, 0);
  });

  test('static PNG row reordering including remainder stays pixel exact',
      () async {
    final image = img.Image(width: 3, height: 21, numChannels: 4);
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        image.setPixelRgba(x, y, y * 11, x * 73, (y + x) * 9, 255);
      }
    }
    final bytes = img.encodePng(image);
    final original = Uint8List.fromList(bytes);
    final result = await _reorder(bytes, '.png');
    expect(result.extension, '.png');
    expect(bytes, original);
    final decoded = img.decodePng(result.bytes)!;
    expect(decoded.width, image.width);
    expect(decoded.height, image.height);
    final expectedRows = [
      18,
      19,
      20,
      for (var segment = 8; segment >= 0; segment--) ...[
        segment * 2,
        segment * 2 + 1
      ]
    ];
    for (var y = 0; y < decoded.height; y++) {
      for (var x = 0; x < decoded.width; x++) {
        final pixel = decoded.getPixel(x, y);
        expect([
          pixel.r,
          pixel.g,
          pixel.b,
          pixel.a
        ], [
          expectedRows[y] * 11,
          x * 73,
          (expectedRows[y] + x) * 9,
          255
        ], reason: 'unchanged ten-segment algorithm at ($x, $y)');
      }
    }
  });
}

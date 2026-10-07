import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/image_pipeline/image_work_scheduler.dart';
import 'package:picakeep/foundation/image_pipeline/reader_raw_image_decoder.dart';

Uint8List _pixels(int width, int height) {
  const colors = [
    [0, 0, 0, 0],
    [1, 0, 1, 1],
    [17, 61, 127, 128],
    [254, 0, 71, 254],
    [255, 255, 255, 255],
    [0, 0, 0, 255],
    [19, 207, 81, 255],
  ];
  return Uint8List.fromList([
    for (var i = 0; i < width * height; i++) ...colors[i % colors.length],
  ]);
}

Future<Uint8List> _rgba(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (data == null) throw StateError('RGBA readback returned no bytes');
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

Future<Uint8List> _paintRgba(ui.Image image) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawImage(
      image,
      ui.Offset.zero,
      ui.Paint()
        ..blendMode = ui.BlendMode.src
        ..filterQuality = ui.FilterQuality.none);
  final picture = recorder.endRecording();
  ui.Image? painted;
  try {
    painted = await picture.toImage(image.width, image.height);
    return await _rgba(painted);
  } finally {
    painted?.dispose();
    picture.dispose();
  }
}

Future<ReaderRawImageDecodeResult> _decode(
    ReaderRawImageDecoder decoder, Uint8List pixels,
    {int width = 7,
    int height = 5,
    int? rowBytes,
    bool preferSync = false,
    bool Function()? isCancelled}) {
  return decoder.decode(pixels,
      width: width,
      height: height,
      rowBytes: rowBytes ?? width * 4,
      preferSync: preferSync,
      isCancelled: isCancelled ?? () => false);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('default preserves all original RGBA pixels, alpha and source view',
      () async {
    final expected = _pixels(7, 5);
    final storage = Uint8List(expected.length + 16);
    storage.setRange(7, 7 + expected.length, expected);
    final view = Uint8List.sublistView(storage, 7, 7 + expected.length);
    final decoder = ReaderRawImageDecoder.forTesting(
        isAndroid: true,
        syncDecode: (_, __, ___, ____) =>
            throw StateError('Default must not opt in to sync'));
    final result = await _decode(decoder, view);
    try {
      expect((result.image.width, result.image.height), (7, 5));
      expect(result.image.colorSpace, ui.ColorSpace.sRGB);
      expect(await _rgba(result.image), expected);
      expect(await _paintRgba(result.image), expected);
      expect(view, expected, reason: 'The decoder must not premultiply twice');
      expect(result.usedSync, isFalse);
      expect(result.syncAttempted, isFalse);
      expect(result.uploadDeferred, isFalse);
      view.fillRange(0, view.length, 0);
      expect(await _rgba(result.image), expected,
          reason: 'A completed image must own its pixel storage');
    } finally {
      result.image.dispose();
    }
  });

  test('padded RGBA rows retain exact pixels through the async route',
      () async {
    final expected = _pixels(3, 2);
    final padded = Uint8List(16 * 2)..fillRange(0, 32, 199);
    padded.setRange(0, 12, expected.sublist(0, 12));
    padded.setRange(16, 28, expected.sublist(12));
    final decoder = ReaderRawImageDecoder.forTesting(
        isAndroid: true,
        syncDecode: (_, __, ___, ____) =>
            throw StateError('Sync cannot accept a padded row stride'));
    final result = await _decode(decoder, padded,
        width: 3, height: 2, rowBytes: 16, preferSync: true);
    try {
      // rawRgba may keep the backing row padding. Verify actual 1:1 painting
      // into a tightly packed output rather than interpreting padding as RGBA.
      expect(await _paintRgba(result.image), expected);
      expect(result.syncAttempted, isFalse);
      expect(result.syncUnsupported, isFalse);
    } finally {
      result.image.dispose();
    }
  });

  test('non Android opt in keeps the existing asynchronous renderer', () async {
    final decoder = ReaderRawImageDecoder.forTesting(
        isAndroid: false,
        syncDecode: (_, __, ___, ____) =>
            throw StateError('Desktop must not try the Android candidate'));
    final result = await _decode(decoder, _pixels(7, 5), preferSync: true);
    try {
      expect(await _rgba(result.image), _pixels(7, 5));
      expect(result.syncAttempted, isFalse);
      expect(result.usedSync, isFalse);
    } finally {
      result.image.dispose();
    }
  });

  test('the real Skia unsupported response falls back only once', () async {
    var attempts = 0;
    final decoder = ReaderRawImageDecoder.forTesting(
        isAndroid: true,
        syncDecode: (bytes, width, height, format) {
          attempts++;
          return ui.decodeImageFromPixelsSync(bytes, width, height, format);
        });
    for (var i = 0; i < 2; i++) {
      final result = await _decode(decoder, _pixels(7, 5), preferSync: true);
      try {
        expect(await _rgba(result.image), _pixels(7, 5));
        expect(result.syncAttempted, i == 0);
        expect(result.syncUnsupported, isTrue);
        expect(result.usedSync, isFalse);
        expect(result.uploadDeferred, isFalse);
      } finally {
        result.image.dispose();
      }
    }
    expect(attempts, 1);
  });

  test('UnsupportedError is remembered and fallback remains pixel exact',
      () async {
    var attempts = 0;
    final decoder = ReaderRawImageDecoder.forTesting(
        isAndroid: true,
        syncDecode: (_, __, ___, ____) {
          attempts++;
          throw UnsupportedError('The renderer does not support sync RGBA');
        });
    for (var i = 0; i < 2; i++) {
      final result = await _decode(decoder, _pixels(7, 5), preferSync: true);
      try {
        expect(await _rgba(result.image), _pixels(7, 5));
        expect(result.syncUnsupported, isTrue);
      } finally {
        result.image.dispose();
      }
    }
    expect(attempts, 1);
  });

  test('a sync resource failure propagates without disabling a later attempt',
      () async {
    final reference = await _decode(ReaderRawImageDecoder(), _pixels(7, 5));
    var attempts = 0;
    final decoder = ReaderRawImageDecoder.forTesting(
        isAndroid: true,
        syncDecode: (_, width, height, format) {
          attempts++;
          if (attempts == 1) throw StateError('Allocation failed');
          expect((width, height, format), (7, 5, ui.PixelFormat.rgba8888));
          return reference.image;
        });
    try {
      await expectLater(_decode(decoder, _pixels(7, 5), preferSync: true),
          throwsA(isA<StateError>()));
      final result = await _decode(decoder, _pixels(7, 5), preferSync: true);
      expect(result.usedSync, isTrue);
      expect(result.uploadDeferred, isTrue);
      expect(result.syncUnsupported, isFalse);
      expect(result.immutableBufferMicroseconds, 0);
      expect(await _rgba(result.image), _pixels(7, 5));
      expect(attempts, 2);
    } finally {
      reference.image.dispose();
    }
  });

  test('cancellation before creation never calls the sync renderer', () async {
    var attempted = false;
    final decoder = ReaderRawImageDecoder.forTesting(
        isAndroid: true,
        syncDecode: (_, __, ___, ____) {
          attempted = true;
          throw StateError('Cancelled input reached renderer');
        });
    await expectLater(
        _decode(decoder, _pixels(7, 5),
            preferSync: true, isCancelled: () => true),
        throwsA(isA<ImageWorkCancelled>()));
    expect(attempted, isFalse);
  });

  test('cancellation during synchronous creation disposes its returned image',
      () async {
    final reference = await _decode(ReaderRawImageDecoder(), _pixels(7, 5));
    var cancelled = false;
    final decoder = ReaderRawImageDecoder.forTesting(
        isAndroid: true,
        syncDecode: (_, __, ___, ____) {
          cancelled = true;
          return reference.image;
        });
    await expectLater(
        _decode(decoder, _pixels(7, 5),
            preferSync: true, isCancelled: () => cancelled),
        throwsA(isA<ImageWorkCancelled>()));
    expect(reference.image.debugDisposed, isTrue);
  });

  test(
      'cancellation after asynchronous creation releases the unpublished image',
      () async {
    ui.Image? created;
    final previousOnCreate = ui.Image.onCreate;
    ui.Image.onCreate = (image) {
      previousOnCreate?.call(image);
      created = image;
    };
    try {
      await expectLater(
          _decode(ReaderRawImageDecoder(), _pixels(7, 5),
              isCancelled: () => created != null),
          throwsA(isA<ImageWorkCancelled>()));
      expect(created, isNotNull);
      expect(created!.debugDisposed, isTrue);
    } finally {
      ui.Image.onCreate = previousOnCreate;
    }
  });

  test('changed output dimensions release the image and fail explicitly',
      () async {
    final wrong = await _decode(ReaderRawImageDecoder(), _pixels(1, 1),
        width: 1, height: 1);
    final decoder = ReaderRawImageDecoder.forTesting(
        isAndroid: true, syncDecode: (_, __, ___, ____) => wrong.image);
    await expectLater(_decode(decoder, _pixels(7, 5), preferSync: true),
        throwsA(isA<StateError>()));
    expect(wrong.image.debugDisposed, isTrue);
  });

  test('truncated or invalid RGBA input fails before image allocation',
      () async {
    final decoder = ReaderRawImageDecoder();
    for (final request in [(0, 5, 28, 140), (7, 5, 27, 140), (7, 5, 28, 139)]) {
      await expectLater(
          _decode(decoder, Uint8List(request.$4),
              width: request.$1, height: request.$2, rowBytes: request.$3),
          throwsArgumentError);
    }
    final result = await _decode(decoder, _pixels(7, 5));
    try {
      expect(await _rgba(result.image), _pixels(7, 5));
    } finally {
      result.image.dispose();
    }
  });
}

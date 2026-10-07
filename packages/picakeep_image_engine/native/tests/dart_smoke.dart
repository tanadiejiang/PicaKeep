import 'dart:io';
import 'dart:typed_data';
import 'package:picakeep_image_engine/picakeep_image_engine.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length < 2) {
    throw ArgumentError('dart_smoke.dart originalPath backingPath');
  }
  if (!PicakeepImageEngine.isAvailable)
    throw StateError('Native DLL unavailable');
  const engine = PicakeepImageEngine();
  final meta = await engine.probe(arguments[0]);
  final token = NativeCancellationToken();
  final pending = engine.decodeRegion(
    arguments[0],
    const NativeImageRect(0, 0, 64, 64),
    backingPath: arguments[1],
    memoryBudgetBytes: 64 << 20,
    cancelToken: token,
  );
  final pixels = await pending;
  token.dispose();
  if (pixels.width != 64 || pixels.bytes.length != 16384) {
    throw StateError('FFI image dimensions do not match');
  }
  final encoded = await engine.encodePixels(
    pixels.bytes,
    width: 64,
    height: 64,
    format: NativeImageEncoding.webp,
    lossless: true,
  );
  if (String.fromCharCodes(encoded.bytes.sublist(0, 4)) != 'RIFF') {
    throw StateError('WebP encoder returned another container');
  }
  encoded.dispose();
  pixels.dispose();
  final cancelled = NativeCancellationToken();
  final job = engine.decodeRegion(
    arguments[0],
    const NativeImageRect(0, 0, 64, 64),
    backingPath: arguments[1],
    memoryBudgetBytes: 64 << 20,
    cancelToken: cancelled,
  );
  cancelled.dispose();
  try {
    final late = await job;
    late.dispose();
  } on ImageEngineException catch (error) {
    if (!error.isCancelled) rethrow;
  }
  final alpha = Uint8List(4 * 4 * 4);
  try {
    await engine.encodePixels(
      alpha,
      width: 4,
      height: 4,
      format: NativeImageEncoding.jpeg,
    );
    throw StateError('JPEG accepted transparent pixels');
  } on ImageEngineException catch (error) {
    if (!error.isUnsupported) rethrow;
  }
  final alphaSource = Uint8List.fromList([
    for (var i = 0; i < 16; i++) ...[
      201,
      99,
      17,
      [0, 1, 128, 255][i % 4],
    ],
  ]);
  final png = await engine.encodePixels(
    alphaSource,
    width: 4,
    height: 4,
    format: NativeImageEncoding.png,
  );
  final alphaFile = File('${arguments[1]}.alpha-fixture.png');
  await alphaFile.writeAsBytes(png.bytes);
  png.dispose();
  final straight = await engine.decodeRegion(
    alphaFile.path,
    const NativeImageRect(0, 0, 4, 4),
    backingPath: '${arguments[1]}.alpha.pixels',
  );
  final premultiplied = await engine.decodeRegion(
    alphaFile.path,
    const NativeImageRect(0, 0, 4, 4),
    backingPath: '${arguments[1]}.alpha.pixels',
    premultiplyAlpha: true,
  );
  if (straight.premultipliedAlpha || !premultiplied.premultipliedAlpha) {
    throw StateError('Alpha buffer flag does not match worker conversion');
  }
  for (var i = 0; i < alphaSource.length; i++) {
    if (straight.bytes[i] != alphaSource[i]) {
      throw StateError('Default alpha path changed original or hidden RGB');
    }
    final expected = i % 4 == 3
        ? alphaSource[i]
        : (alphaSource[i] * alphaSource[(i ~/ 4) * 4 + 3] + 127) ~/ 255;
    if (premultiplied.bytes[i] != expected) {
      throw StateError('Worker premultiplication mismatch at byte $i');
    }
  }
  straight.dispose();
  premultiplied.dispose();
  stdout.writeln(
    'PASS Dart FFI: ${meta.width}x${meta.height}, image, encoder, cancel/dispose.',
  );
}

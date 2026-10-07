// Bounded original-pixel checks against the Flutter engine's actual decoder.
// This helper is used by the independent debug/profile verification entrypoint.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:path_provider/path_provider.dart';
import 'package:picakeep_image_engine/picakeep_image_engine.dart';

Future<Map<String, Object?>> runImagePipeline022PixelChecks(
  String fixturesPath,
) async {
  const engine = PicakeepImageEngine();
  final cases = <Map<String, Object?>>[];
  final report = <String, Object?>{
    'reference':
        'Flutter ImageDescriptor.encoded, original dimensions, rawRgba',
    'candidate': 'native original-pixel region, premultiplyAlpha=true',
    'thresholdApplied': false,
    'sampleCap': '512x512 per case',
    'fixturePath': fixturesPath,
    'nativeAvailable': PicakeepImageEngine.isAvailable,
    'cases': cases,
  };
  if (!PicakeepImageEngine.isAvailable) return report;
  final temp = Platform.isWindows
      ? Directory(r'E:\picakeep-native-022-artifacts')
      : await getTemporaryDirectory();
  final workspaceRoot = await Directory(
    '${temp.path}/picakeep-pixel-checks-022',
  ).create(recursive: true);
  final workspace = await workspaceRoot.createTemp('run-');
  const fixtures = <(String, String)>[
    ('640x960-baseline.jpg', 'JPEG 4:4:4'),
    ('640x960-chroma-420.jpg', 'JPEG 4:2:0 high-frequency ink'),
    ('640x960-orientation-6.jpg', 'JPEG ICC sRGB and EXIF 6'),
    ('640x960.png', 'PNG8 RGB'),
    ('640x960-alpha.png', 'PNG8 alpha and hidden RGB'),
    ('640x960-16bit-icc.png', 'PNG16 ICC sRGB'),
    ('640x960-16bit-interlaced-icc.png', 'PNG16 Adam7 ICC sRGB'),
    ('640x960-gray-icc.png', 'PNG8 gray ICC gamma 2.2'),
    ('640x960-gray-16bit-icc.png', 'PNG16 gray ICC gamma 2.2'),
    ('640x960-p3-icc.png', 'PNG8 Display P3 ICC saturated primaries'),
    (
      '640x960-adobe-rgb-icc.png',
      'PNG8 Adobe RGB 1998 ICC saturated primaries'
    ),
  ];
  try {
    for (final fixture in fixtures) {
      final path = '${Directory(fixturesPath).path}/${fixture.$1}';
      final record = <String, Object?>{
        'file': fixture.$1,
        'description': fixture.$2,
      };
      cases.add(record);
      ui.ImmutableBuffer? buffer;
      ui.ImageDescriptor? descriptor;
      ui.Codec? codec;
      ui.Image? frame;
      NativePixelBuffer? region;
      try {
        if (!await File(path).exists()) {
          record['status'] = 'fixtureMissing';
          continue;
        }
        final metadata = await engine.probe(path);
        record.addAll({
          'sourceWidth': metadata.width,
          'sourceHeight': metadata.height,
          'encodedWidth': metadata.encodedWidth,
          'encodedHeight': metadata.encodedHeight,
          'orientation': metadata.orientation,
          'sourceBitDepth': metadata.bitDepth,
          'sourceHasICC': metadata.hasColorProfile,
        });
        if (metadata.width * metadata.height > 4 * 1024 * 1024 ||
            metadata.width > 4096 ||
            metadata.height > 4096) {
          record['status'] = 'fixtureExceedsBoundedFullDecode';
          continue;
        }
        buffer = await ui.ImmutableBuffer.fromFilePath(path);
        descriptor = await ui.ImageDescriptor.encoded(buffer);
        codec = await descriptor.instantiateCodec();
        frame = (await codec.getNextFrame()).image;
        record.addAll({
          'flutterWidth': frame.width,
          'flutterHeight': frame.height,
          'flutterColorSpace': frame.colorSpace.name,
          'flutterDescriptorWidth': descriptor.width,
          'flutterDescriptorHeight': descriptor.height,
        });
        if (fixture.$1.contains('p3-icc') || fixture.$1.contains('adobe-rgb')) {
          try {
            final extended = await frame.toByteData(
              format: ui.ImageByteFormat.rawExtendedRgba128,
            );
            if (extended != null) {
              final minima = List<double>.filled(4, double.infinity);
              final maxima = List<double>.filled(4, double.negativeInfinity);
              var outOfSrgbComponents = 0;
              for (var offset = 0;
                  offset + 16 <= extended.lengthInBytes;
                  offset += 16) {
                for (var channel = 0; channel < 4; channel++) {
                  final value = extended.getFloat32(
                    offset + channel * 4,
                    Endian.host,
                  );
                  minima[channel] = math.min(minima[channel], value);
                  maxima[channel] = math.max(maxima[channel], value);
                  if (channel < 3 && (value < 0 || value > 1)) {
                    outOfSrgbComponents++;
                  }
                }
              }
              record['flutterExtendedRgbaMinima'] = minima;
              record['flutterExtendedRgbaMaxima'] = maxima;
              record['flutterExtendedOutOfSrgbComponents'] =
                  outOfSrgbComponents;
              record['nativeCanPreserveExtendedGamut'] = false;
            } else {
              record['flutterExtendedReadback'] = 'null';
            }
          } catch (error) {
            record['flutterExtendedReadback'] = error.toString();
          }
        }
        if (frame.width != metadata.width || frame.height != metadata.height) {
          record['status'] = 'orientationDimensionsDiffer';
          continue;
        }
        final reference = await frame.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        if (reference == null) {
          throw StateError('Flutter returned no RGBA bytes');
        }
        final sampleWidth = math.min(512, metadata.width);
        final sampleHeight = math.min(512, metadata.height);
        // Use a non-iMCU boundary wherever possible to expose crop seams.
        final sampleX = math.min(101, metadata.width - sampleWidth);
        final sampleY = math.min(73, metadata.height - sampleHeight);
        record['sourceRect'] = [sampleX, sampleY, sampleWidth, sampleHeight];
        region = await engine.decodeRegion(
          path,
          NativeImageRect(sampleX, sampleY, sampleWidth, sampleHeight),
          backingPath: '${workspace.path}/${fixture.$1}.pixels',
          memoryBudgetBytes: 64 << 20,
          diskBudgetBytes: 64 << 20,
          premultiplyAlpha: true,
        );
        record.addAll({
          'nativeWidth': region.width,
          'nativeHeight': region.height,
          'nativeStride': region.stride,
          'nativeByteLength': region.bytes.length,
          'nativeBackend': region.backend,
          'nativeColorSpace': region.colorSpace,
          'nativeCodecMicroseconds': region.elapsedMicroseconds,
          'nativeWorkingPeakBytes': region.workingPeakBytes,
          'nativePremultipliedAlpha': region.premultipliedAlpha,
        });
        if (region.width != sampleWidth || region.height != sampleHeight) {
          record['status'] = 'regionDimensionsDiffer';
          continue;
        }
        if (region.stride < region.width * 4 ||
            region.bytes.length < region.stride * region.height) {
          record['status'] = 'regionBufferInvalid';
          continue;
        }
        record.addAll({
          ..._compareRegion(
            reference.buffer.asUint8List(
              reference.offsetInBytes,
              reference.lengthInBytes,
            ),
            frame.width * 4,
            region.bytes,
            region.stride,
            sampleX,
            sampleY,
            sampleWidth,
            sampleHeight,
          ),
          'status': 'measured',
        });
      } catch (error) {
        record['status'] = 'error';
        record['error'] = error.toString();
      } finally {
        region?.dispose();
        frame?.dispose();
        codec?.dispose();
        descriptor?.dispose();
        buffer?.dispose();
      }
    }
  } finally {
    // Only this run's generated backing directory is removed.
    await workspace.delete(recursive: true);
  }
  report['allCasesMeasured'] =
      cases.every((item) => item['status'] == 'measured');
  report['allMeasuredPixelsEqual'] = cases.every(
    (item) => item['status'] == 'measured' && item['mismatchedChannels'] == 0,
  );
  report['rawRgbaComparisonCannotProveWideGamutPreservation'] = true;
  report['animationChecks'] = await runImagePipeline022AnimationChecks(
    fixturesPath,
  );
  return report;
}

Future<List<Map<String, Object?>>> runImagePipeline022AnimationChecks(
  String fixturesPath,
) async {
  final cases = <Map<String, Object?>>[];
  for (final name in ['16x16-two-frame.gif', '16x16-two-frame.webp']) {
    final record = <String, Object?>{'file': name};
    cases.add(record);
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      void phase(String value) => print('PICAKEEP_022_ANIMATION $name $value');
      final path = '${Directory(fixturesPath).path}/$name';
      phase('fixture-exists');
      if (!await File(path).exists()) {
        record['status'] = 'fixtureMissing';
        continue;
      }
      phase('immutable-buffer-start');
      buffer = await ui.ImmutableBuffer.fromFilePath(path)
          .timeout(const Duration(seconds: 10));
      phase('descriptor-start');
      descriptor = await ui.ImageDescriptor.encoded(buffer)
          .timeout(const Duration(seconds: 10));
      phase('codec-start');
      codec = await descriptor
          .instantiateCodec()
          .timeout(const Duration(seconds: 10));
      record['frameCount'] = codec.frameCount;
      phase('codec-ready frameCount=${codec.frameCount}');
      final durationMs = <int>[];
      final dimensions = <List<int>>[];
      final pixels = <Uint8List>[];
      for (var i = 0; i < math.min(2, codec.frameCount); i++) {
        phase('frame-$i-start');
        final frame =
            await codec.getNextFrame().timeout(const Duration(seconds: 10));
        image = frame.image;
        dimensions.add([image.width, image.height]);
        durationMs.add(frame.duration.inMilliseconds);
        phase('frame-$i-readback-start');
        final bytes = await image
            .toByteData(format: ui.ImageByteFormat.rawRgba)
            .timeout(const Duration(seconds: 10));
        if (bytes == null) throw StateError('Animation returned no RGBA bytes');
        pixels.add(Uint8List.fromList(bytes.buffer.asUint8List(
          bytes.offsetInBytes,
          bytes.lengthInBytes,
        )));
        image.dispose();
        image = null;
        phase('frame-$i-finished');
      }
      var changedChannels = 0;
      if (pixels.length == 2 && pixels[0].length == pixels[1].length) {
        for (var i = 0; i < pixels[0].length; i++) {
          if (pixels[0][i] != pixels[1][i]) changedChannels++;
        }
      }
      record.addAll({
        'dimensions': dimensions,
        'durationMs': durationMs,
        'changedChannelsBetweenFrames': changedChannels,
        'status': codec.frameCount == 2 && changedChannels > 0
            ? 'measured'
            : 'animationFramesDiffer',
      });
      phase('finished status=${record['status']}');
    } catch (error) {
      record['status'] = 'error';
      record['error'] = error.toString();
      print('PICAKEEP_022_ANIMATION $name error=$error');
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }
  return cases;
}

Map<String, Object?> _compareRegion(
  Uint8List reference,
  int referenceStride,
  Uint8List candidate,
  int candidateStride,
  int x,
  int y,
  int width,
  int height,
) {
  final channelMax = List<int>.filled(4, 0);
  final channelSum = List<int>.filled(4, 0);
  final channelMismatch = List<int>.filled(4, 0);
  final examples = <Map<String, Object?>>[];
  var mismatchedPixels = 0;
  var transparentReferencePixels = 0;
  var transparentCandidateRgbNonzero = 0;
  for (var row = 0; row < height; row++) {
    for (var column = 0; column < width; column++) {
      final a = (y + row) * referenceStride + (x + column) * 4;
      final b = row * candidateStride + column * 4;
      var mismatch = false;
      for (var channel = 0; channel < 4; channel++) {
        final delta = (reference[a + channel] - candidate[b + channel]).abs();
        channelMax[channel] = math.max(channelMax[channel], delta);
        channelSum[channel] += delta;
        if (delta != 0) {
          mismatch = true;
          channelMismatch[channel]++;
        }
      }
      if (reference[a + 3] == 0) transparentReferencePixels++;
      if (candidate[b + 3] == 0 &&
          (candidate[b] != 0 ||
              candidate[b + 1] != 0 ||
              candidate[b + 2] != 0)) {
        transparentCandidateRgbNonzero++;
      }
      if (mismatch) {
        mismatchedPixels++;
        if (examples.length < 12) {
          examples.add({
            'sourceXY': [x + column, y + row],
            'flutterRGBA': reference.sublist(a, a + 4),
            'nativeRGBA': candidate.sublist(b, b + 4),
          });
        }
      }
    }
  }
  final pixels = width * height;
  return {
    'comparedPixels': pixels,
    'maxChannelDifference': channelMax.reduce(math.max),
    'meanChannelDifference': channelSum.reduce((a, b) => a + b) / (pixels * 4),
    'perChannelMax': channelMax,
    'perChannelMean': [for (final total in channelSum) total / pixels],
    'perChannelMismatchCount': channelMismatch,
    'mismatchedChannels': channelMismatch.reduce((a, b) => a + b),
    'mismatchedPixels': mismatchedPixels,
    'transparentReferencePixels': transparentReferencePixels,
    'transparentCandidateRgbNonzero': transparentCandidateRgbNonzero,
    'firstMismatchExamples': examples,
  };
}

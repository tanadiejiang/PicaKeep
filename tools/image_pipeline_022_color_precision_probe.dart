// Engine-only precision diagnosis; no production backend or source mutation.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

const _fixtures = <String, String>{
  '640x960-16bit-icc.png':
      'f783b0a9f870aa2180915618195ede2fcd6a28678f980120da472666c0e0ef8c',
  '640x960-gray-16bit-icc.png':
      '208dd92c8bacd8037586e97236897f88056a573397023677647721e5b6cf27b7',
  '640x960-p3-icc.png':
      '75ff614a900acee1f4213cc14b314662fe0f6309be0a95d8476e19db2610c0ec',
  '640x960-adobe-rgb-icc.png':
      'f708ce36fd2b77b9971c9af03adaf5a1c89759afe2c236a3ce5bde7ddaa8e38f',
};
const _regions = <ui.Rect>[
  ui.Rect.fromLTWH(64, 224, 512, 512),
  ui.Rect.fromLTWH(64, 64, 512, 512),
];

Future<Map<String, Object?>> runImagePipeline022ColorPrecisionProbe(
  String fixturesPath, {
  String? artifactsPath,
}) async {
  if (kReleaseMode) {
    throw StateError('Only debug/profile verification is allowed');
  }
  final started = DateTime.now().toUtc();
  final cases = <Map<String, Object?>>[];
  final errors = <Map<String, Object?>>[];
  for (final fixture in _fixtures.entries) {
    final file = File('${Directory(fixturesPath).path}/${fixture.key}');
    final record = <String, Object?>{'fixture': fixture.key};
    cases.add(record);
    ui.Image? original, targeted, repeated;
    final coldMosaics = <(ui.Image, ui.Image, ui.Image, ui.Image)>[];
    final retainedColdOriginals = <ui.Image>[];
    try {
      final before = await file.stat();
      final hash = (await sha256.bind(file.openRead()).first).toString();
      if (before.type != FileSystemEntityType.file ||
          before.size > 64 << 20 ||
          hash != fixture.value) {
        throw StateError('Source SHA or bounded encoded size does not match');
      }
      final header = await file.open();
      late final Uint8List ihdr;
      try {
        ihdr = await header.read(29);
      } finally {
        await header.close();
      }
      if (ihdr.length != 29 ||
          !listEquals(ihdr.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]) ||
          String.fromCharCodes(ihdr.sublist(12, 16)) != 'IHDR') {
        throw StateError('Expected PNG IHDR');
      }
      // Create each tile from a fresh codec before any source toByteData call.
      // The earlier controls read their original first and can hide startup
      // behavior in a cold crop. Preserve both rectangle and translation paths.
      for (final region in _regions) {
        final rectangle = await _coldMosaic(file, region, translate: false);
        try {
          final translation = await _coldMosaic(file, region, translate: true);
          ui.Image? retained;
          try {
            retained = await _coldMosaic(file, region,
                translate: true, retainOriginals: retainedColdOriginals);
            final warm = await _coldMosaic(file, region,
                translate: true, sourceReadback: true);
            coldMosaics.add((rectangle, translation, retained, warm));
          } catch (_) {
            translation.dispose();
            retained?.dispose();
            rethrow;
          }
        } catch (_) {
          rectangle.dispose();
          rethrow;
        }
      }
      original = await _decode(file);
      targeted = await _decode(file,
          targetWidth: original.width, targetHeight: original.height);
      repeated = await _decode(file);
      if (original.width != 640 || original.height != 960) {
        throw StateError(
            'This diagnosis is restricted to the fixed 640x960 sources');
      }
      final originalReadback = await _read(original);
      record.addAll({
        'sourceSha256Before': hash,
        'sourceBytes': before.size,
        'sourceBitDepth': ihdr[24],
        'sourcePngColorType': ihdr[25],
        'sourceImagePixels': [original.width, original.height],
        'sourceImageColorSpace': original.colorSpace.name,
        'sourceRgba8Sha256': sha256.convert(originalReadback.rgba).toString(),
        'sourceAlpha': _alpha(originalReadback.rgba),
        'floatSourceReadback': originalReadback.floatFacts,
        'repeatCodecVsOriginal':
            _compare(originalReadback, await _read(repeated), 640, 960),
        'explicitOriginalTargetCodecVsOriginal':
            _compare(originalReadback, await _read(targeted), 640, 960),
      });
      repeated.dispose();
      repeated = null;
      final regions = <Map<String, Object?>>[];
      record['regions'] = regions;
      for (var regionIndex = 0; regionIndex < _regions.length; regionIndex++) {
        final region = _regions[regionIndex];
        final reference =
            await _direct(original, region, ui.FilterQuality.none);
        try {
          final referenceData = await _read(reference);
          final variants = <Map<String, Object?>>[];
          regions.add({
            'sourceRect': [
              region.left,
              region.top,
              region.width,
              region.height
            ],
            'reference':
                'Independent original codec; one direct full-image draw over opaque black; integer translation and clip; none',
            'referenceColorSpace': reference.colorSpace.name,
            'referenceRgba8Sha256':
                sha256.convert(referenceData.rgba).toString(),
            'variants': variants,
          });
          Future<void> measure(String name, Future<ui.Image> Function() render,
              {Map<String, Object?>? intermediateFacts}) async {
            final candidate = await render();
            try {
              final diff =
                  _compare(referenceData, await _read(candidate), 512, 512);
              final item = <String, Object?>{
                'operation': name,
                'candidatePixels': [candidate.width, candidate.height],
                'candidateColorSpace': candidate.colorSpace.name,
                ...diff,
                if (intermediateFacts != null)
                  'intermediate': intermediateFacts,
              };
              if (artifactsPath != null && diff['rgba8Exact'] != true) {
                final root =
                    await Directory(artifactsPath).create(recursive: true);
                final prefix = '${fixture.key}-$regionIndex-$name';
                item['artifacts'] = {
                  'actual':
                      await _png(candidate, '${root.path}/$prefix-actual.png'),
                  'reference': await _png(
                      reference, '${root.path}/$prefix-reference.png'),
                };
              }
              variants.add(item);
            } finally {
              candidate.dispose();
            }
          }

          await measure('repeat-direct-whole-none',
              () => _direct(original!, region, ui.FilterQuality.none));
          await measure('cold-codec-grid512-rect-none',
              () async => coldMosaics[regionIndex].$1.clone());
          await measure('cold-codec-grid512-translate-none',
              () async => coldMosaics[regionIndex].$2.clone());
          await measure('cold-codec-grid512-retain-original-none',
              () async => coldMosaics[regionIndex].$3.clone());
          await measure('codec-source-readback-grid512-translate-none',
              () async => coldMosaics[regionIndex].$4.clone(),
              intermediateFacts: {
                'diagnosticSourceReadback': true,
                'sourceReadbackBytesPerTile': 640 * 960 * 4,
                'productionEnabled': false,
              });
          await measure('targeted-direct-whole-none',
              () => _direct(targeted!, region, ui.FilterQuality.none));
          await measure(
              'targeted-direct-roi-medium',
              () => _direct(targeted!, region, ui.FilterQuality.medium,
                  crop: true));
          await measure('direct-original-roi-overlay-twice-medium',
              () => _overlayTwice(original!, region, ui.FilterQuality.medium));
          await measure('direct-original-roi-overlay-twice-none',
              () => _overlayTwice(original!, region, ui.FilterQuality.none));
          for (final filter in const [
            ui.FilterQuality.none,
            ui.FilterQuality.medium
          ]) {
            for (final whole in [false, true]) {
              final inputRect =
                  whole ? const ui.Rect.fromLTWH(0, 0, 640, 960) : region;
              final intermediate = await _crop(targeted, inputRect, filter);
              try {
                final expected = _slice(originalReadback, 640, inputRect);
                final intermediateFacts = <String, Object?>{
                  'pixels': [intermediate.width, intermediate.height],
                  'colorSpace': intermediate.colorSpace.name,
                  'background': 'transparent',
                  'vsOriginalSourceRoi': _compare(
                      expected,
                      await _read(intermediate),
                      inputRect.width.toInt(),
                      inputRect.height.toInt()),
                };
                await measure(
                    'transparent-${whole ? 'whole' : 'crop'}-${filter.name}',
                    () => _direct(
                        intermediate,
                        whole ? region : const ui.Rect.fromLTWH(0, 0, 512, 512),
                        ui.FilterQuality.none),
                    intermediateFacts: intermediateFacts);
              } finally {
                intermediate.dispose();
              }
            }
            await measure('transparent-grid512-${filter.name}',
                () => _mosaic(targeted!, region, filter));
          }
          final sourceRoi = _slice(originalReadback, 640, region);
          for (final floatPixels in [false, true]) {
            if (floatPixels && sourceRoi.extended == null) continue;
            final extended = sourceRoi.extended;
            final pixels = floatPixels
                ? extended!.buffer
                    .asUint8List(extended.offsetInBytes, extended.lengthInBytes)
                : sourceRoi.rgba;
            ui.Image intermediate;
            try {
              intermediate = await _rawImage(pixels, region.width.toInt(),
                  region.height.toInt(), floatPixels);
            } catch (error) {
              final unsupportedFloatFormat = floatPixels &&
                  '$error'
                      .contains('Failed to get color type from pixel format.');
              if (!unsupportedFloatFormat) rethrow;
              variants.add({
                'operation': 'source-readback-roi-float32',
                'status': 'unsupported',
                'reason':
                    'The Android Flutter engine cannot construct an rgbaFloat32 image from raw pixels',
                'engineError': '$error',
                'rawTargetFormat': 'rgbaFloat32',
                'productionEnabled': false,
                'thresholdApplied': false,
              });
              continue;
            }
            try {
              await measure(
                  'source-readback-roi-${floatPixels ? 'float32' : 'rgba8'}',
                  () => _direct(
                      intermediate,
                      const ui.Rect.fromLTWH(0, 0, 512, 512),
                      ui.FilterQuality.none),
                  intermediateFacts: {
                    'diagnosticSourceReadback': true,
                    'rawRoiBytes': pixels.length,
                    'rawTargetFormat': floatPixels ? 'rgbaFloat32' : 'dontCare',
                    'productionEnabled': false,
                    'vsOriginalSourceRoi': _compare(
                        sourceRoi, await _read(intermediate), 512, 512),
                  });
            } catch (error) {
              final unsupportedFloatFormat = floatPixels &&
                  '$error'
                      .contains('Failed to get color type from pixel format.');
              if (!unsupportedFloatFormat) rethrow;
              variants.add({
                'operation': 'source-readback-roi-float32',
                'status': 'unsupported',
                'reason':
                    'The Android Flutter engine cannot read back an rgbaFloat32 image',
                'engineError': '$error',
                'rawTargetFormat': 'rgbaFloat32',
                'productionEnabled': false,
                'thresholdApplied': false,
              });
            } finally {
              intermediate.dispose();
            }
          }
        } finally {
          reference.dispose();
        }
      }
      final after = await file.stat();
      final afterHash = (await sha256.bind(file.openRead()).first).toString();
      record.addAll({
        'sourceSha256After': afterHash,
        'sourceUnchanged': hash == afterHash &&
            before.size == after.size &&
            before.modified == after.modified,
        'status': 'measured',
      });
      if (record['sourceUnchanged'] != true) {
        throw StateError('Original source changed');
      }
    } catch (error, stack) {
      record.addAll({'status': 'error', 'error': '$error', 'stack': '$stack'});
      errors.add({'fixture': fixture.key, 'error': '$error'});
    } finally {
      for (final pair in coldMosaics) {
        pair.$1.dispose();
        pair.$2.dispose();
        pair.$3.dispose();
        pair.$4.dispose();
      }
      for (final image in retainedColdOriginals) {
        image.dispose();
      }
      repeated?.dispose();
      targeted?.dispose();
      original?.dispose();
    }
  }
  return {
    'schema': 'image-pipeline-022-color-precision-v3',
    'platform': Platform.operatingSystem,
    'buildMode': kProfileMode ? 'profile' : 'debug',
    'startedUtc': started.toIso8601String(),
    'finishedUtc': DateTime.now().toUtc().toIso8601String(),
    'status': errors.isEmpty ? 'measured' : 'incomplete',
    'thresholdApplied': false,
    'automaticQualityAcceptance': false,
    'projection':
        'Integer original-coordinate ROI at 1 physical pixel per source pixel; no PhotoView, device transform or Surface',
    'scope':
        'Canvas RGBA8 and available rawExtendedRgba128; not source 16-bit preservation, native codec, HDR display, compositor scan-out or GPU texture-limit proof',
    'boundedWholeScope': {
      'allowedSourcePixels': [640, 960],
      'maximumSourcePixels': 614400,
      'largestImageEdge': 960,
      'rgba8ImageBytes': 2457600,
      'rgbaFloatReadbackBytes': 9830400,
      'imageAllocationBytesMeasured': false,
      'productionAdmission':
          'Whole-image bypass needs metadata/encoded-size bounds, scheduler working reservation, per-surface/global resident allowance, and a verified platform texture edge; these small cases do not authorize larger 16-bit or wide-gamut whole images',
    },
    'cases': cases,
    'errors': errors,
  };
}

Future<ui.Image> _decode(File file,
    {int? targetWidth, int? targetHeight}) async {
  final buffer = await ui.ImmutableBuffer.fromFilePath(file.path);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    if (descriptor.width != 640 || descriptor.height != 960) {
      throw StateError('Decode exceeds the fixed fixture dimensions');
    }
    codec = await descriptor.instantiateCodec(
        targetWidth: targetWidth, targetHeight: targetHeight);
    if (codec.frameCount != 1) throw StateError('Static fixture required');
    return (await codec.getNextFrame()).image;
  } finally {
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}

Future<ui.Image> _picture(int width, int height, void Function(ui.Canvas) draw,
    {bool black = false}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  if (black) canvas.drawColor(const ui.Color(0xff000000), ui.BlendMode.src);
  draw(canvas);
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(width, height);
  } finally {
    picture.dispose();
  }
}

Future<ui.Image> _direct(
        ui.Image image, ui.Rect region, ui.FilterQuality filter,
        {bool crop = false}) =>
    _picture(region.width.toInt(), region.height.toInt(), (canvas) {
      final paint = ui.Paint()..filterQuality = filter;
      if (crop) {
        canvas.drawImageRect(image, region,
            ui.Rect.fromLTWH(0, 0, region.width, region.height), paint);
      } else {
        canvas.translate(-region.left, -region.top);
        canvas.drawImageRect(
            image,
            ui.Rect.fromLTWH(
                0, 0, image.width.toDouble(), image.height.toDouble()),
            ui.Rect.fromLTWH(
                0, 0, image.width.toDouble(), image.height.toDouble()),
            paint);
      }
    }, black: true);

Future<ui.Image> _crop(
        ui.Image image, ui.Rect region, ui.FilterQuality filter) =>
    _picture(region.width.toInt(), region.height.toInt(), (canvas) {
      canvas.drawImageRect(
          image,
          region,
          ui.Rect.fromLTWH(0, 0, region.width, region.height),
          ui.Paint()..filterQuality = filter);
    });

Future<ui.Image> _overlayTwice(
        ui.Image image, ui.Rect region, ui.FilterQuality filter) =>
    _picture(region.width.toInt(), region.height.toInt(), (canvas) {
      final paint = ui.Paint()..filterQuality = filter;
      for (var i = 0; i < 2; i++) {
        canvas.drawImageRect(image, region,
            ui.Rect.fromLTWH(0, 0, region.width, region.height), paint);
      }
    }, black: true);

Future<ui.Image> _mosaic(
    ui.Image original, ui.Rect region, ui.FilterQuality filter) async {
  final tiles = <(ui.Rect, ui.Image)>[];
  try {
    for (var y = 0; y < original.height; y += 512) {
      for (var x = 0; x < original.width; x += 512) {
        final rect = ui.Rect.fromLTWH(
            x.toDouble(),
            y.toDouble(),
            math.min(512, original.width - x).toDouble(),
            math.min(512, original.height - y).toDouble());
        if (rect.overlaps(region)) {
          tiles.add((rect, await _crop(original, rect, filter)));
        }
      }
    }
    return await _picture(region.width.toInt(), region.height.toInt(),
        (canvas) {
      canvas.translate(-region.left, -region.top);
      for (final tile in tiles) {
        canvas.drawImage(tile.$2, tile.$1.topLeft,
            ui.Paint()..filterQuality = ui.FilterQuality.none);
      }
    }, black: true);
  } finally {
    for (final tile in tiles) {
      tile.$2.dispose();
    }
  }
}

Future<ui.Image> _coldMosaic(File file, ui.Rect region,
    {required bool translate,
    List<ui.Image>? retainOriginals,
    bool sourceReadback = false}) async {
  final tiles = <(ui.Rect, ui.Image)>[];
  try {
    for (var y = 0; y < 960; y += 512) {
      for (var x = 0; x < 640; x += 512) {
        final rect = ui.Rect.fromLTWH(
            x.toDouble(),
            y.toDouble(),
            math.min(512, 640 - x).toDouble(),
            math.min(512, 960 - y).toDouble());
        if (!rect.overlaps(region)) continue;
        final original =
            await _decode(file, targetWidth: 640, targetHeight: 960);
        try {
          if (sourceReadback) {
            final data =
                await original.toByteData(format: ui.ImageByteFormat.rawRgba);
            if (data?.lengthInBytes != 640 * 960 * 4) {
              throw StateError('Diagnostic source readback dimensions changed');
            }
          }
          tiles.add((
            rect,
            await _picture(rect.width.toInt(), rect.height.toInt(), (canvas) {
              final paint = ui.Paint()..filterQuality = ui.FilterQuality.none;
              if (translate) {
                canvas.drawImage(original, -rect.topLeft, paint);
              } else {
                canvas.drawImageRect(original, rect,
                    ui.Rect.fromLTWH(0, 0, rect.width, rect.height), paint);
              }
            })
          ));
        } finally {
          if (retainOriginals == null) {
            original.dispose();
          } else {
            retainOriginals.add(original);
          }
        }
      }
    }
    return await _picture(region.width.toInt(), region.height.toInt(),
        (canvas) {
      canvas.translate(-region.left, -region.top);
      for (final tile in tiles) {
        canvas.drawImage(tile.$2, tile.$1.topLeft,
            ui.Paint()..filterQuality = ui.FilterQuality.none);
      }
    }, black: true);
  } finally {
    for (final tile in tiles) {
      tile.$2.dispose();
    }
  }
}

Future<ui.Image> _rawImage(
    Uint8List pixels, int width, int height, bool floatPixels) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  try {
    descriptor = ui.ImageDescriptor.raw(buffer,
        width: width,
        height: height,
        rowBytes: width * (floatPixels ? 16 : 4),
        pixelFormat:
            floatPixels ? ui.PixelFormat.rgbaFloat32 : ui.PixelFormat.rgba8888);
    codec = await descriptor.instantiateCodec(
        targetFormat: floatPixels
            ? ui.TargetPixelFormat.rgbaFloat32
            : ui.TargetPixelFormat.dontCare);
    return (await codec.getNextFrame()).image;
  } finally {
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}

class _Readback {
  const _Readback(this.rgba, this.extended, this.floatError);
  final Uint8List rgba;
  final ByteData? extended;
  final String? floatError;
  Map<String, Object?> get floatFacts => {
        'available': extended != null,
        'byteLength': extended?.lengthInBytes,
        'error': floatError,
      };
}

Future<_Readback> _read(ui.Image image) async {
  final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (rgba == null) throw StateError('RGBA8 readback unavailable');
  ByteData? extended;
  String? error;
  try {
    extended =
        await image.toByteData(format: ui.ImageByteFormat.rawExtendedRgba128);
  } catch (value) {
    error = '$value';
  }
  return _Readback(
      Uint8List.fromList(
          rgba.buffer.asUint8List(rgba.offsetInBytes, rgba.lengthInBytes)),
      extended,
      error);
}

_Readback _slice(_Readback original, int stridePixels, ui.Rect region) {
  Uint8List crop(Uint8List bytes, int bytesPerPixel) {
    final width = region.width.toInt(), height = region.height.toInt();
    final result = Uint8List(width * height * bytesPerPixel);
    for (var y = 0; y < height; y++) {
      final start =
          ((region.top.toInt() + y) * stridePixels + region.left.toInt()) *
              bytesPerPixel;
      result.setRange(y * width * bytesPerPixel,
          (y + 1) * width * bytesPerPixel, bytes, start);
    }
    return result;
  }

  final extended = original.extended;
  return _Readback(
      crop(original.rgba, 4),
      extended == null
          ? null
          : ByteData.sublistView(crop(
              extended.buffer
                  .asUint8List(extended.offsetInBytes, extended.lengthInBytes),
              16)),
      original.floatError);
}

Map<String, Object?> _compare(
    _Readback reference, _Readback candidate, int width, int height) {
  if (reference.rgba.length != width * height * 4 ||
      candidate.rgba.length != reference.rgba.length) {
    throw StateError('RGBA dimensions changed');
  }
  final maximum = List<int>.filled(4, 0), sums = List<int>.filled(4, 0);
  final examples = <Map<String, Object?>>[];
  var different = 0;
  for (var offset = 0; offset < reference.rgba.length; offset += 4) {
    var changed = false;
    for (var channel = 0; channel < 4; channel++) {
      final delta =
          (reference.rgba[offset + channel] - candidate.rgba[offset + channel])
              .abs();
      maximum[channel] = math.max(maximum[channel], delta);
      sums[channel] += delta;
      changed |= delta != 0;
    }
    if (changed) {
      different++;
      if (examples.length < 12) {
        examples.add({
          'xy': [(offset ~/ 4) % width, (offset ~/ 4) ~/ width],
          'actual': candidate.rgba.sublist(offset, offset + 4),
          'reference': reference.rgba.sublist(offset, offset + 4),
        });
      }
    }
  }
  final a = reference.extended, b = candidate.extended;
  final floatMaximum = List<double>.filled(4, 0);
  var floatDifferent = 0, nonFinite = 0;
  if (a != null && b != null) {
    if (a.lengthInBytes != width * height * 16 ||
        b.lengthInBytes != a.lengthInBytes) {
      throw StateError('Float readback dimensions changed');
    }
    for (var offset = 0; offset < a.lengthInBytes; offset += 4) {
      final x = a.getFloat32(offset, Endian.host),
          y = b.getFloat32(offset, Endian.host);
      if (!x.isFinite || !y.isFinite) {
        nonFinite++;
        continue;
      }
      final delta = (x - y).abs();
      if (delta != 0) floatDifferent++;
      final channel = (offset ~/ 4) % 4;
      floatMaximum[channel] = math.max(floatMaximum[channel], delta);
    }
  }
  return {
    'comparedPixels': width * height,
    'rgba8Exact': different == 0,
    'differentPixels': different,
    'maxChannelDifferenceRGBA': maximum,
    'sumAbsoluteChannelDifferenceRGBA': sums,
    'firstDifferentPixels': examples,
    'thresholdApplied': false,
    'floatReadback': {
      'available': a != null && b != null,
      'exact':
          a != null && b != null ? floatDifferent == 0 && nonFinite == 0 : null,
      'differentComponents': floatDifferent,
      'nonFiniteComponents': nonFinite,
      'maximumAbsoluteDifferenceRGBA': floatMaximum,
      'referenceError': reference.floatError,
      'candidateError': candidate.floatError,
    },
  };
}

Map<String, Object?> _alpha(Uint8List rgba) {
  var minimum = 255, maximum = 0, transparent = 0, partial = 0;
  for (var i = 3; i < rgba.length; i += 4) {
    final alpha = rgba[i];
    minimum = math.min(minimum, alpha);
    maximum = math.max(maximum, alpha);
    if (alpha == 0) transparent++;
    if (alpha > 0 && alpha < 255) partial++;
  }
  return {
    'minimum': minimum,
    'maximum': maximum,
    'transparentPixels': transparent,
    'partiallyTransparentPixels': partial
  };
}

Future<String> _png(ui.Image image, String path) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  if (data == null) throw StateError('PNG readback unavailable');
  await File(path).writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      flush: true);
  return path;
}

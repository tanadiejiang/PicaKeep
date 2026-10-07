import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:picakeep/foundation/image_pipeline/cover_decode_target.dart';
import 'package:picakeep/foundation/image_pipeline/cover_thumbnail_size.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('cover accounts for height fitting a wide source into a tall frame', () {
    expect(CoverDecodeTarget.dimensions(2000, 1000, 150, 300, BoxFit.cover),
        (600, 300));
    expect(CoverDecodeTarget.dimensions(2000, 1000, 150, 300, BoxFit.contain),
        (150, 75));
    expect(CoverDecodeTarget.dimensions(800, 30000, 150, 300, BoxFit.cover).$2,
        lessThanOrEqualTo(4096));
  });
  test('real decoded cover uses encoded ratio rather than clamped layout ratio',
      () async {
    final encoded =
        Uint8List.fromList(img.encodePng(img.Image(width: 2000, height: 1000)));
    final provider = CoverDecodeTarget(MemoryImage(encoded),
        frameWidth: 150, frameHeight: 300, fit: BoxFit.cover);
    final stream = provider.resolve(ImageConfiguration.empty);
    final complete = Completer<ImageInfo>();
    final listener = ImageStreamListener((frame, _) => complete.complete(frame),
        onError: (Object error, StackTrace? stack) =>
            complete.completeError(error, stack));
    stream.addListener(listener);
    try {
      final frame = await complete.future;
      expect((frame.image.width, frame.image.height), (600, 300));
      frame.dispose();
    } finally {
      stream.removeListener(listener);
    }
  });

  test('cover target keeps high DPR instead of clamping it to 3x', () {
    final target = coverFramePhysicalTarget(const Size(100, 150), 4.1);
    expect(target.width, (100 * 4.1 * 1.35).ceil());
    expect(target.height, (150 * 4.1 * 1.35).ceil());
    expect(target.width, greaterThan((100 * 3 * 1.35).ceil()));
  });
}

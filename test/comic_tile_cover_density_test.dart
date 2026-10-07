import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:picakeep/base.dart';
import 'package:picakeep/components/comic_tile.dart';
import 'package:picakeep/foundation/image_pipeline/cover_decode_target.dart';

void main() {
  testWidgets(
      'real ComicTile decodes enough pixels at DPR 4.5 and updates at 2.75',
      (tester) async {
    final savedSettings = List<String>.of(appdata.settings);
    appdata.settings[44] = '1';
    appdata.settings[72] = '0';
    appdata.settings[73] = '0';
    addTearDown(() {
      appdata.settings
        ..clear()
        ..addAll(savedSettings);
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final image = img.Image(width: 1200, height: 1800);
    img.fill(image, color: img.ColorRgba8(47, 191, 113, 255));
    final provider = MemoryImage(Uint8List.fromList(img.encodePng(image)));
    tester.view.physicalSize = const Size(720, 1200);
    tester.view.devicePixelRatio = 4.5;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                    width: 120,
                    height: 180,
                    child: DownloadedComicTile(
                        name: 'fixture',
                        author: '',
                        imagePath: File(''),
                        imageProvider: provider,
                        optimizeCoverDecode: true,
                        type: null,
                        tag: const [],
                        size: '',
                        onTap: () {},
                        onLongTap: () {},
                        onSecondaryTap: (_) {}))))));
    Future<void> waitFor(int width, int height) async {
      for (var i = 0; i < 100; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)));
        await tester.pump(const Duration(milliseconds: 16));
        final raw = tester.renderObject<RenderImage>(find.byType(RawImage));
        if (raw.image?.width == width && raw.image?.height == height) return;
      }
      final raw = tester.renderObject<RenderImage>(find.byType(RawImage));
      expect((raw.image?.width, raw.image?.height), (width, height));
    }

    final frameSize = tester.getSize(find.byType(Image));
    final target =
        tester.widget<Image>(find.byType(Image)).image as CoverDecodeTarget;
    expect(target.frameWidth, (frameSize.width * 4.5 * 1.35).ceil());
    expect(target.frameHeight, (frameSize.height * 4.5 * 1.35).ceil());
    final dimensions = CoverDecodeTarget.dimensions(
        1200, 1800, target.frameWidth, target.frameHeight, BoxFit.cover);
    await waitFor(dimensions.$1, dimensions.$2);
    expect(dimensions.$1, greaterThanOrEqualTo((frameSize.width * 4.5).ceil()));
    expect(
        dimensions.$2, greaterThanOrEqualTo((frameSize.height * 4.5).ceil()));
    tester.view.devicePixelRatio = 2.75;
    await tester.pump();
    final next =
        tester.widget<Image>(find.byType(Image)).image as CoverDecodeTarget;
    expect(next.frameWidth, (frameSize.width * 2.75 * 1.35).ceil());
    final nextDimensions = CoverDecodeTarget.dimensions(
        1200, 1800, next.frameWidth, next.frameHeight, BoxFit.cover);
    await waitFor(nextDimensions.$1, nextDimensions.$2);
    expect(nextDimensions.$1, lessThan(dimensions.$1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });
}

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:picakeep/base.dart';
import 'package:picakeep/components/comic_tile.dart';
import 'package:picakeep/foundation/image_loader/base_image_provider.dart';
import 'package:picakeep/foundation/image_loader/stream_image_provider.dart';

void main() {
  final savedSettings = List<String>.of(appdata.settings);
  final png = Uint8List.fromList(img.encodePng(img.Image(width: 24, height: 32)
    ..clear(img.ColorRgba8(47, 191, 113, 255))));

  setUp(() {
    appdata.settings[44] = '1';
    appdata.settings[72] = '0';
    appdata.settings[73] = '0';
  });
  tearDown(() {
    appdata.settings
      ..clear()
      ..addAll(savedSettings);
    BaseImageProvider.clearCache();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  Future<void> mount(WidgetTester tester, ImageProvider<Object> provider,
          {bool optimize = true}) =>
      tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SizedBox(
                  width: 120,
                  height: 180,
                  child: DownloadedComicTile(
                      name: 'fixture',
                      author: '',
                      imagePath: File(''),
                      imageProvider: provider,
                      optimizeCoverDecode: optimize,
                      type: null,
                      tag: const [],
                      size: '',
                      onTap: () {},
                      onLongTap: () {},
                      onSecondaryTap: (_) {})))));

  bool hasPixels(WidgetTester tester) {
    final raw = find.byType(RawImage);
    return raw.evaluate().isNotEmpty &&
        tester.renderObject<RenderImage>(raw).image != null;
  }

  Future<void> waitFor(WidgetTester tester, bool Function() condition) async {
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
      if (condition()) return;
    }
    expect(condition(), isTrue, reason: 'cover state did not settle');
  }

  Future<void> fail(WidgetTester tester) async {
    await waitFor(tester,
        () => find.byIcon(Icons.image_not_supported).evaluate().isNotEmpty);
    expect(tester.takeException(), isNull);
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  }

  testWidgets(
      'local cover repairs cached malformed bytes and failed ImageState',
      (tester) async {
    var loads = 0;
    var repaired = false;
    final provider = StreamImageProvider(() async {
      loads++;
      return Stream<List<int>>.value(repaired ? png : const [1, 2, 3]);
    }, 'local_cover::corrupt-repair');
    await mount(tester, provider);
    await fail(tester);
    expect(loads, 1);
    repaired = true;
    // Rebuilding the parent with an equal source key must not refill its budget.
    await mount(tester, provider);
    await tester.pump(const Duration(seconds: 4));
    expect(loads, 1);
    expect(hasPixels(tester), isFalse);
    await tester.pump(const Duration(seconds: 1));
    await waitFor(tester, () => hasPixels(tester));
    expect(loads, 2,
        reason: 'the cached invalid bytes must be reread, not decoded again');
    await mount(tester, provider);
    await tester.pump(const Duration(seconds: 20));
    expect(loads, 2);
    await unmount(tester);
  });

  testWidgets('persistent missing local cover gets only one automatic retry',
      (tester) async {
    var loads = 0;
    final provider = StreamImageProvider(() async {
      loads++;
      return Stream<List<int>>.value(const []);
    }, 'local_cover::always-missing');
    await mount(tester, provider);
    await fail(tester);
    await tester.pump(const Duration(seconds: 5));
    await waitFor(tester, () => loads == 2);
    await fail(tester);
    await mount(tester, provider);
    await tester.pump(const Duration(seconds: 30));
    expect(loads, 2);
    final equalProvider = StreamImageProvider(() async {
      loads++;
      return Stream<List<int>>.value(const []);
    }, provider.imageKey);
    await mount(tester, equalProvider);
    await tester.pump(const Duration(seconds: 30));
    expect(loads, 2,
        reason:
            'a fresh provider object with the same source key is not a retry');
    expect(hasPixels(tester), isFalse);
    await unmount(tester);
  });

  testWidgets('new source resets the bounded retry without keeping old error',
      (tester) async {
    var firstLoads = 0, nextLoads = 0;
    final first = StreamImageProvider(() async {
      firstLoads++;
      return Stream<List<int>>.value(const []);
    }, 'local_cover::first-source');
    await mount(tester, first);
    await fail(tester);
    await tester.pump(const Duration(seconds: 5));
    await waitFor(tester, () => firstLoads == 2);
    await fail(tester);
    final next = StreamImageProvider(() async {
      nextLoads++;
      return Stream<List<int>>.value(nextLoads == 1 ? const [] : png);
    }, 'local_cover::next-source');
    await mount(tester, next);
    await waitFor(tester, () => nextLoads == 1);
    await fail(tester);
    await tester.pump(const Duration(seconds: 5));
    await waitFor(tester, () => hasPixels(tester));
    expect((firstLoads, nextLoads), (2, 2));
    await unmount(tester);
  });

  testWidgets('disposing a failed card cancels its pending retry',
      (tester) async {
    var loads = 0;
    final provider = StreamImageProvider(() async {
      loads++;
      return Stream<List<int>>.value(const []);
    }, 'local_file::dispose-before-retry');
    await mount(tester, provider);
    await fail(tester);
    await unmount(tester);
    await tester.pump(const Duration(seconds: 30));
    expect(loads, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('network cover errors do not use the local recovery budget',
      (tester) async {
    var loads = 0;
    final provider = StreamImageProvider(() async {
      loads++;
      return Stream<List<int>>.value(const []);
    }, 'remote_cover::no-local-retry');
    await mount(tester, provider);
    await fail(tester);
    await tester.pump(const Duration(seconds: 30));
    expect(loads, 1);
    await unmount(tester);
  });

  testWidgets('foreground recovery retries only failed cards and pauses timers',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    var loads = 0;
    var repaired = false;
    final provider = StreamImageProvider(() async {
      loads++;
      return Stream<List<int>>.value(repaired ? png : const []);
    }, 'local_file::foreground-repair');
    await mount(tester, provider);
    await fail(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 30));
    expect(loads, 1, reason: 'a pending retry is cancelled in the background');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 5));
    await waitFor(tester, () => loads == 2);
    await fail(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    repaired = true;
    await tester.pump(const Duration(seconds: 30));
    expect(loads, 2);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 5));
    await waitFor(tester, () => hasPixels(tester));
    expect(loads, 3);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 30));
    expect(loads, 3, reason: 'healthy covers remain cached on resume');
    await unmount(tester);
  });

  testWidgets(
      'ordinary FileImage fast path recovers a file that becomes readable',
      (tester) async {
    final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('comic_cover_recovery_')))!;
    final file = File('${root.path}/cover.png');
    addTearDown(() async {
      await tester.runAsync(() => root.delete(recursive: true));
    });
    await mount(tester, FileImage(file), optimize: false);
    await fail(tester);
    await tester.runAsync(() => file.writeAsBytes(png));
    await mount(tester, FileImage(file), optimize: false);
    await tester.pump(const Duration(seconds: 4));
    expect(hasPixels(tester), isFalse);
    await tester.pump(const Duration(seconds: 1));
    await waitFor(tester, () => hasPixels(tester));
    final raw = tester.renderObject<RenderImage>(find.byType(RawImage));
    expect((raw.image!.width, raw.image!.height), (24, 32));
    await unmount(tester);
  });
}

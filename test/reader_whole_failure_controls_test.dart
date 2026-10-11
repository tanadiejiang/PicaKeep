import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:photo_view/photo_view.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';
import 'package:picakeep/foundation/image_pipeline/image_work_scheduler.dart';
import 'package:picakeep/foundation/image_pipeline/reader_page_source.dart';
import 'package:picakeep/foundation/log.dart';
import 'package:picakeep/foundation/reader_image_quality.dart';
import 'package:picakeep/pages/reader/reader_image_surface.dart';
import 'package:picakeep/pages/reader/reader_page_image.dart';
import 'package:picakeep/pages/reader/reader_whole_image.dart';

import 'support/image_disk_quota_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late File original;
  late Digest originalHash;
  late ImageDiskQuota quota;
  final previousQuota = ImageDiskQuota.overrideForTesting;
  final previousLogging = LogManager.recordingEnabled;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('reader_failure_controls_057_');
    App.dataPath = '${root.path}/app';
    App.cachePath = '${root.path}/cache';
    await Directory(App.dataPath).create();
    await Directory(App.cachePath).create();
    LogManager.recordingEnabled = false;
    quota = installTaskDiskQuota(() => [App.cachePath]);
    // Above the conservative texture edge, but only 1 MiB of actual RGBA.
    // This exercises the real metadata/whole path without an enormous fixture.
    original = File('${root.path}/wide.png');
    final pixels = image.Image(width: 5000, height: 50, numChannels: 4);
    image.fill(pixels, color: image.ColorRgba8(40, 120, 180, 255));
    await original.writeAsBytes(image.encodePng(pixels));
    originalHash = sha256.convert(await original.readAsBytes());
  });

  tearDownAll(() async {
    await quota.drain();
    ImageDiskQuota.overrideForTesting = previousQuota;
    LogManager.recordingEnabled = previousLogging;
    expect(root.path.split(Platform.pathSeparator).last,
        startsWith('reader_failure_controls_057_'));
    await root.delete(recursive: true);
  });

  Future<void> waitFor(WidgetTester tester, bool Function() ready) async {
    for (var index = 0; index < 100 && !ready(); index++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(ready(), isTrue);
  }

  for (final dark in [false, true]) {
    for (final textScale in [1.0, 3.0]) {
      testWidgets('strict controls are unscaled, scrollable and actionable: dark=$dark font=$textScale',
          (tester) async {
        tester.view.resetPhysicalSize();
        tester.view.physicalSize = const Size(360, 240);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final controller = PhotoViewController();
        final transforms = ValueNotifier<int>(0);
        var detached = false;
        Future<void> detachAndDrain() async {
          if (detached) return;
          await tester.pumpWidget(const SizedBox());
          await waitFor(tester, () => ReaderPageFileLease.activeLeaseCount == 0 &&
              ImageWorkScheduler.shared.activeCount == 0 &&
              ReaderWholeImageResidency.shared.bytes == 0);
          detached = true;
        }
        addTearDown(() async {
          try {
            await detachAndDrain();
          } finally {
            controller.dispose();
            transforms.dispose();
          }
        });
        final viewport = GlobalKey();
        var policy = ReaderLargeImagePolicy.strictOriginal;
        var invalidations = 0;
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
          home: MediaQuery(
            data: MediaQueryData(size: const Size(360, 240),
                textScaler: TextScaler.linear(textScale)),
            child: Scaffold(body: StatefulBuilder(builder: (context, setHostState) =>
              SizedBox.expand(key: viewport, child: ReaderPageImage(
                resourceKey: 'wide-original',
                loadSource: () async => FileReaderPageSource(
                  identity: const ReaderPageIdentity(sourceKey: 'fixture', workId: 'wide',
                      downloadId: 'fixture-wide', episode: 1, page: 0, sourceVersion: 'one'),
                  file: original),
                viewportKey: viewport,
                transformChanges: transforms,
                controller: controller,
                mode: ReaderDisplayMode.sharpFirst,
                largeImagePolicy: policy,
                // This suite checks live controls/decoding, not asynchronous
                // derivative persistence that could outlive a failed fixture.
                persistRaster: false,
                onInvalidate: () async { invalidations++; },
                onUseSafeWhole: () => setHostState(() => policy = ReaderLargeImagePolicy.safeWhole),
              )))),
          ),
        ));
        final safe = find.widgetWithText(TextButton, '改为安全整图显示');
        await waitFor(tester, () => safe.evaluate().isNotEmpty &&
            find.byType(PhotoView).evaluate().isEmpty);
        expect(find.byType(PhotoView), findsNothing,
            reason: 'error controls must not inherit the 5000px source fit transform');
        expect(find.byType(ReaderImageSurface), findsNothing);
        await tester.ensureVisible(safe);
        await tester.pump();
        final box = tester.renderObject<RenderBox>(safe);
        final top = box.localToGlobal(Offset.zero);
        final bottom = box.localToGlobal(Offset(box.size.width, box.size.height));
        expect(bottom.dy - top.dy, greaterThanOrEqualTo(48));
        expect(top.dy, greaterThanOrEqualTo(-0.01));
        expect(bottom.dy, lessThanOrEqualTo(240.01));
        expect(tester.takeException(), isNull);
        await tester.tap(safe);
        await waitFor(tester, () => find.byType(RawImage).evaluate().isNotEmpty);
        expect(policy, ReaderLargeImagePolicy.safeWhole);
        expect(invalidations, 0, reason: 'policy changes must not invalidate originals');
        expect(find.byType(ReaderImageSurface), findsNothing);
        expect(find.byType(ReaderWholeImage), findsOneWidget);
        expect(await tester.runAsync(() async => sha256.convert(await original.readAsBytes())), originalHash);
        await detachAndDrain();
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('continuous wide-page error has usable controls but successful geometry stays exact',
      (tester) async {
    tester.view.physicalSize = const Size(360, 240);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final transforms = ValueNotifier<int>(0);
    final viewport = GlobalKey();
    var policy = ReaderLargeImagePolicy.strictOriginal;
    var invalidations = 0;
    var detached = false;
    Future<void> detachAndDrain() async {
      if (detached) return;
      await tester.pumpWidget(const SizedBox());
      await waitFor(tester, () => ReaderPageFileLease.activeLeaseCount == 0 &&
          ImageWorkScheduler.shared.activeCount == 0 &&
          ReaderWholeImageResidency.shared.bytes == 0);
      detached = true;
    }
    addTearDown(() async {
      try {
        await detachAndDrain();
      } finally {
        transforms.dispose();
      }
    });
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: StatefulBuilder(builder: (context, setHostState) =>
        SingleChildScrollView(child: SizedBox(key: viewport, width: 360,
          child: ReaderPageImage(
            resourceKey: 'continuous-wide-original',
            loadSource: () async => FileReaderPageSource(
              identity: const ReaderPageIdentity(sourceKey: 'fixture', workId: 'wide',
                  downloadId: 'fixture-wide', episode: 1, page: 0, sourceVersion: 'one'),
              file: original),
            viewportKey: viewport,
            transformChanges: transforms,
            continuousWidth: 360,
            sizeHint: const Size(5000, 50),
            mode: ReaderDisplayMode.sharpFirst,
            largeImagePolicy: policy,
            persistRaster: false,
            onInvalidate: () async { invalidations++; },
            onUseSafeWhole: () => setHostState(() => policy = ReaderLargeImagePolicy.safeWhole),
          )))),
    )));
    final page = find.byType(ReaderPageImage);
    final safe = find.widgetWithText(TextButton, '改为安全整图显示');
    await waitFor(tester, () => safe.evaluate().isNotEmpty &&
        tester.getSize(page).height >= 160);
    expect(find.byType(PhotoView), findsNothing);
    expect(tester.getSize(page).height, 160);
    await tester.ensureVisible(safe);
    await tester.pump();
    final box = tester.renderObject<RenderBox>(safe);
    final top = box.localToGlobal(Offset.zero);
    final bottom = box.localToGlobal(Offset(box.size.width, box.size.height));
    expect(bottom.dy - top.dy, greaterThanOrEqualTo(48));
    expect(top.dy, greaterThanOrEqualTo(-0.01));
    expect(bottom.dy, lessThanOrEqualTo(240.01));
    await tester.tap(safe);
    await waitFor(tester, () => find.byType(RawImage).evaluate().isNotEmpty);
    expect(policy, ReaderLargeImagePolicy.safeWhole);
    expect(invalidations, 0);
    expect(tester.getSize(page).height, closeTo(360 * 50 / 5000, 0.000001),
        reason: 'only error cards are enlarged; successful source aspect is unchanged');
    expect(find.byType(ReaderImageSurface), findsNothing);
    expect(await tester.runAsync(() async => sha256.convert(await original.readAsBytes())), originalHash);
    await detachAndDrain();
    expect(tester.takeException(), isNull);
  });
}

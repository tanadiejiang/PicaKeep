import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/components/pixiv_bookmark_feedback.dart';

/// Captures actual Host/ticket frames for an offline GIF. No simulated UI.
void main() {
  testWidgets('capture three real tickets completing and leaving FIFO',
      (tester) async {
    const viewport = Size(320, 180);
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      final sans = File('C:/Windows/Fonts/msyh.ttc');
      final icons =
          File('build/unit_test_assets/fonts/MaterialIcons-Regular.otf');
      expect(sans.existsSync(), isTrue,
          reason: 'Capture must use a real Chinese font.');
      expect(icons.existsSync(), isTrue,
          reason: 'Capture must use actual Material icon glyphs.');
      await (FontLoader('QueueCaptureSans')
            ..addFont(
                Future.value(ByteData.sublistView(await sans.readAsBytes()))))
          .load();
      await (FontLoader('MaterialIcons')
            ..addFont(
                Future.value(ByteData.sublistView(await icons.readAsBytes()))))
          .load();
    });

    late PixivBookmarkFeedbackController controller;
    final captureKey = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFB92E58)),
        fontFamily: 'QueueCaptureSans',
      ),
      home: MediaQuery(
        data: const MediaQueryData(size: viewport),
        child: RepaintBoundary(
          key: captureKey,
          child: Material(
            child: PixivBookmarkFeedbackHost(
              bottomOffset: 16,
              child: Builder(builder: (context) {
                controller = PixivBookmarkFeedbackHost.maybeOf(context)!;
                return const SizedBox.expand();
              }),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final tickets = <String, PixivBookmarkFeedbackTicket>{
      for (final id in ['A', 'B', 'C'])
        id: controller.capture(account: 'offline-capture', workId: id),
    };
    final frames = <Map<String, Object?>>[];
    var elapsed = 0;
    const outputPath = 'docs/verification/pixiv-bookmark-queue-counts-036/animation';

    Future<void> advance(int milliseconds) async {
      elapsed += milliseconds;
      await tester.pump(Duration(milliseconds: milliseconds));
    }

    Future<void> capture(String label) async {
      final index = frames.length;
      final filename = 'frame-${index.toString().padLeft(3, '0')}.png';
      final feedback = find.byKey(const ValueKey('pixiv-bookmark-feedback'));
      final rect =
          feedback.evaluate().isEmpty ? null : tester.getRect(feedback);
      if (rect != null) {
        expect(rect.left, greaterThanOrEqualTo(16));
        expect(rect.right, lessThanOrEqualTo(viewport.width - 16));
        expect(rect.top, greaterThanOrEqualTo(8));
        expect(rect.bottom, lessThanOrEqualTo(viewport.height - 16));
      }
      final snapshots = <Map<String, Object?>>[];
      for (final entry in controller.entries) {
        final id = entry.operationId;
        final translation = tester.widget<Transform>(
            find.byKey(ValueKey('pixiv-bookmark-queue-exit-translation-$id')));
        final opacity = tester.widget<FadeTransition>(
            find.byKey(ValueKey('pixiv-bookmark-queue-exit-opacity-$id')));
        final size = tester.widget<SizeTransition>(
            find.byKey(ValueKey('pixiv-bookmark-queue-exit-size-$id')));
        snapshots.add({
          'operationId': id,
          'workId': entry.workId,
          'status': entry.status.name,
          'text': entry.text,
          'target': entry.target,
          'exiting': entry.exiting,
          'exitTranslateX': translation.transform.entry(0, 3),
          'exitOpacity': opacity.opacity.value,
          'widthFactor': size.sizeFactor.value,
          'entranceOpacity': tester
              .widget<FadeTransition>(find
                  .byKey(ValueKey('pixiv-bookmark-queue-entrance-opacity-$id')))
              .opacity
              .value,
          'entranceTranslateX': tester
              .widget<Transform>(find.byKey(
                  ValueKey('pixiv-bookmark-queue-entrance-translation-$id')))
              .transform
              .entry(0, 3),
          'completionScale': tester
              .widget<Transform>(find
                  .byKey(ValueKey('pixiv-bookmark-queue-completion-scale-$id')))
              .transform
              .entry(0, 0),
          'heartFill': entry.status.name == 'completed'
              ? tester
                  .widget<Opacity>(find
                      .byKey(ValueKey('pixiv-bookmark-queue-heart-fill-$id')))
                  .opacity
              : null,
        });
      }
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final boundary = captureKey.currentContext!.findRenderObject()
            as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        try {
          expect(image.width, 320);
          expect(image.height, 180);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final output = File('$outputPath/$filename');
          await output.parent.create(recursive: true);
          await output.writeAsBytes(data!.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      });
      frames.add({
        'index': index,
        'file': filename,
        'timestampMs': elapsed,
        'label': label,
        'capsule': rect == null
            ? null
            : {
                'left': rect.left,
                'top': rect.top,
                'width': rect.width,
                'height': rect.height,
              },
        'entries': snapshots,
      });
    }

    for (final ticket in tickets.values) {
      ticket.startWaiting(target: true);
    }
    await tester.pump();
    expect(controller.entries.map((entry) => entry.workId), ['A', 'B', 'C']);
    await capture('accepted-three-entrance-0ms');
    await advance(60);
    await capture('three-entrance-60ms');
    await advance(60);
    await capture('three-entrance-120ms');
    await advance(60);
    expect(controller.entries.map((entry) => entry.status.name),
        everyElement('waiting'));
    await capture('three-waiting-180ms');

    expect(tickets['B']!.finish(const PixivBookmarkFeedbackMessage.added()),
        isTrue);
    expect(tickets['C']!.finish(const PixivBookmarkFeedbackMessage.added()),
        isTrue);
    await tester.pump();
    await capture('B-C-completion-0ms');
    await advance(80);
    await capture('B-C-completion-80ms');
    await advance(80);
    expect(controller.entries.map((entry) => entry.status.name),
        ['waiting', 'completed', 'completed']);
    await capture('B-C-completed-A-waiting');

    expect(tickets['A']!.finish(const PixivBookmarkFeedbackMessage.added()),
        isTrue);
    await tester.pump();
    await advance(80);
    await capture('A-completion-80ms');
    await advance(80);
    expect(controller.entries.map((entry) => entry.status.name),
        everyElement('completed'));
    await capture('all-three-completed');

    // A settled at 340ms. Its 2-second readable hold ends at 2340ms;
    // B/C have already completed their hold and wait behind A.
    await advance(1840);
    expect(controller.entries.first.workId, 'A');
    expect(controller.entries.first.exiting, isTrue);
    await capture('A-head-exit-0ms');
    for (final offset in [40, 80, 120, 160, 200]) {
      await advance(40);
      await capture('A-head-exit-${offset}ms');
    }
    await advance(39);
    await capture('A-head-exit-239ms');
    await advance(1);
    expect(controller.entries.map((entry) => entry.workId), ['B', 'C']);
    await capture('A-removed-B-C-retained');

    await advance(180);
    expect(controller.entries.first.workId, 'B');
    expect(controller.entries.first.exiting, isTrue);
    await capture('B-head-exit-0ms');
    await advance(80);
    await capture('B-head-exit-80ms');
    await advance(40);
    await capture('B-head-exit-120ms');
    await advance(40);
    await capture('B-head-exit-160ms');
    await advance(79);
    await capture('B-head-exit-239ms');
    await advance(1);
    expect(controller.entries.single.workId, 'C');
    await capture('B-removed-C-retained');

    await advance(180);
    expect(controller.entries.single.exiting, isTrue);
    await capture('C-head-exit-0ms');
    await advance(80);
    await capture('C-head-exit-80ms');
    await advance(40);
    await capture('C-head-exit-120ms');
    await advance(40);
    await capture('C-head-exit-160ms');
    await advance(79);
    await capture('C-head-exit-239ms');
    await advance(1);
    expect(controller.entries, isEmpty);
    expect(find.byKey(const ValueKey('pixiv-bookmark-feedback')), findsNothing);
    await capture('queue-empty');

    // Preserve exact logical timestamps. GIF encoders may round 1ms to a
    // centisecond; the PNGs and metadata remain the original Flutter frames.
    for (var index = 0; index < frames.length; index++) {
      frames[index]['durationMs'] = index + 1 < frames.length
          ? (frames[index + 1]['timestampMs']! as int) -
              (frames[index]['timestampMs']! as int)
          : 500;
    }
    await tester.runAsync(() async {
      await File('$outputPath/frames.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'source': 'Offline Flutter widget rendering of actual Host/tickets',
          'viewport': {'width': 320, 'height': 180},
          'fontFamily': 'QueueCaptureSans (C:/Windows/Fonts/msyh.ttc)',
          'icons': 'MaterialIcons',
          'reducedMotion': false,
          'account': 'offline-capture',
          'frames': frames,
        }),
      );
    });
    expect(frames, hasLength(29));
    expect(elapsed, 3420);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });
}

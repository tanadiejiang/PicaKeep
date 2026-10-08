import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/components/components.dart' show NaviObserver;
import 'package:picakeep/components/pixiv_bookmark_feedback.dart';

void main() {
  late PixivBookmarkFeedbackController controller;
  late StateSetter change;
  bool active = true;
  Object identity = 'account:A';
  final navigator = GlobalKey<NavigatorState>();
  final captureKey = GlobalKey();
  Future<void> pump(WidgetTester tester, {bool reduced = false}) async {
    active = true;
    identity = 'account:A';
    final observer = NaviObserver();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigator,
      navigatorObservers: [observer],
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: StatefulBuilder(builder: (context, setState) {
          change = setState;
          return PixivBookmarkFeedbackHost(
            active: active,
            identity: identity,
            child: Builder(builder: (context) {
              controller = PixivBookmarkFeedbackHost.maybeOf(context)!;
              return const Center(child: Text('页面内容'));
            }),
          );
        }),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('wait queues immediately, tracks direction and settles once',
      (tester) async {
    await pump(tester);
    final ticket = controller.capture(account: 'A', workId: '1');
    ticket.startWaiting();
    await tester.pump();
    expect(find.text('正在读取收藏状态…'), findsOneWidget);
    ticket.updateWaitingTarget(false);
    await tester.pump();
    expect(find.text('正在读取收藏状态…'), findsNothing);
    expect(find.text('正在取消收藏…'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('pixiv-bookmark-feedback')), findsOneWidget);
    ticket.finish(const PixivBookmarkFeedbackMessage.removed());
    await tester.pumpAndSettle();
    expect(find.text('正在取消收藏…'), findsNothing);
    expect(find.text('已取消收藏'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('已取消收藏'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'older waiting and newer completion retain independent queue results',
      (tester) async {
    await pump(tester);
    final old = controller.capture(account: 'A', workId: '1');
    old.startWaiting(target: true);
    await tester.pump(const Duration(milliseconds: 700));
    final newer = controller.capture(account: 'A', workId: '2');
    newer.startWaiting(target: false);
    newer.finish(const PixivBookmarkFeedbackMessage.removed());
    await tester.pumpAndSettle();
    expect(old.finish(const PixivBookmarkFeedbackMessage.added()), isTrue);
    old.cancelWaiting();
    await tester.pump();
    expect(controller.entries, hasLength(2));
    expect(controller.entries.every((item) => item.status.name == 'completed'),
        isTrue);
    expect(find.textContaining('2 项完成'), findsNothing);
    expect(find.textContaining('正在'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final boundary in ['inactive', 'identity', 'route']) {
    testWidgets(
        '$boundary clears animation, timer and old ticket without revival',
        (tester) async {
      await pump(tester);
      final ticket = controller.capture(account: 'A', workId: '1');
      ticket.startWaiting(target: true);
      ticket.show(const PixivBookmarkFeedbackMessage.added());
      await tester.pump();
      final epoch = controller.visualEpoch;
      if (boundary == 'route') {
        navigator.currentState!
            .push(MaterialPageRoute<void>(builder: (_) => const Text('下一页')));
      } else {
        change(() {
          if (boundary == 'inactive') {
            active = false;
          } else {
            identity = 'account:B';
          }
        });
      }
      await tester.pump();
      expect(ticket.isCurrent, isFalse);
      expect(controller.visualEpoch, greaterThan(epoch));
      expect(find.text('已添加公开收藏', skipOffstage: false), findsNothing);
      if (boundary == 'route') {
        await tester.pumpAndSettle();
        navigator.currentState!.pop();
      } else {
        change(() {
          active = true;
          identity = 'account:A';
        });
      }
      await tester.pumpAndSettle();
      expect(ticket.isCurrent, isFalse);
      expect(
          ticket.finish(const PixivBookmarkFeedbackMessage.added()), isFalse);
      await tester.pump(const Duration(seconds: 2));
      expect(find.textContaining('收藏…'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
      'popup is not a new page, feedback never blocks the underlying button',
      (tester) async {
    await pump(tester);
    final ticket = controller.capture(account: 'A', workId: '1');
    final future = showDialog<void>(
        context: navigator.currentContext!,
        builder: (_) => const AlertDialog(content: Text('确认')));
    await tester.pumpAndSettle();
    expect(ticket.isCurrent, isTrue);
    navigator.currentState!.pop();
    await future;
    await tester.pumpAndSettle();
    expect(ticket.isCurrent, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('queue churn does not restart exit or stagger deadlines',
      (tester) async {
    await pump(tester);
    final head = controller.capture(account: 'A', workId: 'head');
    final next = controller.capture(account: 'A', workId: 'next');
    head.startWaiting(target: true);
    next.startWaiting(target: true);
    head.finish(const PixivBookmarkFeedbackMessage.added());
    next.finish(const PixivBookmarkFeedbackMessage.added());
    await tester.pump(const Duration(seconds: 2));
    expect(controller.entries.first.exiting, isTrue);
    await tester.pump(const Duration(milliseconds: 60));
    final tail = controller.capture(account: 'A', workId: 'cancelled-tail');
    tail.startWaiting(target: true);
    tail.cancelWaiting();
    controller
        .capture(account: 'A', workId: 'live-tail')
        .startWaiting(target: true);
    await tester.pump(const Duration(milliseconds: 179));
    expect(controller.entries.first.workId, 'head');
    await tester.pump(const Duration(milliseconds: 1));
    expect(controller.entries.first.workId, 'next');
    expect(controller.entries.first.exiting, isFalse);
    await tester.pump(const Duration(milliseconds: 90));
    final transient = controller.capture(account: 'A', workId: 'transient');
    transient.startWaiting();
    transient.cancelWaiting();
    await tester.pump(const Duration(milliseconds: 89));
    expect(controller.entries.first.exiting, isFalse);
    await tester.pump(const Duration(milliseconds: 1));
    expect(controller.entries.first.exiting, isTrue);
    await tester.pump(const Duration(milliseconds: 240));
    expect(controller.entries.single.workId, 'live-tail');
    expect(controller.entries.single.status.name, 'waiting');
    await tester.pump(const Duration(seconds: 10));
    expect(controller.entries.single.workId, 'live-tail');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('out-of-order failures show the most recently settled reason',
      (tester) async {
    await pump(tester);
    final semantics = tester.ensureSemantics();
    final first = controller.capture(account: 'A', workId: 'first');
    final second = controller.capture(account: 'A', workId: 'second');
    first.startWaiting(target: true);
    second.startWaiting(target: true);
    second.finish(PixivBookmarkFeedbackMessage.failed('第二项先失败'));
    await tester.pumpAndSettle();
    expect(find.textContaining('第二项先失败'), findsOneWidget);
    first.finish(PixivBookmarkFeedbackMessage.failed('第一项后失败'));
    await tester.pumpAndSettle();
    expect(controller.entries.map((item) => item.workId), ['first', 'second']);
    expect(controller.entries.first.settlementSequence,
        greaterThan(controller.entries.last.settlementSequence!));
    expect(find.textContaining('第一项后失败'), findsOneWidget);
    expect(find.textContaining('第二项先失败'), findsNothing);
    expect(
        tester
            .getSemantics(find.byKey(const ValueKey('pixiv-bookmark-feedback')))
            .label,
        contains('第一项后失败'));
    semantics.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('reduced motion has static entrance and a single live region',
      (tester) async {
    await pump(tester, reduced: true);
    final semantics = tester.ensureSemantics();
    controller
        .capture(account: 'A', workId: '1')
        .show(const PixivBookmarkFeedbackMessage.added());
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
    controller
        .capture(account: 'A', workId: '2')
        .show(const PixivBookmarkFeedbackMessage.removed());
    await tester.pump();
    expect(
        find.byKey(const ValueKey('pixiv-bookmark-feedback')), findsOneWidget);
    expect(controller.entries, hasLength(2));
    expect(find.textContaining('2 项完成'), findsNothing);
    expect(
        tester
            .getSemantics(find.byKey(const ValueKey('pixiv-bookmark-feedback')))
            .label,
        contains('2 项完成'));
    semantics.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final scaffold in [false, true]) {
    testWidgets('keyboard and safe area geometry with scaffold=$scaffold',
        (tester) async {
      tester.view.physicalSize = const Size(375, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final host = PixivBookmarkFeedbackHost(
          avoidViewInsets: true,
          child: Builder(builder: (context) {
            controller = PixivBookmarkFeedbackHost.maybeOf(context)!;
            return const SizedBox.expand();
          }));
      await tester.pumpWidget(MaterialApp(
          home: MediaQuery(
        data: const MediaQueryData(
            size: Size(375, 720),
            viewInsets: EdgeInsets.only(bottom: 280),
            viewPadding: EdgeInsets.only(bottom: 24)),
        child: scaffold ? Scaffold(body: host) : Material(child: host),
      )));
      controller
          .capture(account: 'A', workId: '1')
          .show(const PixivBookmarkFeedbackMessage.added());
      await tester.pumpAndSettle();
      final rect =
          tester.getRect(find.byKey(const ValueKey('pixiv-bookmark-feedback')));
      expect(rect.bottom, closeTo(720 - 280 - 16, 1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final spec in <(String, Size, Brightness, double, bool)>[
    ('light-phone', const Size(375, 720), Brightness.light, 1, false),
    ('dark-phone', const Size(375, 720), Brightness.dark, 1, false),
    ('large-text-error', const Size(375, 720), Brightness.light, 2, true),
    ('landscape', const Size(812, 375), Brightness.dark, 2, true),
    ('waiting-phone', const Size(375, 720), Brightness.light, 1, false),
    ('desktop', const Size(1280, 800), Brightness.light, 1, false),
  ]) {
    testWidgets('actual Flutter capsule geometry and screenshot ${spec.$1}',
        (tester) async {
      tester.view.physicalSize = spec.$2;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        final font = File('C:/Windows/Fonts/msyh.ttc');
        if (font.existsSync()) {
          await (FontLoader('VerificationSans')
                ..addFont(Future.value(
                    ByteData.sublistView(await font.readAsBytes()))))
              .load();
        }
        final iconFont =
            File('build/unit_test_assets/fonts/MaterialIcons-Regular.otf');
        if (iconFont.existsSync()) {
          await (FontLoader('MaterialIcons')
                ..addFont(Future.value(
                    ByteData.sublistView(await iconFont.readAsBytes()))))
              .load();
        }
      });
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(brightness: spec.$3, fontFamily: 'VerificationSans'),
        home: RepaintBoundary(
          key: captureKey,
          child: MediaQuery(
            data: MediaQueryData(
                size: spec.$2, textScaler: TextScaler.linear(spec.$4)),
            child: Material(child:
                PixivBookmarkFeedbackHost(child: Builder(builder: (context) {
              controller = PixivBookmarkFeedbackHost.maybeOf(context)!;
              return ColoredBox(
                  color: Theme.of(context).colorScheme.surface,
                  child: const Center(child: Text('Pixiv 在线收藏反馈')));
            }))),
          ),
        ),
      ));
      controller.capture(account: 'A', workId: '1').show(
          spec.$1 == 'waiting-phone'
              ? const PixivBookmarkFeedbackMessage.waiting(target: true)
              : spec.$5
                  ? PixivBookmarkFeedbackMessage.failed(
                      '网络暂不可用，请检查连接后重试；作品收藏状态保持平台确认值。')
                  : const PixivBookmarkFeedbackMessage.added());
      await tester.pumpAndSettle();
      final rect =
          tester.getRect(find.byKey(const ValueKey('pixiv-bookmark-feedback')));
      expect(rect.left, greaterThanOrEqualTo(16));
      expect(rect.right, lessThanOrEqualTo(spec.$2.width - 16));
      expect(rect.top, greaterThanOrEqualTo(8));
      expect(rect.bottom, lessThanOrEqualTo(spec.$2.height - 16));
      expect(rect.width, lessThanOrEqualTo(420));
      final texts = tester.widgetList<Text>(find.descendant(
          of: find.byKey(const ValueKey('pixiv-bookmark-feedback')),
          matching: find.byType(Text)));
      expect(
          texts.every((text) =>
              text.maxLines == null && text.overflow != TextOverflow.ellipsis),
          isTrue);
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final boundary = captureKey.currentContext!.findRenderObject()
            as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final output = File(
            'docs/verification/pixiv-bookmark-queue-counts-036/${spec.$1}.png');
        await output.parent.create(recursive: true);
        await output.writeAsBytes(bytes!.buffer.asUint8List());
        await File(
                'docs/verification/pixiv-bookmark-queue-counts-036/${spec.$1}-geometry.txt')
            .writeAsString(
                'Viewport: ${spec.$2}\nCapsule: $rect\nText scale: ${spec.$4}\nOffline Flutter widget rendering; not device capture.\n');
        image.dispose();
      });
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

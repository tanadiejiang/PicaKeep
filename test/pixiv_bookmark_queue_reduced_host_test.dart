import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/components/pixiv_bookmark_feedback.dart';

class _HostFixture {
  bool reduced = false;
  late StateSetter change;
  late PixivBookmarkFeedbackController controller;

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(builder: (context, setState) {
        change = setState;
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
          child: PixivBookmarkFeedbackHost(
            identity: 'account-A',
            child: Builder(builder: (context) {
              controller = PixivBookmarkFeedbackHost.maybeOf(context)!;
              return const SizedBox.expand();
            }),
          ),
        );
      }),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> reduce(WidgetTester tester) async {
    change(() => reduced = true);
    await tester.pump();
  }

  PixivBookmarkFeedbackTicket waiting(String workId) =>
      controller.capture(account: 'account-A', workId: workId)
        ..startWaiting(target: true);

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  }
}

Finder _animation(String kind, int operationId) => find.byKey(
      ValueKey('pixiv-bookmark-queue-$kind-$operationId'),
    );

double _opacity(WidgetTester tester, String kind, int operationId) =>
    tester.widget<FadeTransition>(_animation(kind, operationId)).opacity.value;

double _completionScale(WidgetTester tester, int operationId) => tester
    .widget<Transform>(_animation('completion-scale', operationId))
    .transform
    .entry(0, 0);

void main() {
  testWidgets(
      'Host reduced motion interrupts entrance and keeps waiting and result hold',
      (tester) async {
    final fixture = _HostFixture();
    await fixture.pump(tester);
    final ticket = fixture.waiting('A');
    final operationId = fixture.controller.entries.single.operationId;
    final epoch = fixture.controller.visualEpoch;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    expect(_opacity(tester, 'entrance-opacity', operationId),
        inExclusiveRange(0, 1));
    expect(tester.binding.transientCallbackCount, greaterThan(0));

    await fixture.reduce(tester);
    expect(fixture.controller.visualEpoch, epoch);
    expect(ticket.isCurrent, isTrue);
    expect(fixture.controller.entries.single.operationId, operationId);
    expect(_opacity(tester, 'entrance-opacity', operationId), 1);
    expect(_opacity(tester, 'exit-opacity', operationId), 1);
    expect(tester.binding.transientCallbackCount, 0,
        reason: 'The entire Host must stop, including its capsule entrance.');

    await tester.pump(const Duration(seconds: 10));
    expect(fixture.controller.entries.single.status.name, 'waiting');
    expect(ticket.finish(const PixivBookmarkFeedbackMessage.added()), isTrue);
    await tester.pump();
    expect(fixture.controller.entries.single.status.name, 'completed');
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pump(const Duration(milliseconds: 1999));
    expect(fixture.controller.entries, hasLength(1));
    await tester.pump(const Duration(milliseconds: 1));
    expect(fixture.controller.entries, isEmpty);
    expect(tester.binding.transientCallbackCount, 0);
    await fixture.unmount(tester);
  });

  testWidgets(
      'Host reduced motion interrupts completion without resetting retention',
      (tester) async {
    final fixture = _HostFixture();
    await fixture.pump(tester);
    final ticket = fixture.waiting('A');
    final operationId = fixture.controller.entries.single.operationId;
    await tester.pumpAndSettle();
    expect(ticket.finish(const PixivBookmarkFeedbackMessage.added()), isTrue);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(
        tester.widget<Opacity>(_animation('heart-fill', operationId)).opacity,
        closeTo(.5, .01));
    expect(_completionScale(tester, operationId), closeTo(1.1, .01));
    expect(tester.binding.transientCallbackCount, greaterThan(0));

    await fixture.reduce(tester);
    expect(
        tester.widget<Opacity>(_animation('heart-fill', operationId)).opacity,
        1);
    expect(_completionScale(tester, operationId), 1);
    expect(fixture.controller.entries.single.exiting, isFalse);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pump(const Duration(milliseconds: 1919));
    expect(fixture.controller.entries, hasLength(1));
    await tester.pump(const Duration(milliseconds: 1));
    expect(fixture.controller.entries, isEmpty,
        reason: 'Changing motion preference preserves the original 2s hold.');
    expect(tester.binding.transientCallbackCount, 0);
    await fixture.unmount(tester);
  });

  testWidgets(
      'Host reduced motion interrupts head exit and retains FIFO advance delay',
      (tester) async {
    final fixture = _HostFixture();
    await fixture.pump(tester);
    final first = fixture.waiting('A');
    final second = fixture.waiting('B');
    final operationId = fixture.controller.entries.first.operationId;
    await tester.pumpAndSettle();
    expect(first.finish(const PixivBookmarkFeedbackMessage.added()), isTrue);
    expect(second.finish(const PixivBookmarkFeedbackMessage.added()), isTrue);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(fixture.controller.entries.first.exiting, isTrue);
    expect(fixture.controller.entries.last.exiting, isFalse);
    await tester.pump(const Duration(milliseconds: 60));
    expect(
        tester
            .widget<SizeTransition>(_animation('exit-size', operationId))
            .sizeFactor
            .value,
        inExclusiveRange(0, 1));
    expect(tester.binding.transientCallbackCount, greaterThan(0));

    await fixture.reduce(tester);
    expect(fixture.controller.entries.map((entry) => entry.workId), ['B']);
    expect(fixture.controller.entries.single.exiting, isFalse);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pump(const Duration(milliseconds: 179));
    expect(fixture.controller.entries.map((entry) => entry.workId), ['B']);
    await tester.pump(const Duration(milliseconds: 1));
    expect(fixture.controller.entries, isEmpty);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pump(const Duration(seconds: 2));
    expect(fixture.controller.entries, isEmpty,
        reason: 'The cancelled animated exit timer cannot revive old entries.');
    await fixture.unmount(tester);
  });
}

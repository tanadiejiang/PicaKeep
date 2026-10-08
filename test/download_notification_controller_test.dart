import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/tools/download_notification_controller.dart';

DownloadNoticeSnapshot running(
        {String id = 'first::folder::operation',
        int total = 3,
        int completed = 0,
        int percent = 0}) =>
    DownloadNoticeSnapshot(
      state: DownloadNoticeState.running,
      total: total,
      completed: completed,
      currentId: id,
      currentTitle: '书名',
      percent: percent,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'completed count starts at zero and all queue states contribute to total',
      () {
    final snapshot = DownloadNoticeSnapshot.fromTasks(const [
      DownloadNoticeTask(id: 'active', title: 'Current', progress: .25),
      DownloadNoticeTask(id: 'paused', title: 'Paused', paused: true),
      DownloadNoticeTask(id: 'error', title: 'Failed', error: '403'),
      DownloadNoticeTask(id: 'cancel', title: 'Cancelled', cancelled: true),
    ], activeId: 'active');
    expect(snapshot.state, DownloadNoticeState.running);
    expect(snapshot.completed, 0);
    expect(snapshot.total, 4);
    expect(snapshot.percent, 25);
  });

  test(
      'current book follows the executing identity, not queue reorder or work id',
      () {
    final snapshot = DownloadNoticeSnapshot.fromTasks(const [
      DownloadNoticeTask(id: '42::folderB::op2', title: 'Queued'),
      DownloadNoticeTask(
          id: '42::folderA::op1', title: 'Running', progress: .7),
    ], activeId: '42::folderA::op1');
    expect(snapshot.currentTitle, 'Running');
    expect(snapshot.percent, 70);
  });

  test('paused restore, error and cancellation never become false completion',
      () {
    for (final task in const [
      DownloadNoticeTask(id: 'one', title: '', paused: true),
      DownloadNoticeTask(id: 'one', title: '', cancelled: true),
      DownloadNoticeTask(id: 'one', title: '', error: 'network'),
    ]) {
      final snapshot =
          DownloadNoticeSnapshot.fromTasks([task], activeId: 'one');
      expect(snapshot.state, isNot(DownloadNoticeState.running));
      expect(snapshot.state, isNot(DownloadNoticeState.finished));
    }
  });

  test(
      'offline runnable queue waits; a user pause remains paused while offline',
      () {
    expect(
        DownloadNoticeSnapshot.fromTasks(
                const [DownloadNoticeTask(id: '1', title: '')],
                networkAvailable: false)
            .state,
        DownloadNoticeState.waiting);
    expect(
        DownloadNoticeSnapshot.fromTasks(
                const [DownloadNoticeTask(id: '1', title: '', paused: true)],
                networkAvailable: false)
            .state,
        DownloadNoticeState.paused);
  });

  test(
      'book switch resets progress; all completed and empty have distinct terminal states',
      () {
    final snapshot = DownloadNoticeSnapshot.fromTasks(const [
      DownloadNoticeTask(id: '1', title: '', completed: true, progress: 1),
      DownloadNoticeTask(id: '2', title: '', progress: 0),
    ], activeId: '2');
    expect(snapshot.completed, 1);
    expect(snapshot.percent, 0);
    final finished = DownloadNoticeSnapshot.fromTasks(
        const [DownloadNoticeTask(id: '1', title: '', completed: true)]);
    expect(finished.state, DownloadNoticeState.finished);
    expect(finished.percent, 100);
    expect(finished.toMap()['percent'], 100);
    expect(DownloadNoticeSnapshot.fromTasks(const []).state,
        DownloadNoticeState.empty);
  });

  testWidgets(
      'progress coalesces, queue count changes immediately, terminal cancels stale timer',
      (tester) async {
    final sent = <(String, Map<String, Object?>?)>[];
    final controller = DownloadNotificationController(
        enabled: true,
        transport: (method, args) async {
          sent.add((method, args));
          return null;
        });
    addTearDown(controller.dispose);
    controller.update(running());
    await tester.pump();
    controller.update(running(percent: 20));
    controller.update(running(percent: 40));
    await tester.pump(const Duration(milliseconds: 999));
    expect(sent.length, 1);
    await tester.pump(const Duration(milliseconds: 1));
    expect(sent.last.$2!['percent'], 40);
    controller.update(running(total: 4, percent: 50));
    await tester.pump();
    expect(sent.last.$2!['total'], 4);
    controller.update(running(total: 4, percent: 60));
    controller.update(const DownloadNoticeSnapshot(
        state: DownloadNoticeState.finished, total: 4, completed: 4));
    await tester.pump();
    expect(sent.last.$1, 'finish');
    final count = sent.length;
    await tester.pump(const Duration(seconds: 3));
    expect(sent.length, count);
  });

  testWidgets('terminal IPC waits for in-flight start, never overtakes it',
      (tester) async {
    final started = Completer<void>();
    final sent = <String>[];
    final controller = DownloadNotificationController(
        enabled: true,
        transport: (method, args) async {
          sent.add(method);
          if (method == 'update') await started.future;
          return null;
        });
    addTearDown(controller.dispose);
    controller.update(running());
    controller.update(const DownloadNoticeSnapshot(
        state: DownloadNoticeState.finished, total: 3, completed: 3));
    await tester.pump();
    expect(sent, ['update']);
    started.complete();
    await tester.pump();
    expect(sent, ['update', 'finish']);
  });

  testWidgets('queue handoff stops pending progress and stale heartbeat replay',
      (tester) async {
    final sent = <(String, Map<String, Object?>?)>[];
    final controller = DownloadNotificationController(
        enabled: true,
        transport: (method, args) async {
          sent.add((method, args));
          return null;
        });
    addTearDown(controller.dispose);
    controller.update(running(percent: 99));
    await tester.pump();
    controller.update(running(percent: 100));
    controller.update(const DownloadNoticeSnapshot(
        state: DownloadNoticeState.queued, total: 3, completed: 1));
    await tester.pump(const Duration(seconds: 60));
    await controller.foregrounded();
    await tester.pump();
    expect(sent.where((call) => call.$1 == 'update').length, 1);
    expect(sent.where((call) => call.$1 == 'finish'), isEmpty);

    controller.update(running(id: 'next', completed: 1));
    await tester.pump();
    expect(sent.last.$1, 'update');
    expect(sent.last.$2!['currentId'], 'next');
    expect(sent.last.$2!['percent'], 0);
    controller.update(const DownloadNoticeSnapshot(
        state: DownloadNoticeState.empty, total: 0, completed: 0));
    await tester.pump();
  });

  testWidgets('foreground reconciliation retries a failed terminal delivery',
      (tester) async {
    final sent = <(String, Map<String, Object?>?)>[];
    var failedFinish = false;
    final controller = DownloadNotificationController(
        enabled: true,
        transport: (method, args) async {
          sent.add((method, args));
          if (method == 'finish' && !failedFinish) {
            failedFinish = true;
            throw StateError('temporary bridge failure');
          }
          return null;
        });
    addTearDown(controller.dispose);
    controller.update(running(percent: 99));
    await tester.pump();
    controller.update(DownloadNoticeSnapshot.fromTasks(const [
      DownloadNoticeTask(id: 'first', title: '', completed: true),
    ]));
    await tester.pump();
    expect(controller.warning.value, isNotNull);
    await tester.pump(const Duration(seconds: 60));
    expect(sent.where((call) => call.$1 == 'update').length, 1);

    await controller.foregrounded();
    await tester.pump();
    expect(sent.last.$1, 'finish');
    expect(sent.last.$2!['state'], 'finished');
    expect(sent.last.$2!['completed'], 1);
    expect(controller.warning.value, isNull);
    expect(tester.takeException(), isNull);

    controller.markDismissed();
    final finishCount = sent.where((call) => call.$1 == 'finish').length;
    await controller.foregrounded();
    await tester.pump();
    expect(sent.where((call) => call.$1 == 'finish').length, finishCount);
  });

  testWidgets(
      'dismissed completion stays gone until another real download starts',
      (tester) async {
    final sent = <String>[];
    final controller = DownloadNotificationController(
        enabled: true,
        transport: (method, args) async {
          sent.add(method);
          return null;
        });
    addTearDown(controller.dispose);
    const finished = DownloadNoticeSnapshot(
        state: DownloadNoticeState.finished, total: 1, completed: 1);
    controller.update(running());
    controller.update(finished);
    await tester.pump();
    controller.markDismissed();
    controller.update(finished);
    await tester.pump(const Duration(seconds: 3));
    expect(sent, ['update', 'finish']);
    controller.update(running(id: 'new'));
    await tester.pump();
    expect(sent.last, 'update');
    expect(sent.length, 3);
    controller.update(const DownloadNoticeSnapshot(
        state: DownloadNoticeState.empty, total: 0, completed: 0));
    await tester.pump();
  });

  testWidgets(
      'paused disk queue does not create a service or revive an old notice',
      (tester) async {
    final sent = <String>[];
    final controller = DownloadNotificationController(
        enabled: true,
        transport: (method, args) async {
          sent.add(method);
          return null;
        });
    addTearDown(controller.dispose);
    controller.update(const DownloadNoticeSnapshot(
        state: DownloadNoticeState.paused, total: 2, completed: 0));
    await tester.pump();
    expect(sent, isEmpty);
  });

  testWidgets('offline wait sends low frequency heartbeat until user pauses',
      (tester) async {
    final sent = <String>[];
    final controller = DownloadNotificationController(
        enabled: true,
        transport: (method, args) async {
          sent.add(method);
          return null;
        });
    addTearDown(controller.dispose);
    controller.update(const DownloadNoticeSnapshot(
        state: DownloadNoticeState.waiting, total: 1, completed: 0));
    await tester.pump();
    await tester.pump(const Duration(seconds: 30));
    expect(sent, ['update', 'update']);
    controller.update(const DownloadNoticeSnapshot(
        state: DownloadNoticeState.paused, total: 1, completed: 0));
    await tester.pump();
    await tester.pump(const Duration(seconds: 60));
    expect(sent, ['update', 'update', 'finish']);
  });

  testWidgets(
      'service failure reports degraded protection without failing the queue caller',
      (tester) async {
    var failures = 0;
    final controller = DownloadNotificationController(
        enabled: true, transport: (_, __) async => throw StateError('denied'));
    addTearDown(controller.dispose);
    controller.onBackgroundProtectionLost = () => failures++;
    controller.update(running());
    await tester.pump();
    expect(failures, 1);
    expect(controller.warning.value, contains('保护暂不可用'));
    expect(tester.takeException(), isNull);
    controller.update(const DownloadNoticeSnapshot(
        state: DownloadNoticeState.empty, total: 0, completed: 0));
    await tester.pump();
  });

  test(
      'notification intents remain pending through startup/auth and are consumed once',
      () async {
    var route = 'downloaded';
    final controller = DownloadNotificationController(
        enabled: true,
        transport: (method, _) async =>
            method == 'getInitialIntent' ? route : null);
    addTearDown(controller.dispose);
    await controller.pullRoute();
    expect(controller.takeRoute(ready: false), isNull);
    expect(controller.takeRoute(ready: true), 'downloaded');
    expect(controller.takeRoute(ready: true), isNull);
    route = 'queue';
    await controller.pullRoute();
    expect(controller.takeRoute(ready: true), 'queue');
  });

  testWidgets(
      'an Activity/engine recreation stops an orphan running native notice with the restored paused state',
      (tester) async {
    final sent = <String>[];
    final controller = DownloadNotificationController(
        enabled: true,
        transport: (method, _) async {
          sent.add(method);
          return method == 'status'
              ? {'serviceRunning': true, 'networkAvailable': true}
              : null;
        });
    addTearDown(controller.dispose);
    await controller.initialize();
    controller.update(const DownloadNoticeSnapshot(
        state: DownloadNoticeState.paused, total: 2, completed: 0));
    await tester.pump();
    expect(sent, ['status', 'finish']);
  });

  testWidgets(
      'a late initial status cannot erase an already started notification session',
      (tester) async {
    final status = Completer<Object?>();
    final sent = <String>[];
    final controller = DownloadNotificationController(
        enabled: true,
        transport: (method, _) async {
          sent.add(method);
          return method == 'status' ? status.future : null;
        });
    addTearDown(controller.dispose);
    final initialized = controller.initialize();
    controller.update(running());
    await tester.pump();
    status.complete({'serviceRunning': false});
    await initialized;
    controller.update(const DownloadNoticeSnapshot(
        state: DownloadNoticeState.finished, total: 3, completed: 3));
    await tester.pump();
    expect(sent, ['status', 'update', 'finish']);
  });
}

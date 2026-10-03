import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/pages/illust_work_queue.dart';

void main() {
  testWidgets('queue bounds concurrency and drops offscreen pending work',
      (tester) async {
    final tasks = <String, Completer<String?>>{};
    final values = <String, String>{};
    final queue = IllustWorkQueue<String>(
        resolve: (key, _) {
          final result = Completer<String?>();
          tasks[key] = result;
          return result.future;
        },
        publish: values.addAll);
    queue.setVisible(['a', 'b', 'c', 'd']);
    expect(tasks.keys, ['a', 'b']);
    expect(queue.peakActive, 2);
    queue.setVisible(['d', 'e']);
    expect(queue.queued, 2);
    tasks['a']!.complete('a');
    await tester.pump();
    expect(tasks.containsKey('c'), isFalse);
    expect(tasks.containsKey('d'), isTrue);
    queue.dispose();
    for (final task in tasks.values.where((c) => !c.isCompleted)) {
      task.complete(null);
    }
    await tester.pump();
  });
  testWidgets('scroll defers starts and publishes until 140ms idle',
      (tester) async {
    final task = Completer<String?>();
    final values = <String, String>{};
    final queue = IllustWorkQueue<String>(
        concurrency: 1,
        resolve: (key, _) => key == 'a' ? task.future : Future.value(key),
        publish: values.addAll);
    queue.setVisible(['a', 'b']);
    queue.setScrolling(true);
    task.complete('a');
    await tester.pump();
    expect(values, isEmpty);
    expect(queue.started, 1);
    queue.setScrolling(false);
    await tester.pump(const Duration(milliseconds: 139));
    expect(values, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(values, {'a': 'a', 'b': 'b'});
    expect(queue.started, 2);
    queue.dispose();
  });
  testWidgets(
      'repeated scroll cancels idle timer and page pause preserves pending',
      (tester) async {
    final values = <String, String>{};
    final queue = IllustWorkQueue<String>(
        resolve: (key, _) async => key, publish: values.addAll);
    queue.setScrolling(true);
    queue.setVisible(['a']);
    queue.setScrolling(false);
    await tester.pump(const Duration(milliseconds: 100));
    queue.setScrolling(true);
    await tester.pump(const Duration(milliseconds: 200));
    expect(queue.started, 0);
    queue.setActive(false);
    queue.setScrolling(false);
    await tester.pump(const Duration(milliseconds: 200));
    expect(queue.started, 0);
    queue.setActive(true);
    await tester.pump();
    expect(values, {'a': 'a'});
    queue.dispose();
  });
  testWidgets(
      'refresh generation rejects old work and dispose rejects late publication',
      (tester) async {
    final tasks = <Completer<String?>>[];
    final values = <String, String>{};
    final queue = IllustWorkQueue<String>(
        resolve: (key, _) {
          final c = Completer<String?>();
          tasks.add(c);
          return c.future;
        },
        publish: values.addAll);
    queue.setVisible(['same']);
    queue.reset();
    queue.setVisible(['same']);
    tasks.first.complete('old');
    await tester.pump();
    expect(values, isEmpty);
    expect(tasks.length, 2);
    queue.dispose();
    tasks.last.complete('new');
    await tester.pump();
    expect(values, isEmpty);
    expect(queue.queued, 0);
  });
  testWidgets('separate location keys do not merge; completion is not repeated',
      (tester) async {
    final values = <String, String>{};
    final queue = IllustWorkQueue<String>(
        resolve: (key, _) async => key, publish: values.addAll);
    queue.setVisible(['folderA::pixiv1', 'folderB::pixiv1']);
    await tester.pump();
    expect(values.length, 2);
    queue.setVisible(values.keys);
    await tester.pump();
    expect(queue.started, 2);
    queue.dispose();
  });
}

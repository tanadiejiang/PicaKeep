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
  testWidgets('scroll publishes covers immediately and spaces new starts',
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
    expect(values, {'a': 'a'});
    expect(queue.started, 1);
    await tester.pump(const Duration(milliseconds: 119));
    expect(queue.started, 1);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(values, {'a': 'a', 'b': 'b'});
    expect(queue.started, 2);
    // No stop-scrolling event was needed to display either cover.
    queue.dispose();
  });
  testWidgets(
      'repeated scroll keeps cover progress and page pause preserves pending',
      (tester) async {
    final values = <String, String>{};
    final queue = IllustWorkQueue<String>(
        resolve: (key, _) async => key, publish: values.addAll);
    queue.setScrolling(true);
    queue.setVisible(['a']);
    await tester.pump();
    expect(values, {'a': 'a'});
    queue.setScrolling(false);
    await tester.pump(const Duration(milliseconds: 100));
    queue.setScrolling(true);
    await tester.pump(const Duration(milliseconds: 200));
    expect(queue.started, 1);
    queue.setActive(false);
    queue.setVisible(['b']);
    queue.setScrolling(false);
    await tester.pump(const Duration(milliseconds: 200));
    expect(queue.started, 1);
    queue.setActive(true);
    await tester.pump();
    expect(values, {'a': 'a', 'b': 'b'});
    queue.dispose();
  });

  testWidgets('scroll limits in-flight covers even after the spacing expires',
      (tester) async {
    final tasks = <String, Completer<String?>>{};
    final continuation = <String, bool Function()>{};
    final values = <String, String>{};
    final queue = IllustWorkQueue<String>(
      scrollStartSpacing: const Duration(milliseconds: 50),
      resolve: (key, canContinue) {
        continuation[key] = canContinue;
        return (tasks[key] = Completer<String?>()).future;
      },
      publish: values.addAll,
    );
    queue.setScrolling(true);
    queue.setVisible(['a', 'b', 'c']);
    expect(tasks.keys, ['a']);
    await tester.pump(const Duration(milliseconds: 500));
    expect(tasks.keys, ['a']);
    expect(continuation['a']!(), isTrue);
    tasks['a']!.complete('a');
    await tester.pump();
    expect(values, {'a': 'a'});
    expect(tasks.keys, ['a', 'b']);
    expect(queue.peakActive, 1);
    tasks['b']!.complete('b');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 49));
    expect(tasks.length, 2);
    await tester.pump(const Duration(milliseconds: 1));
    expect(tasks.keys, ['a', 'b', 'c']);
    queue.setVisible(['b']);
    expect(continuation['c']!(), isFalse);
    queue.dispose();
    tasks['c']!.complete(null);
    await tester.pump();
  });

  testWidgets('scroll does not cancel covers already running at idle capacity',
      (tester) async {
    final tasks = <String, Completer<String?>>{};
    final continuation = <String, bool Function()>{};
    final values = <String, String>{};
    final queue = IllustWorkQueue<String>(
      resolve: (key, canContinue) {
        continuation[key] = canContinue;
        return (tasks[key] = Completer<String?>()).future;
      },
      publish: values.addAll,
    );
    queue.setVisible(['a', 'b', 'c']);
    expect(tasks.keys, ['a', 'b']);
    queue.setScrolling(true);
    expect(continuation.values.every((check) => check()), isTrue);
    await tester.pump(const Duration(milliseconds: 120));
    tasks['a']!.complete('a');
    await tester.pump();
    expect(values, {'a': 'a'});
    expect(tasks.length, 2);
    tasks['b']!.complete('b');
    await tester.pump();
    expect(tasks.keys, ['a', 'b', 'c']);
    expect(queue.peakActive, 2);
    queue.setActive(false);
    expect(continuation['c']!(), isFalse);
    tasks['c']!.complete('c');
    await tester.pump();
    expect(values.containsKey('c'), isFalse);
    queue.setActive(true);
    expect(values['c'], 'c');
    queue.dispose();
  });

  testWidgets(
      'metadata finishes across scroll but only publishes after settling',
      (tester) async {
    final details = Completer<String?>();
    bool Function()? detailsCanContinue;
    final metadataKeys = <String>[];
    final values = <String, String>{};
    final queue = IllustWorkQueue<String>(
      resolve: (key, _) async => 'cover:$key',
      resolveDetails: (key, value, canContinue) {
        metadataKeys.add(key);
        detailsCanContinue = canContinue;
        return key == 'a' ? details.future : Future.value('$value+info');
      },
      publish: values.addAll,
    );
    queue.setVisible(['a']);
    await tester.pump();
    expect(metadataKeys, ['a']);
    queue.setScrolling(true);
    expect(detailsCanContinue!(), isTrue);
    details.complete('cover:a+info');
    await tester.pump();
    expect(values['a'], 'cover:a');
    queue.setVisible(['a', 'b']);
    await tester.pump(const Duration(milliseconds: 120));
    expect(values['b'], 'cover:b');
    expect(metadataKeys, ['a']);
    queue.setScrolling(false);
    await tester.pump(const Duration(milliseconds: 139));
    expect(values['a'], 'cover:a');
    expect(metadataKeys, ['a']);
    await tester.pump(const Duration(milliseconds: 1));
    expect(values, {'a': 'cover:a+info', 'b': 'cover:b+info'});
    expect(metadataKeys, ['a', 'b']);
    queue.dispose();
  });

  testWidgets('settling transition keeps cover spacing and metadata paused',
      (tester) async {
    var metadataCount = 0;
    final values = <String, String>{};
    final queue = IllustWorkQueue<String>(
      resolve: (key, _) async => key,
      resolveDetails: (_, value, __) async {
        metadataCount++;
        return '$value+info';
      },
      publish: values.addAll,
    );
    queue.setScrolling(true);
    queue.setVisible(['a', 'b', 'c']);
    await tester.pump();
    queue.setScrolling(false);
    await tester.pump(const Duration(milliseconds: 119));
    expect(values, {'a': 'a'});
    expect(metadataCount, 0);
    await tester.pump(const Duration(milliseconds: 1));
    expect(values, {'a': 'a', 'b': 'b'});
    queue.setScrolling(true);
    await tester.pump(const Duration(milliseconds: 20));
    expect(metadataCount, 0);
    expect(values.length, 2);
    await tester.pump(const Duration(milliseconds: 100));
    expect(values, {'a': 'a', 'b': 'b', 'c': 'c'});
    expect(metadataCount, 0);
    queue.dispose();
  });

  testWidgets('retry removes finished metadata waiting for idle publication',
      (tester) async {
    var covers = 0;
    final details = Completer<String?>();
    final values = <String, String>{};
    final queue = IllustWorkQueue<String>(
      resolve: (_, __) async => 'cover${++covers}',
      resolveDetails: (_, value, __) =>
          covers == 1 ? details.future : Future.value('$value+info'),
      publish: values.addAll,
    );
    queue.setVisible(['a']);
    await tester.pump();
    queue.setScrolling(true);
    details.complete('stale info');
    await tester.pump();
    queue.retry('a');
    await tester.pump(const Duration(milliseconds: 120));
    expect(values, {'a': 'cover2'});
    queue.setScrolling(false);
    await tester.pump(const Duration(milliseconds: 140));
    expect(values, {'a': 'cover2+info'});
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

  testWidgets('covers publish while metadata is stalled, sharing one limit',
      (tester) async {
    final values = <String, String>{};
    final metadata = <String, Completer<String?>>{};
    final order = <String>[];
    final queue = IllustWorkQueue<String>(
      concurrency: 1,
      resolve: (key, _) async {
        order.add('cover:$key');
        return 'image:$key';
      },
      resolveDetails: (key, value, _) {
        order.add('metadata:$key');
        final task = Completer<String?>();
        metadata[key] = task;
        return task.future;
      },
      publish: values.addAll,
    );
    queue.setVisible(['a', 'b']);
    await tester.pump();
    expect(values, {'a': 'image:a', 'b': 'image:b'});
    expect(order, ['cover:a', 'cover:b', 'metadata:a']);
    expect(queue.peakActive, 1);

    // Newly visible covers outrank the remaining metadata once a slot is free.
    queue.setVisible(['a', 'b', 'c']);
    metadata['a']!.complete('image:a+size');
    await tester.pump();
    expect(
        order, ['cover:a', 'cover:b', 'metadata:a', 'cover:c', 'metadata:b']);
    expect(values['c'], 'image:c');
    queue.dispose();
    metadata['b']!.complete(null);
    await tester.pump();
  });

  testWidgets('metadata failure preserves cover and does not reload it',
      (tester) async {
    final values = <String, String>{};
    final queue = IllustWorkQueue<String>(
      resolve: (key, _) async => 'cover',
      resolveDetails: (_, __, ___) async => throw StateError('read failed'),
      publish: values.addAll,
    );
    queue.setVisible(['a']);
    await tester.pump();
    expect(values, {'a': 'cover'});
    queue.setVisible(['a']);
    await tester.pump(const Duration(seconds: 40));
    expect(queue.started, 2);
    expect(values, {'a': 'cover'});
    queue.dispose();
  });

  testWidgets('slow metadata leaves capacity for newly visible covers',
      (tester) async {
    final values = <String, String>{};
    final details = Completer<String?>();
    var metadataStarted = 0;
    final queue = IllustWorkQueue<String>(
      resolve: (key, _) async => key,
      resolveDetails: (_, __, ___) {
        metadataStarted++;
        return details.future;
      },
      publish: values.addAll,
    );
    queue.setVisible(['a', 'b']);
    await tester.pump();
    expect(metadataStarted, 1);
    queue.setVisible(['a', 'b', 'c']);
    await tester.pump();
    expect(values['c'], 'c');
    expect(queue.peakActive, 2);
    expect(metadataStarted, 1);
    queue.dispose();
    details.complete(null);
    await tester.pump();
  });

  testWidgets('temporary failure retries without scroll and stops at budget',
      (tester) async {
    var attempts = 0;
    final queue = IllustWorkQueue<String>(
      retryDelay: const Duration(seconds: 1),
      resolve: (_, __) async {
        attempts++;
        if (attempts == 1) throw StateError('permission pending');
        return null;
      },
      publish: (_) {},
    );
    queue.setVisible(['a']);
    await tester.pump();
    expect(attempts, 1);
    for (var i = 0; i < 2; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(attempts, 3);
    queue.setVisible(['a']);
    await tester.pump(const Duration(minutes: 1));
    expect(attempts, 3);
    expect(queue.active, 0);
    queue.dispose();
  });

  testWidgets('retry timers do not start offscreen or background work',
      (tester) async {
    var attempts = 0;
    final values = <String, String>{};
    final queue = IllustWorkQueue<String>(
      retryDelay: const Duration(seconds: 1),
      resolve: (key, _) async => ++attempts < 2 ? null : key,
      publish: values.addAll,
    );
    queue.setVisible(['a']);
    await tester.pump();
    queue.setVisible([]);
    await tester.pump(const Duration(seconds: 2));
    expect(attempts, 1);
    queue.setActive(false);
    queue.setVisible(['a']);
    await tester.pump(const Duration(seconds: 2));
    expect(attempts, 1);
    queue.setActive(true);
    await tester.pump();
    expect(values, {'a': 'a'});
    queue.dispose();
  });

  testWidgets('explicit retry rejects stale metadata and shares running slot',
      (tester) async {
    var covers = 0;
    final details = Completer<String?>();
    final values = <String, String>{};
    final queue = IllustWorkQueue<String>(
      concurrency: 1,
      resolve: (_, __) async => 'cover${++covers}',
      resolveDetails: (_, value, __) =>
          covers == 1 ? details.future : Future.value(value),
      publish: values.addAll,
    );
    queue.setVisible(['a']);
    await tester.pump();
    expect(values, {'a': 'cover1'});
    queue.retry('a');
    expect(covers, 1);
    details.complete('stale');
    await tester.pump();
    expect(values, {'a': 'cover2'});
    expect(queue.peakActive, 1);
    queue.dispose();
  });

  testWidgets('metadata resumes after leaving the viewport without new cover',
      (tester) async {
    var covers = 0;
    var details = 0;
    final task = Completer<String?>();
    final values = <String, String>{};
    final queue = IllustWorkQueue<String>(
      resolve: (key, _) async {
        covers++;
        return key;
      },
      resolveDetails: (_, value, canContinue) async {
        details++;
        if (details == 1) await task.future;
        return canContinue() ? '$value+size' : null;
      },
      publish: values.addAll,
    );
    queue.setVisible(['a']);
    await tester.pump();
    queue.setVisible([]);
    task.complete(null);
    await tester.pump();
    queue.setVisible(['a']);
    await tester.pump();
    expect(covers, 1);
    expect(details, 2);
    expect(values, {'a': 'a+size'});
    queue.dispose();
  });
}

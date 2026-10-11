import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/pixiv_detail_preview.dart';
import 'package:picakeep/foundation/pixiv_detail_session.dart';
import 'package:picakeep/pages/online_comic/pixiv_detail_pager.dart';

/// No network or codec: the test owns this image stream and counts listeners.
class _ObservedCompleter extends ImageStreamCompleter {
  final _listeners = <ImageStreamListener>{};
  int additions = 0;
  int removals = 0;

  int get listenerCount => _listeners.length;

  @override
  void addListener(ImageStreamListener listener) {
    additions++;
    _listeners.add(listener);
    super.addListener(listener);
  }

  @override
  void removeListener(ImageStreamListener listener) {
    removals++;
    _listeners.remove(listener);
    super.removeListener(listener);
  }
}

class _ManualProvider extends ImageProvider<_ManualProvider> {
  final stream = _ObservedCompleter();
  int loads = 0;

  @override
  Future<_ManualProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
      _ManualProvider key, ImageDecoderCallback decode) {
    loads++;
    return stream;
  }
}

PixivDetailPreview _preview(String id, {bool Function()? owner}) =>
    PixivDetailPreview(
      workId: id,
      provider: _ManualProvider(),
      ownerIsCurrent: owner,
    );

Future<void> _flush() async {
  // Let the controlled loader and the queue's awaiting finally both complete.
  for (var i = 0; i < 4; i++) {
    await Future<void>.value();
  }
}

class _CoverLoads {
  final started = <String>[];
  final completions = <String, Completer<void>>{};
  int active = 0;
  int peak = 0;

  Future<void> load(PixivDetailPreview preview) async {
    started.add(preview.workId);
    final completion = Completer<void>();
    completions[preview.workId] = completion;
    active++;
    if (active > peak) peak = active;
    try {
      await completion.future;
    } finally {
      active--;
    }
  }

  Future<void> finish(String id, {bool error = false}) async {
    final completion = completions[id]!;
    if (error) {
      completion.completeError(StateError('offline cover failure'));
    } else {
      completion.complete();
    }
    await _flush();
  }

  Future<void> finishOutstanding() async {
    for (final completion in completions.values.toList()) {
      if (!completion.isCompleted) completion.complete();
    }
    await _flush();
  }
}

PixivDetailSession _session(int count,
        {bool previews = true,
        bool Function()? owner,
        PixivDetailPreview Function(String)? createPreview}) =>
    PixivDetailSession(
      scope: PixivDetailScope.recommendation,
      ownerIsCurrent: owner,
      entries: [
        for (var i = 0; i < count; i++)
          PixivDetailEntry(
            key: 'work-$i',
            comicId: '$i',
            preview:
                previews ? (createPreview?.call('$i') ?? _preview('$i')) : null,
            builder: (context) => Scaffold(
              body: Center(
                child: Text('work-$i active:'
                    '${PixivDetailEntryScope.isActiveOf(context)}'),
              ),
            ),
          ),
      ],
    );

void _mobile(WidgetTester tester) {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

PageController _pageController(WidgetTester tester) => tester
    .widget<PageView>(find.byKey(const Key('pixiv-work-pager')))
    .controller!;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('050 bounded cover queue', () {
    test('current precedes immediate next and previous, never distant entries',
        () {
      final values = List.generate(7, (i) => '$i');
      expect(pixivDetailNeighborCandidates(values, 3), ['3', '4', '2']);
      expect(pixivDetailNeighborCandidates(values, 0), ['0', '1']);
      expect(pixivDetailNeighborCandidates(values, 6), ['6', '5']);
      expect(pixivDetailNeighborCandidates(values, -1), isEmpty);
      expect(pixivDetailNeighborCandidates(values, 7), isEmpty);
    });

    test('at most two workers and three candidates, including current first',
        () async {
      final loads = _CoverLoads();
      final queue = PixivDetailCoverPrefetchQueue(
        loadCover: loads.load,
        maximumConcurrent: 100,
      );
      queue.replaceCandidates(List.generate(8, (i) => _preview('$i')));
      expect(loads.started, ['0', '1']);
      expect(queue.maximumConcurrent, 2);
      expect(queue.runningCount, 2);
      expect(queue.pendingCount, 1);
      await loads.finish('0');
      expect(loads.started, ['0', '1', '2']);
      expect(loads.peak, 2);
      expect(queue.runningCount, 2);
      queue.dispose();
      await loads.finishOutstanding();
      expect(queue.runningCount, 0);
      expect(loads.started, ['0', '1', '2']);
    });

    test('replacement drops queued old neighbors before a worker becomes free',
        () async {
      final loads = _CoverLoads();
      final queue = PixivDetailCoverPrefetchQueue(loadCover: loads.load);
      queue.replaceCandidates([_preview('1'), _preview('2'), _preview('0')]);
      queue.replaceCandidates([_preview('4'), _preview('5'), _preview('3')]);
      await loads.finish('1');
      expect(loads.started, ['1', '2', '4']);
      await loads.finish('2');
      expect(loads.started, ['1', '2', '4', '5']);
      expect(loads.started, isNot(contains('0')));
      expect(loads.peak, 2);
      queue.dispose();
      await loads.finishOutstanding();
      expect(loads.started, isNot(contains('3')));
    });

    test('immediate clear closes the swipe-to-postframe stale-candidate gap',
        () async {
      final loads = _CoverLoads();
      final queue = PixivDetailCoverPrefetchQueue(loadCover: loads.load);
      queue.replaceCandidates([_preview('1'), _preview('2'), _preview('0')]);
      queue.clearCandidates();
      await loads.finish('1');
      expect(loads.started, ['1', '2']);
      expect(queue.pendingCount, 0);
      queue.replaceCandidates([_preview('4'), _preview('5'), _preview('3')]);
      expect(loads.started, ['1', '2', '4']);
      queue.dispose();
      await loads.finishOutstanding();
      expect(loads.peak, 2);
    });

    test('silent cover errors settle once without automatic retry loop',
        () async {
      final loads = _CoverLoads();
      final queue = PixivDetailCoverPrefetchQueue(loadCover: loads.load);
      final first = _preview('1');
      final second = _preview('2');
      queue.replaceCandidates([first, first, second]);
      expect(loads.started, ['1', '2']);
      await loads.finish('1', error: true);
      await loads.finish('2', error: true);
      for (var i = 0; i < 4; i++) {
        queue.replaceCandidates([first, second]);
      }
      expect(loads.started, ['1', '2']);
      expect(queue.runningCount, 0);
      expect(queue.pendingCount, 0);
      queue.dispose();
    });

    test('queue and preview owners reject startup and late results cannot pump',
        () async {
      var current = true;
      final loads = _CoverLoads();
      final queue = PixivDetailCoverPrefetchQueue(
        loadCover: loads.load,
        ownerIsCurrent: () => current,
      );
      queue.replaceCandidates([
        _preview('stale', owner: () => false),
        _preview('1'),
        _preview('2'),
      ]);
      expect(loads.started, ['1', '2']);
      queue.replaceCandidates([_preview('3'), _preview('4'), _preview('5')]);
      current = false;
      await loads.finish('1');
      expect(queue.cancellation.isCancelled, isTrue);
      expect(queue.pendingCount, 0);
      await loads.finish('2');
      current = true;
      queue.replaceCandidates([_preview('3')]);
      expect(loads.started, ['1', '2']);
      expect(queue.runningCount, 0);
    });

    test('dispose cancels once and no late completion starts queued work',
        () async {
      final loads = _CoverLoads();
      final queue = PixivDetailCoverPrefetchQueue(loadCover: loads.load);
      var cancellations = 0;
      queue.cancellation.addListener(() => cancellations++);
      queue.replaceCandidates([_preview('1'), _preview('2'), _preview('0')]);
      queue.dispose();
      queue.dispose();
      expect(cancellations, 1);
      expect(queue.pendingCount, 0);
      await loads.finishOutstanding();
      queue.replaceCandidates([_preview('9')]);
      expect(loads.started, ['1', '2']);
      expect(queue.runningCount, 0);
    });
  });

  group('050 cover warmup owned listeners', () {
    testWidgets('cancellation removes the owned listener immediately and once',
        (tester) async {
      final provider = _ManualProvider();
      final signal = PixivDetailCoverPrefetchCancellation();
      addTearDown(() => PaintingBinding.instance.imageCache.evict(provider));
      final future = warmPixivDetailCover(
        PixivDetailPreview(workId: '1', provider: provider),
        ImageConfiguration.empty,
        cancellation: signal,
      );
      expect(provider.loads, 1);
      final before = provider.stream.listenerCount;
      final removedBefore = provider.stream.removals;
      expect(before, greaterThanOrEqualTo(1));
      signal.cancel();
      expect(provider.stream.listenerCount, before - 1);
      expect(provider.stream.removals, removedBefore + 1);
      await future;
      signal.cancel();
      await tester.pump(const Duration(seconds: 9));
      expect(provider.stream.removals, removedBefore + 1);
      // The cache may still own a pending listener/transport. Only warmup's
      // observation was cancelled; no false assertion of global HTTP abort.
    });

    testWidgets('timeout releases observation without leaving a Timer behind',
        (tester) async {
      final provider = _ManualProvider();
      addTearDown(() => PaintingBinding.instance.imageCache.evict(provider));
      final future = warmPixivDetailCover(
        PixivDetailPreview(workId: '1', provider: provider),
        ImageConfiguration.empty,
        timeout: const Duration(milliseconds: 10),
      );
      final before = provider.stream.listenerCount;
      final removedBefore = provider.stream.removals;
      await tester.pump(const Duration(milliseconds: 11));
      await future;
      expect(provider.stream.listenerCount, before - 1);
      expect(provider.stream.removals, removedBefore + 1);
      await tester.pump(const Duration(seconds: 9));
      expect(provider.stream.removals, removedBefore + 1);
    });

    testWidgets('expired preview, owner, or signal never resolves an image',
        (tester) async {
      final provider = _ManualProvider();
      final signal = PixivDetailCoverPrefetchCancellation()..cancel();
      await warmPixivDetailCover(
        PixivDetailPreview(
            workId: '1', provider: provider, ownerIsCurrent: () => false),
        ImageConfiguration.empty,
      );
      await warmPixivDetailCover(
        PixivDetailPreview(workId: '1', provider: provider),
        ImageConfiguration.empty,
        ownerIsCurrent: () => false,
      );
      await warmPixivDetailCover(
        PixivDetailPreview(workId: '1', provider: provider),
        ImageConfiguration.empty,
        cancellation: signal,
      );
      expect(provider.loads, 0);
      expect(provider.stream.listenerCount, 0);
    });
  });

  group('050 production pager cover scheduling', () {
    testWidgets(
        'real page jump replaces neighbors before old worker completion',
        (tester) async {
      _mobile(tester);
      final loads = _CoverLoads();
      final session = _session(7);
      addTearDown(session.dispose);
      await tester.pumpWidget(MaterialApp(
          home: PixivDetailPager(
              session: session,
              initialKey: 'work-3',
              prefetchCover: loads.load)));
      await tester.pump();
      expect(loads.started, ['3', '4']);
      _pageController(tester).jumpToPage(6);
      await loads.finish('3');
      expect(loads.started, ['3', '4']);
      await tester.pump();
      expect(loads.started, ['3', '4', '6']);
      await loads.finish('4');
      expect(loads.started, ['3', '4', '6', '5']);
      expect(loads.started, isNot(contains('2')));
      expect(loads.peak, 2);
      expect(find.text('work-6 active:true'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await loads.finishOutstanding();
      expect(loads.started, ['3', '4', '6', '5']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('covered route drops queued cover and close cannot restart it',
        (tester) async {
      _mobile(tester);
      final loads = _CoverLoads();
      final session = _session(7);
      addTearDown(session.dispose);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
          navigatorKey: navigator,
          home: PixivDetailPager(
              session: session,
              initialKey: 'work-3',
              prefetchCover: loads.load)));
      await tester.pump();
      expect(loads.started, ['3', '4']);
      unawaited(navigator.currentState!.push<void>(MaterialPageRoute(
          builder: (_) => const Scaffold(body: Text('covered')))));
      await tester.pumpAndSettle();
      await loads.finishOutstanding();
      expect(loads.started, ['3', '4']);
      expect(loads.started, isNot(contains('2')));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(loads.started, ['3', '4']);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'default pager removes its own warm listeners on cover and dispose',
        (tester) async {
      _mobile(tester);
      final providers = List.generate(7, (_) => _ManualProvider());
      final session = _session(7,
          createPreview: (id) => PixivDetailPreview(
              workId: id, provider: providers[int.parse(id)]));
      addTearDown(session.dispose);
      addTearDown(() {
        for (final provider in providers) {
          imageCache.evict(provider);
        }
      });
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
          navigatorKey: navigator,
          home: PixivDetailPager(session: session, initialKey: 'work-3')));
      await tester.pump();
      expect(providers.map((p) => p.loads), [0, 0, 0, 1, 1, 0, 0]);
      final before3 = providers[3].stream.listenerCount;
      final before4 = providers[4].stream.listenerCount;
      unawaited(navigator.currentState!.push<void>(MaterialPageRoute(
          builder: (_) => const Scaffold(body: Text('covered')))));
      await tester.pumpAndSettle();
      expect(providers[3].stream.listenerCount, before3 - 1);
      expect(providers[4].stream.listenerCount, before4 - 1);
      final removals3 = providers[3].stream.removals;
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 9));
      expect(providers[3].stream.removals, removals3);
      expect(providers[2].loads, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'entries without previews and expired session never warm covers',
        (tester) async {
      _mobile(tester);
      final loads = _CoverLoads();
      final local = _session(3, previews: false);
      final expired = _session(3, owner: () => false);
      addTearDown(local.dispose);
      addTearDown(expired.dispose);
      await tester.pumpWidget(MaterialApp(
          home: PixivDetailPager(
              session: local,
              initialKey: 'work-1',
              prefetchCover: loads.load)));
      await tester.pump();
      _pageController(tester).jumpToPage(2);
      await tester.pump();
      expect(loads.started, isEmpty);
      await tester.pumpWidget(MaterialApp(
          home: PixivDetailPager(
              session: expired,
              initialKey: 'work-1',
              prefetchCover: loads.load)));
      await tester.pump();
      expect(loads.started, isEmpty);
      expect(tester.takeException(), isNull);
    });
  });
}

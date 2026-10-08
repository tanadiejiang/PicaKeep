import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/components/components.dart' show NaviObserver;
import 'package:picakeep/components/pixiv_bookmark_button.dart';
import 'package:picakeep/components/pixiv_bookmark_feedback.dart';
import 'package:picakeep/components/pixiv_bookmark_queue.dart';
import 'package:picakeep/foundation/pixiv_bookmark_state.dart';
import 'package:picakeep/network/pixiv_network/pixiv_models.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/online_common/online_recommendation_card.dart';
import 'package:picakeep/pages/online_common/online_waterfall_card.dart';

const _account = 'offline-account-a';

PixivComicBrief _comic(String id, {bool marked = false, bool known = true}) =>
    PixivComicBrief(
      id: id,
      title: '离线作品$id',
      author: '画师',
      cover: '',
      tags: const [],
      illustType: 0,
      pageCount: 1,
      width: 120,
      height: 150,
      isBookmarked: marked,
      bookmarkStateKnown: known,
      isBookmarkable: true,
      canLoadBookmarkState: !known,
    );

/// Keep these exact briefs and the source alive across every Host rebuild.
/// Replacing a brief while its write is pending changes business identity.
class _QueueHarness {
  _QueueHarness(this.comics, {this.duplicateFirst = false}) {
    bookmarks = RecommendationBookmarkController(store: store);
    peer = RecommendationBookmarkController(store: store);
    for (final comic in comics.where((comic) => comic.bookmarkStateKnown)) {
      store.confirm(
        _account,
        comic.id,
        PixivBookmarkState(
            isBookmarked: comic.isBookmarked, isBookmarkable: true),
      );
    }
  }

  final List<PixivComicBrief> comics;
  final bool duplicateFirst;
  final store = PixivBookmarkStateStore();
  late final RecommendationBookmarkController bookmarks;
  late final RecommendationBookmarkController peer;
  final source = ComicSource.named(
    key: 'pixiv',
    name: 'Pixiv',
    data: {'token': _account, 'userId': 'A'},
  );
  final navigator = GlobalKey<NavigatorState>();
  final observer = NaviObserver();
  late PixivBookmarkFeedbackController feedback;
  late StateSetter change;
  bool active = true;
  Object identity = _account;

  Future<void> pump(
    WidgetTester tester, {
    required Future<Res<bool>> Function(String, {required bool isAdding}) write,
    Future<Res<PixivBookmarkState>> Function(String)? read,
    bool reduced = false,
  }) async {
    tester.view.physicalSize = const Size(720, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigator,
      navigatorObservers: [observer],
      home: Material(
        child: StatefulBuilder(builder: (context, setState) {
          change = setState;
          return MediaQuery(
            data: MediaQueryData(
                size: const Size(720, 780), disableAnimations: reduced),
            child: PixivBookmarkFeedbackHost(
              active: active,
              identity: identity,
              child: Builder(builder: (context) {
                feedback = PixivBookmarkFeedbackHost.maybeOf(context)!;
                return Align(
                  alignment: Alignment.topLeft,
                  child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.start,
                    children: [
                      for (var index = 0;
                          index < comics.length + (duplicateFirst ? 1 : 0);
                          index++)
                        SizedBox(
                          width: 170,
                          child: OnlineRecommendationCard(
                            key: ValueKey('integration-card-$index'),
                            source: source,
                            comic: index < comics.length
                                ? comics[index]
                                : comics.first,
                            bookmarks: index < comics.length ? bookmarks : peer,
                            onAccountsChanged: () {},
                            writeBookmark: write,
                            loadBookmarkState: read ??
                                (_) async => const Res.error(
                                    'Unexpected offline fixture state read'),
                            feedbackCurrent: active,
                          ),
                        ),
                    ],
                  ),
                );
              }),
            ),
          );
        }),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Finder card(int index, {bool skipOffstage = true}) => find
      .byKey(ValueKey('integration-card-$index'), skipOffstage: skipOffstage);

  Finder favorite(int index) => find.descendant(
      of: card(index),
      matching: find.byKey(const ValueKey('waterfall-favorite')));

  OnlineWaterfallCard authority(WidgetTester tester, int index) =>
      tester.widget<OnlineWaterfallCard>(find.descendant(
          of: card(index), matching: find.byType(OnlineWaterfallCard)));

  IconData? icon(WidgetTester tester, int index) => tester
      .widget<Icon>(find.descendant(
          of: card(index),
          matching: find.byKey(const ValueKey('pixiv-bookmark-main-icon'))))
      .icon;

  PixivBookmarkQueueEntry entry(String id) =>
      feedback.entries.singleWhere((entry) => entry.workId == id);

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  }

  void dispose() {
    bookmarks.dispose();
    peer.dispose();
    store.dispose();
  }
}

void main() {
  late _QueueHarness harness;
  tearDown(() => harness.dispose());

  testWidgets(
      'real cards queue immediately, retain out-of-order results and exit FIFO',
      (tester) async {
    harness = _QueueHarness([_comic('A'), _comic('B'), _comic('C')],
        duplicateFirst: true);
    final pending = {
      for (final id in ['A', 'B', 'C']) id: Completer<Res<bool>>(),
    };
    final writes = <String>[];
    await harness.pump(tester, write: (id, {required isAdding}) {
      expect(isAdding, isTrue);
      writes.add(id);
      return pending[id]!.future;
    });

    for (var index = 0; index < 3; index++) {
      await tester.tap(harness.favorite(index));
    }
    expect(
        harness.feedback.entries.map((entry) => entry.workId), ['A', 'B', 'C']);
    expect(harness.feedback.entries.map((entry) => entry.status.name),
        everyElement('waiting'));
    expect(harness.feedback.entries.map((entry) => entry.target),
        everyElement(isTrue));
    expect(
        harness.feedback.entries.map((entry) => entry.operationId),
        orderedEquals(
            (harness.feedback.entries.map((entry) => entry.operationId).toList()
              ..sort())));
    expect(harness.feedback.entries.map((entry) => entry.exiting),
        everyElement(isFalse));
    expect(writes, ['A', 'B', 'C']);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(harness.icon(tester, 0), Icons.favorite,
        reason:
            'The initiating card may display its unconfirmed local target.');
    expect(harness.icon(tester, 3), Icons.favorite_border,
        reason:
            'An independent feed must wait for actual shared confirmation.');
    for (var index = 0; index < 3; index++) {
      expect(harness.authority(tester, index).isFavorited, isFalse);
      expect(
          harness.store
              .stateFor(_account, harness.comics[index].id)
              ?.isBookmarked,
          isFalse);
    }

    // C and B settle before the older operation A; neither may suppress A.
    pending['C']!.complete(const Res(true));
    await tester.pump();
    pending['B']!.complete(const Res(true));
    await tester.pump();
    expect(harness.entry('A').status.name, 'waiting');
    expect(harness.entry('B').status.name, 'completed');
    expect(harness.entry('C').status.name, 'completed');
    expect(
        harness.feedback.entries.map((entry) => entry.workId), ['A', 'B', 'C']);
    expect(harness.store.stateFor(_account, 'A')?.isBookmarked, isFalse);
    expect(harness.store.stateFor(_account, 'B')?.isBookmarked, isTrue);
    expect(harness.store.stateFor(_account, 'C')?.isBookmarked, isTrue);
    await tester.pump(const Duration(milliseconds: 2500));
    expect(harness.feedback.entries, hasLength(3),
        reason:
            'An unresolved head retains later results past their own hold.');
    expect(harness.feedback.entries.any((entry) => entry.exiting), isFalse);

    pending['A']!.complete(const Res(true));
    await tester.pump();
    await tester.pump();
    expect(harness.entry('A').status.name, 'completed');
    expect(harness.entry('A').text, '已添加公开收藏');
    expect(harness.store.stateFor(_account, 'A')?.isBookmarked, isTrue);
    expect(harness.icon(tester, 3), Icons.favorite);
    await tester.pump(const Duration(milliseconds: 1999));
    expect(harness.feedback.entries.any((entry) => entry.exiting), isFalse);
    await tester.pump(const Duration(milliseconds: 1));
    expect(harness.entry('A').exiting, isTrue);
    expect(harness.entry('B').exiting, isFalse);
    expect(harness.entry('C').exiting, isFalse);
    final aOperation = harness.entry('A').operationId;
    final bOperation = harness.entry('B').operationId;
    final cOperation = harness.entry('C').operationId;
    await tester.pump(const Duration(milliseconds: 120));
    final aExit = tester.widget<Transform>(find
        .byKey(ValueKey('pixiv-bookmark-queue-exit-translation-$aOperation')));
    expect(aExit.transform.entry(0, 3), lessThan(0),
        reason: 'The first completed heart must leave to the left.');
    expect(aExit.transform.entry(1, 3), 0);
    for (final operation in [bOperation, cOperation]) {
      final exit = tester.widget<Transform>(find
          .byKey(ValueKey('pixiv-bookmark-queue-exit-translation-$operation')));
      expect(exit.transform.entry(0, 3), 0);
      expect(exit.transform.entry(1, 3), 0);
    }
    await tester.pump(const Duration(milliseconds: 119));
    expect(
        harness.feedback.entries.map((entry) => entry.workId), ['A', 'B', 'C']);
    expect(harness.entry('B').exiting, isFalse);
    await tester.pump(const Duration(milliseconds: 1));
    expect(harness.feedback.entries.map((entry) => entry.workId), ['B', 'C']);
    await tester.pump(const Duration(milliseconds: 179));
    expect(harness.entry('B').exiting, isFalse);
    await tester.pump(const Duration(milliseconds: 1));
    expect(harness.entry('B').exiting, isTrue);
    expect(harness.entry('C').exiting, isFalse);
    await tester.pump(const Duration(milliseconds: 240));
    expect(harness.feedback.entries.map((entry) => entry.workId), ['C']);
    await tester.pump(const Duration(milliseconds: 179));
    expect(harness.entry('C').exiting, isFalse);
    await tester.pump(const Duration(milliseconds: 1));
    expect(harness.entry('C').exiting, isTrue);
    await tester.pump(const Duration(milliseconds: 240));
    expect(harness.feedback.entries, isEmpty);
    expect(find.byType(SnackBar), findsNothing);
    await harness.unmount(tester);
  });

  testWidgets(
      'busy duplicate tap creates neither a queue item nor another write',
      (tester) async {
    harness = _QueueHarness([_comic('A')]);
    final pending = Completer<Res<bool>>();
    var writes = 0;
    await harness.pump(tester, write: (_, {required isAdding}) {
      writes++;
      return pending.future;
    });
    await tester.tap(harness.favorite(0));
    final operationId = harness.feedback.entries.single.operationId;
    await tester.tap(harness.favorite(0));
    await tester.pump();
    await tester.tap(harness.favorite(0));
    await tester.pump();
    expect(writes, 1);
    expect(harness.feedback.entries, hasLength(1));
    expect(harness.feedback.entries.single.operationId, operationId);
    expect(harness.bookmarks.isBusy(_account, harness.comics.single), isTrue);
    pending.complete(const Res(true));
    await tester.pumpAndSettle();
    expect(writes, 1);
    expect(harness.feedback.entries.single.status.name, 'completed');
    await harness.unmount(tester);
  });

  testWidgets(
      'failed cancel retains specific reason and shared confirmed heart',
      (tester) async {
    harness = _QueueHarness([_comic('A', marked: true)], duplicateFirst: true);
    final pending = Completer<Res<bool>>();
    final targets = <bool>[];
    await harness.pump(tester, write: (_, {required isAdding}) {
      targets.add(isAdding);
      return pending.future;
    });
    final revision = harness.store.revisionFor(_account, 'A');
    await tester.tap(harness.favorite(0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(harness.icon(tester, 0), Icons.favorite_border);
    expect(harness.icon(tester, 1), Icons.favorite);
    expect(harness.store.stateFor(_account, 'A')?.isBookmarked, isTrue);
    pending.complete(const Res.error('离线取消被拒绝（403）'));
    await tester.pump();
    expect(harness.entry('A').status.name, 'failed');
    expect(harness.entry('A').text, '收藏失败：离线取消被拒绝（403）');
    expect(find.text('收藏失败：离线取消被拒绝（403）'), findsOneWidget);
    expect(harness.entry('A').target, isFalse);
    expect(harness.entry('A').isPrivate, isFalse);
    expect(harness.store.revisionFor(_account, 'A'), revision);
    expect(harness.store.stateFor(_account, 'A')?.isBookmarked, isTrue);
    await tester.pump(const Duration(milliseconds: 160));
    expect(harness.icon(tester, 0), Icons.favorite);
    expect(harness.icon(tester, 1), Icons.favorite);
    expect(targets, [false]);
    await tester.pump(const Duration(milliseconds: 3339));
    expect(harness.entry('A').exiting, isFalse);
    await tester.pump(const Duration(milliseconds: 1));
    expect(harness.entry('A').exiting, isTrue);
    await tester.pump(const Duration(milliseconds: 240));
    expect(harness.feedback.entries, isEmpty);
    await harness.unmount(tester);
  });

  testWidgets('unknown accepted read true then failed cancel restores true',
      (tester) async {
    harness = _QueueHarness([_comic('A', known: false)], duplicateFirst: true);
    final read = Completer<Res<PixivBookmarkState>>();
    final write = Completer<Res<bool>>();
    var reads = 0;
    final targets = <bool>[];
    await harness.pump(tester, read: (id) {
      expect(id, 'A');
      reads++;
      return read.future;
    }, write: (_, {required isAdding}) {
      targets.add(isAdding);
      return write.future;
    });
    await tester.tap(harness.favorite(0));
    await tester.pump();
    expect(harness.entry('A').status.name, 'waiting');
    expect(harness.entry('A').target, isNull);
    expect(harness.entry('A').text, '正在读取收藏状态…');
    expect(harness.authority(tester, 0).favoriteEvent?.phase,
        PixivBookmarkPhase.accepted);
    expect(reads, 1);
    expect(targets, isEmpty);
    expect(harness.store.stateFor(_account, 'A'), isNull);
    await tester.tap(harness.favorite(0));
    expect(reads, 1);
    expect(harness.feedback.entries, hasLength(1));
    read.complete(const Res(
        PixivBookmarkState(isBookmarked: true, isBookmarkable: true)));
    await tester.pump();
    await tester.pump();
    expect(targets, [false]);
    expect(harness.entry('A').target, isFalse);
    expect(harness.entry('A').text, '正在取消收藏…');
    expect(harness.authority(tester, 0).favoriteEvent?.phase,
        PixivBookmarkPhase.begin);
    expect(harness.store.stateFor(_account, 'A')?.isBookmarked, isTrue);
    expect(harness.icon(tester, 1), Icons.favorite);
    final revision = harness.store.revisionFor(_account, 'A');
    write.complete(const Res.error('读取确认后的取消失败'));
    await tester.pumpAndSettle();
    expect(harness.entry('A').status.name, 'failed');
    expect(harness.entry('A').text, '收藏失败：读取确认后的取消失败');
    expect(harness.bookmarks.isStateKnown(_account, harness.comics.single),
        isTrue);
    expect(harness.store.stateFor(_account, 'A')?.isBookmarked, isTrue);
    expect(harness.store.revisionFor(_account, 'A'), revision);
    expect(harness.icon(tester, 0), Icons.favorite);
    expect(harness.icon(tester, 1), Icons.favorite);
    expect(reads, 1);
    expect(targets, [false]);
    await harness.unmount(tester);
  });

  for (final boundary in ['active', 'route', 'identity']) {
    testWidgets('$boundary clears all feedback while late writes still confirm',
        (tester) async {
      harness = _QueueHarness([_comic('A'), _comic('B'), _comic('C')],
          duplicateFirst: true);
      final pending = {
        for (final id in ['A', 'B', 'C']) id: Completer<Res<bool>>(),
      };
      await harness.pump(tester,
          write: (id, {required isAdding}) => pending[id]!.future);
      for (var index = 0; index < 3; index++) {
        await tester.tap(harness.favorite(index));
      }
      pending['A']!.complete(const Res(true));
      pending['C']!.complete(const Res.error('离线后台拒绝'));
      await tester.pump();
      expect(harness.feedback.entries.map((entry) => entry.status.name),
          ['completed', 'waiting', 'failed']);
      // A's result now has an active hold timer while B remains in flight.
      await tester.pump(const Duration(milliseconds: 100));
      final epoch = harness.feedback.visualEpoch;
      if (boundary == 'route') {
        unawaited(harness.navigator.currentState!.push(MaterialPageRoute<void>(
            builder: (_) => const Material(child: Text('下一页')))));
      } else {
        harness.change(() {
          if (boundary == 'active') {
            harness.active = false;
          } else {
            harness.identity = 'visual-identity-b';
          }
        });
      }
      await tester.pump();
      expect(harness.feedback.visualEpoch, greaterThan(epoch));
      expect(harness.feedback.entries, isEmpty);
      expect(harness.bookmarks.isBusy(_account, harness.comics[1]), isTrue);
      pending['B']!.complete(const Res(true));
      await tester.pumpAndSettle();
      expect(harness.store.stateFor(_account, 'B')?.isBookmarked, isTrue,
          reason: 'Visual validity must never cancel a valid business write.');
      expect(harness.store.stateFor(_account, 'A')?.isBookmarked, isTrue);
      expect(harness.store.stateFor(_account, 'C')?.isBookmarked, isFalse);
      expect(harness.bookmarks.isBusy(_account, harness.comics[1]), isFalse);
      expect(harness.feedback.entries, isEmpty);
      if (boundary == 'route') {
        harness.navigator.currentState!.pop();
      } else {
        harness.change(() {
          harness.active = true;
          harness.identity = _account;
        });
      }
      await tester.pumpAndSettle();
      expect(harness.icon(tester, 0), Icons.favorite);
      expect(harness.icon(tester, 3), Icons.favorite);
      await tester.pump(const Duration(seconds: 5));
      expect(harness.feedback.entries, isEmpty);
      expect(find.text('已添加公开收藏'), findsNothing);
      expect(find.text('收藏失败：离线后台拒绝'), findsNothing);
      expect(find.byKey(const ValueKey('pixiv-bookmark-ring')), findsNothing);
      await harness.unmount(tester);
    });
  }

  testWidgets('capture is silent and completion without waiting is queued',
      (tester) async {
    harness = _QueueHarness([_comic('A')]);
    await harness.pump(tester,
        write: (_, {required isAdding}) async => const Res(true));
    final dormant = harness.feedback.capture(account: _account, workId: 'D');
    expect(harness.feedback.entries, isEmpty);
    expect(dormant.show(const PixivBookmarkFeedbackMessage.privateAdded()),
        isTrue);
    expect(harness.feedback.entries.single.workId, 'D');
    expect(harness.feedback.entries.single.status.name, 'completed');
    final completed = harness.feedback.capture(account: _account, workId: 'E');
    expect(
        completed.finish(const PixivBookmarkFeedbackMessage.added()), isTrue);
    expect(harness.feedback.entries.map((entry) => entry.workId), ['D', 'E']);
    expect(harness.entry('D').isPrivate, isTrue);
    expect(harness.entry('D').target, isTrue);
    expect(harness.entry('D').text, '已添加私密收藏');
    dormant.cancelWaiting();
    completed.cancelWaiting();
    expect(harness.feedback.entries.map((entry) => entry.workId), ['D', 'E']);
    expect(dormant.finish(const PixivBookmarkFeedbackMessage.added()), isFalse);
    await tester.pump(const Duration(milliseconds: 2999));
    expect(harness.feedback.entries.any((entry) => entry.exiting), isFalse);
    await tester.pump(const Duration(milliseconds: 1));
    expect(harness.entry('D').exiting, isTrue);
    expect(harness.entry('E').exiting, isFalse);
    await harness.unmount(tester);
  });

  testWidgets('reduced motion preserves result hold and removes without exit',
      (tester) async {
    harness = _QueueHarness([_comic('A')]);
    final pending = Completer<Res<bool>>();
    await harness.pump(tester,
        reduced: true, write: (_, {required isAdding}) => pending.future);
    await tester.tap(harness.favorite(0));
    await tester.pump();
    expect(harness.entry('A').status.name, 'waiting');
    expect(harness.entry('A').exiting, isFalse);
    expect(tester.binding.transientCallbackCount, 0);
    pending.complete(const Res(true));
    await tester.pump();
    expect(harness.entry('A').status.name, 'completed');
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pump(const Duration(milliseconds: 1999));
    expect(harness.feedback.entries, hasLength(1));
    expect(harness.entry('A').exiting, isFalse);
    await tester.pump(const Duration(milliseconds: 1));
    expect(harness.feedback.entries, isEmpty);
    expect(tester.binding.transientCallbackCount, 0);
    await harness.unmount(tester);
  });

  testWidgets('visible cap retains every accepted model operation',
      (tester) async {
    harness = _QueueHarness([
      for (var index = 0; index < 7; index++) _comic('$index'),
    ]);
    final pending = {
      for (var index = 0; index < 7; index++) '$index': Completer<Res<bool>>(),
    };
    await harness.pump(tester,
        write: (id, {required isAdding}) => pending[id]!.future);
    for (var index = 0; index < 7; index++) {
      await tester.tap(harness.favorite(index));
    }
    await tester.pump();
    expect(harness.feedback.entries, hasLength(7));
    expect(harness.feedback.entries.map((entry) => entry.workId),
        ['0', '1', '2', '3', '4', '5', '6']);
    expect(find.text('＋2'), findsOneWidget);
    final visibleStatuses = find.descendant(
        of: find.byType(PixivBookmarkQueueCapsule),
        matching: find.byWidgetPredicate((widget) {
          final key = widget.key;
          return key is ValueKey<String> &&
              key.value.startsWith('pixiv-bookmark-queue-status-');
        }));
    expect(visibleStatuses, findsNWidgets(5));
    pending['6']!.complete(const Res(true));
    await tester.pump();
    expect(harness.feedback.entries, hasLength(7));
    expect(harness.entry('6').status.name, 'completed');
    expect(harness.store.stateFor(_account, '6')?.isBookmarked, isTrue);
    for (var index = 0; index < 6; index++) {
      pending['$index']!.complete(const Res(true));
    }
    await tester.pump();
    expect(harness.feedback.entries, hasLength(7));
    await harness.unmount(tester);
  });
}

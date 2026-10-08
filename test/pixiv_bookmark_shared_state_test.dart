import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/pixiv_bookmark_state.dart';
import 'package:picakeep/network/pixiv_network/pixiv_models.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/online_common/online_recommendation_card.dart';

PixivComicBrief _comic({
  String id = '123',
  bool marked = false,
  bool known = true,
}) =>
    PixivComicBrief(
      id: id,
      title: '作品$id',
      cover: '',
      author: '画师',
      tags: const [],
      illustType: 0,
      pageCount: 1,
      isBookmarked: marked,
      isBookmarkable: known,
      bookmarkStateKnown: known,
      canLoadBookmarkState: !known,
    );

PixivBookmarkState _state(bool marked) => PixivBookmarkState(
      isBookmarked: marked,
      isBookmarkable: true,
    );

void main() {
  const account = 'account-a';
  late PixivBookmarkStateStore store;
  late Set<RecommendationBookmarkController> controllers;

  RecommendationBookmarkController controller({bool resolveUnknown = false}) {
    final value = RecommendationBookmarkController(
        store: store, resolveUnknownStates: resolveUnknown);
    controllers.add(value);
    return value;
  }

  void disposeController(RecommendationBookmarkController value) {
    controllers.remove(value);
    value.dispose();
  }

  setUp(() {
    store = PixivBookmarkStateStore();
    controllers = {};
  });

  tearDown(() {
    for (final value in controllers) {
      value.dispose();
    }
    store.dispose();
  });

  test('confirmed detail state reaches independent feeds and stale briefs', () {
    final ranking = controller();
    final recommendation = controller();
    final unknown = _comic(known: false);
    final stale = _comic();
    expect(ranking.isStateKnown(account, unknown), isFalse);
    expect(recommendation.isBookmarked(account, stale), isFalse);
    var notifications = 0;
    recommendation.addListener(() => notifications++);

    ranking.synchronizeConfirmedState(
      account: account,
      comic: unknown,
      state: _state(true),
    );

    expect(store.stateFor(account, unknown.id)?.isBookmarked, isTrue);
    expect(recommendation.isBookmarked(account, stale), isTrue);
    expect(recommendation.isStateKnown(account, stale), isTrue);
    expect(recommendation.isBusy(account, stale), isFalse);
    expect(notifications, greaterThan(0), reason: '其他已显示的入口卡片需要立即重建');
    expect(recommendation.isBookmarked(account, _comic()), isTrue,
        reason: '新到达的旧推荐快照不能覆盖详情确认的收藏态');
  });

  test('feed reset and disposal preserve confirmed state for a new route', () {
    final first = controller();
    first.synchronizeConfirmedState(
      account: account,
      comic: _comic(),
      state: _state(true),
    );
    first.reset();
    expect(first.isBookmarked(account, _comic(known: false)), isTrue);
    disposeController(first);

    final reopened = controller();
    expect(reopened.isBookmarked(account, _comic(known: false)), isTrue);
    expect(reopened.isStateKnown(account, _comic(known: false)), isTrue);
    expect(reopened.isBookmarked(account, _comic()), isTrue);
    expect(reopened.isBusy(account, _comic()), isFalse);
  });

  test('a successful card write survives opening a different feed', () async {
    final first = controller();
    final result = await first.toggle(
      account: account,
      comic: _comic(),
      write: (_, {required isAdding}) async {
        expect(isAdding, isTrue);
        return const Res(true);
      },
      isCurrentAccount: () => true,
    );
    expect(result?.data, isTrue);
    expect(store.stateFor(account, '123')?.isBookmarked, isTrue);
    disposeController(first);

    final second = controller();
    expect(second.isBookmarked(account, _comic(known: false)), isTrue);
  });

  test('explicit cancellation reaches other routes despite stale true briefs',
      () async {
    final first = controller();
    final second = controller();
    first.synchronizeConfirmedState(
      account: account,
      comic: _comic(),
      state: _state(true),
    );
    expect(second.isBookmarked(account, _comic(marked: true)), isTrue);

    final result = await first.toggle(
      account: account,
      comic: _comic(),
      write: (_, {required isAdding}) async {
        expect(isAdding, isFalse);
        return const Res(true);
      },
      isCurrentAccount: () => true,
    );

    expect(result?.data, isFalse);
    expect(store.stateFor(account, '123')?.isBookmarked, isFalse);
    expect(second.isBookmarked(account, _comic(marked: true)), isFalse);
    expect(second.isStateKnown(account, _comic(known: false)), isTrue);
  });

  test('the same illustration stays isolated between accounts', () {
    final first = controller();
    final second = controller();
    first.synchronizeConfirmedState(
      account: account,
      comic: _comic(),
      state: _state(true),
    );
    expect(second.isBookmarked('account-b', _comic()), isFalse);
    expect(store.stateFor('account-b', '123'), isNull);

    second.synchronizeConfirmedState(
      account: 'account-b',
      comic: _comic(),
      state: _state(false),
    );
    expect(first.isBookmarked(account, _comic(known: false)), isTrue);
    expect(first.isBookmarked('account-b', _comic(known: false)), isFalse);
  });

  test('cancel preserves fresh capability published by the network writer',
      () async {
    final value = controller();
    final comic = _comic(marked: true).copyWith(isBookmarkable: false);
    store.confirm(
      account,
      comic.id,
      const PixivBookmarkState(isBookmarked: true, isBookmarkable: false),
    );
    expect(value.canToggle(account, comic), isTrue, reason: '已有收藏仍允许取消');

    final result = await value.toggle(
      account: account,
      comic: comic,
      write: (_, {required isAdding}) async {
        expect(isAdding, isFalse);
        // The actual network writer has more recent capability from its
        // delete preflight than the old card's canAdd=false snapshot.
        store.confirm(account, comic.id, _state(false));
        return const Res(true);
      },
      isCurrentAccount: () => true,
    );

    expect(result?.data, isFalse);
    expect(store.stateFor(account, comic.id)?.isBookmarked, isFalse);
    expect(store.stateFor(account, comic.id)?.isBookmarkable, isTrue);
    expect(value.isBookmarked(account, comic), isFalse);
    expect(value.canToggle(account, comic), isTrue, reason: '取消后应保留新能力，允许再次收藏');
  });

  test('stale list data cannot invalidate a write based on shared authority',
      () async {
    final first = controller();
    final second = controller();
    final original = _comic();
    first.synchronizeConfirmedState(
      account: account,
      comic: original,
      state: _state(true),
    );
    final pending = Completer<Res<bool>>();
    final write = first.toggle(
      account: account,
      comic: original,
      write: (_, {required isAdding}) {
        expect(isAdding, isFalse);
        return pending.future;
      },
      isCurrentAccount: () => true,
    );
    // A duplicate list entry arriving during the write still has an old false
    // snapshot. It has less authority than the confirmed state used to cancel.
    expect(first.isBookmarked(account, _comic()), isTrue);
    pending.complete(const Res(true));
    final result = await write;

    expect(result?.data, isFalse);
    expect(store.stateFor(account, '123')?.isBookmarked, isFalse);
    expect(first.isBookmarked(account, _comic()), isFalse);
    expect(second.isBookmarked(account, _comic(marked: true)), isFalse);
  });

  test('failed reads and writes retain the shared confirmation', () async {
    final first = controller();
    final second = controller();
    first.synchronizeConfirmedState(
      account: account,
      comic: _comic(),
      state: _state(true),
    );
    final revision = store.revisionFor(account, '123');

    final result = await second.toggle(
      account: account,
      comic: _comic(known: false),
      write: (_, {required isAdding}) async => const Res.error('offline'),
      isCurrentAccount: () => true,
    );
    expect(result?.error, isTrue);
    await second.refreshConfirmedState(
      account: account,
      comic: _comic(known: false),
      readState: (_) async => const Res.error('offline'),
      isCurrentAccount: () => true,
    );

    expect(store.stateFor(account, '123')?.isBookmarked, isTrue);
    expect(store.revisionFor(account, '123'), revision);
    expect(first.isBookmarked(account, _comic()), isTrue);
    expect(second.isBusy(account, _comic(known: false)), isFalse);
  });

  test('newer shared confirmation rejects an older detail-return read',
      () async {
    final returning = controller();
    final otherRoute = controller();
    final pending = Completer<Res<PixivBookmarkState>>();
    final refresh = returning.refreshConfirmedState(
      account: account,
      comic: _comic(),
      readState: (_) => pending.future,
      isCurrentAccount: () => true,
    );
    otherRoute.synchronizeConfirmedState(
      account: account,
      comic: _comic(),
      state: _state(true),
    );
    pending.complete(Res(_state(false)));
    await refresh;

    expect(store.stateFor(account, '123')?.isBookmarked, isTrue);
    expect(returning.isBookmarked(account, _comic()), isTrue);
    expect(otherRoute.isBookmarked(account, _comic(known: false)), isTrue);
  });

  test('a newer unchanged confirmation also rejects an older return read',
      () async {
    final returning = controller();
    final otherRoute = controller();
    returning.synchronizeConfirmedState(
      account: account,
      comic: _comic(),
      state: _state(true),
    );
    final pending = Completer<Res<PixivBookmarkState>>();
    final refresh = returning.refreshConfirmedState(
      account: account,
      comic: _comic(),
      readState: (_) => pending.future,
      isCurrentAccount: () => true,
    );
    // Another route verifies the same visible value more recently. Even when
    // no visual rebuild is necessary, this is newer authority than the read.
    otherRoute.synchronizeConfirmedState(
      account: account,
      comic: _comic(),
      state: _state(true),
    );
    pending.complete(Res(_state(false)));
    await refresh;

    expect(store.stateFor(account, '123')?.isBookmarked, isTrue);
    expect(returning.isBookmarked(account, _comic()), isTrue);
  });

  test('store revisions reject stale confirmation independently per account',
      () {
    final initialRevision = store.revisionFor(account, '123');
    expect(store.confirm(account, '123', _state(true)), isTrue);
    final confirmedRevision = store.revisionFor(account, '123');
    expect(confirmedRevision, greaterThan(initialRevision));
    expect(
      store.confirm(account, '123', _state(false),
          expectedRevision: initialRevision),
      isFalse,
    );
    expect(store.stateFor(account, '123')?.isBookmarked, isTrue);
    expect(
      store.confirm('account-b', '123', _state(false),
          expectedRevision: store.revisionFor('account-b', '123')),
      isTrue,
    );
    expect(store.revisionFor(account, '123'), confirmedRevision);
  });

  test('visible duplicate entries share one state read without becoming busy',
      () async {
    final first = controller();
    final second = controller();
    final pending = Completer<Res<PixivBookmarkState>>();
    var reads = 0;
    Future<Res<PixivBookmarkState>> read(String id) {
      expect(id, '123');
      reads++;
      return pending.future;
    }

    final requests = [
      store.resolve(
        account: account,
        id: '123',
        readState: read,
        isCurrentAccount: () => true,
      ),
      store.resolve(
        account: account,
        id: '123',
        readState: read,
        isCurrentAccount: () => true,
      ),
    ];
    await Future<void>.delayed(Duration.zero);
    expect(reads, 1);
    expect(first.isBusy(account, _comic(known: false)), isFalse);
    expect(second.isBusy(account, _comic(known: false)), isFalse);
    pending.complete(Res(_state(true)));
    await Future.wait(requests);

    expect(first.isBookmarked(account, _comic(known: false)), isTrue);
    expect(second.isBookmarked(account, _comic()), isTrue);
    await store.resolve(
      account: account,
      id: '123',
      readState: read,
      isCurrentAccount: () => true,
    );
    expect(reads, 1, reason: '再次出现的可见卡片应复用刚确认的状态');
  });

  test('an early heart tap reuses the visible lookup and toggles its authority',
      () async {
    final value = controller(resolveUnknown: true);
    final comic = _comic(known: false);
    final pending = Completer<Res<PixivBookmarkState>>();
    final targets = <bool>[];
    var reads = 0;
    Future<Res<PixivBookmarkState>> read(String id) {
      expect(id, comic.id);
      reads++;
      return pending.future;
    }

    final visibleRead = value.ensureConfirmedState(
      account: account,
      comic: comic,
      readState: read,
      isCurrentAccount: () => true,
    );
    await Future<void>.delayed(Duration.zero);
    expect(reads, 1);
    expect(value.isBusy(account, comic), isFalse, reason: '可见卡片后台确认不是用户的收藏操作');
    final action = value.toggle(
      account: account,
      comic: comic,
      readState: read,
      write: (_, {required isAdding}) async {
        targets.add(isAdding);
        return const Res(true);
      },
      isCurrentAccount: () => true,
    );
    await Future<void>.delayed(Duration.zero);
    expect(reads, 1);
    expect(value.isBusy(account, comic), isTrue);
    expect(value.isBusy(account, _comic(id: '456', known: false)), isFalse);
    expect(targets, isEmpty);

    pending.complete(Res(_state(true)));
    await visibleRead;
    final result = await action;
    expect(reads, 1);
    expect(targets, [false], reason: '应基于平台确认的已收藏状态执行一次取消');
    expect(result?.data, isFalse);
    expect(value.isBusy(account, comic), isFalse);
    expect(store.stateFor(account, comic.id)?.isBookmarked, isFalse);
  });

  test(
      'visible state resolution limits concurrent requests and drains its queue',
      () async {
    final pending = <String, Completer<Res<PixivBookmarkState>>>{};
    var active = 0;
    var peak = 0;
    Future<Res<PixivBookmarkState>> read(String id) async {
      active++;
      if (active > peak) peak = active;
      final response = Completer<Res<PixivBookmarkState>>();
      pending[id] = response;
      try {
        return await response.future;
      } finally {
        active--;
      }
    }

    final requests = [
      for (final id in ['123', '456', '789'])
        store.resolve(
          account: account,
          id: id,
          readState: read,
          isCurrentAccount: () => true,
        ),
    ];
    await Future<void>.delayed(Duration.zero);
    expect(pending.keys, containsAll(['123', '456']));
    expect(pending, hasLength(2));
    pending['123']!.complete(Res(_state(true)));
    await Future<void>.delayed(Duration.zero);
    expect(pending, hasLength(3));
    pending['456']!.complete(Res(_state(false)));
    pending['789']!.complete(Res(_state(true)));
    await Future.wait(requests);

    expect(peak, 2);
    expect(store.stateFor(account, '123')?.isBookmarked, isTrue);
    expect(store.stateFor(account, '456')?.isBookmarked, isFalse);
    expect(store.stateFor(account, '789')?.isBookmarked, isTrue);
  });
}

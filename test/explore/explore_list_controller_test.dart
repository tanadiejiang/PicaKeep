/// 探索列表控制器 [ExploreListController] 的行为测试。
///
/// 覆盖面（全部是行为断言，不做字段复述）：
/// - 首屏成功：items 映射 / hasMore / totalPages / optionId；
/// - 首屏失败：error 有值且 items 为空；
/// - 续页成功：追加而非替换，并按 `sourceKey + comic.id` 去重；
/// - 续页失败：保留旧 items 与 nextToken，同一 token 可重试成功；
/// - 单页入口（hasMore=false）：loadMore() 不发请求；
/// - 无选项入口：续页复用首屏选项（回归"续页发空选项被 Registry 拒"的缺陷）；
/// - reloadBatch：替换当前批次而不是追加；
/// - 有 next 但连续返回同一页：停止自动追页且不再无限请求；
/// - 代次竞态：慢的旧请求最后返回也不得覆盖新选择；
/// - dispose 后异步回调不再 notifyListeners（不抛异常）；
/// - applyBlockingResolver：只重算现有条目、不重新请求。
///
/// 用真实的 [ExploreRegistry]（保证 opaque 续页句柄走真实编解码）+ 可编程、
/// 可挂起的 fake provider。全程纯逻辑：不 import 网络单例、不发真实请求。
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/explore/explore_models.dart';
import 'package:picakeep/foundation/explore/explore_provider.dart';
import 'package:picakeep/foundation/explore/explore_registry.dart';
import 'package:picakeep/network/base_comic.dart';
import 'package:picakeep/pages/explore/explore_list_controller.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  测试替身
// ─────────────────────────────────────────────────────────────────────────────

class _FakeComic extends BaseComic {
  const _FakeComic(this.id);

  @override
  final String id;
  @override
  String get title => 'title-$id';
  @override
  String get subTitle => '';
  @override
  String get cover => '';
  @override
  List<String> get tags => const <String>[];
  @override
  String get description => '';
}

/// 一次 `loadComics` 的脚本：条目 id 序列 + 续页游标 + 可选错误 / 挂起闸门。
class _Step {
  _Step({
    this.ids = const <String>[],
    this.nextCursor,
    this.totalPages,
    this.error,
    this.gate,
  });

  final List<String> ids;
  final String? nextCursor;
  final int? totalPages;
  final ExploreError? error;

  /// 非 null 时 provider 会挂起，直到测试手动 complete —— 用来构造竞态。
  final Completer<void>? gate;
}

/// 可编程 fake provider：按调用次序取脚本，支持挂起。
///
/// 私有类型：本文件只用它驱动 [ExploreListController]，不构成公开 API，
/// 因此可以安全地暴露私有脚本类型 [_Step]。
class _ScriptedExploreProvider implements ExploreProvider {
  _ScriptedExploreProvider(this.descriptor);

  @override
  final ExploreSourceDescriptor descriptor;

  final List<ExploreRequest> comicsRequests = <ExploreRequest>[];

  /// 每次 loadComics 返回的脚本；用尽后重复最后一项。
  List<_Step> script = <_Step>[_Step()];

  int _call = 0;

  @override
  bool get isLoggedIn => true;

  @override
  String get contextFingerprint => 'fp-1';

  @override
  Future<ExploreResult<ExploreDirectory>> loadDirectory(
    ExploreRequest request,
  ) async {
    throw UnimplementedError('本文件不覆盖目录加载');
  }

  @override
  Future<ExploreResult<ExploreOverview>> loadOverview(
    ExploreRequest request,
  ) async {
    throw UnimplementedError('本文件不覆盖概览加载');
  }

  @override
  Future<ExploreResult<ExploreComicPage>> loadComics(
    ExploreRequest request,
  ) async {
    // 先登记请求再等待闸门：竞态测试必须在挂起期间就能看到请求次数。
    comicsRequests.add(request);
    final step = script[_call < script.length ? _call : script.length - 1];
    _call++;
    final gate = step.gate;
    if (gate != null) await gate.future;
    final error = step.error;
    if (error != null) return ExploreFailure<ExploreComicPage>(error);
    return ExploreSuccess<ExploreComicPage>(ExploreComicPage(
      sourceKey: descriptor.sourceKey,
      entryId: request.entryId,
      items: <BaseComic>[for (final id in step.ids) _FakeComic(id)],
      nextToken: step.nextCursor,
      totalPages: step.totalPages,
    ));
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  夹具
// ─────────────────────────────────────────────────────────────────────────────

const String _sourceKey = 'fake';
const String _listEntryId = 'list';
const String _singlePageEntryId = 'random';
const String _plainEntryId = 'plain';

const ExploreSourceDescriptor _descriptor = ExploreSourceDescriptor(
  sourceKey: _sourceKey,
  name: 'Fake',
  requiresLogin: false,
  entries: <ExploreEntry>[
    ExploreEntry(
      id: _listEntryId,
      label: '列表',
      kind: ExploreSectionKind.recommend,
      options: <ExploreOption>[ExploreOption(id: 'opt', label: '选项')],
      defaultOptionId: 'opt',
    ),
    ExploreEntry(
      id: _plainEntryId,
      label: '无选项列表',
      kind: ExploreSectionKind.recommend,
    ),
    ExploreEntry(
      id: _singlePageEntryId,
      label: '随机',
      kind: ExploreSectionKind.recommend,
      singlePage: true,
    ),
  ],
);

/// 一个控制器 + 它的真实 Registry / provider。
class _Harness {
  _Harness({String entryId = _listEntryId}) {
    provider = _ScriptedExploreProvider(_descriptor);
    registry = ExploreRegistry()..register(provider);
    sessionId = registry.createSession();
    controller = ExploreListController(
      registry: registry,
      sourceKey: _sourceKey,
      entryId: entryId,
      sessionId: sessionId,
    );
  }

  late final _ScriptedExploreProvider provider;
  late final ExploreRegistry registry;
  late final String sessionId;
  late final ExploreListController controller;

  /// 当前提交到 state 的条目 id 序列。
  List<String> get ids =>
      controller.state.items.map((item) => item.comic.id).toList();

  int get requestCount => provider.comicsRequests.length;
}

/// 该入口唯一的选项（显式传入以断言 optionId 透传）。
const ExploreOptions _option = ExploreOptions(<String>['opt']);

void main() {
  test('首屏成功：items 映射、hasMore、totalPages、optionId', () async {
    final h = _Harness();
    h.provider.script = <_Step>[
      _Step(ids: <String>['a', 'b'], nextCursor: 'cursor-2', totalPages: 3),
    ];

    await h.controller.load(options: _option);

    final state = h.controller.state;
    expect(h.ids, <String>['a', 'b']);
    expect(state.items.map((item) => item.comic.title).toList(),
        <String>['title-a', 'title-b']);
    expect(state.hasMore, isTrue);
    expect(state.totalPages, 3);
    expect(state.optionId, 'opt');
    expect(state.loading, isFalse);
    expect(state.error, isNull);
    expect(state.moreError, isNull);
    // 唯一一次请求带着解析后的选项，且首屏没有续页游标。
    expect(h.requestCount, 1);
    expect(h.provider.comicsRequests.single.options.first, 'opt');
    expect(h.provider.comicsRequests.single.continuation, isNull);
  });

  test('首屏失败：error 有值且 items 为空', () async {
    final h = _Harness();
    h.provider.script = <_Step>[
      _Step(error: const ExploreError(ExploreErrorCode.loginRequired, '请先登录')),
    ];

    await h.controller.load(options: _option);

    final state = h.controller.state;
    expect(state.error?.code, ExploreErrorCode.loginRequired);
    expect(state.error?.message, '请先登录');
    expect(state.items, isEmpty);
    expect(state.loading, isFalse);
    expect(state.hasMore, isFalse);
    expect(state.totalPages, isNull);
    expect(h.requestCount, 1);
  });

  test('续页成功：追加而非替换，并按 sourceKey + comic.id 去重', () async {
    final h = _Harness();
    h.provider.script = <_Step>[
      _Step(ids: <String>['a', 'b'], nextCursor: 'cursor-2'),
      // 第二页故意重复 b：必须被去重，不能出现两条 b。
      _Step(ids: <String>['b', 'c']),
    ];

    await h.controller.load(options: _option);
    await h.controller.loadMore();

    expect(h.ids, <String>['a', 'b', 'c'], reason: '续页是追加而不是替换');
    expect(h.controller.state.hasMore, isFalse);
    expect(h.controller.state.moreError, isNull);

    // 去重身份由 sourceKey + comic.id 共同构成。
    final items = h.controller.state.items;
    expect(items[0].dedupeKeyOf(_sourceKey), contains('a'));
    expect(
      items[0].dedupeKeyOf(_sourceKey),
      isNot(items[1].dedupeKeyOf(_sourceKey)),
      reason: '同源下不同 id 必须是不同身份',
    );
    expect(
      items[0].dedupeKeyOf(_sourceKey),
      isNot(items[0].dedupeKeyOf('other-source')),
      reason: 'id 相同但源不同必须是不同身份',
    );
  });

  test('续页失败：保留旧 items 与 nextToken，同一 token 重试成功', () async {
    final h = _Harness();
    h.provider.script = <_Step>[
      _Step(ids: <String>['a'], nextCursor: 'cursor-2'),
      _Step(error: const ExploreError(ExploreErrorCode.network, '续页失败')),
      _Step(ids: <String>['b']),
    ];

    await h.controller.load(options: _option);
    final tokenBefore = h.controller.nextToken;
    expect(tokenBefore, isNotNull);
    expect(h.ids, <String>['a']);

    await h.controller.loadMore();

    expect(h.requestCount, 2);
    expect(h.controller.state.moreError?.code, ExploreErrorCode.network);
    expect(h.controller.state.loadingMore, isFalse);
    expect(h.ids, <String>['a'], reason: '续页失败必须保留旧条目');
    expect(h.controller.nextToken, tokenBefore, reason: '续页失败不得清掉 token');
    expect(h.controller.state.hasMore, isTrue,
        reason: '保留 token 时 hasMore 必须仍然为真，否则页尾不给重试入口');

    // 用同一 token 重试（token 未被清掉，所以自动走同一页）。
    await h.controller.loadMore();

    expect(h.requestCount, 3);
    expect(h.provider.comicsRequests[1].continuation, 'cursor-2');
    expect(h.provider.comicsRequests[2].continuation, 'cursor-2',
        reason: '重试必须复用同一个游标');
    expect(h.controller.state.moreError, isNull);
    expect(h.ids, <String>['a', 'b']);
    expect(h.controller.state.hasMore, isFalse);
  });

  test('无选项入口：续页复用首屏的选项，不会被 Registry 判成"不接受选项"', () async {
    final h = _Harness(entryId: _plainEntryId);
    h.provider.script = <_Step>[
      _Step(ids: <String>['a'], nextCursor: 'cursor-2'),
      _Step(ids: <String>['b']),
    ];

    await h.controller.load();

    expect(h.controller.state.optionId, isNull, reason: '该入口没有选项');
    expect(h.controller.state.hasMore, isTrue);
    expect(h.requestCount, 1);

    await h.controller.loadMore();

    // 旧实现续页发送 ExploreOptions.single('')，会被 Registry 以
    // invalidArgument（该入口不接受选项）直接拒掉且不发请求。
    expect(h.requestCount, 2, reason: '续页必须真的打到 provider');
    expect(h.controller.state.moreError, isNull);
    expect(h.provider.comicsRequests.last.options.isEmpty, isTrue,
        reason: '无选项入口的续页必须继续不带选项');
    expect(h.provider.comicsRequests.last.continuation, 'cursor-2');
    expect(h.ids, <String>['a', 'b']);
    expect(h.controller.state.hasMore, isFalse);
  });

  test('单页入口（hasMore=false）：loadMore() 不发请求', () async {
    final h = _Harness(entryId: _singlePageEntryId);
    h.provider.script = <_Step>[
      _Step(ids: <String>['a', 'b'], nextCursor: 'ignored'),
    ];

    await h.controller.load();

    expect(h.requestCount, 1);
    expect(h.ids, <String>['a', 'b']);
    expect(h.controller.state.hasMore, isFalse, reason: '单页入口不得发放续页句柄');
    expect(h.controller.nextToken, isNull);

    await h.controller.loadMore();
    await h.controller.loadMore();

    expect(h.requestCount, 1, reason: '没有 token 时 loadMore 不得发请求');
    expect(h.ids, <String>['a', 'b']);
  });

  test('reloadBatch 换一批：替换当前批次而不是追加', () async {
    final h = _Harness();
    h.provider.script = <_Step>[
      _Step(ids: <String>['a', 'b'], nextCursor: 'cursor-2'),
      _Step(ids: <String>['c'], nextCursor: 'cursor-3'),
      _Step(ids: <String>['x']),
    ];

    await h.controller.load(options: _option);
    await h.controller.loadMore();
    expect(h.ids, <String>['a', 'b', 'c'], reason: '前置条件：续页确实追加过');

    await h.controller.reloadBatch();

    expect(h.requestCount, 3);
    expect(h.ids, <String>['x'], reason: '换一批必须替换整个批次');
    expect(h.controller.state.hasMore, isFalse);
    expect(h.controller.state.moreError, isNull);
  });

  test('有 next 但连续返回同一页：停止自动追页且不再无限请求', () async {
    final h = _Harness();
    h.provider.script = <_Step>[
      _Step(ids: <String>['a', 'b'], nextCursor: 'cursor-2'),
      // 同一 id 序列 + 仍然带 next：异常响应。
      _Step(ids: <String>['a', 'b'], nextCursor: 'cursor-3'),
      _Step(ids: <String>['c']),
    ];

    await h.controller.load(options: _option);
    expect(h.controller.state.hasMore, isTrue);

    await h.controller.loadMore();

    expect(h.requestCount, 2);
    expect(h.controller.state.hasMore, isFalse, reason: '连续同页必须停止自动追页');
    expect(h.controller.state.moreError, isNotNull);
    expect(h.controller.state.moreError?.code, ExploreErrorCode.parse);
    expect(h.ids, <String>['a', 'b'], reason: '重复页不得再次并入');
    expect(h.controller.nextToken, isNull);

    // 不会无限请求：再点多少次都不再发。
    for (var i = 0; i < 5; i++) {
      await h.controller.loadMore();
    }
    expect(h.requestCount, 2);
    expect(h.ids, <String>['a', 'b']);
  });

  test('代次竞态：慢的旧请求最后返回也不覆盖新选择', () async {
    final h = _Harness();
    final gateA = Completer<void>();
    h.provider.script = <_Step>[
      _Step(ids: <String>['stale'], gate: gateA),
      _Step(ids: <String>['fresh-1', 'fresh-2']),
    ];

    final slow = h.controller.load(options: _option);
    expect(h.requestCount, 1, reason: 'A 已经发出并且被挂起');

    final fast = h.controller.load(options: _option);
    expect(h.requestCount, 2);
    await fast;

    expect(h.ids, <String>['fresh-1', 'fresh-2']);

    // A 现在才返回：它的代次已经过期，必须被丢弃。
    gateA.complete();
    await slow;

    expect(h.ids, <String>['fresh-1', 'fresh-2'], reason: '旧代次的响应不得覆盖新选择');
    expect(h.controller.state.loading, isFalse);
    expect(h.controller.state.error, isNull);
    expect(h.requestCount, 2);
  });

  test('dispose 后异步回调不再 notifyListeners，也不抛异常', () async {
    final h = _Harness();
    final gate = Completer<void>();
    h.provider.script = <_Step>[
      _Step(ids: <String>['a'], gate: gate)
    ];

    var notifications = 0;
    h.controller.addListener(() => notifications++);

    final pending = h.controller.load(options: _option);
    expect(notifications, greaterThan(0));
    final beforeDispose = notifications;

    h.controller.dispose();
    gate.complete();

    // 若 dispose 后仍然 notifyListeners，这里会因为
    // "A ExploreListController was used after being disposed" 直接失败。
    await pending;
    await Future<void>.delayed(Duration.zero);

    expect(notifications, beforeDispose, reason: 'dispose 后不得再通知监听者');
    expect(h.ids, isEmpty, reason: 'dispose 后的响应不得提交到 state');

    // dispose 之后再调用 load 直接返回，不发请求。
    await h.controller.load(options: _option);
    expect(h.requestCount, 1);
  });

  test('applyBlockingResolver：只重算现有条目、不重新请求', () async {
    final h = _Harness();
    h.provider.script = <_Step>[
      _Step(ids: <String>['a', 'b'], nextCursor: 'cursor-2'),
    ];

    await h.controller.load(options: _option);
    expect(h.requestCount, 1);

    h.controller.applyBlockingResolver(
      (comic) => comic.id == 'b' ? 'blocked-word' : null,
    );

    expect(h.requestCount, 1, reason: '重算屏蔽不得重新请求');
    final items = h.controller.state.items;
    expect(items.map((item) => item.comic.id).toList(), <String>['a', 'b'],
        reason: '重算必须保留条目与位置');
    expect(items[0].isBlocked, isFalse);
    expect(items[0].blockedBy, isNull);
    expect(items[1].isBlocked, isTrue);
    expect(items[1].blockedBy, 'blocked-word');
    expect(h.controller.state.hasVisibleItems, isTrue);
    expect(h.controller.state.isEmpty, isFalse);
    // 旧条目保留原始 comic，屏蔽词变化不需要重新拉数据。
    expect(items[1].comic.title, 'title-b');

    // 换成"全部屏蔽"：仍不请求，只是可见性变化。
    h.controller.applyBlockingResolver((comic) => 'all');
    expect(h.requestCount, 1);
    expect(h.controller.state.hasVisibleItems, isFalse);
    expect(h.controller.state.isEmpty, isTrue);
    expect(h.controller.state.items, hasLength(2));

    // 清掉屏蔽：blockedBy 回落为 null。
    h.controller.applyBlockingResolver(null);
    expect(h.requestCount, 1);
    expect(h.ids, <String>['a', 'b']);
    expect(h.controller.state.items.every((item) => !item.isBlocked), isTrue);
  });
}

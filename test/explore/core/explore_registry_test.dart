/// 探索 Registry / 会话 / 续页句柄的纯 Dart 契约测试。
///
/// 只依赖 `package:test` 与纯层文件：不 import Flutter、不碰磁盘、不发网络。
library;

import 'dart:async';

import 'package:picakeep/foundation/explore/explore_models.dart';
import 'package:picakeep/foundation/explore/explore_provider.dart';
import 'package:picakeep/foundation/explore/explore_registry.dart';
import 'package:picakeep/network/base_comic.dart';
import 'package:test/test.dart';

class _FakeComic extends BaseComic {
  const _FakeComic(this.id);

  @override
  final String id;
  @override
  String get title => 'T';
  @override
  String get subTitle => '';
  @override
  String get cover => '';
  @override
  List<String> get tags => const <String>[];
  @override
  String get description => '';
}

/// 可编程 fake provider：记录收到的请求，按脚本返回结果。
class FakeExploreProvider implements ExploreProvider {
  FakeExploreProvider({
    required this.descriptor,
    this.loggedIn = true,
    this.fingerprint = 'fp-1',
  });

  @override
  final ExploreSourceDescriptor descriptor;

  bool loggedIn;
  String fingerprint;

  final List<ExploreRequest> comicsRequests = <ExploreRequest>[];
  final List<ExploreRequest> directoryRequests = <ExploreRequest>[];
  final List<ExploreRequest> overviewRequests = <ExploreRequest>[];

  /// 每次 loadComics 返回的 (items, nextCursor)；按调用次序取，用尽后重复最后一项。
  List<({int count, String? next})> comicsScript =
      <({int count, String? next})>[
    (count: 1, next: null),
  ];

  /// 每次 loadOverview 返回的 sections。
  List<ExploreSection> overviewSections = const <ExploreSection>[];

  ExploreError? comicsError;
  ExploreError? directoryError;
  ExploreError? overviewError;
  Future<void>? responseGate;

  int _comicsCall = 0;

  @override
  bool get isLoggedIn => loggedIn;

  @override
  String get contextFingerprint => fingerprint;

  @override
  Future<ExploreResult<ExploreDirectory>> loadDirectory(
    ExploreRequest request,
  ) async {
    directoryRequests.add(request);
    if (responseGate != null) await responseGate;
    final error = directoryError;
    if (error != null) return ExploreFailure(error);
    return ExploreSuccess(ExploreDirectory(
      sourceKey: descriptor.sourceKey,
      groups: const <ExploreCategoryGroup>[
        ExploreCategoryGroup(id: 'g', title: 'G', items: <ExploreCategoryItem>[
          ExploreCategoryItem(
            id: 'c1',
            label: 'C1',
            route: ExploreCategoryTarget(kind: 'native', value: 'c1'),
          ),
        ]),
      ],
    ));
  }

  @override
  Future<ExploreResult<ExploreOverview>> loadOverview(
    ExploreRequest request,
  ) async {
    overviewRequests.add(request);
    if (responseGate != null) await responseGate;
    final error = overviewError;
    if (error != null) return ExploreFailure(error);
    return ExploreSuccess(ExploreOverview(
      sourceKey: descriptor.sourceKey,
      entryId: request.entryId,
      sections: overviewSections,
    ));
  }

  @override
  Future<ExploreResult<ExploreComicPage>> loadComics(
    ExploreRequest request,
  ) async {
    comicsRequests.add(request);
    if (responseGate != null) await responseGate;
    final error = comicsError;
    if (error != null) return ExploreFailure(error);
    final script = comicsScript[_comicsCall < comicsScript.length
        ? _comicsCall
        : comicsScript.length - 1];
    _comicsCall++;
    return ExploreSuccess(ExploreComicPage(
      sourceKey: descriptor.sourceKey,
      entryId: request.entryId,
      items: <BaseComic>[
        for (var i = 0; i < script.count; i++)
          _FakeComic('${request.entryId}-$i'),
      ],
      nextToken: script.next,
    ));
  }
}

const _recommendEntry = ExploreEntry(
  id: 'home',
  label: '主页',
  kind: ExploreSectionKind.recommend,
);

const _listEntry = ExploreEntry(
  id: 'latest',
  label: '最新',
  kind: ExploreSectionKind.recommend,
);

const _rankEntry = ExploreEntry(
  id: 'ranking',
  label: '榜单',
  kind: ExploreSectionKind.ranking,
  options: <ExploreOption>[
    ExploreOption(id: 'today', label: '今日'),
    ExploreOption(id: 'week', label: '本周'),
  ],
  defaultOptionId: 'today',
);

const _singlePageEntry = ExploreEntry(
  id: 'random',
  label: '随机',
  kind: ExploreSectionKind.recommend,
  singlePage: true,
);

const _categoryEntry = ExploreEntry(
  id: 'categories',
  label: '分类',
  kind: ExploreSectionKind.category,
);

FakeExploreProvider _makeProvider({
  String key = 'jm',
  List<ExploreEntry> entries = const <ExploreEntry>[
    _listEntry,
    _rankEntry,
    _singlePageEntry,
    _categoryEntry,
  ],
}) {
  return FakeExploreProvider(
    descriptor: ExploreSourceDescriptor(
      sourceKey: key,
      name: key,
      entries: entries,
    ),
  );
}

void main() {
  group('Registry 描述与能力', () {
    test('listSources 返回注册的源与入口，且不暴露 Widget/BuildContext', () {
      final registry = ExploreRegistry()
        ..register(_makeProvider(key: 'jm'))
        ..register(_makeProvider(key: 'nhentai'));
      final sources = registry.listSources();
      expect(sources.map((s) => s.sourceKey), <String>['jm', 'nhentai']);
      expect(sources.first.entries.map((e) => e.id),
          <String>['latest', 'ranking', 'random', 'categories']);
    });

    test('describe 未知源返回 null；hasSource 大小写不敏感', () {
      final registry = ExploreRegistry()..register(_makeProvider());
      expect(registry.describe('missing'), isNull);
      expect(registry.hasSource('JM'), isTrue);
      expect(registry.describe('JM')?.sourceKey, 'jm');
    });

    test('listSourceStates 实时读取登录态（注册后改变也生效）', () {
      final provider = _makeProvider();
      final registry = ExploreRegistry()..register(provider);
      expect(registry.listSourceStates().single.loggedIn, isTrue);
      provider.loggedIn = false;
      expect(registry.listSourceStates().single.loggedIn, isFalse);
    });

    test('缺省选项由描述符给出；未知选项报 invalidArgument 且不发网络', () async {
      final provider = _makeProvider();
      final registry = ExploreRegistry()..register(provider);
      final session = registry.createSession();

      final ok = await registry.loadComics(ExploreRequest(
        sessionId: session,
        sourceKey: 'jm',
        entryId: 'ranking',
      ));
      expect(ok.isSuccess, isTrue);
      expect(provider.comicsRequests.single.options.first, 'today');

      final bad = await registry.loadComics(ExploreRequest(
        sessionId: session,
        sourceKey: 'jm',
        entryId: 'ranking',
        options: const ExploreOptions(<String>['nope']),
      ));
      expect(bad.errorOrNull?.code, ExploreErrorCode.invalidArgument);
      expect(provider.comicsRequests.length, 1);
    });

    test('未知源与未知入口报 unsupported，且不发网络', () async {
      final provider = _makeProvider();
      final registry = ExploreRegistry()..register(provider);
      final session = registry.createSession();

      final unknownSource = await registry.loadComics(ExploreRequest(
        sessionId: session,
        sourceKey: 'ghost',
        entryId: 'latest',
      ));
      expect(unknownSource.errorOrNull?.code, ExploreErrorCode.unsupported);

      final unknownEntry = await registry.loadComics(ExploreRequest(
        sessionId: session,
        sourceKey: 'jm',
        entryId: 'ghost',
      ));
      expect(unknownEntry.errorOrNull?.code, ExploreErrorCode.unsupported);
      expect(provider.comicsRequests, isEmpty);
    });

    test('缺少会话 ID 报 invalidArgument', () async {
      final registry = ExploreRegistry()..register(_makeProvider());
      final result = await registry.loadComics(const ExploreRequest(
        sessionId: '',
        sourceKey: 'jm',
        entryId: 'latest',
      ));
      expect(result.errorOrNull?.code, ExploreErrorCode.invalidArgument);
    });
  });

  group('Registry.load 统一分派', () {
    const weekEntry = ExploreEntry(
      id: 'week',
      label: '每周推荐',
      kind: ExploreSectionKind.recommend,
      directoryAsTab: true,
    );
    late FakeExploreProvider provider;
    late ExploreRegistry registry;
    late String session;

    setUp(() {
      provider = _makeProvider(entries: const [
        _recommendEntry,
        _listEntry,
        _categoryEntry,
        _rankEntry,
        _singlePageEntry,
        weekEntry,
      ]);
      registry = ExploreRegistry()..register(provider);
      session = registry.createSession();
    });

    test('分类无目标加载目录，带目标加载漫画结果', () async {
      final dir = await registry.load(ExploreRequest(
        sessionId: session,
        sourceKey: 'jm',
        entryId: 'categories',
      ));
      expect(dir.dataOrNull, isA<ExploreDirectory>());
      expect(provider.directoryRequests.length, 1);

      final comics = await registry.load(ExploreRequest(
        sessionId: session,
        sourceKey: 'jm',
        entryId: 'categories',
        category: const ExploreCategoryTarget(kind: 'native', value: 'sample'),
      ));
      expect(comics.dataOrNull, isA<ExploreComicPage>());
      expect(provider.comicsRequests.length, 1);
      expect(provider.comicsRequests.single.category?.value, 'sample');
      expect(provider.directoryRequests.length, 1);
      expect(provider.overviewRequests, isEmpty);
    });

    test('每周推荐无期号先读目录，有期号直接加载对应内容', () async {
      final directory = await registry.load(ExploreRequest(
        sessionId: session,
        sourceKey: 'jm',
        entryId: 'week',
      ));
      final comics = await registry.load(ExploreRequest(
        sessionId: session,
        sourceKey: 'jm',
        entryId: 'week',
        category: const ExploreCategoryTarget(kind: 'period', value: 'sample'),
      ));

      expect(directory.dataOrNull, isA<ExploreDirectory>());
      expect(comics.dataOrNull, isA<ExploreComicPage>());
      expect(provider.directoryRequests, hasLength(1));
      expect(provider.comicsRequests, hasLength(1));
      expect(provider.overviewRequests, isEmpty);
    });

    test('主页概览成功时不重复请求漫画接口', () async {
      final result = await registry.load(ExploreRequest(
        sessionId: session,
        sourceKey: 'jm',
        entryId: 'home',
      ));

      expect(result.dataOrNull, isA<ExploreOverview>());
      expect(provider.overviewRequests, hasLength(1));
      expect(provider.comicsRequests, isEmpty);
      expect(provider.directoryRequests, isEmpty);
    });

    test('普通推荐仅在概览 unsupported 时回落列表，续页直接加载列表', () async {
      provider.overviewError =
          const ExploreError(ExploreErrorCode.unsupported, 'No overview');
      provider.comicsScript = [(count: 1, next: 'second-page')];
      final first = await registry.load(ExploreRequest(
        sessionId: session,
        sourceKey: 'jm',
        entryId: 'latest',
      ));
      final page = first.dataOrNull! as ExploreComicPage;
      expect(page.nextToken, isNotNull);
      expect(provider.overviewRequests, hasLength(1));
      expect(provider.comicsRequests, hasLength(1));

      final second = await registry.load(ExploreRequest(
        sessionId: session,
        sourceKey: 'jm',
        entryId: 'latest',
        continuation: page.nextToken,
      ));
      expect(second.dataOrNull, isA<ExploreComicPage>());
      expect(provider.overviewRequests, hasLength(1));
      expect(provider.comicsRequests, hasLength(2));
      expect(provider.comicsRequests.last.continuation, 'second-page');
    });

    for (final code in ExploreErrorCode.values
        .where((code) => code != ExploreErrorCode.unsupported)) {
      test('概览 $code 错误原样返回，不请求列表掩盖错误', () async {
        final error = ExploreError(code, 'Sample failure');
        provider.overviewError = error;
        final result = await registry.load(ExploreRequest(
          sessionId: session,
          sourceKey: 'jm',
          entryId: 'home',
        ));

        expect(result.errorOrNull, same(error));
        expect(provider.overviewRequests, hasLength(1));
        expect(provider.comicsRequests, isEmpty);
      });
    }

    test('榜单和单页随机直接读取列表', () async {
      for (final entry in ['ranking', 'random']) {
        final result = await registry.load(ExploreRequest(
          sessionId: session,
          sourceKey: 'jm',
          entryId: entry,
        ));
        expect(result.dataOrNull, isA<ExploreComicPage>());
      }
      expect(provider.comicsRequests, hasLength(2));
      expect(provider.comicsRequests.first.options.first, 'today');
      expect(provider.overviewRequests, isEmpty);
      expect(provider.directoryRequests, isEmpty);
    });

    test('推荐条目携带分区目标或 categoryId 时直接读取列表', () async {
      for (final target in [
        const ExploreCategoryTarget(kind: 'section', value: 'sample'),
        null,
      ]) {
        final result = await registry.load(ExploreRequest(
          sessionId: session,
          sourceKey: 'jm',
          entryId: 'home',
          category: target,
          categoryId: target == null ? 'sample' : null,
        ));
        expect(result.dataOrNull, isA<ExploreComicPage>());
      }
      expect(provider.comicsRequests, hasLength(2));
      expect(provider.overviewRequests, isEmpty);
      expect(provider.directoryRequests, isEmpty);
    });

    test('统一入口校验失败不触发任何 provider 请求', () async {
      final result = await registry.load(ExploreRequest(
        sessionId: session,
        sourceKey: 'jm',
        entryId: 'ranking',
        options: ExploreOptions.single('unknown'),
      ));
      expect(result.errorOrNull?.code, ExploreErrorCode.invalidArgument);
      expect(provider.comicsRequests, isEmpty);
      expect(provider.overviewRequests, isEmpty);
      expect(provider.directoryRequests, isEmpty);
    });
  });

  group('登录闸门与请求上下文', () {
    for (final endpoint in ['overview', 'directory', 'comics', 'unified']) {
      Future<ExploreResult<Object>> request(
        ExploreRegistry registry,
        String session,
      ) async {
        final req = ExploreRequest(
          sessionId: session,
          sourceKey: 'jm',
          entryId: endpoint == 'directory' ? 'categories' : 'home',
        );
        return switch (endpoint) {
          'overview' => registry.loadOverview(req),
          'directory' => registry.loadDirectory(req),
          'comics' => registry.loadComics(req),
          _ => registry.load(req),
        };
      }

      FakeExploreProvider provider({bool requiresLogin = true}) =>
          FakeExploreProvider(
            descriptor: ExploreSourceDescriptor(
              sourceKey: 'jm',
              name: 'Sample',
              requiresLogin: requiresLogin,
              entries: const [_recommendEntry, _categoryEntry],
            ),
          );

      test('$endpoint：需登录源在未登录时不发任何请求', () async {
        final fake = provider()..loggedIn = false;
        final registry = ExploreRegistry()..register(fake);
        final result = await request(registry, registry.createSession());

        expect(result.errorOrNull?.code, ExploreErrorCode.loginRequired);
        expect(fake.comicsRequests, isEmpty);
        expect(fake.overviewRequests, isEmpty);
        expect(fake.directoryRequests, isEmpty);
      });

      test('$endpoint：不需登录的源允许匿名请求', () async {
        final fake = provider(requiresLogin: false)..loggedIn = false;
        final registry = ExploreRegistry()..register(fake);
        final result = await request(registry, registry.createSession());

        expect(result.isSuccess, isTrue);
        expect(
            fake.comicsRequests.length +
                fake.overviewRequests.length +
                fake.directoryRequests.length,
            1);
      });

      test('$endpoint：请求途中更换账号/站点时丢弃旧响应并释放本会话', () async {
        final gate = Completer<void>();
        final fake = provider()..responseGate = gate.future;
        final registry = ExploreRegistry()..register(fake);
        final session = registry.createSession();
        final otherSession = registry.createSession();
        final pending = request(registry, session);
        fake.fingerprint = 'new-context';
        gate.complete();
        final result = await pending;

        expect(result.dataOrNull, isNull);
        expect(result.errorOrNull?.code, ExploreErrorCode.expiredContinuation);
        expect(result.errorOrNull?.message, isNot(contains('new-context')));
        expect(registry.isSessionAlive(session), isFalse);
        expect(registry.isSessionAlive(otherSession), isTrue);
      });

      test('$endpoint：请求途中退出时返回需登录，不提交旧响应', () async {
        final gate = Completer<void>();
        final fake = provider()..responseGate = gate.future;
        final registry = ExploreRegistry()..register(fake);
        final session = registry.createSession();
        final pending = request(registry, session);
        fake.loggedIn = false;
        gate.complete();
        final result = await pending;

        expect(result.dataOrNull, isNull);
        expect(result.errorOrNull?.code, ExploreErrorCode.loginRequired);
        expect(registry.isSessionAlive(session), isFalse);
      });
    }

    test('身份变化期间返回 unsupported 不得继续用新身份回落到列表', () async {
      final gate = Completer<void>();
      final provider = _makeProvider(entries: const [_recommendEntry])
        ..responseGate = gate.future
        ..overviewError =
            const ExploreError(ExploreErrorCode.unsupported, 'No overview');
      final registry = ExploreRegistry()..register(provider);
      final pending = registry.load(ExploreRequest(
        sessionId: registry.createSession(),
        sourceKey: 'jm',
        entryId: 'home',
      ));
      provider.fingerprint = 'new-context';
      gate.complete();

      expect((await pending).errorOrNull?.code,
          ExploreErrorCode.expiredContinuation);
      expect(provider.overviewRequests, hasLength(1));
      expect(provider.comicsRequests, isEmpty);
    });
  });

  group('续页句柄', () {
    test('首个请求无 token；有后续时必须回传 token 且与 hasMore 一致', () async {
      final provider = _makeProvider()
        ..comicsScript = <({int count, String? next})>[
          (count: 2, next: 'cursor-2'),
          (count: 1, next: null),
        ];
      final registry = ExploreRegistry()..register(provider);
      final session = registry.createSession();

      final first = await registry.loadComics(ExploreRequest(
        sessionId: session,
        sourceKey: 'jm',
        entryId: 'latest',
      ));
      final page1 = first.dataOrNull!;
      expect(page1.nextToken, isNotNull);
      expect(page1.hasMore, isTrue);

      final second = await registry.loadComics(ExploreRequest(
        sessionId: session,
        sourceKey: 'jm',
        entryId: 'latest',
        continuation: page1.nextToken,
      ));
      final page2 = second.dataOrNull!;
      expect(page2.nextToken, isNull);
      expect(page2.hasMore, isFalse);
      // Registry 把 opaque 句柄解成源自己的游标再交给适配器。
      expect(provider.comicsRequests.last.continuation, 'cursor-2');
    });

    test('单页入口不发 token，显式续页请求报 invalidArgument', () async {
      final provider = _makeProvider()
        ..comicsScript = <({int count, String? next})>[
          (count: 3, next: 'ignored'),
        ];
      final registry = ExploreRegistry()..register(provider);
      final session = registry.createSession();

      final first = await registry.loadComics(ExploreRequest(
        sessionId: session,
        sourceKey: 'jm',
        entryId: 'random',
      ));
      expect(first.dataOrNull?.nextToken, isNull);
      expect(first.dataOrNull?.hasMore, isFalse);

      final forced = await registry.loadComics(ExploreRequest(
        sessionId: session,
        sourceKey: 'jm',
        entryId: 'random',
        continuation: 'anything',
      ));
      expect(forced.errorOrNull?.code, ExploreErrorCode.invalidArgument);
    });

    test('旧 token 在对不上的入口上失效，且不发网络', () async {
      final provider = _makeProvider()
        ..comicsScript = <({int count, String? next})>[
          (count: 1, next: 'cursor-2'),
        ];
      final registry = ExploreRegistry()..register(provider);
      final session = registry.createSession();

      final first = await registry.loadComics(ExploreRequest(
        sessionId: session,
        sourceKey: 'jm',
        entryId: 'latest',
      ));
      final token = first.dataOrNull!.nextToken!;
      final before = provider.comicsRequests.length;

      final mismatched = await registry.loadComics(ExploreRequest(
        sessionId: session,
        sourceKey: 'jm',
        entryId: 'ranking',
        continuation: token,
      ));
      expect(
          mismatched.errorOrNull?.code, ExploreErrorCode.expiredContinuation);
      expect(provider.comicsRequests.length, before);
    });

    test('token 结构损坏报 expiredContinuation', () async {
      final provider = _makeProvider();
      final registry = ExploreRegistry()..register(provider);
      final session = registry.createSession();
      final result = await registry.loadComics(ExploreRequest(
        sessionId: session,
        sourceKey: 'jm',
        entryId: 'latest',
        continuation: 'not-base64-json',
      ));
      expect(result.errorOrNull?.code, ExploreErrorCode.expiredContinuation);
      expect(provider.comicsRequests, isEmpty);
    });

    test('releaseSession 后旧 token 失效且不发网络', () async {
      final provider = _makeProvider()
        ..comicsScript = <({int count, String? next})>[
          (count: 1, next: 'cursor-2'),
        ];
      final registry = ExploreRegistry()..register(provider);
      final session = registry.createSession();
      final first = await registry.loadComics(ExploreRequest(
        sessionId: session,
        sourceKey: 'jm',
        entryId: 'latest',
      ));
      final token = first.dataOrNull!.nextToken!;
      registry.releaseSession(session);
      final before = provider.comicsRequests.length;

      final replayed = await registry.loadComics(ExploreRequest(
        sessionId: session,
        sourceKey: 'jm',
        entryId: 'latest',
        continuation: token,
      ));
      expect(replayed.errorOrNull?.code, ExploreErrorCode.expiredContinuation);
      expect(provider.comicsRequests.length, before);
    });

    test('releaseSession 幂等，且不影响其它消费者的会话', () async {
      final provider = _makeProvider()
        ..comicsScript = <({int count, String? next})>[
          (count: 1, next: 'cursor-2'),
          (count: 1, next: 'cursor-2'),
        ];
      final registry = ExploreRegistry()..register(provider);
      final a = registry.createSession();
      final b = registry.createSession();

      final pageA = (await registry.loadComics(ExploreRequest(
        sessionId: a,
        sourceKey: 'jm',
        entryId: 'latest',
      )))
          .dataOrNull!;
      final pageB = (await registry.loadComics(ExploreRequest(
        sessionId: b,
        sourceKey: 'jm',
        entryId: 'latest',
      )))
          .dataOrNull!;

      registry.releaseSession(a);
      registry.releaseSession(a); // 幂等
      expect(registry.isSessionAlive(a), isFalse);
      expect(registry.isSessionAlive(b), isTrue);

      // B 的 token 仍然可用。
      final continued = await registry.loadComics(ExploreRequest(
        sessionId: b,
        sourceKey: 'jm',
        entryId: 'latest',
        continuation: pageB.nextToken,
      ));
      expect(continued.isSuccess, isTrue);
      expect(pageA.nextToken, isNotNull);
    });

    test('无选项入口不接受任何选项（含空串），发之前就被拦下', () async {
      // 这条契约是"列表控制器必须原样保存 options 供续页复用"的依据：
      // 无选项入口若在续页时发送 ExploreOptions.single('')，必须被明确拒绝，
      // 而不是悄悄把空串当选项打到站点。
      final provider = _makeProvider(entries: const <ExploreEntry>[_listEntry]);
      final registry = ExploreRegistry()..register(provider);
      final session = registry.createSession();

      final ok = await registry.loadComics(ExploreRequest(
        sessionId: session,
        sourceKey: 'jm',
        entryId: 'latest',
      ));
      expect(ok.isSuccess, isTrue);
      expect(provider.comicsRequests.single.options.isEmpty, isTrue);

      final bad = await registry.loadComics(ExploreRequest(
        sessionId: session,
        sourceKey: 'jm',
        entryId: 'latest',
        options: ExploreOptions.single(''),
      ));
      expect(bad.errorOrNull?.code, ExploreErrorCode.invalidArgument);
      expect(provider.comicsRequests.length, 1);
    });

    test('有选项入口缺省时用描述符默认值，续页沿用同一选项', () async {
      final provider = _makeProvider(entries: const <ExploreEntry>[_rankEntry])
        ..comicsScript = <({int count, String? next})>[
          (count: 1, next: 'cursor-2'),
        ];
      final registry = ExploreRegistry()..register(provider);
      final session = registry.createSession();

      final first = await registry.loadComics(ExploreRequest(
        sessionId: session,
        sourceKey: 'jm',
        entryId: 'ranking',
      ));
      expect(provider.comicsRequests.last.options.first, 'today');

      await registry.loadComics(ExploreRequest(
        sessionId: session,
        sourceKey: 'jm',
        entryId: 'ranking',
        options: ExploreOptions.single('today'),
        continuation: first.dataOrNull!.nextToken,
      ));
      expect(provider.comicsRequests.last.options.first, 'today');
      expect(provider.comicsRequests.last.continuation, 'cursor-2');
    });

    test('两个消费者的续页互不干扰（各自持有自己的游标）', () async {
      final provider = _makeProvider()
        ..comicsScript = <({int count, String? next})>[
          (count: 1, next: 'first-cursor'),
          (count: 2, next: 'second-cursor'),
        ];
      final registry = ExploreRegistry()..register(provider);
      final a = registry.createSession();
      final b = registry.createSession();

      final tokenA = (await registry.loadComics(ExploreRequest(
        sessionId: a,
        sourceKey: 'jm',
        entryId: 'latest',
      )))
          .dataOrNull!
          .nextToken!;
      final tokenB = (await registry.loadComics(ExploreRequest(
        sessionId: b,
        sourceKey: 'jm',
        entryId: 'latest',
      )))
          .dataOrNull!
          .nextToken!;

      expect(tokenA, isNot(tokenB));

      // A 的 token 在 B 的会话上重放必须失败。
      final crossSession = await registry.loadComics(ExploreRequest(
        sessionId: b,
        sourceKey: 'jm',
        entryId: 'latest',
        continuation: tokenA,
      ));
      expect(
          crossSession.errorOrNull?.code, ExploreErrorCode.expiredContinuation);

      final good = await registry.loadComics(ExploreRequest(
        sessionId: a,
        sourceKey: 'jm',
        entryId: 'latest',
        continuation: tokenA,
      ));
      expect(good.isSuccess, isTrue);
      expect(provider.comicsRequests.last.continuation, 'first-cursor');
    });
  });

  group('会话策略（TTL / LRU / 句柄上限）', () {
    test('空闲超过 TTL 的会话失效', () async {
      var now = DateTime(2026, 1, 1);
      final registry = ExploreRegistry(clock: () => now);
      final session = registry.createSession();
      expect(registry.isSessionAlive(session), isTrue);

      now = now.add(const Duration(minutes: 21));
      expect(registry.isSessionAlive(session), isFalse);
    });

    test('会话数超过上限时按最久未使用者淘汰', () {
      final registry = ExploreRegistry(
        policy: const ExploreSessionPolicy(maxSessions: 3),
        clock: () => DateTime(2026, 1, 1),
      );
      final ids = <String>[
        for (var i = 0; i < 4; i++) registry.createSession(),
      ];
      expect(registry.sessionCount, 3);
      expect(registry.isSessionAlive(ids.first), isFalse);
      expect(registry.isSessionAlive(ids.last), isTrue);
    });

    test('单会话续页句柄超过上限时按最久未使用者淘汰', () async {
      final provider = _makeProvider()
        ..comicsScript = <({int count, String? next})>[
          for (var i = 0; i < 10; i++) (count: 1, next: 'cursor-$i'),
        ];
      final registry = ExploreRegistry(
        policy: const ExploreSessionPolicy(maxHandlesPerSession: 3),
        clock: () => DateTime(2026, 1, 1),
      )..register(provider);
      final session = registry.createSession();

      final tokens = <String>[];
      for (var i = 0; i < 5; i++) {
        final page = (await registry.loadComics(ExploreRequest(
          sessionId: session,
          sourceKey: 'jm',
          entryId: 'latest',
        )))
            .dataOrNull!;
        tokens.add(page.nextToken!);
      }
      expect(registry.handleCountOf(session), 3);

      // 最早的句柄已被淘汰。
      final evicted = await registry.loadComics(ExploreRequest(
        sessionId: session,
        sourceKey: 'jm',
        entryId: 'latest',
        continuation: tokens.first,
      ));
      expect(evicted.errorOrNull?.code, ExploreErrorCode.expiredContinuation);

      final kept = await registry.loadComics(ExploreRequest(
        sessionId: session,
        sourceKey: 'jm',
        entryId: 'latest',
        continuation: tokens.last,
      ));
      expect(kept.isSuccess, isTrue);
    });
  });

  group('上下文变化', () {
    test('invalidateSource 只清对应源的会话', () async {
      final jm = _makeProvider(key: 'jm')
        ..comicsScript = <({int count, String? next})>[
          (count: 1, next: 'jm-cursor'),
        ];
      final nh = _makeProvider(key: 'nhentai')
        ..comicsScript = <({int count, String? next})>[
          (count: 1, next: 'nh-cursor'),
        ];
      final registry = ExploreRegistry()
        ..register(jm)
        ..register(nh);
      final jmSession = registry.createSession();
      final nhSession = registry.createSession();

      await registry.loadComics(ExploreRequest(
        sessionId: jmSession,
        sourceKey: 'jm',
        entryId: 'latest',
      ));
      await registry.loadComics(ExploreRequest(
        sessionId: nhSession,
        sourceKey: 'nhentai',
        entryId: 'latest',
      ));

      final removed = registry.invalidateSource('jm');
      expect(removed, 1);
      expect(registry.isSessionAlive(jmSession), isFalse);
      expect(registry.isSessionAlive(nhSession), isTrue);
    });

    test('contextFingerprints 反映实时的 provider 指纹', () {
      final provider = _makeProvider();
      final registry = ExploreRegistry()..register(provider);
      expect(registry.contextFingerprints()['jm'], 'fp-1');
      provider.fingerprint = 'fp-2';
      expect(registry.contextFingerprints()['jm'], 'fp-2');
    });
  });

  group('概览', () {
    test('分区错误互相隔离，单个失败不抹掉其它成功分区', () async {
      final provider =
          _makeProvider(entries: const <ExploreEntry>[_recommendEntry])
            ..overviewSections = <ExploreSection>[
              const ExploreSection(
                id: 'ok',
                title: 'OK',
                entryId: 'home',
                items: <BaseComic>[_FakeComic('a')],
              ),
              const ExploreSection(
                id: 'bad',
                title: 'BAD',
                entryId: 'home',
                error: ExploreError(ExploreErrorCode.network, 'boom'),
              ),
            ];
      final registry = ExploreRegistry()..register(provider);
      final session = registry.createSession();

      final result = await registry.loadOverview(ExploreRequest(
        sessionId: session,
        sourceKey: 'jm',
        entryId: 'home',
      ));
      final overview = result.dataOrNull!;
      expect(overview.sections.length, 2);
      expect(overview.sections[0].error, isNull);
      expect(overview.sections[0].items, hasLength(1));
      expect(overview.sections[1].error?.code, ExploreErrorCode.network);
    });
  });
}

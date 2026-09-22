import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/explore/explore_bindings.dart';
import 'package:picakeep/foundation/explore/explore_models.dart';
import 'package:picakeep/foundation/explore/explore_provider.dart';
import 'package:picakeep/foundation/explore/explore_registry.dart';
import 'package:picakeep/network/base_comic.dart';
import 'package:picakeep/pages/explore/explore_result_page.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;

  @override
  Future<String?> getApplicationCachePath() async => '$root/cache';

  @override
  Future<String?> getApplicationSupportPath() async => '$root/support';
}

class _Comic extends BaseComic {
  const _Comic(this.id);
  @override
  final String id;
  @override
  String get title => 'Sample $id';
  @override
  String get cover => '';
  @override
  String get subTitle => '';
  @override
  String get description => '';
  @override
  List<String> get tags => const [];
}

class _Provider implements ExploreProvider {
  final requests = <ExploreRequest>[];
  bool empty = false;
  bool fail = false;
  bool failMore = false;
  bool paged = false;

  @override
  bool get isLoggedIn => true;
  @override
  String get contextFingerprint => 'sample-account';
  @override
  ExploreSourceDescriptor get descriptor => const ExploreSourceDescriptor(
        sourceKey: 'sample',
        name: 'Sample source',
        requiresLogin: false,
        entries: [
          ExploreEntry(
            id: 'latest',
            label: 'Latest',
            kind: ExploreSectionKind.recommend,
          ),
          ExploreEntry(
            id: 'ranking',
            label: 'Ranking',
            kind: ExploreSectionKind.ranking,
            options: [
              ExploreOption(id: 'day', label: 'Daily'),
              ExploreOption(id: 'month', label: 'Monthly'),
            ],
            defaultOptionId: 'day',
          ),
          ExploreEntry(
            id: 'batch',
            label: 'Batch',
            kind: ExploreSectionKind.recommend,
            singlePage: true,
          ),
        ],
      );

  @override
  Future<ExploreResult<ExploreComicPage>> loadComics(
      ExploreRequest request) async {
    requests.add(request);
    if (fail || (failMore && request.continuation != null)) {
      return const ExploreFailure(
        ExploreError(ExploreErrorCode.network, 'Sample network error'),
      );
    }
    return ExploreSuccess(ExploreComicPage(
      sourceKey: 'sample',
      entryId: request.entryId,
      items: empty ? [] : [_Comic('${requests.length}')],
      nextToken: paged ? 'page-${requests.length + 1}' : null,
    ));
  }

  @override
  Future<ExploreResult<ExploreDirectory>> loadDirectory(
          ExploreRequest request) async =>
      throw UnimplementedError();

  @override
  Future<ExploreResult<ExploreOverview>> loadOverview(
          ExploreRequest request) async =>
      throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final originalPaths = PathProviderPlatform.instance;
  late Directory temp;
  late List<ComicSource> originalSources;
  late _Provider provider;
  late ExploreRegistry registry;
  late DateTime now;

  setUpAll(() async {
    temp = await Directory.systemTemp.createTemp('picakeep_result_refresh_');
    PathProviderPlatform.instance = _Paths(temp.path);
    await App.init(dataPathOverride: '${temp.path}/data');
  });

  tearDownAll(() async {
    PathProviderPlatform.instance = originalPaths;
    await temp.delete(recursive: true);
  });

  setUp(() {
    originalSources = List.of(ComicSource.sources);
    ComicSource.sources
      ..clear()
      ..add(ComicSource.named(key: 'sample', name: 'Sample source'));
    provider = _Provider();
    now = DateTime.utc(2026, 1, 1);
    registry = ExploreRegistry(clock: () => now)..register(provider);
    ExploreBindings.debugSetInstance(ExploreBindings.forTesting(
      registry,
      fingerprints: registry.contextFingerprints(),
    ));
  });

  tearDown(() {
    ExploreBindings.debugSetInstance(null);
    ComicSource.sources
      ..clear()
      ..addAll(originalSources);
  });

  Future<void> pumpPage(WidgetTester tester,
      {String entry = 'latest', ExploreCategoryTarget? category}) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: ExploreResultPage(
        sourceKey: 'sample',
        entryId: entry,
        category: category,
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> pullToRefresh(WidgetTester tester) async {
    await tester.drag(find.byType(RefreshIndicator), const Offset(0, 360));
    await tester.pumpAndSettle();
  }

  testWidgets('无选项短列表可下拉刷新，替换内容且不发送空字符串选项', (tester) async {
    await pumpPage(tester);
    expect(find.text('Sample 1'), findsOneWidget);

    await pullToRefresh(tester);

    expect(provider.requests, hasLength(2));
    expect(provider.requests.last.options.isEmpty, isTrue);
    expect(provider.requests.last.continuation, isNull);
    expect(find.text('Sample 1'), findsNothing);
    expect(find.text('Sample 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('空结果仍可下拉刷新并恢复内容', (tester) async {
    provider.empty = true;
    await pumpPage(tester);
    expect(find.text('没有内容'), findsOneWidget);
    provider.empty = false;

    await pullToRefresh(tester);

    expect(provider.requests, hasLength(2));
    expect(find.text('Sample 2'), findsOneWidget);
  });

  testWidgets('首屏网络错误可通过下拉恢复', (tester) async {
    provider.fail = true;
    await pumpPage(tester);
    expect(find.text('Sample network error'), findsOneWidget);
    provider.fail = false;

    await pullToRefresh(tester);

    expect(provider.requests, hasLength(2));
    expect(find.text('Sample 2'), findsOneWidget);
  });

  testWidgets('切换榜期失败后的重试保留当前榜期，刷新也保留', (tester) async {
    await pumpPage(tester, entry: 'ranking');
    provider.fail = true;
    await tester.tap(find.text('Monthly'));
    await tester.pumpAndSettle();
    expect(provider.requests.last.options.first, 'month');
    provider.fail = false;

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    await pullToRefresh(tester);

    expect(provider.requests, hasLength(4));
    expect(provider.requests.skip(1).every((r) => r.options.first == 'month'),
        isTrue);
  });

  testWidgets('单页换一批保留分类/期号目标，下拉也替换整批', (tester) async {
    const category =
        ExploreCategoryTarget(kind: 'period', value: 'sample-week');
    await pumpPage(tester, entry: 'batch', category: category);

    await tester.tap(find.byTooltip('换一批'));
    await tester.pumpAndSettle();
    await pullToRefresh(tester);

    expect(provider.requests, hasLength(3));
    expect(provider.requests.every((r) => r.category == category), isTrue);
    expect(find.text('Sample 3'), findsOneWidget);
    expect(find.text('Sample 1'), findsNothing);
    expect(find.text('Sample 2'), findsNothing);
  });

  testWidgets('续页过期保留原条目，点击从头刷新获得新会话并可继续翻页', (tester) async {
    provider.paged = true;
    await pumpPage(tester, entry: 'ranking');
    final firstSession = provider.requests.single.sessionId;
    now = now.add(const Duration(minutes: 21));

    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();
    expect(find.text('Sample 1'), findsOneWidget);
    expect(find.text('从头刷新'), findsOneWidget);
    expect(provider.requests, hasLength(1));

    await tester.tap(find.text('从头刷新'));
    await tester.pumpAndSettle();
    expect(provider.requests, hasLength(2));
    expect(provider.requests.last.sessionId, isNot(firstSession));
    expect(provider.requests.last.continuation, isNull);

    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();
    expect(provider.requests, hasLength(3));
    expect(provider.requests.last.continuation, isNotNull);
    expect(find.text('Sample 2'), findsOneWidget);
    expect(find.text('Sample 3'), findsOneWidget);
  });

  testWidgets('普通续页网络错误重试原 token 且保留已加载内容', (tester) async {
    provider.paged = true;
    provider.failMore = true;
    await pumpPage(tester);
    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();
    final failed = provider.requests.last;
    expect(find.text('Sample 1'), findsOneWidget);
    expect(find.text('从头刷新'), findsNothing);
    provider.failMore = false;

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(provider.requests.last.continuation, failed.continuation);
    expect(provider.requests.last.sessionId, failed.sessionId);
    expect(find.text('Sample 1'), findsOneWidget);
    expect(find.text('Sample 3'), findsOneWidget);
  });
}

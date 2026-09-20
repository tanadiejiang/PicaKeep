import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/untranslated_tags/untranslated_tag_store.dart';
import 'package:picakeep/network/base_comic.dart';
import 'package:picakeep/network/eh_network/eh_models.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/online_search/online_search_result_page.dart';
import 'package:picakeep/tools/tags_translation.dart';
import 'package:shared_preferences/shared_preferences.dart';

// A15 走真实采集链路(页面 → Coordinator 单例 → Repository 单例 → 临时 App 路径),
// 因此本文件独立初始化 App,不与其他测试文件共享 fixture。
//
// 同步注意:页面发起的采集任务在 fake-async 区域入队,其 dart:io 完成回调只有
// pump 才能推进;而协调器队列又是串行的。所以这里不能 await 队列(会与
// runAsync 互相等待),必须交替推进 runAsync(真实 IO)与 pump(fake 微任务),
// 再对可观察结果做轮询断言。

class _Paths extends PathProviderPlatform {
  _Paths(this.root);

  final String root;

  @override
  Future<String?> getApplicationCachePath() async => '$root/cache';

  @override
  Future<String?> getApplicationSupportPath() async => '$root/support';
}

final Uint8List _transparentPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

class _FakeHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => _FakeHttpClient();
}

class _FakeHttpClient implements HttpClient {
  @override
  bool autoUncompress = true;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _FakeHttpRequest(url);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('HttpClient.${invocation.memberName}');
}

class _FakeHttpRequest implements HttpClientRequest {
  _FakeHttpRequest(this.uri);

  @override
  final Uri uri;

  @override
  final HttpHeaders headers = _FakeHttpHeaders();

  @override
  Future<HttpClientResponse> close() async => _FakeHttpResponse();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('HttpClientRequest.${invocation.memberName}');
}

class _FakeHttpHeaders implements HttpHeaders {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeHttpResponse implements HttpClientResponse {
  @override
  int get statusCode => HttpStatus.ok;

  @override
  int get contentLength => _transparentPng.length;

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.value(_transparentPng).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('HttpClientResponse.${invocation.memberName}');
}

EhGalleryBrief _ehItem(String id, List<String> tags) => EhGalleryBrief(
      'title-$id',
      'manga',
      'time',
      'uploader',
      'https://example.invalid/$id.jpg',
      0,
      'https://e-hentai.org/g/$id/abcdef1234/',
      tags,
    );

typedef _Req = ({String source, String keyword, int page, String option});

class _Handle {
  _Handle(this.key);

  final String key;
  final List<_Req> requests = <_Req>[];
  final List<Completer<Res<List<BaseComic>>>> pending =
      <Completer<Res<List<BaseComic>>>>[];

  Future<Res<List<BaseComic>>> load(
    String keyword,
    int page,
    String option,
  ) {
    requests.add((source: key, keyword: keyword, page: page, option: option));
    final completer = Completer<Res<List<BaseComic>>>();
    pending.add(completer);
    return completer.future;
  }

  void complete(int index, Res<List<BaseComic>> res) =>
      pending[index].complete(res);
}

ComicSource _buildSource({
  required String key,
  required String name,
  required _Handle handle,
  String defaultOption = 'e1',
  List<SearchOption> options = const <SearchOption>[
    SearchOption(label: 'E1', value: 'e1'),
    SearchOption(label: 'E2', value: 'e2'),
  ],
}) {
  return ComicSource.named(
    key: key,
    name: name,
    data: <String, dynamic>{'token': 'test-token'},
    searchPageData: SearchPageData(
      defaultOption: defaultOption,
      searchOptions: options,
      loadPage: (keyword, page, option) => handle.load(keyword, page, option),
    ),
    comicPageBuilder: (comic) => Scaffold(body: Text('detail-${comic.id}')),
  );
}

Future<void> _deleteQuietly(Directory directory) async {
  try {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  } catch (_) {
    // 临时目录清理失败不影响断言结果。
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory workspace;
  late List<ComicSource> originalSources;
  final PathProviderPlatform originalPaths = PathProviderPlatform.instance;
  final HttpOverrides? originalHttpOverrides = HttpOverrides.current;

  setUpAll(() async {
    workspace = await Directory.systemTemp.createTemp('picakeep_search_obs_');
    PathProviderPlatform.instance = _Paths(workspace.path);
    await App.init(dataPathOverride: '${workspace.path}/data');
    HttpOverrides.global = _FakeHttpOverrides();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 空翻译表 = 所有标签都算"未翻译",从而进入采集链路。
    setTagTranslationsForTesting(<String, Map<String, String>>{}, ready: true);
  });

  tearDownAll(() async {
    resetTagTranslationsForTesting();
    HttpOverrides.global = originalHttpOverrides;
    PathProviderPlatform.instance = originalPaths;
    await _deleteQuietly(workspace);
  });

  setUp(() {
    originalSources = List<ComicSource>.of(ComicSource.sources);
  });

  tearDown(() {
    ComicSource.sources
      ..clear()
      ..addAll(originalSources);
  });

  /// 交替推进真实 IO 与 fake 微任务,直到 [done] 成立或用尽轮次。
  /// 调用方在之后仍按可观察结果断言,所以轮次用尽只会让断言失败,不会静默通过。
  Future<void> advanceTags(
    WidgetTester tester,
    bool Function() done, {
    int maxRounds = 80,
  }) async {
    for (var round = 0; round < maxRounds; round++) {
      if (done()) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
  }

  /// 固定轮次推进:用于"本不该发生变化"的负向断言,给链路充分时间。
  Future<void> settleTagPipeline(WidgetTester tester, {int rounds = 40}) async {
    for (var round = 0; round < rounds; round++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
  }

  UntranslatedTagRecord? recordFor(String needle) {
    for (final record in UntranslatedTagRepository.instance.records) {
      if (record.source == 'ehentai' && record.rawTag.contains(needle)) {
        return record;
      }
    }
    return null;
  }

  Future<void> pumpPage(WidgetTester tester, ComicSource source) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: OnlineSearchResultPage(
          source: source,
          keyword: 'kw',
          option: '',
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> submitKeyword(WidgetTester tester, String keyword) async {
    await tester.enterText(find.byType(TextField), keyword);
    await tester.pump();
    await tester.tap(
      find
          .descendant(
            of: find.byType(TextField),
            matching: find.byIcon(Icons.search),
          )
          .last,
    );
    await tester.pump();
  }

  // 两个场景必须放在同一个 testWidgets 内:采集走的是进程级单例队列,
  // 而测试结束时 fake-async 区域内发起的挂起任务会永久占住队首(其 Zone 已销毁),
  // 拆成两个用例会让后一个用例的观察任务永远排不到。
  testWidgets('A15 采集按查询去重、跨页不重复、过期响应不入库', (tester) async {
    const tagA = 'artist:uniq-a15-crosspage';
    const tagB = 'artist:uniq-a15-fresh';
    const tagC = 'artist:uniq-a15-stale';
    final eh = _Handle('ehentai');
    final source = _buildSource(key: 'ehentai', name: 'E-Hentai', handle: eh);
    ComicSource.sources
      ..clear()
      ..add(source);

    await pumpPage(tester, source);

    // (1) 首次查询:目标漫画带独有未翻译标签
    eh.complete(
      0,
      Res<List<BaseComic>>(
        <BaseComic>[
          _ehItem('111', const <String>[tagA]),
          for (int i = 0; i < 11; i++) _ehItem('f$i', const <String>[]),
        ],
        subData: 4,
      ),
    );
    await tester.pump();
    await advanceTags(tester, () => recordFor('uniq-a15-crosspage') != null);

    final first = recordFor('uniq-a15-crosspage');
    expect(first, isNotNull);
    expect(first!.source, 'ehentai');
    expect(first.encounterCount, 1);

    // (2) 同一次查询翻到第二页,同一漫画再次出现 → 不重复计数
    await tester.drag(find.byType(ListView), const Offset(0, -3000));
    await tester.pump();
    expect(eh.requests, hasLength(2));
    expect(eh.requests.last.page, 2);
    eh.complete(
      1,
      Res<List<BaseComic>>(
        <BaseComic>[
          _ehItem('111', const <String>[tagA])
        ],
        subData: 4,
      ),
    );
    await tester.pump();
    await settleTagPipeline(tester);

    expect(
      recordFor('uniq-a15-crosspage')!.encounterCount,
      1,
      reason: '同一次查询内跨页重复出现不应重复计数',
    );

    // (3) 再翻一页并保持挂起,稍后作为过期响应
    await tester.drag(find.byType(ListView), const Offset(0, -3000));
    await tester.pump();
    expect(eh.requests, hasLength(3));
    expect(eh.requests.last.page, 3);

    // (4) 提交新关键词 = 新查询,它的标签必须入库
    await submitKeyword(tester, 'kw2');
    expect(eh.requests, hasLength(4));
    expect(eh.requests.last.keyword, 'kw2');
    eh.complete(
      3,
      Res<List<BaseComic>>(
        <BaseComic>[
          _ehItem('222', const <String>[tagB])
        ],
      ),
    );
    await tester.pump();
    await advanceTags(tester, () => recordFor('uniq-a15-fresh') != null);
    expect(recordFor('uniq-a15-fresh'), isNotNull);

    // (5) 过期响应(旧查询的第 3 页)返回:独有标签不得入库
    eh.complete(
      2,
      Res<List<BaseComic>>(
        <BaseComic>[
          _ehItem('999', const <String>[tagC])
        ],
      ),
    );
    await tester.pump();
    await settleTagPipeline(tester);

    expect(
      recordFor('uniq-a15-stale'),
      isNull,
      reason: '被丢弃的过期响应不应产生标签记录',
    );
    // 过期响应同样不得改变屏幕内容
    expect(find.text('title-999'), findsNothing);
    expect(find.text('title-222'), findsOneWidget);
  });
}

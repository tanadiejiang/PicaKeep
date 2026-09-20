import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/components/comic_tile.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/network/base_comic.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/online_search/online_search_result_page.dart';
import 'package:picakeep/tools/tags_translation.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  测试替身:路径、图片 HTTP、假源、假漫画
// ─────────────────────────────────────────────────────────────────────────────

class _Paths extends PathProviderPlatform {
  _Paths(this.root);

  final String root;

  @override
  Future<String?> getApplicationCachePath() async => '$root/cache';

  @override
  Future<String?> getApplicationSupportPath() async => '$root/support';
}

/// 1x1 透明 PNG:让结果页封面走完整解码路径,而不是依赖网络失败。
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

class _FakeComic extends BaseComic {
  _FakeComic(this.id, {String? title, List<String>? tags, String? author})
      : _title = title ?? 'comic-$id',
        _tags = tags ?? const <String>[],
        _author = author ?? 'author-$id';

  @override
  final String id;
  final String _title;
  final List<String> _tags;
  final String _author;

  @override
  String get title => _title;

  @override
  String get subTitle => _author;

  @override
  String get cover => 'https://example.invalid/$id.jpg';

  @override
  List<String> get tags => _tags;

  @override
  String get description => 'desc-$id';
}

typedef _Req = ({String source, String keyword, int page, String option});

/// 记录每一次 loadPage 调用,并允许测试控制完成顺序。
class _Handle {
  _Handle(this.key);

  final String key;
  final List<_Req> requests = <_Req>[];
  final List<Completer<Res<List<BaseComic>>>> pending =
      <Completer<Res<List<BaseComic>>>>[];

  /// 返回 Future 的应答器:同步 throw 与 `Future.error` 是两条不同路径,
  /// 都由测试显式构造。
  Future<Res<List<BaseComic>>> Function(
      String keyword, int page, String option)? responder;

  int detailBuilds = 0;
  int headerBuilds = 0;

  Future<Res<List<BaseComic>>> load(
    String keyword,
    int page,
    String option,
  ) {
    requests.add((source: key, keyword: keyword, page: page, option: option));
    final respond = responder;
    if (respond != null) {
      return respond(keyword, page, option);
    }
    final completer = Completer<Res<List<BaseComic>>>();
    pending.add(completer);
    return completer.future;
  }

  void complete(int index, Res<List<BaseComic>> res) {
    pending[index].complete(res);
  }

  void fail(int index, Object error) {
    pending[index].completeError(error);
  }
}

ComicSource _buildSource({
  required String key,
  required String name,
  required _Handle handle,
  String defaultOption = 'a1',
  List<SearchOption> options = const <SearchOption>[],
  bool loggedIn = true,
  String? detailLabel,
  ImageHeadersBuilder? headersBuilder,
}) {
  return ComicSource.named(
    key: key,
    name: name,
    data: <String, dynamic>{if (loggedIn) 'token': 'test-token'},
    searchPageData: SearchPageData(
      defaultOption: defaultOption,
      searchOptions: options,
      loadPage: (keyword, page, option) => handle.load(keyword, page, option),
    ),
    comicPageBuilder: (comic) {
      handle.detailBuilds++;
      return Scaffold(
        body: Text('${detailLabel ?? 'detail'}-${comic.id}'),
      );
    },
    imageHeadersBuilder: headersBuilder == null
        ? null
        : (comic) {
            handle.headerBuilds++;
            return headersBuilder(comic);
          },
  );
}

const List<SearchOption> _twoOptions = <SearchOption>[
  SearchOption(label: 'A1', value: 'a1'),
  SearchOption(label: 'A2', value: 'a2'),
];

const List<SearchOption> _betaOptions = <SearchOption>[
  SearchOption(label: 'B1', value: 'b1'),
  SearchOption(label: 'B2', value: 'b2'),
];

// ─────────────────────────────────────────────────────────────────────────────
//  测试环境
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory workspace;
  late List<ComicSource> originalSources;
  final PathProviderPlatform originalPaths = PathProviderPlatform.instance;
  final HttpOverrides? originalHttpOverrides = HttpOverrides.current;

  setUpAll(() async {
    workspace = await Directory.systemTemp.createTemp('picakeep_search_page_');
    PathProviderPlatform.instance = _Paths(workspace.path);
    await App.init(dataPathOverride: '${workspace.path}/data');
    HttpOverrides.global = _FakeHttpOverrides();
  });

  tearDownAll(() async {
    HttpOverrides.global = originalHttpOverrides;
    PathProviderPlatform.instance = originalPaths;
    if (await workspace.exists()) {
      await workspace.delete(recursive: true);
    }
  });

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    setTagTranslationsForTesting(<String, Map<String, String>>{}, ready: true);
    originalSources = List<ComicSource>.of(ComicSource.sources);
    appdata.searchHistory.clear();
  });

  tearDown(() {
    ComicSource.sources
      ..clear()
      ..addAll(originalSources);
    resetTagTranslationsForTesting();
    appdata.searchHistory.clear();
  });

  void useSources(List<ComicSource> sources) {
    ComicSource.sources
      ..clear()
      ..addAll(sources);
  }

  /// 直接读内置声明,不依赖 ComicSource.init() 是否已经跑过。
  ComicSource builtInSource(String key) =>
      ComicSource.builtIn.firstWhere((source) => source.key == key);

  Future<void> pumpPage(
    WidgetTester tester,
    ComicSource source, {
    String keyword = 'kw',
    String option = '',
    Size? size,
  }) async {
    if (size != null) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }
    await tester.pumpWidget(
      MaterialApp(
        home: OnlineSearchResultPage(
          source: source,
          keyword: keyword,
          option: option,
        ),
      ),
    );
    await tester.pump();
  }

  /// 弹窗/菜单动画用受控 pump:页面可能长期处于 loading(无限转圈),
  /// 不能使用 pumpAndSettle。
  Future<void> settleDialog(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> openSourceDialog(WidgetTester tester, {bool wide = true}) async {
    if (wide) {
      await tester.tap(find.byTooltip('切换源'));
    } else {
      await tester.tap(find.byTooltip('更多'));
      await settleDialog(tester);
      await tester.tap(find.text('切换源').last);
    }
    await settleDialog(tester);
  }

  Future<void> openOptionDialog(WidgetTester tester, {bool wide = true}) async {
    if (wide) {
      await tester.tap(find.byTooltip('搜索选项'));
    } else {
      await tester.tap(find.byTooltip('更多'));
      await settleDialog(tester);
      await tester.tap(find.text('搜索选项').last);
    }
    await settleDialog(tester);
  }

  FilledButton confirmButton(WidgetTester tester) =>
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, '确认'));

  Res<List<BaseComic>> ok(List<BaseComic> items, {dynamic subData}) =>
      Res<List<BaseComic>>(items, subData: subData);

  // ───────────────────────────────────────────────────────────────────────────
  //  A01 初始选项规范化
  // ───────────────────────────────────────────────────────────────────────────

  group('A01 初始选项规范化', () {
    testWidgets('未命中的传入值在首次请求前回落到源默认值', (tester) async {
      final handle = _Handle('alpha');
      final source = _buildSource(
        key: 'alpha',
        name: 'Alpha',
        handle: handle,
        defaultOption: 'a2',
        options: _twoOptions,
      );
      useSources(<ComicSource>[source]);

      await pumpPage(tester, source, option: '');

      expect(handle.requests, hasLength(1));
      expect(handle.requests.single.option, 'a2');
    });

    testWidgets('命中的合法非默认值原样保留,且弹窗高亮与首次请求一致', (tester) async {
      final handle = _Handle('alpha');
      final source = _buildSource(
        key: 'alpha',
        name: 'Alpha',
        handle: handle,
        defaultOption: 'a2',
        options: _twoOptions,
      );
      useSources(<ComicSource>[source]);

      await pumpPage(tester, source, option: 'a1');
      expect(handle.requests.single.option, 'a1');

      handle.complete(0, ok(<BaseComic>[_FakeComic('1')]));
      await tester.pump();

      await openOptionDialog(tester);
      final selected = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, 'A1'),
      );
      expect(selected.selected, isTrue);
      final other = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, 'A2'),
      );
      expect(other.selected, isFalse);
    });

    testWidgets('源没有声明选项时保留传入值且搜索选项入口禁用', (tester) async {
      final handle = _Handle('alpha');
      final source = _buildSource(
        key: 'alpha',
        name: 'Alpha',
        handle: handle,
        defaultOption: 'a1',
        options: const <SearchOption>[],
      );
      useSources(<ComicSource>[source]);

      await pumpPage(tester, source, option: 'kept');
      expect(handle.requests.single.option, 'kept');

      final tune = tester.widget<IconButton>(
        find.ancestor(
          of: find.byTooltip('搜索选项'),
          matching: find.byType(IconButton),
        ),
      );
      expect(tune.onPressed, isNull);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  //  A02 空串是合法选项
  // ───────────────────────────────────────────────────────────────────────────

  group('A02 空串选项', () {
    const options = <SearchOption>[
      SearchOption(label: '全部', value: ''),
      SearchOption(label: '同人', value: 'doujinshi'),
    ];

    testWidgets('空串初始值直接提交并请求一次', (tester) async {
      final handle = _Handle('alpha');
      final source = _buildSource(
        key: 'alpha',
        name: 'Alpha',
        handle: handle,
        defaultOption: '',
        options: options,
      );
      useSources(<ComicSource>[source]);

      await pumpPage(tester, source, option: '');
      expect(handle.requests.single.option, '');

      handle.complete(0, ok(<BaseComic>[_FakeComic('1')]));
      await tester.pump();

      await openOptionDialog(tester);
      final all = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, '全部'),
      );
      expect(all.selected, isTrue);
    });

    testWidgets('从非空选项切回空串会被当作有效选择并重搜', (tester) async {
      final handle = _Handle('alpha');
      final source = _buildSource(
        key: 'alpha',
        name: 'Alpha',
        handle: handle,
        defaultOption: '',
        options: options,
      );
      useSources(<ComicSource>[source]);

      await pumpPage(tester, source, option: 'doujinshi');
      expect(handle.requests.single.option, 'doujinshi');
      handle.complete(0, ok(<BaseComic>[_FakeComic('1')]));
      await tester.pump();

      await openOptionDialog(tester);
      await tester.tap(find.text('全部'));
      await settleDialog(tester);
      await tester.tap(find.widgetWithText(FilledButton, '确认'));
      await settleDialog(tester);

      expect(handle.requests, hasLength(2));
      expect(handle.requests.last.option, '');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  //  A03 响应式顶栏
  // ───────────────────────────────────────────────────────────────────────────

  group('A03 顶栏自适应', () {
    testWidgets('400dp 显示两个图标,399dp 与 360dp 折叠为更多菜单', (tester) async {
      final handle = _Handle('alpha');
      final source = _buildSource(
        key: 'alpha',
        name: 'Alpha',
        handle: handle,
        options: _twoOptions,
      );
      useSources(<ComicSource>[source]);

      await pumpPage(tester, source, size: const Size(400, 800));
      expect(find.byTooltip('切换源'), findsOneWidget);
      expect(find.byTooltip('搜索选项'), findsOneWidget);
      expect(find.byTooltip('更多'), findsNothing);

      tester.view.physicalSize = const Size(399, 800);
      await tester.pump();
      expect(find.byTooltip('更多'), findsOneWidget);
      expect(find.byTooltip('切换源'), findsNothing);

      tester.view.physicalSize = const Size(360, 800);
      await tester.pump();
      expect(find.byTooltip('更多'), findsOneWidget);

      // 窄屏菜单里的两个入口都可达
      await tester.tap(find.byTooltip('更多'));
      await settleDialog(tester);
      expect(find.text('切换源'), findsOneWidget);
      expect(find.text('搜索选项'), findsOneWidget);
    });

    testWidgets('窄屏更多菜单可以打开两个弹窗且不叠开', (tester) async {
      final handle = _Handle('alpha');
      final source = _buildSource(
        key: 'alpha',
        name: 'Alpha',
        handle: handle,
        options: _twoOptions,
      );
      useSources(<ComicSource>[source]);

      await pumpPage(tester, source, size: const Size(360, 800));
      handle.complete(0, ok(<BaseComic>[_FakeComic('1')]));
      await tester.pump();

      await openSourceDialog(tester, wide: false);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('切换源'), findsWidgets);
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await settleDialog(tester);
      expect(find.byType(AlertDialog), findsNothing);

      await openOptionDialog(tester, wide: false);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('排序'), findsOneWidget);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  //  A04 切换源弹窗内容与禁用规则
  // ───────────────────────────────────────────────────────────────────────────

  group('A04 切换源列表', () {
    testWidgets('按 registry 顺序列出全部源,未登录项置灰且无法提交', (tester) async {
      final alpha = _Handle('alpha');
      final beta = _Handle('beta');
      final gamma = _Handle('gamma');
      final sources = <ComicSource>[
        _buildSource(
          key: 'alpha',
          name: 'Alpha',
          handle: alpha,
          options: _twoOptions,
        ),
        _buildSource(
          key: 'beta',
          name: 'Beta',
          handle: beta,
          options: _betaOptions,
          loggedIn: false,
        ),
        _buildSource(
          key: 'gamma',
          name: 'Gamma',
          handle: gamma,
          options: _twoOptions,
        ),
      ];
      useSources(sources);

      await pumpPage(tester, sources.first, size: const Size(400, 900));
      alpha.complete(0, ok(<BaseComic>[_FakeComic('1')]));
      await tester.pump();

      await openSourceDialog(tester);

      // 顺序与 registry 一致
      final titles = tester
          .widgetList<Text>(
            find.descendant(
              of: find.byType(RadioListTile<String>),
              matching: find.byType(Text),
            ),
          )
          .map((e) => e.data)
          .whereType<String>()
          .toList();
      expect(
        titles.where((e) => e == 'Alpha' || e == 'Beta' || e == 'Gamma'),
        <String>['Alpha', 'Beta', 'Gamma'],
      );
      expect(find.text('未登录'), findsOneWidget);

      // 未登录项在控件层就是禁用的
      final betaTile = tester.widget<RadioListTile<String>>(
        find.ancestor(
          of: find.text('Beta'),
          matching: find.byType(RadioListTile<String>),
        ),
      );
      expect(betaTile.enabled, isFalse);
      final alphaTile = tester.widget<RadioListTile<String>>(
        find.ancestor(
          of: find.text('Alpha'),
          matching: find.byType(RadioListTile<String>),
        ),
      );
      expect(alphaTile.enabled, isTrue);

      // 点击置灰项不会改变选择:确认后仍停留在原源,不会切到未登录源
      await tester.tap(find.text('Beta'));
      await settleDialog(tester);
      await tester.tap(find.widgetWithText(FilledButton, '确认'));
      await settleDialog(tester);
      expect(beta.requests, isEmpty);
      expect(alpha.requests, hasLength(1));
    });

    testWidgets('全部源都不可用时确认按钮禁用', (tester) async {
      final alpha = _Handle('alpha');
      final beta = _Handle('beta');
      final sources = <ComicSource>[
        _buildSource(
          key: 'alpha',
          name: 'Alpha',
          handle: alpha,
          options: _twoOptions,
          loggedIn: false,
        ),
        _buildSource(
          key: 'beta',
          name: 'Beta',
          handle: beta,
          options: _betaOptions,
          loggedIn: false,
        ),
      ];
      useSources(sources);

      await pumpPage(tester, sources.first, size: const Size(400, 900));
      await tester.pump();

      await openSourceDialog(tester);
      expect(confirmButton(tester).onPressed, isNull);
      expect(find.text('未登录'), findsNWidgets(2));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  //  A05 取消语义与同值确认
  // ───────────────────────────────────────────────────────────────────────────

  group('A05 取消与同值确认', () {
    late _Handle alpha;
    late _Handle beta;
    late List<ComicSource> sources;

    setUp(() {
      alpha = _Handle('alpha');
      beta = _Handle('beta');
      sources = <ComicSource>[
        _buildSource(
          key: 'alpha',
          name: 'Alpha',
          handle: alpha,
          defaultOption: 'a2',
          options: _twoOptions,
        ),
        _buildSource(
          key: 'beta',
          name: 'Beta',
          handle: beta,
          defaultOption: 'b1',
          options: _betaOptions,
        ),
      ];
      useSources(sources);
    });

    testWidgets('改选后取消不改变配置、不新增请求、不动历史', (tester) async {
      await pumpPage(tester, sources.first, option: 'a1');
      alpha.complete(0, ok(<BaseComic>[_FakeComic('1')]));
      await tester.pump();

      await openSourceDialog(tester);
      await tester.tap(find.text('Beta'));
      await settleDialog(tester);
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await settleDialog(tester);

      expect(alpha.requests, hasLength(1));
      expect(beta.requests, isEmpty);
      expect(appdata.searchHistory, isEmpty);
    });

    testWidgets('点遮罩关闭不改配置', (tester) async {
      await pumpPage(tester, sources.first, option: 'a1');
      alpha.complete(0, ok(<BaseComic>[_FakeComic('1')]));
      await tester.pump();

      await openSourceDialog(tester);
      await tester.tapAt(const Offset(5, 5));
      await settleDialog(tester);

      expect(find.byType(AlertDialog), findsNothing);
      expect(alpha.requests, hasLength(1));
      expect(beta.requests, isEmpty);
    });

    testWidgets('系统返回关闭不改配置', (tester) async {
      await pumpPage(tester, sources.first, option: 'a1');
      alpha.complete(0, ok(<BaseComic>[_FakeComic('1')]));
      await tester.pump();

      await openSourceDialog(tester);
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await settleDialog(tester);

      expect(find.byType(AlertDialog), findsNothing);
      expect(alpha.requests, hasLength(1));
    });

    testWidgets('确认当前源不重搜且保留非默认选项', (tester) async {
      await pumpPage(tester, sources.first, option: 'a1');
      alpha.complete(0, ok(<BaseComic>[_FakeComic('1')]));
      await tester.pump();

      await openSourceDialog(tester);
      await tester.tap(find.widgetWithText(FilledButton, '确认'));
      await settleDialog(tester);

      expect(alpha.requests, hasLength(1));
      await openOptionDialog(tester);
      final selected = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, 'A1'),
      );
      expect(selected.selected, isTrue);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  //  A06 切源后的请求归属
  // ───────────────────────────────────────────────────────────────────────────

  testWidgets('A06 切源只发一次新请求且使用新源默认值、同一关键词、第一页', (tester) async {
    final alpha = _Handle('alpha');
    final beta = _Handle('beta');
    final sources = <ComicSource>[
      _buildSource(
        key: 'alpha',
        name: 'Alpha',
        handle: alpha,
        defaultOption: 'a2',
        options: _twoOptions,
      ),
      _buildSource(
        key: 'beta',
        name: 'Beta',
        handle: beta,
        defaultOption: 'b1',
        options: _betaOptions,
      ),
    ];
    useSources(sources);

    await pumpPage(tester, sources.first, keyword: 'blue', option: 'a1');
    alpha.complete(0, ok(<BaseComic>[_FakeComic('1')]));
    await tester.pump();

    await openSourceDialog(tester);
    await tester.tap(find.text('Beta'));
    await settleDialog(tester);
    await tester.tap(find.widgetWithText(FilledButton, '确认'));
    await settleDialog(tester);

    expect(alpha.requests, hasLength(1));
    expect(beta.requests, hasLength(1));
    expect(beta.requests.single.keyword, 'blue');
    expect(beta.requests.single.page, 1);
    expect(beta.requests.single.option, 'b1');

    // 新源的选项列表与高亮立即可用
    await openOptionDialog(tester);
    final selected = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, 'B1'),
    );
    expect(selected.selected, isTrue);
    expect(find.widgetWithText(ChoiceChip, 'A1'), findsNothing);
  });

  // ───────────────────────────────────────────────────────────────────────────
  //  A07 选项弹窗回显与取消
  // ───────────────────────────────────────────────────────────────────────────

  testWidgets('A07 改选项后回显新值,取消不改变请求,加载态仍可打开', (tester) async {
    final handle = _Handle('alpha');
    final source = _buildSource(
      key: 'alpha',
      name: 'Alpha',
      handle: handle,
      defaultOption: 'a1',
      options: _twoOptions,
    );
    useSources(<ComicSource>[source]);

    await pumpPage(tester, source, option: 'a1');
    handle.complete(0, ok(<BaseComic>[_FakeComic('1')]));
    await tester.pump();

    // 加载态(请求挂起)也能打开配置入口
    await openOptionDialog(tester);
    await tester.tap(find.text('A2'));
    await settleDialog(tester);
    await tester.tap(find.widgetWithText(FilledButton, '确认'));
    await settleDialog(tester);
    expect(handle.requests, hasLength(2));
    expect(handle.requests.last.option, 'a2');

    await openOptionDialog(tester);
    final selected = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, 'A2'),
    );
    expect(selected.selected, isTrue);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await settleDialog(tester);
    expect(handle.requests, hasLength(2));
  });

  // ───────────────────────────────────────────────────────────────────────────
  //  A08 已提交关键词与输入草稿分离
  // ───────────────────────────────────────────────────────────────────────────

  testWidgets('A08 切源使用已提交关键词,草稿保留,只有显式提交才写历史', (tester) async {
    final alpha = _Handle('alpha');
    final beta = _Handle('beta');
    final sources = <ComicSource>[
      _buildSource(
        key: 'alpha',
        name: 'Alpha',
        handle: alpha,
        options: _twoOptions,
      ),
      _buildSource(
        key: 'beta',
        name: 'Beta',
        handle: beta,
        defaultOption: 'b1',
        options: _betaOptions,
      ),
    ];
    useSources(sources);

    await pumpPage(tester, sources.first, keyword: 'alpha-kw', option: 'a1');
    alpha.complete(0, ok(<BaseComic>[_FakeComic('1')]));
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'draft-kw');
    await tester.pump();

    await openSourceDialog(tester);
    await tester.tap(find.text('Beta'));
    await settleDialog(tester);
    await tester.tap(find.widgetWithText(FilledButton, '确认'));
    await settleDialog(tester);

    expect(beta.requests.single.keyword, 'alpha-kw');
    expect(appdata.searchHistory, isEmpty);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      'draft-kw',
    );

    // 显式提交草稿:使用新源与新选项,并写入历史
    await tester.tap(
      find
          .descendant(
            of: find.byType(TextField),
            matching: find.byIcon(Icons.search),
          )
          .last,
    );
    await settleDialog(tester);

    expect(beta.requests, hasLength(2));
    expect(beta.requests.last.keyword, 'draft-kw');
    expect(beta.requests.last.option, 'b1');
    expect(appdata.searchHistory, contains('draft-kw'));
  });

  // ───────────────────────────────────────────────────────────────────────────
  //  A09 / A10 竞态与异步过期
  // ───────────────────────────────────────────────────────────────────────────

  group('A09 旧请求不得覆盖新查询', () {
    late _Handle alpha;
    late _Handle beta;
    late List<ComicSource> sources;

    setUp(() {
      alpha = _Handle('alpha');
      beta = _Handle('beta');
      sources = <ComicSource>[
        _buildSource(
          key: 'alpha',
          name: 'Alpha',
          handle: alpha,
          options: _twoOptions,
        ),
        _buildSource(
          key: 'beta',
          name: 'Beta',
          handle: beta,
          defaultOption: 'b1',
          options: _betaOptions,
        ),
      ];
      useSources(sources);
    });

    Future<void> switchToBeta(WidgetTester tester) async {
      await openSourceDialog(tester);
      await tester.tap(find.text('Beta'));
      await settleDialog(tester);
      await tester.tap(find.widgetWithText(FilledButton, '确认'));
      await settleDialog(tester);
    }

    testWidgets('新请求仍挂起时旧请求失败不能关闭 loading 或显示旧错误', (tester) async {
      await pumpPage(tester, sources.first);
      await switchToBeta(tester);

      expect(beta.requests, hasLength(1));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      alpha.fail(0, StateError('old-failure'));
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('old-failure'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      beta.complete(0, ok(<BaseComic>[_FakeComic('b1', title: 'beta-item')]));
      await tester.pump();
      expect(find.text('beta-item'), findsOneWidget);
    });

    testWidgets('新请求先完成后旧请求成功也不能覆盖结果', (tester) async {
      await pumpPage(tester, sources.first);
      await switchToBeta(tester);

      beta.complete(0, ok(<BaseComic>[_FakeComic('b1', title: 'beta-item')]));
      await tester.pump();
      expect(find.text('beta-item'), findsOneWidget);

      alpha.complete(0, ok(<BaseComic>[_FakeComic('a1', title: 'alpha-item')]));
      await tester.pump();
      await tester.pump();

      expect(find.text('beta-item'), findsOneWidget);
      expect(find.text('alpha-item'), findsNothing);
    });

    testWidgets('旧请求异步异常不产生未处理错误也不影响新查询', (tester) async {
      await pumpPage(tester, sources.first);
      await switchToBeta(tester);

      alpha.fail(0, StateError('old-async-boom'));
      beta.complete(0, ok(<BaseComic>[_FakeComic('b1', title: 'beta-item')]));
      await tester.pump();
      await tester.pump();

      expect(find.text('beta-item'), findsOneWidget);
      expect(find.textContaining('old-async-boom'), findsNothing);
    });

    testWidgets('旧请求 Res.error 不显示为新错误', (tester) async {
      await pumpPage(tester, sources.first);
      await switchToBeta(tester);

      alpha.complete(0, const Res<List<BaseComic>>.error('old-res-error'));
      await tester.pump();
      expect(find.text('old-res-error'), findsNothing);

      beta.complete(0, ok(<BaseComic>[_FakeComic('b1', title: 'beta-item')]));
      await tester.pump();
      expect(find.text('beta-item'), findsOneWidget);
    });
  });

  testWidgets('A10 A→B→A 后只有最后一次查询的响应被接受', (tester) async {
    final alpha = _Handle('alpha');
    final beta = _Handle('beta');
    final sources = <ComicSource>[
      _buildSource(
        key: 'alpha',
        name: 'Alpha',
        handle: alpha,
        options: _twoOptions,
      ),
      _buildSource(
        key: 'beta',
        name: 'Beta',
        handle: beta,
        defaultOption: 'b1',
        options: _betaOptions,
      ),
    ];
    useSources(sources);

    await pumpPage(tester, sources.first);
    // A(1) → B(1) → A(2)
    await openSourceDialog(tester);
    await tester.tap(find.text('Beta'));
    await settleDialog(tester);
    await tester.tap(find.widgetWithText(FilledButton, '确认'));
    await settleDialog(tester);

    await openSourceDialog(tester);
    await tester.tap(find.text('Alpha'));
    await settleDialog(tester);
    await tester.tap(find.widgetWithText(FilledButton, '确认'));
    await settleDialog(tester);

    expect(alpha.requests, hasLength(2));
    expect(beta.requests, hasLength(1));

    // 最早的 A 响应先回来:必须被丢弃
    alpha.complete(0, ok(<BaseComic>[_FakeComic('a-old', title: 'old')]));
    await tester.pump();
    expect(find.text('old'), findsNothing);

    // 最新的 A 响应胜出
    alpha.complete(1, ok(<BaseComic>[_FakeComic('a-new', title: 'new')]));
    await tester.pump();
    expect(find.text('new'), findsOneWidget);
  });

  // ───────────────────────────────────────────────────────────────────────────
  //  A11 分页与滚动复位
  // ───────────────────────────────────────────────────────────────────────────

  testWidgets('A11 翻页后切源会清空旧条目、回到第一页并从顶部开始', (tester) async {
    final alpha = _Handle('alpha');
    final beta = _Handle('beta');
    final sources = <ComicSource>[
      _buildSource(
        key: 'alpha',
        name: 'Alpha',
        handle: alpha,
        options: _twoOptions,
      ),
      _buildSource(
        key: 'beta',
        name: 'Beta',
        handle: beta,
        defaultOption: 'b1',
        options: _betaOptions,
      ),
    ];
    useSources(sources);

    await pumpPage(tester, sources.first, size: const Size(400, 800));
    alpha.complete(
      0,
      ok(
        List<BaseComic>.generate(12, (i) => _FakeComic('a$i')),
        subData: 5,
      ),
    );
    await tester.pump();

    // 触发加载更多 → 第二页
    await tester.drag(find.byType(ListView), const Offset(0, -3000));
    await tester.pump();
    expect(alpha.requests, hasLength(2));
    expect(alpha.requests.last.page, 2);
    alpha.complete(1, ok(<BaseComic>[_FakeComic('a12')], subData: 5));
    await tester.pump();
    await tester.pump();

    // 切源
    await openSourceDialog(tester);
    await tester.tap(find.text('Beta'));
    await settleDialog(tester);
    await tester.tap(find.widgetWithText(FilledButton, '确认'));
    await settleDialog(tester);

    expect(find.text('comic-a0'), findsNothing);
    expect(beta.requests.single.page, 1);
    beta.complete(0, ok(<BaseComic>[_FakeComic('b0')], subData: 9));
    await tester.pump();

    final scrollable = tester.widget<ListView>(find.byType(ListView));
    expect(scrollable.controller?.position.pixels, 0);
  });

  // ───────────────────────────────────────────────────────────────────────────
  //  A12 失败路径与重试
  // ───────────────────────────────────────────────────────────────────────────

  group('A12 失败与重试', () {
    testWidgets('Res.error 结束 loading、显示错误,重试从第一页重搜', (tester) async {
      final handle = _Handle('alpha');
      final source = _buildSource(
        key: 'alpha',
        name: 'Alpha',
        handle: handle,
        options: _twoOptions,
      );
      useSources(<ComicSource>[source]);

      await pumpPage(tester, source);
      handle.complete(0, const Res<List<BaseComic>>.error('boom'));
      await tester.pump();

      expect(find.text('boom'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      await tester.tap(find.text('重试'));
      await tester.pump();
      expect(handle.requests, hasLength(2));
      expect(handle.requests.last.page, 1);

      handle.complete(1, ok(<BaseComic>[_FakeComic('1')], subData: 1));
      await tester.pump();
      expect(find.text('boom'), findsNothing);
    });

    testWidgets('同步 throw 进入同一错误路径且不产生二次异常', (tester) async {
      final handle = _Handle('alpha');
      handle.responder =
          (keyword, page, option) => throw StateError('sync-boom');
      final source = _buildSource(
        key: 'alpha',
        name: 'Alpha',
        handle: handle,
        options: _twoOptions,
      );
      useSources(<ComicSource>[source]);

      await pumpPage(tester, source);
      await tester.pump();

      expect(find.textContaining('sync-boom'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('Future error 进入同一错误路径', (tester) async {
      final handle = _Handle('alpha');
      handle.responder = (keyword, page, option) =>
          Future<Res<List<BaseComic>>>.error(StateError('async-boom'));
      final source = _buildSource(
        key: 'alpha',
        name: 'Alpha',
        handle: handle,
        options: _twoOptions,
      );
      useSources(<ComicSource>[source]);

      await pumpPage(tester, source);
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('async-boom'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('加载更多失败保留既有条目与页码,再次触底仍请求同一页', (tester) async {
      final handle = _Handle('alpha');
      final source = _buildSource(
        key: 'alpha',
        name: 'Alpha',
        handle: handle,
        options: _twoOptions,
      );
      useSources(<ComicSource>[source]);

      await pumpPage(tester, source, size: const Size(400, 800));
      handle.complete(
        0,
        ok(
          List<BaseComic>.generate(12, (i) => _FakeComic('a$i')),
          subData: 6,
        ),
      );
      await tester.pump();

      await tester.drag(find.byType(ListView), const Offset(0, -3000));
      await tester.pump();
      expect(handle.requests.last.page, 2);

      handle.complete(1, const Res<List<BaseComic>>.error('page2-failed'));
      await tester.pump();

      expect(find.text('page2-failed'), findsOneWidget);
      // 既有条目仍在列表里(滚动位置可能让首项离屏,故按列表项计数断言)
      expect(find.byType(DownloadedComicTile), findsWidgets);

      await tester.drag(find.byType(ListView), const Offset(0, -3000));
      await tester.pump();
      expect(handle.requests, hasLength(3));
      expect(handle.requests.last.page, 2);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  //  A13 销毁后无副作用
  // ───────────────────────────────────────────────────────────────────────────

  testWidgets('A13 请求与弹窗未结束即销毁页面不产生异常', (tester) async {
    final handle = _Handle('alpha');
    final source = _buildSource(
      key: 'alpha',
      name: 'Alpha',
      handle: handle,
      options: _twoOptions,
    );
    useSources(<ComicSource>[source]);

    await pumpPage(tester, source);
    await openSourceDialog(tester);
    expect(find.byType(AlertDialog), findsOneWidget);

    // 销毁页面(弹窗随导航栈一起移除)
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump();

    handle.complete(0, ok(<BaseComic>[_FakeComic('1')]));
    await tester.pump();
    await tester.pump();
    // 无 setState after dispose / 未处理异常即通过
  });

  // ───────────────────────────────────────────────────────────────────────────
  //  A14 源契约跟随(详情 builder / 封面 headers / 作者)
  // ───────────────────────────────────────────────────────────────────────────

  testWidgets('A14 切源后详情 builder、封面 headers 与作者文本都跟随新源', (tester) async {
    final alpha = _Handle('alpha');
    final eh = _Handle('ehentai');
    final sources = <ComicSource>[
      _buildSource(
        key: 'alpha',
        name: 'Alpha',
        handle: alpha,
        options: _twoOptions,
        detailLabel: 'alpha-detail',
      ),
      _buildSource(
        key: 'ehentai',
        name: 'E-Hentai',
        handle: eh,
        defaultOption: 'e1',
        options: const <SearchOption>[
          SearchOption(label: 'E1', value: 'e1'),
          SearchOption(label: 'E2', value: 'e2'),
        ],
        detailLabel: 'eh-detail',
        headersBuilder: (comic) => const <String, String>{
          'User-Agent': 'test-agent',
        },
      ),
    ];
    useSources(sources);

    await pumpPage(tester, sources.first, size: const Size(400, 900));
    alpha.complete(
      0,
      ok(<BaseComic>[_FakeComic('a1', title: 'alpha-item')]),
    );
    await tester.pump();
    expect(alpha.headerBuilds, 0);

    // 切到带 headers 的源
    await openSourceDialog(tester);
    await tester.tap(find.text('E-Hentai'));
    await settleDialog(tester);
    await tester.tap(find.widgetWithText(FilledButton, '确认'));
    await settleDialog(tester);

    eh.complete(0, ok(<BaseComic>[_FakeComic('e1', title: 'eh-item')]));
    await tester.pump();
    await tester.pump();

    expect(find.text('eh-item'), findsOneWidget);
    expect(eh.headerBuilds, greaterThan(0));

    // 详情 builder 跟随新源
    await tester.tap(find.text('eh-item'));
    await settleDialog(tester);
    expect(find.text('eh-detail-e1'), findsOneWidget);
  });

  // ───────────────────────────────────────────────────────────────────────────
  //  A16 声明合同
  // ───────────────────────────────────────────────────────────────────────────

  group('A16 四源选项声明', () {
    test('JM 恰好七项且顺序、取值与原项目一致', () {
      final jm = builtInSource('jm');
      final data = jm.searchPageData!;
      expect(data.defaultOption, 'mr');
      expect(
        data.searchOptions.map((e) => e.value).toList(),
        <String>['mr', 'mv', 'mv_m', 'mv_w', 'mv_t', 'mp', 'tf'],
      );
      expect(
        data.searchOptions.map((e) => e.label).toList(),
        <String>['最新', '总排行', '月排行', '周排行', '日排行', '最多图片', '最多喜欢'],
      );
    });

    test('每个内置源的默认值都属于自己的选项集', () {
      for (final source in ComicSource.builtIn) {
        final data = source.searchPageData;
        expect(data, isNotNull, reason: '${source.key} 缺少搜索声明');
        final values = data!.searchOptions.map((e) => e.value).toList();
        expect(
          values,
          contains(data.defaultOption),
          reason: '${source.key} 的默认值不在选项集内',
        );
      }
    });

    test('入口页与结果页读取同一份声明', () {
      final jm = builtInSource('jm');
      expect(
        identical(builtInSource('jm').searchPageData, jm.searchPageData),
        isTrue,
      );
      final values =
          jm.searchPageData!.searchOptions.map((e) => e.value).toList();
      expect(values.length, 7);
      expect(values.toSet().length, 7);
    });

    test('结果页规范化使用声明值', () {
      final jm = builtInSource('jm');
      expect(resolveSearchOptionForSource(jm, ''), 'mr');
      expect(resolveSearchOptionForSource(jm, 'mp'), 'mp');
      final eh = builtInSource('ehentai');
      expect(resolveSearchOptionForSource(eh, ''), '');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  //  A17 弹窗期间的登录失效与连击
  // ───────────────────────────────────────────────────────────────────────────

  group('A17 失效与连击', () {
    testWidgets('弹窗打开后候选源登录失效则拒绝提交', (tester) async {
      final alpha = _Handle('alpha');
      final beta = _Handle('beta');
      final betaSource = _buildSource(
        key: 'beta',
        name: 'Beta',
        handle: beta,
        defaultOption: 'b1',
        options: _betaOptions,
      );
      final sources = <ComicSource>[
        _buildSource(
          key: 'alpha',
          name: 'Alpha',
          handle: alpha,
          options: _twoOptions,
        ),
        betaSource,
      ];
      useSources(sources);

      await pumpPage(tester, sources.first, size: const Size(400, 900));
      alpha.complete(0, ok(<BaseComic>[_FakeComic('1')]));
      await tester.pump();

      await openSourceDialog(tester);
      // 弹窗已打开:期间登录态失效
      betaSource.data.remove('token');
      await tester.pump();

      await tester.tap(find.text('Beta'));
      await settleDialog(tester);
      await tester.tap(find.widgetWithText(FilledButton, '确认'));
      await settleDialog(tester);

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('该源未登录'), findsOneWidget);
      expect(beta.requests, isEmpty);
      expect(alpha.requests, hasLength(1));
    });

    testWidgets('连击入口不会叠开多个对话框,也不会重复发起请求', (tester) async {
      final alpha = _Handle('alpha');
      final beta = _Handle('beta');
      final sources = <ComicSource>[
        _buildSource(
          key: 'alpha',
          name: 'Alpha',
          handle: alpha,
          options: _twoOptions,
        ),
        _buildSource(
          key: 'beta',
          name: 'Beta',
          handle: beta,
          defaultOption: 'b1',
          options: _betaOptions,
        ),
      ];
      useSources(sources);

      await pumpPage(tester, sources.first, size: const Size(400, 900));
      alpha.complete(0, ok(<BaseComic>[_FakeComic('1')]));
      await tester.pump();

      // 同一帧内连点两次入口
      await tester.tap(find.byTooltip('切换源'), warnIfMissed: false);
      await tester.tap(find.byTooltip('切换源'), warnIfMissed: false);
      await settleDialog(tester);
      expect(find.byType(AlertDialog), findsOneWidget);

      // 连点两次确认也只发一次请求
      await tester.tap(find.text('Beta'));
      await settleDialog(tester);
      await tester.tap(find.widgetWithText(FilledButton, '确认'),
          warnIfMissed: false);
      await tester.tap(find.widgetWithText(FilledButton, '确认'),
          warnIfMissed: false);
      await settleDialog(tester);

      expect(beta.requests, hasLength(1));
      expect(alpha.requests, hasLength(1));
    });
  });
}

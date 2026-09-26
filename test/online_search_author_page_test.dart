/// 第十八轮 34 号：在线搜索页 ID 直跳区的「打开作者页」入口（仅 Pixiv，App 内打开）。
///
/// 覆盖：
/// 1. `pixiv` 声明了作者页钩子，且钩子把**清洗后的 uid** 交给 App 内页面；
/// 2. 未声明钩子的源不产生该 chip（其它 3 个源的回归保护）；
/// 3. 输入命中 `idMatcher` 时，Pixiv 那组同时出现「打开漫画」与「打开作者页」，
///    且两者图标不同（`open_in_new` vs `person_outline`）。
///
/// 不起真正的作者页（那一步会构造 `PixivNetwork`，需要 sqlite/网络），
/// 因此这里断言的是"钩子返回了正确的页面对象"，点击后的导航与
/// 「打开漫画」chip 走同一条 `Navigator.push(AppPageRoute(...))`。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/network/base_comic.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/online_comic/pixiv_author_page_v2.dart';
import 'package:picakeep/pages/online_search/online_search_page.dart';
import 'package:picakeep/tools/tags_translation.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  测试替身
// ─────────────────────────────────────────────────────────────────────────────

class _Paths extends PathProviderPlatform {
  _Paths(this.root);

  final String root;

  @override
  Future<String?> getApplicationCachePath() async => '$root/cache';

  @override
  Future<String?> getApplicationSupportPath() async => '$root/support';
}

/// ID 直跳区传给钩子的就是这种只带 id 的轻量 BaseComic。
class _IdComic extends BaseComic {
  const _IdComic(this.id);

  @override
  final String id;
  @override
  String get title => '';
  @override
  String get subTitle => '';
  @override
  String get cover => '';
  @override
  List<String> get tags => const <String>[];
  @override
  String get description => '';
}

/// 声明了 idMatcher / comicPageBuilder，但**没有**作者页钩子的假源。
ComicSource _plainSource() => ComicSource.named(
      key: 'plain',
      name: 'Plain',
      data: <String, dynamic>{'token': 'test-token'},
      searchPageData: SearchPageData(
        loadPage: (keyword, page, option) async =>
            const Res<List<BaseComic>>(<BaseComic>[]),
      ),
      comicPageBuilder: (comic) => Scaffold(body: Text('detail-${comic.id}')),
      idMatcher: RegExp(r'^\d+$'),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory workspace;
  late List<ComicSource> originalSources;
  final PathProviderPlatform originalPaths = PathProviderPlatform.instance;

  setUpAll(() async {
    workspace = await Directory.systemTemp.createTemp('picakeep_author_page_');
    PathProviderPlatform.instance = _Paths(workspace.path);
    await App.init(dataPathOverride: '${workspace.path}/data');
  });

  tearDownAll(() async {
    PathProviderPlatform.instance = originalPaths;
    if (await workspace.exists()) {
      await workspace.delete(recursive: true);
    }
  });

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // tags 翻译表直接注入"已就绪"，避免页面 initState 去读 assets。
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

  /// 直接读内置声明，不依赖 `ComicSource.init()` 是否已经跑过。
  ComicSource builtInSource(String key) =>
      ComicSource.builtIn.firstWhere((source) => source.key == key);

  /// 内置源是全局单例：临时注入 token（页面只在有已登录源时才渲染 ID 直跳区），
  /// 用例结束后恢复原值，避免污染同进程内的其它用例。
  void markLoggedIn(ComicSource source) {
    final original = source.data['token'];
    source.data['token'] = 'test-token';
    addTearDown(() {
      if (original == null) {
        source.data.remove('token');
      } else {
        source.data['token'] = original;
      }
    });
  }

  Future<void> pumpSearchPage(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: OnlineSearchPage()));
    // 让 initState 里的 tags 懒加载 future 落地。
    await tester.pump();
  }

  Future<void> enterId(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField).first, text);
    await tester.pump();
  }

  /// 取出钩子构造出的作者页（不 pump，避免真去联网）。
  PixivAuthorPageV2 buildAuthorPage(String rawId) {
    final page = builtInSource('pixiv').authorPageBuilder!(_IdComic(rawId));
    expect(page, isA<PixivAuthorPageV2>());
    return page as PixivAuthorPageV2;
  }

  // ───────────────────────────────────────────────────────────────────────────
  //  A01 钩子契约
  // ───────────────────────────────────────────────────────────────────────────

  group('A01 作者页钩子', () {
    test('Pixiv：钩子把 uid 交给 App 内页面（不是走外部浏览器）', () {
      expect(
        builtInSource('pixiv').authorPageBuilder,
        isNotNull,
        reason: 'pixiv 必须声明作者页钩子',
      );
      expect(buildAuthorPage('41678351').uid, '41678351');
    });

    test('Pixiv：带前缀的输入被清洗成纯 uid（复用既有清洗，不重复实现）', () {
      // 大小写不敏感：下载 id 形态出现过 `Pixiv123` 的写法。
      expect(buildAuthorPage('pixiv41678351').uid, '41678351');
      expect(buildAuthorPage('Pixiv41678351').uid, '41678351');
    });

    test('Pixiv：非数字输入不编造 uid（交给页面报"uid 无效"）', () {
      expect(buildAuthorPage('witch').uid, isEmpty);
    });

    test('只有 pixiv 声明作者页钩子（其它内置源保持 null）', () {
      final declaring = <String>[
        for (final source in ComicSource.builtIn)
          if (source.authorPageBuilder != null) source.key,
      ];
      expect(declaring, <String>['pixiv']);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  //  A02 搜索页并排渲染
  // ───────────────────────────────────────────────────────────────────────────

  group('A02 搜索页并排入口', () {
    testWidgets('Pixiv 命中 idMatcher 时「打开漫画」与「打开作者页」并排出现', (tester) async {
      final pixiv = builtInSource('pixiv');
      markLoggedIn(pixiv);
      useSources(<ComicSource>[pixiv]);

      await pumpSearchPage(tester);
      await enterId(tester, '41678351');

      expect(find.text('打开漫画: Pixiv  41678351'), findsOneWidget);
      expect(find.text('打开作者页: Pixiv  41678351'), findsOneWidget);
      // 图标区分：作品用 open_in_new，作者主页用 person_outline。
      expect(find.byIcon(Icons.open_in_new), findsOneWidget);
      expect(find.byIcon(Icons.person_outline), findsOneWidget);
    });

    testWidgets('带前缀输入时两个入口都显示清洗后的纯数字', (tester) async {
      final pixiv = builtInSource('pixiv');
      markLoggedIn(pixiv);
      useSources(<ComicSource>[pixiv]);

      await pumpSearchPage(tester);
      await enterId(tester, 'pixiv41678351');

      expect(find.text('打开漫画: Pixiv  41678351'), findsOneWidget);
      expect(find.text('打开作者页: Pixiv  41678351'), findsOneWidget);
    });

    testWidgets('输入不匹配 idMatcher 时两个入口都不出现', (tester) async {
      final pixiv = builtInSource('pixiv');
      markLoggedIn(pixiv);
      useSources(<ComicSource>[pixiv]);

      await pumpSearchPage(tester);
      await enterId(tester, 'witch');

      expect(find.textContaining('打开漫画'), findsNothing);
      expect(find.textContaining('打开作者页'), findsNothing);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  //  A03 其它源的回归保护
  // ───────────────────────────────────────────────────────────────────────────

  group('A03 其它源不产生该 chip', () {
    testWidgets('裸数字仍只给出三个「打开漫画」chip，没有「打开作者页」', (tester) async {
      final sources = <ComicSource>[
        builtInSource('jm'),
        builtInSource('nhentai'),
        builtInSource('komiic'),
      ];
      for (final source in sources) {
        markLoggedIn(source);
      }
      useSources(sources);

      await pumpSearchPage(tester);
      await enterId(tester, '123456');

      expect(find.textContaining('打开漫画'), findsNWidgets(3));
      expect(find.text('打开漫画: 禁漫  123456'), findsOneWidget);
      expect(find.text('打开漫画: Nhentai  123456'), findsOneWidget);
      expect(find.text('打开漫画: Komiic  123456'), findsOneWidget);
      expect(find.textContaining('打开作者页'), findsNothing);
      expect(find.byIcon(Icons.person_outline), findsNothing);
    });

    testWidgets('声明了 idMatcher 但没声明钩子的源不产生该 chip', (tester) async {
      useSources(<ComicSource>[_plainSource()]);

      await pumpSearchPage(tester);
      await enterId(tester, '41678351');

      expect(find.text('打开漫画: Plain  41678351'), findsOneWidget);
      expect(find.textContaining('打开作者页'), findsNothing);
    });
  });
}

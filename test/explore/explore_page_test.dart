/// 探索首页（[ExplorePage]）的 widget 测试。
///
/// 覆盖两种模式：
///
/// **A. 注入 fake registry**（`ExploreBindings.forTesting` + `debugSetInstance`）
/// —— 页面级行为：四源可达（源是 `TabBar` 的页签，与「卡片信息显示」页同款）、
/// 三页签可达（推荐/榜单/分类，仍是 `ChoiceChip`）、榜单选项条出现、
/// 分类入口列表出现、未登录源不发**任何**请求且显示登录说明与账号管理入口、
/// 概览分区错误隔离、切榜期换 option（请求 +1 且带新 id）、
/// 以及满屏源页签 + 页签下窄屏大字号不溢出。四个源全部是 fake provider，
/// 不构造任何真实网络单例（因此不触发 sqlite3）。
///
/// **B. ExploreBindings 未初始化时的降级 UI** —— `ExploreBindings.instance == null`
/// 时显示 '探索能力尚未初始化'、不崩、不渲染源条/页签；保留它是因为这是真实的
/// 启动早期状态（`install()` 尚未执行）。
///
/// 注意：页面级覆盖**不能**用 `ExploreBindings.install()` —— 它会构造 `EhNetwork()`
/// → `CookieJarSql` → `sqlite3.open`，而 `flutter test` 下加载 `sqlite3.dll` 失败
/// （实测：`Invalid argument(s): Failed to load dynamic library 'sqlite3.dll'`），
/// 因此走 `forTesting` 接缝注入纯 fake 注册表。
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/components/components.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/app_page_route.dart';
import 'package:picakeep/foundation/explore/explore_bindings.dart';
import 'package:picakeep/foundation/explore/explore_models.dart';
import 'package:picakeep/foundation/explore/explore_provider.dart';
import 'package:picakeep/foundation/explore/explore_registry.dart';
import 'package:picakeep/network/base_comic.dart';
import 'package:picakeep/pages/explore/explore_page.dart';
import 'package:picakeep/pages/explore/explore_keep_alive_switcher.dart';
import 'package:picakeep/pages/explore/explore_route_scope.dart';
import 'package:picakeep/pages/online_common/online_comic_list_item.dart';

/// 让 `App.init()` 在测试里拿到临时目录（与仓库内其它 widget 测试同款接缝）。
class _Paths extends PathProviderPlatform {
  _Paths(this.root);

  final String root;

  @override
  Future<String?> getApplicationCachePath() async => '$root/cache';

  @override
  Future<String?> getApplicationSupportPath() async => '$root/support';
}

// ─────────────────────────────────────────────────────────────────────────────
//  页面级测试替身：全部 fake，不触碰任何真实网络单例
// ─────────────────────────────────────────────────────────────────────────────

class _FakeComic extends BaseComic {
  const _FakeComic(this.id, this.title);

  @override
  final String id;
  @override
  final String title;
  @override
  String get subTitle => '';
  // 空封面：卡片只会走 `errorBuilder` 占位，不产生真实图片请求。
  @override
  String get cover => '';
  @override
  List<String> get tags => const <String>[];
  @override
  String get description => '';
}

class _BuildProbeComic extends _FakeComic {
  _BuildProbeComic(super.id, super.title);

  int titleReads = 0;
  @override
  String get title {
    titleReads++;
    return super.title;
  }
}

/// 四个源各一个实例；分别统计三类请求，用来断言"未登录源一次都没请求"。
class _PageFakeProvider implements ExploreProvider {
  _PageFakeProvider({
    required this.descriptor,
    required this.loggedIn,
    required this.overviewSections,
  });

  @override
  ExploreSourceDescriptor descriptor;

  bool loggedIn;
  String accountVersion = 'account-1';

  /// 概览返回的分区（可含带 `error` 的分区）。
  List<ExploreSection> overviewSections;
  List<BaseComic>? comics;
  bool overviewUnsupported = false;
  Completer<ExploreResult<ExploreOverview>>? pendingOverview;
  List<ExploreCategoryGroup>? directoryGroups;

  final List<ExploreRequest> comicsRequests = <ExploreRequest>[];
  final List<ExploreRequest> overviewRequests = <ExploreRequest>[];
  final List<ExploreRequest> directoryRequests = <ExploreRequest>[];

  /// 三个方法的总调用次数。
  int get callCount =>
      comicsRequests.length +
      overviewRequests.length +
      directoryRequests.length;

  @override
  bool get isLoggedIn => loggedIn;

  @override
  String get contextFingerprint => 'fp-${descriptor.sourceKey}/$accountVersion';

  @override
  Future<ExploreResult<ExploreOverview>> loadOverview(
    ExploreRequest request,
  ) async {
    overviewRequests.add(request);
    if (pendingOverview != null) return pendingOverview!.future;
    if (overviewUnsupported) {
      return const ExploreFailure(
          ExploreError(ExploreErrorCode.unsupported, '普通列表入口'));
    }
    return ExploreSuccess<ExploreOverview>(ExploreOverview(
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
    final option = request.options.first ?? 'none';
    return ExploreSuccess<ExploreComicPage>(ExploreComicPage(
      sourceKey: descriptor.sourceKey,
      entryId: request.entryId,
      optionId: request.options.first,
      items: comics ??
          <BaseComic>[
            _FakeComic('${request.entryId}-$option-1', '条目 $option-1'),
            _FakeComic('${request.entryId}-$option-2', '条目 $option-2'),
          ],
    ));
  }

  @override
  Future<ExploreResult<ExploreDirectory>> loadDirectory(
    ExploreRequest request,
  ) async {
    directoryRequests.add(request);
    return ExploreSuccess<ExploreDirectory>(ExploreDirectory(
      sourceKey: descriptor.sourceKey,
      groups: directoryGroups ??
          const <ExploreCategoryGroup>[
            ExploreCategoryGroup(
              id: 'g1',
              title: '本地分组',
              items: <ExploreCategoryItem>[
                ExploreCategoryItem(
                  id: 'c1',
                  label: '目录项 1',
                  route: ExploreCategoryTarget(kind: 'native', value: 'c1'),
                ),
              ],
            ),
          ],
    ));
  }
}

const List<ExploreOption> _rankOptions = <ExploreOption>[
  ExploreOption(id: 'mv', label: '总排行'),
  ExploreOption(id: 'mv_m', label: '月排行'),
];

/// 每个源都声明 recommend + ranking + category 三类入口（三页签才有意义）。
ExploreSourceDescriptor _descriptorFor(String key, String name) {
  return ExploreSourceDescriptor(
    sourceKey: key,
    name: name,
    requiresLogin: true,
    entries: <ExploreEntry>[
      ExploreEntry(
        id: '$key.home',
        label: '$name 主页',
        kind: ExploreSectionKind.recommend,
      ),
      ExploreEntry(
        id: '$key.ranking',
        label: '$name 榜单',
        kind: ExploreSectionKind.ranking,
        options: _rankOptions,
        defaultOptionId: 'mv',
        description: '站点口径',
      ),
      ExploreEntry(
        id: '$key.categories',
        label: '$key 分类目录',
        kind: ExploreSectionKind.category,
      ),
    ],
  );
}

/// 默认概览：一个成功分区 + 两个条目。
List<ExploreSection> _okSections() => const <ExploreSection>[
      ExploreSection(
        id: 's1',
        title: '热门推荐区',
        entryId: 'jm.home',
        items: <BaseComic>[
          _FakeComic('s1-1', '条目 1'),
          _FakeComic('s1-2', '条目 2'),
        ],
      ),
    ];

/// 只含 [ExplorePage] 的最小 MaterialApp；[textScale] 用于放大字号。
Widget _exploreApp({
  double textScale = 1.0,
  GlobalKey? captureKey,
  bool withShell = false,
  Brightness brightness = Brightness.light,
}) {
  final observer = NaviObserver();
  return MaterialApp(
    theme: ThemeData(
      brightness: brightness,
      fontFamily: captureKey == null ? null : 'ExploreQA',
      colorSchemeSeed: Colors.deepPurple,
    ),
    home: withShell
        ? Scaffold(
            body: NaviPane(
              observer: observer,
              paneItems: [
                PaneItemEntry(
                    label: '探索',
                    icon: Icons.explore_outlined,
                    activeIcon: Icons.explore),
              ],
              paneActions: [
                PaneActionEntry(
                    label: '在线搜索', icon: Icons.travel_explore, onTap: () {}),
                PaneActionEntry(label: '搜索', icon: Icons.search, onTap: () {}),
                PaneActionEntry(
                    label: '设置', icon: Icons.settings_outlined, onTap: () {}),
              ],
              pageBuilder: (_) => Navigator(
                observers: [observer],
                onGenerateRoute: (_) => AppPageRoute(
                  isRootRoute: true,
                  preventRebuild: false,
                  builder: (_) => ExploreRouteScope(
                      observer: observer, child: const ExplorePage()),
                ),
              ),
            ),
          )
        : const ExplorePage(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(textScale),
      ),
      child: captureKey == null
          ? child!
          : RepaintBoundary(key: captureKey, child: child!),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory workspace;
  final PathProviderPlatform originalPaths = PathProviderPlatform.instance;

  setUpAll(() async {
    workspace = await Directory.systemTemp.createTemp('picakeep_explore_page_');
    PathProviderPlatform.instance = _Paths(workspace.path);
    await App.init(dataPathOverride: '${workspace.path}/data');
  });

  tearDownAll(() async {
    PathProviderPlatform.instance = originalPaths;
    if (await workspace.exists()) {
      await workspace.delete(recursive: true);
    }
  });

  void useScreen(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  test('前提：本文件运行时 ExploreBindings 未初始化（install 在本环境不可用）', () {
    expect(ExploreBindings.instance, isNull);
  });

  testWidgets('未初始化时显示降级 UI：提示文案 + 重试入口，且不渲染源条/页签', (tester) async {
    await tester.pumpWidget(_exploreApp());
    await tester.pump(); // 跑掉 initState 里的首个 postFrameCallback(_initSource)

    expect(tester.takeException(), isNull);
    // 本页**不再自带 AppBar**：标题「探索」由主导航（NaviPane）顶栏提供，
    // 页面自己再加一个就会出现两个「探索」（用户真机反馈的第 1 条）。
    expect(find.byType(AppBar), findsNothing,
        reason: '探索页不得再自带 AppBar（避免与主导航顶栏重复）');
    expect(find.text('探索'), findsNothing,
        reason: '页面自己不再渲染「探索」标题（该文案只由主导航顶栏提供）');
    expect(find.text('探索能力尚未初始化'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    // 没有 registry 就不该出现任何源切换或页签（也不许伪造四源/三页签）。
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.text('没有可用的探索源'), findsNothing);

    // 重试仍然只走降级路径：不崩、不改变结论。
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('探索能力尚未初始化'), findsOneWidget);
    expect(find.byType(ChoiceChip), findsNothing);
  });

  testWidgets('窄屏 360x640 + 字号 1.5 不溢出', (tester) async {
    useScreen(tester, const Size(360, 640));

    await tester.pumpWidget(_exploreApp(textScale: 1.5));
    await tester.pump();

    expect(tester.takeException(), isNull,
        reason: '360x640 + textScaler 1.5 下不得有 overflow 异常');
    expect(find.text('探索能力尚未初始化'), findsOneWidget);

    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('极窄 320x520 + 字号 2.0 的极端组合不溢出', (tester) async {
    useScreen(tester, const Size(320, 520));

    await tester.pumpWidget(_exploreApp(textScale: 2.0));
    await tester.pump();

    expect(tester.takeException(), isNull,
        reason: '320x520 + textScaler 2.0 下不得有 overflow 异常');
    expect(find.text('探索能力尚未初始化'), findsOneWidget);

    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('宽屏 1400x900 可渲染', (tester) async {
    useScreen(tester, const Size(1400, 900));

    await tester.pumpWidget(_exploreApp());
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byType(AppBar), findsNothing, reason: '宽屏下同样不自带 AppBar');
    expect(find.text('探索能力尚未初始化'), findsOneWidget);
    expect(tester.getSize(find.byType(ExplorePage)).width, 1400);

    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  // ───────────────────────────────────────────────────────────────────────────
  //  模式 A：注入纯 fake registry（四源 / 三页签 / 未登录闸门 / 分区隔离）
  // ───────────────────────────────────────────────────────────────────────────

  group('注入 fake registry 后（四源 / 三页签）', () {
    late List<ComicSource> originalSources;

    setUp(() {
      originalSources = List<ComicSource>.of(ComicSource.sources);
      // 页面的登录闸门读 `ComicSource.find(key)?.isLoggedIn`：
      // jm / picacg 有 token（已登录），ehentai / nhentai 不注册（未登录）。
      ComicSource.sources
        ..clear()
        ..add(ComicSource.named(
          key: 'jm',
          name: '禁漫',
          data: <String, dynamic>{'token': 'token-jm'},
        ))
        ..add(ComicSource.named(
          key: 'picacg',
          name: '哔咔',
          data: <String, dynamic>{'token': 'token-picacg'},
        ));
    });

    tearDown(() {
      ExploreBindings.debugSetInstance(null);
      ComicSource.sources
        ..clear()
        ..addAll(originalSources);
    });

    /// 注册四个 fake 源并注入进程级实例；返回 key → provider 便于计数断言。
    Map<String, _PageFakeProvider> installFakeBindings({
      List<ExploreSection>? overviewSections,
    }) {
      const specs = <(String, String, bool)>[
        ('jm', '禁漫', true),
        ('picacg', '哔咔', true),
        ('ehentai', 'E-Hentai', false),
        ('nhentai', 'Nhentai', false),
      ];
      final registry = ExploreRegistry();
      final providers = <String, _PageFakeProvider>{};
      for (final spec in specs) {
        providers[spec.$1] = _PageFakeProvider(
          descriptor: _descriptorFor(spec.$1, spec.$2),
          loggedIn: spec.$3,
          overviewSections: overviewSections ?? _okSections(),
        );
        registry.register(providers[spec.$1]!);
      }
      ExploreBindings.debugSetInstance(ExploreBindings.forTesting(registry));
      return providers;
    }

    Future<void> pumpExplorePage(
      WidgetTester tester, {
      Size? size,
      double textScale = 1.0,
    }) async {
      if (size != null) useScreen(tester, size);
      await tester.pumpWidget(_exploreApp(textScale: textScale));
      await tester.pumpAndSettle();
    }

    /// 页面把"上次选中的源/页签"存在库级变量里（切 tab 重建页面也不丢），
    /// 所以每个用例都显式点一次目标控件，而不是依赖默认值。
    /// 点已选中项是 no-op（`_selectSource` / `_selectTab` 都会提前返回）。
    ///
    /// 源已从 `ChoiceChip` 改成 `TabBar` 的页签（与「卡片信息显示」页同款），
    /// 因此**源**要用 [tapSourceTab]，而「推荐/榜单/分类」这些内部选项仍是
    /// `ChoiceChip`，继续用 [tapChip]。
    ///
    /// 点控件**自身**（而不是它的 Text）：Text 的 RenderParagraph 不在命中路径里，
    /// 点 Text 只是恰好由祖先 InkWell 收到，会带 "would not hit test" 警告。
    Future<void> tapChip(WidgetTester tester, String label) async {
      final target = find
          .ancestor(of: find.text(label), matching: find.byType(ChoiceChip))
          .first;
      await tester.ensureVisible(target);
      await tester.tap(target);
      await tester.pumpAndSettle();
    }

    Future<void> selectOption(WidgetTester tester, String label) async {
      final menu = find.byType(PopupMenuButton<String>);
      await tester.ensureVisible(menu);
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(PopupMenuItem<String>, label));
      await tester.pumpAndSettle();
    }

    bool chipSelected(WidgetTester tester, String label) {
      final chip = tester.widget<ChoiceChip>(
        find
            .ancestor(of: find.text(label), matching: find.byType(ChoiceChip))
            .first,
      );
      return chip.selected;
    }

    /// 源页签（`TabBar` 里的 `Tab`）。
    Finder sourceTab(String label) =>
        find.ancestor(of: find.text(label), matching: find.byType(Tab)).first;

    Future<void> tapSourceTab(WidgetTester tester, String label) async {
      await tester.ensureVisible(sourceTab(label));
      await tester.tap(sourceTab(label));
      await tester.pumpAndSettle();
    }

    /// 当前选中的源页签文案（直接读页面传进 `TabBar` 的 controller 下标）。
    ///
    /// 这是"哪个源被选中"的**唯一真相**：既证明了选中态，也证明了选中的
    /// 确实是那个源，而不是只看文案是否存在。
    String selectedSourceLabel(WidgetTester tester) {
      final tabBar = tester.widget<TabBar>(find.byType(TabBar));
      final index = (tabBar.controller ??
              DefaultTabController.of(tester.element(find.byType(TabBar))))
          .index;
      expect(index, inInclusiveRange(0, tabBar.tabs.length - 1));
      return (tabBar.tabs[index] as Tab).text!;
    }

    testWidgets('四源可达：源条上四个源标签都在，未登录源带「（未登录）」后缀', (tester) async {
      final providers = installFakeBindings();
      await pumpExplorePage(tester);

      expect(tester.takeException(), isNull);
      // 正常（有源）路径同样不自带 AppBar、不重复标题、没有 AppBar 上的账号按钮。
      expect(find.byType(AppBar), findsNothing,
          reason: '探索页不得再自带 AppBar（标题由主导航顶栏提供）');
      expect(find.text('探索'), findsNothing, reason: '页面自己不渲染「探索」标题，避免与主导航顶栏重复');
      expect(find.byIcon(Icons.manage_accounts_outlined), findsNothing,
          reason: 'AppBar 右上角的账号管理快捷按钮已移除');
      // 源现在住在 `TabBar` 的页签里（与「卡片信息显示」页同款）。
      expect(find.byType(TabBar), findsOneWidget);
      expect(find.byType(Tab), findsNWidgets(4), reason: '四个源四个页签');
      expect(find.text('禁漫'), findsOneWidget);
      expect(find.text('哔咔'), findsOneWidget);
      expect(find.text('E-Hentai（未登录）'), findsOneWidget);
      expect(find.text('Nhentai（未登录）'), findsOneWidget);

      // 默认落到首个已登录源；即使上一次用例把源暂存成别的，显式点一次也能确定。
      await tapSourceTab(tester, '禁漫');
      // 页签固定到推荐，避免上一次用例暂存的榜期选项条干扰计数。
      await tapChip(tester, '推荐');
      expect(selectedSourceLabel(tester), '禁漫');
      expect(selectedSourceLabel(tester), isNot('哔咔'));
      expect(selectedSourceLabel(tester), isNot('E-Hentai（未登录）'));
      expect(selectedSourceLabel(tester), isNot('Nhentai（未登录）'));

      // 切源**真的生效**（而不是只动了页签选中态）：点到另一个已登录源后，
      // 请求必须落到新源上。
      await tapSourceTab(tester, '哔咔');
      await tapChip(tester, '推荐');
      expect(selectedSourceLabel(tester), '哔咔');
      expect(providers['picacg']!.overviewRequests, isNotEmpty,
          reason: '切到哔咔必须真的请求哔咔');

      // 4 个源已从 ChoiceChip 变成 Tab，剩下的 ChoiceChip 只有"推荐/榜单/分类"。
      expect(find.byType(ChoiceChip), findsNWidgets(3),
          reason: '源不再是 ChoiceChip；3 个内部页签仍是');
    });

    testWidgets('三页签可达：推荐/榜单/分类都在；榜单出榜期选项、分类出目录入口', (tester) async {
      final providers = installFakeBindings();
      await pumpExplorePage(tester);
      await tapSourceTab(tester, '禁漫');
      await tapChip(tester, '推荐');

      // 三个页签都可达（已登录源声明了三类入口）。
      expect(find.text('推荐'), findsOneWidget);
      expect(find.text('榜单'), findsOneWidget);
      expect(find.text('分类'), findsOneWidget);

      // 推荐：概览分区标题与条目可见。
      await tapChip(tester, '推荐');
      expect(chipSelected(tester, '推荐'), isTrue);
      expect(find.text('热门推荐区'), findsOneWidget);
      expect(find.text('条目 1'), findsOneWidget);
      expect(providers['jm']!.overviewRequests, isNotEmpty);

      // 榜单：出现榜期选项条（ExploreOption.label）。
      await tapChip(tester, '榜单');
      expect(chipSelected(tester, '榜单'), isTrue);
      expect(find.text('总排行'), findsOneWidget);
      expect(find.text('月排行'), findsNothing, reason: '未选榜期收进菜单，避免第二排占高度');
      expect(providers['jm']!.comicsRequests, isNotEmpty);

      // 分类：出现分类入口列表（entry.label 可见）。
      await tapChip(tester, '分类');
      expect(chipSelected(tester, '分类'), isTrue);
      expect(find.text('本地分组'), findsOneWidget);
      expect(find.text('目录项 1'), findsOneWidget);
      expect(providers['jm']!.directoryRequests, hasLength(1));

      expect(tester.takeException(), isNull);
    });

    testWidgets('未登录源：三个加载方法调用次数全为 0，并显示需要登录说明与账号管理入口', (tester) async {
      final providers = installFakeBindings();
      await pumpExplorePage(tester);
      await tapSourceTab(tester, '禁漫');

      await tapSourceTab(tester, 'E-Hentai（未登录）');

      final notLoggedIn = providers['ehentai']!;
      expect(notLoggedIn.overviewRequests, isEmpty);
      expect(notLoggedIn.comicsRequests, isEmpty);
      expect(notLoggedIn.directoryRequests, isEmpty);
      expect(notLoggedIn.callCount, 0, reason: '未登录源不得发任何请求');

      // 顺带确认另一个未登录源同样没有被请求过。
      expect(providers['nhentai']!.callCount, 0);

      expect(find.text('E-Hentai 需要登录后才能浏览'), findsOneWidget);
      // 账号管理入口必须**仍然存在**（AppBar 上那个快捷按钮已按用户要求去掉，
      // 未登录说明里的这个按钮是保留的入口；两者不是同一个控件）。
      expect(find.text('账号管理'), findsOneWidget);
      expect(find.byIcon(Icons.manage_accounts_outlined), findsNothing,
          reason: 'AppBar 上的账号管理快捷按钮已移除');
      expect(selectedSourceLabel(tester), 'E-Hentai（未登录）');
      expect(tester.takeException(), isNull);
    });

    testWidgets('概览分区错误隔离：成功分区条目可见，失败分区显示错误+重试，互不抹掉', (tester) async {
      installFakeBindings(overviewSections: const <ExploreSection>[
        ExploreSection(
          id: 'ok',
          title: '推荐区A',
          entryId: 'jm.home',
          items: <BaseComic>[
            _FakeComic('a1', '条目 A-1'),
            _FakeComic('a2', '条目 A-2'),
          ],
        ),
        ExploreSection(
          id: 'bad',
          title: '推荐区B',
          entryId: 'jm.home',
          error: ExploreError(ExploreErrorCode.network, '分区B炸了'),
        ),
      ]);
      // 大画布：两个分区（含 164dp 卡片）都要真正被 build 出来。
      await pumpExplorePage(tester, size: const Size(1000, 1400));
      await tapSourceTab(tester, '禁漫');
      await tapChip(tester, '推荐');

      // 成功分区的内容在。
      expect(find.text('推荐区A'), findsOneWidget);
      expect(find.text('条目 A-1'), findsOneWidget);
      expect(find.text('条目 A-2'), findsOneWidget);
      // 失败分区自己的错误与页内重试在（不是整页错误视图）。
      expect(find.text('推荐区B'), findsOneWidget);
      expect(find.text('分区B炸了'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      // 失败分区没有抹掉成功分区。
      expect(find.text('没有推荐内容'), findsNothing);
      expect(find.text('条目 A-1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('切榜期：新请求带新 option id，且请求次数 +1', (tester) async {
      final providers = installFakeBindings();
      await pumpExplorePage(tester);
      await tapSourceTab(tester, '禁漫');
      await tapChip(tester, '榜单');

      final jm = providers['jm']!;
      // 先点「总排行」把选中态确定下来（若已选中则是 no-op，不发请求）。
      await selectOption(tester, '总排行');
      final before = jm.comicsRequests.length;

      await selectOption(tester, '月排行');

      expect(jm.comicsRequests.length, before + 1, reason: '换榜期恰好新增一次请求');
      expect(jm.comicsRequests.last.options.first, 'mv_m');
      expect(jm.comicsRequests.last.entryId, 'jm.ranking');
      expect(jm.comicsRequests.last.continuation, isNull, reason: '换榜期是首屏请求');
      expect(jm.comicsRequests.last.category, isNull);
      expect(find.text('月排行'), findsOneWidget);
      expect(find.text('总排行'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('注入 registry 后窄屏 360x640 + 字号 1.5：满屏源页签+页签不溢出', (tester) async {
      final providers = installFakeBindings();
      await pumpExplorePage(
        tester,
        size: const Size(360, 640),
        textScale: 1.5,
      );
      await tapSourceTab(tester, '禁漫');
      await tapChip(tester, '推荐');

      // 此时确实是"满屏控件"：4 个源页签（可横向滚动）+ 3 个内部页签 chip。
      expect(find.byType(Tab), findsNWidgets(4), reason: '四个源页签都在（超宽时横向滚动）');
      expect(selectedSourceLabel(tester), '禁漫', reason: '窄屏上源页签仍可点中');
      expect(find.text('禁漫'), findsOneWidget);
      expect(find.text('推荐'), findsOneWidget);
      expect(find.text('榜单'), findsOneWidget);
      expect(find.text('分类'), findsOneWidget);
      expect(tester.takeException(), isNull,
          reason: '360x640 + textScaler 1.5 下满屏控件不得 overflow');

      // 再切到榜单（选项条 + 卡片列表）仍然不溢出；并用请求证明切换真的生效。
      await tapChip(tester, '榜单');
      expect(chipSelected(tester, '榜单'), isTrue, reason: '窄屏上页签 chip 仍可点中');
      expect(find.text('总排行'), findsOneWidget);
      expect(providers['jm']!.comicsRequests, isNotEmpty,
          reason: '切到榜单必须真的发起榜单请求');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('切源返回保留已加载内容和滚动位置，不重复发请求', (tester) async {
      final providers = installFakeBindings(overviewSections: [
        ExploreSection(
          id: 'many',
          title: '推荐内容',
          entryId: 'jm.home',
          items: List.generate(20, (i) => _FakeComic('item-$i', '示例条目 $i')),
        )
      ]);
      await pumpExplorePage(tester, size: const Size(430, 800));
      await tapSourceTab(tester, '禁漫');
      await tapChip(tester, '推荐');
      final before = providers['jm']!.overviewRequests.length;
      await tester.drag(find.byType(ListView), const Offset(0, -630));
      await tester.pumpAndSettle();
      final controller =
          tester.widget<ListView>(find.byType(ListView)).controller!;
      final offset = controller.offset;
      expect(offset, greaterThan(300));

      await tapSourceTab(tester, '哔咔');
      expect(providers['picacg']!.overviewRequests, hasLength(1));
      await tapSourceTab(tester, '禁漫');
      expect(providers['jm']!.overviewRequests, hasLength(before));
      expect(tester.widget<ListView>(find.byType(ListView)).controller,
          same(controller));
      expect(controller.offset, closeTo(offset, 0.1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('推荐与榜单相互返回保留请求结果和榜期选择', (tester) async {
      final providers = installFakeBindings();
      await pumpExplorePage(tester);
      await tapSourceTab(tester, '禁漫');
      await tapChip(tester, '推荐');
      await tapChip(tester, '榜单');
      await selectOption(tester, '月排行');
      final overviewBefore = providers['jm']!.overviewRequests.length;
      final listBefore = providers['jm']!.comicsRequests.length;

      await tapChip(tester, '推荐');
      expect(find.text('条目 1'), findsOneWidget);
      await tapChip(tester, '榜单');
      expect(find.text('月排行'), findsOneWidget);
      expect(find.text('条目 mv_m-1'), findsOneWidget);
      expect(providers['jm']!.overviewRequests, hasLength(overviewBefore));
      expect(providers['jm']!.comicsRequests, hasLength(listBefore));
      expect(tester.takeException(), isNull);
    });

    testWidgets('分类模式跨源保持一致，返回已访问分类不再请求', (tester) async {
      final providers = installFakeBindings();
      await pumpExplorePage(tester);
      await tapSourceTab(tester, '禁漫');
      await tapChip(tester, '分类');
      final jmBefore = providers['jm']!.directoryRequests.length;
      expect(find.text('目录项 1'), findsOneWidget);
      await tapSourceTab(tester, '哔咔');
      expect(chipSelected(tester, '分类'), isTrue);
      expect(providers['picacg']!.directoryRequests, hasLength(1));
      expect(find.text('目录项 1'), findsOneWidget);
      await tapSourceTab(tester, '禁漫');
      expect(chipSelected(tester, '分类'), isTrue);
      expect(providers['jm']!.directoryRequests, hasLength(jmBefore));
      expect(tester.takeException(), isNull);
    });

    for (final empty in [true, false]) {
      testWidgets('概览${empty ? '空' : '短'}内容可以下拉刷新', (tester) async {
        final providers = installFakeBindings(
            overviewSections: empty
                ? []
                : const [
                    ExploreSection(
                        id: 'short',
                        title: '推荐内容',
                        entryId: 'jm.home',
                        items: [_FakeComic('short', '刷新前')]),
                  ]);
        await pumpExplorePage(tester, size: const Size(430, 800));
        await tapSourceTab(tester, '禁漫');
        await tapChip(tester, '推荐');
        final jm = providers['jm']!;
        final before = jm.overviewRequests.length;
        if (empty) expect(find.text('没有推荐内容'), findsOneWidget);
        jm.overviewSections = const [
          ExploreSection(
              id: 'fresh',
              title: '更新推荐',
              entryId: 'jm.home',
              items: [_FakeComic('fresh', '刷新后')])
        ];
        await tester.drag(find.byType(RefreshIndicator), const Offset(0, 400));
        await tester.pumpAndSettle();
        expect(jm.overviewRequests, hasLength(before + 1));
        expect(find.text('刷新后'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('普通列表${empty ? '空' : '短'}内容可以下拉刷新', (tester) async {
        final providers = installFakeBindings();
        for (final provider in providers.values) {
          provider.overviewUnsupported = true;
          provider.comics = empty ? [] : const [_FakeComic('short', '刷新前')];
        }
        await pumpExplorePage(tester, size: const Size(430, 800));
        await tapSourceTab(tester, '哔咔');
        await tapChip(tester, '推荐');
        final pica = providers['picacg']!;
        final before = pica.comicsRequests.length;
        if (empty) expect(find.text('没有内容'), findsOneWidget);
        pica.comics = const [_FakeComic('fresh', '刷新后')];
        await tester.drag(find.byType(RefreshIndicator), const Offset(0, 400));
        await tester.pumpAndSettle();
        expect(pica.comicsRequests, hasLength(before + 1));
        expect(find.text('刷新后'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('慢请求期间切源，迟到结果只更新原源', (tester) async {
      final providers = installFakeBindings();
      providers['picacg']!.overviewSections = const [
        ExploreSection(
          id: 'pica',
          title: '哔咔内容',
          entryId: 'picacg.home',
          items: [_FakeComic('pica', '目标源内容')],
        )
      ];
      await pumpExplorePage(tester);
      await tapSourceTab(tester, '禁漫');
      await tapChip(tester, '推荐');
      final pending = Completer<ExploreResult<ExploreOverview>>();
      providers['jm']!.pendingOverview = pending;
      await tester.drag(find.byType(RefreshIndicator), const Offset(0, 400));
      await tester.pump(const Duration(seconds: 1));
      await tester.ensureVisible(sourceTab('哔咔'));
      await tester.tap(sourceTab('哔咔'));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.text('目标源内容'), findsOneWidget);
      pending.complete(const ExploreSuccess(
          ExploreOverview(sourceKey: 'jm', entryId: 'jm.home', sections: [
        ExploreSection(
            id: 'late',
            title: '迟到分区',
            entryId: 'jm.home',
            items: [_FakeComic('late', '迟到源内容')]),
      ])));
      await tester.pumpAndSettle();
      expect(find.text('迟到源内容'), findsNothing);
      expect(find.text('目标源内容'), findsOneWidget);
      final before = providers['jm']!.overviewRequests.length;
      await tapSourceTab(tester, '禁漫');
      expect(find.text('迟到源内容'), findsOneWidget);
      expect(providers['jm']!.overviewRequests, hasLength(before));
      expect(tester.takeException(), isNull);
    });

    testWidgets('普通字号推荐与榜单控制条不超过52dp，榜期仍可操作', (tester) async {
      installFakeBindings();
      await pumpExplorePage(tester, size: const Size(360, 640));
      await tapSourceTab(tester, '禁漫');
      await tapChip(tester, '推荐');
      final toolbar = find.byKey(const ValueKey('explore-toolbar'));
      expect(tester.getSize(toolbar).height, lessThanOrEqualTo(52));
      await tapChip(tester, '榜单');
      expect(tester.getSize(toolbar).height, lessThanOrEqualTo(52));
      await selectOption(tester, '月排行');
      expect(find.text('月排行'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('账号指纹变化在恢复时清掉旧内容并重载当前源', (tester) async {
      final providers = installFakeBindings();
      await pumpExplorePage(tester);
      await tapSourceTab(tester, '禁漫');
      await tapChip(tester, '推荐');
      final jm = providers['jm']!;
      final before = jm.overviewRequests.length;
      jm.accountVersion = 'account-2';
      jm.overviewSections = const [
        ExploreSection(
            id: 'new',
            title: '新账号推荐',
            entryId: 'jm.home',
            items: [_FakeComic('new', '新账号内容')])
      ];
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(jm.overviewRequests, hasLength(before + 1));
      expect(find.text('新账号内容'), findsOneWidget);
      expect(find.text('条目 1'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('账号变更后旧账号慢请求返回不会污染当前账号', (tester) async {
      final providers = installFakeBindings();
      await pumpExplorePage(tester);
      await tapSourceTab(tester, '禁漫');
      await tapChip(tester, '推荐');
      final jm = providers['jm']!;
      final pending = Completer<ExploreResult<ExploreOverview>>();
      jm.pendingOverview = pending;
      final before = jm.overviewRequests.length;
      await tester.drag(find.byType(RefreshIndicator), const Offset(0, 400));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 300));
      expect(jm.overviewRequests, hasLength(before + 1));
      jm.accountVersion = 'account-2';
      jm.pendingOverview = null;
      jm.overviewSections = const [
        ExploreSection(
            id: 'new',
            title: '新账号推荐',
            entryId: 'jm.home',
            items: [_FakeComic('new', '新账号内容')])
      ];
      pending.complete(const ExploreSuccess(
          ExploreOverview(sourceKey: 'jm', entryId: 'jm.home', sections: [
        ExploreSection(
            id: 'old',
            title: '旧账号推荐',
            entryId: 'jm.home',
            items: [_FakeComic('old', '禁止展示的旧账号结果')]),
      ])));
      await tester.pumpAndSettle();
      expect(find.text('禁止展示的旧账号结果'), findsNothing);
      expect(find.text('新账号内容'), findsOneWidget);
      expect(jm.overviewRequests, hasLength(before + 2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('320x640加2倍字体下三模式与榜期菜单都能操作', (tester) async {
      installFakeBindings();
      await pumpExplorePage(tester, size: const Size(320, 640), textScale: 2);
      await tapSourceTab(tester, '禁漫');
      await tapChip(tester, '推荐');
      await tapChip(tester, '榜单');
      await selectOption(tester, '月排行');
      expect(find.text('月排行'), findsOneWidget);
      await tapChip(tester, '分类');
      expect(find.text('目录项 1'), findsOneWidget);
      await tapSourceTab(tester, '哔咔');
      expect(chipSelected(tester, '分类'), isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('大推荐分区按漫画行懒加载，不一次性构建整组', (tester) async {
      final comics = [
        for (var i = 0; i < 500; i++) _FakeComic('large-$i', '推荐条目 $i'),
      ];
      installFakeBindings(overviewSections: [
        ExploreSection(
            id: 'large', title: '大分区', entryId: 'jm.home', items: comics),
      ]);
      await pumpExplorePage(tester, size: const Size(430, 800));
      await tapSourceTab(tester, '禁漫');
      await tapChip(tester, '推荐');
      expect(find.byType(OnlineComicListItem).evaluate().length,
          inInclusiveRange(1, 10));
      expect(find.text('推荐条目 499', skipOffstage: false), findsNothing);
      await tester.drag(find.byType(ListView), const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(find.byType(OnlineComicListItem).evaluate().length,
          lessThanOrEqualTo(12));
      expect(tester.takeException(), isNull);
    });

    testWidgets('切源有渐变位移，动画帧不反复构建卡片', (tester) async {
      final providers = installFakeBindings();
      final comics = [
        _BuildProbeComic('jm-probe', '源一'),
        _BuildProbeComic('pica-probe', '源二')
      ];
      for (final entry in [('jm', comics[0]), ('picacg', comics[1])]) {
        providers[entry.$1]!.overviewSections = [
          ExploreSection(
              id: 'probe',
              title: '动画测试',
              entryId: '${entry.$1}.home',
              items: [entry.$2]),
        ];
      }
      await pumpExplorePage(tester, size: const Size(430, 800));
      await tapSourceTab(tester, '禁漫');
      await tapChip(tester, '推荐');
      await tapSourceTab(tester, '哔咔');
      final requests = providers.values.fold(0, (sum, p) => sum + p.callCount);
      await tester.tap(sourceTab('禁漫'));
      await tester.pump();
      final deck = find.byType(ExploreKeepAliveSwitcher).first;
      final fade = find
          .descendant(of: deck, matching: find.byType(FadeTransition))
          .first;
      final slide = find
          .descendant(of: deck, matching: find.byType(SlideTransition))
          .first;
      expect(tester.widget<FadeTransition>(fade).opacity.value, lessThan(1));
      expect(
          tester.widget<SlideTransition>(slide).position.value.dx, lessThan(0));
      final reads = comics.map((comic) => comic.titleReads).toList();
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(comics.map((comic) => comic.titleReads), reads);
      expect(tester.widget<FadeTransition>(fade).opacity.value, 1);
      expect(tester.widget<SlideTransition>(slide).position.value, Offset.zero);
      expect(providers.values.fold(0, (sum, p) => sum + p.callCount), requests);
      expect(tester.takeException(), isNull);
    });

    testWidgets('菜单开合不重建已经加载的漫画卡片', (tester) async {
      final providers = installFakeBindings();
      final comic = _BuildProbeComic('probe', '重建探针');
      providers['jm']!.comics = [comic];
      useScreen(tester, const Size(430, 800));
      await tester.pumpWidget(_exploreApp(withShell: true));
      await tester.pumpAndSettle();
      await tapSourceTab(tester, '禁漫');
      await tapChip(tester, '榜单');
      final reads = comic.titleReads;
      expect(reads, greaterThan(0));
      await tester.tap(find.byKey(const ValueKey('explore-entry-menu')));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(comic.titleReads, reads, reason: '菜单的路由与焦点变化不应重建卡片');
      expect(tester.takeException(), isNull);
    });

    testWidgets('主导航内展开和关闭菜单不移动顶底栏、不刷新列表', (tester) async {
      final providers = installFakeBindings();
      useScreen(tester, const Size(430, 900));
      await tester.pumpWidget(_exploreApp(withShell: true));
      await tester.pumpAndSettle();
      await tapSourceTab(tester, '禁漫');
      await tapChip(tester, '榜单');

      final menu = find.byKey(const ValueKey('explore-entry-menu'));
      final settings = find.byTooltip('设置').first;
      final settingsRect = tester.getRect(settings);
      final pageRect = tester.getRect(find.byType(ExplorePage));
      final controller =
          tester.widget<ListView>(find.byType(ListView)).controller;
      final requestCount = providers['jm']!.callCount;

      Future<void> openMenu() async {
        await tester.tap(menu);
        // Cover the opening animation as well as the settled position.
        for (final duration in [16, 80, 160]) {
          await tester.pump(Duration(milliseconds: duration));
          expect(tester.getRect(settings), settingsRect);
          expect(tester.getRect(find.byType(ExplorePage)), pageRect);
        }
        await tester.pumpAndSettle();
        expect(find.text('禁漫 · 榜单范围'), findsOneWidget);
        expect(providers['jm']!.callCount, requestCount);
      }

      await openMenu();
      // Android's back action should only dismiss the popup.
      final navigator =
          tester.state<NavigatorState>(find.byType(Navigator).last);
      await navigator.maybePop();
      await tester.pumpAndSettle();
      expect(find.text('禁漫 · 榜单范围'), findsNothing);
      expect(settings.hitTestable(), findsOneWidget);

      await openMenu();
      await tester.tapAt(const Offset(16, 220));
      await tester.pumpAndSettle();
      expect(find.text('禁漫 · 榜单范围'), findsNothing);

      await openMenu();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('禁漫 · 榜单范围'), findsNothing);

      await openMenu();
      await tester.tap(find.widgetWithText(PopupMenuItem<String>, '总排行'));
      await tester.pumpAndSettle();
      expect(providers['jm']!.callCount, requestCount, reason: '选择当前入口也不得重载');
      expect(tester.widget<ListView>(find.byType(ListView)).controller,
          same(controller));
      expect(tester.getRect(settings), settingsRect);
      expect(tester.getRect(find.byType(ExplorePage)), pageRect);
      expect(tester.takeException(), isNull);
    });

    for (final brightness in Brightness.values) {
      testWidgets('窄屏大字号的${brightness.name}菜单可完整选择榜期', (tester) async {
        final providers = installFakeBindings();
        useScreen(tester, const Size(320, 700));
        await tester
            .pumpWidget(_exploreApp(textScale: 2, brightness: brightness));
        await tester.pumpAndSettle();
        await tapSourceTab(tester, '禁漫');
        await tapChip(tester, '榜单');
        await tester.tap(find.byKey(const ValueKey('explore-entry-menu')));
        await tester.pumpAndSettle();
        final option = find.widgetWithText(PopupMenuItem<String>, '月排行');
        expect(tester.getRect(option).left, greaterThanOrEqualTo(0));
        expect(tester.getRect(option).right, lessThanOrEqualTo(320));
        await tester.tap(option);
        await tester.pumpAndSettle();
        expect(providers['jm']!.comicsRequests.last.options.first, 'mv_m');
        expect(find.text('条目 mv_m-1'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    const qaDirectory = String.fromEnvironment('EXPLORE_QA_DIR');
    testWidgets('中性数据视觉验收截图', (tester) async {
      final previousShadows = debugDisableShadows;
      debugDisableShadows = false;
      addTearDown(() => debugDisableShadows = previousShadows);
      await tester.runAsync(() async {
        final bytes = await File('C:/Windows/Fonts/msyh.ttc').readAsBytes();
        await (FontLoader('ExploreQA')
              ..addFont(Future.value(ByteData.sublistView(bytes))))
            .load();
        final icons =
            await File('build/unit_test_assets/fonts/MaterialIcons-Regular.otf')
                .readAsBytes();
        await (FontLoader('MaterialIcons')
              ..addFont(Future.value(ByteData.sublistView(icons))))
            .load();
      });
      final providers = installFakeBindings(overviewSections: const [
        ExploreSection(id: 'sketch', title: '今日推荐', entryId: 'jm.home', items: [
          _FakeComic('1001', '山间写生与城市速写'),
          _FakeComic('1002', '周末旅行手记')
        ]),
        ExploreSection(
            id: 'latest',
            title: '最近更新',
            entryId: 'jm.home',
            items: [_FakeComic('1003', '植物观察图鉴')]),
      ]);
      for (final provider in providers.values) {
        provider.loggedIn = true;
        final descriptor = provider.descriptor;
        provider.descriptor = ExploreSourceDescriptor(
            sourceKey: descriptor.sourceKey,
            name: descriptor.name,
            entries: [
              ExploreEntry(
                  id: '${descriptor.sourceKey}.home',
                  label: '主页推荐',
                  kind: ExploreSectionKind.recommend),
              ...descriptor.entries.where((e) => !e.id.endsWith('.home')),
              ExploreEntry(
                  id: '${descriptor.sourceKey}.latest',
                  label: '最新',
                  kind: ExploreSectionKind.recommend),
              ExploreEntry(
                  id: '${descriptor.sourceKey}.week',
                  label: '每周推荐',
                  kind: ExploreSectionKind.recommend),
            ]);
        provider.directoryGroups = [
          ExploreCategoryGroup(id: 'types', title: '分类', items: [
            for (final label in [
              '大家都在看',
              '最近更新',
              '编辑推荐',
              '全彩',
              '长篇',
              '短篇',
              '原创',
              '同人',
              '插画',
              '冒险',
              '日常',
              '奇幻'
            ])
              ExploreCategoryItem(
                  id: label,
                  label: label,
                  route: ExploreCategoryTarget(kind: 'native', value: label)),
          ]),
          ExploreCategoryGroup(
              id: 'themes',
              title: '主题',
              isSearch: true,
              items: [
                for (final label in [
                  '旅行',
                  '城市',
                  '自然',
                  '植物',
                  '艺术',
                  '历史',
                  '科学',
                  '生活'
                ])
                  ExploreCategoryItem(
                      id: label,
                      label: label,
                      isSearch: true,
                      route:
                          ExploreCategoryTarget(kind: 'search', value: label)),
              ]),
        ];
      }
      useScreen(tester, const Size(430, 900));
      final captureKey = GlobalKey();
      await tester
          .pumpWidget(_exploreApp(captureKey: captureKey, withShell: true));
      await tester.pumpAndSettle();
      await tapSourceTab(tester, '禁漫');
      await tapChip(tester, '推荐');
      Future<void> capture(String fileName) async {
        final boundary = captureKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('$qaDirectory/$fileName');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      await capture('探索-首页.png');
      await tester.tap(find.byKey(const ValueKey('explore-entry-menu')));
      await tester.pumpAndSettle();
      await capture('探索-入口菜单.png');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tapChip(tester, '分类');
      await capture('探索-分类.png');
      expect(tester.takeException(), isNull);
      debugDisableShadows = previousShadows;
    }, skip: qaDirectory.isEmpty);
  });
}

/// 探索首页「榜单」页签的**关键词屏蔽两态**与**过滤后仍能继续真实 next** 页面级测试。
///
/// 覆盖验收标准 10：
/// - `settings[83] == '0'`（不隐藏）：命中屏蔽词的条目仍渲染，但必须带上
///   「已屏蔽：<词>」说明（两态里的"可见态"）；
/// - `settings[83] == '1'`（完全隐藏）：命中屏蔽词的条目不再渲染（"隐藏态"）；
/// - 过滤后可见列表为空但仍有 next 时：**不**为了凑可见列表自动翻页（首屏恰好 1 次
///   `loadComics`），页尾保留「加载更多」，点它才用真实 cursor 续页。
///
/// 夹具全部是 fake provider + `ExploreBindings.forTesting` 接缝：不构造任何真实
/// 网络单例（EH 的 `CookieJarSql` 需要 sqlite3 动态库，`flutter test` 下加载不了）。
///
/// 注意：`ExplorePage` 把"上次选中的源/页签"存在**库级变量**里，所以每个用例都
/// 显式点一次目标源 + 目标页签（点已选中的 chip 是 no-op），不依赖默认值。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/explore/explore_bindings.dart';
import 'package:picakeep/foundation/explore/explore_models.dart';
import 'package:picakeep/foundation/explore/explore_provider.dart';
import 'package:picakeep/foundation/explore/explore_registry.dart';
import 'package:picakeep/network/base_comic.dart';
import 'package:picakeep/pages/explore/explore_page.dart';
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

/// 最小漫画条目：只给标题参与屏蔽匹配，空封面走卡片占位。
class _BlockingComic extends BaseComic {
  const _BlockingComic(this.id, this.title);

  @override
  final String id;
  @override
  final String title;
  @override
  String get subTitle => '';
  @override
  String get cover => '';
  @override
  List<String> get tags => const <String>[];
  @override
  String get description => '';
}

/// 单页签（榜单）fake 源：按 `continuation` 返回第 1 / 第 2 页，并记录每次请求。
class _RankingFakeProvider implements ExploreProvider {
  _RankingFakeProvider({
    required this.descriptor,
    required this.page1,
    required this.page1NextToken,
    required this.page2,
  });

  @override
  final ExploreSourceDescriptor descriptor;

  /// 第 1 页（`continuation == null`）返回的条目。
  final List<BaseComic> page1;

  /// 第 1 页给出的续页游标；`null` 表示到末页。
  final String? page1NextToken;

  /// 第 2 页返回的条目（`nextToken` 恒为 null）。
  final List<BaseComic> page2;

  final List<ExploreRequest> comicsRequests = <ExploreRequest>[];
  final List<ExploreRequest> overviewRequests = <ExploreRequest>[];
  final List<ExploreRequest> directoryRequests = <ExploreRequest>[];

  @override
  bool get isLoggedIn => true;

  @override
  String get contextFingerprint => 'fp-${descriptor.sourceKey}';

  @override
  Future<ExploreResult<ExploreComicPage>> loadComics(
    ExploreRequest request,
  ) async {
    comicsRequests.add(request);
    final isFirstPage = request.continuation == null;
    return ExploreSuccess<ExploreComicPage>(ExploreComicPage(
      sourceKey: descriptor.sourceKey,
      entryId: request.entryId,
      optionId: request.options.first,
      items: isFirstPage ? page1 : page2,
      nextToken: isFirstPage ? page1NextToken : null,
    ));
  }

  @override
  Future<ExploreResult<ExploreOverview>> loadOverview(
    ExploreRequest request,
  ) async {
    overviewRequests.add(request);
    return const ExploreFailure<ExploreOverview>(
      ExploreError(ExploreErrorCode.unsupported, '夹具没有概览入口'),
    );
  }

  @override
  Future<ExploreResult<ExploreDirectory>> loadDirectory(
    ExploreRequest request,
  ) async {
    directoryRequests.add(request);
    return const ExploreFailure<ExploreDirectory>(
      ExploreError(ExploreErrorCode.unsupported, '夹具没有分类入口'),
    );
  }
}

// ── 夹具常量 ─────────────────────────────────────────────────────────────────

/// 屏蔽词。
const String kBlockedWord = '屏蔽词';

const String kBlockedTitleA = '屏蔽词 条目 A';
const String kBlockedTitleB = '含屏蔽词的条目 B';
const String kNormalTitle1 = '正常条目 1';
const String kNormalTitle2 = '正常条目 2';

/// 榜单入口：`singlePage: false` + 一个选项 → 页面走真实翻页路径。
const ExploreSourceDescriptor _jmRankingDescriptor = ExploreSourceDescriptor(
  sourceKey: 'jm',
  name: '禁漫',
  requiresLogin: true,
  entries: <ExploreEntry>[
    ExploreEntry(
      id: 'jm.ranking',
      label: '榜单',
      kind: ExploreSectionKind.ranking,
      singlePage: false,
      options: <ExploreOption>[ExploreOption(id: 'mv', label: '总排行')],
      defaultOptionId: 'mv',
    ),
  ],
);

/// 第 1 页：两条命中屏蔽词 + 一条正常。
const List<BaseComic> _page1Mixed = <BaseComic>[
  _BlockingComic('b1', kBlockedTitleA),
  _BlockingComic('b2', kBlockedTitleB),
  _BlockingComic('ok1', kNormalTitle1),
];

/// 第 1 页：两条**都**命中屏蔽词（过滤后可见列表为空，但仍有 next）。
const List<BaseComic> _page1AllBlocked = <BaseComic>[
  _BlockingComic('b1', kBlockedTitleA),
  _BlockingComic('b2', kBlockedTitleB),
];

/// 第 2 页：一条正常条目。
const List<BaseComic> _page2 = <BaseComic>[
  _BlockingComic('ok2', kNormalTitle2),
];

Widget _exploreApp() => const MaterialApp(home: ExplorePage());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory workspace;
  final PathProviderPlatform originalPaths = PathProviderPlatform.instance;

  setUpAll(() async {
    workspace = await Directory.systemTemp.createTemp('picakeep_blocking_');
    PathProviderPlatform.instance = _Paths(workspace.path);
    await App.init(dataPathOverride: '${workspace.path}/data');
  });

  tearDownAll(() async {
    PathProviderPlatform.instance = originalPaths;
    if (await workspace.exists()) {
      await workspace.delete(recursive: true);
    }
  });

  // ── 每个用例前：干净的源注册 + 干净的屏蔽设置快照 ───────────────────────────

  late List<String> originalSettings;
  late List<String> originalKeywords;
  late List<ComicSource> originalSources;

  setUp(() {
    originalSettings = List<String>.from(appdata.settings);
    originalKeywords = List<String>.from(appdata.blockingKeyword);
    originalSources = List<ComicSource>.of(ComicSource.sources);

    // 只有 jm 一个已登录源（带 token），页面才不是"需要登录"态。
    ComicSource.sources
      ..clear()
      ..add(ComicSource.named(
        key: 'jm',
        name: '禁漫',
        data: <String, dynamic>{'token': 'token-jm'},
      ));
    appdata.blockingKeyword = <String>[kBlockedWord];
  });

  tearDown(() {
    ExploreBindings.debugSetInstance(null);
    ComicSource.sources
      ..clear()
      ..addAll(originalSources);
    // 就地还原，避免污染别的测试文件（两个值都是全局 appdata 字段）。
    appdata.blockingKeyword
      ..clear()
      ..addAll(originalKeywords);
    appdata.settings
      ..clear()
      ..addAll(originalSettings);
  });

  /// 「完全隐藏屏蔽的作品」开关（`settings[83]`）；不足 84 项时补齐，保证索引存在。
  void setHideBlocked(bool hide) {
    final settings = appdata.settings;
    while (settings.length <= 83) {
      settings.add('');
    }
    settings[83] = hide ? '1' : '0';
  }

  /// 注册 fake 榜单源并注入进程级绑定；返回 provider 便于计数断言。
  _RankingFakeProvider installRankingFixture({
    required List<BaseComic> page1,
    String? page1NextToken = 'cursor-2',
    List<BaseComic> page2 = _page2,
  }) {
    final provider = _RankingFakeProvider(
      descriptor: _jmRankingDescriptor,
      page1: page1,
      page1NextToken: page1NextToken,
      page2: page2,
    );
    final registry = ExploreRegistry()..register(provider);
    ExploreBindings.debugSetInstance(ExploreBindings.forTesting(registry));
    return provider;
  }

  /// 点"源"或内部选项的**控件自身**（而不是它的 Text）：Text 的 RenderParagraph
  /// 不在命中路径里，点 Text 只是恰好由祖先 InkWell 收到，会带 "would not hit test"
  /// 警告。
  ///
  /// 源已从 `ChoiceChip` 改成 `TabBar` 的页签（与「卡片信息显示」页一致），
  /// 所以这里按文案先找 `ChoiceChip`、找不到再找 `Tab` —— **只改"怎么定位控件"**，
  /// 本文件各用例的语义断言一个都没动。
  Future<void> tapChip(WidgetTester tester, String label) async {
    final chip = find.ancestor(
      of: find.text(label),
      matching: find.byType(ChoiceChip),
    );
    final tab = find.ancestor(of: find.text(label), matching: find.byType(Tab));
    await tester.tap(
      chip.evaluate().isNotEmpty ? chip.first : tab.first,
    );
    await tester.pumpAndSettle();
  }

  /// pump 页面并**显式**切到「禁漫 → 榜单」（点已选中 chip 是 no-op）。
  ///
  /// 画布给足高度：3 张 164dp 卡片 + 页尾按钮都要真正被 build 出来。
  Future<void> pumpRanking(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_exploreApp());
    await tester.pumpAndSettle();
    await tapChip(tester, '禁漫');
    await tapChip(tester, '榜单');
  }

  // ── 1. 不隐藏态：条目可见 + 「已屏蔽」标记 ──────────────────────────────────

  testWidgets('1a. settings[83]==0（不隐藏）：3 条都在列表中可见', (tester) async {
    setHideBlocked(false);
    final provider = installRankingFixture(page1: _page1Mixed);
    await pumpRanking(tester);

    // 首屏恰好一次请求（没有为凑列表额外翻页）。
    expect(provider.comicsRequests, hasLength(1));
    expect(provider.comicsRequests.single.continuation, isNull);

    // 三条都在列表里（可见态：屏蔽不是删除）。
    expect(find.byType(OnlineComicListItem), findsNWidgets(3),
        reason: '不隐藏时三条都要渲染');
    expect(find.text(kBlockedTitleA), findsOneWidget);
    expect(find.text(kBlockedTitleB), findsOneWidget);
    expect(find.text(kNormalTitle1), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('1b. settings[83]==0（不隐藏）：被屏蔽的两条带「已屏蔽：<词>」标记（验收要求）',
      (tester) async {
    // **该断言未通过**：`ExplorePage._buildRankBody` 对命中屏蔽词的条目只传
    // `highlighted: item.isBlocked`（0.45 透明度），**没有**传 `trailing`；而同一
    // 个控制器、同一张卡片在 `ExploreResultPage._buildList`
    // （lib/pages/explore/explore_result_page.dart:322）里是传了
    // `trailing: Text('已屏蔽：${item.blockedBy}')` 的。于是首页榜单页签上被屏蔽的
    // 条目只是"变淡"，用户看不到任何原因说明（两态里的"可见态"缺了可解释性）。
    // 按任务约定：不改断言、不改 lib/ 代码，保持失败并上报。
    setHideBlocked(false);
    installRankingFixture(page1: _page1Mixed);
    await pumpRanking(tester);

    expect(find.text('已屏蔽：$kBlockedWord'), findsNWidgets(2),
        reason: '被屏蔽的两条都要带「已屏蔽：<词>」说明');
  });

  // ── 2. 完全隐藏态：命中条目不再渲染 ─────────────────────────────────────────

  testWidgets('2. settings[83]==1（完全隐藏）：被屏蔽的两条不再渲染，正常那条仍可见', (tester) async {
    setHideBlocked(true);
    final provider = installRankingFixture(page1: _page1Mixed);
    await pumpRanking(tester);

    expect(provider.comicsRequests, hasLength(1));
    expect(find.byType(OnlineComicListItem), findsOneWidget,
        reason: '隐藏态只剩正常那一条');
    expect(find.text(kNormalTitle1), findsOneWidget);
    expect(find.text(kBlockedTitleA), findsNothing);
    expect(find.text(kBlockedTitleB), findsNothing);
    expect(find.textContaining('已屏蔽'), findsNothing,
        reason: '隐藏态不应再出现「已屏蔽」占位说明');
    expect(tester.takeException(), isNull);
  });

  // ── 3. 过滤后空页 + 仍有 next：不自动预取 ───────────────────────────────────

  testWidgets('3. 全部被屏蔽且仍有 next：不自动翻页，首屏只请求 1 次且页尾给「加载更多」', (tester) async {
    setHideBlocked(true);
    final provider = installRankingFixture(page1: _page1AllBlocked);
    await pumpRanking(tester);

    expect(provider.comicsRequests, hasLength(1), reason: '不得为了凑可见列表自动预取下一页');
    // 可见列表为空：两张卡片都不渲染。
    expect(find.byType(OnlineComicListItem), findsNothing);
    expect(find.text(kBlockedTitleA), findsNothing);
    expect(find.text(kBlockedTitleB), findsNothing);
    // 但"过滤后为空"不等于"没有内容"：不能显示空态，必须留真实的继续入口。
    expect(find.text('没有内容'), findsNothing);
    expect(find.text('加载更多'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // ── 4. 过滤后仍可继续真实 next ──────────────────────────────────────────────

  testWidgets('4. 过滤后空页仍能继续真实 next：点「加载更多」用 cursor-2 拿到第 2 页', (tester) async {
    setHideBlocked(true);
    final provider = installRankingFixture(page1: _page1AllBlocked);
    await pumpRanking(tester);
    expect(provider.comicsRequests, hasLength(1));

    await tester.tap(find.widgetWithText(OutlinedButton, '加载更多'));
    await tester.pumpAndSettle();

    // 第 2 次请求带的是**适配器游标**（Registry 解开的真实 cursor）。
    expect(provider.comicsRequests, hasLength(2));
    expect(provider.comicsRequests.last.continuation, 'cursor-2');
    expect(provider.comicsRequests.last.entryId, 'jm.ranking');
    expect(provider.comicsRequests.last.options.first, 'mv',
        reason: '续页必须原样带回首屏选项');

    // 第 2 页那条正常条目出现了。
    expect(find.text(kNormalTitle2), findsOneWidget);
    expect(find.byType(OnlineComicListItem), findsOneWidget);
    // 到末页：继续入口消失，被屏蔽的两条依旧不渲染。
    expect(find.text('加载更多'), findsNothing);
    expect(find.text(kBlockedTitleA), findsNothing);
    expect(find.text(kBlockedTitleB), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

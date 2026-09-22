import 'dart:async';
import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:picakeep/foundation/explore/explore_bindings.dart';
import 'package:picakeep/foundation/explore/explore_models.dart';
import 'package:picakeep/foundation/explore/explore_provider.dart';
import 'package:picakeep/foundation/explore/explore_registry.dart';
import 'package:picakeep/pages/explore/explore_category_panel.dart';
import 'package:picakeep/pages/explore/explore_result_page.dart';
import 'package:picakeep/tools/tags_translation.dart';

class _DirectoryProvider implements ExploreProvider {
  @override
  final descriptor = const ExploreSourceDescriptor(
    sourceKey: 'catalog',
    name: '示例源',
    entries: [
      ExploreEntry(id: 'home', label: '主页', kind: ExploreSectionKind.recommend),
      ExploreEntry(id: 'rank', label: '榜单', kind: ExploreSectionKind.ranking),
      ExploreEntry(
          id: 'categories', label: '分类', kind: ExploreSectionKind.category),
      ExploreEntry(id: 'tags', label: '标签', kind: ExploreSectionKind.category),
    ],
  );

  @override
  bool isLoggedIn = true;

  @override
  String contextFingerprint = 'account-1';

  final requests = <ExploreRequest>[];
  bool failCategories = false;
  Completer<ExploreResult<ExploreDirectory>>? pendingCategories;
  List<ExploreCategoryGroup> tags = const [
    ExploreCategoryGroup(id: 'themes', title: '主题', isSearch: true, items: [
      ExploreCategoryItem(
          id: 'landscape',
          label: '风景',
          isSearch: true,
          route: ExploreCategoryTarget(
              kind: 'search', value: 'landscape', optionId: 'theme')),
    ]),
  ];

  @override
  Future<ExploreResult<ExploreDirectory>> loadDirectory(
      ExploreRequest request) async {
    requests.add(request);
    if (request.entryId == 'categories') {
      if (pendingCategories != null) return pendingCategories!.future;
      if (failCategories) {
        return const ExploreFailure(
            ExploreError(ExploreErrorCode.network, '分类暂时不可用'));
      }
      return ExploreSuccess(ExploreDirectory(sourceKey: 'catalog', groups: [
        ExploreCategoryGroup(id: 'native', title: '作品类型', items: [
          ExploreCategoryItem(
              id: 'illustration',
              label: '插画 $contextFingerprint',
              route: const ExploreCategoryTarget(
                  kind: 'native', value: 'illustration')),
        ]),
      ]));
    }
    return ExploreSuccess(ExploreDirectory(sourceKey: 'catalog', groups: tags));
  }

  @override
  Future<ExploreResult<ExploreComicPage>> loadComics(
          ExploreRequest request) async =>
      ExploreSuccess(ExploreComicPage(
          sourceKey: 'catalog', entryId: request.entryId, items: const []));

  @override
  Future<ExploreResult<ExploreOverview>> loadOverview(
          ExploreRequest request) async =>
      ExploreSuccess(ExploreOverview(
          sourceKey: 'catalog', entryId: request.entryId, sections: const []));
}

void main() {
  late _DirectoryProvider provider;

  setUp(() {
    provider = _DirectoryProvider();
    final registry = ExploreRegistry()..register(provider);
    ExploreBindings.debugSetInstance(ExploreBindings.forTesting(registry));
  });

  tearDown(() => ExploreBindings.debugSetInstance(null));

  Future<void> pumpPanel(
    WidgetTester tester, {
    ValueChanged<ExploreEntry>? onSelectEntry,
    double textScale = 1,
    bool boldText = false,
    Locale? locale,
    ThemeData? theme,
  }) async {
    await tester.pumpWidget(MaterialApp(
      theme: theme,
      locale: locale,
      supportedLocales: const [Locale('en'), Locale('zh')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: Scaffold(
          body: ExploreCategoryPanel(
        sourceKey: 'catalog',
        onSelectEntry: onSelectEntry,
      )),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale), boldText: boldText),
        child: child!,
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('分类一次展开原生分类和主题分组，快捷入口返回原描述符', (tester) async {
    ExploreEntry? selected;
    await pumpPanel(tester, onSelectEntry: (entry) => selected = entry);

    expect(provider.requests.map((request) => request.entryId),
        ['categories', 'tags']);
    expect(find.text('作品类型'), findsOneWidget);
    expect(find.text('插画 account-1'), findsOneWidget);
    expect(find.text('主题'), findsOneWidget);
    expect(find.text('风景'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
    expect(find.byType(CustomScrollView), findsOneWidget);

    await tester.tap(find.text('排行榜'));
    expect(selected?.id, 'rank');
    await tester.tap(find.text('推荐'));
    expect(selected?.id, 'home');

    await tester.tap(find.text('风景'));
    await tester.pumpAndSettle();
    final result =
        tester.widget<ExploreResultPage>(find.byType(ExploreResultPage));
    expect(result.entryId, 'tags');
    expect(result.categoryId, 'landscape');
    expect(
        result.category,
        const ExploreCategoryTarget(
            kind: 'search', value: 'landscape', optionId: 'theme'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('单个目录失败仍显示其它分组，短页下拉也能刷新并恢复', (tester) async {
    provider.failCategories = true;
    await pumpPanel(tester);
    expect(find.text('分类暂时不可用'), findsOneWidget);
    expect(find.text('风景'), findsOneWidget);

    provider.failCategories = false;
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(provider.requests.length, 4);
    expect(find.text('分类暂时不可用'), findsNothing);
    expect(find.text('插画 account-1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('大量标签限量展示，但筛选能找到批次外的原始标签', (tester) async {
    provider.tags = [
      ExploreCategoryGroup(
        id: 'themes',
        title: '主题',
        isSearch: true,
        items: List.generate(
            200,
            (index) => ExploreCategoryItem(
                  id: 'tag-$index',
                  label: 'Topic $index',
                  isSearch: true,
                  route: ExploreCategoryTarget(
                      kind: 'search', value: 'Topic $index'),
                )),
      )
    ];
    await pumpPanel(tester);
    expect(find.text('Topic 0'), findsOneWidget);
    expect(find.text('Topic 150'), findsNothing);
    expect(find.byType(ElevatedButton).evaluate().length, lessThan(51),
        reason: '当前批次也仅创建视口附近的按钮行');
    await tester.enterText(find.byType(TextField), 'Topic 150');
    await tester.pumpAndSettle();
    expect(find.text('Topic 150'), findsNWidgets(2));
    expect(find.text('Topic 0'), findsNothing);
    expect(find.byType(ElevatedButton), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('未登录不加载目录；账号变更后不能展示旧账号的迟到结果', (tester) async {
    provider.isLoggedIn = false;
    await pumpPanel(tester);
    expect(provider.requests, isEmpty);
    expect(find.text('示例源 需要登录后才能浏览'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());

    provider.isLoggedIn = true;
    final pending = Completer<ExploreResult<ExploreDirectory>>();
    provider.pendingCategories = pending;
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: ExploreCategoryPanel(sourceKey: 'catalog'))));
    await tester.pump();
    provider.contextFingerprint = 'account-2';
    provider.pendingCategories = null;
    pending.complete(
        const ExploreSuccess(ExploreDirectory(sourceKey: 'catalog', groups: [
      ExploreCategoryGroup(id: 'old', title: '旧账号内容', items: [
        ExploreCategoryItem(id: 'old', label: '不应出现'),
      ]),
    ])));
    await tester.pumpAndSettle();
    expect(find.text('旧账号内容'), findsNothing);
    expect(find.text('不应出现'), findsNothing);
    expect(find.text('插画 account-2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏与大字体下长标签换行且不溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    provider.tags = const [
      ExploreCategoryGroup(
        id: 'themes',
        title: '很长的主题分组名称',
        isSearch: true,
        items: [
          ExploreCategoryItem(
              id: 'long',
              label: '一段比较长的分类标签名称用于验证按钮内容自动换行',
              route:
                  ExploreCategoryTarget(kind: 'search', value: 'long label')),
        ],
      )
    ];
    await pumpPanel(tester,
        textScale: 2, boldText: true, onSelectEntry: (_) {});
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('一段比较长的分类标签名称用于验证按钮内容自动换行'), findsOneWidget);
  });

  testWidgets('明确指定的推荐目录入口直接加载并保留原入口身份', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
          body: ExploreCategoryPanel(sourceKey: 'catalog', entryId: 'home')),
    ));
    await tester.pumpAndSettle();
    expect(provider.requests.map((request) => request.entryId), ['home']);
    expect(find.text('风景'), findsOneWidget);
    expect(find.text('该源没有分类目录'), findsNothing);
    await tester.tap(find.text('风景'));
    await tester.pumpAndSettle();
    final result =
        tester.widget<ExploreResultPage>(find.byType(ExploreResultPage));
    expect(result.entryId, 'home');
    expect(result.category?.value, 'landscape');
    expect(tester.takeException(), isNull);
  });

  testWidgets('EH式长分组按行回收按钮，屏内可访问性和深处入口仍可用', (tester) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final semantics = tester.ensureSemantics();
    try {
      String label(int group, int item) =>
          'Category $group item $item long label';
      provider.tags = [
        for (var group = 0; group < 4; group++)
          ExploreCategoryGroup(
            id: 'ns-$group',
            title: 'Namespace $group',
            isSearch: true,
            items: [
              for (var item = 0; item < 150; item++)
                ExploreCategoryItem(
                  id: '$group/$item',
                  label: label(group, item),
                  route: ExploreCategoryTarget(
                      kind: 'search', value: '$group/$item'),
                ),
            ],
          ),
      ];
      await pumpPanel(tester);
      expect(find.byType(ElevatedButton).evaluate().length, lessThan(30));
      expect(find.text(label(0, 49)), findsNothing);
      final first = find.widgetWithText(ElevatedButton, label(0, 0));
      expect(
          tester
              .getSemantics(first)
              .getSemanticsData()
              .hasAction(SemanticsAction.tap),
          isTrue);
      final titleWidget = tester.widget(find.text(label(0, 0)));
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -20));
      await tester.pumpAndSettle();
      expect(tester.widget(find.text(label(0, 0))), same(titleWidget),
          reason: '滚动约束变化不得重新创建已有按钮内容');
      await tester.scrollUntilVisible(find.text(label(2, 30)), 500,
          scrollable: find.byType(Scrollable).first, maxScrolls: 40);
      await tester.pumpAndSettle();
      expect(find.byType(ElevatedButton).evaluate().length, lessThan(30));
      expect(find.text(label(0, 20)), findsNothing);
      await tester.tap(find.text(label(2, 30)));
      await tester.pumpAndSettle();
      final result =
          tester.widget<ExploreResultPage>(find.byType(ExploreResultPage));
      expect(result.category?.value, '2/30');
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('换批与筛选在滚离再返回后仍保留，刷新也不重置输入', (tester) async {
    tester.view.physicalSize = const Size(390, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    provider.tags = [
      ExploreCategoryGroup(id: 'themes', title: '主题', items: [
        for (var i = 0; i < 200; i++)
          ExploreCategoryItem(id: '$i', label: 'Topic $i long title'),
      ]),
    ];
    await pumpPanel(tester);
    await tester.tap(find.byTooltip('换一批主题'));
    await tester.pumpAndSettle();
    expect(find.text('Topic 50 long title'), findsOneWidget);
    final position =
        tester.state<ScrollableState>(find.byType(Scrollable).first).position;
    position.jumpTo(1500);
    await tester.pumpAndSettle();
    position.jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.text('Topic 50 long title'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Topic 150');
    await tester.pumpAndSettle();
    expect(find.text('Topic 150 long title'), findsOneWidget);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        'Topic 150');
    expect(find.text('Topic 150 long title'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '不存在的词');
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的分类'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('翻译表就绪与宽度字号变化会重排，中文筛选保留原始路由', (tester) async {
    addTearDown(resetTagTranslationsForTesting);
    resetTagTranslationsForTesting();
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    provider.tags = [
      ExploreCategoryGroup(id: 'themes', title: '主题', isSearch: true, items: [
        for (var i = 0; i < 80; i++)
          ExploreCategoryItem(
              id: '$i',
              label: 'Landscape $i',
              groupId: 'tags',
              route:
                  ExploreCategoryTarget(kind: 'search', value: 'Landscape $i')),
      ]),
    ];
    await pumpPanel(tester, locale: const Locale('zh'));
    expect(find.text('Landscape 0'), findsOneWidget);
    setTagTranslationsForTesting({
      'tags': {'Landscape 0': '风景与自然观察', 'Landscape 70': '山林'}
    });
    tester.view.physicalSize = const Size(320, 800);
    await pumpPanel(tester, locale: const Locale('zh'), textScale: 2);
    expect(find.text('风景与自然观察'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '山林');
    await tester.pumpAndSettle();
    final button = find.widgetWithText(ElevatedButton, '山林');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<ExploreResultPage>(find.byType(ExploreResultPage))
            .category
            ?.value,
        'Landscape 70');
    expect(tester.takeException(), isNull);
  });

  testWidgets('分类和快捷按钮随主题及明暗模式更新，缓存行不保留旧配色', (tester) async {
    final backgrounds = <Color>{};
    for (final setting in [
      (Colors.purple, Brightness.light),
      (Colors.green, Brightness.light),
      (Colors.green, Brightness.dark),
    ]) {
      final scheme =
          ColorScheme.fromSeed(seedColor: setting.$1, brightness: setting.$2);
      await pumpPanel(tester,
          onSelectEntry: (_) {}, theme: ThemeData(colorScheme: scheme));
      Color? background(String label) => tester
          .widget<ElevatedButton>(find.widgetWithText(ElevatedButton, label))
          .style!
          .backgroundColor!
          .resolve({});
      final color = background('风景')!;
      backgrounds.add(color);
      expect(color, isNot(scheme.surfaceContainerLow), reason: '分类按钮有可辨识的主题底色');
      expect(background('排行榜'), color);
      expect(background('推荐'), color);
      expect(background('插画 account-1'), color);
      final foreground = tester
          .widget<ElevatedButton>(find.widgetWithText(ElevatedButton, '风景'))
          .style!
          .foregroundColor!
          .resolve({})!;
      final luminances = [
        color.computeLuminance(),
        foreground.computeLuminance()
      ]..sort();
      expect((luminances.last + .05) / (luminances.first + .05),
          greaterThanOrEqualTo(4.5));
    }
    expect(backgrounds, hasLength(3));
    expect(provider.requests, hasLength(2), reason: '主题切换不重新请求目录');
    expect(tester.takeException(), isNull);
  });
}

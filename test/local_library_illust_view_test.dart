/// 「图集页 → 插画视图」的**纯逻辑契约**：数据源判据、宽高降级、标签汇总与筛选。
///
/// ## 为什么要有这个文件
///
/// 这几条判据都是"错了不会报错、只会静默显示错内容"的类型：
///
/// - 按 id 前缀猜 Pixiv（而不是按 `sourceKey`）会让某些记录**静默消失**
///   （21 号文档的核心教训：Pixiv 与 Komiic 就是这么一路落到
///   `ScannedDownloadedComic`，源标签错、大小未知、作者不显示）；
/// - 宽高为 null 时如果没降级，会算出 `Infinity` 高度 → 布局直接崩；
/// - 标签汇总如果不稳定排序，同样的数据每次渲染顺序都不同。
///
/// 所以这些必须由测试盯住，而不是靠肉眼看 UI。
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/local_library_illust_view.dart';
import 'package:picakeep/foundation/local_library_settings.dart';
import 'package:picakeep/pages/local_library_illust_card.dart';
import 'package:picakeep/pages/local_library_illust_view.dart';

/// 造一条插画条目。`json` 列的内容就是 `CustomDownloadedItem.toJson()` 的形态。
LocalLibraryComicItem _item({
  required String id,
  required String sourceKey,
  String name = '作品',
  String author = '作者',
  List<String> tags = const <String>[],
  int? width,
  int? height,
  String? rawJson,
  double? comicSize,
  String? fileSystemPath,
}) {
  final json = rawJson ??
      '{"comicSize":$comicSize,"downloadedEps":[0],"chapters":null,'
          '"id":"$id","name":"$name","subTitle":"$author",'
          '"tags":${_jsonList(tags)},"sourceKey":"$sourceKey",'
          '"sourceName":"${sourceKey == 'pixiv' ? 'Pixiv' : sourceKey}",'
          '"cover":"","comicId":"$id",'
          '"width":${width ?? 'null'},"height":${height ?? 'null'}}';
  return LocalLibraryComicItem(
    itemId: 'local_download::current_download::$id',
    originalId: id,
    type: DownloadType.other,
    name: name,
    subTitle: author,
    tags: tags,
    sourceDisplayName: sourceKey,
    fileSystemPath: fileSystemPath ?? '/tmp/$id',
    episodeFiles: const <int, List<String>>{},
    downloadedEps: const <int>[0],
    eps: const <String>['全部'],
    localCoverPath: null,
    localStorageExists: true,
    canDelete: false,
    aliases: <String>[id],
    sourceRowJson: json,
  );
}

String _jsonList(List<String> values) =>
    '[${values.map((v) => '"$v"').join(',')}]';

void main() {
  group('瀑布流范围通知', () {
    final entries = buildIllustEntries([
      for (var i = 0; i < 30; i++)
        _item(id: 'pixiv-range-$i', sourceKey: 'pixiv'),
    ]);

    Widget harness(ScrollController controller, List<(int, int)> ranges) =>
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              controller: controller,
              cacheExtent: 0,
              slivers: [
                LocalLibraryIllustSlivers(
                  allEntries: entries,
                  entries: entries,
                  tags: const [],
                  selectedTags: const {},
                  loading: false,
                  errorText: null,
                  columns: 2,
                  itemBuilder: (_, entry) => SizedBox(
                    height: 1000,
                    child: Text(entry.id),
                  ),
                  onToggleTag: (_) {},
                  onClearTags: () {},
                  onLayoutRange: (first, last) => ranges.add((first, last)),
                ),
              ],
            ),
          ),
        );

    void setViewport(WidgetTester tester) {
      tester.view.physicalSize = const Size(390, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    testWidgets('实际滚动在相同条目内不重复通知，跨条目后通知', (tester) async {
      setViewport(tester);
      final controller = ScrollController();
      addTearDown(controller.dispose);
      final ranges = <(int, int)>[];
      await tester.pumpWidget(harness(controller, ranges));
      await tester.pumpAndSettle();
      expect(ranges, isNotEmpty);
      final initial = ranges.single;
      for (var i = 0; i < 3; i++) {
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -60));
        await tester.pumpAndSettle();
      }
      expect(controller.offset, greaterThan(100));
      expect(ranges, [initial], reason: '真实滑动产生的重复布局不应反复派发可见队列');

      controller.jumpTo(2200);
      await tester.pumpAndSettle();
      expect(ranges.length, 2);
      expect(ranges.last.$1, greaterThan(initial.$1));
      expect(ranges.last.$2, greaterThan(initial.$2));
    });

    testWidgets('同帧多次布局只通知最终范围，回到已发布范围不重发', (tester) async {
      setViewport(tester);
      final controller = ScrollController();
      addTearDown(controller.dispose);
      final ranges = <(int, int)>[];
      await tester.pumpWidget(harness(controller, ranges));
      await tester.pumpAndSettle();
      final delegate = tester
          .widget<SliverMasonryGrid>(
              find.byKey(LocalLibraryIllustSlivers.waterfallKey))
          .delegate;
      ranges.clear();
      delegate.didFinishLayout(4, 8);
      delegate.didFinishLayout(6, 10);
      delegate.didFinishLayout(8, 12);
      expect(ranges, isEmpty);
      tester.binding.scheduleFrame();
      await tester.pump();
      expect(ranges, [(8, 12)]);

      delegate.didFinishLayout(10, 14);
      delegate.didFinishLayout(8, 12);
      tester.binding.scheduleFrame();
      await tester.pump();
      expect(ranges, [(8, 12)]);
      delegate.didFinishLayout(8, 12);
      tester.binding.scheduleFrame();
      await tester.pump();
      expect(ranges, [(8, 12)]);
    });

    testWidgets('父重建的新 delegate 即使范围相同仍发首次通知', (tester) async {
      setViewport(tester);
      final controller = ScrollController();
      addTearDown(controller.dispose);
      final ranges = <(int, int)>[];
      await tester.pumpWidget(harness(controller, ranges));
      await tester.pumpAndSettle();
      final finder = find.byKey(LocalLibraryIllustSlivers.waterfallKey);
      final previousDelegate =
          tester.widget<SliverMasonryGrid>(finder).delegate;
      final previousRender = tester.renderObject(finder);
      final initial = ranges.single;

      await tester.pumpWidget(harness(controller, ranges));
      await tester.pumpAndSettle();
      expect(tester.widget<SliverMasonryGrid>(finder).delegate,
          isNot(same(previousDelegate)));
      expect(tester.renderObject(finder), same(previousRender),
          reason: '普通重建保留 59 号的相同条目布局');
      expect(ranges, [initial, initial], reason: '刷新清空工作队列后，相同范围也必须能重新调度');
    });
  });

  group('筛选变化后的瀑布流布局', () {
    for (final mode in [
      'subset',
      'prefix',
      'middle',
      'reverse',
      'tail',
      'first'
    ]) {
      for (final initialOffset in [0.0, 2300.0]) {
        testWidgets('$mode 在 $initialOffset 处过滤后没有沿用旧列偏移且末项可达', (tester) async {
          tester.view.physicalSize = const Size(390, 600);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final all = buildIllustEntries([
            for (var i = 0; i < 70; i++)
              _item(id: 'pixiv$i', sourceKey: 'pixiv'),
          ]);
          final heights = {
            for (var i = 0; i < all.length; i++)
              all[i].id: 80.0 + (i * 97 % 360),
          };
          final anchors = {for (final entry in all) entry.id: GlobalKey()};
          final shown = ValueNotifier(all);
          final controller = ScrollController();
          addTearDown(shown.dispose);
          addTearDown(controller.dispose);
          await tester.pumpWidget(MaterialApp(
            home: Scaffold(
              body: ValueListenableBuilder<List<IllustLibraryEntry>>(
                valueListenable: shown,
                builder: (context, entries, _) => CustomScrollView(
                  controller: controller,
                  slivers: [
                    LocalLibraryIllustSlivers(
                      allEntries: all,
                      entries: entries,
                      tags: const [],
                      selectedTags: const {},
                      loading: false,
                      errorText: null,
                      columns: 2,
                      itemBuilder: (_, entry) => KeyedSubtree(
                        key: anchors[entry.id],
                        child: SizedBox(
                          key: ValueKey('card-${entry.id}'),
                          height: heights[entry.id],
                          child: Text(entry.id),
                        ),
                      ),
                      onToggleTag: (_) {},
                      onClearTags: () {},
                    ),
                  ],
                ),
              ),
            ),
          ));
          await tester.pumpAndSettle();
          if (initialOffset != 0) {
            controller.jumpTo(initialOffset);
            await tester.pumpAndSettle();
          }
          final renderBefore = tester
              .renderObject(find.byKey(LocalLibraryIllustSlivers.waterfallKey));
          shown.value = [...all];
          await tester.pumpAndSettle();
          expect(
              tester.renderObject(
                  find.byKey(LocalLibraryIllustSlivers.waterfallKey)),
              same(renderBefore),
              reason: '普通重建不能丢弃瀑布流布局缓存');
          expect(controller.offset, closeTo(initialOffset, 0.1));

          // Remove the first item and many interior items, preserving identities
          // of survivors just as changing the selected download folder does.
          final filtered = switch (mode) {
            'prefix' => all.sublist(1),
            'middle' => [...all.take(3), ...all.skip(4)],
            'reverse' => all.reversed.toList(),
            'tail' => all.sublist(40, 46),
            'first' => [all.first, ...all.skip(30)],
            _ => [
                for (var i = 1; i < 44; i++)
                  if (i % 3 != 0) all[i],
              ],
          };
          shown.value = filtered;
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final expectedColumns = [0.0, 0.0];
          for (final entry in filtered) {
            final column = expectedColumns[0] <= expectedColumns[1] ? 0 : 1;
            final card = find.byKey(ValueKey('card-${entry.id}'));
            if (card.evaluate().isNotEmpty) {
              expect(tester.getTopLeft(card).dy + controller.offset,
                  closeTo(expectedColumns[column], 0.1),
                  reason: '筛选后仍在屏幕附近的 ${entry.id} 应使用新布局位置');
            }
            expectedColumns[column] += heights[entry.id]!;
          }
          controller.jumpTo(0);
          await tester.pumpAndSettle();
          for (final entry in filtered.take(2)) {
            expect(
              tester.getTopLeft(find.byKey(ValueKey('card-${entry.id}'))).dy,
              closeTo(0, 0.1),
              reason: '每列第一张作品应从顶部开始，不保留旧作品占用的空洞',
            );
          }

          final last = find.byKey(ValueKey('card-${filtered.last.id}'));
          for (var i = 0; i < 80; i++) {
            controller.jumpTo((controller.offset + 400)
                .clamp(0, controller.position.maxScrollExtent));
            await tester.pumpAndSettle();
            if (last.evaluate().isNotEmpty &&
                controller.position.extentAfter < 0.1) {
              break;
            }
          }
          expect(last, findsOneWidget, reason: '末项必须实际布局，不能提前到底');
          expect(
              tester
                  .getRect(last)
                  .overlaps(const Rect.fromLTWH(0, 0, 390, 600)),
              isTrue);
          final columnHeights = [0.0, 0.0];
          for (final entry in filtered) {
            final column = columnHeights[0] <= columnHeights[1] ? 0 : 1;
            columnHeights[column] += heights[entry.id]!;
          }
          final contentHeight = columnHeights.reduce((a, b) => a > b ? a : b);
          expect(controller.position.maxScrollExtent,
              closeTo(contentHeight + 96 - 600, 0.1),
              reason: '滚动范围应只由筛选后的作品高度决定');
          expect(tester.takeException(), isNull);
        });
      }
    }
  });

  test('页数直接来自下载数据库，旧目录不猜文件名或章节数', () {
    for (final path in ['/old/作品_p0', '/old/作品.zip', '/old/作品.jpg']) {
      final item = _item(
          id: 'pixiv1',
          sourceKey: 'pixiv',
          fileSystemPath: path,
          rawJson: '{"sourceKey":"pixiv","pageCount":2}');
      expect(buildIllustEntries([item]).single.pageCount, 2);
    }
    final invalid = _item(
        id: 'pixiv1',
        sourceKey: 'pixiv',
        rawJson: '{"sourceKey":"pixiv","pageCount":0}');
    expect(buildIllustEntries([invalid]).single.pageCount, isNull);
  });
  test(
      'single image artifacts have an immediate page count without filesystem IO',
      () {
    for (final extension in ['JPG', 'jpeg', 'png', 'gif', 'webp']) {
      final item = _item(
          id: 'pixiv1',
          sourceKey: 'pixiv',
          fileSystemPath: '/not-existing/作品.$extension');
      expect(buildIllustEntries([item]).single.pageCount, 1);
    }
    for (final path in [
      '/not-existing/作品_p2',
      '/not-existing/作品_p2.zip',
      '/not-existing/作品.cbz'
    ]) {
      final item =
          _item(id: 'pixiv1', sourceKey: 'pixiv', fileSystemPath: path);
      expect(buildIllustEntries([item]).single.pageCount, isNull,
          reason: 'Do not infer a directory/archive count from its filename');
    }
  });

  group('插画视图设置项归一化', () {
    test('视图：只认 illust，其余落回 album（默认与改动前一致）', () {
      expect(normalizeIllustLibraryView('illust'), 'illust');
      expect(normalizeIllustLibraryView('album'), 'album');
      expect(normalizeIllustLibraryView(null), 'album');
      expect(normalizeIllustLibraryView(''), 'album');
      expect(normalizeIllustLibraryView('ILLUST'), 'album');
      expect(normalizeIllustLibraryView('啥都不是'), 'album');
      expect(
        illustLibraryViewFromSetting('illust'),
        IllustLibraryView.illust,
      );
      expect(
        illustLibraryViewFromSetting('album'),
        IllustLibraryView.album,
      );
      expect(illustLibraryViewToSetting(IllustLibraryView.illust), 'illust');
      expect(illustLibraryViewToSetting(IllustLibraryView.album), 'album');
    });

    test('瀑布流列数：夹到 2..3，脏值落回默认 3', () {
      expect(normalizeIllustWaterfallColumns('2'), 2);
      expect(normalizeIllustWaterfallColumns('3'), 3);
      expect(normalizeIllustWaterfallColumns('1'), 2);
      expect(normalizeIllustWaterfallColumns('0'), 2);
      expect(normalizeIllustWaterfallColumns('9'), 3);
      expect(normalizeIllustWaterfallColumns('-1'), 2);
      expect(
        normalizeIllustWaterfallColumns(null),
        illustWaterfallDefaultColumns,
      );
      expect(
        normalizeIllustWaterfallColumns('abc'),
        illustWaterfallDefaultColumns,
      );
      // 写回 settings 的形态必须是字符串（settings 是 List<String>）。
      expect(normalizeIllustWaterfallColumnsSetting('2'), '2');
      expect(normalizeIllustWaterfallColumnsSetting('999'), '3');
      expect(normalizeIllustWaterfallColumnsSetting(null), '3');
    });

    test('悬浮按钮位置：只认 left，其余靠右（= Flutter FAB 默认位）', () {
      expect(normalizeIllustViewSwitcherPosition('left'), 'left');
      expect(normalizeIllustViewSwitcherPosition('right'), 'right');
      expect(normalizeIllustViewSwitcherPosition(null), 'right');
      expect(normalizeIllustViewSwitcherPosition('LEFT'), 'right');
      expect(illustViewSwitcherAlignsLeft('left'), isTrue);
      expect(illustViewSwitcherAlignsLeft(null), isFalse);
    });

    test('新设置项下标不落在 152/153/154 上（否则会顶掉 23 号计划占位）', () {
      expect(illustLibraryViewSettingIndex, greaterThanOrEqualTo(155));
      expect(illustWaterfallColumnsSettingIndex, greaterThan(155));
      expect(illustViewSwitcherPositionSettingIndex, greaterThan(155));
      expect(
        <int>{
          illustLibraryViewSettingIndex,
          illustWaterfallColumnsSettingIndex,
          illustViewSwitcherPositionSettingIndex,
        }.length,
        3,
      );
    });
  });

  group('插画过滤判据：sourceKey == pixiv', () {
    test('只取 pixiv，其它源一律不纳入', () {
      final items = <LocalLibraryComicItem>[
        _item(id: 'pixiv1', sourceKey: 'pixiv', name: '插画一'),
        _item(id: 'pixiv2', sourceKey: 'pixiv', name: '插画二'),
        _item(id: 'jm1', sourceKey: 'jm'),
        _item(id: 'picacg1', sourceKey: 'picacg'),
        _item(id: 'eh1', sourceKey: 'ehentai'),
        _item(id: 'nh1', sourceKey: 'nhentai'),
        _item(id: 'k1', sourceKey: 'Komiic'),
      ];
      final entries = buildIllustEntries(items);
      expect(entries.map((e) => e.originalId).toList(),
          <String>['pixiv1', 'pixiv2']);
    });

    test('不按 id 前缀猜：id 带 pixiv 前缀但 sourceKey 不是 pixiv 的不纳入', () {
      final entries = buildIllustEntries(<LocalLibraryComicItem>[
        // 这是关键的"反向"用例：id 长得像 Pixiv，但 json 里的 sourceKey 说不是。
        // 按前缀猜的实现会把它误收进来（21 号文档教训的反面）。
        _item(id: 'pixiv99999', sourceKey: 'jm'),
      ]);
      expect(entries, isEmpty);
    });

    test('sourceKey 缺失 / json 是坏数据 → 跳过而不是猜', () {
      final entries = buildIllustEntries(<LocalLibraryComicItem>[
        _item(id: 'pixiv1', sourceKey: 'pixiv'),
        _item(id: 'noKey', sourceKey: 'x', rawJson: '{"id":"noKey"}'),
        _item(id: 'badJson', sourceKey: 'x', rawJson: '不是 json'),
        _item(id: 'emptyJson', sourceKey: 'x', rawJson: ''),
      ]);
      expect(entries.map((e) => e.originalId).toList(), <String>['pixiv1']);
    });

    test('sourceKey 前后空白不影响判定（trim 后比较）', () {
      final entries = buildIllustEntries(<LocalLibraryComicItem>[
        _item(id: 'pixiv1', sourceKey: 'pixiv'),
      ]);
      expect(entries, hasLength(1));
      final trimmed = buildIllustEntries(<LocalLibraryComicItem>[
        _item(
          id: 'pixiv2',
          sourceKey: 'x',
          rawJson: '{"id":"pixiv2","sourceKey":" pixiv "}',
        ),
      ]);
      expect(trimmed, hasLength(1));
    });

    test('空输入不抛异常', () {
      expect(buildIllustEntries(const <LocalLibraryComicItem>[]), isEmpty);
    });
  });

  group('宽高降级：缺失不走 height=0 也不除零', () {
    test('正常宽高用真实比例', () {
      expect(illustAspectRatioForSize(1200, 1600), closeTo(0.75, 1e-9));
      expect(illustAspectRatioForSize(1600, 1200), closeTo(4 / 3, 1e-9));
    });

    test('null / 0 / 负数一律降级为占位比例，且恒为正有限数', () {
      for (final pair in const <List<int?>>[
        <int?>[null, null],
        <int?>[null, 1600],
        <int?>[1200, null],
        <int?>[0, 0],
        <int?>[0, 1600],
        <int?>[1200, 0],
        <int?>[-5, 100],
        <int?>[100, -5],
      ]) {
        final ratio = illustAspectRatioForSize(pair[0], pair[1]);
        expect(
          ratio,
          illustFallbackAspectRatio,
          reason: 'width=${pair[0]} height=${pair[1]} 应降级',
        );
        expect(ratio.isFinite, isTrue);
        expect(ratio, greaterThan(0));
      }
    });

    test('极端长条被夹住，绝不会算出 0 或无穷高度', () {
      expect(illustAspectRatioForSize(1, 20000), greaterThan(0));
      expect(illustAspectRatioForSize(1, 20000), closeTo(1 / 5, 1e-9));
      expect(illustAspectRatioForSize(20000, 1), closeTo(5.0, 1e-9));
      for (final ratio in <double>[
        illustAspectRatioForSize(1, 20000),
        illustAspectRatioForSize(20000, 1),
      ]) {
        // 卡片高度 = 列宽 / ratio：ratio 有限且 > 0 时高度才有限。
        expect((1 / ratio).isFinite, isTrue);
      }
    });

    test('条目侧：json 里 width/height 缺失时条目仍被收录且比例可用', () {
      final entries = buildIllustEntries(<LocalLibraryComicItem>[
        _item(id: 'pixivOld', sourceKey: 'pixiv'), // 老记录：没有宽高键
      ]);
      expect(entries, hasLength(1));
      expect(entries.single.width, isNull);
      expect(entries.single.height, isNull);
      expect(entries.single.aspectRatio, illustFallbackAspectRatio);
    });

    test('条目侧：JSON 往返后宽高退化成 double 也能读出来', () {
      final entries = buildIllustEntries(<LocalLibraryComicItem>[
        _item(
          id: 'pixivDouble',
          sourceKey: 'pixiv',
          rawJson: '{"id":"pixivDouble","sourceKey":"pixiv",'
              '"width":1200.0,"height":1600.0}',
        ),
      ]);
      expect(entries.single.width, 1200);
      expect(entries.single.height, 1600);
      expect(entries.single.aspectRatio, closeTo(0.75, 1e-9));
    });

    test('条目侧：width 是 0 时降级（不能被当成"比例为 0"）', () {
      final entries = buildIllustEntries(<LocalLibraryComicItem>[
        _item(
          id: 'pixivZero',
          sourceKey: 'pixiv',
          rawJson: '{"id":"pixivZero","sourceKey":"pixiv",'
              '"width":0,"height":0}',
        ),
      ]);
      expect(entries.single.width, isNull);
      expect(entries.single.aspectRatio, illustFallbackAspectRatio);
    });
  });

  group('标签汇总与筛选', () {
    List<IllustLibraryEntry> entriesWithTags(List<List<String>> tagGroups) {
      return buildIllustEntries(<LocalLibraryComicItem>[
        for (var i = 0; i < tagGroups.length; i++)
          _item(
            id: 'pixiv$i',
            sourceKey: 'pixiv',
            tags: tagGroups[i],
          ),
      ]);
    }

    test('汇总去重 + 按出现次数降序，次数相同按名字升序（顺序稳定）', () {
      final entries = entriesWithTags(<List<String>>[
        <String>['オリジナル', '女の子'],
        <String>['オリジナル', '風景'],
        <String>['オリジナル'],
      ]);
      final tags = summarizeIllustTags(entries);
      expect(tags.map((t) => t.tag).toList(), <String>['オリジナル', '女の子', '風景']);
      expect(tags.map((t) => t.count).toList(), <int>[3, 1, 1]);
    });

    test('同一条目内重复标签只算一次', () {
      final entries = entriesWithTags(<List<String>>[
        <String>['A', 'A', 'A'],
      ]);
      final tags = summarizeIllustTags(entries);
      expect(tags, hasLength(1));
      expect(tags.single.count, 1);
    });

    test('空标签 / 纯空白标签不进汇总', () {
      final entries = entriesWithTags(<List<String>>[
        <String>['', '   ', '有效'],
      ]);
      final tags = summarizeIllustTags(entries);
      expect(tags.map((t) => t.tag).toList(), <String>['有效']);
    });

    test('无标签时汇总为空（图集侧也不会因此出现空筛选条）', () {
      expect(summarizeIllustTags(entriesWithTags(<List<String>>[])), isEmpty);
      expect(
        summarizeIllustTags(entriesWithTags(<List<String>>[<String>[]])),
        isEmpty,
      );
    });

    test('选中一个标签 → 只留含它的条目', () {
      final entries = entriesWithTags(<List<String>>[
        <String>['A', 'B'],
        <String>['A'],
        <String>['B'],
      ]);
      final filtered =
          filterIllustEntriesByTags(entries, <String>{'A'}).toList();
      expect(filtered.map((e) => e.originalId).toList(),
          <String>['pixiv0', 'pixiv1']);
    });

    test('多选是 AND：越多标签结果越少（与"筛选"直觉一致）', () {
      final entries = entriesWithTags(<List<String>>[
        <String>['A', 'B'],
        <String>['A'],
        <String>['B'],
      ]);
      final filtered =
          filterIllustEntriesByTags(entries, <String>{'A', 'B'}).toList();
      expect(filtered.map((e) => e.originalId).toList(), <String>['pixiv0']);
    });

    test('清空选择 → 恢复全量', () {
      final entries = entriesWithTags(<List<String>>[
        <String>['A'],
        <String>['B'],
      ]);
      final filtered =
          filterIllustEntriesByTags(entries, const <String>{}).toList();
      expect(filtered, hasLength(2));
    });

    test('无匹配 → 结果为空（交给 noTagMatch 空态）', () {
      final entries = entriesWithTags(<List<String>>[
        <String>['A'],
      ]);
      expect(filterIllustEntriesByTags(entries, <String>{'不存在'}), isEmpty);
    });

    test('标签来自 item.tags；item.tags 为空时回落到 json 里的 tags', () {
      final fromJson = buildIllustEntries(<LocalLibraryComicItem>[
        _item(
          id: 'pixivJson',
          sourceKey: 'pixiv',
          rawJson: '{"id":"pixivJson","sourceKey":"pixiv","tags":["来自json"]}',
        ),
      ]);
      expect(fromJson.single.tags, <String>['来自json']);
    });
  });

  group('三种空态要分开（不能共用"没有内容"）', () {
    test('加载中：转圈', () {
      expect(
        resolveIllustContentState(
            loading: true, totalCount: 0, filteredCount: 0),
        IllustContentState.loading,
      );
    });

    test('没有内容：空态（不是转圈）', () {
      expect(
        resolveIllustContentState(
            loading: false, totalCount: 0, filteredCount: 0),
        IllustContentState.empty,
      );
    });

    test('筛选无匹配：与"没有内容"是**不同**状态', () {
      final state = resolveIllustContentState(
          loading: false, totalCount: 5, filteredCount: 0);
      expect(state, IllustContentState.noTagMatch);
      expect(state, isNot(IllustContentState.empty));
    });

    test('有数据就渲染内容（后台刷新不把列表换成转圈）', () {
      expect(
        resolveIllustContentState(
            loading: true, totalCount: 5, filteredCount: 5),
        IllustContentState.content,
      );
      expect(
        resolveIllustContentState(
            loading: false, totalCount: 5, filteredCount: 3),
        IllustContentState.content,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // 以下为**真实渲染**断言（计划验收标准 2 要求"布局类要做实际渲染断言，
  // 不要只测常量"）。这里渲染的是生产控件 `LocalLibraryIllustSlivers`
  // 与 `IllustCard` 本身，不是测试副本。
  // ---------------------------------------------------------------------------
  group('瀑布流真实渲染：列数与变高', () {
    /// 把插画 sliver 挂进真实的 `CustomScrollView`（与页面里的结构一致）。
    Widget harness({
      required List<IllustLibraryEntry> all,
      required List<IllustLibraryEntry> shown,
      List<IllustTagSummary> tags = const <IllustTagSummary>[],
      Set<String> selected = const <String>{},
      bool loading = false,
      int columns = 3,
    }) {
      return MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              LocalLibraryIllustSlivers(
                allEntries: all,
                entries: shown,
                tags: tags,
                selectedTags: selected,
                loading: loading,
                errorText: null,
                columns: columns,
                itemBuilder: (context, entry) => IllustCard(
                  entry: entry,
                  imageProvider: null, // 无封面 → 走占位分支，不触发真实 IO
                  onTap: () {},
                  onLongPress: () {},
                ),
                onToggleTag: (_) {},
                onClearTags: () {},
              ),
            ],
          ),
        ),
      );
    }

    List<IllustLibraryEntry> entriesWithRatios(List<double> ratios) {
      return buildIllustEntries(<LocalLibraryComicItem>[
        for (var i = 0; i < ratios.length; i++)
          _item(
            id: 'pixiv$i',
            sourceKey: 'pixiv',
            name: '作品$i',
            // 比例 = width / height；用 1000 宽做基准反推高度。
            width: 1000,
            height: (1000 / ratios[i]).round(),
          ),
      ]);
    }

    testWidgets('列数设置真的作用到 SliverMasonryGrid（2 列 / 3 列各断言一次）', (tester) async {
      final entries = entriesWithRatios(<double>[0.75, 0.75, 0.75]);

      for (final columns in <int>[2, 3]) {
        await tester.pumpWidget(
          harness(all: entries, shown: entries, columns: columns),
        );
        await tester.pump();

        final grid = tester.widget<SliverMasonryGrid>(
          find.byKey(LocalLibraryIllustSlivers.waterfallKey),
        );
        expect(
          grid.gridDelegate,
          isA<SliverSimpleGridDelegateWithFixedCrossAxisCount>(),
        );
        expect(
          (grid.gridDelegate as SliverSimpleGridDelegateWithFixedCrossAxisCount)
              .crossAxisCount,
          columns,
        );
        // 布局真的发生了：SliverMasonryGrid 产出了非零 geometry。
        final box = tester.renderObject<RenderSliver>(
          find.byKey(LocalLibraryIllustSlivers.waterfallKey),
        );
        expect(box.geometry!.paintExtent, greaterThan(0));
      }
    });

    testWidgets('同一列宽下，不同比例渲染出不同高度（瀑布流不是定高网格）', (tester) async {
      // 一张竖图 + 一张方图。定高网格下两者等高；瀑布流下高度必须不同。
      final entries = entriesWithRatios(<double>[0.5, 1.0]);
      await tester.pumpWidget(harness(all: entries, shown: entries));
      await tester.pump();

      final heights = <double>[];
      for (final entry in entries) {
        final card = find.byWidgetPredicate(
          (w) => w is IllustCard && w.entry.id == entry.id,
        );
        expect(card, findsOneWidget);
        heights.add(tester.getSize(card).height);
      }
      expect(
        heights.first,
        isNot(closeTo(heights.last, 0.5)),
        reason: '0.5 与 1.0 两种比例必须渲染出不同高度，否则不是瀑布流',
      );
      // 比例小（更竖）的卡片更高。
      expect(heights.first, greaterThan(heights.last));
    });

    testWidgets('卡片近无边框：留白显著小于定高网格的观感（≤ 4dp）', (tester) async {
      final entries = entriesWithRatios(<double>[0.75]);
      await tester.pumpWidget(harness(all: entries, shown: entries));
      await tester.pump();
      final card = find.byType(IllustCard);
      final outer = tester.getSize(card);
      final image = tester.getSize(
        find.descendant(of: card, matching: find.byType(AspectRatio)),
      );
      // 图片宽度 = 卡片宽度 - 左右各 illustCardGap。
      expect(outer.width - image.width, closeTo(illustCardGap * 2, 0.5));
      expect(illustCardGap, lessThanOrEqualTo(4));
    });

    testWidgets('没有封面时渲染占位图标而不是抛异常（特权模式下 provider 可能为 null）', (tester) async {
      final entries = entriesWithRatios(<double>[0.75]);
      await tester.pumpWidget(harness(all: entries, shown: entries));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.image_not_supported_outlined), findsOneWidget);
    });

    testWidgets('信息在底部：标题与作者渲染在图片下方，且各自一行（文字 top ≥ 图片 bottom）', (tester) async {
      final entries = buildIllustEntries(<LocalLibraryComicItem>[
        _item(
          id: 'pixiv1',
          sourceKey: 'pixiv',
          name: '标题在这里',
          author: '作者在这里',
        ),
      ]);
      await tester.pumpWidget(harness(all: entries, shown: entries));
      await tester.pump();
      final card = find.byType(IllustCard);
      final imageRect = tester.getRect(
        find.descendant(of: card, matching: find.byType(AspectRatio)),
      );
      // 32 号起信息块是**一个** `Text.rich`（字段顺序与分隔符可配，
      // 换行分隔符与 `-` 分隔符都由同一份拼接结果渲染），所以这里按富文本取值，
      // 不能再 `find.text('标题在这里')` —— `Text.rich` 的 `data` 是 null。
      final infoFinder = find.descendant(
        of: card,
        matching: find.byType(Text),
      );
      expect(infoFinder, findsOneWidget);
      final info = tester.widget<Text>(infoFinder);
      // 默认配置（标题 + 换行 + 作者）—— 与改动前的观感一致
      expect(info.textSpan!.toPlainText(), '标题在这里\n作者在这里');
      expect(info.maxLines, 2);
      expect(
        tester.getRect(infoFinder).top,
        greaterThanOrEqualTo(imageRect.bottom - 0.5),
      );
    });
  });

  group('内容区三种状态的真实渲染', () {
    Widget harness({
      required List<IllustLibraryEntry> all,
      required List<IllustLibraryEntry> shown,
      bool loading = false,
    }) {
      return MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              LocalLibraryIllustSlivers(
                allEntries: all,
                entries: shown,
                tags: const <IllustTagSummary>[],
                selectedTags: const <String>{},
                loading: loading,
                errorText: null,
                columns: 3,
                itemBuilder: (context, entry) => IllustCard(
                  entry: entry,
                  imageProvider: null,
                  onTap: () {},
                  onLongPress: () {},
                ),
                onToggleTag: (_) {},
                onClearTags: () {},
              ),
            ],
          ),
        ),
      );
    }

    testWidgets('加载中只转圈，且不出现两类空态文案', (tester) async {
      await tester.pumpWidget(harness(
        all: const <IllustLibraryEntry>[],
        shown: const <IllustLibraryEntry>[],
        loading: true,
      ));
      await tester.pump();
      expect(find.byKey(LocalLibraryIllustSlivers.loadingKey), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byKey(LocalLibraryIllustSlivers.emptyKey), findsNothing);
      expect(
        find.byKey(LocalLibraryIllustSlivers.noTagMatchKey),
        findsNothing,
      );
      // 加载态下不渲染瀑布流（避免出现"网格 + 转圈"叠着）。
      expect(find.byKey(LocalLibraryIllustSlivers.waterfallKey), findsNothing);
    });

    testWidgets('没有内容：显示"暂无插画"，且不是转圈', (tester) async {
      await tester.pumpWidget(harness(
        all: const <IllustLibraryEntry>[],
        shown: const <IllustLibraryEntry>[],
      ));
      await tester.pump();
      expect(find.byKey(LocalLibraryIllustSlivers.emptyKey), findsOneWidget);
      expect(find.text('暂无插画'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('筛选无匹配：走**另一个**空态，不是"没有内容"', (tester) async {
      final all = buildIllustEntries(<LocalLibraryComicItem>[
        _item(id: 'pixiv1', sourceKey: 'pixiv', tags: <String>['A']),
      ]);
      await tester.pumpWidget(harness(
        all: all,
        shown: const <IllustLibraryEntry>[],
      ));
      await tester.pump();
      expect(
        find.byKey(LocalLibraryIllustSlivers.noTagMatchKey),
        findsOneWidget,
      );
      expect(find.text('没有匹配的作品'), findsOneWidget);
      expect(find.byKey(LocalLibraryIllustSlivers.emptyKey), findsNothing);
      expect(find.text('暂无插画'), findsNothing);
    });
  });

  group('标签筛选条真实渲染', () {
    Widget harness({
      required List<IllustLibraryEntry> all,
      required List<IllustLibraryEntry> shown,
      required List<IllustTagSummary> tags,
      required Set<String> selected,
      void Function(String)? onToggle,
      void Function()? onClear,
    }) {
      return MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              LocalLibraryIllustSlivers(
                allEntries: all,
                entries: shown,
                tags: tags,
                selectedTags: selected,
                loading: false,
                errorText: null,
                columns: 3,
                itemBuilder: (context, entry) => IllustCard(
                  entry: entry,
                  imageProvider: null,
                  onTap: () {},
                  onLongPress: () {},
                ),
                onToggleTag: onToggle ?? (_) {},
                onClearTags: onClear ?? () {},
              ),
            ],
          ),
        ),
      );
    }

    testWidgets('汇总出的每个标签都渲染成可点芯片，并带出现次数', (tester) async {
      final entries = buildIllustEntries(<LocalLibraryComicItem>[
        _item(id: 'pixiv1', sourceKey: 'pixiv', tags: <String>['オリジナル']),
        _item(id: 'pixiv2', sourceKey: 'pixiv', tags: <String>['オリジナル']),
        _item(id: 'pixiv3', sourceKey: 'pixiv', tags: <String>['風景']),
      ]);
      final tags = summarizeIllustTags(entries);
      await tester.pumpWidget(harness(
        all: entries,
        shown: entries,
        tags: tags,
        selected: const <String>{},
      ));
      await tester.pump();
      expect(
        find.byKey(LocalLibraryIllustSlivers.tagFilterBarKey),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('illust-tag-オリジナル')), findsOneWidget);
      expect(find.byKey(const ValueKey('illust-tag-風景')), findsOneWidget);
      expect(find.text('オリジナル (2)'), findsOneWidget);
      expect(find.text('風景 (1)'), findsOneWidget);
    });

    testWidgets('点标签会回调；未选中时不出现清除按钮', (tester) async {
      final entries = buildIllustEntries(<LocalLibraryComicItem>[
        _item(id: 'pixiv1', sourceKey: 'pixiv', tags: <String>['A']),
      ]);
      String? toggled;
      await tester.pumpWidget(harness(
        all: entries,
        shown: entries,
        tags: summarizeIllustTags(entries),
        selected: const <String>{},
        onToggle: (tag) => toggled = tag,
      ));
      await tester.pump();
      expect(find.byTooltip('清除筛选'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('illust-tag-A')));
      await tester.pump();
      expect(toggled, 'A');
    });

    testWidgets('有选中标签时出现清除入口，点它会回调清除', (tester) async {
      final entries = buildIllustEntries(<LocalLibraryComicItem>[
        _item(id: 'pixiv1', sourceKey: 'pixiv', tags: <String>['A']),
      ]);
      var cleared = false;
      await tester.pumpWidget(harness(
        all: entries,
        shown: entries,
        tags: summarizeIllustTags(entries),
        selected: const <String>{'A'},
        onClear: () => cleared = true,
      ));
      await tester.pump();
      final clearButton = find.byTooltip('清除筛选');
      expect(clearButton, findsOneWidget);
      await tester.tap(clearButton);
      await tester.pump();
      expect(cleared, isTrue);
    });

    testWidgets('筛选后只渲染筛过的条目（真渲染数量而非只测列表长度）', (tester) async {
      final all = buildIllustEntries(<LocalLibraryComicItem>[
        _item(id: 'pixiv1', sourceKey: 'pixiv', tags: <String>['A']),
        _item(id: 'pixiv2', sourceKey: 'pixiv', tags: <String>['B']),
      ]);
      final shown = filterIllustEntriesByTags(all, <String>{'A'}).toList();
      await tester.pumpWidget(harness(
        all: all,
        shown: shown,
        tags: summarizeIllustTags(all),
        selected: const <String>{'A'},
      ));
      await tester.pump();
      expect(find.byType(IllustCard), findsOneWidget);
    });

    testWidgets('图集视图不显示筛选条：无标签时不渲染筛选条', (tester) async {
      // 图集条目 tags 恒为空数组（调研 §2.1），所以图集侧根本汇总不出标签
      // → 筛选条不渲染。这就是"图集侧不显示筛选入口"在实现上的落点。
      final albumLike = buildIllustEntries(const <LocalLibraryComicItem>[]);
      await tester.pumpWidget(harness(
        all: albumLike,
        shown: albumLike,
        tags: summarizeIllustTags(albumLike),
        selected: const <String>{},
      ));
      await tester.pump();
      expect(
        find.byKey(LocalLibraryIllustSlivers.tagFilterBarKey),
        findsNothing,
      );
    });
  });

  group('视图切换按钮的显示判据（含与多选 FAB 的互斥）', () {
    bool show({
      bool albumOnly = true,
      bool isLocalRootPage = false,
      bool isRemoteRootPage = false,
      bool selecting = false,
      bool operationRunning = false,
    }) {
      return shouldShowIllustViewSwitcher(
        albumOnly: albumOnly,
        isLocalRootPage: isLocalRootPage,
        isRemoteRootPage: isRemoteRootPage,
        selecting: selecting,
        operationRunning: operationRunning,
      );
    }

    test('图集根列表：显示', () {
      expect(show(), isTrue);
    });

    test('多选态：不显示（与多选 FAB 互斥）', () {
      expect(show(selecting: true), isFalse);
    });

    test('操作进行中（删除遮罩）：不显示', () {
      expect(show(operationRunning: true), isFalse);
    });

    test('非图集形态（资源库）：不显示', () {
      expect(show(albumOnly: false), isFalse);
    });

    test('子页面（本地目录内 / 远程根内）：不显示 —— 与 _showSourceSelector 同口径', () {
      expect(show(isLocalRootPage: true), isFalse);
      expect(show(isRemoteRootPage: true), isFalse);
    });

    test('多个条件同时为真也只是不显示（不抛异常）', () {
      expect(
        show(
          albumOnly: false,
          isLocalRootPage: true,
          isRemoteRootPage: true,
          selecting: true,
          operationRunning: true,
        ),
        isFalse,
      );
    });
  });

  group('档位独立（决策 3 的核心：两个档位分别持久化，互不覆盖）', () {
    test('视图设置项与图集档位设置项是两个不同的下标', () {
      // 这是决策 3 的硬约束：**不要复用 settings[104]**。
      // 用同一格会让"图集侧切到聚合档 → 去插画视图 → 切回来"丢掉聚合档。
      expect(illustLibraryViewSettingIndex, isNot(104));
      expect(
        illustLibraryViewSettingIndex,
        isNot(localLibraryViewSettingIndex),
      );
    });

    test('视图与档位的取值空间不重叠（一个是 album/illust，一个是 local/aggregate/remote）', () {
      for (final view in IllustLibraryView.values) {
        final raw = illustLibraryViewToSetting(view);
        // 若某天有人把插画塞进 normalizeLocalLibraryView，这里会立刻炸：
        // 'illust' 会被归一化成 'local'，于是视图选择永远存不下来。
        expect(normalizeLocalLibraryView(raw), 'local');
        expect(raw, isNot('local'));
        expect(raw, isNot('aggregate'));
        expect(raw, isNot('remote'));
      }
    });

    test('模拟两侧独立切换：图集侧保持"聚合"，插画侧自己的状态不被互相覆盖', () {
      // 用一个假的 settings 数组模拟 appdata.settings。
      final settings = List<String>.filled(160, '0', growable: true);
      settings[localLibraryViewSettingIndex] = 'aggregate'; // 图集侧选了聚合

      // 切到插画视图：只写视图格。
      settings[illustLibraryViewSettingIndex] =
          illustLibraryViewToSetting(IllustLibraryView.illust);
      expect(
        illustLibraryViewFromSetting(settings[illustLibraryViewSettingIndex]),
        IllustLibraryView.illust,
      );
      expect(
        normalizeLocalLibraryView(settings[localLibraryViewSettingIndex]),
        'aggregate',
        reason: '切视图不得改写图集侧档位 settings[104]',
      );

      // 切回图集视图：图集侧仍是聚合。
      settings[illustLibraryViewSettingIndex] =
          illustLibraryViewToSetting(IllustLibraryView.album);
      expect(
        normalizeLocalLibraryView(settings[localLibraryViewSettingIndex]),
        'aggregate',
        reason: '来回切换后图集侧档位必须原样保留',
      );
    });
  });
}

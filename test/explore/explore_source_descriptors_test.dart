/// 四源探索能力**静态声明**的契约测试。
///
/// 本文件只读 `<Xxx>ExploreProvider.descriptorOf` 静态常量，**绝不构造 provider
/// 实例**：构造会创建真实网络单例（`JmNetwork()` 需要 `App.dataPath`；
/// `EhNetwork()` 会 new `CookieJarSql` → 需要 sqlite3 动态库），在 `flutter test`
/// 下必然失败。把能力声明做成真 const，正是为了让"四源真实能力"可以脱离实例断言。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/explore/explore_models.dart';
import 'package:picakeep/foundation/explore/providers/eh_explore_provider.dart';
import 'package:picakeep/foundation/explore/providers/jm_explore_provider.dart';
import 'package:picakeep/foundation/explore/providers/nhentai_explore_provider.dart';
import 'package:picakeep/foundation/explore/providers/picacg_explore_provider.dart';

/// 四源描述符。**全部是静态常量**：这里没有任何 provider 实例。
const List<ExploreSourceDescriptor> allDescriptors = <ExploreSourceDescriptor>[
  JmExploreProvider.descriptorOf,
  PicacgExploreProvider.descriptorOf,
  EhExploreProvider.descriptorOf,
  NhentaiExploreProvider.descriptorOf,
];

/// 探索源选择里必须出现的四个 sourceKey（顺序即本测试的期望顺序）。
const List<String> expectedSourceKeys = <String>[
  'jm',
  'picacg',
  'ehentai',
  'nhentai',
];

/// 每个源唯一的 kind 入口（用于遍历断言时给出可读定位）。
List<ExploreEntry> rankingEntriesOf(ExploreSourceDescriptor d) =>
    d.entriesOf(ExploreSectionKind.ranking);

void main() {
  group('探索源能力声明（只读静态常量，不构造 provider）', () {
    test('1. 四源齐全：sourceKey 恰为 jm/picacg/ehentai/nhentai 且两两不重复', () {
      final keys =
          allDescriptors.map((d) => d.sourceKey).toList(growable: false);

      expect(keys, expectedSourceKeys, reason: '四源必须全部出现在探索源选择中');
      expect(keys.toSet().length, keys.length, reason: 'sourceKey 不能重复');

      for (final descriptor in allDescriptors) {
        expect(
          descriptor.name.trim(),
          isNotEmpty,
          reason: '${descriptor.sourceKey} 的 name 不能为空',
        );
        expect(
          descriptor.requiresLogin,
          isTrue,
          reason: '${descriptor.sourceKey} 声明 requiresLogin == true',
        );
      }
    });

    test('2. 不存在空声明占位：四源 entries 非空，且各有 recommend/ranking/category', () {
      for (final descriptor in allDescriptors) {
        expect(
          descriptor.entries,
          isNotEmpty,
          reason: '${descriptor.sourceKey} 的 entries 不能为空（空声明占位）',
        );
        for (final kind in ExploreSectionKind.values) {
          expect(
            descriptor.entriesOf(kind),
            isNotEmpty,
            reason: '${descriptor.sourceKey} 至少要有 1 个 ${kind.name} 入口',
          );
        }
      }
    });

    test('3. 入口 ID 在源内唯一，且每个 entry.label 非空', () {
      for (final descriptor in allDescriptors) {
        final ids = descriptor.entries.map((e) => e.id).toList(growable: false);
        expect(
          ids.toSet().length,
          ids.length,
          reason: '${descriptor.sourceKey} 的 entry.id 不能重复：$ids',
        );
        for (final entry in descriptor.entries) {
          expect(
            entry.label.trim(),
            isNotEmpty,
            reason: '${descriptor.sourceKey}/${entry.id} 的 label 不能为空',
          );
        }
      }
    });

    test('4. 选项契约自洽：有 options ⇔ defaultOptionId 合法；无 options ⇔ default 为 null',
        () {
      for (final descriptor in allDescriptors) {
        for (final entry in descriptor.entries) {
          final where = '${descriptor.sourceKey}/${entry.id}';
          if (entry.options.isEmpty) {
            expect(
              entry.defaultOptionId,
              isNull,
              reason: '$where 没有选项时 defaultOptionId 必须为 null',
            );
          } else {
            expect(
              entry.defaultOptionId,
              isNotNull,
              reason: '$where 有选项时必须声明 defaultOptionId',
            );
            expect(
              entry.optionById(entry.defaultOptionId!),
              isNotNull,
              reason: '$where 的 defaultOptionId 必须能在 options 里找到',
            );
          }
        }
      }
    });

    test('5a. 榜单口径：EH ranking 恰为 昨天/本月/今年/全部，且不含「今日」', () {
      final ranking = rankingEntriesOf(EhExploreProvider.descriptorOf).single;
      final ids = ranking.options.map((o) => o.id).toList(growable: false);
      final labels =
          ranking.options.map((o) => o.label).toList(growable: false);

      expect(ids, <String>['yesterday', 'month', 'year', 'all']);
      expect(labels, <String>['昨天', '本月', '今年', '全部']);
      for (final option in ranking.options) {
        expect(
          option.label.contains('今日'),
          isFalse,
          reason: 'EH 榜期不能改写成「今日」：${option.label}',
        );
      }
    });

    test('5b. 榜单口径：Pica ranking 恰为 H24/D7/D30，且不存在任何「总榜」', () {
      final ranking =
          rankingEntriesOf(PicacgExploreProvider.descriptorOf).single;
      final ids = ranking.options.map((o) => o.id).toList(growable: false);

      expect(ids, <String>['H24', 'D7', 'D30']);
      expect(ids.length, 3);
      for (final option in ranking.options) {
        expect(
          option.id.contains('总'),
          isFalse,
          reason: 'Pica 没有总榜：${option.id}',
        );
        expect(
          option.label.contains('总'),
          isFalse,
          reason: 'Pica 没有总榜：${option.label}',
        );
      }
    });

    test('5c. 榜单口径：NH ranking 为 4 档热门，且不含 id `recent`', () {
      final ranking =
          rankingEntriesOf(NhentaiExploreProvider.descriptorOf).single;
      final ids = ranking.options.map((o) => o.id).toList(growable: false);

      expect(ids.length, 4, reason: 'NH 榜单是四档热门：$ids');
      expect(ids, contains('popular-today'));
      for (final option in ranking.options) {
        expect(
          option.id == 'recent',
          isFalse,
          reason: '「最新」不是榜期，不能出现在 NH ranking 选项里',
        );
        expect(
          option.label.contains('最新'),
          isFalse,
          reason: 'NH ranking 的 label 不能出现「最新」：${option.label}',
        );
      }
    });

    test('5d. 榜单口径：JM ranking 选项恰为 mv/mv_m/mv_w/mv_t 四项', () {
      final ranking = rankingEntriesOf(JmExploreProvider.descriptorOf).single;
      final ids = ranking.options.map((o) => o.id).toList(growable: false);

      expect(ids, <String>['mv', 'mv_m', 'mv_w', 'mv_t']);
      expect(ranking.defaultOptionId, 'mv');
    });

    test('6a. 单页入口：Pica 随机 / NH 随机 singlePage == true', () {
      const picacg = PicacgExploreProvider.descriptorOf;
      expect(
        picacg.entryById(PicacgExploreEntries.random)?.singlePage,
        isTrue,
        reason: 'Pica 随机是单页（刷新即换一批）',
      );

      const nhentai = NhentaiExploreProvider.descriptorOf;
      expect(
        nhentai.entryById(NhentaiExploreEntries.random)?.singlePage,
        isTrue,
        reason: 'NH 随机是单本，无分页',
      );
    });

    test('6b. 单页入口：Pica 榜单 singlePage == true（验收要求）', () {
      // 任务验收要求 Pica 榜单入口声明 singlePage == true。**该断言未通过**：
      // 真实代码里 `picacg.ranking` 没有写 `singlePage: true`（默认 false），
      // 尽管它的 description 写着「单页，不再请求下一页」、`_loadRanking` 也
      // 恒返回 `nextToken: null`。按任务约定：不为了让测试通过而改断言或改代码，
      // 只报告。详见本轮汇报的「真实设计缺陷」一节。
      const picacg = PicacgExploreProvider.descriptorOf;
      expect(
        picacg.entryById(PicacgExploreEntries.ranking)?.singlePage,
        isTrue,
        reason: 'Pica 榜单声明为单页（不再请求下一页）',
      );
    });

    test('7. 单页与续页语义不矛盾：带选项的单页入口 default 必须合法', () {
      // 任务约定：单页入口允许携带多个选项（用于「换一批」），但必须有合法
      // defaultOptionId —— 上面第 4 条已对全量入口断言，这里只对单页入口复述一遍，
      // 并把「单页 + 不许刷新 + 无选项」这种完全冻结的组合记录下来（不改代码）。
      final frozenEntries = <String>[];

      for (final descriptor in allDescriptors) {
        for (final entry in descriptor.entries.where((e) => e.singlePage)) {
          final where = '${descriptor.sourceKey}/${entry.id}';
          if (entry.options.isNotEmpty) {
            expect(
              entry.defaultOptionId,
              isNotNull,
              reason: '$where 是带选项的单页入口，必须有 defaultOptionId',
            );
            expect(
              entry.optionById(entry.defaultOptionId!),
              isNotNull,
              reason: '$where 的 defaultOptionId 必须能在 options 里找到',
            );
          }
          if (!entry.supportsRefresh && entry.options.isEmpty) {
            frozenEntries.add(where);
          }
        }
      }

      // 记录（不隐藏）：这些入口既不能续页、也不许刷新、还没有「换一批」选项。
      // 按任务要求这里不因该组合转红，只把事实打印出来由报告确认。
      print('[explore-descriptor] 单页 + 禁刷新 + 无选项的入口: $frozenEntries');
    });
  });
}

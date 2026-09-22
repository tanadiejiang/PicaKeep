/// 主导航启动页语义测试：历史设置值 `settings[23]`（"0"=我 / "1"=收藏）
/// 映射到**当前可见 tab 列表**内的下标。
///
/// 回归点：`settings[23]` 不是最终数组下标。开启 AI 后可见 tab 变为
/// `[me, ai, favorites, explore, ...]`，"1"（收藏）的下标从 1 变成 2 ——
/// 旧实现直接把它当索引用，会把"收藏"错落到 AI 页。
///
/// 断言矩阵：AI 开/关 × 运行模式客户端/服务端 四组合，
/// `"1"` 始终解析到 `MainTabId.favorites`，`"0"` 解析到 me，
/// 坏值（""/"abc"/"9"/"2"/"-1"）一律回落到 me。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/pages/main_page.dart';

/// 实际可见 tab 顺序：me, [ai], favorites, explore, [serviceInfo]。
List<MainTabId> visibleTabs({required bool ai, required bool server}) =>
    <MainTabId>[
      MainTabId.me,
      if (ai) MainTabId.ai,
      MainTabId.favorites,
      MainTabId.explore,
      if (server) MainTabId.serviceInfo,
    ];

void main() {
  group('visibleTabs 夹具本身', () {
    test('四组合的可见 tab 顺序与下标符合预期', () {
      expect(visibleTabs(ai: false, server: false),
          <MainTabId>[MainTabId.me, MainTabId.favorites, MainTabId.explore]);
      expect(visibleTabs(ai: true, server: false), <MainTabId>[
        MainTabId.me,
        MainTabId.ai,
        MainTabId.favorites,
        MainTabId.explore,
      ]);
      expect(visibleTabs(ai: false, server: true), <MainTabId>[
        MainTabId.me,
        MainTabId.favorites,
        MainTabId.explore,
        MainTabId.serviceInfo,
      ]);
      expect(visibleTabs(ai: true, server: true), <MainTabId>[
        MainTabId.me,
        MainTabId.ai,
        MainTabId.favorites,
        MainTabId.explore,
        MainTabId.serviceInfo,
      ]);
    });
  });

  group('resolveInitialMainTabIndex：AI 开/关 × 客户端/服务端', () {
    for (final ai in <bool>[false, true]) {
      for (final server in <bool>[false, true]) {
        final label = 'AI=${ai ? '开' : '关'} × ${server ? '服务端' : '客户端'}';

        test('$label：settings[23]="1" 始终解析到收藏', () {
          final tabs = visibleTabs(ai: ai, server: server);
          final index = resolveInitialMainTabIndex(
            visibleTabs: tabs,
            storedSetting: '1',
          );

          expect(tabs[index], MainTabId.favorites,
              reason: '历史值 1 的语义恒为「收藏」，与 AI/服务信息是否可见无关');
          expect(index, tabs.indexOf(MainTabId.favorites));
          // 开 AI 后收藏下标必须是 2（旧实现会错落到 AI 的 1）。
          expect(index, ai ? 2 : 1);
          expect(tabs[index], isNot(MainTabId.ai));
        });

        test('$label：settings[23]="0" 始终解析到我', () {
          final tabs = visibleTabs(ai: ai, server: server);
          final index = resolveInitialMainTabIndex(
            visibleTabs: tabs,
            storedSetting: '0',
          );

          expect(tabs[index], MainTabId.me);
          expect(index, tabs.indexOf(MainTabId.me));
          expect(index, 0);
        });

        test('$label：坏值一律回落到我（不越界、不当作下标）', () {
          final tabs = visibleTabs(ai: ai, server: server);
          for (final bad in <String>['', 'abc', '9', '2', '-1', ' ']) {
            final index = resolveInitialMainTabIndex(
              visibleTabs: tabs,
              storedSetting: bad,
            );
            expect(index, tabs.indexOf(MainTabId.me),
                reason: '坏值 $bad 必须回落到「我」');
            expect(index, inInclusiveRange(0, tabs.length - 1),
                reason: '坏值 $bad 不得越界');
          }
        });
      }
    }
  });

  group('resolveInitialMainTabIndex：边界', () {
    test('历史值两侧空白被容忍', () {
      final tabs = visibleTabs(ai: true, server: true);
      expect(
        resolveInitialMainTabIndex(visibleTabs: tabs, storedSetting: ' 1 '),
        tabs.indexOf(MainTabId.favorites),
      );
      expect(
        resolveInitialMainTabIndex(visibleTabs: tabs, storedSetting: ' 0 '),
        tabs.indexOf(MainTabId.me),
      );
    });

    test('"1" 但收藏不可见时回落到我（而不是硬编码下标 1）', () {
      const tabs = <MainTabId>[MainTabId.me, MainTabId.explore];
      final index = resolveInitialMainTabIndex(
        visibleTabs: tabs,
        storedSetting: '1',
      );
      expect(index, 0);
      expect(tabs[index], MainTabId.me);
    });

    test('「我」不可见时回落到 0；空列表也返回 0', () {
      expect(
        resolveInitialMainTabIndex(
          visibleTabs: const <MainTabId>[MainTabId.favorites],
          storedSetting: 'abc',
        ),
        0,
      );
      expect(
        resolveInitialMainTabIndex(
          visibleTabs: const <MainTabId>[],
          storedSetting: '1',
        ),
        0,
      );
    });

    test('探索恒可见不影响「我/收藏」的下标语义', () {
      final withExplore = visibleTabs(ai: false, server: false);
      final withoutExplore = <MainTabId>[
        MainTabId.me,
        MainTabId.favorites,
      ];
      expect(
        resolveInitialMainTabIndex(
            visibleTabs: withExplore, storedSetting: '1'),
        1,
      );
      expect(
        resolveInitialMainTabIndex(
            visibleTabs: withoutExplore, storedSetting: '1'),
        1,
      );
      expect(
        resolveInitialMainTabIndex(
            visibleTabs: withExplore, storedSetting: '0'),
        0,
      );
    });
  });
}

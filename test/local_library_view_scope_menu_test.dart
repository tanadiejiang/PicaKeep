/// 「资源库显示设置」面板里各区块的**可见性契约**（36 号，替代 33 号那份）。
///
/// ## 36 号改了什么
///
/// 33 号把"档位有没有意义"和"档位能不能切"**混在一条判据**里
/// （`_showSourceSelector` = 远程可用 && 不是子页面），于是远程不可用时档位
/// **整块消失** —— 用户找不到它，真机反馈原话是
/// 「还有本地-聚合-远程 挡位切换按钮呢」。
///
/// 现在拆成两条：
/// - [LocalLibraryViewScopeMenu.tiersApplicable]：**有没有意义**，只看是不是
///   本地根 / 远程根子页面。→ 决定档位折叠区出不出现；
/// - [LocalLibraryViewScopeMenu.tiersEnabled]：**能不能切**，只看远程是否可用。
///   → 决定"聚合 / 远程"两档是否置灰（**不隐藏**）。
///
/// 判据本体是 `foundation/local_library_settings.dart` 里的纯函数，
/// 所以这里不需要渲染整页图集页 —— 页面上的"远程可用"还依赖
/// `_remoteAvailable`，而它要"客户端模式 + 远程服务在线"才会为真，
/// widget 测试里造不出来（页面侧由
/// `local_library_page_view_scope_test.dart` 从"远程不可用"一侧守住）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/local_library_settings.dart';

void main() {
  LocalLibraryViewScopeMenu menu({
    bool remoteAvailable = false,
    bool isLocalRootPage = false,
    bool isRemoteRootPage = false,
    bool pageAlbumOnly = true,
    bool albumOnly = true,
  }) {
    return localLibraryViewScopeMenu(
      remoteAvailable: remoteAvailable,
      isLocalRootPage: isLocalRootPage,
      isRemoteRootPage: isRemoteRootPage,
      pageAlbumOnly: pageAlbumOnly,
      albumOnly: albumOnly,
    );
  }

  group('档位"有没有意义"：只取决于是不是子页面', () {
    test('根列表上（无论远程是否可用）都有意义', () {
      expect(menu().tiersApplicable, isTrue);
      expect(
        menu(remoteAvailable: true).tiersApplicable,
        isTrue,
      );
    });

    test('远程不可用**不影响**这一条 —— 33 号正是在这里把档位藏掉了', () {
      // 这是 36 号的核心回归：用户在远程不可用时问"档位切换按钮呢"。
      expect(menu(remoteAvailable: false).tiersApplicable, isTrue);
    });

    test('本地根 / 远程根子页面 → 没有意义（整块不出现）', () {
      for (final flags in <List<bool>>[
        <bool>[true, false],
        <bool>[false, true],
        <bool>[true, true],
      ]) {
        expect(
          menu(
            remoteAvailable: true,
            isLocalRootPage: flags[0],
            isRemoteRootPage: flags[1],
          ).tiersApplicable,
          isFalse,
          reason: '子页面里"档位"没有意义',
        );
      }
    });
  });

  group('档位"能不能切"：只看远程是否可用', () {
    test('远程可用 → 三档都能选', () {
      final m = menu(remoteAvailable: true);
      expect(m.tiersEnabled, isTrue);
      expect(m.tierAvailable(needsRemote: false), isTrue);
      expect(m.tierAvailable(needsRemote: true), isTrue);
    });

    test('远程不可用 → 本地可点，需要远程的两档置灰（但**仍在列表里**）', () {
      final m = menu(remoteAvailable: false);
      expect(m.tiersEnabled, isFalse);
      expect(
        m.tierAvailable(needsRemote: false),
        isTrue,
        reason: '本地档不依赖远程，任何时候都能选',
      );
      expect(
        m.tierAvailable(needsRemote: true),
        isFalse,
        reason: '聚合 / 远程需要远程服务；置灰而不是隐藏，用户才找得到档位',
      );
    });

    test('档位有没有意义 与 能不能切 是正交的两条', () {
      // 四种组合都要能表达出来，否则又退化成 33 号那条混在一起的判据。
      expect(menu(remoteAvailable: true).tiersApplicable, isTrue);
      expect(menu(remoteAvailable: true).tiersEnabled, isTrue);
      expect(menu(remoteAvailable: false).tiersApplicable, isTrue);
      expect(menu(remoteAvailable: false).tiersEnabled, isFalse);
      expect(menu(remoteAvailable: true, isLocalRootPage: true).tiersApplicable,
          isFalse);
      expect(menu(remoteAvailable: true, isLocalRootPage: true).tiersEnabled,
          isTrue);
    });
  });

  group('「资源库显示设置」：32 号的页内入口条件，逐字保留', () {
    test('图集页（`widget.albumOnly` 为真）→ 有', () {
      expect(menu(pageAlbumOnly: true, albumOnly: true).showDisplaySettings,
          isTrue);
    });

    test('资源库页（`widget.albumOnly` 为假）→ 也有', () {
      expect(menu(pageAlbumOnly: false, albumOnly: false).showDisplaySettings,
          isTrue);
    });

    test('`widget.albumOnly` 为真但生效的 albumOnly 为假 → 没有（与旧条件同解）',
        () {
      // 旧写法 `!widget.albumOnly || _isAlbumOnly`：这里两项都是假。
      expect(menu(pageAlbumOnly: true, albumOnly: false).showDisplaySettings,
          isFalse);
    });
  });

  group('合成：按钮永远有内容可放', () {
    // `_isAlbumOnly = widget.albumOnly || settings[94] != '0'`，所以
    // **`pageAlbumOnly` 为真时 `albumOnly` 必然也为真**。
    // 下面枚举的是"根列表"（非子页面）上的可达组合 —— 它们**永远非空**，
    // 这正是"按钮不会整个消失、既有入口不会丢"的依据。
    // （子页面上另有可达的空组合，见下一条用例。）
    test('根列表的可达组合下永远非空（否则按钮会消失 = 丢了既有入口）', () {
      for (final remoteAvailable in <bool>[true, false]) {
        for (final pageAlbumOnly in <bool>[true, false]) {
          // 可达性约束：pageAlbumOnly ⇒ albumOnly。
          final albumOnlyOptions =
              pageAlbumOnly ? <bool>[true] : <bool>[true, false];
          for (final albumOnly in albumOnlyOptions) {
            final m = menu(
              remoteAvailable: remoteAvailable,
              pageAlbumOnly: pageAlbumOnly,
              albumOnly: albumOnly,
            );
            expect(m.isEmpty, isFalse,
                reason: 'remote=$remoteAvailable page=$pageAlbumOnly '
                    'album=$albumOnly');
          }
        }
      }
    });

    test('可达的"整体为空"组合：子页面 + 关掉「仅显示图集」→ 按钮不出现', () {
      // 36 号起"整体为空"与远程是否可用**无关**了（档位不再依赖它），
      // 只剩这一种组合：本页是子页面（档位没意义）且设置入口条件为假
      // （`widget.albumOnly` 为真而生效的 albumOnly 为假）。
      // 这类页面上本来就没有页内设置入口 —— 与 32 号的行为一致，不是漏洞。
      final m = menu(
        isLocalRootPage: true,
        pageAlbumOnly: true,
        albumOnly: false,
      );
      expect(m.tiersApplicable, isFalse);
      expect(m.showDisplaySettings, isFalse);
      expect(m.isEmpty, isTrue);
    });

    test('档位区与设置入口同时存在（同一个面板里，不再是一个菜单）', () {
      final m = menu(remoteAvailable: true);
      expect(m.tiersApplicable, isTrue);
      expect(m.showDisplaySettings, isTrue);
    });
  });
}

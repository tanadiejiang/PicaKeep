import 'dart:ffi';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/local_data_source.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/pages/online_comic/platform_favorite_panel.dart';
import 'package:sqlite3/open.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationCachePath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

/// 四源平台收藏弹窗的形态与提交语义（对齐原项目 `FavoriteComicWidget`）。
///
/// 这些用例只驱动 `PlatformFavoritePanel` 本身：各源页面只负责把网络调用包成
/// 回调，形态与"何时可以提交"由面板统一保证，因此在这里集中验证最划算。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  open.overrideFor(
      OperatingSystem.windows,
      () =>
          DynamicLibrary.open('${Directory.current.path}/windows/sqlite3.dll'));

  late Directory workspace;
  late String oldMode;
  final manager = LocalFavoritesManager();
  final originalPaths = PathProviderPlatform.instance;

  setUpAll(() async {
    workspace = await Directory.systemTemp.createTemp('picakeep_panel_');
    PathProviderPlatform.instance = _Paths(workspace.path);
    await App.init(dataPathOverride: '${workspace.path}/data');
    oldMode = managedDataSourceMode;
    setManagedDataSourceMode(managedDataSourceModeCurrentOnly);
  });

  // 面板的「本地」页会读 `LocalFavoritesManager`，必须先把存储初始化出来。
  setUp(() async {
    final root = await Directory(
            '${workspace.path}/${DateTime.now().microsecondsSinceEpoch}')
        .create();
    setManagedDataRootOverride(root.path);
    await manager.init();
    for (final folder in manager.folderNames) {
      manager.deleteFolder(folder);
    }
  });

  tearDown(() => manager.dispose());

  tearDownAll(() {
    PathProviderPlatform.instance = originalPaths;
    setManagedDataRootOverride(null);
    setManagedDataSourceMode(oldMode);
  });

  final localItem = FavoriteItem(
    target: '123',
    name: 'Fixture',
    coverPath: '',
    author: '',
    type: FavoriteType.jm,
    tags: const [],
  );

  const folders = <FavoriteFolderOption>[
    FavoriteFolderOption(id: '', name: '默认收藏夹'),
    FavoriteFolderOption(id: '7', name: '同人'),
  ];

  /// 挂一个按钮打开面板，避免在测试里铺完整详情页。
  Future<void> openPanel(
    WidgetTester tester, {
    required Future<PlatformFavoriteSubmitResult> Function({
      String? folderId,
      required bool favorite,
    }) onSubmit,
    bool isFavorite = false,
    bool canFavorite = true,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showPlatformFavoritePanel(
              context,
              sourceTitle: '禁漫',
              localItem: localItem,
              isFavorite: isFavorite,
              canFavorite: canFavorite,
              folders: folders,
              onSubmitPlatform: onSubmit,
            ),
            child: const Text('打开面板'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开面板'));
    await tester.pumpAndSettle();
  }

  group('P01 面板形态', () {
    testWidgets('打开后是「网络 / 本地」两个页签，网络页列出收藏夹', (tester) async {
      await openPanel(tester, onSubmit: ({folderId, required favorite}) async {
        return const PlatformFavoriteSubmitResult.ok();
      });

      expect(find.text('网络'), findsOneWidget);
      expect(find.text('本地'), findsOneWidget);
      // 网络页默认展示夹列表。
      expect(find.text('默认收藏夹'), findsOneWidget);
      expect(find.text('同人'), findsOneWidget);
      // 未选中任何夹 → 提交按钮禁用（不制造"无变化提交"）。
      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(button.onPressed, isNull);
    });

    testWidgets('选中夹后出现打勾；再选另一个是单选（旧的取消）', (tester) async {
      await openPanel(tester, onSubmit: ({folderId, required favorite}) async {
        return const PlatformFavoriteSubmitResult.ok();
      });

      await tester.tap(find.byKey(const ValueKey('folder-7')));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.check), findsOneWidget,
          reason: '选中项应有打勾');
      expect(find.byIcon(Icons.folder), findsOneWidget,
          reason: '选中项文件夹图标应为实心');

      await tester.tap(find.byKey(const ValueKey('folder-')));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.check), findsOneWidget,
          reason: '网络页是单选，仍只有一颗勾');
      final selectedIcon = tester.widget<Icon>(find.byIcon(Icons.folder));
      expect(selectedIcon.key, isNull);
    });
  });

  group('P02 提交语义', () {
    testWidgets('选中非默认夹提交 → 回调拿到该夹 id 且 favorite=true', (tester) async {
      String? gotFolderId;
      bool? gotFavorite;
      await openPanel(tester, onSubmit: ({folderId, required favorite}) async {
        gotFolderId = folderId;
        gotFavorite = favorite;
        return const PlatformFavoriteSubmitResult.ok();
      });

      await tester.tap(find.byKey(const ValueKey('folder-7')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('收藏'));
      await tester.pumpAndSettle();

      expect(gotFolderId, '7');
      expect(gotFavorite, isTrue);
      // 提交成功后面板关闭。
      expect(find.text('网络'), findsNothing);
    });

    testWidgets('已收藏时点「取消收藏」→ favorite=false（无需先取消勾选）',
        (tester) async {
      bool? gotFavorite;
      await openPanel(
        tester,
        isFavorite: true,
        onSubmit: ({folderId, required favorite}) async {
          gotFavorite = favorite;
          return const PlatformFavoriteSubmitResult.ok();
        },
      );

      // 已收藏：按钮直接是「取消收藏」且可点 —— 与原项目一致。
      expect(find.text('取消收藏'), findsOneWidget);
      await tester.tap(find.text('取消收藏'));
      await tester.pumpAndSettle();
      expect(gotFavorite, isFalse);
    });

    testWidgets('已收藏时选中一个新夹 → 按钮变「收藏」并提交 favorite=true（换夹）',
        (tester) async {
      bool? gotFavorite;
      String? gotFolderId;
      await openPanel(
        tester,
        isFavorite: true,
        onSubmit: ({folderId, required favorite}) async {
          gotFavorite = favorite;
          gotFolderId = folderId;
          return const PlatformFavoriteSubmitResult.ok();
        },
      );

      await tester.tap(find.byKey(const ValueKey('folder-7')));
      await tester.pumpAndSettle();
      expect(find.text('取消收藏'), findsNothing,
          reason: '选中新夹后是「收藏」而不是「取消收藏」');
      await tester.tap(find.text('收藏'));
      await tester.pumpAndSettle();
      expect(gotFavorite, isTrue);
      expect(gotFolderId, '7');
    });

    testWidgets('提交失败 → 面板不关闭、弹错误提示', (tester) async {
      await openPanel(tester, onSubmit: ({folderId, required favorite}) async {
        return const PlatformFavoriteSubmitResult.failed('平台收藏失败');
      });

      await tester.tap(find.byKey(const ValueKey('folder-7')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('收藏'));
      await tester.pumpAndSettle();

      expect(find.text('平台收藏失败'), findsOneWidget);
      expect(find.text('网络'), findsOneWidget, reason: '失败时面板应留在原地');
    });
  });

  group('P05 单夹源（Picacg / NH 形态）', () {
    testWidgets('已收藏 → 底部直接是「取消收藏」且可点；点它调接口并传 favorite=false',
        (tester) async {
      bool? gotFavorite;
      var calls = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showPlatformFavoritePanel(
                context,
                sourceTitle: 'Picacg',
                localItem: localItem,
                isFavorite: true,
                canFavorite: true,
                folders: const [
                  FavoriteFolderOption(id: 'picacg', name: 'Picacg 收藏'),
                ],
                onSubmitPlatform: ({folderId, required favorite}) async {
                  calls++;
                  gotFavorite = favorite;
                  return const PlatformFavoriteSubmitResult.ok();
                },
              ),
              child: const Text('打开面板'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('打开面板'));
      await tester.pumpAndSettle();

      // 已收藏：按钮是「取消收藏」，且**不能**是禁用态（点它即取消）。
      expect(find.text('取消收藏'), findsOneWidget);
      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(button.onPressed, isNotNull);

      await tester.tap(find.text('取消收藏'));
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(gotFavorite, isFalse, reason: '已收藏时点「取消收藏」应传 favorite=false');
    });

    testWidgets('未收藏 → 按钮是禁用的「收藏」，不会调用接口', (tester) async {
      var calls = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showPlatformFavoritePanel(
                context,
                sourceTitle: 'Picacg',
                localItem: localItem,
                isFavorite: false,
                canFavorite: true,
                folders: const [
                  FavoriteFolderOption(id: 'picacg', name: 'Picacg 收藏'),
                ],
                onSubmitPlatform: ({folderId, required favorite}) async {
                  calls++;
                  return const PlatformFavoriteSubmitResult.ok();
                },
              ),
              child: const Text('打开面板'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('打开面板'));
      await tester.pumpAndSettle();

      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(button.onPressed, isNull);
      expect(calls, 0,
          reason: 'toggle 源在"保持收藏"时绝不能调用接口，否则会翻转成取消');
    });
  });

  group('P06 本地页：预选已收藏的夹 + 暂存差异提交', () {
    /// 把 [localItem] 加入 [folder]，返回后打开面板并切到本地页。
    Future<void> openLocalTabWithFavorite(
      WidgetTester tester, {
      required String folder,
    }) async {
      manager.createFolder(folder);
      await manager.addComicsToFolders([folder], [localItem]);
      await openPanel(
        tester,
        onSubmit: ({folderId, required favorite}) async {
          return const PlatformFavoriteSubmitResult.ok();
        },
      );
      await tester.tap(find.text('本地'));
      await tester.pumpAndSettle();
    }

    testWidgets('已收藏在该夹 → 复选框自动勾选（能看出本地收藏状态）',
        (tester) async {
      await openLocalTabWithFavorite(tester, folder: 'AI图但涩');

      final tiles = tester
          .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
          .toList();
      expect(tiles, isNotEmpty);
      expect(tiles.first.value, isTrue,
          reason: '这本已在「AI图但涩」里，复选框必须是勾选态');
    });

    testWidgets('取消勾选后点「完成」→ 从该夹移除（暂存差异语义）',
        (tester) async {
      await openLocalTabWithFavorite(tester, folder: 'AI图但涩');
      expect(manager.comicExists('AI图但涩', '123', FavoriteType.jm.key), isTrue);

      await tester.tap(find.byType(CheckboxListTile).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();

      expect(manager.comicExists('AI图但涩', '123', FavoriteType.jm.key), isFalse,
          reason: '取消勾选 + 完成 = 取消该收藏夹的该漫画');
      expect(find.text('网络'), findsNothing, reason: '提交后面板应关闭');
    });

    testWidgets('不动任何东西直接点「完成」→ 不写库、静默关闭', (tester) async {
      await openLocalTabWithFavorite(tester, folder: 'AI图但涩');

      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();

      expect(manager.comicExists('AI图但涩', '123', FavoriteType.jm.key), isTrue,
          reason: '无差异时不应误删');
      expect(find.text('网络'), findsNothing);
    });
  });

  group('P07 无平台能力时', () {
    testWidgets('未登录：网络页给提示且提交禁用，本地页仍可用', (tester) async {
      await openPanel(
        tester,
        canFavorite: false,
        onSubmit: ({folderId, required favorite}) async {
          return const PlatformFavoriteSubmitResult.ok();
        },
      );

      expect(find.text('登录 禁漫 后可使用平台收藏'), findsOneWidget);
      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(button.onPressed, isNull);

      // 本地页仍然是复选框形态，且有「新建并选中」。
      await tester.tap(find.text('本地'));
      await tester.pumpAndSettle();
      expect(find.text('新建并选中'), findsOneWidget);
      expect(find.byType(CheckboxListTile), findsNothing,
          reason: '测试环境没有本地收藏夹，故列表为空');
    });
  });
}

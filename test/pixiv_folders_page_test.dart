import 'dart:convert';
import 'package:image/image.dart' as img;
import 'package:picakeep/pages/local_library_page.dart';
import 'package:picakeep/pages/local_library_illust_card.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/illust_page_count_cache.dart';
import 'package:picakeep/foundation/illust_folder_preferences.dart';
import 'package:picakeep/pages/illust_folder_selector.dart';
import 'package:picakeep/foundation/local_data_source.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/local_trash_store.dart';
import 'package:picakeep/foundation/pixiv_download_naming.dart';
import 'package:picakeep/foundation/pixiv_library.dart';
import 'package:picakeep/pages/pixiv_folders_page.dart';
import 'package:picakeep/pages/online_comic/online_comic_page_components.dart';
import 'package:sqlite3/open.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationCachePath() async => p.join(root, 'cache');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory workspace;
  late PixivLibrary library;
  final saved = List<String>.from(appdata.settings);
  final provider = PathProviderPlatform.instance;
  setUpAll(() async {
    if (Platform.isWindows) {
      open.overrideFor(
          OperatingSystem.windows,
          () => DynamicLibrary.open(
              p.join(Directory.current.path, 'windows', 'sqlite3.dll')));
    }
    workspace = await Directory.systemTemp.createTemp('pk46_widgets_');
    PathProviderPlatform.instance = _Paths(workspace.path);
    await App.init(dataPathOverride: p.join(workspace.path, 'app'));
    SharedPreferences.setMockInitialValues({});
    await sharedIllustPageCountCache();
    await IllustFolderPreferences.instance.load();
    library = PixivLibrary(p.join(workspace.path, 'library'));
    await library.initialize();
    await library.createFolder('壁纸');
    await library.createFolder('风景');
    appdata.settings[pixivDownloadDirSettingIndex] = library.root;
    appdata.settings[22] = p.join(workspace.path, 'other');
  });
  tearDownAll(() async {
    LocalTrashStore.instance.dispose();
    appdata.settings
      ..clear()
      ..addAll(saved);
    PathProviderPlatform.instance = provider;
    try {
      await workspace.delete(recursive: true);
    } on FileSystemException catch (error) {
      // Flutter's fake-async image/scan callbacks can retain a Windows handle
      // until the test isolate exits. Only defer cleanup for that exact OS error.
      if (!Platform.isWindows || error.osError?.errorCode != 32) rethrow;
      print('Fixture cleanup deferred until process exit: ${workspace.path}');
    }
  });
  Future<void> settleIO(WidgetTester tester) async {
    for (var i = 0; i < 120; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 100));
      if (i > 10 &&
          find.byType(LinearProgressIndicator).evaluate().isEmpty &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty) {
        break;
      }
    }
    await tester.pumpAndSettle();
  }

  Future<void> showPage(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () => Navigator.push<String>(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const PixivFoldersPage())),
                    child: const Text('管理'))))));
    await tester.tap(find.text('管理'));
    await settleIO(tester);
  }

  Future<void> expectFolderCounts(
      WidgetTester tester, Map<String, int> counts) async {
    // Real file events and fake-async continuations alternate. Wait for the
    // expected page snapshot (not only the spinner, which may not exist while
    // clear-cache / refresh awaits before it sets loading).
    for (var attempt = 0; attempt < 400; attempt++) {
      final selector = tester
          .widget<IllustFolderSelector>(find.byType(IllustFolderSelector));
      if (selector.onSelected != null && selector.totalCount == counts['全部文件夹']) {
        break;
      }
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(
        tester
            .widget<IllustFolderSelector>(find.byType(IllustFolderSelector))
            .onSelected,
        isNotNull,
        reason:
            'all background folder operations must finish before opening menu');
    await tester.tap(find.byTooltip('选择插画文件夹'));
    await tester.pumpAndSettle();
    for (final entry in counts.entries) {
      expect(
          find.descendant(
              of: find.widgetWithText(PopupMenuItem<String>, entry.key),
              matching: find.text('${entry.value}')),
          findsOneWidget,
          reason:
              '${entry.key} must count the actual loaded illustrations; actual menu: ${tester.widgetList<Text>(find.descendant(of: find.byType(PopupMenuItem<String>), matching: find.byType(Text))).map((text) => text.data).toList()}');
    }
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, '全部文件夹'));
    await tester.pumpAndSettle();
  }

  testWidgets('folders show names/counts; long press opens single-folder menu',
      (tester) async {
    await showPage(tester);
    expect(find.text('新建'), findsOneWidget);
    expect(find.text('排序'), findsOneWidget);
    await tester.longPress(find.text('壁纸'));
    await tester.pumpAndSettle();
    expect(find.text('重命名'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
    expect(find.textContaining('已选择'), findsNothing);
    expect(find.text('全选'), findsNothing);
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '壁纸 新名字');
    await tester.tap(find.text('确定'));
    await settleIO(tester);
    expect(find.text('壁纸 新名字'), findsOneWidget);
    expect(Directory(p.join(library.root, '壁纸 新名字')).existsSync(), isTrue);
    expect(find.byType(PixivFoldersPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'new folder uses entered physical name; cancellation creates nothing',
      (tester) async {
    await showPage(tester);
    await tester.tap(find.text('新建'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '取消的新目录');
    await tester.tap(find.text('取消'));
    await settleIO(tester);
    expect(Directory(p.join(library.root, '取消的新目录')).existsSync(), isFalse);
    await tester.tap(find.text('新建'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '手动目录');
    await tester.tap(find.text('确定'));
    await settleIO(tester);
    expect(find.text('手动目录'), findsOneWidget);
    expect(Directory(p.join(library.root, '手动目录')).existsSync(), isTrue);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'folder sorting is separate from its long-press menu and persists on back',
      (tester) async {
    await showPage(tester);
    final before = library.folders().map((f) => f.id).toList();
    await tester.tap(find.text('排序'));
    await tester.pumpAndSettle();
    final widget =
        tester.widget<ReorderableListView>(find.byType(ReorderableListView));
    widget.onReorder(1, 3);
    await tester.pump();
    await tester.pageBack();
    await settleIO(tester);
    final after = library.folders().map((f) => f.id).toList();
    expect(after[2], before[1]);
    expect(after[1], before[2]);
    expect(find.byType(PixivFoldersPage), findsOneWidget);
  });
  testWidgets(
      'root folder offers default action but cannot be renamed or deleted',
      (tester) async {
    await showPage(tester);
    await tester.longPress(find.text('主目录'));
    await tester.pumpAndSettle();
    expect(find.text('重命名'), findsNothing);
    expect(find.text('删除'), findsNothing);
    expect(find.text('设为默认下载文件夹'), findsOneWidget);
  });
  testWidgets(
      'illustration long press selects actual items and copies the batch to one folder',
      (tester) async {
    late PixivFolder target;
    await tester.runAsync(() async {
      target = await library.createFolder('批量目标');
      final bytes = img.encodePng(img.Image(width: 12, height: 18));
      for (final n in [1, 2]) {
        await File(p.join(library.root, 'batch$n.png')).writeAsBytes(bytes);
        final db = PixivLibrary.openDownloads(library.root);
        try {
          db.execute('INSERT INTO download VALUES(?,?,?,?,?,?,?)', [
            'pixivwidget$n',
            '测试插画$n',
            '作者',
            1,
            'batch$n.png',
            1.0,
            jsonEncode({
              'id': 'pixivwidget$n',
              'name': '测试插画$n',
              'subTitle': '作者',
              'sourceKey': 'pixiv',
              'sourceName': 'Pixiv',
              'comicId': '$n',
              'tags': [],
              'cover': '',
              'downloadedEps': [0],
              'width': 12,
              'height': 18
            })
          ]);
        } finally {
          db.dispose();
        }
      }
      appdata.settings[155] = 'illust';
      appdata.settings[104] = 'local';
      setManagedDataSourceMode(managedDataSourceModeCurrentOnly);
      await LocalLibraryManager().refresh();
    });
    await tester
        .pumpWidget(const MaterialApp(home: LocalLibraryPage(albumOnly: true)));
    await settleIO(tester);
    expect(find.byType(IllustCard), findsNWidgets(2));
    await expectFolderCounts(
        tester, {'全部文件夹': 2, '主目录': 2, '批量目标': 0, '风景': 0});
    await tester.longPress(find.byType(IllustCard).first);
    await tester.pumpAndSettle();
    expect(find.text('已选择 1 个项目'), findsOneWidget);
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    expect(find.text('已选择 2 个项目'), findsOneWidget);
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制到…'));
    await settleIO(tester);
    await tester.tap(find.text('批量目标'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择'));
    await settleIO(tester);
    expect(find.text('成功 2，已存在 0，失败 0'), findsOneWidget);
    await tester.tap(find.text('完成'));
    await settleIO(tester);
    expect(library.records(target).length, 2);
    expect(library.records(library.folder('root')).length, 2);
    await expectFolderCounts(
        tester, {'全部文件夹': 4, '主目录': 2, '批量目标': 2, '风景': 0});
    await tester.tap(find.byTooltip('选择插画文件夹'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, '批量目标'));
    await settleIO(tester);
    expect(find.byType(IllustCard), findsNWidgets(2));

    // Simulate a removed download record, then use the real page refresh.
    await tester.runAsync(() async {
      final db = PixivLibrary.openDownloads(target.path);
      try {
        db.execute('DELETE FROM download WHERE id = ?', ['pixivwidget1']);
      } finally {
        db.dispose();
      }
    });
    await tester.tap(find.byIcon(Icons.refresh).first);
    await settleIO(tester);
    await expectFolderCounts(
        tester, {'全部文件夹': 3, '主目录': 2, '批量目标': 1, '风景': 0});
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await settleIO(tester);
  });

  testWidgets(
      'download pill delivers long-press without running ordinary download',
      (tester) async {
    var clicks = 0, longPresses = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: OnlineComicPillButton(
                label: '下载',
                onTap: () => clicks++,
                onLongPress: () => longPresses++))));
    await tester.longPress(find.text('下载'));
    await tester.pumpAndSettle();
    expect(longPresses, 1);
    expect(clicks, 0);
    await tester.tap(find.text('下载'));
    expect(clicks, 1);
  });
}

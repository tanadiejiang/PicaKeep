import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/illust_folder_preferences.dart';
import 'package:picakeep/foundation/pixiv_library.dart';
import 'package:picakeep/pages/illust_folder_selector.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _folders = [
  PixivFolder(
      root: '/pixiv',
      libraryId: 'library',
      id: 'root',
      name: '主目录',
      relativePath: '',
      count: 1),
  PixivFolder(
      root: '/pixiv',
      libraryId: 'library',
      id: 'stable-id',
      name: '很长的自定义收藏文件夹名称',
      relativePath: 'folder',
      count: 24),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final scope = IllustFolderPreferences.scope('/pixiv', 'library');
  setUp(() => SharedPreferences.setMockInitialValues({}));

  IllustFolderPreferences prefs() {
    final value = IllustFolderPreferences();
    addTearDown(value.dispose);
    return value;
  }

  test('restart retention is the default and survives a new instance',
      () async {
    final first = prefs();
    await first.load();
    expect(first.retention, IllustFolderRetention.restart);
    expect(first.selection(scope), isNull);
    await first.remember(scope, 'stable-id');
    await first.load(); // re-entry uses the same in-memory selection
    expect(first.selection(scope), 'stable-id');
    final second = prefs();
    await second.load();
    expect(second.selection(scope), 'stable-id');
  });

  test('session retention keeps re-entry but ignores saved choices on restart',
      () async {
    final first = prefs();
    await first.setRetention(IllustFolderRetention.session);
    await first.remember(scope, 'stable-id');
    await first.load();
    expect(first.selection(scope), 'stable-id');
    final second = prefs();
    await second.load();
    expect(second.retention, IllustFolderRetention.session);
    expect(second.selection(scope), isNull);
  });

  test(
      'switching session clears disk and switching back persists current choice',
      () async {
    final first = prefs();
    await first.remember(scope, 'old');
    await first.setRetention(IllustFolderRetention.session);
    expect(first.selection(scope), 'old');
    final disk = await SharedPreferences.getInstance();
    expect(
        jsonDecode(
            disk.getString(IllustFolderPreferences.storageKey)!)['selected'],
        isEmpty);
    await first.remember(scope, 'new');
    await first.setRetention(IllustFolderRetention.restart);
    final second = prefs();
    await second.load();
    expect(second.selection(scope), 'new');
  });

  test('root and library identity isolate selections, paths normalize',
      () async {
    final value = prefs();
    final otherRoot = IllustFolderPreferences.scope('/other', 'library');
    final otherLibrary = IllustFolderPreferences.scope('/pixiv', 'new-library');
    await value.remember(scope, 'stable-id');
    expect(value.selection(otherRoot), isNull);
    expect(value.selection(otherLibrary), isNull);
    expect(IllustFolderPreferences.scope('/pixiv/sub/..', 'library'), scope);
    await value.remember(otherRoot, 'other-id');
    expect(value.selection(scope), 'stable-id');
  });

  test('pending initial load never overwrites queued new selections', () async {
    final disk = await SharedPreferences.getInstance();
    await disk.setString(
        IllustFolderPreferences.storageKey,
        jsonEncode({
          'retention': 'restart',
          'selected': {scope: 'old'},
        }));
    final pending = Completer<SharedPreferences>();
    final value = IllustFolderPreferences(loader: () => pending.future);
    addTearDown(value.dispose);
    final loading = value.load();
    final choice1 = value.remember(scope, 'first');
    final choice2 = value.remember(scope, 'latest');
    pending.complete(disk);
    await Future.wait([loading, choice1, choice2]);
    expect(value.selection(scope), 'latest');
    final restarted = prefs();
    await restarted.load();
    expect(restarted.selection(scope), 'latest');
  });

  test('clearing selection is persistent and corrupted data falls back safely',
      () async {
    final value = prefs();
    await value.remember(scope, 'stable-id');
    await value.remember(scope, null);
    final restarted = prefs();
    await restarted.load();
    expect(restarted.selection(scope), isNull);
    final disk = await SharedPreferences.getInstance();
    await disk.setString(IllustFolderPreferences.storageKey, '{broken');
    final damaged = prefs();
    await damaged.load();
    expect(damaged.retention, IllustFolderRetention.restart);
    expect(damaged.selection(scope), isNull);
  });

  testWidgets(
      'menu is bounded on narrow dark screens and selection pops only menu',
      (tester) async {
    tester.view.physicalSize = const Size(320, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final choices = <String?>[];
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigator,
      theme: ThemeData.dark(),
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.7)),
          child: child!),
      home: const Scaffold(body: Text('上一页面')),
    ));
    navigator.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => Scaffold(
              appBar: AppBar(title: const Text('插画页面')),
              body: IllustFolderSelector(
                  folders: _folders,
                  totalCount: 27,
                  selectedId: 'root',
                  onSelected: choices.add,
                  onManage: () {}),
            )));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('选择插画文件夹'));
    await tester.pumpAndSettle();
    expect(find.text('全部文件夹'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    // All includes two entries from another managed root as well.
    expect(find.text('27'), findsOneWidget);
    await tester.tap(find.text('很长的自定义收藏文件夹名称'));
    await tester.pumpAndSettle();
    expect(choices, ['stable-id']);
    expect(find.text('插画页面'), findsOneWidget);
    expect(find.text('上一页面'), findsNothing);
    expect(find.text('全部文件夹'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'rename keeps stable selection and absent ID displays all folders',
      (tester) async {
    Widget build(List<PixivFolder> folders) => MaterialApp(
            home: Scaffold(
                body: IllustFolderSelector(
          folders: folders,
          totalCount: 25,
          selectedId: 'stable-id',
          onSelected: (_) {},
          onManage: () {},
        )));
    await tester.pumpWidget(build(_folders));
    expect(find.text('很长的自定义收藏文件夹名称'), findsOneWidget);
    await tester.pumpWidget(build(const [
      PixivFolder(
          root: '/pixiv',
          libraryId: 'library',
          id: 'stable-id',
          name: '改名后',
          relativePath: 'renamed'),
    ]));
    expect(find.text('改名后'), findsOneWidget);
    await tester.pumpWidget(build(const []));
    expect(find.text('全部文件夹'), findsOneWidget);
  });

  testWidgets('retention dialog changes policy without leaving page',
      (tester) async {
    final value = prefs();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
      appBar: AppBar(title: const Text('设置页面')),
      body: IllustFolderRetentionTile(preferences: value),
    )));
    await tester.pumpAndSettle();
    expect(find.text('重启后保持'), findsOneWidget);
    await tester.tap(find.text('记住插画文件夹'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('仅本次应用会话'));
    await tester.pumpAndSettle();
    expect(value.retention, IllustFolderRetention.session);
    expect(find.byType(SimpleDialog), findsNothing);
    expect(find.text('设置页面'), findsOneWidget);
  });

  testWidgets('retention read failure is visible and can retry',
      (tester) async {
    var reads = 0;
    final value = IllustFolderPreferences(loader: () async {
      if (++reads == 1) throw StateError('preferences temporarily unavailable');
      return SharedPreferences.getInstance();
    });
    addTearDown(value.dispose);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: IllustFolderRetentionTile(preferences: value))));
    await tester.pumpAndSettle();
    expect(find.text('读取失败，点击重试'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('读取失败，点击重试'));
    await tester.pumpAndSettle();
    expect(find.text('重启后保持'), findsOneWidget);
    expect(reads, 2);
  });
}

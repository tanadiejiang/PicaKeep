import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/components/pixiv_bookmark_feedback.dart';
import 'package:picakeep/components/pixiv_bookmark_queue.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/log.dart';
import 'package:picakeep/foundation/pixiv_bookmark_feedback_settings.dart';
import 'package:picakeep/pages/settings/settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _index = pixivBookmarkQueueCountsSettingIndex;
const _settingKey = ValueKey('pixiv-bookmark-queue-counts-setting');
const _captionKey = ValueKey('pixiv-bookmark-queue-caption');
const _feedbackKey = ValueKey('pixiv-bookmark-feedback');

class _Paths extends PathProviderPlatform {
  _Paths(this.root);

  final Directory root;

  Future<String> _dir(String name) async =>
      (await Directory(p.join(root.path, name)).create(recursive: true)).path;

  @override
  Future<String?> getApplicationCachePath() => _dir('cache');

  @override
  Future<String?> getApplicationSupportPath() => _dir('support');
}

Future<PackageInfo> _packageInfo() async => PackageInfo(
      appName: 'PicaKeep',
      packageName: 'lingxue.picakeep',
      version: 'test',
      buildNumber: '0',
    );

Widget _settingsPage() => const MaterialApp(
      home: Scaffold(
        body: SettingsPage(initialPage: 0, packageInfoLoader: _packageInfo),
      ),
    );

String _caption(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(_captionKey)).data!;

List<Object> _records(PixivBookmarkFeedbackController controller) => [
      for (final entry in controller.entries)
        (
          entry.operationId,
          entry.workId,
          entry.status,
          entry.text,
          entry.target,
          entry.isPrivate,
          entry.exiting,
          entry.settlementSequence,
        ),
    ];

class _HostFixture {
  late PixivBookmarkFeedbackController controller;
  final captureKey = GlobalKey();

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(fontFamily: 'VerificationSans036'),
      home: RepaintBoundary(
        key: captureKey,
        child: MediaQuery(
          data: const MediaQueryData(
            size: Size(375, 180),
            disableAnimations: true,
          ),
          child: Material(
            child: PixivBookmarkFeedbackHost(
              identity: 'account-A',
              child: Builder(builder: (context) {
                controller = PixivBookmarkFeedbackHost.maybeOf(context)!;
                return const SizedBox.expand();
              }),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  PixivBookmarkFeedbackTicket waiting(String workId) =>
      controller.capture(account: 'account-A', workId: workId)
        ..startWaiting(target: true);

  Future<void> capture(WidgetTester tester, String state) async {
    await tester.runAsync(() async {
      final boundary = captureKey.currentContext!.findRenderObject()
          as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1);
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final output = File(
          'docs/verification/pixiv-bookmark-queue-counts-036/counts-$state.png',
        );
        await output.parent.create(recursive: true);
        await output.writeAsBytes(bytes!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory workspace;
  late PathProviderPlatform savedPaths;
  late List<String> savedSettings;
  late File settingsFile;

  setUpAll(() async {
    savedPaths = PathProviderPlatform.instance;
    savedSettings = List.of(appdata.settings);
    final tempParent = Directory(p.join('.dart_tool', '036-temp')).absolute;
    await tempParent.create(recursive: true);
    workspace = await tempParent.createTemp('feedback-settings-');
    PathProviderPlatform.instance = _Paths(workspace);
    await App.init(dataPathOverride: p.join(workspace.path, 'data'));
    settingsFile = File(p.join(App.dataPath, 'settings'));
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    appdata.settings = List.of(Appdata().settings);
    // readSettings prioritizes disk over prefs. Only this test's isolated file
    // is removed, so each case actually reads its intended fixture.
    if (await settingsFile.exists()) {
      expect(p.dirname(settingsFile.absolute.path),
          p.join(workspace.path, 'data'));
      await settingsFile.delete();
    }
  });

  tearDown(() {
    appdata.settings = List.of(savedSettings);
  });

  tearDownAll(() async {
    appdata.settings = List.of(savedSettings);
    PathProviderPlatform.instance = savedPaths;
    expect(
      p.isWithin(Directory(p.join('.dart_tool', '036-temp')).absolute.path,
          workspace.absolute.path),
      isTrue,
    );
    await workspace.delete(recursive: true);
  });

  Future<void> expectPersisted(String raw) async {
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('settings')![_index], raw);
    final disk =
        List<String>.from(jsonDecode(await settingsFile.readAsString()));
    expect(disk[_index], raw);
    final fresh = Appdata();
    await fresh.readSettings(prefs);
    expect(fresh.settings[_index], raw);
    expect(showPixivBookmarkQueueCounts(fresh.settings), raw == '1');
  }

  Future<void> waitForSave(String raw) async {
    final prefs = await SharedPreferences.getInstance();
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (prefs.getStringList('settings')?.elementAtOrNull(_index) != raw) {
      if (DateTime.now().isAfter(deadline)) {
        fail('The production settings save did not persist $raw to prefs.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await expectPersisted(raw);
  }

  Future<void> waitForControlSave(WidgetTester tester, String raw) async {
    // SwitchSetting launches the production save without awaiting it. Let its
    // real file I/O finish; calling updateSettings here would hide a UI bug.
    await tester.runAsync(() => waitForSave(raw));
  }

  test('036 defaults are off; only exact 1 enables counts', () {
    expect(_index, 166);
    expect(Appdata().settings, hasLength(167));
    expect(Appdata().settings[_index], '0');
    expect(showPixivBookmarkQueueCounts(Appdata().settings), isFalse);
    for (final raw in <String?>[
      null,
      '',
      '0',
      'true',
      'yes',
      '2',
      '-1',
      ' 1',
      '1 '
    ]) {
      expect(normalizePixivBookmarkQueueCounts(raw), '0', reason: 'raw=$raw');
      if (raw != null) {
        final settings = List.of(Appdata().settings)..[_index] = raw;
        expect(showPixivBookmarkQueueCounts(settings), isFalse,
            reason: 'raw=$raw');
      }
    }
    expect(normalizePixivBookmarkQueueCounts('1'), '1');
    expect(
        showPixivBookmarkQueueCounts(
            List.of(Appdata().settings)..[_index] = '1'),
        isTrue);
    for (final length in [0, 20, 151, 166]) {
      expect(showPixivBookmarkQueueCounts(List.filled(length, '1')), isFalse);
    }
  });

  testWidgets('real Browse settings switch defaults off, saves on and off',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(375, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_settingsPage());
    await tester.pumpAndSettle();

    final entry = find.byKey(_settingKey);
    expect(entry, findsOneWidget);
    final setting = tester.widget<SwitchSetting>(entry);
    expect(setting.title, '显示 Pixiv 收藏队列数量');
    expect(setting.subTitle, '在收藏悬浮提示中显示等待、完成和失败数量');
    expect(setting.settingsIndex, _index);
    expect(find.text('在线浏览'), findsOneWidget);
    final entryY = tester.getTopLeft(entry).dy;
    expect(entryY, greaterThan(tester.getTopLeft(find.text('在线浏览')).dy));
    expect(entryY, lessThan(tester.getTopLeft(find.text('阅读器')).dy));

    await tester.ensureVisible(entry);
    await tester.pumpAndSettle();
    final control = find.descendant(of: entry, matching: find.byType(Switch));
    expect(tester.widget<Switch>(control).value, isFalse);
    final version = App.displaySettingsVersion.value;
    final preserved = appdata.settings[148] = '036-preserved-existing-value';

    await tester.runAsync(() => tester.tap(control));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(control).value, isTrue);
    expect(appdata.settings[_index], '1');
    expect(App.displaySettingsVersion.value, version + 1);
    await waitForControlSave(tester, '1');
    expect(appdata.settings[148], preserved);

    await tester.runAsync(() => tester.tap(control));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(control).value, isFalse);
    expect(App.displaySettingsVersion.value, version + 2);
    await waitForControlSave(tester, '0');
    expect(appdata.settings[148], preserved);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final length in [166, 151, 20]) {
    test('legacy in-memory length $length updates to 167 preserving old values',
        () async {
      final data = Appdata();
      data.settings = data.settings.take(length).toList();
      data.settings[0] = '036-custom-first';
      data.settings[length > 148 ? 148 : 18] = '036-custom-existing';
      // 165 already has a migration rule. Seed its canonical value before the
      // snapshot so this test measures appending 166, not that older migration.
      if (length == 166) {
        await data.updateSettings();
        data.settings = data.settings.take(length).toList();
      }
      final previous = List.of(data.settings);
      await data.updateSettings();
      expect(data.settings, hasLength(167));
      expect(data.settings.take(length), previous);
      expect(data.settings[_index], '0');
      await expectPersisted('0');
    });
  }

  for (final source in ['prefs', 'disk']) {
    test('$source read normalizes invalid value and missing old setting to off',
        () async {
      final prefs = await SharedPreferences.getInstance();
      for (final raw in ['1', 'true', ' 1', '', '0']) {
        final stored = List.of(Appdata().settings)..[_index] = raw;
        if (source == 'prefs') {
          if (await settingsFile.exists()) await settingsFile.delete();
          await prefs.setStringList('settings', stored);
        } else {
          await prefs.setStringList(
              'settings', List.of(Appdata().settings)..[_index] = '1');
          await settingsFile.writeAsString(jsonEncode(stored));
        }
        final data = Appdata()..settings[_index] = '1';
        await data.readSettings(prefs);
        expect(data.settings[_index], raw == '1' ? '1' : '0');
        expect(showPixivBookmarkQueueCounts(data.settings), raw == '1');
      }
      for (final length in [166, 20]) {
        final legacy = Appdata().settings.take(length).toList();
        legacy[0] = '036-legacy-first';
        if (source == 'prefs') {
          if (await settingsFile.exists()) await settingsFile.delete();
          await prefs.setStringList('settings', legacy);
        } else {
          await prefs.setStringList(
              'settings', List.of(Appdata().settings)..[_index] = '1');
          await settingsFile.writeAsString(jsonEncode(legacy));
        }
        final data = Appdata()..settings[_index] = '1';
        await data.readSettings(prefs);
        expect(data.settings, hasLength(167));
        expect(data.settings[0], '036-legacy-first');
        expect(data.settings[_index], '0',
            reason: 'Missing old field overrides a previous on value.');
        await expectPersisted('0');
      }
    });
  }

  test('updateSettings normalizes an invalid value before both saves',
      () async {
    final data = Appdata()..settings[_index] = 'true';
    await data.updateSettings();
    expect(data.settings[_index], '0');
    await expectPersisted('0');
  });

  test(
      'JSON import enables exact 1; old missing and invalid fields turn it off',
      () async {
    final data = Appdata();
    for (final stored in [
      List.of(Appdata().settings)..[_index] = '1',
      Appdata().settings.take(166).toList(),
      List.of(Appdata().settings)..[_index] = 'true',
      Appdata().settings.take(20).toList(),
    ]) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('settings');
      if (await settingsFile.exists()) await settingsFile.delete();
      data.settings[_index] = '1';
      final expected = stored.elementAtOrNull(_index) == '1' ? '1' : '0';
      final imported = data.readDataFromJson(jsonDecode(jsonEncode({
        'settings': stored,
        'firstUse': List.of(data.firstUse),
        'blockingKeywords': <String>[],
        'favoriteTags': <String>[],
      })) as Map<String, dynamic>);
      expect(imported, isTrue,
          reason: LogManager.logs
              .where((log) => log.title == 'Appdata.readDataFromJson')
              .map((log) => log.content)
              .join('\n'));
      expect(data.settings, hasLength(167));
      expect(data.settings[_index], expected);
      // Import launches its own writeData; verify that save without performing
      // another write that could conceal a missing import persistence call.
      await waitForSave(expected);
    }
  });

  testWidgets(
      'capsule hides mixed-result counts by default but keeps semantics',
      (tester) async {
    final semantics = tester.ensureSemantics();
    const entries = [
      PixivBookmarkQueueEntry(
        operationId: 1,
        workId: 'a',
        status: PixivBookmarkQueueStatus.waiting,
        text: '正在提交收藏…',
        target: true,
      ),
      PixivBookmarkQueueEntry(
        operationId: 2,
        workId: 'b',
        status: PixivBookmarkQueueStatus.completed,
        text: '已添加公开收藏',
        target: true,
        settlementSequence: 1,
      ),
      PixivBookmarkQueueEntry(
        operationId: 3,
        workId: 'c',
        status: PixivBookmarkQueueStatus.failed,
        text: '收藏失败：离线 fixture',
        target: true,
        settlementSequence: 2,
      ),
    ];
    Widget view({bool showCounts = false}) => MaterialApp(
          home: Center(
              child: PixivBookmarkQueueCapsule(
            entries: entries,
            reducedMotion: true,
            showCounts: showCounts,
          )),
        );
    await tester.pumpWidget(view());
    expect(_caption(tester), '收藏失败：离线 fixture');
    final label = tester.getSemantics(find.byKey(_feedbackKey)).label;
    expect(label, '1 项等待 · 1 项完成 · 1 项失败。收藏失败：离线 fixture');
    await tester.pumpWidget(view(showCounts: true));
    expect(_caption(tester), '1 项等待 · 1 项完成 · 1 项失败 · 收藏失败：离线 fixture');
    expect(tester.getSemantics(find.byKey(_feedbackKey)).label, label);
    expect(tester.takeException(), isNull);
    semantics.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Host instantly toggles waiting3 counts without changing tickets',
      (tester) async {
    tester.view.physicalSize = const Size(375, 180);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      final font = File('C:/Windows/Fonts/msyh.ttc');
      final icons =
          File('build/unit_test_assets/fonts/MaterialIcons-Regular.otf');
      if (font.existsSync() && icons.existsSync()) {
        await (FontLoader('VerificationSans036')
              ..addFont(
                  Future.value(ByteData.sublistView(await font.readAsBytes()))))
            .load();
        await (FontLoader('MaterialIcons')
              ..addFont(Future.value(
                  ByteData.sublistView(await icons.readAsBytes()))))
            .load();
      }
    });
    final fixture = _HostFixture();
    await fixture.pump(tester);
    final semantics = tester.ensureSemantics();
    final tickets = [
      for (final id in ['A', 'B', 'C']) fixture.waiting(id)
    ];
    await tester.pump();
    expect(_caption(tester), '正在提交收藏…');
    expect(tester.binding.transientCallbackCount, 0);
    final controller = fixture.controller;
    final epoch = controller.visualEpoch;
    final records = _records(controller);
    final operationIds =
        controller.entries.map((entry) => entry.operationId).toList();
    final itemStates = [
      for (final id in operationIds)
        tester.state(find.byKey(ValueKey('pixiv-bookmark-queue-item-$id'))),
    ];
    final label = tester.getSemantics(find.byKey(_feedbackKey)).label;
    expect(label, '3 项等待 · 0 项完成。正在提交收藏…');
    await fixture.capture(tester, 'off');
    var queueNotifications = 0;
    void notified() => queueNotifications++;
    controller.addListener(notified);

    for (final show in [true, false]) {
      appdata.settings[_index] = show ? '1' : '0';
      App.notifyDisplaySettingsChanged();
      await tester.pump();
      expect(_caption(tester), show ? '3 项等待 · 0 项完成 · 正在提交收藏…' : '正在提交收藏…');
      expect(fixture.controller, same(controller));
      expect(controller.visualEpoch, epoch);
      expect(_records(controller), records);
      expect(
          controller.entries.map((entry) => entry.operationId), operationIds);
      expect(tickets.every((ticket) => ticket.isCurrent), isTrue);
      expect(queueNotifications, 0);
      for (var i = 0; i < operationIds.length; i++) {
        expect(
            tester.state(find.byKey(
                ValueKey('pixiv-bookmark-queue-item-${operationIds[i]}'))),
            same(itemStates[i]));
      }
      expect(tester.getSemantics(find.byKey(_feedbackKey)).label, label);
      expect(tester.binding.transientCallbackCount, 0);
      if (show) await fixture.capture(tester, 'on');
    }
    controller.removeListener(notified);
    semantics.dispose();
    await fixture.unmount(tester);
    // A disposed Host must have removed its display-settings listener.
    App.notifyDisplaySettingsChanged();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'display toggles preserve the completed head exact 1999/1 deadline',
      (tester) async {
    final fixture = _HostFixture();
    await fixture.pump(tester);
    final tickets = [
      for (final id in ['A', 'B', 'C']) fixture.waiting(id)
    ];
    await tester.pump();
    expect(tickets.first.finish(const PixivBookmarkFeedbackMessage.added()),
        isTrue);
    await tester.pump();
    final epoch = fixture.controller.visualEpoch;
    final records = _records(fixture.controller);
    final operationIds =
        fixture.controller.entries.map((entry) => entry.operationId).toList();
    expect(_caption(tester), '已添加公开收藏');

    await tester.pump(const Duration(milliseconds: 700));
    appdata.settings[_index] = '1';
    App.notifyDisplaySettingsChanged();
    await tester.pump();
    expect(_caption(tester), '2 项等待 · 1 项完成 · 已添加公开收藏');
    expect(_records(fixture.controller), records);
    expect(fixture.controller.visualEpoch, epoch);
    expect(tickets.every((ticket) => ticket.isCurrent), isTrue);

    await tester.pump(const Duration(milliseconds: 1299));
    expect(fixture.controller.entries, hasLength(3),
        reason: 'Still retained at t=1999ms.');
    appdata.settings[_index] = '0';
    App.notifyDisplaySettingsChanged();
    await tester.pump();
    expect(_caption(tester), '已添加公开收藏');
    expect(_records(fixture.controller), records);
    expect(fixture.controller.visualEpoch, epoch);
    expect(tickets.every((ticket) => ticket.isCurrent), isTrue);
    expect(tester.binding.transientCallbackCount, 0);

    await tester.pump(const Duration(milliseconds: 1));
    expect(fixture.controller.entries.map((entry) => entry.operationId),
        operationIds.skip(1),
        reason:
            'Original completed hold expires at t=2000ms despite both toggles.');
    expect(
        fixture.controller.entries
            .every((entry) => entry.status == PixivBookmarkQueueStatus.waiting),
        isTrue);
    expect(fixture.controller.visualEpoch, epoch);
    expect(tickets.every((ticket) => ticket.isCurrent), isTrue);
    expect(_caption(tester), '正在提交收藏…');
    expect(tester.binding.transientCallbackCount, 0);
    await fixture.unmount(tester);
  });
}

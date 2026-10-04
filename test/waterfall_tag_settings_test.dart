import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/comic_tile_display_config.dart';
import 'package:picakeep/pages/settings/settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempRoot;
  setUpAll(() async {
    tempRoot = await Directory.systemTemp.createTemp('pk-waterfall-settings-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => tempRoot.path);
    await App.init(dataPathOverride: tempRoot.path);
  });
  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'), null);
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    appdata.settings[comicTileDisplayConfigSettingIndex] = '{}';
  });

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
      builder: (context) => TextButton(
          onPressed: () => showWaterfallTagSettings(context),
          child: const Text('打开')),
    ))));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  testWidgets('取消不保存、不发刷新；重新打开仍是旧配置', (tester) async {
    final version = App.displaySettingsVersion.value;
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('waterfall-local-switch')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('waterfall-local-row-1')));
    await tester.pump();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(appdata.settings[comicTileDisplayConfigSettingIndex], '{}');
    expect(App.displaySettingsVersion.value, version);
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<SwitchListTile>(
                find.byKey(const ValueKey('waterfall-local-switch')))
            .value,
        isFalse);
    expect(
        tester
            .widget<ChoiceChip>(
                find.byKey(const ValueKey('waterfall-local-row-2')))
            .selected,
        isTrue);
  });

  testWidgets('确定分别保存两组并通知，保留编辑过程中更新的普通卡片配置', (tester) async {
    final version = App.displaySettingsVersion.value;
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('waterfall-local-switch')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('waterfall-local-row-1')));
    await tester.pump();
    await tester.ensureVisible(
        find.byKey(const ValueKey('waterfall-pixivAuthor-switch')));
    await tester
        .tap(find.byKey(const ValueKey('waterfall-pixivAuthor-switch')));
    await tester.pump();
    await tester.ensureVisible(
        find.byKey(const ValueKey('waterfall-pixivAuthor-row-3')));
    await tester.tap(find.byKey(const ValueKey('waterfall-pixivAuthor-row-3')));
    await tester.pump();
    await tester.runAsync(() async {
      await writeComicTileDisplayConfig(
          scope: 'search', sourceKey: 'pixiv', tagRows: 3);
      await tester.tap(find.text('确定'));
      // This dialog saves an actual file before SharedPreferences. Run the
      // operation outside the fake clock, then verify the completed UI below.
      for (var attempt = 0;
          attempt < 100 && App.displaySettingsVersion.value == version;
          attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();
    final saved = readComicTileDisplaySettings();
    expect(saved.localIllustTags,
        const WaterfallTagDisplayConfig(showTags: true, tagRows: 1));
    expect(saved.pixivAuthorTags,
        const WaterfallTagDisplayConfig(showTags: true, tagRows: 3));
    expect(saved.search('pixiv').tagRows, 3);
    expect(App.displaySettingsVersion.value, version + 1);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('推荐不限与收藏颜色透明度确定后保存，取消不改设置', (tester) async {
    final version = App.displaySettingsVersion.value;
    await open(tester);
    final rows = find.byKey(const ValueKey('waterfall-recommend-row-0'));
    await tester.ensureVisible(rows);
    await tester.tap(rows);
    await tester.pump();
    final color = find.byKey(const ValueKey('waterfall-favorite-color-theme'));
    await tester.ensureVisible(color);
    await tester.tap(color);
    await tester.pump();
    final opacity = find.byKey(const ValueKey('waterfall-favorite-opacity-60'));
    await tester.ensureVisible(opacity);
    await tester.tap(opacity);
    await tester.pump();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(appdata.settings[comicTileDisplayConfigSettingIndex], '{}');
    expect(App.displaySettingsVersion.value, version);
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(rows);
    await tester.tap(rows);
    await tester.pump();
    await tester.ensureVisible(color);
    await tester.tap(color);
    await tester.pump();
    await tester.ensureVisible(opacity);
    await tester.tap(opacity);
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.text('确定'));
      for (var attempt = 0;
          attempt < 100 && App.displaySettingsVersion.value == version;
          attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();
    final saved = readComicTileDisplaySettings();
    expect(saved.recommendTags.showTags, isTrue);
    expect(saved.recommendTags.maxTagRows, isNull);
    expect(saved.favoriteStyle,
        const WaterfallFavoriteStyle(color: 'theme', opacity: 60));
    expect(saved.localIllustTags, WaterfallTagDisplayConfig.defaults);
    expect(saved.pixivAuthorTags, WaterfallTagDisplayConfig.defaults);
    expect(App.displaySettingsVersion.value, version + 1);
  });

  testWidgets('纯编辑器支持窄屏与大字体，改变一组不影响另一组', (tester) async {
    WaterfallTagDisplayConfig? changedLocal, changedAuthor;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: MediaQuery(
      data: const MediaQueryData(textScaler: TextScaler.linear(1.8)),
      child: SingleChildScrollView(
          child: SizedBox(
        width: 200,
        child: WaterfallTagSettingsEditor(
          initialLocal: WaterfallTagDisplayConfig.defaults,
          initialPixivAuthor: WaterfallTagDisplayConfig.defaults,
          onChanged: (local, author) {
            changedLocal = local;
            changedAuthor = author;
          },
        ),
      )),
    ))));
    await tester
        .ensureVisible(find.byKey(const ValueKey('waterfall-local-row-3')));
    await tester.tap(find.byKey(const ValueKey('waterfall-local-row-3')));
    expect(changedLocal?.tagRows, 3);
    expect(changedAuthor, WaterfallTagDisplayConfig.defaults);
    await tester.ensureVisible(
        find.byKey(const ValueKey('waterfall-favorite-opacity-50')));
    await tester
        .tap(find.byKey(const ValueKey('waterfall-favorite-opacity-50')));
    expect(tester.takeException(), isNull);
    expect(appdata.settings[comicTileDisplayConfigSettingIndex], '{}');
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/components/comic_tile.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/comic_tile_display_config.dart';
import 'package:picakeep/foundation/download_author_resolver.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 13 号计划：卡片信息显示配置（本地收藏一套 / 在线收藏一套 / 搜索页按源）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const settingIndex = comicTileDisplayConfigSettingIndex;

  late Directory tempRoot;

  setUpAll(() async {
    // `Appdata.readSettings` 会先看 `${App.dataPath}/settings` 这个文件，
    // `updateSettings` 会写它。测试里 App 从未初始化，dataPath 是 late final
    // 未赋值状态，一碰就抛 LateInitializationError —— 于是把 path_provider 的
    // 平台通道 mock 到临时目录，让这两条真实文件路径也一并被测到。
    tempRoot = await Directory.systemTemp.createTemp('pk-card-display-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tempRoot.path,
    );
    await App.init(dataPathOverride: tempRoot.path);
  });

  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (tempRoot.existsSync()) {
      try {
        tempRoot.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  setUp(() {
    // 配置读取是纯函数式（按 settings 索引 150 的原始字符串），不依赖数据库。
    appdata.settings[settingIndex] = '{}';
  });

  tearDown(() {
    appdata.settings[settingIndex] = '{}';
  });

  void setRaw(String raw) {
    appdata.settings[settingIndex] = raw;
  }

  group('X03 新索引默认值', () {
    test('索引 150 存在且默认值为空对象', () {
      expect(settingIndex, 150);
      expect(appdata.settings.length, greaterThan(settingIndex));
      expect(appdata.settings[settingIndex], '{}');
    });

    test('全新安装读到的就是"升级前观感"的三个默认值', () {
      final config = readLocalComicTileDisplayConfig();
      expect(config.tagRows, 2);
      expect(config.showTags, isTrue);
      expect(config.showId, isTrue);

      final online = readOnlineComicTileDisplayConfig();
      expect(online, ComicTileDisplayConfig.defaults);

      final search = readSearchComicTileDisplayConfig('jm');
      expect(search, ComicTileDisplayConfig.defaults);
    });
  });

  group('X04 老配置补齐', () {
    test('旧 settings 列表补齐后新索引有默认值且不抛异常', () async {
      // readSettings 优先读 `${App.dataPath}/settings` 文件；先清掉它，否则会读到
      // 同一测试文件里前序用例 updateSettings 写下的真实配置，而不是下面构造的旧列表。
      final settingsFile = File('${App.dataPath}/settings');
      if (settingsFile.existsSync()) {
        settingsFile.deleteSync();
      }
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = await SharedPreferences.getInstance();

      // 模拟升级前用户：旧列表在索引 150 之前就结束了，且已存在的最后一项
      // （索引 148）是用户自己的取值。切片长度必须**小于** settingIndex，
      // 否则会把索引 149 也当成"用户旧值"，测出与需求无关的差异。
      final data = Appdata();
      const legacyLength = settingIndex - 1;
      final legacy = List<String>.filled(legacyLength, '1');
      for (var i = 0; i < legacy.length; i++) {
        data.settings[i] = legacy[i];
      }
      // readSettings 会把旧列表逐项搬进来，其余保持默认值（即自动补齐）。
      await data.readSettings(prefs);

      expect(data.settings.length, greaterThan(settingIndex));

      // 补齐语义：索引 150 在旧列表里不存在，必须由默认值补齐为 '{}'。
      expect(data.settings[settingIndex], '{}',
          reason: '新索引必须由默认值补齐');

      // 旧列表覆盖到的最后一项（索引 148）必须是用户自己的值，不能被默认值冲掉。
      expect(data.settings[legacyLength - 1], '1',
          reason: '用户已有的设置项不得被默认值改写');

      // 旧列表之后的索引（149）保留默认值 '0'（AI 自动下载默认关闭）。
      expect(data.settings[149], '0',
          reason: '旧列表未覆盖的索引必须保持默认值，不得被补齐逻辑污染');
    });
  });

  group('X05 页面隔离', () {
    test('只改 search/jm 不影响 local / online / search/ehentai', () async {
      await writeComicTileDisplayConfig(
        scope: comicTileDisplaySearchPageKey,
        sourceKey: 'jm',
        tagRows: 3,
        showTags: false,
        showId: false,
      );

      expect(readSearchComicTileDisplayConfig('jm').tagRows, 3);
      expect(readSearchComicTileDisplayConfig('jm').showTags, isFalse);
      expect(readSearchComicTileDisplayConfig('jm').showId, isFalse);

      expect(readLocalComicTileDisplayConfig(),
          ComicTileDisplayConfig.defaults);
      expect(readOnlineComicTileDisplayConfig(),
          ComicTileDisplayConfig.defaults);
      expect(readSearchComicTileDisplayConfig('ehentai'),
          ComicTileDisplayConfig.defaults);
    });

    test('只改 local 不影响 online / search', () async {
      await writeComicTileDisplayConfig(
        scope: comicTileDisplayLocalPageKey,
        tagRows: 0,
      );

      expect(readLocalComicTileDisplayConfig().tagRows, 0);
      expect(readLocalComicTileDisplayConfig().maxTagRows, isNull,
          reason: '不限行时必须交给卡片的可选布局');
      expect(readOnlineComicTileDisplayConfig().tagRows, 2);
      expect(readSearchComicTileDisplayConfig('jm').tagRows, 2);
      expect(readSearchComicTileDisplayConfig('nhentai').tagRows, 2);
    });

    test('逐字段写入时未传的字段沿用该节点当前值', () async {
      await writeComicTileDisplayConfig(
        scope: comicTileDisplayLocalPageKey,
        showTags: false,
      );
      await writeComicTileDisplayConfig(
        scope: comicTileDisplayLocalPageKey,
        showId: false,
      );

      final config = readLocalComicTileDisplayConfig();
      expect(config.showTags, isFalse, reason: '第二次写入不得把 showTags 冲回默认');
      expect(config.showId, isFalse);
      expect(config.tagRows, 2);
      expect(readOnlineComicTileDisplayConfig(),
          ComicTileDisplayConfig.defaults);
    });

    test('写入只改目标节点，不动其它页面/源的既有 JSON', () async {
      await writeComicTileDisplayConfig(
        scope: comicTileDisplaySearchPageKey,
        sourceKey: 'nhentai',
        tagRows: 3,
      );
      await writeComicTileDisplayConfig(
        scope: comicTileDisplayOnlinePageKey,
        showId: false,
      );

      expect(readSearchComicTileDisplayConfig('nhentai').tagRows, 3,
          reason: '写 online 时不得丢掉 search/nhentai');
      expect(readOnlineComicTileDisplayConfig().showId, isFalse);
    });
  });

  group('X05b 搜索页按源隔离', () {
    test('写 search/jm 后四个源互不影响', () async {
      await writeComicTileDisplayConfig(
        scope: comicTileDisplaySearchPageKey,
        sourceKey: 'jm',
        tagRows: 3,
      );

      expect(readSearchComicTileDisplayConfig('jm').tagRows, 3);
      for (final source in const ['ehentai', 'nhentai', 'picacg']) {
        expect(
          readSearchComicTileDisplayConfig(source),
          ComicTileDisplayConfig.defaults,
          reason: '$source 不应被 jm 的改动影响',
        );
      }
    });

    test('源 key 大小写不一致时指向同一套配置，未知源回退默认值', () async {
      await writeComicTileDisplayConfig(
        scope: comicTileDisplaySearchPageKey,
        sourceKey: 'JM',
        tagRows: 3,
      );

      expect(readSearchComicTileDisplayConfig('jm').tagRows, 3);
      expect(readSearchComicTileDisplayConfig(' Jm ').tagRows, 3);
      expect(readSearchComicTileDisplayConfig('unknown-source'),
          ComicTileDisplayConfig.defaults);
      expect(readSearchComicTileDisplayConfig(''),
          ComicTileDisplayConfig.defaults);
    });

    test('缺少源 key 时写入是空操作，不产生空 key 节点', () async {
      await writeComicTileDisplayConfig(
        scope: comicTileDisplaySearchPageKey,
        tagRows: 3,
      );

      expect(appdata.settings[settingIndex], '{}');
      expect(readSearchComicTileDisplayConfig('jm').tagRows, 2);
    });
  });

  group('X06 逐层回退与损坏容错', () {
    test('search 下缺该源节点时回退默认值', () {
      setRaw(jsonEncode(<String, Object?>{
        'search': <String, Object?>{
          'jm': <String, Object?>{'tagRows': 3},
        },
      }));

      expect(readSearchComicTileDisplayConfig('jm').tagRows, 3);
      expect(readSearchComicTileDisplayConfig('picacg'),
          ComicTileDisplayConfig.defaults);
    });

    test('空串 / 损坏 JSON / 非对象 / 空对象一律回退默认值且不抛异常', () {
      for (final raw in const <String>[
        '',
        '   ',
        'not-json{{',
        '[]',
        '"a string"',
        '42',
        'null',
        '{}',
      ]) {
        setRaw(raw);
        expect(
          readComicTileDisplaySettings(),
          ComicTileDisplaySettings.defaults,
          reason: 'raw=$raw 必须回退默认值',
        );
        expect(readLocalComicTileDisplayConfig().tagRows, 2, reason: 'raw=$raw');
      }
    });

    test('节点类型异常时该节点回退默认值，其它节点不受影响', () {
      setRaw(jsonEncode(<String, Object?>{
        'local': 'not-a-map',
        'online': <String, Object?>{'showTags': 'yes'},
        'search': 'not-a-map',
      }));

      expect(readLocalComicTileDisplayConfig(),
          ComicTileDisplayConfig.defaults);
      expect(readOnlineComicTileDisplayConfig(),
          ComicTileDisplayConfig.defaults);
      expect(readSearchComicTileDisplayConfig('jm'),
          ComicTileDisplayConfig.defaults);
    });

    test('非法 tagRows（越界 / 类型不符 / 负数）回退默认行数', () {
      for (final raw in <Object?>[1, 4, 99, -1, 2.5, '3', null, true]) {
        setRaw(jsonEncode(<String, Object?>{
          'local': <String, Object?>{'tagRows': raw},
        }));
        expect(
          readLocalComicTileDisplayConfig().tagRows,
          2,
          reason: 'tagRows=$raw 不是 2/3/不限，必须回退',
        );
      }

      // 合法值照旧生效。
      for (final raw in const <int>[2, 3, 0]) {
        setRaw(jsonEncode(<String, Object?>{
          'local': <String, Object?>{'tagRows': raw},
        }));
        expect(readLocalComicTileDisplayConfig().tagRows, raw);
      }
    });

    test('写入能修复损坏的配置', () async {
      setRaw('not-json{{');

      await writeComicTileDisplayConfig(
        scope: comicTileDisplayLocalPageKey,
        tagRows: 3,
      );

      expect(readLocalComicTileDisplayConfig().tagRows, 3);
      expect(jsonDecode(appdata.settings[settingIndex]), isA<Map>());
    });

    test('settings 索引缺失时读默认值，写入会补齐索引', () async {
      final saved = appdata.settings.length;
      appdata.settings.removeRange(settingIndex, appdata.settings.length);
      addTearDown(() {
        while (appdata.settings.length < saved) {
          appdata.settings.add('');
        }
        appdata.settings[settingIndex] = '{}';
      });

      expect(readLocalComicTileDisplayConfig(),
          ComicTileDisplayConfig.defaults);

      await writeComicTileDisplayConfig(
        scope: comicTileDisplayLocalPageKey,
        tagRows: 3,
      );
      expect(appdata.settings.length, greaterThan(settingIndex));
      expect(readLocalComicTileDisplayConfig().tagRows, 3);
    });

    test('保存整份配置会洗掉非法字段', () async {
      setRaw(jsonEncode(<String, Object?>{
        'local': <String, Object?>{'tagRows': 99, 'showTags': 'yes'},
        'search': <String, Object?>{
          'jm': <String, Object?>{'showId': false},
        },
      }));

      await saveComicTileDisplaySettings(readComicTileDisplaySettings());

      expect(readLocalComicTileDisplayConfig(),
          ComicTileDisplayConfig.defaults);
      expect(readSearchComicTileDisplayConfig('jm').showId, isFalse);
    });
  });

  group('X07 标签行数生效', () {
    // 行数配置要生效，卡片高度必须够：定高卡片下标签区还受可用高度二次裁剪
    // （_LimitedTagWrap 按 maxHeight 提前收行），164dp 高度时 2 行与 3 行都会
    // 被裁剪到同一结果——那是设计上的溢出保护，不是配置失效。故此处用足够
    // 高度，单独验证"行数上限"这一维。
    const tallCard = 320.0;

    testWidgets('配置 tagRows=2 → 最多 2 行', (tester) async {
      final rows = await _renderedTagRows(
        tester,
        config: const ComicTileDisplayConfig(
          tagRows: 2,
          showTags: true,
          showId: true,
        ),
        height: tallCard,
      );
      expect(rows, 2, reason: '高度充足时必须恰好用满 2 行上限');
    });

    testWidgets('配置 tagRows=3 → 比 2 行显示更多标签，且最多 3 行', (tester) async {
      const twoRows = ComicTileDisplayConfig(
        tagRows: 2,
        showTags: true,
        showId: true,
      );
      const threeRows = ComicTileDisplayConfig(
        tagRows: 3,
        showTags: true,
        showId: true,
      );

      final twoRowCount =
          await _renderedTagCount(tester, config: twoRows, height: tallCard);
      final threeRowCount =
          await _renderedTagCount(tester, config: threeRows, height: tallCard);
      expect(threeRowCount, greaterThan(twoRowCount),
          reason: '3 行配置必须比 2 行配置多显示标签（2 行=$twoRowCount）');

      final rows = await _renderedTagRows(
        tester,
        config: threeRows,
        height: tallCard,
      );
      expect(rows, 3);
    });

    testWidgets('标签区高度不足时按可用高度收行，不把描述位挤出卡片',
        (tester) async {
      // 定高 164dp + 30 个标签：行数上限给到 3，但高度只够 2 行。
      final rows = await _renderedTagRows(
        tester,
        config: const ComicTileDisplayConfig(
          tagRows: 3,
          showTags: true,
          showId: true,
        ),
      );
      expect(rows, lessThanOrEqualTo(3));
      expect(find.text('128 MB'), findsOneWidget);
    });

    testWidgets('配置不限行（tagRows=0）→ 同高度下比 3 行配置显示更多标签',
        (tester) async {
      const unlimited = ComicTileDisplayConfig(
        tagRows: 0,
        showTags: true,
        showId: true,
      );
      const threeRows = ComicTileDisplayConfig(
        tagRows: 3,
        showTags: true,
        showId: true,
      );

      final unlimitedCount =
          await _renderedTagCount(tester, config: unlimited, height: tallCard);
      final threeRowCount =
          await _renderedTagCount(tester, config: threeRows, height: tallCard);

      expect(unlimitedCount, greaterThan(threeRowCount),
          reason: '不限行($unlimitedCount) 必须比 3 行($threeRowCount) 显示更多');
      expect(unlimited.maxTagRows, isNull,
          reason: '不限行必须把 maxTagRows 交给卡片的可选布局');
    });
  });

  group('X08 显示标签开关', () {
    testWidgets('关闭后不渲染任何标签，描述位仍在', (tester) async {
      final tags = List<String>.generate(6, (index) => 'tag-$index');
      await tester.pumpWidget(
        _tile(
          tags: tags,
          config: const ComicTileDisplayConfig(
            tagRows: 2,
            showTags: false,
            showId: true,
          ),
        ),
      );

      for (final tag in tags) {
        expect(find.text(tag), findsNothing);
      }
      expect(find.text('128 MB'), findsOneWidget);
      expect(find.text('Always visible author'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('开启时标签照常渲染（同参数对照）', (tester) async {
      final tags = List<String>.generate(6, (index) => 'tag-$index');
      await tester.pumpWidget(
        _tile(
          tags: tags,
          config: const ComicTileDisplayConfig(
            tagRows: 2,
            showTags: true,
            showId: true,
          ),
        ),
      );

      expect(find.text(tags.first), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('不传配置时保持历史行为：标签不限制、始终渲染', (tester) async {
      final tags = List<String>.generate(6, (index) => 'tag-$index');
      await tester.pumpWidget(_tile(tags: tags, height: 300));
      for (final tag in tags) {
        expect(find.text(tag), findsOneWidget);
      }
    });
  });

  group('X09 显示来源 id 开关', () {
    test('showId=false 时 JM / NH 描述位不再回退标识号', () {
      expect(
        displaySourceInfoLine(
          source: 'jm',
          comicId: '1466163',
          description: '',
          showId: false,
        ),
        isEmpty,
      );
      expect(
        displaySourceInfoLine(
          source: 'nhentai',
          comicId: '605366',
          description: '',
          showId: false,
        ),
        isEmpty,
      );
    });

    test('有简介时开关不影响简介显示', () {
      for (final source in const ['jm', 'nhentai', 'picacg', 'ehentai']) {
        expect(
          displaySourceInfoLine(
            source: source,
            comicId: '1466163',
            description: '作品简介',
            showId: false,
          ),
          '作品简介',
        );
      }
    });

    test('showId 默认开启，保持历史回退行为', () {
      expect(
        displaySourceInfoLine(source: 'jm', comicId: '1466163', description: ''),
        'jm1466163',
      );
    });
  });

  group('角标尺寸（两条布局分支必须一致）', () {
    testWidgets('有限布局分支（maxTagRows 有值）用紧凑角标', (tester) async {
      await tester.pumpWidget(_tile(tags: const ['a'], maxTagRows: 2));
      final badge = find.text('已下载');
      expect(badge, findsOneWidget);
      expect(tester.widget<Text>(badge).style?.fontSize, 10.0);
      expect(tester.getSize(badge).height, lessThan(16.0),
          reason: '角标过高会跟标签区抢行高');
    });

    testWidgets('无限制布局分支（不限档 / 网络收藏 / 搜索页）同样是紧凑角标',
        (tester) async {
      // 这两条分支原先各写一份角标，改小时只改了一处 —— 「不限」档的卡片
      // 就还是旧的大角标（用户实测发现）。现在共用 _ComicBadge。
      await tester.pumpWidget(_tile(tags: const ['a']));
      final badge = find.text('已下载');
      expect(badge, findsOneWidget);
      expect(tester.widget<Text>(badge).style?.fontSize, 10.0);
      expect(tester.getSize(badge).height, lessThan(16.0));
    });

    testWidgets('两条分支的角标高度一致', (tester) async {
      await tester.pumpWidget(_tile(tags: const ['a'], maxTagRows: 2));
      final limited = tester.getSize(find.text('已下载')).height;
      await tester.pumpWidget(_tile(tags: const ['a']));
      final unlimited = tester.getSize(find.text('已下载')).height;
      expect(unlimited, limited, reason: '同一个角标不应有两种尺寸');
    });
  });

  group('源注册表与配置页口径一致', () {
    test('内置源的 key 都能取到配置（未配置即默认值），不抛异常', () {
      for (final key in const ['picacg', 'jm', 'ehentai', 'nhentai']) {
        expect(readSearchComicTileDisplayConfig(key),
            ComicTileDisplayConfig.defaults);
      }
    });
  });

  group('来源 id 行颜色（idColor）', () {
    test('缺省即橙色，且与升级前观感一致', () {
      expect(readComicTileDisplaySettings().idColor,
          comicTileDisplayDefaultIdColor);
      expect(comicTileDisplayDefaultIdColor, 'orange');
    });

    test('非法颜色键一律回退橙色', () {
      for (final raw in const ['', '  ', 'chartreuse', 'Orange', '0', 'null']) {
        expect(normalizeComicTileIdColor(raw), 'orange', reason: 'raw="$raw"');
      }
      for (final raw in const <Object?>[null, 12, true, <String>[]]) {
        expect(normalizeComicTileIdColor(raw), 'orange');
      }
    });

    test('只改颜色不动页面/源配置，只改页面也不动颜色', () async {
      await saveComicTileDisplaySettings(
        readComicTileDisplaySettings().withIdColor('blue'),
      );
      await writeComicTileDisplayConfig(
        scope: comicTileDisplayLocalPageKey,
        tagRows: 3,
      );

      final settings = readComicTileDisplaySettings();
      expect(settings.idColor, 'blue', reason: '写页面配置不得把颜色冲回默认');
      expect(settings.local.tagRows, 3);
      expect(settings.online, ComicTileDisplayConfig.defaults);
    });

    test('颜色随 JSON 序列化往返', () {
      final settings = ComicTileDisplaySettings.defaults.withIdColor('teal');
      expect(settings.toJson()[comicTileDisplayIdColorKey], 'teal');
      expect(
        ComicTileDisplaySettings.fromJsonString(
          jsonEncode(settings.toJson()),
        ).idColor,
        'teal',
      );
    });

    test('解析时把非法颜色洗成默认值，写入能修复坏配置', () async {
      setRaw(jsonEncode(<String, Object?>{
        comicTileDisplayIdColorKey: 'not-a-color',
        'local': <String, Object?>{'tagRows': 3},
      }));
      expect(readComicTileDisplaySettings().idColor, 'orange');
      expect(readLocalComicTileDisplayConfig().tagRows, 3);

      await saveComicTileDisplaySettings(readComicTileDisplaySettings());
      expect(readComicTileDisplaySettings().idColor, 'orange');
      expect(readLocalComicTileDisplayConfig().tagRows, 3);
    });

    testWidgets('ThemeData(brightness:) 在本 Flutter 版本不改主题亮度（对照记录）',
        (tester) async {
      late Brightness fromParam;
      late Brightness fromDarkFactory;
      await tester.pumpWidget(_colorProbe(
        onLight: (context) => fromParam = Theme.of(context).brightness,
      ));
      await tester.pumpWidget(_colorProbe(
        dark: true,
        onLight: (context) => fromDarkFactory = Theme.of(context).brightness,
      ));
      expect(fromParam, Brightness.light);
      expect(fromDarkFactory, Brightness.dark,
          reason: 'ThemeData.dark() 生效；(brightness:) 不生效');
    });

    testWidgets('「黑 / 白」在浅色主题是黑、深色主题是白', (tester) async {
      late Color lightBlack;
      late Color darkBlack;
      await tester.pumpWidget(_colorProbe(
        onLight: (context) =>
            lightBlack = resolveComicTileIdColor(context, 'black'),
      ));
      await tester.pumpWidget(_colorProbe(
        dark: true,
        onLight: (context) =>
            darkBlack = resolveComicTileIdColor(context, 'black'),
      ));
      expect(lightBlack, Colors.black);
      expect(darkBlack, Colors.white,
          reason: '深色模式下纯黑会看不见，必须自动转白');
    });

    testWidgets('颜色键 → 实际颜色（浅色主题）', (tester) async {
      late Color lightTheme;
      late Color lightBlue;

      await tester.pumpWidget(_colorProbe(
        onLight: (context) {
          lightTheme = resolveComicTileIdColor(context, 'theme');
          lightBlue = resolveComicTileIdColor(context, 'blue');
        },
      ));

      expect(lightBlue, Colors.blue);
      expect(lightTheme, isNotNull);
      expect(lightTheme, isNot(Colors.black));
    });
  });
}

/// 取一个只在 build 期求值的颜色探针（需要 BuildContext 才能读主题）。
///
/// 注意 `ThemeData(brightness: Brightness.dark)` 在本 Flutter 版本**不会**改
/// `Theme.of(context).brightness`（实测仍是 light），深色必须用 `ThemeData.dark()`。
/// 取一个只在 build 期求值的颜色探针（需要 BuildContext 才能读主题）。
///
/// `key: ValueKey(dark)` 是必需的：同一测试内先后 pump 明暗两种主题时，
/// MaterialApp 会复用元素并保留旧主题，深色不会生效。
Widget _colorProbe({
  required void Function(BuildContext context) onLight,
  bool dark = false,
}) {
  return MaterialApp(
    key: ValueKey<bool>(dark),
    theme: dark
        ? ThemeData.dark()
        : ThemeData(brightness: Brightness.light),
    home: Builder(
      builder: (context) {
        onLight(context);
        return const SizedBox.shrink();
      },
    ),
  );
}

/// 渲染一张卡片，返回它实际显示的标签行数（按标签文本的 y 坐标去重）。
Future<int> _renderedTagRows(
  WidgetTester tester, {
  required ComicTileDisplayConfig config,
  double width = 360,
  double height = 164,
}) async {
  final tags = List<String>.generate(30, (index) => 't$index');
  await tester.pumpWidget(
    _tile(
      tags: tags,
      config: config,
      width: width,
      height: height,
    ),
  );

  final rows = <double>[];
  for (final tag in tags) {
    final finder = find.text(tag);
    if (finder.evaluate().isEmpty) continue;
    final y = tester.getTopLeft(finder).dy;
    if (!rows.any((rowY) => (rowY - y).abs() < 1)) {
      rows.add(y);
    }
  }
  expect(tester.takeException(), isNull);
  return rows.length;
}

/// 渲染一张卡片，返回它实际显示的标签个数。
Future<int> _renderedTagCount(
  WidgetTester tester, {
  required ComicTileDisplayConfig config,
  double width = 360,
  double height = 164,
}) async {
  final tags = List<String>.generate(30, (index) => 't$index');
  await tester.pumpWidget(
    _tile(
      tags: tags,
      config: config,
      width: width,
      height: height,
    ),
  );

  var count = 0;
  for (final tag in tags) {
    if (find.text(tag).evaluate().isNotEmpty) {
      count++;
    }
  }
  expect(tester.takeException(), isNull);
  return count;
}

Widget _tile({
  required List<String> tags,
  ComicTileDisplayConfig? config,
  int? maxTagRows,
  double width = 360,
  double height = 164,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          height: height,
          child: DownloadedComicTile(
            name: 'Downloaded comic',
            author: 'Always visible author',
            imagePath: File(''),
            isFavoriteOverride: false,
            type: '已下载',
            tag: tags,
            size: '128 MB',
            maxTagRows: maxTagRows,
            cardDisplayConfig: config,
            onTap: () {},
            onLongTap: () {},
            onSecondaryTap: (_) {},
          ),
        ),
      ),
    ),
  );
}

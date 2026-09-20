import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/comic_tile_display_config.dart';
import 'package:picakeep/foundation/download_author_resolver.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/pages/favorites/local_favorites.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 12 号计划：本地收藏卡片的标签限行与来源 id 显示。
///
/// 这组用例**直接构建真实的 `LocalFavoriteTile`**（不是测试副本），因此断言的
/// 是生产渲染路径：`LocalFavoriteTile.build → readLocalComicTileDisplayConfig →
/// favoriteSourceIdLabel → _LocalFavoriteDownloadedComicTile → DownloadedComicTile`。
///
/// 不伪造的部分：封面与"已下载"角标依赖真实本地库（`LocalLibraryManager` /
/// `DownloadManager`），卡片内部对它们全程 try/catch，未初始化时降级为无封面、
/// 无角标 —— 与本计划要验证的标签/id 行布局无关，属真机 M01–M03 覆盖范围。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const settingIndex = comicTileDisplayConfigSettingIndex;

  /// 卡片高度取自本地收藏列表的真实定高（`layout.dart` 的
  /// `SliverGridDelegateWithComics.childMainAxisExtent = 164 * scale`）。
  const cardHeight = 164.0;

  late String originalLanguage;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // settings[50] 是界面文字语言（`App.locale` 直接读它）。固定为英文后
    // `_generateTags` 不做标签翻译，标签文本即原值，断言才稳定。
    originalLanguage = appdata.settings[50];
    appdata.settings[50] = 'en';
    appdata.settings[settingIndex] = '{}';
  });

  tearDown(() {
    appdata.settings[50] = originalLanguage;
    appdata.settings[settingIndex] = '{}';
  });

  void setLocalConfig({
    int? tagRows,
    bool? showTags,
    bool? showId,
    String? idColor,
  }) {
    appdata.settings[settingIndex] = '{"idColor":'
        '"${idColor ?? comicTileDisplayDefaultIdColor}",'
        '"local":{"tagRows":'
        '${tagRows ?? ComicTileDisplayConfig.defaultTagRows},'
        '"showTags":${showTags ?? true},"showId":${showId ?? true}}}';
  }

  /// 本地收藏卡片底部那一行（`comic.time | comic.type.name`）。
  String descriptionOf(FavoriteItem comic) =>
      '${comic.time} | ${comic.type.name}';

  group('favoriteSourceIdLabel：源 → 标识号文本', () {
    test('W03 JM 条目返回 jm<target>', () {
      expect(
        favoriteSourceIdLabel(typeKey: FavoriteType.jm.key, target: '1472970'),
        'jm1472970',
      );
    });

    test('W04 NH 条目返回 nhentai<target>', () {
      expect(
        favoriteSourceIdLabel(
            typeKey: FavoriteType.nhentai.key, target: '605366'),
        'nhentai605366',
      );
    });

    test('W05 其它源一律不显示（EH 的 target 是长 URL、picacg 是 ObjectId）', () {
      const longEhLink = 'https://e-hentai.org/g/2009163/61926e092e/';
      final cases = <String, int>{
        'picacg': FavoriteType.picacg.key,
        'ehentai': FavoriteType.ehentai.key,
        'hitomi': FavoriteType.hitomi.key,
        'htManga': FavoriteType.htManga.key,
        'copyManga': FavoriteType.copyManga.key,
        'komiic': FavoriteType.komiic.key,
        // 自定义源的 key 是 hash 值，取一个必然不等于 jm/nh 的值。
        'custom': 12345,
      };
      cases.forEach((name, key) {
        expect(
          favoriteSourceIdLabel(typeKey: key, target: longEhLink),
          isNull,
          reason: '$name 不应显示 id 行',
        );
        expect(
          favoriteSourceIdLabel(typeKey: key, target: '1472970'),
          isNull,
          reason: '$name 即使 target 是数字也不显示 id 行',
        );
      });
    });

    test('W05b showId=false 时一律返回 null（连 jm/nh 也不显示）', () {
      for (final key in [FavoriteType.jm.key, FavoriteType.nhentai.key]) {
        expect(
          favoriteSourceIdLabel(
              typeKey: key, target: '1472970', showId: false),
          isNull,
        );
      }
    });

    test('空 target / 纯空白不产生 id 行', () {
      for (final target in const ['', '   ']) {
        expect(
          favoriteSourceIdLabel(typeKey: FavoriteType.jm.key, target: target),
          isNull,
          reason: 'target="$target" 不应产出 jm 前缀的空 id',
        );
      }
    });

    test('target 两侧空白被裁剪', () {
      expect(
        favoriteSourceIdLabel(typeKey: FavoriteType.jm.key, target: ' 1472970 '),
        'jm1472970',
      );
    });

    test('typeKey 常量与 FavoriteType 定义一致（防两处口径漂移）', () {
      expect(favoriteTypeJmKey, FavoriteType.jm.key);
      expect(favoriteTypeNhentaiKey, FavoriteType.nhentai.key);
    });
  });

  group('W03/W04/W05 卡片上的 id 行（真实 LocalFavoriteTile）', () {
    testWidgets('W03 JM 条目渲染 jm1472970', (tester) async {
      final comic = _comic(type: FavoriteType.jm, target: '1472970');
      await tester.pumpWidget(_card(comic, descriptionOf(comic)));

      expect(find.text('jm1472970'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('W04 NH 条目渲染 nhentai605366', (tester) async {
      final comic = _comic(type: FavoriteType.nhentai, target: '605366');
      await tester.pumpWidget(_card(comic, descriptionOf(comic)));

      expect(find.text('nhentai605366'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('W05 EH 条目（长 URL target）不渲染任何 id 行', (tester) async {
      const link = 'https://e-hentai.org/g/2009163/61926e092e/';
      final comic = _comic(type: FavoriteType.ehentai, target: link);
      await tester.pumpWidget(_card(comic, descriptionOf(comic)));

      expect(find.textContaining('jm'), findsNothing);
      expect(find.textContaining('nhentai'), findsNothing);
      expect(find.text(link), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('W05 picacg 条目不渲染 id 行', (tester) async {
      final comic = _comic(type: FavoriteType.picacg, target: '5f1a2b3c4d');
      await tester.pumpWidget(_card(comic, descriptionOf(comic)));

      expect(find.textContaining('jm'), findsNothing);
      expect(find.textContaining('nhentai'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('W05b 关闭「显示来源 id」后 id 行消失，日期行与作者仍在',
        (tester) async {
      setLocalConfig(showId: false);
      final comic = _comic(type: FavoriteType.jm, target: '1472970');
      await tester.pumpWidget(_card(comic, descriptionOf(comic)));

      expect(find.text('jm1472970'), findsNothing);
      expect(find.text(descriptionOf(comic)), findsOneWidget);
      expect(find.text('Author'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('W01/W01b 标签限行（真实 LocalFavoriteTile）', () {
    testWidgets('W01 标签远超上限时只渲染部分标签，日期行仍在卡片内',
        (tester) async {
      // 用户截图那类条目的形态：十几个标签 + 常规标题作者。
      final tags = List<String>.generate(13, (index) => 'tag-$index');
      final comic = _comic(type: FavoriteType.ehentai, target: 'x', tags: tags);
      await tester.pumpWidget(_card(comic, descriptionOf(comic)));

      final rendered = tags.where((t) => find.text(t).evaluate().isNotEmpty);
      expect(rendered, isNotEmpty, reason: '至少要渲染一行标签');
      expect(rendered.length, lessThan(tags.length),
          reason: '13 个标签不得全部渲染（限行未生效）');

      // 日期行必须整体留在卡片高度内 —— 这正是用户截图里的溢出症状。
      final footerBottom =
          tester.getBottomLeft(find.text(descriptionOf(comic))).dy;
      expect(footerBottom, lessThanOrEqualTo(cardHeight),
          reason: '日期行底部 $footerBottom 超出卡片高度 $cardHeight');
      expect(tester.takeException(), isNull);
    });

    testWidgets('W01b-2 行档：7 个短标签正好排满 2 行（用户真机样本形态）',
        (tester) async {
      // 用户实测的形态：禁漫条目、长标题、7 个两字标签。
      // 修复前这里只显示 1 行（标题 2 行 + id 行把标签区压到只剩 1 行）。
      final tags = <String>['剧情向', '肛交', '口交', '束缚', '塞口器', '萝莉', '巫女'];
      final comic = _comic(
        type: FavoriteType.jm,
        target: '618742',
        tags: tags,
        name: '【樱水晶 (夜樱ソウキ)】壊れた巫女～エピソード・オブ・ティナIV [中国翻译] [DL版]',
        author: '夜樱ソウキ',
      );
      setLocalConfig(tagRows: 2);
      await tester.pumpWidget(
        _card(comic, descriptionOf(comic), width: 411),
      );

      final rows = _tagRowCount(tester, tags);
      expect(rows, 2, reason: '2 行档必须真的显示 2 行（修复前只有 1 行）');
      expect(tester.takeException(), isNull);
    });

    testWidgets('W01b-3 行档：渲染行数不超过配置值', (tester) async {
      final tags = List<String>.generate(30, (index) => 'tag-$index');
      final comic = _comic(type: FavoriteType.jm, target: '1472970', tags: tags);

      for (final rows in const [2, 3]) {
        setLocalConfig(tagRows: rows);
        await tester.pumpWidget(
          _card(comic, descriptionOf(comic), width: 411),
        );
        expect(_tagRowCount(tester, tags), lessThanOrEqualTo(rows),
            reason: 'tagRows=$rows 时不得超过该行数');
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('W06c 3 行档在"补偿后的卡片高度"下真的显示 3 行', (tester) async {
      // 本地收藏网格会按 tagRows 抬高行高（`localFavoriteThreeTagRowsExtraHeight`），
      // 因为定高卡片自己长不高。这里用补偿后的真实高度验证 3 行确实生效 ——
      // 修复前即使把卡片加到 190dp 也只有 2 行（标签区 maxHeight 差 1.2dp）。
      final tags = List<String>.generate(30, (index) => 'tag-$index');
      final comic = _comic(type: FavoriteType.jm, target: '1472970', tags: tags);
      setLocalConfig(tagRows: 3);
      await tester.pumpWidget(
        _card(
          comic,
          descriptionOf(comic),
          width: 411,
          height: cardHeight + localFavoriteThreeTagRowsExtraHeight,
        ),
      );

      expect(_tagRowCount(tester, tags), 3, reason: '3 行档必须真的显示 3 行');
      // id 行与日期行仍要留在卡片内
      final idBottom = tester.getBottomLeft(find.text('jm1472970')).dy;
      final footerBottom =
          tester.getBottomLeft(find.text(descriptionOf(comic))).dy;
      const cardBottom = cardHeight + localFavoriteThreeTagRowsExtraHeight;
      expect(idBottom, lessThanOrEqualTo(cardBottom));
      expect(footerBottom, lessThanOrEqualTo(cardBottom),
          reason: '日期行底部 $footerBottom 超出卡片高度 $cardBottom');
      expect(tester.takeException(), isNull);
    });

    testWidgets('W06d 2 行档不受高度补偿影响（仍是 2 行、内容都在卡内）',
        (tester) async {
      final tags = List<String>.generate(30, (index) => 'tag-$index');
      final comic = _comic(type: FavoriteType.jm, target: '1472970', tags: tags);
      setLocalConfig(tagRows: 2);
      await tester.pumpWidget(
        _card(comic, descriptionOf(comic), width: 411),
      );

      expect(_tagRowCount(tester, tags), 2);
      final footerBottom =
          tester.getBottomLeft(find.text(descriptionOf(comic))).dy;
      expect(footerBottom, lessThanOrEqualTo(cardHeight));
      expect(tester.takeException(), isNull);
    });

    testWidgets('W01b-不限（tagRows=0）时不截断标签', (tester) async {
      setLocalConfig(tagRows: 0);
      final tags = List<String>.generate(6, (index) => 'tag-$index');
      final comic = _comic(type: FavoriteType.ehentai, target: 'x', tags: tags);
      await tester.pumpWidget(
        _card(comic, descriptionOf(comic), width: 411),
      );

      for (final tag in tags) {
        expect(find.text(tag), findsOneWidget,
            reason: '"不限"档不得截断标签');
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('id 行恒在标签区之下（"不限"档曾把它顶到标签上面）',
        (tester) async {
      setLocalConfig(tagRows: 0);
      final tags = List<String>.generate(6, (index) => 'tag-$index');
      final comic = _comic(type: FavoriteType.jm, target: '1472970', tags: tags);
      // 必须用真实卡片比例：`_buildDetailedMode` 的图片宽度按高度算
      // （height * 0.68），把卡片拉得过高会把文本区挤成一条缝，
      // 测出一堆与真机无关的现象。
      await tester.pumpWidget(
        _card(comic, descriptionOf(comic), width: 411),
      );

      final lastTagFinder = find.text(tags.last);
      final idFinder = find.text('jm1472970');
      expect(lastTagFinder, findsOneWidget);
      expect(idFinder, findsOneWidget);
      final lastTagY = tester.getTopLeft(lastTagFinder).dy;
      final idY = tester.getTopLeft(idFinder).dy;
      expect(idY, greaterThan(lastTagY), reason: 'id 行必须在标签之下');
      expect(tester.takeException(), isNull);
    });

    testWidgets('W02 标签只有 1~2 个时全部显示（不回归）', (tester) async {
      final tags = <String>['只有两个', '标签'];
      final comic = _comic(type: FavoriteType.jm, target: '1472970', tags: tags);
      await tester.pumpWidget(_card(comic, descriptionOf(comic)));

      for (final tag in tags) {
        expect(find.text(tag), findsOneWidget);
      }
      expect(find.text('jm1472970'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('W05c 关闭「显示标签」后标签区消失，id 行与日期行仍在',
        (tester) async {
      setLocalConfig(showTags: false);
      final tags = List<String>.generate(6, (index) => 'tag-$index');
      final comic = _comic(type: FavoriteType.jm, target: '1472970', tags: tags);
      await tester.pumpWidget(_card(comic, descriptionOf(comic)));

      for (final tag in tags) {
        expect(find.text(tag), findsNothing);
      }
      expect(find.text('jm1472970'), findsOneWidget);
      expect(find.text(descriptionOf(comic)), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('W06 id 行不引入溢出', () {
    testWidgets('JM：jm 号 + 默认标签行数，整卡内容都在固定高度内',
        (tester) async {
      final tags = List<String>.generate(13, (index) => 'tag-$index');
      final comic = _comic(type: FavoriteType.jm, target: '1472970', tags: tags);
      await tester.pumpWidget(_card(comic, descriptionOf(comic)));

      final idBottom = tester.getBottomLeft(find.text('jm1472970')).dy;
      final footerBottom =
          tester.getBottomLeft(find.text(descriptionOf(comic))).dy;
      expect(idBottom, lessThanOrEqualTo(cardHeight),
          reason: 'id 行底部 $idBottom 超出卡片高度 $cardHeight');
      expect(footerBottom, lessThanOrEqualTo(cardHeight),
          reason: '日期行底部 $footerBottom 超出卡片高度 $cardHeight');
      expect(tester.takeException(), isNull);
    });

    testWidgets('id 行位于标签区之下、日期行之上（位置契约）', (tester) async {
      final tags = <String>['同人', '中文'];
      final comic = _comic(type: FavoriteType.jm, target: '1472970', tags: tags);
      await tester.pumpWidget(_card(comic, descriptionOf(comic)));

      final tagY = tester.getTopLeft(find.text(tags.first)).dy;
      final idY = tester.getTopLeft(find.text('jm1472970')).dy;
      final dateY = tester.getTopLeft(find.text(descriptionOf(comic))).dy;

      expect(idY, greaterThan(tagY), reason: 'id 行应在标签之下');
      expect(idY, lessThan(dateY), reason: 'id 行应在日期行之上');
      expect(tester.takeException(), isNull);
    });

    testWidgets('W06b 长标题 + 13 标签 + id 行 + 阅读位置：仍不溢出',
        (tester) async {
      final tags = List<String>.generate(13, (index) => 'tag-$index');
      final comic = _comic(
        type: FavoriteType.jm,
        target: '1472970',
        tags: tags,
        name: '【ばんばんべいん（ばんばん）】るりちゃんは調教済み【中國翻譯】[DL版]',
        author: 'ばんばん',
      );
      await tester.pumpWidget(_card(comic, descriptionOf(comic)));

      expect(find.text('jm1472970'), findsOneWidget);
      final footerBottom =
          tester.getBottomLeft(find.text(descriptionOf(comic))).dy;
      expect(footerBottom, lessThanOrEqualTo(cardHeight),
          reason: '日期行底部 $footerBottom 超出卡片高度 $cardHeight');
      expect(tester.takeException(), isNull);
    });
  });

  group('标签字号自适应（"三行或不限时把标签变小，显示不全时自己调小"）',
      () {
    testWidgets('2 行档用默认字号（12pt），与改动前一致', (tester) async {
      final tags = List<String>.generate(6, (index) => 'tag-$index');
      final comic = _comic(type: FavoriteType.jm, target: '1472970', tags: tags);
      setLocalConfig(tagRows: 2);
      await tester.pumpWidget(_card(comic, descriptionOf(comic), width: 411));

      expect(_tagFontSize(tester, tags.first), 12.0);
    });

    testWidgets('3 行档 / 不限档用更小字号', (tester) async {
      final tags = List<String>.generate(6, (index) => 'tag-$index');
      final comic = _comic(type: FavoriteType.jm, target: '1472970', tags: tags);

      for (final rows in const [3, 0]) {
        setLocalConfig(tagRows: rows);
        await tester.pumpWidget(_card(
          comic,
          descriptionOf(comic),
          width: 411,
          height: cardHeight + localFavoriteThreeTagRowsExtraHeight,
        ));
        expect(_tagFontSize(tester, tags.first), lessThan(12.0),
            reason: 'tagRows=$rows 应使用紧凑字号');
      }
    });

    testWidgets('缩小字号不会让可见标签变少（自适应只在"不亏"时缩）',
        (tester) async {
      final tags = List<String>.generate(30, (index) => 'tag-$index');
      final comic = _comic(type: FavoriteType.jm, target: '1472970', tags: tags);

      setLocalConfig(tagRows: 2);
      await tester.pumpWidget(_card(comic, descriptionOf(comic), width: 411));
      final twelveCount = _renderedTagCount(tester, tags);
      final twelveFont = _tagFontSize(tester, tags.first);

      // 30 个标签在 2 行里放不下 → 会缩到下限 9.5，可见数应不少于 12pt 时的结果
      expect(twelveFont, lessThanOrEqualTo(12.0));
      expect(_renderedTagCount(tester, tags), greaterThanOrEqualTo(twelveCount),
          reason: '缩小字号后可见标签数不应减少');
    });

    testWidgets('字号有下限（不会无限缩小到看不清）', (tester) async {
      // 极端：13 个两字标签 + 2 行档，仍应是可读字号
      final tags = List<String>.generate(13, (index) => '标签$index');
      final comic = _comic(type: FavoriteType.jm, target: '1472970', tags: tags);
      setLocalConfig(tagRows: 2);
      await tester.pumpWidget(_card(comic, descriptionOf(comic), width: 411));

      final fontSize = _tagFontSize(tester, tags.first);
      expect(fontSize, greaterThanOrEqualTo(9.5),
          reason: '低于 9.5pt 影响可读性，应接受截断而不是继续缩');
    });
  });

  group('id 行颜色（用户自定义）', () {
    testWidgets('默认（未配颜色）是橙色', (tester) async {
      final comic = _comic(type: FavoriteType.jm, target: '1472970');
      await tester.pumpWidget(_card(comic, descriptionOf(comic)));

      final color = _idLineColor(tester, 'jm1472970');
      expect(color, Colors.orange, reason: '默认必须与升级前一致（橙色）');
    });

    testWidgets('选了蓝色 → 卡片上的 id 行真的变蓝', (tester) async {
      setLocalConfig(idColor: 'blue');
      final comic = _comic(type: FavoriteType.jm, target: '1472970');
      await tester.pumpWidget(_card(comic, descriptionOf(comic)));

      expect(_idLineColor(tester, 'jm1472970'), Colors.blue);
    });

    testWidgets('选「黑 / 白」→ 浅色模式黑、深色模式白', (tester) async {
      setLocalConfig(idColor: 'black');
      final comic = _comic(type: FavoriteType.jm, target: '1472970');

      await tester.pumpWidget(_card(comic, descriptionOf(comic)));
      expect(_idLineColor(tester, 'jm1472970'), Colors.black);

      await tester.pumpWidget(_card(comic, descriptionOf(comic), dark: true));
      expect(_idLineColor(tester, 'jm1472970'), Colors.white,
          reason: '深色模式下纯黑看不见，必须自动转白');
    });

    testWidgets('颜色不影响 id 行位置与其它行', (tester) async {
      setLocalConfig(idColor: 'purple');
      final comic = _comic(type: FavoriteType.jm, target: '1472970');
      await tester.pumpWidget(_card(comic, descriptionOf(comic)));

      expect(find.text('jm1472970'), findsOneWidget);
      expect(find.text(descriptionOf(comic)), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

/// 读取 id 行文本最终生效的颜色（卡片用 [DefaultTextStyle] 注入颜色）。
Color _idLineColor(WidgetTester tester, String text) {
  final context = tester.element(find.text(text));
  final style = DefaultTextStyle.of(context).style;
  final color = style.color;
  expect(color, isNotNull, reason: 'id 行必须有显式颜色');
  return color!;
}

/// 当前渲染出的标签占了几行（按标签文本的 y 坐标去重）。
int _tagRowCount(WidgetTester tester, List<String> tags) {
  final rows = <double>[];
  for (final tag in tags) {
    final finder = find.text(tag);
    if (finder.evaluate().isEmpty) continue;
    final y = tester.getTopLeft(finder).dy;
    if (!rows.any((row) => (row - y).abs() < 1)) rows.add(y);
  }
  return rows.length;
}

/// 某个标签实际用的字号（读 `Text` 自己的 style，别读继承来的 DefaultTextStyle）。
double? _tagFontSize(WidgetTester tester, String tag) {
  return tester.widget<Text>(find.text(tag)).style?.fontSize;
}

/// 当前渲染出的标签个数。
int _renderedTagCount(WidgetTester tester, List<String> tags) {
  return tags.where((tag) => find.text(tag).evaluate().isNotEmpty).length;
}

/// 构造一个本地收藏条目（不落库，只用于渲染卡片）。
FavoriteItem _comic({
  required FavoriteType type,
  required String target,
  List<String>? tags,
  String name = 'Downloaded comic',
  String author = 'Author',
}) {
  return FavoriteItem(
    target: target,
    name: name,
    coverPath: '',
    author: author,
    type: type,
    tags: tags ?? const <String>[],
  );
}

/// 在定高约束下渲染真实的 [LocalFavoriteTile]（等价于本地收藏网格里的一格）。
Widget _card(
  FavoriteItem comic,
  String description, {
  double width = 360,
  double height = 164,
  bool dark = false,
}) {
  return MaterialApp(
    // `key` 是必需的：同一测试内先后 pump 明暗两种主题时，MaterialApp 会复用
    // 元素并保留旧主题，深色不会生效。
    key: ValueKey<bool>(dark),
    theme: dark ? ThemeData.dark() : ThemeData.light(),
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          height: height,
          child: LocalFavoriteTile(
            comic: comic,
            folderName: '临时收藏',
            onDelete: () {},
            enableLongPressed: false,
          ),
        ),
      ),
    ),
  );
}

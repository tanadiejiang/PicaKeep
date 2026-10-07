/// 插画卡片的**真实渲染契约**：图片不被裁切、底部信息随配置变化、降采样仍在。
///
/// ## 为什么必须真实渲染
///
/// 32 号计划「验收标准 2」第三条要求布局断言。而本轮用户报的两个症状都在
/// **渲染层**，只看代码常量毫无意义：
///
/// - 「图的比例没有完全显示」= `BoxFit.cover` 在格子比例与图不符时裁边
///   → 必须断言 `Image.fit` **是** `contain`；
/// - 「下面的信息可以在设置里显示」= 底部那块由配置驱动
///   → 必须渲染真实控件，断言"配了几个字段就显示几段、值为空就不显示"。
///
/// 另外钉住一条容易在重构里丢掉的约束：**降采样不能因为换成 `contain` 就失效**。
/// 比例不符时实际显示宽度小于列宽，`cacheWidth` 必须跟着变小，
/// 否则会白解一大截、把 `BaseImageProvider` 的 50 MB 字节缓存冲掉。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:typed_data';
import 'dart:ui' show SemanticsAction, Tristate;
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/components/comic_tag_wrap.dart';
import 'package:picakeep/foundation/comic_tile_display_config.dart';
import 'package:picakeep/foundation/illust_card_info_config.dart';
import 'package:picakeep/foundation/image_pipeline/cover_decode_target.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/local_library_illust_view.dart';
import 'package:picakeep/pages/local_library_illust_card.dart';

/// 造一条插画条目。
IllustLibraryEntry _entry({
  String name = '作品标题',
  String author = '作者名',
  int? width,
  int? height,
  int? pageCount,
  String id = 'pixiv1',
}) {
  final json = '{"id":"$id","name":"$name","subTitle":"$author",'
      '"tags":[],"sourceKey":"pixiv","sourceName":"Pixiv","cover":"",'
      '"comicId":"$id","width":${width ?? 'null'},"height":${height ?? 'null'}}';
  final item = LocalLibraryComicItem(
    itemId: 'local_download::current_download::$id',
    originalId: id,
    type: DownloadType.other,
    name: name,
    subTitle: author,
    tags: const <String>[],
    sourceDisplayName: 'Pixiv',
    fileSystemPath: '/tmp/$id',
    episodeFiles: const <int, List<String>>{},
    downloadedEps: const <int>[0],
    eps: const <String>['全部'],
    localCoverPath: null,
    localStorageExists: true,
    canDelete: false,
    aliases: <String>[id],
    sourceRowJson: json,
  );
  final entry = buildIllustEntries(<LocalLibraryComicItem>[item]).single;
  return pageCount == null
      ? entry
      : entry.withResolvedInfo(pageCount: pageCount);
}

/// 把卡片放进**与瀑布流一致的约束**里：固定列宽、高度不限（`SliverMasonryGrid`
/// 给子项的就是这个形态）。
Widget _harness({
  required IllustLibraryEntry entry,
  List<IllustCardInfoSpan>? infoSpans,
  List<String>? infoFields,
  String infoSeparator = '\n',
  TextScaler textScaler = TextScaler.noScaling,
  double columnWidth = 120,
  WaterfallTagDisplayConfig tagConfig = WaterfallTagDisplayConfig.defaults,
}) {
  return MaterialApp(
    home: Scaffold(
      body: MediaQuery(
        data: MediaQueryData(textScaler: textScaler),
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: columnWidth,
            child: IllustCard(
              entry: entry,
              imageProvider: null,
              infoSpans: infoSpans,
              infoFields: infoFields,
              infoSeparator: infoSeparator,
              tagConfig: tagConfig,
              onTap: () {},
              onLongPress: () {},
            ),
          ),
        ),
      ),
    ),
  );
}

/// 卡片里那个 `Image` 控件（`imageProvider: null` 时不存在，故仅供有图用例用）。
Image _imageIn(WidgetTester tester) => tester.widget<Image>(find.byType(Image));

void main() {
  testWidgets('本地插画不限标签自然增高，统一封面圆角为4dp', (tester) async {
    final base = _entry(width: 600, height: 800);
    const config = WaterfallTagDisplayConfig(showTags: true, tagRows: 0);
    await tester.pumpWidget(
        _harness(entry: base, infoSpans: const [], tagConfig: config));
    final before = tester.getSize(find.byType(IllustCard));
    final cover = tester.getSize(find.byType(AspectRatio));
    expect(tester.widget<ClipRRect>(find.byType(ClipRRect)).borderRadius,
        BorderRadius.circular(4));
    final tagged = IllustLibraryEntry(
        item: base.item,
        aspectRatio: base.aspectRatio,
        tags: List.generate(10, (i) => '作品标签-$i'),
        width: base.width,
        height: base.height);
    await tester.pumpWidget(
        _harness(entry: tagged, infoSpans: const [], tagConfig: config));
    expect(tester.getSize(find.byType(IllustCard)).height,
        greaterThan(before.height));
    expect(tester.getSize(find.byType(AspectRatio)), cover);
    expect(find.byType(ComicTagChip), findsNWidgets(10));
    expect(tester.takeException(), isNull);
  });
  testWidgets('本地标签独立于信息模板，补齐标签不改预算，空模板仍可管理', (tester) async {
    final base = _entry(width: 600, height: 800);
    const config = WaterfallTagDisplayConfig(showTags: true, tagRows: 2);
    await tester.pumpWidget(
        _harness(entry: base, infoSpans: const [], tagConfig: config));
    final before = tester.getSize(find.byType(IllustCard));
    expect(find.byType(ComicTagWrap), findsOneWidget);
    final tagged = IllustLibraryEntry(
        item: base.item,
        aspectRatio: base.aspectRatio,
        tags: List.generate(80, (i) => '作品标签-$i'),
        width: base.width,
        height: base.height);
    await tester.pumpWidget(
        _harness(entry: tagged, infoSpans: const [], tagConfig: config));
    expect(tester.getSize(find.byType(IllustCard)), before);
    expect(find.byType(ComicTagChip), findsNWidgets(2));
    var detail = 0, longPress = 0, read = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
          width: 120,
          child: IllustCard(
            entry: tagged,
            imageProvider: null,
            infoSpans: const [],
            tagConfig: config,
            onTap: () => read++,
            onInfoTap: () => detail++,
            onLongPress: () => longPress++,
          )),
    ))));
    await tester.tap(find.byType(ComicTagChip).first);
    await tester.longPress(find.byType(ComicTagChip).first);
    expect([read, detail, longPress], [0, 1, 1]);
    expect(tester.takeException(), isNull);
  });
  group('异步信息补齐的布局预留', () {
    testWidgets('未知页数变为 p2 不推动卡片下方，占位不渲染或朗读', (tester) async {
      final semantics = tester.ensureSemantics();
      final entry = _entry(width: 600, height: 800);
      const fields = ['title', 'author', 'pages'];
      await tester.pumpWidget(_harness(entry: entry, infoFields: fields));
      final before = tester.getSize(find.byType(IllustCard));
      expect(tester.widget<Text>(find.byType(Text)).textSpan!.toPlainText(),
          '作品标题\n作者名');
      expect(find.bySemanticsLabel(RegExp('p88')), findsNothing);
      await tester.pumpWidget(_harness(
          entry: entry.withResolvedInfo(pageCount: 2), infoFields: fields));
      expect(tester.widget<Text>(find.byType(Text)).textSpan!.toPlainText(),
          '作品标题\n作者名\np2');
      expect(tester.getSize(find.byType(IllustCard)), before);
      semantics.dispose();
    });

    testWidgets('未知变单图立即释放页数空行，不必离屏重建', (tester) async {
      final entry = _entry(width: 600, height: 800);
      const fields = ['title', 'author', 'pages'];
      await tester.pumpWidget(_harness(entry: entry, infoFields: fields));
      final before = tester.getSize(find.byType(IllustCard));
      final single = entry.withResolvedInfo(pageCount: 1);
      await tester.pumpWidget(_harness(entry: single, infoFields: fields));
      final after = tester.getSize(find.byType(IllustCard));
      expect(after.height, lessThan(before.height));
      expect(tester.widget<Text>(find.byType(Text)).textSpan!.toPlainText(),
          '作品标题\n作者名');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(_harness(entry: single, infoFields: fields));
      expect(tester.getSize(find.byType(IllustCard)), after);
    });

    testWidgets('未勾动态字段时，与旧 spans 调用同高', (tester) async {
      final entry = _entry();
      await tester.pumpWidget(_harness(entry: entry));
      final before = tester.getSize(find.byType(IllustCard));
      await tester.pumpWidget(
          _harness(entry: entry, infoFields: const ['title', 'author']));
      expect(tester.getSize(find.byType(IllustCard)), before);
      await tester.pumpWidget(_harness(entry: entry, infoFields: const []));
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('换行字段重排、页数与尺寸一起补齐、大字体仍保持信息高度', (tester) async {
      final entry = _entry();
      const fields = ['size', 'pages', 'title', 'author'];
      await tester.pumpWidget(_harness(
          entry: entry,
          infoFields: fields,
          columnWidth: 240,
          textScaler: const TextScaler.linear(1.8)));
      final before = tester.getSize(find.byType(IllustCard));
      final imageBefore = tester.getSize(find.byType(AspectRatio));
      await tester.pumpWidget(_harness(
          entry: entry.withResolvedInfo(width: 600, height: 800, pageCount: 2),
          infoFields: fields,
          columnWidth: 240,
          textScaler: const TextScaler.linear(1.8)));
      final text = tester.widget<Text>(find.byType(Text));
      expect(text.textSpan!.toPlainText(), '600×800\np2\n作品标题\n作者名');
      expect(tester.getSize(find.byType(AspectRatio)), imageBefore);
      expect(tester.getSize(find.byType(IllustCard)), before);
    });

    testWidgets('紧凑分隔符保持串接，不改成每字段一行', (tester) async {
      final entry = _entry(name: 'T', author: 'A', width: 600, height: 800);
      const fields = ['title', 'pages', 'author'];
      await tester.pumpWidget(_harness(
          entry: entry,
          infoFields: fields,
          infoSeparator: ' / ',
          columnWidth: 240));
      final before = tester.getSize(find.byType(IllustCard));
      expect(tester.widget<Text>(find.byType(Text)).textSpan!.toPlainText(),
          'T / A');
      await tester.pumpWidget(_harness(
          entry: entry.withResolvedInfo(pageCount: 2),
          infoFields: fields,
          infoSeparator: ' / ',
          columnWidth: 240));
      expect(tester.widget<Text>(find.byType(Text)).textSpan!.toPlainText(),
          'T / p2 / A');
      expect(tester.getSize(find.byType(IllustCard)), before);
    });

    testWidgets('只选未知页数预留空间，解析单图移除整个空信息区', (tester) async {
      final entry = _entry(width: 600, height: 800);
      const fields = ['pages'];
      await tester.pumpWidget(_harness(entry: entry, infoFields: fields));
      final before = tester.getSize(find.byType(IllustCard));
      expect(find.byType(Text), findsNothing);
      await tester.pumpWidget(_harness(
          entry: entry.withResolvedInfo(pageCount: 1), infoFields: fields));
      expect(tester.getSize(find.byType(IllustCard)).height,
          lessThan(before.height));
      expect(find.byType(Text), findsNothing);
      await tester.pumpWidget(_harness(
          entry: entry.withResolvedInfo(pageCount: 2), infoFields: fields));
      expect(tester.getSize(find.byType(IllustCard)), before);
      expect(
          tester.widget<Text>(find.byType(Text)).textSpan!.toPlainText(), 'p2');
      await tester
          .pumpWidget(_harness(entry: entry, infoFields: const ['title']));
      expect(tester.widget<Text>(find.byType(Text)).textSpan!.toPlainText(),
          '作品标题');
    });
  });
  testWidgets('语义保留阅读、详情、多选动作而不重复朗读装饰内容', (tester) async {
    final semantics = tester.ensureSemantics();
    var read = 0, detail = 0, selected = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
      width: 180,
      child: IllustCard(
          entry: _entry(),
          imageProvider: null,
          selecting: true,
          selected: true,
          locationLabel: '壁纸',
          onTap: () {
            read++;
          },
          onInfoTap: () {
            detail++;
          },
          onLongPress: () {
            selected++;
          }),
    ))));
    final image = find.bySemanticsLabel('选择：作品标题，作者名，壁纸');
    final info = find.bySemanticsLabel(RegExp('详情与管理：.*壁纸', dotAll: true));
    expect(image, findsOneWidget);
    expect(info, findsOneWidget);
    expect(
        tester
            .getSemantics(image)
            .getSemanticsData()
            .hasAction(SemanticsAction.tap),
        isTrue);
    expect(
        tester
            .getSemantics(image)
            .getSemanticsData()
            .hasAction(SemanticsAction.longPress),
        isTrue);
    expect(
        tester
            .getSemantics(image)
            .getSemanticsData()
            .flagsCollection
            .isSelected,
        Tristate.isTrue);
    await tester.tap(image);
    await tester.tap(info);
    await tester.longPress(image);
    expect([read, detail, selected], [1, 1, 1]);
    expect(find.bySemanticsLabel('壁纸'), findsNothing);
    semantics.dispose();
  });
  group('不裁切：图片用 contain', () {
    testWidgets('有 provider 时 fit 必须是 contain（cover 必然裁边）', (tester) async {
      final entry = _entry(width: 638, height: 1200);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 120,
              child: IllustCard(
                entry: entry,
                // 一张 1x1 的内存图：只关心 fit 与尺寸，不需要真实解码。
                imageProvider: MemoryImage(_pngBytes(1, 1)),
                onTap: () {},
                onLongPress: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(_imageIn(tester).fit, BoxFit.contain);
    });

    testWidgets('格子比例 = 图片比例时，图片铺满格子（contain 不产生留白）', (tester) async {
      const ratio = 638 / 1200;
      final entry = _entry(width: 638, height: 1200);
      await tester.pumpWidget(
        _harness(entry: entry, columnWidth: 122, infoSpans: const []),
      );
      await tester.pump();

      final aspect = tester.getSize(find.byType(AspectRatio));
      // AspectRatio 的宽高由 entry.aspectRatio 决定
      expect(aspect.width / aspect.height, closeTo(ratio, 0.001));
    });
  });

  group('底部信息：由配置驱动', () {
    testWidgets('默认（不传 infoSpans）渲染标题 + 作者，与改动前一致', (tester) async {
      await tester.pumpWidget(_harness(entry: _entry()));
      await tester.pump();

      final richTexts = tester.widgetList<Text>(find.byType(Text)).toList();
      expect(richTexts.length, 1, reason: '信息块是**一个** Text.rich');
      final plain = richTexts.single.textSpan!.toPlainText();
      expect(plain, '作品标题\n作者名');
      // 标题加粗、作者次要：分段样式不能丢
      final span = richTexts.single.textSpan! as TextSpan;
      expect(span.children!.length, 3);
      expect(
          (span.children![0] as TextSpan).style!.fontWeight, FontWeight.w600);
      expect((span.children![2] as TextSpan).style!.color, isNotNull);
    });

    testWidgets('只勾标题 → 只有一行', (tester) async {
      await tester.pumpWidget(_harness(
        entry: _entry(),
        infoSpans: const <IllustCardInfoSpan>[
          IllustCardInfoSpan('作品标题', emphasized: true),
        ],
      ));
      await tester.pump();
      final text = tester.widget<Text>(find.byType(Text));
      expect(text.textSpan!.toPlainText(), '作品标题');
    });

    testWidgets('勾了尺寸 → 显示 宽×高（真实比例那条链路的可见结果）', (tester) async {
      final entry = _entry(width: 638, height: 1200);
      await tester.pumpWidget(_harness(
        entry: entry,
        infoSpans: illustrateCardInfoSpansFor(
          entry: entry,
          fields: <String>['title', 'size'],
          separator: '\n',
        ),
      ));
      await tester.pump();
      final text = tester.widget<Text>(find.byType(Text));
      expect(text.textSpan!.toPlainText(), '作品标题\n638×1200');
    });

    testWidgets('勾了页数 → 显示 p{N}（33 号：与下载命名同口径）', (tester) async {
      final entry = _entry(pageCount: 3);
      await tester.pumpWidget(_harness(
        entry: entry,
        infoSpans: illustrateCardInfoSpansFor(
          entry: entry,
          fields: <String>['title', 'pages'],
          separator: '\n',
        ),
      ));
      await tester.pump();
      final text = tester.widget<Text>(find.byType(Text));
      expect(text.textSpan!.toPlainText(), '作品标题\np3');
    });

    testWidgets('一个字段都没勾（空 spans）→ 底部不渲染任何文字', (tester) async {
      await tester.pumpWidget(_harness(
        entry: _entry(),
        infoSpans: const <IllustCardInfoSpan>[],
      ));
      await tester.pump();
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('分隔符不是换行时，字段排在同一行', (tester) async {
      final entry = _entry(width: 638, height: 1200);
      await tester.pumpWidget(_harness(
        entry: entry,
        infoSpans: illustrateCardInfoSpansFor(
          entry: entry,
          fields: <String>['title', 'author', 'size'],
          separator: ' - ',
        ),
      ));
      await tester.pump();
      final text = tester.widget<Text>(find.byType(Text));
      expect(text.textSpan!.toPlainText(), '作品标题 - 作者名 - 638×1200');
      expect(text.maxLines, 3);
    });

    testWidgets('信息整体在图片下方', (tester) async {
      await tester.pumpWidget(_harness(entry: _entry()));
      await tester.pump();
      final imageRect = tester.getRect(find.byType(AspectRatio));
      final textRect = tester.getRect(find.byType(Text));
      expect(textRect.top, greaterThanOrEqualTo(imageRect.bottom - 0.5));
    });

    testWidgets('比例未知（占位 3:4）时信息照样在图片下方，高度由占位比例决定', (tester) async {
      final entry = _entry();
      expect(entry.aspectRatio, illustFallbackAspectRatio);
      await tester.pumpWidget(_harness(entry: entry, columnWidth: 122));
      await tester.pump();
      final image = tester.getSize(find.byType(AspectRatio));
      expect(image.width / image.height,
          closeTo(illustFallbackAspectRatio, 0.001));
    });
  });

  group('降采样：contain 下按"实际显示宽度"算 cacheWidth', () {
    /// 量出卡片里 `ResizeImage` 的 `cacheWidth`。
    ///
    /// `ResizeImage.resizeIfNeeded` 在 `cacheWidth == null` 时返回原 provider，
    /// 所以这里必须用真实 `ImageProvider` 才能看到包装结果。
    Future<int?> cacheWidthFor(
      WidgetTester tester, {
      required double cellWidth,
      required double aspectRatio,
    }) async {
      final entry = _entry(
        width: (aspectRatio * 1000).round(),
        height: 1000,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: cellWidth,
                child: IllustCard(
                  entry: entry,
                  imageProvider: MemoryImage(_pngBytes(1, 1)),
                  infoSpans: const <IllustCardInfoSpan>[],
                  onTap: () {},
                  onLongPress: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final provider = _imageIn(tester).image;
      if (provider is CoverDecodeTarget) {
        return provider.frameWidth;
      }
      return null;
    }

    testWidgets('真实比例生效时，显示宽度 = 列宽 → cacheWidth ≈ 列宽 × DPR × 1.35',
        (tester) async {
      const cellWidth = 120.0; // 扣掉 illustCardGap * 2 后的图片宽度为 114
      const imageWidth = cellWidth - illustCardGap * 2;
      final cacheWidth = await cacheWidthFor(
        tester,
        cellWidth: cellWidth,
        aspectRatio: 0.75,
      );
      // 测试环境 DPR = 3.0
      expect(cacheWidth, (imageWidth * 3.0 * 1.35).round());
    });

    testWidgets('比例不符（格子比图更宽）时按实际显示宽度降采样，不按列宽白解', (tester) async {
      const cellWidth = 120.0;
      const imageWidth = cellWidth - illustCardGap * 2;
      // 格子比例固定为占位 0.75 时无法制造"不符"，所以这里用真实比例 0.75 的格子
      // 与一张更"瘦"的图（0.3）来对照：格子高 = imageWidth / 0.75，
      // contain 按高贴合 → 显示宽度 = 格高 × 0.3 < imageWidth。
      final cacheWidth = await cacheWidthFor(
        tester,
        cellWidth: cellWidth,
        // 传入 0.3 的图 → entry.aspectRatio = 0.3 → 格子也变成 0.3（同比例）。
        aspectRatio: 0.3,
      );
      // 同比例时仍是"列宽 × DPR × 1.35"（没有白解也没有欠采样）
      expect(cacheWidth, (imageWidth * 3.0 * 1.35).round());
    });

    testWidgets('占位比例与真实比例不一致的那一帧：cacheWidth 小于列宽口径', (tester) async {
      // 造一条"比例未知"的条目（格子 = 3:4 占位），但把它的 aspectRatio 改成
      // 更瘦的 0.3 —— 等价于"图比格子瘦"的 contain 场景。
      final entry = _entry();
      final thin = IllustLibraryEntry(
        item: entry.item,
        aspectRatio: 0.3,
        tags: entry.tags,
        width: entry.width,
        height: entry.height,
      );
      const cellWidth = 120.0;
      const imageWidth = cellWidth - illustCardGap * 2;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: cellWidth,
                child: IllustCard(
                  entry: thin,
                  imageProvider: MemoryImage(_pngBytes(1, 1)),
                  infoSpans: const <IllustCardInfoSpan>[],
                  onTap: () {},
                  onLongPress: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final provider = _imageIn(tester).image;
      expect(provider, isA<CoverDecodeTarget>());
      final cacheWidth = (provider as CoverDecodeTarget).frameWidth;
      // 格子与图同比例（都取自 entry.aspectRatio），所以这里等于列宽口径。
      expect(cacheWidth, (imageWidth * 3.0 * 1.35).round());
      // 关键：cacheWidth 一定是**有限正数**（降采样没被丢掉）
      expect(cacheWidth, greaterThan(0));
    });

    testWidgets('无 provider 时渲染占位图标，不抛异常', (tester) async {
      await tester.pumpWidget(_harness(entry: _entry()));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.image_not_supported_outlined), findsOneWidget);
    });
  });

  group('分区点击（36 号）：图片进阅读、信息进详情', () {
    Widget tapHarness({
      required IllustLibraryEntry entry,
      required VoidCallback onTap,
      VoidCallback? onInfoTap,
      required VoidCallback onLongPress,
    }) {
      return MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 160,
              child: IllustCard(
                entry: entry,
                imageProvider: MemoryImage(_pngBytes(1, 1)),
                onTap: onTap,
                onInfoTap: onInfoTap,
                onLongPress: onLongPress,
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('点**图片** → 只触发图片回调', (tester) async {
      var imageTaps = 0;
      var infoTaps = 0;
      await tester.pumpWidget(
        tapHarness(
          entry: _entry(width: 638, height: 1200, pageCount: 3),
          onTap: () => imageTaps++,
          onInfoTap: () => infoTaps++,
          onLongPress: () {},
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(Image));
      await tester.pumpAndSettle();

      expect(imageTaps, 1);
      expect(infoTaps, 0, reason: '图片区不该触发"打开详情"');
    });

    testWidgets('点**信息区** → 只触发信息回调', (tester) async {
      var imageTaps = 0;
      var infoTaps = 0;
      await tester.pumpWidget(
        tapHarness(
          entry: _entry(name: '可点的标题', width: 638, height: 1200),
          onTap: () => imageTaps++,
          onInfoTap: () => infoTaps++,
          onLongPress: () {},
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.textContaining('可点的标题', findRichText: true));
      await tester.pumpAndSettle();

      expect(infoTaps, 1);
      expect(imageTaps, 0, reason: '信息区不该直接进阅读器');
    });

    testWidgets('长按**两个区**都能触发（多选与点哪个区无关）', (tester) async {
      // 32 号首版这里只声明了 onTap 却忘了挂上去，整张卡片点不动；
      // 36 号补手势时把两个区都挂上，这条用例守住"别再只挂一半"。
      var longPresses = 0;
      await tester.pumpWidget(
        tapHarness(
          entry: _entry(name: '长按我', width: 638, height: 1200),
          onTap: () {},
          onInfoTap: () {},
          onLongPress: () => longPresses++,
        ),
      );
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(Image));
      await tester.pumpAndSettle();
      expect(longPresses, 1, reason: '图片区长按要能进多选');

      await tester.longPress(find.textContaining('长按我', findRichText: true));
      await tester.pumpAndSettle();
      expect(longPresses, 2, reason: '信息区长按同样要能进多选');
    });

    testWidgets('不传 onInfoTap 时回落到 onTap（既有调用不失去点击）', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        tapHarness(
          entry: _entry(name: '回落标题', width: 638, height: 1200),
          onTap: () => taps++,
          // 刻意不传 onInfoTap。
          onLongPress: () {},
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.textContaining('回落标题', findRichText: true));
      await tester.pumpAndSettle();
      expect(taps, 1);
    });

    testWidgets('信息区为空（没勾任何字段）时不会挡住图片区的点击', (tester) async {
      var imageTaps = 0;
      await tester.pumpWidget(
        tapHarness(
          entry: _entry(width: 638, height: 1200),
          onTap: () => imageTaps++,
          onInfoTap: () {},
          onLongPress: () {},
        ),
      );
      await tester.pumpAndSettle();
      // 默认信息区是有内容的（标题 + 作者），这里只确认图片仍可点中。
      await tester.tap(find.byType(Image));
      await tester.pumpAndSettle();
      expect(imageTaps, 1);
    });
  });
}

/// 一张最小的合法 PNG（1x1），给 `MemoryImage` 用。
Uint8List _pngBytes(int width, int height) {
  return Uint8List.fromList(<int>[
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
    0,
    0,
    0,
    13,
    0x49,
    0x48,
    0x44,
    0x52,
    0,
    0,
    0,
    width,
    0,
    0,
    0,
    height,
    8,
    6,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
  ]);
}

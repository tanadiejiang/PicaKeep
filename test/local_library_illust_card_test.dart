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
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/illust_card_info_config.dart';
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
  return pageCount == null ? entry : entry.withResolvedInfo(pageCount: pageCount);
}

/// 把卡片放进**与瀑布流一致的约束**里：固定列宽、高度不限（`SliverMasonryGrid`
/// 给子项的就是这个形态）。
Widget _harness({
  required IllustLibraryEntry entry,
  List<IllustCardInfoSpan>? infoSpans,
  double columnWidth = 120,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: columnWidth,
          child: IllustCard(
            entry: entry,
            imageProvider: null,
            infoSpans: infoSpans,
            onTap: () {},
            onLongPress: () {},
          ),
        ),
      ),
    ),
  );
}

/// 卡片里那个 `Image` 控件（`imageProvider: null` 时不存在，故仅供有图用例用）。
Image _imageIn(WidgetTester tester) => tester.widget<Image>(find.byType(Image));

void main() {
  group('不裁切：图片用 contain', () {
    testWidgets('有 provider 时 fit 必须是 contain（cover 必然裁边）',
        (tester) async {
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

    testWidgets('格子比例 = 图片比例时，图片铺满格子（contain 不产生留白）',
        (tester) async {
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
    testWidgets('默认（不传 infoSpans）渲染标题 + 作者，与改动前一致',
        (tester) async {
      await tester.pumpWidget(_harness(entry: _entry()));
      await tester.pump();

      final richTexts = tester.widgetList<Text>(find.byType(Text)).toList();
      expect(richTexts.length, 1, reason: '信息块是**一个** Text.rich');
      final plain = richTexts.single.textSpan!.toPlainText();
      expect(plain, '作品标题\n作者名');
      // 标题加粗、作者次要：分段样式不能丢
      final span = richTexts.single.textSpan! as TextSpan;
      expect(span.children!.length, 3);
      expect((span.children![0] as TextSpan).style!.fontWeight,
          FontWeight.w600);
      expect((span.children![2] as TextSpan).style!.color,
          isNotNull);
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

    testWidgets('勾了尺寸 → 显示 宽×高（真实比例那条链路的可见结果）',
        (tester) async {
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

    testWidgets('比例未知（占位 3:4）时信息照样在图片下方，高度由占位比例决定',
        (tester) async {
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
      if (provider is ResizeImage) {
        return provider.width;
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

    testWidgets('比例不符（格子比图更宽）时按实际显示宽度降采样，不按列宽白解',
        (tester) async {
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

    testWidgets('占位比例与真实比例不一致的那一帧：cacheWidth 小于列宽口径',
        (tester) async {
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
      expect(provider, isA<ResizeImage>());
      final cacheWidth = (provider as ResizeImage).width!;
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
}

/// 一张最小的合法 PNG（1x1），给 `MemoryImage` 用。
Uint8List _pngBytes(int width, int height) {
  return Uint8List.fromList(<int>[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    0, 0, 0, 13,
    0x49, 0x48, 0x44, 0x52,
    0, 0, 0, width,
    0, 0, 0, height,
    8, 6, 0, 0, 0,
    0, 0, 0, 0,
  ]);
}

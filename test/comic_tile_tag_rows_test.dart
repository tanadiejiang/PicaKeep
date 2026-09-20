import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/components/comic_tile.dart';

void main() {
  const author = 'Always visible author';
  const size = '128 MB';
  const badge = 'EH';

  group('DownloadedComicTile tag row limit', () {
    testWidgets('builds only a two-row tag prefix and hides its semantics',
        (tester) async {
      final tags = List<String>.generate(18, (index) => 'tag-$index');
      final semanticsHandle = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          _tile(
            tags: tags,
            maxTagRows: 2,
          ),
        );

        final visibleTags = <String>[
          for (final tag in tags)
            if (find.text(tag).evaluate().isNotEmpty) tag,
        ];
        expect(visibleTags, isNotEmpty);
        expect(visibleTags.length, lessThan(tags.length));
        expect(visibleTags, orderedEquals(tags.take(visibleTags.length)));

        final tagRows = <double>[];
        for (final tag in visibleTags) {
          final y = tester.getTopLeft(find.text(tag)).dy;
          if (!tagRows.any((rowY) => (rowY - y).abs() < 1)) {
            tagRows.add(y);
          }
        }
        expect(tagRows.length, lessThanOrEqualTo(2));
        expect(find.text(author), findsOneWidget);
        expect(find.text(size), findsOneWidget);
        expect(find.text(badge), findsOneWidget);
        expect(
          find.bySemanticsLabel(RegExp(RegExp.escape(visibleTags.first))),
          findsWidgets,
        );
        expect(
          find.bySemanticsLabel(RegExp(RegExp.escape(tags.last))),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      } finally {
        semanticsHandle.dispose();
      }
    });

    testWidgets('uses current scale and chip width without overflowing',
        (tester) async {
      const longTag = 'this is a deliberately very long downloaded tag value';
      final tags = <String>[
        longTag,
        ...List<String>.generate(12, (index) => 'scaled-tag-$index'),
      ];
      await tester.pumpWidget(
        _tile(
          width: 280,
          height: 220,
          title: 'A title that needs two lines at a larger text scale',
          textScale: 1.8,
          tags: tags,
          maxTagRows: 2,
        ),
      );

      final longTagText = tester.widget<Text>(find.text(longTag));
      expect(longTagText.maxLines, 1);
      expect(longTagText.overflow, TextOverflow.ellipsis);
      expect(find.text(author), findsOneWidget);
      expect(find.text(size), findsOneWidget);
      expect(find.text(badge), findsOneWidget);

      final visibleTags = <String>[
        for (final tag in tags)
          if (find.text(tag).evaluate().isNotEmpty) tag,
      ];
      final tagRows = <double>[];
      for (final tag in visibleTags) {
        final y = tester.getTopLeft(find.text(tag)).dy;
        if (!tagRows.any((rowY) => (rowY - y).abs() < 1)) {
          tagRows.add(y);
        }
      }
      expect(tagRows.length, lessThanOrEqualTo(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'keeps the author and footer through narrow, normal, and wide layouts',
        (tester) async {
      final tags =
          List<String>.generate(20, (index) => 'responsive-tag-$index');
      final cases = <({double width, double textScale, String title})>[
        (width: 240, textScale: 1, title: 'One line title'),
        (
          width: 240,
          textScale: 1.8,
          title:
              'A narrow layout title that needs two lines at large text scale',
        ),
        (width: 360, textScale: 1, title: 'One line title'),
        (
          width: 360,
          textScale: 1.8,
          title:
              'A normal layout title that needs two lines at large text scale',
        ),
        (
          width: 600,
          textScale: 1,
          title:
              'A sufficiently long wide layout title that still needs two lines at normal scale',
        ),
        (
          width: 600,
          textScale: 1.8,
          title:
              'A sufficiently long wide layout title that needs two lines at a large text scale',
        ),
      ];

      for (final layout in cases) {
        await tester.pumpWidget(
          _tile(
            width: layout.width,
            title: layout.title,
            textScale: layout.textScale,
            tags: tags,
            maxTagRows: 2,
          ),
        );

        final visibleTags = <String>[
          for (final tag in tags)
            if (find.text(tag).evaluate().isNotEmpty) tag,
        ];
        final tagRows = <double>[];
        for (final tag in visibleTags) {
          final y = tester.getTopLeft(find.text(tag)).dy;
          if (!tagRows.any((rowY) => (rowY - y).abs() < 1)) {
            tagRows.add(y);
          }
        }
        expect(tagRows.length, lessThanOrEqualTo(2));
        expect(find.text(author), findsOneWidget);
        expect(find.text(size), findsOneWidget);
        expect(find.text(badge), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('keeps the unrestricted layout when no limit is supplied',
        (tester) async {
      final tags = List<String>.generate(12, (index) => 'unrestricted-$index');
      await tester.pumpWidget(
        _tile(
          height: 280,
          tags: tags,
        ),
      );

      for (final tag in tags) {
        expect(find.text(tag), findsOneWidget);
      }
      expect(find.text(author), findsOneWidget);
      expect(find.text(size), findsOneWidget);
      expect(find.text(badge), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('retains the historical expanded empty-list layout by default',
        (tester) async {
      await tester.pumpWidget(
        _tile(
          height: 280,
          tags: const <String>[],
        ),
      );
      final unrestrictedFooterY = tester.getTopLeft(find.text(size)).dy;

      await tester.pumpWidget(
        _tile(
          height: 280,
          tags: const <String>[],
          maxTagRows: 2,
        ),
      );
      final limitedFooterY = tester.getTopLeft(find.text(size)).dy;

      expect(unrestrictedFooterY, greaterThan(limitedFooterY));
      expect(tester.takeException(), isNull);
    });
  });
  // 04 计划：JM 列表卡片同时有分类标签与 jm 号时的布局回归。
  group('标签 + 描述位同显时不出卡片', () {
    const jmTitle = '【ばんばんべいん（ばんばん）】るりちゃ'
        'んは調教済み【中國翻譯】[DL版]';
    const jmTags = <String>['同人'];

    testWidgets('JM 卡片：jm 号与标签都在卡片高度内', (tester) async {
      const cardHeight = 164.0;
      await tester.pumpWidget(
        _tile(
          height: cardHeight,
          title: jmTitle,
          author: 'ばんばん',
          size: 'jm1473622',
          tags: jmTags,
          maxTagRows: 2,
        ),
      );

      final footerBottom = tester.getBottomLeft(find.text('jm1473622')).dy;
      expect(footerBottom, lessThanOrEqualTo(cardHeight),
          reason: 'jm 号底部 $footerBottom 超出卡片高度 $cardHeight');
      expect(tester.takeException(), isNull);
    });

    testWidgets('对照：描述位为空时同样不出卡片', (tester) async {
      const cardHeight = 164.0;
      await tester.pumpWidget(
        _tile(
          height: cardHeight,
          title: jmTitle,
          author: 'ばんばん',
          size: '',
          tags: jmTags,
          maxTagRows: 2,
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('真机宽度 544dp：jm 号底部落在卡片内', (tester) async {
      const cardHeight = 164.0;
      await tester.pumpWidget(
        _tile(
          width: 544,
          height: cardHeight,
          title: jmTitle,
          author: 'ばんばん',
          size: 'jm1473622',
          tags: jmTags,
          maxTagRows: 2,
        ),
      );

      final footerBottom = tester.getBottomLeft(find.text('jm1473622')).dy;
      expect(footerBottom, lessThanOrEqualTo(cardHeight),
          reason: 'jm 号底部 $footerBottom 超出卡片高度 $cardHeight');
      expect(tester.takeException(), isNull);
    });

    testWidgets('诊断：空间受压时 jm 号不被挤出卡片', (tester) async {
      const cardHeight = 164.0;
      for (final scale in <double>[1.0, 1.3, 1.6, 1.8]) {
        await tester.pumpWidget(
          _tile(
            width: 411,
            height: cardHeight,
            textScale: scale,
            title: jmTitle,
            author: 'ばんばん',
            size: 'jm1473622',
            tags: jmTags,
            maxTagRows: 2,
          ),
        );
        final footerBottom = tester.getBottomLeft(find.text('jm1473622')).dy;
        expect(footerBottom, lessThanOrEqualTo(cardHeight),
            reason: 'textScale=$scale 时 jm 号底部 $footerBottom 超出 '
                '卡片高度 $cardHeight');
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('描述位贴内容排布：标签区不抢占 footer 所需高度', (tester) async {
      const cardHeight = 164.0;
      await tester.pumpWidget(
        _tile(
          width: 544,
          height: cardHeight,
          title: jmTitle,
          author: 'ばんばん',
          size: 'jm1473622',
          tags: jmTags,
          maxTagRows: 2,
        ),
      );

      final footerBottom = tester.getBottomLeft(find.text('jm1473622')).dy;
      final cardBottom =
          tester.getBottomLeft(find.byType(DownloadedComicTile)).dy;
      // 关键性质：footer 底部必须留在卡片高度内。标签区若用 Expanded 抢满
      // 剩余高度，footer 会被顶到定高之外（真机超出约 6.6dp）。
      expect(footerBottom, lessThanOrEqualTo(cardBottom),
          reason: '描述位被挤出卡片：footer=$footerBottom card=$cardBottom');
      expect(footerBottom, lessThan(cardHeight));
      expect(tester.takeException(), isNull);
    });

    testWidgets('标签区只占内容高度，不撑满剩余空间', (tester) async {
      await tester.pumpWidget(
        _tile(
          width: 544,
          height: 164,
          title: jmTitle,
          author: 'ばんばん',
          size: 'jm1473622',
          tags: jmTags,
          maxTagRows: 2,
        ),
      );
      const chipHeight = 23.0; // 12pt 文本 + 上下 padding + 行间距
      final tagTop = tester.getTopLeft(find.text('同人')).dy;
      final footerTop = tester.getTopLeft(find.text('jm1473622')).dy;
      final tagBlockHeight = footerTop - tagTop;
      // 单行标签时标签区应贴近一个 chip 的高度；若被撑满剩余空间会远大于此。
      expect(tagBlockHeight, inInclusiveRange(chipHeight, chipHeight * 1.6),
          reason: '标签区实际高度 $tagBlockHeight 偏离单行内容高度');
      expect(tester.takeException(), isNull);
    });

    // 网络收藏页与搜索结果页都不传 maxTagRows，走的是"无限制"布局分支；
    // 上面的用例走 _buildLimitedLayout，两者必须分别覆盖。
    testWidgets('不传 maxTagRows 时（收藏/搜索实际路径）描述位仍在卡片内',
        (tester) async {
      const cardHeight = 164.0;
      await tester.pumpWidget(
        _tile(
          width: 544,
          height: cardHeight,
          title: jmTitle,
          author: 'ばんばん',
          size: 'jm1473622',
          tags: jmTags,
        ),
      );

      final tagTop = tester.getTopLeft(find.text('同人')).dy;
      final footerTop = tester.getTopLeft(find.text('jm1473622')).dy;
      final footerBottom = tester.getBottomLeft(find.text('jm1473622')).dy;
      final cardBottom =
          tester.getBottomLeft(find.byType(DownloadedComicTile)).dy;
      // 标签与描述行之间仍有实际间距（标签区没被压成 0 高）。
      expect(footerTop - tagTop, greaterThanOrEqualTo(20.0),
          reason: '标签与描述行间距异常：${footerTop - tagTop}');
      // 关键性质：描述位整体留在卡片高度内，不被顶出去。
      expect(footerBottom, lessThanOrEqualTo(cardBottom),
          reason: '描述位被挤出卡片：footer=$footerBottom card=$cardBottom');
      expect(tester.takeException(), isNull);
    });
  });
}

Widget _tile({
  required List<String> tags,
  int? maxTagRows,
  double width = 360,
  double height = 164,
  double textScale = 1,
  String title = 'Downloaded comic',
  String author = 'Always visible author',
  String size = '128 MB',
  bool? isFavorite = false,
}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            height: height,
            child: DownloadedComicTile(
              name: title,
              author: author,
              imagePath: File(''),
              isFavoriteOverride: isFavorite,
              type: 'EH',
              tag: tags,
              size: size,
              maxTagRows: maxTagRows,
              onTap: () {},
              onLongTap: () {},
              onSecondaryTap: (_) {},
            ),
          ),
        ),
      ),
    ),
  );
}

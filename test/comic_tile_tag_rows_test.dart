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
}

Widget _tile({
  required List<String> tags,
  int? maxTagRows,
  double width = 360,
  double height = 164,
  double textScale = 1,
  String title = 'Downloaded comic',
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
              author: 'Always visible author',
              imagePath: File(''),
              isFavoriteOverride: false,
              type: 'EH',
              tag: tags,
              size: '128 MB',
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

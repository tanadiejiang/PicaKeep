import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/components/comic_tag_wrap.dart';

void main() {
  testWidgets('不限时全部标签自然换行，不预留固定行预算', (tester) async {
    Future<void> show(List<String> tags) => tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(
                width: 100,
                child:
                    ComicTagWrap(tags: tags, maxRows: null, reserveRows: true),
              ),
            ),
          ),
        ));
    await show([]);
    expect(tester.getSize(find.byType(ComicTagWrap)).height, 0);
    await show(['一']);
    final one = tester.getSize(find.byType(ComicTagWrap)).height;
    await show(List.generate(20, (i) => '很长的标签-$i'));
    expect(find.byType(ComicTagChip), findsNWidgets(20));
    expect(tester.getSize(find.byType(ComicTagWrap)).height, greaterThan(one));
    expect(find.text('很长的标签-19'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  for (final rows in [1, 2, 3]) {
    for (final scale in [1.0, 1.8]) {
      testWidgets('$rows 行在字号缩放 $scale 和 RTL 下截断且高度固定', (tester) async {
        final semantics = tester.ensureSemantics();
        Future<void> show(List<String> tags) => tester.pumpWidget(MaterialApp(
              home: Scaffold(
                  body: MediaQuery(
                data: MediaQueryData(
                    textScaler: TextScaler.linear(scale), boldText: true),
                child: Directionality(
                    textDirection: TextDirection.rtl,
                    child: Align(
                      alignment: Alignment.topRight,
                      child: SizedBox(
                          width: 100,
                          child: ComicTagWrap(
                            tags: tags,
                            maxRows: rows,
                            reserveRows: true,
                          )),
                    )),
              )),
            ));
        await show([]);
        final budget = tester.getSize(find.byType(ComicTagWrap));
        await show(List.generate(200, (i) => '特别长的标签-$i-🙂'));
        expect(tester.getSize(find.byType(ComicTagWrap)), budget);
        expect(find.byType(ComicTagChip), findsNWidgets(rows));
        final area = tester.getRect(find.byType(ComicTagWrap));
        for (final chip in tester.elementList(find.byType(ComicTagChip))) {
          final rect = tester.getRect(find.byWidget(chip.widget));
          expect(rect.left, greaterThanOrEqualTo(area.left - .01));
          expect(rect.right, lessThanOrEqualTo(area.right + .01));
          expect(rect.bottom, lessThanOrEqualTo(area.bottom + .01));
        }
        expect(find.bySemanticsLabel(RegExp('特别长的标签-199')), findsNothing);
        expect(tester.takeException(), isNull);
        semantics.dispose();
      });
    }
  }
}

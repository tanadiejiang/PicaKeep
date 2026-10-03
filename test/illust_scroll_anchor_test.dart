import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/pages/illust_scroll_anchor.dart';

void main() {
  testWidgets(
      'idle size updates above a visible artwork keep its screen position',
      (tester) async {
    final anchor = IllustScrollAnchor();
    var firstHeight = 100.0;
    late StateSetter redraw;
    await tester.pumpWidget(
        MaterialApp(home: StatefulBuilder(builder: (context, update) {
      redraw = update;
      return ListView(controller: anchor.controller, children: [
        SizedBox(height: firstHeight),
        SizedBox(
            key: anchor.keyFor('visible'),
            height: 400,
            child: const Text('artwork')),
        const SizedBox(height: 1800),
      ]);
    })));
    anchor.controller.jumpTo(150);
    await tester.pump();
    final before = tester.getTopLeft(find.byKey(anchor.keyFor('visible'))).dy;
    final captured = anchor.capture(['visible'], 0, 600);
    redraw(() => firstHeight = 200);
    anchor.restore(captured, isCurrent: () => true);
    await tester.pump();
    await tester.pump();
    expect(tester.getTopLeft(find.byKey(anchor.keyFor('visible'))).dy,
        closeTo(before, 0.5));
    expect(anchor.controller.offset, 250);
    await tester.pumpWidget(const SizedBox());
    anchor.dispose();
  });

  testWidgets('stale generation never forces scroll correction',
      (tester) async {
    final anchor = IllustScrollAnchor();
    await tester.pumpWidget(MaterialApp(
        home: ListView(
            controller: anchor.controller,
            children: [SizedBox(key: anchor.keyFor('item'), height: 2000)])));
    anchor.controller.jumpTo(100);
    await tester.pump();
    final captured = anchor.capture(['item'], 0, 600);
    anchor.restore(captured, isCurrent: () => false);
    anchor.controller.jumpTo(200);
    await tester.pump();
    expect(anchor.controller.offset, 200);
    await tester.pumpWidget(const SizedBox());
    anchor.dispose();
  });
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/components/info_value_action.dart';

void main() {
  testWidgets('long press copies directly without opening a menu',
      (tester) async {
    String? copied;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InfoValueAction(
            data: const InfoValueData(
              displayText: '狐女',
              rawSearchValue: 'female:fox girl',
            ),
            onSearch: () {},
            clipboardWriter: (value) async {
              copied = value;
            },
            child: const Text('狐女'),
          ),
        ),
      ),
    );

    await tester.longPress(find.text('狐女'));
    await tester.pump();

    expect(copied, '狐女');
    expect(find.byType(PopupMenuButton), findsNothing);
  });

  testWidgets('Enter and Space activate the search callback when focused',
      (tester) async {
    var searches = 0;
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InfoValueAction(
            focusNode: focusNode,
            data: const InfoValueData(displayText: 'artist'),
            onSearch: () => searches++,
            child: const Text('artist'),
          ),
        ),
      ),
    );

    focusNode.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);

    expect(searches, 2);
  });

  testWidgets('empty values do not invoke search or clipboard writer',
      (tester) async {
    var searches = 0;
    var copies = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InfoValueAction(
            data: const InfoValueData(displayText: ' '),
            onSearch: () => searches++,
            clipboardWriter: (_) async => copies++,
            child: const SizedBox(width: 1, height: 1),
          ),
        ),
      ),
    );

    final target = find.byType(InfoValueAction);
    await tester.tap(target);
    await tester.longPress(target);
    await tester.pump();

    expect(searches, 0);
    expect(copies, 0);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InfoValueAction(
            data: const InfoValueData(displayText: '未知'),
            onSearch: () => searches++,
            child: const Text('未知'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('未知'));
    expect(searches, 0);
  });

  testWidgets('keeps intrinsic size when placed in a metadata Wrap',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: Wrap(
              spacing: 6,
              children: [
                Chip(
                  key: ValueKey('compact-label'),
                  label: Text('标签'),
                ),
                InfoValueAction(
                  key: ValueKey('compact-value'),
                  data: InfoValueData(displayText: '狐女'),
                  child: Chip(label: Text('狐女')),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final actionSize =
        tester.getSize(find.byKey(const ValueKey('compact-value')));
    final chipSize = tester.getSize(find.widgetWithText(Chip, '狐女'));
    expect(actionSize.width, closeTo(chipSize.width, 0.01));
    expect(actionSize.height, closeTo(chipSize.height, 0.01));
    expect(actionSize.width, lessThan(320));
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('compact-value'))).dy,
      closeTo(
        tester.getTopLeft(find.byKey(const ValueKey('compact-label'))).dy,
        0.01,
      ),
    );
  });

  testWidgets(
      'allows an explicit full-width layout without changing the default',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: InfoValueAction(
              key: ValueKey('expanded-value'),
              layout: InfoValueActionLayout.expand,
              data: InfoValueData(displayText: '标题'),
              child: Text('标题'),
            ),
          ),
        ),
      ),
    );

    expect(
      tester.getSize(find.byKey(const ValueKey('expanded-value'))).width,
      320,
    );
  });
}

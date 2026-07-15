import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/ai/ai_conversation.dart';
import 'package:picakeep/pages/ai/ai_chat_page.dart';

List<Map<String, dynamic>> _fixtureItems() =>
    List<Map<String, dynamic>>.generate(
      12,
      (index) => {
        'id': '$index',
        'title': '脱敏标题 $index',
        'author': '作者 $index',
        'coverUrl': '',
        'source': index < 2 ? 'ehentai' : 'nhentai',
        'tags': <String>['fixture'],
        'availability': '7页，汉化',
      },
    );

Widget _host(Widget child) => MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: Scaffold(body: child),
    );

void _useTallTestSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

void main() {
  testWidgets('工具卡原始结果入口使用规范化条数并可进入完整清单', (tester) async {
    _useTallTestSurface(tester);
    await tester.pumpWidget(
      _host(
        AiToolResultCard(
          toolName: 'display_result_list',
          resultText: '工具执行成功',
          resultData: {'items': _fixtureItems()},
          isResult: true,
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byType(ErrorWidget), findsNothing);
    expect(find.text('查看 12 条原始结果'), findsOneWidget);

    await tester.tap(find.text('查看 12 条原始结果'));
    await tester.pumpAndSettle();
    expect(find.text('工具结果 (12条)'), findsOneWidget);
  });

  testWidgets('消息清单查看全部入口和长灰块回归', (tester) async {
    _useTallTestSurface(tester);
    await tester.pumpWidget(
      _host(
        AiResultListEntryCard(
          message: AiChatMessage.resultList(items: _fixtureItems()),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byType(ErrorWidget), findsNothing);
    final entrySize = tester.getSize(find.byType(AiResultListEntryCard));
    expect(entrySize.height, lessThan(1000));
    expect(find.text('共 12 条结果，查看全部'), findsOneWidget);

    await tester.tap(find.text('共 12 条结果，查看全部'));
    await tester.pumpAndSettle();
    expect(find.text('工具结果 (12条)'), findsOneWidget);
  });

  testWidgets('全不可恢复旧数据显示有界失败态且点击不抛异常', (tester) async {
    _useTallTestSurface(tester);
    await tester.pumpWidget(
      _host(
        AiResultListEntryCard(
          message: AiChatMessage(
            type: AiChatMessageType.resultList,
            text: '旧结果',
            toolData: {
              'items': [
                {},
              ],
            },
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('清单结果暂不可读取'), findsOneWidget);
    expect(find.byType(ErrorWidget), findsNothing);
    expect(tester.getSize(find.byType(AiResultListEntryCard)).height,
        lessThan(300));
  });
}

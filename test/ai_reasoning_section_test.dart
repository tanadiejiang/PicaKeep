import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/pages/ai/ai_chat_page.dart';

/// 15轮06号计划：思考块折叠状态机 + 「点击折叠 / 长按选择共存」行为守卫。
void main() {
  Future<void> pump(
    WidgetTester tester, {
    required bool streaming,
    required bool hasContent,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: AiReasoningSection(
            reasoningText: '这是一段思考内容',
            streaming: streaming,
            hasContent: hasContent,
          ),
        ),
      ),
    ));
  }

  bool contentVisible(WidgetTester tester) =>
      tester.any(find.widgetWithText(SelectableText, '这是一段思考内容'));

  testWidgets('历史消息默认折叠，点标题行展开', (tester) async {
    await pump(tester, streaming: false, hasContent: true);
    expect(find.text('思考过程'), findsOneWidget);
    expect(contentVisible(tester), isFalse);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);

    await tester.tap(find.text('思考过程'));
    await tester.pumpAndSettle();
    expect(contentVisible(tester), isTrue);
    expect(find.byIcon(Icons.expand_less), findsOneWidget);
  });

  testWidgets('折叠图标为 16px 小图标', (tester) async {
    await pump(tester, streaming: false, hasContent: true);
    final icon = tester.widget<Icon>(find.byIcon(Icons.chevron_right));
    expect(icon.size, 16);
  });

  testWidgets('展开后点内容本身 → 折叠（SelectableText.onTap）', (tester) async {
    await pump(tester, streaming: false, hasContent: true);
    await tester.tap(find.text('思考过程'));
    await tester.pumpAndSettle();
    expect(contentVisible(tester), isTrue);

    await tester.tap(find.text('这是一段思考内容'));
    await tester.pumpAndSettle();
    expect(contentVisible(tester), isFalse);
  });

  testWidgets('展开后长按内容 → 仍展开（长按走选择不走折叠）', (tester) async {
    await pump(tester, streaming: false, hasContent: true);
    await tester.tap(find.text('思考过程'));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('这是一段思考内容'));
    await tester.pumpAndSettle();
    expect(contentVisible(tester), isTrue);
  });

  testWidgets('流式思考期默认展开并显示「思考中…」+ 转圈', (tester) async {
    await pump(tester, streaming: true, hasContent: false);
    expect(find.text('思考中…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(contentVisible(tester), isTrue);
  });

  testWidgets('正文首字到达（hasContent 翻 true）→ 自动折叠', (tester) async {
    await pump(tester, streaming: true, hasContent: false);
    expect(contentVisible(tester), isTrue);

    // 同一 State 上重建（widget 配置变化，不重新创建 State）。
    await pump(tester, streaming: true, hasContent: true);
    await tester.pumpAndSettle();
    expect(contentVisible(tester), isFalse);
    expect(find.text('思考过程'), findsOneWidget);
  });

  testWidgets('用户手动展开后，自动逻辑不覆盖用户选择', (tester) async {
    await pump(tester, streaming: true, hasContent: false);
    // streaming 态有无限转圈动画，pumpAndSettle 永不返回，这里只 pump 有限帧。
    // 手动收起再手动展开 → _userChoice = true 接管。
    await tester.tap(find.text('思考中…'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(contentVisible(tester), isFalse);
    await tester.tap(find.text('思考中…'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(contentVisible(tester), isTrue);

    // 正文到达后依然保持展开。
    await pump(tester, streaming: true, hasContent: true);
    await tester.pump(const Duration(milliseconds: 100));
    expect(contentVisible(tester), isTrue);
  });
}

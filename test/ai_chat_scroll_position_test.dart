import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/ai/ai_conversation.dart';
import 'package:picakeep/foundation/ai/ai_conversation_store.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/pages/ai/ai_chat_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 12/13号计划：AI 聊天页滚动定位语义的 widget 测试。
///
/// 13号计划将"切 tab 回来到底部"改为"切 tab 也保存并恢复阅读位置"，
/// 与"页内切会话保位置"语义完全对齐：
/// - 首次加载（无记忆位置）→ 到底部；
/// - 切 tab（State 销毁重建）回到 AI 页 → 恢复离开时的阅读位置；
/// - 页内切会话再切回 → 恢复离开该会话时的阅读位置。
///
/// 用真实 AiChatPage + 真实 AiConversationStore（数据目录指向临时目录）跑，
/// 不打网络：只有 send() 会调 LLM，本测试全部走"预置会话文件 → 读取"路径。
void main() {
  // AiChatPage.initState 自己走真实文件 I/O 加载会话（loadLastActiveId →
  // loadConversation）。默认的 AutomatedTestWidgetsFlutterBinding 是 FakeAsync
  // 区，区内发起的真实 I/O future 永不完成，页面会一直停在加载转圈上；改用
  // LiveTestWidgetsFlutterBinding 走真实事件循环。
  LiveTestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() async {
    tempDir = Directory.systemTemp.createTempSync('ai_chat_scroll_test');
    App.dataPath = tempDir.path;
    SharedPreferences.setMockInitialValues({});
    // appdata 是懒初始化的顶层变量：只有被访问过 _createAppdata() 才会执行，
    // AiPromptTagSettingsController.instance 才拿到 settings 存储绑定。
    appdata.settings.length;
    // 会话文件必须在 testWidgets 之外预置：testWidgets 体内直接 await 文件 I/O
    // 不受 pump 驱动，容易死等。
    await _seedConversation(id: _tabCaseId, title: _tabCaseTitle);
    await _seedConversation(id: _tabCaseId2, title: _tabCaseTitle2);
    await _seedConversation(id: _switchCaseAId, title: _switchCaseATitle);
    await _seedConversation(id: _switchCaseAId2, title: _switchCaseATitle2);
    await _seedConversation(id: _switchCaseBId, title: _switchCaseBTitle);
  });

  tearDownAll(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  testWidgets('首次加载落在最底部', (tester) async {
    // 用独立 id，static 记忆表里绝对没有记录 → 走"首次访问到底部"路径。
    await AiConversationStore.saveLastActiveId(_tabCaseId);
    await _pumpChatPage(tester);

    final first = _requireMessageController(tester);
    expect(first.position.maxScrollExtent, greaterThan(0),
        reason: '预置 30 条消息应撑出可滚动区域');
    expect(first.offset, closeTo(first.position.maxScrollExtent, 1),
        reason: '首次加载（无记忆位置）应落在最底部');
  });

  testWidgets('切 tab 回来恢复离开时的阅读位置', (tester) async {
    // 用独立 id 保证这是"首次访问"，以底部开始。
    await AiConversationStore.saveLastActiveId(_tabCaseId2);
    await _pumpChatPage(tester);

    final first = _requireMessageController(tester);
    expect(first.offset, closeTo(first.position.maxScrollExtent, 1),
        reason: '首次加载应落在最底部');

    // 手动往上翻到中间，模拟用户读历史。
    await _scrollUp(tester, 420);
    final middle = _requireMessageController(tester).offset;
    expect(middle, lessThan(first.position.maxScrollExtent - 100),
        reason: '手动上翻应真正离开底部');

    // 切 tab：NaviPane 不用 IndexedStack，切走会完整销毁 State，
    // dispose() 在销毁前保存 offset。
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
    );
    await _settle(tester, frames: 4);
    // 切回来：_loadController 走 _restoreScrollOffsetAfterFrame，有记忆位置就恢复。
    await _pumpChatPage(tester);

    final back = _requireMessageController(tester);
    expect(back.offset, closeTo(middle, 8),
        reason: '切 tab 回来应恢复离开时的阅读位置（13号计划新语义）');
  });

  testWidgets('页内切会话再切回恢复历史阅读位置', (tester) async {
    // 独立 id，首次访问 → 到底部开始。
    await AiConversationStore.saveLastActiveId(_switchCaseAId);
    await _pumpChatPage(tester);

    expect(find.textContaining('第 0 条消息'), findsNothing,
        reason: '会话甲首次进入应在底部，第一条消息不可见');
    await _scrollUp(tester, 480);
    final savedOffset = _requireMessageController(tester).offset;
    expect(savedOffset, greaterThan(0));
    expect(
      savedOffset,
      lessThan(
          _requireMessageController(tester).position.maxScrollExtent - 100),
    );

    // 页内切到会话乙（首次访问，无记忆位置 → 到底部）。
    await _switchConversationViaDrawer(tester, _switchCaseBTitle);
    final onB = _requireMessageController(tester);
    expect(onB.offset, closeTo(onB.position.maxScrollExtent, 1),
        reason: '首次访问的会话应落在底部');

    // 再切回会话甲 → 恢复刚才翻到的位置。
    await _switchConversationViaDrawer(tester, _switchCaseATitle);
    final backOnA = _requireMessageController(tester);
    expect(backOnA.offset, closeTo(savedOffset, 8), reason: '切回旧会话应恢复离开时的阅读位置');
    expect(backOnA.offset, lessThan(backOnA.position.maxScrollExtent - 100),
        reason: '恢复后不应被 pending 滚底或自动跟随拉回底部');
  });

  testWidgets('切 tab 与切会话位置记忆互不污染', (tester) async {
    // 验证：会话甲曾被页内切换记录了中间位置，切 tab 回来后读的是同一张记忆表
    // （13号计划新语义：切 tab 也保位置，不再强制到底部）。
    // 用独立 id 保证记忆表里只有本次测试写入的内容。
    await AiConversationStore.saveLastActiveId(_switchCaseAId2);
    await _pumpChatPage(tester);

    // 首次访问 → 到底部。
    final first = _requireMessageController(tester);
    expect(first.offset, closeTo(first.position.maxScrollExtent, 1),
        reason: '首次访问无记忆位置，应在底部');

    // 翻到中间。
    await _scrollUp(tester, 480);
    final savedOffset = _requireMessageController(tester).offset;
    expect(savedOffset, lessThan(first.position.maxScrollExtent - 100));

    // 切 tab 离开（保存位置）然后切回（恢复位置）。
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
    );
    await _settle(tester, frames: 4);
    await _pumpChatPage(tester);

    final back = _requireMessageController(tester);
    expect(back.offset, closeTo(savedOffset, 8),
        reason: '切 tab 回来恢复位置，与页内切会话语义一致');
  });
}

const _tabCaseId = 'scroll-case-tab';
const _tabCaseTitle = '滚动用例-切标签页';
const _tabCaseId2 = 'scroll-case-tab2';
const _tabCaseTitle2 = '滚动用例-切标签页2';
const _switchCaseAId = 'scroll-case-a';
const _switchCaseATitle = '滚动用例-会话甲';
const _switchCaseAId2 = 'scroll-case-a2';
const _switchCaseATitle2 = '滚动用例-会话甲2';
const _switchCaseBId = 'scroll-case-b';
const _switchCaseBTitle = '滚动用例-会话乙';

Future<void> _seedConversation({
  required String id,
  required String title,
  int messageCount = 30,
}) async {
  await AiConversationStore.save(
    id: id,
    title: title,
    createdAt: DateTime.now(),
    displayMessages: List<AiChatMessage>.generate(
      messageCount,
      (index) => AiChatMessage.assistant('第 $index 条消息，用于撑开列表高度。'),
    ),
    history: const [],
  );
}

Future<void> _pumpChatPage(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: AiChatPage()));
  await _settle(tester, frames: 12);
  expect(_messageScrollController(tester), isNotNull,
      reason: '会话应加载完成并渲染出消息列表');
}

/// 有界推帧：AiChatPage 在 controller 加载完成前显示 CircularProgressIndicator
/// （无限动画），pumpAndSettle 永不返回；这里用"真实等待 + pump"逐帧推进，
/// 顺带给 pending 滚动的逐帧收敛留出帧数。
Future<void> _settle(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
    await tester.pump();
  }
}

Future<void> _scrollUp(WidgetTester tester, double distance) async {
  await tester.drag(find.byType(ListView).first, Offset(0, distance));
  await _settle(tester, frames: 6);
}

Future<void> _switchConversationViaDrawer(
  WidgetTester tester,
  String title,
) async {
  await tester.tap(find.byIcon(Icons.menu));
  await _settle(tester, frames: 10);
  await tester.tap(find.text(title));
  await _settle(tester, frames: 14);
}

/// 消息列表的 ScrollController：页面里只有消息 ListView 显式挂了 controller
/// （侧栏 ListView 没有），据此区分。
ScrollController? _messageScrollController(WidgetTester tester) {
  for (final listView in tester.widgetList<ListView>(find.byType(ListView))) {
    final controller = listView.controller;
    if (controller != null && controller.hasClients) return controller;
  }
  return null;
}

ScrollController _requireMessageController(WidgetTester tester) {
  final controller = _messageScrollController(tester);
  expect(controller, isNotNull, reason: '未找到消息列表的 ScrollController');
  return controller!;
}

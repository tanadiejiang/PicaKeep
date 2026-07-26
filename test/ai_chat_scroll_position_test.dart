import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/components/scrollable_list/scrollable_positioned_list.dart';
import 'package:picakeep/foundation/ai/ai_conversation.dart';
import 'package:picakeep/foundation/ai/ai_conversation_store.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/pages/ai/ai_chat_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 12/13/15号计划：AI 聊天页滚动定位语义的 widget 测试。
///
/// 13号计划将"切 tab 回来到底部"改为"切 tab 也保存并恢复阅读位置"，
/// 与"页内切会话保位置"语义完全对齐：
/// - 首次加载（无记忆位置）→ 到底部；
/// - 切 tab（State 销毁重建）回到 AI 页 → 恢复离开时的阅读位置；
/// - 页内切会话再切回 → 恢复离开该会话时的阅读位置。
///
/// 15号计划把消息列表换成 ScrollablePositionedList，位置记忆从"像素 offset"
/// 改为"item index"，因此断言口径同步调整：
/// - 贴底仍然是像素语义（maxScrollExtent 才是真底部），继续用 offset 断言；
/// - 恢复历史位置改成断言"离开时顶部那条消息又回到了顶部"（index 语义），
///   像素值不再要求逐像素相等。
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
    await _seedConversation(id: _anchorCaseLongId, title: _anchorCaseLongTitle);
    await _seedConversation(id: _anchorCaseMidId, title: _anchorCaseMidTitle);
    await _seedConversation(id: _anchorCaseMid2Id, title: _anchorCaseMid2Title);
    await _seedConversation(
      id: _anchorCaseShortId,
      title: _anchorCaseShortTitle,
      messageCount: 3,
    );
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
    final middleOffset = _requireMessageController(tester).offset;
    expect(middleOffset, lessThan(first.position.maxScrollExtent - 100),
        reason: '手动上翻应真正离开底部');
    final middleTopIndex = _topVisibleIndex(tester);
    expect(middleTopIndex, greaterThan(0), reason: '上翻后顶部不应还是第 0 条');

    // 切 tab：NaviPane 不用 IndexedStack，切走会完整销毁 State，
    // dispose() 在销毁前保存 offset。
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
    );
    await _settle(tester, frames: 4);
    // 切回来：_loadController 走 _restoreScrollOffsetAfterFrame，有记忆位置就恢复。
    await _pumpChatPage(tester);

    final back = _requireMessageController(tester);
    expect(_topVisibleIndex(tester), middleTopIndex,
        reason: '切 tab 回来应把离开时顶部那条消息重新顶到顶部（15号计划 index 语义）');
    expect(back.offset, lessThan(back.position.maxScrollExtent - 100),
        reason: '恢复后不应被 pending 滚底或自动跟随拉回底部');
  });

  testWidgets('页内切会话再切回恢复历史阅读位置', (tester) async {
    // 独立 id，首次访问 → 到底部开始。
    await AiConversationStore.saveLastActiveId(_switchCaseAId);
    await _pumpChatPage(tester);

    expect(find.textContaining('第 0 条消息'), findsNothing,
        reason: '会话甲首次进入应在底部，第一条消息不可见');
    await _scrollUp(tester, 480);
    final savedTopIndex = _topVisibleIndex(tester);
    expect(savedTopIndex, greaterThan(0));
    expect(
      _requireMessageController(tester).offset,
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
    expect(_topVisibleIndex(tester), savedTopIndex,
        reason: '切回旧会话应把离开时顶部那条消息重新顶到顶部');
    expect(backOnA.offset, lessThan(backOnA.position.maxScrollExtent - 100),
        reason: '恢复后不应被 pending 滚底或自动跟随拉回底部');
  });

  testWidgets('内容不足一屏的短会话必须真正显示出来', (tester) async {
    // 15号计划回归用例：UnboundedCustomScrollView 的 maxScrollExtent 允许为负
    // （内容不足一屏时 min == max < 0）。pending 落位若用 maxExtent <= 0 判断
    // "列表还没渲染"，短会话会把重试预算耗尽而永不清 pending，Opacity 卡在 0，
    // 整页消息不可见（find 仍能找到，所以必须显式断言 opacity）。
    await AiConversationStore.saveLastActiveId(_anchorCaseShortId);
    await _pumpChatPage(tester);

    expect(_messageListOpacity(tester), 1.0,
        reason: 'pending 应已清除，消息列表不能停留在 Opacity(0)');
    expect(find.textContaining('第 0 条消息'), findsOneWidget,
        reason: '短会话的首条消息应可见');
  });

  testWidgets('锚点停在历史位置时切到贴底会话仍落在真底部', (tester) async {
    // 15号计划专项用例：切会话不会重建 ScrollablePositionedList 的 State，
    // 锚点 positionedIndex 会带着上一个会话的历史 index 进入新会话。
    // 断言此时"跳到 maxScrollExtent"依然等于跳到真实内容底部。
    await AiConversationStore.saveLastActiveId(_anchorCaseLongId);
    await _pumpChatPage(tester);

    // 手动上翻只改像素、不改锚点；必须"切走再切回"走一次 index 恢复，
    // 才能让列表锚点真正落在历史 index 上。
    await _scrollUp(tester, 480);
    final savedTopIndex = _topVisibleIndex(tester);
    expect(savedTopIndex, greaterThan(2), reason: '需要一个足够深的历史锚点');
    await _switchConversationViaDrawer(tester, _anchorCaseMidTitle);
    await _switchConversationViaDrawer(tester, _anchorCaseLongTitle);
    expect(_topVisibleIndex(tester), savedTopIndex,
        reason: '切回长会话应按 index 恢复，此时锚点 != 0');

    // 页内切到另一个首次访问的长会话（无记忆位置 → 贴底路径）。
    await _switchConversationViaDrawer(tester, _anchorCaseMid2Title);
    final onMid2 = _requireMessageController(tester);
    expect(onMid2.offset, closeTo(onMid2.position.maxScrollExtent, 1),
        reason: '锚点非 0 时贴底仍应收敛到 maxScrollExtent');
    expect(find.textContaining('第 29 条消息'), findsOneWidget,
        reason: '真底部意味着最后一条消息可见');
    expect(_messageListOpacity(tester), 1.0, reason: 'pending 应已清除');
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
    final savedTopIndex = _topVisibleIndex(tester);
    expect(_requireMessageController(tester).offset,
        lessThan(first.position.maxScrollExtent - 100));

    // 切 tab 离开（保存位置）然后切回（恢复位置）。
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
    );
    await _settle(tester, frames: 4);
    await _pumpChatPage(tester);

    expect(_topVisibleIndex(tester), savedTopIndex,
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
const _anchorCaseLongId = 'scroll-case-anchor-long';
const _anchorCaseLongTitle = '滚动用例-锚点长会话';
const _anchorCaseMidId = 'scroll-case-anchor-mid';
const _anchorCaseMidTitle = '滚动用例-锚点中转会话';
const _anchorCaseMid2Id = 'scroll-case-anchor-mid2';
const _anchorCaseMid2Title = '滚动用例-锚点中转会话2';
const _anchorCaseShortId = 'scroll-case-anchor-short';
const _anchorCaseShortTitle = '滚动用例-锚点短会话';

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
  await tester.drag(
      find.byType(ScrollablePositionedList).first, Offset(0, distance));
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

/// 15号计划：消息列表是页面里唯一的 ScrollablePositionedList（侧栏仍是 ListView）。
ScrollablePositionedList? _messageList(WidgetTester tester) {
  final found = tester.widgetList<ScrollablePositionedList>(
      find.byType(ScrollablePositionedList));
  if (found.isEmpty) return null;
  final list = found.first;
  return list.scrollController.hasClients ? list : null;
}

/// 消息列表的 ScrollController：贴底类断言仍走像素语义。
ScrollController? _messageScrollController(WidgetTester tester) =>
    _messageList(tester)?.scrollController;

ScrollController _requireMessageController(WidgetTester tester) {
  final controller = _messageScrollController(tester);
  expect(controller, isNotNull, reason: '未找到消息列表的 ScrollController');
  return controller!;
}

/// 消息列表外层 Opacity 的当前值：13号计划用 Opacity(0) 遮住 pending 期间的
/// 首帧，pending 若永不清除会表现为整页不可见，必须能被断言到。
double _messageListOpacity(WidgetTester tester) {
  final opacity = tester.widget<Opacity>(
    find
        .ancestor(
          of: find.byType(ScrollablePositionedList),
          matching: find.byType(Opacity),
        )
        .first,
  );
  return opacity.opacity;
}

/// 当前可见的最小 index（= 视口顶部那条）。itemPositions 不按 index 排序，
/// 必须自己取 min。
int _topVisibleIndex(WidgetTester tester) {
  final list = _messageList(tester);
  expect(list, isNotNull, reason: '未找到消息列表');
  final positions = list!.itemPositionsNotifier!.itemPositions.value;
  expect(positions, isNotEmpty, reason: 'itemPositions 应已上报可见项');
  return positions.map((p) => p.index).reduce((a, b) => a < b ? a : b);
}

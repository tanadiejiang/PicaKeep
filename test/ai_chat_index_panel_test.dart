import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/components/scrollable_list/scrollable_positioned_list.dart';
import 'package:picakeep/foundation/ai/ai_conversation.dart';
import 'package:picakeep/foundation/ai/ai_conversation_store.dart';
import 'package:picakeep/foundation/ai/ai_settings.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/pages/ai/ai_chat_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 15号计划 Feature 2 / 16号计划：AI 聊天页消息索引面板的 widget 测试。
///
/// 覆盖点：
/// - 长按右边缘打开面板，点击面板外遮罩关闭；
/// - 面板只索引 user / assistant 消息，工具类消息不进索引；
/// - 点击条目跳到对应消息（主列表可见 index 变化）并关闭面板；
/// - 当前可见消息对应的条目被高亮（未可见的不高亮）；
/// - 右边缘触发条不吞掉主列表的竖向滚动；
/// - 16号计划：长按拖到某条松手 → 跳转 + 面板关闭；
/// - 16号计划：长按原地松手 → 跳转 + 面板关闭；
/// - 16号计划：高亮一致性——拖选目标与跳转目标相同 index。
///
/// 与 ai_chat_scroll_position_test.dart 同样用真实 AiChatPage +
/// 真实 AiConversationStore（数据目录指向临时目录），不打网络。
void main() {
  // AiChatPage.initState 走真实文件 I/O 加载会话，默认的 FakeAsync binding 里
  // 这些 future 永不完成，必须用 LiveTestWidgetsFlutterBinding。
  LiveTestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  // 17号计划步骤 10/11：两个新设置都是全局 appdata.settings，跨 testWidgets 存活。
  // 每个用例前复位成默认值，避免前一个用例改过的设置污染后一个（用例顺序无关）。
  setUp(() {
    appdata.settings[aiIndexUserOnlySettingIndex] = '1';
    appdata.settings[aiIndexBarMaxTicksSettingIndex] = '6';
  });

  setUpAll(() async {
    tempDir = Directory.systemTemp.createTempSync('ai_chat_index_panel_test');
    App.dataPath = tempDir.path;
    SharedPreferences.setMockInitialValues({});
    appdata.settings.length;
    await _seedMixedConversation();
    // 阅读位置记忆表是 _AiChatPageState 的 static 字段，跨 testWidgets 存活：
    // 每个用例必须用独立会话 id，否则前一个用例留下的位置会让后一个用例
    // 不再从底部开始。
    await _seedLongConversation(_jumpCaseId, _jumpCaseTitle);
    await _seedLongConversation(_highlightCaseId, _highlightCaseTitle);
    await _seedLongConversation(_dragCaseId, _dragCaseTitle);
    await _seedLongConversation(_rehighlightCaseId, _rehighlightCaseTitle);
    // 16号计划：拖选手势用例各需独立会话 id，避免阅读位置记忆污染。
    await _seedLongConversation(_lpDragCaseId, _lpDragCaseTitle);
    await _seedLongConversation(_lpRelCaseId, _lpRelCaseTitle);
    await _seedLongConversation(_lpConsistCaseId, _lpConsistCaseTitle);
    // 17号计划：高度约束哨兵用例
    await _seedLongConversation(_extentCaseId, _extentCaseTitle);
    // _inputAreaReserve=265 后 60% 上限约 167：4 条（208）已放不下，
    // "面板按内容收缩/不可滚动"用例改用 3 条（156）的专用短会话。
    await _seedShortConversation(_shortCaseId, _shortCaseTitle);
    // 17号计划步骤 11/12：过滤开关与迷你索引条用例
    await _seedMixedAs(_userOnlyCaseId, _userOnlyCaseTitle);
    await _seedMixedAs(_toggleCaseId, _toggleCaseTitle);
    await _seedMixedAs(_barUserSrcCaseId, _barUserSrcCaseTitle);
    await _seedLongConversation(_barCaseId, _barCaseTitle);
    await _seedLongConversation(_barLimitCaseId, _barLimitCaseTitle);
    await _seedLongConversation(_barActiveCaseId, _barActiveCaseTitle);
    await _seedLongConversation(_barScrollCaseId, _barScrollCaseTitle);
    await _seedAssistantOnlyConversation(_barEmptyCaseId, _barEmptyCaseTitle);
    await _seedAssistantOnlyConversation(
      _emptyScaleCaseId,
      _emptyScaleCaseTitle,
    );
    // 第 1 轮校验补：横线数超过命中区容量的回归用例（"不限制" + 超长会话）。
    await _seedLongConversation(
      _barFitCaseId,
      _barFitCaseTitle,
      messageCount: 240,
    );
    // 17号计划步骤 8：边缘自动滚动用例。前 8 个需要长会话把面板撑到可滚动，
    // 最后一个刻意用短会话验证 maxScrollExtent==0 时不启动。
    await _seedLongConversation(_autoDownCaseId, _autoDownCaseTitle);
    await _seedLongConversation(_autoUpCaseId, _autoUpCaseTitle);
    await _seedLongConversation(_autoMidCaseId, _autoMidCaseTitle);
    await _seedLongConversation(_autoReleaseCaseId, _autoReleaseCaseTitle);
    await _seedLongConversation(_autoEndCaseId, _autoEndCaseTitle);
    await _seedLongConversation(_autoHoverCaseId, _autoHoverCaseTitle);
    await _seedLongConversation(_autoSpeedCaseId, _autoSpeedCaseTitle);
    await _seedLongConversation(_autoCapCaseId, _autoCapCaseTitle);
    // 「内容不足一屏不启动」同样受 60% 上限收紧影响，改用 3 条的短会话
    // （见 _seedShortConversation 注释），保证 maxScrollExtent==0 的前提成立。
    await _seedShortConversation(_autoNoScrollCaseId, _autoNoScrollCaseTitle);
    await _seedLongConversation(_autoDisposeCaseId, _autoDisposeCaseTitle);
  });

  tearDownAll(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  testWidgets('长按右边缘打开索引面板，点击面板外区域关闭', (tester) async {
    await AiConversationStore.saveLastActiveId(_mixedId);
    await _pumpChatPage(tester);

    expect(find.bySemanticsLabel('消息索引面板'), findsNothing, reason: '默认不显示索引面板');

    final gesture = await _longPressRightEdge(tester);
    expect(find.bySemanticsLabel('消息索引面板'), findsOneWidget,
        reason: '长按右边缘应打开面板');

    // 点面板外的左侧区域（面板贴右边缘，屏幕左侧一定在面板之外）。
    final size = tester.view.physicalSize / tester.view.devicePixelRatio;
    await tester.tapAt(Offset(24, size.height / 2));
    await _settle(tester, frames: 8);
    expect(find.bySemanticsLabel('消息索引面板'), findsNothing,
        reason: '点击面板外遮罩应关闭面板');
    await gesture.cancel();
  });

  testWidgets('索引只收录 user/assistant 消息，工具类消息不进索引', (tester) async {
    // 17号计划步骤 11 之后 user+assistant 只在「仅显示用户对话」关闭时成立。
    // 本用例考的是"工具类消息永不进索引"这条不变量，与过滤开关无关，
    // 因此显式关掉开关以保留原始意图（断言一字未改）。
    appdata.settings[aiIndexUserOnlySettingIndex] = '0';
    await AiConversationStore.saveLastActiveId(_mixedId);
    await _pumpChatPage(tester);
    final gesture = await _longPressRightEdge(tester);

    // 预置会话：user/assistant 各 2 条 + 1 条 toolCall + 1 条 toolResult。
    // 面板里应只出现 4 条，且不含工具消息文本。
    expect(_panelRowCount(tester), 4, reason: '面板条目数应等于 user+assistant 条数');
    expect(
      _panelTextFinder(tester, '正在调用工具'),
      findsNothing,
      reason: '工具调用消息不应进入索引',
    );
    expect(_panelTextFinder(tester, '问题一'), findsOneWidget);
    expect(_panelTextFinder(tester, '回答一'), findsOneWidget);
    await gesture.cancel();
  });

  testWidgets('点击索引条目跳到对应消息并关闭面板', (tester) async {
    await AiConversationStore.saveLastActiveId(_jumpCaseId);
    await _pumpChatPage(tester);

    // 首次加载在底部：第 0 条不可见。
    expect(find.textContaining('第 0 条消息'), findsNothing);
    final bottomTopIndex = _topVisibleIndex(tester);
    expect(bottomTopIndex, greaterThan(0));

    final gesture = await _longPressRightEdge(tester);
    // 面板打开时会把当前高亮条目滚进视口（此处在底部），第 2 条要先滚上去。
    // 面板 ListView 用 itemExtent 定高，只构建可见行，未构建的行 find 不到。
    await _scrollPanelToTop(tester);
    await tester.tap(_panelTextFinder(tester, '第 2 条消息'));
    await _settle(tester, frames: 10);

    expect(find.bySemanticsLabel('消息索引面板'), findsNothing, reason: '点击条目后面板应关闭');
    expect(_topVisibleIndex(tester), lessThan(bottomTopIndex),
        reason: '主列表应向上跳到目标消息附近');
    expect(find.textContaining('第 2 条消息'), findsOneWidget, reason: '目标消息应进入视口');
    // 面板已由点击条目关闭，此处 cancel 只清理手势残留（onLongPressCancel 不跳转）。
    await gesture.cancel();
  });

  testWidgets('当前可见消息对应条目高亮，不可见的不高亮', (tester) async {
    await AiConversationStore.saveLastActiveId(_highlightCaseId);
    await _pumpChatPage(tester);

    final visibleIndices = _visibleIndices(tester);
    expect(visibleIndices, isNotEmpty);
    // 面板打开时会把"第一个高亮条目"滚到面板视口中部，即最小可见 index 那条，
    // 它一定被构建出来，可以稳定断言。
    final topVisible = _topVisibleIndex(tester);

    final gesture = await _longPressRightEdge(tester);

    expect(_isRowHighlighted(tester, '第 $topVisible 条消息'), isTrue,
        reason: '可见消息对应的索引条目应高亮');

    // 滚到面板顶部，第 0 条一定不在主列表视口内 → 不应高亮。
    await _scrollPanelToTop(tester);
    expect(visibleIndices.contains(0), isFalse);
    expect(_isRowHighlighted(tester, '第 0 条消息'), isFalse,
        reason: '不在视口内的消息，其索引条目不应高亮');
    await gesture.cancel();
  });

  testWidgets('跳转后重开面板，高亮跟着落到新位置', (tester) async {
    await AiConversationStore.saveLastActiveId(_rehighlightCaseId);
    await _pumpChatPage(tester);

    final bottomTop = _topVisibleIndex(tester);
    final gesture1 = await _longPressRightEdge(tester);
    await _scrollPanelToTop(tester);
    await tester.tap(_panelTextFinder(tester, '第 1 条消息'));
    await _settle(tester, frames: 10);
    await gesture1.cancel();

    // 跳转后重开面板：_visibleIndices 应已刷新到跳转后的视口
    // （关闭时摘监听、打开时重读一次当前 itemPositions）。
    final afterJumpTop = _topVisibleIndex(tester);
    expect(afterJumpTop, lessThan(bottomTop));
    final gesture2 = await _longPressRightEdge(tester);
    expect(_isRowHighlighted(tester, '第 $afterJumpTop 条消息'), isTrue,
        reason: '重开面板应高亮跳转后的可见条目');

    // 原底部条目已离开视口 → 不该再高亮。它此刻在面板视口之外（面板自动把
    // 高亮条目滚到中部），要先滚下去让它被构建出来才能断言。
    await _scrollPanelToBottom(tester);
    expect(_isRowHighlighted(tester, '第 29 条消息'), isFalse,
        reason: '原底部条目已离开视口，不应再高亮');
    await gesture2.cancel();
  });

  testWidgets('在触发条上竖向拖动应照常滚动主列表', (tester) async {
    await AiConversationStore.saveLastActiveId(_dragCaseId);
    await _pumpChatPage(tester);

    final before = _topVisibleIndex(tester);
    // 通过 Semantics label 取触发条实际中心，避免猜坐标。
    final center = tester.getCenter(
      find.bySemanticsLabel('消息索引，长按打开'),
    );
    await tester.dragFrom(center, const Offset(0, 360));
    await _settle(tester, frames: 8);

    expect(_topVisibleIndex(tester), lessThan(before),
        reason: '在触发条上竖向拖动应照常滚动主列表');
    expect(find.bySemanticsLabel('消息索引面板'), findsNothing, reason: '拖动不应打开面板');
  });

  // -----------------------------------------------------------------------
  // 16号计划：拖选手势用例
  // -----------------------------------------------------------------------

  // -----------------------------------------------------------------------
  // 17号计划步骤 1：面板高度约束哨兵
  // -----------------------------------------------------------------------

  testWidgets('面板内容超出可用高度时列表可滚动，且打开时高亮条目已滚进视口', (tester) async {
    await AiConversationStore.saveLastActiveId(_extentCaseId);
    await _pumpChatPage(tester);

    final gesture = await _longPressRightEdge(tester);

    // 哨兵：Positioned 只给 top/right 时 Stack 下发无界高度约束，视口高度会等于
    // 内容高度、maxScrollExtent 恒为 0。没有这条断言，后续任何"面板滚动"用例
    // 都是假绿（offset 永远是 0）。
    final position = _panelScrollPosition(tester);
    expect(position.maxScrollExtent, greaterThan(0),
        reason: '30 条消息（30×52=1560）远超可用高度，面板列表必须有可滚动余量');
    expect(position.viewportDimension, lessThan(30 * 52.0),
        reason: '面板视口必须小于内容全高，否则高度上限没生效');

    // _revealActiveEntry 此前是空操作（maxScrollExtent==0，jumpTo 只能落 0）。
    // 首次加载停在会话底部，高亮条目在列表尾部，滚动位置必须已被推离顶端。
    expect(position.pixels, greaterThan(0),
        reason: '打开面板时应把高亮条目滚进视口，而不是停在第 0 条');

    // 面板底边不得压到输入区：输入区是 body Column 的最后一段，
    // 取消息列表底边作为输入区上沿。
    final panelRect = tester.getRect(find.bySemanticsLabel('消息索引面板'));
    final listRect = tester.getRect(find.byType(ScrollablePositionedList));
    expect(panelRect.bottom, lessThanOrEqualTo(listRect.bottom),
        reason: '面板底边必须留在输入区上方');
    // 约 60% 上限：面板高度不应超过消息区高度的 60% 再加一点余量。
    expect(panelRect.height, lessThan(listRect.height * 0.65),
        reason: '面板最大高度约为可用高度的 60%');

    await gesture.cancel();
    await _settle(tester, frames: 8);
  });

  testWidgets('短会话面板按内容收缩，不留空白也不可滚动', (tester) async {
    // _inputAreaReserve 手调到 265 后，测试视口（600 高）里 60% 上限只剩约
    // 167：原来 4 条可索引消息的内容高 208 已超上限，"短会话"前提失效。
    // 改用 3 条 user 消息的专用会话（3×52=156 仍在上限内），期望值按
    // 运行时行数 × 行高现算，上限将来再调也不必改数字。
    await AiConversationStore.saveLastActiveId(_shortCaseId);
    await _pumpChatPage(tester);
    final gesture = await _longPressRightEdge(tester);

    // 原始意图不变：内容不足上限时，面板高度==内容高度、且没有可滚动余量。
    final rows = _panelRowCount(tester);
    expect(rows, 3, reason: '前置：短会话应有 3 条可索引消息');
    final panelRect = tester.getRect(find.bySemanticsLabel('消息索引面板'));
    expect(panelRect.height, closeTo(rows * 52.0, 1.0),
        reason: '短会话面板高度应等于条目总高（行数×52），不留空白；'
            '若此处失败且高度更小，说明高度上限已低于 3 行，"短会话"前提再次失效');
    expect(_panelScrollPosition(tester).maxScrollExtent, 0,
        reason: '内容不足一屏时不应产生可滚动余量');
    await gesture.cancel();
    await _settle(tester, frames: 8);
  });

  // -----------------------------------------------------------------------
  // 17号计划步骤 11：仅显示用户消息
  // -----------------------------------------------------------------------

  testWidgets('默认只索引用户消息，AI 回复不进面板', (tester) async {
    await AiConversationStore.saveLastActiveId(_userOnlyCaseId);
    await _pumpChatPage(tester);
    final gesture = await _longPressRightEdge(tester);

    // 混合会话：user/assistant 各 2 条 + 2 条工具消息。默认开关开启 → 只剩 2 条。
    expect(_panelRowCount(tester), 2, reason: '默认应只索引 user 消息');
    expect(_panelTextFinder(tester, '问题一'), findsOneWidget);
    expect(_panelTextFinder(tester, '回答一'), findsNothing,
        reason: 'assistant 消息不应进入索引');
    await gesture.cancel();
    await _settle(tester, frames: 8);
  });

  testWidgets('切换「仅显示用户对话」立即生效，无需重开会话', (tester) async {
    await AiConversationStore.saveLastActiveId(_toggleCaseId);
    await _pumpChatPage(tester);

    final gesture1 = await _longPressRightEdge(tester);
    expect(_panelRowCount(tester), 2, reason: '默认开启 → 只有 2 条 user');
    await gesture1.cancel();
    await _settle(tester, frames: 8);

    // 关掉开关后重开面板。会话 id、渲染项数、消息数、末条文本长度全都没变，
    // 版本键若不含该设置值就会命中旧缓存，表现为"开关拨了没反应"。
    appdata.settings[aiIndexUserOnlySettingIndex] = '0';
    final gesture2 = await _longPressRightEdge(tester);
    expect(_panelRowCount(tester), 4,
        reason: '关闭开关应立刻列出 user+assistant，说明版本键已含该设置');
    expect(_panelTextFinder(tester, '回答一'), findsOneWidget);
    await gesture2.cancel();
    await _settle(tester, frames: 8);
  });

  // -----------------------------------------------------------------------
  // 17号计划步骤 12：迷你索引条
  // -----------------------------------------------------------------------

  testWidgets('迷你索引条常驻显示，横线数按刻度上限截断', (tester) async {
    await AiConversationStore.saveLastActiveId(_barCaseId);
    await _pumpChatPage(tester);

    // 不长按也可见：默认上限 6，会话有 30 条 user 消息 → 截断成 6 根。
    expect(find.bySemanticsLabel('消息索引面板'), findsNothing, reason: '未长按，面板不应打开');
    expect(_tickCount(tester), 6, reason: '30 条用户消息 + 上限 6 → 6 根横线');

    // 命中区扩大到 36dp（向屏幕内侧延伸 16dp），视觉索引条仍贴右边缘。
    expect(
      tester.getSize(find.bySemanticsLabel('消息索引，长按打开')).width,
      36,
      reason: '命中区应为 36dp 宽（从 20dp 扩大，更容易触发）',
    );
    final gesture = await _longPressRightEdge(tester);
    expect(find.bySemanticsLabel('消息索引面板'), findsOneWidget,
        reason: '换成迷你索引条后长按仍应触发面板');
    await gesture.cancel();
    await _settle(tester, frames: 8);
  });

  testWidgets('刻度上限改小/设为不限制都立即反映到横线数', (tester) async {
    appdata.settings[aiIndexBarMaxTicksSettingIndex] = '4';
    await AiConversationStore.saveLastActiveId(_barLimitCaseId);
    await _pumpChatPage(tester);
    expect(_tickCount(tester), 4, reason: '上限 4 → 4 根');

    appdata.settings[aiIndexBarMaxTicksSettingIndex] = '0';
    await tester.tap(find.byType(ScrollablePositionedList),
        warnIfMissed: false);
    await _settle(tester, frames: 6);
    expect(_tickCount(tester), 30, reason: "'0' = 不限制 → 横线数等于用户消息数 30");
  });

  testWidgets('不限制 + 超长会话时横线数收到命中区装得下的根数，不溢出', (tester) async {
    // 第 1 轮校验发现的回归：横线槽位固定 3dp，间距收到 0 之后仍有物理上限
    // （命中区高度 / 3）。设置选「不限制」且会话很长时会超出命中区——实测命中区
    // 高 480、240 条用户消息时 Column 溢出 240px。收紧后走既有的
    // 「截断 + 百分比映射」路径，两端仍能到齐。
    appdata.settings[aiIndexBarMaxTicksSettingIndex] = '0';
    await AiConversationStore.saveLastActiveId(_barFitCaseId);
    await _pumpChatPage(tester);

    expect(tester.takeException(), isNull, reason: '迷你索引条不应溢出命中区');
    final barHeight = tester.getSize(find.bySemanticsLabel('消息索引，长按打开')).height;
    final count = _tickCount(tester);
    expect(count, lessThan(240), reason: '装不下 240 根时必须收紧根数');
    expect(count, greaterThan(0), reason: '收紧不等于不画');
    // 槽位 3dp/根，总高不得超过命中区。
    expect(count * 3.0, lessThanOrEqualTo(barHeight), reason: '横线总高不得超过命中区高度');
    // 截断后仍走百分比映射：首帧在底部 → 加深最后一根。
    expect(_activeTickIndex(tester), count - 1, reason: '截断后滚到底仍应加深最后一根');
  });

  testWidgets('当前位置横线同时更深、更长、更厚', (tester) async {
    await AiConversationStore.saveLastActiveId(_barActiveCaseId);
    await _pumpChatPage(tester);

    final colorScheme =
        Theme.of(tester.element(find.byType(AiChatPage))).colorScheme;
    final ticks = _tickWidgets(tester);
    expect(ticks.length, 6);

    // 首帧停在会话底部 → 加深的应是最后一根。
    final activeIdx = _activeTickIndex(tester);
    expect(activeIdx, 5, reason: '首次加载停在底部，应加深最后一根');

    final active = ticks[activeIdx];
    final normal = ticks[0];
    // 三个维度逐一断言，不只看颜色。
    expect(_tickWidth(active), greaterThan(_tickWidth(normal)),
        reason: '当前线应更长');
    expect(_tickHeight(active), greaterThan(_tickHeight(normal)),
        reason: '当前线应更厚');
    expect(_tickColor(active), colorScheme.primary, reason: '当前线应是 primary 实色');
    expect(_tickColor(normal)!.a, lessThan(1.0), reason: '普通线应是压低透明度的浅色');
    expect(_tickColor(active)!.a, greaterThan(_tickColor(normal)!.a),
        reason: '当前线应更深');

    // 右端贴边对齐：长度差往内侧（左）延伸，右边缘应对齐。
    final activeRect = _tickRect(tester, activeIdx);
    final normalRect = _tickRect(tester, 0);
    expect(activeRect.right, closeTo(normalRect.right, 0.01),
        reason: '右端应贴边对齐，长度差往左延伸');
    expect(activeRect.left, lessThan(normalRect.left));
  });

  testWidgets('滚动主列表时加深位置随之移动', (tester) async {
    await AiConversationStore.saveLastActiveId(_barScrollCaseId);
    await _pumpChatPage(tester);

    expect(_activeTickIndex(tester), 5, reason: '底部 → 最后一根');

    // 往上滚到顶：加深位置应回到第一根。
    for (var i = 0; i < 8; i++) {
      await tester.drag(
          find.byType(ScrollablePositionedList), const Offset(0, 600));
      await _settle(tester, frames: 4);
    }
    expect(_activeTickIndex(tester), 0, reason: '滚到顶部 → 加深第一根');

    // 往下滚回去：加深位置应重新前进。
    for (var i = 0; i < 4; i++) {
      await tester.drag(
          find.byType(ScrollablePositionedList), const Offset(0, -400));
      await _settle(tester, frames: 4);
    }
    expect(_activeTickIndex(tester), greaterThan(0), reason: '向下滚动后加深位置应前移');
  });

  testWidgets('迷你索引条只数用户消息，不受「仅显示用户对话」开关影响', (tester) async {
    // 关掉开关：面板会列 user+assistant 共 4 条，但索引条仍只按 2 条 user 画。
    appdata.settings[aiIndexUserOnlySettingIndex] = '0';
    await AiConversationStore.saveLastActiveId(_barUserSrcCaseId);
    await _pumpChatPage(tester);

    expect(_tickCount(tester), 2, reason: '索引条始终只取 user，与面板过滤开关无关');
    final gesture = await _longPressRightEdge(tester);
    expect(_panelRowCount(tester), 4, reason: '面板此时应列 user+assistant');
    await gesture.cancel();
    await _settle(tester, frames: 8);
  });

  testWidgets('会话无用户消息时不画横线也不崩', (tester) async {
    await AiConversationStore.saveLastActiveId(_barEmptyCaseId);
    await _pumpChatPage(tester);

    expect(_tickCount(tester), 0, reason: '没有用户消息时不应画横线');
    expect(tester.takeException(), isNull);
    // 命中区仍在，长按仍能开面板（面板此时是"暂无可索引的消息"空态）。
    final gesture = await _longPressRightEdge(tester);
    // 这里必须用 RegExp 而不是精确字符串：空态下面板内没有 ListView，
    // 少了 Scrollable 那道语义边界，"暂无可索引的消息"这个 Text 会被
    // 合并进面板的容器节点，label 变成 '消息索引面板\n暂无可索引的消息'，
    // 精确匹配查不到（实测确认）。非空态有 ListView 时不会合并。
    expect(find.bySemanticsLabel(RegExp('消息索引面板')), findsOneWidget,
        reason: '空态下长按仍应打开面板');
    expect(find.text('暂无可索引的消息'), findsOneWidget, reason: '空态文案应出现');
    await gesture.cancel();
    await _settle(tester, frames: 8);
  });

  testWidgets('特大字号下空态面板不被高度上限压出溢出', (tester) async {
    // 第 1 轮校验发现的回归：步骤 1 的 ConstrainedBox 上限若在空态也按 rowExtent
    // (52) 兜底，特大字号（App 自身最大档 1.25，见 resolveAppTextScale）下
    // "暂无可索引的消息"会在 124dp 宽的面板里折行到 42dp，连同上下各 16 的
    // padding 共需 74dp，被 52 压出 RenderFlex 溢出（实测溢出 22px）。
    // 空态没有列表、不需要可滚动余量，上限只需保证"不超出可用区"。
    await AiConversationStore.saveLastActiveId(_emptyScaleCaseId);
    await _pumpChatPage(tester, textScale: 1.25);
    final gesture = await _longPressRightEdge(tester);

    // 溢出会以 FlutterError 上报；不 take 就会让用例失败，这里显式断言更直白。
    expect(tester.takeException(), isNull, reason: '空态面板不应产生 RenderFlex 溢出');
    final panelRect = tester.getRect(find.bySemanticsLabel(RegExp('消息索引面板')));
    final textRect = tester.getRect(find.text('暂无可索引的消息'));
    expect(panelRect.height, greaterThanOrEqualTo(textRect.height + 32),
        reason: '空态面板高度应容得下文案与上下 padding');
    // 收紧的下边界仍然成立：空态也不得压到输入区。
    final listRect = tester.getRect(find.byType(ScrollablePositionedList));
    expect(panelRect.bottom, lessThanOrEqualTo(listRect.bottom),
        reason: '空态面板底边同样必须留在输入区上方');
    await gesture.cancel();
    await _settle(tester, frames: 8);
  });

  testWidgets('长按拖到某条松手，该条消息进入视口并关闭面板', (tester) async {
    await AiConversationStore.saveLastActiveId(_lpDragCaseId);
    await _pumpChatPage(tester);

    expect(find.textContaining('第 0 条消息'), findsNothing);
    final center = tester.getCenter(find.bySemanticsLabel('消息索引，长按打开'));

    final gesture = await tester.startGesture(center);
    for (var i = 0; i < 28; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      await tester.pump();
    }
    await _settle(tester, frames: 4);

    expect(find.bySemanticsLabel('消息索引面板'), findsOneWidget, reason: '长按应打开面板');

    // 17号计划步骤 1 之后：面板列表真的可滚动了，且打开时 _revealActiveEntry 会把
    // 高亮条目滚到面板视口中部（此前 maxScrollExtent 恒为 0，offset 永远是 0）。
    // _indexFromGlobalY 会把 offset 计进换算，所以"拖到面板上方 → clamp 到第一条"
    // 只在面板已滚到顶时成立。先显式滚到顶，把这个前提摆明，再断言原来的结论。
    await _scrollPanelToTop(tester);

    // 向上拖出足够距离，面板内容区顶端条目被选中（clamp 到最小 index）。
    final size = tester.view.physicalSize / tester.view.devicePixelRatio;
    await gesture.moveBy(Offset(0, -size.height));
    await _settle(tester, frames: 4);

    await gesture.up();
    await _settle(tester, frames: 12);

    expect(find.bySemanticsLabel('消息索引面板'), findsNothing, reason: '松手后面板应关闭');
    expect(find.textContaining('第 0 条消息'), findsOneWidget,
        reason: '向上拖到顶部松手应跳到最早的消息');
  });

  testWidgets('长按原地松手，跳转并关闭面板', (tester) async {
    await AiConversationStore.saveLastActiveId(_lpRelCaseId);
    await _pumpChatPage(tester);

    final center = tester.getCenter(find.bySemanticsLabel('消息索引，长按打开'));

    final gesture = await tester.startGesture(center);
    for (var i = 0; i < 28; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      await tester.pump();
    }
    await _settle(tester, frames: 4);

    expect(find.bySemanticsLabel('消息索引面板'), findsOneWidget);

    // 不移动，直接松手——onLongPressEnd 当场用松手坐标换算条目并跳转。
    await gesture.up();
    await _settle(tester, frames: 12);

    expect(find.bySemanticsLabel('消息索引面板'), findsNothing,
        reason: '原地松手后面板应关闭，不保持打开');
    expect(_topVisibleIndex(tester), greaterThanOrEqualTo(0),
        reason: '跳转后列表仍应有可见条目');
  });

  testWidgets('高亮一致性：拖到顶部时第一条高亮，松手后该条进入视口', (tester) async {
    await AiConversationStore.saveLastActiveId(_lpConsistCaseId);
    await _pumpChatPage(tester);

    expect(find.textContaining('第 0 条消息'), findsNothing,
        reason: '初始应在底部，第 0 条不可见');

    final center = tester.getCenter(find.bySemanticsLabel('消息索引，长按打开'));

    final gesture = await tester.startGesture(center);
    for (var i = 0; i < 28; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      await tester.pump();
    }
    await _settle(tester, frames: 4);

    expect(find.bySemanticsLabel('消息索引面板'), findsOneWidget, reason: '长按应打开面板');

    // 17号计划步骤 1 之后同上：面板已可滚动且打开时自动居中高亮条目，
    // 先把面板滚到顶，"拖到顶部 == 第一条"这个前提才成立。
    await _scrollPanelToTop(tester);

    // 向上拖出整屏，_indexFromGlobalY clamp 后锁定到第一条（index 0）。
    final size = tester.view.physicalSize / tester.view.devicePixelRatio;
    await gesture.moveBy(Offset(0, -size.height));
    await _settle(tester, frames: 4);

    // 松手：_dragHoverIndex=0 → _jumpToIndexEntry 跳到 index 0 → 面板关闭。
    await gesture.up();
    await _settle(tester, frames: 12);

    expect(find.bySemanticsLabel('消息索引面板'), findsNothing, reason: '松手后面板应关闭');
    // 高亮一致性证明：拖到顶部的 hover index = 0，松手跳转目标也是 0，
    // 因此"第 0 条消息"应进入视口。
    expect(find.textContaining('第 0 条消息'), findsOneWidget,
        reason: '拖选目标与跳转目标一致，第 0 条消息应进入视口');
  });

  // -----------------------------------------------------------------------
  // 17号计划步骤 3~7：拖选时的边缘自动滚动
  //
  // 每个用例开头都重申一次 maxScrollExtent > 0 的前置哨兵：面板不可滚动时
  // 自动滚动是空操作，offset 恒为 0，所有断言都会变成假绿。
  // -----------------------------------------------------------------------

  testWidgets('手指停在下缘区不动，面板列表持续向下滚动', (tester) async {
    await AiConversationStore.saveLastActiveId(_autoDownCaseId);
    await _pumpChatPage(tester);
    final gesture = await _longPressRightEdge(tester);

    final position = _panelScrollPosition(tester);
    expect(position.maxScrollExtent, greaterThan(0), reason: '前置：面板必须可滚动');
    final content = _panelContentRect(tester);
    final bar = tester.getCenter(find.bySemanticsLabel('消息索引，长按打开'));
    final startPixels = position.pixels;
    final visibleBefore = _visibleIndices(tester);

    // 停在下缘区靠边处（内容区 97% 高度处）后**不再移动手指**：
    // onLongPressMoveUpdate 从此不会再触发，后续滚动全靠 Ticker 自持续。
    await _moveFingerTo(
        tester, gesture, _armedFingerX(bar), _contentFracY(content, 0.97));
    final series = await _samplePanelPixels(tester, frames: 4);

    for (var i = 1; i < series.length; i++) {
      expect(series[i], greaterThanOrEqualTo(series[i - 1]),
          reason: '自动滚动只能单向推进，不得回弹：$series');
    }
    expect(series.last, greaterThan(startPixels),
        reason: '手指停在下缘区不动也必须持续滚动：$startPixels → $series');
    // 用户已拍板"主列表不实时跟随"：拖选期间只有面板在滚。
    expect(_visibleIndices(tester), visibleBefore, reason: '自动滚动期间主消息列表不得跟随滚动');

    await gesture.cancel();
    await _settle(tester, frames: 8);
  });

  testWidgets('手指停在上缘区不动，面板列表持续向上滚动', (tester) async {
    await AiConversationStore.saveLastActiveId(_autoUpCaseId);
    await _pumpChatPage(tester);
    final gesture = await _longPressRightEdge(tester);

    final position = _panelScrollPosition(tester);
    expect(position.maxScrollExtent, greaterThan(0), reason: '前置：面板必须可滚动');
    // 打开面板时 _revealActiveEntry 已把高亮条目滚到视口中部（会话停在底部，
    // 因此 pixels 远离 0），向上滚动有充足余量，不必先手动滚到底。
    final startPixels = position.pixels;
    expect(startPixels, greaterThan(0), reason: '前置：向上滚动需要有余量');

    final content = _panelContentRect(tester);
    final bar = tester.getCenter(find.bySemanticsLabel('消息索引，长按打开'));
    await _moveFingerTo(
        tester, gesture, _armedFingerX(bar), _contentFracY(content, 0.03));
    final series = await _samplePanelPixels(tester, frames: 4);

    for (var i = 1; i < series.length; i++) {
      expect(series[i], lessThanOrEqualTo(series[i - 1]),
          reason: '上缘区只能向上推进：$series');
    }
    expect(series.last, lessThan(startPixels),
        reason: '手指停在上缘区不动也必须持续向上滚动：$startPixels → $series');

    await gesture.cancel();
    await _settle(tester, frames: 8);
  });

  testWidgets('手指移回中间区，自动滚动立即停止', (tester) async {
    await AiConversationStore.saveLastActiveId(_autoMidCaseId);
    await _pumpChatPage(tester);
    final gesture = await _longPressRightEdge(tester);

    final position = _panelScrollPosition(tester);
    expect(position.maxScrollExtent, greaterThan(0), reason: '前置：面板必须可滚动');
    final content = _panelContentRect(tester);
    final bar = tester.getCenter(find.bySemanticsLabel('消息索引，长按打开'));

    // 先把面板滚回顶部：打开时 _revealActiveEntry 已把 offset 推到列表尾部附近，
    // _inputAreaReserve=265 让面板变矮后，距 maxScrollExtent 的余量只剩约 400px，
    // 下缘区满速滚几帧就可能撞底，让"停在中段"的断言变成偶发红。
    // 从顶部出发有整段余量，与"移回中间区即停"这个用例意图无关。
    await _scrollPanelToTop(tester);

    // 先在下缘区滚起来，确认真的在动。
    await _moveFingerTo(
        tester, gesture, _armedFingerX(bar), _contentFracY(content, 0.97));
    final moving = await _samplePanelPixels(tester, frames: 3);
    expect(moving.last, greaterThan(moving.first), reason: '前置：下缘区应已滚动');

    // 移回中间区（内容区 60% 处，在上下两条边缘区之间；横向已固定偏移
    // 两行高、恒超过起手抑制阈值，因此停止只能是"中间区速度为 0"的结果，
    // 不是起手抑制的结果）。
    await _moveFingerTo(
        tester, gesture, _armedFingerX(bar), _contentFracY(content, 0.60));
    final stopped = await _samplePanelPixels(tester, frames: 5);

    for (final pixels in stopped) {
      expect(pixels, stopped.first, reason: '移回中间区后应立刻停住，后续每帧都不再变化：$stopped');
    }
    // 证明"停住"不是撞到边界被 clamp 的假象。
    expect(stopped.first, greaterThan(position.minScrollExtent));
    expect(stopped.first, lessThan(position.maxScrollExtent),
        reason: '停在中段而非尽头，才能证明是中间区判定生效');

    await gesture.cancel();
    await _settle(tester, frames: 8);
  });

  testWidgets('松手后自动滚动停止，不留在后台继续跑', (tester) async {
    await AiConversationStore.saveLastActiveId(_autoReleaseCaseId);
    await _pumpChatPage(tester);
    final gesture = await _longPressRightEdge(tester);

    expect(_panelScrollPosition(tester).maxScrollExtent, greaterThan(0),
        reason: '前置：面板必须可滚动');
    final content = _panelContentRect(tester);
    final bar = tester.getCenter(find.bySemanticsLabel('消息索引，长按打开'));

    // 在上缘区滚一段，停在中段（不撞边界，"不再变化"才有意义）。
    await _moveFingerTo(
        tester, gesture, _armedFingerX(bar), _contentFracY(content, 0.03));
    final moving = await _samplePanelPixels(tester, frames: 3);
    expect(moving.last, lessThan(moving.first), reason: '前置：上缘区应已滚动');

    // 基准取「松手前那一刻」的 offset：这样即使淡出窗口里只采到一帧，
    // 该帧与基准相等也已经证明 Ticker 没再推进（若还在跑，第一帧就会不同）。
    // 不用"采到的帧彼此相等"当断言——那需要至少两帧，而淡出窗口只有 160ms
    // 墙上时间，能采到几帧取决于机器快慢，会变成偶发红。
    final baseline = _panelScrollPosition(tester).pixels;
    await gesture.up();
    // 面板要淡出 160ms，这段时间内 ListView 仍挂在树上、controller 仍有 client，
    // 正好可以观察"松手后还在不在滚"。用不带 delay 的 pump 尽量多采几帧。
    final afterRelease = <double>[];
    for (var i = 0; i < 8; i++) {
      await tester.pump();
      if (_panelListFinder().evaluate().isEmpty) break;
      afterRelease.add(_panelScrollPosition(tester).pixels);
    }
    expect(afterRelease, isNotEmpty, reason: '淡出窗口内至少应能采到一帧，否则这条断言等于没跑');
    for (final pixels in afterRelease) {
      expect(pixels, baseline, reason: '松手后面板不得继续滚动：$baseline → $afterRelease');
    }

    // 定时器泄漏哨兵：Ticker 只要还 active 就会不停 scheduleFrame，排帧排不空。
    expect(await _drainScheduledFrames(tester), isTrue,
        reason: '松手后排定帧应能排空（Ticker 未停会一直排帧）');
  });

  testWidgets('停在下缘区直到滚到头，停在 maxScrollExtent 不越界不抛异常', (tester) async {
    await AiConversationStore.saveLastActiveId(_autoEndCaseId);
    await _pumpChatPage(tester);
    final gesture = await _longPressRightEdge(tester);

    final position = _panelScrollPosition(tester);
    final maxExtent = position.maxScrollExtent;
    expect(maxExtent, greaterThan(0), reason: '前置：面板必须可滚动');
    final content = _panelContentRect(tester);
    final bar = tester.getCenter(find.bySemanticsLabel('消息索引，长按打开'));

    // 停到面板下边缘之外（满速），一直不松手，直到撞到底。
    await _moveFingerTo(
        tester, gesture, _armedFingerX(bar), content.bottom + 40);
    await _samplePanelPixels(tester, frames: 16);
    expect(position.pixels, maxExtent,
        reason: '应停在 maxScrollExtent，既不停在半路也不越界');

    // 到头后不停 Ticker（用户拍板"停住"语义，方向反转要能立即恢复），
    // 因此这里继续推帧，验证不越界、不抛断言。
    final held = await _samplePanelPixels(tester, frames: 6);
    for (final pixels in held) {
      expect(pixels, maxExtent, reason: '到头后应停住不动，不越界：$held');
    }
    expect(tester.takeException(), isNull, reason: '到头继续推进不得抛异常');

    await gesture.cancel();
    await _settle(tester, frames: 8);
  });

  testWidgets('自动滚动过程中拖选高亮随之变化，松手跳转与高亮一致', (tester) async {
    await AiConversationStore.saveLastActiveId(_autoHoverCaseId);
    await _pumpChatPage(tester);
    final gesture = await _longPressRightEdge(tester);

    expect(_panelScrollPosition(tester).maxScrollExtent, greaterThan(0),
        reason: '前置：面板必须可滚动');
    final content = _panelContentRect(tester);
    final bar = tester.getCenter(find.bySemanticsLabel('消息索引，长按打开'));

    await _moveFingerTo(
        tester, gesture, _armedFingerX(bar), _contentFracY(content, 0.03));
    final hoverAtStart = _dragHoverText(tester);
    expect(hoverAtStart, isNotNull, reason: '拖到上缘区后应有拖选高亮行');

    await _samplePanelPixels(tester, frames: 4);
    final hoverAfterScroll = _dragHoverText(tester);
    expect(hoverAfterScroll, isNotNull, reason: '自动滚动过程中仍应有拖选高亮行');
    // 手指一动不动，但面板在滚 → _indexFromGlobalY 里的 offset 变了 → 高亮必须跟着变。
    // 少了每 tick 的高亮重算就会"面板在滚、高亮卡住"，且松手跳错消息。
    expect(hoverAfterScroll, isNot(hoverAtStart),
        reason: '自动滚动改变了面板 offset，高亮行必须随之变化');

    await gesture.up();
    await _settle(tester, frames: 12);
    expect(find.bySemanticsLabel('消息索引面板'), findsNothing, reason: '松手后面板应关闭');
    // 高亮与跳转同源：松手瞬间高亮的那条，必须是跳转后进入视口的那条。
    expect(find.textContaining(hoverAfterScroll!), findsOneWidget,
        reason: '松手跳转目标应与松手瞬间的高亮行一致：$hoverAfterScroll');
  });

  testWidgets('滚动速度随深入程度递进：区边界附近慢、贴边快、中间区为 0', (tester) async {
    await AiConversationStore.saveLastActiveId(_autoSpeedCaseId);
    await _pumpChatPage(tester);
    final gesture = await _longPressRightEdge(tester);

    final position = _panelScrollPosition(tester);
    expect(position.maxScrollExtent, greaterThan(0), reason: '前置：面板必须可滚动');
    final content = _panelContentRect(tester);
    final bar = tester.getCenter(find.bySemanticsLabel('消息索引，长按打开'));

    // 先把面板滚回顶部：_revealActiveEntry 已把 offset 推近列表尾部，
    // _inputAreaReserve=265 让面板变矮后余量只剩约 400px，深处满速采样几帧
    // 就可能撞底，触发下面"不能撞到底"的护栏（偶发红）。从顶部出发，
    // 浅+深两段位移合计远小于全程余量，速度对比不受影响。
    await _scrollPanelToTop(tester);

    // 浅处：下缘区起点是 2/3 高度处，0.80 只深入约 40%（平方曲线 → 约 16% 速度）。
    final shallowStart = position.pixels;
    await _moveFingerTo(
        tester, gesture, _armedFingerX(bar), _contentFracY(content, 0.80));
    final shallow = await _samplePanelPixels(tester, frames: 3);
    final shallowDelta = shallow.last - shallowStart;
    expect(shallowDelta, greaterThan(0), reason: '浅处仍应滚动，只是慢：$shallow');

    // 深处：同样帧数，贴着面板底边（深入约 91% → 约 83% 速度）。
    final deepStart = _panelScrollPosition(tester).pixels;
    await _moveFingerTo(
        tester, gesture, _armedFingerX(bar), _contentFracY(content, 0.97));
    final deep = await _samplePanelPixels(tester, frames: 3);
    final deepDelta = deep.last - deepStart;
    expect(deep.last, lessThan(position.maxScrollExtent),
        reason: '本用例不能撞到底，否则深处位移被截断、比较失效');
    // 实测约 5 倍差（166 px/s vs 861 px/s）。这里只要求 2.5 倍，给帧长抖动留足余量
    // ——LiveTestWidgetsFlutterBinding 下每帧 dt 在 50~120ms 之间浮动。
    expect(deepDelta, greaterThan(shallowDelta * 2.5),
        reason: '越靠面板边缘越快：浅处 $shallowDelta / 深处 $deepDelta');

    await gesture.cancel();
    await _settle(tester, frames: 8);
  });

  testWidgets('手指越过面板边缘之外不无限加速，深入程度封顶', (tester) async {
    await AiConversationStore.saveLastActiveId(_autoCapCaseId);
    await _pumpChatPage(tester);
    final gesture = await _longPressRightEdge(tester);

    final position = _panelScrollPosition(tester);
    expect(position.maxScrollExtent, greaterThan(0), reason: '前置：面板必须可滚动');
    final content = _panelContentRect(tester);
    final bar = tester.getCenter(find.bySemanticsLabel('消息索引，长按打开'));
    final startPixels = position.pixels;

    // 把手指甩到面板上方极远处（相当于内容区高度的 4 倍）。若深入程度不封顶，
    // 速度会是满速的几十倍（深入 5 倍 → 平方后 25 倍），一帧之内就会把 offset
    // 推到 0；封顶后每帧最多 1040 px/s × 帧长，2 帧只走一两百像素。
    await _moveFingerTo(
      tester,
      gesture,
      _armedFingerX(bar),
      content.top - content.height * 4,
    );
    await _samplePanelPixels(tester, frames: 2);

    expect(position.pixels, lessThan(startPixels), reason: '越界之外应满速向上滚');
    expect(position.pixels, greaterThan(position.maxScrollExtent * 0.25),
        reason: '两帧之内不该冲到顶：越界越远越快说明深入程度没有封顶'
            '（起点 $startPixels，现在 ${position.pixels}）');

    await gesture.cancel();
    await _settle(tester, frames: 8);
  });

  testWidgets('内容不足一屏时不启动自动滚动，不空转', (tester) async {
    // 短会话：3 条可索引消息 → 面板 156 高、内容刚好装满 → maxScrollExtent == 0。
    // （原先用 4 条的混合会话，_inputAreaReserve 调到 265 后 60% 上限只剩约
    // 167，208 的内容高已产生 40.6 的滚动余量，前提失效，故换 3 条短会话。）
    await AiConversationStore.saveLastActiveId(_autoNoScrollCaseId);
    await _pumpChatPage(tester);
    final gesture = await _longPressRightEdge(tester);

    final position = _panelScrollPosition(tester);
    expect(position.maxScrollExtent, 0, reason: '前置：短会话面板不该有可滚动余量');
    final content = _panelContentRect(tester);
    final bar = tester.getCenter(find.bySemanticsLabel('消息索引，长按打开'));

    await _moveFingerTo(
        tester, gesture, _armedFingerX(bar), content.bottom + 40);
    final series = await _samplePanelPixels(tester, frames: 5);
    for (final pixels in series) {
      expect(pixels, 0, reason: '不可滚动时不该有任何位移：$series');
    }
    expect(tester.takeException(), isNull, reason: '不可滚动时不得抛异常');
    // "不空转"的直接证据：手指此刻**仍按在下缘区之外**，若 Ticker 被启动了它会
    // 无止境地 scheduleFrame，排帧永远排不空。这条必须放在 cancel 之前——
    // cancel 本身会停 Ticker，放在它之后无论有没有守卫都是绿的。
    expect(await _drainScheduledFrames(tester), isTrue,
        reason: 'maxScrollExtent==0 时不应启动 Ticker 空转（手指仍停在下缘区外）');

    await gesture.cancel();
    await _settle(tester, frames: 8);
  });

  testWidgets('自动滚动中销毁页面不抛异常，Ticker 随 dispose 回收', (tester) async {
    await AiConversationStore.saveLastActiveId(_autoDisposeCaseId);
    await _pumpChatPage(tester);
    final gesture = await _longPressRightEdge(tester);

    expect(_panelScrollPosition(tester).maxScrollExtent, greaterThan(0),
        reason: '前置：面板必须可滚动');
    final content = _panelContentRect(tester);
    final bar = tester.getCenter(find.bySemanticsLabel('消息索引，长按打开'));
    await _moveFingerTo(
        tester, gesture, _armedFingerX(bar), _contentFracY(content, 0.97));
    final moving = await _samplePanelPixels(tester, frames: 3);
    expect(moving.last, greaterThan(moving.first), reason: '前置：应已在自动滚动');

    // Ticker 还在跑就把整页换掉（等价于切 tab / 退出路由 → State.dispose）。
    // dispose 里若忘了停 Ticker，SingleTickerProviderStateMixin 会抛
    // "was disposed with an active Ticker"；若忘了 Ticker.dispose 则会泄漏。
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await _settle(tester, frames: 8);
    expect(tester.takeException(), isNull,
        reason: '自动滚动中销毁页面不得抛异常（dispose 必须先停 Ticker 再回收）');
    expect(find.byType(ScrollablePositionedList), findsNothing);
    expect(await _drainScheduledFrames(tester), isTrue,
        reason: '页面销毁后不应还有 Ticker 在排帧');
    await gesture.cancel();
  });
}

const _mixedId = 'index-panel-mixed';
const _mixedTitle = '索引面板用例-混合消息';
const _jumpCaseId = 'index-panel-jump';
const _jumpCaseTitle = '索引面板用例-点击跳转';
const _highlightCaseId = 'index-panel-highlight';
const _highlightCaseTitle = '索引面板用例-高亮';
const _dragCaseId = 'index-panel-drag';
const _dragCaseTitle = '索引面板用例-边缘拖动';
const _rehighlightCaseId = 'index-panel-rehighlight';
const _rehighlightCaseTitle = '索引面板用例-跳转后高亮';
// 16号计划：拖选手势用例
const _lpDragCaseId = 'index-panel-lp-drag-a';
const _lpDragCaseTitle = '索引面板用例-长按拖选松手跳转';
const _lpRelCaseId = 'index-panel-lp-rel-b';
const _lpRelCaseTitle = '索引面板用例-长按原地松手跳转';
const _lpConsistCaseId = 'index-panel-lp-consist-c';
const _lpConsistCaseTitle = '索引面板用例-高亮一致性';
// 17号计划：面板高度约束哨兵用例
const _extentCaseId = 'index-panel-extent-d';
const _extentCaseTitle = '索引面板用例-高度约束哨兵';
// _inputAreaReserve=265 适配：3 条消息的短会话（内容高 156 < 60% 上限约 167）
const _shortCaseId = 'index-panel-short-y';
const _shortCaseTitle = '索引面板用例-短会话收缩';
// 17号计划步骤 11/12：过滤开关与迷你索引条用例（各自独立会话 id）
const _userOnlyCaseId = 'index-panel-useronly-e';
const _userOnlyCaseTitle = '索引面板用例-默认仅用户消息';
const _toggleCaseId = 'index-panel-toggle-f';
const _toggleCaseTitle = '索引面板用例-切换过滤开关';
const _barCaseId = 'index-panel-bar-g';
const _barCaseTitle = '索引面板用例-迷你索引条';
const _barLimitCaseId = 'index-panel-bar-limit-h';
const _barLimitCaseTitle = '索引面板用例-刻度上限';
const _barActiveCaseId = 'index-panel-bar-active-i';
const _barActiveCaseTitle = '索引面板用例-当前线三维强化';
const _barScrollCaseId = 'index-panel-bar-scroll-j';
const _barScrollCaseTitle = '索引面板用例-加深位置跟随滚动';
const _barUserSrcCaseId = 'index-panel-bar-usersrc-k';
const _barUserSrcCaseTitle = '索引面板用例-索引条只数用户消息';
const _barEmptyCaseId = 'index-panel-bar-empty-l';
const _barEmptyCaseTitle = '索引面板用例-无用户消息';
// 第 1 轮校验补：空态 + 特大字号的高度上限回归用例
const _emptyScaleCaseId = 'index-panel-empty-scale-w';
const _emptyScaleCaseTitle = '索引面板用例-空态特大字号';
const _barFitCaseId = 'index-panel-bar-fit-x';
const _barFitCaseTitle = '索引面板用例-不限制且超长会话';
// 17号计划步骤 8：边缘自动滚动用例（各自独立会话 id）
const _autoDownCaseId = 'index-panel-auto-down-m';
const _autoDownCaseTitle = '索引面板用例-下缘自动滚动';
const _autoUpCaseId = 'index-panel-auto-up-n';
const _autoUpCaseTitle = '索引面板用例-上缘自动滚动';
const _autoMidCaseId = 'index-panel-auto-mid-o';
const _autoMidCaseTitle = '索引面板用例-移回中间区停止';
const _autoReleaseCaseId = 'index-panel-auto-release-p';
const _autoReleaseCaseTitle = '索引面板用例-松手停止';
const _autoEndCaseId = 'index-panel-auto-end-q';
const _autoEndCaseTitle = '索引面板用例-滚到头停住';
const _autoHoverCaseId = 'index-panel-auto-hover-r';
const _autoHoverCaseTitle = '索引面板用例-自动滚动中高亮跟随';
const _autoSpeedCaseId = 'index-panel-auto-speed-s';
const _autoSpeedCaseTitle = '索引面板用例-速度随深入递进';
const _autoCapCaseId = 'index-panel-auto-cap-t';
const _autoCapCaseTitle = '索引面板用例-越界不无限加速';
const _autoNoScrollCaseId = 'index-panel-auto-noscroll-u';
const _autoNoScrollCaseTitle = '索引面板用例-内容不足一屏不启动';
const _autoDisposeCaseId = 'index-panel-auto-dispose-v';
const _autoDisposeCaseTitle = '索引面板用例-滚动中销毁页面';

Future<void> _seedMixedConversation() async {
  await AiConversationStore.save(
    id: _mixedId,
    title: _mixedTitle,
    createdAt: DateTime.now(),
    displayMessages: [
      AiChatMessage.user('问题一：帮我找点东西'),
      AiChatMessage.assistant('回答一：好的，我来搜索。'),
      AiChatMessage.toolCall(toolName: 'search_comic', toolArgs: const {}),
      AiChatMessage.toolResult(toolName: 'search_comic', ok: true),
      AiChatMessage.user('问题二：换个关键词'),
      AiChatMessage.assistant('回答二：已换关键词重试。'),
    ],
    history: const [],
  );
}

/// 与 [_seedMixedConversation] 同样的消息构成，但落到指定会话 id。
/// 阅读位置记忆是 static 的，用例之间必须换 id。
Future<void> _seedMixedAs(String id, String title) async {
  await AiConversationStore.save(
    id: id,
    title: title,
    createdAt: DateTime.now(),
    displayMessages: [
      AiChatMessage.user('问题一：帮我找点东西'),
      AiChatMessage.assistant('回答一：好的，我来搜索。'),
      AiChatMessage.toolCall(toolName: 'search_comic', toolArgs: const {}),
      AiChatMessage.toolResult(toolName: 'search_comic', ok: true),
      AiChatMessage.user('问题二：换个关键词'),
      AiChatMessage.assistant('回答二：已换关键词重试。'),
    ],
    history: const [],
  );
}

/// 全 assistant 会话：用于验证"没有用户消息时迷你索引条不画横线也不崩"。
Future<void> _seedAssistantOnlyConversation(String id, String title) async {
  await AiConversationStore.save(
    id: id,
    title: title,
    createdAt: DateTime.now(),
    displayMessages: [
      AiChatMessage.assistant('只有 AI 回复，没有用户消息。'),
      AiChatMessage.assistant('第二条 AI 回复。'),
    ],
    history: const [],
  );
}

Future<void> _seedLongConversation(
  String id,
  String title, {
  int messageCount = 30,
}) async {
  await AiConversationStore.save(
    id: id,
    title: title,
    createdAt: DateTime.now(),
    // 17号计划步骤 11：索引默认只收 user，长会话改用 user 消息填充。
    // 这些用例考的是"长会话下的索引/滚动/拖选"，与消息类型无关，
    // 换成 user 后既保留原有全部断言（index 口径 1:1 未变），
    // 又顺带让默认设置下的路径被真正覆盖。同时它也是迷你索引条的数据源。
    displayMessages: List<AiChatMessage>.generate(
      messageCount,
      (index) => AiChatMessage.user('第 $index 条消息，用于撑开列表高度。'),
    ),
    history: const [],
  );
}

/// 短会话：3 条 user 消息（3×52=156），用于"面板按内容收缩/不可滚动"用例。
///
/// _inputAreaReserve 被用户在真机上手调到 265 后，测试视口（800×600、无安全区）
/// 里的面板 60% 上限只剩 (600-56-265)×0.6≈167：原先充当"短会话"的混合会话有
/// 4 条可索引消息（208），已经超上限、会产生可滚动余量。3 条仍在上限内，
/// 让 maxScrollExtent==0 的前提重新成立。
Future<void> _seedShortConversation(String id, String title) async {
  await AiConversationStore.save(
    id: id,
    title: title,
    createdAt: DateTime.now(),
    displayMessages: List<AiChatMessage>.generate(
      3,
      (index) => AiChatMessage.user('短会话第 $index 条消息。'),
    ),
    history: const [],
  );
}

/// [textScale] 非空时按 main.dart 的做法固定字号（withClampedTextScaling），
/// 用于验证大字号下的布局约束；为空则沿用测试默认的 1.0。
Future<void> _pumpChatPage(WidgetTester tester, {double? textScale}) async {
  await tester.pumpWidget(MaterialApp(
    builder: textScale == null
        ? null
        : (context, child) => MediaQuery.withClampedTextScaling(
              minScaleFactor: textScale,
              maxScaleFactor: textScale,
              child: child!,
            ),
    home: const AiChatPage(),
  ));
  await _settle(tester, frames: 12);
  expect(find.byType(ScrollablePositionedList), findsOneWidget,
      reason: '会话应加载完成并渲染出消息列表');
}

/// 有界推帧：controller 加载期间有无限动画的 CircularProgressIndicator，
/// pumpAndSettle 永不返回。
Future<void> _settle(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
    await tester.pump();
  }
}

/// 在右边缘触发条内长按，使面板打开并保持开着（手指仍按住）。
///
/// 触发条改用 onLongPressStart 后，tester.longPressAt 无法触发它；
/// 必须 startGesture + pump(500ms) 才能触发 onLongPressStart → 面板打开。
///
/// 返回 TestGesture，手势仍处于按住状态，面板此时可见。
/// 调用方在测试结束前必须调 `await gesture.cancel()` 清理（cancel 只关面板，不跳转）。
Future<TestGesture> _longPressRightEdge(WidgetTester tester) async {
  // 通过 Semantics label 取触发条的实际中心坐标，避免猜测坐标偏离。
  final center = tester.getCenter(find.bySemanticsLabel('消息索引，长按打开'));
  final gesture = await tester.startGesture(center);
  // LiveTestWidgetsFlutterBinding 里定时器走真实时间；
  // 必须用 Future.delayed + pump 循环（与 _settle 相同模式）来推进真实时钟，
  // 才能可靠触发 GestureRecognizer 的 kLongPressTimeout(500ms) → onLongPressStart。
  // 28 帧 × 25ms = 700ms > 500ms。
  for (var i = 0; i < 28; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
    await tester.pump();
  }
  await _settle(tester, frames: 4);
  // 面板已打开，手势保持按住。调用方必须最终调 gesture.cancel()（不跳转）。
  return gesture;
}

/// 把面板内部列表滚到顶部。面板 ListView 用 itemExtent 定高只构建可见行，
/// 要断言/点击靠前的条目必须先把它滚进面板视口。
Future<void> _scrollPanelToTop(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.drag(_panelListFinder().first, const Offset(0, 600));
    await _settle(tester, frames: 4);
  }
}

Future<void> _scrollPanelToBottom(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.drag(_panelListFinder().first, const Offset(0, -600));
    await _settle(tester, frames: 4);
  }
}

ScrollablePositionedList _messageList(WidgetTester tester) =>
    tester.widget<ScrollablePositionedList>(
      find.byType(ScrollablePositionedList),
    );

Set<int> _visibleIndices(WidgetTester tester) => _messageList(tester)
    .itemPositionsNotifier!
    .itemPositions
    .value
    .map((p) => p.index)
    .toSet();

int _topVisibleIndex(WidgetTester tester) {
  final indices = _visibleIndices(tester);
  expect(indices, isNotEmpty, reason: 'itemPositions 应已上报可见项');
  return indices.reduce((a, b) => a < b ? a : b);
}

/// 面板内部的 ListView（消息列表是 ScrollablePositionedList，不会被误命中；
/// 侧栏 ListView 只有抽屉打开时才在树里）。
Finder _panelListFinder() => find.descendant(
      of: find.byType(Material),
      matching: find.byType(ListView),
    );

/// 面板内部列表的 ScrollPosition。_panelScrollController 是 _AiChatPageState 的
/// 私有字段，测试拿不到，只能从面板 ListView 内的 Scrollable 反查。
ScrollPosition _panelScrollPosition(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(
        of: _panelListFinder().first,
        matching: find.byType(Scrollable),
      ),
    )
    .position;

int _panelRowCount(WidgetTester tester) {
  final list = tester.widget<ListView>(_panelListFinder().first);
  return list.semanticChildCount ?? 0;
}

/// 面板里包含指定文本的条目。面板条目预览是折叠空白后的前 30 字，
/// 用 textContaining 匹配即可；限定在面板 ListView 内，避免命中气泡正文。
Finder _panelTextFinder(WidgetTester tester, String text) => find.descendant(
      of: _panelListFinder().first,
      matching: find.textContaining(text),
    );

// ---------------------------------------------------------------------------
// 17号计划步骤 12：迷你索引条读数helper
//
// _MiniIndexBar 是私有类，测试拿不到；但它的横线是触发条 Semantics 子树里唯一的
// AnimatedContainer，按类型 + 祖先限定即可稳定命中，且顺序与 Column 里一致。
// ---------------------------------------------------------------------------

Finder _tickFinder() => find.descendant(
      of: find.bySemanticsLabel('消息索引，长按打开'),
      matching: find.byType(AnimatedContainer),
    );

int _tickCount(WidgetTester tester) => _tickFinder().evaluate().length;

List<AnimatedContainer> _tickWidgets(WidgetTester tester) =>
    _tickFinder().evaluate().map((e) => e.widget as AnimatedContainer).toList();

/// AnimatedContainer 把 width/height 折进 constraints，取回目标值。
double _tickWidth(AnimatedContainer tick) => tick.constraints!.maxWidth;

double _tickHeight(AnimatedContainer tick) => tick.constraints!.maxHeight;

Color? _tickColor(AnimatedContainer tick) =>
    (tick.decoration as BoxDecoration?)?.color;

Rect _tickRect(WidgetTester tester, int index) =>
    tester.getRect(_tickFinder().at(index));

/// 当前加深的是第几根：厚度最大的那根（三个维度同时强化，取任一即可定位）。
int _activeTickIndex(WidgetTester tester) {
  final ticks = _tickWidgets(tester);
  expect(ticks, isNotEmpty, reason: '应已画出迷你索引条');
  var best = 0;
  for (var i = 1; i < ticks.length; i++) {
    if (_tickHeight(ticks[i]) > _tickHeight(ticks[best])) best = i;
  }
  return best;
}

// ---------------------------------------------------------------------------
// 17号计划步骤 8：边缘自动滚动读数 helper
//
// 断言口径一律用 getRect 现算的相对位置：测试视口 800×600 与手机竖屏比例差很多，
// 写死坐标一改布局就废。边缘区宽度 = min(内容区高度/3, 96)，与实现同一算法；
// 下面用「内容区高度的分数位置」表达手指落点，0=内容区顶端、1=底端、
// 超出 [0,1] 表示手指已跑到面板之外。
// ---------------------------------------------------------------------------

/// 面板内容区矩形（即 _panelContentKey 指向的那个 RenderBox 的范围）。
/// 实测它与面板整体 rect 完全重合（面板里只有这一个 ListView，无标题栏/内边距）。
Rect _panelContentRect(WidgetTester tester) =>
    tester.getRect(_panelListFinder().first);

/// 把「内容区高度分数」换成全局 Y。
double _contentFracY(Rect content, double frac) =>
    content.top + content.height * frac;

/// 拖选自动滚动用例统一的手指横向落点：从触发条中心向屏幕内侧偏移两行高（104）。
///
/// 边缘区判定与 index 换算都只看 globalY（实现里 _panelLocalGeometry /
/// _indexFromGlobalY 只用 dy），横向分量不改变任何用例语义；它的唯一作用是让
/// 「手指-长按起点」的直线距离恒大于起手抑制阈值 _edgeScrollArmDistance
/// （一行高 52，偏移取 2 倍留余量）。_inputAreaReserve 被手调到 265 后面板
/// 变矮、整体上移，面板内的竖向目标点可能落进长按起点 52px 半径内，纯竖向
/// 移动会被起手抑制拦住（这是设计内行为，不是 bug）；固定横向偏移后，
/// 「是否触发自动滚动」只由竖向落点所在的边缘区决定，不再受面板几何变化影响。
double _armedFingerX(Offset barCenter) => barCenter.dx - 104;

/// 把手指移到内容区的指定分数位置，并推一帧让 onLongPressMoveUpdate 落地。
Future<void> _moveFingerTo(
  WidgetTester tester,
  TestGesture gesture,
  double x,
  double y,
) async {
  await gesture.moveTo(Offset(x, y));
  await tester.pump();
}

/// 连续采样面板滚动位置：每帧「真实等待 25ms + pump」，与 _settle 同一节奏。
///
/// 注意：LiveTestWidgetsFlutterBinding 下 Ticker 的 elapsed 走真实墙上时钟，
/// 实测每帧 dt 在 50~120ms 之间浮动（不是固定 33.3ms），因此**只能断言单调/阈值**，
/// 不能断言精确增量。
Future<List<double>> _samplePanelPixels(
  WidgetTester tester, {
  required int frames,
}) async {
  final out = <double>[];
  for (var i = 0; i < frames; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
    await tester.pump();
    out.add(_panelScrollPosition(tester).pixels);
  }
  return out;
}

/// 推帧直到没有任何排定帧，返回是否成功排空。
///
/// 这是"Ticker 有没有在空转"的唯一可观测信号：Ticker 每 tick 都会 scheduleFrame，
/// 只要它还 active，这个循环就永远等不到 false；而普通过渡动画（面板淡出 160ms、
/// 索引条 140ms）几帧内就会自己结束。
///
/// **不要直接断言 `hasScheduledFrame == false`**：它是全局 binding 状态，单跑用例
/// 时是干净的，整文件连跑时会被上一个用例遗留的动画/延时污染，变成偶发红
/// （本文件最初就踩了这个坑：单跑绿、连跑红）。
Future<bool> _drainScheduledFrames(WidgetTester tester,
    {int budget = 24}) async {
  for (var i = 0; i < budget; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
    await tester.pump();
    if (!WidgetsBinding.instance.hasScheduledFrame) return true;
  }
  return false;
}

/// 当前被拖选高亮那一行的预览文本（null=没有拖选高亮行）。
///
/// 拖选高亮行的 Material 背景是 primary alpha 0.28，可见高亮是 0.14，
/// 靠这个透明度区分两者。用于验证「自动滚动时高亮跟着变」。
String? _dragHoverText(WidgetTester tester) {
  final list = _panelListFinder().first;
  final hoverColor = Theme.of(tester.element(list))
      .colorScheme
      .primary
      .withValues(alpha: 0.28);
  for (final element in find
      .descendant(of: list, matching: find.byType(Material))
      .evaluate()) {
    final material = element.widget as Material;
    if (material.color != hoverColor) continue;
    final texts = find
        .descendant(of: find.byWidget(material), matching: find.byType(Text))
        .evaluate();
    if (texts.isEmpty) return null;
    return (texts.first.widget as Text).data;
  }
  return null;
}

/// 条目是否高亮：高亮行的 Material 背景色是 primary 的半透明叠色，
/// 非高亮行是 transparent。
bool _isRowHighlighted(WidgetTester tester, String text) {
  final textFinder = _panelTextFinder(tester, text);
  expect(textFinder, findsOneWidget, reason: '面板里应有包含"$text"的条目');
  final material = tester.widget<Material>(
    find.ancestor(of: textFinder, matching: find.byType(Material)).first,
  );
  final color = material.color;
  return color != null && color != Colors.transparent && color.a > 0;
}

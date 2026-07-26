import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
// 17号计划步骤 6：Ticker 本体在 scheduler 里，material.dart 只导出
// TickerProvider/SingleTickerProviderStateMixin，不带 Ticker 类本身。
import 'package:flutter/scheduler.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:photo_view/photo_view.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/components/scrollable_list/scrollable_positioned_list.dart';
import 'package:picakeep/foundation/ai/ai_attachments.dart';
import 'package:picakeep/foundation/ai/ai_conversation.dart';
import 'package:picakeep/foundation/ai/balance_client.dart';
import 'package:picakeep/foundation/ai/ai_conversation_store.dart';
import 'package:picakeep/foundation/ai/ai_download_queue.dart';
import 'package:picakeep/foundation/ai/ai_prompt_tags.dart';
import 'package:picakeep/foundation/ai/ai_result_item.dart';
import 'package:picakeep/foundation/ai/ai_settings.dart';
import 'package:picakeep/foundation/ai/ai_sources.dart';
import 'package:picakeep/foundation/app_page_route.dart';
import 'package:picakeep/pages/ai/ai_download_list_page.dart';
import 'package:picakeep/pages/ai/ai_item_list_page.dart';
import 'package:picakeep/pages/online_comic/eh_comic_page_v2.dart';
import 'package:picakeep/pages/online_comic/jm_comic_page_v2.dart';
import 'package:picakeep/pages/online_comic/nhentai_comic_page_v2.dart';
import 'package:picakeep/pages/online_comic/picacg_comic_page_v2.dart';
import 'package:picakeep/tools/translations.dart';

const _promptTagBoundaryPattern = r'''[\s#，。；、,.!?;！：:（）()\[\]{}<>《》“”"'`~～]''';

/// 15轮03号计划：把新选图合并进待发附件列表（去重、上限 4 张/条，限制单请求
/// base64 体积：4×1.5MB≈8MB）。返回 true 表示有图因超限被丢弃（调用方据此
/// 提示）。抽成纯函数以便自动化验收（验收标准 11 的「待发行最多 4 张」）。
@visibleForTesting
bool mergePendingAiAttachmentSelection(
  List<String> pending,
  Iterable<String> picked,
) {
  var overflow = false;
  for (final path in picked) {
    if (pending.length >= 4) {
      overflow = true;
      break;
    }
    if (!pending.contains(path)) pending.add(path);
  }
  return overflow;
}

class AiChatPage extends StatefulWidget {
  const AiChatPage({super.key});

  @override
  State<AiChatPage> createState() => _AiChatPageState();
}

class _AiChatPageState extends State<AiChatPage>
    with AutomaticKeepAliveClientMixin, SingleTickerProviderStateMixin {
  // 按会话 id 缓存的输入草稿。AiConversationController.create() 每次都是
  // 全新实例（从磁盘反序列化的静态工厂，无全局单例/注册表复用），
  // 草稿不能挂在 controller 上，只能挂在 State 的类级 static 字段上。
  static final Map<String, String> _draftsByConversationId = {};

  // 12号计划：按会话 id 缓存阅读位置。
  // 与 _draftsByConversationId 同一层级，用 static 保证跨 State 重建存活。
  // 13号计划：语义扩展——deactivate()（切 tab）也写入位置，_loadController() 也读取恢复，
  // 切 tab 回来与页内切会话走同一条"有记忆位置就恢复，无则到底部"路径。
  // 15号计划：值语义从"像素 offset"改为"item index"（消息列表换成
  // ScrollablePositionedList 后按 index 定位才是原生语义，像素 offset 在
  // anchor 视口里是相对当前 positionedIndex 的相对值，跨帧不可复用）。
  // 该表只存在内存里、从不落盘（AiConversationStore 里没有任何滚动位置字段），
  // 因此不存在需要迁移的历史数据；旧 double 值只可能来自开发期热重载，
  // 由 _sanitizeSavedIndex() 统一容错。
  static final Map<String, int> _scrollIndexByConversationId = {};

  @override
  bool get wantKeepAlive => true;

  AiConversationController? _controller;
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  late final TextEditingController _inputController;
  late final ScrollController _scrollController;

  // 15号计划：消息列表改用 ScrollablePositionedList。
  // _itemScrollController 负责按 index 跳转（恢复阅读位置、后续索引面板点击跳转），
  // _itemPositionsListener 负责读当前可见 index 区间（保存阅读位置、后续面板高亮）。
  // 注意：fork 版 ScrollablePositionedList 的 scrollController 是必填参数，
  // 仍然复用 _scrollController，"贴底/距底 200dp"这类像素判定继续走它。
  final ItemScrollController _itemScrollController = ItemScrollController();
  final ItemPositionsListener _itemPositionsListener =
      ItemPositionsListener.create();

  /// 当前列表渲染项（build 时重算并暂存，供 pending 落位与后续索引面板复用）。
  /// 不是状态、只是"上一帧渲染快照"，写入不触发 setState。
  List<_DisplayItem> _displayItems = const [];

  /// 列表真实 itemCount：_displayItems.length + 下载确认卡（若有）。
  /// index 语义的所有 clamp 都以它为准，不能用 _displayItems.length。
  int _listItemCount = 0;

  /// 首帧锚点：State 全新创建（切 tab 回来）时由 ScrollablePositionedList 的
  /// initialScrollIndex 直接生效，省掉一次可见的重定位。
  int _initialScrollIndex = 0;

  // 15号计划 Feature 2：消息索引面板。
  // 面板只在长按右边缘后出现，因此条目列表按需构建（_buildIndexEntries），
  // 并用 _cachedIndexEntries + _cachedIndexEntriesKey 做同版本复用——
  // 流式输出期间 _onControllerUpdate 每个 token 都 setState，逐帧重算整表会掉帧。
  bool _indexPanelVisible = false;
  List<_IndexEntry> _cachedIndexEntries = const [];
  String? _cachedIndexEntriesKey;

  /// 17号计划步骤 12：迷你索引条的数据源缓存（用户消息在 _displayItems 里的下标）。
  /// 迷你索引条常驻显示且随滚动重建，必须缓存，详见 _userMessageIndices。
  List<int> _cachedUserIndices = const [];
  String? _cachedUserIndicesKey;

  /// 面板高亮用的当前可见 index 集合。仅在面板可见期间由
  /// _itemPositionsListener 的监听维护（关闭即摘监听，避免高频 setState）。
  Set<int> _visibleIndices = const {};

  // 16号计划：拖选跳转新增字段。
  // _dragHoverIndex：拖动过程中悬停在哪条索引条目上（null=不在拖选中）；
  // _longPressStartGlobal：长按起始点全局坐标，用于把面板顶端对齐到手指位置；
  // _panelContentKey：指向面板内部列表容器的 RenderBox，供坐标换算用；
  // _panelScrollController：面板内部列表滚动控制器，提升到父 State
  //   便于 _indexFromGlobalY 计入滚动偏移，保证拖选高亮与松手跳转完全一致。
  int? _dragHoverIndex;
  Offset? _longPressStartGlobal;
  final GlobalKey _panelContentKey = GlobalKey();
  final ScrollController _panelScrollController = ScrollController();

  /// 17号计划步骤 3：拖选期间最后一次已知的手指全局坐标。
  ///
  /// 与 _longPressStartGlobal 严格分开：后者是**起点**，被面板 top 定位读取
  /// （longPressStartY），覆写它会让面板在拖动过程中跟着手指乱跳。
  /// 边缘自动滚动每 tick 都要用"当前"手指位置重算高亮，所以必须另存一份。
  Offset? _dragCurrentGlobal;

  /// 17号计划步骤 6：边缘自动滚动的 Ticker 与当前速度（px/s，正=向下）。
  ///
  /// 选 Ticker 而不是 Timer.periodic：Ticker 与帧同步（每帧最多推进一次，
  /// 不会在一帧内累计多次 jumpTo），elapsed 单调可差分，且随 State 生命周期回收。
  /// SingleTickerProviderStateMixin 只允许 createTicker 一次，因此这里懒建一次后
  /// 反复 start/stop 复用，不重建。
  Ticker? _edgeScrollTicker;
  double _edgeScrollSpeed = 0;

  /// 上一次 tick 的 elapsed，用于差分出真实 dt（不假设固定帧长）。
  /// 每次 start 后第一次 tick 只用来立基准，不推进滚动。
  Duration? _lastEdgeTickElapsed;

  final LayerLink _promptPanelLink = LayerLink();
  final GlobalKey _promptTagButtonKey = GlobalKey();
  final GlobalKey _pendingTagRowKey = GlobalKey();
  OverlayEntry? _promptPanelEntry;
  bool _resetSourceRestriction = false;

  // 12号计划（方案三）：懒加载列表的 maxScrollExtent 是随 item 逐帧
  // 构建才增长的估算值，单次 postFrame 的 jumpTo 常常落在"当时的假底部"。
  // 用一个 pending 标志把"该滚到哪"记下来，postFrame 与 _onControllerUpdate
  // 都去调 _applyPendingScroll()，落位成功即清标志（否则用户手动往上翻历史
  // 会被后续 controller 更新强制弹回）。
  // 15号计划：贴底仍是像素目标（maxScrollExtent 才是真底部，逐帧收敛照旧），
  // 恢复历史位置改成 index 目标（一次 jumpTo 即精确落位，无需收敛）。
  bool _pendingScrollToBottom = false;
  int? _pendingScrollIndex;
  int _pendingScrollFrames = 0;
  int _pendingScrollWaitFrames = 0;
  double? _lastPendingScrollExtent;
  // Finding 2 修复：防止 postFrame 重复注册——_onControllerUpdate 调
  // _schedulePendingScroll 时若已有一帧在途，不再二次注册，避免同一帧内两次
  // _applyPendingScroll 导致 _pendingScrollFrames/extentSettled 误计。
  bool _pendingScrollScheduled = false;

  /// pending 滚动最多连续重试的帧数（约 8 帧 ≈ 130ms）。有界重试保证标志不会
  /// 无限存活——否则一旦目标 offset 永远追不上（如会话被清空），用户之后的每次
  /// 手动滚动都会被弹回。
  static const int _maxPendingScrollFrames = 8;

  /// Finding 1 修复：_scrollIndexByConversationId 里存此哨兵表示"离开时贴底"。
  /// 恢复时走 _scrollToBottomAfterFrame()，跟到最新底部，不受后台新消息影响。
  /// 15号计划：index 语义下 -1 天然不是合法 index，沿用同一个哨兵值。
  static const int _atBottomSentinel = -1;

  // 结构化选中态：面板 chip 点选后写入这些集合，不再写入 _inputController 文本。
  // 发送时与 _inputController 文本的正则识别结果合并，手动在输入框里打 #标签名 仍有效。
  final Set<String> _selectedTagChips = {}; // 普通标签名，不含 #
  final Set<String> _selectedSourceChips =
      {}; // source 值（picacg/jm/ehentai/nhentai）
  bool _selectedLocalOnly = false;

  /// 15轮05号计划：面板 `#搜图` chip 的选中态（对本次发送的图片执行以图搜源）。
  /// 只作用于当轮，不参与长期持久化（步骤 7-b），故无对应长期区 chip。
  bool _selectedSearchByImage = false;

  /// 15轮03号计划：待发送的图片附件（用户所选源文件的**绝对路径**，未压缩未落盘；
  /// 压缩落盘发生在 _send() 内）。附件草稿不跨会话、不跨重启（见计划「不执行的内容」）。
  final List<String> _pendingAttachments = [];

  /// 15轮03号计划：_send() 在 isLoading 置位前有一段 await 窗口（标签初始化、
  /// 压缩落盘），期间用户可能再点发送/回车造成重复发送；该标志覆盖整个 _send()
  /// 生命周期，发送与选图按钮据此禁用（计划「风险」项的二选一，选了禁用方案）。
  bool _sendInFlight = false;

  final AiPromptTagSettingsController _promptTagSettings =
      AiPromptTagSettingsController.instance;

  static const Map<String, String> _sourceByTagName = aiPromptSourceTagToSource;

  @override
  void initState() {
    super.initState();
    _inputController = TextEditingController();
    _scrollController = ScrollController();
    _promptTagSettings.addListener(_onPromptTagSettingsUpdate);
    _promptTagSettings.initialize();
    _loadController();
  }

  Future<void> _loadController() async {
    final lastId = await AiConversationStore.loadLastActiveId();
    final ctrl = await AiConversationRegistry.instance.getOrCreate(lastId);
    if (mounted) {
      // Fix B（13号计划）：先置 pending（Opacity=0 遮住首帧），再 setState 触发渲染，
      // 防止列表在第一帧渲染出旧位置/顶部后才 jumpTo，产生可见跳帧。
      // Fix C（13号计划）：改为 _restoreScrollOffsetAfterFrame——有记忆位置就恢复，
      // 无记忆（新会话/首次）则到底部。切 tab 回来也走此路径（dispose() 已保存）。
      _restoreScrollOffsetAfterFrame(ctrl);
      setState(() => _controller = ctrl);
      _controller!.addListener(_onControllerUpdate);
      _restoreDraft(ctrl);
    }
  }

  Future<void> _switchConversation(AiConversationMeta meta) async {
    _clearPromptPanelState();
    // 15轮03号计划：附件不跨会话带草稿（见计划「不执行的内容」）。
    _pendingAttachments.clear();
    // 15号计划：索引条目按当前会话的渲染项算，换会话后 index 全部失效，先关面板。
    _closeIndexPanel();
    // 12号计划：必须在 await 之前读位置——await 之后 setState 会把列表
    // 换成新会话的内容，此时可见 index / offset 已不属于旧会话。
    _saveScrollOffset();
    final newCtrl = await AiConversationRegistry.instance.getOrCreate(meta.id);
    if (mounted) {
      // controller 生命周期交给 AiConversationRegistry 管理，切换会话时只
      // 摘除本页面挂的监听，不再 dispose()——旧会话若仍在跑 _runLoop()，
      // dispose 会导致后续 notifyListeners 命中 ChangeNotifier 的 disposed-assert。
      _controller?.removeListener(_onControllerUpdate);
      // Fix B（13号计划）：先置 pending（Opacity=0 遮住首帧），再 setState 触发渲染，
      // 防止新会话内容在第一帧出现在顶部/旧位置后才 jumpTo，产生可见跳帧。
      _restoreScrollOffsetAfterFrame(newCtrl);
      setState(() => _controller = newCtrl);
      _controller!.addListener(_onControllerUpdate);
      _restoreDraft(newCtrl);
      await AiConversationStore.saveLastActiveId(meta.id);
    }
  }

  Future<void> _newConversation() async {
    _clearPromptPanelState();
    // 15轮03号计划：附件不跨会话带草稿（见计划「不执行的内容」）。
    _pendingAttachments.clear();
    _closeIndexPanel();
    // 12号计划：先记下旧会话的阅读位置，之后切回它才能恢复。
    _saveScrollOffset();
    final newCtrl = await AiConversationRegistry.instance.getOrCreate(null);
    if (mounted) {
      _controller?.removeListener(_onControllerUpdate);
      // Fix B（13号计划）：先置 pending（Opacity=0 遮住首帧），再 setState 触发渲染。
      _scrollToBottomAfterFrame();
      setState(() => _controller = newCtrl);
      _controller!.addListener(_onControllerUpdate);
      _restoreDraft(newCtrl);
      if (newCtrl.conversationId != null) {
        await AiConversationStore.saveLastActiveId(newCtrl.conversationId!);
      }
    }
  }

  /// 侧栏重命名成功后的回调：若重命名的正好是当前活跃会话，同步 controller
  /// 内存里的标题/自定义标志，避免用户重命名后立刻发消息触发 `_save()`，
  /// 内存里的旧标题反而把刚落盘的新标题覆盖回去。
  void _onConversationRenamed(String id, String newTitle) {
    if (_controller?.conversationId == id) {
      _controller!.applyExternalRename(newTitle);
    }
  }

  /// 切到底部一次（用于 controller 重建/切会话后定位到最新消息）。
  /// 12号计划：改为置 pending 标志 + 逐帧收敛，首帧列表未完成懒加载布局
  /// （maxScrollExtent 仍为 0 或仍是偏小的估算值）时不会静默跳过。
  /// 15号计划：贴底继续用像素目标（maxScrollExtent 才是真底部），
  /// 同时把首帧锚点重置为 0，避免 State 重建时从历史锚点起跳。
  void _scrollToBottomAfterFrame() {
    _pendingScrollToBottom = true;
    _pendingScrollIndex = null;
    _initialScrollIndex = 0;
    _resetPendingScrollCounters();
    _schedulePendingScroll();
  }

  /// 恢复到某个具体 item index（用于页内切回曾经翻过历史的会话）。
  /// 15号计划：index 语义——把该条消息顶到视口顶部，与像素 offset 不同，
  /// 消息高度重算（字体/宽度变化、markdown 重排）后仍指向同一条消息。
  void _scrollToIndexAfterFrame(int index) {
    _pendingScrollToBottom = false;
    _pendingScrollIndex = index;
    // State 全新创建时 ScrollablePositionedList 会直接用它做首帧锚点，
    // 后续 pending 的 jumpTo 落在同一 index 上，用户看不到二次跳动。
    _initialScrollIndex = index;
    _resetPendingScrollCounters();
    _schedulePendingScroll();
  }

  /// 页内切会话时：有记忆位置就恢复，没有（新会话/首次访问）就到底部。
  ///
  /// Finding 1 修复：saved == _atBottomSentinel 表示离开时贴底，同样走
  /// _scrollToBottomAfterFrame()，让 pending 收敛追到"当前底部"（含后台新消息），
  /// 而不是恢复一个已过时的绝对像素、阻断后续贴底自动跟随。
  void _restoreScrollOffsetAfterFrame(AiConversationController ctrl) {
    final id = ctrl.conversationId;
    final saved = id == null ? null : _scrollIndexByConversationId[id];
    // 恢复目标属于"即将切进来"的会话，itemCount 不能读上一帧的 _listItemCount，
    // 必须按新 controller 的消息重算，否则 clamp 用的是旧会话的长度。
    final itemCount = _itemCountOf(ctrl);
    final target = _sanitizeSavedIndex(saved, itemCount);
    if (target == null) {
      _scrollToBottomAfterFrame();
    } else {
      _scrollToIndexAfterFrame(target);
    }
  }

  /// 把记忆表里的值归一成合法 index；返回 null 表示"该走贴底"。
  ///
  /// 容错三类脏值（均重置为 0 = 列表顶部，绝不抛异常）：
  /// - double（开发期热重载残留的旧像素 offset 语义）；
  /// - 负数（除哨兵外没有合法负 index）；
  /// - 超出当前 itemCount（会话被清空或消息变少）。
  static int? _sanitizeSavedIndex(Object? saved, int itemCount) {
    if (saved == null) return null;
    if (saved is! num) return null;
    final raw = saved;
    if (raw == _atBottomSentinel) return null;
    if (itemCount <= 0) return null;
    // 旧像素语义（double）无法映射成 index，按"重置到顶部"处理。
    final index = raw is int ? raw : 0;
    if (index < 0 || index > itemCount - 1) return 0;
    return index;
  }

  int _itemCountOf(AiConversationController ctrl) =>
      _buildDisplayItems(ctrl.displayMessages).length +
      (ctrl.pendingDownload != null ? 1 : 0);

  /// 保存当前会话的阅读位置。只在列表已 attach 时写入——未 attach 时读不到
  /// 位置，若兜底写 0 会把有效位置覆盖成"顶部"。
  ///
  /// Finding 1 修复：若离开时已贴底（距底 ≤ 200dp），存哨兵 _atBottomSentinel
  /// 而非具体位置。恢复时哨兵走 _scrollToBottomAfterFrame，保证后台继续产出的
  /// 新消息仍能被跟随（原来存绝对像素导致 nearBottom 判定永远为假）。
  ///
  /// 15号计划两点变化：
  /// 1. 非贴底时存"当前最小可见 index"（视口顶部那条）。itemPositions 底层是
  ///    Set<Element> 的挂载顺序、不按 index 排序，必须自己取 min，不能用 first。
  /// 2. 流式输出进行中不写具体 index（消息还在增长，index 会偏移）；但贴底哨兵
  ///    与 index 无关，仍然照写，否则流式期间切 tab 回来会丢掉贴底跟随。
  ///
  /// "距底 ≤ 200dp 存哨兵"的判据保持像素语义不变：UnboundedCustomScrollView 的
  /// maxScrollExtent 始终是当前锚点坐标系下的真实底部，maxScrollExtent - pixels
  /// 仍然等于"到内容底部还剩多少"，与换组件前完全同义。
  void _saveScrollOffset() {
    final id = _controller?.conversationId;
    if (id == null) return;
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    final nearBottom = pos.maxScrollExtent - pos.pixels <= 200;
    if (nearBottom) {
      _scrollIndexByConversationId[id] = _atBottomSentinel;
      return;
    }
    if (_controller!.isLoading) return;
    final positions = _itemPositionsListener.itemPositions.value;
    if (positions.isEmpty) return;
    _scrollIndexByConversationId[id] =
        positions.map((p) => p.index).reduce(math.min);
  }

  bool get _hasPendingScroll =>
      _pendingScrollToBottom || _pendingScrollIndex != null;

  /// Finding 2 修复：用 _pendingScrollScheduled 去重，避免同一帧内
  /// _onControllerUpdate 和已在途的 postFrame 链都调用 _applyPendingScroll，
  /// 导致 _pendingScrollFrames / _lastPendingScrollExtent 在同一布局帧被
  /// 累计两次、extentSettled 提前误判为 true 而清标志。
  void _schedulePendingScroll() {
    if (_pendingScrollScheduled) return;
    _pendingScrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pendingScrollScheduled = false;
      if (!mounted) return;
      _applyPendingScroll();
    });
  }

  /// 目标还不存在（列表未 attach 或还没内容）时的等待：自排帧有上限，超限后
  /// 标志继续保留，交给 _onControllerUpdate 在消息真正渲染进列表时补一次。
  void _waitForPendingScrollTarget() {
    _pendingScrollWaitFrames++;
    if (_pendingScrollWaitFrames < _maxPendingScrollFrames) {
      _schedulePendingScroll();
    }
  }

  /// 执行一次 pending 滚动（仅由 postFrame 链调用）。落位成功（或重试预算耗尽）
  /// 立即清标志，避免与 _onControllerUpdate 里"贴底自动跟随"两条路径互相干扰。
  ///
  /// Finding 2 修复要点：
  /// 1. 此方法只由 _schedulePendingScroll 的 postFrame 回调调用，预算只在真实帧
  ///    边界推进，不再被 _onControllerUpdate 直接消耗（那边改为调
  ///    _schedulePendingScroll，已去重）。
  /// 2. "到底部"语义要求清标志时 offset 真的贴底：仅 extentSettled 不够，因为
  ///    content 仍在增长时 extentSettled 可能偶发为 true（两帧之间 maxExtent
  ///    恰好相等）。加 effectivelyAtTarget 守卫（距底 ≤ 200dp）。
  /// 3. 预算耗尽时对"到底部"做一次最终 jumpTo，确保 offset 贴底后再清标志，
  ///    否则 offset 停在旧像素、nearBottom 判定为假、后续跟随永久失效。
  void _applyPendingScroll() {
    if (!_hasPendingScroll) return;
    // 15号计划：index 目标走独立分支——jumpTo(index:) 是精确重排锚点，
    // 不存在"maxScrollExtent 估算偏小"问题，落位一次即可，不需要逐帧收敛。
    if (_pendingScrollIndex != null) {
      _applyPendingIndexScroll();
      return;
    }
    // 列表还没 attach（controller 刚 setState / 空会话只显示引导页）：
    // 标志保留，等下一帧或下一次 _onControllerUpdate 触发的 _schedulePendingScroll。
    if (!_scrollController.hasClients) {
      _waitForPendingScrollTarget();
      return;
    }
    // 15号计划实测结论：ScrollablePositionedList 用的是 UnboundedCustomScrollView，
    // maxScrollExtent 允许为负（不像普通 Viewport 会 max(0, ...) 截断），
    // 因此无论锚点 positionedIndex 停在哪一条，maxScrollExtent 始终等于
    // "当前锚点坐标系下的真实内容底部"，pixels 收敛逻辑无需先把锚点归零。
    // 内容不足一屏时 min == max，视口自动钉死在唯一合法位置（全部内容可见）。
    final pos = _scrollController.position;
    final maxExtent = pos.maxScrollExtent;
    final target = maxExtent;
    // 列表尚未完成首次布局：等下一帧或下一次 _onControllerUpdate，
    // 不消耗收敛预算、不判定失败。
    //
    // 15号计划：这里原来的判据是 maxExtent <= 0。换成 UnboundedCustomScrollView
    // 之后 maxScrollExtent 允许为负（内容不足一屏时 min == max < 0），旧判据会把
    // "已经布局好的短会话"误判成"还没渲染"，把 8 帧等待预算耗尽后 pending 标志
    // 永远留着，Opacity 卡在 0 → 短会话整页不可见。改用 ScrollPosition 自己的
    // 布局完成标志，长会话（maxExtent > 0）行为与 12/13号计划完全一致。
    if (!pos.hasContentDimensions ||
        !pos.hasViewportDimension ||
        _listItemCount <= 0) {
      _waitForPendingScrollTarget();
      return;
    }
    if (_scrollController.offset != target) {
      _scrollController.jumpTo(target);
    }
    _pendingScrollFrames++;
    final extentSettled = _lastPendingScrollExtent == maxExtent;
    // Finding 2 修复：到底部时还需确认 offset 真正贴底（防止 extentSettled 在
    // content 仍增长时偶发为 true 而提前清标志）。
    final effectivelyAtTarget = maxExtent - _scrollController.offset <= 200;
    final reachedTarget = extentSettled && effectivelyAtTarget;
    _lastPendingScrollExtent = maxExtent;
    if (reachedTarget || _pendingScrollFrames >= _maxPendingScrollFrames) {
      // Finding 2 修复：预算耗尽时若仍未贴底（content 持续增长导致收敛追不上），
      // 做最后一次 jumpTo 确保 offset == 当前 maxExtent，使 nearBottom=true，
      // 让 _onControllerUpdate 的自动跟随能立即接管后续新消息。
      if (_pendingScrollToBottom && _scrollController.hasClients) {
        final finalMax = _scrollController.position.maxScrollExtent;
        if (_scrollController.position.maxScrollExtent -
                _scrollController.offset >
            200) {
          _scrollController.jumpTo(finalMax);
        }
      }
      _clearPendingScroll();
      return;
    }
    // maxExtent 可能随后续 item 构建继续增长，下一帧再追一次。
    _schedulePendingScroll();
  }

  /// 15号计划：index 目标的落位。等三件事就绪即可一次跳到位：
  /// ItemScrollController 已 attach（列表已建）、itemCount > 0、
  /// ScrollController 已有 position（fork 的 _jumpTo 内部会调 jumpTo(0)）。
  void _applyPendingIndexScroll() {
    final target = _pendingScrollIndex!;
    if (!_itemScrollController.isAttached ||
        _listItemCount <= 0 ||
        !_scrollController.hasClients) {
      _waitForPendingScrollTarget();
      return;
    }
    // 只用 jumpTo，不用 scrollTo——fork 把 primary/secondary 两个内部列表塞进
    // 同一个 ScrollController，scrollTo 的"远距离过渡"分支会让一个
    // ScrollController 绑出两个 ScrollPosition，命中 Flutter 的单 position 断言。
    _itemScrollController.jumpTo(index: target.clamp(0, _listItemCount - 1));
    _clearPendingScroll();
  }

  void _clearPendingScroll() {
    _pendingScrollToBottom = false;
    _pendingScrollIndex = null;
    _resetPendingScrollCounters();
    // Fix B（13号计划）：pending 清除后触发重建，使 Opacity 从 0 恢复到 1.0，
    // 列表直接呈现在正确位置，用户不会看到任何跳帧。
    if (mounted) setState(() {});
  }

  void _resetPendingScrollCounters() {
    _pendingScrollFrames = 0;
    _pendingScrollWaitFrames = 0;
    _lastPendingScrollExtent = null;
  }

  /// 按会话 id 恢复输入框草稿；没有草稿则清空，避免残留上一个会话的文字。
  void _restoreDraft(AiConversationController ctrl) {
    final draft = _draftsByConversationId[ctrl.conversationId ?? ''] ?? '';
    _inputController.text = draft;
    _inputController.selection = TextSelection.collapsed(
      offset: _inputController.text.length,
    );
  }

  void _saveDraft() {
    _draftsByConversationId[_controller?.conversationId ?? ''] =
        _inputController.text;
  }

  bool get _isPromptTagsLongTermEnabled => _promptTagSettings.longTermEnabled;

  Future<void> _setPromptTagsLongTermEnabled(bool value) =>
      _promptTagSettings.setLongTermEnabled(value);

  List<AiPromptTag> _loadPromptTagOptions() => _promptTagSettings.promptTags;

  void _onPromptTagSettingsUpdate() {
    if (!mounted) return;
    setState(() {});
    _promptPanelEntry?.markNeedsBuild();
  }

  List<String> _persistentPromptTagNames() =>
      _controller?.persistentPromptTags.map((tag) => tag.name).toList() ??
      const [];

  Set<String> _persistentAllowedSources() =>
      _controller?.persistentAllowedSearchSources ?? const {};

  Set<String> _sourceTagsInInput() {
    return _sourceByTagName.keys
        .where((name) => _containsPromptToken(name))
        .toSet();
  }

  Set<String> _selectedSourceTagNames() {
    if (_resetSourceRestriction || _containsPromptToken('不限来源')) {
      return const {};
    }
    // 面板 chip 选中态优先；若有结构化选中来源，直接返回对应 tag 名
    if (_selectedSourceChips.isNotEmpty) {
      return _sourceByTagName.entries
          .where((entry) => _selectedSourceChips.contains(entry.value))
          .map((entry) => entry.key)
          .toSet();
    }
    // fallback：手输文本里识别的来源标签
    final inputSources = _sourceTagsInInput();
    if (inputSources.isNotEmpty) return inputSources;
    // fallback：会话长期来源限制（只用于 chip 的 selected 展示，不是"真实选中"）
    final persistentSources = _persistentAllowedSources();
    return _sourceByTagName.entries
        .where((entry) => persistentSources.contains(entry.value))
        .map((entry) => entry.key)
        .toSet();
  }

  bool _containsPromptToken(String name) {
    final token = '#${name.replaceFirst(RegExp(r'^#'), '')}';
    return RegExp(
      '(^|$_promptTagBoundaryPattern)${RegExp.escape(token)}'
      '(?=$_promptTagBoundaryPattern|\$)',
      multiLine: true,
    ).hasMatch(_inputController.text);
  }

  // 注：不再提供程序化插入/删除输入框 token 的方法（_insertPromptToken/
  // _removePromptTokens 随本次结构化选中改造被移除）。面板 chip 点选只操作
  // _selectedTagChips/_selectedSourceChips/_selectedLocalOnly 结构化集合；
  // 手动在输入框正文里打出 #标签名 的旧路径仍受 _containsPromptToken 识别、
  // 由 parseAiPromptTags 在发送时解析，两条路径互不干扰。

  void _togglePromptTag(String name) {
    final normalized = name.replaceFirst(RegExp(r'^#'), '');
    if (_selectedTagChips.contains(normalized)) {
      _selectedTagChips.remove(normalized);
    } else {
      _selectedTagChips.add(normalized);
    }
    if (mounted) setState(() {});
    _promptPanelEntry?.markNeedsBuild();
  }

  /// 面板"#搜本地" chip 的选中/取消。与来源标签互斥范围而非并集来源，
  /// 不强制清空 `_selectedSourceChips`，选中时来源选择仅在取消本地限定后生效。
  void _toggleLocalOnlyTag() {
    _selectedLocalOnly = !_selectedLocalOnly;
    if (mounted) setState(() {});
    _promptPanelEntry?.markNeedsBuild();
  }

  /// 15轮05号计划：面板"#搜图" chip 的选中/取消（面板挂在 OverlayEntry 上，
  /// 与 [_toggleLocalOnlyTag] 同款：State setState + markNeedsBuild 双通知）。
  void _toggleSearchByImageTag() {
    _selectedSearchByImage = !_selectedSearchByImage;
    if (mounted) setState(() {});
    _promptPanelEntry?.markNeedsBuild();
  }

  void _toggleSourceTag(String name) {
    final source = _sourceByTagName[name];
    if (source == null) return;
    if (_selectedSourceChips.contains(source)) {
      _selectedSourceChips.remove(source);
    } else {
      _selectedSourceChips.add(source);
    }
    _resetSourceRestriction = _selectedSourceChips.isEmpty;
    if (mounted) setState(() {});
    _promptPanelEntry?.markNeedsBuild();
  }

  void _selectAllSources() {
    _selectedSourceChips.clear();
    _resetSourceRestriction = true;
    if (mounted) setState(() {});
    _promptPanelEntry?.markNeedsBuild();
  }

  Future<void> _clearPersistentPromptTags() async {
    await _controller?.clearPersistentPromptTags();
    _promptPanelEntry?.markNeedsBuild();
  }

  Future<void> _clearPersistentSources() async {
    await _controller?.clearPersistentSourceRestriction();
    _resetSourceRestriction = false;
    _promptPanelEntry?.markNeedsBuild();
    if (mounted) setState(() {});
  }

  Future<void> _clearPersistentLocalOnly() async {
    await _controller?.clearPersistentLocalOnly();
    _promptPanelEntry?.markNeedsBuild();
    if (mounted) setState(() {});
  }

  /// 15轮09号计划：「已了解」——永久隐藏「当前会话长期状态」说明卡片。
  ///
  /// 只写 settings[148]，不触碰长期状态本身；面板挂在 OverlayEntry 上，
  /// 单靠 setState 不会重建它，必须同 _clearPersistentLocalOnly 一样先
  /// markNeedsBuild 再 setState。
  void _dismissPersistentStateCard() {
    appdata.settings[aiPersistentCardDismissedSettingIndex] = '1';
    appdata.updateSettings();
    _promptPanelEntry?.markNeedsBuild();
    if (!mounted) return;
    setState(() {});
    // ⚠️ 严禁 showToast（本项目是 no-op 空实现），提示一律走 SnackBar。
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('后续有问题请到设置里查看'.tl),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _togglePromptPanel() {
    if (_promptPanelEntry != null) {
      _closePromptPanel();
    } else {
      _showPromptPanel();
    }
  }

  void _showPromptPanel() {
    if (_promptPanelEntry != null || !mounted) return;
    final buttonContext = _promptTagButtonKey.currentContext;
    final buttonBox = buttonContext?.findRenderObject() as RenderBox?;
    if (buttonBox == null || !buttonBox.hasSize) return;
    final media = MediaQuery.of(context);
    final buttonTop = buttonBox.localToGlobal(Offset.zero).dy;
    final maxHeight = (buttonTop - media.padding.top - 16).clamp(96.0, 480.0);
    final panelWidth = (media.size.width - 16).clamp(240.0, 380.0);
    final tagRowBox =
        _pendingTagRowKey.currentContext?.findRenderObject() as RenderBox?;
    final tagRowHeight =
        (tagRowBox?.hasSize ?? false) ? tagRowBox!.size.height : 0.0;

    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (overlayContext) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _closePromptPanel,
              child: const ColoredBox(color: Colors.transparent),
            ),
          ),
          CompositedTransformFollower(
            link: _promptPanelLink,
            showWhenUnlinked: false,
            targetAnchor: Alignment.topLeft,
            followerAnchor: Alignment.bottomLeft,
            offset: Offset(0, -8 - tagRowHeight),
            child: Material(
              elevation: 10,
              borderRadius: BorderRadius.circular(16),
              clipBehavior: Clip.antiAlias,
              color: Theme.of(overlayContext).colorScheme.surfaceContainer,
              child: SizedBox(
                width: panelWidth,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: maxHeight),
                  child: _buildPromptPanel(overlayContext),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    _promptPanelEntry = entry;
    Overlay.of(context).insert(entry);
    if (mounted) setState(() {});
  }

  void _closePromptPanel() {
    final entry = _promptPanelEntry;
    _promptPanelEntry = null;
    entry?.remove();
    if (mounted) setState(() {});
  }

  void _clearPromptPanelState() {
    final entry = _promptPanelEntry;
    _promptPanelEntry = null;
    entry?.remove();
    _resetSourceRestriction = false;
    _selectedTagChips.clear();
    _selectedSourceChips.clear();
    _selectedLocalOnly = false;
    _selectedSearchByImage = false;
  }

  // ---------------------------------------------------------------------------
  // 15号计划 Feature 2：消息索引面板
  // ---------------------------------------------------------------------------

  /// 打开索引面板，并挂上"可见 index → 高亮"的监听。
  ///
  /// 监听只在面板可见期间存在：itemPositions 在每次滚动的 postFrame 都会更新，
  /// 常驻监听会把整页 setState 频率抬到与滚动同频。
  void _openIndexPanel() {
    if (_indexPanelVisible) return;
    _itemPositionsListener.itemPositions.addListener(_onVisibleItemsChanged);
    setState(() {
      _indexPanelVisible = true;
      _visibleIndices = _currentVisibleIndices();
    });
  }

  void _closeIndexPanel() {
    // 17号计划步骤 7：停止逻辑放在 early-return **之前**。
    // 面板还会因点遮罩、切会话、返回键等路径关闭，把停止收在这个唯一出口里
    // 比散在各手势回调里更难漏；放在 return 之前是为了即使状态已是"不可见"
    // （重复调用、或其它路径先改了标志）也一定能把 Ticker 停掉。
    _stopEdgeAutoScroll();
    if (!_indexPanelVisible) return;
    _itemPositionsListener.itemPositions.removeListener(_onVisibleItemsChanged);
    setState(() {
      _indexPanelVisible = false;
      _visibleIndices = const {};
    });
  }

  /// itemPositions 变化回调。该 notifier 由 PositionedList 在 postFrame 里更新，
  /// 不在 build/layout 阶段，因此这里 setState 是安全的。
  /// 只有集合真的变了才 setState，避免滚动中每帧无谓重建。
  void _onVisibleItemsChanged() {
    if (!mounted || !_indexPanelVisible) return;
    final next = _currentVisibleIndices();
    if (_sameIndexSet(next, _visibleIndices)) return;
    setState(() => _visibleIndices = next);
  }

  Set<int> _currentVisibleIndices() =>
      _itemPositionsListener.itemPositions.value.map((p) => p.index).toSet();

  static bool _sameIndexSet(Set<int> a, Set<int> b) =>
      a.length == b.length && a.containsAll(b);

  /// 面板条目缓存的版本键：会话 id + 渲染项数 + 最后一条消息的文本长度。
  /// 流式输出时最后一条 assistant 消息在增长，长度变化会让预览文本跟着刷新；
  /// 其余 setState（输入框、标签面板）不改这三项，直接命中缓存。
  /// 17号计划步骤 11：过滤条件也必须进版本键。「仅显示用户对话」改了但会话内容
  /// 没变时，上面三项全都一样，不并进来就会命中旧缓存——表现为"开关拨了没反应"，
  /// 且不报错、不变红。
  String _indexEntriesVersionKey() {
    final messages = _controller?.displayMessages ?? const <AiChatMessage>[];
    final lastLength = messages.isEmpty ? 0 : messages.last.text.length;
    return '${_controller?.conversationId ?? ''}'
        '|${_displayItems.length}|${messages.length}|$lastLength'
        '|${_indexUserOnly ? 1 : 0}';
  }

  /// 索引面板是否只列用户消息（设置 141，默认开启）。
  bool get _indexUserOnly =>
      appdata.settings[aiIndexUserOnlySettingIndex] == '1';

  /// 迷你索引条横线数上限（设置 142）。0 或非法值中的 0 表示不限制；
  /// 解析失败时退回默认 6，避免脏值把索引条画空。
  int get _indexBarMaxTicks {
    final raw = appdata.settings[aiIndexBarMaxTicksSettingIndex];
    final parsed = int.tryParse(raw);
    if (parsed == null || parsed < 0) return 6;
    return parsed;
  }

  /// 从当前渲染快照提取索引条目：默认只取 user 单条消息，
  /// 关闭「仅显示用户对话」（设置 141）后同时取 assistant。
  /// 工具调用分组（_ToolGroup）与工具类消息不进索引——它们不是用户会去回看的内容。
  ///
  /// index 口径与列表 itemCount 完全一致（即 _displayItems 下标），
  /// 跳转时可直接交给 ItemScrollController。
  List<_IndexEntry> _buildIndexEntries() {
    final key = _indexEntriesVersionKey();
    if (_cachedIndexEntriesKey == key) return _cachedIndexEntries;
    final userOnly = _indexUserOnly;
    final entries = <_IndexEntry>[];
    for (var i = 0; i < _displayItems.length; i++) {
      final item = _displayItems[i];
      if (item is! _SingleItem) continue;
      final type = item.message.type;
      // 17号计划步骤 11：默认只收 user；关闭设置后沿用 15 号计划的 user+assistant。
      if (userOnly) {
        if (type != AiChatMessageType.user) continue;
      } else if (type != AiChatMessageType.user &&
          type != AiChatMessageType.assistant) {
        continue;
      }
      // 15轮03号计划：带图消息在面板条目前缀显示 [图×N]。
      // （空文本+图片经桥接语后 text 非空，「（空消息）」分支实际不会出现在
      // 图片消息上；保留兜底不改 _indexPreviewText 本体。消息一经入列不可变，
      // 附件数不会事后变化，无需并入 _indexEntriesVersionKey。）
      final attachmentCount = item.message.attachmentPaths.length;
      final base = _indexPreviewText(item.message.text);
      entries.add(_IndexEntry(
        index: i,
        preview: attachmentCount == 0 ? base : '[图×$attachmentCount] $base',
        type: type,
      ));
    }
    _cachedIndexEntries = List.unmodifiable(entries);
    _cachedIndexEntriesKey = key;
    return _cachedIndexEntries;
  }

  /// 17号计划步骤 12：迷你索引条的数据源——全部用户消息在 _displayItems 里的下标。
  ///
  /// 与面板条目分开算：迷你索引条**始终只取 user**，不受「仅显示用户对话」开关
  /// 影响（该开关只管面板内容）。缓存键不含该设置值，正是因为它与设置无关。
  ///
  /// 迷你索引条常驻显示，每次滚动都会重建（ValueListenableBuilder），
  /// 因此这份列表必须缓存，不能每帧遍历 _displayItems。
  List<int> _userMessageIndices() {
    final messages = _controller?.displayMessages ?? const <AiChatMessage>[];
    final key = '${_controller?.conversationId ?? ''}'
        '|${_displayItems.length}|${messages.length}';
    if (_cachedUserIndicesKey == key) return _cachedUserIndices;
    final result = <int>[];
    for (var i = 0; i < _displayItems.length; i++) {
      final item = _displayItems[i];
      if (item is _SingleItem && item.message.type == AiChatMessageType.user) {
        result.add(i);
      }
    }
    _cachedUserIndices = List.unmodifiable(result);
    _cachedUserIndicesKey = key;
    return _cachedUserIndices;
  }

  /// 预览文本：折叠所有空白（含换行）后取前 30 个字符。
  /// 用 runes 截断而不是 substring，避免把 emoji 的代理对切成半个字符。
  static String _indexPreviewText(String text) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.isEmpty) return '（空消息）';
    final runes = flat.runes.toList();
    if (runes.length <= 30) return flat;
    return '${String.fromCharCodes(runes.take(30))}…';
  }

  /// 把全局 Y 坐标换算成对应的消息 index 值。
  ///
  /// 拖选高亮（onLongPressMoveUpdate）与松手跳转（onLongPressEnd）共用此方法，
  /// 保证两者始终基于同一换算结果，不会出现高亮到 A 却跳到 B 的情形。
  ///
  /// 换算步骤：
  ///   1. 通过 _panelContentKey 取面板内容区的 RenderBox；
  ///   2. 把全局 Y 转成 box 局部 Y；
  ///   3. 加上面板列表当前滚动偏移，得到"从列表顶部算起的 Y"；
  ///   4. 除以行高取整，clamp 到合法区间，映射到 entries[rowIdx].index。
  int? _indexFromGlobalY(double globalY, List<_IndexEntry> entries) {
    if (entries.isEmpty) return null;
    final context = _panelContentKey.currentContext;
    if (context == null) {
      // 面板刚打开、内容区还没完成首帧 layout：直接返回第一条，不崩溃。
      return entries.first.index;
    }
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return entries.first.index;
    final local = box.globalToLocal(Offset(0, globalY));
    final scrollOffset =
        _panelScrollController.hasClients ? _panelScrollController.offset : 0.0;
    final scrolledY = local.dy + scrollOffset;
    final rowIdx = (scrolledY / _ConversationIndexPanelState.rowExtent)
        .floor()
        .clamp(0, entries.length - 1);
    return entries[rowIdx].index;
  }

  // ---------------------------------------------------------------------------
  // 17号计划步骤 4~7：拖选时的边缘自动滚动
  // ---------------------------------------------------------------------------

  /// 边缘区高度上限。基准是"内容区高度的 1/3"（用户描述的"上下 1/3 处"），
  /// 但面板最矮只有一行（rowExtent=52），无条件按 1/3 划分会让上下两区紧邻，
  /// 所以再压一道固定上限。1/3 划分本身已保证两区之和 ≤ 2/3 高度、永不重叠。
  static const double _edgeZoneMaxHeight = 96;

  /// 边缘区最大滚动速度（px/s）。rowExtent=52，1040 ≈ 每秒 20 行：
  /// 30 条消息的面板（内容 1560、可滚动余量约 1313）约 1.3 秒滚到头，
  /// 既能快速跨越一屏之外的中间段，又不至于一闪而过看不清落点。
  static const double _edgeScrollMaxSpeed = 1040;

  /// 起手抑制距离：手指离长按起点不足一行高度时不自动滚。
  ///
  /// 面板是"顶端对齐到长按起点"浮动出来的，手指天然就落在第一行附近，也就是
  /// **天然落在上缘区里**；长按点靠屏幕下方时面板还会被 clamp 上移，手指反而落到
  /// 面板下边缘之外（下缘区最深处）。若不加这道闸，任何一次长按只要有几像素抖动
  /// 就会立刻满速滚走，面板刚出现就跑到头。用一行高度作阈值：手指抖动是几像素级，
  /// 真要去边缘区必然移动远超一行。这是计划外补充的一条约束，理由见回写区。
  static const double _edgeScrollArmDistance =
      _ConversationIndexPanelState.rowExtent;

  /// 取手指在面板内容区里的局部 Y 与内容区高度。
  ///
  /// 与 _indexFromGlobalY **共用同一个 _panelContentKey 的 RenderBox**，因此两者
  /// 坐标系严格一致：这里判定"在上缘/下缘/中间"，那边换算 index，不会打架。
  ///
  /// 与 _indexFromGlobalY 的关键区别：**不做任何 clamp**。那边末步 clamp 到
  /// [0, len-1]，手指"刚好贴着面板底边"与"已经跑到面板下方 300px"返回值完全相同，
  /// 没法用来判定边缘、更算不出深入程度。
  ///
  /// 内容区未挂载（面板刚打开还没 layout、或空态没有 ListView）时返回 null。
  ({double localY, double height})? _panelLocalGeometry(double globalY) {
    final context = _panelContentKey.currentContext;
    if (context == null) return null;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return null;
    return (
      localY: box.globalToLocal(Offset(0, globalY)).dy,
      height: box.size.height,
    );
  }

  /// 按手指位置算出自动滚动速度（px/s，正=向下滚，0=不滚）。
  ///
  /// 速度随深入程度**递进**而不是进区即定速：
  ///   - 刚踩到区边界 → 深入度 0 → 速度 0
  ///   - 越靠面板边缘 → 深入度越大 → 越快
  ///   - 抵达边缘或越界之外 → 深入度封顶 1 → 满速保持，不因越得更远而无限加速
  ///
  /// 曲线取**平方**（depth²）而不是线性：区边界附近速度极小（深入 10% 只有 1%
  /// 速度），手指在中间区与边缘区之间徘徊时不会一跨过界就明显窜动；真要快滚
  /// 只需再往边缘挪一点。线性在边界处的斜率是常数，边界两侧手感会有台阶。
  double _edgeScrollSpeedFor(double localY, double height) {
    if (height <= 0) return 0;
    final zone = math.min(height / 3, _edgeZoneMaxHeight);
    if (zone <= 0) return 0;
    if (localY < zone) {
      // 上缘区：localY 越小（越靠顶）越深；越过顶端（负值）封顶。
      final depth = ((zone - localY) / zone).clamp(0.0, 1.0);
      return -_edgeScrollMaxSpeed * depth * depth;
    }
    final bottomZoneStart = height - zone;
    if (localY > bottomZoneStart) {
      final depth = ((localY - bottomZoneStart) / zone).clamp(0.0, 1.0);
      return _edgeScrollMaxSpeed * depth * depth;
    }
    return 0;
  }

  /// 按当前手指位置更新自动滚动状态（步骤 7 的启动/更新入口）。
  ///
  /// 只在 onLongPressMoveUpdate 里调：手指停着不动时不会再有回调，靠 Ticker 自持续。
  /// 已在运行时只改速度、不重启 Ticker（重启会把 elapsed 基准清零，白丢一帧）。
  void _updateEdgeAutoScroll() {
    final finger = _dragCurrentGlobal;
    final start = _longPressStartGlobal;
    if (finger == null || !_indexPanelVisible) {
      _stopEdgeAutoScroll();
      return;
    }
    // 起手抑制：手指还没离开长按起点一行以上，视为抖动，不滚。
    if (start != null && (finger - start).distance < _edgeScrollArmDistance) {
      _stopEdgeAutoScroll();
      return;
    }
    final geom = _panelLocalGeometry(finger.dy);
    if (geom == null) {
      _stopEdgeAutoScroll();
      return;
    }
    // 内容不足一屏（maxScrollExtent==0）时不启动，避免空转。
    if (!_panelScrollController.hasClients ||
        _panelScrollController.position.maxScrollExtent <= 0) {
      _stopEdgeAutoScroll();
      return;
    }
    final speed = _edgeScrollSpeedFor(geom.localY, geom.height);
    if (speed == 0) {
      _stopEdgeAutoScroll();
      return;
    }
    _edgeScrollSpeed = speed;
    final ticker = _edgeScrollTicker ??= createTicker(_onEdgeScrollTick);
    if (!ticker.isActive) {
      _lastEdgeTickElapsed = null;
      ticker.start();
    }
  }

  /// 停止自动滚动。幂等，可从任意出口重复调用。
  void _stopEdgeAutoScroll() {
    _edgeScrollSpeed = 0;
    _lastEdgeTickElapsed = null;
    final ticker = _edgeScrollTicker;
    if (ticker != null && ticker.isActive) {
      // canceled:true —— start() 返回的 TickerFuture 没人 await，
      // 用 stop() 正常完成会留下一个无人接的 future，cancel 语义才对。
      ticker.stop(canceled: true);
    }
  }

  /// 每帧推进：算位移 → jumpTo → 用当前手指坐标重算高亮。
  void _onEdgeScrollTick(Duration elapsed) {
    final last = _lastEdgeTickElapsed;
    _lastEdgeTickElapsed = elapsed;
    // 首帧只立基准（Ticker 第一次回调 elapsed 恒为 0），下一帧才有真实 dt。
    if (last == null) return;
    if (!mounted || _edgeScrollSpeed == 0) return;
    final dt = (elapsed - last).inMicroseconds / Duration.microsecondsPerSecond;
    if (dt <= 0) return;
    // 面板淡出后 _rendered=false，内容子树被移除、controller 无 client。
    // 沿用 _revealActiveEntry 的 hasClients + clamp 范式，越界 jumpTo 会抛断言。
    if (!_panelScrollController.hasClients) return;
    final position = _panelScrollController.position;
    final target = (position.pixels + _edgeScrollSpeed * dt)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    // 到头就停止推进，但**不停 Ticker**：手指还在边缘区，一旦方向反转或内容
    // 变长应当立即恢复滚动（用户已拍板"到头即停、不回弹"）。
    if (target != position.pixels) position.jumpTo(target);
    // 关键不变量（15/16 号计划确立）：高亮与松手跳转共用 _indexFromGlobalY。
    // 手指没动但 offset 变了，该换算结果会变；不重算就会"面板在滚、高亮卡住"，
    // 且松手跳到错的消息。仅在值真变化时 setState，避免每帧无谓重建。
    final finger = _dragCurrentGlobal;
    if (finger == null) return;
    final hover = _indexFromGlobalY(finger.dy, _cachedIndexEntries);
    if (hover != _dragHoverIndex) {
      setState(() => _dragHoverIndex = hover);
    }
  }

  /// 面板条目点击：跳到对应消息并关闭面板。
  ///
  /// 只有"目标已在可见区间"时才用 scrollTo 做动画：fork 版
  /// ScrollablePositionedList 把 primary/secondary 两个内部列表塞进同一个
  /// ScrollController，scrollTo 的远距离过渡分支会让一个 ScrollController 绑出
  /// 两个 ScrollPosition，随后读 .offset 命中 Flutter 的单 position 断言。
  /// 远距离一律退化成 jumpTo（瞬时落位，无动画，但不会崩）。
  void _jumpToIndexEntry(_IndexEntry entry) {
    if (!_itemScrollController.isAttached || _listItemCount <= 0) {
      _closeIndexPanel();
      return;
    }
    final target = entry.index.clamp(0, _listItemCount - 1);
    final visible = _itemPositionsListener.itemPositions.value
        .any((p) => p.index == target);
    if (visible) {
      _itemScrollController.scrollTo(
        index: target,
        alignment: 0.05,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      _itemScrollController.jumpTo(index: target, alignment: 0.05);
    }
    _closeIndexPanel();
  }

  /// 输入框上方常驻的结构化标签行：展示本次待发送选中项 + 已生效的长期状态。
  /// 两者皆无时不占位（返回 SizedBox.shrink），不改变无标签场景下的输入区布局。
  /// chip 不接受文本输入、无法用退格键从中间删改，只能点击整体移除。
  Widget _buildPendingTagRow(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final pendingSourceNames = _sourceByTagName.entries
        .where((entry) => _selectedSourceChips.contains(entry.value))
        .map((entry) => entry.key)
        .toList();
    final persistentTagNames = _persistentPromptTagNames();
    final persistentSources = _persistentAllowedSources();
    final persistentSourceNames = _sourceByTagName.entries
        .where((entry) => persistentSources.contains(entry.value))
        .map((entry) => entry.key)
        .toList();
    final persistentLocalOnly = _controller?.effectiveLocalOnly ?? false;

    final hasPending = _selectedTagChips.isNotEmpty ||
        pendingSourceNames.isNotEmpty ||
        _selectedLocalOnly ||
        _selectedSearchByImage;
    final hasPersistent = persistentTagNames.isNotEmpty ||
        persistentSourceNames.isNotEmpty ||
        persistentLocalOnly;
    if (!hasPending && !hasPersistent) return const SizedBox.shrink();
    const bottomGap = SizedBox(height: 4);

    Widget buildChip({
      required String label,
      required VoidCallback onRemove,
      required bool persistent,
    }) {
      return InputChip(
        label: Text(label),
        onDeleted: onRemove,
        deleteIcon: const Icon(Icons.close, size: 16),
        visualDensity: VisualDensity.compact,
        backgroundColor:
            persistent ? Colors.transparent : colorScheme.primaryContainer,
        side: persistent
            ? BorderSide(color: colorScheme.outline.withValues(alpha: 0.6))
            : BorderSide.none,
        shape: const StadiumBorder(),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final name in _selectedTagChips)
                buildChip(
                  label: '#$name',
                  onRemove: () =>
                      setState(() => _selectedTagChips.remove(name)),
                  persistent: false,
                ),
              for (final name in pendingSourceNames)
                buildChip(
                  label: '#$name',
                  onRemove: () => setState(
                    () => _selectedSourceChips.remove(_sourceByTagName[name]),
                  ),
                  persistent: false,
                ),
              if (_selectedLocalOnly)
                buildChip(
                  label: '#$aiLocalOnlyScopeTagName',
                  onRemove: () => setState(() => _selectedLocalOnly = false),
                  persistent: false,
                ),
              if (_selectedSearchByImage)
                buildChip(
                  label: '#$aiSearchByImageTagName',
                  onRemove: () =>
                      setState(() => _selectedSearchByImage = false),
                  persistent: false,
                ),
              for (final name in persistentTagNames)
                buildChip(
                  label: '#$name',
                  onRemove: _clearPersistentPromptTags,
                  persistent: true,
                ),
              if (persistentSourceNames.isNotEmpty)
                buildChip(
                  label:
                      '来源：${persistentSourceNames.map((n) => '#$n').join(' ')}',
                  onRemove: _clearPersistentSources,
                  persistent: true,
                ),
              if (persistentLocalOnly)
                buildChip(
                  label: '#$aiLocalOnlyScopeTagName',
                  onRemove: _clearPersistentLocalOnly,
                  persistent: true,
                ),
            ],
          ),
        ),
        bottomGap,
      ],
    );
  }

  Widget _buildPromptPanel(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final tags = _loadPromptTagOptions();
    final selectedSources = _selectedSourceTagNames();
    final persistentTagNames = _persistentPromptTagNames();
    final persistentSources = _persistentAllowedSources();
    final persistentLocalOnly = _controller?.effectiveLocalOnly ?? false;
    final persistentSourceLabels = _sourceByTagName.entries
        .where((entry) => persistentSources.contains(entry.value))
        .map((entry) => '#${entry.key}')
        .join('  ');
    // 15轮09号计划：点过「已了解」后这张说明卡片永久不再渲染（长期状态机制不变）。
    final cardDismissed =
        appdata.settings[aiPersistentCardDismissedSettingIndex] == '1';

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.tag, color: colorScheme.primary),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  '提示词标签',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              const Text('长期生效', style: TextStyle(fontSize: 12)),
              Switch(
                value: _isPromptTagsLongTermEnabled,
                onChanged: _setPromptTagsLongTermEnabled,
              ),
            ],
          ),
          Text(
            _isPromptTagsLongTermEnabled
                ? '新选择会写入当前会话；关闭开关不会删除已有长期状态。'
                : '新选择仅对本次完整回复和工具循环有效。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (!cardDismissed &&
              (persistentTagNames.isNotEmpty ||
                  persistentSources.isNotEmpty ||
                  persistentLocalOnly)) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: colorScheme.secondaryContainer.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      const Expanded(
                        child: Text(
                          '当前会话长期状态',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      TextButton(
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 0,
                          ),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          textStyle: const TextStyle(fontSize: 11),
                        ),
                        onPressed: _dismissPersistentStateCard,
                        child: const Text('已了解'),
                      ),
                    ],
                  ),
                  if (persistentTagNames.isNotEmpty)
                    Text(
                      persistentTagNames.map((name) => '#$name').join('  '),
                      style: const TextStyle(fontSize: 12),
                    ),
                  if (persistentSources.isNotEmpty)
                    Text(
                      '来源：$persistentSourceLabels',
                      style: const TextStyle(fontSize: 12),
                    ),
                  if (persistentLocalOnly)
                    const Text(
                      '范围：#$aiLocalOnlyScopeTagName（仅本地/远程库，不联网）',
                      style: TextStyle(fontSize: 12),
                    ),
                  Wrap(
                    spacing: 4,
                    children: [
                      if (persistentTagNames.isNotEmpty)
                        TextButton.icon(
                          onPressed: _clearPersistentPromptTags,
                          icon: const Icon(Icons.clear_all, size: 16),
                          label: const Text('清除长期提示'),
                        ),
                      if (persistentSources.isNotEmpty)
                        TextButton.icon(
                          onPressed: _clearPersistentSources,
                          icon: const Icon(Icons.public, size: 16),
                          label: const Text('恢复全部来源'),
                        ),
                      if (persistentLocalOnly)
                        TextButton.icon(
                          onPressed: _clearPersistentLocalOnly,
                          icon: const Icon(Icons.wifi, size: 16),
                          label: const Text('取消仅本地'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          Text('来源', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              FilterChip(
                label: const Text('默认/全部来源'),
                selected: selectedSources.isEmpty,
                onSelected: (_) => _selectAllSources(),
              ),
              FilterChip(
                label: const Text('#$aiLocalOnlyScopeTagName'),
                tooltip: '仅查本地设备库与已连接的远程库快照，不联网；'
                    '与来源选择同时选中时以本地限定为准',
                selected: _selectedLocalOnly,
                onSelected: (_) => _toggleLocalOnlyTag(),
              ),
              FilterChip(
                label: const Text('#$aiSearchByImageTagName'),
                tooltip: '对本次发送的图片执行以图搜源（soutubot）',
                selected: _selectedSearchByImage,
                onSelected: (_) => _toggleSearchByImageTag(),
              ),
              for (final name in _sourceByTagName.keys)
                FilterChip(
                  label: Text('#$name'),
                  selected: selectedSources.contains(name),
                  onSelected: (_) => _toggleSourceTag(name),
                ),
            ],
          ),
          const Divider(height: 24),
          Text('普通标签', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 6),
          if (tags.isEmpty)
            Text(
              '暂无普通标签，请在 AI 设置中添加。',
              style: Theme.of(context).textTheme.bodySmall,
            )
          else
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final tag in tags)
                  FilterChip(
                    tooltip: tag.prompt,
                    label: Text('#${tag.name}'),
                    selected: _selectedTagChips.contains(tag.name),
                    onSelected: (_) => _togglePromptTag(tag.name),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  @override
  void deactivate() {
    // 13号计划（Fix C）：切 tab / 被其他路由覆盖时保存阅读位置。
    // deactivate() 在 Widget 从树中移除之前调用，此时 ScrollController 仍
    // attached（列表尚未 unmount），_saveScrollOffset() 能正确读到位置。
    // dispose() 时 ScrollController 已经 detached，读不到位置，因此挪到这里。
    _saveScrollOffset();
    super.deactivate();
  }

  @override
  void dispose() {
    _clearPromptPanelState();
    // 15号计划：面板可见时挂着 itemPositions 监听，销毁前摘掉。
    // _itemPositionsListener 是 State 字段，会随 State 一起回收，因此这里不是
    // 防内存泄漏，而是防"列表 unmount 过程中 fork 仍上报一次位置"时回调进
    // 已销毁的 State（_onVisibleItemsChanged 里的 mounted 判定是第二道闸）。
    if (_indexPanelVisible) {
      _itemPositionsListener.itemPositions
          .removeListener(_onVisibleItemsChanged);
      _indexPanelVisible = false;
    }
    // 17号计划步骤 7：边缘自动滚动的 Ticker 必须在 super.dispose() 之前停掉并回收
    // ——SingleTickerProviderStateMixin.dispose() 会断言"Ticker 不得仍处于 active"。
    _stopEdgeAutoScroll();
    _edgeScrollTicker?.dispose();
    _edgeScrollTicker = null;
    _promptTagSettings.removeListener(_onPromptTagSettingsUpdate);
    // 下面只摘除监听、不 dispose controller：否则若该轮 _runLoop() 仍在跑，
    // 之后的 notifyListeners 会命中 ChangeNotifier 的 disposed-assert，
    // 导致该轮对话被中断/丢失。
    _controller?.removeListener(_onControllerUpdate);
    _inputController.dispose();
    _scrollController.dispose();
    _panelScrollController.dispose();
    super.dispose();
  }

  void _onControllerUpdate() {
    setState(() {});
    _promptPanelEntry?.markNeedsBuild();
    // Finding 2 修复：不再直接调 _applyPendingScroll()，改为 _schedulePendingScroll()。
    // 去重设计保证一帧内只有一个 postFrame 在途，预算计数与 extentSettled 判定
    // 都在真实帧边界推进，消除"同一布局帧被累计两次"的误判。
    // 作用等同于原来的"补一次落位"：若有 pending 且 postFrame 还没排上，这里
    // 会排一个；若已在途，dedup 直接 return。
    if (_hasPendingScroll) _schedulePendingScroll();
    // 只有用户接近底部（距底 ≤ 200dp）时才自动跟随新消息，
    // 避免用户主动翻历史时被新消息强制拉回底部。
    // pending 期间定位权归 pending 路径，跳过自动跟随，避免"恢复到历史位置"
    // 刚落位就被这条 animateTo 拉回底部（发新消息的滚底是独立路径：那时
    // pending 已清，不受影响）。
    if (!_hasPendingScroll && _scrollController.hasClients) {
      final pos = _scrollController.position;
      final nearBottom = pos.maxScrollExtent - pos.pixels <= 200;
      if (nearBottom) {
        Future.delayed(const Duration(milliseconds: 100), () {
          if (mounted && _scrollController.hasClients) {
            _scrollController.animateTo(
              _scrollController.position.maxScrollExtent,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
            );
          }
        });
      }
    }
  }

  Widget _buildEmptyGuide(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final dimColor = colorScheme.onSurface.withValues(alpha: 0.4);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_awesome, size: 48, color: dimColor),
            const SizedBox(height: 16),
            Text(
              'AI 助手',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '当前对话的上下文在本次会话中保留，\n关闭对话或清空后重置。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: dimColor),
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                _buildExampleChip(context, '我有没有下过 XXX'),
                _buildExampleChip(context, '帮我搜索 XXX'),
                _buildExampleChip(context, '我收藏过 XXX 吗'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExampleChip(BuildContext context, String text) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        border: Border.all(
          color: colorScheme.outline.withValues(alpha: 0.4),
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        '「$text」',
        style: TextStyle(
          fontSize: 12,
          color: colorScheme.onSurface.withValues(alpha: 0.5),
        ),
      ),
    );
  }

  /// 15轮03号计划：唤起系统选图器，把所选图片加入待发附件（上限 4 张/条，
  /// 限制单请求 base64 体积：4×1.5MB≈8MB）。
  Future<void> _pickAttachments() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: true,
    );
    if (result == null || !mounted) return;
    final paths = result.files.map((f) => f.path).whereType<String>().toList();
    var overflow = false;
    setState(() {
      overflow = mergePendingAiAttachmentSelection(_pendingAttachments, paths);
    });
    if (overflow && mounted) {
      // ⚠️ 严禁 showToast（本项目是 no-op 空实现），提示一律走 SnackBar
      // （先例 lib/pages/local_library_page.dart:81）。
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('每条消息最多发送 4 张图片'.tl)),
      );
    }
  }

  /// 输入框上方的待发附件缩略图行；无附件时不占位（同 _buildPendingTagRow 约定）。
  Widget _buildPendingAttachmentRow(BuildContext context) {
    if (_pendingAttachments.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 64,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
        itemCount: _pendingAttachments.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (context, i) {
          final path = _pendingAttachments[i];
          return Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(
                  File(path),
                  width: 56,
                  height: 56,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    width: 56,
                    height: 56,
                    color:
                        Theme.of(context).colorScheme.surfaceContainerHighest,
                    child: const Icon(Icons.broken_image_outlined),
                  ),
                ),
              ),
              Positioned(
                // 右上角 × 删除
                top: 0,
                right: 0,
                child: GestureDetector(
                  onTap: () => setState(() => _pendingAttachments.removeAt(i)),
                  child: Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      // surface 底色确保深浅图上都可见
                      color: Theme.of(context).colorScheme.surface,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Theme.of(context)
                            .colorScheme
                            .outline
                            .withValues(alpha: 0.4),
                      ),
                    ),
                    child: const Icon(Icons.close, size: 12),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _send() async {
    // 15轮03号计划：_sendInFlight 覆盖整个 _send()（含 isLoading 置位前的
    // await 窗口），防止压缩落盘期间二次发送。
    if (_sendInFlight) return;
    final text = _inputController.text.trim();
    final hasPendingSelection = _selectedTagChips.isNotEmpty ||
        _selectedSourceChips.isNotEmpty ||
        _selectedLocalOnly ||
        _selectedSearchByImage;
    if (text.isEmpty && !hasPendingSelection && _pendingAttachments.isEmpty) {
      return;
    }
    setState(() => _sendInFlight = true);
    try {
      // initState 中的初始化是异步的；发送前等待同一个 pending future，避免用户
      // 刚进入页面就发送时读到空标签列表或错误的长期生效开关。
      await _promptTagSettings.initialize();
      if (!mounted || _controller == null) return;
      final resetSourceRestriction = _resetSourceRestriction;
      // 结构化选中集合：面板点选的普通标签/来源/本地限定，与手输文本里的 #标签名
      // 并行合并，由 AiConversationController.send() 内部统一去重（结构化选中 ∪ 文本识别）。
      final structuredSources = Set<String>.from(_selectedSourceChips);
      final localOnlyRequested = _selectedLocalOnly;
      // 15轮05号计划：在 _clearPromptPanelState() 之前冻结（照上方冻结惯例）。
      final searchByImageRequested = _selectedSearchByImage;
      final availableTags = _promptTagSettings.promptTags;
      final selectedPromptTags = availableTags
          .where((tag) => _selectedTagChips.contains(tag.name))
          .toList();
      // send() 内部对空文本+无附件会直接 return false；三态桥接语：
      // 图片桥接优先于标签桥接——turn_context 已承载标签语义，而图片-only
      // 消息若放任标签桥接语进 parse，模型会收到与图片无关的导向语。
      // 搜图路径图片给工具用，不用"请查看并结合我发送的图片回答"引导模型。
      final effectiveText = text.isNotEmpty
          ? text
          : (_pendingAttachments.isNotEmpty && !searchByImageRequested)
              ? aiImageOnlyUserBridge
              : aiPromptTagOnlyUserBridge;

      // 15轮03号计划：先压缩落盘，失败则输入与待发附件均原样保留。
      var attachmentRelativePaths = const <String>[];
      final pendingSnapshot = List<String>.from(_pendingAttachments);
      if (pendingSnapshot.isNotEmpty) {
        try {
          attachmentRelativePaths = await persistAiAttachments(
              _controller!.conversationId ?? '', pendingSnapshot);
        } catch (e) {
          if (mounted) {
            // ⚠️ 严禁 showToast（no-op），见 _pickAttachments 处说明。
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('${'图片处理失败'.tl}：$e')),
            );
          }
          return; // 输入与待发附件均原样保留
        }
        if (!mounted || _controller == null) {
          await deleteAiAttachmentFiles(attachmentRelativePaths);
          return;
        }
      }

      _clearPromptPanelState();
      _inputController.clear();
      _draftsByConversationId.remove(_controller?.conversationId ?? '');
      setState(() => _pendingAttachments.clear());
      final sent = await _controller!.send(
        effectiveText,
        availablePromptTags: availableTags,
        selectedPromptTags: selectedPromptTags,
        allowedSearchSources:
            structuredSources.isEmpty ? null : structuredSources,
        resetSourceRestriction: resetSourceRestriction,
        persistSelections: _promptTagSettings.longTermEnabled,
        localOnly: localOnlyRequested,
        searchByImage: searchByImageRequested,
        attachmentPaths: attachmentRelativePaths,
      );
      if (!sent) {
        // OCR 失败等未入列场景：删除本次落盘文件防重复，恢复输入与附件供重试。
        await deleteAiAttachmentFiles(attachmentRelativePaths);
        if (mounted) {
          setState(() {
            _pendingAttachments
              ..clear()
              ..addAll(pendingSnapshot);
            if (_inputController.text.isEmpty && text.isNotEmpty) {
              _inputController.text = text;
              _saveDraft();
            }
          });
        }
      }
    } finally {
      if (mounted) {
        setState(() => _sendInFlight = false);
      } else {
        _sendInFlight = false;
      }
    }
  }

  List<_DisplayItem> _buildDisplayItems(List<AiChatMessage> messages) {
    final result = <_DisplayItem>[];
    int i = 0;
    while (i < messages.length) {
      final msg = messages[i];
      if (msg.type == AiChatMessageType.toolCall) {
        final toolName = msg.toolName!;
        final groupMsgs = <AiChatMessage>[msg];
        int j = i + 1;
        while (j < messages.length) {
          final next = messages[j];
          if (next.type == AiChatMessageType.toolResult &&
              next.toolName == toolName) {
            groupMsgs.add(next);
            j++;
            if (j < messages.length &&
                messages[j].type == AiChatMessageType.toolCall &&
                messages[j].toolName == toolName) {
              groupMsgs.add(messages[j]);
              j++;
            } else {
              break;
            }
          } else {
            break;
          }
        }
        if (groupMsgs.length >= 4) {
          result.add(_ToolGroup(toolName: toolName, messages: groupMsgs));
        } else {
          for (final m in groupMsgs) {
            result.add(_SingleItem(m));
          }
        }
        i = j;
      } else {
        result.add(_SingleItem(msg));
        i++;
      }
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_controller == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final displayItems = _buildDisplayItems(_controller!.displayMessages);
    // 15号计划：把渲染快照与真实 itemCount 暂存到字段，供 pending 落位、
    // 位置保存（末项可见判定）以及后续索引面板复用。
    _displayItems = displayItems;
    final listItemCount =
        displayItems.length + (_controller!.pendingDownload != null ? 1 : 0);
    _listItemCount = listItemCount;
    return PopScope(
      // 15号计划：索引面板打开时也先拦返回键关面板，与提示词面板一致。
      canPop: _promptPanelEntry == null && !_indexPanelVisible,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_promptPanelEntry != null) {
          _closePromptPanel();
        } else {
          _closeIndexPanel();
        }
      },
      child: Scaffold(
        key: _scaffoldKey,
        drawer: _ConversationDrawer(
          currentId: _controller!.conversationId,
          onSelect: _switchConversation,
          onNewConversation: _newConversation,
          onRenamed: _onConversationRenamed,
        ),
        appBar: AppBar(
          automaticallyImplyLeading: false,
          titleSpacing: 0,
          leading: IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => _scaffoldKey.currentState?.openDrawer(),
          ),
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: '清空对话'.tl,
                onPressed: _controller!.isLoading
                    ? null
                    : () {
                        _controller!.clear();
                      },
              ),
            ],
          ),
        ),
        body: Stack(
          children: [
            Column(
              children: [
                // 消息列表
                Expanded(
                  child: _controller!.displayMessages.isEmpty &&
                          _controller!.pendingDownload == null
                      ? _buildEmptyGuide(context)
                      // Fix B（13号计划）：pending 期间用 Opacity=0 遮住列表，
                      // 消除切 tab/切会话时的首帧闪烁。IgnorePointer 同步屏蔽
                      // 触摸命中，防止不可见时意外触发手势。
                      : IgnorePointer(
                          ignoring: _hasPendingScroll,
                          child: Opacity(
                            opacity: _hasPendingScroll ? 0.0 : 1.0,
                            child: Stack(
                              children: [
                                GestureDetector(
                                  behavior: HitTestBehavior.translucent,
                                  onTap: () => FocusScope.of(context).unfocus(),
                                  // 15号计划：换成按 index 定位的列表，
                                  // 为"恢复阅读位置 / 索引面板跳转"提供原生能力。
                                  // scrollController 仍传 _scrollController（fork 必填），
                                  // 贴底判定与自动跟随继续走像素路径。
                                  child: ScrollablePositionedList.builder(
                                    scrollController: _scrollController,
                                    itemScrollController: _itemScrollController,
                                    itemPositionsListener:
                                        _itemPositionsListener,
                                    initialScrollIndex: _initialScrollIndex,
                                    padding: const EdgeInsets.all(8),
                                    itemCount: listItemCount,
                                    itemBuilder: (context, index) {
                                      // 15号计划：itemBuilder 读快照字段而不是 build
                                      // 局部变量——ScrollablePositionedList 会在过渡帧
                                      // 用上一帧的 delegate 构建，读闭包捕获的旧 list
                                      // 可能越界。
                                      final items = _displayItems;
                                      // 如果是最后一项且有 pendingDownload，显示确认卡片
                                      if (index >= items.length) {
                                        final pending =
                                            _controller!.pendingDownload;
                                        if (pending == null) {
                                          return const SizedBox.shrink();
                                        }
                                        return _DownloadConfirmCard(
                                          pending: pending,
                                          onConfirm: (confirmed) => _controller!
                                              .confirmDownload(confirmed),
                                        );
                                      }
                                      final item = items[index];
                                      if (item is _SingleItem) {
                                        return _MessageBubble(
                                          message: item.message,
                                          streaming: identical(item.message,
                                              _controller!.streamingMessage),
                                        );
                                      } else if (item is _ToolGroup) {
                                        return _ToolGroupCard(group: item);
                                      }
                                      return const SizedBox.shrink();
                                    },
                                  ),
                                ),
                                // 15号计划：右边缘长按触发条。只放在消息列表区域内，
                                // 不覆盖输入区与右下 FAB，避免长按发送按钮/FAB 时
                                // 误开面板。translucent 让命中同时落到下层列表，
                                // 竖向拖动由列表的 drag 手势在竞技场里胜出，
                                // 因此不吞滚动；单击也照旧传给收键盘的 onTap。
                                // 页面右边缘无 endDrawer、无 tab 横滑，
                                // AppPageRoute 的侧滑返回固定在 left:0 宽 20，
                                // 与本条无冲突。
                                // 16号计划：触发条升级——四段手势回调 + 可见胶囊。
                                // GestureDetector behavior 保持 translucent，
                                // 视觉胶囊不设手势回调、不拦截命中，
                                // 竖向拖动仍由下层列表在竞技场里胜出。
                                // 17号计划修正：命中区从 20dp 扩到 36dp，
                                // 增加的 16dp 向左（屏幕内侧）延伸，
                                // 视觉索引条仍贴右边缘，命中区更宽更好打中。
                                Positioned(
                                  top: 0,
                                  bottom: 0,
                                  right: 0,
                                  width: 36,
                                  child: Semantics(
                                    label: '消息索引，长按打开',
                                    child: Stack(
                                      children: [
                                        // GestureDetector 不暴露 duration 参数；
                                        // 用 RawGestureDetector + 自定义
                                        // LongPressGestureRecognizer 把触发时间
                                        // 从默认 500ms 缩短到 200ms，手感更灵敏。
                                        RawGestureDetector(
                                          behavior: HitTestBehavior.translucent,
                                          gestures: {
                                            LongPressGestureRecognizer:
                                                GestureRecognizerFactoryWithHandlers<
                                                    LongPressGestureRecognizer>(
                                              () => LongPressGestureRecognizer(
                                                duration: const Duration(
                                                  milliseconds: 200,
                                                ),
                                                debugOwner: this,
                                              ),
                                              (LongPressGestureRecognizer
                                                  instance) {
                                                instance.onLongPressStart =
                                                    (d) {
                                                  _longPressStartGlobal =
                                                      d.globalPosition;
                                                  // 17号计划步骤 3：起点与"当前位置"
                                                  // 各存一份，前者只喂面板定位。
                                                  _dragCurrentGlobal =
                                                      d.globalPosition;
                                                  _openIndexPanel();
                                                  // 刚按下未移动时不设 _dragHoverIndex，
                                                  // 避免打开面板瞬间产生不必要的拖选高亮。
                                                  // 第一次 MoveUpdate 才开始高亮跟踪；
                                                  // 若原地松手，End 里当场算坐标。
                                                };
                                                instance.onLongPressMoveUpdate =
                                                    (d) {
                                                  _dragCurrentGlobal =
                                                      d.globalPosition;
                                                  // 用缓存，不重复 build。
                                                  final hover =
                                                      _indexFromGlobalY(
                                                    d.globalPosition.dy,
                                                    _cachedIndexEntries,
                                                  );
                                                  if (hover !=
                                                      _dragHoverIndex) {
                                                    setState(
                                                      () => _dragHoverIndex =
                                                          hover,
                                                    );
                                                  }
                                                  // 17号计划步骤 7：边缘自动滚动只在这里
                                                  // 启动/改速。手指停住后不再有回调，
                                                  // 靠 Ticker 自持续（详见 _onEdgeScrollTick）。
                                                  _updateEdgeAutoScroll();
                                                };
                                                instance.onLongPressEnd = (d) {
                                                  // 松手先停自动滚动，再读 hover：
                                                  // 保证跳转目标就是松手瞬间那一行，
                                                  // 不会被后续 tick 又改掉。
                                                  _stopEdgeAutoScroll();
                                                  final entries =
                                                      _cachedIndexEntries;
                                                  // 若有移动轨迹则用缓存的 hover index；
                                                  // 若原地松手（_dragHoverIndex==null）则
                                                  // 当场用松手坐标换算，保证一律跳转。
                                                  final idx = _dragHoverIndex ??
                                                      _indexFromGlobalY(
                                                        d.globalPosition.dy,
                                                        entries,
                                                      );
                                                  setState(() {
                                                    _dragHoverIndex = null;
                                                    _longPressStartGlobal =
                                                        null;
                                                    _dragCurrentGlobal = null;
                                                  });
                                                  if (entries.isEmpty) {
                                                    _closeIndexPanel();
                                                    return;
                                                  }
                                                  final target =
                                                      entries.firstWhere(
                                                    (e) =>
                                                        e.index ==
                                                        (idx ??
                                                            entries
                                                                .first.index),
                                                    orElse: () => entries.first,
                                                  );
                                                  // _jumpToIndexEntry 内含 _closeIndexPanel。
                                                  _jumpToIndexEntry(target);
                                                };
                                                instance.onLongPressCancel =
                                                    () {
                                                  _stopEdgeAutoScroll();
                                                  setState(() {
                                                    _dragHoverIndex = null;
                                                    _longPressStartGlobal =
                                                        null;
                                                    _dragCurrentGlobal = null;
                                                  });
                                                  _closeIndexPanel();
                                                  // 取消不跳转。
                                                };
                                              },
                                            ),
                                          },
                                        ),
                                        // 17号计划步骤 12：细胶囊 → 迷你索引条。
                                        // 不设手势回调、不拦截命中（IgnorePointer），
                                        // 命中区仍是上面那个 20dp 宽的
                                        // GestureDetector，长按照旧触发面板。
                                        IgnorePointer(
                                          child: _MiniIndexBar(
                                            itemPositions:
                                                _itemPositionsListener
                                                    .itemPositions,
                                            userIndices: _userMessageIndices(),
                                            maxTicks: _indexBarMaxTicks,
                                            faded: _indexPanelVisible,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                ),

                // 加载指示器
                if (_controller!.isLoading)
                  const Padding(
                    padding: EdgeInsets.all(8),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        SizedBox(width: 8),
                        Text('思考中...', style: TextStyle(fontSize: 12)),
                      ],
                    ),
                  ),

                // 错误提示
                if (_controller!.error != null)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: Text(
                      _controller!.error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onErrorContainer,
                        fontSize: 12,
                      ),
                    ),
                  ),

                // 输入框
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.1),
                        blurRadius: 4,
                        offset: const Offset(0, -2),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      KeyedSubtree(
                        key: _pendingTagRowKey,
                        child: _buildPendingTagRow(context),
                      ),
                      // 15轮03号计划：待发附件缩略图行。
                      _buildPendingAttachmentRow(context),
                      Row(
                        children: [
                          CompositedTransformTarget(
                            link: _promptPanelLink,
                            child: IconButton(
                              key: _promptTagButtonKey,
                              onPressed: _controller!.isLoading ||
                                      _controller!.pendingDownload != null
                                  ? null
                                  : _togglePromptPanel,
                              tooltip: '提示词标签',
                              visualDensity: VisualDensity.compact,
                              icon: Icon(
                                Icons.tag,
                                color: _promptPanelEntry != null
                                    ? Theme.of(context).colorScheme.primary
                                    : null,
                              ),
                            ),
                          ),
                          // 15轮03号计划：选图按钮。
                          IconButton(
                            onPressed: _controller!.isLoading ||
                                    _controller!.pendingDownload != null ||
                                    _sendInFlight
                                ? null
                                : _pickAttachments,
                            tooltip: '发送图片'.tl,
                            visualDensity: VisualDensity.compact,
                            icon: Icon(
                              Icons.image_outlined,
                              color: _pendingAttachments.isNotEmpty
                                  ? Theme.of(context).colorScheme.primary
                                  : null,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: TextField(
                              controller: _inputController,
                              decoration: InputDecoration(
                                hintText: _controller!.pendingDownload != null
                                    ? '请先处理下载确认'.tl
                                    : '输入消息...'.tl,
                                border: const OutlineInputBorder(),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                                isDense: true,
                              ),
                              maxLines: 3,
                              minLines: 1,
                              enabled: !_controller!.isLoading &&
                                  _controller!.pendingDownload == null,
                              onChanged: (_) => _saveDraft(),
                              onSubmitted: (_) => _send(),
                            ),
                          ),
                          const SizedBox(width: 8),
                          // 15轮07号计划：AI 回复进行中换为「停止」按钮；
                          // _sendInFlight（压缩落盘期）不显示停止（本地操作，极短）。
                          if (_controller!.isLoading && !_sendInFlight)
                            IconButton.filled(
                              icon: const Icon(Icons.stop_rounded),
                              tooltip: '停止生成',
                              onPressed: () => _controller?.stopGeneration(),
                            )
                          else
                            FilledButton(
                              onPressed: _controller!.isLoading ||
                                      _controller!.pendingDownload != null ||
                                      _sendInFlight
                                  ? null
                                  : _send,
                              child: Text('发送'.tl),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            // 15号计划：面板可见时铺一层遮罩，点击面板外区域关闭。
            // 用 opaque 而不是 translucent：translucent 会让这一下点击继续穿到
            // 下层气泡（结果卡片有 onTap 会跳详情页），"点外面关面板"变成
            // "点外面关面板并跳走"。与本文件既有提示词面板浮层（用 opaque）一致。
            // 放在 FAB 之前，使 FAB 仍在遮罩之上可点。
            if (_indexPanelVisible)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _closeIndexPanel,
                  child: const ColoredBox(color: Colors.transparent),
                ),
              ),
            Positioned(
              right: 12,
              bottom: 64,
              child: ListenableBuilder(
                listenable: AiDownloadQueue.instance,
                builder: (context, _) {
                  final count = AiDownloadQueue.instance.items.length;
                  return Badge(
                    label: count > 0 ? Text('$count') : null,
                    isLabelVisible: count > 0,
                    child: FloatingActionButton.small(
                      heroTag: 'ai_download_queue_fab',
                      elevation: 2,
                      onPressed: () => Navigator.of(context).push(
                        AppPageRoute(
                            builder: (_) => const AiDownloadListPage()),
                      ),
                      tooltip: 'AI 下载清单',
                      child: const Icon(Icons.download_outlined, size: 18),
                    ),
                  );
                },
              ),
            ),
            // 15号计划：索引面板本体，永远在最上层。
            // 条目只在面板可见时才构建；关闭时传空表，淡出那 160ms 由
            // _ConversationIndexPanel 用自己保留的 _renderEntries 快照继续渲染。
            _ConversationIndexPanel(
              visible: _indexPanelVisible,
              entries: _indexPanelVisible ? _buildIndexEntries() : const [],
              visibleIndices: _visibleIndices,
              onSelect: _jumpToIndexEntry,
              dragHoverIndex: _dragHoverIndex,
              longPressStartY: _longPressStartGlobal?.dy,
              panelScrollController: _panelScrollController,
              panelContentKey: _panelContentKey,
            ),
          ],
        ),
      ),
    );
  }
}

/// 索引面板的一条：指向消息列表里的第 [index] 项。
///
/// [index] 与 ScrollablePositionedList 的 itemCount 同口径（即 _displayItems
/// 下标），可直接交给 ItemScrollController.jumpTo/scrollTo。
class _IndexEntry {
  const _IndexEntry({
    required this.index,
    required this.preview,
    required this.type,
  });

  final int index;
  final String preview;
  final AiChatMessageType type;
}

/// 17号计划步骤 12：右边缘常驻的迷你索引条。
///
/// N 根短横线，每根对应一条用户消息；当前位置那根同时**颜色更深 + 略长 + 略厚**
/// （三个维度叠加，单独任何一个幅度都很小，靠叠加做到一眼可辨）。
///
/// 性能约束（本步最大风险）：加深位置必须随主列表滚动常驻更新，但 15 号计划
/// 刻意只在面板可见期间挂 itemPositions 监听，理由是"itemPositions 每次滚动的
/// postFrame 都更新，常驻监听会把整页 setState 抬到与滚动同频"。因此这里用
/// [ValueListenableBuilder] **只重建这一小块**，绝不退回常驻 setState —— 否则
/// 滚动时整页（消息列表、气泡、输入区）每帧重建，还会与流式输出期间
/// _onControllerUpdate 的逐 token setState 叠加，必然掉帧。
///
/// 同理每次重建的计算必须廉价：只读一次 itemPositions 取最小可见 index，
/// 再对已缓存的 userIndices 做一次二分 + 一次除法，不遍历消息、不重算 entries。
class _MiniIndexBar extends StatelessWidget {
  const _MiniIndexBar({
    required this.itemPositions,
    required this.userIndices,
    required this.maxTicks,
    required this.faded,
  });

  /// 主列表可见项 notifier。只在 builder 内读，不 addListener。
  final ValueListenable<Iterable<ItemPosition>> itemPositions;

  /// 用户消息在 _displayItems 里的下标（升序），由父 State 缓存。
  final List<int> userIndices;

  /// 横线数上限；0 = 不限制。
  final int maxTicks;

  /// 面板打开期间淡出（沿用 15/16 号计划的行为）。
  final bool faded;

  /// 普通线与当前线的视觉规格。三个维度的差都控制在"一点点"。
  static const double _tickLength = 10;
  static const double _activeTickLength = 14;
  static const double _tickThickness = 1.5;
  static const double _activeTickThickness = 2.5;

  /// 每根线占用的固定竖向槽位。取 >= _activeTickThickness，
  /// 使加深/变细时槽位高度不变、整条不会随动画上下抖动。
  static const double _slotHeight = 3;

  /// 线之间的默认间距（够密集）；条目多时按可用高度自动收紧，下限 0。
  static const double _maxGap = 5;

  static const Duration _fadeDuration = Duration(milliseconds: 160);
  static const Duration _tickAnimDuration = Duration(milliseconds: 140);

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // 空态：没有用户消息就什么都不画（命中区仍在，长按照旧能开面板）。
    if (userIndices.isEmpty) return const SizedBox.shrink();

    return AnimatedOpacity(
      opacity: faded ? 0.0 : 1.0,
      duration: _fadeDuration,
      child: Align(
        alignment: Alignment.centerRight,
        // 右端贴边（与旧胶囊同样留 2dp），长度差往内侧（左）延伸。
        child: Padding(
          padding: const EdgeInsets.only(right: 2),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final available = constraints.hasBoundedHeight
                  ? constraints.maxHeight
                  : double.infinity;
              final requested = maxTicks <= 0
                  ? userIndices.length
                  : math.min(userIndices.length, maxTicks);
              // 总高不超命中区：先按 _maxGap 算间距，放不下就收紧到 0。
              // 但槽位高度固定（_slotHeight），间距收到 0 之后仍有物理上限
              // available / _slotHeight——设置选「不限制」且会话很长时会超出：
              // 命中区高 480 时 161 根就装不下，实测 300 条用户消息溢出 420px
              // （Column 的 mainAxisSize.min 只让 Column 取子高之和，并不阻止
              // 溢出）。因此这里再收一道"装得下几根就画几根"。
              // 收紧后走的正是既有的"截断 + 百分比映射"路径，_activeTickIndex
              // 无需改：tickCount < userIndices.length 时它已按滚动进度映射。
              final fitCount = available.isFinite
                  ? (available / _slotHeight).floor()
                  : requested;
              final tickCount = math.min(requested, fitCount);
              if (tickCount <= 0) return const SizedBox.shrink();
              final gap = _resolveGap(tickCount, available);
              return ValueListenableBuilder<Iterable<ItemPosition>>(
                valueListenable: itemPositions,
                builder: (context, positions, _) {
                  final activeTick = _activeTickIndex(positions, tickCount);
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (var i = 0; i < tickCount; i++) ...[
                        if (i > 0) SizedBox(height: gap),
                        _buildTick(colorScheme, active: i == activeTick),
                      ],
                    ],
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }

  static double _resolveGap(int tickCount, double available) {
    if (tickCount <= 1 || !available.isFinite) return _maxGap;
    final slots = tickCount * _slotHeight;
    final gapRoom = (available - slots) / (tickCount - 1);
    return gapRoom.clamp(0.0, _maxGap).toDouble();
  }

  /// 当前该加深第几根线。
  ///
  /// 百分比取的是**滚动进度**（像滚动条滑块），而不是"视口顶端那条消息的序号"。
  /// 后者看似更直白，实际是错的：一屏能显示 k 条消息时，滚到最底部视口顶端也只
  /// 到第 (n-k) 条，百分比永远到不了 1.0——用户明明滑到尽头，索引条却停在 3/6。
  /// 因此分母用**可达范围** (n-1-可见跨度)，两端才都能到齐：
  /// 滚到顶 → 第一根，滚到底 → 最后一根。
  ///
  /// 未截断（用户消息数 <= 上限）时 tickCount == userIndices.length，
  /// 同一式子自然退化成 1:1 映射，不需要分支。
  ///
  /// 计算成本：两次二分 + 一次除法，不遍历消息、不重算 entries。
  int _activeTickIndex(Iterable<ItemPosition> positions, int tickCount) {
    if (tickCount <= 0) return -1;
    final userCount = userIndices.length;
    if (userCount <= 1 || positions.isEmpty) return 0;

    var topVisible = positions.first.index;
    var bottomVisible = positions.first.index;
    for (final p in positions) {
      if (p.index < topVisible) topVisible = p.index;
      if (p.index > bottomVisible) bottomVisible = p.index;
    }
    final topOrdinal = _userOrdinalAtOrBefore(topVisible);
    final bottomOrdinal = _userOrdinalAtOrBefore(bottomVisible);
    // 可见跨度（以用户消息条数计）；可达范围 = 总数-1 − 跨度。
    final visibleSpan = bottomOrdinal - topOrdinal;
    final reachable = userCount - 1 - visibleSpan;
    // 一屏装得下全部用户消息 → 没有滚动余量，固定加深第一根。
    if (reachable <= 0) return 0;
    final percent = (topOrdinal / reachable).clamp(0.0, 1.0);
    return (percent * (tickCount - 1)).round().clamp(0, tickCount - 1);
  }

  /// userIndices 里 <= [displayIndex] 的最后一个元素的序号（都比它大则取 0）。
  /// userIndices 升序，用二分，避免随滚动每帧线性扫描。
  int _userOrdinalAtOrBefore(int displayIndex) {
    var lo = 0;
    var hi = userIndices.length - 1;
    var result = 0;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (userIndices[mid] <= displayIndex) {
        result = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return result;
  }

  /// 一根线。长度/厚度/颜色三者都走 AnimatedContainer，滚动时平滑过渡不硬跳。
  /// 外层固定 _slotHeight 的槽位 + centerRight 对齐：厚度变化不挤动邻线，
  /// 长度变化只往左长。
  Widget _buildTick(ColorScheme colorScheme, {required bool active}) {
    return SizedBox(
      height: _slotHeight,
      child: Align(
        alignment: Alignment.centerRight,
        child: AnimatedContainer(
          duration: _tickAnimDuration,
          curve: Curves.easeOut,
          width: active ? _activeTickLength : _tickLength,
          height: active ? _activeTickThickness : _tickThickness,
          decoration: BoxDecoration(
            color: active
                ? colorScheme.primary
                : colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(_activeTickThickness / 2),
          ),
        ),
      ),
    );
  }
}

/// 会话消息索引面板：右侧圆角卡片浮层，长按右边缘触发。
///
/// 自身不持有可见状态（由 _AiChatPageState 管），只负责：
/// 1. AnimatedOpacity 淡入淡出，淡出结束后彻底不渲染内容（省掉隐藏时的布局）；
/// 2. 打开时把第一个高亮条目滚进面板视口（长会话打开面板不至于停在顶部）；
/// 3. 16号计划：按长按起点纵坐标定位面板顶端；拖选期间显示更深高亮+竖线。
class _ConversationIndexPanel extends StatefulWidget {
  const _ConversationIndexPanel({
    required this.visible,
    required this.entries,
    required this.visibleIndices,
    required this.onSelect,
    required this.panelScrollController,
    required this.panelContentKey,
    this.dragHoverIndex,
    this.longPressStartY,
  });

  final bool visible;
  final List<_IndexEntry> entries;
  final Set<int> visibleIndices;
  final ValueChanged<_IndexEntry> onSelect;
  // 16号计划：滚动控制器提升到父 State，供 _indexFromGlobalY 计入偏移。
  final ScrollController panelScrollController;
  // 16号计划：面板内容区 Key，供坐标换算取 RenderBox。
  final GlobalKey panelContentKey;
  // 16号计划：拖动中悬停的消息 index（null=非拖选状态）。
  final int? dragHoverIndex;
  // 16号计划：长按起始点的全局 Y（用于对齐面板顶端），null 时用默认 top:8。
  final double? longPressStartY;

  @override
  State<_ConversationIndexPanel> createState() =>
      _ConversationIndexPanelState();
}

class _ConversationIndexPanelState extends State<_ConversationIndexPanel> {
  // rowExtent 改为 static（内部+父State均可访问，避免重复常量声明）。
  static const double rowExtent = 52;
  static const Duration _fadeDuration = Duration(milliseconds: 160);

  /// 17号计划步骤 9：输入区预留高度（132 = 旧算式 116+16 的总量）。
  static const double _inputAreaReserve = 265;

  /// 面板与可用区上/下边界的留白。
  static const double _panelEdgeMargin = 8;

  /// 17号计划步骤 9：面板最大高度占可用高度的比例（用户拍板"约 60%"）。
  static const double _panelMaxHeightRatio = 0.6;

  /// 是否需要渲染面板内容。可见时立即置 true；隐藏时等淡出动画结束再置 false，
  /// 这样关闭有过渡、关闭后又不留下常驻的 ListView 布局开销。
  bool _rendered = false;

  /// 首帧透明度。面板刚进入渲染时先给 0，下一帧再升到 1，
  /// 否则 AnimatedOpacity 首次构建就等于目标值、淡入动画会被跳过。
  bool _fadedIn = false;

  /// 面板打开时缓存的 longPressStartY。
  ///
  /// 父 State 在 onLongPressEnd 里会把 _longPressStartGlobal 清成 null（同步于
  /// 跳转逻辑），导致面板在淡出的 160ms 里用 null 退化到 top:8，出现位置跳动。
  /// 这里在面板 visible false→true 时缓存一份，整个开/关周期内不再变化，
  /// 保证面板位置从打开到完全淡出始终一致。
  double? _openedAtY;

  /// 真正用于渲染的条目快照。关闭后父组件不再构建条目（传空表），但淡出动画
  /// 还要跑 160ms，直接读 widget.entries 会让面板内容在淡出途中塌成
  /// "暂无可索引的消息"。因此只在可见期间同步，淡出用最后一份快照，
  /// 淡出结束（_rendered=false）时清掉，不长期持有旧会话的条目。
  List<_IndexEntry> _renderEntries = const [];

  @override
  void didUpdateWidget(_ConversationIndexPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible) _renderEntries = widget.entries;
    if (widget.visible && !oldWidget.visible) {
      _openedAtY = widget.longPressStartY; // 打开时缓存位置，避免父State清null后位置跳变
      _rendered = true;
      _fadedIn = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !widget.visible) return;
        setState(() => _fadedIn = true);
        _revealActiveEntry();
      });
    }
  }

  @override
  void dispose() {
    // panelScrollController 已提升到父 State，生命周期由父管理，此处不 dispose。
    super.dispose();
  }

  /// 打开面板时把高亮条目滚进视口中部。行高固定（rowExtent）所以能直接算，
  /// 不需要测量。
  void _revealActiveEntry() {
    final sc = widget.panelScrollController;
    if (!sc.hasClients) return;
    final activeRow = _renderEntries
        .indexWhere((e) => widget.visibleIndices.contains(e.index));
    if (activeRow < 0) return;
    final position = sc.position;
    final target =
        activeRow * rowExtent - (position.viewportDimension - rowExtent) / 2;
    sc.jumpTo(
      target.clamp(position.minScrollExtent, position.maxScrollExtent),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_rendered) return const SizedBox.shrink();
    final colorScheme = Theme.of(context).colorScheme;
    final mediaQuery = MediaQuery.of(context);
    final safeTop = mediaQuery.padding.top;
    final bottomInset =
        mediaQuery.viewInsets.bottom + mediaQuery.padding.bottom;
    final screenHeight = mediaQuery.size.height;

    // 16号计划：面板顶端对齐到长按起点，让手指落在第一行附近。
    // 若 longPressStartY == null（普通点击打开，已被删除；此处只作兜底），
    // 退化到默认 top:8。
    //
    // 17号计划步骤 1+9：以下算式全部在 **body-Stack 坐标系** 里做。
    // 旧算式直接拿 screenHeight 减安全区当可用高度，却把结果用在 Positioned.top
    // 上——而 Positioned 的原点在 AppBar 下方，两者差了一整个 toolbar 高度，
    // 于是面板底边算出来"还在屏内"，实际已经压到输入区（用户反馈的"有点靠底"）。
    // AppBar 无 toolbarHeight/bottom 覆写，body 顶端恒为 safeTop + kToolbarHeight。
    final entries = _renderEntries;
    final bodyHeight = screenHeight - safeTop - kToolbarHeight - bottomInset;
    // 可用高度 = body 高度 − 输入区预留；下限兜住极窄视口，避免负数。
    final usableHeight = math.max(
      bodyHeight - _inputAreaReserve,
      rowExtent + _panelEdgeMargin * 2,
    );
    // 面板高度：内容全高与"可用高度 60%"取小，再兜一行。
    // 这个值同时是内容区的高度上限——ConstrainedBox 靠它把 Stack 下发的
    // 无界高度约束收成有界，_buildContent 的 listHeight 才会小于内容全高，
    // maxScrollExtent 才不再恒为 0（详见 build 返回值处的 ConstrainedBox）。
    final maxPanelHeight = usableHeight * _panelMaxHeightRatio;
    // 空态（没有可索引消息）不能按 rowExtent 兜底：空态内容是一行文案 +
    // 上下各 16 的 padding，标准字号需 49dp 已经贴着 52 的上限，字号一放大
    // 文案就折行——特大字号（1.25）实测需 74dp，被 52 压出 RenderFlex 溢出。
    // 空态没有列表、不需要可滚动余量，上限的唯一职责是"不超出可用区"，
    // 因此直接用 maxPanelHeight，让内容自己决定高度（Column 是 mainAxisSize.min）。
    final panelActualHeight = entries.isEmpty
        ? maxPanelHeight
        : math
            .min(entries.length * rowExtent, maxPanelHeight)
            .clamp(rowExtent, double.infinity)
            .toDouble();
    double top;
    if (_openedAtY != null) {
      // 用打开时缓存的坐标，而非 widget.longPressStartY（父State在松手后会清null）。
      final localY = _openedAtY! - safeTop - kToolbarHeight;
      top = localY - rowExtent / 2;
      // 下界收紧：面板底边不得越过"可用高度"下沿（即输入区上方留白处）。
      final maxTop = usableHeight - panelActualHeight - _panelEdgeMargin;
      top = top.clamp(
        _panelEdgeMargin,
        math.max(_panelEdgeMargin, maxTop),
      );
    } else {
      top = _panelEdgeMargin;
    }

    return Positioned(
      top: top,
      right: 8,
      child: IgnorePointer(
        ignoring: !widget.visible,
        child: AnimatedOpacity(
          opacity: widget.visible && _fadedIn ? 1.0 : 0.0,
          duration: _fadeDuration,
          curve: Curves.easeOut,
          onEnd: () {
            // 淡出结束后停止渲染内容；淡入结束不动（_rendered 已是 true）。
            if (!widget.visible && _rendered && mounted) {
              setState(() {
                _rendered = false;
                _renderEntries = const [];
              });
            }
          },
          // 面板自身吞掉点击，避免点在面板空白处穿到下层遮罩把面板关掉。
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {},
            child: Semantics(
              label: '消息索引面板',
              container: true,
              child: Material(
                elevation: 10,
                borderRadius: BorderRadius.circular(16),
                clipBehavior: Clip.antiAlias,
                color: colorScheme.surfaceContainer,
                // 17号计划步骤 1：面板根节点是 Positioned(top:, right:)，只给单侧
                // 定位、不给 height/bottom，RenderStack 因此下发 0..∞ 的高度约束，
                // _buildContent 的 LayoutBuilder 拿到 hasBoundedHeight == false，
                // maxHeight 退化成内容全高 → 视口高度 == 内容高度 →
                // maxScrollExtent 恒为 0，面板超出屏幕的部分被 Clip 裁掉且滚不到。
                // 这里补一层 ConstrainedBox 把无界约束收成有界：
                // 选它而不是"把上限当参数传进 _buildContent 取 min"，因为约束是
                // 真正落在布局层的，LayoutBuilder 与将来任何嵌套子树都能看到同一个
                // 上限，也保证 Material 自身不会超出可用区（传参只能管住 listHeight，
                // 日后在 Column 里加标题栏之类的兄弟节点仍会溢出）。
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: panelActualHeight),
                  child: _buildContent(context, colorScheme),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context, ColorScheme colorScheme) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 宽度取"实际可用宽度"而不是 MediaQuery.size：页面可能被放进受约束的
        // 容器（分屏、桌面窄窗、外层 SizedBox），窗口宽度不等于这里的可用宽度。
        // 最宽 200dp，窄屏按可用宽度的 62% 收缩，下限 120dp 仍能读出预览文本；
        // 可用宽度本身小于 120dp 时以可用宽度为准，避免溢出。
        final available =
            constraints.hasBoundedWidth ? constraints.maxWidth : 200.0;
        final panelWidth = (available * 0.62)
            .clamp(math.min(120.0, available), 200.0)
            .toDouble();
        // 16号计划：去掉标题栏，高度只计条目行。
        // 用 itemExtent + 定高，避免 shrinkWrap 在长会话里一次性构建全部条目。
        final entries = _renderEntries;
        final desired = entries.length * rowExtent;
        final maxHeight =
            constraints.hasBoundedHeight ? constraints.maxHeight : desired;
        final listHeight = math.min(desired, maxHeight).clamp(0.0, maxHeight);
        return SizedBox(
          width: panelWidth,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (entries.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 16,
                  ),
                  child: Text(
                    '暂无可索引的消息',
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              else
                SizedBox(
                  height: listHeight,
                  child: KeyedSubtree(
                    key: widget.panelContentKey,
                    child: ListView.builder(
                      controller: widget.panelScrollController,
                      padding: EdgeInsets.zero,
                      itemExtent: rowExtent,
                      itemCount: entries.length,
                      itemBuilder: (context, i) => _buildRow(
                        colorScheme,
                        entries[i],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildRow(ColorScheme colorScheme, _IndexEntry entry) {
    final isUser = entry.type == AiChatMessageType.user;
    // 16号计划：拖选高亮优先级高于可见高亮——拖到哪条就深色+竖线。
    final isDragHover =
        widget.dragHoverIndex != null && entry.index == widget.dragHoverIndex;
    final isVisible =
        widget.visibleIndices.contains(entry.index) && !isDragHover;
    final roleLabel = isUser ? '我' : 'AI';
    // SizedBox + clipBehavior 双保险：
    // Stack 默认 fit:loose，文本换行时 Material 会比 rowExtent 高，
    // Positioned(bottom:0) 的竖线随之溢出到上下行。
    // SizedBox 把高度钉死在 rowExtent，Stack 的 Clip.hardEdge 裁掉溢出部分。
    return SizedBox(
      height: rowExtent,
      child: MergeSemantics(
        child: Semantics(
          button: true,
          label: '$roleLabel：${entry.preview}',
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              // Positioned.fill 让 Material 撑满整行：高亮背景盖住全行，
              // 内容（图标 + 预览）竖向居中——单行预览不再贴顶留出
              // "空换行"似的下半截。
              Positioned.fill(
                child: Material(
                  color: isDragHover
                      ? colorScheme.primary.withValues(alpha: 0.28)
                      : isVisible
                          ? colorScheme.primary.withValues(alpha: 0.14)
                          : Colors.transparent,
                  child: InkWell(
                    onTap: () => widget.onSelect(entry),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: ExcludeSemantics(
                        child: Row(
                          // 默认 center：图标与文本随行高竖向居中。
                          children: [
                            Icon(
                              isUser
                                  ? Icons.person_outline
                                  : Icons.smart_toy_outlined,
                              size: 16,
                              color: (isDragHover || isVisible)
                                  ? colorScheme.primary
                                  : colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                entry.preview,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  height: 1.3,
                                  fontWeight: (isDragHover || isVisible)
                                      ? FontWeight.w600
                                      : FontWeight.normal,
                                  color: (isDragHover || isVisible)
                                      ? colorScheme.primary
                                      : colorScheme.onSurface
                                          .withValues(alpha: 0.8),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // 拖选时左侧显示 2dp 竖线，明确标识当前拖选目标。
              if (isDragHover)
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: Container(
                    width: 2,
                    decoration: BoxDecoration(
                      color: colorScheme.primary,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 渲染分组：单条消息或同名工具多次调用分组
sealed class _DisplayItem {}

class _SingleItem extends _DisplayItem {
  final AiChatMessage message;
  _SingleItem(this.message);
}

class _ToolGroup extends _DisplayItem {
  final String toolName;
  final List<AiChatMessage> messages;
  _ToolGroup({required this.toolName, required this.messages});

  int get callCount =>
      messages.where((m) => m.type == AiChatMessageType.toolCall).length;
}

bool _hasMarkdownTable(String text) =>
    RegExp(r'^\s*\|', multiLine: true).hasMatch(text);

Widget _buildSelectableUserText(
  AiChatMessage message,
  ColorScheme colorScheme,
) {
  final normalStyle = TextStyle(color: colorScheme.onPrimaryContainer);
  final names = message.promptTagNames
      .map((name) => name.replaceFirst(RegExp(r'^#'), ''))
      .where((name) => name.isNotEmpty)
      .toSet()
      .toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  if (names.isEmpty) {
    return SelectableText(message.text, style: normalStyle);
  }

  final alternatives = names.map(RegExp.escape).join('|');
  final regex = RegExp(
    '(^|$_promptTagBoundaryPattern)(#(?:$alternatives))'
    '(?=$_promptTagBoundaryPattern|\$)',
    multiLine: true,
  );
  final spans = <InlineSpan>[];
  var cursor = 0;
  for (final match in regex.allMatches(message.text)) {
    final prefixLength = match.group(1)?.length ?? 0;
    final tokenStart = match.start + prefixLength;
    if (tokenStart > cursor) {
      spans.add(TextSpan(text: message.text.substring(cursor, tokenStart)));
    }
    spans.add(
      TextSpan(
        text: message.text.substring(tokenStart, match.end),
        style: TextStyle(
          color: colorScheme.primary,
          fontWeight: FontWeight.bold,
          backgroundColor: colorScheme.primary.withValues(alpha: 0.12),
        ),
      ),
    );
    cursor = match.end;
  }
  if (cursor == 0) {
    return SelectableText(message.text, style: normalStyle);
  }
  if (cursor < message.text.length) {
    spans.add(TextSpan(text: message.text.substring(cursor)));
  }
  return SelectableText.rich(TextSpan(style: normalStyle, children: spans));
}

/// 15轮03号计划：用户气泡里的附件缩略图。文件缺失（被清理/目录改动）时
/// 显示灰底占位；点击 push 全屏预览页（Hero 过渡）。
class _AttachmentThumb extends StatelessWidget {
  const _AttachmentThumb({
    required this.relativePath,
    required this.createdAt,
  });

  final String relativePath;
  final DateTime createdAt;

  /// 同图多次发送不撞 tag：相对路径 + 消息创建时间共同构成唯一 tag。
  String get _heroTag =>
      'ai_attachment_${relativePath}_${createdAt.microsecondsSinceEpoch}';

  @override
  Widget build(BuildContext context) {
    final file = File(resolveAiAttachmentPath(relativePath));
    return GestureDetector(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => _AiAttachmentPreviewPage(
              imageProvider: FileImage(file),
              heroTag: _heroTag,
            ),
          ),
        );
      },
      child: Hero(
        tag: _heroTag,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.file(
            file,
            width: 120,
            height: 120,
            fit: BoxFit.cover,
            errorBuilder: (context, _, __) => Container(
              width: 120,
              height: 120,
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.broken_image_outlined),
                  const SizedBox(height: 4),
                  Text(
                    '图片已清理'.tl,
                    style: const TextStyle(fontSize: 11),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 15轮03号计划：附件全屏预览页。照抄 local_comic_detail_page.dart 的
/// _CoverPreviewPage（Scaffold + AppBar + Hero + PhotoView，minScale
/// `contained * 0.9`，loading/error builder 同款）。
class _AiAttachmentPreviewPage extends StatelessWidget {
  const _AiAttachmentPreviewPage({
    required this.imageProvider,
    required this.heroTag,
  });

  final ImageProvider<Object> imageProvider;
  final String heroTag;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('图片'.tl),
      ),
      body: Hero(
        tag: heroTag,
        child: PhotoView(
          minScale: PhotoViewComputedScale.contained * 0.9,
          imageProvider: imageProvider,
          filterQuality: FilterQuality.medium,
          loadingBuilder: (context, event) {
            return const ColoredBox(
              color: Colors.black,
              child: Center(child: CircularProgressIndicator()),
            );
          },
          errorBuilder: (context, error, stackTrace, retry) {
            return ColoredBox(
              color: Colors.black,
              child: Center(
                child: IconButton(
                  tooltip: '重试'.tl,
                  color: Colors.white,
                  icon: const Icon(Icons.refresh),
                  onPressed: retry,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 消息气泡
class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message, this.streaming = false});

  final AiChatMessage message;

  /// 15轮06号计划：该条是否为“流式进行中”的那条消息（决定思考块自动展开）。
  final bool streaming;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    switch (message.type) {
      case AiChatMessageType.user:
        // 本轮识别到的标签 + 本轮仍长期生效但未被再次识别的标签，合并去重后
        // 统一展示，避免长期标签发过一次就从气泡里消失。
        // 正文内联高亮（_buildSelectableUserText）仍只吃 promptTagNames：长期标签
        // 在后续消息正文里并不存在 `#标签` 字面 token。
        final tagNames = <String>[
          ...message.promptTagNames,
          ...message.activePersistentTagNames,
        ]
            .map((name) => name.replaceFirst(RegExp(r'^#'), ''))
            .where((name) => name.isNotEmpty)
            .toSet()
            .toList();
        return Align(
          alignment: Alignment.centerRight,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.all(12),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.7,
            ),
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildSelectableUserText(message, colorScheme),
                // 15轮03号计划（决策D 展示面）：附件缩略图，点击全屏预览。
                if (message.attachmentPaths.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final relative in message.attachmentPaths)
                        _AttachmentThumb(
                          relativePath: relative,
                          createdAt: message.createdAt,
                        ),
                    ],
                  ),
                ],
                if (tagNames.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      for (final name in tagNames)
                        Text(
                          '#$name',
                          style: TextStyle(
                            fontSize: 11,
                            color: colorScheme.onPrimaryContainer
                                .withValues(alpha: 0.65),
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        );

      case AiChatMessageType.assistant:
        return Align(
          alignment: Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.all(12),
            constraints: BoxConstraints(
              maxWidth: _hasMarkdownTable(message.text)
                  ? MediaQuery.of(context).size.width * 0.95
                  : MediaQuery.of(context).size.width * 0.7,
            ),
            decoration: BoxDecoration(
              color: colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // 15轮06号计划：思考块。渲染与否由设置147控制（关掉只是不渲染，
                // 内容照常接收+存档）。
                if (message.reasoningText != null &&
                    message.reasoningText!.isNotEmpty &&
                    appdata.settings[aiShowReasoningSettingIndex] == '1')
                  AiReasoningSection(
                    reasoningText: message.reasoningText!,
                    streaming: streaming,
                    hasContent: message.text.trim().isNotEmpty,
                  ),
                SelectionArea(
                  child: MarkdownBody(
                    data: message.text,
                    styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                        .copyWith(
                      p: TextStyle(
                        color: colorScheme.onSecondaryContainer,
                        fontSize: 14,
                      ),
                      strong: TextStyle(
                        color: colorScheme.onSecondaryContainer,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                      em: TextStyle(
                        color: colorScheme.onSecondaryContainer,
                        fontStyle: FontStyle.italic,
                        fontSize: 14,
                      ),
                      code: TextStyle(
                        color: colorScheme.onSecondaryContainer,
                        backgroundColor: colorScheme.surfaceContainerHighest,
                        fontFamily: 'monospace',
                        fontSize: 13,
                      ),
                      codeblockDecoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      tableBody: TextStyle(
                        color: colorScheme.onSecondaryContainer,
                        fontSize: 13,
                      ),
                      tableHead: TextStyle(
                        color: colorScheme.onSecondaryContainer,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                      tableBorder: TableBorder.all(
                        color: colorScheme.outline.withValues(alpha: 0.4),
                        width: 0.5,
                      ),
                      listBullet: TextStyle(
                        color: colorScheme.onSecondaryContainer,
                        fontSize: 14,
                      ),
                    ),
                    selectable: false,
                    softLineBreak: true,
                  ),
                ),
              ],
            ),
          ),
        );

      case AiChatMessageType.toolCall:
        return AiToolResultCard(
          toolName: message.toolName!,
          toolArgs: message.toolArgs,
          isResult: false,
        );

      case AiChatMessageType.toolResult:
        return AiToolResultCard(
          toolName: message.toolName!,
          resultText: message.text,
          resultData: message.toolData,
          isResult: true,
        );

      case AiChatMessageType.error:
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colorScheme.errorContainer,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(Icons.error_outline, color: colorScheme.onErrorContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message.text,
                  style: TextStyle(color: colorScheme.onErrorContainer),
                ),
              ),
            ],
          ),
        );

      case AiChatMessageType.resultList:
        return AiResultListEntryCard(message: message);

      default:
        return const SizedBox.shrink();
    }
  }
}

/// 15轮06号计划：assistant 气泡内的思考过程折叠块。
///
/// 折叠状态机（_userChoice == null 时全自动）：
/// - 自动值 = streaming && !hasContent：流式思考期展开；正文首字到达那一帧
///   hasContent 翻 true → 自动值变 false，即“思考完自动折叠”——不需要显式
///   翻转状态，也不在流式期间反复切换（性能护栏：折叠只在 content 首字
///   到达的同一帧发生一次，此时正文尚短，高度突变被贴底跟随的 200dp 容差
///   + 该次 notify 触发的 animateTo 吸收）。
/// - 用户点击后 _userChoice 接管，自动逻辑不再覆盖（流式中手动展开/收起
///   都被尊重）。
/// - 列表 item 滚远回收后 State 重建，_userChoice 归 null（历史消息
///   streaming=false → 默认折叠），与 _ToolGroupCardState._expanded 现状一致。
///
/// 公开类而非私有：本文件其余折叠卡（AiToolResultCard）同为公开，且
/// widget 测试需直接泵该 widget（见 test/ai_reasoning_section_test.dart）。
class AiReasoningSection extends StatefulWidget {
  const AiReasoningSection({
    super.key,
    required this.reasoningText,
    required this.streaming,
    required this.hasContent,
  });

  final String reasoningText;
  final bool streaming;
  final bool hasContent;

  @override
  State<AiReasoningSection> createState() => _AiReasoningSectionState();
}

class _AiReasoningSectionState extends State<AiReasoningSection> {
  bool? _userChoice;

  bool get _expanded => _userChoice ?? (widget.streaming && !widget.hasContent);

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final dimColor = colorScheme.onSecondaryContainer.withValues(alpha: 0.6);
    final thinkingLive = widget.streaming && !widget.hasContent;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 紧凑标题行：16px chevron（用户要求“展开按钮不用很大”）+ 小字文案，
        // 整行可点切换。
        InkWell(
          onTap: () => setState(() => _userChoice = !_expanded),
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _expanded ? Icons.expand_less : Icons.chevron_right,
                  size: 16,
                  color: dimColor,
                ),
                const SizedBox(width: 2),
                Text(
                  thinkingLive ? '思考中…' : '思考过程',
                  style: TextStyle(fontSize: 11, color: dimColor),
                ),
                if (thinkingLive) ...[
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(
                        strokeWidth: 1.5, color: dimColor),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (_expanded)
          Padding(
            padding: const EdgeInsets.only(left: 18, top: 2, bottom: 6),
            // 点击折叠 + 长按自由选择共存方案：SelectableText.onTap 只在
            // “无拖动的单击抬起”时触发（→ 收起）；长按走其自带的选词 +
            // 选择柄拖拽（与用户消息 _buildSelectableUserText 的
            // SelectableText 同款自由选择体验）；桌面端鼠标按下+拖动是
            // 拖选（不触发 onTap），单击收起。
            child: SelectableText(
              widget.reasoningText,
              onTap: () => setState(() => _userChoice = false),
              style: TextStyle(fontSize: 12, height: 1.4, color: dimColor),
            ),
          ),
      ],
    );
  }
}

/// 同名工具多次调用折叠卡片
class _ToolGroupCard extends StatefulWidget {
  const _ToolGroupCard({required this.group});
  final _ToolGroup group;

  @override
  State<_ToolGroupCard> createState() => _ToolGroupCardState();
}

class _ToolGroupCardState extends State<_ToolGroupCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final group = widget.group;
    final callCount = group.callCount;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 2),
      color: colorScheme.surfaceContainerHighest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            leading: Icon(Icons.check_circle_outline,
                size: 20, color: colorScheme.primary),
            title: Text(
              '${group.toolName}  ×$callCount',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
            ),
            subtitle: Text(
              '已完成 $callCount 次调用',
              style: const TextStyle(fontSize: 11),
            ),
            trailing: IconButton(
              icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                  size: 20),
              padding: EdgeInsets.zero,
              onPressed: () => setState(() => _expanded = !_expanded),
            ),
          ),
          if (_expanded) ...[
            const Divider(height: 1),
            ...group.messages.map((msg) => Padding(
                  key: ValueKey(msg.hashCode),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: AiToolResultCard(
                    toolName: msg.toolName ?? group.toolName,
                    toolArgs: msg.toolArgs,
                    resultText: msg.type == AiChatMessageType.toolResult
                        ? msg.text
                        : null,
                    resultData: msg.type == AiChatMessageType.toolResult
                        ? msg.toolData
                        : null,
                    isResult: msg.type == AiChatMessageType.toolResult,
                  ),
                )),
          ],
        ],
      ),
    );
  }
}

/// 工具调用/结果卡片
class AiToolResultCard extends StatefulWidget {
  const AiToolResultCard({
    super.key,
    required this.toolName,
    this.toolArgs,
    this.resultText,
    this.resultData,
    required this.isResult,
  });

  final String toolName;
  final Map<String, dynamic>? toolArgs;
  final String? resultText;
  final Object? resultData;
  final bool isResult;

  @override
  State<AiToolResultCard> createState() => _ToolCardState();
}

class _ToolCardState extends State<AiToolResultCard> {
  bool _expanded = false;

  bool _hasItems(Object? data) {
    return AiResultItem.decodeToolData(data).items.isNotEmpty;
  }

  int _itemCount(Object? data) {
    return AiResultItem.decodeToolData(data).items.length;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 2),
      color: colorScheme.surfaceContainerHighest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            leading: Icon(
              widget.isResult ? Icons.check_circle_outline : Icons.build,
              size: 20,
              color: colorScheme.onSurfaceVariant,
            ),
            title: Text(
              widget.toolName,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
            subtitle: widget.isResult
                ? Text(widget.resultText ?? '',
                    style: const TextStyle(fontSize: 11))
                : null,
            trailing: IconButton(
              icon: Icon(
                _expanded ? Icons.expand_less : Icons.expand_more,
                size: 20,
              ),
              onPressed: () => setState(() => _expanded = !_expanded),
            ),
          ),
          if (widget.isResult && _hasItems(widget.resultData)) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () {
                    final items =
                        AiResultItem.decodeToolData(widget.resultData).items;
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => AiItemListPage(
                          title: '工具结果',
                          items: items,
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.list_alt_outlined, size: 14),
                  label: Text('查看 ${_itemCount(widget.resultData)} 条原始结果'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ),
            ),
          ],
          if (_expanded) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: colorScheme.surface,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  _formatJson(
                      widget.isResult ? widget.resultData : widget.toolArgs),
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _formatJson(Object? obj) {
    try {
      return const JsonEncoder.withIndent('  ').convert(obj ?? {});
    } catch (_) {
      return obj?.toString() ?? '';
    }
  }
}

/// 结果清单入口卡片
class AiResultListEntryCard extends StatelessWidget {
  const AiResultListEntryCard({super.key, required this.message});

  final AiChatMessage message;

  @override
  Widget build(BuildContext context) {
    final report = AiResultItem.decodeToolData(message.toolData);
    final items = report.items;
    if (items.isEmpty) {
      final colorScheme = Theme.of(context).colorScheme;
      return Card(
        margin: const EdgeInsets.symmetric(vertical: 4),
        color: colorScheme.secondaryContainer,
        child: ListTile(
          leading:
              Icon(Icons.list_alt, color: colorScheme.onSecondaryContainer),
          title: const Text('清单结果暂不可读取'),
          subtitle: const Text('没有可展示的结果'),
          onTap: null,
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _CompactResultCardRow(items: items),
        if (report.discardedCount > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${report.discardedCount} 条结果无法读取',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 结果卡片栏：带封面图的横向可滚动卡片栏，点击单卡进详情页，
/// 末尾"查看全部"入口进 [AiItemListPage] 全屏清单页。
/// 不论 [items] 条数多少均使用同一渲染路径，保持展示形态统一。
class _CompactResultCardRow extends StatelessWidget {
  const _CompactResultCardRow({required this.items});

  final List<AiResultItem> items;

  static const _cardWidth = 108.0;
  static const _coverHeight = 132.0;

  void _openDetail(BuildContext context, AiResultItem item) {
    Widget page;
    switch (item.source) {
      case aiSourcePicacg:
        page = PicacgComicPageV2(item.id);
      case aiSourceJm:
        page = JmComicPageV2(item.id);
      case aiSourceNhentai:
        page = NhentaiComicPageV2(item.id);
      case aiSourceEhentai:
        page = EhentaiComicPageV2(item.id);
      default:
        _openList(context);
        return;
    }
    Navigator.of(context).push(AppPageRoute(builder: (_) => page));
  }

  void _openList(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => AiItemListPage(title: '工具结果', items: items),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      color: colorScheme.secondaryContainer,
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: _coverHeight + 48,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(8),
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final item = items[index];
                return _CompactResultCard(
                  item: item,
                  width: _cardWidth,
                  coverHeight: _coverHeight,
                  onTap: () => _openDetail(context, item),
                );
              },
            ),
          ),
          InkWell(
            onTap: () => _openList(context),
            child: Container(
              color: colorScheme.primaryContainer,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Icon(Icons.list_alt,
                      size: 20, color: colorScheme.onPrimaryContainer),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '共 ${items.length} 条结果，查看全部',
                      style: TextStyle(
                        color: colorScheme.onPrimaryContainer,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Icon(Icons.chevron_right,
                      color: colorScheme.onPrimaryContainer),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 卡片栏内单张卡片：封面图 + 限定行数标题。
class _CompactResultCard extends StatelessWidget {
  const _CompactResultCard({
    required this.item,
    required this.width,
    required this.coverHeight,
    required this.onTap,
  });

  final AiResultItem item;
  final double width;
  final double coverHeight;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: item.coverUrl.isEmpty
                  ? SizedBox(
                      width: width,
                      height: coverHeight,
                      child: const Icon(Icons.image_not_supported_outlined),
                    )
                  : Image.network(
                      item.coverUrl,
                      width: width,
                      height: coverHeight,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => SizedBox(
                        width: width,
                        height: coverHeight,
                        child: const Icon(Icons.image_not_supported_outlined),
                      ),
                    ),
            ),
            const SizedBox(height: 4),
            Text(
              item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

/// 下载确认卡片
class _DownloadConfirmCard extends StatelessWidget {
  const _DownloadConfirmCard({
    required this.pending,
    required this.onConfirm,
  });

  final PendingDownload pending;
  final void Function(bool) onConfirm;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final title = pending.title?.toString() ?? '未知漫画';
    final source = pending.source;
    final comicId = pending.comicId;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      color: colorScheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.download_outlined,
                  color: colorScheme.onTertiaryContainer,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '确认下载'.tl,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onTertiaryContainer,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '漫画：$title',
              style: TextStyle(color: colorScheme.onTertiaryContainer),
            ),
            Text(
              '来源：$source，ID：$comicId',
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onTertiaryContainer.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => onConfirm(false),
                  child: Text('取消'.tl),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => onConfirm(true),
                  child: Text('确认下载'.tl),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 会话侧栏抽屉
class _ConversationDrawer extends StatefulWidget {
  final String? currentId;
  final Future<void> Function(AiConversationMeta) onSelect;
  final VoidCallback onNewConversation;
  final void Function(String id, String newTitle) onRenamed;

  const _ConversationDrawer({
    required this.currentId,
    required this.onSelect,
    required this.onNewConversation,
    required this.onRenamed,
  });

  @override
  State<_ConversationDrawer> createState() => _ConversationDrawerState();
}

class _ConversationDrawerState extends State<_ConversationDrawer> {
  Future<List<AiConversationMeta>>? _indexFuture;

  /// 15轮06号计划：当前 provider 的余额。Scaffold 的 drawer 子树只在打开时
  /// inflate、关闭即 dispose，所以放 initState 天然满足“每次打开抽屉自动
  /// 刷新”，不需要 Scaffold.onDrawerChanged。
  Future<AiBalanceResult>? _balanceFuture;

  @override
  void initState() {
    super.initState();
    _indexFuture = AiConversationStore.loadIndex();
    _balanceFuture = AiBalanceClient.fetch();
    // 41号计划：订阅注册表的 loading 广播，使某会话进入/退出后台 AI 处理时，
    // 侧栏对应行的 trailing 能够重新渲染，而不需要等待下一次手动 _refresh()。
    AiConversationRegistry.instance.addListener(_onRegistryChanged);
  }

  @override
  void dispose() {
    AiConversationRegistry.instance.removeListener(_onRegistryChanged);
    super.dispose();
  }

  void _onRegistryChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _refresh() {
    setState(() => _indexFuture = AiConversationStore.loadIndex());
  }

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: Column(
        children: [
          SafeArea(
            bottom: false,
            child: Container(
              color: Theme.of(context).colorScheme.primaryContainer,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              width: double.infinity,
              child: Text(
                '历史会话',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.add),
            title: const Text('新建会话'),
            // 15轮06号计划：当前 provider 余额。不支持余额查询的服务商整个
            // 不显示（不占位、不报错）；只有 key 错/网络失败才用红字提示。
            trailing: FutureBuilder<AiBalanceResult>(
              future: _balanceFuture,
              builder: (context, snapshot) {
                final theme = Theme.of(context);
                final colorScheme = theme.colorScheme;
                // 字号 = 标题（bodyLarge，默认 16sp）的 2/3 ≈ 10.7sp。按主题
                // 基准算而非写死，避免用户调系统字号后比例失衡。
                final baseSize = theme.textTheme.bodyLarge?.fontSize ?? 16;
                final style = theme.textTheme.bodyLarge?.copyWith(
                  fontSize: baseSize * 2 / 3,
                  color: colorScheme.onSurfaceVariant,
                );
                if (snapshot.connectionState != ConnectionState.done) {
                  return SizedBox(
                    width: baseSize * 2 / 3,
                    height: baseSize * 2 / 3,
                    child: const CircularProgressIndicator(strokeWidth: 1.5),
                  );
                }
                final result = snapshot.data;
                if (result == null ||
                    result.status == AiBalanceStatus.unsupported) {
                  return const SizedBox.shrink();
                }
                if (result.status == AiBalanceStatus.error) {
                  return Text(
                    result.message ?? '余额获取失败',
                    style: style?.copyWith(color: colorScheme.error),
                  );
                }
                return Text(result.display, style: style);
              },
            ),
            onTap: () {
              Navigator.pop(context);
              widget.onNewConversation();
            },
          ),
          const Divider(),
          Expanded(
            child: FutureBuilder<List<AiConversationMeta>>(
              future: _indexFuture,
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final list = snapshot.data!;
                if (list.isEmpty) {
                  return const Center(child: Text('暂无历史会话'));
                }
                return ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (context, index) {
                    final meta = list[index];
                    final isCurrent = meta.id == widget.currentId;
                    final isLoading = AiConversationRegistry.instance.loadingIds
                        .contains(meta.id);
                    return ListTile(
                      selected: isCurrent,
                      title: Text(
                        meta.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(_formatTime(meta.updatedAt)),
                      // 41号计划：该会话正在后台 loading 时，用转圈指示器替代
                      // 三点菜单按钮，让用户在侧栏列表层面看到哪个会话仍在跑；
                      // 转圈态下不响应菜单点击（没有"取消菜单"这个操作的意义，
                      // 且此时菜单里的"重命名/删除"对一个正在写入的会话执行
                      // 语义不明确，直接隐藏交互比允许误触更安全）。
                      trailing: isLoading
                          ? const Padding(
                              padding: EdgeInsets.all(8),
                              child: SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            )
                          : Builder(
                              builder: (buttonContext) => IconButton(
                                icon: const Icon(Icons.more_vert),
                                tooltip: '更多操作',
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                  minWidth: 36,
                                  minHeight: 36,
                                ),
                                onPressed: () =>
                                    _showConversationMenu(buttonContext, meta),
                              ),
                            ),
                      onTap: () {
                        if (!isCurrent) {
                          Navigator.pop(context);
                          widget.onSelect(meta);
                        }
                      },
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 三个点菜单：定位在按钮附近弹出，含"重命名"、"删除"两项。
  Future<void> _showConversationMenu(
      BuildContext context, AiConversationMeta meta) async {
    final buttonBox = context.findRenderObject() as RenderBox?;
    final overlayBox = Overlay.of(context, rootOverlay: true)
        .context
        .findRenderObject() as RenderBox?;
    RelativeRect position;
    if (buttonBox != null && overlayBox != null) {
      final topLeft =
          buttonBox.localToGlobal(Offset.zero, ancestor: overlayBox);
      final bottomRight = buttonBox.localToGlobal(
        buttonBox.size.bottomRight(Offset.zero),
        ancestor: overlayBox,
      );
      position = RelativeRect.fromRect(
        Rect.fromPoints(topLeft, bottomRight),
        Offset.zero & overlayBox.size,
      );
    } else {
      position = const RelativeRect.fromLTRB(0, 0, 0, 0);
    }

    final action = await showMenu<String>(
      context: context,
      position: position,
      useRootNavigator: true,
      items: const [
        PopupMenuItem(value: 'rename', child: Text('重命名')),
        PopupMenuItem(value: 'delete', child: Text('删除')),
      ],
    );
    if (!context.mounted) return;
    if (action == 'rename') {
      await _renameConversation(context, meta);
    } else if (action == 'delete') {
      await _confirmDelete(context, meta);
    }
  }

  /// 弹出输入框对话框重命名会话，确认后持久化并回调通知外层同步活跃 controller。
  Future<void> _renameConversation(
      BuildContext context, AiConversationMeta meta) async {
    final controller = TextEditingController(text: meta.title);
    final newTitle = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名会话'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 50,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (newTitle == null || newTitle.isEmpty) return;
    await AiConversationStore.renameConversation(meta.id, newTitle);
    widget.onRenamed(meta.id, newTitle);
    _refresh();
  }

  Future<void> _confirmDelete(
      BuildContext context, AiConversationMeta meta) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除会话'),
        content: Text('确定删除「${meta.title}」？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await AiConversationStore.delete(meta.id);
      // 33号计划：会话被用户显式永久删除时，同步从全局注册表移除并真正
      // dispose 对应的 controller（若曾被缓存），避免残留一个不会再被
      // 访问、但仍占内存的对象。放在 UI 层而非 AiConversationStore 内部，
      // 避免 ai_conversation_store.dart ⇄ ai_conversation.dart 循环 import
      // （ai_conversation.dart 已 import ai_conversation_store.dart）。
      //
      // 例外：若删除的正是当前页面持有的会话（widget.currentId == meta.id），
      // 不在此处 dispose——_controller 字段仍指向它，页面还在用它渲染消息
      // 列表/响应用户操作；立即 dispose 会导致后续任何 UI 交互命中
      // ChangeNotifier 的 disposed-assert。调用方（AiChatPage）在
      // onSelect/新建会话时才会真正切走该 controller，届时它已不在注册表
      // 缓存中（本分支跳过了 remove），后续切换不会再复用到已删除的会话。
      if (meta.id != widget.currentId) {
        AiConversationRegistry.instance.remove(meta.id);
      }
      _refresh();
    }
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
    if (diff.inHours < 24) return '${diff.inHours}小时前';
    if (diff.inDays < 30) return '${diff.inDays}天前';
    if (diff.inDays < 365) return '${(diff.inDays / 30).floor()}个月前';
    return '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')}';
  }
}

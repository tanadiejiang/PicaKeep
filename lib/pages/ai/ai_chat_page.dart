import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:picakeep/foundation/ai/ai_conversation.dart';
import 'package:picakeep/foundation/ai/ai_conversation_store.dart';
import 'package:picakeep/foundation/ai/ai_download_queue.dart';
import 'package:picakeep/foundation/ai/ai_prompt_tags.dart';
import 'package:picakeep/foundation/ai/ai_result_item.dart';
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

class AiChatPage extends StatefulWidget {
  const AiChatPage({super.key});

  @override
  State<AiChatPage> createState() => _AiChatPageState();
}

class _AiChatPageState extends State<AiChatPage>
    with AutomaticKeepAliveClientMixin {
  // 按会话 id 缓存的输入草稿。AiConversationController.create() 每次都是
  // 全新实例（从磁盘反序列化的静态工厂，无全局单例/注册表复用），
  // 草稿不能挂在 controller 上，只能挂在 State 的类级 static 字段上。
  static final Map<String, String> _draftsByConversationId = {};

  // 12号计划：按会话 id 缓存阅读位置（会话 id → offset）。
  // 与 _draftsByConversationId 同一层级，用 static 保证跨 State 重建存活。
  // 13号计划：语义扩展——dispose()（切 tab）也写入位置，_loadController() 也读取恢复，
  // 切 tab 回来与页内切会话走同一条"有记忆位置就恢复，无则到底部"路径。
  static final Map<String, double> _scrollOffsetByConversationId = {};

  @override
  bool get wantKeepAlive => true;

  AiConversationController? _controller;
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  late final TextEditingController _inputController;
  late final ScrollController _scrollController;
  final LayerLink _promptPanelLink = LayerLink();
  final GlobalKey _promptTagButtonKey = GlobalKey();
  final GlobalKey _pendingTagRowKey = GlobalKey();
  OverlayEntry? _promptPanelEntry;
  bool _resetSourceRestriction = false;

  // 12号计划（方案三）：ListView.builder 的 maxScrollExtent 是随 item 逐帧
  // 构建才增长的估算值，单次 postFrame 的 jumpTo 常常落在"当时的假底部"。
  // 用一个 pending 标志把"该滚到哪"记下来，postFrame 与 _onControllerUpdate
  // 都去调 _applyPendingScroll()，落位成功即清标志（否则用户手动往上翻历史
  // 会被后续 controller 更新强制弹回）。
  bool _pendingScrollToBottom = false;
  double? _pendingScrollOffset;
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

  /// Finding 1 修复：_scrollOffsetByConversationId 里存此哨兵表示"离开时贴底"。
  /// 恢复时走 _scrollToBottomAfterFrame()，跟到最新底部，不受后台新消息影响。
  static const double _atBottomSentinel = -1.0;

  // 结构化选中态：面板 chip 点选后写入这些集合，不再写入 _inputController 文本。
  // 发送时与 _inputController 文本的正则识别结果合并，手动在输入框里打 #标签名 仍有效。
  final Set<String> _selectedTagChips = {}; // 普通标签名，不含 #
  final Set<String> _selectedSourceChips =
      {}; // source 值（picacg/jm/ehentai/nhentai）
  bool _selectedLocalOnly = false;
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
    // 12号计划：必须在 await 之前读 offset——await 之后 setState 会把 ListView
    // 换成新会话的内容，此时 _scrollController.offset 已不属于旧会话。
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
  /// 12号计划：改为置 pending 标志 + 逐帧收敛，首帧 ListView 未完成懒加载布局
  /// （maxScrollExtent 仍为 0 或仍是偏小的估算值）时不会静默跳过。
  void _scrollToBottomAfterFrame() {
    _pendingScrollToBottom = true;
    _pendingScrollOffset = null;
    _resetPendingScrollCounters();
    _schedulePendingScroll();
  }

  /// 恢复到某个具体 offset（用于页内切回曾经翻过历史的会话）。
  void _scrollToOffsetAfterFrame(double offset) {
    _pendingScrollToBottom = false;
    _pendingScrollOffset = offset;
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
    final saved = id == null ? null : _scrollOffsetByConversationId[id];
    if (saved == null || saved == _atBottomSentinel) {
      _scrollToBottomAfterFrame();
    } else {
      _scrollToOffsetAfterFrame(saved);
    }
  }

  /// 保存当前会话的阅读位置。只在 ListView 已 attach 时写入——未 attach 时
  /// offset 不可读，若兜底写 0 会把有效位置覆盖成"顶部"。
  ///
  /// Finding 1 修复：若离开时已贴底（距底 ≤ 200dp），存哨兵 _atBottomSentinel
  /// 而非绝对像素。恢复时哨兵走 _scrollToBottomAfterFrame，保证后台继续产出的
  /// 新消息仍能被跟随（原来存绝对像素导致 nearBottom 判定永远为假）。
  void _saveScrollOffset() {
    final id = _controller?.conversationId;
    if (id == null) return;
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    final nearBottom = pos.maxScrollExtent - pos.pixels <= 200;
    _scrollOffsetByConversationId[id] =
        nearBottom ? _atBottomSentinel : pos.pixels;
  }

  bool get _hasPendingScroll =>
      _pendingScrollToBottom || _pendingScrollOffset != null;

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
    // ListView 还没 attach（controller 刚 setState / 空会话只显示引导页）：
    // 标志保留，等下一帧或下一次 _onControllerUpdate 触发的 _schedulePendingScroll。
    if (!_scrollController.hasClients) {
      _waitForPendingScrollTarget();
      return;
    }
    final pos = _scrollController.position;
    final maxExtent = pos.maxScrollExtent;
    final target = _pendingScrollToBottom
        ? maxExtent
        : _pendingScrollOffset!.clamp(0.0, maxExtent);
    if (_scrollController.offset != target) {
      _scrollController.jumpTo(target);
    }
    // maxExtent 仍为 0：列表尚未渲染出内容（消息还没进 ListView），同样等下一帧
    // 或下一次 _onControllerUpdate，不消耗收敛预算、不判定失败。
    if (maxExtent <= 0) {
      _waitForPendingScrollTarget();
      return;
    }
    _pendingScrollFrames++;
    final extentSettled = _lastPendingScrollExtent == maxExtent;
    // Finding 2 修复：到底部时还需确认 offset 真正贴底（防止 extentSettled 在
    // content 仍增长时偶发为 true 而提前清标志）。
    final effectivelyAtTarget = _pendingScrollToBottom
        ? (maxExtent - _scrollController.offset <= 200)
        : (_pendingScrollOffset! <= maxExtent);
    final reachedTarget = _pendingScrollToBottom
        ? (extentSettled && effectivelyAtTarget)
        : effectivelyAtTarget;
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

  void _clearPendingScroll() {
    _pendingScrollToBottom = false;
    _pendingScrollOffset = null;
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
        _selectedLocalOnly;
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
          if (persistentTagNames.isNotEmpty ||
              persistentSources.isNotEmpty ||
              persistentLocalOnly) ...[
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
                  const Text(
                    '当前会话长期状态',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
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
    // attached（ListView 尚未 unmount），_saveScrollOffset() 能正确读到 offset。
    // dispose() 时 ScrollController 已经 detached，读不到位置，因此挪到这里。
    _saveScrollOffset();
    super.deactivate();
  }

  @override
  void dispose() {
    _clearPromptPanelState();
    _promptTagSettings.removeListener(_onPromptTagSettingsUpdate);
    // 下面只摘除监听、不 dispose controller：否则若该轮 _runLoop() 仍在跑，
    // 之后的 notifyListeners 会命中 ChangeNotifier 的 disposed-assert，
    // 导致该轮对话被中断/丢失。
    _controller?.removeListener(_onControllerUpdate);
    _inputController.dispose();
    _scrollController.dispose();
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

  Future<void> _send() async {
    final text = _inputController.text.trim();
    final hasPendingSelection = _selectedTagChips.isNotEmpty ||
        _selectedSourceChips.isNotEmpty ||
        _selectedLocalOnly;
    if (text.isEmpty && !hasPendingSelection) return;
    // initState 中的初始化是异步的；发送前等待同一个 pending future，避免用户
    // 刚进入页面就发送时读到空标签列表或错误的长期生效开关。
    await _promptTagSettings.initialize();
    if (!mounted || _controller == null) return;
    final resetSourceRestriction = _resetSourceRestriction;
    // 结构化选中集合：面板点选的普通标签/来源/本地限定，与手输文本里的 #标签名
    // 并行合并，由 AiConversationController.send() 内部统一去重（结构化选中 ∪ 文本识别）。
    final structuredSources = Set<String>.from(_selectedSourceChips);
    final localOnlyRequested = _selectedLocalOnly;
    final availableTags = _promptTagSettings.promptTags;
    final selectedPromptTags = availableTags
        .where((tag) => _selectedTagChips.contains(tag.name))
        .toList();
    // send() 内部对空文本会直接 return；仅选中 chip、未打任何正文时用桥接语句
    // 代替空字符串，避免"点了标签但什么都没发生"。
    final effectiveText =
        text.isEmpty && hasPendingSelection ? aiPromptTagOnlyUserBridge : text;
    _clearPromptPanelState();
    _inputController.clear();
    _draftsByConversationId.remove(_controller?.conversationId ?? '');
    await _controller!.send(
      effectiveText,
      availablePromptTags: availableTags,
      selectedPromptTags: selectedPromptTags,
      allowedSearchSources:
          structuredSources.isEmpty ? null : structuredSources,
      resetSourceRestriction: resetSourceRestriction,
      persistSelections: _promptTagSettings.longTermEnabled,
      localOnly: localOnlyRequested,
    );
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
    return PopScope(
      canPop: _promptPanelEntry == null,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _closePromptPanel();
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
                            child: GestureDetector(
                              behavior: HitTestBehavior.translucent,
                              onTap: () => FocusScope.of(context).unfocus(),
                              child: ListView.builder(
                                controller: _scrollController,
                                padding: const EdgeInsets.all(8),
                                itemCount: displayItems.length +
                                    (_controller!.pendingDownload != null
                                        ? 1
                                        : 0),
                                itemBuilder: (context, index) {
                                  // 如果是最后一项且有 pendingDownload，显示确认卡片
                                  if (index == displayItems.length &&
                                      _controller!.pendingDownload != null) {
                                    return _DownloadConfirmCard(
                                      pending: _controller!.pendingDownload!,
                                      onConfirm: (confirmed) => _controller!
                                          .confirmDownload(confirmed),
                                    );
                                  }
                                  final item = displayItems[index];
                                  if (item is _SingleItem) {
                                    return _MessageBubble(
                                        message: item.message);
                                  } else if (item is _ToolGroup) {
                                    return _ToolGroupCard(group: item);
                                  }
                                  return const SizedBox.shrink();
                                },
                              ),
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
                          FilledButton(
                            onPressed: _controller!.isLoading ||
                                    _controller!.pendingDownload != null
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
          ],
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

/// 消息气泡
class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final AiChatMessage message;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    switch (message.type) {
      case AiChatMessageType.user:
        final tagNames = message.promptTagNames
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
            child: SelectionArea(
              child: MarkdownBody(
                data: message.text,
                styleSheet:
                    MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
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

  @override
  void initState() {
    super.initState();
    _indexFuture = AiConversationStore.loadIndex();
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

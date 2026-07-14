import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/ai/ai_capabilities.dart';
import 'package:picakeep/foundation/ai/ai_conversation_store.dart';
import 'package:picakeep/foundation/ai/ai_prompt_tags.dart';
import 'package:picakeep/foundation/ai/ai_settings.dart';
import 'package:picakeep/foundation/ai/ai_sources.dart';
import 'package:picakeep/foundation/ai/ai_tool.dart';
import 'package:picakeep/foundation/ai/llm_client.dart';

/// AI 聊天消息类型
enum AiChatMessageType {
  user,
  assistant,
  toolCall,
  toolResult,
  resultList,
  error,
  system,
}

/// AI 聊天消息（用于 UI 展示）
class AiChatMessage {
  final AiChatMessageType type;
  final String text;
  final String? toolName;
  final Map<String, dynamic>? toolArgs;
  final Object? toolData;
  final DateTime createdAt;

  /// 发送该条用户消息时识别出的普通/来源标签名快照（不带 `#`）。
  final List<String> promptTagNames;

  AiChatMessage({
    required this.type,
    required this.text,
    this.toolName,
    this.toolArgs,
    this.toolData,
    Iterable<String> promptTagNames = const <String>[],
    DateTime? createdAt,
  })  : promptTagNames = List<String>.unmodifiable(
          promptTagNames
              .map(_normalizePromptTagName)
              .where((name) => name.isNotEmpty),
        ),
        createdAt = createdAt ?? DateTime.now();

  AiChatMessage.user(
    this.text, {
    Iterable<String> promptTagNames = const <String>[],
  })  : type = AiChatMessageType.user,
        toolName = null,
        toolArgs = null,
        toolData = null,
        promptTagNames = List<String>.unmodifiable(
          promptTagNames
              .map(_normalizePromptTagName)
              .where((name) => name.isNotEmpty),
        ),
        createdAt = DateTime.now();

  AiChatMessage.assistant(this.text)
      : type = AiChatMessageType.assistant,
        toolName = null,
        toolArgs = null,
        toolData = null,
        promptTagNames = const <String>[],
        createdAt = DateTime.now();

  AiChatMessage.toolCall({
    required this.toolName,
    required this.toolArgs,
  })  : type = AiChatMessageType.toolCall,
        text = '正在调用工具：$toolName',
        toolData = null,
        promptTagNames = const <String>[],
        createdAt = DateTime.now();

  AiChatMessage.toolResult({
    required this.toolName,
    required bool ok,
    Object? data,
    String? message,
  })  : type = AiChatMessageType.toolResult,
        text = ok ? (message ?? '工具执行成功') : (message ?? '工具执行失败'),
        toolArgs = null,
        toolData = data,
        promptTagNames = const <String>[],
        createdAt = DateTime.now();

  AiChatMessage.resultList({required List<Map<String, dynamic>> items})
      : type = AiChatMessageType.resultList,
        text = '共 ${items.length} 条结果',
        toolName = null,
        toolArgs = null,
        toolData = {'items': items},
        promptTagNames = const <String>[],
        createdAt = DateTime.now();

  AiChatMessage.error(this.text)
      : type = AiChatMessageType.error,
        toolName = null,
        toolArgs = null,
        toolData = null,
        promptTagNames = const <String>[],
        createdAt = DateTime.now();

  Map<String, dynamic> toJson() {
    return {
      'type': type.name,
      'text': text,
      if (toolName != null) 'toolName': toolName,
      if (toolArgs != null) 'toolArgs': toolArgs,
      if (toolData != null) 'toolData': toolData,
      if (promptTagNames.isNotEmpty) 'promptTagNames': promptTagNames,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory AiChatMessage.fromJson(Map<String, dynamic> json) {
    return AiChatMessage(
      type: AiChatMessageType.values.firstWhere(
        (type) => type.name == json['type']?.toString(),
        orElse: () => AiChatMessageType.assistant,
      ),
      text: json['text']?.toString() ?? '',
      toolName: json['toolName']?.toString(),
      toolArgs: (json['toolArgs'] as Map?)?.cast<String, dynamic>(),
      toolData: json['toolData'],
      promptTagNames:
          (json['promptTagNames'] as List?)?.map((name) => name.toString()) ??
              const <String>[],
      createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? ''),
    );
  }
}

String _normalizePromptTagName(String value) {
  final trimmed = value.trim();
  return trimmed.startsWith('#') ? trimmed.substring(1).trim() : trimmed;
}

/// 待确认的下载任务
class PendingDownload {
  final String toolCallId;
  final String source;
  final String comicId;
  final String? title;

  PendingDownload({
    required this.toolCallId,
    required this.source,
    required this.comicId,
    this.title,
  });
}

class _ActiveTurnContext {
  const _ActiveTurnContext({
    required this.promptTags,
    required this.hasSourceOverride,
    required this.allowedSearchSources,
    required this.localOnly,
  });

  final List<AiPromptTag> promptTags;
  final bool hasSourceOverride;
  final Set<String>? allowedSearchSources;

  /// `true`=本轮仅本地，`null`=本轮无本地限定覆盖，走会话长期状态。
  final bool? localOnly;
}

enum _RunLoopOutcome { finished, waitingForDownloadConfirmation }

const _orderedAiSources = <String>[
  aiSourcePicacg,
  aiSourceJm,
  aiSourceEhentai,
  aiSourceNhentai,
];

/// 查询本地设备库/已连接远程库快照的工具名单。`#搜本地`/仅在线范围限定据此过滤。
/// `get_download_status` 不涉及库内容查询，不属于该名单。
@visibleForTesting
const localLibraryToolNames = <String>{
  'query_local_library',
  'search_local',
  'resolve_local_items',
  'query_remote_library',
};

/// 纯逻辑：按"仅本地"/"仅在线"两种有效范围过滤工具名单，与 schema 结构无关。
/// 供 [AiConversationController._getEnabledToolSchemas] 复用，也供单元测试直接验证
/// 过滤规则本身（不需要构造真实 schema 或依赖工具注册表）。
@visibleForTesting
bool isToolAllowedByScope(
  String toolName, {
  required bool effectiveLocalOnly,
  required bool effectiveOnlineOnly,
}) {
  if (effectiveLocalOnly && toolName == 'search_online') return false;
  if (effectiveOnlineOnly && localLibraryToolNames.contains(toolName)) {
    return false;
  }
  return true;
}

/// 深复制并按来源约束收窄 `search_online.source.enum`。
///
/// 无约束时直接返回原 schema 引用，维持改动前行为；有约束时只复制并修改
/// `search_online`，避免污染工具注册表持有的共享/const 嵌套 Map/List。
@visibleForTesting
List<Map<String, Object?>> constrainAiToolSchemasBySources(
  Iterable<Map<String, Object?>> schemas,
  Set<String>? allowedSources,
) {
  if (allowedSources == null) return schemas.toList();

  final normalizedAllowed =
      _normalizeSourceSet(allowedSources) ?? const <String>{};
  final orderedAllowed = _orderedAiSources
      .where(normalizedAllowed.contains)
      .toList(growable: false);

  return schemas.map((schema) {
    if (schema['name']?.toString() != 'search_online') return schema;
    final copied = _deepCopyStringMap(schema);
    final parameters = copied['parameters'];
    if (parameters is! Map<String, Object?>) return copied;
    final properties = parameters['properties'];
    if (properties is! Map<String, Object?>) return copied;
    final source = properties['source'];
    if (source is! Map<String, Object?>) return copied;
    source['enum'] = orderedAllowed;
    return copied;
  }).toList(growable: false);
}

/// 返回非空表示该次 `search_online` 调用必须被本地拒绝。
@visibleForTesting
AiToolResult? disallowedSearchSourceResult(
  String toolName,
  Map<String, dynamic> arguments,
  Set<String>? allowedSources,
) {
  if (toolName != 'search_online' || allowedSources == null) return null;

  final normalizedAllowed =
      _normalizeSourceSet(allowedSources) ?? const <String>{};
  final rawSource = arguments['source'];
  final normalizedSource = normalizeAiSource(rawSource);
  if (normalizedSource != null &&
      normalizedAllowed.contains(normalizedSource)) {
    return null;
  }

  final allowedText =
      _orderedAiSources.where(normalizedAllowed.contains).join(', ');
  return AiToolResult.failure(
    '当前会话/本轮仅允许：${allowedText.isEmpty ? '无' : allowedText}；'
    '实际传入：${rawSource?.toString() ?? 'null'}',
  );
}

/// 返回非空表示该次工具调用因"仅本地"或"仅在线"的有效范围限定被本地拒绝。
/// 拦截判定复用 [isToolAllowedByScope]，与 [AiConversationController._getEnabledToolSchemas]
/// 用同一套规则，避免 schema 层放行但 dispatch 层拦截（或反过来）的不一致。
@visibleForTesting
AiToolResult? disallowedScopeResult(
  String toolName,
  bool effectiveLocalOnly,
  bool effectiveOnlineOnly,
) {
  if (isToolAllowedByScope(
    toolName,
    effectiveLocalOnly: effectiveLocalOnly,
    effectiveOnlineOnly: effectiveOnlineOnly,
  )) {
    return null;
  }
  if (effectiveLocalOnly && toolName == 'search_online') {
    return const AiToolResult.failure(
      '当前会话/本轮范围限定为仅本地，工具 search_online 不可用。',
    );
  }
  if (effectiveOnlineOnly && localLibraryToolNames.contains(toolName)) {
    return AiToolResult.failure(
      '当前会话/本轮范围限定为仅在线，工具 $toolName 不可用。',
    );
  }
  return null;
}

Map<String, Object?> _deepCopyStringMap(Map<Object?, Object?> source) {
  return source.map(
    (key, value) => MapEntry(key.toString(), _deepCopyJsonLike(value)),
  );
}

Object? _deepCopyJsonLike(Object? value) {
  if (value is Map) return _deepCopyStringMap(value);
  if (value is List) return value.map(_deepCopyJsonLike).toList();
  return value;
}

Set<String>? _normalizeSourceSet(Iterable<Object?>? values) {
  if (values == null) return null;
  final normalized = <String>{};
  for (final value in values) {
    final source = normalizeAiSource(value);
    if (source != null) normalized.add(source);
  }
  return normalized.isEmpty ? null : normalized;
}

/// AI 对话控制器
class AiConversationController extends ChangeNotifier {
  final List<AiChatMessage> displayMessages = [];
  bool isLoading = false;
  String? error;

  /// 46号计划：一轮回复内可能出现多个 `download_comic` 调用，按出现顺序
  /// 依次排队等待用户确认；队列非空即代表"当前有待确认下载"。UI 侧
  /// （`ai_chat_page.dart`）只读队首（见 [pendingDownload]），不感知队列
  /// 本身，兼容旧的"单个可空对象"式判断（`!= null` / `== null`）写法。
  final List<PendingDownload> _pendingDownloads = [];

  /// 当前待确认下载（队列头部）。队列为空时为 `null`。
  PendingDownload? get pendingDownload =>
      _pendingDownloads.isEmpty ? null : _pendingDownloads.first;

  /// 测试用：当前待确认下载队列剩余长度，用于验证"一轮内多个 download_comic"
  /// 场景下队列的入队/出队顺序与长度变化。
  @visibleForTesting
  int get pendingDownloadQueueLengthForTesting => _pendingDownloads.length;

  String? conversationId;
  String _conversationTitle = '新会话';

  /// `true`=用户通过侧栏"重命名"手动设置过标题，`_save()` 时不再用
  /// `_deriveTitle()` 覆盖当前标题。持久化在会话文件里（不是索引文件），
  /// 因为索引文件的 title 只是展示用镜像值，真实状态要跟着会话内容走，
  /// 下次 `create(loadId: ...)` 加载时才能正确恢复"是否跳过自动派生"。
  bool _titleIsCustom = false;
  DateTime? _createdAt;

  // LLM 对话历史（internal）
  final List<LlmMessage> _history = [];

  // 当前工具调用轮次
  int _currentRound = 0;

  List<Map<String, dynamic>>? _pendingDisplayItems;
  final List<AiPromptTag> _persistentPromptTags = [];
  Set<String>? _persistentAllowedSearchSources;

  /// `null`=未设置/沿用默认，`true`=长期仅本地。`false` 状态不显式表示，
  /// 取消本地限定直接把该字段置回 `null`。
  bool? _persistentLocalOnly;
  _ActiveTurnContext? _activeTurnContext;

  int get _effectiveMaxRounds {
    final raw = appdata.settings[aiMaxToolRoundsSettingIndex];
    final n = int.tryParse(raw) ?? 5;
    return n <= 0 ? 999 : n;
  }

  AiConversationController._internal();

  List<AiPromptTag> get persistentPromptTags =>
      List<AiPromptTag>.unmodifiable(_persistentPromptTags);

  Set<String>? get persistentAllowedSearchSources =>
      _persistentAllowedSearchSources == null
          ? null
          : Set<String>.unmodifiable(_persistentAllowedSearchSources!);

  Set<String>? get effectiveAllowedSearchSources {
    final active = _activeTurnContext;
    if (active != null && active.hasSourceOverride) {
      return active.allowedSearchSources == null
          ? null
          : Set<String>.unmodifiable(active.allowedSearchSources!);
    }
    return persistentAllowedSearchSources;
  }

  /// 本轮/本会话是否被限定为"仅本地"（仅本地设备库+已连接远程库快照，不联网）。
  bool get effectiveLocalOnly {
    final active = _activeTurnContext;
    if (active != null && active.localOnly != null) return active.localOnly!;
    return _persistentLocalOnly ?? false;
  }

  /// 本轮/本会话是否存在硬性"仅在线"意图：没有本地限定，且存在明确的
  /// 来源限制集合（即用户已选中某个/某些来源标签）。未选任何来源标签时
  /// 不触发该层拦截，保持默认"可本地可在线"行为不变。
  bool get effectiveOnlineOnly {
    if (effectiveLocalOnly) return false;
    final sources = effectiveAllowedSearchSources;
    return sources != null && sources.isNotEmpty;
  }

  /// 静态工厂方法：创建新会话或加载已有会话
  static Future<AiConversationController> create({String? loadId}) async {
    final ctrl = AiConversationController._internal();
    if (loadId == null) {
      ctrl._createNew();
      return ctrl;
    }

    final data = await AiConversationStore.loadConversation(loadId);
    if (data == null) {
      ctrl._createNew();
    } else {
      ctrl._restoreStoredConversation(data, fallbackId: loadId);
    }
    return ctrl;
  }

  @visibleForTesting
  static AiConversationController restoreForTesting(
    Map<String, dynamic> data, {
    String fallbackId = 'test-conversation',
  }) {
    final ctrl = AiConversationController._internal();
    ctrl._restoreStoredConversation(data, fallbackId: fallbackId);
    return ctrl;
  }

  void _restoreStoredConversation(
    Map<String, dynamic> data, {
    required String fallbackId,
  }) {
    conversationId = data['id']?.toString() ?? fallbackId;
    _conversationTitle = data['title']?.toString() ?? '新会话';
    _titleIsCustom = data['titleIsCustom'] == true;
    _createdAt = DateTime.tryParse(data['createdAt']?.toString() ?? '') ??
        DateTime.now();

    final dispMsgs = data['displayMessages'] as List?;
    if (dispMsgs != null) {
      displayMessages.addAll(
        dispMsgs.whereType<Map<String, dynamic>>().map(AiChatMessage.fromJson),
      );
    }

    final version = int.tryParse(data['version']?.toString() ?? '1') ?? 1;
    if (version >= 2) _restorePersistentState(data);

    // 旧基础 system 历史始终丢弃；长期指令由 version 2 元数据重建。
    _initSystemPrompt();
    final histMsgs = data['history'] as List?;
    if (histMsgs != null) {
      _history.addAll(
        histMsgs
            .whereType<Map<String, dynamic>>()
            .map(LlmMessage.fromJson)
            .where((message) => message.role != 'system'),
      );
    }
  }

  void _restorePersistentState(Map<String, dynamic> data) {
    final promptTags = data['persistentPromptTags'] as List?;
    if (promptTags != null) {
      final byName = <String, AiPromptTag>{};
      for (final raw in promptTags.whereType<Map>()) {
        final name = _normalizePromptTagName(raw['name']?.toString() ?? '');
        final prompt = raw['prompt']?.toString() ?? '';
        if (name.isEmpty || prompt.trim().isEmpty) continue;
        byName[name] = AiPromptTag(name: name, prompt: prompt);
      }
      _persistentPromptTags
        ..clear()
        ..addAll(byName.values);
    }

    _persistentAllowedSearchSources = _normalizeSourceSet(
      data['persistentAllowedSearchSources'] as List?,
    );

    _persistentLocalOnly = data['persistentLocalOnly'] == true ? true : null;
  }

  /// 初始化新会话元数据。新会话不继承其他会话的长期状态。
  void _createNew() {
    conversationId = _generateUuid();
    _conversationTitle = '新会话';
    _titleIsCustom = false;
    _createdAt = DateTime.now();
    _pendingDisplayItems = null;
    _persistentPromptTags.clear();
    _persistentAllowedSearchSources = null;
    _persistentLocalOnly = null;
    _activeTurnContext = null;
    _initSystemPrompt();
  }

  /// 简化版 UUID v4
  String _generateUuid() {
    final random = Random();
    const chars = '0123456789abcdef';
    return List.generate(32, (i) => chars[random.nextInt(16)])
        .join()
        .replaceRange(8, 8, '-')
        .replaceRange(13, 13, '-')
        .replaceRange(18, 18, '-')
        .replaceRange(23, 23, '-');
  }

  /// 测试用：当前标题是否已被用户手动设置（跳过 `_deriveTitle()` 自动覆盖）。
  @visibleForTesting
  bool get titleIsCustomForTesting => _titleIsCustom;

  /// 测试用：直接触发一次持久化 `_save()`，不经过 `send()`/`confirmDownload()`
  /// （两者都会调用 LLM 网络接口）。用于验证"标记为自定义标题后，标题不会被
  /// `_deriveTitle()` 覆盖"的回归场景，不依赖网络配置。
  @visibleForTesting
  Future<void> saveForTesting() => _save();

  /// 从第一段剥离已识别标签后仍有效的用户文本派生标题。
  String _deriveTitle() {
    for (final message in displayMessages) {
      if (message.type != AiChatMessageType.user) continue;
      final text = _stripRecognizedPromptTags(
        message.text,
        message.promptTagNames,
      ).trim();
      if (text.isEmpty) continue;
      return text.length > 15 ? text.substring(0, 15) : text;
    }
    return '新会话';
  }

  /// 持久化当前会话。活动轮次上下文永不写入文件。
  /// 标题若已被用户手动重命名（`_titleIsCustom == true`），跳过
  /// `_deriveTitle()` 的自动派生覆盖，沿用当前 `_conversationTitle`。
  Future<void> _save() async {
    if (conversationId == null) return;
    if (!_titleIsCustom) {
      _conversationTitle = _deriveTitle();
    }
    await AiConversationStore.save(
      id: conversationId!,
      title: _conversationTitle,
      createdAt: _createdAt ?? DateTime.now(),
      displayMessages: displayMessages,
      history: _history,
      persistentPromptTags: _persistentPromptTags,
      persistentAllowedSearchSources: _persistentAllowedSearchSources,
      persistentLocalOnly: _persistentLocalOnly,
      titleIsCustom: _titleIsCustom,
    );
    await AiConversationStore.saveLastActiveId(conversationId!);
  }

  /// 供侧栏在"重命名的正好是当前活跃会话"时同步内存状态：会话文件已经在
  /// `AiConversationStore.renameConversation()` 里写过，这里只更新内存值，
  /// 不触发额外的 `_save()`（避免覆盖刚落盘的文件，也避免不必要的 I/O）。
  void applyExternalRename(String newTitle) {
    _conversationTitle = newTitle;
    _titleIsCustom = true;
    notifyListeners();
  }

  void _initSystemPrompt() {
    const systemPrompt = '''你是 PicaKeep 的 AI 助手，帮助用户管理和查找漫画。

能力：
- 查询本地已下载/收藏/历史漫画（优先本地，默认不联网）
- 解析用户提供的漫画名/链接/ID，判断本地是否已有
- 在线搜索漫画（仅用户明确要求时）
- 查询下载队列状态
- （需用户确认后）触发下载
- 收藏管理：可以列出/创建/删除/重命名收藏夹，向收藏夹添加或移除漫画（需提供 comic_id + source + title + folder），检查某漫画是否已收藏

规则：
1. 默认先查本地，不联网
2. 所有下载操作必须告知用户并等待确认，不自行触发
3. 数据来源必须透明（说明是本地库/收藏/历史/在线）
4. 字段缺失时如实说明，不猜测
5. 用中文回复
6. 工具返回漫画列表（items数组）时：
   - 文字回复只简要总结数量与分类（不逐条罗列，不输出markdown表格）
   - 若需要展示精选/筛选结果，必须调用 display_result_list 工具，把要展示的条目传入 items；不要用文字替代清单
   - 若用户要求排除/筛选，先从上轮搜索结果里筛选出目标条目，再调用 display_result_list 展示
   - 只有用户明确要求重新搜索时，才重新调用 search_online
7. 已经触发在线搜索后，如果结果明显少于用户期望或只有少量候选，不要立即宣布完成。在最多 5 轮的工具预算内至少换一种策略重试：角色搜索尝试原文、罗马音、英文名、常用昵称或简称，并结合所属作品或题材消歧；题材/标签搜索尝试同义词、近义标签或放宽过窄条件；存在多个可用来源时可换源。多种策略仍无更多结果后，再说明实际尝试过的关键词、来源与结果边界，不得伪造数量。
8. picacg 与 jm 的关键词搜索不支持多词组合/AND 逻辑，服务端把整个 keyword 当作一个短语原样匹配；这两个源搜索时应使用单个简短关键词（角色名或题材词，不要把作品名、消歧条件等一起拼进关键词字符串），拿到结果列表后自行核对每条的标题/标签/作者是否匹配，筛掉明显不相关结果，不要指望搜索词本身帮你做精确过滤。eh、nhentai 支持空格分隔的标签组合搜索，不受此限制，可以正常拼多个词。
9. 用户消息中可能藏有"JM ID 解码"彩蛋：把句子中按自然顺序出现的一组数字依次提取并直接拼接（不加分隔符），即得到一个 JM（禁漫）漫画 ID。识别到这种模式时（消息里出现多个数字、语境像是有意设计的数字线索），先按顺序拼出候选 ID，再调用 get_comic_detail（source: jm, id: 拼出的ID）查看该 ID 对应的漫画详情做确认，不要直接调用 download_comic 跳过确认步骤；确认后再询问用户是否需要下载。
- 执行收藏增删操作前，应先向用户确认操作目标（特别是删除收藏夹这类不可逆操作）''';

    if (_history.isEmpty || _history.first.role != 'system') {
      _history.insert(0, LlmMessage.system(systemPrompt));
    }
  }

  /// 发送用户消息。
  ///
  /// [availablePromptTags] 是发送时可识别的普通标签集合；固定来源标签由统一
  /// 解析器自行识别。[allowedSearchSources] 表示 UI 的结构化来源覆盖，
  /// [resetSourceRestriction] 表示用户明确选择“默认/全部来源”。
  Future<void> send(
    String text, {
    Iterable<AiPromptTag>? availablePromptTags,
    Iterable<AiPromptTag>? selectedPromptTags,
    Set<String>? allowedSearchSources,
    bool resetSourceRestriction = false,
    bool? persistSelections,
    bool localOnly = false,
  }) async {
    if (text.trim().isEmpty || isLoading) return;
    if (pendingDownload != null) {
      error = '请先处理下载确认';
      notifyListeners();
      return;
    }

    final promptTagSettings = AiPromptTagSettingsController.instance;
    if (availablePromptTags == null || persistSelections == null) {
      await promptTagSettings.initialize();
    }
    final parsed = parseAiPromptTags(
      text,
      promptTags: availablePromptTags ?? promptTagSettings.promptTags,
      resetSourceRestriction: resetSourceRestriction,
    );
    final shouldPersistSelections =
        persistSelections ?? promptTagSettings.longTermEnabled;
    final parsedSources = _normalizeSourceSet(parsed.sourceTags);
    final structuredSources = _normalizeSourceSet(allowedSearchSources);
    final selectedSources = <String>{
      ...?parsedSources,
      ...?structuredSources,
    };
    final resetRequested =
        resetSourceRestriction || parsed.resetSourceRestriction;
    final hasSourceOverride = resetRequested ||
        allowedSearchSources != null ||
        parsed.sourceTags.isNotEmpty;
    final turnAllowedSources =
        resetRequested || selectedSources.isEmpty ? null : selectedSources;
    final localOnlyRequested = localOnly || parsed.localOnly;
    final hasLocalOverride = localOnlyRequested;

    // 结构化选中的普通标签（面板 chip 点选，未必出现在手输文本里）与文本识别结果
    // 按 name 去重合并；结构化选中优先，避免同名标签内容不一致时的歧义。
    final mergedPromptTagsByName = <String, AiPromptTag>{
      for (final tag in parsed.promptTags) tag.name: tag,
    };
    for (final tag in selectedPromptTags ?? const <AiPromptTag>[]) {
      mergedPromptTagsByName[tag.name] = tag;
    }
    final mergedPromptTags = mergedPromptTagsByName.values.toList();

    // 先落地本轮的长期持久化/临时覆盖状态，再基于“最终生效范围”计算气泡
    // 回显标签，确保回显与 effectiveAllowedSearchSources/effectiveLocalOnly
    // （system prompt 注入、工具调用约束用的同一份判定）完全一致：本轮有
    // 手动覆盖时按本轮，没有手动覆盖时回落到长期生效状态，而不是本轮没选就
    // 直接不显示。
    if (shouldPersistSelections) {
      _mergePersistentPromptTags(mergedPromptTags);
      if (hasSourceOverride) {
        _persistentAllowedSearchSources = turnAllowedSources;
      }
      if (localOnlyRequested) {
        _persistentLocalOnly = true;
      }
      _activeTurnContext = const _ActiveTurnContext(
        promptTags: <AiPromptTag>[],
        hasSourceOverride: false,
        allowedSearchSources: null,
        localOnly: null,
      );
    } else {
      _activeTurnContext = _ActiveTurnContext(
        promptTags: List<AiPromptTag>.unmodifiable(mergedPromptTags),
        hasSourceOverride: hasSourceOverride,
        allowedSearchSources: turnAllowedSources == null
            ? null
            : Set<String>.unmodifiable(turnAllowedSources),
        localOnly: hasLocalOverride ? true : null,
      );
    }

    // 本轮气泡展示的来源/本地限定标签：本轮显式选中的（临时或长期）与长期
    // 生效但本轮未手动选中的，都应折入名单；两条路径共用同一个“最终生效
    // 范围”读出，天然去重，不会同一标签重复出现，也不会展示与实际生效范围
    // 不符的标签。
    final effectiveSources = effectiveAllowedSearchSources;
    final scopeTagNames = <String>[
      for (final source in _orderedAiSources)
        if (effectiveSources?.contains(source) ?? false)
          if (aiPromptTagNameForSource(source) != null)
            aiPromptTagNameForSource(source)!,
      if (effectiveLocalOnly) aiLocalOnlyScopeTagName,
    ];
    final mergedRecognizedNames = <String>[
      ...parsed.recognizedNames,
      for (final tag in mergedPromptTagsByName.keys)
        if (!parsed.recognizedNames.contains(tag)) tag,
      for (final name in scopeTagNames)
        if (!parsed.recognizedNames.contains(name) &&
            !mergedPromptTagsByName.containsKey(name))
          name,
    ];

    displayMessages.add(
      AiChatMessage.user(
        parsed.displayText,
        promptTagNames: mergedRecognizedNames,
      ),
    );
    _history.add(LlmMessage.user(parsed.userText));

    isLoading = true;
    error = null;
    _currentRound = 0;
    notifyListeners();

    try {
      await _runLoop();
    } catch (exception) {
      final message = 'AI 对话执行失败：$exception';
      displayMessages.add(AiChatMessage.error(message));
      error = message;
      isLoading = false;
      _activeTurnContext = null;
      notifyListeners();
    }
    await _save();
  }

  void _mergePersistentPromptTags(Iterable<AiPromptTag> tags) {
    final byName = <String, AiPromptTag>{
      for (final tag in _persistentPromptTags) tag.name: tag,
    };
    for (final tag in tags) {
      byName[tag.name] = AiPromptTag(name: tag.name, prompt: tag.prompt);
    }
    _persistentPromptTags
      ..clear()
      ..addAll(byName.values);
  }

  /// 每一轮请求均从基础 system + 长期引导 + 本轮短期引导 + 历史重建。
  List<LlmMessage> _buildRequestMessages() {
    _initSystemPrompt();
    final messages = <LlmMessage>[_history.first];
    if (_persistentPromptTags.isNotEmpty) {
      messages.add(
        LlmMessage.system(
          _buildPromptTagInstruction('当前会话长期提示词标签', _persistentPromptTags),
        ),
      );
    }
    final activeTags = _activeTurnContext?.promptTags ?? const <AiPromptTag>[];
    if (activeTags.isNotEmpty) {
      messages.add(
        LlmMessage.system(
          _buildPromptTagInstruction('仅当前轮提示词标签', activeTags),
        ),
      );
    }
    final scopeMessage = _buildScopeInstruction();
    if (scopeMessage != null) {
      messages.add(LlmMessage.system(scopeMessage));
    }
    messages
        .addAll(_history.skip(1).where((message) => message.role != 'system'));
    return messages;
  }

  @visibleForTesting
  List<LlmMessage> buildRequestMessagesForTesting() => _buildRequestMessages();

  /// 合并"仅本地"/"仅在线（来源限制）"两种有效范围限定为单条 system 指令，
  /// 避免与来源限制语义重叠时出现两条重复啰嗦的 system 消息。
  /// 都不生效时返回 null（不追加任何范围相关的 system 消息）。
  String? _buildScopeInstruction() {
    if (effectiveLocalOnly) {
      return '本轮范围限定：用户明确要求仅查本地设备库/已连接的远程库快照，'
          '不得调用在线搜索，也不需要询问用户是否联网。';
    }
    final activeSources = effectiveAllowedSearchSources;
    if (effectiveOnlineOnly && activeSources != null) {
      final readable = _orderedAiSources
          .where(activeSources.contains)
          .map((s) => '#${aiPromptTagNameForSource(s) ?? s}')
          .join('、');
      final multiSourceHint = activeSources.length > 1
          ? '这些来源应分别调用一次 search_online（可在同一轮回复内一起发出），'
              '不需要询问用户具体选哪一个，取得各来源结果后自行合并处理/展示。'
          : '';
      return '本轮范围限定：用户已明确指定在线搜索来源（$readable），'
          '不需要先查本地库或询问用户是否联网，请直接对上述来源执行在线搜索，'
          '也不得使用其他来源。$multiSourceHint';
    }
    return null;
  }

  String _buildPromptTagInstruction(
      String heading, Iterable<AiPromptTag> tags) {
    final byName = <String, AiPromptTag>{};
    for (final tag in tags) {
      byName[tag.name] = tag;
    }
    final lines = byName.values
        .map((tag) => '- #${tag.name}：${tag.prompt.trim()}')
        .join('\n');
    return '''$heading：
以下内容是搜索策略建议，应结合用户当前实际意图采用，不得覆盖用户的明确要求，也不得自行触发用户未要求的在线搜索。
$lines''';
  }

  /// 工具调用循环
  Future<_RunLoopOutcome> _runLoop() async {
    if (_currentRound >= _effectiveMaxRounds) {
      displayMessages.add(
        AiChatMessage.assistant('已达到最大工具调用次数（$_effectiveMaxRounds轮），对话结束。'),
      );
      _flushPendingDisplayItems();
      _finishActiveTurn();
      return _RunLoopOutcome.finished;
    }

    final tools = _getEnabledToolSchemas();
    final response =
        await LlmClient.chat(_buildRequestMessages(), tools: tools);

    if (response.hasError) {
      displayMessages.add(AiChatMessage.error(response.error!));
      error = response.error;
      _finishActiveTurn();
      return _RunLoopOutcome.finished;
    }

    if (!response.hasToolCalls) {
      _handleFinalTextResponse(response.content);
      return _RunLoopOutcome.finished;
    }

    _currentRound++;
    _history.add(LlmMessage.assistant(toolCalls: response.toolCalls));

    return _processToolCalls(response.toolCalls!);
  }

  /// 处理一轮"LLM 无 tool_calls"的最终文本回复：
  /// - 有实际内容（trim 后非空）：正常生成气泡并写入 `_history`。
  /// - 无内容（`null`/空字符串/纯空白）：不生成空文本气泡（避免灰色空块）；
  ///   若此时也没有待展示的工具结果（清单卡等），改为展示一条轻量提示气泡，
  ///   让用户感知"AI本轮没有回复内容"而不是完全静默；该提示气泡只展示给
  ///   用户，不写入 `_history`，避免污染后续请求的历史上下文。
  void _handleFinalTextResponse(String? rawText) {
    final trimmedText = rawText?.trim() ?? '';
    if (trimmedText.isNotEmpty) {
      // 保留原始文本（未 trim）写入气泡与历史，与修复前的展示行为保持一致，
      // 只用 trim 后的结果判断“是否算有内容”。
      displayMessages.add(AiChatMessage.assistant(rawText!));
      _history.add(LlmMessage.assistant(content: rawText));
    } else if (_pendingDisplayItems == null || _pendingDisplayItems!.isEmpty) {
      displayMessages.add(AiChatMessage.assistant('（AI本轮未返回有效内容）'));
    }
    _flushPendingDisplayItems();
    _finishActiveTurn();
  }

  /// 测试用：绕过真实网络请求，直接模拟"LLM 一轮回复的 `content`（可能为
  /// `null`/空字符串/纯空白/正常文本），且本轮没有 tool_calls"这一场景，
  /// 驱动与 [_runLoop] 完全相同的收尾逻辑（[_handleFinalTextResponse]）。
  /// 用于验证空/空白 content 不再产生空文本气泡（02号计划）。
  @visibleForTesting
  void simulateFinalTextResponseForTesting(String? content) {
    _handleFinalTextResponse(content);
  }

  /// 处理一轮 LLM 回复里的全部 tool_call（不含往 `_history` 追加那条 assistant
  /// tool_calls 消息本身——调用方负责，见 [_runLoop] 与
  /// [processToolCallsForTesting]）。
  ///
  /// 46号计划：一轮回复内可能出现多个 `download_comic` 调用，不能命中第一个就
  /// 提前 `return`——那样后续 tool_call（无论是否也是 `download_comic`）永远
  /// 不会被追加对应的 `tool` 消息，之后每次请求都会因缺失配对而必现 400。
  /// 这里遇到 `download_comic` 时入队后继续遍历，等本轮全部 tool_call 都
  /// 处理完（非下载的已 dispatch 并追加结果，下载的已入队）才统一判断是否
  /// 要暂停：只要队列非空就必须暂停等待确认，不能带着未回填的 tool_calls
  /// 继续请求下一轮。
  Future<_RunLoopOutcome> _processToolCalls(
    List<LlmToolCall> toolCalls,
  ) async {
    for (final toolCall in toolCalls) {
      final toolName = toolCall.name;
      final toolArgs = toolCall.arguments;

      displayMessages.add(
        AiChatMessage.toolCall(toolName: toolName, toolArgs: toolArgs),
      );
      notifyListeners();

      if (toolName == 'download_comic') {
        _pendingDownloads.add(
          PendingDownload(
            toolCallId: toolCall.id,
            source: toolArgs['source']?.toString() ?? '',
            comicId: toolArgs['comicId']?.toString() ??
                toolArgs['id']?.toString() ??
                '',
            title: toolArgs['title']?.toString(),
          ),
        );
        notifyListeners();
        continue;
      }

      final blockedResult = disallowedScopeResult(
            toolName,
            effectiveLocalOnly,
            effectiveOnlineOnly,
          ) ??
          disallowedSearchSourceResult(
            toolName,
            toolArgs,
            effectiveAllowedSearchSources,
          );
      final result = blockedResult ??
          await AiCapabilities.registry.dispatch(toolName, toolArgs);
      _appendToolResult(toolCall.id, toolName, result);
    }

    // 本轮出现过 download_comic：所有非下载 tool_call 已经正常回填结果，
    // 但下载类还在排队等待用户逐一确认，必须先暂停，不能继续下一轮 LLM 请求
    // （否则请求体里会带着还没有配对 tool 消息的 assistant tool_calls）。
    if (_pendingDownloads.isNotEmpty) {
      return _RunLoopOutcome.waitingForDownloadConfirmation;
    }

    return _runLoop();
  }

  /// 测试用：绕过真实网络请求，直接模拟"LLM 一轮回复带有这些 tool_calls"，
  /// 驱动 `_runLoop()` 本应执行的处理逻辑（往 `_history` 追加 assistant
  /// tool_calls 消息 + 逐个处理）。用于验证 46号计划"一轮内多个
  /// download_comic"场景下不会产生孤儿 tool_call。
  @visibleForTesting
  Future<void> simulateToolCallRoundForTesting(
    List<LlmToolCall> toolCalls,
  ) async {
    _currentRound++;
    _history.add(LlmMessage.assistant(toolCalls: toolCalls));
    final outcome = await _processToolCalls(toolCalls);
    if (outcome == _RunLoopOutcome.waitingForDownloadConfirmation) {
      notifyListeners();
    }
  }

  /// 测试用：直接读取内部 LLM 历史（只读快照），用于断言每个 tool_call_id
  /// 是否都有且仅有一条对应的 `tool` 消息（46号计划核心不变式）。
  @visibleForTesting
  List<LlmMessage> historyForTesting() => List<LlmMessage>.unmodifiable(_history);

  void _appendToolResult(
    String toolCallId,
    String toolName,
    AiToolResult result,
  ) {
    _history.add(
      LlmMessage.tool(
        toolCallId: toolCallId,
        name: toolName,
        content: jsonEncode(result.toJson()),
      ),
    );
    displayMessages.add(
      AiChatMessage.toolResult(
        toolName: toolName,
        ok: result.ok,
        data: result.data,
        message: result.message,
      ),
    );
    if (toolName == 'display_result_list' && result.ok && result.data is Map) {
      final rawItems = (result.data as Map)['items'];
      if (rawItems is List) {
        _pendingDisplayItems =
            rawItems.whereType<Map<String, dynamic>>().toList();
      }
    }
    notifyListeners();
  }

  void _flushPendingDisplayItems() {
    if (_pendingDisplayItems != null && _pendingDisplayItems!.isNotEmpty) {
      displayMessages.add(
        AiChatMessage.resultList(items: List.of(_pendingDisplayItems!)),
      );
    }
    _pendingDisplayItems = null;
  }

  void _finishActiveTurn() {
    isLoading = false;
    _activeTurnContext = null;
    notifyListeners();
  }

  /// 确认或取消下载。暂停期间保留本轮短期提示和来源约束，续跑真正结束后清理。
  ///
  /// 46号计划：一轮回复内可能有多个排队的 `download_comic` 调用——本方法只
  /// 出队并处理队首那一个，处理完追加对应 `tool` 消息后：若队列里还有剩余
  /// （即本轮还有更多待确认下载），直接停留在"等待确认"状态，不进入
  /// `_runLoop()`（此时也不该真正续跑一轮新的 LLM 请求，因为还有尚未回复
  /// 的 tool_call 挂在 assistant 消息上）；只有队列真正清空后才续跑
  /// `_runLoop()` 让 LLM 看到全部下载结果继续对话。
  Future<void> confirmDownload(bool confirmed) async {
    if (_pendingDownloads.isEmpty) return;

    final pending = _pendingDownloads.removeAt(0);
    notifyListeners();

    AiToolResult result;
    if (confirmed) {
      try {
        result = await AiCapabilities.registry.dispatch(
          'download_comic',
          {
            'source': pending.source,
            'id': pending.comicId,
            if (pending.title != null) 'title': pending.title,
          },
        );
      } catch (exception) {
        result = AiToolResult.failure('下载工具执行失败：$exception');
      }
    } else {
      result = const AiToolResult.failure('用户取消了下载');
    }

    _appendToolResult(pending.toolCallId, 'download_comic', result);
    await _save();

    if (_pendingDownloads.isNotEmpty) {
      // 本轮还有更多待确认下载：停留等待，不续跑 LLM 请求。
      return;
    }

    try {
      await _runLoop();
    } catch (exception) {
      final message = 'AI 对话执行失败：$exception';
      displayMessages.add(AiChatMessage.error(message));
      error = message;
      isLoading = false;
      _activeTurnContext = null;
      notifyListeners();
    }
    await _save();
  }

  Future<void> clearPersistentPromptTags() async {
    if (_persistentPromptTags.isEmpty) return;
    _persistentPromptTags.clear();
    await _save();
    notifyListeners();
  }

  Future<void> clearPersistentSourceRestriction() async {
    if (_persistentAllowedSearchSources == null) return;
    _persistentAllowedSearchSources = null;
    await _save();
    notifyListeners();
  }

  Future<void> clearPersistentLocalOnly() async {
    if (_persistentLocalOnly != true) return;
    _persistentLocalOnly = null;
    await _save();
    notifyListeners();
  }

  /// 清空对话，创建新会话
  void clear() {
    displayMessages.clear();
    _history.clear();
    isLoading = false;
    error = null;
    _pendingDownloads.clear();
    _currentRound = 0;
    _createNew();
    notifyListeners();
  }

  /// 获取启用的工具 schema
  List<Map<String, Object?>> _getEnabledToolSchemas() {
    AiCapabilities.ensureRegistered();
    final localOnly = effectiveLocalOnly;
    final onlineOnly = effectiveOnlineOnly;
    final enabledSchemas =
        AiCapabilities.registry.toolSchemas().where((schema) {
      final toolName = schema['name']?.toString() ?? '';
      if (!isAiCapabilityEnabled(toolName)) return false;
      return isToolAllowedByScope(
        toolName,
        effectiveLocalOnly: localOnly,
        effectiveOnlineOnly: onlineOnly,
      );
    }).toList();

    return constrainAiToolSchemasBySources(
      enabledSchemas,
      effectiveAllowedSearchSources,
    );
  }
}

/// 全局会话控制器注册表：按 conversationId 缓存复用 [AiConversationController]。
///
/// 33号计划：把 controller 的生命周期从"绑定单个 AiChatPage State"改为
/// "绑定到跨页面存活的全局注册表"，使 `_runLoop()` 在页面切换/会话切换时
/// 不会被 State 的 `dispose()` 强制中断。controller 的真正销毁只应发生在
/// 用户显式永久删除该会话时（见 [remove]，由 `AiConversationStore.delete`
/// 调用点联动触发)。
///
/// 41号计划：注册表自身现在也是 [ChangeNotifier]——每当任一被缓存
/// controller 的 `isLoading` 发生翻转，都会同步更新 [loadingIds] 并
/// `notifyListeners()`，供侧栏 Drawer 等 UI 订阅以决定是否显示"转圈中"。
class AiConversationRegistry extends ChangeNotifier {
  AiConversationRegistry._();

  static final AiConversationRegistry instance = AiConversationRegistry._();

  /// 缓存上限：超出后淘汰最久未访问的非-loading会话，避免无限增长导致内存问题。
  /// 正在 `isLoading` 的会话永远不参与淘汰。
  static const int _maxCacheSize = 20;

  // 用 Map 的插入顺序近似 LRU：每次访问（getOrCreate 命中）时 remove+重新插入，
  // 使其移到"最近访问"端；淘汰时从最前面（最久未访问）开始找第一个非-loading的。
  final Map<String, AiConversationController> _cache = {};

  /// 40号计划：并发去重表。key 为非空 conversationId，value 为该 id 正在进行中
  /// 的创建 Future。同一 id 的第二次及后续 getOrCreate 调用若命中此表，直接
  /// await 同一个 Future 而不是各自发起新的 `AiConversationController.create()`
  /// 调用，避免两次磁盘读取各自反序列化出互相独立、之后永久分裂的 controller
  /// 实例。仅覆盖 conversationId 非空的路径——`getOrCreate(null)`（新建会话）
  /// 语义上每次调用都应该是独立的新会话，不需要（也不能）去重。
  final Map<String, Future<AiConversationController>> _pending = {};

  /// 41号计划：当前处于 `isLoading == true` 的 conversationId 集合，供外部
  /// （侧栏 Drawer）监听以决定是否显示转圈指示器。只读暴露给外部，内部通过
  /// [_setLoading] 变更并触发 [notifyListeners]。
  final Set<String> _loadingIds = <String>{};

  /// 供外部只读访问当前 loading 集合的快照（每次取值返回新的不可变副本，
  /// 避免外部持有引用后绕过 [notifyListeners] 直接修改内部状态）。
  Set<String> get loadingIds => Set.unmodifiable(_loadingIds);

  /// 41号计划：记录已经为哪些 controller 挂过内部监听器，避免同一个
  /// controller（LRU 缓存命中、多次 getOrCreate 命中同一实例）被重复挂听，
  /// 否则每次 isLoading 翻转都会触发多次冗余的 registry notifyListeners。
  /// value 是挂在该 controller 上的监听器函数本身，remove() 时需要用它
  /// 精确地 removeListener，避免残留悬挂引用。
  final Map<String, VoidCallback> _loadingListeners = {};

  /// 41号计划：为 controller 挂一个内部监听器，比较其 `isLoading` 的
  /// 前后值，变化时更新 [_loadingIds] 并广播。同一个 conversationId 只挂
  /// 一次；`conversationId` 为 null（新建会话尚未落盘出 id 前）的场景不适用
  /// 本方法，由调用方保证只在 id 非空时调用。
  void _attachLoadingListener(String conversationId, AiConversationController ctrl) {
    if (_loadingListeners.containsKey(conversationId)) return;
    var lastLoading = ctrl.isLoading;
    if (lastLoading) {
      _loadingIds.add(conversationId);
    }
    void listener() {
      final current = ctrl.isLoading;
      if (current == lastLoading) return;
      lastLoading = current;
      if (current) {
        _loadingIds.add(conversationId);
      } else {
        _loadingIds.remove(conversationId);
      }
      notifyListeners();
    }
    ctrl.addListener(listener);
    _loadingListeners[conversationId] = listener;
  }

  /// 按 conversationId 获取已缓存的 controller；不存在或 id 为 null（新建会话）
  /// 时创建新的并存入缓存。同一个非空 conversationId 多次调用返回同一实例，
  /// 即使这些调用是并发发起、缓存尚未命中时也是如此（见 [_pending]）。
  Future<AiConversationController> getOrCreate(String? conversationId) async {
    if (conversationId != null && _cache.containsKey(conversationId)) {
      // 命中缓存：移到 Map 末尾，标记为"最近访问"，供 LRU 淘汰参考。
      final ctrl = _cache.remove(conversationId)!;
      _cache[conversationId] = ctrl;
      _attachLoadingListener(conversationId, ctrl);
      return ctrl;
    }
    if (conversationId != null) {
      // 缓存未命中，但可能已有同 id 的创建流程在途（并发调用）：直接复用同一个
      // Future，保证两次调用最终拿到的是同一个 controller 实例，而不是各自
      // 反序列化磁盘文件、创建出两个此后永久分裂的独立实例。
      final existing = _pending[conversationId];
      if (existing != null) {
        return existing;
      }
      final future = _createAndCache(conversationId);
      _pending[conversationId] = future;
      try {
        return await future;
      } finally {
        // 无论成功还是失败都必须清理该条目——若 create() 抛出异常后不清理，
        // 后续所有对该 id 的 getOrCreate 调用会一直 await 一个已经失败、
        // 永远不会 resolve 的旧 Future，造成永久卡死。
        _pending.remove(conversationId);
      }
    }
    // conversationId 为 null：新建会话，不涉及去重，直接创建。
    final ctrl = await AiConversationController.create(loadId: null);
    final id = ctrl.conversationId;
    if (id != null) {
      _cache[id] = ctrl;
      _attachLoadingListener(id, ctrl);
      _evictIfNeeded();
    }
    return ctrl;
  }

  Future<AiConversationController> _createAndCache(String conversationId) async {
    final ctrl = await AiConversationController.create(loadId: conversationId);
    final id = ctrl.conversationId;
    if (id != null) {
      _cache[id] = ctrl;
      _attachLoadingListener(id, ctrl);
      _evictIfNeeded();
    }
    return ctrl;
  }

  /// 会话被用户显式永久删除时调用：从缓存移除并真正 dispose 该 controller。
  /// 该 conversationId 不在缓存中时是安全的空操作。同步清理 41号计划新增的
  /// loading 监听器绑定与 loading 集合记录，避免残留过期状态或悬挂监听器。
  void remove(String conversationId) {
    final ctrl = _cache.remove(conversationId);
    final listener = _loadingListeners.remove(conversationId);
    if (ctrl != null && listener != null) {
      ctrl.removeListener(listener);
    }
    final wasLoading = _loadingIds.remove(conversationId);
    ctrl?.dispose();
    if (wasLoading) {
      notifyListeners();
    }
  }

  /// 缓存条目数超过上限时，淘汰最久未访问、且当前不在 `isLoading` 的会话。
  /// 若最久未访问的若干个都在 loading，则依次往后找，直至找到可淘汰的一个
  /// 或已扫描全部缓存条目（此时暂不淘汰，等待下次访问后条件改变再试）。
  void _evictIfNeeded() {
    if (_cache.length <= _maxCacheSize) return;
    for (final id in _cache.keys.toList(growable: false)) {
      final ctrl = _cache[id];
      if (ctrl != null && !ctrl.isLoading) {
        _cache.remove(id);
        ctrl.dispose();
        return;
      }
    }
  }

  /// 测试/调试用：当前缓存条目数。
  @visibleForTesting
  int get cacheSizeForTesting => _cache.length;

  /// 测试/调试用：某 conversationId 是否在缓存中。
  @visibleForTesting
  bool containsForTesting(String conversationId) =>
      _cache.containsKey(conversationId);

  /// 41号计划测试/调试用：当前是否已为该 conversationId 挂过 loading 监听器。
  @visibleForTesting
  bool hasLoadingListenerForTesting(String conversationId) =>
      _loadingListeners.containsKey(conversationId);
}

String _stripRecognizedPromptTags(String text, Iterable<String> names) {
  var result = text;
  final orderedNames = names
      .map(_normalizePromptTagName)
      .where((name) => name.isNotEmpty)
      .toSet()
      .toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  for (final name in orderedNames) {
    final escaped = RegExp.escape(name);
    result = result.replaceAll(
      RegExp('(^|\\s)#$escaped(?=\\s|[，。！？、；：,.!?;:]|\$)', multiLine: true),
      ' ',
    );
  }
  return result
      .replaceAll(RegExp(r'[ \t]+'), ' ')
      .replaceAll(RegExp(r'\s*\n\s*'), '\n')
      .trim();
}

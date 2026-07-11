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
  PendingDownload? pendingDownload;

  String? conversationId;
  String _conversationTitle = '新会话';
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
  Future<void> _save() async {
    if (conversationId == null) return;
    _conversationTitle = _deriveTitle();
    await AiConversationStore.save(
      id: conversationId!,
      title: _conversationTitle,
      createdAt: _createdAt ?? DateTime.now(),
      displayMessages: displayMessages,
      history: _history,
      persistentPromptTags: _persistentPromptTags,
      persistentAllowedSearchSources: _persistentAllowedSearchSources,
      persistentLocalOnly: _persistentLocalOnly,
    );
    await AiConversationStore.saveLastActiveId(conversationId!);
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
    final mergedRecognizedNames = <String>[
      ...parsed.recognizedNames,
      for (final tag in mergedPromptTagsByName.keys)
        if (!parsed.recognizedNames.contains(tag)) tag,
    ];

    displayMessages.add(
      AiChatMessage.user(
        parsed.displayText,
        promptTagNames: mergedRecognizedNames,
      ),
    );
    _history.add(LlmMessage.user(parsed.userText));

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
      return '本轮范围限定：用户已明确指定在线搜索来源（$readable），'
          '不需要先查本地库或询问用户是否联网，请直接对上述来源执行在线搜索，'
          '也不得使用其他来源。';
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
      final text = response.content ?? '';
      displayMessages.add(AiChatMessage.assistant(text));
      _history.add(LlmMessage.assistant(content: text));
      _flushPendingDisplayItems();
      _finishActiveTurn();
      return _RunLoopOutcome.finished;
    }

    _currentRound++;
    _history.add(LlmMessage.assistant(toolCalls: response.toolCalls));

    for (final toolCall in response.toolCalls!) {
      final toolName = toolCall.name;
      final toolArgs = toolCall.arguments;

      displayMessages.add(
        AiChatMessage.toolCall(toolName: toolName, toolArgs: toolArgs),
      );
      notifyListeners();

      if (toolName == 'download_comic') {
        pendingDownload = PendingDownload(
          toolCallId: toolCall.id,
          source: toolArgs['source']?.toString() ?? '',
          comicId: toolArgs['comicId']?.toString() ??
              toolArgs['id']?.toString() ??
              '',
          title: toolArgs['title']?.toString(),
        );
        notifyListeners();
        return _RunLoopOutcome.waitingForDownloadConfirmation;
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

    return _runLoop();
  }

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
  Future<void> confirmDownload(bool confirmed) async {
    if (pendingDownload == null) return;

    final pending = pendingDownload!;
    pendingDownload = null;
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
    pendingDownload = null;
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

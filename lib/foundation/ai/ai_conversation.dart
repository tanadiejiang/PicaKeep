import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:picakeep/foundation/ai/ai_capabilities.dart';
import 'package:picakeep/foundation/ai/ai_conversation_store.dart';
import 'package:picakeep/foundation/ai/ai_settings.dart';
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

  AiChatMessage({
    required this.type,
    required this.text,
    this.toolName,
    this.toolArgs,
    this.toolData,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  AiChatMessage.user(this.text)
      : type = AiChatMessageType.user,
        toolName = null,
        toolArgs = null,
        toolData = null,
        createdAt = DateTime.now();

  AiChatMessage.assistant(this.text)
      : type = AiChatMessageType.assistant,
        toolName = null,
        toolArgs = null,
        toolData = null,
        createdAt = DateTime.now();

  AiChatMessage.toolCall({
    required this.toolName,
    required this.toolArgs,
  })  : type = AiChatMessageType.toolCall,
        text = '正在调用工具：$toolName',
        toolData = null,
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
        createdAt = DateTime.now();

  AiChatMessage.resultList({required List<Map<String, dynamic>> items})
      : type = AiChatMessageType.resultList,
        text = '共 ${items.length} 条结果',
        toolName = null,
        toolArgs = null,
        toolData = {'items': items},
        createdAt = DateTime.now();

  AiChatMessage.error(this.text)
      : type = AiChatMessageType.error,
        toolName = null,
        toolArgs = null,
        toolData = null,
        createdAt = DateTime.now();

  Map<String, dynamic> toJson() {
    return {
      'type': type.name,
      'text': text,
      if (toolName != null) 'toolName': toolName,
      if (toolArgs != null) 'toolArgs': toolArgs,
      if (toolData != null) 'toolData': toolData,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory AiChatMessage.fromJson(Map<String, dynamic> json) {
    return AiChatMessage(
      type: AiChatMessageType.values.byName(json['type'] as String),
      text: json['text'] as String,
      toolName: json['toolName'] as String?,
      toolArgs: (json['toolArgs'] as Map<String, dynamic>?)?.cast<String, dynamic>(),
      toolData: json['toolData'],
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }
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

  // 待展示的结果列表缓冲区（跨多个工具调用累积，文本回复后一并展示）
  final List<Map<String, dynamic>> _pendingResultItems = [];

  static const int _maxRounds = 3;

  AiConversationController._internal();

  /// 静态工厂方法：创建新会话或加载已有会话
  static Future<AiConversationController> create({String? loadId}) async {
    final ctrl = AiConversationController._internal();

    if (loadId != null) {
      // 加载已有会话
      final data = await AiConversationStore.loadConversation(loadId);
      if (data != null) {
        ctrl.conversationId = data['id'] as String;
        ctrl._conversationTitle = data['title'] as String;
        ctrl._createdAt = DateTime.parse(data['createdAt'] as String);

        // 恢复 displayMessages
        final dispMsgs = data['displayMessages'] as List?;
        if (dispMsgs != null) {
          ctrl.displayMessages.addAll(
            dispMsgs
                .whereType<Map<String, dynamic>>()
                .map(AiChatMessage.fromJson),
          );
        }

        // 恢复 history（先加 system，再加持久化的消息）
        ctrl._initSystemPrompt(); // system prompt
        final histMsgs = data['history'] as List?;
        if (histMsgs != null) {
          ctrl._history.addAll(
            histMsgs
                .whereType<Map<String, dynamic>>()
                .map(LlmMessage.fromJson)
                .where((m) => m.role != 'system'), // 跳过持久化的 system
          );
        }
      } else {
        // 文件不存在，创建新会话
        ctrl._createNew();
      }
    } else {
      // 创建新会话
      ctrl._createNew();
    }

    return ctrl;
  }

  /// 初始化新会话元数据
  void _createNew() {
    conversationId = _generateUuid();
    _conversationTitle = '新会话';
    _createdAt = DateTime.now();
    _pendingResultItems.clear();
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

  /// 从第一条用户消息派生会话标题
  String _deriveTitle() {
    final firstUser = displayMessages.firstWhere(
      (m) => m.type == AiChatMessageType.user,
      orElse: () => AiChatMessage.user(''),
    );
    final text = firstUser.text.trim();
    if (text.isEmpty) return '新会话';
    return text.length > 15 ? text.substring(0, 15) : text;
  }

  /// 持久化当前会话
  Future<void> _save() async {
    if (conversationId == null) return;
    _conversationTitle = _deriveTitle();
    await AiConversationStore.save(
      id: conversationId!,
      title: _conversationTitle,
      createdAt: _createdAt ?? DateTime.now(),
      displayMessages: displayMessages,
      history: _history,
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

规则：
1. 默认先查本地，不联网
2. 所有下载操作必须告知用户并等待确认，不自行触发
3. 数据来源必须透明（说明是本地库/收藏/历史/在线）
4. 字段缺失时如实说明，不猜测
5. 用中文回复
6. 工具返回漫画列表（items数组）时，文字回复只需简要总结数量、已下载/未下载等占比，不要逐条罗列或输出markdown表格，提示用户点击下方清单查看详情''';

    if (_history.isEmpty || _history.first.role != 'system') {
      _history.insert(0, LlmMessage.system(systemPrompt));
    }
  }

  /// 发送用户消息
  Future<void> send(String text) async {
    if (text.trim().isEmpty) return;
    if (isLoading) return;
    if (pendingDownload != null) {
      error = '请先处理下载确认';
      notifyListeners();
      return;
    }

    // 添加用户消息
    displayMessages.add(AiChatMessage.user(text));
    _history.add(LlmMessage.user(text));

    // 开始 LLM 循环
    isLoading = true;
    error = null;
    _currentRound = 0;
    notifyListeners();

    await _runLoop();
    await _save();
  }

  /// 工具调用循环
  Future<void> _runLoop() async {
    if (_currentRound >= _maxRounds) {
      displayMessages.add(
        AiChatMessage.assistant('已达到最大工具调用次数（$_maxRounds轮），对话结束。'),
      );
      isLoading = false;
      notifyListeners();
      return;
    }

    // 获取启用的工具 schema
    final tools = _getEnabledToolSchemas();

    // 调用 LLM
    final response = await LlmClient.chat(_history, tools: tools);

    if (response.hasError) {
      displayMessages.add(AiChatMessage.error(response.error!));
      error = response.error;
      isLoading = false;
      notifyListeners();
      return;
    }

    // 处理普通文本回复
    if (!response.hasToolCalls) {
      final text = response.content ?? '';
      displayMessages.add(AiChatMessage.assistant(text));
      _history.add(LlmMessage.assistant(content: text));
      if (_pendingResultItems.isNotEmpty) {
        displayMessages.add(AiChatMessage.resultList(items: List.of(_pendingResultItems)));
        _pendingResultItems.clear();
      }
      isLoading = false;
      notifyListeners();
      return;
    }

    // 处理工具调用
    _currentRound++;

    // 先添加 assistant message 到历史
    _history.add(
      LlmMessage.assistant(toolCalls: response.toolCalls),
    );

    // 逐个执行工具
    for (final toolCall in response.toolCalls!) {
      final toolName = toolCall.name;
      final toolArgs = toolCall.arguments;

      // 添加 toolCall 展示消息
      displayMessages.add(
        AiChatMessage.toolCall(toolName: toolName, toolArgs: toolArgs),
      );
      notifyListeners();

      // 检查是否是 download_comic
      if (toolName == 'download_comic') {
        // 挂起，等待用户确认
        pendingDownload = PendingDownload(
          toolCallId: toolCall.id,
          source: toolArgs['source']?.toString() ?? '',
          comicId: toolArgs['comicId']?.toString() ?? '',
          title: toolArgs['title']?.toString(),
        );
        notifyListeners();
        return; // 挂起，等待 confirmDownload
      }

      // 其他工具直接执行
      final result = await AiCapabilities.registry.dispatch(toolName, toolArgs);
      final resultJson = result.toJson();

      // 添加 tool result 到历史
      _history.add(
        LlmMessage.tool(
          toolCallId: toolCall.id,
          name: toolName,
          content: jsonEncode(resultJson),
        ),
      );

      // 添加 toolResult 展示消息
      displayMessages.add(
        AiChatMessage.toolResult(
          toolName: toolName,
          ok: result.ok,
          data: result.data,
          message: result.message,
        ),
      );
      if (result.data is Map) {
        final dataMap = result.data as Map;
        final rawItems = dataMap['items'];
        if (rawItems is List) {
          _pendingResultItems.addAll(rawItems.whereType<Map<String, dynamic>>());
        }
      }
      notifyListeners();
    }

    // 所有工具执行完毕，继续下一轮
    await _runLoop();
  }

  /// 确认或取消下载
  Future<void> confirmDownload(bool confirmed) async {
    if (pendingDownload == null) return;

    final pending = pendingDownload!;
    pendingDownload = null;
    notifyListeners();

    if (confirmed) {
      // 执行下载
      final result = await AiCapabilities.registry.dispatch(
        'download_comic',
        {
          'source': pending.source,
          'comicId': pending.comicId,
          if (pending.title != null) 'title': pending.title,
        },
      );

      final resultJson = result.toJson();
      _history.add(
        LlmMessage.tool(
          toolCallId: pending.toolCallId,
          name: 'download_comic',
          content: jsonEncode(resultJson),
        ),
      );

      displayMessages.add(
        AiChatMessage.toolResult(
          toolName: 'download_comic',
          ok: result.ok,
          data: result.data,
          message: result.message,
        ),
      );
    } else {
      // 用户取消
      final cancelResult = {
        'ok': false,
        'message': '用户取消了下载',
      };
      _history.add(
        LlmMessage.tool(
          toolCallId: pending.toolCallId,
          name: 'download_comic',
          content: jsonEncode(cancelResult),
        ),
      );

      displayMessages.add(
        AiChatMessage.toolResult(
          toolName: 'download_comic',
          ok: false,
          message: '用户取消了下载',
        ),
      );
    }

    notifyListeners();
    await _save();

    // 继续循环
    await _runLoop();
    await _save();
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
    final allSchemas = AiCapabilities.registry.toolSchemas();

    return allSchemas.where((schema) {
      final toolName = schema['name']?.toString() ?? '';
      return isAiCapabilityEnabled(toolName);
    }).toList();
  }
}

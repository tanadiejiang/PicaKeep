import 'dart:io';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:picakeep/foundation/app.dart';
import 'ai_conversation.dart';
import 'ai_prompt_tags.dart';
import 'ai_sources.dart';
import 'llm_client.dart';

/// 对话元数据
class AiConversationMeta {
  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;

  AiConversationMeta({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory AiConversationMeta.fromJson(Map<String, dynamic> json) {
    return AiConversationMeta(
      id: json['id'] as String,
      title: json['title'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
    );
  }
}

/// 对话持久化存储（纯静态方法）
class AiConversationStore {
  AiConversationStore._();

  static const int _maxConversations = 50;

  static Future<String> get _dir async {
    final path = '${App.dataPath}${Platform.pathSeparator}ai_conversations';
    await Directory(path).create(recursive: true);
    return path;
  }

  static String get _indexPath =>
      '${App.dataPath}${Platform.pathSeparator}ai_conversations_index.json';

  static String get _lastActiveIdPath =>
      '${App.dataPath}${Platform.pathSeparator}ai_last_active_conversation.txt';

  /// 加载对话索引
  static Future<List<AiConversationMeta>> loadIndex() async {
    try {
      final file = File(_indexPath);
      if (!await file.exists()) return [];

      final content = await file.readAsString();
      final jsonList = jsonDecode(content) as List<dynamic>;
      return jsonList
          .whereType<Map<String, dynamic>>()
          .map((json) => AiConversationMeta.fromJson(json))
          .toList();
    } catch (e) {
      print('Failed to load conversation index: $e');
      return [];
    }
  }

  /// 加载对话内容
  static Future<Map<String, dynamic>?> loadConversation(String id) async {
    try {
      final dir = await _dir;
      final file = File('$dir${Platform.pathSeparator}$id.json');
      if (!await file.exists()) return null;

      final content = await file.readAsString();
      return jsonDecode(content) as Map<String, dynamic>;
    } catch (e) {
      print('Failed to load conversation $id: $e');
      return null;
    }
  }

  @visibleForTesting
  static Map<String, dynamic> serializeConversationForTesting({
    required String id,
    required String title,
    required DateTime createdAt,
    required DateTime updatedAt,
    required List<AiChatMessage> displayMessages,
    required List<LlmMessage> history,
    Iterable<AiPromptTag> persistentPromptTags = const <AiPromptTag>[],
    Set<String>? persistentAllowedSearchSources,
    bool? persistentLocalOnly,
    bool titleIsCustom = false,
  }) {
    final json = <String, dynamic>{
      'version': 2,
      'id': id,
      'title': title,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'displayMessages':
          displayMessages.map((msg) => _serializeAiChatMessage(msg)).toList(),
      'history': history.map((msg) => msg.toJson()).toList(),
      'persistentPromptTags': _serializePersistentPromptTags(
        persistentPromptTags,
      ),
      'persistentAllowedSearchSources': _serializeAllowedSources(
        persistentAllowedSearchSources,
      ),
    };
    if (persistentLocalOnly == true) {
      json['persistentLocalOnly'] = true;
    }
    if (titleIsCustom) {
      json['titleIsCustom'] = true;
    }
    return json;
  }

  /// 保存对话
  static Future<void> save({
    required String id,
    required String title,
    required DateTime createdAt,
    required List<AiChatMessage> displayMessages,
    required List<LlmMessage> history,
    Iterable<AiPromptTag> persistentPromptTags = const <AiPromptTag>[],
    Set<String>? persistentAllowedSearchSources,
    bool? persistentLocalOnly,
    bool titleIsCustom = false,
  }) async {
    try {
      final updatedAt = DateTime.now();
      final dir = await _dir;

      final conversationJson = serializeConversationForTesting(
        id: id,
        title: title,
        createdAt: createdAt,
        updatedAt: updatedAt,
        displayMessages: displayMessages,
        history: history,
        persistentPromptTags: persistentPromptTags,
        persistentAllowedSearchSources: persistentAllowedSearchSources,
        persistentLocalOnly: persistentLocalOnly,
        titleIsCustom: titleIsCustom,
      );

      // 写入对话文件
      final file = File('$dir${Platform.pathSeparator}$id.json');
      await file.writeAsString(jsonEncode(conversationJson));

      // 更新索引
      final index = await loadIndex();
      final existingIndex = index.indexWhere((meta) => meta.id == id);

      final newMeta = AiConversationMeta(
        id: id,
        title: title,
        createdAt: createdAt,
        updatedAt: updatedAt,
      );

      if (existingIndex >= 0) {
        index[existingIndex] = newMeta;
      } else {
        index.add(newMeta);
      }

      // 按 updatedAt 降序排序
      index.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

      // 清理超量对话
      await _pruneIfNeeded(index);

      // 写回索引
      final indexFile = File(_indexPath);
      await indexFile
          .writeAsString(jsonEncode(index.map((m) => m.toJson()).toList()));
    } catch (e) {
      print('Failed to save conversation $id: $e');
    }
  }

  /// 重命名对话：只改会话文件与索引文件的 title 字段，并在会话文件里标记
  /// `titleIsCustom: true`（供 [AiConversationController] 加载时识别，跳过
  /// `_deriveTitle()` 的自动覆盖）。不走完整的 [save]，避免不必要的
  /// displayMessages/history 重复写入。`updatedAt` 保持不变——重命名不算
  /// "更新对话内容"，不应影响会话列表按 updatedAt 的排序位置。
  static Future<void> renameConversation(String id, String newTitle) async {
    final trimmed = newTitle.trim();
    if (trimmed.isEmpty) return;
    try {
      final data = await loadConversation(id);
      if (data == null) return;
      data['title'] = trimmed;
      data['titleIsCustom'] = true;
      final dir = await _dir;
      final file = File('$dir${Platform.pathSeparator}$id.json');
      await file.writeAsString(jsonEncode(data));

      final index = await loadIndex();
      final idx = index.indexWhere((meta) => meta.id == id);
      if (idx >= 0) {
        final old = index[idx];
        index[idx] = AiConversationMeta(
          id: old.id,
          title: trimmed,
          createdAt: old.createdAt,
          updatedAt: old.updatedAt,
        );
        final indexFile = File(_indexPath);
        await indexFile
            .writeAsString(jsonEncode(index.map((m) => m.toJson()).toList()));
      }
    } catch (e) {
      print('Failed to rename conversation $id: $e');
    }
  }

  /// 删除对话
  static Future<void> delete(String id) async {
    try {
      // 删除对话文件
      final dir = await _dir;
      final file = File('$dir${Platform.pathSeparator}$id.json');
      if (await file.exists()) {
        await file.delete();
      }

      // 从索引移除
      final index = await loadIndex();
      index.removeWhere((meta) => meta.id == id);

      final indexFile = File(_indexPath);
      await indexFile
          .writeAsString(jsonEncode(index.map((m) => m.toJson()).toList()));
    } catch (e) {
      print('Failed to delete conversation $id: $e');
    }
  }

  /// 加载最后活跃的对话 ID
  static Future<String?> loadLastActiveId() async {
    try {
      final file = File(_lastActiveIdPath);
      if (!await file.exists()) return null;
      return (await file.readAsString()).trim();
    } catch (e) {
      print('Failed to load last active conversation id: $e');
      return null;
    }
  }

  /// 保存最后活跃的对话 ID
  static Future<void> saveLastActiveId(String id) async {
    try {
      final file = File(_lastActiveIdPath);
      await file.writeAsString(id);
    } catch (e) {
      print('Failed to save last active conversation id: $e');
    }
  }

  /// 清理超量对话
  static Future<void> _pruneIfNeeded(List<AiConversationMeta> index) async {
    if (index.length <= _maxConversations) return;

    try {
      // 按 createdAt 排序，删除最老的
      final sorted = List<AiConversationMeta>.from(index);
      sorted.sort((a, b) => a.createdAt.compareTo(b.createdAt));

      final toDelete = sorted.take(sorted.length - _maxConversations).toList();
      final dir = await _dir;

      for (final meta in toDelete) {
        final file = File('$dir${Platform.pathSeparator}${meta.id}.json');
        if (await file.exists()) {
          await file.delete();
        }
        index.removeWhere((m) => m.id == meta.id);
      }
    } catch (e) {
      print('Failed to prune conversations: $e');
    }
  }

  /// 序列化 AiChatMessage
  static Map<String, dynamic> _serializeAiChatMessage(AiChatMessage msg) {
    final json = <String, dynamic>{
      'type': msg.type.name,
      'text': msg.text,
      'createdAt': msg.createdAt.toIso8601String(),
    };

    if (msg.toolName != null) json['toolName'] = msg.toolName;
    if (msg.toolArgs != null) json['toolArgs'] = msg.toolArgs;
    if (msg.promptTagNames.isNotEmpty) {
      json['promptTagNames'] = msg.promptTagNames;
    }

    // toolData 序列化：仅支持基本类型
    if (msg.toolData != null) {
      final data = msg.toolData;
      if (data is String || data is num || data is bool) {
        json['toolData'] = data;
      } else if (data is List || data is Map) {
        try {
          json['toolData'] = jsonDecode(jsonEncode(data));
        } catch (_) {
          // 无法序列化则跳过
        }
      }
    }

    return json;
  }

  static List<Map<String, String>> _serializePersistentPromptTags(
    Iterable<AiPromptTag> tags,
  ) {
    final byName = <String, AiPromptTag>{};
    for (final tag in tags) {
      final name = tag.name.trim().replaceFirst(RegExp(r'^#'), '');
      if (name.isEmpty || tag.prompt.trim().isEmpty) continue;
      byName[name] = tag;
    }
    return byName.entries
        .map(
          (entry) => <String, String>{
            'name': entry.key,
            'prompt': entry.value.prompt,
          },
        )
        .toList(growable: false);
  }

  static List<String>? _serializeAllowedSources(Set<String>? sources) {
    if (sources == null) return null;
    const order = <String>[
      aiSourcePicacg,
      aiSourceJm,
      aiSourceEhentai,
      aiSourceNhentai,
    ];
    final normalized =
        sources.map(normalizeAiSource).whereType<String>().toSet();
    if (normalized.isEmpty) return null;
    return order.where(normalized.contains).toList(growable: false);
  }

  /// 反序列化 AiChatMessage
  static AiChatMessage deserializeAiChatMessage(Map<String, dynamic> json) {
    final typeStr = json['type'] as String;
    final type = AiChatMessageType.values.firstWhere(
      (e) => e.name == typeStr,
      orElse: () => AiChatMessageType.assistant,
    );

    return AiChatMessage(
      type: type,
      text: json['text'] as String,
      toolName: json['toolName'] as String?,
      toolArgs: json['toolArgs'] as Map<String, dynamic>?,
      toolData: json['toolData'],
      promptTagNames:
          (json['promptTagNames'] as List?)?.map((name) => name.toString()) ??
              const <String>[],
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'] as String)
          : DateTime.now(),
    );
  }

  /// 反序列化 LlmMessage
  static LlmMessage deserializeLlmMessage(Map<String, dynamic> json) {
    final role = json['role'] as String;
    final content = json['content'] as String?;
    final toolCallsJson = json['tool_calls'] as List<dynamic>?;
    final toolCallId = json['tool_call_id'] as String?;
    final name = json['name'] as String?;

    List<LlmToolCall>? toolCalls;
    if (toolCallsJson != null) {
      toolCalls = toolCallsJson
          .whereType<Map<String, dynamic>>()
          .map((tc) => LlmToolCall.fromJson(tc))
          .toList();
    }

    return LlmMessage(
      role: role,
      content: content,
      toolCalls: toolCalls,
      toolCallId: toolCallId,
      name: name,
    );
  }
}

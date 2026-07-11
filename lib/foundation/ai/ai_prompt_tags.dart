import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

const _promptTemplatesSettingIndex = 132;
const _promptTagsLongTermSettingIndex = 136;
const _promptTemplatesInitializedSettingIndex = 137;

const aiPromptTagOnlyUserBridge = '请结合当前对话上下文，并按本轮提示词标签继续处理。';
const aiResetSourceRestrictionTagName = '不限来源';

/// 固定、只读的可见来源标签名到 `search_online.source` 的协议映射。
const aiPromptSourceTagToSource = <String, String>{
  '搜pica': 'picacg',
  '搜jm': 'jm',
  '搜eh': 'ehentai',
  '搜nh': 'nhentai',
};

/// 固定、只读的范围标签名：仅查本地设备库与已连接的远程库快照，不联网。
/// 与来源标签同属固定协议标签，不进入普通标签列表。
/// 对应可见标签为 `#搜本地`（与 `搜pica`/`搜jm` 等来源标签命名风格一致）。
const aiLocalOnlyScopeTagName = '搜本地';

const aiDefaultPromptTags = <AiPromptTag>[
  AiPromptTag(
    name: '搜角色',
    prompt: '搜索角色时，除日文、罗马音、英文全名外，还要考虑以下变体：\n'
        '1. 仅用名字不带姓：包括假名形式（如"ミヨ"而非"桜井ミヨ"）和罗马音形式（如"Miyo"而非'
        '"Sakurai Miyo"）——eh、nhentai 等站点的标题/标签尤其依赖罗马音简称，这个变体对这两个源格外重要；\n'
        '2. 中文音译名：如"ミヨ"的中文常见译名"美代"——中文汉化版标题和标签大量使用音译；\n'
        '3. 玩家/粉丝昵称或简称；\n'
        '全名搜索结果偏少时，依次尝试上述变体，不要只用一种形式就结束。简称/译名结果混杂时结合所属作品名和题材消歧，'
        '排除明显不相关结果。',
  ),
  AiPromptTag(
    name: '搜题材',
    prompt: '按题材/主题搜索时，先考虑同义词、近义概念和子分类，多角度组合尝试，不只使用一个关键词。',
  ),
  AiPromptTag(
    name: '搜标签',
    prompt: '按标签搜索时尝试相关或近义标签组合；结果稀少时放宽过窄标签或更换组合后重试。',
  ),
  AiPromptTag(
    name: aiResetSourceRestrictionTagName,
    prompt: '搜索时不限定单一站点；在可用来源中尝试并汇总。该标签同时表示清除当前/长期来源硬限制。',
  ),
  AiPromptTag(
    name: '结果不足重试',
    prompt: '搜索结果明显偏少时，更换关键词、别名、语言形式或筛选条件后至少再尝试一种策略，不直接把少量结果当最终答案。',
  ),
];

@immutable
class AiPromptTag {
  const AiPromptTag({required this.name, required this.prompt});

  /// 存储时不带前导 `#`。
  final String name;
  final String prompt;

  AiPromptTag copyWith({String? name, String? prompt}) => AiPromptTag(
        name: name ?? this.name,
        prompt: prompt ?? this.prompt,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'prompt': prompt,
      };

  factory AiPromptTag.fromJson(Map<String, dynamic> json) {
    final name = json['name'] ?? json['title'] ?? json['label'];
    final prompt =
        json['prompt'] ?? json['content'] ?? json['template'] ?? json['value'];
    if (name is! String || prompt is! String) {
      throw const FormatException('提示词标签必须包含字符串 name 和 prompt');
    }
    return AiPromptTag(name: name, prompt: prompt);
  }

  @override
  bool operator ==(Object other) =>
      other is AiPromptTag && other.name == name && other.prompt == prompt;

  @override
  int get hashCode => Object.hash(name, prompt);

  @override
  String toString() => 'AiPromptTag(name: $name, prompt: $prompt)';
}

@immutable
class AiPromptTagParseResult {
  AiPromptTagParseResult({
    required this.displayText,
    required this.userText,
    required Iterable<AiPromptTag> promptTags,
    required Iterable<String> sourceTags,
    required this.resetSourceRestriction,
    required Iterable<String> recognizedNames,
    this.localOnly = false,
  })  : promptTags = List<AiPromptTag>.unmodifiable(promptTags),
        sourceTags = Set<String>.unmodifiable(sourceTags),
        recognizedNames = List<String>.unmodifiable(recognizedNames);

  final String displayText;
  final String userText;
  final List<AiPromptTag> promptTags;

  /// `search_online.source` 的值，而不是可见标签名。
  final Set<String> sourceTags;
  final bool resetSourceRestriction;

  /// 不带 `#`，按首次出现顺序去重。
  final List<String> recognizedNames;

  /// 是否识别到固定范围标签 `#搜本地`（仅本地设备库/已连接远程库快照，不联网）。
  /// 与 [sourceTags] 可同时为真：本地限定优先，来源集合本身不清空，
  /// 由下游控制器在计算"有效范围"时以本地限定为准。
  final bool localOnly;
}

@immutable
class AiPromptTagInitializationResult {
  AiPromptTagInitializationResult({
    required Iterable<AiPromptTag> promptTags,
    required this.promptTemplatesJson,
    required this.initializedValue,
    required this.valuesChanged,
    required this.installedDefaults,
    this.decodeError,
  }) : promptTags = List<AiPromptTag>.unmodifiable(promptTags);

  final List<AiPromptTag> promptTags;
  final String promptTemplatesJson;
  final String initializedValue;
  final bool valuesChanged;
  final bool installedDefaults;
  final String? decodeError;

  bool get hasDecodeError => decodeError != null;
}

String normalizeAiPromptTagName(String value) {
  var normalized = value.trim();
  if (normalized.startsWith('#')) {
    normalized = normalized.substring(1).trim();
  }
  return normalized;
}

/// 返回面向用户的校验错误；返回 null 表示合法。
String? validateAiPromptTagName(
  String value, {
  Iterable<String> existingNames = const <String>[],
  String? originalName,
}) {
  final name = normalizeAiPromptTagName(value);
  if (name.isEmpty) return '标签名不能为空';
  if (name.contains('#')) return '标签名不能包含额外的 #';
  if (RegExp(r'\s', unicode: true).hasMatch(name)) {
    return '标签名不能包含空格或换行';
  }
  if (aiPromptSourceTagToSource.containsKey(name)) {
    return '#$name 是固定来源标签，不能作为普通标签使用';
  }
  if (name == aiLocalOnlyScopeTagName) {
    return '#$name 是固定范围标签，不能作为普通标签使用';
  }

  final ignoredName =
      originalName == null ? null : normalizeAiPromptTagName(originalName);
  if (existingNames.any((item) {
    final existing = normalizeAiPromptTagName(item);
    return existing == name && existing != ignoredName;
  })) {
    return '标签名 #$name 已存在';
  }
  return null;
}

List<AiPromptTag> validateAiPromptTags(Iterable<AiPromptTag> tags) {
  final result = <AiPromptTag>[];
  final names = <String>[];
  for (final tag in tags) {
    final normalizedName = normalizeAiPromptTagName(tag.name);
    final error = validateAiPromptTagName(
      normalizedName,
      existingNames: names,
    );
    if (error != null) throw FormatException(error);
    names.add(normalizedName);
    result.add(AiPromptTag(name: normalizedName, prompt: tag.prompt));
  }
  return List<AiPromptTag>.unmodifiable(result);
}

String encodeAiPromptTags(Iterable<AiPromptTag> tags) =>
    jsonEncode(validateAiPromptTags(tags).map((tag) => tag.toJson()).toList());

/// 解码当前数组格式，并兼容旧的 `{ "tags": [...] }` 包装格式、
/// `{ "标签名": "提示词" }` 映射格式以及常见旧字段名。
List<AiPromptTag> decodeAiPromptTags(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return const <AiPromptTag>[];

  final dynamic decoded;
  try {
    decoded = jsonDecode(trimmed);
  } on FormatException catch (error) {
    throw FormatException('提示词标签 JSON 无法解析：${error.message}');
  }

  late final Iterable<AiPromptTag> tags;
  if (decoded is List<dynamic>) {
    tags = decoded.map(_decodePromptTagItem);
  } else if (decoded is Map<String, dynamic>) {
    final wrappedTags = decoded['tags'];
    if (wrappedTags is List<dynamic>) {
      tags = wrappedTags.map(_decodePromptTagItem);
    } else {
      tags = decoded.entries.map((entry) {
        if (entry.value is! String) {
          throw const FormatException('旧版提示词标签映射的值必须是字符串');
        }
        return AiPromptTag(name: entry.key, prompt: entry.value as String);
      });
    }
  } else {
    throw const FormatException('提示词标签 JSON 顶层必须是数组或对象');
  }
  return validateAiPromptTags(tags);
}

AiPromptTag _decodePromptTagItem(dynamic item) {
  if (item is! Map) {
    throw const FormatException('提示词标签数组元素必须是对象');
  }
  return AiPromptTag.fromJson(Map<String, dynamic>.from(item));
}

String? sourceForAiPromptTagName(String name) =>
    aiPromptSourceTagToSource[normalizeAiPromptTagName(name)];

String? aiPromptTagNameForSource(String source) {
  for (final entry in aiPromptSourceTagToSource.entries) {
    if (entry.value == source) return entry.key;
  }
  return null;
}

/// 纯逻辑的一次性初始化决策。非法原始 JSON 会原样保留，只回退为空列表。
AiPromptTagInitializationResult initializeAiPromptTagSettings({
  required String promptTemplatesJson,
  required String initializedValue,
}) {
  List<AiPromptTag> tags;
  String? decodeError;
  try {
    tags = decodeAiPromptTags(promptTemplatesJson);
  } on FormatException catch (error) {
    tags = const <AiPromptTag>[];
    decodeError = error.message;
  }

  var nextJson = promptTemplatesJson;
  var installedDefaults = false;
  final needsInitialization = initializedValue != '1';
  if (needsInitialization && decodeError == null && tags.isEmpty) {
    tags = aiDefaultPromptTags;
    nextJson = encodeAiPromptTags(tags);
    installedDefaults = true;
  }

  final nextInitializedValue = needsInitialization ? '1' : initializedValue;
  return AiPromptTagInitializationResult(
    promptTags: tags,
    promptTemplatesJson: nextJson,
    initializedValue: nextInitializedValue,
    valuesChanged: nextJson != promptTemplatesJson ||
        nextInitializedValue != initializedValue,
    installedDefaults: installedDefaults,
    decodeError: decodeError,
  );
}

AiPromptTagParseResult parseAiPromptTags(
  String displayText, {
  Iterable<AiPromptTag> promptTags = const <AiPromptTag>[],
  bool resetSourceRestriction = false,
}) {
  final validatedTags = validateAiPromptTags(promptTags);
  final ordinaryByName = <String, AiPromptTag>{
    for (final tag in validatedTags) tag.name: tag,
  };
  final matchNames = <String>{
    ...ordinaryByName.keys,
    ...aiPromptSourceTagToSource.keys,
    aiLocalOnlyScopeTagName,
  }.toList()
    ..sort((a, b) {
      final lengthOrder = b.length.compareTo(a.length);
      return lengthOrder != 0 ? lengthOrder : a.compareTo(b);
    });

  final matches = <_PromptTagMatch>[];
  var index = 0;
  while (index < displayText.length) {
    if (displayText.codeUnitAt(index) != 0x23 ||
        !_isPromptTagBoundary(displayText, index - 1)) {
      index++;
      continue;
    }

    _PromptTagMatch? found;
    for (final name in matchNames) {
      final token = '#$name';
      if (!displayText.startsWith(token, index)) continue;
      final end = index + token.length;
      if (!_isPromptTagBoundary(displayText, end)) continue;
      found = _PromptTagMatch(start: index, end: end, name: name);
      break;
    }
    if (found == null) {
      index++;
      continue;
    }
    matches.add(found);
    index = found.end;
  }

  final recognizedNames = <String>[];
  final recognizedNameSet = <String>{};
  final selectedPromptTags = <AiPromptTag>[];
  final selectedPromptNames = <String>{};
  final selectedSources = <String>{};
  var shouldResetSources = resetSourceRestriction;
  var localOnly = false;

  for (final match in matches) {
    if (recognizedNameSet.add(match.name)) recognizedNames.add(match.name);
    final ordinaryTag = ordinaryByName[match.name];
    if (ordinaryTag != null && selectedPromptNames.add(match.name)) {
      selectedPromptTags.add(ordinaryTag);
    }
    final source = aiPromptSourceTagToSource[match.name];
    if (source != null) selectedSources.add(source);
    if (match.name == aiResetSourceRestrictionTagName) {
      shouldResetSources = true;
    }
    if (match.name == aiLocalOnlyScopeTagName) {
      localOnly = true;
    }
  }

  if (shouldResetSources) selectedSources.clear();

  final buffer = StringBuffer();
  var previousEnd = 0;
  for (final match in matches) {
    buffer.write(displayText.substring(previousEnd, match.start));
    previousEnd = match.end;
  }
  buffer.write(displayText.substring(previousEnd));
  final strippedText = _cleanPromptTagStrippedText(buffer.toString());

  return AiPromptTagParseResult(
    displayText: displayText,
    userText: strippedText.isEmpty ? aiPromptTagOnlyUserBridge : strippedText,
    promptTags: selectedPromptTags,
    sourceTags: selectedSources,
    resetSourceRestriction: shouldResetSources,
    recognizedNames: recognizedNames,
    localOnly: localOnly,
  );
}

bool _isPromptTagBoundary(String text, int index) {
  if (index < 0 || index >= text.length) return true;
  final character = text.substring(index, index + 1);
  return RegExp(r'''[\s#，。！？、,.!?;；:：()（）\[\]{}<>《》“”"'`~…]''')
      .hasMatch(character);
}

String _cleanPromptTagStrippedText(String value) => value
    .replaceAll(RegExp(r'[ \t]+'), ' ')
    .replaceAll(RegExp(r' *\n *'), '\n')
    .replaceAll(RegExp(r'\n{3,}'), '\n\n')
    .trim();

class _PromptTagMatch {
  const _PromptTagMatch({
    required this.start,
    required this.end,
    required this.name,
  });

  final int start;
  final int end;
  final String name;
}

/// 设置页与所有已打开聊天页面应共同监听此单例。
class AiPromptTagSettingsController extends ChangeNotifier {
  AiPromptTagSettingsController._();

  static final AiPromptTagSettingsController instance =
      AiPromptTagSettingsController._();

  List<String> Function()? _settingsProvider;
  FutureOr<void> Function()? _persistSettings;
  List<AiPromptTag> _promptTags = const <AiPromptTag>[];
  bool _longTermEnabled = false;
  bool _isInitialized = false;
  String? _loadError;
  Future<void>? _initializing;

  /// 绑定应用的 settings 存储。`base.dart` 在创建/重建 Appdata 时调用。
  AiPromptTagSettingsController configureStorage({
    required List<String> Function() settingsProvider,
    required FutureOr<void> Function() persistSettings,
  }) {
    _settingsProvider = settingsProvider;
    _persistSettings = persistSettings;
    _promptTags = const <AiPromptTag>[];
    _longTermEnabled = false;
    _isInitialized = false;
    _loadError = null;
    _initializing = null;
    return this;
  }

  /// 仅供纯逻辑测试或隔离存储环境使用；应用代码应使用 [instance]。
  @visibleForTesting
  factory AiPromptTagSettingsController.detached({
    required List<String> settings,
    FutureOr<void> Function()? persistSettings,
  }) {
    return AiPromptTagSettingsController._().configureStorage(
      settingsProvider: () => settings,
      persistSettings: persistSettings ?? () {},
    );
  }

  List<AiPromptTag> get promptTags => _promptTags;
  List<AiPromptTag> get tags => promptTags;
  bool get longTermEnabled => _longTermEnabled;
  bool get isLongTermEnabled => longTermEnabled;
  bool get isInitialized => _isInitialized;
  String? get loadError => _loadError;
  bool get hasInvalidStoredJson => _loadError != null;

  Future<void> initialize() {
    final pending = _initializing;
    if (pending != null) return pending;
    final future = _initialize();
    _initializing = future;
    return future.whenComplete(() {
      if (identical(_initializing, future)) _initializing = null;
    });
  }

  Future<void> refresh() => initialize();

  Future<void> _initialize() async {
    final settings = _checkedSettings();
    final result = initializeAiPromptTagSettings(
      promptTemplatesJson: settings[_promptTemplatesSettingIndex],
      initializedValue: settings[_promptTemplatesInitializedSettingIndex],
    );
    if (result.valuesChanged) {
      settings[_promptTemplatesSettingIndex] = result.promptTemplatesJson;
      settings[_promptTemplatesInitializedSettingIndex] =
          result.initializedValue;
      await _persist();
    }

    final nextLongTerm = settings[_promptTagsLongTermSettingIndex] == '1';
    final shouldNotify = !_isInitialized ||
        !listEquals(_promptTags, result.promptTags) ||
        _longTermEnabled != nextLongTerm ||
        _loadError != result.decodeError;
    _promptTags = result.promptTags;
    _longTermEnabled = nextLongTerm;
    _loadError = result.decodeError;
    _isInitialized = true;
    if (shouldNotify) notifyListeners();
  }

  Future<void> setPromptTags(Iterable<AiPromptTag> tags) async {
    await initialize();
    final normalized = validateAiPromptTags(tags);
    if (listEquals(_promptTags, normalized) && _loadError == null) return;
    final settings = _checkedSettings();
    settings[_promptTemplatesSettingIndex] = encodeAiPromptTags(normalized);
    settings[_promptTemplatesInitializedSettingIndex] = '1';
    await _persist();
    _promptTags = normalized;
    _loadError = null;
    notifyListeners();
  }

  Future<void> addTag(AiPromptTag tag) async {
    await initialize();
    await setPromptTags(<AiPromptTag>[..._promptTags, tag]);
  }

  Future<void> updateTag(String oldName, AiPromptTag tag) async {
    await initialize();
    final normalizedOldName = normalizeAiPromptTagName(oldName);
    final index = _promptTags.indexWhere(
      (item) => item.name == normalizedOldName,
    );
    if (index < 0) throw StateError('找不到提示词标签 #$normalizedOldName');
    final updated = List<AiPromptTag>.of(_promptTags)..[index] = tag;
    await setPromptTags(updated);
  }

  Future<void> removeTag(String name) async {
    await initialize();
    final normalizedName = normalizeAiPromptTagName(name);
    final updated = _promptTags
        .where((tag) => tag.name != normalizedName)
        .toList(growable: false);
    if (updated.length == _promptTags.length) return;
    await setPromptTags(updated);
  }

  Future<void> deleteTag(String name) => removeTag(name);

  Future<void> clearTags() => setPromptTags(const <AiPromptTag>[]);

  Future<void> restoreDefaults() => setPromptTags(aiDefaultPromptTags);

  Future<void> setLongTermEnabled(bool value) async {
    await initialize();
    if (_longTermEnabled == value) return;
    final settings = _checkedSettings();
    settings[_promptTagsLongTermSettingIndex] = value ? '1' : '0';
    await _persist();
    _longTermEnabled = value;
    notifyListeners();
  }

  List<String> _checkedSettings() {
    final provider = _settingsProvider;
    if (provider == null || _persistSettings == null) {
      throw StateError('AiPromptTagSettingsController 尚未绑定 settings 存储');
    }
    final settings = provider();
    if (settings.length <= _promptTemplatesInitializedSettingIndex) {
      throw StateError(
        'settings 长度 ${settings.length} 不足，至少需要 '
        '${_promptTemplatesInitializedSettingIndex + 1} 项',
      );
    }
    return settings;
  }

  Future<void> _persist() async {
    final persist = _persistSettings;
    if (persist == null) {
      throw StateError('AiPromptTagSettingsController 尚未绑定 settings 存储');
    }
    await persist();
  }
}

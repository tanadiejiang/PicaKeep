part of 'settings_page.dart';

class AiSettingsPage extends StatefulWidget {
  const AiSettingsPage({this.width = 0, super.key});

  final double width;

  @override
  State<AiSettingsPage> createState() => _AiSettingsPageState();
}

class _AiSettingsPageState extends State<AiSettingsPage> {
  bool _providerExpanded = false;
  bool _showApiKey = false;

  // 15轮03号计划：OCR 配置区折叠态与 API Key 遮蔽态。
  bool _ocrExpanded = false;
  bool _showOcrApiKey = false;

  static const _templateBaseUrls = <String, String>{
    'openai_compat': 'http://localhost:11434/v1',
    'ollama': 'http://localhost:11434',
    'deepseek': 'https://api.deepseek.com',
    'openai': 'https://api.openai.com/v1',
    'custom': '',
  };

  /// Base URL 留空时按模板展示的占位提示（仅提示，不写入 settings；
  /// DeepSeek 模板留空时 [LlmClient.chat] 会在实际请求时 fallback 到该地址）。
  static const _templateBaseUrlHints = <String, String>{
    'openai_compat': 'http://localhost:11434/v1',
    'ollama': 'http://localhost:11434',
    'deepseek': 'https://api.deepseek.com',
    'openai': 'https://api.openai.com/v1',
    'custom': 'http://localhost:11434/v1',
  };

  /// DeepSeek 模板下的 Model ID 候选项；[_ModelIdAutocompleteField] 用它做下拉
  /// 建议，同时仍允许直接输入其他任意值。
  static const _deepseekModelPresets = <String>[
    'deepseek-v4-flash',
    'deepseek-v4-pro',
  ];

  bool get _anyCapabilityEnabled {
    return [
      aiCapabilitySearchOnlineSettingIndex,
      aiCapabilityDownloadComicSettingIndex,
      aiCapabilitySearchLocalSettingIndex,
      aiCapabilityQueryLocalLibrarySettingIndex,
      aiCapabilityResolveLocalItemsSettingIndex,
      aiCapabilityGetDownloadStatusSettingIndex,
      aiCapabilityQueryRemoteLibrarySettingIndex,
      aiCapabilityGetComicDetailSettingIndex,
      aiCapabilitySearchByImageSettingIndex,
    ].any((idx) => appdata.settings[idx] == '1');
  }

  void _setSetting(int index, String value) {
    setState(() {
      appdata.settings[index] = value;
    });
    appdata.updateSettings();
    if (index == showAiTabSettingIndex) {
      App.serviceConfigVersion.value++;
    }
  }

  void _toggleCapability(int index) {
    _setSetting(index, appdata.settings[index] == '1' ? '0' : '1');
  }

  Widget _buildSwitch({
    required String title,
    String? subtitle,
    required int settingIndex,
    Widget? leading,
  }) {
    return SwitchListTile(
      secondary: leading,
      title: Text(title),
      subtitle: subtitle != null ? Text(subtitle) : null,
      value: appdata.settings[settingIndex] == '1',
      onChanged: (_) => _toggleCapability(settingIndex),
    );
  }

  Widget _buildMaxToolRoundsTile() {
    const options = <String, String>{
      '5': '5 轮（默认）',
      '8': '8 轮',
      '12': '12 轮',
      '20': '20 轮',
      '0': '不限制',
    };
    final current = appdata.settings[aiMaxToolRoundsSettingIndex];
    final displayValue = options.containsKey(current) ? current : '5';
    return ListTile(
      leading: const Icon(Icons.loop_outlined),
      title: Text('最大工具调用轮次'.tl),
      subtitle: Text('每次对话最多进行多少轮工具调用；不限制时由模型自行判断结束'.tl),
      trailing: DropdownButton<String>(
        value: displayValue,
        underline: const SizedBox.shrink(),
        items: options.entries
            .map(
              (e) => DropdownMenuItem<String>(
                value: e.key,
                child: Text(e.value),
              ),
            )
            .toList(),
        onChanged: (v) {
          if (v != null) _setSetting(aiMaxToolRoundsSettingIndex, v);
        },
      ),
    );
  }

  /// 17号计划步骤 10：迷你索引条刻度上限。
  /// 结构照抄 [_buildMaxToolRoundsTile]，'0' 表示不限制（与 aiMaxToolRounds 同约定）。
  Widget _buildIndexBarMaxTicksTile() {
    const options = <String, String>{
      '4': '4 条',
      '6': '6 条（默认）',
      '8': '8 条',
      '12': '12 条',
      '24': '24 条',
      '0': '不限制',
    };
    final current = appdata.settings[aiIndexBarMaxTicksSettingIndex];
    final displayValue = options.containsKey(current) ? current : '6';
    return ListTile(
      leading: const Icon(Icons.drag_handle),
      title: Text('索引条刻度上限'.tl),
      subtitle: Text('只影响聊天页右边缘迷你索引条的横线数量；索引面板内始终列出全部'.tl),
      trailing: DropdownButton<String>(
        value: displayValue,
        underline: const SizedBox.shrink(),
        items: options.entries
            .map(
              (e) => DropdownMenuItem<String>(
                value: e.key,
                child: Text(e.value),
              ),
            )
            .toList(),
        onChanged: (v) {
          if (v != null) _setSetting(aiIndexBarMaxTicksSettingIndex, v);
        },
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
      ),
    );
  }

  Widget _buildProviderSection() {
    final template = appdata.settings[aiProviderTemplateSettingIndex];
    final baseUrlHint = _templateBaseUrlHints[template] ??
        _templateBaseUrlHints['openai_compat']!;
    final modelPresets =
        template == 'deepseek' ? _deepseekModelPresets : const <String>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          title: Text('Provider 配置'.tl),
          subtitle: _anyCapabilityEnabled
              ? null
              : Text('请先开启至少一项能力'.tl,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  )),
          trailing: _anyCapabilityEnabled
              ? Icon(
                  _providerExpanded ? Icons.expand_less : Icons.expand_more,
                )
              : null,
          onTap: _anyCapabilityEnabled
              ? () => setState(() {
                    _providerExpanded = !_providerExpanded;
                  })
              : null,
        ),
        if (_anyCapabilityEnabled && _providerExpanded) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: DropdownButtonFormField<String>(
              decoration: InputDecoration(
                labelText: 'Provider 模板'.tl,
                border: const OutlineInputBorder(),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              initialValue: template.isEmpty ? null : template,
              hint: Text('请选择'.tl),
              items: const [
                DropdownMenuItem(
                    value: 'openai_compat',
                    child: Text('OpenAI 兼容 (Ollama 等)')),
                DropdownMenuItem(value: 'ollama', child: Text('Ollama')),
                DropdownMenuItem(value: 'deepseek', child: Text('DeepSeek')),
                DropdownMenuItem(value: 'openai', child: Text('OpenAI')),
                DropdownMenuItem(value: 'custom', child: Text('自定义')),
              ],
              onChanged: (value) {
                if (value == null) return;
                final defaultUrl = _templateBaseUrls[value] ?? '';
                setState(() {
                  appdata.settings[aiProviderTemplateSettingIndex] = value;
                  if (defaultUrl.isNotEmpty) {
                    appdata.settings[aiBaseUrlSettingIndex] = defaultUrl;
                  }
                });
                appdata.updateSettings();
              },
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _EditableSettingField(
              label: 'Base URL'.tl,
              settingIndex: aiBaseUrlSettingIndex,
              hint: baseUrlHint,
              onChanged: (v) {
                setState(() {
                  appdata.settings[aiBaseUrlSettingIndex] = v;
                });
                appdata.updateSettings();
              },
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _ObscurableSettingField(
              label: 'API Key'.tl,
              settingIndex: aiApiKeySettingIndex,
              obscure: !_showApiKey,
              onToggleObscure: () => setState(() => _showApiKey = !_showApiKey),
              onChanged: (v) {
                setState(() {
                  appdata.settings[aiApiKeySettingIndex] = v;
                });
                appdata.updateSettings();
              },
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _ModelIdField(
              settingIndex: aiModelIdSettingIndex,
              presets: modelPresets,
              hint: modelPresets.isEmpty ? 'gpt-4o-mini' : modelPresets.first,
              onChanged: (v) {
                setState(() {
                  appdata.settings[aiModelIdSettingIndex] = v;
                });
                appdata.updateSettings();
              },
            ),
          ),
          // 15轮03号计划：视觉开关（属主模型属性，放 Provider 配置区内）。
          _buildSwitch(
            title: '当前模型支持图片识别（视觉）'.tl,
            subtitle: '开启后图片直接发给模型；关闭后先经 OCR 转文字'.tl,
            settingIndex: aiModelSupportsVisionSettingIndex,
            leading: const Icon(Icons.remove_red_eye_outlined),
          ),
          // 15轮06号计划：思考两个独立开关（请求侧 / 展示侧）。
          _buildSwitch(
            title: '开启思考'.tl,
            subtitle:
                '关闭时请求带 thinking:disabled；仅 DeepSeek 等支持该字段的服务生效，其他服务如报错请保持开启'
                    .tl,
            settingIndex: aiThinkingEnabledSettingIndex,
            leading: const Icon(Icons.psychology_outlined),
          ),
          _buildSwitch(
            title: '显示思考过程'.tl,
            subtitle: '在会话中流式展示并可展开思考；关闭后仍会接收并保存思考内容'.tl,
            settingIndex: aiShowReasoningSettingIndex,
            leading: const Icon(Icons.visibility_outlined),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _EditableSettingField(
              label: '其他参数（JSON）'.tl,
              settingIndex: aiModelParamsSettingIndex,
              hint: '{"temperature": 0.7}',
              maxLines: 3,
              onChanged: (v) {
                setState(() {
                  appdata.settings[aiModelParamsSettingIndex] = v;
                });
                appdata.updateSettings();
              },
            ),
          ),
          const SizedBox(height: 12),
        ],
      ],
    );
  }

  final AiPromptTagSettingsController _promptTagSettings =
      AiPromptTagSettingsController.instance;

  // ── 15轮03号计划：OCR 接口配置区 ──────────────────────────────────────────

  /// 三个预设模板（决策F，写死为 const）。端点/字段名/取值路径取自各项目公开
  /// 文档（Umi-OCR HTTP API、PaddleOCR hubserving、PaddleX 服务化部署），
  /// 未对真实服务实测，属待验证假设；实测有误时另开计划改表即可。
  static const _ocrTemplatePresets = <String, Map<String, Object?>>{
    'umi': {
      'baseUrl': 'http://127.0.0.1:1224/api/ocr',
      'imageField': 'base64',
      'imageEncoding': 'b64',
      'extraBody': {
        'options': {'data.format': 'text'},
      },
      'resultPath': 'data',
    },
    'paddle_hub': {
      'baseUrl': 'http://127.0.0.1:8866/predict/ocr_system',
      'imageField': 'images',
      'imageEncoding': 'b64_array',
      'extraBody': <String, Object?>{},
      'resultPath': 'results[0][*].text',
    },
    'paddlex': {
      'baseUrl': 'http://127.0.0.1:8080/ocr',
      'imageField': 'file',
      'imageEncoding': 'b64',
      'extraBody': {'fileType': 1},
      'resultPath': 'result.ocrResults[0].prunedResult.rec_texts[*]',
    },
  };

  /// 读 144 号槽位的 OCR 配置 JSON；坏 JSON/非 Map 一律回退空表（防御式）。
  Map<String, dynamic> _readOcrConfig() {
    try {
      final decoded = jsonDecode(appdata.settings[aiOcrConfigSettingIndex]);
      if (decoded is Map<String, dynamic>) return Map.of(decoded);
    } catch (_) {}
    return <String, dynamic>{};
  }

  /// 所有 OCR 字段读写都走 144 这一个 JSON（合并写回）。
  void _updateOcrConfig(String key, Object? value) {
    final config = _readOcrConfig();
    config[key] = value;
    _setSetting(aiOcrConfigSettingIndex, jsonEncode(config));
  }

  /// 选中预设模板：一次性回填 template/imageField/imageEncoding/extraBody/
  /// resultPath，并在端点为空时填默认端点（思路同 Provider 模板回填）。
  void _applyOcrTemplate(String template) {
    final config = _readOcrConfig();
    config['template'] = template;
    final preset = _ocrTemplatePresets[template];
    if (preset != null) {
      config['imageField'] = preset['imageField'];
      config['imageEncoding'] = preset['imageEncoding'];
      config['extraBody'] = preset['extraBody'];
      config['resultPath'] = preset['resultPath'];
      final currentUrl = config['baseUrl'];
      if (currentUrl is! String || currentUrl.trim().isEmpty) {
        config['baseUrl'] = preset['baseUrl'];
      }
    }
    _setSetting(aiOcrConfigSettingIndex, jsonEncode(config));
  }

  Widget _buildOcrSection() {
    final config = _readOcrConfig();
    final type = config['type'] == 'generic' ? 'generic' : 'vision';
    final template = _ocrTemplatePresets.containsKey(config['template'])
        ? config['template'] as String
        : '';
    final extraBody = config['extraBody'];
    final extraBodyText = extraBody is Map
        ? jsonEncode(extraBody)
        : (extraBody?.toString() ?? '{}');
    String stringOf(String key) {
      final value = config[key];
      return value is String ? value : '';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          title: Text('OCR 接口（图片转文字兜底）'.tl),
          subtitle: _anyCapabilityEnabled
              ? null
              : Text('请先开启至少一项能力'.tl,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  )),
          trailing: _anyCapabilityEnabled
              ? Icon(_ocrExpanded ? Icons.expand_less : Icons.expand_more)
              : null,
          onTap: _anyCapabilityEnabled
              ? () => setState(() {
                    _ocrExpanded = !_ocrExpanded;
                  })
              : null,
        ),
        if (_anyCapabilityEnabled && _ocrExpanded) ...[
          SwitchListTile(
            secondary: const Icon(Icons.document_scanner_outlined),
            title: Text('启用 OCR 兜底'.tl),
            subtitle: Text('模型未声明支持视觉时，先把图片经 OCR 转成文字随消息发送'.tl),
            value: config['enabled'] == true,
            onChanged: (v) => _updateOcrConfig('enabled', v),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: DropdownButtonFormField<String>(
              decoration: InputDecoration(
                labelText: '接口类型'.tl,
                border: const OutlineInputBorder(),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              initialValue: type,
              items: const [
                DropdownMenuItem(value: 'vision', child: Text('OpenAI 兼容视觉模型')),
                DropdownMenuItem(
                    value: 'generic', child: Text('通用 OCR HTTP 服务')),
              ],
              onChanged: (v) {
                if (v != null) _updateOcrConfig('type', v);
              },
            ),
          ),
          const SizedBox(height: 12),
          if (type == 'vision') ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _OcrTextField(
                label: 'Base URL'.tl,
                value: stringOf('baseUrl'),
                hint: 'http://localhost:11434/v1',
                onChanged: (v) => _updateOcrConfig('baseUrl', v),
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _OcrTextField(
                label: 'API Key'.tl,
                value: stringOf('apiKey'),
                obscure: !_showOcrApiKey,
                onToggleObscure: () =>
                    setState(() => _showOcrApiKey = !_showOcrApiKey),
                onChanged: (v) => _updateOcrConfig('apiKey', v),
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _OcrTextField(
                label: '模型名'.tl,
                value: stringOf('modelId'),
                hint: 'qwen-vl-max / llava 等',
                onChanged: (v) => _updateOcrConfig('modelId', v),
              ),
            ),
          ] else ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: DropdownButtonFormField<String>(
                decoration: InputDecoration(
                  labelText: '服务模板'.tl,
                  border: const OutlineInputBorder(),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
                initialValue: template,
                items: const [
                  DropdownMenuItem(value: '', child: Text('自定义')),
                  DropdownMenuItem(value: 'umi', child: Text('Umi-OCR')),
                  DropdownMenuItem(
                      value: 'paddle_hub',
                      child: Text('PaddleOCR hub serving')),
                  DropdownMenuItem(value: 'paddlex', child: Text('PaddleX')),
                ],
                onChanged: (v) {
                  if (v != null) _applyOcrTemplate(v);
                },
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _OcrTextField(
                label: '端点 URL（完整，不拼接）'.tl,
                value: stringOf('baseUrl'),
                hint: 'http://127.0.0.1:1224/api/ocr',
                onChanged: (v) => _updateOcrConfig('baseUrl', v),
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _OcrTextField(
                label: '鉴权头（Header名:值，可空）'.tl,
                value: stringOf('authHeader'),
                hint: 'Authorization:Bearer xxx',
                onChanged: (v) => _updateOcrConfig('authHeader', v),
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _OcrTextField(
                label: '图片字段名'.tl,
                value: stringOf('imageField'),
                hint: 'base64',
                onChanged: (v) => _updateOcrConfig('imageField', v),
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: DropdownButtonFormField<String>(
                decoration: InputDecoration(
                  labelText: '编码形态'.tl,
                  border: const OutlineInputBorder(),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
                initialValue: const {'b64', 'b64_array', 'data_uri'}
                        .contains(config['imageEncoding'])
                    ? config['imageEncoding'] as String
                    : 'b64',
                items: const [
                  DropdownMenuItem(value: 'b64', child: Text('纯 base64')),
                  DropdownMenuItem(
                      value: 'b64_array', child: Text('base64 包数组')),
                  DropdownMenuItem(
                      value: 'data_uri', child: Text('data URI 带前缀')),
                ],
                onChanged: (v) {
                  if (v != null) _updateOcrConfig('imageEncoding', v);
                },
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _OcrTextField(
                label: '额外请求体 JSON'.tl,
                value: extraBodyText,
                hint: '{"options":{"data.format":"text"}}',
                maxLines: 3,
                // 合法 JSON 对象存 Map；中间态/非法 JSON 原样存字符串保住用户
                // 输入（AiOcrConfig.fromSettings 对非 Map 防御式回退空表）。
                onChanged: (v) {
                  Object? parsed;
                  try {
                    parsed = jsonDecode(v);
                  } catch (_) {
                    parsed = null;
                  }
                  _updateOcrConfig('extraBody', parsed is Map ? parsed : v);
                },
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _OcrTextField(
                label: '结果取值路径'.tl,
                value: stringOf('resultPath'),
                hint: 'data 或 results[0][*].text',
                onChanged: (v) => _updateOcrConfig('resultPath', v),
              ),
            ),
          ],
          const SizedBox(height: 12),
        ],
      ],
    );
  }

  @override
  void initState() {
    super.initState();
    unawaited(_initializePromptTagSettings());
  }

  Future<void> _initializePromptTagSettings() async {
    try {
      await _promptTagSettings.initialize();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('读取提示词标签失败：$error')),
      );
    }
  }

  String? _validatePromptTagName(String value, {String? originalName}) {
    return validateAiPromptTagName(
      value,
      existingNames: _promptTagSettings.tags.map((tag) => tag.name),
      originalName: originalName,
    )?.tl;
  }

  Future<void> _runPromptTagMutation(
    FutureOr<void> Function() mutation,
    String failureMessage,
  ) async {
    try {
      await mutation();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$failureMessage：$error')),
      );
    }
  }

  Future<void> _showPromptTagEditor({AiPromptTag? original}) async {
    final nameController = TextEditingController(text: original?.name ?? '');
    final promptController =
        TextEditingController(text: original?.prompt ?? '');
    String? nameError;
    String? promptError;
    final result = await showDialog<AiPromptTag>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          void submit() {
            final nextNameError = _validatePromptTagName(
              nameController.text,
              originalName: original?.name,
            );
            final nextPromptError =
                promptController.text.trim().isEmpty ? '完整提示词内容不能为空'.tl : null;
            if (nextNameError != null || nextPromptError != null) {
              setDialogState(() {
                nameError = nextNameError;
                promptError = nextPromptError;
              });
              return;
            }
            Navigator.of(dialogContext).pop(
              AiPromptTag(
                name: normalizeAiPromptTagName(nameController.text),
                prompt: promptController.text.trim(),
              ),
            );
          }

          return AlertDialog(
            title: Text(original == null ? '新增普通标签'.tl : '编辑普通标签'.tl),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameController,
                      autofocus: true,
                      decoration: InputDecoration(
                        labelText: '标签名称'.tl,
                        hintText: '例如：搜角色（可输入前导 #）'.tl,
                        errorText: nameError,
                        border: const OutlineInputBorder(),
                      ),
                      textInputAction: TextInputAction.next,
                      onChanged: (_) {
                        if (nameError != null) {
                          setDialogState(() => nameError = null);
                        }
                      },
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: promptController,
                      minLines: 4,
                      maxLines: 8,
                      decoration: InputDecoration(
                        labelText: '完整提示词'.tl,
                        hintText: '输入选择该标签后提供给 AI 的完整引导内容'.tl,
                        errorText: promptError,
                        alignLabelWithHint: true,
                        border: const OutlineInputBorder(),
                      ),
                      onChanged: (_) {
                        if (promptError != null) {
                          setDialogState(() => promptError = null);
                        }
                      },
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: Text('取消'.tl),
              ),
              FilledButton(onPressed: submit, child: Text('保存'.tl)),
            ],
          );
        },
      ),
    );
    nameController.dispose();
    promptController.dispose();
    if (result == null || !mounted) return;
    await _runPromptTagMutation(
      () => original == null
          ? _promptTagSettings.addTag(result)
          : _promptTagSettings.updateTag(original.name, result),
      original == null ? '新增标签失败'.tl : '编辑标签失败'.tl,
    );
  }

  Future<void> _confirmDeletePromptTag(AiPromptTag tag) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text('删除普通标签'.tl),
            content: Text(
              '确定删除 #${tag.name}？此操作不会修改已保存到会话中的长期标签快照。'.tl,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text('取消'.tl),
              ),
              FilledButton.tonal(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text('删除'.tl),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    await _runPromptTagMutation(
      () => _promptTagSettings.deleteTag(tag.name),
      '删除标签失败'.tl,
    );
  }

  Future<void> _confirmRestoreDefaultPromptTags() async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text('恢复默认普通标签'.tl),
            content: Text(
              '这会用五个默认普通标签替换当前普通标签列表，现有自定义标签将被移除。是否继续？'.tl,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text('取消'.tl),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text('恢复默认'.tl),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    await _runPromptTagMutation(
      _promptTagSettings.restoreDefaults,
      '恢复默认标签失败'.tl,
    );
  }

  Widget _buildPromptTagSection() {
    return AnimatedBuilder(
      animation: _promptTagSettings,
      builder: (context, _) {
        final tags = _promptTagSettings.tags;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildSectionTitle('提示词标签'.tl),
            if (!_promptTagSettings.isInitialized)
              const LinearProgressIndicator()
            else if (_promptTagSettings.loadError != null)
              ListTile(
                leading: Icon(
                  Icons.warning_amber_rounded,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: Text('已保存的标签数据无法解析'.tl),
                subtitle: Text(
                  '当前暂时显示空列表，原始数据不会被静默覆盖；可点击“恢复默认”重新建立五个默认标签。'.tl,
                ),
              ),
            SwitchListTile(
              secondary: const Icon(Icons.all_inclusive),
              title: Text('长期生效'.tl),
              subtitle: Text(
                (_promptTagSettings.longTermEnabled
                        ? '已开启：新选择会写入当前会话，之后轮次和重开会话继续有效。'
                        : '已关闭：新选择仅对当前一次完整回复/工具循环有效。')
                    .tl,
              ),
              value: _promptTagSettings.longTermEnabled,
              onChanged: (value) => _runPromptTagMutation(
                () => _promptTagSettings.setLongTermEnabled(value),
                '更新长期生效设置失败'.tl,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                '关闭开关只影响后续选择，不会自动清除已写入会话的长期标签或来源；请在聊天快捷面板中显式清除。'.tl,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.public_outlined),
              title: Text('固定来源标签（只读）'.tl),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (final name in aiPromptSourceTagToSource.keys)
                      InputChip(
                        label: Text("#$name"),
                        onPressed: null,
                        tooltip: '固定来源协议，不可编辑'.tl,
                      ),
                    Text(
                      '不选 = 全部来源'.tl,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                alignment: WrapAlignment.end,
                children: [
                  Text(
                    '普通标签'.tl,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  TextButton.icon(
                    onPressed: _confirmRestoreDefaultPromptTags,
                    icon: const Icon(Icons.restore),
                    label: Text('恢复默认'.tl),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: _showPromptTagEditor,
                    icon: const Icon(Icons.add),
                    label: Text('新增'.tl),
                  ),
                ],
              ),
            ),
            if (tags.isEmpty)
              ListTile(
                leading: const Icon(Icons.label_off_outlined),
                title: Text('暂无普通标签'.tl),
                subtitle: Text('可新增自定义标签，或恢复五个默认标签。'.tl),
              )
            else
              for (final tag in tags)
                ListTile(
                  leading: const Icon(Icons.tag),
                  title: Text('#${tag.name}'),
                  subtitle: Text(
                    tag.prompt,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Wrap(
                    spacing: 0,
                    children: [
                      IconButton(
                        tooltip: '编辑'.tl,
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () => _showPromptTagEditor(original: tag),
                      ),
                      IconButton(
                        tooltip: '删除'.tl,
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _confirmDeletePromptTag(tag),
                      ),
                    ],
                  ),
                ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return buildTwoColumnLayout(widget.width, [
      _buildSectionTitle('底栏'.tl),
      _buildSwitch(
        title: '显示 AI 标签页'.tl,
        settingIndex: showAiTabSettingIndex,
        leading: const Icon(Icons.smart_toy_outlined),
      ),
      const Divider(),
      _buildSectionTitle('能力开关'.tl),
      _buildSwitch(
        title: '在线搜索'.tl,
        settingIndex: aiCapabilitySearchOnlineSettingIndex,
        leading: const Icon(Icons.travel_explore),
      ),
      _buildSwitch(
        title: '下载漫画'.tl,
        subtitle: '开启「允许AI自动下载」后无需确认，直接加入下载队列'.tl,
        settingIndex: aiCapabilityDownloadComicSettingIndex,
        leading: const Icon(Icons.download_outlined),
      ),
      // 16轮05：仅当下载能力主开关开启时显示子toggle
      if (appdata.settings[aiCapabilityDownloadComicSettingIndex] == '1')
        Padding(
          padding: const EdgeInsetsDirectional.only(start: 32),
          child: _buildSwitch(
            title: '允许AI自动下载'.tl,
            subtitle: '开启后无需逐项确认；关闭后 AI 无法自行发起下载'.tl,
            settingIndex: aiAutoDownloadEnabledSettingIndex,
            leading: const Icon(Icons.bolt_outlined),
          ),
        ),
      _buildSwitch(
        title: '本地库问答'.tl,
        settingIndex: aiCapabilityQueryLocalLibrarySettingIndex,
        leading: const Icon(Icons.library_books_outlined),
      ),
      _buildSwitch(
        title: '批量解析'.tl,
        settingIndex: aiCapabilityResolveLocalItemsSettingIndex,
        leading: const Icon(Icons.format_list_bulleted),
      ),
      _buildSwitch(
        title: '查询下载状态'.tl,
        settingIndex: aiCapabilityGetDownloadStatusSettingIndex,
        leading: const Icon(Icons.info_outline),
      ),
      _buildSwitch(
        title: '查看详情（不下载）'.tl,
        subtitle: 'get_comic_detail：按源和ID查看漫画完整详情，不加入下载队列'.tl,
        settingIndex: aiCapabilityGetComicDetailSettingIndex,
        leading: const Icon(Icons.visibility_outlined),
      ),
      _buildSwitch(
        title: '远程库查询'.tl,
        subtitle: '查询远程服务器已下载漫画（需已连接远程服务）'.tl,
        settingIndex: aiCapabilityQueryRemoteLibrarySettingIndex,
        leading: const Icon(Icons.cloud_done_outlined),
      ),
      _buildSwitch(
        title: '展示搜索清单'.tl,
        subtitle: 'display_result_list：将筛选后的漫画以清单卡片展示'.tl,
        settingIndex: aiCapabilityDisplayResultListSettingIndex,
        leading: const Icon(Icons.list_alt_outlined),
      ),
      _buildSwitch(
        title: '收藏管理'.tl,
        subtitle: 'manage_favorites：创建/删除收藏夹，添加/移除收藏'.tl,
        settingIndex: aiCapabilityManageFavoritesSettingIndex,
        leading: const Icon(Icons.bookmark_add_outlined),
      ),
      _buildSwitch(
        title: '以图搜源'.tl,
        subtitle:
            'search_by_image：对聊天中发送的图片在 soutubot.moe 反向搜索（需通过 Cloudflare 验证）'
                .tl,
        settingIndex: aiCapabilitySearchByImageSettingIndex,
        leading: const Icon(Icons.image_search_outlined),
      ),
      _buildMaxToolRoundsTile(),
      const Divider(),
      // 17号计划步骤 10：消息索引相关设置。
      _buildSectionTitle('消息索引'.tl),
      _buildSwitch(
        title: '消息索引仅显示用户对话'.tl,
        subtitle: '关闭后 AI 回复也会进入索引面板'.tl,
        settingIndex: aiIndexUserOnlySettingIndex,
        leading: const Icon(Icons.person_outline),
      ),
      _buildIndexBarMaxTicksTile(),
      const Divider(),
      _buildProviderSection(),
      const Divider(),
      // 15轮03号计划：OCR 接口配置区。
      _buildOcrSection(),
      const Divider(),
      _buildPromptTagSection(),
      const Divider(),
      _buildSectionTitle('调试'.tl),
      ListTile(
        leading: const Icon(Icons.build_outlined),
        title: Text('AI 工具调试'.tl),
        subtitle: Text('查看工具列表、测试调用、检查开关状态'.tl),
        trailing: const Icon(Icons.chevron_right),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (ctx) => const AiToolDebugPage(),
            ),
          );
        },
      ),
    ]);
  }
}

class _EditableSettingField extends StatefulWidget {
  const _EditableSettingField({
    required this.label,
    required this.settingIndex,
    this.hint = '',
    this.maxLines = 1,
    required this.onChanged,
  });

  final String label;
  final int settingIndex;
  final String hint;
  final int maxLines;
  final ValueChanged<String> onChanged;

  @override
  State<_EditableSettingField> createState() => _EditableSettingFieldState();
}

class _EditableSettingFieldState extends State<_EditableSettingField> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: appdata.settings[widget.settingIndex]);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _ctrl,
      maxLines: widget.maxLines,
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hint,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      onChanged: widget.onChanged,
    );
  }
}

class _ObscurableSettingField extends StatefulWidget {
  const _ObscurableSettingField({
    required this.label,
    required this.settingIndex,
    required this.obscure,
    required this.onToggleObscure,
    required this.onChanged,
  });

  final String label;
  final int settingIndex;
  final bool obscure;
  final VoidCallback onToggleObscure;
  final ValueChanged<String> onChanged;

  @override
  State<_ObscurableSettingField> createState() =>
      _ObscurableSettingFieldState();
}

class _ObscurableSettingFieldState extends State<_ObscurableSettingField> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: appdata.settings[widget.settingIndex]);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _ctrl,
      obscureText: widget.obscure,
      decoration: InputDecoration(
        labelText: widget.label,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        suffixIcon: IconButton(
          icon: Icon(widget.obscure ? Icons.visibility_off : Icons.visibility),
          onPressed: widget.onToggleObscure,
        ),
      ),
      onChanged: widget.onChanged,
    );
  }
}

/// Model ID 输入框：`presets` 非空时表现为"文本框 + 聚焦/输入即弹出候选下拉"
/// （类似 Provider 模板下拉框的框内展开体验），同时保留自由输入任意值的能力；
/// `presets` 为空时退化为普通文本框。切换 Provider 模板导致 `presets`/底层
/// setting 值变化时，通过 [didUpdateWidget] 同步文本框显示，不需要外部改 key。
class _ModelIdField extends StatefulWidget {
  const _ModelIdField({
    required this.settingIndex,
    required this.presets,
    this.hint = '',
    required this.onChanged,
  });

  final int settingIndex;
  final List<String> presets;
  final String hint;
  final ValueChanged<String> onChanged;

  @override
  State<_ModelIdField> createState() => _ModelIdFieldState();
}

class _ModelIdFieldState extends State<_ModelIdField> {
  late TextEditingController _ctrl;
  late FocusNode _focusNode;

  // 15轮06号计划：模型列表拉取态。拉到了就只显示拉取结果（决策5），
  // 失败退回预置/手输并在 helperText 提示。
  List<String>? _fetchedModels;
  bool _loading = false;
  String? _fetchError;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: appdata.settings[widget.settingIndex]);
    _focusNode = FocusNode();
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(_ModelIdField oldWidget) {
    super.didUpdateWidget(oldWidget);
    final current = appdata.settings[widget.settingIndex];
    if (_ctrl.text != current) {
      _ctrl.text = current;
    }
    // 切模板（presets 变化）时作废上一模板的拉取结果。
    // 本文件是 settings_page.dart 的 part，不能自带 import；material 的
    // re-export 不含 foundation 的 listEquals，故手写等价比较。
    if (!_sameStringList(widget.presets, oldWidget.presets)) {
      _fetchedModels = null;
      _fetchError = null;
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChanged);
    _ctrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    // “展开就自动获取”：下拉靠聚焦触发，聚焦瞬间即拉取。缓存 + in-flight
    // 去重保证反复聚焦不重复请求（成功 10 分钟 / 失败 30 秒内直接命中）。
    if (_focusNode.hasFocus) _triggerFetch();
  }

  Future<void> _triggerFetch() async {
    setState(() {
      _loading = true;
      _fetchError = null;
    });
    final result = await ModelListClient.fetch();
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (result.ok) {
        _fetchedModels = result.models; // 决策5：成功后只显示拉取到的
        _fetchError = null;
      } else {
        _fetchedModels = null; // 失败退回预置/手输
        _fetchError = result.error;
      }
    });
    _refreshOptionsView();
  }

  /// 拉取结果就绪后强制 RawAutocomplete 重跑 optionsBuilder：
  /// RawAutocomplete 只监听 controller/focus 变化，外部 setState 不会刷新
  /// 已弹出的候选层。用 composing 微扰（同文本、不同 composing）触发两次
  /// value 变更再复原，文本与光标不动。
  void _refreshOptionsView() {
    if (!_focusNode.hasFocus) return;
    final value = _ctrl.value;
    _ctrl.value = value.copyWith(composing: const TextRange(start: 0, end: 0));
    _ctrl.value = value;
  }

  List<String> get _effectivePresets =>
      (_fetchedModels != null && _fetchedModels!.isNotEmpty)
          ? _fetchedModels!
          : widget.presets;

  static bool _sameStringList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    // 15轮06号计划：所有模板都可能拉到列表，统一走 RawAutocomplete
    // （options 为空时候选层本来就不显示，行为等同普通输入框）。
    return RawAutocomplete<String>(
      textEditingController: _ctrl,
      focusNode: _focusNode,
      optionsBuilder: (textEditingValue) {
        final presets = _effectivePresets;
        final query = textEditingValue.text.trim().toLowerCase();
        // 文本为空，或当前文本本身就是某个预设的完整值（意味着用户是刚选中/
        // 尚未主动做过筛选输入），都展示全部预设，而不是按 contains 收窄成
        // 只剩自己一项——否则点开下拉会看不到另一个预设选项。
        final isExactPreset = presets.any((p) => p.toLowerCase() == query);
        if (query.isEmpty || isExactPreset) return presets;
        return presets.where((p) => p.toLowerCase().contains(query));
      },
      onSelected: widget.onChanged,
      fieldViewBuilder: (context, controller, focusNode, onSubmitted) {
        return TextField(
          controller: controller,
          focusNode: focusNode,
          decoration: InputDecoration(
            labelText: 'Model ID'.tl,
            hintText: widget.hint,
            border: const OutlineInputBorder(),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            helperText:
                _fetchError == null ? null : '模型列表获取失败：$_fetchError（可手动输入）',
            helperMaxLines: 2,
            helperStyle: TextStyle(
                color: Theme.of(context).colorScheme.error, fontSize: 11),
            suffixIcon: _loading
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                // 点箭头：已展开则折叠（unfocus），未展开则聚焦+拉取。
                : IconButton(
                    icon: const Icon(Icons.arrow_drop_down),
                    onPressed: () {
                      if (_focusNode.hasFocus) {
                        _focusNode.unfocus();
                      } else {
                        _focusNode.requestFocus();
                        _triggerFetch();
                      }
                    },
                  ),
          ),
          onChanged: widget.onChanged,
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(4),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 200),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: options.length,
                itemBuilder: (context, index) {
                  final option = options.elementAt(index);
                  return ListTile(
                    dense: true,
                    title: Text(option),
                    onTap: () => onSelected(option),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 15轮03号计划：OCR 配置 JSON 子字段的文本框。
/// 既有 [_EditableSettingField]/[_ObscurableSettingField] 绑定整个 settingIndex
/// 槽位，不能复用于 JSON 子字段；本组件把 `settingIndex` 换成 `value` 初值 +
/// `onChanged` 回调，并加可选 `obscure`/`onToggleObscure` 覆盖 API Key 场景。
/// 模板回填等外部改值经 [didUpdateWidget] 同步显示；用户自己键入时
/// `value == _ctrl.text`，不会重置光标。
class _OcrTextField extends StatefulWidget {
  const _OcrTextField({
    required this.label,
    required this.value,
    this.hint = '',
    this.maxLines = 1,
    this.obscure = false,
    this.onToggleObscure,
    required this.onChanged,
  });

  final String label;
  final String value;
  final String hint;
  final int maxLines;
  final bool obscure;
  final VoidCallback? onToggleObscure;
  final ValueChanged<String> onChanged;

  @override
  State<_OcrTextField> createState() => _OcrTextFieldState();
}

class _OcrTextFieldState extends State<_OcrTextField> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.value);
  }

  @override
  void didUpdateWidget(_OcrTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value && widget.value != _ctrl.text) {
      _ctrl.text = widget.value;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _ctrl,
      maxLines: widget.obscure ? 1 : widget.maxLines,
      obscureText: widget.obscure,
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hint,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        suffixIcon: widget.onToggleObscure == null
            ? null
            : IconButton(
                icon: Icon(
                  widget.obscure ? Icons.visibility_off : Icons.visibility,
                ),
                onPressed: widget.onToggleObscure,
              ),
      ),
      onChanged: widget.onChanged,
    );
  }
}

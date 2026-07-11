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

  static const _templateBaseUrls = <String, String>{
    'openai_compat': 'http://localhost:11434/v1',
    'ollama': 'http://localhost:11434',
    'deepseek': 'https://api.deepseek.com',
    'openai': 'https://api.openai.com/v1',
    'custom': '',
  };

  static const _templateModelHints = <String, String>{
    'openai_compat': 'qwen3:8b',
    'ollama': 'qwen3:8b',
    'deepseek': 'deepseek-chat',
    'openai': 'gpt-4o-mini',
    'custom': '',
  };

  bool get _anyCapabilityEnabled {
    return [
      aiCapabilitySearchOnlineSettingIndex,
      aiCapabilityDownloadComicSettingIndex,
      aiCapabilitySearchLocalSettingIndex,
      aiCapabilityQueryLocalLibrarySettingIndex,
      aiCapabilityResolveLocalItemsSettingIndex,
      aiCapabilityGetDownloadStatusSettingIndex,
      aiCapabilityQueryRemoteLibrarySettingIndex,
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
    final modelHint = _templateModelHints[template] ?? '';
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
              hint: 'http://localhost:11434/v1',
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
            child: _EditableSettingField(
              label: 'Model ID'.tl,
              settingIndex: aiModelIdSettingIndex,
              hint: modelHint.isEmpty ? 'gpt-4o-mini' : modelHint,
              onChanged: (v) {
                setState(() {
                  appdata.settings[aiModelIdSettingIndex] = v;
                });
                appdata.updateSettings();
              },
            ),
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
        subtitle: '每次下载均需二次确认'.tl,
        settingIndex: aiCapabilityDownloadComicSettingIndex,
        leading: const Icon(Icons.download_outlined),
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
      _buildMaxToolRoundsTile(),
      const Divider(),
      _buildProviderSection(),
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

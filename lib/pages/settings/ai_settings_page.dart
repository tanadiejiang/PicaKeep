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
                  _providerExpanded
                      ? Icons.expand_less
                      : Icons.expand_more,
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
                    value: 'openai_compat', child: Text('OpenAI 兼容 (Ollama 等)')),
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
              onToggleObscure: () =>
                  setState(() => _showApiKey = !_showApiKey),
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
      const Divider(),
      _buildProviderSection(),
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
    _ctrl = TextEditingController(
        text: appdata.settings[widget.settingIndex]);
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
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
    _ctrl = TextEditingController(
        text: appdata.settings[widget.settingIndex]);
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
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        suffixIcon: IconButton(
          icon: Icon(
              widget.obscure ? Icons.visibility_off : Icons.visibility),
          onPressed: widget.onToggleObscure,
        ),
      ),
      onChanged: widget.onChanged,
    );
  }
}

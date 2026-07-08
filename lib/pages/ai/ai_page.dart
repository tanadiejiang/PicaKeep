import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:picakeep/foundation/ai/ai_capabilities.dart';
import 'package:picakeep/foundation/ai/ai_settings.dart';
import 'package:picakeep/pages/ai/ai_chat_page.dart';
import 'package:picakeep/tools/translations.dart';

class AiPage extends StatelessWidget {
  const AiPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const AiChatPage();
  }
}

class AiToolDebugPage extends StatefulWidget {
  const AiToolDebugPage({super.key});

  @override
  State<AiToolDebugPage> createState() => _AiToolDebugPageState();
}

class _AiToolDebugPageState extends State<AiToolDebugPage> {
  late final List<Map<String, Object?>> _schemas;

  @override
  void initState() {
    super.initState();
    AiCapabilities.ensureRegistered();
    _schemas = AiCapabilities.registry.toolSchemas();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('AI 工具调试'.tl),
      ),
      body: CustomScrollView(
        slivers: [
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => _ToolCard(schema: _schemas[index]),
              childCount: _schemas.length,
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }
}

class _ToolCard extends StatefulWidget {
  const _ToolCard({required this.schema});

  final Map<String, Object?> schema;

  @override
  State<_ToolCard> createState() => _ToolCardState();
}

class _ToolCardState extends State<_ToolCard> {
  bool _expanded = false;
  bool _loading = false;
  Map<String, Object?>? _result;
  late final TextEditingController _argsCtrl;

  String get _toolName => widget.schema['name']?.toString() ?? '';

  bool get _enabled => isAiCapabilityEnabled(_toolName);

  @override
  void initState() {
    super.initState();
    _argsCtrl = TextEditingController(text: '{}');
  }

  @override
  void dispose() {
    _argsCtrl.dispose();
    super.dispose();
  }

  void _formatJson() {
    try {
      final obj = jsonDecode(_argsCtrl.text);
      final formatted =
          const JsonEncoder.withIndent('  ').convert(obj);
      setState(() {
        _argsCtrl.value = TextEditingValue(
          text: formatted,
          selection: TextSelection.collapsed(offset: formatted.length),
        );
      });
    } catch (_) {}
  }

  Future<void> _invoke() async {
    if (!_enabled) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('请先在 设置→AI 中开启此能力'.tl),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }

    Map<String, dynamic> parsedArgs;
    try {
      final decoded = jsonDecode(_argsCtrl.text);
      if (decoded is Map) {
        parsedArgs =
            decoded.map((k, v) => MapEntry(k.toString(), v));
      } else {
        parsedArgs = {};
      }
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('参数 JSON 格式错误'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    if (_toolName == 'download_comic') {
      final confirmed = await _showDownloadConfirm(parsedArgs);
      if (confirmed != true) return;
    }

    setState(() {
      _loading = true;
      _result = null;
    });

    final result =
        await AiCapabilities.registry.dispatch(_toolName, parsedArgs);

    if (!mounted) return;
    setState(() {
      _loading = false;
      _result = result.toJson();
    });
  }

  Future<bool?> _showDownloadConfirm(Map<String, dynamic> args) {
    final source = args['source']?.toString() ?? '?';
    final comicId = args['comicId']?.toString() ?? '?';
    final title = args['title']?.toString() ?? '未知';
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('确认下载'.tl),
        content: Text('确认下载「$title」？\n来源：$source，ID：$comicId'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消'.tl),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('确认下载'.tl),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final name = _toolName;
    final description =
        widget.schema['description']?.toString() ?? '';
    final schemaJson = const JsonEncoder.withIndent('  ')
        .convert(widget.schema['parameters'] ?? {});
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            title: Text(
              name,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Text(
              description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Chip(
              label: Text(
                _enabled ? '已开启'.tl : '未开启'.tl,
                style: TextStyle(
                  fontSize: 11,
                  color: _enabled
                      ? colorScheme.onSecondaryContainer
                      : colorScheme.onSurfaceVariant,
                ),
              ),
              backgroundColor: _enabled
                  ? colorScheme.secondaryContainer
                  : colorScheme.surfaceContainerHighest,
              padding: EdgeInsets.zero,
            ),
            onTap: () => setState(() => _expanded = !_expanded),
          ),
          if (_expanded) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Parameters Schema'.tl,
                      style:
                          Theme.of(context).textTheme.labelMedium),
                  const SizedBox(height: 4),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      schemaJson,
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 11),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Text('参数 (JSON)'.tl,
                            style:
                                Theme.of(context).textTheme.labelMedium),
                      ),
                      TextButton(
                        onPressed: _formatJson,
                        child: Text('格式化'.tl),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  TextField(
                    controller: _argsCtrl,
                    maxLines: 5,
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 12),
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.all(8),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: _loading
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                                strokeWidth: 2),
                          )
                        : FilledButton(
                            onPressed: _invoke,
                            child: Text('调用'.tl),
                          ),
                  ),
                  if (_result != null) ...[
                    const SizedBox(height: 12),
                    _ResultView(result: _result!),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ResultView extends StatelessWidget {
  const _ResultView({required this.result});

  final Map<String, Object?> result;

  @override
  Widget build(BuildContext context) {
    final ok = result['ok'] == true;
    final colorScheme = Theme.of(context).colorScheme;
    final color = ok ? colorScheme.tertiary : colorScheme.error;
    final prettyJson =
        const JsonEncoder.withIndent('  ').convert(result);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 1),
        const SizedBox(height: 8),
        Text(
          ok ? '成功'.tl : '失败'.tl,
          style: TextStyle(
              color: color, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: color.withValues(alpha: 0.3)),
          ),
          child: Text(
            prettyJson,
            style: const TextStyle(
                fontFamily: 'monospace', fontSize: 11),
          ),
        ),
      ],
    );
  }
}

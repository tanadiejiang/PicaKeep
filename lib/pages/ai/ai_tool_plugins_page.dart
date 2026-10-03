import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:picakeep/foundation/ai/ai_tool_plugin_runtime.dart';
import 'package:picakeep/foundation/ai/ai_tool_plugin_store.dart';

/// Installed adapters can change independently of the application package.
class AiToolPluginsPage extends StatefulWidget {
  const AiToolPluginsPage({
    super.key,
    this.store,
    this.pickManifest,
    this.diagnose,
  });

  final AiToolPluginStore? store;
  final Future<String?> Function()? pickManifest;
  final Future<Map<String, Object?>> Function(String id)? diagnose;

  @override
  State<AiToolPluginsPage> createState() => _AiToolPluginsPageState();
}

class _AiToolPluginsPageState extends State<AiToolPluginsPage> {
  late final AiToolPluginStore _store =
      widget.store ?? AiToolPluginStore.instance;
  bool _loading = true;
  bool _busy = false;
  bool _showProgress = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      await _store.load();
    } catch (_) {
      if (mounted) _loadError = '无法读取工具插件，请重试';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _showProgress = true;
    });
    try {
      await action();
    } on FormatException catch (error) {
      _message(error.message);
    } on FileSystemException {
      _message('无法读写插件文件，请检查存储权限和可用空间后重试');
    } catch (_) {
      _message('操作未完成，请稍后重试');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _showProgress = false;
        });
      }
    }
  }

  Future<T?> _dialog<T>(WidgetBuilder builder) async {
    setState(() => _showProgress = false);
    try {
      return await showDialog<T>(context: context, builder: builder);
    } finally {
      if (mounted) setState(() => _showProgress = true);
    }
  }

  Future<String?> _pickManifest() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json'],
      allowMultiple: false,
    );
    final chosen = result?.files.singleOrNull;
    if (chosen == null) return null;
    if (chosen.size > 65536) throw const FormatException('插件清单不能超过 64KB');
    final bytes = chosen.bytes;
    if (bytes != null) {
      if (bytes.length > 65536) throw const FormatException('插件清单不能超过 64KB');
      return utf8.decode(bytes);
    }
    final path = chosen.path;
    if (path == null) throw const FormatException('未能读取所选文件，请重新选择');
    final file = File(path);
    if (await file.length() > 65536) {
      throw const FormatException('插件清单不能超过 64KB');
    }
    // Read at most one byte over the bound if the file changes after stat.
    final data = <int>[];
    await for (final chunk in file.openRead(0, 65537)) {
      data.addAll(chunk);
    }
    if (data.length > 65536) throw const FormatException('插件清单不能超过 64KB');
    return utf8.decode(data);
  }

  Future<void> _import() => _run(() async {
        final text = await (widget.pickManifest?.call() ?? _pickManifest());
        if (text == null || !mounted) return;
        if (utf8.encode(text).length > 65536) {
          throw const FormatException('插件清单不能超过 64KB');
        }
        final raw = jsonDecode(text);
        if (raw is! Map) throw const FormatException('插件清单必须为 JSON 对象');
        final plugin = AiToolPlugin.fromJson(Map<String, dynamic>.from(raw));
        final existing = _store.record(plugin.id);
        final accepted = await _dialog<bool>(
          (context) => AlertDialog(
            title: Text(existing == null ? '导入工具插件' : '更新工具插件'),
            content: SingleChildScrollView(
                child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(plugin.name,
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 12),
                Text(existing == null
                    ? '版本 ${plugin.version}'
                    : '${existing.plugin.version} → ${plugin.version}'),
                const SizedBox(height: 12),
                const Text('使用时会访问以下服务：'),
                const SizedBox(height: 4),
                SelectableText(plugin.endpoint.toString()),
                const SizedBox(height: 12),
                Text(plugin.kind == 'image_search'
                    ? '搜图时会发送你在当前对话中选择的图片。'
                    : '查询时会发送 AI 根据当前对话填写的查询参数。'),
                if (existing != null) ...[
                  const SizedBox(height: 12),
                  const Text('更新后保留上一版本，方便回退。'),
                ],
              ],
            )),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('取消')),
              FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(existing == null ? '导入' : '更新')),
            ],
          ),
        );
        if (accepted != true || !mounted) return;
        await _store.importManifest(text);
        _message('已${existing == null ? '导入' : '更新'} ${plugin.name}，下次调用生效');
      });

  Future<void> _showText(String title, String text) async {
    if (!mounted) return;
    await _dialog<void>((context) => AlertDialog(
          title: Text(title),
          content: SizedBox(
              width: 560,
              child: SingleChildScrollView(child: SelectableText(text))),
          actions: [
            TextButton(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: text));
                  _message('已复制');
                },
                child: const Text('复制')),
            FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('完成')),
          ],
        ));
  }

  Future<void> _action(AiToolPluginRecord record, String action) =>
      _run(() async {
        final plugin = record.plugin;
        switch (action) {
          case 'diagnose':
            final result = await (widget.diagnose?.call(plugin.id) ??
                diagnoseAiToolPlugin(plugin.id, store: _store));
            await _showText('${plugin.name} · 诊断',
                const JsonEncoder.withIndent('  ').convert(result));
          case 'export':
            await _showText(
                '${plugin.name} · 导出清单', _store.exportManifest(plugin.id));
          case 'rollback':
            await _store.rollback(plugin.id);
            _message('已恢复 ${_store.record(plugin.id)?.plugin.version}');
          case 'builtin':
            await _store.restoreBuiltin();
            _message('已恢复内置搜图插件并启用');
          case 'remove':
            final confirmed = await _dialog<bool>((context) => AlertDialog(
                  title: const Text('移除工具插件'),
                  content: Text('移除“${plugin.name}”后，AI 将不能再调用这个工具。'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('取消')),
                    FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('移除')),
                  ],
                ));
            if (confirmed != true || !mounted) return;
            await _store.remove(plugin.id);
            _message('已移除 ${plugin.name}');
        }
      });

  Widget _pluginCard(AiToolPluginRecord record) {
    final plugin = record.plugin;
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12),
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(color: theme.colorScheme.outlineVariant)),
      child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(
                    plugin.kind == 'image_search'
                        ? Icons.image_search_outlined
                        : Icons.extension_outlined,
                    color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                    child:
                        Text(plugin.name, style: theme.textTheme.titleMedium)),
                Semantics(
                  label: '${record.enabled ? '关闭' : '启用'}${plugin.name}',
                  child: Switch(
                    value: record.enabled,
                    onChanged: _busy
                        ? null
                        : (value) =>
                            _run(() => _store.setEnabled(plugin.id, value)),
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: '${plugin.name}操作',
                  enabled: !_busy,
                  onSelected: (value) => _action(record, value),
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'diagnose', child: Text('诊断连接')),
                    const PopupMenuItem(value: 'export', child: Text('导出清单')),
                    PopupMenuItem(
                        value: 'rollback',
                        enabled: record.previous != null,
                        child: Text(record.previous == null
                            ? '暂无上一版本'
                            : '恢复上一版本 ${record.previous!.version}')),
                    if (plugin.id == builtinImagePluginId)
                      const PopupMenuItem(
                          value: 'builtin', child: Text('恢复内置版本'))
                    else
                      const PopupMenuItem(value: 'remove', child: Text('移除插件')),
                  ],
                ),
              ]),
              const SizedBox(height: 8),
              Text(
                  '${plugin.kind == 'image_search' ? '以图搜源' : '在线查询'} · ${plugin.version}',
                  style: theme.textTheme.bodyMedium),
              const SizedBox(height: 4),
              Text(plugin.endpoint.host,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              if (!record.enabled)
                Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text('已停用', style: theme.textTheme.labelMedium)),
            ],
          )),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AI 工具插件')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(_loadError!),
                  TextButton(onPressed: _load, child: const Text('重试')),
                ]))
              : ListenableBuilder(
                  listenable: _store,
                  builder: (context, _) => Align(
                        alignment: Alignment.topCenter,
                        child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 760),
                            child: ListView(
                              padding: const EdgeInsets.all(16),
                              children: [
                                Text('让工具保持可用',
                                    style: Theme.of(context)
                                        .textTheme
                                        .headlineSmall),
                                const SizedBox(height: 8),
                                Text('导入新的工具，或更新现有工具的接口规则。启用后仍遵循对话的能力开关与联网范围。',
                                    style:
                                        Theme.of(context).textTheme.bodyMedium),
                                const SizedBox(height: 16),
                                Align(
                                    alignment: Alignment.centerLeft,
                                    child: FilledButton.icon(
                                      onPressed: _busy ? null : _import,
                                      icon: const Icon(Icons.add),
                                      label: const Text('从文件导入'),
                                    )),
                                if (_showProgress)
                                  const Padding(
                                      padding: EdgeInsets.only(top: 12),
                                      child: LinearProgressIndicator()),
                                if (_store.loadWarning != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 12),
                                    child: Text(_store.loadWarning!,
                                        style: TextStyle(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .error)),
                                  ),
                                const SizedBox(height: 20),
                                ..._store.records.map(_pluginCard),
                                const SizedBox(height: 8),
                                Card(
                                  elevation: 0,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .surfaceContainerLow,
                                  child: SwitchListTile(
                                    value: _store.maintenanceEnabled,
                                    onChanged: _busy
                                        ? null
                                        : (value) => _run(() => _store
                                            .setMaintenanceEnabled(value)),
                                    title: const Text('允许 AI 维护工具'),
                                    subtitle: const Text(
                                        '允许对话中的 AI 诊断并更新已安装工具的同一网络来源规则，也可恢复上一版本。新增服务需先由你导入。'),
                                  ),
                                ),
                                const Padding(
                                    padding: EdgeInsets.fromLTRB(8, 12, 8, 20),
                                    child: Text(
                                        '诊断只检查公开接口，不发送聊天图片。工具更新出错时，可从操作菜单恢复上一版本或内置搜图。')),
                              ],
                            )),
                      )),
    );
  }
}

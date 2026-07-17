import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'download_export_core.dart';
import 'download_export_delivery.dart';
import 'download_export_models.dart';

typedef DownloadExportClipboardWriter = Future<void> Function(String text);

Future<void> _writeDownloadExportClipboard(String text) {
  return Clipboard.setData(ClipboardData(text: text));
}

class DownloadExportFieldConfigPage extends StatefulWidget {
  DownloadExportFieldConfigPage({
    super.key,
    required Iterable<DownloadExportRequest> requests,
    this.service = const DownloadExportService(),
    this.sink = const PlatformDownloadExportArtifactSink(),
    this.clipboardWriter,
  }) : requests = List.unmodifiable(requests);

  final List<DownloadExportRequest> requests;
  final DownloadExportService service;
  final DownloadExportArtifactSink sink;
  final DownloadExportClipboardWriter? clipboardWriter;

  @override
  State<DownloadExportFieldConfigPage> createState() =>
      _DownloadExportFieldConfigPageState();
}

class _DownloadExportFieldConfigPageState
    extends State<DownloadExportFieldConfigPage> {
  final Set<DownloadExportField> _selected = {
    DownloadExportField.title,
    DownloadExportField.author,
    DownloadExportField.id,
  };
  bool _copying = false;

  DownloadExportFieldConfiguration get _configuration =>
      DownloadExportFieldConfiguration(
        DownloadExportField.values.where(_selected.contains),
      );

  void _openProgressPage() {
    if (_configuration.isEmpty || _copying) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DownloadExportProgressPage(
          requests: widget.requests,
          fields: _configuration,
          includeContent: false,
          service: widget.service,
          sink: widget.sink,
        ),
      ),
    );
  }

  Future<void> _copyManifest() async {
    if (_configuration.isEmpty || _copying) return;
    setState(() => _copying = true);
    try {
      final text = await widget.service.buildManifestText(
        requests: widget.requests,
        fields: _configuration,
      );
      await (widget.clipboardWriter ?? _writeDownloadExportClipboard)(text);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已复制到剪贴板')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('复制清单失败，请重试：$error')),
      );
    } finally {
      if (mounted) setState(() => _copying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preview = widget.requests
        .map((request) => request.descriptor.title.trim())
        .where((title) => title.isNotEmpty)
        .take(3)
        .join('、');
    final emptyFields = _configuration.isEmpty;

    return Scaffold(
      appBar: AppBar(title: const Text('导出清单')),
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Text(
                  '已选择 ${widget.requests.length} 部漫画'
                  '${preview.isEmpty ? '' : '：$preview'}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium,
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  for (final field in DownloadExportField.values)
                    CheckboxListTile(
                      value: _selected.contains(field),
                      onChanged: _copying
                          ? null
                          : (value) {
                              setState(() {
                                if (value == true) {
                                  _selected.add(field);
                                } else {
                                  _selected.remove(field);
                                }
                              });
                            },
                      title: Text(field.label),
                      subtitle:
                          field.isSensitive ? const Text('可能暴露设备目录信息') : null,
                      secondary: field.isSensitive
                          ? const Icon(Icons.warning_amber_outlined)
                          : null,
                      controlAffinity: ListTileControlAffinity.leading,
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 16),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                children: [
                  if (emptyFields)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '至少选择一项',
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _copying
                              ? null
                              : () {
                                  setState(() {
                                    _selected
                                      ..clear()
                                      ..addAll(DownloadExportField.values);
                                  });
                                },
                          icon: const Icon(Icons.select_all),
                          label: const Text('全选字段'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _copying
                              ? null
                              : () {
                                  setState(() {
                                    _selected
                                      ..clear()
                                      ..addAll(
                                        DownloadExportFieldConfiguration
                                                .defaults()
                                            .fields,
                                      );
                                  });
                                },
                          icon: const Icon(Icons.restore),
                          label: const Text('恢复默认'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: emptyFields || _copying
                              ? null
                              : _openProgressPage,
                          icon: const Icon(Icons.description_outlined),
                          label: const Text('生成并分享清单'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed:
                              emptyFields || _copying ? null : _copyManifest,
                          icon: _copying
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.copy_outlined),
                          label: const Text('复制到剪贴板'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class DownloadExportProgressPage extends StatefulWidget {
  DownloadExportProgressPage({
    super.key,
    required Iterable<DownloadExportRequest> requests,
    required this.fields,
    required this.includeContent,
    this.service = const DownloadExportService(),
    this.sink = const PlatformDownloadExportArtifactSink(),
    this.suggestedName,
  }) : requests = List.unmodifiable(requests);

  final List<DownloadExportRequest> requests;
  final DownloadExportFieldConfiguration fields;
  final bool includeContent;
  final DownloadExportService service;
  final DownloadExportArtifactSink sink;
  final String? suggestedName;

  @override
  State<DownloadExportProgressPage> createState() =>
      _DownloadExportProgressPageState();
}

class _DownloadExportProgressPageState
    extends State<DownloadExportProgressPage> {
  final DownloadExportCancellationToken _cancellation =
      DownloadExportCancellationToken();
  DownloadExportProgress? _progress;
  DownloadExportResult? _result;
  bool _running = true;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    final result = await widget.service.exportAndDeliver(
      requests: widget.requests,
      fields: widget.fields,
      includeContent: widget.includeContent,
      sink: widget.sink,
      cancellation: _cancellation,
      suggestedName: widget.suggestedName,
      onProgress: (progress) {
        if (!mounted) return;
        setState(() => _progress = progress);
      },
    );
    if (!mounted) return;
    setState(() {
      _running = false;
      _result = result;
    });
  }

  void _cancel() {
    if (_running) {
      _cancellation.cancel();
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_running,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _running) {
          _cancel();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.includeContent ? '导出漫画' : '生成清单'),
          leading: _running
              ? IconButton(
                  onPressed: _cancel,
                  tooltip: '取消',
                  icon: const Icon(Icons.close),
                )
              : null,
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child:
                    _running ? _buildRunning(context) : _buildResult(context),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRunning(BuildContext context) {
    final progress = _progress;
    final fraction = progress?.fraction;
    final current = progress?.current ?? 0;
    final total = progress?.total ?? widget.requests.length;
    final title = progress?.currentTitle.trim() ?? '';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '正在处理 $current/$total',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 16),
        LinearProgressIndicator(value: fraction),
        const SizedBox(height: 16),
        if (title.isNotEmpty)
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        const SizedBox(height: 8),
        Text(progress?.phase ?? '准备中'),
        if (progress != null && progress.writtenBytes > 0)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('已写入 ${_formatBytes(progress.writtenBytes)}'),
          ),
        const SizedBox(height: 24),
        OutlinedButton.icon(
          onPressed: _cancellation.isCancelled ? null : _cancel,
          icon: const Icon(Icons.close),
          label: const Text('取消导出'),
        ),
      ],
    );
  }

  Widget _buildResult(BuildContext context) {
    final result = _result;
    if (result == null) return const CircularProgressIndicator();
    final theme = Theme.of(context);
    final (IconData icon, String title, Color color) = switch (result.status) {
      DownloadExportResultStatus.success => (
          Icons.check_circle_outline,
          '导出完成',
          theme.colorScheme.primary,
        ),
      DownloadExportResultStatus.cancelled => (
          Icons.cancel_outlined,
          '已取消导出',
          theme.colorScheme.outline,
        ),
      DownloadExportResultStatus.partialFailure => (
          Icons.warning_amber_outlined,
          '部分导出成功',
          theme.colorScheme.error,
        ),
      DownloadExportResultStatus.failure => (
          Icons.error_outline,
          '导出失败',
          theme.colorScheme.error,
        ),
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(icon, color: color, size: 48),
        const SizedBox(height: 12),
        Text(
          title,
          textAlign: TextAlign.center,
          style: theme.textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        Text(
          '${result.processed}/${result.total} 项已处理',
          textAlign: TextAlign.center,
        ),
        if (result.failures.isNotEmpty) ...[
          const SizedBox(height: 20),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: result.failures.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final failure = result.failures[index];
                return ListTile(
                  dense: true,
                  leading: const Icon(Icons.error_outline),
                  title: Text(
                    failure.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(failure.reason),
                  contentPadding: EdgeInsets.zero,
                );
              },
            ),
          ),
        ],
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.done),
          label: const Text('完成'),
        ),
      ],
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
}

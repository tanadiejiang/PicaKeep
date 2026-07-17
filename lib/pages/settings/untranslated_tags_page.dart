import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:picakeep/foundation/untranslated_tags/untranslated_tag_store.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:share_plus/share_plus.dart';

class UntranslatedTagsPage extends StatefulWidget {
  const UntranslatedTagsPage({super.key});

  @override
  State<UntranslatedTagsPage> createState() => _UntranslatedTagsPageState();
}

class _UntranslatedTagsPageState extends State<UntranslatedTagsPage> {
  final _repository = UntranslatedTagRepository.instance;
  String _sourceFilter = 'all';
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    await _repository.load();
    await _repository.pruneTranslated();
    if (!mounted) return;
    setState(() => _loading = false);
  }

  List<UntranslatedTagRecord> get _filteredRecords {
    final values = _repository.records;
    if (_sourceFilter == 'all') return values;
    return values.where((record) => record.source == _sourceFilter).toList();
  }

  Map<String, List<UntranslatedTagRecord>> _groupRecords(
    Iterable<UntranslatedTagRecord> records,
  ) {
    final result = <String, List<UntranslatedTagRecord>>{};
    for (final record in records) {
      result.putIfAbsent('${record.source}::${record.normalizedNamespace}', () {
        return <UntranslatedTagRecord>[];
      }).add(record);
    }
    return result;
  }

  Future<void> _copyRecord(UntranslatedTagRecord record,
      {bool full = false}) async {
    final text = full ? '${record.namespace}:${record.rawTag}' : record.rawTag;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(full ? '已复制完整标签' : '已复制原始标签')),
    );
  }

  Future<void> _export() async {
    if (_filteredRecords.isEmpty || _busy) return;
    setState(() => _busy = true);
    File? temporary;
    try {
      final directory = await getTemporaryDirectory();
      final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
      temporary = File(
        '${directory.path}${Platform.pathSeparator}PicaKeep-待翻译标签-$stamp.txt',
      );
      await temporary.writeAsString(
        _repository.formatText(_filteredRecords),
        flush: true,
      );
      if (App.isDesktop) {
        final location = await getSaveLocation(
          suggestedName: temporary.path.split(Platform.pathSeparator).last,
        );
        if (location == null) return;
        await XFile(temporary.path).saveTo(location.path);
      } else {
        await Share.shareXFiles([XFile(temporary.path)],
            text: 'PicaKeep 待翻译标签');
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(App.isDesktop ? '标签清单已保存' : '标签清单已交给系统分享')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('标签清单导出失败，请重试')),
        );
      }
    } finally {
      if (temporary != null) {
        try {
          if (await temporary.exists()) await temporary.delete();
        } catch (_) {}
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    if (_repository.records.isEmpty || _busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空待翻译标签？'),
        content: const Text('这会删除所有来源的采集记录，且无法撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    await _repository.clear();
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('待翻译标签已清空')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final records = _filteredRecords;
    final groups = _groupRecords(records);
    final ehCount =
        _repository.records.where((e) => e.source == 'ehentai').length;
    final nhCount =
        _repository.records.where((e) => e.source == 'nhentai').length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('待翻译标签'),
        actions: [
          IconButton(
            tooltip: '导出清单',
            onPressed: records.isEmpty || _busy ? null : _export,
            icon: const Icon(Icons.ios_share_outlined),
          ),
          IconButton(
            tooltip: '清空',
            onPressed: _repository.records.isEmpty || _busy ? null : _clear,
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                children: [
                  _buildSummary(ehCount, nhCount),
                  const SizedBox(height: 12),
                  _buildFilter(),
                  const SizedBox(height: 20),
                  if (records.isEmpty)
                    _buildEmptyState()
                  else ...[
                    Text('信息', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 12),
                    for (final entry in groups.entries) ...[
                      _buildGroupTitle(entry.value.first),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final record in entry.value)
                            Semantics(
                              button: true,
                              label: '${record.namespace}:${record.rawTag}',
                              hint: '点击复制原始标签，长按复制完整标签',
                              child: GestureDetector(
                                onLongPress: () =>
                                    _copyRecord(record, full: true),
                                child: ActionChip(
                                  label: Text(
                                    record.rawTag,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  avatar: Text('${record.encounterCount}'),
                                  onPressed: () => _copyRecord(record),
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 20),
                    ],
                  ],
                ],
              ),
            ),
    );
  }

  Widget _buildSummary(int ehCount, int nhCount) {
    final latest = _repository.records
        .map((record) => record.lastSeenAt)
        .fold<DateTime?>(null, (current, value) {
      if (current == null || value.isAfter(current)) return value;
      return current;
    });
    return Semantics(
      container: true,
      label:
          '共 ${_repository.records.length} 个待翻译标签，EH $ehCount 个，NH $nhCount 个',
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _summaryChip('全部 ${_repository.records.length}'),
          _summaryChip('EH $ehCount'),
          _summaryChip('NH $nhCount'),
          if (latest != null) _summaryChip('最近 ${_formatDate(latest)}'),
        ],
      ),
    );
  }

  Widget _summaryChip(String text) {
    return Chip(
      label: Text(text),
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _buildFilter() {
    return SegmentedButton<String>(
      segments: const [
        ButtonSegment(
            value: 'all',
            label: Text('全部'),
            icon: Icon(Icons.list_alt_outlined)),
        ButtonSegment(
            value: 'ehentai', label: Text('EH'), icon: Icon(Icons.language)),
        ButtonSegment(
            value: 'nhentai',
            label: Text('NH'),
            icon: Icon(Icons.language_outlined)),
      ],
      selected: {_sourceFilter},
      onSelectionChanged: (value) =>
          setState(() => _sourceFilter = value.first),
    );
  }

  Widget _buildGroupTitle(UntranslatedTagRecord record) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Icon(Icons.label_outline,
              size: 18, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Text('${record.source} / ${record.namespace}',
              style: Theme.of(context).textTheme.titleSmall),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 72),
      child: Column(
        children: [
          Icon(Icons.translate_outlined,
              size: 48, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 16),
          const Text('暂无待翻译标签'),
          const SizedBox(height: 8),
          Text(
            '在 EH/NH 的在线详情、下载或本地恢复中遇到词表外标签后，会在这里显示。',
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.outline),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime value) {
    final local = value.toLocal();
    return '${local.month}/${local.day} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }
}

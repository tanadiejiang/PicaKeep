part of 'settings_page.dart';

class LogSetting extends StatefulWidget {
  const LogSetting({super.key});

  @override
  State<LogSetting> createState() => _LogSettingState();
}

class _LogSettingState extends State<LogSetting> {
  Future<void> _exportLogs() async {
    try {
      final path = await LogFileService.instance.exportCurrent();
      if (path == null) {
        if (mounted) _showSettingMessage(context, '日志导出失败'.tl);
        return;
      }

      if (App.isDesktop) {
        final location = await getSaveLocation(
          suggestedName: path.split(Platform.pathSeparator).last,
        );
        if (location == null) return;
        await XFile(path).saveTo(location.path);
        if (mounted) _showSettingMessage(context, '日志已导出'.tl);
        return;
      }

      await Share.shareXFiles([XFile(path)], text: 'PicaKeep Log');
    } catch (_) {
      if (mounted) _showSettingMessage(context, '日志导出失败'.tl);
    }
  }

  Future<void> _copyAll() async {
    try {
      final text = await LogFileService.instance.copyAll();
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) _showSettingMessage(context, '已复制到剪贴板'.tl);
    } catch (_) {
      if (mounted) _showSettingMessage(context, '复制日志失败'.tl);
    }
  }

  Future<void> _exportAllAsZip() async {
    try {
      final zipPath = await LogFileService.instance.exportAllAsZip();
      if (zipPath == null) {
        if (mounted) _showSettingMessage(context, '无可导出的日志'.tl);
        return;
      }

      if (App.isDesktop) {
        final location = await getSaveLocation(
          suggestedName: zipPath.split(Platform.pathSeparator).last,
        );
        if (location == null) return;
        await XFile(zipPath).saveTo(location.path);
        if (mounted) _showSettingMessage(context, '日志已打包导出'.tl);
        return;
      }

      await Share.shareXFiles([XFile(zipPath)], text: 'PicaKeep Logs');
    } catch (_) {
      if (mounted) _showSettingMessage(context, '日志打包导出失败'.tl);
    }
  }

  void _showHistory() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => const _LogHistorySheet(),
    );
  }

  Color _levelColor(ColorScheme scheme, LogLevel level) {
    return switch (level) {
      LogLevel.error => scheme.error,
      LogLevel.warning => scheme.errorContainer,
      LogLevel.info => scheme.primaryContainer,
    };
  }

  Color _levelTextColor(LogLevel level) {
    return level == LogLevel.error ? Colors.white : Colors.black;
  }

  Widget _buildRecorderTile() {
    return SwitchListTile(
      secondary: const Icon(Icons.fiber_manual_record_outlined),
      title: Text('记录日志'.tl),
      subtitle: Text('关闭后新的应用内日志不会继续写入；已有日志会保留'.tl),
      value: LogManager.recordingEnabled,
      onChanged: (value) {
        setState(() {
          LogManager.recordingEnabled = value;
        });
      },
    );
  }

  Widget _buildEmptyState() {
    return ListView(
      children: [
        _buildRecorderTile(),
        const Divider(height: 1),
        SizedBox(
          height: 240,
          child: Center(child: Text('暂无日志'.tl)),
        ),
      ],
    );
  }

  Widget _buildLogItem(Log log) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: SelectionArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest,
                    borderRadius: const BorderRadius.all(
                      Radius.circular(16),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(5, 0, 5, 1),
                    child: Text(log.title),
                  ),
                ),
                const SizedBox(width: 3),
                Container(
                  decoration: BoxDecoration(
                    color: _levelColor(colorScheme, log.level),
                    borderRadius: const BorderRadius.all(
                      Radius.circular(16),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(5, 0, 5, 1),
                    child: Text(
                      log.level.name,
                      style: TextStyle(
                        color: _levelTextColor(log.level),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(log.content),
            const SizedBox(height: 4),
            Text(
              log.time.toString().replaceAll(RegExp(r'\.\w+'), ''),
            ),
            TextButton(
              onPressed: () async {
                await Clipboard.setData(
                  ClipboardData(text: log.content),
                );
                if (!mounted) {
                  return;
                }
                _showSettingMessage(context, '已复制'.tl);
              },
              child: Text('复制'.tl),
            ),
            const Divider(),
          ],
        ),
      ),
    );
  }

  Widget _buildLogList() {
    return ListView.builder(
      itemCount: LogManager.logs.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Column(
            children: [
              _buildRecorderTile(),
              const Divider(height: 1),
              const SizedBox(height: 8),
            ],
          );
        }
        final log = LogManager.logs[LogManager.logs.length - index];
        return _buildLogItem(log);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Logs'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) async {
              if (value == 'clear') {
                setState(LogManager.clear);
              } else if (value == 'ignore') {
                LogManager.ignoreLimitation = true;
                _showSettingMessage(context, '仅在本次运行时有效'.tl);
              } else if (value == 'export') {
                await _exportLogs();
              } else if (value == 'copyAll') {
                await _copyAll();
              } else if (value == 'exportZip') {
                await _exportAllAsZip();
              } else if (value == 'history') {
                _showHistory();
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem<String>(
                value: 'clear',
                child: Text('清空'.tl),
              ),
              PopupMenuItem<String>(
                value: 'ignore',
                child: Text('禁用长度限制'.tl),
              ),
              const PopupMenuDivider(),
              PopupMenuItem<String>(
                value: 'copyAll',
                child: Text('复制全部'.tl),
              ),
              PopupMenuItem<String>(
                value: 'export',
                child: Text('导出当前日志'.tl),
              ),
              PopupMenuItem<String>(
                value: 'exportZip',
                child: Text('打包所有日志为 ZIP'.tl),
              ),
              const PopupMenuDivider(),
              PopupMenuItem<String>(
                value: 'history',
                child: Text('历史日志'.tl),
              ),
            ],
          ),
        ],
      ),
      body: LogManager.logs.isEmpty ? _buildEmptyState() : _buildLogList(),
    );
  }
}

/// 历史日志弹窗
class _LogHistorySheet extends StatefulWidget {
  const _LogHistorySheet();

  @override
  State<_LogHistorySheet> createState() => _LogHistorySheetState();
}

class _LogHistorySheetState extends State<_LogHistorySheet> {
  late Future<List<LogFileInfo>> _historyFuture;

  @override
  void initState() {
    super.initState();
    _historyFuture = LogFileService.instance.listHistory();
  }

  void _reload() {
    setState(() {
      _historyFuture = LogFileService.instance.listHistory();
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<LogFileInfo>>(
      future: _historyFuture,
      builder: (context, snapshot) {
        final files = snapshot.data ?? const <LogFileInfo>[];
        if (files.isEmpty) {
          return SizedBox(
            height: 200,
            child: Center(child: Text('暂无历史日志'.tl)),
          );
        }
        return SizedBox(
          height: MediaQuery.of(context).size.height * 0.7,
          child: SafeArea(
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: files.length,
              separatorBuilder: (_, __) => const Divider(),
              itemBuilder: (context, index) {
                final file = files[index];
                return ListTile(
                  leading: const Icon(Icons.description),
                  title: Text(file.name),
                  subtitle: Text(
                      '${(file.sizeBytes / 1024).toStringAsFixed(1)} KB · ${_formatDate(file.modified)}'),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => _LogFileViewerPage(file: file),
                    ),
                  ),
                  trailing: Wrap(
                    spacing: 0,
                    children: [
                      IconButton(
                        tooltip: '分享'.tl,
                        onPressed: () async {
                          await _shareHistoryLog(context, file);
                        },
                        icon: const Icon(Icons.share),
                      ),
                      IconButton(
                        tooltip: '删除'.tl,
                        onPressed: () async {
                          await LogFileService.instance
                              .deleteHistory(file.path);
                          if (context.mounted) _reload();
                        },
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }

  String _formatDate(DateTime dt) {
    return '${dt.year}-${_pad(dt.month)}-${_pad(dt.day)} '
        '${_pad(dt.hour)}:${_pad(dt.minute)}';
  }

  String _pad(int v) => v.toString().padLeft(2, '0');
}

/// 历史日志文件查看页
class _LogFileViewerPage extends StatelessWidget {
  const _LogFileViewerPage({required this.file});

  final LogFileInfo file;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(file.name),
        actions: [
          IconButton(
            tooltip: '分享'.tl,
            onPressed: () => _shareHistoryLog(context, file),
            icon: const Icon(Icons.share),
          ),
        ],
      ),
      body: FutureBuilder<String>(
        future: LogFileService.instance.readHistoryFile(file.path),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final text = snapshot.data ?? '';
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: SelectableText(
              text,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            ),
          );
        },
      ),
    );
  }
}

Future<void> _shareHistoryLog(
  BuildContext context,
  LogFileInfo file,
) async {
  try {
    final path = await LogFileService.instance.exportHistory(file.path);
    if (path == null) {
      if (context.mounted) _showSettingMessage(context, '日志分享失败'.tl);
      return;
    }
    await Share.shareXFiles([XFile(path)], text: file.name);
  } catch (_) {
    if (context.mounted) _showSettingMessage(context, '日志分享失败'.tl);
  }
}

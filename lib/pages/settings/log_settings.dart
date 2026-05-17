part of 'settings_page.dart';

class LogSetting extends StatefulWidget {
  const LogSetting({super.key});

  @override
  State<LogSetting> createState() => _LogSettingState();
}

class _LogSettingState extends State<LogSetting> {
  Future<void> _exportLogs() async {
    final directory = Directory('${App.dataPath}/logs');
    if (!directory.existsSync()) {
      directory.createSync(recursive: true);
    }
    final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final file = File('${directory.path}/picakeep-log-$timestamp.txt');
    await file.writeAsString(LogManager().toString());

    if (App.isDesktop) {
      final location =
          await getSaveLocation(suggestedName: file.uri.pathSegments.last);
      if (location == null) {
        return;
      }
      await XFile(file.path).saveTo(location.path);
      if (mounted) {
        _showSettingMessage(context, '日志已导出'.tl);
      }
      return;
    }

    await Share.shareXFiles([XFile(file.path)], text: 'PicaKeep Logs');
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
              PopupMenuItem<String>(
                value: 'export',
                child: Text('导出'.tl),
              ),
            ],
          ),
        ],
      ),
      body: LogManager.logs.isEmpty ? _buildEmptyState() : _buildLogList(),
    );
  }
}
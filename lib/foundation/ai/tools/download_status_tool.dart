import 'package:picakeep/foundation/online_download_manager.dart';

import '../ai_tool.dart';

class DownloadStatusTool extends AiTool {
  const DownloadStatusTool();

  @override
  String get name => 'get_download_status';

  @override
  String get description => '查询在线下载队列任务状态。taskId 省略时返回全部任务。';

  @override
  Map<String, Object?> get parametersSchema => const {
        'type': 'object',
        'properties': {
          'taskId': {'type': 'string', 'description': '可选，指定任务ID'},
        },
      };

  @override
  Future<AiToolResult> execute(Map<String, dynamic> args) async {
    final taskId = args['taskId']?.toString().trim();
    final tasks = OnlineDownloadManager.instance.tasks
        .where((task) => taskId == null || taskId.isEmpty || task.id == taskId)
        .map((task) => {
              'taskId': task.id,
              'title': task.taskTitle,
              'progress': task.progress,
              'state': _state(task),
              if (task.error != null) 'message': task.error,
            })
        .toList();
    return AiToolResult.success({'items': tasks});
  }

  String _state(OnlineDownloadTask task) {
    if (task.error != null) return 'error';
    if (task.completed) return 'completed';
    if (task.paused) return 'paused';
    if (task.cancelled) return 'cancelled';
    return 'downloading';
  }
}

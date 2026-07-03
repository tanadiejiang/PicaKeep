import 'ai_tool_registry.dart';
import 'tools/download_comic_tool.dart';
import 'tools/download_status_tool.dart';
import 'tools/search_local_tool.dart';
import 'tools/search_online_tool.dart';

class AiCapabilities {
  AiCapabilities._();

  static bool _registered = false;

  static AiToolRegistry get registry {
    ensureRegistered();
    return AiToolRegistry.instance;
  }

  static void ensureRegistered() {
    if (_registered) return;
    AiToolRegistry.instance.registerAll(const [
      SearchOnlineTool(),
      DownloadComicTool(),
      SearchLocalTool(),
      DownloadStatusTool(),
    ]);
    _registered = true;
  }
}

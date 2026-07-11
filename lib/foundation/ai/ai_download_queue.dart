import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:picakeep/foundation/app.dart';
import 'ai_result_item.dart';

/// AI 下载队列：持久化的待下载漫画清单。
///
/// 单例 ChangeNotifier，持有 [List<AiResultItem>]。
/// 去重键：`source:id` 组合。
class AiDownloadQueue extends ChangeNotifier {
  AiDownloadQueue._();

  static final AiDownloadQueue instance = AiDownloadQueue._();

  List<AiResultItem> _items = [];

  /// 当前队列（只读视图）。
  List<AiResultItem> get items => List.unmodifiable(_items);

  // ────────────────────────────────────────────────────────
  //  文件路径
  // ────────────────────────────────────────────────────────

  static String _file() =>
      '${App.dataPath}${Platform.pathSeparator}ai_download_queue.json';

  // ────────────────────────────────────────────────────────
  //  加载
  // ────────────────────────────────────────────────────────

  /// 从磁盘读取并反序列化队列。应用启动时调用一次。
  Future<void> load() async {
    try {
      final file = File(_file());
      if (!await file.exists()) return;

      final content = await file.readAsString();
      final jsonList = jsonDecode(content) as List<dynamic>;
      _items = jsonList
          .whereType<Map<String, dynamic>>()
          .map(AiResultItem.fromJson)
          .toList();
      notifyListeners();
    } catch (e) {
      debugPrint('AiDownloadQueue.load failed: $e');
    }
  }

  // ────────────────────────────────────────────────────────
  //  写入操作
  // ────────────────────────────────────────────────────────

  /// 批量追加条目，按 `source:id` 去重后保存。
  Future<void> addItems(List<AiResultItem> newItems) async {
    final existingKeys = _items.map(_key).toSet();
    final toAdd = newItems.where((e) => !existingKeys.contains(_key(e)));
    _items.addAll(toAdd);
    notifyListeners();
    await _save();
  }

  /// 移除单条条目后保存。
  Future<void> remove(AiResultItem item) async {
    final before = _items.length;
    _items.removeWhere((e) => _key(e) == _key(item));
    if (_items.length != before) {
      notifyListeners();
      await _save();
    }
  }

  /// 清空整个队列后保存。
  Future<void> clear() async {
    if (_items.isEmpty) return;
    _items = [];
    notifyListeners();
    await _save();
  }

  // ────────────────────────────────────────────────────────
  //  持久化
  // ────────────────────────────────────────────────────────

  Future<void> _save() async {
    try {
      final jsonList = _items.map(_itemToJson).toList();
      final file = File(_file());
      await file.writeAsString(jsonEncode(jsonList));
    } catch (e) {
      debugPrint('AiDownloadQueue._save failed: $e');
    }
  }

  // ────────────────────────────────────────────────────────
  //  辅助
  // ────────────────────────────────────────────────────────

  /// 去重键：`source:id`。
  static String _key(AiResultItem item) => '${item.source}:${item.id}';

  /// 序列化为 JSON（AiResultItem 暂无 toJson，在此补充）。
  static Map<String, dynamic> _itemToJson(AiResultItem item) => {
        'id': item.id,
        'title': item.title,
        'author': item.author,
        'coverUrl': item.coverUrl,
        'source': item.source,
        'tags': item.tags,
        'availability': item.availability,
      };
}

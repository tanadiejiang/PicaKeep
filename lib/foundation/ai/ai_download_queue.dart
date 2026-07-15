import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/log.dart';
import 'package:picakeep/foundation/online_download_manager.dart';
import 'package:picakeep/network/eh_network/eh_main_network.dart';
import 'package:picakeep/network/jm_network/jm_network.dart';
import 'package:picakeep/network/nhentai_network/nhentai_main_network.dart';
import 'package:picakeep/network/picacg_network/picacg_network.dart';
import 'ai_result_item.dart';
import 'ai_sources.dart';

/// AI 下载队列：持久化的待下载漫画清单。
///
/// 单例 ChangeNotifier，持有 [List<AiResultItem>]。
/// 去重键：`source:id` 组合。
///
/// 33号计划：入队循环（[startDownload]/[startAll]）搬迁到本类内部，
/// 不依赖 `BuildContext`/页面 State 生命周期，页面退出不会中断循环。
class AiDownloadQueue extends ChangeNotifier {
  AiDownloadQueue._();

  static final AiDownloadQueue instance = AiDownloadQueue._();

  List<AiResultItem> _items = [];

  /// 当前队列（只读视图）。
  List<AiResultItem> get items => List.unmodifiable(_items);

  /// 正在发起下载的条目 key 集合（key = 'source:id'）。供页面 UI 订阅展示
  /// "正在发起下载"高亮态；循环体本身不依赖此集合的存在与否继续执行。
  final Set<String> downloading = {};

  /// 是否有 [startAll] 正在跑，防止用户重复点击"全部开始下载"造成重入。
  bool _startingAll = false;
  bool get isStartingAll => _startingAll;

  static String itemKey(AiResultItem item) => '${item.source}:${item.id}';

  // ────────────────────────────────────────────────────────
  //  下载入队循环（原页面 State 里的 _startDownload/_startAll，
  //  33号计划搬迁至此，脱离 Page State 生命周期）
  // ────────────────────────────────────────────────────────

  /// 把一条 AI 队列条目转换为 [OnlineDownloadManager] 任务并入队。
  ///
  /// 成功入队（或已存在于下载管理器中）后会从本队列移除该条目并返回 `true`；
  /// 查询/入队失败时记录日志、保留条目在队列中，返回 `false`。
  /// 不依赖 `BuildContext`，调用方（页面）销毁不会中断本方法的执行。
  Future<bool> startDownload(AiResultItem item) async {
    final key = itemKey(item);
    if (downloading.contains(key)) return false;
    downloading.add(key);
    notifyListeners();

    try {
      switch (item.source) {
        case aiSourcePicacg:
          final res = await PicacgNetwork().getComicInfo(item.id);
          if (res.error) {
            _logStartDownloadError(item, res.errorMessageWithoutNull);
            return false;
          }
          final enq =
              await OnlineDownloadManager.instance.enqueuePicacg(res.data);
          if (enq.error) {
            _logStartDownloadError(item, enq.errorMessageWithoutNull);
            return false;
          }

        case aiSourceJm:
          final normalizedId =
              item.id.replaceFirst(RegExp(r'^jm', caseSensitive: false), '');
          final res = await JmNetwork().getComicInfo(normalizedId);
          if (res.error) {
            _logStartDownloadError(item, res.errorMessageWithoutNull);
            return false;
          }
          final enq = await OnlineDownloadManager.instance.enqueueJm(res.data);
          if (enq.error) {
            _logStartDownloadError(item, enq.errorMessageWithoutNull);
            return false;
          }

        case aiSourceEhentai:
          final res = await EhNetwork().getGalleryInfo(item.id);
          if (res.error) {
            _logStartDownloadError(item, res.errorMessageWithoutNull);
            return false;
          }
          final enq =
              await OnlineDownloadManager.instance.enqueueEhentai(res.data);
          if (enq.error) {
            _logStartDownloadError(item, enq.errorMessageWithoutNull);
            return false;
          }

        case aiSourceNhentai:
          final normalizedId = item.id
              .replaceFirst(RegExp(r'^nhentai', caseSensitive: false), '')
              .replaceFirst(RegExp(r'^nh', caseSensitive: false), '');
          final res = await NhentaiNetwork().getComicInfo(normalizedId);
          if (res.error) {
            _logStartDownloadError(item, res.errorMessageWithoutNull);
            return false;
          }
          final enq =
              await OnlineDownloadManager.instance.enqueueNhentai(res.data);
          if (enq.error) {
            _logStartDownloadError(item, enq.errorMessageWithoutNull);
            return false;
          }

        default:
          _logStartDownloadError(item, '不支持的来源: ${item.source}');
          return false;
      }

      // 入队成功，从 AI 待下载队列中移除
      await remove(item);
      return true;
    } catch (e, s) {
      LogManager.addLog(
        LogLevel.error,
        'AiDownloadQueue',
        'startDownload(${item.source}:${item.id}) failed: $e\n$s',
      );
      return false;
    } finally {
      downloading.remove(key);
      notifyListeners();
    }
  }

  void _logStartDownloadError(AiResultItem item, String message) {
    LogManager.addLog(
      LogLevel.warning,
      'AiDownloadQueue',
      'startDownload(${item.source}:${item.id}) failed: $message',
    );
  }

  /// 串行遍历当前队列快照，依次入队。脱离页面 State 生命周期：调用方（页面）
  /// 销毁不会中断循环，循环体挂在本单例上持续跑完。
  ///
  /// [_startingAll] 防止重入：若已有一轮 [startAll] 在跑，后续调用直接返回，
  /// 避免用户重复点击"全部开始下载"导致同一批条目被并发处理多次。
  Future<void> startAll() async {
    if (_startingAll) return;
    _startingAll = true;
    try {
      final snapshot = List<AiResultItem>.from(_items);
      for (final item in snapshot) {
        await startDownload(item);
      }
    } finally {
      _startingAll = false;
    }
  }

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

  /// 批量追加条目，按 `source:id` 去重后保存；`source` 非法或为空的条目会被跳过、不入队。
  ///
  /// 返回被跳过的条目数（含"来源非法"与"重复去重"两类）。
  Future<int> addItems(List<AiResultItem> newItems) async {
    final existingKeys = _items.map(_key).toSet();
    final valid = newItems.where((e) => isSupportedAiSource(e.source));
    final toAdd = valid.where((e) => !existingKeys.contains(_key(e))).toList();
    final skipped = newItems.length - toAdd.length;
    _items.addAll(toAdd);
    if (toAdd.isNotEmpty) {
      notifyListeners();
      await _save();
    }
    return skipped;
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

  /// 批量移除条目后一次性保存（供多选批量删除调用）。
  Future<void> removeAll(List<AiResultItem> toRemove) async {
    if (toRemove.isEmpty) return;
    final keysToRemove = toRemove.map(_key).toSet();
    final before = _items.length;
    _items.removeWhere((e) => keysToRemove.contains(_key(e)));
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
      final jsonList = _items.map((item) => item.toJson()).toList();
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
}

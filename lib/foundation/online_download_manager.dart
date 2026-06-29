import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/image_loader/jm_image_recombine.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/foundation/log.dart';
import 'package:picakeep/network/app_dio.dart';
import 'package:picakeep/network/jm_network/jm_network.dart';
import 'package:picakeep/network/picacg_network/picacg_network.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/reader/comic_reading_page.dart';

class OnlineDownloadTask {
  OnlineDownloadTask.picacg({required PicacgComicItem comic})
      : _comic = comic,
        _jmInfo = null,
        sourceKey = 'picacg';

  OnlineDownloadTask.jm({required JmComicInfo jmInfo})
      : _comic = null,
        _jmInfo = jmInfo,
        sourceKey = 'jm';

  final PicacgComicItem? _comic;
  final JmComicInfo? _jmInfo;
  final String sourceKey;

  // 向前兼容的 comic getter（仅 picacg 任务有效）
  PicacgComicItem get comic => _comic!;

  /// 通用 display getters
  String get taskId => sourceKey == 'jm' ? 'jm${_jmInfo!.id}' : _comic!.id;
  String get taskTitle =>
      sourceKey == 'jm' ? _jmInfo!.title : _comic!.title;
  String get taskCover =>
      sourceKey == 'jm' ? _jmInfo!.coverUrl : _comic!.cover;

  // 并发下载时每张图各自的 token
  final _cancelTokens = <CancelToken>{};
  CancelToken? cancelToken;
  int currentEp = 0;
  int totalEps = 0;
  int currentPage = 0;
  int totalPages = 0;
  String currentEpName = '';
  bool completed = false;
  bool cancelled = false;
  bool paused = false;
  String? error;

  void addToken(CancelToken token) => _cancelTokens.add(token);
  void removeToken(CancelToken token) => _cancelTokens.remove(token);

  void cancelAllTokens() {
    for (final t in _cancelTokens) {
      if (!t.isCancelled) t.cancel('task cancelled');
    }
    _cancelTokens.clear();
    cancelToken?.cancel('task cancelled');
  }

  // 测速
  int currentSpeed = 0;
  int _bytesSinceLastSecond = 0;
  Timer? _speedTimer;

  void onData(int length) {
    _bytesSinceLastSecond += length;
  }

  void startSpeedTimer(void Function() notify) {
    _speedTimer?.cancel();
    _speedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      currentSpeed = _bytesSinceLastSecond;
      _bytesSinceLastSecond = 0;
      notify();
    });
  }

  void stopSpeedTimer() {
    _speedTimer?.cancel();
    _speedTimer = null;
    currentSpeed = 0;
  }

  String get id => taskId;

  double get progress {
    if (totalEps <= 0) {
      return 0;
    }
    final epProgress =
        totalPages <= 0 ? 0 : currentPage / math.max(totalPages, 1);
    return ((currentEp - 1).clamp(0, totalEps) + epProgress) / totalEps;
  }
}

class OnlineDownloadManager {
  OnlineDownloadManager._();

  static final OnlineDownloadManager instance = OnlineDownloadManager._();

  final Map<String, OnlineDownloadTask> _tasks = <String, OnlineDownloadTask>{};
  final ValueNotifier<int> version = ValueNotifier<int>(0);
  bool _globalPaused = false;
  bool get isGloballyPaused => _globalPaused;
  bool _running = false; // 串行锁：同时只跑一个任务

  List<OnlineDownloadTask> get tasks => _tasks.values.toList(growable: false);

  bool isDownloading(String id) => _tasks.containsKey(id);

  Future<List<DownloadedItem>> loadCompletedDownloads() async {
    final roots = <String>{await _defaultOnlineDownloadRoot()};
    final configured = appdata.settings[22].trim();
    if (configured.isNotEmpty) {
      roots.add(configured);
    }
    final items = <DownloadedItem>[];
    for (final root in roots) {
      final dbPath = '$root${Platform.pathSeparator}download.db';
      if (!File(dbPath).existsSync()) {
        continue;
      }
      try {
        final db = sqlite3.open(dbPath);
        try {
          final rows = db.select('select * from download;');
          for (final row in rows) {
            final id = row['id']?.toString() ?? '';
            final rawJson = row['json']?.toString() ?? '';
            final timeMs = row['time'] as int?;
            final directory = row['directory']?.toString() ?? id;
            final parsed = parseDownloadedItemRecordJson(
              id,
              rawJson,
              time: timeMs == null
                  ? null
                  : DateTime.fromMillisecondsSinceEpoch(timeMs),
              directory: directory,
            );
            if (parsed is DownloadedJmComic) {
              items.add(
                OnlineDownloadedJmComic.fromDownloadedJmComic(
                  parsed,
                  rootPath: root,
                  directoryName: directory,
                ),
              );
            } else if (parsed is DownloadedComic) {
              items.add(
                OnlineDownloadedComic.fromDownloadedComic(
                  parsed,
                  rootPath: root,
                  directoryName: directory,
                ),
              );
            }
          }
        } finally {
          db.dispose();
        }
      } catch (error, stackTrace) {
        LogManager.addLog(
          LogLevel.warning,
          'OnlineDownload',
          'Failed to load online downloads from $root\n$error\n$stackTrace',
        );
      }
    }
    return items;
  }

  void cancel(String id) {
    final task = _tasks[id];
    if (task == null || task.completed || task.cancelled) return;
    task.cancelled = true;
    task.cancelAllTokens();
    unawaited(_saveQueue());
    _scheduleNext();
    _notify();
  }

  void pauseOne(String id) {
    final task = _tasks[id];
    if (task == null || task.completed || task.cancelled || task.paused) return;
    task.paused = true;
    task.stopSpeedTimer();
    unawaited(_saveQueue());
    _notify();
  }

  void resumeOne(String id) {
    final task = _tasks[id];
    if (task == null || task.completed || task.cancelled || !task.paused) return;
    task.paused = false;
    task.cancelled = false;
    task.cancelToken = null;
    unawaited(_saveQueue());
    _scheduleNext();
    _notify();
  }

  void moveToFront(String id) {
    final task = _tasks.remove(id);
    if (task == null) return;
    final reordered = <String, OnlineDownloadTask>{id: task, ..._tasks};
    _tasks
      ..clear()
      ..addAll(reordered);
    unawaited(_saveQueue());
    _scheduleNext();
    _notify();
  }

  void cancelAll(List<String> ids) {
    for (final id in ids) {
      cancel(id);
    }
  }

  void removeAll(List<String> ids) {
    for (final id in ids) {
      _tasks.remove(id);
    }
    unawaited(_saveQueue());
    _notify();
  }

  void pauseAll() {
    _globalPaused = true;
    for (final task in _tasks.values) {
      if (!task.completed && !task.cancelled && task.error == null) {
        task.paused = true;
        task.stopSpeedTimer();
      }
    }
    unawaited(_saveQueue());
    _notify();
  }

  void resumeAll() {
    _globalPaused = false;
    for (final task in _tasks.values) {
      if (task.paused && !task.completed && !task.cancelled) {
        task.paused = false;
        task.cancelled = false;
        task.cancelToken = null;
      }
    }
    unawaited(_saveQueue());
    _scheduleNext();
    _notify();
  }

  void retry(String id) {
    final task = _tasks[id];
    if (task == null || task.completed) return;
    task.error = null;
    task.cancelled = false;
    task.paused = false;
    task.cancelToken = null;
    _scheduleNext();
    _notify();
  }

  void clearFinished() {
    _tasks.removeWhere((_, t) => t.completed || t.cancelled);
    unawaited(_saveQueue());
    _notify();
  }

  Future<Res<bool>> enqueuePicacg(PicacgComicItem comic) async {
    if (_tasks.containsKey('picacg${comic.id}') || _tasks.containsKey(comic.id)) {
      return const Res(true);
    }
    final task = OnlineDownloadTask.picacg(comic: comic)
      ..totalEps = comic.eps.length;
    _tasks[task.id] = task;
    _notify();
    unawaited(_saveQueue());
    _scheduleNext();
    return const Res(true);
  }

  Future<Res<bool>> enqueueJm(JmComicInfo info) async {
    final key = 'jm${info.id}';
    if (_tasks.containsKey(key)) return const Res(true);
    final task = OnlineDownloadTask.jm(jmInfo: info)
      ..totalEps = info.series.length;
    _tasks[task.id] = task;
    _notify();
    unawaited(_saveQueue());
    _scheduleNext();
    return const Res(true);
  }

  /// 找队列里第一个待下载的任务启动（若已有任务在跑则跳过）
  void _scheduleNext() {
    if (_running) return;
    for (final task in _tasks.values) {
      if (!task.completed && !task.cancelled && !task.paused &&
          task.error == null) {
        unawaited(_runTask(task));
        return;
      }
    }
  }

  Future<void> _runTask(OnlineDownloadTask task) async {
    if (task.sourceKey == 'jm') {
      await _runJmTask(task);
    } else {
      await _runPicacgTask(task);
    }
  }

  Future<void> _runPicacgTask(OnlineDownloadTask task) async {
    if (_running) return; // 已有任务在跑，跳过（_scheduleNext 会在完成后再调）
    _running = true;
    task.startSpeedTimer(_notify);
    try {
      final downloadRoot = await _resolveOnlineDownloadRoot();
      final safeDirectory = _safeName(task.comic.title);
      final root = Directory(
        '$downloadRoot${Platform.pathSeparator}$safeDirectory',
      );
      await root.create(recursive: true);
      if (task.comic.cover.isNotEmpty) {
        await _downloadFile(
          task,
          task.comic.cover,
          File('${root.path}${Platform.pathSeparator}cover.jpg'),
        );
      }
      final downloadedEps = <int>[];
      for (var epIndex = 0; epIndex < task.comic.eps.length; epIndex++) {
        task.currentEp = epIndex + 1;
        task.currentEpName = epIndex < task.comic.eps.length
            ? task.comic.eps[epIndex]
            : '第 ${epIndex + 1} 章';
        task.currentPage = 0;
        task.totalPages = 0;
        _notify();
        final content = await PicacgNetwork().getComicContent(
          task.comic.id,
          epIndex + 1,
        );
        if (content.error) {
          throw Exception(content.errorMessageWithoutNull);
        }
        final epDir = Directory(
          '${root.path}${Platform.pathSeparator}${epIndex + 1}',
        );
        await epDir.create(recursive: true);
        task.totalPages = content.data.length;
        var completedPages = 0;
        final concurrency = int.tryParse(appdata.settings[79]) ?? 6;
        final semaphore = _Semaphore(concurrency);
        final errors = <String>[];
        final futures = <Future<void>>[];
        for (var pageIndex = 0; pageIndex < content.data.length; pageIndex++) {
          _throwIfCancelled(task);
          final url = content.data[pageIndex];
          final file = File(
            '${epDir.path}${Platform.pathSeparator}${pageIndex + 1}${_imageExtension(url)}',
          );
          final future = semaphore.run(() async {
            _throwIfCancelled(task);
            try {
              await _downloadFile(task, url, file);
            } catch (e) {
              errors.add(e.toString());
              return;
            }
            completedPages++;
            task.currentPage = completedPages;
            _notify();
          });
          futures.add(future);
        }
        await Future.wait(futures);
        _throwIfCancelled(task);
        if (errors.isNotEmpty && completedPages == 0) {
          throw Exception(errors.first);
        }
        downloadedEps.add(epIndex);
        unawaited(_saveQueue());
      }
      final item = DownloadedComic(
        comicId: task.id,
        title: task.comic.title,
        author: task.comic.author,
        description: task.comic.description,
        thumbUrl: task.comic.cover,
        chapters: task.comic.eps,
        downloadedChapters: downloadedEps,
        size: _directoryMb(root),
        tagList: task.comic.tags,
      )
        ..directory = safeDirectory
        ..time = DateTime.now();
      await _upsertDownloadRecord(
        rootPath: downloadRoot,
        item: item,
        directory: safeDirectory,
      );
      task.completed = true;
      App.notifyLocalDataChanged();
    } on _OnlineDownloadCancelled catch (_) {
      if (task.paused) {
        // paused 由 pauseAll 设置，不标 cancelled
      } else {
        task.cancelled = true;
      }
    } catch (error, stackTrace) {
      task.error = error.toString();
      LogManager.addLog(
        LogLevel.error,
        'OnlineDownload',
        '$error\n$stackTrace',
      );
    } finally {
      _running = false;
      task.stopSpeedTimer();
      unawaited(_saveQueue());
      _notify();
      _scheduleNext(); // 完成/取消/出错后自动启动下一个等待任务
    }
  }

  Future<void> _runJmTask(OnlineDownloadTask task) async {
    if (_running) return;
    _running = true;
    task.startSpeedTimer(_notify);
    final info = task._jmInfo!;
    try {
      final downloadRoot = await _resolveOnlineDownloadRoot();
      final safeDirectory = _safeName(info.title);
      final root = Directory('$downloadRoot${Platform.pathSeparator}$safeDirectory');
      await root.create(recursive: true);
      // 封面（不重组，直接存原始字节）
      if (info.coverUrl.isNotEmpty) {
        await _downloadJmFile(task, info.coverUrl,
            '${root.path}${Platform.pathSeparator}cover',
            chapterId: info.id,
            pictureName: 'cover',
            originalExtension: _imageExtension(info.coverUrl),
            allowRecombine: false);
      }
      final downloadedEps = <int>[];
      final sortedSeries = info.series.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      for (var i = 0; i < sortedSeries.length; i++) {
        final epKey = i + 1;
        final chapterId = sortedSeries[i].value;
        task.currentEp = epKey;
        task.currentEpName = i < info.epNames.length
            ? info.epNames[i]
            : '第$epKey章';
        task.currentPage = 0;
        task.totalPages = 0;
        _notify();
        final content = await JmNetwork().getChapter(chapterId);
        if (content.error) throw Exception(content.errorMessageWithoutNull);
        final epDir = Directory('${root.path}${Platform.pathSeparator}$epKey');
        await epDir.create(recursive: true);
        task.totalPages = content.data.length;
        var completedPages = 0;
        final concurrency = int.tryParse(appdata.settings[79]) ?? 6;
        final semaphore = _Semaphore(concurrency);
        final errors = <String>[];
        final futures = <Future<void>>[];
        for (var pi = 0; pi < content.data.length; pi++) {
          _throwIfCancelled(task);
          final url = content.data[pi];
          final fileName = Uri.parse(url).pathSegments.last;
          final pictureName = fileName.replaceFirst(RegExp(r'\.[^.]+$'), '');
          // 基础路径（不含扩展名）；最终扩展名由重组结果决定（重组→.png，不重组→原始）
          final basePath =
              '${epDir.path}${Platform.pathSeparator}${pi + 1}';
          futures.add(semaphore.run(() async {
            _throwIfCancelled(task);
            try {
              await _downloadJmFile(task, url, basePath,
                  chapterId: chapterId,
                  pictureName: pictureName,
                  originalExtension: _imageExtension(url));
            } catch (e) {
              errors.add(e.toString());
              return;
            }
            completedPages++;
            task.currentPage = completedPages;
            _notify();
          }));
        }
        await Future.wait(futures);
        _throwIfCancelled(task);
        if (errors.isNotEmpty && completedPages == 0) {
          throw Exception(errors.first);
        }

        // 验证：扫描缺失页，顺序重试（应对并发批次中的偶发失败）
        for (var pi = 0; pi < content.data.length; pi++) {
          final basePath = '${epDir.path}${Platform.pathSeparator}${pi + 1}';
          bool exists = false;
          for (final ext in const ['.png', '.webp', '.jpg', '.jpeg']) {
            if (File('$basePath$ext').existsSync()) { exists = true; break; }
          }
          if (!exists) {
            _throwIfCancelled(task);
            final url = content.data[pi];
            final fileName = Uri.parse(url).pathSegments.last;
            final pictureName = fileName.replaceFirst(RegExp(r'\.[^.]+$'), '');
            try {
              await _downloadJmFile(task, url, basePath,
                  chapterId: chapterId,
                  pictureName: pictureName,
                  originalExtension: _imageExtension(url));
              completedPages++;
              task.currentPage = completedPages;
              _notify();
            } catch (e) {
              LogManager.addLog(LogLevel.warning, 'OnlineDownload',
                  'Page ${pi + 1} retry failed: $e');
            }
          }
        }

        downloadedEps.add(i);
        unawaited(_saveQueue());
      }
      final item = DownloadedJmComic(
        comicId: info.id,
        name: info.title,
        author: info.authors.join(', '),
        size: _directoryMb(root),
        downloadedChapters: downloadedEps,
        epNames: info.epNames,
        tagList: info.tags,
      )
        ..directory = safeDirectory
        ..time = DateTime.now();
      await _upsertDownloadRecord(
          rootPath: downloadRoot, item: item, directory: safeDirectory);
      task.completed = true;
      App.notifyLocalDataChanged();
    } on _OnlineDownloadCancelled catch (_) {
      if (!task.paused) task.cancelled = true;
    } catch (error, stackTrace) {
      task.error = error.toString();
      LogManager.addLog(LogLevel.error, 'OnlineDownload', '$error\n$stackTrace');
    } finally {
      _running = false;
      task.stopSpeedTimer();
      unawaited(_saveQueue());
      _notify();
      _scheduleNext();
    }
  }

  /// jm 专用下载：下载字节 → 图块重组 → 写盘
  /// [basePath] 不含扩展名；最终扩展名由重组结果决定（重组→.png，不重组→原始）
  /// [allowRecombine] false 时直接存原始字节，不重组（封面用）
  Future<void> _downloadJmFile(
    OnlineDownloadTask task,
    String url,
    String basePath, {
    required String chapterId,
    required String pictureName,
    required String originalExtension,
    bool allowRecombine = true,
  }) async {
    _throwIfCancelled(task);
    // 已存在检查：任一可能的扩展名命中即视为已下载
    for (final ext in const ['.png', '.webp', '.jpg', '.jpeg']) {
      final existing = File('$basePath$ext');
      if (await existing.exists() && await existing.length() > 0) return;
    }
    await Directory(basePath).parent.create(recursive: true);

    // 下载原始字节（带重试）
    Uint8List? raw;
    var attempt = 0;
    while (true) {
      attempt++;
      try {
        raw = await _downloadJmBytes(task, url);
        break;
      } catch (error) {
        _throwIfCancelled(task);
        if (attempt >= 3) rethrow;
        final msg = error.toString();
        final retryable = error is TimeoutException ||
            msg.contains('HandshakeException') ||
            msg.contains('SocketException') ||
            msg.contains('Connection');
        if (!retryable) rethrow;
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
    if (raw.isEmpty) return;

    // 图块重组（若允许）
    final Uint8List bytes;
    final String extension;
    if (allowRecombine) {
      final result = await JmRecombine.recombine(
        raw,
        epsId: chapterId,
        scrambleId: kJmScrambleId,
        pictureName: pictureName,
        originalExtension: originalExtension,
      );
      bytes = result.bytes;
      extension = result.extension;
    } else {
      // 封面等不重组的：直接存原始
      bytes = raw;
      extension = originalExtension;
    }
    final file = File('$basePath$extension');
    await file.writeAsBytes(bytes, flush: true);
  }

  Future<Uint8List> _downloadJmBytes(
      OnlineDownloadTask task, String url) async {
    final dio = logDio(BaseOptions(headers: getJmImgHeaders()));
    final cancelToken = CancelToken();
    task.addToken(cancelToken);
    try {
      final res = await dio.get<ResponseBody>(
        url,
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          sendTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
        ),
      );
      _throwIfCancelled(task);
      final body = res.data;
      if (body == null) throw Exception('Empty response: $url');
      final expectedLength = int.tryParse(res.headers.value('content-length') ?? '');
      final bytes = <int>[];
      await for (final chunk in body.stream.timeout(
        const Duration(seconds: 20),
        onTimeout: (_) => throw TimeoutException('stream timeout'),
      )) {
        _throwIfCancelled(task);
        task.onData(chunk.length);
        bytes.addAll(chunk);
      }
      if (expectedLength != null && bytes.length < expectedLength) {
        throw TimeoutException(
            'Incomplete download: ${bytes.length}/$expectedLength bytes');
      }
      return Uint8List.fromList(bytes);
    } finally {
      task.removeToken(cancelToken);
    }
  }

  Future<void> _downloadFile(
    OnlineDownloadTask task,
    String url,
    File file,
  ) async {
    _throwIfCancelled(task);
    if (await file.exists() && await file.length() > 0) {
      return;
    }
    await file.parent.create(recursive: true);

    var attempt = 0;
    while (true) {
      attempt++;
      try {
        await _downloadFileOnce(task, url, file);
        return;
      } catch (error) {
        _throwIfCancelled(task);
        if (attempt >= 3) rethrow;
        final msg = error.toString();
        final retryable = error is TimeoutException ||
            msg.contains('HandshakeException') ||
            msg.contains('Connection reset') ||
            msg.contains('SocketException') ||
            msg.contains('Connection terminated') ||
            msg.contains('连接超时') ||
            msg.contains('stream timeout');
        if (!retryable) rethrow;
        LogManager.addLog(
          LogLevel.warning,
          'OnlineDownload',
          'Retrying file ($attempt/3): $url\n$msg',
        );
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
  }

  Future<void> _downloadFileOnce(
    OnlineDownloadTask task,
    String url,
    File file,
  ) async {
    final dio = logDio();
    final cancelToken = CancelToken();
    task.addToken(cancelToken);
    try {
      final response = await dio.get<ResponseBody>(
        url,
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          sendTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
        ),
      );
      _throwIfCancelled(task);
      final body = response.data;
    if (body == null) {
      throw Exception('Empty image response: $url');
    }
    final sink = file.openWrite();
    try {
      // stream 模式下 receiveTimeout 对流内静默段无效，套 timeout 兜底
      await for (final chunk in body.stream.timeout(
        const Duration(seconds: 20),
        onTimeout: (_) => throw TimeoutException('stream timeout'),
      )) {
        _throwIfCancelled(task);
        task.onData(chunk.length);
        sink.add(chunk);
      }
      await sink.flush();
    } catch (_) {
      await sink.close();
      if (await file.exists()) await file.delete();
      rethrow;
    }
    await sink.close();
    } finally {
      task.removeToken(cancelToken);
    }
  }

  void _throwIfCancelled(OnlineDownloadTask task) {
    if (task.cancelled || task.paused) {
      throw const _OnlineDownloadCancelled();
    }
  }

  String _safeName(String value) {
    return value.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  }

  String _imageExtension(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
    if (path.endsWith('.png')) return '.png';
    if (path.endsWith('.webp')) return '.webp';
    if (path.endsWith('.jpeg')) return '.jpg';
    return '.jpg';
  }

  double _directoryMb(Directory dir) {
    var bytes = 0;
    if (!dir.existsSync()) {
      return 0;
    }
    for (final entity in dir.listSync(recursive: true)) {
      if (entity is File) {
        bytes += entity.lengthSync();
      }
    }
    return bytes / 1024 / 1024;
  }

  // ── 持久化 ──────────────────────────────────────────────

  bool _isSaving = false;
  bool _pendingSave = false;

  String _queueFilePath(String rootPath) =>
      '$rootPath${Platform.pathSeparator}download_queue.json';

  Future<void> _saveQueue() async {
    if (_isSaving) {
      // 当前正在写盘，标记"写完后再写一次"确保最新状态不丢
      _pendingSave = true;
      return;
    }
    _isSaving = true;
    _pendingSave = false;
    try {
      final rootPath = await _defaultOnlineDownloadRoot();
      await Directory(rootPath).create(recursive: true);
      final pending = _tasks.values
          .where((t) => !t.completed && !t.cancelled && t.error == null)
          .map((t) {
            if (t.sourceKey == 'jm') {
              return {
                'sourceKey': 'jm',
                'jmJson': _jmComicInfoToQueueJson(t._jmInfo!),
                'currentEp': t.currentEp,
                'paused': t.paused,
              };
            } else {
              return {
                'sourceKey': 'picacg',
                'comicJson': t._comic!.toQueueJson(),
                'currentEp': t.currentEp,
                'paused': t.paused,
              };
            }
          })
          .toList();
      final json = jsonEncode(pending);
      final path = _queueFilePath(rootPath);
      final tmp = File('$path.tmp');
      await tmp.writeAsString(json);
      await tmp.rename(path);
    } catch (e, s) {
      LogManager.addLog(
          LogLevel.warning, 'OnlineDownload', 'saveQueue error: $e\n$s');
    } finally {
      _isSaving = false;
      if (_pendingSave) {
        // 写盘期间有新变化，立即补一次
        unawaited(_saveQueue());
      }
    }
  }

  Future<void> loadQueue() async {
    try {
      final rootPath = await _defaultOnlineDownloadRoot();
      final file = File(_queueFilePath(rootPath));
      if (!await file.exists()) return;
      final content = await file.readAsString();
      final list = jsonDecode(content) as List;
      for (final item in list) {
        try {
          final sourceKey = item['sourceKey']?.toString() ?? 'picacg';
          if (sourceKey == 'jm') {
            final jmJson = item['jmJson'] as Map;
            final info = _jmComicInfoFromQueueJson(jmJson);
            final key = 'jm${info.id}';
            if (_tasks.containsKey(key)) continue;
            final task = OnlineDownloadTask.jm(jmInfo: info)
              ..totalEps = info.series.length
              ..currentEp = (item['currentEp'] as int?) ?? 0
              ..paused = true;
            _tasks[task.id] = task;
          } else {
            final comicJson = item['comicJson'] as Map;
            final comic = PicacgComicItem.fromQueueJson(comicJson);
            if (_tasks.containsKey(comic.id)) continue;
            final task = OnlineDownloadTask.picacg(comic: comic)
              ..totalEps = comic.eps.length
              ..currentEp = (item['currentEp'] as int?) ?? 0
              ..paused = true;
            _tasks[task.id] = task;
          }
        } catch (e) {
          LogManager.addLog(
              LogLevel.warning, 'OnlineDownload', 'loadQueue item error: $e');
        }
      }
      _scheduleNext();
      _notify();
    } catch (e, s) {
      LogManager.addLog(
          LogLevel.warning, 'OnlineDownload', 'loadQueue error: $e\n$s');
    }
  }

  void _notify() {
    version.value++;
  }

  Future<String> _resolveOnlineDownloadRoot() async {
    final configured = appdata.settings[22].trim();
    final fallbackRoot = await _defaultOnlineDownloadRoot();
    final candidates = <String>[
      if (configured.isNotEmpty) configured,
      fallbackRoot,
    ];
    Object? lastError;
    for (final root in candidates.toSet()) {
      try {
        await Directory(root).create(recursive: true);
        _openDownloadDb(root).dispose();
        LogManager.addLog(
          LogLevel.info,
          'OnlineDownload',
          'Using download root: $root',
        );
        return root;
      } catch (error, stackTrace) {
        lastError = error;
        LogManager.addLog(
          LogLevel.warning,
          'OnlineDownload',
          'Download root unavailable: $root\n$error\n$stackTrace',
        );
      }
    }
    throw Exception('在线下载目录不可用: $lastError');
  }

  Future<String> _defaultOnlineDownloadRoot() async {
    return '${(await getApplicationSupportDirectory()).path}'
        '${Platform.pathSeparator}download';
  }

  Future<void> _upsertDownloadRecord({
    required String rootPath,
    required DownloadedItem item,
    required String directory,
  }) async {
    final db = _openDownloadDb(rootPath);
    try {
      db.execute('''
        insert or replace into download
        values (?,?,?,?,?,?,?)
      ''', [
        item.id,
        item.name,
        item.subTitle,
        (item.time ?? DateTime.now()).millisecondsSinceEpoch,
        directory,
        item.comicSize,
        jsonEncode(item.toJson()),
      ]);

      // 验证记录确实写入（防止只读 db 静默失败）
      final check = db.select('select count(*) as c from download where id = ?', [item.id]);
      final count = check.isNotEmpty ? (check.first['c'] as int?) ?? 0 : 0;
      if (count == 0) {
        throw Exception(
          '下载记录写入失败：数据库未保存该条目 (id=${item.id})。\n'
          '数据库可能为只读，请检查文件权限：\n'
          '$rootPath${Platform.pathSeparator}download.db',
        );
      }
    } finally {
      db.dispose();
    }
  }

  Database _openDownloadDb(String rootPath) {
    final dbPath = '$rootPath${Platform.pathSeparator}download.db';

    // 检测并修复只读文件
    final dbFile = File(dbPath);
    if (dbFile.existsSync()) {
      var needRebuild = false;
      try {
        // 尝试写测试：如果只读会抛异常
        final raf = dbFile.openSync(mode: FileMode.append);
        raf.closeSync();
      } catch (e) {
        // 文件只读或权限异常，尝试删除重建
        LogManager.addLog(
          LogLevel.warning,
          'OnlineDownload',
          'download.db is readonly or locked, trying to remove: $e',
        );
        needRebuild = true;
      }
      if (needRebuild) {
        try {
          dbFile.deleteSync();
        } catch (delErr) {
          // 删除失败（通常是 root 拥有的文件，应用无权删除）
          // 必须明确抛错，否则后续 insert 会静默失败导致下载记录丢失
          throw Exception(
            '数据库文件无法写入且无法删除，可能被 root 权限污染。\n'
            '请手动删除该文件后重试：\n$dbPath\n'
            '原始错误: $delErr',
          );
        }
      }
    }

    final db = sqlite3.open(dbPath);
    db.execute('''
      create table if not exists download (
        id text primary key,
        title text,
        subtitle text,
        time int,
        directory text,
        size int,
        json text
      )
    ''');
    return db;
  }

  static Map<String, dynamic> _jmComicInfoToQueueJson(JmComicInfo info) => {
        'id': info.id,
        'title': info.title,
        'authors': info.authors,
        'description': info.description,
        'tags': info.tags,
        'works': info.works,
        'epNames': info.epNames,
        'series': {
          for (final e in info.series.entries) e.key.toString(): e.value,
        },
        'coverUrl': info.coverUrl,
      };

  static JmComicInfo _jmComicInfoFromQueueJson(Map json) {
    final series = <int, String>{};
    final rawSeries = (json['series'] as Map?) ?? {};
    for (final e in rawSeries.entries) {
      final k = int.tryParse(e.key.toString());
      if (k != null) series[k] = e.value.toString();
    }
    final epNames =
        (json['epNames'] as List?)?.map((e) => e.toString()).toList() ?? [];
    if (series.isEmpty) {
      series[1] = json['id'].toString();
      if (epNames.isEmpty) epNames.add('第1章');
    }
    return JmComicInfo(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      authors: (json['authors'] as List?)?.map((e) => e.toString()).toList() ?? [],
      description: json['description']?.toString() ?? '',
      likes: 0,
      views: 0,
      comments: 0,
      tags: (json['tags'] as List?)?.map((e) => e.toString()).toList() ?? [],
      works: (json['works'] as List?)?.map((e) => e.toString()).toList() ?? [],
      actors: (json['actors'] as List?)?.map((e) => e.toString()).toList() ?? [],
      series: series,
      epNames: epNames,
      isFavourite: false,
      isLiked: false,
      coverUrl: json['coverUrl']?.toString() ?? '',
      relatedComics: const [],
    );
  }

  /// 将旧式（纯ID）文件夹名修正为新式（标题），同步更新 DB 的 directory 字段。
  /// 返回 (fixed, failed, skipped) 三元组。
  Future<({int fixed, int failed, int skipped})> fixDirectoryNames() async {
    int fixed = 0, failed = 0, skipped = 0;
    final roots = <String>{await _defaultOnlineDownloadRoot()};
    final configured = appdata.settings[22].trim();
    if (configured.isNotEmpty) roots.add(configured);

    for (final root in roots) {
      final dbPath = '$root${Platform.pathSeparator}download.db';
      if (!File(dbPath).existsSync()) continue;
      Database? db;
      try {
        db = sqlite3.open(dbPath);
        final rows =
            db.select('select id, title, directory from download;').toList();
        for (final row in rows) {
          final id = row['id']?.toString() ?? '';
          final title = row['title']?.toString() ?? '';
          final oldDir = row['directory']?.toString() ?? '';
          if (id.isEmpty || title.isEmpty) {
            skipped++;
            continue;
          }
          final expectedDir = _safeName(title);
          if (oldDir == expectedDir) {
            skipped++;
            continue;
          }
          final oldPath =
              Directory('$root${Platform.pathSeparator}$oldDir');
          final newPath =
              Directory('$root${Platform.pathSeparator}$expectedDir');
          if (!oldPath.existsSync()) {
            // 源目录不存在，只更新 DB（可能已手动改过）
            try {
              db.execute(
                'update download set directory = ? where id = ?',
                [expectedDir, id],
              );
              fixed++;
            } catch (_) {
              failed++;
            }
            continue;
          }
          if (newPath.existsSync()) {
            // 目标已存在，跳过避免覆盖
            skipped++;
            continue;
          }
          try {
            await oldPath.rename(newPath.path);
            db.execute(
              'update download set directory = ? where id = ?',
              [expectedDir, id],
            );
            fixed++;
          } catch (e, s) {
            failed++;
            LogManager.addLog(
              LogLevel.warning,
              'OnlineDownload',
              'fixDirectoryNames failed for $id: $e\n$s',
            );
          }
        }
      } catch (e, s) {
        LogManager.addLog(
          LogLevel.warning,
          'OnlineDownload',
          'fixDirectoryNames DB error: $e\n$s',
        );
      } finally {
        db?.dispose();
      }
    }
    App.notifyLocalDataChanged();
    return (fixed: fixed, failed: failed, skipped: skipped);
  }
}

class _Semaphore {
  _Semaphore(this._maxCount);

  final int _maxCount;
  int _current = 0;
  final _queue = <Completer<void>>[];

  Future<void> run(Future<void> Function() fn) async {
    if (_current >= _maxCount) {
      final completer = Completer<void>();
      _queue.add(completer);
      await completer.future;
    }
    _current++;
    try {
      await fn();
    } finally {
      _current--;
      if (_queue.isNotEmpty) {
        _queue.removeAt(0).complete();
      }
    }
  }
}

String bytesPerSecToText(int bytesPerSec) {
  if (bytesPerSec < 1024) return '$bytesPerSec B/s';
  if (bytesPerSec < 1024 * 1024) {
    return '${(bytesPerSec / 1024).toStringAsFixed(2)} KB/s';
  }
  if (bytesPerSec < 1024 * 1024 * 1024) {
    return '${(bytesPerSec / 1024 / 1024).toStringAsFixed(2)} MB/s';
  }
  return '${(bytesPerSec / 1024 / 1024 / 1024).toStringAsFixed(2)} GB/s';
}

class _OnlineDownloadCancelled {
  const _OnlineDownloadCancelled();
}

class OnlineDownloadedComic extends DownloadedComic {
  OnlineDownloadedComic({
    required this.rootPath,
    required this.directoryName,
    required super.comicId,
    required super.title,
    required super.author,
    super.description,
    super.thumbUrl,
    required super.chapters,
    required super.downloadedChapters,
    super.size,
    super.tagList,
  });

  factory OnlineDownloadedComic.fromDownloadedComic(
    DownloadedComic comic, {
    required String rootPath,
    required String directoryName,
  }) {
    return OnlineDownloadedComic(
      rootPath: rootPath,
      directoryName: directoryName,
      comicId: comic.comicId,
      title: comic.title,
      author: comic.author,
      description: comic.description,
      thumbUrl: comic.thumbUrl,
      chapters: comic.chapters,
      downloadedChapters: comic.downloadedChapters,
      size: comic.size,
      tagList: comic.tagList,
    )
      ..time = comic.time
      ..directory = directoryName;
  }

  final String rootPath;
  final String directoryName;

  String get rootDirectoryPath =>
      '$rootPath${Platform.pathSeparator}$directoryName';

  @override
  String? get fileSystemPath => rootDirectoryPath;

  @override
  String? get localCoverPath {
    for (final name in const ['cover.jpg', 'cover.webp', 'cover.png']) {
      final path = '$rootDirectoryPath${Platform.pathSeparator}$name';
      if (File(path).existsSync()) {
        return path;
      }
    }
    return null;
  }

  @override
  bool get canDelete => false;

  @override
  Widget createReadingPage({int? ep, int? page}) {
    final epsMap = <String, String>{};
    for (var i = 0; i < chapters.length; i++) {
      epsMap[(i + 1).toString()] = chapters[i];
    }
    return ComicReadingPage(
      OnlineLocalReadingData(
        title: title,
        id: id,
        rootDirectoryPath: rootDirectoryPath,
        chapters: epsMap,
      ),
      page ?? 1,
      ep ?? 1,
    );
  }
}

/// jm 在线下载漫画的本地包装：提供磁盘路径、封面、阅读页。
/// 与 OnlineDownloadedComic 平行（picacg 专用），区别在 id 带 jm 前缀、来源为禁漫。
class OnlineDownloadedJmComic extends DownloadedJmComic {
  OnlineDownloadedJmComic({
    required this.rootPath,
    required this.directoryName,
    required super.comicId,
    required super.name,
    super.author,
    super.size,
    required super.downloadedChapters,
    super.epNames,
    super.tagList,
  });

  factory OnlineDownloadedJmComic.fromDownloadedJmComic(
    DownloadedJmComic comic, {
    required String rootPath,
    required String directoryName,
  }) {
    return OnlineDownloadedJmComic(
      rootPath: rootPath,
      directoryName: directoryName,
      comicId: comic.comicId,
      name: comic.name,
      author: comic.author,
      size: comic.size,
      downloadedChapters: comic.downloadedChapters,
      epNames: comic.epNames,
      tagList: comic.tagList,
    )
      ..time = comic.time
      ..directory = directoryName;
  }

  final String rootPath;
  final String directoryName;

  String get rootDirectoryPath =>
      '$rootPath${Platform.pathSeparator}$directoryName';

  @override
  String? get fileSystemPath => rootDirectoryPath;

  @override
  String? get localCoverPath {
    for (final name in const ['cover.jpg', 'cover.webp', 'cover.png']) {
      final path = '$rootDirectoryPath${Platform.pathSeparator}$name';
      if (File(path).existsSync()) {
        return path;
      }
    }
    return null;
  }

  @override
  bool get canDelete => false;

  @override
  Widget createReadingPage({int? ep, int? page}) {
    final epsMap = <String, String>{};
    final epList = eps;
    for (var i = 0; i < epList.length; i++) {
      epsMap[(i + 1).toString()] = epList[i];
    }
    return ComicReadingPage(
      OnlineLocalReadingData(
        title: name,
        id: id,
        rootDirectoryPath: rootDirectoryPath,
        chapters: epsMap,
        isJm: true,
        jmComicId: comicId,
      ),
      page ?? 1,
      ep ?? 1,
    );
  }
}

class OnlineLocalReadingData extends ReadingData {
  OnlineLocalReadingData({
    required this.title,
    required this.id,
    required this.rootDirectoryPath,
    required this.chapters,
    this.isJm = false,
    this.jmComicId,
  });

  @override
  final String title;

  @override
  final String id;

  final String rootDirectoryPath;

  final Map<String, String> chapters;

  /// 是否为禁漫源；为 true 时缺图/坏图可走网络回退重下（含图块重组）。
  final bool isJm;

  /// 禁漫数字 id（不含 jm 前缀），用于回退时拉取在线章节图片列表。
  final String? jmComicId;

  /// 缓存每个 ep 的在线章节信息，避免重复网络请求。
  /// key = ep 序号(1-based)，value = (chapterId, urls)。
  final Map<int, ({String chapterId, List<String> urls})> _jmEpCache = {};

  @override
  String get downloadId => id;

  @override
  String get sourceKey => 'picacg';

  @override
  ComicType get comicType => ComicType.picacg;

  @override
  bool get hasEp => chapters.isNotEmpty;

  @override
  Map<String, String>? get eps => hasEp ? chapters : null;

  @override
  bool get downloaded => false;

  @override
  FavoriteType get favoriteType => FavoriteType.picacg;

  @override
  Future<List<String>> loadEpNetwork(int ep) async {
    final dir = Directory(
      hasEp
          ? '$rootDirectoryPath${Platform.pathSeparator}$ep'
          : rootDirectoryPath,
    );
    if (!await dir.exists()) {
      return const <String>[];
    }
    final files = dir
        .listSync()
        .whereType<File>()
        .where(_isImageFile)
        .toList(growable: false)
      ..sort((a, b) => _imageIndex(a).compareTo(_imageIndex(b)));
    return files.map((file) => file.path).toList(growable: false);
  }

  @override
  Stream<List<int>> loadImageNetwork(int ep, int page, String url) async* {
    // url 是 loadEpNetwork 返回的本地文件路径。
    final file = File(url);
    // 1) 先尝试本地：文件存在且非空即直接返回。
    if (await file.exists()) {
      final bytes = await file.readAsBytes();
      if (bytes.isNotEmpty) {
        yield bytes;
        return;
      }
    }
    // 2) 本地缺失/损坏：仅 jm 支持网络回退重下（含图块重组）。
    if (!isJm || jmComicId == null || jmComicId!.isEmpty) {
      // 非 jm 或缺少在线身份信息：无法回退，抛错让重试 UI 显示。
      throw Exception('图片缺失且无法重新下载: $url');
    }
    final bytes = await _refetchJmPage(url);
    yield bytes;
  }

  /// 从本地路径解析 ep/页序号，拉取在线章节图片列表，下载该页（含重组）写回磁盘并返回字节。
  Future<Uint8List> _refetchJmPage(String localPath) async {
    final f = File(localPath);
    final sep = Platform.pathSeparator;
    // 文件名形如 "{pageIndex+1}.{ext}"；上级目录名为 ep 序号（hasEp 时）。
    final fileName = f.uri.pathSegments.isNotEmpty
        ? f.uri.pathSegments.last
        : localPath.split(sep).last;
    final stem = fileName.replaceFirst(RegExp(r'\.[^.]+$'), '');
    final pageNo = int.tryParse(stem);
    if (pageNo == null || pageNo < 1) {
      throw Exception('无法解析页序号: $localPath');
    }
    // ep 序号：父目录名（数字）；无 ep 结构时回退为 1。
    final parentPath = f.parent.path;
    final parentName = parentPath
        .split(RegExp(r'[\\/]'))
        .where((s) => s.isNotEmpty)
        .lastOrNull ??
        '';
    final epNo = hasEp ? (int.tryParse(parentName) ?? 1) : 1;

    final info = await _ensureJmEp(epNo);
    final urls = info.urls;
    final idx = pageNo - 1;
    if (idx < 0 || idx >= urls.length) {
      throw Exception('页序号超出范围: $pageNo / ${urls.length}');
    }
    final onlineUrl = urls[idx];
    final onlineFileName = Uri.parse(onlineUrl).pathSegments.last;
    final pictureName = onlineFileName.replaceFirst(RegExp(r'\.[^.]+$'), '');
    final originalExt = _onlineExt(onlineUrl);

    // 下载原始字节（带重试）。
    final raw = await _downloadJmRawWithRetry(onlineUrl);
    if (raw.isEmpty) {
      throw Exception('下载到空字节: $onlineUrl');
    }
    final result = await JmRecombine.recombine(
      raw,
      epsId: info.chapterId,
      scrambleId: kJmScrambleId,
      pictureName: pictureName,
      originalExtension: originalExt,
    );
    // 写回磁盘：用解析出的 basePath（去掉原扩展名）+ 重组结果扩展名。
    final basePath = '${f.parent.path}$sep$pageNo';
    // 清掉同名残留的坏文件（任意扩展名）。
    for (final ext in const ['.png', '.webp', '.jpg', '.jpeg']) {
      final old = File('$basePath$ext');
      if (await old.exists()) {
        try {
          await old.delete();
        } catch (_) {}
      }
    }
    final out = File('$basePath${result.extension}');
    await out.writeAsBytes(result.bytes, flush: true);
    return result.bytes;
  }

  /// 拉取并缓存某 ep 的在线章节信息（chapterId + 图片 url 列表）。
  Future<({String chapterId, List<String> urls})> _ensureJmEp(int epNo) async {
    final cached = _jmEpCache[epNo];
    if (cached != null) return cached;
    final infoRes = await JmNetwork().getComicInfo(jmComicId!);
    if (infoRes.error) {
      throw Exception('获取漫画信息失败: ${infoRes.errorMessageWithoutNull}');
    }
    final series = infoRes.data.series;
    String chapterId;
    if (series.isEmpty) {
      // 单章漫画：chapterId 即漫画 id。
      chapterId = jmComicId!;
    } else {
      final sorted = series.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      final i = epNo - 1;
      if (i < 0 || i >= sorted.length) {
        throw Exception('章节序号超出范围: $epNo / ${sorted.length}');
      }
      chapterId = sorted[i].value;
    }
    final chapRes = await JmNetwork().getChapter(chapterId);
    if (chapRes.error) {
      throw Exception('获取章节失败: ${chapRes.errorMessageWithoutNull}');
    }
    final entry = (chapterId: chapterId, urls: chapRes.data);
    _jmEpCache[epNo] = entry;
    return entry;
  }

  Future<Uint8List> _downloadJmRawWithRetry(String url) async {
    var attempt = 0;
    while (true) {
      attempt++;
      try {
        final dio = logDio(BaseOptions(headers: getJmImgHeaders()));
        final res = await dio.get<List<int>>(
          url,
          options: Options(
            responseType: ResponseType.bytes,
            sendTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 30),
          ),
        );
        final data = res.data;
        if (data == null || data.isEmpty) {
          throw Exception('空响应: $url');
        }
        final expectedLength =
            int.tryParse(res.headers.value('content-length') ?? '');
        if (expectedLength != null && data.length < expectedLength) {
          throw Exception('下载不完整: ${data.length}/$expectedLength');
        }
        return Uint8List.fromList(data);
      } catch (error) {
        if (attempt >= 3) rethrow;
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
  }

  static String _onlineExt(String url) {
    final name = Uri.parse(url).pathSegments.last.toLowerCase();
    final dot = name.lastIndexOf('.');
    if (dot < 0) return '.jpg';
    return name.substring(dot);
  }

  @override
  String buildImageKey(int ep, int page, String url) => url;

  static bool _isImageFile(File file) {
    final name = file.path.toLowerCase();
    return name.endsWith('.jpg') ||
        name.endsWith('.jpeg') ||
        name.endsWith('.png') ||
        name.endsWith('.webp');
  }

  static int _imageIndex(File file) {
    final name =
        file.uri.pathSegments.isEmpty ? file.path : file.uri.pathSegments.last;
    final stem = name.replaceFirst(RegExp(r'\.[^.]+$'), '');
    return int.tryParse(stem) ?? 0;
  }
}

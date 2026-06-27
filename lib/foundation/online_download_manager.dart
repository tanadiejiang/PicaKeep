import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/foundation/log.dart';
import 'package:picakeep/network/app_dio.dart';
import 'package:picakeep/network/picacg_network/picacg_network.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/reader/comic_reading_page.dart';

class OnlineDownloadTask {
  OnlineDownloadTask({required this.comic});

  final PicacgComicItem comic;
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

  String get id => comic.id;

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
            if (parsed is DownloadedComic) {
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
    task.cancelToken?.cancel('cancelled');
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
    if (_tasks.containsKey(comic.id)) {
      return const Res(true);
    }
    final task = OnlineDownloadTask(comic: comic)..totalEps = comic.eps.length;
    _tasks[comic.id] = task;
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
        unawaited(_runPicacgTask(task));
        return;
      }
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
    task.cancelToken = cancelToken;
    final response = await dio.get<ResponseBody>(
      url,
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.stream,
        sendTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
      ),
    );
    task.cancelToken = null;
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
          .map((t) => {
                'comicJson': t.comic.toQueueJson(),
                'currentEp': t.currentEp,
                'paused': t.paused,
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
          final comicJson = item['comicJson'] as Map;
          final comic = PicacgComicItem.fromQueueJson(comicJson);
          if (_tasks.containsKey(comic.id)) continue;
          final task = OnlineDownloadTask(comic: comic)
            ..totalEps = comic.eps.length
            ..currentEp = (item['currentEp'] as int?) ?? 0
            ..paused = true;
          _tasks[comic.id] = task;
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
    } finally {
      db.dispose();
    }
  }

  Database _openDownloadDb(String rootPath) {
    final dbPath = '$rootPath${Platform.pathSeparator}download.db';
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

  /// 将旧式（纯ID）文件夹名修正为新式（标题_ID），同步更新 DB 的 directory 字段。
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

class OnlineLocalReadingData extends ReadingData {
  OnlineLocalReadingData({
    required this.title,
    required this.id,
    required this.rootDirectoryPath,
    required this.chapters,
  });

  @override
  final String title;

  @override
  final String id;

  final String rootDirectoryPath;

  final Map<String, String> chapters;

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
    yield await File(url).readAsBytes();
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

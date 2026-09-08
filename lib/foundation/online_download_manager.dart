import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive_io.dart';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/download_author_resolver.dart';
import 'package:picakeep/foundation/image_loader/jm_image_recombine.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/foundation/log.dart';
import 'package:picakeep/foundation/untranslated_tags/untranslated_tag_coordinator.dart';
import 'package:picakeep/network/app_dio.dart';
import 'package:picakeep/network/eh_network/eh_main_network.dart';
import 'package:picakeep/network/eh_network/eh_models.dart';
import 'package:picakeep/network/eh_network/get_gallery_id.dart';
import 'package:picakeep/network/jm_network/jm_network.dart';
import 'package:picakeep/network/nhentai_network/nhentai_main_network.dart';
import 'package:picakeep/network/picacg_network/picacg_network.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/reader/comic_reading_page.dart';
import 'package:picakeep/tools/tags_translation.dart';
import 'package:uuid/uuid.dart';

class OnlineDownloadTask {
  OnlineDownloadTask.jm({required JmComicInfo jmInfo})
      : _comic = null,
        _jmInfo = jmInfo,
        _gallery = null,
        _nhentaiComic = null,
        sourceKey = 'jm';

  OnlineDownloadTask.picacg({required PicacgComicItem comic})
      : _comic = comic,
        _jmInfo = null,
        _gallery = null,
        _nhentaiComic = null,
        sourceKey = 'picacg';

  OnlineDownloadTask.ehentai({required Gallery gallery})
      : _comic = null,
        _jmInfo = null,
        _gallery = gallery,
        _nhentaiComic = null,
        sourceKey = 'ehentai';

  OnlineDownloadTask.nhentai({required NhentaiComic nhentaiComic})
      : _comic = null,
        _jmInfo = null,
        _gallery = null,
        _nhentaiComic = nhentaiComic,
        sourceKey = 'nhentai';

  final PicacgComicItem? _comic;
  final JmComicInfo? _jmInfo;
  final Gallery? _gallery;
  final NhentaiComic? _nhentaiComic;
  final String sourceKey;

  // 向前兼容的 comic getter（仅 picacg 任务有效）
  PicacgComicItem get comic => _comic!;

  /// ehentai 画廊载体（仅 ehentai 任务有效）。
  Gallery get gallery => _gallery!;

  /// nhentai 画廊载体（仅 nhentai 任务有效）。
  NhentaiComic get nhentaiComic => _nhentaiComic!;

  /// 通用 display getters
  String get taskId {
    switch (sourceKey) {
      case 'jm':
        return 'jm${_jmInfo!.id}';
      case 'ehentai':
        return getGalleryId(_gallery!.link); // 无前缀，与 DownloadedGallery.id 一致
      case 'nhentai':
        return 'nhentai${_nhentaiComic!.id}';
      default:
        return _comic!.id;
    }
  }

  String get taskTitle {
    switch (sourceKey) {
      case 'jm':
        return _jmInfo!.title;
      case 'ehentai':
        return _gallery!.title;
      case 'nhentai':
        return _nhentaiComic!.title;
      default:
        return _comic!.title;
    }
  }

  String get taskCover {
    switch (sourceKey) {
      case 'jm':
        return _jmInfo!.coverUrl;
      case 'ehentai':
        return _gallery!.coverPath;
      case 'nhentai':
        return _nhentaiComic!.cover;
      default:
        return _comic!.cover;
    }
  }

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

  // ehentai 专用：0=逐页，1=归档Original，2=归档Resample
  int downloadType = 0;

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

String _onlineDownloadRecordSubtitle(DownloadedItem item) {
  if (item.type == DownloadType.ehentai || item.type == DownloadType.nhentai) {
    return resolveDownloadedAuthors(item).join(', ');
  }
  return item.subTitle;
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
            } else if (parsed is DownloadedGallery) {
              items.add(
                OnlineDownloadedGallery.fromDownloadedGallery(
                  parsed,
                  rootPath: root,
                  directoryName: directory,
                ),
              );
            } else if (parsed is NhentaiDownloadedComic) {
              items.add(
                OnlineDownloadedNhentai.fromNhentaiDownloadedComic(
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
    await _observeUntranslatedTags(items, context: 'local');
    return items;
  }

  Future<void> _observeUntranslatedTags(
    Iterable<DownloadedItem> items, {
    required String context,
  }) async {
    try {
      if (!tagTranslationsReady) {
        try {
          await loadTagTranslations();
        } catch (_) {
          // The collector keeps a bounded observation queue until retry.
        }
      }
      if (tagTranslationsReady) {
        await UntranslatedTagCoordinator.instance.flushPending();
      }
      final operationId = '$context-${const Uuid().v4()}';
      for (final item in items) {
        final source = switch (item.type) {
          DownloadType.ehentai => 'ehentai',
          DownloadType.nhentai => 'nhentai',
          _ => '',
        };
        if (source.isEmpty) continue;
        final categorized = item is NhentaiDownloadedComic
            ? item.categorizedTags
            : const <String, List<String>>{};
        final comicId = item is NhentaiDownloadedComic ? item.comicID : item.id;
        await UntranslatedTagCoordinator.instance.observe(
          UntranslatedTagObservation(
            source: source,
            comicId: comicId,
            operationId: operationId,
            context: context,
            flat: item.tags,
            categorized: categorized,
          ),
        );
      }
    } catch (_) {
      // Collection must not fail a download or a list restore.
    }
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
    if (task == null || task.completed || task.cancelled || !task.paused) {
      return;
    }
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
    if (_tasks.containsKey('picacg${comic.id}') ||
        _tasks.containsKey(comic.id)) {
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

  /// 入队一个 ehentai 画廊（单画廊多图、无章节）。供 06 详情页下载按钮调用。
  ///
  /// 去重：同 [getGalleryId] 标识不重复入队。totalEps 恒为 1（无章节）。
  Future<Res<bool>> enqueueEhentai(Gallery gallery, [int type = 0]) async {
    final key = getGalleryId(gallery.link);
    if (_tasks.containsKey(key)) return const Res(true);
    final task = OnlineDownloadTask.ehentai(gallery: gallery)
      ..totalEps = 1
      ..totalPages = int.tryParse(gallery.maxPage) ?? 0
      ..downloadType = type;
    _tasks[task.id] = task;
    _notify();
    unawaited(_saveQueue());
    _scheduleNext();
    return const Res(true);
  }

  /// 入队一个 nhentai 画廊（单画廊多图、无章节）。供详情页下载按钮调用。
  ///
  /// 去重：同 `nhentai{id}` 标识不重复入队。totalEps 恒为 1（无章节）；
  /// totalPages 先用详情页缩略图数预估，下载时以 getImages 实际数为准。
  Future<Res<bool>> enqueueNhentai(NhentaiComic comic) async {
    final key = 'nhentai${comic.id}';
    if (_tasks.containsKey(key)) return const Res(true);
    final task = OnlineDownloadTask.nhentai(nhentaiComic: comic)
      ..totalEps = 1
      ..totalPages = comic.thumbnails.length;
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
      if (!task.completed &&
          !task.cancelled &&
          !task.paused &&
          task.error == null) {
        unawaited(_runTask(task));
        return;
      }
    }
  }

  Future<void> _runTask(OnlineDownloadTask task) async {
    if (task.sourceKey == 'jm') {
      await _runJmTask(task);
    } else if (task.sourceKey == 'ehentai') {
      await _runEhentaiTask(task);
    } else if (task.sourceKey == 'nhentai') {
      await _runNhentaiTask(task);
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
        sourceTime: task.comic.updatedAt,
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
      final root =
          Directory('$downloadRoot${Platform.pathSeparator}$safeDirectory');
      await root.create(recursive: true);
      // 封面（不重组，直接存原始字节）
      if (info.coverUrl.isNotEmpty) {
        await _downloadJmFile(
            task, info.coverUrl, '${root.path}${Platform.pathSeparator}cover',
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
        task.currentEpName =
            i < info.epNames.length ? info.epNames[i] : '第$epKey章';
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
          final basePath = '${epDir.path}${Platform.pathSeparator}${pi + 1}';
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
            if (File('$basePath$ext').existsSync()) {
              exists = true;
              break;
            }
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
      LogManager.addLog(
          LogLevel.error, 'OnlineDownload', '$error\n$stackTrace');
    } finally {
      _running = false;
      task.stopSpeedTimer();
      unawaited(_saveQueue());
      _notify();
      _scheduleNext();
    }
  }

  /// ehentai 专用下载执行体（单画廊多图、无章节、根目录平铺）。
  ///
  /// 逐页 [EhNetwork.getEhImageUrl]（`preflightVerify: false`，不发试探性 GET）解密拿
  /// 直链，再带图片鉴权三件套 header 写盘到根目录 `1.{ext}…pageCount.{ext}`；直链是否
  /// 命中 509 由下载响应头判定，命中则 [EhNetwork.retryEhImageUrlWithNL] 换 CDN 节点
  /// 重试。完成后写 [DownloadedGallery]（真实页数）落库。
  Future<void> _runEhentaiTask(OnlineDownloadTask task) async {
    if (_running) return;
    _running = true;
    task.startSpeedTimer(_notify);
    final gallery = task._gallery!;
    try {
      final downloadRoot = await _resolveOnlineDownloadRoot();
      final safeDirectory = _safeName(gallery.title);
      final root =
          Directory('$downloadRoot${Platform.pathSeparator}$safeDirectory');
      await root.create(recursive: true);

      if (task.downloadType == 0) {
        // ── 逐页模式 ────────────────────────────────────────────────────────
        final headers = EhNetwork().galleryHeaders(gallery.link);

        if (gallery.coverPath.isNotEmpty) {
          final coverUrl =
              gallery.coverPath.replaceFirst('s.exhentai.org', 'ehgt.org');
          try {
            await _downloadFile(
              task,
              coverUrl,
              File('${root.path}${Platform.pathSeparator}cover.jpg'),
              headers: headers,
            );
          } catch (e) {
            LogManager.addLog(
                LogLevel.warning, 'OnlineDownload', 'eh cover failed: $e');
          }
        }

        final totalPages = int.tryParse(gallery.maxPage) ?? 0;
        if (totalPages <= 0) {
          throw Exception('Invalid gallery page count: ${gallery.maxPage}');
        }
        task.currentEp = 1;
        task.currentEpName = gallery.title;
        // 续传：不无条件重置 currentPage（暂停/失败前的进度需要保留）；
        // totalPages 每次都以画廊真实页数重新赋值，不受续传影响。
        task.totalPages = totalPages;
        _notify();

        // 页级流水线（reader页解析+解密+下载）并发度，与 picacg/jm/nhentai 统一读
        // settings[79]。ehgt.org 的 3 并发官方限流契约不受影响：真实字节下载
        // （_downloadFileOnce）过 acquireEhgtSlot，共用 EhNetwork 单例的同一个
        // ehgtLoading 计数器，指向 ehgt.org/s.exhentai.org 的在途请求总数仍被硬卡在 3。
        // 下载链路已取消试探性 GET，故一张图只占一个 ehgt 配额槽（过去是两个）。
        final ehConcurrency = int.tryParse(appdata.settings[79]) ?? 6;
        final semaphore = _Semaphore(ehConcurrency);
        var completedPages = 0;
        final errors = <String>[];
        final futures = <Future<void>>[];
        for (var pageIndex = 0; pageIndex < totalPages; pageIndex++) {
          _throwIfCancelled(task);
          final page = pageIndex + 1;
          // 续传兜底：本地文件已存在（暂停/失败前已下载完成）直接计入完成数，
          // 不再对该页发起 getEhImageUrl 网络请求——避免"缓慢爬升"式空转
          // （旧实现必须先跑完整解密请求才能判断是否需要下载，这才是真正耗时点）。
          if (_ehPageFileExists(root, page)) {
            completedPages++;
            task.currentPage = completedPages;
            _notify();
            continue;
          }
          futures.add(semaphore.run(() async {
            _throwIfCancelled(task);
            try {
              // preflightVerify: false —— 不再发试探性 GET，直链可用性由下面这次
              // 真实下载的响应头判定，每张图只发一次图片请求。
              var (imageUrl, nl) = await EhNetwork()
                  .getEhImageUrl(gallery, page, preflightVerify: false);
              // 509/失效节点重试：命中 text/html、非 2xx 或空直链就用 nl 换 CDN
              // 节点重取直链，最多 4 次下载尝试（与移除的 _verifyImageReachable
              // 内部 retryTimes==4 上限对齐），4 次仍失败才记该页失败。
              var attempts = 0;
              while (true) {
                final file = File(
                  '${root.path}${Platform.pathSeparator}$page${_imageExtension(imageUrl)}',
                );
                try {
                  // preflightVerify:false 时网络层不再校验直链，reader 页结构变化/
                  // 被风控页替换会解析出空串（showpage 回退分支）或字面量 "null"
                  // （MPV 分支 apiJson['i'] 为 null）。这类直链发出去只会拿到无意义
                  // 的错误，等同「节点不可用」，走同一条 nl 换节点路径——旧预检链路
                  // 由 _verifyImageReachable 的 `if (image.isEmpty) throw` 挡住并重试。
                  if (!imageUrl.startsWith('http')) {
                    throw _EhImageLimitReachedException(imageUrl, 'empty url');
                  }
                  await _downloadFile(task, imageUrl, file,
                      headers: headers, detectEhLimitPage: true);
                  break;
                } on _EhImageLimitReachedException {
                  attempts++;
                  if (attempts >= 4) {
                    throw Exception(
                        'Failed to load image.\nMaximum number of retries reached.');
                  }
                  (imageUrl, nl) = await EhNetwork()
                      .retryEhImageUrlWithNL(gallery, page, nl);
                }
              }
            } catch (e) {
              if (e is _OnlineDownloadCancelled) rethrow;
              errors.add('page $page: $e');
              LogManager.addLog(LogLevel.warning, 'OnlineDownload',
                  'eh page $page failed: $e');
              return;
            }
            // 已完成页数量计数（而非页序直接赋值），保证并发乱序完成时进度单调递增。
            completedPages++;
            task.currentPage = completedPages;
            _notify();
          }));
          if (pageIndex % 5 == 0) {
            unawaited(_saveQueue());
          }
        }
        await Future.wait(futures);
        _throwIfCancelled(task);
        if (completedPages == 0) {
          throw Exception(
              errors.isNotEmpty ? errors.first : 'No page downloaded');
        }

        final item = DownloadedGallery(
          galleryTitle: gallery.title,
          subtitle: gallery.subTitle ?? '',
          uploader: gallery.uploader,
          link: gallery.link,
          coverPath: gallery.coverPath,
          size: _directoryMb(root),
          tagList: gallery.toBrief().tags,
          sourceTime: gallery.time,
          pageCount: completedPages,
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
      } else {
        // ── 归档模式（type 1=Original / 2=Resample）───────────────────────
        final archiveUrl = gallery.auth?['archiveDownload'];
        if (archiveUrl == null || archiveUrl.isEmpty) {
          throw Exception('归档下载 URL 缺失（画廊 auth["archiveDownload"] 为 null）');
        }

        task.currentEp = 1;
        task.currentEpName = gallery.title;
        task.currentPage = 0;
        task.totalPages = 100; // 用百分比模拟；实际字节进度下方更新
        _notify();

        // 1. 取 zip 真实链接（会实际扣积分，务必在用户确认后才走到此处）
        final linkRes = await EhNetwork()
            .getArchiveDownloadLink(archiveUrl, task.downloadType);
        if (linkRes.error) {
          throw Exception('获取归档链接失败：${linkRes.errorMessageWithoutNull}');
        }
        final zipUrl = linkRes.data;

        // 2. 流式下载 zip 到 temp.zip，用字节进度模拟页进度
        final tempZip = File('${root.path}${Platform.pathSeparator}temp.zip');
        final dio = logDio();
        final cancelToken = CancelToken();
        task.addToken(cancelToken);
        try {
          int received = 0;
          int? total;
          await dio.download(
            zipUrl,
            tempZip.path,
            cancelToken: cancelToken,
            options: Options(headers: EhNetwork().galleryHeaders(gallery.link)),
            onReceiveProgress: (rcv, ttl) {
              received = rcv;
              total = ttl > 0 ? ttl : null;
              task.onData(rcv - received);
              if (total != null) {
                task.currentPage = ((received / total!) * 90).round();
                _notify();
              }
            },
          );
        } finally {
          task.removeToken(cancelToken);
        }
        _throwIfCancelled(task);

        // 3. 解压 zip
        task.currentPage = 91;
        _notify();
        final bytes = await tempZip.readAsBytes();
        final archive = ZipDecoder().decodeBytes(bytes);
        final imageFiles = archive.files
            .where((f) =>
                f.isFile &&
                f.name != 'cover.jpg' &&
                RegExp(r'\.(jpe?g|png|webp|gif)$', caseSensitive: false)
                    .hasMatch(f.name))
            .toList()
          ..sort((a, b) => a.name.compareTo(b.name));

        // 封面（若归档包含 cover.jpg 则保留，否则单独不处理）
        final coverEntry = archive.files.firstWhere(
          (f) => f.isFile && f.name == 'cover.jpg',
          orElse: () => ArchiveFile.noCompress('__none__', 0, Uint8List(0)),
        );
        if (coverEntry.name != '__none__') {
          await File('${root.path}${Platform.pathSeparator}cover.jpg')
              .writeAsBytes(coverEntry.content as List<int>);
        }

        // 4. 按序重命名写盘：0.ext / 1.ext ...
        for (var i = 0; i < imageFiles.length; i++) {
          _throwIfCancelled(task);
          final entry = imageFiles[i];
          final ext = entry.name.contains('.')
              ? '.${entry.name.split('.').last.toLowerCase()}'
              : '.jpg';
          final dest =
              File('${root.path}${Platform.pathSeparator}${i + 1}$ext');
          await dest.writeAsBytes(entry.content as List<int>);
          task.currentPage = 91 + ((i / imageFiles.length) * 8).round();
          _notify();
        }
        task.currentPage = 99;
        _notify();

        // 5. 删 temp.zip
        if (await tempZip.exists()) await tempZip.delete();

        if (imageFiles.isEmpty) {
          throw Exception('归档解压后无图片文件');
        }

        final item = DownloadedGallery(
          galleryTitle: gallery.title,
          subtitle: gallery.subTitle ?? '',
          uploader: gallery.uploader,
          link: gallery.link,
          coverPath: gallery.coverPath,
          size: _directoryMb(root),
          tagList: gallery.toBrief().tags,
          sourceTime: gallery.time,
          pageCount: imageFiles.length,
        )
          ..directory = safeDirectory
          ..time = DateTime.now();
        await _upsertDownloadRecord(
          rootPath: downloadRoot,
          item: item,
          directory: safeDirectory,
        );
        task.currentPage = 100;
        task.completed = true;
        App.notifyLocalDataChanged();
      }
    } on _OnlineDownloadCancelled catch (_) {
      if (!task.paused) task.cancelled = true;
    } catch (error, stackTrace) {
      task.error = error.toString();
      LogManager.addLog(
          LogLevel.error, 'OnlineDownload', '$error\n$stackTrace');
    } finally {
      _running = false;
      task.stopSpeedTimer();
      unawaited(_saveQueue());
      _notify();
      _scheduleNext();
    }
  }

  /// nhentai 专用下载执行体（单画廊多图、无章节、根目录平铺）。
  ///
  /// 与 ehentai 的差异：nhentai 图片是 CDN 直链，[NhentaiNetwork.getImages] 一次
  /// 性返回全部页 URL（无需逐页解密），故可并发下载。带 Referer 头规避 CDN 防盗链。
  /// 完成后写 [NhentaiDownloadedComic]（id=`nhentai{id}`）落库。
  Future<void> _runNhentaiTask(OnlineDownloadTask task) async {
    if (_running) return;
    _running = true;
    task.startSpeedTimer(_notify);
    final comic = task._nhentaiComic!;
    try {
      final downloadRoot = await _resolveOnlineDownloadRoot();
      final safeDirectory = _safeName(comic.title);
      final root =
          Directory('$downloadRoot${Platform.pathSeparator}$safeDirectory');
      await root.create(recursive: true);

      const headers = {'Referer': 'https://nhentai.net/'};

      // 封面（失败不阻断正文）。
      if (comic.cover.isNotEmpty) {
        try {
          await _downloadFile(
            task,
            comic.cover,
            File('${root.path}${Platform.pathSeparator}cover.jpg'),
            headers: headers,
          );
        } catch (e) {
          LogManager.addLog(
              LogLevel.warning, 'OnlineDownload', 'nhentai cover failed: $e');
        }
      }

      // 一次性取全部页 CDN 直链。
      final imagesRes = await NhentaiNetwork().getImages(comic.id);
      if (imagesRes.error) {
        throw Exception(imagesRes.errorMessageWithoutNull);
      }
      final urls = imagesRes.data;
      if (urls.isEmpty) {
        throw Exception('No page found');
      }

      task.currentEp = 1;
      task.currentEpName = comic.title;
      task.currentPage = 0;
      task.totalPages = urls.length;
      _notify();

      var completedPages = 0;
      final concurrency = int.tryParse(appdata.settings[79]) ?? 6;
      final semaphore = _Semaphore(concurrency);
      final errors = <String>[];
      final futures = <Future<void>>[];
      for (var pageIndex = 0; pageIndex < urls.length; pageIndex++) {
        _throwIfCancelled(task);
        final url = urls[pageIndex];
        final file = File(
          '${root.path}${Platform.pathSeparator}${pageIndex + 1}${_imageExtension(url)}',
        );
        futures.add(semaphore.run(() async {
          _throwIfCancelled(task);
          try {
            await _downloadFile(task, url, file, headers: headers);
          } catch (e) {
            errors.add('page ${pageIndex + 1}: $e');
            return;
          }
          completedPages++;
          task.currentPage = completedPages;
          _notify();
        }));
      }
      await Future.wait(futures);
      _throwIfCancelled(task);
      if (completedPages == 0) {
        throw Exception(
            errors.isNotEmpty ? errors.first : 'No page downloaded');
      }

      final item = NhentaiDownloadedComic(
        comicID: comic.id,
        title: comic.title,
        size: _directoryMb(root),
        cover: comic.cover,
        tagList: comic.tags['Tags'] ?? const [],
        categorizedTags: comic.tags,
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
      if (!task.paused) task.cancelled = true;
    } catch (error, stackTrace) {
      task.error = error.toString();
      LogManager.addLog(
          LogLevel.error, 'OnlineDownload', '$error\n$stackTrace');
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
      final expectedLength =
          int.tryParse(res.headers.value('content-length') ?? '');
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

  /// [detectEhLimitPage] 为 true 时（仅 EH 链路传），响应头 Content-Type 为 text/html
  /// 或状态码非 2xx（509 配额耗尽等）即抛 [_EhImageLimitReachedException]，且不进本
  /// 函数的同 URL 重试——换节点由调用方（`_runEhentaiTask`）用 nl 处理。
  Future<void> _downloadFile(
    OnlineDownloadTask task,
    String url,
    File file, {
    Map<String, String>? headers,
    bool detectEhLimitPage = false,
  }) async {
    _throwIfCancelled(task);
    if (await file.exists() && await file.length() > 0) {
      return;
    }
    await file.parent.create(recursive: true);

    var attempt = 0;
    while (true) {
      attempt++;
      try {
        await _downloadFileOnce(task, url, file,
            headers: headers, detectEhLimitPage: detectEhLimitPage);
        return;
      } catch (error) {
        _throwIfCancelled(task);
        // 509 限流页：URL 本身已失效，重试同一 URL 只会再拿到 html，直接交给
        // 上层换 CDN 节点。
        if (error is _EhImageLimitReachedException) rethrow;
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
    File file, {
    Map<String, String>? headers,
    bool detectEhLimitPage = false,
  }) async {
    // ehgt.org 3 并发闸：acquireEhgtSlot/releaseEhgtSlot 内部会先判断 url 是否
    // 指向 ehgt.org/s.exhentai.org，非该域名直接空操作返回，故对 picacg/jm/
    // nhentai 的下载请求无影响；真实图片字节下载请求接入这个闸后，下载链路取消
    // 试探性 GET，一张图只占一个配额槽。
    await EhNetwork().acquireEhgtSlot(url);
    // 共享下载 dio：复用底层 HttpClient 连接池 / keep-alive，避免每张图都重新
    // TLS 握手。options 仅首次调用生效，值必须与 EhNetwork.sharedDownloadBaseOptions()
    // 一致（同一单例，谁先初始化都得到同样配置）。CancelToken 与进度回调仍是
    // per-request 参数，不受共享实例影响。
    final dio =
        sharedDownloadDio(options: EhNetwork.sharedDownloadBaseOptions());
    final cancelToken = CancelToken();
    task.addToken(cancelToken);
    try {
      final response = await dio.get<ResponseBody>(
        url,
        cancelToken: cancelToken,
        options: Options(
          headers: headers,
          responseType: ResponseType.stream,
          sendTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
          // EH 链路放开状态码校验：dio 默认只放行 2xx，509（H@H 配额耗尽）会在拿到
          // ResponseBody 之前就抛 DioException.badResponse，下面的判定块根本执行不
          // 到，该页会被当成不可重试错误直接失败——旧预检链路对这类响应是会换节点
          // 的。放开后由下面统一把「非 2xx」也判成限流/失效节点，交给 nl 换节点重试。
          // null 即沿用 BaseOptions 上的默认校验（只放行 2xx），非 EH 链路行为不变。
          validateStatus: detectEhLimitPage ? (_) => true : null,
        ),
      );
      _throwIfCancelled(task);
      final body = response.data;
      if (body == null) {
        throw Exception('Empty image response: $url');
      }
      if (detectEhLimitPage) {
        // 509 判定挪到真实下载这一次请求上：响应头就够判，不必读字节，判据与旧
        // EhNetwork._verifyImageReachable 一致（它对任何请求异常——含非 2xx 抛出的
        // DioException——都会换节点重试，故这里把状态码型失败也算进去）。在
        // openWrite 之前抛出，保证 html/错误页永远不会被写成图片文件。
        final status = response.statusCode ?? 0;
        final contentType = body.headers['Content-Type']?[0] ??
            body.headers['content-type']?[0];
        final badStatus = status < 200 || status >= 300;
        final isHtml =
            contentType != null && contentType.startsWith('text/html');
        if (badStatus || isHtml) {
          // 509 页只有几百字节，读完丢弃让连接正常归还连接池。不能用
          // CancelToken.cancel：它与 receiveTimeout 定时器竞态，会复现
          // "Bad state: Cannot add event after closing"（见第十四轮计划 10）。
          try {
            await body.stream.drain<void>().timeout(const Duration(seconds: 5));
          } catch (_) {
            // 丢弃失败不影响判定结果。
          }
          throw _EhImageLimitReachedException(
            url,
            badStatus ? 'HTTP $status' : 'content-type $contentType',
          );
        }
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
      EhNetwork().releaseEhgtSlot(url);
    }
  }

  void _throwIfCancelled(OnlineDownloadTask task) {
    if (task.cancelled || task.paused) {
      throw const _OnlineDownloadCancelled();
    }
  }

  /// 续传兜底：判断第 [page] 页是否已经真实落盘（任一已知扩展名、非空文件）。
  /// 用于并发改造后跳过已完成页而不发起 getEhImageUrl 网络请求，
  /// 同时不依赖 currentPage 数值本身语义（暂停瞬间的计数可能与实际落盘不完全一致）。
  bool _ehPageFileExists(Directory root, int page) {
    for (final ext in const ['.jpg', '.png', '.webp', '.jpeg']) {
      final file = File('${root.path}${Platform.pathSeparator}$page$ext');
      if (file.existsSync() && file.lengthSync() > 0) {
        return true;
      }
    }
    return false;
  }

  String _safeName(String value) {
    var name = value.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    // 240 字节上限：留出去重后缀余量；与 download.dart _DownloadDb.sanitizeFileName 保持同一上限
    while (utf8.encode(name).length > 240) {
      name = name.substring(0, name.length - 1);
    }
    return name;
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
        } else if (t.sourceKey == 'ehentai') {
          return {
            'sourceKey': 'ehentai',
            'galleryJson': t._gallery!.toJson(),
            'currentPage': t.currentPage,
            'paused': t.paused,
            'downloadType': t.downloadType,
          };
        } else if (t.sourceKey == 'nhentai') {
          return {
            'sourceKey': 'nhentai',
            'nhentaiJson': t._nhentaiComic!.toMap(),
            'currentPage': t.currentPage,
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
      }).toList();
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
          } else if (sourceKey == 'ehentai') {
            final galleryJson = (item['galleryJson'] as Map)
                .map((k, v) => MapEntry(k.toString(), v));
            // Gallery.fromJson 第138行 tag 桶 bug 已在 02 修复。
            final gallery = Gallery.fromJson(galleryJson);
            final key = getGalleryId(gallery.link);
            if (_tasks.containsKey(key)) continue;
            final task = OnlineDownloadTask.ehentai(gallery: gallery)
              ..totalEps = 1
              ..totalPages = int.tryParse(gallery.maxPage) ?? 0
              ..currentPage = (item['currentPage'] as int?) ?? 0
              ..downloadType = (item['downloadType'] as int?) ?? 0
              ..paused = true;
            _tasks[task.id] = task;
          } else if (sourceKey == 'nhentai') {
            final nhentaiJson = (item['nhentaiJson'] as Map)
                .map((k, v) => MapEntry(k.toString(), v));
            final comic = NhentaiComic.fromMap(nhentaiJson);
            final key = 'nhentai${comic.id}';
            if (_tasks.containsKey(key)) continue;
            final task = OnlineDownloadTask.nhentai(nhentaiComic: comic)
              ..totalEps = 1
              ..currentPage = (item['currentPage'] as int?) ?? 0
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
        _onlineDownloadRecordSubtitle(item),
        (item.time ?? DateTime.now()).millisecondsSinceEpoch,
        directory,
        item.comicSize,
        jsonEncode(item.toJson()),
      ]);

      // 验证记录确实写入（防止只读 db 静默失败）
      final check = db
          .select('select count(*) as c from download where id = ?', [item.id]);
      final count = check.isNotEmpty ? (check.first['c'] as int?) ?? 0 : 0;
      if (count == 0) {
        throw Exception(
          '下载记录写入失败：数据库未保存该条目 (id=${item.id})。\n'
          '数据库可能为只读，请检查文件权限：\n'
          '$rootPath${Platform.pathSeparator}download.db',
        );
      }
      await _observeUntranslatedTags([item], context: 'download');
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
      authors:
          (json['authors'] as List?)?.map((e) => e.toString()).toList() ?? [],
      description: json['description']?.toString() ?? '',
      likes: 0,
      views: 0,
      comments: 0,
      tags: (json['tags'] as List?)?.map((e) => e.toString()).toList() ?? [],
      works: (json['works'] as List?)?.map((e) => e.toString()).toList() ?? [],
      actors:
          (json['actors'] as List?)?.map((e) => e.toString()).toList() ?? [],
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
          final oldPath = Directory('$root${Platform.pathSeparator}$oldDir');
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

/// EH 图片直链不可用：命中 509 限流页 / 失效 CDN 节点 / 非 2xx 响应 / 解析出空直链。
///
/// 重试同一 URL 无意义（该 URL 本身已失效），必须回到网络层用 nl 换 CDN 节点
/// 重取直链，故 [OnlineDownloadManager._downloadFile] 的通用重试要放行此异常，
/// 由 `_runEhentaiTask` 的 nl 重试循环接手。
class _EhImageLimitReachedException implements Exception {
  const _EhImageLimitReachedException(this.url, this.reason);

  final String url;

  /// 判定依据（如 `HTTP 509`、`content-type text/html`、`empty url`），进日志用。
  final String reason;

  @override
  String toString() => 'EH image unavailable ($reason): $url';
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
    super.sourceTime,
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
      sourceTime: comic.sourceTime,
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

/// ehentai 在线下载画廊的本地包装：提供磁盘路径、封面、阅读页。
/// 与 OnlineDownloadedComic / OnlineDownloadedJmComic 平行；ehentai 为单画廊
/// 多图、无章节，页图平铺在下载目录根（1.{ext}…pageCount.{ext}）。
class OnlineDownloadedGallery extends DownloadedGallery {
  OnlineDownloadedGallery({
    required this.rootPath,
    required this.directoryName,
    required super.galleryTitle,
    super.subtitle,
    super.uploader,
    required super.link,
    super.coverPath,
    super.size,
    super.tagList,
    super.sourceTime,
    super.pageCount,
  });

  factory OnlineDownloadedGallery.fromDownloadedGallery(
    DownloadedGallery gallery, {
    required String rootPath,
    required String directoryName,
  }) {
    return OnlineDownloadedGallery(
      rootPath: rootPath,
      directoryName: directoryName,
      galleryTitle: gallery.galleryTitle,
      subtitle: gallery.subtitle,
      uploader: gallery.uploader,
      link: gallery.link,
      coverPath: gallery.coverPath,
      size: gallery.size,
      tagList: gallery.tagList,
      sourceTime: gallery.sourceTime,
      pageCount: gallery.pageCount,
    )
      ..time = gallery.time
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
    // 无章节：chapters 传空 map → hasEp=false → 读根目录平铺图。
    return ComicReadingPage(
      OnlineLocalReadingData(
        title: name,
        id: id,
        rootDirectoryPath: rootDirectoryPath,
        chapters: const <String, String>{},
        isEhentai: true,
        tagFlatTags: tagList,
      ),
      page ?? 1,
      ep ?? 1,
    );
  }
}

/// nhentai 在线下载画廊的本地包装：提供磁盘路径、封面、阅读页。
/// 与 OnlineDownloadedGallery 平行；nhentai 为单画廊多图、无章节，
/// 页图平铺在下载目录根（1.{ext}…pageCount.{ext}）。
class OnlineDownloadedNhentai extends NhentaiDownloadedComic {
  OnlineDownloadedNhentai({
    required this.rootPath,
    required this.directoryName,
    required super.comicID,
    required super.title,
    super.size,
    super.cover,
    super.tagList,
    super.categorizedTags,
  });

  factory OnlineDownloadedNhentai.fromNhentaiDownloadedComic(
    NhentaiDownloadedComic comic, {
    required String rootPath,
    required String directoryName,
  }) {
    return OnlineDownloadedNhentai(
      rootPath: rootPath,
      directoryName: directoryName,
      comicID: comic.comicID,
      title: comic.title,
      size: comic.size,
      cover: comic.cover,
      tagList: comic.tagList,
      categorizedTags: comic.categorizedTags,
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
    // 无章节：chapters 传空 map → hasEp=false → 读根目录平铺图。
    return ComicReadingPage(
      OnlineLocalReadingData(
        title: name,
        id: id,
        rootDirectoryPath: rootDirectoryPath,
        chapters: const <String, String>{},
        isNhentai: true,
        tagFlatTags: tagList,
        tagCategorizedTags: categorizedTags,
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
    this.isEhentai = false,
    this.isNhentai = false,
    this.tagFlatTags = const <String>[],
    this.tagCategorizedTags = const <String, List<String>>{},
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

  /// 是否为 ehentai 源（单画廊多图、无章节）。为 true 时 sourceKey/comicType/
  /// favoriteType 走 ehentai，hasEp=false 读根目录平铺图。
  final bool isEhentai;

  /// 是否为 nhentai 源（单画廊多图、无章节）。与 ehentai 同构：hasEp=false 读
  /// 根目录平铺图，sourceKey/comicType/favoriteType 走 nhentai。
  final bool isNhentai;

  final List<String> tagFlatTags;
  final Map<String, List<String>> tagCategorizedTags;

  /// 缓存每个 ep 的在线章节信息，避免重复网络请求。
  /// key = ep 序号(1-based)，value = (chapterId, urls)。
  final Map<int, ({String chapterId, List<String> urls})> _jmEpCache = {};

  @override
  String get downloadId => id;

  @override
  String get sourceKey => isJm
      ? 'jm'
      : isEhentai
          ? 'ehentai'
          : isNhentai
              ? 'nhentai'
              : 'picacg';

  @override
  Iterable<String> get untranslatedTagFlatTags => tagFlatTags;

  @override
  Map<String, List<String>> get untranslatedTagCategorizedTags =>
      tagCategorizedTags;

  @override
  ComicType get comicType => isJm
      ? ComicType.jm
      : isEhentai
          ? ComicType.ehentai
          : isNhentai
              ? ComicType.nhentai
              : ComicType.picacg;

  @override
  bool get hasEp => chapters.isNotEmpty;

  @override
  Map<String, String>? get eps => hasEp ? chapters : null;

  @override
  bool get downloaded => false;

  @override
  FavoriteType get favoriteType => isJm
      ? FavoriteType.jm
      : isEhentai
          ? FavoriteType.ehentai
          : isNhentai
              ? FavoriteType.nhentai
              : FavoriteType.picacg;

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

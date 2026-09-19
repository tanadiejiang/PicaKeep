part of 'download_page.dart';

extension DownloadPageLogicCover on DownloadPageLogic {
  bool get _showFavoriteBadge => appdata.settings[72] == '1';

  bool get _showReadingPosition => appdata.settings[73] == '1';

  Future<void> _prepareTileViewModels(List<DownloadedItem> items) async {
    // 远程档/remoteRootId 页：直接用字段访问构建 ViewModel，跳过：
    //   1. 本地历史/收藏 DB 查询（item id 是服务端派生值，对不上本地 target，且极慢）
    //   2. 通用 _downloadedItemAuthor/_downloadedItemTags 等 fallback 路径——它们
    //      在字段为空时会调 toJson()，而 RemoteLibraryComicItem.toJson() 会序列化
    //      全部章节页 URL，4075 个 item 同步跑造成主线程数秒阻塞。
    // 直接访问 .subTitle/.sourceDisplayName/.tags/.comicSize 均为 O(1) getter，
    // 不触发 DB 或序列化，预构建后滚动与本地档一样流畅。
    if (_view == _DownloadedLibraryView.remote || _isRemoteRootPage) {
      _tileViewModels
        ..clear()
        ..addEntries(items.map((item) => MapEntry(
              item.id,
              _DownloadedTileViewModel(
                author: item.subTitle.trim(),
                type: item.sourceDisplayName.trim(),
                tags: item.tags,
                size: item.comicSize != null
                    ? '${item.comicSize!.toStringAsFixed(2)}MB'
                    : '未知大小'.tl,
              ),
            )));
      return;
    }
    final showFavoriteBadge = _showFavoriteBadge;
    final showReadingPosition = _showReadingPosition;
    final readingHistoryById = showReadingPosition
        ? await _buildReadingHistoryById(items)
        : const <String, History>{};
    final favoriteById = showFavoriteBadge
        ? await _buildFavoriteById(items)
        : const <String, bool>{};

    _tileViewModels
      ..clear()
      ..addEntries(items.map(
        (item) => MapEntry(
          item.id,
          _DownloadedTileViewModel(
            author: _downloadedItemAuthor(item),
            type: _downloadedItemSource(item),
            tags: _downloadedItemDisplayTags(item),
            size: _downloadedItemSizeText(item),
            readingHistoryOverride:
                showReadingPosition ? readingHistoryById[item.id] : null,
            isFavoriteOverride:
                showFavoriteBadge ? (favoriteById[item.id] ?? false) : null,
          ),
        ),
      ));
  }

  Future<Map<String, History>> _buildReadingHistoryById(
      List<DownloadedItem> items) async {
    // 远程项（根目录或单项）的 id 是服务端派生值，与本地历史/收藏 target 无关，
    // 排除后避免聚合档里混入的远程项也触发无意义查询。
    final ids = items
        .where((item) =>
            item is! RemoteLibraryRootItem && item is! RemoteLibraryComicItem)
        .map((item) => item.id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    if (ids.isEmpty) {
      return const <String, History>{};
    }
    final manager = HistoryManager();
    await manager.init();
    return manager.findManySync(ids);
  }

  Future<Map<String, bool>> _buildFavoriteById(
      List<DownloadedItem> items) async {
    if (!items.any((item) =>
        item is! RemoteLibraryRootItem &&
        item is! RemoteLibraryComicItem &&
        item.id.trim().isNotEmpty)) {
      return const <String, bool>{};
    }
    await LocalFavoritesManager().init();
    return _queryFavoriteById(items);
  }

  Map<String, bool> _queryFavoriteById(List<DownloadedItem> items) {
    final ids = items
        .where((item) =>
            item is! RemoteLibraryRootItem && item is! RemoteLibraryComicItem)
        .map((item) => item.id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    if (ids.isEmpty) {
      return const <String, bool>{};
    }
    return LocalFavoritesManager().existsMany(ids);
  }

  void _scheduleFavoriteRefresh() {
    if (_favoriteSubscription == null ||
        !_favoriteRefreshPending ||
        _favoriteLoadsInProgress != 0 ||
        _favoriteRefreshTimer != null) {
      return;
    }
    final generation = _favoriteBindingGeneration;
    _favoriteRefreshTimer = Timer(const Duration(milliseconds: 16), () {
      _favoriteRefreshTimer = null;
      if (generation != _favoriteBindingGeneration ||
          _favoriteSubscription == null) {
        return;
      }
      if (_favoriteLoadsInProgress != 0) return;
      _favoriteRefreshPending = false;
      if (!_showFavoriteBadge ||
          _view == _DownloadedLibraryView.remote ||
          _isRemoteRootPage) {
        return;
      }
      final watch = Stopwatch()..start();
      try {
        final favorites = _queryFavoriteById(baseComics);
        var changed = false;
        for (final entry in favorites.entries) {
          final model = _tileViewModels[entry.key];
          if (model != null && model.isFavoriteOverride != entry.value) {
            _tileViewModels[entry.key] = model.withFavorite(entry.value);
            changed = true;
          }
        }
        if (changed) update();
        Log.info('DownloadPage',
            'favorites.refresh items=${favorites.length} changed=$changed elapsedUs=${watch.elapsedMicroseconds}');
      } catch (e) {
        // A store may be disposed during navigation; its next init emits again.
        Log.warning('DownloadPage', 'favorites.refresh failed: $e');
      }
      _scheduleFavoriteRefresh();
    });
  }

  _DownloadedTileViewModel _viewModelFor(DownloadedItem item) {
    return _tileViewModels[item.id] ??
        _DownloadedTileViewModel(
          author: _downloadedItemAuthor(item),
          type: _downloadedItemSource(item),
          tags: _downloadedItemDisplayTags(item),
          size: _downloadedItemSizeText(item),
        );
  }

  void _prefetchCoverThumbnails(List<DownloadedItem> items) {
    final remoteItems = items
        .where(
          (item) =>
              item is RemoteLibraryComicItem || item is RemoteLibraryRootItem,
        )
        .take(12)
        .toList(growable: false);
    if (remoteItems.isEmpty) {
      return;
    }
    unawaited(Future<void>.delayed(const Duration(milliseconds: 96), () async {
      for (final item in remoteItems) {
        if (!baseComics.any((comic) => comic.id == item.id)) {
          continue;
        }
        final provider =
            _coverImageProviders[item.id] ?? coverImageProviderFor(item);
        if (provider == null) {
          continue;
        }
        unawaited(_warmImageProvider(provider).catchError((_) {}));
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
    }));
  }

  Future<void> _warmImageProvider(ImageProvider<Object> provider) {
    final completer = Completer<void>();
    final stream = provider.resolve(const ImageConfiguration());
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (image, synchronousCall) {
        if (!completer.isCompleted) {
          completer.complete();
        }
        stream.removeListener(listener);
      },
      onError: (exception, stackTrace) {
        if (!completer.isCompleted) {
          completer.complete();
        }
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
    return completer.future;
  }

  void _scheduleCoverRefresh() {
    if (_isScrollInteracting) {
      _pendingCoverRefresh = true;
      return;
    }
    if (_coverRefreshScheduled) {
      return;
    }
    _coverRefreshScheduled = true;
    Future<void>.delayed(const Duration(milliseconds: 320), () {
      _coverRefreshScheduled = false;
      if (!loading) {
        update();
      }
    });
  }

  void setScrollInteracting(bool interacting) {
    if (interacting) {
      _scrollIdleTimer?.cancel();
      if (_isScrollInteracting) {
        return;
      }
      _isScrollInteracting = true;
      return;
    }

    _scrollIdleTimer?.cancel();
    _scrollIdleTimer = Timer(const Duration(milliseconds: 140), () {
      if (!_isScrollInteracting) {
        return;
      }
      _isScrollInteracting = false;
      // 滚动停止：重启被暂停的封面解析队列，把可见区缺图项的封面补齐
      // （活跃滚动时 _drainCoverResolveQueue 只入队、break 出循环，未清空队列）。
      if (_coverResolveQueue.isNotEmpty && !_coverResolveQueueRunning) {
        unawaited(_drainCoverResolveQueue());
      }
      if (_pendingCoverRefresh) {
        _pendingCoverRefresh = false;
        _scheduleCoverRefresh();
      }
    });
  }

  bool _useDirectMobileLocalCoverPath(DownloadedItem item) {
    return App.isMobile &&
        !_usesManagedDownloadSources &&
        item is! LocalLibraryComicItem &&
        item is! RemoteLibraryComicItem &&
        item is! RemoteLibraryRootItem;
  }

  File coverFor(DownloadedItem item) {
    if (item is RemoteLibraryComicItem) {
      return File('');
    }
    if (item is LocalLibraryComicItem) {
      final path = item.localCoverPath?.trim();
      if (path != null && path.isNotEmpty) {
        return File(path);
      }
      return File('');
    }
    final localCoverPath = item.localCoverPath?.trim();
    if (localCoverPath != null && localCoverPath.isNotEmpty) {
      return File(localCoverPath);
    }
    return DownloadManager().getCover(item.id);
  }

  ImageProvider<Object>? coverImageProviderFor(DownloadedItem item) {
    if (_useDirectMobileLocalCoverPath(item) &&
        item is! LocalLibraryComicItem) {
      return null;
    }

    final cachedProvider = _coverImageProviders[item.id];
    if (cachedProvider != null) {
      return cachedProvider;
    }

    ImageProvider<Object>? provider;
    if (item is RemoteLibraryComicItem) {
      provider = item.coverImageProvider;
    } else if (item is RemoteLibraryRootItem) {
      provider = item.coverImageProvider;
    } else if (item is LocalLibraryComicItem) {
      final coverPath = item.localCoverPath?.trim();
      if (coverPath != null &&
          coverPath.isNotEmpty &&
          coverPath != LocalLibraryManager.noCoverSentinel) {
        // 本地项封面（managed 下载项 + non-managed 图集项）一律走
        // privileged-aware 的 imageProviderForLocalPath，而非裸 FileImage(File(...))：
        // root/shizuku 模式无 MANAGE_EXTERNAL_STORAGE，裸 FileImage 读外部路径会静默
        // 失败破图，此 provider 在 dart:io 读不到时回退特权通道（_readFileBytes）补字节。
        // full-access 模式下 dart:io 直接命中，行为不变。managed 项不再排后台迁移队列：
        // 那个队列每个 item 至少两次特权通道，对已缓存封面只为得出"无事可做"，滚动时在
        // 帧间隙持续打通道，是 root 模式列表滚动卡顿的来源。缺图项走下面 else 按需排队。
        provider = LocalLibraryManager().imageProviderForLocalPath(coverPath);
      } else if (coverPath == LocalLibraryManager.noCoverSentinel) {
        // 已持久化「无封面」标记——不入队、不走 root 通道，直接渲染占位图标。
        // 用户添加封面文件后做一次刷新/重新加载即可清除标记、重新探测。
      } else {
        _queueLocalCoverResolve(item);
      }
    } else {
      final coverFile = coverFor(item);
      if (coverFile.path.isNotEmpty) {
        provider = FileImage(coverFile);
      }
    }
    if (provider != null) {
      _coverImageProviders[item.id] = provider;
    }
    return provider;
  }

  void _queueLocalCoverResolve(LocalLibraryComicItem item) {
    if (!item.localStorageExists ||
        _coverResolveFailedIds.contains(item.id) ||
        _coverImageProviders.containsKey(item.id) ||
        !_queuedCoverIds.add(item.id)) {
      return;
    }
    _coverResolveQueue.add(item);
    if (!_coverResolveQueueRunning) {
      unawaited(_drainCoverResolveQueue());
    }
  }

  Future<void> _drainCoverResolveQueue() async {
    if (_coverResolveQueueRunning) {
      return;
    }
    _coverResolveQueueRunning = true;
    try {
      while (_coverResolveQueue.isNotEmpty) {
        // 活跃滚动时暂停解析：占位图标已即时展示，封面解析会经 root 特权通道
        // 读源字节+写缓存（managed 下载项），在滚动帧间隙跑会造成 vsync 帧外
        // 阻塞（卡顿）。手指还在滑就只入队不打通道，由 setScrollInteracting
        // 的 idle 回调在滚动停止后重启本 drain 补齐——即"没内容也照常展示，
        // 滚动保持流畅，停下再补封面"。break 在 removeFirst 之前，不丢队列项。
        if (_isScrollInteracting) {
          break;
        }
        final item = _coverResolveQueue.removeFirst();
        if (!baseComics.any((comic) => comic.id == item.id)) {
          _queuedCoverIds.remove(item.id);
          continue;
        }
        final path = await LocalLibraryManager().resolveCoverPathForItem(item);
        if (path != null && path.trim().isNotEmpty) {
          // 统一走 privileged-aware provider（含 non-managed 图集项）：root/shizuku
          // 下裸 FileImage 读外部路径会破图，此 provider 会回退特权通道补字节。
          _coverImageProviders[item.id] =
              LocalLibraryManager().imageProviderForLocalPath(path);
          _scheduleCoverRefresh();
        } else {
          // 无可用封面：记下 id，避免折返到此项时反复重走 root 特权通道。
          // 占位图标已是其最终态，无封面可补（见 _coverResolveFailedIds 注释）。
          _coverResolveFailedIds.add(item.id);
        }
        _queuedCoverIds.remove(item.id);
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }
    } finally {
      _coverResolveQueueRunning = false;
    }
  }

  String pathFor(DownloadedItem item) {
    if (item is RemoteLibraryComicItem) {
      return item.remotePath.isNotEmpty ? item.remotePath : item.detailUrl;
    }
    if (item is RemoteLibraryRootItem) {
      return item.root.path;
    }
    final fsPath = item.fileSystemPath?.trim();
    if (fsPath != null && fsPath.isNotEmpty) {
      return fsPath;
    }
    return "${DownloadManager().path}/${item.directory ?? ''}";
  }
}

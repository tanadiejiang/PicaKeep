part of 'download_page.dart';

extension DownloadPageLogicLoading on DownloadPageLogic {
  Future<void> _refreshFromNotifier() async {
    if (_isRefreshingFromLocalData || _isDeletingItems) {
      return;
    }
    _isRefreshingFromLocalData = true;
    try {
      loading = true;
      update();
      await reload();
    } finally {
      _isRefreshingFromLocalData = false;
    }
  }

  Future<bool> _checkRemoteAvailability() async {
    final normalizedAddress = normalizeRemoteServerAddressValue(
      appdata.settings[remoteServerAddressSettingIndex],
    );
    if (normalizedAddress.isEmpty) {
      return false;
    }
    try {
      final snapshot = await RemoteRuntimeServiceDataSource().fetchSnapshot();
      return snapshot.connectionState == ServiceConnectionState.online;
    } catch (_) {
      return false;
    }
  }

  Future<void> reload() async {
    final forceRemoteRefresh = _forceRemoteRefreshOnNextReload;
    _forceRemoteRefreshOnNextReload = false;
    // 用户主动刷新时清除持久化的"无封面"标记，使有新增封面文件的项得以重新探测。
    await LocalLibraryManager().invalidateNoCoverSentinels();
    var order = '', direction = 'desc';
    switch (appdata.settings[26][0]) {
      case "0":
        order = 'time';
      case "1":
        order = 'title';
      case "2":
        order = 'subtitle';
      case "3":
        order = 'size';
      default:
        throw UnimplementedError();
    }
    if (appdata.settings[26][1] == "1") {
      direction = 'asc';
    }
    _loadIssue = null;
    // 远程可用性探测（fetchSnapshot）远程离线时会走到 ~3s 超时。local 视图的
    // _loadComics 完全不读 remoteAvailable，showSourceSelector 也用
    // _hasConfiguredRemoteServer 兜底，因此 local 视图无需等待该探测——
    // 否则本地几千部漫画的加载会被一个注定失败的远程探测白白阻塞 3 秒。
    // 仅 aggregate/remote 视图（真正依赖 remoteAvailable）才同步等待。
    if (_view == _DownloadedLibraryView.local) {
      remoteAvailable = false;
    } else {
      remoteAvailable = await _checkRemoteAvailability();
    }
    final loadResult = await _loadComics(
      order,
      direction,
      forceRemoteRefresh: forceRemoteRefresh,
    );
    final loadedComics = List<DownloadedItem>.from(loadResult.items);
    _loadIssue = loadedComics.isEmpty ? loadResult.issue : null;
    final visibleIds = loadedComics.map((item) => item.id).toSet();
    _coverImageProviders.removeWhere((key, _) => !visibleIds.contains(key));
    await _prepareTileViewModels(loadedComics);
    baseComics = loadedComics;
    _prefetchCoverThumbnails(loadedComics);
    keyword_ = '__stale__';
    find();
    loading = false;
    update();
  }

  Future<void> _reloadVisibleComics() async {
    try {
      await reload();
    } catch (e) {
      _loadIssue = _unexpectedLoadIssue();
      loading = false;
      update();
      print('[PicaKeep] DownloadPage reload failed: $e');
    }
  }

  Future<_DownloadedLoadResult> _loadComics(
    String order,
    String direction, {
    bool forceRemoteRefresh = false,
  }) async {
    switch (_view) {
      case _DownloadedLibraryView.local:
        return _loadLocalBranch(order, direction);
      case _DownloadedLibraryView.aggregate:
        final results = await Future.wait<_DownloadedLoadResult>([
          _loadLocalBranch(order, direction),
          if (remoteAvailable)
            _loadRemoteBranch(
              order,
              direction,
              forceRemoteRefresh: forceRemoteRefresh,
            ),
        ]);
        final merged = <DownloadedItem>[
          for (final result in results) ...result.items,
        ];
        if (merged.isNotEmpty) {
          _sortItems(merged, order, direction);
          return _DownloadedLoadResult(items: merged);
        }
        for (final result in results) {
          if (result.issue != null) {
            return _DownloadedLoadResult(issue: result.issue);
          }
        }
        if (_hasConfiguredRemoteServer && !remoteAvailable) {
          return _DownloadedLoadResult(issue: _remoteUnavailableIssue());
        }
        return const _DownloadedLoadResult();
      case _DownloadedLibraryView.remote:
        if (!remoteAvailable) {
          if (_hasConfiguredRemoteServer || _shouldStrictlyUseRemoteData) {
            return _DownloadedLoadResult(issue: _remoteUnavailableIssue());
          }
          return const _DownloadedLoadResult();
        }
        return _loadRemoteBranch(
          order,
          direction,
          forceRemoteRefresh: forceRemoteRefresh,
        );
    }
  }

  Future<_DownloadedLoadResult> _loadLocalBranch(
    String order,
    String direction,
  ) async {
    try {
      var timeout = _localLoadTimeout;
      final localLibraryManager = LocalLibraryManager();
      if ((!_usesManagedDownloadSources &&
              await localLibraryManager
                  .shouldBypassDirectDownloadManagerForCurrentDownloads()) ||
          (_usesManagedDownloadSources &&
              await localLibraryManager
                  .shouldUsePrivilegedManagedDownloadHandling())) {
        timeout = const Duration(seconds: 20);
      }
      final items = await _loadLocalComics(order, direction).timeout(
        timeout,
      );
      return _DownloadedLoadResult(items: items);
    } on TimeoutException {
      return _DownloadedLoadResult(issue: _localTimeoutIssue());
    } catch (e) {
      print('[PicaKeep] Local downloads load failed: $e');
      return _DownloadedLoadResult(issue: _localFailureIssue());
    }
  }

  Future<_DownloadedLoadResult> _loadRemoteBranch(
    String order,
    String direction, {
    bool forceRemoteRefresh = false,
  }) async {
    try {
      final items = await _loadRemoteComics(
        order,
        direction,
        forceRemoteRefresh: forceRemoteRefresh,
      ).timeout(_remoteLoadTimeout);
      return _DownloadedLoadResult(items: items);
    } on TimeoutException {
      return _DownloadedLoadResult(issue: _remoteTimeoutIssue());
    } on RemoteLibraryDataSourceException catch (e) {
      print('[PicaKeep] Remote downloads load failed: ${e.message}');
      if (e.message.contains('超时')) {
        return _DownloadedLoadResult(issue: _remoteTimeoutIssue());
      }
      return _DownloadedLoadResult(issue: _remoteFailureIssue(e.message));
    } catch (e) {
      print('[PicaKeep] Remote downloads load failed: $e');
      return _DownloadedLoadResult(issue: _remoteFailureIssue());
    }
  }

  // ignore: unused_element
  Future<List<DownloadedItem>> _loadComicsLegacy(
    String order,
    String direction, {
    bool forceRemoteRefresh = false,
  }) async {
    final localItems = await _loadLocalComics(order, direction);
    if (!remoteAvailable) {
      if (_shouldStrictlyUseRemoteData) {
        throw const RemoteLibraryDataSourceException('远程服务当前不可用');
      }
      if (_view == _DownloadedLibraryView.remote &&
          _hasConfiguredRemoteServer) {
        return const <DownloadedItem>[];
      }
      return localItems;
    }

    switch (_view) {
      case _DownloadedLibraryView.local:
        return localItems;
      case _DownloadedLibraryView.aggregate:
        try {
          final remoteItems = await _loadRemoteComics(
            order,
            direction,
            forceRemoteRefresh: forceRemoteRefresh,
          );
          final merged = <DownloadedItem>[...localItems, ...remoteItems];
          _sortItems(merged, order, direction);
          return merged;
        } catch (_) {
          return localItems;
        }
      case _DownloadedLibraryView.remote:
        return _loadRemoteComics(
          order,
          direction,
          forceRemoteRefresh: forceRemoteRefresh,
        );
    }
  }

  Future<List<DownloadedItem>> _loadLocalComics(
      String order, String direction) async {
    if (!_usesManagedDownloadSources) {
      final localLibraryManager = LocalLibraryManager();
      if (await localLibraryManager
          .shouldBypassDirectDownloadManagerForCurrentDownloads()) {
        final items =
            await localLibraryManager.getCurrentDownloadsWithShizukuFallback();
        final downloads = items.cast<DownloadedItem>().toList();
        _sortItems(downloads, order, direction);
        return downloads;
      }
      await DownloadManager().init();
      return DownloadManager().getAll(order, direction);
    }
    final items = await LocalLibraryManager().getManagedDownloads();
    final downloads = items.cast<DownloadedItem>().toList();
    _sortItems(downloads, order, direction);
    return downloads;
  }

  Future<List<DownloadedItem>> _loadRemoteComics(
    String order,
    String direction, {
    bool forceRemoteRefresh = false,
  }) async {
    RemoteLibraryEventChannel.instance.onRemotePageActivated();
    final rootId = remoteRootId?.trim() ?? '';
    final downloads = rootId.isNotEmpty
        ? await _remoteDataSource.fetchItemsForRoot(
            rootId,
            forceRefresh: forceRemoteRefresh,
          )
        : (await _remoteDataSource.fetchItems(
            forceRefresh: forceRemoteRefresh,
          ))
            .where((item) => item.isManagedDownloadRoot)
            .toList(growable: false);
    final items = downloads.cast<DownloadedItem>().toList();
    _sortItems(items, order, direction);
    return items;
  }

  void _sortItems(List<DownloadedItem> items, String order, String direction) {
    int compare(DownloadedItem a, DownloadedItem b) {
      switch (order) {
        case 'title':
          return a.name.compareTo(b.name);
        case 'subtitle':
          return a.subTitle.compareTo(b.subTitle);
        case 'size':
          return (a.comicSize ?? 0).compareTo(b.comicSize ?? 0);
        case 'time':
        default:
          return (a.time ?? DateTime.fromMillisecondsSinceEpoch(0))
              .compareTo(b.time ?? DateTime.fromMillisecondsSinceEpoch(0));
      }
    }

    items.sort(compare);
    if (direction == 'desc') {
      items.setAll(0, items.reversed.toList());
    }
  }

  _DownloadedLoadIssue _localTimeoutIssue() {
    return const _DownloadedLoadIssue(
      title: '本地已下载加载超时',
      detail: '本地已下载在 8 秒内没有完成读取，请检查下载目录、Root 或 Shizuku 访问状态后重新加载。',
      timedOut: true,
    );
  }

  _DownloadedLoadIssue _localFailureIssue() {
    return const _DownloadedLoadIssue(
      title: '本地已下载加载失败',
      detail: '读取本地已下载时出现错误，请检查下载目录和权限状态后重新加载。',
    );
  }

  _DownloadedLoadIssue _remoteTimeoutIssue() {
    return const _DownloadedLoadIssue(
      title: '远程已下载加载超时',
      detail: '远程已下载在 10 秒内没有完成读取，请确认服务在线、网络可达后重新加载。',
      timedOut: true,
    );
  }

  _DownloadedLoadIssue _remoteFailureIssue([String? message]) {
    final normalized = message?.trim() ?? '';
    return _DownloadedLoadIssue(
      title: '远程已下载加载失败',
      detail: normalized.isNotEmpty ? normalized : '读取远程已下载时出现错误，请检查服务状态后重新加载。',
    );
  }

  _DownloadedLoadIssue _remoteUnavailableIssue() {
    final address = remoteServerAddressText.trim();
    return _DownloadedLoadIssue(
      title: '远程服务当前未连接',
      detail: address.isEmpty
          ? '已配置远程服务，但当前无法连接，请检查服务状态或地址配置。'
          : '当前无法连接到 $address，请检查服务是否在线。',
    );
  }

  _DownloadedLoadIssue _unexpectedLoadIssue() {
    return const _DownloadedLoadIssue(
      title: '加载失败',
      detail: '已下载列表加载过程中出现异常，请重新加载后再试。',
    );
  }
}

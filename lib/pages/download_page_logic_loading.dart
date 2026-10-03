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
    _favoriteLoadsInProgress++;
    try {
      await _reloadContent();
    } finally {
      _favoriteLoadsInProgress--;
      _scheduleFavoriteRefresh();
    }
  }

  Future<void> _reloadContent() async {
    // ignore: avoid_print
    print(
      '[PicaKeep][DownloadPage] reload.start view=$_view remoteRootId=$remoteRootId',
    );
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
    final reloadSw = Stopwatch()..start();
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
    final availMs = reloadSw.elapsedMilliseconds;
    final loadResult = await _loadComics(
      order,
      direction,
      forceRemoteRefresh: forceRemoteRefresh,
    );
    final loadMs = reloadSw.elapsedMilliseconds - availMs;
    // 36 号：已下载页不再显示 Pixiv 的下载内容（用户要求）。
    //
    // 过滤放在**三个档位的公共出口**，而不是各分支内部 —— 这样"本地 / 聚合 /
    // 远程"口径一致，用户切档时不会突然冒出一批 Pixiv 记录。
    // 判据见 [isPixivDownloadedItem]。
    final loadedComics = <DownloadedItem>[
      for (final item in loadResult.items)
        if (!isPixivDownloadedItem(item)) item,
    ];
    _loadIssue = loadedComics.isEmpty ? loadResult.issue : null;
    final visibleIds = loadedComics.map((item) => item.id).toSet();
    _coverImageProviders.removeWhere((key, _) => !visibleIds.contains(key));
    await _prepareTileViewModels(loadedComics);
    final tileMs = reloadSw.elapsedMilliseconds - availMs - loadMs;
    Log.info(
      'DownloadPage',
      'reload view=$_view avail=${availMs}ms load=${loadMs}ms tileModels=${tileMs}ms items=${loadedComics.length}',
    );
    // ignore: avoid_print
    print(
      '[PicaKeep][DownloadPage] reload view=$_view avail=${availMs}ms load=${loadMs}ms tileModels=${tileMs}ms items=${loadedComics.length}',
    );
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
      // 43 号：本地分支现在**恒走新本地库**（见 `_loadLocalComics`），
      // 而新库要**真实列目录**（必要时走特权通道），比老库"只读 db"慢得多。
      // 所以不再按模式挑超时，统一给宽限 —— 从前那个条件判断的前提
      //（"只有特权模式才慢"）随着代码路径解耦已经不存在了。
      const timeout = Duration(seconds: 20);
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
    // 43 号：本地分支**统一走新本地库**，不再按"源设置"分岔。
    //
    // ## 为什么必须解耦
    //
    // 此前这里是三分支，且**由 `_usesManagedDownloadSources`（= 用户在设置页选的
    // 源集合）决定走哪套代码**。这两件事没有因果关系：用户选"仅本应用"只是说
    // "别扫原应用目录"，它不该顺带把整个页面切到老链路上去。
    //
    // 而老链路（`DownloadManager.getAll()` + `loadCompletedDownloads()`）
    // **只读 db、不校验目录** —— 于是"记录还在、内容已搬走"的条目会被列出来，
    // 点开却读不到。真机症状：**「未知错误」，不报错、不写日志**
    // （`OnlineLocalReadingData.loadEpNetwork` 里 `if (!dir.exists()) return []`
    // 是静默的）。
    //
    // ## 为什么不保留"新库为空就回退老库"
    //
    // 老库只读 db，**目录读不到时它照样能列出记录** —— 看似是兜底，
    // 但那正是上面那个症状的来源：列表有、点不开。**这不是兜底，是把 bug 请回来。**
    // 而新库自己**已经有完整的降级链**（`PrivilegedStorageAccess`：
    // Dart IO → Shizuku/root），它读不到就是真的读不到。
    //
    // 用户想诊断"缺了哪一个"时，打开「显示全部数据库记录」即可 ——
    // 新库在 `_resolveDownloadItemDirectoryFromMetadata` 里已按这个语义实现
    // （没有真实目录时保留原路径，由该开关决定是否展示占位）。
    //
    // 源集合仍由 `managedDataSourceMode` 决定，但那件事现在**只在新库内部生效**
    // （`_buildSources` 的 switch：仅本应用 / 本+原应用 / 仅原应用）。
    //
    // ## 43 号续：在这里补回两道过滤（37 号的语义 + 跨源去重）
    //
    // **① Pixiv 不进「已下载」页。** 37 号做过这件事，但那个过滤写在**老链路**里；
    // 本页改走新库后它就丢了 —— 而新库的 `_buildSources` 在"仅本应用"档下
    // **照样会挂上 Pixiv 源**（`addPixivSourceIfConfigured`），于是 Pixiv 全冒出来。
    // Pixiv 有自己的页面（图集页的「插画」）与自己的下载根，**不该混在漫画列表里**。
    //
    // **② 跨源按 id 去重，实体存在者优先。** 新库是"一个源一份结果"，
    // 同一个 id 可能同时出现在当前下载目录与 Pixiv 目录里（用户改过下载目录、
    // 或旧内容还没归位时）—— 不去重就会看到"两本一模一样的漫画"，
    // 而且其中一份的实体可能已经不在。
    final items = await LocalLibraryManager().getManagedDownloads();
    final byId = <String, DownloadedItem>{};
    for (final item in items) {
      if (isPixivLocalLibraryItem(item)) {
        continue;
      }
      final existing = byId[item.id];
      if (existing == null) {
        byId[item.id] = item;
        continue;
      }
      if (!OnlineDownloadManager.downloadedItemEntityExists(existing) &&
          OnlineDownloadManager.downloadedItemEntityExists(item)) {
        byId[item.id] = item;
      }
    }
    final downloads = byId.values.toList();
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
        : await _remoteDataSource.fetchManagedDownloadItems(
            forceRefresh: forceRemoteRefresh,
          );
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
          return resolveDownloadedAuthors(a)
              .join(', ')
              .compareTo(resolveDownloadedAuthors(b).join(', '));
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

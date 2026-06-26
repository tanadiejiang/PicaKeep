part of 'download_page.dart';

extension DownloadPageLogicView on DownloadPageLogic {
  void bindLocalDataRefresh() {
    _localDataListener ??= _refreshFromNotifier;
    _serviceStateListener ??= _refreshFromNotifier;
    App.localDataVersion.addListener(_localDataListener!);
    App.serviceConfigVersion.addListener(_serviceStateListener!);
    App.serviceRuntimeVersion.addListener(_serviceStateListener!);
  }

  void unbindLocalDataRefresh() {
    final localListener = _localDataListener;
    if (localListener != null) {
      App.localDataVersion.removeListener(localListener);
      _localDataListener = null;
    }

    final serviceListener = _serviceStateListener;
    if (serviceListener != null) {
      App.serviceConfigVersion.removeListener(serviceListener);
      App.serviceRuntimeVersion.removeListener(serviceListener);
      _serviceStateListener = null;
    }
  }

  bool get _usesManagedDownloadSources =>
      normalizeManagedDataSourceMode(
          appdata.settings[managedDataSourceModeSettingIndex]) !=
      managedDataSourceModeCurrentOnly;

  bool get _hasConfiguredRemoteServer => normalizeRemoteServerAddressValue(
        appdata.settings[remoteServerAddressSettingIndex],
      ).isNotEmpty;

  bool get _isRemoteRootPage => remoteRootId?.trim().isNotEmpty == true;

  bool get _shouldStrictlyUseRemoteData => _isRemoteRootPage;

  bool get showSourceSelector =>
      !_isRemoteRootPage && (remoteAvailable || _hasConfiguredRemoteServer);

  bool get shouldAutoRefreshOnResume => _view != _DownloadedLibraryView.local;

  void forceRemoteRefresh() {
    _forceRemoteRefreshOnNextReload = true;
    if (_isDeletingItems) {
      return;
    }
    refresh();
  }

  bool get showManualRemoteRefreshButton =>
      !selecting &&
      !searchMode &&
      (_view == _DownloadedLibraryView.remote ||
          _view == _DownloadedLibraryView.aggregate);

  void triggerManualRemoteRefresh() {
    final now = DateTime.now();
    final lastTriggeredAt = _lastManualRemoteRefreshAt;
    if (lastTriggeredAt != null &&
        now.difference(lastTriggeredAt) < const Duration(milliseconds: 1500)) {
      return;
    }
    _lastManualRemoteRefreshAt = now;
    _forceRemoteRefreshOnNextReload = true;
    refresh();
  }

  Future<void> _setView(_DownloadedLibraryView nextView) async {
    if (_view == nextView) {
      return;
    }
    _view = nextView;
    appdata.settings[downloadedLibraryViewSettingIndex] =
        _downloadedLibraryViewToSetting(nextView);
    await appdata.updateSettings();
    refresh();
  }

  void change() {
    loading = !loading;
    try {
      update();
    } catch (e) {
      // ignore
    }
  }

  void find() {
    final normalizedKeyword = keyword.trim().toLowerCase();
    if (normalizedKeyword == keyword_) {
      return;
    }
    keyword = normalizedKeyword;
    keyword_ = normalizedKeyword;
    if (normalizedKeyword.isEmpty) {
      comics = List<DownloadedItem>.from(baseComics);
    } else {
      comics = baseComics
          .where((element) =>
              _matchesDownloadedKeyword(element, normalizedKeyword))
          .toList(growable: false);
    }
    resetSelected(comics.length);
  }

  bool get showRemoteDisconnectedHint =>
      _view == _DownloadedLibraryView.remote &&
      _hasConfiguredRemoteServer &&
      !remoteAvailable;

  bool get hasLoadIssue => _loadIssue != null;

  String? get loadIssueTitle => _loadIssue?.title;

  String? get loadIssueDetail => _loadIssue?.detail;

  bool get loadIssueTimedOut => _loadIssue?.timedOut ?? false;

  String get remoteServerAddressText => normalizeRemoteServerAddressValue(
        appdata.settings[remoteServerAddressSettingIndex],
      );

  String emptyStatePathText() {
    if (_view == _DownloadedLibraryView.remote) {
      return '远程服务'.tl;
    }
    final mode = normalizeManagedDataSourceMode(
      appdata.settings[managedDataSourceModeSettingIndex],
    );
    final currentPath = (DownloadManager().path ?? appdata.settings[22]).trim();
    final originalPath =
        appdata.settings[originalDownloadDirSettingIndex].trim();
    final localText = switch (mode) {
      managedDataSourceModeCurrentAndOriginal => [
          if (currentPath.isNotEmpty) currentPath,
          if (originalPath.isNotEmpty && originalPath != currentPath)
            originalPath,
        ].join(' / '),
      managedDataSourceModeOriginalOnly => originalPath,
      _ => currentPath,
    };
    if (_view == _DownloadedLibraryView.aggregate && remoteAvailable) {
      return [
        if (localText.isNotEmpty) localText,
        '远程服务'.tl,
      ].join(' / ');
    }
    return localText;
  }
}

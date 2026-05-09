import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:io' show File, Platform, Process;

import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/app_runtime_mode.dart';
import 'package:picakeep/foundation/download.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/history.dart';
import 'package:picakeep/foundation/local_data_source.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/local_library_settings.dart';
import 'package:picakeep/foundation/remote_library_data_source.dart';
import 'package:picakeep/foundation/service_data_source.dart';
import 'package:picakeep/foundation/trash.dart';
import 'package:picakeep/foundation/ui_mode.dart';
import 'package:picakeep/tools/translations.dart';
import 'package:picakeep/components/comic_tile.dart';
import 'package:picakeep/components/scrollable.dart';
import 'package:picakeep/components/layout.dart';
import 'package:picakeep/components/components.dart';
import 'package:picakeep/components/window_frame.dart';
import 'package:picakeep/tools/read_history_helper.dart';
import 'package:picakeep/tools/tags_translation.dart';
import 'local_comic_detail_page.dart';

void _toComicInfoPage(BuildContext context, DownloadedItem comic) {
  if (comic is RemoteLibraryRootItem) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DownloadPage(
          remoteRootId: comic.root.id,
          title: comic.name,
        ),
      ),
    );
    return;
  }
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => LocalComicDetailPage(comic: comic),
  ));
}

extension ReadComic on DownloadedItem {
  Future<void> read({int? ep, int? page}) async {
    await ensureHistoryBeforeRead(this);
    await App.openReader(() => createReadingPage(ep: ep, page: page));
  }
}

String _translateDownloadedTag(String tag) {
  try {
    for (final map in tagTranslations.values) {
      for (final entry in map.entries) {
        if (entry.key.toLowerCase() == tag.toLowerCase()) {
          return entry.value.isNotEmpty ? entry.value.first : tag;
        }
      }
    }
  } catch (_) {}
  return tag;
}

Iterable<String> _searchTermsForDownloadedTag(String tag) sync* {
  final raw = tag.trim();
  if (raw.isEmpty) {
    return;
  }

  yield raw.toLowerCase();

  String normalizeTagLabel(String value) {
    return value.replaceFirst(' ♀', '').replaceFirst(' ♂', '').trim();
  }

  if (raw.contains(':')) {
    final value = raw.split(':').last.trim();
    if (value.isNotEmpty) {
      yield value.toLowerCase();
      yield _translateDownloadedTag(value).trim().toLowerCase();
    }
    return;
  }

  final normalized = normalizeTagLabel(raw);
  if (normalized.isNotEmpty) {
    yield normalized.toLowerCase();
    yield _translateDownloadedTag(normalized).trim().toLowerCase();
  }
}

Iterable<String> _searchTermsForDownloadedItem(DownloadedItem item) sync* {
  yield item.name.toLowerCase();
  yield item.subTitle.toLowerCase();
  yield item.sourceDisplayName.toLowerCase();

  for (final tag in item.tags) {
    yield* _searchTermsForDownloadedTag(tag)
        .where((value) => value.isNotEmpty)
        .map((value) => value.toLowerCase());
  }

  try {
    final json = item.toJson();
    for (final key in const [
      'comicId',
      'id',
      'itemId',
      'link',
      'favoriteTarget',
      'directory',
    ]) {
      final value = json[key]?.toString().trim();
      if (value != null && value.isNotEmpty) {
        yield value.toLowerCase();
      }
    }
  } catch (_) {}

  if (item is LocalLibraryComicItem) {
    yield item.itemId.toLowerCase();
    yield item.originalId.toLowerCase();
    final favoriteTarget = item.favoriteTarget?.trim();
    if (favoriteTarget != null && favoriteTarget.isNotEmpty) {
      yield favoriteTarget.toLowerCase();
    }
    for (final alias in item.aliases) {
      final value = alias.trim();
      if (value.isNotEmpty) {
        yield value.toLowerCase();
      }
    }
  }
}

bool _matchesDownloadedKeyword(DownloadedItem item, String keyword) {
  final words = keyword
      .trim()
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((e) => e.isNotEmpty)
      .toList();
  if (words.isEmpty) {
    return true;
  }
  final terms = _searchTermsForDownloadedItem(item).toList();
  return words.every((word) => terms.any((term) => term.contains(word)));
}

String _downloadedItemAuthor(DownloadedItem item) {
  final direct = item.subTitle.trim();
  if (direct.isNotEmpty) {
    return direct;
  }
  try {
    final json = item.toJson();
    for (final key in const ['subtitle', 'subTitle', 'author']) {
      final value = json[key]?.toString().trim();
      if (value != null && value.isNotEmpty) {
        return value;
      }
    }
    final comicItem = json['comicItem'];
    if (comicItem is Map) {
      for (final key in const ['subtitle', 'subTitle', 'author']) {
        final value = comicItem[key]?.toString().trim();
        if (value != null && value.isNotEmpty) {
          return value;
        }
      }
    }
  } catch (_) {}
  return '';
}

List<String> _downloadedItemTags(DownloadedItem item) {
  if (item.tags.isNotEmpty) {
    return item.tags;
  }
  try {
    final json = item.toJson();
    for (final key in const ['tags', 'tagList', 'metadataTags']) {
      final raw = json[key];
      if (raw is List) {
        final values = raw
            .map((entry) => entry.toString().trim())
            .where((entry) => entry.isNotEmpty)
            .toList(growable: false);
        if (values.isNotEmpty) {
          return values;
        }
      }
    }
    final comicItem = json['comicItem'];
    if (comicItem is Map) {
      for (final key in const ['tags', 'tagList']) {
        final raw = comicItem[key];
        if (raw is List) {
          final values = raw
              .map((entry) => entry.toString().trim())
              .where((entry) => entry.isNotEmpty)
              .toList(growable: false);
          if (values.isNotEmpty) {
            return values;
          }
        }
      }
    }
  } catch (_) {}
  return const <String>[];
}

List<String> _downloadedItemDisplayTags(DownloadedItem item) {
  final values = _downloadedItemTags(item)
      .map((tag) => _translateDownloadedTag(tag).trim())
      .where((tag) => tag.isNotEmpty)
      .toList(growable: false);
  return values;
}

String _downloadedItemSource(DownloadedItem item) {
  final direct = item.sourceDisplayName.trim();
  if (direct.isNotEmpty) {
    return direct;
  }
  try {
    final json = item.toJson();
    for (final key in const ['sourceDisplayName', 'metadataSourceDisplayName', 'sourceTitle']) {
      final value = json[key]?.toString().trim();
      if (value != null && value.isNotEmpty) {
        return value;
      }
    }
  } catch (_) {}
  return downloadTypeDisplayName(item.type);
}

String _downloadedItemSizeText(DownloadedItem item) {
  final size = item.comicSize;
  return size != null ? '${size.toStringAsFixed(2)}MB' : '未知大小'.tl;
}

class _DownloadedTileViewModel {
  const _DownloadedTileViewModel({
    required this.author,
    required this.type,
    required this.tags,
    required this.size,
    this.readingHistoryOverride,
    this.isFavoriteOverride,
  });

  final String author;
  final String type;
  final List<String> tags;
  final String size;
  final History? readingHistoryOverride;
  final bool? isFavoriteOverride;
}

enum _DownloadedLibraryView {
  local,
  aggregate,
  remote,
}

String _downloadedLibraryViewLabel(_DownloadedLibraryView view) {
  switch (view) {
    case _DownloadedLibraryView.local:
      return '本地已下载';
    case _DownloadedLibraryView.aggregate:
      return '聚合';
    case _DownloadedLibraryView.remote:
      return '远程 · 已下载';
  }
}

_DownloadedLibraryView _downloadedLibraryViewFromSetting(String value) {
  switch (normalizeDownloadedLibraryView(value)) {
    case 'aggregate':
      return _DownloadedLibraryView.aggregate;
    case 'remote':
      return _DownloadedLibraryView.remote;
    case 'local':
    default:
      return _DownloadedLibraryView.local;
  }
}

String _downloadedLibraryViewToSetting(_DownloadedLibraryView view) {
  switch (view) {
    case _DownloadedLibraryView.aggregate:
      return 'aggregate';
    case _DownloadedLibraryView.remote:
      return 'remote';
    case _DownloadedLibraryView.local:
      return 'local';
  }
}

class _DownloadedPageComicTile extends DownloadedComicTile {
  const _DownloadedPageComicTile({
    required this.comicId,
    required super.name,
    required super.author,
    required super.imagePath,
    super.imageProvider,
    super.readingHistoryOverride,
    super.isFavoriteOverride,
    required super.type,
    required super.tag,
    required super.size,
    required super.onTap,
    required super.onLongTap,
    required super.onSecondaryTap,
  });

  final String comicId;

  @override
  String? get comicID => comicId;
}

class DownloadPageLogic extends StateController {
  DownloadPageLogic({
    this.remoteRootId,
    this.pageTitle,
  }) {
    if (remoteRootId?.trim().isNotEmpty == true) {
      _view = _DownloadedLibraryView.remote;
    } else {
      _view = _downloadedLibraryViewFromSetting(
        appdata.settings[downloadedLibraryViewSettingIndex],
      );
    }
  }

  final String? remoteRootId;
  final String? pageTitle;
  final RemoteLibraryDataSource _remoteDataSource =
      const RemoteLibraryDataSource();
  final Map<String, ImageProvider<Object>> _coverImageProviders = {};
  final Map<String, _DownloadedTileViewModel> _tileViewModels = {};
  final Set<String> _queuedCoverIds = <String>{};
  final Queue<LocalLibraryComicItem> _coverResolveQueue = Queue<LocalLibraryComicItem>();
  bool _coverResolveQueueRunning = false;
  bool _coverRefreshScheduled = false;
  bool _isScrollInteracting = false;
  bool _pendingCoverRefresh = false;
  Timer? _scrollIdleTimer;

  bool loading = true;
  bool selecting = false;
  int selectedNum = 0;
  var selected = <bool>[];
  var comics = <DownloadedItem>[];
  var baseComics = <DownloadedItem>[];
  bool searchMode = false;
  bool searchInit = false;
  String keyword = "";
  String keyword_ = "";
  VoidCallback? _localDataListener;
  VoidCallback? _serviceStateListener;
  bool _isRefreshingFromLocalData = false;
  _DownloadedLibraryView _view = _DownloadedLibraryView.local;
  bool remoteAvailable = false;
  bool _forceRemoteRefreshOnNextReload = false;

  Future<void> _refreshFromNotifier() async {
    if (_isRefreshingFromLocalData) {
      return;
    }
    _isRefreshingFromLocalData = true;
    try {
      loading = true;
      update();
      await DownloadManager().init();
      await reload();
    } finally {
      _isRefreshingFromLocalData = false;
    }
  }

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

  bool get _isClientMode =>
      normalizeAppRuntimeMode(appdata.settings[appRuntimeModeSettingIndex]) ==
      appRuntimeModeClient;

  bool get _isRemoteRootPage => remoteRootId?.trim().isNotEmpty == true;

  bool get _shouldStrictlyUseRemoteData => _isRemoteRootPage;

  bool get showSourceSelector => remoteAvailable && !_isRemoteRootPage;

  bool get shouldAutoRefreshOnResume =>
      _view != _DownloadedLibraryView.local;

  void forceRemoteRefresh() {
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

  Future<bool> _checkRemoteAvailability() async {
    if (!_isClientMode) {
      return false;
    }
    try {
      final snapshot =
          await RuntimeServiceDataSourceResolver.current().fetchSnapshot();
      return snapshot.connectionState == ServiceConnectionState.online;
    } catch (_) {
      return false;
    }
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
          .where((element) => _matchesDownloadedKeyword(element, normalizedKeyword))
          .toList(growable: false);
    }
    resetSelected(comics.length);
  }

  @override
  void refresh() {
    searchMode = false;
    selecting = false;
    selectedNum = 0;
    selected = <bool>[];
    comics = <DownloadedItem>[];
    baseComics = <DownloadedItem>[];
    _tileViewModels.clear();
    _queuedCoverIds.clear();
    _coverResolveQueue.clear();
    _coverResolveQueueRunning = false;
    _coverRefreshScheduled = false;
    loading = true;
    update();
    unawaited(_reloadVisibleComics());
  }

  Future<void> _reloadVisibleComics() async {
    try {
      await DownloadManager().init();
      await reload();
    } catch (e) {
      loading = false;
      update();
      print('[PicaKeep] DownloadPage reload failed: $e');
    }
  }

  Future<void> reload() async {
    final forceRemoteRefresh = _forceRemoteRefreshOnNextReload;
    _forceRemoteRefreshOnNextReload = false;
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
    remoteAvailable = await _checkRemoteAvailability();
    if (!remoteAvailable &&
        _view != _DownloadedLibraryView.local &&
        !_shouldStrictlyUseRemoteData) {
      _view = _DownloadedLibraryView.local;
      appdata.settings[downloadedLibraryViewSettingIndex] = 'local';
      await appdata.updateSettings();
    }
    final loadedComics =
        List<DownloadedItem>.from(await _loadComics(
      order,
      direction,
      forceRemoteRefresh: forceRemoteRefresh,
    ));
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

  bool get _showFavoriteBadge => appdata.settings[72] == '1';

  bool get _showReadingPosition => appdata.settings[73] == '1';

  Future<void> _prepareTileViewModels(List<DownloadedItem> items) async {
    final showFavoriteBadge = _showFavoriteBadge;
    final showReadingPosition = _showReadingPosition;
    final readingHistoryById =
        showReadingPosition ? await _buildReadingHistoryById(items) : const <String, History>{};
    final favoriteById =
        showFavoriteBadge ? await _buildFavoriteById(items) : const <String, bool>{};

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
    final ids = items
        .where((item) => item is! RemoteLibraryRootItem)
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
    final ids = items
        .where((item) => item is! RemoteLibraryRootItem)
        .map((item) => item.id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    if (ids.isEmpty) {
      return const <String, bool>{};
    }
    final manager = LocalFavoritesManager();
    await manager.init();
    return manager.existsMany(ids);
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

  void _prefetchCoverThumbnails(List<DownloadedItem> items) {}

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
      if (_pendingCoverRefresh) {
        _pendingCoverRefresh = false;
        _scheduleCoverRefresh();
      }
    });
  }

  Future<List<DownloadedItem>> _loadComics(
    String order,
    String direction, {
    bool forceRemoteRefresh = false,
  }) async {
    final localItems = await _loadLocalComics(order, direction);
    if (!remoteAvailable) {
      if (_shouldStrictlyUseRemoteData) {
        throw const RemoteLibraryDataSourceException('远程服务当前不可用');
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

  bool canDeleteItem(DownloadedItem item) {
    if (item is RemoteLibraryRootItem) {
      return false;
    }
    if (item is RemoteLibraryComicItem) {
      return true;
    }
    if (item is LocalLibraryComicItem) {
      return (item.fileSystemPath?.trim().isNotEmpty ?? false);
    }
    return item.canDelete && !_usesManagedDownloadSources;
  }

  Future<String?> deleteItems(Iterable<DownloadedItem> items) async {
    try {
      for (final item in items) {
        if (!canDeleteItem(item)) {
          continue;
        }
        final result = await TrashManager.instance.deleteItem(item);
        if (!result.ok) {
          return result.error ?? 'delete_failed';
        }
      }
      await reload();
      update();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<int> rescanDisk() async {
    if (_view == _DownloadedLibraryView.remote) {
      await reload();
      return 0;
    }
    if (!_usesManagedDownloadSources) {
      await DownloadManager().init();
      final count = DownloadManager().scanDirectoryForComics();
      await reload();
      return count;
    }
    final count = await LocalLibraryManager().rescan();
    await reload();
    return count;
  }

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
    return DownloadManager().getCover(item.id);
  }

  ImageProvider<Object>? coverImageProviderFor(DownloadedItem item) {
    if (_useDirectMobileLocalCoverPath(item) && item is! LocalLibraryComicItem) {
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
      if (coverPath != null && coverPath.isNotEmpty) {
        if (item.isManagedDownloadItem) {
          provider = LocalLibraryManager().imageProviderForLocalPath(coverPath);
          _queueLocalCoverResolve(item);
        } else {
          provider = FileImage(File(coverPath));
        }
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
        final item = _coverResolveQueue.removeFirst();
        if (!baseComics.any((comic) => comic.id == item.id)) {
          _queuedCoverIds.remove(item.id);
          continue;
        }
        final path = await LocalLibraryManager().resolveCoverPathForItem(item);
        if (path != null && path.trim().isNotEmpty) {
          _coverImageProviders[item.id] = item.isManagedDownloadItem
              ? LocalLibraryManager().imageProviderForLocalPath(path)
              : FileImage(File(path));
          _scheduleCoverRefresh();
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

  void resetSelected(int length) {
    selected = List.generate(length, (index) => false);
    selectedNum = 0;
  }
}

class DownloadPage extends StatefulWidget {
  const DownloadPage({
    super.key,
    this.remoteRootId,
    this.title,
  });

  final String? remoteRootId;
  final String? title;

  @override
  State<DownloadPage> createState() => _DownloadPageState();
}

class _DownloadPageState extends State<DownloadPage>
    with WidgetsBindingObserver {
  DownloadPageLogic? _logic;
  bool _wasCurrentRoute = false;
  bool _hasActivatedOnce = false;

  void _refreshRemoteIfNeeded() {
    final logic = _logic;
    if (logic == null || !logic.shouldAutoRefreshOnResume) {
      return;
    }
    logic.forceRemoteRefresh();
  }

  void _syncCurrentRouteState() {
    final route = ModalRoute.of(context);
    final isCurrent = route?.isCurrent ?? false;
    if (!isCurrent) {
      _wasCurrentRoute = false;
      return;
    }
    if (_wasCurrentRoute) {
      return;
    }
    _wasCurrentRoute = true;
    if (_hasActivatedOnce) {
      return;
    }
    _hasActivatedOnce = true;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshRemoteIfNeeded();
    }
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _syncCurrentRouteState();
      }
    });
    return StateBuilder<DownloadPageLogic>(
      init: DownloadPageLogic(
        remoteRootId: widget.remoteRootId,
        pageTitle: widget.title,
      ),
      initState: (logic) {
        _logic = logic;
        logic.bindLocalDataRefresh();
        logic.refresh();
      },
      dispose: (logic) {
        if (identical(_logic, logic)) {
          _logic = null;
        }
        logic.unbindLocalDataRefresh();
      },
      builder: (logic) {
        _logic = logic;
        if (logic.loading) {
          return const Scaffold(
            body: Center(
              child: CircularProgressIndicator(),
            ),
          );
        }
        return Scaffold(
          floatingActionButton: _buildFAB(context, logic),
          body: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification is ScrollStartNotification ||
                  (notification is UserScrollNotification &&
                      notification.direction != ScrollDirection.idle)) {
                logic.setScrollInteracting(true);
              } else if (notification is ScrollEndNotification ||
                  (notification is UserScrollNotification &&
                      notification.direction == ScrollDirection.idle)) {
                logic.setScrollInteracting(false);
              }
              return false;
            },
            child: SmoothCustomScrollView(
              cacheExtent: App.isMobile
                  ? MediaQuery.of(context).size.height * 0.25
                  : MediaQuery.of(context).size.height,
              slivers: [
                _buildAppbar(context, logic),
                if (logic.showSourceSelector)
                  _buildSourceSelector(context, logic),
                _buildComics(context, logic)
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildComics(BuildContext context, DownloadPageLogic logic) {
    final comics = logic.comics;
    if (comics.isEmpty) {
      return SliverToBoxAdapter(
        child: _buildEmptyState(context, logic),
      );
    }
    return SliverGrid(
      delegate: SliverChildBuilderDelegate(
        childCount: comics.length,
        addAutomaticKeepAlives: false,
        addRepaintBoundaries: true,
        addSemanticIndexes: false,
        (context, index) {
          return _buildItem(context, logic, index);
        },
      ),
      gridDelegate: SliverGridDelegateWithComics(
        false,
        null,
        appdata.settings[44],
      ),
    );
  }

  Widget _buildItem(BuildContext context, DownloadPageLogic logic, int index) {
    final item = logic.comics[index];
    final viewModel = logic._viewModelFor(item);
    final selected = logic.selected[index];
    final isRootItem = item is RemoteLibraryRootItem;
    final coverProvider = logic.coverImageProviderFor(item);
    final coverFile = coverProvider == null ? logic.coverFor(item) : File('');
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(2),
      child: ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(16)),
        child: Stack(
          children: [
            Positioned.fill(
              child: _DownloadedPageComicTile(
                comicId: item.id,
                name: item.name,
                author: viewModel.author,
                imagePath: coverFile,
                imageProvider: coverProvider,
                readingHistoryOverride: viewModel.readingHistoryOverride,
                isFavoriteOverride: viewModel.isFavoriteOverride,
                type: viewModel.type,
                tag: viewModel.tags,
                onTap: () async {
                  if (logic.selecting) {
                    logic.selected[index] = !logic.selected[index];
                    logic.selected[index] ? logic.selectedNum++ : logic.selectedNum--;
                    if (logic.selectedNum == 0) {
                      logic.selecting = false;
                    }
                    logic.update();
                  } else if (isRootItem) {
                    _toComicInfoPage(context, item);
                  } else {
                    _showInfo(index, logic, context);
                  }
                },
                size: viewModel.size,
                onLongTap: () {
                  if (logic.selecting) return;
                  logic.selected[index] = true;
                  logic.selectedNum++;
                  logic.selecting = true;
                  logic.update();
                },
                onSecondaryTap: (details) {
                  _showDesktopMenu(context, logic, index, details);
                },
              ),
            ),
            if (selected)
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colorScheme.primary.withValues(alpha: 0.22),
                      border: Border.all(
                        color: colorScheme.primary,
                        width: 1.6,
                      ),
                      borderRadius: const BorderRadius.all(Radius.circular(16)),
                    ),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            colorScheme.primary.withValues(alpha: 0.14),
                            colorScheme.primary.withValues(alpha: 0.28),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (selected)
              Positioned(
                top: 10,
                right: 10,
                child: IgnorePointer(
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: colorScheme.primary,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: colorScheme.shadow.withValues(alpha: 0.18),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Icon(
                      Icons.check,
                      size: 16,
                      color: colorScheme.onPrimary,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showDesktopMenu(BuildContext context, DownloadPageLogic logic,
      int index, TapDownDetails details) {
    final item = logic.comics[index];
    final isRootItem = item is RemoteLibraryRootItem;
    showMenu(
      context: context,
      position: RelativeRect.fromLTRB(
        details.globalPosition.dx,
        details.globalPosition.dy,
        details.globalPosition.dx + 1,
        details.globalPosition.dy + 1,
      ),
      items: [
        PopupMenuItem(
          child: Text(isRootItem ? "打开列表".tl : "阅读".tl),
          onTap: () {
            if (isRootItem) {
              Future.delayed(const Duration(milliseconds: 120), () {
                _toComicInfoPage(App.globalContext!, item);
              });
              return;
            }
            item.read();
          },
        ),
        if (logic.canDeleteItem(item))
          PopupMenuItem(
            child: Text("删除".tl),
            onTap: () {
              Future.delayed(const Duration(milliseconds: 200), () {
                final texts = buildDeleteActionTexts(itemName: item.name);
                showDialog(
                  context: App.globalContext!,
                  builder: (ctx) => AlertDialog(
                    title: Text(texts.title.tl),
                    content: Text(texts.content.tl),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: Text("取消".tl),
                      ),
                      TextButton(
                        onPressed: () async {
                          Navigator.pop(ctx);
                          final error = await logic.deleteItems([item]);
                          if (error != null && App.globalContext != null) {
                            ScaffoldMessenger.of(App.globalContext!).showSnackBar(
                              SnackBar(content: Text(error)),
                            );
                            return;
                          }
                          logic.refresh();
                        },
                        child: Text(texts.confirmLabel.tl),
                      ),
                    ],
                  ),
                );
              });
            },
          ),
        PopupMenuItem(
          child: Text("导出".tl),
          onTap: () => _exportComic(context, logic, logic.comics[index]),
        ),
        PopupMenuItem(
          child: Text("查看漫画详情".tl),
          onTap: () {
            Future.delayed(const Duration(milliseconds: 300), () {
              _toComicInfoPage(App.globalContext!, logic.comics[index]);
            });
          },
        ),
        PopupMenuItem(
          child: Text("复制路径".tl),
          onTap: () {
            Future.delayed(const Duration(milliseconds: 300), () {
              var path = logic.pathFor(logic.comics[index]);
              Clipboard.setData(ClipboardData(text: path));
            });
          },
        ),
      ],
    );
  }

  void _exportComic(
      BuildContext context, DownloadPageLogic logic, DownloadedItem comic) {
    final fullPath = logic.pathFor(comic);
    if (fullPath.isEmpty) {
      return;
    }
    if (Platform.isWindows) {
      Process.run('explorer', [fullPath]);
    } else if (Platform.isMacOS) {
      Process.run('open', [fullPath]);
    } else if (Platform.isLinux) {
      Process.run('xdg-open', [fullPath]);
    }
  }

  void _showInfo(int index, DownloadPageLogic logic, BuildContext context) {
    final item = logic.comics[index];
    if (UiMode.m1(context)) {
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        showDragHandle: false,
        useSafeArea: false,
        builder: (context) {
          return DownloadedComicInfoView(item, logic);
        },
      );
    } else {
      showSideBar(
        context,
        DownloadedComicInfoView(item, logic),
        useSurfaceTintColor: true,
      );
    }
  }

  Widget _buildFAB(BuildContext context, DownloadPageLogic logic) =>
      FloatingActionButton(
        enableFeedback: true,
        onPressed: () {
          if (!logic.selecting) {
            logic.selecting = true;
            logic.update();
          } else {
            if (logic.selectedNum == 0) return;
            showDialog(
              context: context,
              builder: (dialogContext) {
                return AlertDialog(
                  title: Text(buildDeleteActionTexts(count: logic.selectedNum).title.tl),
                  content: Text(buildDeleteActionTexts(count: logic.selectedNum).content.tl),
                  actions: [
                    TextButton(
                      onPressed: () => App.globalBack(),
                      child: Text("取消".tl),
                    ),
                    TextButton(
                      onPressed: () async {
                        App.globalBack();
                        final items = <DownloadedItem>[];
                        for (int i = 0; i < logic.selected.length; i++) {
                          if (logic.selected[i] &&
                              logic.canDeleteItem(logic.comics[i])) {
                            items.add(logic.comics[i]);
                          }
                        }
                        if (items.isEmpty) {
                          return;
                        }
                        final error = await logic.deleteItems(items);
                        if (error != null && context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(error)),
                          );
                          return;
                        }
                        logic.refresh();
                      },
                      child: Text(buildDeleteActionTexts(count: logic.selectedNum).confirmLabel.tl),
                    ),
                  ],
                );
              },
            );
          }
        },
        child: logic.selecting
            ? const Icon(Icons.delete_forever_outlined)
            : const Icon(Icons.checklist_outlined),
      );

  Widget _buildTitle(BuildContext context, DownloadPageLogic logic) {
    if (logic.searchMode && !logic.selecting) {
      final FocusNode focusNode = FocusNode();
      focusNode.requestFocus();
      bool focus = logic.searchInit;
      logic.searchInit = false;
      return TextField(
        focusNode: focus ? focusNode : null,
        decoration: InputDecoration(
          border: InputBorder.none,
          hintText: "搜索".tl,
        ),
        onChanged: (s) {
          logic.keyword = s;
          logic.find();
          logic.update();
        },
      );
    } else {
      final defaultTitle = logic.pageTitle?.trim().isNotEmpty == true
          ? logic.pageTitle!.trim()
          : "已下载".tl;
      return logic.selecting
          ? Text("已选择 @num 个项目".tlParams({"num": logic.selectedNum.toString()}))
          : Text(defaultTitle);
    }
  }

  Widget _buildAppbar(BuildContext context, DownloadPageLogic logic) {
    return SliverAppbar(
      title: _buildTitle(context, logic),
      color: logic.selecting
          ? Theme.of(context).colorScheme.primaryContainer
          : null,
      leading: logic.selecting
          ? IconButton(
              onPressed: () {
                logic.selecting = false;
                logic.selectedNum = 0;
                for (int i = 0; i < logic.selected.length; i++) {
                  logic.selected[i] = false;
                }
                logic.update();
              },
              icon: const Icon(Icons.close),
            )
          : null,
      actions: _buildActions(context, logic),
    );
  }

  Widget _buildSourceSelector(BuildContext context, DownloadPageLogic logic) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Align(
          alignment: Alignment.centerLeft,
          child: SegmentedButton<_DownloadedLibraryView>(
            showSelectedIcon: false,
            segments: [
              for (final view in _DownloadedLibraryView.values)
                ButtonSegment<_DownloadedLibraryView>(
                  value: view,
                  label: Text(_downloadedLibraryViewLabel(view).tl),
                ),
            ],
            selected: {logic._view},
            onSelectionChanged: (selection) {
              if (selection.isEmpty) {
                return;
              }
              unawaited(logic._setView(selection.first));
            },
          ),
        ),
      ),
    );
  }

  List<Widget> _buildActions(BuildContext context, DownloadPageLogic logic) {
    return [
      if (!logic.selecting && !logic.searchMode)
        Tooltip(
          message: "排序".tl,
          child: IconButton(
            icon: const Icon(Icons.sort),
            onPressed: () async {
              bool changed = false;
              var sortMode = int.parse(appdata.settings[26][0]);
              var reverse = appdata.settings[26][1] == "1";
              await showDialog(
                context: context,
                builder: (context) => StatefulBuilder(
                  builder: (context, setDialogState) => SimpleDialog(
                    title: Text("漫画排序模式".tl),
                    children: [
                      SizedBox(
                        width: 400,
                        child: Column(
                          children: [
                            ListTile(
                              title: Text("漫画排序模式".tl),
                              trailing: DropdownButton<int>(
                                value: sortMode,
                                items: [
                                  DropdownMenuItem(
                                      value: 0, child: Text("时间".tl)),
                                  DropdownMenuItem(
                                      value: 1, child: Text("漫画名".tl)),
                                  DropdownMenuItem(
                                      value: 2, child: Text("作者名".tl)),
                                  DropdownMenuItem(
                                      value: 3, child: Text("大小".tl)),
                                ],
                                onChanged: (i) {
                                  if (i == null || i == sortMode) {
                                    return;
                                  }
                                  setDialogState(() {
                                    sortMode = i;
                                  });
                                  appdata.settings[26] = appdata.settings[26]
                                      .replaceRange(0, 1, i.toString());
                                  appdata.updateSettings();
                                  changed = true;
                                },
                              ),
                            ),
                            ListTile(
                              title: Text("倒序".tl),
                              trailing: Switch(
                                value: reverse,
                                onChanged: (b) {
                                  if (b == reverse) {
                                    return;
                                  }
                                  setDialogState(() {
                                    reverse = b;
                                  });
                                  appdata.settings[26] = appdata.settings[26]
                                      .replaceRange(1, 2, b ? "1" : "0");
                                  appdata.updateSettings();
                                  changed = true;
                                },
                              ),
                            ),
                          ],
                        ),
                      )
                    ],
                  ),
                ),
              );
              if (changed) {
                logic.refresh();
              }
            },
          ),
        ),
      if (logic.selecting)
        Tooltip(
          message: "更多".tl,
          child: IconButton(
            icon: const Icon(Icons.more_horiz),
            onPressed: () {
              showMenu(
                context: context,
                position: RelativeRect.fromLTRB(
                  MediaQuery.of(context).size.width - 60,
                  50,
                  MediaQuery.of(context).size.width - 60,
                  50,
                ),
                items: [
                  PopupMenuItem(
                    child: Text("全选".tl),
                    onTap: () {
                      for (int i = 0; i < logic.selected.length; i++) {
                        logic.selected[i] = true;
                      }
                      logic.selectedNum = logic.comics.length;
                      logic.update();
                    },
                  ),
                  PopupMenuItem(
                    child: Text("导出".tl),
                    onTap: () => _exportSelected(context, logic),
                  ),
                  PopupMenuItem(
                    child: Text("查看漫画详情".tl),
                    onTap: () => Future.delayed(
                      const Duration(milliseconds: 200),
                      () {
                        if (logic.selectedNum != 1) {
                          // showToast not available in picakeep
                        } else {
                          for (int i = 0; i < logic.selected.length; i++) {
                            if (logic.selected[i]) {
                              _toComicInfoPage(
                                  App.globalContext!, logic.comics[i]);
                            }
                          }
                        }
                      },
                    ),
                  ),
                  PopupMenuItem(
                    child: Text("添加至本地收藏".tl),
                    onTap: () => Future.delayed(
                      const Duration(milliseconds: 200),
                      () => _addToLocalFavoriteFolder(logic),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      if (!logic.selecting)
        Tooltip(
          message: "搜索".tl,
          child: IconButton(
            icon: const Icon(Icons.search),
            onPressed: () {
              logic.searchMode = !logic.searchMode;
              logic.searchInit = true;
              if (!logic.searchMode) {
                logic.keyword = "";
                logic.find();
              }
              logic.update();
            },
          ),
        )
    ];
  }

  void _exportSelected(BuildContext context, DownloadPageLogic logic) {
    if (logic.selectedNum == 0) return;
    for (int i = 0; i < logic.selected.length; i++) {
      if (logic.selected[i]) {
        _exportComic(context, logic, logic.comics[i]);
      }
    }
  }

  void _addToLocalFavoriteFolder(DownloadPageLogic logic) {
    String? folder;
    showDialog(
      context: App.globalContext!,
      builder: (context) => SimpleDialog(
        title: const Text("复制到..."),
        children: [
          SizedBox(
            width: 400,
            height: 132,
            child: Column(
              children: [
                ListTile(
                  title: Text("收藏夹".tl),
                  trailing: DropdownButton<String>(
                    hint: Text("选择收藏夹".tl),
                    items: LocalFavoritesManager()
                        .folderNames
                        .map((f) => DropdownMenuItem(value: f, child: Text(f)))
                        .toList(),
                    onChanged: (v) => folder = v,
                  ),
                ),
                const Spacer(),
                Center(
                  child: FilledButton(
                    child: Text("确认".tl),
                    onPressed: () {
                      if (folder == null) return;
                      for (int i = 0; i < logic.selected.length; i++) {
                        if (logic.selected[i]) {
                          var comic = logic.comics[i];
                          LocalFavoritesManager().addComic(
                            folder!,
                            FavoriteItem.fromDownloadedItem(
                              comic,
                              coverPath: logic.coverFor(comic).path,
                            ),
                          );
                        }
                      }
                      App.globalBack();
                    },
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          )
        ],
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context, DownloadPageLogic logic) {
    final path = logic.emptyStatePathText();
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.download_done, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            Text('暂无已下载的漫画'.tl,
                style: const TextStyle(fontSize: 18, color: Colors.grey)),
            const SizedBox(height: 8),
            if (path.isNotEmpty)
              Text('下载目录: $path',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                  textAlign: TextAlign.center),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () async {
                final count = await logic.rescanDisk();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('扫描完成，共发现 $count 个漫画')),
                  );
                }
              },
              icon: const Icon(Icons.refresh),
              label: Text('重新扫描磁盘'.tl),
            ),
            const SizedBox(height: 8),
            Text('请确保下载目录中存在 download.db 数据库文件',
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.outline)),
          ],
        ),
      ),
    );
  }
}

class DownloadedComicInfoView extends StatefulWidget {
  const DownloadedComicInfoView(this.item, this.logic, {super.key});
  final DownloadedItem item;
  final DownloadPageLogic logic;

  @override
  State<DownloadedComicInfoView> createState() =>
      _DownloadedComicInfoViewState();
}

class _DownloadedComicInfoViewState extends State<DownloadedComicInfoView> {
  String name = "";
  String author = "";
  String source = "";
  List<String> tags = const <String>[];
  List<String> eps = [];
  List<int> downloadedEps = [];
  late final ScrollController _scrollController;
  late DownloadedItem _comic;
  String? _resolvedCoverPath;
  bool _loadingRemoteDetail = false;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _comic = widget.item;
    _syncInfo();
    _resolveCoverIfNeeded();
    _loadRemoteDetailIfNeeded();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadRemoteDetailIfNeeded() async {
    final comic = _comic;
    if (comic is! RemoteLibraryComicItem) {
      return;
    }
    if (comic.hasUsableDetailPayload) {
      return;
    }
    setState(() {
      _loadingRemoteDetail = true;
    });
    try {
      final detail = await comic.client.fetchItemDetail(comic.id);
      if (!mounted) {
        return;
      }
      setState(() {
        _comic = detail;
        _syncInfo();
      });
      _resolveCoverIfNeeded();
    } catch (_) {
      if (!mounted) {
        return;
      }
    } finally {
      if (mounted) {
        setState(() {
          _loadingRemoteDetail = false;
        });
      }
    }
  }

  void deleteEpisode(int i) {
    if (!widget.logic.canDeleteItem(_comic)) {
      return;
    }
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text("确认删除".tl),
        content: Text("要删除这个章节吗".tl),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text("取消".tl),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final message = await DownloadManager().deleteEpisode(_comic, i);
              if (message == null && mounted) {
                setState(_syncInfo);
              }
            },
            child: Text("确认".tl),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mediaQuery = MediaQuery.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: mediaQuery.size.height * 0.54,
          ),
          child: Column(
            children: [
              const SizedBox(height: 4),
              Material(
                color: theme.colorScheme.surfaceContainerLow,
                surfaceTintColor: theme.colorScheme.surfaceTint,
                borderRadius: const BorderRadius.all(Radius.circular(20)),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildCover(theme),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              name,
                              style: theme.textTheme.titleLarge,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (author.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text(author, style: theme.textTheme.bodyMedium),
                            ],
                            if (source.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Text(
                                source,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.outline,
                                ),
                              ),
                            ],
                            const SizedBox(height: 8),
                            Text(
                              '${eps.length} ${eps.length == 1 ? '章' : '章节'}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.outline,
                              ),
                            ),
                            if (tags.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: [
                                  for (final tag in tags)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: theme.colorScheme.secondaryContainer,
                                        borderRadius: BorderRadius.circular(999),
                                      ),
                                      child: Text(
                                        _translateDownloadedTag(tag),
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (_loadingRemoteDetail)
              const Padding(
                padding: EdgeInsets.only(top: 10),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '章节'.tl,
                style: theme.textTheme.titleMedium,
              ),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: Scrollbar(
                controller: _scrollController,
                thumbVisibility: true,
                child: GridView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.only(bottom: 12),
                  gridDelegate:
                      const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 300,
                    childAspectRatio: 4,
                  ),
                  itemBuilder: (BuildContext context, int i) {
                    final isDownloaded = downloadedEps.contains(i);
                    return Padding(
                      padding: const EdgeInsets.all(4),
                      child: InkWell(
                        borderRadius: const BorderRadius.all(Radius.circular(16)),
                        child: Material(
                          color: isDownloaded
                              ? theme.colorScheme.primaryContainer
                              : theme.colorScheme.surfaceContainerHighest,
                          surfaceTintColor: theme.colorScheme.surfaceTint,
                          borderRadius:
                              const BorderRadius.all(Radius.circular(16)),
                          child: Row(
                            children: [
                              const SizedBox(width: 16),
                              Expanded(
                                child: Text(
                                  eps[i],
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 4),
                              if (isDownloaded)
                                const Icon(Icons.download_done_outlined),
                              const SizedBox(width: 16),
                            ],
                          ),
                        ),
                        onTap: () => readSpecifiedEps(i),
                        onLongPress: () => deleteEpisode(i),
                        onSecondaryTapDown: (_) => deleteEpisode(i),
                      ),
                    );
                  },
                  itemCount: eps.length,
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 56,
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.tonal(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(56),
                      ),
                      onPressed: () {
                        App.globalBack();
                        _toComicInfoPage(context, _comic);
                      },
                      child: Text("查看详情".tl),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(56),
                      ),
                      onPressed: read,
                      child: Text("阅读".tl),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: math.max(mediaQuery.padding.bottom, 12)),
          ],
        ),
      ),
    ),
    );
  }

  Future<void> _resolveCoverIfNeeded() async {
    final comic = _comic;
    if (comic is! LocalLibraryComicItem) {
      return;
    }
    final cached = comic.localCoverPath?.trim();
    if (cached != null && cached.isNotEmpty) {
      if (_resolvedCoverPath != cached && mounted) {
        setState(() {
          _resolvedCoverPath = cached;
        });
      } else {
        _resolvedCoverPath = cached;
      }
      return;
    }
    final path = await LocalLibraryManager().resolveCoverPathForItem(comic);
    if (!mounted) {
      return;
    }
    final resolved = path?.trim();
    if (resolved == null || resolved.isEmpty || _resolvedCoverPath == resolved) {
      return;
    }
    setState(() {
      _resolvedCoverPath = resolved;
    });
  }

  Widget _buildCover(ThemeData theme) {
    final resolvedCoverPath = _resolvedCoverPath?.trim();
    if (resolvedCoverPath != null && resolvedCoverPath.isNotEmpty) {
      return ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(16)),
        child: Container(
          width: 92,
          height: 124,
          color: theme.colorScheme.surfaceContainerHighest,
          child: Image.file(
            File(resolvedCoverPath),
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _buildCoverPlaceholder(theme),
          ),
        ),
      );
    }

    final imageProvider = widget.logic.coverImageProviderFor(_comic);
    final file = widget.logic.coverFor(_comic);
    final hasFile = file.path.trim().isNotEmpty;
    return ClipRRect(
      borderRadius: const BorderRadius.all(Radius.circular(16)),
      child: Container(
        width: 92,
        height: 124,
        color: theme.colorScheme.surfaceContainerHighest,
        child: imageProvider != null
            ? Image(
                image: imageProvider,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _buildCoverPlaceholder(theme),
              )
            : hasFile
                ? Image.file(
                    file,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _buildCoverPlaceholder(theme),
                  )
                : _buildCoverPlaceholder(theme),
      ),
    );
  }

  Widget _buildCoverPlaceholder(ThemeData theme) {
    return Center(
      child: Icon(
        Icons.menu_book_outlined,
        color: theme.colorScheme.outline,
        size: 32,
      ),
    );
  }

  void _syncInfo() {
    name = _comic.name;
    author = _downloadedItemAuthor(_comic);
    source = _downloadedItemSource(_comic);
    tags = _downloadedItemTags(_comic);
    eps = _comic.eps;
    downloadedEps = _comic.downloadedEps;
    if (_comic is RemoteLibraryComicItem && downloadedEps.isEmpty && eps.isNotEmpty) {
      downloadedEps = List<int>.generate(eps.length, (index) => index, growable: false);
    }
  }

  void read() {
    _comic.read();
  }

  void readSpecifiedEps(int i) {
    _comic.read(ep: i + 1);
  }
}

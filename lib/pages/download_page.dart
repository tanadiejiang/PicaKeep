import 'dart:async';
import 'dart:io' show File, Platform, Process;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/app_runtime_mode.dart';
import 'package:picakeep/foundation/download.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/local_data_source.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/local_library_settings.dart';
import 'package:picakeep/foundation/remote_library_data_source.dart';
import 'package:picakeep/foundation/service_data_source.dart';
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

class _DownloadedPageComicTile extends DownloadedComicTile {
  const _DownloadedPageComicTile({
    required this.comicId,
    required super.name,
    required super.author,
    required super.imagePath,
    super.imageProvider,
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
    }
  }

  final String? remoteRootId;
  final String? pageTitle;
  final RemoteLibraryDataSource _remoteDataSource =
      const RemoteLibraryDataSource();

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

  bool get showSourceSelector => remoteAvailable && !_isRemoteRootPage;

  void _setView(_DownloadedLibraryView nextView) {
    if (_view == nextView) {
      return;
    }
    _view = nextView;
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
    if (keyword == keyword_) {
      return;
    }
    keyword_ = keyword;
    comics = <DownloadedItem>[];
    if (keyword == "") {
      comics.addAll(baseComics);
    } else {
      for (var element in baseComics) {
        if (_matchesDownloadedKeyword(element, keyword)) {
          comics.add(element);
        }
      }
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
    if (!remoteAvailable && _view != _DownloadedLibraryView.local) {
      _view = _DownloadedLibraryView.local;
    }
    comics = List<DownloadedItem>.from(await _loadComics(order, direction));
    baseComics = List<DownloadedItem>.from(comics);
    resetSelected(comics.length);
    loading = false;
    update();
  }

  Future<List<DownloadedItem>> _loadComics(
      String order, String direction) async {
    final localItems = await _loadLocalComics(order, direction);
    if (!remoteAvailable) {
      return localItems;
    }

    switch (_view) {
      case _DownloadedLibraryView.local:
        return localItems;
      case _DownloadedLibraryView.aggregate:
        try {
          final remoteItems = await _loadRemoteComics(order, direction);
          final merged = <DownloadedItem>[...localItems, ...remoteItems];
          _sortItems(merged, order, direction);
          return merged;
        } catch (_) {
          return localItems;
        }
      case _DownloadedLibraryView.remote:
        return _loadRemoteComics(order, direction);
    }
  }

  Future<List<DownloadedItem>> _loadLocalComics(
      String order, String direction) async {
    if (!_usesManagedDownloadSources) {
      await DownloadManager().init();
      return DownloadManager().getAll(order, direction);
    }
    await LocalLibraryManager().refresh();
    final items = await LocalLibraryManager().getAll();
    final downloads =
        items.where((item) => !item.isAlbum).cast<DownloadedItem>().toList();
    _sortItems(downloads, order, direction);
    return downloads;
  }

  Future<List<DownloadedItem>> _loadRemoteComics(
      String order, String direction) async {
    final rootId = remoteRootId?.trim() ?? '';
    final downloads = rootId.isNotEmpty
        ? await _remoteDataSource.fetchItemsForRoot(rootId)
        : (await _remoteDataSource.fetchItems())
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
    return item.canDelete &&
        !_usesManagedDownloadSources &&
        item is! RemoteLibraryComicItem &&
        item is! RemoteLibraryRootItem;
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

  File coverFor(DownloadedItem item) {
    if (item is RemoteLibraryComicItem) {
      return File('');
    }
    if (item is LocalLibraryComicItem) {
      final path = item.localCoverPath?.trim();
      if (path != null && path.isNotEmpty) {
        return File(path);
      }
    }
    return DownloadManager().getCover(item.id);
  }

  ImageProvider<Object>? coverImageProviderFor(DownloadedItem item) {
    if (item is RemoteLibraryComicItem) {
      return item.coverImageProvider;
    }
    if (item is RemoteLibraryRootItem) {
      return item.coverImageProvider;
    }
    return null;
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

class DownloadPage extends StatelessWidget {
  const DownloadPage({
    super.key,
    this.remoteRootId,
    this.title,
  });

  final String? remoteRootId;
  final String? title;

  @override
  Widget build(BuildContext context) {
    return StateBuilder<DownloadPageLogic>(
      init: DownloadPageLogic(
        remoteRootId: remoteRootId,
        pageTitle: title,
      ),
      initState: (logic) {
        logic.bindLocalDataRefresh();
        logic.refresh();
      },
      dispose: (logic) => logic.unbindLocalDataRefresh(),
      builder: (logic) {
        if (logic.loading) {
          return const Scaffold(
            body: Center(
              child: CircularProgressIndicator(),
            ),
          );
        }
        return Scaffold(
          floatingActionButton: _buildFAB(context, logic),
          body: SmoothCustomScrollView(
            slivers: [
              _buildAppbar(context, logic),
              if (logic.showSourceSelector)
                _buildSourceSelector(context, logic),
              _buildComics(context, logic)
            ],
          ),
        );
      },
    );
  }

  Widget _buildComics(BuildContext context, DownloadPageLogic logic) {
    logic.find();
    final comics = logic.comics;
    if (comics.isEmpty) {
      return SliverToBoxAdapter(
        child: _buildEmptyState(context, logic),
      );
    }
    return SliverGrid(
      delegate: SliverChildBuilderDelegate(
        childCount: comics.length,
        (context, index) {
          return _buildItem(context, logic, index);
        },
      ),
      gridDelegate: SliverGridDelegateWithComics(),
    );
  }

  Widget _buildItem(BuildContext context, DownloadPageLogic logic, int index) {
    final item = logic.comics[index];
    final selected = logic.selected[index];
    final type = _downloadedItemSource(item);
    final author = _downloadedItemAuthor(item);
    final tags = _downloadedItemTags(item);
    final isRootItem = item is RemoteLibraryRootItem;
    return Padding(
      padding: const EdgeInsets.all(2),
      child: Container(
        decoration: BoxDecoration(
          color: selected
              ? Theme.of(context).colorScheme.surfaceContainerHighest
              : Colors.transparent,
          borderRadius: const BorderRadius.all(Radius.circular(16)),
        ),
        child: _DownloadedPageComicTile(
          comicId: item.id,
          name: item.name,
          author: author,
          imagePath: logic.coverFor(item),
          imageProvider: logic.coverImageProviderFor(item),
          type: type,
          tag: tags,
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
          size: () {
            if (logic.comics[index].comicSize != null) {
              return "${logic.comics[index].comicSize!.toStringAsFixed(2)}MB";
            } else {
              return "未知大小".tl;
            }
          }.call(),
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
                showDialog(
                  context: App.globalContext!,
                  builder: (ctx) => AlertDialog(
                    title: Text("确认删除".tl),
                    content: Text("此操作无法撤销, 是否继续?".tl),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: Text("取消".tl),
                      ),
                      TextButton(
                        onPressed: () {
                          Navigator.pop(ctx);
                          DownloadManager().delete([item.id]);
                          logic.comics.removeAt(index);
                          logic.selected.removeAt(index);
                          logic.update();
                        },
                        child: Text("确认".tl),
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
    if (UiMode.m1(context)) {
      showModalBottomSheet(
        context: context,
        builder: (context) {
          return DownloadedComicInfoView(logic.comics[index], logic);
        },
      );
    } else {
      showSideBar(
        context,
        DownloadedComicInfoView(logic.comics[index], logic),
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
                  title: Text("删除".tl),
                  content: Text("要删除已选择的项目吗? 此操作无法撤销".tl),
                  actions: [
                    TextButton(
                      onPressed: () => App.globalBack(),
                      child: Text("取消".tl),
                    ),
                    TextButton(
                      onPressed: () async {
                        App.globalBack();
                        final comics = <String>[];
                        for (int i = 0; i < logic.selected.length; i++) {
                          if (logic.selected[i] &&
                              logic.canDeleteItem(logic.comics[i])) {
                            comics.add(logic.comics[i].id);
                          }
                        }
                        if (comics.isEmpty) {
                          return;
                        }
                        await DownloadManager().delete(comics);
                        logic.refresh();
                      },
                      child: Text("确认".tl),
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
          logic.keyword = s.toLowerCase();
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
              logic._setView(selection.first);
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
              await showDialog(
                context: context,
                builder: (context) => SimpleDialog(
                  title: Text("漫画排序模式".tl),
                  children: [
                    SizedBox(
                      width: 400,
                      child: Column(
                        children: [
                          ListTile(
                            title: Text("漫画排序模式".tl),
                            trailing: DropdownButton<int>(
                              value: int.parse(appdata.settings[26][0]),
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
                                if (i != null) {
                                  appdata.settings[26] = appdata.settings[26]
                                      .replaceRange(0, 1, i.toString());
                                  appdata.updateSettings();
                                  changed = true;
                                }
                              },
                            ),
                          ),
                          ListTile(
                            title: Text("倒序".tl),
                            trailing: Switch(
                              value: appdata.settings[26][1] == "1",
                              onChanged: (b) {
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
  late final comic = widget.item;

  deleteEpisode(int i) {
    if (!widget.logic.canDeleteItem(comic)) {
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
              var message = await DownloadManager().deleteEpisode(comic, i);
              if (message == null) {
                setState(() {});
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
    getInfo();
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 16, 0, 12),
            child: Text(
              name,
              style: const TextStyle(fontSize: 22),
            ),
          ),
          if (author.isNotEmpty || source.isNotEmpty || tags.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (author.isNotEmpty)
                    Row(
                      children: [
                        Icon(
                          Icons.person_outline,
                          size: 16,
                          color: Theme.of(context).colorScheme.outline,
                        ),
                        const SizedBox(width: 6),
                        Expanded(child: Text(author)),
                      ],
                    ),
                  if (author.isNotEmpty && source.isNotEmpty)
                    const SizedBox(height: 8),
                  if (source.isNotEmpty)
                    Row(
                      children: [
                        Icon(
                          Icons.source_outlined,
                          size: 16,
                          color: Theme.of(context).colorScheme.outline,
                        ),
                        const SizedBox(width: 6),
                        Expanded(child: Text(source)),
                      ],
                    ),
                  if (tags.isNotEmpty) ...[
                    const SizedBox(height: 10),
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
                              color: Theme.of(context)
                                  .colorScheme
                                  .secondaryContainer,
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
          Expanded(
            child: GridView.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 300,
                childAspectRatio: 4,
              ),
              itemBuilder: (BuildContext context, int i) {
                return Padding(
                  padding: const EdgeInsets.all(4),
                  child: InkWell(
                    borderRadius: const BorderRadius.all(Radius.circular(16)),
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius:
                            const BorderRadius.all(Radius.circular(16)),
                        color: downloadedEps.contains(i)
                            ? Theme.of(context).colorScheme.primaryContainer
                            : Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest,
                      ),
                      child: Row(
                        children: [
                          const SizedBox(width: 16),
                          Expanded(
                            child: Text(eps[i]),
                          ),
                          const SizedBox(width: 4),
                          if (downloadedEps.contains(i))
                            const Icon(Icons.download_done),
                          const SizedBox(width: 16),
                        ],
                      ),
                    ),
                    onTap: () => readSpecifiedEps(i),
                    onLongPress: () {
                      deleteEpisode(i);
                    },
                    onSecondaryTapDown: (details) {
                      deleteEpisode(i);
                    },
                  ),
                );
              },
              itemCount: eps.length,
            ),
          ),
          SizedBox(
            height: 50,
            child: Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: () {
                      App.globalBack();
                      _toComicInfoPage(context, widget.item);
                    },
                    child: Text("查看详情".tl),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: FilledButton(
                    onPressed: () => read(),
                    child: Text("阅读".tl),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: MediaQuery.of(context).padding.bottom,
          )
        ],
      ),
    );
  }

  void getInfo() {
    name = comic.name;
    author = _downloadedItemAuthor(comic);
    source = _downloadedItemSource(comic);
    tags = _downloadedItemTags(comic);
    eps = comic.eps;
    downloadedEps = comic.downloadedEps;
  }

  void read() {
    comic.read();
  }

  void readSpecifiedEps(int i) {
    comic.read(ep: i + 1);
  }
}

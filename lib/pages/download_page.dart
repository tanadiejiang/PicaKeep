import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:io' show File, Platform, Process;

import 'package:flutter/rendering.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/app_page_route.dart';
import 'package:picakeep/foundation/app_runtime_mode.dart';
import 'package:picakeep/foundation/download.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/history.dart';
import 'package:picakeep/foundation/archive/archive_password_store.dart';
import 'package:picakeep/foundation/local_data_source.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/local_library_settings.dart';
import 'package:picakeep/foundation/log.dart';
import 'package:picakeep/foundation/online_download_manager.dart';
import 'package:picakeep/foundation/remote_library_event_channel.dart';
import 'package:picakeep/foundation/remote_library_data_source.dart';
import 'package:picakeep/foundation/service_data_source.dart';
import 'package:picakeep/foundation/trash.dart';
import 'package:picakeep/foundation/ui_mode.dart';
import 'package:picakeep/tools/translations.dart';
import 'downloading/downloading_page.dart';
import 'package:picakeep/components/comic_tile.dart';
import 'package:picakeep/components/scrollable.dart';
import 'package:picakeep/components/layout.dart';
import 'package:picakeep/components/components.dart';
import 'package:picakeep/components/archive_password_dialog.dart';
import 'package:picakeep/components/window_frame.dart';
import 'package:picakeep/tools/read_history_helper.dart';
import 'package:picakeep/tools/tags_translation.dart';
import 'local_comic_detail_page.dart';

part 'download_page_logic_loading.dart';
part 'download_page_logic_cover.dart';
part 'download_page_logic_actions.dart';
part 'download_page_logic_view.dart';

Future<RemoteLibraryComicItem?> _ensureRemoteArchiveUnlockedFor(
  BuildContext context,
  RemoteLibraryComicItem item,
) async {
  if (!item.needsArchivePassword) {
    return item;
  }
  final result = await showArchivePasswordDialog(
    context: context,
    archivePath: item.remotePath,
    archiveFileName: item.name,
    format: item.archiveFormat,
    allowAddToDefaults: false,
    onVerify: (password) => item.client.unlockArchive(item.id, password),
  );
  if (result == null) {
    return null;
  }
  item.archivePasswordMatched = true;
  try {
    return (await item.client.fetchItemDetail(item.id))
        .copyWith(archivePasswordMatched: true);
  } catch (_) {
    return item.copyWith(archivePasswordMatched: true);
  }
}

void _toComicInfoPage(DownloadedItem comic) {
  if (comic is RemoteLibraryRootItem) {
    App.pushInner(
      () => DownloadPage(
        remoteRootId: comic.root.id,
        title: comic.name,
      ),
    );
    return;
  }
  App.pushInner(() => LocalComicDetailPage(comic: comic));
}

extension ReadComic on DownloadedItem {
  Future<void> read({int? ep, int? page, BuildContext? context}) async {
    final contextNavigator = context == null ? null : Navigator.of(context);
    DownloadedItem itemToRead = this;
    if (this is RemoteLibraryComicItem) {
      final item = this as RemoteLibraryComicItem;
      final unlockContext = context ?? App.globalContext;
      if (item.needsArchivePassword && unlockContext == null) {
        return;
      }
      if (unlockContext != null) {
        final unlocked = await _ensureRemoteArchiveUnlockedFor(
          unlockContext,
          item,
        );
        if (unlocked == null) {
          return;
        }
        itemToRead = unlocked;
      }
    }
    await ensureHistoryBeforeRead(itemToRead);
    if (contextNavigator != null) {
      if (!contextNavigator.mounted) {
        return;
      }
      await contextNavigator.push(
        AppPageRoute(
          builder: (context) =>
              itemToRead.createReadingPage(ep: ep, page: page),
        ),
      );
    } else {
      await App.pushInner(
          () => itemToRead.createReadingPage(ep: ep, page: page));
    }
  }
}

String _translateDownloadedTag(String tag) {
  try {
    var value = tag.trim();
    if (value.contains(':')) {
      value = value.split(':').last.trim();
    }
    var suffix = '';
    if (value.endsWith(' ♀')) {
      suffix = '♀';
      value = value.substring(0, value.length - 2).trim();
    } else if (value.endsWith(' ♂')) {
      suffix = '♂';
      value = value.substring(0, value.length - 2).trim();
    }
    final lowerValue = value.toLowerCase();
    for (final map in tagTranslations.values) {
      final hit = map[lowerValue];
      if (hit != null && hit.isNotEmpty) {
        return '$hit$suffix';
      }
    }
    return '$value$suffix';
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

  // 远程条目：toJson() 序列化全量 episodes 极慢，直接返回轻量字段
  if (item is RemoteLibraryComicItem) {
    if (item.displayId.isNotEmpty) yield item.displayId.toLowerCase();
    if (item.remoteId.isNotEmpty) yield item.remoteId.toLowerCase();
    if (item.remotePath.isNotEmpty) yield item.remotePath.toLowerCase();
    return;
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
    for (final key in const [
      'sourceDisplayName',
      'metadataSourceDisplayName',
      'sourceTitle'
    ]) {
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
  }) : super(
          optimizeCoverDecode: true,
          maxTagRows: 2,
        );

  final String comicId;

  @override
  String? get comicID => comicId;
}

class _DownloadedLoadIssue {
  const _DownloadedLoadIssue({
    required this.title,
    required this.detail,
    this.timedOut = false,
  });

  final String title;
  final String detail;
  final bool timedOut;
}

class _DownloadedLoadResult {
  const _DownloadedLoadResult({
    this.items = const <DownloadedItem>[],
    this.issue,
  });

  final List<DownloadedItem> items;
  final _DownloadedLoadIssue? issue;
}

const Duration _localLoadTimeout = Duration(seconds: 8);
const Duration _remoteLoadTimeout = Duration(seconds: 10);

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
  // 解析结果为「无封面」的 managed 下载项 id：其源目录没有任何可用封面
  // （cover.* 全部命中失败、剧集图片枚举也为空），resolveCoverPathForItem 每次都
  // 返回 null 且不写缓存。若不记忆，列表折返时它们会被反复重新入队、每次重走
  // ~11 次 root 特权通道（exists×8 + listDir×3），造成滚动期周期性卡顿。记下后
  // 只渲染占位图标、不再触发通道。reload 时随队列一起清空，真正刷新仍会重试。
  final Set<String> _coverResolveFailedIds = <String>{};
  final Queue<LocalLibraryComicItem> _coverResolveQueue =
      Queue<LocalLibraryComicItem>();
  bool _coverResolveQueueRunning = false;
  bool _coverRefreshScheduled = false;
  bool _isScrollInteracting = false;
  bool _pendingCoverRefresh = false;
  Timer? _scrollIdleTimer;
  Timer? _searchDebounceTimer;

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
  bool _isDeletingItems = false;
  int _deleteProgressCurrent = 0;
  int _deleteProgressTotal = 0;
  String _deleteProgressActionLabel = '';
  _DownloadedLibraryView _view = _DownloadedLibraryView.local;
  bool remoteAvailable = false;
  bool _forceRemoteRefreshOnNextReload = false;
  _DownloadedLoadIssue? _loadIssue;
  DateTime? _lastManualRemoteRefreshAt;

  @override
  void refresh() {
    if (_isDeletingItems) {
      _forceRemoteRefreshOnNextReload = true;
      return;
    }
    searchMode = false;
    selecting = false;
    selectedNum = 0;
    selected = <bool>[];
    comics = <DownloadedItem>[];
    baseComics = <DownloadedItem>[];
    _tileViewModels.clear();
    _queuedCoverIds.clear();
    _coverResolveQueue.clear();
    _coverResolveFailedIds.clear();
    _coverResolveQueueRunning = false;
    _coverRefreshScheduled = false;
    _loadIssue = null;
    loading = true;
    update();
    unawaited(_reloadVisibleComics());
  }

  @override
  void dispose() {
    _scrollIdleTimer?.cancel();
    _searchDebounceTimer?.cancel();
    super.dispose();
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
    RemoteLibraryEventChannel.instance.onRemotePageActivated();
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
    RemoteLibraryEventChannel.instance.onRemotePageActivated();
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
        // loading 态不再整页替换成转圈（那样会盖住 AppBar 与视图选择器，
        // 切远程档时整屏一片转圈）。改为始终渲染正常骨架，由 _buildComics
        // 在 loading && 无数据时只让列表区显示转圈。
        Widget page = Scaffold(
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
                  ? MediaQuery.of(context).size.height
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
        if (logic.isDeleteOperationRunning) {
          page = Stack(
            fit: StackFit.expand,
            children: [
              page,
              Positioned.fill(
                child: _buildDeleteProgressOverlayContent(context, logic),
              ),
            ],
          );
        }
        return PopScope(
          canPop: !logic.isDeleteOperationRunning,
          child: page,
        );
      },
    );
  }

  Widget _buildDeleteProgressOverlayContent(
      BuildContext context, DownloadPageLogic logic) {
    final theme = Theme.of(context);
    final progressText =
        '${logic.deleteProgressCurrent}/${logic.deleteProgressTotal}';
    final isDesktop = App.isDesktop;
    final barrierColor = Color.alphaBlend(
      theme.colorScheme.primary.withValues(alpha: 0.06),
      Colors.white.withValues(alpha: 0.76),
    );
    final panelColor = Color.alphaBlend(
      theme.colorScheme.primary.withValues(alpha: 0.04),
      theme.colorScheme.surface.withValues(alpha: 0.97),
    );
    return Stack(
      children: [
        ModalBarrier(
          dismissible: false,
          color: barrierColor,
        ),
        Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: isDesktop ? 440 : 300,
              minWidth: isDesktop ? 340 : 260,
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: panelColor,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: theme.colorScheme.shadow.withValues(alpha: 0.08),
                    blurRadius: 24,
                    offset: const Offset(0, 10),
                  ),
                ],
                border: Border.all(
                  color:
                      theme.colorScheme.outlineVariant.withValues(alpha: 0.45),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 22,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 36,
                      height: 36,
                      child: CircularProgressIndicator(
                        strokeWidth: 3.2,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (isDesktop)
                      Text(
                        '${logic.deleteProgressActionLabel.tl} $progressText',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.onSurface,
                        ),
                      )
                    else ...[
                      Text(
                        logic.deleteProgressActionLabel.tl,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        progressText,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.primary,
                          height: 1.25,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Text(
                      logic.deleteProgressHint.tl,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildComics(BuildContext context, DownloadPageLogic logic) {
    final comics = logic.comics;
    if (comics.isEmpty) {
      // 加载中且尚无数据：只在列表区显示转圈，保留上方 AppBar 与视图选择器。
      // 任何档位（本地/远程/聚合）切换或首次加载都走这里，加载完成后
      // update() 刷新即显示列表，无需整页覆盖。
      if (logic.loading) {
        return const SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: CircularProgressIndicator()),
        );
      }
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
                    logic.selected[index]
                        ? logic.selectedNum++
                        : logic.selectedNum--;
                    if (logic.selectedNum == 0) {
                      logic.selecting = false;
                    }
                    logic.update();
                  } else if (isRootItem) {
                    _toComicInfoPage(item);
                  } else if (item is RemoteLibraryComicItem &&
                      item.needsArchivePassword) {
                    final unlockedItem =
                        await _ensureRemoteArchiveUnlockedFor(context, item);
                    if (!context.mounted) {
                      return;
                    }
                    if (unlockedItem != null) {
                      logic.refresh();
                      _showInfo(
                        index,
                        logic,
                        context,
                        itemOverride: unlockedItem,
                      );
                    }
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
                _toComicInfoPage(item);
              });
              return;
            }
            item.read(context: context);
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
                            ScaffoldMessenger.of(App.globalContext!)
                                .showSnackBar(
                              SnackBar(content: Text(error)),
                            );
                            return;
                          }
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
              _toComicInfoPage(logic.comics[index]);
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

  void _showInfo(
    int index,
    DownloadPageLogic logic,
    BuildContext context, {
    DownloadedItem? itemOverride,
  }) {
    final item = itemOverride ?? logic.comics[index];
    if (UiMode.m1(context)) {
      final screenHeight = MediaQuery.of(context).size.height;
      final maxSize = screenHeight > 0
          ? math.min(0.8, math.max(0.5, (screenHeight - 92) / screenHeight))
          : 0.8;
      const minSize = 0.3;
      final sheetController = DraggableScrollableController();
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        showDragHandle: false,
        useSafeArea: false,
        backgroundColor: Colors.transparent,
        builder: (context) {
          return DraggableScrollableSheet(
            controller: sheetController,
            initialChildSize: 0.6,
            minChildSize: minSize,
            maxChildSize: maxSize,
            expand: false,
            builder: (context, scrollController) {
              return Material(
                color: Theme.of(context).colorScheme.surface,
                surfaceTintColor: Theme.of(context).colorScheme.surfaceTint,
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.vertical(
                    top: Radius.circular(16),
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: DownloadedComicInfoView(
                  item,
                  logic,
                  scrollController: scrollController,
                  sheetController: sheetController,
                  sheetMaxSize: maxSize,
                  sheetMinSize: minSize,
                ),
              );
            },
          );
        },
      ).whenComplete(sheetController.dispose);
    } else {
      showSideBar(
        App.globalContext ?? context,
        DownloadedComicInfoView(item, logic),
        useSurfaceTintColor: true,
      );
    }
  }

  Widget _buildFAB(BuildContext context, DownloadPageLogic logic) =>
      FloatingActionButton(
        enableFeedback: true,
        onPressed: logic.isDeleteOperationRunning
            ? null
            : () {
                if (!logic.selecting) {
                  logic.selecting = true;
                  logic.update();
                } else {
                  if (logic.selectedNum == 0) return;
                  showDialog(
                    context: context,
                    builder: (dialogContext) {
                      return AlertDialog(
                        title: Text(
                            buildDeleteActionTexts(count: logic.selectedNum)
                                .title
                                .tl),
                        content: Text(
                            buildDeleteActionTexts(count: logic.selectedNum)
                                .content
                                .tl),
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
                            },
                            child: Text(
                                buildDeleteActionTexts(count: logic.selectedNum)
                                    .confirmLabel
                                    .tl),
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
          logic._searchDebounceTimer?.cancel();
          logic._searchDebounceTimer = Timer(
            const Duration(milliseconds: 280),
            () {
              logic.keyword = s;
              logic.find();
              logic.update();
            },
          );
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
      if (logic.showManualRemoteRefreshButton)
        Tooltip(
          message: '刷新远程'.tl,
          child: IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: logic.triggerManualRemoteRefresh,
          ),
        ),
      if (!logic.selecting && !logic.searchMode)
        Tooltip(
          message: '下载队列'.tl,
          child: IconButton(
            icon: const Icon(Icons.downloading_outlined),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const DownloadingPage()),
              );
            },
          ),
        ),
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
                            ListTile(
                              title: Text("显示数据库全部记录".tl),
                              subtitle: Text(
                                "包含本地已删除但数据库仍有记录的项".tl,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              trailing: Switch(
                                value: appdata.settings[
                                        localLibraryShowAllDatabaseRecordsSettingIndex] ==
                                    '1',
                                onChanged: (b) {
                                  setDialogState(() {
                                    appdata.settings[
                                            localLibraryShowAllDatabaseRecordsSettingIndex] =
                                        b ? '1' : '0';
                                  });
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
                              _toComicInfoPage(logic.comics[i]);
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
    final showRemoteDisconnectedHint = logic.showRemoteDisconnectedHint;
    final remoteAddress = logic.remoteServerAddressText;
    final hasLoadIssue = logic.hasLoadIssue;
    final title = showRemoteDisconnectedHint
        ? '远程服务当前未连接'.tl
        : (logic.loadIssueTitle ?? '暂无已下载的漫画'.tl);
    final detail = showRemoteDisconnectedHint
        ? (remoteAddress.isEmpty
            ? '已配置远程服务，但当前无法连接，请检查服务状态或地址配置。'.tl
            : '当前无法连接到 $remoteAddress，请检查服务是否在线。'.tl)
        : logic.loadIssueDetail;
    final actionLabel = showRemoteDisconnectedHint
        ? '刷新连接状态'.tl
        : hasLoadIssue
            ? '重新加载'.tl
            : '重新扫描磁盘'.tl;
    final hintText = showRemoteDisconnectedHint
        ? '如地址无误，请确认远程服务已启动且当前网络可达。'.tl
        : hasLoadIssue
            ? '可以点击重新加载再次尝试。'.tl
            : '请确保下载目录中存在 download.db 数据库文件。'.tl;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              showRemoteDisconnectedHint
                  ? Icons.cloud_off_outlined
                  : hasLoadIssue
                      ? (logic.loadIssueTimedOut
                          ? Icons.hourglass_disabled_outlined
                          : Icons.error_outline)
                      : Icons.download_done,
              size: 64,
              color: Colors.grey,
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: const TextStyle(fontSize: 18, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            if (detail != null && detail.isNotEmpty)
              Text(
                detail,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
                textAlign: TextAlign.center,
              )
            else if (path.isNotEmpty)
              Text(
                '下载目录: $path',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
                textAlign: TextAlign.center,
              ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () async {
                if (showRemoteDisconnectedHint || hasLoadIssue) {
                  logic.refresh();
                  if (!context.mounted) {
                    return;
                  }
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('已重新开始加载'.tl)),
                  );
                  return;
                }
                final count = await logic.rescanDisk();
                if (!context.mounted) {
                  return;
                }
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('扫描完成，共发现 $count 个漫画'.tl)),
                );
              },
              icon: const Icon(Icons.refresh),
              label: Text(actionLabel),
            ),
            const SizedBox(height: 8),
            Text(
              hintText,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.outline,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  // ignore: unused_element
  Widget _buildEmptyStateLegacy(BuildContext context, DownloadPageLogic logic) {
    final path = logic.emptyStatePathText();
    final showRemoteDisconnectedHint = logic.showRemoteDisconnectedHint;
    final remoteAddress = logic.remoteServerAddressText;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              showRemoteDisconnectedHint
                  ? Icons.cloud_off_outlined
                  : Icons.download_done,
              size: 64,
              color: Colors.grey,
            ),
            const SizedBox(height: 16),
            Text(
              showRemoteDisconnectedHint ? '远程服务当前未连接'.tl : '暂无已下载的漫画'.tl,
              style: const TextStyle(fontSize: 18, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            if (showRemoteDisconnectedHint)
              Text(
                remoteAddress.isEmpty
                    ? '已配置远程服务，但当前无法连接，请检查服务状态或地址配置。'.tl
                    : '当前无法连接到 $remoteAddress，请检查服务是否在线。'.tl,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
                textAlign: TextAlign.center,
              )
            else if (path.isNotEmpty)
              Text('下载目录: $path',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                  textAlign: TextAlign.center),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () async {
                final count = await logic.rescanDisk();
                if (!context.mounted) {
                  return;
                }
                if (showRemoteDisconnectedHint) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('已刷新远程连接状态'.tl)),
                  );
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('扫描完成，共发现 $count 个漫画')),
                  );
                }
              },
              icon: const Icon(Icons.refresh),
              label:
                  Text(showRemoteDisconnectedHint ? '刷新连接状态'.tl : '重新扫描磁盘'.tl),
            ),
            const SizedBox(height: 8),
            Text(
              showRemoteDisconnectedHint
                  ? '如地址无误，请确认远程服务已启动且当前网络可达。'.tl
                  : '请确保下载目录中存在 download.db 数据库文件'.tl,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.outline,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class DownloadedComicInfoView extends StatefulWidget {
  const DownloadedComicInfoView(
    this.item,
    this.logic, {
    super.key,
    this.scrollController,
    this.sheetController,
    this.sheetMaxSize,
    this.sheetMinSize = 0.3,
  });
  final DownloadedItem item;
  final DownloadPageLogic? logic;
  final ScrollController? scrollController;
  final DraggableScrollableController? sheetController;
  final double? sheetMaxSize;
  final double sheetMinSize;

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

  bool get _isArchive {
    final comic = _comic;
    if (comic is LocalLibraryComicItem) {
      return comic.isArchiveItem;
    }
    if (comic is RemoteLibraryComicItem) {
      return comic.isArchive;
    }
    return false;
  }

  bool get _canToggleChapterNumber {
    final comic = _comic;
    if (comic is LocalLibraryComicItem) {
      return comic.isArchiveItem ||
          (comic.sourceDisplayName == '合集图集' && comic.eps.length > 1);
    }
    if (comic is RemoteLibraryComicItem) {
      return comic.isArchive ||
          (comic.isCustomLibraryRoot && comic.hasMultipleEpisodes);
    }
    return false;
  }

  bool get _isCollectionShellAlbum {
    final comic = _comic;
    if (comic is LocalLibraryComicItem) {
      return comic.sourceDisplayName == '合集图集';
    }
    if (comic is RemoteLibraryComicItem) {
      return comic.metadataSourceDisplayName.trim() == '合集图集';
    }
    return false;
  }

  String _stripCollectionShellPrefix(String title) {
    if (!_isCollectionShellAlbum) {
      return title;
    }
    final itemTitle = _comic.name.trim();
    final normalizedTitle = title.trim();
    if (itemTitle.isEmpty || !normalizedTitle.startsWith(itemTitle)) {
      return title;
    }
    final rest = normalizedTitle.substring(itemTitle.length).trimLeft();
    final cleaned =
        rest.replaceFirst(RegExp(r'^[\s/_\\\-—:：]+'), '').trimLeft();
    return cleaned.isEmpty ? title : cleaned;
  }

  String _chapterNumberDisplayName({
    required int index,
    required int episodeIndex,
    required String title,
  }) {
    final trimmed = title.trim();
    if (trimmed.isEmpty) {
      return '${episodeIndex > 0 ? episodeIndex : index + 1}';
    }
    if (RegExp(r'^(第\s*)?\d+\s*(章|话|集|回)?([\s._-]+|$)').hasMatch(trimmed)) {
      return trimmed;
    }
    return '${episodeIndex > 0 ? episodeIndex : index + 1} $trimmed';
  }

  List<String> get _displayNames {
    final comic = _comic;
    if (comic is LocalLibraryComicItem && comic.isArchiveItem) {
      return LocalLibraryManager.archiveDisplayChapterNames(comic);
    }
    if (comic is LocalLibraryComicItem && comic.sourceDisplayName == '合集图集') {
      final titles = eps
          .map((title) => _stripCollectionShellPrefix(title))
          .toList(growable: false);
      if (!readArchiveUseChapterNumber()) {
        return titles;
      }
      return List<String>.generate(titles.length, (index) {
        return _chapterNumberDisplayName(
          index: index,
          episodeIndex: index + 1,
          title: titles[index],
        );
      });
    }
    if (comic is RemoteLibraryComicItem) {
      final titles = eps
          .map((title) => _stripCollectionShellPrefix(title))
          .toList(growable: false);
      if (!comic.isArchive && !comic.isCustomLibraryRoot) {
        return titles;
      }
      if (!readArchiveUseChapterNumber()) {
        return titles;
      }
      return List<String>.generate(titles.length, (index) {
        final episodeIndex = index < comic.episodesData.length
            ? comic.episodesData[index].index
            : index + 1;
        return _chapterNumberDisplayName(
          index: index,
          episodeIndex: episodeIndex,
          title: titles[index],
        );
      });
    }
    return eps;
  }

  ScrollController? _ownedScrollController;
  ScrollController get _scrollController =>
      widget.scrollController ?? _ownedScrollController!;
  late DownloadedItem _comic;
  String? _resolvedCoverPath;
  bool _loadingRemoteDetail = false;

  @override
  void initState() {
    super.initState();
    if (widget.scrollController == null) {
      _ownedScrollController = ScrollController();
    }
    _comic = widget.item;
    _syncInfo();
    _resolveCoverIfNeeded();
    _loadRemoteDetailIfNeeded();
  }

  @override
  void dispose() {
    _ownedScrollController?.dispose();
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
    if (widget.logic == null || !widget.logic!.canDeleteItem(_comic)) {
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
              } else if (message != null && mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(message)),
                );
              }
            },
            child: Text("确认".tl),
          ),
        ],
      ),
    );
  }

  void _handleSheetWheel(PointerSignalEvent event) {
    final sheet = widget.sheetController;
    if (sheet == null || !sheet.isAttached) return;
    if (event is! PointerScrollEvent) return;
    final dy = event.scrollDelta.dy;
    if (dy <= 0) return;
    final maxSize = widget.sheetMaxSize ?? 1.0;
    if (sheet.size >= maxSize - 0.0001) return;
    final screenHeight = MediaQuery.of(context).size.height;
    if (screenHeight <= 0) return;
    final next = (sheet.size + dy / screenHeight).clamp(
      widget.sheetMinSize,
      maxSize,
    );
    sheet.jumpTo(next);
  }

  Widget _buildHeader(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
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
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          source,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.outline,
                          ),
                        ),
                      ),
                      if (_canForgetArchivePassword()) ...[
                        const SizedBox(width: 6),
                        IconButton(
                          onPressed: _forgetArchivePassword,
                          icon: const Icon(Icons.lock_reset),
                          iconSize: 18,
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 28,
                            minHeight: 28,
                          ),
                          tooltip: '忘记密码'.tl,
                          color: theme.colorScheme.primary,
                        ),
                      ],
                    ],
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
                          constraints: const BoxConstraints(maxWidth: 140),
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
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
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
    );
  }

  Widget _buildChapterTitleRow(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        children: [
          Text('章节'.tl, style: theme.textTheme.titleMedium),
          const Spacer(),
          if (_canToggleChapterNumber) ...[
            Text('序号', style: theme.textTheme.bodySmall),
            Transform.scale(
              scale: 0.8,
              child: Switch(
                value: readArchiveUseChapterNumber(),
                onChanged: (v) async {
                  await writeArchiveUseChapterNumber(v);
                  setState(() {});
                },
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildChapterGrid(ThemeData theme) {
    return GridView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 300,
        childAspectRatio: 4,
      ),
      itemCount: eps.length,
      itemBuilder: (BuildContext context, int i) {
        final isDownloaded = _isArchive || downloadedEps.contains(i);
        final displayNames = _displayNames;
        return Padding(
          padding: const EdgeInsets.all(4),
          child: InkWell(
            borderRadius: const BorderRadius.all(Radius.circular(16)),
            onTap: () => readSpecifiedEps(i),
            onLongPress: () => deleteEpisode(i),
            onSecondaryTapDown: (_) => deleteEpisode(i),
            child: Material(
              color: isDownloaded
                  ? theme.colorScheme.primaryContainer
                  : theme.colorScheme.surfaceContainerHighest,
              surfaceTintColor: theme.colorScheme.surfaceTint,
              borderRadius: const BorderRadius.all(Radius.circular(16)),
              child: Row(
                children: [
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      i < displayNames.length ? displayNames[i] : eps[i],
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 4),
                  if (!_isArchive && isDownloaded)
                    const Icon(Icons.download_done_outlined),
                  const SizedBox(width: 16),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mediaQuery = MediaQuery.of(context);
    final topSpacer =
        widget.scrollController != null ? 12.0 : mediaQuery.padding.top + 12.0;
    Widget grid = _buildChapterGrid(theme);
    if (widget.sheetController != null) {
      grid = Listener(
        onPointerSignal: _handleSheetWheel,
        child: grid,
      );
    }
    return SafeArea(
      top: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(height: topSpacer),
          _buildHeader(theme),
          if (_loadingRemoteDetail)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          _buildChapterTitleRow(theme),
          Expanded(child: grid),
          Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              12,
              16,
              math.max(mediaQuery.padding.bottom, 16),
            ),
            child: SizedBox(
              height: 56,
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.tonal(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(56),
                      ),
                      onPressed: () {
                        Navigator.of(context).pop();
                        _toComicInfoPage(_comic);
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
          ),
        ],
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
    if (resolved == null ||
        resolved.isEmpty ||
        _resolvedCoverPath == resolved) {
      return;
    }
    setState(() {
      _resolvedCoverPath = resolved;
    });
  }

  Widget _buildCover(ThemeData theme) {
    // 底栏/侧栏面板封面。本地项一律走 privileged-aware provider，而非裸 Image.file：
    // root/shizuku 模式无 MANAGE_EXTERNAL_STORAGE，Image.file(File(path)) 读外部路径
    // 会静默失败破图——这正是「底栏/侧栏封面只有这两个权限下不显示」的根因。
    // _resolvedCoverPath 有值 → imageProviderForLocalPath（特权通道）；为空且是本地项
    // → coverImageProviderForItem（惰性解析+特权通道）；其余非本地项走原 file 回退。
    final resolvedCoverPath = _resolvedCoverPath?.trim();
    final comic = _comic;
    ImageProvider<Object>? coverProvider;
    if (resolvedCoverPath != null && resolvedCoverPath.isNotEmpty) {
      coverProvider =
          LocalLibraryManager().imageProviderForLocalPath(resolvedCoverPath);
    } else if (comic is LocalLibraryComicItem) {
      coverProvider = LocalLibraryManager().coverImageProviderForItem(comic);
    } else {
      coverProvider = widget.logic?.coverImageProviderFor(comic)
          ?? (comic is RemoteLibraryComicItem ? comic.coverImageProvider : null);
    }

    final file = widget.logic?.coverFor(comic) ?? File('');
    final hasFile = file.path.trim().isNotEmpty;
    return ClipRRect(
      borderRadius: const BorderRadius.all(Radius.circular(16)),
      child: Container(
        width: 92,
        height: 124,
        color: theme.colorScheme.surfaceContainerHighest,
        child: coverProvider != null
            ? Image(
                image: coverProvider,
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
    if (_comic is RemoteLibraryComicItem &&
        downloadedEps.isEmpty &&
        eps.isNotEmpty) {
      downloadedEps =
          List<int>.generate(eps.length, (index) => index, growable: false);
    }
  }

  Future<void> read() async {
    var comic = _comic;
    if (comic is RemoteLibraryComicItem) {
      final unlocked = await _ensureRemoteArchiveUnlockedFor(context, comic);
      if (unlocked == null) {
        return;
      }
      comic = unlocked;
    }
    if (!mounted) {
      return;
    }
    await comic.read(context: context);
    if (mounted) {
      setState(_syncInfo);
    }
  }

  Future<void> readSpecifiedEps(int i) async {
    var comic = _comic;
    if (comic is RemoteLibraryComicItem) {
      final unlocked = await _ensureRemoteArchiveUnlockedFor(context, comic);
      if (unlocked == null) {
        return;
      }
      comic = unlocked;
    }
    if (!mounted) {
      return;
    }
    await comic.read(ep: i + 1, context: context);
    if (mounted) {
      setState(_syncInfo);
    }
  }

  bool _canForgetArchivePassword() {
    final comic = _comic;
    if (comic is! LocalLibraryComicItem) return false;
    if (!comic.isArchiveItem || !comic.archiveEncrypted) return false;
    final path = comic.fileSystemPath ?? '';
    if (path.isEmpty) return false;
    return ArchivePasswordStore.instance.getSessionPassword(path) != null;
  }

  Future<void> _forgetArchivePassword() async {
    final comic = _comic;
    if (comic is! LocalLibraryComicItem) return;
    final path = comic.fileSystemPath ?? '';
    if (path.isEmpty) return;
    ArchivePasswordStore.instance.forget(path);
    comic.markArchiveLocked();
    App.notifyLocalDataChanged();
    if (mounted) Navigator.of(context).maybePop();
  }
}

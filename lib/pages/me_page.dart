import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/app_runtime_mode.dart';
import 'package:picakeep/foundation/history.dart';
import 'package:picakeep/foundation/download.dart';
import 'package:picakeep/foundation/local_data_source.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/remote_library_data_source.dart';
import 'package:picakeep/foundation/service_data_source.dart';
import 'package:picakeep/tools/translations.dart';
import 'package:picakeep/tools/read_history_helper.dart';
import 'package:picakeep/foundation/image_favorites.dart';
import 'history_page.dart';
import 'image_favorites.dart';
import 'app_capabilities_page.dart';
import 'service_info_page.dart';
import 'tools.dart';
import 'download_page.dart';
import 'local_library_page.dart';

class MePage extends StatefulWidget {
  const MePage({super.key});

  @override
  State<MePage> createState() => _MePageState();
}

class _MePageCachedState {
  const _MePageCachedState({
    required this.downloadCount,
    required this.localLibraryCount,
    required this.imageFavoriteCount,
    required this.historyItems,
    required this.historyLoaded,
    required this.localLibraryCountLoaded,
    required this.remoteSummaryResolved,
    required this.remoteSnapshot,
  });

  final int? downloadCount;
  final int? localLibraryCount;
  final int? imageFavoriteCount;
  final List<History> historyItems;
  final bool historyLoaded;
  final bool localLibraryCountLoaded;
  final bool remoteSummaryResolved;
  final ServiceInfoSnapshot? remoteSnapshot;
}

class _MePageState extends State<MePage> {
  static const Duration _historyLoadDelay = Duration.zero;
  static const Duration _historyCoverRevealDelay =
      kDebugMode ? Duration(milliseconds: 420) : Duration.zero;
  static const Duration _downloadCountLoadDelay = Duration(milliseconds: 900);
  static const Duration _localLibraryLoadDelay = Duration(milliseconds: 1500);
  static const Duration _imageFavoriteLoadDelay = Duration(milliseconds: 2100);
  static const Duration _remoteSummaryLoadDelay = Duration(milliseconds: 3200);

  static _MePageCachedState? _cachedState;

  int? _downloadCount;
  int? _localLibraryCount;
  int? _imageFavoriteCount;
  List<History> _historyItems = const <History>[];
  bool _historyLoaded = false;
  bool _loadingDownloadCount = false;
  bool _localLibraryCountLoaded = false;
  bool _loadingRemoteSummary = false;
  bool _remoteSummaryResolved = false;
  bool _historyCoversVisible = false;
  ServiceInfoSnapshot? _remoteSnapshot;

  Timer? _historyLoadTimer;
  Timer? _historyCoverRevealTimer;
  Timer? _downloadCountLoadTimer;
  Timer? _localLibraryLoadTimer;
  Timer? _imageFavoriteLoadTimer;
  Timer? _remoteSummaryLoadTimer;

  @override
  void initState() {
    super.initState();
    AppStartupTrace.log('MePage.initState');
    _restoreCachedState();
    StateController.putSimpleController(() {
      if (!mounted) {
        return;
      }
      setState(() {});
      _scheduleProgressiveLoads(forceRefresh: true);
    }, "me_page");
    App.localDataVersion.addListener(_handleLocalDataChanged);
    App.serviceConfigVersion.addListener(_handleServiceStateChanged);
    App.serviceRuntimeVersion.addListener(_handleServiceStateChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppStartupTrace.log('MePage.firstPostFrame');
      if (!mounted) {
        return;
      }
      _scheduleHistoryCoverReveal();
      _scheduleProgressiveLoads();
    });
  }

  @override
  void dispose() {
    _cacheCurrentState();
    _cancelScheduledLoads();
    App.localDataVersion.removeListener(_handleLocalDataChanged);
    App.serviceConfigVersion.removeListener(_handleServiceStateChanged);
    App.serviceRuntimeVersion.removeListener(_handleServiceStateChanged);
    StateController.remove<SimpleController>("me_page");
    super.dispose();
  }

  void _restoreCachedState() {
    final cached = _cachedState;
    if (cached == null) {
      return;
    }
    _downloadCount = cached.downloadCount;
    _localLibraryCount = cached.localLibraryCount;
    _imageFavoriteCount = cached.imageFavoriteCount;
    _historyItems = List<History>.of(cached.historyItems);
    _historyLoaded = cached.historyLoaded;
    _localLibraryCountLoaded = cached.localLibraryCountLoaded;
    _remoteSummaryResolved = cached.remoteSummaryResolved;
    _remoteSnapshot = cached.remoteSnapshot;
  }

  void _cacheCurrentState() {
    _cachedState = _MePageCachedState(
      downloadCount: _downloadCount,
      localLibraryCount: _localLibraryCount,
      imageFavoriteCount: _imageFavoriteCount,
      historyItems: List<History>.of(_historyItems),
      historyLoaded: _historyLoaded,
      localLibraryCountLoaded: _localLibraryCountLoaded,
      remoteSummaryResolved: _remoteSummaryResolved,
      remoteSnapshot: _remoteSnapshot,
    );
  }

  void _cancelProgressiveLoadTimers() {
    _historyLoadTimer?.cancel();
    _downloadCountLoadTimer?.cancel();
    _localLibraryLoadTimer?.cancel();
    _imageFavoriteLoadTimer?.cancel();
    _remoteSummaryLoadTimer?.cancel();
  }

  void _cancelScheduledLoads() {
    _cancelProgressiveLoadTimers();
    _historyCoverRevealTimer?.cancel();
  }

  void _scheduleHistoryCoverReveal() {
    if (_historyCoversVisible) {
      return;
    }
    _historyCoverRevealTimer?.cancel();
    _historyCoverRevealTimer = Timer(_historyCoverRevealDelay, () {
      if (!mounted || _historyCoversVisible) {
        return;
      }
      setState(() {
        _historyCoversVisible = true;
      });
    });
  }

  void _scheduleProgressiveLoads({bool forceRefresh = false}) {
    _cancelProgressiveLoadTimers();
    if (forceRefresh || !_historyLoaded) {
      _historyLoadTimer = Timer(
        _historyLoadDelay,
        _loadHistoryPreview,
      );
    }
    if (forceRefresh || _downloadCount == null) {
      _downloadCountLoadTimer = Timer(
        _downloadCountLoadDelay,
        () => _loadDownloadCount(forceRefresh: forceRefresh),
      );
    }
    if (forceRefresh || !_localLibraryCountLoaded) {
      _localLibraryLoadTimer = Timer(
        _localLibraryLoadDelay,
        () => _loadLocalLibraryCount(forceRefresh: forceRefresh),
      );
    }
    if (forceRefresh || _imageFavoriteCount == null) {
      _imageFavoriteLoadTimer = Timer(
        _imageFavoriteLoadDelay,
        _loadImageFavoriteCount,
      );
    }
    if (forceRefresh || !_remoteSummaryResolved) {
      _remoteSummaryLoadTimer = Timer(
        _remoteSummaryLoadDelay,
        _loadRemoteLibrarySummary,
      );
    }
  }

  void _handleLocalDataChanged() {
    _scheduleProgressiveLoads(forceRefresh: true);
  }

  void _handleServiceStateChanged() {
    _remoteSummaryLoadTimer?.cancel();
    _remoteSummaryLoadTimer = Timer(
      const Duration(milliseconds: 900),
      _loadRemoteLibrarySummary,
    );
  }

  Future<void> _loadHistoryPreview() async {
    try {
      final manager = HistoryManager();
      if (!manager.isInitialized) {
        await manager.init();
      }
      final history = manager.getRecent();
      if (!mounted) {
        return;
      }
      setState(() {
        _historyItems = history;
        _historyLoaded = true;
      });
      _cacheCurrentState();
    } catch (e) {
      print('[PicaKeep] MePage: load history preview failed: $e');
      if (mounted && !_historyLoaded) {
        setState(() {
          _historyLoaded = true;
          _historyItems = const <History>[];
        });
        _cacheCurrentState();
      }
    }
  }

  Future<int> _resolveDownloadCount({required bool forceRefresh}) async {
    final mode = normalizeManagedDataSourceMode(
      appdata.settings[managedDataSourceModeSettingIndex],
    );
    if (mode == managedDataSourceModeCurrentOnly) {
      final manager = DownloadManager();
      await manager.init();
      return manager.getAll().length;
    }

    if (forceRefresh) {
      await LocalLibraryManager().refresh();
    } else {
      await LocalLibraryManager().ensureLoaded();
    }
    final items = await LocalLibraryManager().getAll();
    return items.where((item) => !item.isAlbum).length;
  }

  Future<void> _loadDownloadCount({bool forceRefresh = false}) async {
    if (_loadingDownloadCount) {
      return;
    }
    _loadingDownloadCount = true;
    try {
      final total = await _resolveDownloadCount(forceRefresh: forceRefresh);
      if (mounted) {
        setState(() {
          _downloadCount = total;
        });
        _cacheCurrentState();
      }
    } catch (e) {
      print('[PicaKeep] MePage: load download count failed: $e');
    } finally {
      _loadingDownloadCount = false;
    }
  }

  Future<void> _loadLocalLibraryCount({bool forceRefresh = false}) async {
    try {
      if (forceRefresh) {
        await LocalLibraryManager().refresh();
      } else {
        await LocalLibraryManager().ensureLoaded();
      }
      if (mounted) {
        setState(() {
          _localLibraryCount = LocalLibraryManager().cachedAlbumCount;
          _localLibraryCountLoaded = true;
        });
        _cacheCurrentState();
      }
    } catch (e) {
      print('[PicaKeep] MePage: load local library count failed: $e');
      if (mounted && !_localLibraryCountLoaded) {
        setState(() {
          _localLibraryCount = 0;
          _localLibraryCountLoaded = true;
        });
        _cacheCurrentState();
      }
    }
  }

  Future<void> _loadImageFavoriteCount() async {
    try {
      final total = ImageFavoriteManager.length;
      if (mounted) {
        setState(() {
          _imageFavoriteCount = total;
        });
        _cacheCurrentState();
      }
    } catch (e) {
      if (e.toString().contains('LateInitializationError')) {
        _imageFavoriteLoadTimer?.cancel();
        _imageFavoriteLoadTimer = Timer(
          const Duration(milliseconds: 420),
          _loadImageFavoriteCount,
        );
        return;
      }
      print('[PicaKeep] MePage: load image favorite count failed: $e');
      if (mounted && _imageFavoriteCount == null) {
        setState(() {
          _imageFavoriteCount = 0;
        });
        _cacheCurrentState();
      }
    }
  }

  Future<void> _loadRemoteLibrarySummary() async {
    if (_loadingRemoteSummary) {
      return;
    }
    _loadingRemoteSummary = true;
    try {
      final mode =
          normalizeAppRuntimeMode(appdata.settings[appRuntimeModeSettingIndex]);
      if (mode != appRuntimeModeClient) {
        if (mounted) {
          setState(() {
            _remoteSnapshot = null;
            _remoteSummaryResolved = true;
          });
          _cacheCurrentState();
        }
        return;
      }
      final snapshot =
          await RuntimeServiceDataSourceResolver.current().fetchSnapshot();
      if (!mounted) {
        return;
      }
      setState(() {
        _remoteSnapshot = snapshot.isClientMode &&
                snapshot.connectionState == ServiceConnectionState.online
            ? snapshot
            : null;
        _remoteSummaryResolved = true;
      });
      _cacheCurrentState();
    } catch (e) {
      print('[PicaKeep] MePage: load remote library summary failed: $e');
      if (mounted) {
        setState(() {
          _remoteSnapshot = null;
          _remoteSummaryResolved = true;
        });
        _cacheCurrentState();
      }
    } finally {
      _loadingRemoteSummary = false;
    }
  }

  bool get _showRemoteLibraryEntry =>
      _remoteSnapshot?.connectionState == ServiceConnectionState.online;

  int get _remoteComicCount => _remoteSnapshot?.comicCount ?? 0;

  Future<void> _openLocalLibraryPage(BuildContext context) {
    return Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => const LocalLibraryPage(
              albumOnly: true,
              title: '图集',
            ),
          ),
        )
        .then((_) => _loadLocalLibraryCount());
  }

  Future<void> _openRemoteLibraryPage(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const LocalLibraryPage(
          preferRemoteView: true,
          title: '远程 · 资源库',
        ),
      ),
    );
  }

  Future<void> _openToolsPage(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ToolsPage()),
    );
  }

  Future<void> _openServiceInfoPage(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const ServiceInfoPage(standalone: true),
      ),
    );
  }

  Future<void> _openAppCapabilitiesPage(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const AppCapabilitiesPage()),
    );
  }

  String _historyTitle(int recentCount) {
    if (!_historyLoaded) {
      return "历史记录".tl;
    }
    return "${"历史记录".tl}($recentCount)";
  }

  Widget _historyPlaceholder(BuildContext context) {
    return Center(
      child: Icon(
        Icons.auto_stories,
        size: 32,
        color: Theme.of(context).colorScheme.onSecondaryContainer,
      ),
    );
  }

  Widget _buildCardDescriptionText(String text) {
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _buildCardLoadingIndicator(BuildContext context) {
    if (!kDebugMode) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          const SizedBox(width: 8),
          Text('加载中'.tl),
        ],
      );
    }
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.schedule_outlined,
          size: 16,
          color: color,
        ),
        const SizedBox(width: 6),
        Text(
          '稍后加载'.tl,
          style: TextStyle(color: color),
        ),
      ],
    );
  }

  Widget _buildHistoryLoadingStrip(BuildContext context) {
    final color = Theme.of(context).colorScheme.secondaryContainer;
    return ListView.builder(
      scrollDirection: Axis.horizontal,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      itemCount: 4,
      itemBuilder: (context, index) {
        if (!kDebugMode) {
          return Container(
            width: 96,
            height: 128,
            margin: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: color,
            ),
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Theme.of(context).colorScheme.onSecondaryContainer,
                ),
              ),
            ),
          );
        }
        return Container(
          width: 96,
          height: 128,
          margin: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: color,
          ),
          child: Icon(
            Icons.auto_stories,
            size: 22,
            color: Theme.of(context).colorScheme.onSecondaryContainer,
          ),
        );
      },
    );
  }

  Widget _buildEmptyHistoryPreview(BuildContext context) {
    return Center(
      child: Text(
        '暂无历史记录'.tl,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  File _coverFile(History item) {
    final cover = item.cover.trim();
    if (cover.isNotEmpty && (cover.startsWith('/') || cover.contains(':\\'))) {
      return File(cover);
    }
    try {
      final file =
          DownloadManager().getCoverFromCandidates(item.candidateDownloadIds());
      if (file.existsSync()) {
        return file;
      }
    } catch (_) {}
    final localComic = LocalLibraryManager()
        .findCachedByCandidates(item.candidateDownloadIds());
    if (localComic != null) {
      final coverPath = resolveLocalComicCoverPath(
        localComic,
        legacyTargets: item.candidateDownloadIds(),
      );
      if (coverPath.isNotEmpty) {
        return File(coverPath);
      }
    }
    return File('');
  }

  ImageProvider<Object>? _coverImageProvider(History item) {
    final cover = item.cover.trim();
    if (cover.startsWith('http://') || cover.startsWith('https://')) {
      return NetworkImage(cover);
    }
    if (cover.isNotEmpty && (cover.startsWith('/') || cover.contains(':\\'))) {
      return LocalLibraryManager().imageProviderForLocalPath(cover);
    }
    final localComic = LocalLibraryManager()
        .findCachedByCandidates(item.candidateDownloadIds());
    if (localComic != null) {
      final coverPath = resolveLocalComicCoverPath(
        localComic,
        legacyTargets: item.candidateDownloadIds(),
      );
      if (coverPath.isNotEmpty) {
        return LocalLibraryManager().imageProviderForLocalPath(coverPath);
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: LayoutBuilder(
        builder: (context, constrains) {
          final width = constrains.maxWidth;
          bool shouldShowTwoPanel = width > 600;
          return SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(
              children: [
                const SizedBox(height: 12),
                _buildHistoryCard(context),
                if (shouldShowTwoPanel)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          children: [
                            const SizedBox(height: 12),
                            _buildDownloadCard(context),
                            const SizedBox(height: 12),
                            _buildLibraryAccessSection(
                              context,
                              horizontal: true,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          children: [
                            const SizedBox(height: 12),
                            _buildImageFavoriteCard(context),
                            const SizedBox(height: 12),
                            _buildToolsCard(context),
                          ],
                        ),
                      ),
                    ],
                  )
                else ...[
                  const SizedBox(height: 12),
                  _buildDownloadCard(context),
                  const SizedBox(height: 12),
                  _buildLibraryAccessSection(
                    context,
                    horizontal: false,
                  ),
                  const SizedBox(height: 12),
                  _buildImageFavoriteCard(context),
                  const SizedBox(height: 12),
                  _buildToolsCard(context),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildHistoryCard(BuildContext context) {
    final history = _historyItems;
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const HistoryPage()),
      ),
      mouseCursor: SystemMouseCursors.click,
      borderRadius: BorderRadius.circular(12),
      child: Card.outlined(
        margin: EdgeInsets.zero,
        color: Colors.transparent,
        child: Container(
          margin: EdgeInsets.zero,
          width: double.infinity,
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.history),
                title: Text(_historyTitle(history.length)),
                trailing: const Icon(Icons.chevron_right),
                mouseCursor: SystemMouseCursors.click,
              ),
              SizedBox(
                height: 128,
                child: !_historyLoaded
                    ? _buildHistoryLoadingStrip(context)
                    : history.isEmpty
                        ? _buildEmptyHistoryPreview(context)
                        : ListView.builder(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            itemCount: history.length,
                            itemBuilder: (context, index) {
                              final item = history[index];
                              return InkWell(
                                onTap: () =>
                                    _openComicFromHistory(context, item),
                                borderRadius: BorderRadius.circular(8),
                                child: Container(
                                  width: 96,
                                  height: 128,
                                  margin: const EdgeInsets.symmetric(
                                      horizontal: 8),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(8),
                                    color: Theme.of(context)
                                        .colorScheme
                                        .secondaryContainer,
                                  ),
                                  clipBehavior: Clip.antiAlias,
                                  child: kDebugMode && !_historyCoversVisible
                                      ? _historyPlaceholder(context)
                                      : _buildCoverImage(context, item),
                                ),
                              );
                            },
                          ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCoverImage(BuildContext context, History item) {
    final imageProvider = _coverImageProvider(item);
    if (imageProvider != null) {
      return Image(
        image: imageProvider,
        width: 96,
        height: 128,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.medium,
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          if (wasSynchronouslyLoaded || frame != null) {
            return child;
          }
          return _historyPlaceholder(context);
        },
        errorBuilder: (context, error, stackTrace) {
          return _historyPlaceholder(context);
        },
      );
    }

    final cover = _coverFile(item);
    if (!cover.existsSync()) {
      return _historyPlaceholder(context);
    }
    return Image.file(
      cover,
      width: 96,
      height: 128,
      fit: BoxFit.cover,
      filterQuality: FilterQuality.medium,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded || frame != null) {
          return child;
        }
        return _historyPlaceholder(context);
      },
      errorBuilder: (context, error, stackTrace) {
        return _historyPlaceholder(context);
      },
    );
  }

  void _openComicFromHistory(BuildContext context, History history) async {
    try {
      final dm = DownloadManager();
      await dm.init();
      var comic =
          await dm.getComicOrNullFromCandidates(history.candidateDownloadIds());
      comic ??= await LocalLibraryManager()
          .findByCandidates(history.candidateDownloadIds());
      comic ??= await const RemoteLibraryDataSource()
          .findByCandidates(history.candidateDownloadIds());
      if (comic != null) {
        if (!context.mounted) return;
        await ensureHistoryBeforeRead(
          comic,
          legacyTargets: history.candidateDownloadIds(),
        );
        if (mounted) {
          setState(() {
            final cover = resolveLocalComicCover(
              comic!,
              legacyTargets: history.candidateDownloadIds(),
            );
            history.target = comic.id;
            history.title = comic.name;
            history.subtitle = comic.subTitle;
            if (cover.existsSync()) {
              history.cover = cover.path;
            }
          });
          _cacheCurrentState();
        }
        if (!context.mounted) return;
        await App.openReader(
          () => comic!.createReadingPage(ep: history.ep, page: history.page),
        );
      } else if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("未找到该漫画".tl)),
        );
      }
    } catch (e) {
      print('[PicaKeep] MePage: _openComicFromHistory failed: $e');
    }
  }

  Widget _buildDownloadCard(BuildContext context) {
    return _MePageCard(
      icon: const Icon(Icons.download_for_offline),
      title: "已下载".tl,
      description: _downloadCount == null
          ? _buildCardLoadingIndicator(context)
          : _buildCardDescriptionText(
              "共 @a 部漫画".tlParams({"a": _downloadCount.toString()}),
            ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const DownloadPage()),
      ),
    );
  }

  Widget _buildLocalLibraryCard(BuildContext context) {
    return _MePageCard(
      icon: const Icon(Icons.photo_library),
      title: '图集'.tl,
      description: !_localLibraryCountLoaded
          ? _buildCardLoadingIndicator(context)
          : _buildCardDescriptionText(
              '共 @a 个图集'.tlParams({'a': '${_localLibraryCount ?? 0}'}),
            ),
      onTap: () => _openLocalLibraryPage(context),
    );
  }

  Widget _buildRemoteLibraryCard(BuildContext context) {
    final available = _showRemoteLibraryEntry;
    final isLoading = !_remoteSummaryResolved;
    return _MePageCard(
      icon: Icon(
        available ? Icons.cloud_sync_outlined : Icons.cloud_off_outlined,
      ),
      title: '资源库'.tl,
      description: isLoading
          ? _buildCardLoadingIndicator(context)
          : _buildCardDescriptionText(
              available
                  ? '共 @a 个远程项目'.tlParams(
                      {'a': _remoteComicCount.toString()},
                    )
                  : '未连接远程服务'.tl,
            ),
      onTap: available ? () => _openRemoteLibraryPage(context) : null,
      isLoading: isLoading,
    );
  }

  Widget _buildLibraryAccessSection(
    BuildContext context, {
    required bool horizontal,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: _buildLocalLibraryCard(context)),
        const SizedBox(width: 12),
        Expanded(child: _buildRemoteLibraryCard(context)),
      ],
    );
  }

  Widget _buildImageFavoriteCard(BuildContext context) {
    return _MePageCard(
      icon: const Icon(Icons.image),
      title: "图片收藏".tl,
      description: _imageFavoriteCount == null
          ? _buildCardLoadingIndicator(context)
          : _buildCardDescriptionText(
              "@a 条图片收藏".tlParams({"a": "$_imageFavoriteCount"}),
            ),
      onTap: () => Navigator.of(context)
          .push(
        MaterialPageRoute(builder: (_) => const ImageFavoritesPage()),
      )
          .then((_) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) {
            return;
          }
          _loadImageFavoriteCount();
        });
      }),
    );
  }

  Widget _buildToolsCard(BuildContext context) {
    final quickActions = [
      _QuickToolAction(
        label: '服务信息'.tl,
        icon: Icons.router_outlined,
        onTap: () => _openServiceInfoPage(context),
      ),
      _QuickToolAction(
        label: '本地文件'.tl,
        icon: Icons.folder_open,
        onTap: () => _openToolsPage(context),
      ),
      _QuickToolAction(
        label: '图集'.tl,
        icon: Icons.photo_library,
        onTap: () => _openLocalLibraryPage(context),
      ),
      _QuickToolAction(
        label: 'APP能力'.tl,
        icon: Icons.cloud_sync_outlined,
        onTap: () => _openAppCapabilitiesPage(context),
      ),
    ];

    return Card.outlined(
      margin: EdgeInsets.zero,
      color: Colors.transparent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            leading: const Icon(Icons.build_circle),
            title: Text("工具".tl),
            subtitle: Text("使用工具发现更多漫画".tl),
            trailing: const Icon(Icons.chevron_right),
            mouseCursor: SystemMouseCursors.click,
            onTap: () => _openToolsPage(context),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                mouseCursor: SystemMouseCursors.click,
                onTap: () => _openToolsPage(context),
                child: SizedBox(
                  width: double.infinity,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: quickActions,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickToolAction extends StatelessWidget {
  const _QuickToolAction({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.secondaryContainer.withValues(alpha: 0.72),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 14,
                color: colorScheme.onSecondaryContainer,
              ),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSecondaryContainer,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MePageCard extends StatelessWidget {
  const _MePageCard({
    required this.icon,
    required this.title,
    required this.description,
    this.onTap,
    this.isLoading = false,
  });

  final Widget icon;
  final String title;
  final Widget description;
  final VoidCallback? onTap;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final visuallyEnabled = enabled || isLoading;
    return Opacity(
      opacity: visuallyEnabled ? 1 : 0.7,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Card.outlined(
          margin: EdgeInsets.zero,
          color: Colors.transparent,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ListTile(
                leading: icon,
                title: Text(title),
                trailing: Icon(
                  enabled
                      ? Icons.chevron_right
                      : isLoading
                          ? Icons.schedule
                          : Icons.remove,
                ),
                mouseCursor: enabled
                    ? SystemMouseCursors.click
                    : SystemMouseCursors.basic,
              ),
              Padding(
                padding: const EdgeInsets.only(left: 16, right: 16, bottom: 16, top: 8),
                child: SizedBox(
                  height: 20,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: description,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

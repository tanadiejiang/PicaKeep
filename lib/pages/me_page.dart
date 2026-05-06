import 'dart:io';
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

class _MePageState extends State<MePage> {
  int _downloadCount = 0;
  bool _loadingDownloadCount = false;
  bool _loadingRemoteSummary = false;
  ServiceInfoSnapshot? _remoteSnapshot;

  @override
  void initState() {
    super.initState();
    StateController.putSimpleController(() {
      if (mounted) {
        setState(() {});
        _loadDownloadCount();
        _loadLocalLibraryCount();
        _loadRemoteLibrarySummary();
      }
    }, "me_page");
    App.localDataVersion.addListener(_handleLocalDataChanged);
    App.serviceConfigVersion.addListener(_handleServiceStateChanged);
    App.serviceRuntimeVersion.addListener(_handleServiceStateChanged);
    _loadDownloadCount();
    _loadLocalLibraryCount();
    _loadRemoteLibrarySummary();
  }

  @override
  void dispose() {
    App.localDataVersion.removeListener(_handleLocalDataChanged);
    App.serviceConfigVersion.removeListener(_handleServiceStateChanged);
    App.serviceRuntimeVersion.removeListener(_handleServiceStateChanged);
    StateController.remove<SimpleController>("me_page");
    super.dispose();
  }

  void _handleLocalDataChanged() {
    _reloadLocalCounts();
  }

  void _handleServiceStateChanged() {
    _loadRemoteLibrarySummary();
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

  Future<void> _reloadLocalCounts() async {
    if (_loadingDownloadCount) {
      return;
    }
    _loadingDownloadCount = true;
    try {
      final total = await _resolveDownloadCount(forceRefresh: true);
      if (mounted) {
        setState(() {
          _downloadCount = total;
        });
      }
    } catch (e) {
      print('[PicaKeep] MePage: reload download count failed: $e');
    } finally {
      _loadingDownloadCount = false;
    }
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
        await _reloadLocalCounts();
      } else {
        await LocalLibraryManager().ensureLoaded();
      }
      if (mounted) {
        setState(() {});
      }
    } catch (_) {}
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
          });
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
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _remoteSnapshot = null;
        });
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
    try {
      return "${"历史记录".tl}(${HistoryManager().count()})";
    } catch (_) {
      return "${"历史记录".tl}($recentCount)";
    }
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

  File _coverFile(History item) {
    final cover = item.cover.trim();
    if (cover.isNotEmpty && (cover.startsWith('/') || cover.contains(':\\'))) {
      final file = File(cover);
      if (file.existsSync()) {
        return file;
      }
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
      final file = resolveLocalComicCover(
        localComic,
        legacyTargets: item.candidateDownloadIds(),
      );
      if (file.existsSync()) {
        return file;
      }
    }
    return File('');
  }

  ImageProvider<Object>? _coverImageProvider(History item) {
    final cover = item.cover.trim();
    if (cover.startsWith('http://') || cover.startsWith('https://')) {
      return NetworkImage(cover);
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
    List<History> history = [];
    try {
      history = HistoryManager().getRecent();
    } catch (e) {
      print('[PicaKeep] MePage: HistoryManager.getRecent() failed: $e');
    }
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
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  itemCount: history.length,
                  itemBuilder: (context, index) {
                    return InkWell(
                      onTap: () =>
                          _openComicFromHistory(context, history[index]),
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        width: 96,
                        height: 128,
                        margin: const EdgeInsets.symmetric(horizontal: 8),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          color:
                              Theme.of(context).colorScheme.secondaryContainer,
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: _buildCoverImage(context, history[index]),
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
      description: "共 @a 部漫画".tlParams({"a": _downloadCount.toString()}),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const DownloadPage()),
      ),
    );
  }

  Widget _buildLocalLibraryCard(BuildContext context) {
    final total = LocalLibraryManager().cachedAlbumCount;
    return _MePageCard(
      icon: const Icon(Icons.photo_library),
      title: '图集'.tl,
      description: '共 @a 个图集'.tlParams({'a': total.toString()}),
      onTap: () => _openLocalLibraryPage(context),
    );
  }

  Widget _buildRemoteLibraryCard(BuildContext context) {
    final available = _showRemoteLibraryEntry;
    return _MePageCard(
      icon: Icon(
        available ? Icons.cloud_sync_outlined : Icons.cloud_off_outlined,
      ),
      title: '远程 · 资源库'.tl,
      description: available
          ? '共 @a 个远程项目'.tlParams({'a': _remoteComicCount.toString()})
          : '未连接远程服务'.tl,
      onTap: available ? () => _openRemoteLibraryPage(context) : null,
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
      description: "@a 条图片收藏".tlParams({"a": "${ImageFavoriteManager.length}"}),
      onTap: () => Navigator.of(context)
          .push(
        MaterialPageRoute(builder: (_) => const ImageFavoritesPage()),
      )
          .then((_) {
        // Defer setState until after the route transition completes, so the
        // widget tree is fully restored and the count reflects DB changes.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() {});
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
  });

  final Widget icon;
  final String title;
  final String description;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Opacity(
      opacity: enabled ? 1 : 0.7,
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
                  enabled ? Icons.chevron_right : Icons.remove,
                ),
                mouseCursor: enabled
                    ? SystemMouseCursors.click
                    : SystemMouseCursors.basic,
              ),
              Padding(
                padding: const EdgeInsets.only(left: 16, bottom: 16, top: 8),
                child: Text(description),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

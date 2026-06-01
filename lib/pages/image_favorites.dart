import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/components/layout.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/app_runtime_mode.dart';
import 'package:picakeep/foundation/image_favorites.dart';
import 'package:picakeep/foundation/download.dart';
import 'package:picakeep/foundation/local_library_settings.dart';
import 'package:picakeep/foundation/remote_library_data_source.dart';
import 'package:picakeep/foundation/service_data_source.dart';
import 'package:picakeep/pages/reader/comic_reading_page.dart'
    show ComicReadingPage, LocalReadingData;
import 'package:picakeep/tools/translations.dart';

enum _ImageFavoritesView { local, remote }

String _imageFavoritesViewLabel(_ImageFavoritesView view) {
  switch (view) {
    case _ImageFavoritesView.local:
      return '本地';
    case _ImageFavoritesView.remote:
      return '远程';
  }
}

_ImageFavoritesView _imageFavoritesViewFromSetting(String value) {
  return normalizeTwoWayLibraryView(value) == 'remote'
      ? _ImageFavoritesView.remote
      : _ImageFavoritesView.local;
}

String _imageFavoritesViewToSetting(_ImageFavoritesView view) {
  return view == _ImageFavoritesView.remote ? 'remote' : 'local';
}

class ImageFavoritesPage extends StatefulWidget {
  const ImageFavoritesPage({super.key});

  @override
  State<ImageFavoritesPage> createState() => _ImageFavoritesPageState();
}

class _ImageFavoritesPageState extends State<ImageFavoritesPage> {
  final RemoteLibraryClient? _remoteClient =
      RemoteLibraryClient.tryFromCurrentSettings();
  _ImageFavoritesView _view = _imageFavoritesViewFromSetting(
    appdata.settings[imageFavoritesLibraryViewSettingIndex],
  );
  bool _loadingRemote = false;
  String? _remoteError;
  List<RemoteImageFavorite> _remoteImages = const <RemoteImageFavorite>[];

  @override
  void initState() {
    super.initState();
    App.serviceConfigVersion.addListener(_reloadRemoteState);
    App.serviceRuntimeVersion.addListener(_reloadRemoteState);
    if (_view == _ImageFavoritesView.remote) {
      _reloadRemoteState();
    }
  }

  @override
  void dispose() {
    App.serviceConfigVersion.removeListener(_reloadRemoteState);
    App.serviceRuntimeVersion.removeListener(_reloadRemoteState);
    super.dispose();
  }

  void _reloadRemoteState() {
    if (_view == _ImageFavoritesView.remote) {
      unawaited(_loadRemoteImages());
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

  Future<void> _setView(_ImageFavoritesView nextView) async {
    if (_view == nextView) {
      return;
    }
    setState(() {
      _view = nextView;
    });
    appdata.settings[imageFavoritesLibraryViewSettingIndex] =
        _imageFavoritesViewToSetting(nextView);
    await appdata.updateSettings();
    if (nextView == _ImageFavoritesView.remote) {
      await _loadRemoteImages();
    }
  }

  Future<void> _loadRemoteImages() async {
    setState(() {
      _loadingRemote = true;
      _remoteError = null;
    });
    final remoteAvailable = await _checkRemoteAvailability();
    if (!remoteAvailable) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loadingRemote = false;
        _remoteImages = const <RemoteImageFavorite>[];
        _remoteError = '远程加载失败'.tl;
      });
      return;
    }
    try {
      final images = await _remoteClient?.fetchImageFavorites() ??
          const <RemoteImageFavorite>[];
      if (!mounted) {
        return;
      }
      setState(() {
        _loadingRemote = false;
        _remoteImages = images;
        _remoteError = null;
      });
    } on RemoteLibraryRequestException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loadingRemote = false;
        _remoteImages = const <RemoteImageFavorite>[];
        _remoteError = e.statusCode == 404 ? '服务端不支持'.tl : '远程加载失败'.tl;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loadingRemote = false;
        _remoteImages = const <RemoteImageFavorite>[];
        _remoteError = '远程加载失败'.tl;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return StateBuilder(
      tag: "image_favorites_page",
      init: SimpleController(),
      builder: (controller) {
        final localImages = ImageFavoriteManager.getAll();
        final useRemote = _view == _ImageFavoritesView.remote;
        final isEmpty = useRemote ? _remoteImages.isEmpty : localImages.isEmpty;

        return Scaffold(
          appBar: AppBar(
            title: Text('图片收藏'.tl),
            actions: [
              if (useRemote)
                IconButton(
                  onPressed: _loadRemoteImages,
                  icon: const Icon(Icons.refresh),
                ),
            ],
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(52),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: SegmentedButton<_ImageFavoritesView>(
                    showSelectedIcon: false,
                    segments: [
                      for (final view in _ImageFavoritesView.values)
                        ButtonSegment<_ImageFavoritesView>(
                          value: view,
                          label: Text(_imageFavoritesViewLabel(view).tl),
                        ),
                    ],
                    selected: {_view},
                    onSelectionChanged: (selection) {
                      if (selection.isEmpty) {
                        return;
                      }
                      unawaited(_setView(selection.first));
                    },
                  ),
                ),
              ),
            ),
          ),
          body: _loadingRemote && useRemote
              ? const Center(child: CircularProgressIndicator())
              : _remoteError != null && useRemote
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.cloud_off_outlined,
                              size: 64, color: Colors.grey),
                          const SizedBox(height: 16),
                          Text(_remoteError!),
                          const SizedBox(height: 16),
                          FilledButton.icon(
                            onPressed: _loadRemoteImages,
                            icon: const Icon(Icons.refresh),
                            label: Text('重新加载'.tl),
                          ),
                        ],
                      ),
                    )
                  : isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.image_not_supported_outlined,
                                  size: 64, color: Colors.grey),
                              const SizedBox(height: 16),
                              Text(
                                '暂无图片收藏'.tl,
                                style: const TextStyle(
                                    fontSize: 16, color: Colors.grey),
                              ),
                            ],
                          ),
                        )
                      : GridView.builder(
                          padding: const EdgeInsets.all(4),
                          gridDelegate: SliverGridDelegateWithComics(
                              true, appdata.settings[74]),
                          itemCount: useRemote
                              ? _remoteImages.length
                              : localImages.length,
                          itemBuilder: (context, index) {
                            if (useRemote) {
                              return _RemoteFavoriteImageTile(
                                _remoteImages[index],
                                _remoteClient,
                                () async {
                                  await _remoteClient
                                      ?.deleteRemoteImageFavorite(
                                          _remoteImages[index]);
                                  await _loadRemoteImages();
                                },
                              );
                            }
                            return _FavoriteImageTile(localImages[index], () {
                              ImageFavoriteManager.delete(localImages[index]);
                              controller.update();
                            });
                          },
                        ),
        );
      },
    );
  }
}

class _RemoteFavoriteImageTile extends StatelessWidget {
  const _RemoteFavoriteImageTile(this.image, this.client, this.onDelete);

  final RemoteImageFavorite image;
  final RemoteLibraryClient? client;
  final Future<void> Function() onDelete;

  static void _addCandidate(List<String> candidates, String value) {
    final candidate = value.trim();
    if (candidate.isNotEmpty && !candidates.contains(candidate)) {
      candidates.add(candidate);
    }
  }

  static void _addCandidateVariants(
    List<String> candidates,
    String value,
    String sourceKey,
  ) {
    final pending = <String>[value.trim()];
    final prefixes = <String>{
      if (sourceKey.isNotEmpty) '$sourceKey-',
      if (sourceKey.isNotEmpty) sourceKey,
      'nhentai',
      'hitomi',
      'jm',
      'Ht',
      'ht',
    };
    for (var i = 0; i < pending.length; i++) {
      final current = pending[i].trim();
      if (current.isEmpty) {
        continue;
      }
      _addCandidate(candidates, current);
      for (final prefix in prefixes) {
        if (!current.startsWith(prefix) || current.length <= prefix.length) {
          continue;
        }
        final suffix = current
            .substring(prefix.length)
            .replaceFirst(RegExp(r'^[-_]+'), '')
            .trim();
        if (suffix.isNotEmpty && !pending.contains(suffix)) {
          pending.add(suffix);
        }
      }
    }
  }

  List<String> _candidateIds({bool includeTitle = false}) {
    final candidates = <String>[];
    final downloadId = image.otherInfo['downloadId']?.toString() ?? '';
    final sourceKey = image.otherInfo['sourceKey']?.toString().trim() ?? '';

    _addCandidateVariants(candidates, image.id, sourceKey);
    _addCandidateVariants(candidates, downloadId, sourceKey);
    if (includeTitle) {
      _addCandidate(candidates, image.title);
    }

    return candidates;
  }

  Future<void> _onTap(BuildContext context) async {
    final remoteClient = client;
    if (remoteClient == null) {
      return;
    }
    RemoteLibraryComicItem? resolved;
    try {
      resolved = await remoteClient.findItemByCandidates(
        _candidateIds(),
        fetchDetail: true,
      );
      resolved ??= await remoteClient.findItemByCandidates(
        _candidateIds(includeTitle: true),
        fetchDetail: true,
      );
    } on RemoteLibraryDataSourceException catch (e) {
      // Surface the error to the user instead of letting it bubble up as an
      // unhandled exception (which silently leaves the user stuck with no
      // feedback). Without this catch, a single timeout reads as "tap does
      // nothing" because the navigation never happens.
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)),
        );
      }
      return;
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('打开失败：$e')),
        );
      }
      return;
    }
    final resolvedItem = resolved;
    if (resolvedItem == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('该漫画在服务端不可定位'.tl)),
        );
      }
      return;
    }
    App.pushInner(() => ComicReadingPage(
          RemoteLibraryReadingData(item: resolvedItem),
          image.page,
          resolvedItem.hasMultipleEpisodes ? image.ep : 0,
        ));
  }

  @override
  Widget build(BuildContext context) {
    final provider = (client == null || image.imageUrl.trim().isEmpty)
        ? null
        : client!.coverImageProviderForUrl(image.imageUrl);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        elevation: 1,
        child: Stack(
          children: [
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                clipBehavior: Clip.antiAlias,
                child: provider != null
                    ? Image(
                        image: provider,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        errorBuilder: (_, __, ___) =>
                            const Center(child: Icon(Icons.broken_image)),
                      )
                    : const Center(child: Icon(Icons.image_not_supported)),
              ),
            ),
            Positioned(
              top: 6,
              left: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'E${image.ep} P${image.page}',
                  style: const TextStyle(
                    fontSize: 10,
                    color: Colors.white,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.3),
                      Colors.black.withValues(alpha: 0.5),
                    ],
                  ),
                  borderRadius: const BorderRadius.only(
                    bottomLeft: Radius.circular(8),
                    bottomRight: Radius.circular(8),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
                  child: Text(
                    image.title.replaceAll("\n", ""),
                    style: const TextStyle(
                      fontWeight: FontWeight.w500,
                      fontSize: 12.0,
                      color: Colors.white,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => _onTap(context),
                  onLongPress: () {
                    showDialog(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('删除'),
                        content: const Text('要删除这个图片收藏吗？'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('取消'),
                          ),
                          TextButton(
                            onPressed: () async {
                              Navigator.pop(ctx);
                              await onDelete();
                            },
                            child: const Text('删除'),
                          ),
                        ],
                      ),
                    );
                  },
                  borderRadius: BorderRadius.circular(8),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FavoriteImageTile extends StatelessWidget {
  const _FavoriteImageTile(this.image, this.onDelete);

  final ImageFavorite image;
  final VoidCallback onDelete;

  Future<void> _onTap(BuildContext context) async {
    // Use stored info from otherInfo (set by tool_bar.dart when favoriting)
    final sourceKey = (image.otherInfo['sourceKey'] as String?) ?? '';
    final epsList = (image.otherInfo['eps'] as List?)?.cast<String>() ?? [];
    final eps = <String, String>{};
    for (var i = 0; i < epsList.length; i++) {
      eps[(i + 1).toString()] = epsList[i];
    }

    final data = LocalReadingData(
      title: image.title,
      id: image.id,
      downloadId: image.otherInfo['downloadId'] as String? ?? image.id,
      sourceKey: sourceKey,
      hasEp: eps.isNotEmpty,
      comicType: ComicType.other,
      eps: eps.isNotEmpty ? eps : null,
    );

    try {
      await DownloadManager().init();
    } catch (_) {}
    App.pushInner(() => ComicReadingPage(data, image.page, image.ep));
  }

  Widget _buildPlaceholder(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: Container(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            clipBehavior: Clip.antiAlias,
            child: const Center(child: Icon(Icons.image_not_supported)),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // Handle empty path gracefully (may come from old migration data)
    if (image.imagePath.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          elevation: 1,
          child: _buildPlaceholder(context),
        ),
      );
    }

    // Try stored path as-is (new format: full path from persistentCurrentImage).
    var file = File(image.imagePath);
    if (!file.existsSync()) {
      // Old format: bare filename without directory — prepend images dir.
      if (!image.imagePath.contains('/') && !image.imagePath.contains('\\')) {
        file = File("${App.dataPath}/images/${image.imagePath}");
      }
    }
    final hasImage = file.existsSync();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        elevation: 1,
        child: Stack(
          children: [
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                clipBehavior: Clip.antiAlias,
                child: hasImage
                    ? Image.file(
                        file,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) =>
                            const Center(child: Icon(Icons.broken_image)),
                      )
                    : const Center(child: Icon(Icons.image_not_supported)),
              ),
            ),
            // Chapter/Page label at top-left corner
            Positioned(
              top: 6,
              left: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'E${image.ep} P${image.page}',
                  style: const TextStyle(
                    fontSize: 10,
                    color: Colors.white,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
            // Bottom title overlay
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.3),
                      Colors.black.withValues(alpha: 0.5),
                    ],
                  ),
                  borderRadius: const BorderRadius.only(
                    bottomLeft: Radius.circular(8),
                    bottomRight: Radius.circular(8),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
                  child: Text(
                    image.title.replaceAll("\n", ""),
                    style: const TextStyle(
                      fontWeight: FontWeight.w500,
                      fontSize: 12.0,
                      color: Colors.white,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => _onTap(context),
                  onLongPress: () {
                    showDialog(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('删除'),
                        content: const Text('要删除这个图片收藏吗？'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('取消'),
                          ),
                          TextButton(
                            onPressed: () {
                              onDelete();
                              Navigator.pop(ctx);
                            },
                            child: const Text('删除'),
                          ),
                        ],
                      ),
                    );
                  },
                  borderRadius: BorderRadius.circular(8),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

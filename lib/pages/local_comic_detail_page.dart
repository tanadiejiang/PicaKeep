import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/components/scrollable.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/download.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/local_library_settings.dart';
import 'package:picakeep/foundation/remote_library_data_source.dart';
import 'package:picakeep/foundation/trash.dart';
import 'package:picakeep/tools/read_history_helper.dart';
import 'package:picakeep/tools/tags_translation.dart';
import 'package:picakeep/tools/translations.dart';

import 'local_search_page.dart';

class LocalComicDetailPage extends StatefulWidget {
  final DownloadedItem comic;

  const LocalComicDetailPage({super.key, required this.comic});

  @override
  State<LocalComicDetailPage> createState() => _LocalComicDetailPageState();
}

class _LocalRecommendation {
  const _LocalRecommendation({
    required this.item,
    required this.score,
    required this.reason,
  });

  final DownloadedItem item;
  final double score;
  final String reason;
}

class _LocalComicDetailPageState extends State<LocalComicDetailPage> {
  final _scrollController = ScrollController();
  final _remoteDataSource = const RemoteLibraryDataSource();
  final List<DownloadedItem> _localItems = [];
  late DownloadedItem _comic;

  bool _reverseEpsOrder = false;
  bool _showFullEps = false;
  bool _showAppbarTitle = false;
  int _recommendationPage = 0;
  double _bottomPullDistance = 0;

  static const _recommendationPageSize = 10;

  @override
  void initState() {
    super.initState();
    _comic = widget.comic;
    _scrollController.addListener(_handleScroll);
    _loadRemoteDetailIfNeeded();
    _loadLocalItems();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_handleScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _handleScroll() {
    if (!_scrollController.hasClients) return;
    final showTitle = _scrollController.position.pixels > 136;
    if (showTitle != _showAppbarTitle) {
      setState(() {
        _showAppbarTitle = showTitle;
      });
    }
  }

  Future<void> _loadLocalItems() async {
    List<DownloadedItem> items;
    final current = _comic;
    if (current is RemoteLibraryComicItem) {
      try {
        final rootId = current.rootId.trim();
        items = rootId.isNotEmpty
            ? await _remoteDataSource.fetchItemsForRoot(rootId)
            : await _remoteDataSource.fetchItems();
      } catch (_) {
        items = const <DownloadedItem>[];
      }
    } else {
      items = await LocalLibraryManager().getAll();
    }
    if (!mounted) return;
    setState(() {
      _localItems
        ..clear()
        ..addAll(items);
    });
  }

  Future<void> _loadRemoteDetailIfNeeded() async {
    final current = _comic;
    if (current is! RemoteLibraryComicItem || current.hasUsableDetailPayload) {
      return;
    }
    try {
      final detail = await current.client.fetchItemDetail(current.id);
      if (!mounted) return;
      setState(() {
        _comic = detail;
      });
    } catch (_) {}
  }

  String get _sourceLabel {
    final label = _comic.sourceDisplayName.trim();
    if (label.isNotEmpty) return label.tl;
    return downloadTypeDisplayName(_comic.type).tl;
  }

  bool get _isAlbum {
    final comic = _comic;
    if (comic is LocalLibraryComicItem) return comic.isAlbum;
    return comic.sourceDisplayName == '图集';
  }

  bool get _canDeleteComic {
    final comic = _comic;
    if (comic is RemoteLibraryRootItem) {
      return false;
    }
    if (comic is RemoteLibraryComicItem) {
      return true;
    }
    if (comic is LocalLibraryComicItem) {
      return comic.fileSystemPath?.trim().isNotEmpty == true;
    }
    return comic.canDelete;
  }

  String _formatSize(double? size) {
    if (size == null) return '未知'.tl;
    if (size > 1024) return '${(size / 1024).toStringAsFixed(1)} GB';
    return '${size.toStringAsFixed(1)} MB';
  }

  String _formatTime(DateTime? time) {
    if (time == null) return '';
    return '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')} ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }

  String _translateTagIfNeeded(String tag) {
    if (App.locale.languageCode != 'zh') return tag;
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

  String _recommendationAuthor(DownloadedItem item) {
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
    } catch (_) {}
    return '';
  }

  List<String> _recommendationTags(DownloadedItem item) {
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
    } catch (_) {}
    return const <String>[];
  }

  List<String> _historyTargetsFor(DownloadedItem comic) {
    final targets = <String>{comic.id};
    try {
      final json = comic.toJson();
      for (final key in const [
        'comicId',
        'id',
        'itemId',
        'link',
        'favoriteTarget',
      ]) {
        final value = json[key]?.toString().trim();
        if (value != null && value.isNotEmpty) targets.add(value);
      }
    } catch (_) {}
    if (comic is LocalLibraryComicItem) {
      final originalId = comic.originalId.trim();
      if (originalId.isNotEmpty) targets.add(originalId);
      final favoriteTarget = comic.favoriteTarget?.trim();
      if (favoriteTarget != null && favoriteTarget.isNotEmpty) {
        targets.add(favoriteTarget);
      }
      for (final alias in comic.aliases) {
        final value = alias.trim();
        if (value.isNotEmpty) targets.add(value);
      }
    }
    return targets.toList();
  }

  dynamic _historyFor(DownloadedItem comic) {
    for (final target in _historyTargetsFor(comic)) {
      final history = appdata.history.find(target);
      if (history != null) return history;
    }
    return null;
  }

  Future<void> _onRead({int? ep, int? page}) async {
    await ensureHistoryBeforeRead(
      _comic,
      legacyTargets: _historyTargetsFor(_comic),
    );
    await App.openReader(
      () => _comic.createReadingPage(ep: ep, page: page),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _onDelete() async {
    if (!_canDeleteComic) {
      _showMessage('当前项目不支持在此删除'.tl);
      return;
    }
    final texts = buildDeleteActionTexts(
      itemName: _comic.name,
      itemLabel: _comic.sourceDisplayName == '图集' ? '图集' : '漫画',
    );
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(texts.title.tl),
        content: Text(texts.content.tl),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消'.tl),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(texts.confirmLabel.tl),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final result = await TrashManager.instance.deleteItem(_comic);
      if (!result.ok) {
        _showMessage(deleteFailureMessage(result.error).tl);
        return;
      }
      if (mounted) Navigator.of(context).pop();
    }
  }

  Future<void> _onDeleteEpisode(int ep) async {
    if (!_comic.canDelete) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除章节'.tl),
        content: Text('确定要删除"${_comic.eps[ep]}"吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消'.tl),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('删除'.tl),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final error = await DownloadManager().deleteEpisode(_comic, ep);
      if (error != null) _showMessage(error);
      if (mounted) setState(() {});
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void _copyText(String text) {
    Clipboard.setData(ClipboardData(text: text));
    _showMessage('已复制'.tl);
  }

  String? _getDescription() {
    try {
      final json = _comic.toJson();
      final candidates = [
        json['description'],
        json['comicItem'] is Map ? json['comicItem']['description'] : null,
        json['intro'],
        json['introduction'],
      ];
      for (final value in candidates) {
        final text = value?.toString().trim();
        if (text != null && text.isNotEmpty) return text;
      }
    } catch (_) {}
    return null;
  }

  String _displayIdFor(DownloadedItem comic) {
    final isAlbum = comic is LocalLibraryComicItem
        ? comic.isAlbum
        : comic.sourceDisplayName == '图集';
    if (isAlbum) {
      return comic.name;
    }
    if (comic is LocalLibraryComicItem) {
      final originalId = comic.originalId.trim();
      if (originalId.isNotEmpty) {
        return originalId;
      }
    }
    final json = comic.toJson();
    for (final key in const ['displayId', 'comicId', 'id', 'itemId']) {
      final value = json[key]?.toString().trim();
      if (value != null && value.isNotEmpty) {
        return value;
      }
    }
    final comicItem = json['comicItem'];
    if (comicItem is Map) {
      for (final key in const ['displayId', 'comicId', 'id']) {
        final value = comicItem[key]?.toString().trim();
        if (value != null && value.isNotEmpty) {
          return value;
        }
      }
    }
    return comic.id;
  }

  String? _displayPathFor(DownloadedItem comic) {
    String? fullPath;
    final fileSystemPath = comic.fileSystemPath?.trim();
    if (fileSystemPath != null && fileSystemPath.isNotEmpty) {
      fullPath = fileSystemPath;
    } else {
      final directory = comic.directory?.trim();
      if (directory != null && directory.isNotEmpty) {
        final rootPath =
            (DownloadManager().path ?? appdata.settings[22]).trim();
        fullPath = rootPath.isNotEmpty
            ? '$rootPath${Platform.pathSeparator}$directory'
            : directory;
      }
    }
    if (fullPath == null || fullPath.isEmpty) {
      return null;
    }

    final normalized = fullPath.replaceAll('\\', '/');
    final trimmed = normalized.endsWith('/') && normalized.length > 1
        ? normalized.substring(0, normalized.length - 1)
        : normalized;
    final lastSeparator = trimmed.lastIndexOf('/');
    if (lastSeparator <= 0) {
      return trimmed.replaceAll('/', Platform.pathSeparator);
    }
    return trimmed
        .substring(0, lastSeparator)
        .replaceAll('/', Platform.pathSeparator);
  }

  void _showNextRecommendationPage(int total) {
    if (total <= _recommendationPageSize) return;
    setState(() {
      final pages = (total / _recommendationPageSize).ceil();
      _recommendationPage = (_recommendationPage + 1) % pages;
    });
  }

  Map<String, List<String>> _buildInfoGroups() {
    final comic = _comic;
    final groups = <String, List<String>>{};

    void add(String key, Iterable<String?> values) {
      final normalized = values
          .whereType<String>()
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toSet()
          .toList();
      if (normalized.isNotEmpty) groups[key] = normalized;
    }

    add('ID', [_displayIdFor(comic)]);
    add('作者', [comic.subTitle]);
    add('漫画源', [comic.sourceDisplayName]);
    add('时间', [_formatTime(comic.time)]);
    add('路径', [_displayPathFor(comic)]);
    if (comic.tags.isNotEmpty) {
      groups['标签'] = comic.tags.map(_translateTagIfNeeded).toSet().toList();
    }
    return groups;
  }

  List<_LocalRecommendation> _buildRecommendations() {
    final mode = normalizeLocalDetailRecommendationMode(
      appdata.settings[localDetailRecommendationSettingIndex],
    );
    if (mode == '5') return const [];

    final current = _comic;
    final currentName = current.name;
    final currentAuthor = _recommendationAuthor(current).trim().toLowerCase();
    final currentTags = _recommendationTags(current)
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toSet();
    final currentTopics = _nameTopics(currentName);
    final albumOnly = _isAlbum;

    final recommendations = <_LocalRecommendation>[];
    for (final item in _localItems) {
      final sameId = item.id == current.id;
      final sameName = item.name == current.name;
      final sameLocalOriginalId = item is LocalLibraryComicItem &&
          (item.originalId == current.id || item.originalId == current.name);
      if (sameId || sameName || sameLocalOriginalId) {
        continue;
      }

      final nameScore = _nameSimilarity(currentName, item.name);
      final itemAuthor = _recommendationAuthor(item).trim().toLowerCase();
      final sameAuthor =
          currentAuthor.isNotEmpty && currentAuthor == itemAuthor;
      final itemTags = _recommendationTags(item)
          .map((e) => e.trim().toLowerCase())
          .where((e) => e.isNotEmpty)
          .toSet();
      final tagMatches = currentTags.intersection(itemTags).length;
      final topicMatches =
          currentTopics.intersection(_nameTopics(item.name)).length;
      final hasTopic = topicMatches > 0 || nameScore >= 0.36;

      double score;
      String reason;
      if (albumOnly) {
        score = nameScore * 1000;
        reason = '名称相似'.tl;
        if (score <= 0) continue;
      } else {
        final strongName = nameScore >= 0.62;
        final authorAndTopic = sameAuthor && hasTopic;
        final sameTopic = hasTopic;
        final hasTags = tagMatches > 0;

        switch (mode) {
          case '1':
            if (nameScore <= 0) continue;
            score = nameScore * 1000 + tagMatches * 20 + (sameAuthor ? 80 : 0);
            reason = '名称相似'.tl;
            break;
          case '2':
            if (!authorAndTopic) continue;
            score =
                3000 + topicMatches * 80 + nameScore * 300 + tagMatches * 20;
            reason = '同作者 + 同题材'.tl;
            break;
          case '3':
            if (!sameTopic) continue;
            score = 2000 + topicMatches * 90 + nameScore * 400;
            reason = '同题材'.tl;
            break;
          case '4':
            if (!hasTags) continue;
            score = 1000 +
                tagMatches * 120 +
                nameScore * 200 +
                (sameAuthor ? 60 : 0);
            reason = '同标签'.tl;
            break;
          case '0':
          default:
            if (strongName) {
              score = 4000 + nameScore * 1000 + tagMatches * 20;
              reason = '名称高度相似'.tl;
            } else if (authorAndTopic) {
              score =
                  3000 + topicMatches * 100 + nameScore * 400 + tagMatches * 20;
              reason = '同作者 + 同题材'.tl;
            } else if (sameTopic) {
              score = 2000 + topicMatches * 100 + nameScore * 400;
              reason = '同题材'.tl;
            } else if (hasTags) {
              score = 1000 + tagMatches * 120 + nameScore * 200;
              reason = '同标签'.tl;
            } else {
              continue;
            }
            break;
        }
      }

      recommendations
          .add(_LocalRecommendation(item: item, score: score, reason: reason));
    }

    recommendations.sort((a, b) {
      final score = b.score.compareTo(a.score);
      if (score != 0) return score;
      final at = a.item.time ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bt = b.item.time ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bt.compareTo(at);
    });
    return recommendations;
  }

  Set<String> _nameTopics(String value) {
    final normalized = value
        .toLowerCase()
        .replaceAll(RegExp(r'[\[\]【】()（）「」『』<>《》!！?？:：,，.。_\-]+'), ' ');
    final matches = RegExp(r'[a-z0-9]{3,}|[\u4e00-\u9fa5]{2,}|[ぁ-んァ-ンー]{2,}')
        .allMatches(normalized)
        .map((e) => e.group(0)!)
        .where((e) => e.length >= 2)
        .toSet();
    return matches;
  }

  double _nameSimilarity(String a, String b) {
    final left = _normalizeName(a);
    final right = _normalizeName(b);
    if (left.isEmpty || right.isEmpty) return 0;
    if (left == right) return 1;
    if (left.contains(right) || right.contains(left)) {
      final minLen = math.min(left.length, right.length);
      final maxLen = math.max(left.length, right.length);
      return 0.72 + (minLen / maxLen) * 0.18;
    }
    final leftBigrams = _bigrams(left);
    final rightBigrams = _bigrams(right);
    if (leftBigrams.isEmpty || rightBigrams.isEmpty) return 0;
    final intersection = leftBigrams.intersection(rightBigrams).length;
    return (2 * intersection) / (leftBigrams.length + rightBigrams.length);
  }

  String _normalizeName(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'\[[^\]]*\]|【[^】]*】|\([^)]*\)|（[^）]*）'), '')
        .replaceAll(RegExp(r'[^a-z0-9\u4e00-\u9fa5ぁ-んァ-ンー]+'), '');
  }

  Set<String> _bigrams(String value) {
    if (value.length < 2) return {value};
    return {
      for (int i = 0; i < value.length - 1; i++) value.substring(i, i + 2),
    };
  }

  bool _handleRecommendationOverscroll(
      OverscrollNotification notification, int total) {
    if (notification.dragDetails == null ||
        notification.overscroll <= 0 ||
        total <= _recommendationPageSize) {
      return false;
    }
    final metrics = notification.metrics;
    if (metrics.pixels < metrics.maxScrollExtent - 24) return false;
    _bottomPullDistance += notification.overscroll;
    if (_bottomPullDistance >= 120) {
      _showNextRecommendationPage(total);
      _bottomPullDistance = 0;
    }
    return false;
  }

  Future<void> _showRecommendationSettings() async {
    var mode = normalizeLocalDetailRecommendationMode(
      appdata.settings[localDetailRecommendationSettingIndex],
    );
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return Dialog(
              insetPadding:
                  const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18)),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
                        child: Row(
                          children: [
                            Text(
                              '相关推荐设置'.tl,
                              style: const TextStyle(
                                  fontSize: 18, fontWeight: FontWeight.w600),
                            ),
                            const Spacer(),
                            IconButton(
                              icon: const Icon(Icons.close),
                              onPressed: () => Navigator.pop(dialogContext),
                            ),
                          ],
                        ),
                      ),
                      for (final entry in const <MapEntry<String, String>>[
                        MapEntry('0', '智能推荐'),
                        MapEntry('1', '名称相似优先'),
                        MapEntry('2', '同作者 + 同题材'),
                        MapEntry('3', '同题材'),
                        MapEntry('4', '同标签最多'),
                        MapEntry('5', '不推荐'),
                      ])
                        ListTile(
                          leading: Icon(
                            mode == entry.key
                                ? Icons.radio_button_checked
                                : Icons.radio_button_unchecked,
                          ),
                          title: Text(entry.value.tl),
                          onTap: () async {
                            setDialogState(() => mode = entry.key);
                            appdata.settings[
                                    localDetailRecommendationSettingIndex] =
                                entry.key;
                            await appdata.updateSettings();
                            if (mounted) {
                              setState(() => _recommendationPage = 0);
                            }
                          },
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildCover(BuildContext context, double width, double height) {
    final legacyTargets = <String>{
      ..._historyTargetsFor(_comic),
      if (_comic is RemoteLibraryComicItem)
        ...(_comic as RemoteLibraryComicItem).candidateValues,
    };
    final cover = resolveLocalComicCover(
      _comic,
      legacyTargets: legacyTargets,
    );
    final coverProvider = _comic is RemoteLibraryComicItem
        ? (_comic as RemoteLibraryComicItem).coverImageProvider
        : _comic is RemoteLibraryRootItem
            ? (_comic as RemoteLibraryRootItem).coverImageProvider
            : null;
    final hasLocalCover = cover.existsSync();
    final heroTag = 'local-cover-${_comic.id}';
    return GestureDetector(
      onTap: hasLocalCover
          ? () => _showCoverPreviewFile(cover)
          : coverProvider != null
              ? () => _showCoverPreviewProvider(coverProvider)
              : null,
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        clipBehavior: Clip.antiAlias,
        child: hasLocalCover
            ? Hero(
                tag: heroTag,
                child: Image.file(
                  cover,
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.medium,
                  isAntiAlias: true,
                  errorBuilder: (_, __, ___) => _placeholderCover(),
                ),
              )
            : coverProvider != null
                ? Hero(
                    tag: heroTag,
                    child: Image(
                      image: coverProvider,
                      fit: BoxFit.cover,
                      filterQuality: FilterQuality.medium,
                      isAntiAlias: true,
                      errorBuilder: (_, __, ___) => _placeholderCover(),
                    ),
                  )
                : _placeholderCover(),
      ),
    );
  }

  Widget _placeholderCover() {
    return const Center(child: Icon(Icons.image_not_supported, size: 36));
  }

  void _showCoverPreviewFile(File cover) {
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: InteractiveViewer(
          child: Hero(
            tag: 'local-cover-${_comic.id}',
            child: Image.file(cover, fit: BoxFit.contain),
          ),
        ),
      ),
    );
  }

  void _showCoverPreviewProvider(ImageProvider<Object> coverProvider) {
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: InteractiveViewer(
          child: Hero(
            tag: 'local-cover-${_comic.id}',
            child: Image(
              image: coverProvider,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => _placeholderCover(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _sectionHeader(String title, {Widget? trailing}) {
    return SliverToBoxAdapter(
      child: Column(
        children: [
          const Divider(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Row(
              children: [
                Text(
                  title.tl,
                  style: const TextStyle(
                      fontWeight: FontWeight.w500, fontSize: 18),
                ),
                const Spacer(),
                if (trailing != null) trailing,
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showTextActionsAt(
    Offset position,
    String text, {
    String? searchAuthor,
    String? searchTag,
  }) async {
    if (text.trim().isEmpty) return;
    final overlay = Overlay.of(context).context.findRenderObject();
    if (overlay is! RenderBox) {
      return;
    }
    final localPosition = overlay.globalToLocal(position);
    final size = overlay.size;
    final dx = localPosition.dx.clamp(0.0, size.width);
    final dy = localPosition.dy.clamp(0.0, size.height);
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        dx,
        dy,
        size.width - dx,
        size.height - dy,
      ),
      items: [
        PopupMenuItem<String>(
          value: 'copy',
          child: Text('复制'.tl),
        ),
        if (searchAuthor != null && searchAuthor.trim().isNotEmpty)
          PopupMenuItem<String>(
            value: 'author',
            child: Text('推荐该作者'.tl),
          ),
        if (searchTag != null && searchTag.trim().isNotEmpty)
          PopupMenuItem<String>(
            value: 'tag',
            child: Text('推荐该标签'.tl),
          ),
      ],
    );
    if (!mounted || action == null) {
      return;
    }
    switch (action) {
      case 'copy':
        _copyText(text);
        break;
      case 'author':
        _openRecommendationSearch(searchAuthor!);
        break;
      case 'tag':
        _openRecommendationSearch(searchTag!);
        break;
    }
  }

  void _openRecommendationSearch(String keyword) {
    final normalized = keyword.trim();
    if (normalized.isEmpty) {
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LocalSearchPage(initialKeyword: normalized),
      ),
    );
  }

  Widget _infoCard(String text, {bool title = false, String? group}) {
    if (text.trim().isEmpty) text = '未知'.tl;
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(4, 4, 4, 4),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onLongPressStart: title
            ? null
            : (details) => _showTextActionsAt(
                  details.globalPosition,
                  text,
                  searchAuthor: group == '作者' ? text : null,
                  searchTag: group == '标签' ? text : null,
                ),
        onSecondaryTapDown: title
            ? null
            : (details) => _showTextActionsAt(
                  details.globalPosition,
                  text,
                  searchAuthor: group == '作者' ? text : null,
                  searchTag: group == '标签' ? text : null,
                ),
        child: Card(
          margin: EdgeInsets.zero,
          color: title
              ? colorScheme.primaryContainer.withAlpha(160)
              : ElevationOverlay.applySurfaceTint(
                  colorScheme.surface,
                  colorScheme.surfaceTint,
                  3,
                ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          elevation: 0,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
            child: Text(text, style: const TextStyle(fontSize: 13)),
          ),
        ),
      ),
    );
  }

  Widget _buildActionItem(String title, IconData icon, VoidCallback? onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: const BorderRadius.all(Radius.circular(8)),
      child: SizedBox(
        height: 72,
        width: 72,
        child: Column(
          children: [
            const SizedBox(height: 12),
            Icon(icon, size: 24, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 8),
            Text(title.tl, style: const TextStyle(fontSize: 12), maxLines: 1),
          ],
        ),
      ),
    );
  }

  Widget _recommendationTile(_LocalRecommendation recommendation) {
    final item = recommendation.item;
    final cover = resolveLocalComicCover(
      item,
      legacyTargets: _historyTargetsFor(item),
    );
    final coverProvider = item is RemoteLibraryComicItem
        ? item.coverImageProvider
        : item is RemoteLibraryRootItem
            ? item.coverImageProvider
            : null;
    final author = _recommendationAuthor(item);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => LocalComicDetailPage(comic: item)),
        );
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 18, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 76,
              height: 112,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              clipBehavior: Clip.antiAlias,
              child: cover.existsSync()
                  ? Image.file(cover, fit: BoxFit.cover)
                  : coverProvider != null
                      ? Image(
                          image: coverProvider,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) =>
                              const Icon(Icons.image_not_supported),
                        )
                      : const Icon(Icons.image_not_supported),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 4),
                  if (author.isNotEmpty)
                    Text(
                      author,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  const Spacer(),
                  Text(
                    _displayIdFor(item),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.outline),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    recommendation.reason,
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.primary),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final comic = _comic;
    final description = _getDescription();
    final history = _historyFor(comic);
    final infoGroups = _buildInfoGroups();
    final recommendations = _buildRecommendations();
    final start = recommendations.isEmpty
        ? 0
        : (_recommendationPage * _recommendationPageSize) %
            recommendations.length;
    final pageRecommendations =
        recommendations.skip(start).take(_recommendationPageSize).toList();

    return Scaffold(
      body: NotificationListener<OverscrollNotification>(
        onNotification: (notification) => _handleRecommendationOverscroll(
          notification,
          recommendations.length,
        ),
        child: SmoothCustomScrollView(
          controller: _scrollController,
          slivers: [
            SliverAppBar(
              pinned: true,
              title: AnimatedOpacity(
                opacity: _showAppbarTitle ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                child: Text(
                  comic.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              actions: [
                IconButton(
                  tooltip: '复制标题'.tl,
                  icon: const Icon(Icons.more_horiz),
                  onPressed: () => _copyText(comic.name),
                ),
              ],
            ),
            SliverToBoxAdapter(child: _buildComicInfo(context, history)),
            _sectionHeader('信息'),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final entry in infoGroups.entries)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Wrap(
                          children: [
                            _infoCard(entry.key.tl, title: true),
                            for (final value in entry.value)
                              _infoCard(value, group: entry.key),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            ..._buildEpisodes(context),
            ..._buildIntroduction(description),
            ..._buildRecommendationSlivers(
              pageRecommendations,
              recommendations.length,
            ),
            SliverPadding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).padding.bottom + 24,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildComicInfo(BuildContext context, dynamic history) {
    final comic = _comic;
    final canContinue = history != null && (history.ep > 0 || history.page > 0);
    return LayoutBuilder(builder: (context, constraints) {
      final compact = constraints.maxWidth < 500;
      final actions = Wrap(
        alignment: compact ? WrapAlignment.center : WrapAlignment.start,
        children: [
          if (canContinue)
            _buildActionItem('继续阅读', Icons.menu_book,
                () => _onRead(ep: history.ep, page: history.page)),
          _buildActionItem(
            '从头开始',
            Icons.not_started_outlined,
            () => _onRead(ep: comic.eps.length > 1 ? 1 : 0),
          ),
          _buildActionItem('分享', Icons.share, () => _copyText(comic.name)),
          if (_canDeleteComic)
            _buildActionItem('删除下载', Icons.delete_outline, _onDelete),
        ],
      );

      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildCover(context, 102, 136),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SelectableText(
                        comic.name.trim(),
                        style: const TextStyle(fontSize: 18),
                      ),
                      if (comic.subTitle.trim().isNotEmpty) ...[
                        const SizedBox(height: 8),
                        SelectableText(comic.subTitle,
                            style: const TextStyle(fontSize: 14)),
                      ],
                      const SizedBox(height: 8),
                      Text(_sourceLabel, style: const TextStyle(fontSize: 12)),
                      const SizedBox(height: 8),
                      Text(_formatSize(comic.comicSize),
                          style: const TextStyle(fontSize: 12)),
                      if (!compact)
                        Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: actions),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (compact)
            Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: actions),
        ],
      );
    });
  }

  List<Widget> _buildEpisodes(BuildContext context) {
    final comic = _comic;
    if (comic.eps.isEmpty) return const [];
    var length = comic.eps.length;
    if (!_showFullEps) length = math.min(length, 20);

    return [
      _sectionHeader(
        '章节  ·  共${comic.eps.length}章',
        trailing: Tooltip(
          message: '排序'.tl,
          child: IconButton(
            icon: const Icon(Icons.swap_vert),
            onPressed: () =>
                setState(() => _reverseEpsOrder = !_reverseEpsOrder),
          ),
        ),
      ),
      const SliverPadding(padding: EdgeInsets.all(6)),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        sliver: SliverGrid(
          delegate: SliverChildBuilderDelegate(
            childCount: length,
            (context, i) {
              final index = _reverseEpsOrder ? comic.eps.length - i - 1 : i;
              final isDownloaded =
                  comic.downloadedEps.contains(index) || !comic.canDelete;
              final readEp = comic.eps.length > 1 ? index + 1 : 0;
              return Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                child: InkWell(
                  borderRadius: const BorderRadius.all(Radius.circular(16)),
                  onTap: isDownloaded ? () => _onRead(ep: readEp) : null,
                  onLongPress: comic.canDelete && isDownloaded
                      ? () => _onDeleteEpisode(index)
                      : null,
                  child: Material(
                    elevation: 5,
                    color: Theme.of(context).colorScheme.surface,
                    surfaceTintColor: Theme.of(context).colorScheme.surfaceTint,
                    borderRadius: const BorderRadius.all(Radius.circular(12)),
                    shadowColor: Colors.transparent,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      child: Center(
                        child: Text(
                          comic.eps[index],
                          maxLines: 1,
                          textAlign: TextAlign.center,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: isDownloaded
                                ? null
                                : Theme.of(context).colorScheme.outline,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 200,
            mainAxisExtent: 48,
          ),
        ),
      ),
      if (comic.eps.length > 20 && !_showFullEps)
        SliverToBoxAdapter(
          child: Align(
            alignment: Alignment.center,
            child: FilledButton.tonal(
              style: ButtonStyle(
                shape: WidgetStateProperty.all(
                  const RoundedRectangleBorder(
                    borderRadius: BorderRadius.all(Radius.circular(8)),
                  ),
                ),
              ),
              onPressed: () => setState(() => _showFullEps = true),
              child: Text('${'显示全部'.tl} (${comic.eps.length})'),
            ),
          ),
        ),
    ];
  }

  List<Widget> _buildIntroduction(String? description) {
    if (description == null || description.isEmpty) return const [];
    return [
      const SliverPadding(padding: EdgeInsets.all(5)),
      _sectionHeader('简介'),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
          child: SelectableText(description),
        ),
      ),
      const SliverPadding(padding: EdgeInsets.all(5)),
    ];
  }

  List<Widget> _buildRecommendationSlivers(
    List<_LocalRecommendation> recommendations,
    int total,
  ) {
    if (normalizeLocalDetailRecommendationMode(
          appdata.settings[localDetailRecommendationSettingIndex],
        ) ==
        '5') {
      return const [];
    }
    if (recommendations.isEmpty) {
      return [
        _sectionHeader(
          '相关推荐',
          trailing: IconButton(
            tooltip: '设置'.tl,
            icon: const Icon(Icons.tune),
            onPressed: _showRecommendationSettings,
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
            child: Text(
              _comic is RemoteLibraryComicItem
                  ? '暂无可推荐的远程内容'.tl
                  : '暂无可推荐的本地漫画'.tl,
            ),
          ),
        ),
      ];
    }

    return [
      _sectionHeader(
        '相关推荐',
        trailing: IconButton(
          tooltip: '设置'.tl,
          icon: const Icon(Icons.tune),
          onPressed: _showRecommendationSettings,
        ),
      ),
      const SliverPadding(padding: EdgeInsets.all(5)),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        sliver: SliverGrid(
          delegate: SliverChildBuilderDelegate(
            childCount: recommendations.length,
            (context, index) => _recommendationTile(recommendations[index]),
          ),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 520,
            mainAxisExtent: 136,
          ),
        ),
      ),
      if (total > _recommendationPageSize)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: FilledButton.tonalIcon(
                onPressed: () => _showNextRecommendationPage(total),
                icon: const Icon(Icons.keyboard_double_arrow_up),
                label: Text('下一组推荐'.tl),
              ),
            ),
          ),
        ),
    ];
  }
}

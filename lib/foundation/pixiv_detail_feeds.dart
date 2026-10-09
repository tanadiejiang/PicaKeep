import 'package:flutter/foundation.dart';
import 'package:picakeep/network/pixiv_network/pixiv_models.dart';
import 'package:picakeep/network/res.dart';

typedef PixivWorkIdsLoader = Future<Res<List<String>>> Function(
    String authorId);
typedef PixivAuthorPreviewLoader = Future<Res<List<PixivComicBrief>>> Function(
    String authorId, List<String> ids);
typedef PixivRecommendationsLoader = Future<Res<PixivRecommendationsPage>>
    Function(String workId);
typedef PixivRecommendationWorksLoader = Future<Res<List<PixivComicBrief>>>
    Function(List<String> ids);

bool _validId(String id) =>
    RegExp(r'^[0-9]+$').hasMatch(id) && (int.tryParse(id) ?? 0) > 0;

/// A detail owns these reads. Late responses never update a replacement feed.
abstract class _OwnedPixivFeed extends ChangeNotifier {
  _OwnedPixivFeed({required this.ownerIsCurrent});
  final bool Function() ownerIsCurrent;
  bool _disposed = false;
  Future<void>? _pending;
  bool busy = false;
  String? error;
  bool get isCurrent => !_disposed && ownerIsCurrent();

  Future<void> run(Future<void> Function() operation) {
    if (!isCurrent) return Future.value();
    if (_pending case final pending?) return pending;
    busy = true;
    error = null;
    notifyListeners();
    return _pending = _perform(operation);
  }

  Future<void> _perform(Future<void> Function() operation) async {
    try {
      await operation();
    } catch (failure) {
      if (isCurrent) {
        error = failure
            .toString()
            .replaceFirst('Bad state: ', '')
            .replaceFirst('StateError: ', '');
      }
    } finally {
      busy = false;
      _pending = null;
      if (isCurrent) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// The bounded author strip is independent of the work recommendation queue.
class PixivAuthorPreviewController extends _OwnedPixivFeed {
  PixivAuthorPreviewController({
    required this.workId,
    required this.authorId,
    required Iterable<PixivComicBrief> seed,
    required this.loadIds,
    required this.loadWorks,
    required super.ownerIsCurrent,
    this.accepts,
    this.previewCount = 5,
  }) : assert(previewCount >= 1 && previewCount <= 30) {
    _append(seed);
  }

  final int previewCount;
  final String workId;
  final String authorId;
  final PixivWorkIdsLoader loadIds;
  final PixivAuthorPreviewLoader loadWorks;
  final bool Function(PixivComicBrief)? accepts;
  final _items = <PixivComicBrief>[];
  final _seen = <String>{};
  List<String>? _ids;
  int _cursor = 0;
  bool attempted = false;

  List<PixivComicBrief> get items => List.unmodifiable(_items);
  bool get hasMore =>
      _validId(authorId) &&
      _items.length < previewCount &&
      (_ids == null || _cursor < _ids!.length);

  void _append(Iterable<PixivComicBrief> incoming) {
    for (final item in incoming) {
      if (_items.length >= previewCount) break;
      if (!_validId(item.id) ||
          item.id == workId ||
          (item.authorId.isNotEmpty && item.authorId != authorId) ||
          !(accepts?.call(item) ?? true) ||
          !_seen.add(item.id)) {
        continue;
      }
      _items.add(item);
    }
  }

  Future<void> load() {
    if (!hasMore) return Future.value();
    return run(() async {
      attempted = true;
      if (_ids == null) {
        final result = await loadIds(authorId);
        if (!isCurrent) return;
        if (result.error) throw StateError(result.errorMessageWithoutNull);
        final seenIds = <String>{workId, ..._seen};
        _ids = [
          for (final id in result.data)
            if (_validId(id) && seenIds.add(id)) id,
        ];
      }
      // The configured preview is bounded to thirty cards, five IDs per read.
      // Filtered candidates get a finite budget, then an explicit continuation.
      final budget = ((previewCount + 4) ~/ 5).clamp(2, 6);
      for (var batch = 0; batch < budget && hasMore; batch++) {
        final ids = _ids!
            .skip(_cursor)
            .take((previewCount - _items.length).clamp(1, 5))
            .toList(growable: false);
        final result = await loadWorks(authorId, ids);
        if (!isCurrent) return;
        if (result.error) throw StateError(result.errorMessageWithoutNull);
        final byId = {for (final item in result.data) item.id: item};
        _append(ids.map((id) => byId[id]).whereType<PixivComicBrief>());
        _cursor += ids.length;
      }
    });
  }
}

/// Server-ordered recommendations. Null batch size displays the full response;
/// explicit counts retain their local reveal limit. New rounds are user-owned.
class PixivWorkRecommendationsController extends _OwnedPixivFeed {
  PixivWorkRecommendationsController({
    required this.workId,
    required this.loadInitial,
    required this.loadWorks,
    required super.ownerIsCurrent,
    this.accepts,
    this.batchSize,
  }) : assert(batchSize == null || (batchSize >= 1 && batchSize <= 18));

  static const int _transportBatchSize = 18;
  final int? batchSize;
  final String workId;
  final PixivRecommendationsLoader loadInitial;
  final PixivRecommendationWorksLoader loadWorks;
  final bool Function(PixivComicBrief)? accepts;
  final _items = <PixivComicBrief>[];
  final _buffer = <PixivComicBrief>[];
  final _seen = <String>{};
  List<String> _ids = const [];
  int _cursor = 0;
  int _consumedIds = 0;
  int _serverRoundSize = _transportBatchSize;
  bool initialized = false;
  bool attempted = false;
  int lastAddedCount = 0;
  int completedRounds = 0;

  bool get usesPixivCount => batchSize == null;
  List<PixivComicBrief> get items => List.unmodifiable(_items);

  /// Snapshot sessions only continue known IDs; they never rerun init on their
  /// own. The parent exposes a separate explicit gesture for another round.
  bool get hasMore =>
      initialized && (_buffer.isNotEmpty || _cursor < _ids.length);
  bool get canLoadNextRound => initialized;
  int get continuationPosition => _consumedIds;

  void _append(Iterable<PixivComicBrief> incoming) {
    for (final item in incoming) {
      if (!_validId(item.id) || item.id == workId || !_seen.add(item.id)) {
        continue;
      }
      if (accepts?.call(item) ?? true) _buffer.add(item);
    }
  }

  void _revealBuffered() {
    final count = batchSize == null
        ? _buffer.length
        : _buffer.length.clamp(0, batchSize!);
    _items.addAll(_buffer.take(count));
    _buffer.removeRange(0, count);
    lastAddedCount = count;
    completedRounds++;
  }

  Future<void> _loadInitialRound() async {
    attempted = true;
    final result = await loadInitial(workId);
    if (!isCurrent) return;
    if (result.error) throw StateError(result.errorMessageWithoutNull);
    // Keep the response's effective window for nextIds, rather than forcing a
    // five-card presentation. Each HTTP hydration remains bounded to eighteen.
    _serverRoundSize = result.data.items.isEmpty
        ? _transportBatchSize
        : result.data.items.length;
    _append(result.data.items);
    _revealBuffered();
    final seenIds = <String>{workId, ..._seen};
    _ids = [
      for (final id in result.data.nextIds)
        if (_validId(id) && seenIds.add(id)) id,
    ];
    _cursor = 0;
    initialized = true;
  }

  Future<void> load() {
    if (initialized) return Future.value();
    return run(_loadInitialRound);
  }

  /// Called only by the parent detail's bottom gesture or an explicit button.
  /// Known candidate IDs are used first; once exhausted, a fresh init read can
  /// provide a new round. Repeated IDs are suppressed across all rounds.
  Future<void> loadNextRound() {
    if (!initialized) return load();
    if (hasMore) return loadMore();
    return run(_loadInitialRound);
  }

  Future<void> loadMore() {
    if (!initialized) return load();
    if (!hasMore) return Future.value();
    return run(() async {
      if (_buffer.isNotEmpty) {
        _revealBuffered();
        return;
      }
      final count = batchSize ?? _serverRoundSize;
      final ids = _ids.skip(_cursor).take(count).toList(growable: false);
      final byId = <String, PixivComicBrief>{};
      // A server-sized presentation may span more than one bounded transport
      // read. Commit this round atomically so a failed later read can retry the
      // same IDs without dropping or reordering unseen works.
      for (var offset = 0; offset < ids.length; offset += _transportBatchSize) {
        final slice = ids.skip(offset).take(_transportBatchSize).toList();
        final result = await loadWorks(slice);
        if (!isCurrent) return;
        if (result.error) throw StateError(result.errorMessageWithoutNull);
        for (final item in result.data) {
          byId.putIfAbsent(item.id, () => item);
        }
      }
      _append(ids.map((id) => byId[id]).whereType<PixivComicBrief>());
      _revealBuffered();
      _cursor += ids.length;
      _consumedIds += ids.length;
    });
  }
}

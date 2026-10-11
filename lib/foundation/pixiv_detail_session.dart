import 'package:flutter/material.dart';
import 'package:picakeep/foundation/pixiv_detail_preview.dart';

enum PixivDetailScope {
  search,
  author,
  recommendation,
  platformFavorites,
  localFavorites,
  localLibrary,
  localSearch,
  aiResults,
  related,
}

class PixivDetailEntry {
  const PixivDetailEntry({
    required this.key,
    required this.comicId,
    required this.builder,
    this.localFavoriteFolder,
    this.preview,
  });

  final String key;
  final String comicId;
  final WidgetBuilder builder;
  final String? localFavoriteFolder;
  final PixivDetailPreview? preview;
}

class PixivDetailBatch {
  const PixivDetailBatch(this.entries,
      {required this.hasMore, this.total, this.continuationPosition});

  final Iterable<PixivDetailEntry> entries;
  final bool hasMore;
  final int? total;

  /// Related-work ID queues may consume a batch with no visible new entries.
  /// Other scopes retain the existing stop-on-empty contract.
  final int? continuationPosition;
}

/// A route owns a stable snapshot; continuation remains owned by its source.
class PixivDetailSession extends ChangeNotifier {
  PixivDetailSession({
    required Iterable<PixivDetailEntry> entries,
    required this.scope,
    this.localFavoriteFolder,
    bool hasMore = false,
    this.total,
    this.loadMore,
    this.ownerIsCurrent,
    int? continuationPosition,
  })  : _hasMore = hasMore && loadMore != null,
        _continuationPosition = continuationPosition {
    _append(entries);
  }

  final PixivDetailScope scope;
  final String? localFavoriteFolder;
  final Future<PixivDetailBatch> Function()? loadMore;
  final bool Function()? ownerIsCurrent;
  final List<PixivDetailEntry> _entries = [];
  final Set<String> _keys = {};
  // Metadata and page URLs only; decoded images stay owned by ImageCache.
  final _responses = <(String, String, String), Future<Object>>{};
  static const _maximumResponses = 64;
  bool _hasMore;
  bool _busy = false;
  bool _disposed = false;
  int _generation = 0;
  int? _continuationPosition;
  String? _error;
  int? total;

  List<PixivDetailEntry> get entries => List.unmodifiable(_entries);
  bool get hasMore => _hasMore;
  bool get busy => _busy;
  String? get error => _error;
  int indexOf(String key) => _entries.indexWhere((entry) => entry.key == key);

  /// Retain lightweight successful reads across evicted page states, with
  /// account/work/kind identity. Failed reads can be retried immediately.
  Future<T> readResponse<T extends Object>({
    required String account,
    required String workId,
    required String kind,
    required Future<T> Function() load,
    required bool Function(T value) isReusable,
  }) {
    if (_disposed || !(ownerIsCurrent?.call() ?? true)) return load();
    final key = (account, workId, kind);
    final cached = _responses.remove(key);
    if (cached != null) {
      _responses[key] = cached;
      return cached.then((value) => value as T);
    }
    late final Future<T> request;
    void forget() {
      if (identical(_responses[key], request)) _responses.remove(key);
    }

    request = Future<T>.sync(load).then<T>((value) {
      if (_disposed ||
          !(ownerIsCurrent?.call() ?? true) ||
          !isReusable(value)) {
        forget();
      }
      return value;
    }, onError: (Object error, StackTrace stack) {
      forget();
      Error.throwWithStackTrace(error, stack);
    });
    _responses[key] = request;
    while (_responses.length > _maximumResponses) {
      _responses.remove(_responses.keys.first);
    }
    return request;
  }

  void invalidateResponses(
      {required String account, required String workId, String? kind}) {
    _responses.removeWhere((key, _) =>
        key.$1 == account &&
        key.$2 == workId &&
        (kind == null || key.$3 == kind));
  }

  void _append(Iterable<PixivDetailEntry> items) {
    for (final entry in items) {
      if (_keys.add(entry.key)) _entries.add(entry);
    }
  }

  Future<void> requestMore() async {
    if (_disposed || _busy || !_hasMore || loadMore == null) return;
    if (!(ownerIsCurrent?.call() ?? true)) {
      _stop('入口已变化，请返回刷新后继续浏览');
      return;
    }
    final generation = _generation;
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      final batch = await loadMore!();
      if (_disposed || generation != _generation) return;
      if (!(ownerIsCurrent?.call() ?? true)) {
        _stop('入口已变化，请返回刷新后继续浏览');
        return;
      }
      final oldCount = _entries.length;
      _append(batch.entries);
      total = batch.total ?? total;
      _hasMore = batch.hasMore;
      final position = batch.continuationPosition;
      final queueAdvanced = scope == PixivDetailScope.related &&
          position != null &&
          position > (_continuationPosition ?? 0);
      if (queueAdvanced) _continuationPosition = position;
      if (_entries.length == oldCount && batch.hasMore && !queueAdvanced) {
        _hasMore = false;
        _error = '没有收到新的作品，请返回刷新';
      }
    } catch (_) {
      if (_disposed || generation != _generation) return;
      _error = '下一批加载失败，请重试';
    } finally {
      if (!_disposed && generation == _generation) {
        _busy = false;
        notifyListeners();
      }
    }
  }

  /// Mutating a bookmark query makes its old offset unsafe to continue.
  void invalidatePagination() {
    if (_disposed || scope != PixivDetailScope.platformFavorites) return;
    _stop('收藏已更新，请返回刷新后继续浏览');
  }

  void _stop(String message) {
    _generation++;
    _busy = false;
    _hasMore = false;
    _error = message;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _responses.clear();
    _generation++;
    super.dispose();
  }
}

class PixivDetailSessionScope extends InheritedNotifier<PixivDetailSession> {
  const PixivDetailSessionScope({
    super.key,
    required PixivDetailSession session,
    required super.child,
  }) : super(notifier: session);

  static PixivDetailSession? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<PixivDetailSessionScope>()
      ?.notifier;

  static PixivDetailPreview? previewOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<PixivDetailEntryScope>()
      ?.entry
      .preview;

  static String? favoriteFolderOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<PixivDetailEntryScope>()
          ?.entry
          .localFavoriteFolder ??
      maybeOf(context)?.localFavoriteFolder;
}

class PixivDetailEntryScope extends InheritedWidget {
  const PixivDetailEntryScope({
    super.key,
    required this.entry,
    required super.child,
    this.isActive = true,
  });
  final PixivDetailEntry entry;

  /// Gates visual feedback only; pending writes still settle normally.
  final bool isActive;

  static bool isActiveOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<PixivDetailEntryScope>()
          ?.isActive ??
      true;

  @override
  bool updateShouldNotify(PixivDetailEntryScope oldWidget) =>
      oldWidget.entry != entry || oldWidget.isActive != isActive;
}

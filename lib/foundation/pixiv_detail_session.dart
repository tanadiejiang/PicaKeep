import 'package:flutter/material.dart';

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
  });

  final String key;
  final String comicId;
  final WidgetBuilder builder;
  final String? localFavoriteFolder;
}

class PixivDetailBatch {
  const PixivDetailBatch(this.entries, {required this.hasMore, this.total});

  final Iterable<PixivDetailEntry> entries;
  final bool hasMore;
  final int? total;
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
  }) : _hasMore = hasMore && loadMore != null {
    _append(entries);
  }

  final PixivDetailScope scope;
  final String? localFavoriteFolder;
  final Future<PixivDetailBatch> Function()? loadMore;
  final bool Function()? ownerIsCurrent;
  final List<PixivDetailEntry> _entries = [];
  final Set<String> _keys = {};
  bool _hasMore;
  bool _busy = false;
  bool _disposed = false;
  int _generation = 0;
  String? _error;
  int? total;

  List<PixivDetailEntry> get entries => List.unmodifiable(_entries);
  bool get hasMore => _hasMore;
  bool get busy => _busy;
  String? get error => _error;
  int indexOf(String key) => _entries.indexWhere((entry) => entry.key == key);

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
      if (_entries.length == oldCount && batch.hasMore) {
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

import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/network/pixiv_network/pixiv_models.dart';
import 'package:picakeep/network/res.dart';

/// Account identity must not change when a later request discovers the UID.
/// This opaque session value is used only as an in-memory key, never logged.
String pixivBookmarkAccountIdentity([ComicSource? source]) =>
    (source ?? ComicSource.find('pixiv'))?.data['token']?.toString() ?? '';

class _ConfirmedBookmark {
  _ConfirmedBookmark(this.revision);
  PixivBookmarkState? state;
  DateTime? confirmedAt;
  DateTime? retryAfter;
  int revision;
}

class _BookmarkLookup {
  _BookmarkLookup({
    required this.key,
    required this.account,
    required this.id,
    required this.generation,
    required this.readState,
    required bool Function() isCurrentAccount,
  }) : currentChecks = [isCurrentAccount];

  final String key;
  final String account;
  final String id;
  final int generation;
  final Future<Res<PixivBookmarkState>> Function(String) readState;
  final List<bool Function()> currentChecks;
  final completion = Completer<void>();

  bool get isCurrent => currentChecks.any((check) {
        try {
          return check();
        } catch (_) {
          return false;
        }
      });
}

/// Confirmed platform state shared across routes for the running app session.
/// Missing list fields cannot erase a detail read or a successful user write.
class PixivBookmarkStateStore extends ChangeNotifier {
  PixivBookmarkStateStore({
    this.maxEntries = 2000,
    this.maxConcurrentReads = 2,
    DateTime Function()? now,
  })  : assert(maxEntries > 0),
        assert(maxConcurrentReads > 0),
        _now = now ?? DateTime.now;

  static final shared = PixivBookmarkStateStore();
  final int maxEntries;
  final int maxConcurrentReads;
  final DateTime Function() _now;
  final _states = <String, _ConfirmedBookmark>{};
  final _lookups = <String, _BookmarkLookup>{};
  final _pending = Queue<_BookmarkLookup>();
  int _activeReads = 0;
  int _generation = 0;
  int _revisionClock = 0;
  int _missingRevision = 0;
  bool _disposed = false;

  String _key(String account, String id) => '$account\u0000$id';

  _ConfirmedBookmark? _entry(String key) {
    final value = _states.remove(key);
    if (value != null) _states[key] = value;
    return value;
  }

  _ConfirmedBookmark _ensureEntry(String key) {
    final value = _entry(key) ?? _ConfirmedBookmark(_missingRevision);
    _states[key] = value;
    while (_states.length > maxEntries) {
      _states.remove(_states.keys.first);
      // A late read for an evicted key must not resurrect an older state.
      _missingRevision = ++_revisionClock;
    }
    return value;
  }

  PixivBookmarkState? stateFor(String account, String id) =>
      _entry(_key(account, id))?.state;

  int revisionFor(String account, String id) =>
      _entry(_key(account, id))?.revision ?? _missingRevision;

  bool confirm(String account, String id, PixivBookmarkState state,
      {int? expectedRevision}) {
    if (_disposed || account.isEmpty || id.isEmpty) return false;
    final key = _key(account, id);
    final previous = _entry(key);
    if (expectedRevision != null &&
        expectedRevision != (previous?.revision ?? _missingRevision)) {
      return false;
    }
    final value = previous ?? _ensureEntry(key);
    final changed = value.state?.isBookmarked != state.isBookmarked ||
        value.state?.isBookmarkable != state.isBookmarkable ||
        value.state?.bookmarkPrivate != state.bookmarkPrivate;
    value
      ..state = state
      ..confirmedAt = _now()
      ..retryAfter = null
      ..revision = ++_revisionClock;
    if (changed) notifyListeners();
    return true;
  }

  bool isFresh(String account, String id,
      {Duration maxAge = const Duration(minutes: 3)}) {
    final value = _entry(_key(account, id));
    final confirmedAt = value?.confirmedAt;
    return value?.state != null &&
        confirmedAt != null &&
        _now().difference(confirmedAt) < maxAge;
  }

  /// Resolve only visible unknown/stale cards. Reads are deduplicated and
  /// bounded; refreshing state does not put the heart into the write UI state.
  Future<void> resolve({
    required String account,
    required String id,
    required Future<Res<PixivBookmarkState>> Function(String) readState,
    required bool Function() isCurrentAccount,
    bool force = false,
  }) {
    if (_disposed || account.isEmpty || id.isEmpty || !isCurrentAccount()) {
      return Future<void>.value();
    }
    final key = _key(account, id);
    final existing = _lookups[key];
    if (existing != null) {
      existing.currentChecks.add(isCurrentAccount);
      return existing.completion.future;
    }
    final entry = _entry(key);
    if (!force &&
        (isFresh(account, id) ||
            (entry?.retryAfter?.isAfter(_now()) ?? false))) {
      return Future<void>.value();
    }
    final lookup = _BookmarkLookup(
      key: key,
      account: account,
      id: id,
      generation: _generation,
      readState: readState,
      isCurrentAccount: isCurrentAccount,
    );
    _lookups[key] = lookup;
    _pending.add(lookup);
    _drain();
    return lookup.completion.future;
  }

  void _drain() {
    while (!_disposed &&
        _activeReads < maxConcurrentReads &&
        _pending.isNotEmpty) {
      final lookup = _pending.removeFirst();
      _activeReads++;
      unawaited(_read(lookup));
    }
  }

  Future<void> _read(_BookmarkLookup lookup) async {
    final revision = revisionFor(lookup.account, lookup.id);
    bool current() =>
        !_disposed && lookup.generation == _generation && lookup.isCurrent;
    try {
      if (!current()) return;
      final response = await lookup.readState(lookup.id);
      if (!current()) return;
      if (response.success) {
        confirm(lookup.account, lookup.id, response.data,
            expectedRevision: revision);
      } else if (revisionFor(lookup.account, lookup.id) == revision) {
        _ensureEntry(lookup.key).retryAfter =
            _now().add(const Duration(seconds: 30));
      }
    } catch (_) {
      if (current() && revisionFor(lookup.account, lookup.id) == revision) {
        _ensureEntry(lookup.key).retryAfter =
            _now().add(const Duration(seconds: 30));
      }
    } finally {
      if (identical(_lookups[lookup.key], lookup)) {
        _lookups.remove(lookup.key);
      }
      _activeReads--;
      if (!lookup.completion.isCompleted) lookup.completion.complete();
      _drain();
    }
  }

  void clear() {
    if (_disposed) return;
    _generation++;
    _missingRevision = ++_revisionClock;
    _states.clear();
    for (final lookup in _pending) {
      if (!lookup.completion.isCompleted) lookup.completion.complete();
    }
    _pending.clear();
    _lookups.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    clear();
    _disposed = true;
    super.dispose();
  }
}

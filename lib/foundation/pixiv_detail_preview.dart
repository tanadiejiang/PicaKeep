import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// A first-page preview, not authority for bookmarks or later work pages.
/// Keep the exact painted ResizeImage; resizing it changes the decoded key.
@immutable
class PixivDetailPreview {
  const PixivDetailPreview({
    required this.workId,
    required this.provider,
    this.fallbackProvider,
    this.aspectRatio = .75,
    this.aspectRatioKnown = false,
    this.pageCount = 0,
    this.authorAvatarUrl = '',
    this.accountIdentity = '',
    this.ownerIsCurrent,
  });

  final String workId;
  final ImageProvider<Object> provider;
  final ImageProvider<Object>? fallbackProvider;
  final double aspectRatio;
  final bool aspectRatioKnown;
  final int pageCount;
  final String authorAvatarUrl;

  /// In-process validation only; do not log or publish account credentials.
  final String accountIdentity;
  final bool Function()? ownerIsCurrent;

  bool get isCurrent => ownerIsCurrent?.call() ?? true;
}

/// Bounded provider-only registry. No ImageInfo, ui.Image or owner callbacks.
/// Only callers that actually displayed a first frame may remember a provider.
class PixivDetailPreviewRegistry {
  PixivDetailPreviewRegistry({int maximumEntries = 128})
      : maximumEntries = maximumEntries.clamp(1, 128).toInt();

  static final shared = PixivDetailPreviewRegistry();
  final int maximumEntries;
  final _providers = <String, ImageProvider<Object>>{};

  int get length => _providers.length;

  String _key(String workId, String coverUrl, Map<String, String> headers,
      String accountIdentity) {
    final entries = headers.entries.toList()
      ..sort((a, b) {
        final byName = a.key.toLowerCase().compareTo(b.key.toLowerCase());
        return byName != 0 ? byName : a.value.compareTo(b.value);
      });
    return sha256
        .convert(utf8.encode(jsonEncode([
          'pixiv-detail-preview-v1',
          workId,
          coverUrl.trim(),
          entries
              .map((entry) => [entry.key.toLowerCase(), entry.value])
              .toList(),
          accountIdentity,
        ])))
        .toString();
  }

  void rememberReady({
    required String workId,
    required String coverUrl,
    required Map<String, String> headers,
    required String accountIdentity,
    required ImageProvider<Object> provider,
  }) {
    if (workId.isEmpty || coverUrl.trim().isEmpty) return;
    final key = _key(workId, coverUrl, headers, accountIdentity);
    _providers.remove(key);
    _providers[key] = provider;
    while (_providers.length > maximumEntries) {
      _providers.remove(_providers.keys.first);
    }
  }

  ImageProvider<Object>? lookup({
    required String workId,
    required String coverUrl,
    required Map<String, String> headers,
    required String accountIdentity,
  }) {
    final key = _key(workId, coverUrl, headers, accountIdentity);
    final provider = _providers.remove(key);
    if (provider != null) _providers[key] = provider;
    return provider;
  }

  @visibleForTesting
  void clear() => _providers.clear();
}

/// Cancels listeners owned by speculation, not a provider's transport.
class PixivDetailCoverPrefetchCancellation {
  final _listeners = <VoidCallback>{};
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void addListener(VoidCallback listener) {
    if (_cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
  }

  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final listeners = _listeners.toList();
    _listeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }
}

/// Replaceable cover-only queue, never a details/pages/original-image loader.
class PixivDetailCoverPrefetchQueue {
  PixivDetailCoverPrefetchQueue({
    required this.loadCover,
    this.ownerIsCurrent,
    PixivDetailCoverPrefetchCancellation? cancellation,
    int maximumConcurrent = 2,
  })  : cancellation = cancellation ?? PixivDetailCoverPrefetchCancellation(),
        maximumConcurrent = maximumConcurrent.clamp(1, 2).toInt();

  final Future<void> Function(PixivDetailPreview preview) loadCover;
  final bool Function()? ownerIsCurrent;
  final PixivDetailCoverPrefetchCancellation cancellation;
  final int maximumConcurrent;
  final _pending = <PixivDetailPreview>[];
  final _running = <String>{};
  final _settled = <String>{};
  bool _disposed = false;

  bool get _isCurrent =>
      !_disposed &&
      !cancellation.isCancelled &&
      (ownerIsCurrent?.call() ?? true);
  int get runningCount => _running.length;
  int get pendingCount => _pending.length;

  /// Drop stale queued candidates immediately, before the next frame schedules
  /// replacement candidates. Running loads retain their bounded slots.
  void clearCandidates() => _pending.clear();

  /// Supply current and immediate neighbors. Replacement drops stale queued
  /// candidates before any newly free slot starts work after a fast swipe.
  void replaceCandidates(Iterable<PixivDetailPreview> previews) {
    _pending.clear();
    if (!_isCurrent) {
      dispose();
      return;
    }
    final seen = <String>{};
    for (final preview in previews.take(3)) {
      if (preview.isCurrent &&
          seen.add(preview.workId) &&
          !_running.contains(preview.workId) &&
          !_settled.contains(preview.workId)) {
        _pending.add(preview);
      }
    }
    while (_settled.length > 128) {
      _settled.remove(_settled.first);
    }
    _pump();
  }

  void _pump() {
    if (!_isCurrent) {
      dispose();
      return;
    }
    while (_running.length < maximumConcurrent && _pending.isNotEmpty) {
      final preview = _pending.removeAt(0);
      if (!preview.isCurrent || !_isCurrent) continue;
      _running.add(preview.workId);
      unawaited(_load(preview));
    }
  }

  Future<void> _load(PixivDetailPreview preview) async {
    try {
      await loadCover(preview);
    } catch (_) {
      // Speculation failure is silent and cannot cause a retry loop. The
      // visible Image keeps its own accessible error and retry handling.
    } finally {
      _running.remove(preview.workId);
      if (_isCurrent && preview.isCurrent) _settled.add(preview.workId);
      _pump();
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _pending.clear();
    _settled.clear();
    cancellation.cancel();
  }
}

/// Releases only this speculation's listener/timer on frame, error or cancel.
/// Removing a listener does not promise to abort the provider's transport.
Future<void> warmPixivDetailCover(
  PixivDetailPreview preview,
  ImageConfiguration configuration, {
  Duration timeout = const Duration(seconds: 8),
  bool Function()? ownerIsCurrent,
  PixivDetailCoverPrefetchCancellation? cancellation,
}) async {
  bool current() =>
      preview.isCurrent &&
      (ownerIsCurrent?.call() ?? true) &&
      !(cancellation?.isCancelled ?? false);
  if (!current()) return;
  final stream = preview.provider.resolve(configuration);
  final complete = Completer<void>();
  Timer? timer;
  var attached = false;
  late final ImageStreamListener listener;

  void finish() {
    timer?.cancel();
    cancellation?.removeListener(finish);
    if (attached) {
      attached = false;
      stream.removeListener(listener);
    }
    if (!complete.isCompleted) complete.complete();
  }

  listener = ImageStreamListener(
    (frame, synchronous) {
      frame.dispose();
      finish();
    },
    onError: (Object error, StackTrace? stack) => finish(),
  );
  timer = Timer(timeout, finish);
  cancellation?.addListener(finish);
  if (!complete.isCompleted && current()) {
    attached = true;
    stream.addListener(listener);
  } else {
    finish();
  }
  try {
    await complete.future;
  } finally {
    finish();
  }
}

/// The current entry first, followed by its immediate next and previous only.
Iterable<T> pixivDetailNeighborCandidates<T>(
    List<T> entries, int current) sync* {
  if (current < 0 || current >= entries.length) return;
  yield entries[current];
  if (current + 1 < entries.length) yield entries[current + 1];
  if (current > 0) yield entries[current - 1];
}

import 'dart:async';

import 'package:flutter/painting.dart';

import 'reader_preview_provider.dart';
import 'stream_image_provider.dart';

/// A bounded, single-worker neighbour window. Inspectable providers need a
/// Flutter header-based decoded/work admission before frame decoding. Opaque
/// providers skip speculative work; visible loading keeps its original decoder.
/// Codec working-memory accounting is conservative estimation, not an OS cap.
class ReaderPreviewPreloader {
  ReaderPreviewPreloader(
      {ReaderPreviewImagePool? pool,
      this.maximumPages = 8,
      this.maximumDecodedBytes = 64 << 20})
      : pool = pool ?? ReaderPreviewImagePool.shared {
    if (maximumPages < 0 || maximumPages > 8 || maximumDecodedBytes <= 0) {
      throw ArgumentError('Invalid reader preload limits');
    }
    this.pool.addListener(_schedule);
  }

  final ReaderPreviewImagePool pool;
  final int maximumPages, maximumDecodedBytes;
  final _wanted = <String, ReaderPreviewProviderLoader>{};
  final _jobs = <String, _PreviewPreload>{};
  final _failed = <String>{};
  final _handoff = <String, Timer>{};
  int _limit = 0;
  ImageConfiguration _configuration = ImageConfiguration.empty;
  bool _disposed = false, _queued = false;

  List<String> get retainedKeys => List.unmodifiable(_jobs.keys);
  int get retainedDecodedBytes =>
      _jobs.values.fold(0, (n, job) => n + job.lease.decodedBytes);

  void update({
    required int currentPage,
    required int pageCount,
    required int preloadCount,
    required String Function(int) resourceKeyForPage,
    required FutureOr<ImageProvider> Function(int, StreamImageAbortSignal)
        loadProvider,
    Set<int> visiblePages = const {},
    ImageConfiguration configuration = ImageConfiguration.empty,
    bool Function()? canAddIdleExtras,
  }) {
    if (_disposed) return;
    _configuration = configuration;
    _wanted.clear();
    final valid = currentPage >= 0 && currentPage < pageCount;
    final base = preloadCount.clamp(0, maximumPages);
    // No fabricated ImageManager.haveTask idle signal. The host must supply a
    // real foreground + budget observation to opt into the legacy extra 3.
    final extra = valid &&
            base > 0 &&
            !pool.hasPendingVisible &&
            canAddIdleExtras?.call() == true
        ? 3
        : 0;
    final count = (base + extra).clamp(0, maximumPages);
    _limit = valid ? count : 0;
    final visibleKeys = valid && count > 0
        ? <int>{currentPage, ...visiblePages}
            .where((page) => page >= 0 && page < pageCount)
            .map(resourceKeyForPage).toSet()
        : <String>{};
    if (valid) {
      for (var page = currentPage + 1;
          page < pageCount && page <= currentPage + count;
          page++) {
        if (visiblePages.contains(page)) continue;
        final key = resourceKeyForPage(page);
        _wanted.putIfAbsent(key, () => (abort) => loadProvider(page, abort));
      }
    }
    _failed.removeWhere((key) => !_wanted.containsKey(key));
    for (final key in _jobs.keys.toList()) {
      if (_wanted.containsKey(key)) {
        _handoff.remove(key)?.cancel();
      } else if (visibleKeys.contains(key) && !pool.hasVisibleLease(key)) {
        // jumpToPage publishes its index before an animated viewport creates
        // the target widget. Keep its existing operation, never start another.
        _handoff.putIfAbsent(key, () => Timer(const Duration(milliseconds: 500), () {
          _handoff.remove(key);
          if (!_wanted.containsKey(key)) _remove(key);
          _schedule();
        }));
      } else {
        _remove(key);
      }
    }
    while (_jobs.length > _limit) {
      final farthest = _jobs.keys.where((key) => !_handoff.containsKey(key));
      _remove(farthest.isNotEmpty ? farthest.last : _jobs.keys.last);
    }
    _schedule();
  }

  void _schedule() {
    if (_disposed || _queued) return;
    _queued = true;
    scheduleMicrotask(() {
      _queued = false;
      if (_disposed) return;
      for (final key in _handoff.keys.toList()) {
        if (pool.hasVisibleLease(key)) _remove(key);
      }
      if (pool.hasPendingVisible) {
        // Relinquish speculative consumers. If a visible consumer joined that
        // same operation its independent lease keeps the transfer alive.
        for (final key in _jobs.keys.toList()) {
          _remove(key);
        }
        return;
      }
      if (_jobs.length >= _limit || _jobs.values.any((job) => !job.complete)) return;
      for (final item in _wanted.entries) {
        if (_jobs.containsKey(item.key) || _failed.contains(item.key)) continue;
        if (retainedDecodedBytes >= maximumDecodedBytes) return;
        _start(item.key, item.value);
        return;
      }
    });
  }

  void _start(String key, ReaderPreviewProviderLoader loader) {
    final lease = pool.acquire(
        resourceKey: key,
        loadProvider: loader,
        visible: false,
        maximumPreloadBytes: maximumDecodedBytes - retainedDecodedBytes);
    final stream = lease.provider.resolve(_configuration);
    final job = _PreviewPreload(lease, stream);
    _jobs[key] = job;
    job.listener = ImageStreamListener((info, synchronous) {
      info.dispose();
      if (_disposed || !identical(_jobs[key], job)) return;
      job.complete = true;
      // The pool lease keeps the first frame, not an animation listener. Just
      // like precacheImage, hidden neighbours stop producing animation frames.
      stream.removeListener(job.listener);
      while (retainedDecodedBytes > maximumDecodedBytes && _jobs.isNotEmpty) {
        final victim = _jobs.keys.last;
        _failed.add(victim);
        _remove(victim);
      }
      _schedule();
    }, onError: (Object error, StackTrace? stack) {
      if (_disposed || !identical(_jobs[key], job)) return;
      _failed.add(key);
      _remove(key);
      _schedule();
    });
    stream.addListener(job.listener);
  }

  void _remove(String key) {
    _handoff.remove(key)?.cancel();
    final job = _jobs.remove(key);
    if (job == null) return;
    job.stream.removeListener(job.listener);
    job.lease.release();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    pool.removeListener(_schedule);
    _wanted.clear();
    for (final key in _jobs.keys.toList()) {
      _remove(key);
    }
  }
}

class _PreviewPreload {
  _PreviewPreload(this.lease, this.stream);
  final ReaderPreviewImageLease lease;
  final ImageStream stream;
  late final ImageStreamListener listener;
  bool complete = false;
}

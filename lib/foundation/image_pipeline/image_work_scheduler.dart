import 'dart:async';

enum ImageWorkPriority { visible, neighbour, cover, background }

enum ImageWorkState { queued, running, ready, failed, cancelled }

/// HTTP readers must not hold a native execution slot while the same-process
/// server needs that slot to produce their response. Both lanes share memory.
enum ImageWorkLane { execution, network }

class ImageWorkQueueExceeded implements Exception {
  const ImageWorkQueueExceeded(this.lane, this.limit);
  final ImageWorkLane lane;
  final int limit;
  @override
  String toString() => 'Image work queue is full';
}

class ImageWorkCancelled implements Exception {
  const ImageWorkCancelled();
  @override
  String toString() => 'Image request cancelled';
}

class ImageWorkBudgetExceeded implements Exception {
  const ImageWorkBudgetExceeded(this.requestedBytes, this.budgetBytes);
  final int requestedBytes;
  final int budgetBytes;
  @override
  String toString() => 'Image working set exceeds available budget';
}

class ImageWorkCancellation {
  bool _cancelled = false;
  final _completion = Completer<void>();
  bool get isCancelled => _cancelled;
  Future<void> get cancelled => _completion.future;
  void _cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _completion.complete();
  }

  void throwIfCancelled() {
    if (_cancelled) throw const ImageWorkCancelled();
  }
}

class ImageWorkTicket<T> {
  ImageWorkTicket._(this.future, this._cancel);
  final Future<T> future;
  final void Function() _cancel;
  bool _released = false;
  void cancel() {
    if (_released) return;
    _released = true;
    _cancel();
  }
}

class _ImageJob<T> {
  _ImageJob(this.key, this.priority, this.bytes, this.run, this.disposeResult,
      this.lane, this.servesNetwork);
  final String key;
  ImageWorkPriority priority;
  final int bytes;
  final Future<T> Function(ImageWorkCancellation) run;
  final void Function(T)? disposeResult;
  final ImageWorkLane lane;
  final bool servesNetwork;
  final cancellation = ImageWorkCancellation();
  final listeners = <Completer<T>>{};
  ImageWorkState state = ImageWorkState.queued;
}

/// Deduplicates in-flight work and reserves memory before starting it.
/// Completed images are owned by their consumers, not this queue.
class ImageWorkScheduler {
  ImageWorkScheduler(
      {this.maxConcurrent = 2,
      this.maxNetworkConcurrent = 2,
      this.maxExecutionPending = 128,
      this.maxNetworkPending = 32,
      this.memoryBudgetBytes = 512 << 20})
      : assert(maxConcurrent > 0),
        assert(maxNetworkConcurrent > 0),
        assert(maxExecutionPending > 0),
        assert(maxNetworkPending > 0),
        assert(memoryBudgetBytes > 0);

  static final shared = ImageWorkScheduler(memoryBudgetBytes: 1 << 30);
  final int maxConcurrent;
  final int maxNetworkConcurrent, maxExecutionPending, maxNetworkPending;
  final int memoryBudgetBytes;
  final _jobs = <String, _ImageJob<dynamic>>{};
  int _activeExecution = 0, _activeNetwork = 0;
  int _reserved = 0;
  bool _backgroundPaused = false;

  int get activeCount => _activeExecution + _activeNetwork;
  int get activeExecutionCount => _activeExecution;
  int get activeNetworkCount => _activeNetwork;
  int get pendingCount => _jobs.length;
  int get reservedBytes => _reserved;
  bool get hasWork => _jobs.isNotEmpty;
  ImageWorkState? stateOf(String key) => _jobs[key]?.state;

  ImageWorkTicket<T> submit<T>({
    required String key,
    required ImageWorkPriority priority,
    required int estimatedBytes,
    required Future<T> Function(ImageWorkCancellation) run,
    void Function(T)? disposeResult,
    ImageWorkLane lane = ImageWorkLane.execution,
    bool servesNetwork = false,
  }) {
    final completion = Completer<T>();
    if (estimatedBytes < 0 || estimatedBytes > memoryBudgetBytes) {
      completion.completeError(
          ImageWorkBudgetExceeded(estimatedBytes, memoryBudgetBytes));
      return ImageWorkTicket._(completion.future, () {});
    }
    var job = _jobs[key] as _ImageJob<T>?;
    if (job == null || job.cancellation.isCancelled) {
      final limit = lane == ImageWorkLane.network
          ? maxNetworkPending
          : maxExecutionPending;
      if (_jobs.values.where((job) => job.lane == lane).length >= limit) {
        completion.completeError(ImageWorkQueueExceeded(lane, limit));
        return ImageWorkTicket._(completion.future, () {});
      }
      job = _ImageJob<T>(key, priority, estimatedBytes, run, disposeResult,
          lane, servesNetwork);
      _jobs[key] = job;
    } else if (priority.index < job.priority.index) {
      job.priority = priority;
    }
    final ownedJob = job;
    job.listeners.add(completion);
    scheduleMicrotask(_drain);
    return ImageWorkTicket<T>._(completion.future, () {
      if (!ownedJob.listeners.remove(completion)) return;
      if (!completion.isCompleted) {
        completion.completeError(const ImageWorkCancelled());
      }
      if (ownedJob.listeners.isEmpty) {
        ownedJob.cancellation._cancel();
        if (ownedJob.state == ImageWorkState.queued) {
          ownedJob.state = ImageWorkState.cancelled;
          if (identical(_jobs[key], ownedJob)) _jobs.remove(key);
        }
      }
      _drain();
    });
  }

  void pauseBackground(bool pause) {
    _backgroundPaused = pause;
    _drain();
  }

  void cancelWhere(bool Function(String key) matches) {
    for (final job in _jobs.values.toList()) {
      if (!matches(job.key)) continue;
      job.cancellation._cancel();
      for (final listener in job.listeners) {
        if (!listener.isCompleted) {
          listener.completeError(const ImageWorkCancelled());
        }
      }
      job.listeners.clear();
      if (job.state == ImageWorkState.queued &&
          identical(_jobs[job.key], job)) {
        _jobs.remove(job.key);
      }
    }
    _drain();
  }

  void _drain() {
    while (true) {
      final candidates = _jobs.values
          .where((j) =>
              j.state == ImageWorkState.queued &&
              !j.cancellation.isCancelled &&
              (!_backgroundPaused || j.priority == ImageWorkPriority.visible))
          .toList()
        ..sort((a, b) => a.priority.index.compareTo(b.priority.index));
      if (candidates.isEmpty) return;
      // Do not let smaller background work jump a blocked foreground request.
      final available = candidates.where((job) {
        final active = job.lane == ImageWorkLane.network
            ? _activeNetwork
            : _activeExecution;
        final maximum = job.lane == ImageWorkLane.network
            ? maxNetworkConcurrent
            : maxConcurrent;
        return active < maximum &&
            (maximum == 1 ||
                job.priority == ImageWorkPriority.visible ||
                active < maximum - 1);
      });
      if (available.isEmpty) return;
      var job = available.first;
      if (_reserved + job.bytes > memoryBudgetBytes &&
          _activeNetwork > 0 &&
          _activeExecution == 0) {
        // A previously queued ordinary image may not fit until its HTTP
        // neighbour completes. Let that neighbour's explicit server dependency
        // run ahead when it has equal or higher foreground priority.
        final dependencies = available.where((candidate) =>
            candidate.servesNetwork &&
            candidate.priority.index <= job.priority.index);
        if (dependencies.isNotEmpty) job = dependencies.first;
      }
      // Keep one execution slot available for a newly visible page.
      if (_reserved + job.bytes > memoryBudgetBytes) {
        // An IO reader can depend on this server job. If no execution task can
        // finish to free memory, waiting would be a circular dependency.
        // Report an explicit resource failure so the HTTP consumer releases its
        // IO reservation rather than polling 202 forever.
        if (job.servesNetwork && _activeNetwork > 0 && _activeExecution == 0) {
          job.state = ImageWorkState.failed;
          for (final listener in job.listeners) {
            if (!listener.isCompleted) {
              listener.completeError(ImageWorkBudgetExceeded(
                  job.bytes, memoryBudgetBytes - _reserved));
            }
          }
          job.listeners.clear();
          if (identical(_jobs[job.key], job)) _jobs.remove(job.key);
          continue;
        }
        return;
      }
      if (job.lane == ImageWorkLane.network) {
        _activeNetwork++;
      } else {
        _activeExecution++;
      }
      _reserved += job.bytes;
      job.state = ImageWorkState.running;
      unawaited(_run(job));
    }
  }

  Future<void> _run<T>(_ImageJob<T> job) async {
    try {
      final result = await job.run(job.cancellation);
      if (job.cancellation.isCancelled || job.listeners.isEmpty) {
        job.disposeResult?.call(result);
        throw const ImageWorkCancelled();
      }
      job.cancellation.throwIfCancelled();
      job.state = ImageWorkState.ready;
      for (final listener in job.listeners) {
        if (!listener.isCompleted) listener.complete(result);
      }
    } catch (error, stack) {
      job.state = job.cancellation.isCancelled
          ? ImageWorkState.cancelled
          : ImageWorkState.failed;
      for (final listener in job.listeners) {
        if (!listener.isCompleted) listener.completeError(error, stack);
      }
    } finally {
      job.listeners.clear();
      if (job.lane == ImageWorkLane.network) {
        _activeNetwork--;
      } else {
        _activeExecution--;
      }
      _reserved -= job.bytes;
      if (identical(_jobs[job.key], job)) _jobs.remove(job.key);
      _drain();
    }
  }
}

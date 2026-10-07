part of '../picakeep_image_engine.dart';

enum _WorkerOperation { probe, estimate, decode, decodePrepared }

class _WorkerCall {
  const _WorkerCall(this.id, this.operation, this.arguments);
  final int id;
  final _WorkerOperation operation;
  final List<Object> arguments;
}

class _WorkerStarted {
  const _WorkerStarted(this.port, this.initializationMicroseconds);
  final SendPort port;
  final int initializationMicroseconds;
}

class _WorkerReply {
  const _WorkerReply(
    this.id,
    this.value,
    this.executionMicroseconds, {
    this.error,
    this.stack,
  });
  final int id;
  final Object? value;
  final int executionMicroseconds;
  final Object? error;
  final String? stack;
}

class _WorkerResult {
  const _WorkerResult(
    this.value,
    this.workerId,
    this.queueMicroseconds,
    this.startupMicroseconds,
    this.executionMicroseconds,
    this.transportMicroseconds,
  );
  final Object value;
  final int workerId;
  final int queueMicroseconds;
  final int startupMicroseconds;
  final int executionMicroseconds;
  final int transportMicroseconds;
}

class _WorkerJob {
  _WorkerJob(this.call, this.tokenAddress);
  final _WorkerCall call;
  final int tokenAddress;
  final completion = Completer<_WorkerResult>();
  final clock = Stopwatch()..start();
  int queueMicroseconds = 0;
  int startupMicroseconds = 0;
}

// The application owns memory admission and priority. This pool only bounds
// execution and metadata messages, without acquiring or releasing source leases.
class _ImageWorkerPool {
  _ImageWorkerPool({void Function(SendPort)? workerEntrypoint})
    : _workerEntrypoint = workerEntrypoint ?? _imageWorkerMain;
  static final instance = _ImageWorkerPool();
  final void Function(SendPort) _workerEntrypoint;
  static const _maxWorkers = 2;
  static const _maxQueued = 128;
  final _queue = ListQueue<_WorkerJob>();
  final _workers = <_ImageWorker>[];
  int _nextJob = 0, _nextWorker = 0;
  int _created = 0, _completed = 0, _failed = 0, _cancelled = 0, _queuePeak = 0;
  final _failedCodes = <int, int>{};
  final _submittedOperations = <_WorkerOperation, int>{};
  final _completedOperations = <_WorkerOperation, int>{};
  final _failedOperations = <_WorkerOperation, int>{};
  final _cancelledOperations = <_WorkerOperation, int>{};
  final _executionOperations = <_WorkerOperation, int>{};
  final _queueOperations = <_WorkerOperation, int>{};
  int _failedOther = 0;
  int _startupFailures = 0;
  int _startupFailuresTotal = 0;
  int _initializationMicroseconds = 0, _startupMicroseconds = 0;
  Timer? _idleTimer;

  Map<String, int> get diagnostics => {
    'workerLimit': _maxWorkers,
    'workersAlive': _workers.length,
    'activeJobs': _workers.where((worker) => worker.job != null).length,
    'queuedJobs': _queue.length,
    'queuedLimit': _maxQueued,
    'queuePeak': _queuePeak,
    'workersCreated': _created,
    'jobsCompleted': _completed,
    'jobsFailed': _failed,
    for (final entry in _failedCodes.entries)
      'jobsFailedCode${entry.key}': entry.value,
    'jobsFailedNonNative': _failedOther,
    for (final operation in _WorkerOperation.values) ...{
      'jobsSubmitted${_operationLabel(operation)}':
          _submittedOperations[operation] ?? 0,
      'jobsCompleted${_operationLabel(operation)}':
          _completedOperations[operation] ?? 0,
      'jobsFailed${_operationLabel(operation)}':
          _failedOperations[operation] ?? 0,
      'jobsCancelledBeforeExecution${_operationLabel(operation)}':
          _cancelledOperations[operation] ?? 0,
      'workerExecutionMicroseconds${_operationLabel(operation)}':
          _executionOperations[operation] ?? 0,
      'workerQueueMicroseconds${_operationLabel(operation)}':
          _queueOperations[operation] ?? 0,
    },
    'jobsCancelledBeforeExecution': _cancelled,
    'bindingInitializationMicroseconds': _initializationMicroseconds,
    'workerStartupMicroseconds': _startupMicroseconds,
    'workerStartupFailures': _startupFailuresTotal,
  };

  static String _operationLabel(_WorkerOperation operation) =>
      '${operation.name[0].toUpperCase()}${operation.name.substring(1)}';

  void _increment(
    Map<_WorkerOperation, int> counts,
    _WorkerOperation operation, [
    int amount = 1,
  ]) => counts.update(
    operation,
    (value) => value + amount,
    ifAbsent: () => amount,
  );

  void _recordFailure(Object error, _WorkerOperation operation) {
    _failed++;
    _increment(_failedOperations, operation);
    if (error is ImageEngineException) {
      _failedCodes.update(error.code, (value) => value + 1, ifAbsent: () => 1);
    } else {
      _failedOther++;
    }
  }

  Future<_WorkerResult> run(
    _WorkerOperation operation,
    List<Object> arguments, {
    int tokenAddress = 0,
  }) {
    if (_queue.length >= _maxQueued) {
      return Future.error(const ImageEngineQueueExceeded(_maxQueued));
    }
    _idleTimer?.cancel();
    _idleTimer = null;
    if (_workers.isEmpty && _queue.isEmpty) _startupFailures = 0;
    final job = _WorkerJob(
      _WorkerCall(++_nextJob, operation, arguments),
      tokenAddress,
    );
    _increment(_submittedOperations, operation);
    _queue.add(job);
    if (_queue.length > _queuePeak) _queuePeak = _queue.length;
    _drain();
    return job.completion.future;
  }

  void cancelQueued(int tokenAddress) {
    final cancelled = _queue
        .where((job) => job.tokenAddress == tokenAddress)
        .toList();
    for (final job in cancelled) {
      _queue.remove(job);
      _cancelled++;
      _increment(_cancelledOperations, job.call.operation);
      job.completion.completeError(
        const ImageEngineException(2, 'Queued image operation cancelled'),
      );
    }
    _drain();
  }

  void _drain() {
    for (final worker in _workers.toList()) {
      if (_queue.isEmpty) break;
      if (worker.port == null || worker.job != null || worker.closing) continue;
      final job = _queue.removeFirst();
      job.queueMicroseconds = job.clock.elapsedMicroseconds;
      job.startupMicroseconds = worker.firstStartupMicroseconds;
      worker.firstStartupMicroseconds = 0;
      worker.job = job;
      worker.port!.send(job.call);
    }
    final starting = _workers
        .where((worker) => worker.port == null && !worker.closing)
        .length;
    if (_queue.length > starting &&
        _workers.length + _startupFailures < _maxWorkers) {
      final worker = _ImageWorker(this, ++_nextWorker);
      _workers.add(worker);
      _created++;
      unawaited(worker.start());
      _drain();
    }
    if (_queue.isEmpty &&
        _workers.isNotEmpty &&
        _workers.every(
          (worker) =>
              worker.port != null && worker.job == null && !worker.closing,
        )) {
      _idleTimer ??= Timer(const Duration(seconds: 10), () {
        _idleTimer = null;
        unawaited(shutdownIdle());
      });
    }
  }

  Future<void> shutdownIdle() async {
    _idleTimer?.cancel();
    _idleTimer = null;
    if (_queue.isEmpty && _workers.every((worker) => worker.job == null)) {
      final starting = _workers
          .where((worker) => worker.port == null && !worker.closing)
          .toList();
      await Future.wait(starting.map((worker) => worker.initialized.future));
    }
    final idle = _workers
        .where(
          (worker) =>
              worker.port != null && worker.job == null && !worker.closing,
        )
        .toList();
    for (final worker in idle) {
      worker.closing = true;
      // A message makes the worker close its receive port after all native
      // cleanup. Isolate.kill could skip FFI finally blocks and is never used.
      worker.port!.send(null);
    }
    await Future.wait(idle.map((worker) => worker.exited.future));
  }

  void _reply(_ImageWorker worker, _WorkerReply reply) {
    final job = worker.job;
    if (job == null || job.call.id != reply.id) {
      _workerFailed(
        worker,
        StateError('Image worker response identity mismatch'),
      );
      return;
    }
    worker.job = null;
    _increment(
      _executionOperations,
      job.call.operation,
      reply.executionMicroseconds,
    );
    _increment(_queueOperations, job.call.operation, job.queueMicroseconds);
    // A functioning sibling breaks the consecutive startup-failure cohort and
    // allows replacement capacity even if it initialized before the failure.
    _startupFailures = 0;
    if (reply.error != null) {
      _recordFailure(reply.error!, job.call.operation);
      job.completion.completeError(
        reply.error!,
        StackTrace.fromString(reply.stack ?? ''),
      );
    } else {
      _completed++;
      _increment(_completedOperations, job.call.operation);
      final transport =
          job.clock.elapsedMicroseconds -
          job.queueMicroseconds -
          reply.executionMicroseconds;
      job.completion.complete(
        _WorkerResult(
          reply.value!,
          worker.id,
          job.queueMicroseconds,
          job.startupMicroseconds,
          reply.executionMicroseconds,
          transport < 0 ? 0 : transport,
        ),
      );
    }
    _drain();
  }

  void _workerFailed(_ImageWorker worker, Object error) {
    if (!_workers.contains(worker)) return;
    worker.closing = true;
    final job = worker.job;
    worker.job = null;
    if (job != null) {
      _recordFailure(error, job.call.operation);
      job.completion.completeError(error);
    } else if (worker.port == null) {
      // Charge a startup failure to one queued caller. Let an initializing
      // sibling continue serving its own cohort; cap consecutive respawns.
      _startupFailures++;
      _startupFailuresTotal++;
      if (_queue.isNotEmpty) {
        final failedJob = _queue.removeFirst();
        _recordFailure(error, failedJob.call.operation);
        failedJob.completion.completeError(error);
      }
      final siblingCanServe = _workers.any(
        (candidate) =>
            !identical(candidate, worker) &&
            candidate.port != null &&
            !candidate.closing,
      );
      if (_startupFailures >= 2 && !siblingCanServe) {
        while (_queue.isNotEmpty) {
          final failedJob = _queue.removeFirst();
          _recordFailure(error, failedJob.call.operation);
          failedJob.completion.completeError(error);
        }
      }
    }
    _workerExited(worker);
  }

  void _workerExited(_ImageWorker worker) {
    if (_workers.contains(worker) && !worker.closing && worker.port == null) {
      _workerFailed(
        worker,
        StateError('Native image worker exited at startup'),
      );
      return;
    }
    if (!_workers.remove(worker)) return;
    if (!worker.initialized.isCompleted) worker.initialized.complete(false);
    if (worker.job != null) {
      final error = StateError(
        'Native image worker exited before returning its result',
      );
      _recordFailure(error, worker.job!.call.operation);
      worker.job!.completion.completeError(error);
      worker.job = null;
    }
    worker.closePorts();
    worker.exited.complete();
    _drain();
  }
}

class _ImageWorker {
  _ImageWorker(this.pool, this.id);
  final _ImageWorkerPool pool;
  final int id;
  final replies = ReceivePort();
  final errors = ReceivePort();
  final exits = ReceivePort();
  final exited = Completer<void>();
  final initialized = Completer<bool>();
  SendPort? port;
  _WorkerJob? job;
  bool closing = false;
  int firstStartupMicroseconds = 0;

  Future<void> start() async {
    final clock = Stopwatch()..start();
    replies.listen((message) {
      if (message is _WorkerStarted) {
        port = message.port;
        if (!initialized.isCompleted) initialized.complete(true);
        pool._startupFailures = 0;
        firstStartupMicroseconds = clock.elapsedMicroseconds;
        pool._startupMicroseconds += firstStartupMicroseconds;
        pool._initializationMicroseconds += message.initializationMicroseconds;
        pool._drain();
      } else if (message is _WorkerReply) {
        pool._reply(this, message);
      }
    });
    errors.listen(
      (error) => pool._workerFailed(
        this,
        RemoteError(error[0].toString(), error[1].toString()),
      ),
    );
    exits.listen((_) => pool._workerExited(this));
    try {
      await Isolate.spawn(
        pool._workerEntrypoint,
        replies.sendPort,
        onError: errors.sendPort,
        onExit: exits.sendPort,
        debugName: 'picakeep-image-$id',
      );
    } catch (error) {
      pool._workerFailed(this, error);
    }
  }

  void closePorts() {
    replies.close();
    errors.close();
    exits.close();
  }
}

void _imageWorkerMain(SendPort replies) {
  final initClock = Stopwatch()..start();
  _Bindings.instance;
  final requests = ReceivePort();
  replies.send(
    _WorkerStarted(requests.sendPort, initClock.elapsedMicroseconds),
  );
  requests.listen((message) {
    if (message == null) {
      requests.close();
      return;
    }
    final call = message as _WorkerCall;
    final clock = Stopwatch()..start();
    try {
      final args = call.arguments;
      final value = switch (call.operation) {
        _WorkerOperation.probe => _probe(args[0] as String),
        _WorkerOperation.estimate => _estimate(
          args[0] as String,
          args[1] as String,
          args[2] as int,
          args[3] as int,
        ),
        _WorkerOperation.decode => _decode(
          args[0] as String,
          args[1] as NativeImageRect,
          args[2] as String,
          args[3] as int,
          args[4] as int,
          args[5] as int,
          args[6] as int,
          args[7] as int,
          args[8] as bool,
        ),
        _WorkerOperation.decodePrepared => _decode(
          args[0] as String,
          args[1] as NativeImageRect,
          args[2] as String,
          args[3] as int,
          args[4] as int,
          args[5] as int,
          args[6] as int,
          args[7] as int,
          args[8] as bool,
          preparedOnly: true,
        ),
      };
      replies.send(_WorkerReply(call.id, value, clock.elapsedMicroseconds));
    } catch (error, stack) {
      final safeError = error is ImageEngineException
          ? error
          : RemoteError(error.toString(), stack.toString());
      replies.send(
        _WorkerReply(
          call.id,
          null,
          clock.elapsedMicroseconds,
          error: safeError,
          stack: stack.toString(),
        ),
      );
    }
  });
}

int _estimate(String path, String backingPath, int width, int height) {
  final input = path.toNativeUtf8(), backing = backingPath.toNativeUtf8();
  try {
    return _Bindings.instance.estimate(input, backing, width, height);
  } finally {
    calloc.free(input);
    calloc.free(backing);
  }
}

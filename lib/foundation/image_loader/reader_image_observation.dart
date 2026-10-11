import 'dart:async';
import 'dart:collection';

/// Actual failure locations, never inferred from the exception type at the UI.
enum ReaderImageStage {
  fetch,
  cache,
  transform,
  decode,
  unknown;

  String get token => name;
}

/// Closed diagnostic vocabulary. No exception text or caller-provided token is
/// admitted as a reason. These values never participate in retry decisions.
enum ReaderImageReason {
  encodedInputLimit,
  sourcePixelLimit,
  workBudget,
  residentBudget,
  queueFull,
  unboundedProvider,
  transformBudget,
  unsupportedTransform,
  imageLimit,
  unsupportedEncoding,
  invalidLength,
  inputLimit,
  lengthMismatch,
  emptyBody,
  emptyInput,
  bodyContract,
  httpStatus,
  timeout,
  tls,
  network,
  diskAdmission,
  diskBudget,
  workspaceBudget,
  cacheLeaseConflict,
  sourceChanged,
  transformOutputLimit,
}

enum ReaderHttpStatusClass {
  unknown,
  success,
  redirect,
  auth,
  rateLimited,
  clientError,
  serverError,
}

enum ReaderEncodingContract { unknown, identity, gzipDecoded, unsupported }

ReaderHttpStatusClass readerHttpStatusClass(int? status) {
  if (status == 401 || status == 403) return ReaderHttpStatusClass.auth;
  if (status == 429) return ReaderHttpStatusClass.rateLimited;
  if (status == null) return ReaderHttpStatusClass.unknown;
  if (status >= 200 && status < 300) return ReaderHttpStatusClass.success;
  if (status >= 300 && status < 400) return ReaderHttpStatusClass.redirect;
  if (status >= 400 && status < 500) return ReaderHttpStatusClass.clientError;
  if (status >= 500 && status < 600) return ReaderHttpStatusClass.serverError;
  return ReaderHttpStatusClass.unknown;
}

/// Immutable, constant-sized execution facts. null cache flags mean that this
/// execution did not observe that lookup, NOT that it missed. Different cache
/// layers cannot overwrite one another (processed miss + raw disk hit is valid).
class ReaderImageFacts {
  const ReaderImageFacts({
    this.httpStatusClass = ReaderHttpStatusClass.unknown,
    this.encodingContract = ReaderEncodingContract.unknown,
    this.rawCacheHit,
    this.onlineCacheHit,
    this.processedCacheHit,
    this.reasonHint,
  });

  final ReaderHttpStatusClass httpStatusClass;
  final ReaderEncodingContract encodingContract;
  final bool? rawCacheHit, onlineCacheHit, processedCacheHit;
  final ReaderImageReason? reasonHint;

  ReaderImageFacts merge(ReaderImageFacts other) => ReaderImageFacts(
        httpStatusClass: other.httpStatusClass == ReaderHttpStatusClass.unknown
            ? httpStatusClass
            : other.httpStatusClass,
        encodingContract:
            other.encodingContract == ReaderEncodingContract.unknown
                ? encodingContract
                : other.encodingContract,
        rawCacheHit: other.rawCacheHit ?? rawCacheHit,
        onlineCacheHit: other.onlineCacheHit ?? onlineCacheHit,
        processedCacheHit: other.processedCacheHit ?? processedCacheHit,
        reasonHint: other.reasonHint ?? reasonHint,
      );

  ReaderImageFacts withReason(ReaderImageReason? reason) => ReaderImageFacts(
        httpStatusClass: httpStatusClass,
        encodingContract: encodingContract,
        rawCacheHit: rawCacheHit,
        onlineCacheHit: onlineCacheHit,
        processedCacheHit: processedCacheHit,
        reasonHint: reason,
      );

  Map<String, Object?> toSnapshot() => {
        'httpStatusClass': httpStatusClass.name,
        'encodingContract': encodingContract.name,
        'rawCacheHit': rawCacheHit,
        'onlineCacheHit': onlineCacheHit,
        'processedCacheHit': processedCacheHit,
      };
}

/// Original exception/stack and facts frozen at the real failure boundary.
class ReaderImageObservedFailure {
  const ReaderImageObservedFailure({
    required this.stage,
    required this.error,
    required this.stackTrace,
    required this.executionId,
    this.facts = const ReaderImageFacts(),
  });
  final ReaderImageStage stage;
  final Object error;
  final StackTrace stackTrace;
  final int executionId;
  final ReaderImageFacts facts;
}

/// One instance represents ONE execution, not a pool entry's entire lifetime.
/// Shared producers never capture the creating consumer. Each consumer forwards
/// the producer's safe facts on success AND failure in its own execution Zone.
class ReaderImageObservation {
  ReaderImageObservation({bool Function()? isCancelled})
      : _isCancelled = isCancelled,
        executionId = ++_nextExecutionId;

  static int _nextExecutionId = 0;
  static const maximumFailures = 8;
  static final Object _zoneKey = Object();
  final bool Function()? _isCancelled;
  final int executionId;
  final ListQueue<ReaderImageObservedFailure> _failures = ListQueue();
  final _reasonHints = LinkedHashMap<Object, ReaderImageReason>.identity();
  ReaderImageFacts _facts = const ReaderImageFacts();
  void Function(ReaderImageObservedFailure)? _sink;
  bool _closed = false;

  static ReaderImageObservation? get current =>
      Zone.current[_zoneKey] as ReaderImageObservation?;
  ReaderImageFacts get facts => _facts;
  List<ReaderImageObservedFailure> get recentFailures =>
      List<ReaderImageObservedFailure>.unmodifiable(_failures);
  ReaderImageObservedFailure? get latestFailure =>
      _failures.isEmpty ? null : _failures.last;
  ReaderImageObservedFailure? failureFor(Object error) {
    for (final failure in _failures) {
      if (identical(failure.error, error)) return failure;
    }
    return null;
  }

  ReaderImageStage? stageFor(Object error) => failureFor(error)?.stage;
  ReaderImageFacts factsFor(Object error) =>
      failureFor(error)?.facts ?? _facts.withReason(_reasonHints[error]);

  void mergeFacts(ReaderImageFacts facts) {
    if (_closed || _isCancelled?.call() == true) return;
    // A failure's reason never becomes a mutable "last reason" for later work.
    _facts = _facts.merge(facts).withReason(null);
  }

  void hint(Object error, ReaderImageReason reason) {
    if (_closed || _isCancelled?.call() == true) return;
    if (failureFor(error) != null) return;
    _reasonHints[error] = reason;
    while (_reasonHints.length > maximumFailures) {
      _reasonHints.remove(_reasonHints.keys.first);
    }
  }

  void attachSink(void Function(ReaderImageObservedFailure) sink) {
    if (!_closed) _sink = sink;
  }

  void detachSink() {
    _sink = null;
  }

  void record(ReaderImageStage stage, Object error, StackTrace stackTrace) {
    if (_closed || _isCancelled?.call() == true) return;
    // Innermost origin wins only within THIS execution. Retries use new owners.
    if (failureFor(error) != null) return;
    final failure = ReaderImageObservedFailure(
      stage: stage,
      error: error,
      stackTrace: stackTrace,
      executionId: executionId,
      facts: _facts.withReason(_reasonHints.remove(error)),
    );
    _failures.addLast(failure);
    while (_failures.length > maximumFailures) {
      _failures.removeFirst();
    }
    try {
      _sink?.call(failure);
    } catch (_) {}
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _sink = null;
    _failures.clear();
    _reasonHints.clear();
    _facts = const ReaderImageFacts();
  }

  static T run<T>(ReaderImageObservation observation, T Function() body) =>
      runZoned(body, zoneValues: {_zoneKey: observation});
}

void observeReaderImageFacts({
  ReaderHttpStatusClass httpStatusClass = ReaderHttpStatusClass.unknown,
  ReaderEncodingContract encodingContract = ReaderEncodingContract.unknown,
  bool? rawCacheHit,
  bool? onlineCacheHit,
  bool? processedCacheHit,
}) {
  try {
    ReaderImageObservation.current?.mergeFacts(ReaderImageFacts(
      httpStatusClass: httpStatusClass,
      encodingContract: encodingContract,
      rawCacheHit: rawCacheHit,
      onlineCacheHit: onlineCacheHit,
      processedCacheHit: processedCacheHit,
    ));
  } catch (_) {}
}

/// Annotate a known refusal at its ORIGINAL throw site. Returns the identical
/// object and never throws, so the original throw and its stack stay intact.
T observeReaderImageReason<T extends Object>(
    T error, ReaderImageReason reason) {
  try {
    ReaderImageObservation.current?.hint(error, reason);
  } catch (_) {}
  return error;
}

void observeReaderImageFailure(
    ReaderImageStage stage, Object error, StackTrace stackTrace) {
  try {
    ReaderImageObservation.current?.record(stage, error, stackTrace);
  } catch (_) {}
}

Future<T> observeReaderImageStage<T>(
    ReaderImageStage stage, Future<T> Function() body) async {
  try {
    return await body();
  } catch (error, stack) {
    observeReaderImageFailure(stage, error, stack);
    rethrow;
  }
}

void forwardReaderImageFacts(ReaderImageObservation? shared) {
  if (shared == null) return;
  try {
    ReaderImageObservation.current?.mergeFacts(shared.facts);
  } catch (_) {}
}

void forwardReaderImageStage(
    ReaderImageObservation? shared, Object error, StackTrace stackTrace) {
  if (shared == null) return;
  try {
    final target = ReaderImageObservation.current;
    if (target == null || identical(target, shared)) return;
    final failure = shared.failureFor(error);
    final facts = shared.factsFor(error);
    target.mergeFacts(facts);
    final reason = facts.reasonHint;
    if (reason != null) target.hint(error, reason);
    if (failure != null) target.record(failure.stage, error, stackTrace);
  } catch (_) {}
}

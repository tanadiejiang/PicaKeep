import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import '../image_loader/reader_image_retry.dart';
import '../image_loader/reader_image_limits.dart';
import '../image_loader/reader_image_observation.dart';
import '../../network/http_image_body.dart';
import 'image_disk_quota.dart';
import 'package:picakeep_image_engine/picakeep_image_engine.dart';

import '../log.dart';
import 'image_work_scheduler.dart';
import 'reader_raster_backend.dart';

class ReaderSourceSnapshotMismatch implements Exception {
  ReaderSourceSnapshotMismatch({
    required FileStat expected,
    required FileStat current,
    required bool sourceIdentityMatches,
  }) : snapshot = Map.unmodifiable({
          'expectedFileType': expected.type.toString(),
          'currentFileType': current.type.toString(),
          'expectedFileSize': expected.size,
          'currentFileSize': current.size,
          'expectedModifiedMicros': expected.modified.microsecondsSinceEpoch,
          'currentModifiedMicros': current.modified.microsecondsSinceEpoch,
          'expectedChangedMicros': expected.changed.microsecondsSinceEpoch,
          'currentChangedMicros': current.changed.microsecondsSinceEpoch,
          'expectedAccessedMicros': expected.accessed.microsecondsSinceEpoch,
          'currentAccessedMicros': current.accessed.microsecondsSinceEpoch,
          'fileTypeMatches': current.type == expected.type,
          'currentIsFile': current.type == FileSystemEntityType.file,
          'fileSizeMatches': current.size == expected.size,
          'modifiedMatches': current.modified == expected.modified,
          'changedMatches': current.changed == expected.changed,
          'accessedMatches': current.accessed == expected.accessed,
          'sourceIdentityMatches': sourceIdentityMatches,
        });

  final Map<String, Object?> snapshot;

  @override
  String toString() =>
      'Original source changed after its metadata was resolved (snapshot mismatch)';
}

/// A resident admission reports the actual request and remaining capacity.
/// [snapshot] also retains both limits when multiple surfaces compete.
class ReaderResidentBudgetExceeded extends ImageWorkBudgetExceeded {
  ReaderResidentBudgetExceeded({
    required int requestBytes,
    required int availableBytes,
    required this.snapshot,
  }) : super(requestBytes, availableBytes);

  factory ReaderResidentBudgetExceeded.fromUsage({
    required int requestBytes,
    required int localUsage,
    required int globalUsage,
    required int localLimit,
    required int globalLimit,
    bool alreadyPending = false,
    Map<String, Object?> snapshot = const {},
  }) {
    // Handoff verification can fail after charging its own pending pixels.
    // Describe available capacity before that request, without counting it twice.
    final countedRequest = alreadyPending ? requestBytes : 0;
    final localBeforeRequest = localUsage - countedRequest;
    final globalBeforeRequest = globalUsage - countedRequest;
    final localAvailable = max(0, localLimit - localBeforeRequest);
    final globalAvailable = max(0, globalLimit - globalBeforeRequest);
    final globalIsTighter = globalAvailable < localAvailable;
    final available = globalIsTighter ? globalAvailable : localAvailable;
    return ReaderResidentBudgetExceeded(
        requestBytes: requestBytes,
        availableBytes: available,
        snapshot: {
          ...snapshot,
          'requestBytes': requestBytes,
          'currentUsage':
              globalIsTighter ? globalBeforeRequest : localBeforeRequest,
          'limitBytes': globalIsTighter ? globalLimit : localLimit,
          'availableBytes': available,
          'localAvailableBytes': localAvailable,
          'globalAvailableBytes': globalAvailable,
          'localLimitBytes': localLimit,
          'globalLimitBytes': globalLimit,
          'localExceeded': localBeforeRequest + requestBytes > localLimit,
          'globalExceeded': globalBeforeRequest + requestBytes > globalLimit,
          'alreadyPending': alreadyPending,
        });
  }

  final Map<String, Object?> snapshot;
}

/// Diagnostics are subordinate to reading: no filesystem reads, raw URLs or
/// exception messages enter these events, and failures in the writer are ignored.
class ReaderFailureDiagnosticsSession {
  ReaderFailureDiagnosticsSession({void Function(String)? writer})
      : _writer = writer,
        _salt = '${DateTime.now().microsecondsSinceEpoch}:'
            '${Random().nextInt(1 << 32)}';

  static const maximumPages = 256;
  static const maximumEventLength = 3000;
  final void Function(String)? _writer;
  final String _salt;
  final _pages = <String, ReaderFailurePageDiagnostics>{};
  bool _disposed = false;

  ReaderFailurePageDiagnostics page({
    required String logicalIdentity,
    required int chapter,
    required int page,
    required String readingMode,
  }) {
    final key = _digest('$_salt:$logicalIdentity:$chapter:$page');
    final existing = _pages.remove(key);
    final result = existing ??
        ReaderFailurePageDiagnostics._(this, key, chapter, page, readingMode);
    result.readingMode = readingMode;
    if (_pages.length >= maximumPages) {
      _pages.remove(_pages.keys.first)?._attempt?.close();
    }
    _pages[key] = result;
    return result;
  }

  void _write(Map<String, Object?> event) {
    if (_disposed || !LogManager.recordingEnabled) return;
    try {
      var encoded = jsonEncode(event);
      if (encoded.length > maximumEventLength) {
        final compact = Map<String, Object?>.of(event)
          ..remove('stack')
          ..remove('snapshot')
          ..['detailsOmitted'] = true;
        encoded = jsonEncode(compact);
      }
      if (encoded.length > maximumEventLength) return;
      if (_writer != null) {
        _writer(encoded);
      } else if (event['event'] == 'failure') {
        Log.warning('ReaderImage', encoded);
      } else {
        Log.info('ReaderImage', encoded);
      }
    } catch (_) {}
  }

  void dispose() {
    if (_disposed) return;
    for (final page in _pages.values) {
      page._attempt?.close();
    }
    _pages.clear();
    _disposed = true;
  }
}

class ReaderFailurePageDiagnostics {
  ReaderFailurePageDiagnostics._(
      this._session, this.pageKey, this.chapter, this.page, this.readingMode);

  final ReaderFailureDiagnosticsSession _session;
  final String pageKey;
  final int chapter, page;
  String readingMode;
  int _attemptCount = 0;
  ReaderFailureAttemptDiagnostics? _attempt;

  ReaderFailureAttemptDiagnostics beginAttempt({
    required int generation,
    required String qualityMode,
    bool explicitRetry = false,
  }) {
    final awaitingRecovery =
        explicitRetry || (_attempt?._awaitingRecovery ?? false);
    _attempt?.close();
    final attempt = ReaderFailureAttemptDiagnostics._(
        this, ++_attemptCount, generation, qualityMode);
    attempt._awaitingRecovery = awaitingRecovery;
    _attempt = attempt;
    if (explicitRetry) attempt._emit('explicitRetry');
    return attempt;
  }
}

class ReaderFailureAttemptDiagnostics {
  ReaderFailureAttemptDiagnostics._(
      this._page, this.attempt, this.generation, this.qualityMode);

  final ReaderFailurePageDiagnostics _page;
  final int attempt, generation;
  String qualityMode;
  final _source = <String, Object?>{};
  final _failures = <String, int>{};
  final _retries = <String>{};
  String? _renderer;
  int _failureCount = 0, _summarizedCount = 0;
  int _recoveryCount = 0;
  bool _awaitingRecovery = false, _closed = false;

  bool get awaitingRecovery => !_closed && _awaitingRecovery;

  void updateQualityMode(String mode) {
    if (_closed) return;
    qualityMode = mode;
  }

  ReaderFailureAttemptDiagnostics explicitRetry({required int generation}) {
    final next =
        _page.beginAttempt(generation: generation, qualityMode: qualityMode);
    next._awaitingRecovery = true;
    next._source.addAll(_source);
    next._renderer = _renderer;
    next._emit('explicitRetry');
    return next;
  }

  void updateSource({
    String? sourceVersion,
    String? sourceType,
    String? backendType,
    int? fileLength,
    int? fileModifiedMillis,
    double? width,
    double? height,
    String? format,
  }) {
    if (_closed) return;
    final updates = <String, Object?>{
      if (sourceVersion != null) 'sourceVersionHash': _digest(sourceVersion),
      'sourceType': sourceType,
      'backendType': backendType,
      'fileLength': fileLength,
      'fileModifiedMillis': fileModifiedMillis,
      'width': width,
      'height': height,
      'format': format,
    }..removeWhere((_, value) => value == null);
    _source.addAll(_safeSnapshot(updates));
  }

  void failure({
    required String stage,
    required Object error,
    StackTrace? stackTrace,
    Map<String, Object?> snapshot = const {},
    bool terminal = true,
    ReaderImageReason? reasonHint,
  }) {
    if (_closed ||
        readerFailureIsCancellation(error) ||
        error is ReaderPreparedReadMiss ||
        _page._session._disposed) {
      return;
    }
    final reason = reasonHint?.name ?? _reason(error);
    final safeStage = _token(stage) ?? 'unknown';
    final details = <String, Object?>{...snapshot};
    if (error is DioException && error.response?.statusCode != null) {
      details['httpStatusClass'] =
          readerHttpStatusClass(error.response!.statusCode).name;
    }
    final factSignature = _safeSnapshot({
      'httpStatusClass': details['httpStatusClass'] ?? 'unknown',
      'encodingContract': details['encodingContract'] ?? 'unknown',
      'rawCacheHit': details['rawCacheHit'],
      'onlineCacheHit': details['onlineCacheHit'],
      'processedCacheHit': details['processedCacheHit'],
    });
    final key = '$safeStage:$reason:$terminal:${jsonEncode(factSignature)}';
    _failureCount++;
    _awaitingRecovery = true;
    if (_failures.containsKey(key)) {
      _failures[key] = _failures[key]! + 1;
      return;
    }
    if (_failures.length >= 32) return;
    _failures[key] = 1;
    if (error is ImageDiskQuotaExceeded) {
      details.addAll({
        'requestBytes': error.requestedBytes,
        'availableBytes': error.availableBytes
      });
    }
    if (error is ReaderResidentBudgetExceeded) {
      details.addAll(error.snapshot);
    } else if (error is ImageWorkBudgetExceeded) {
      details.addAll({
        'requestBytes': error.requestedBytes,
        'availableBytes': error.budgetBytes,
      });
    }
    if (error is ReaderSourceSnapshotMismatch) {
      details.addAll(error.snapshot);
    }
    if (error is ImageWorkQueueExceeded) {
      details.addAll({'queueLane': error.lane.name, 'queueLimit': error.limit});
    } else if (error is ImageEngineQueueExceeded) {
      details.addAll({'queueLane': 'execution', 'queueLimit': error.limit});
    }
    if (error is ReaderRasterDimensionMismatch) {
      details.addAll({
        'expectedWidth': error.expectedSize.width,
        'expectedHeight': error.expectedSize.height,
        'actualWidth': error.actualSize.width,
        'actualHeight': error.actualSize.height,
      });
    }
    _emit('failure',
        fields: {
          'stage': safeStage,
          'reason': reason,
          'errorType': _token(error.runtimeType.toString()) ?? 'unknown',
          if (error is ImageEngineException) 'nativeCode': error.code,
          'terminal': terminal,
          'failureCount': _failureCount,
          if (stackTrace != null) 'stack': _safeStack(stackTrace),
        },
        snapshot: details);
  }

  void retry({
    required String stage,
    required int retry,
    Map<String, Object?> snapshot = const {},
  }) {
    if (_closed || _retries.length >= 16) return;
    final key = '$stage:$retry';
    if (!_retries.add(key)) return;
    _emit('retryScheduled',
        fields: {
          'stage': _token(stage) ?? 'unknown',
          'retry': retry,
        },
        snapshot: snapshot);
  }

  void rendererPath(String path) {
    if (_closed || _renderer == path) return;
    _renderer = _token(path);
    // Only the uncovered renderer requires a standalone event on success.
    if (_renderer == 'compatibility') _emit('rendererPath');
  }

  void recovered({Map<String, Object?> snapshot = const {}}) {
    if (_closed || !_awaitingRecovery) return;
    if (_recoveryCount++ < 8) {
      _emit('recovered',
          fields: {'failureCount': _failureCount}, snapshot: snapshot);
    }
    _summarizedCount = _failureCount;
    _awaitingRecovery = false;
  }

  void close() {
    if (_closed) return;
    if (_failureCount > _summarizedCount && _failureCount > _failures.length) {
      _emit('failureSummary', fields: {'failureCount': _failureCount});
    }
    _closed = true;
  }

  void _emit(String event,
      {Map<String, Object?> fields = const {},
      Map<String, Object?> snapshot = const {}}) {
    _page._session._write({
      'event': event,
      'pageKey': _page.pageKey,
      'chapter': _page.chapter,
      'page': _page.page,
      'attempt': attempt,
      'generation': generation,
      'readingMode': _token(_page.readingMode) ?? 'unknown',
      'qualityMode': _token(qualityMode) ?? 'unknown',
      if (_renderer != null) 'rendererPath': _renderer,
      ...fields,
      if (_source.isNotEmpty || snapshot.isNotEmpty)
        'snapshot': {..._source, ..._safeSnapshot(snapshot)},
    });
  }
}

String _digest(String value) => sha256.convert(utf8.encode(value)).toString();

String? _token(String? value) =>
    value != null && RegExp(r'^[a-zA-Z0-9_.-]{1,80}$').hasMatch(value)
        ? value
        : null;

String _reason(Object error) {
  if (error is ReaderImageLimit) {
    return switch (error.reason) {
      'encoded-input' => 'encodedInputLimit',
      'source-pixels' => 'sourcePixelLimit',
      'codec-work' || 'provider-overhead' => 'workBudget',
      'input-residency' ||
      'input-metadata-residency' ||
      'shared-residency' =>
        'residentBudget',
      'queue' => 'queueFull',
      'unbounded-provider' => 'unboundedProvider',
      'jm-recombine-budget' => 'transformBudget',
      'jm-recombine-animation' => 'unsupportedTransform',
      _ => 'imageLimit',
    };
  }
  if (error is HttpImageBodyException) {
    return switch (error.reason) {
      'unsupported-content-encoding' => 'unsupportedEncoding',
      'invalid-content-length' => 'invalidLength',
      'maximum-bytes-exceeded' => 'inputLimit',
      'body-length-mismatch' => 'lengthMismatch',
      'empty-body' => 'emptyBody',
      _ => 'bodyContract',
    };
  }
  if (error is ImageDiskQuotaExceeded) return 'diskAdmission';
  if (error is DioException) {
    return switch (error.type) {
      DioExceptionType.badResponse => 'httpStatus',
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout =>
        'timeout',
      DioExceptionType.badCertificate => 'tls',
      DioExceptionType.connectionError => 'network',
      _ => 'other',
    };
  }
  if (error is TimeoutException) return 'timeout';
  if (error is TlsException || error is HandshakeException) return 'tls';
  if (error is SocketException || error is HttpException) return 'network';
  if (error is ReaderSourceSnapshotMismatch) return 'sourceChanged';
  if (error is ReaderResidentBudgetExceeded) return 'residentBudget';
  if (error is ReaderRasterDimensionMismatch) return 'dimensionMismatch';
  if (error is ImageWorkQueueExceeded || error is ImageEngineQueueExceeded) {
    return 'queueFull';
  }
  if (error is ImageWorkBudgetExceeded) return 'workBudget';
  if (error is ImageEngineException) {
    return error.isResourceLimited ? 'nativeResourceLimit' : 'nativeError';
  }
  if (error is StateError &&
      const {
        'Original source changed after its metadata was resolved',
        'Original source changed while this page was selected',
        'Resolved original no longer matches the selected page',
      }.contains(error.message)) {
    return 'sourceChanged';
  }
  // No exception message, path, URL or OS error text is copied into the log.
  return error is FileSystemException ? 'fileIO' : 'other';
}

String _safeStack(StackTrace stack) {
  final names = <String>[];
  try {
    for (final line in stack.toString().split('\n').take(5)) {
      final match = RegExp(r'^#\d+\s+([a-zA-Z0-9_.<>]+)').firstMatch(line);
      if (match != null) {
        names
            .add(match.group(1)!.substring(0, min(72, match.group(1)!.length)));
      }
    }
  } catch (_) {}
  return names.join(',');
}

bool readerFailureIsCancellation(Object error) =>
    error is ImageWorkCancelled ||
    error is ReaderImageCancelled ||
    error is DioException && error.type == DioExceptionType.cancel ||
    error is ImageEngineException && error.isCancelled;

Map<String, Object?> _safeSnapshot(Map<String, Object?> input) {
  const allowed = {
    'sourceVersionHash',
    'sourceType',
    'backendType',
    'fileLength',
    'fileModifiedMillis',
    'width',
    'height',
    'format',
    'generation',
    'operationId',
    'executionId',
    'replayed',
    'httpStatusClass',
    'encodingContract',
    'rawCacheHit',
    'onlineCacheHit',
    'processedCacheHit',
    'tileWidth',
    'tileHeight',
    'density',
    'retry',
    'active',
    'pending',
    'reservedBytes',
    'workingBytes',
    'requestBytes',
    'availableBytes',
    'currentUsage',
    'limitBytes',
    'localResidentBytes',
    'localPendingBytes',
    'globalResidentBytes',
    'globalPendingBytes',
    'retainedBytes',
    'localLimitBytes',
    'globalLimitBytes',
    'localAvailableBytes',
    'globalAvailableBytes',
    'localExceeded',
    'globalExceeded',
    'queueLane',
    'queueLimit',
    'expectedWidth',
    'expectedHeight',
    'actualWidth',
    'actualHeight',
    'surfaceGeneration',
    'desiredCount',
    'missingCount',
    'preview',
    'preparedAdmission',
    'alreadyPending',
    'expectedFileType',
    'currentFileType',
    'expectedFileSize',
    'currentFileSize',
    'expectedModifiedMicros',
    'currentModifiedMicros',
    'expectedChangedMicros',
    'currentChangedMicros',
    'expectedAccessedMicros',
    'currentAccessedMicros',
    'fileTypeMatches',
    'currentIsFile',
    'fileSizeMatches',
    'modifiedMatches',
    'changedMatches',
    'accessedMatches',
    'sourceIdentityMatches',
  };
  final result = <String, Object?>{};
  for (final entry in input.entries) {
    if (!allowed.contains(entry.key)) continue;
    final value = entry.value;
    if (entry.key == 'httpStatusClass') {
      result[entry.key] = value is String &&
              ReaderHttpStatusClass.values.any((v) => v.name == value)
          ? value
          : 'unknown';
      continue;
    }
    if (entry.key == 'encodingContract') {
      result[entry.key] = value is String &&
              ReaderEncodingContract.values.any((v) => v.name == value)
          ? value
          : 'unknown';
      continue;
    }
    if (const {'rawCacheHit', 'onlineCacheHit', 'processedCacheHit'}
        .contains(entry.key)) {
      result[entry.key] = value is bool ? value : null;
      continue;
    }
    if (value == null || value is bool || value is num && value.isFinite) {
      result[entry.key] = value;
    } else if (value is String) {
      result[entry.key] = _token(value) ?? 'unavailable';
    }
  }
  return result;
}

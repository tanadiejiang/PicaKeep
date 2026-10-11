import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:picakeep/foundation/image_loader/stream_image_provider.dart';
import 'package:picakeep/foundation/image_pipeline/reader_page_source.dart';

typedef LocalJmPageRecombiner = Future<({Uint8List bytes, String extension})>
    Function(
  Uint8List bytes, {
  required String epsId,
  required String scrambleId,
  required String pictureName,
  required String originalExtension,
});

/// A reader can stop waiting before a non-preemptible recombine returns, but
/// disposal must await [settled] before considering that backend work drained.
class LocalJmPageRepairTicket {
  LocalJmPageRepairTicket(this.file, this.settled, this.cancel);

  final Future<File> file;
  final Future<void> settled;
  final void Function() cancel;
}

/// Bounded admission shared by local JM reader instances. No raw/decoded bytes
/// are allocated for queued pages. Finished entries retain paths, never pixels.
class LocalJmPageRepairQueue {
  LocalJmPageRepairQueue._();

  static final shared = LocalJmPageRepairQueue._();
  static const maximumPending = 32;
  final _jobs = <String, _RepairJob>{};
  final _pending = <_RepairJob>[];
  final _completed = <String, File>{};
  bool _working = false;

  File? completedFile(String key) => _completed[key];

  LocalJmPageRepairTicket request({
    required String key,
    required Future<File> Function(
            StreamImageAbortSignal abort, CancelToken token)
        run,
    StreamImageAbortSignal? abortSignal,
  }) {
    if (abortSignal?.isAborted == true) {
      throw StateError('Local image repair cancelled');
    }
    var job = _jobs[key];
    if (job == null || job.abort.isAborted) {
      if (_pending.length >= maximumPending) {
        throw StateError('Local image repair queue is full');
      }
      job = _RepairJob(key, run, Zone.current);
      _jobs[key] = job;
      _pending.add(job);
    }
    final current = job;
    final consumer = Object();
    final abort = StreamImageAbortSignal();
    current.consumers.add(consumer);
    if (abortSignal != null) {
      unawaited(abortSignal.aborted.then((_) => abort.abort()));
    }
    void release() {
      if (!current.consumers.remove(consumer) || current.finished) return;
      if (current.consumers.isEmpty) {
        current.abort.abort();
        current.token.cancel('Local image repair cancelled');
        if (!current.running) {
          _pending.remove(current);
          _finish(current, error: StateError('Local image repair cancelled'));
        }
      }
    }

    final cancelled = abort.aborted.then<File>((_) {
      release();
      throw StateError('Local image repair cancelled');
    });
    Future<File> wait() async {
      try {
        final file = await Future.any([current.result.future, cancelled]);
        if (abort.isAborted || abortSignal?.isAborted == true) {
          throw StateError('Local image repair cancelled');
        }
        return file;
      } finally {
        release();
      }
    }

    final waiting = wait();
    scheduleMicrotask(_startNext);
    return LocalJmPageRepairTicket(
        waiting, current.settled.future, abort.abort);
  }

  void _finish(_RepairJob job, {File? file, Object? error, StackTrace? stack}) {
    if (job.finished) return;
    job.finished = true;
    if (identical(_jobs[job.key], job)) _jobs.remove(job.key);
    if (file != null) {
      _completed.remove(job.key);
      _completed[job.key] = file;
      if (_completed.length > 128) _completed.remove(_completed.keys.first);
      job.result.complete(file);
    } else {
      job.result.completeError(error!, stack ?? StackTrace.current);
    }
    job.settled.complete();
  }

  void _startNext() {
    if (_working || _pending.isEmpty) return;
    _working = true;
    final job = _pending.removeAt(0)..running = true;
    unawaited(() async {
      try {
        if (job.abort.isAborted) {
          throw StateError('Local image repair cancelled');
        }
        // Preserve the request's managed-retry Zone, not the preceding job's.
        final file = await job.zone.run(() => job.run(job.abort, job.token));
        if (job.abort.isAborted) {
          throw StateError('Local image repair cancelled');
        }
        _finish(job, file: file);
      } catch (error, stack) {
        _finish(job, error: error, stack: stack);
      } finally {
        _working = false;
        _startNext();
      }
    }());
  }
}

class _RepairJob {
  _RepairJob(this.key, this.run, this.zone);
  final String key;
  final Future<File> Function(StreamImageAbortSignal, CancelToken) run;
  final Zone zone;
  final abort = StreamImageAbortSignal();
  final token = CancelToken();
  final consumers = <Object>{};
  final result = Completer<File>();
  final settled = Completer<void>();
  bool running = false;
  bool finished = false;
}

/// A repaired page belongs to the downloaded library, not a temporary cache.
/// Header inspection is bounded Dart IO only; it never invokes a native codec.
class LocalJmRepairReaderSource extends DeferredReaderPageSource {
  factory LocalJmRepairReaderSource({
    required ReaderPageIdentity identity,
    required LocalJmPageRepairTicket Function(StreamImageAbortSignal) open,
  }) {
    final metadata = _RepairMetadata();
    LocalJmPageRepairTicket? ticket;
    return LocalJmRepairReaderSource._(
      metadata,
      identity: identity,
      opener: (cancellation) async {
        final abort = StreamImageAbortSignal();
        if (cancellation.isCancelled) abort.abort();
        unawaited(cancellation.cancelled.then((_) => abort.abort()));
        ticket = open(abort);
        final file = await ticket!.file;
        cancellation.throwIfCancelled();
        final handle = await file.open();
        try {
          final type = readerPageTypeFromHeader(await handle.read(32));
          metadata.extension = type.extension;
          metadata.mime = type.mime;
          metadata.length = await handle.length();
        } finally {
          await handle.close();
        }
        cancellation.throwIfCancelled();
        return file;
      },
      onDispose: () async {
        ticket?.cancel();
        await ticket?.settled;
      },
    );
  }

  LocalJmRepairReaderSource._(this._metadata,
      {required super.identity,
      required super.opener,
      required super.onDispose})
      : super(ownsFile: false);

  final _RepairMetadata _metadata;
  @override
  String? get extension => _metadata.extension;
  @override
  String? get mimeType => _metadata.mime;
  @override
  int? get byteLength => _metadata.length;
}

class _RepairMetadata {
  String? extension;
  String? mime;
  int? length;
}

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:picakeep_image_engine/picakeep_image_engine.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    throw ArgumentError('dart_worker_pool_test.dart fixturePath backingPath');
  }
  if (!PicakeepImageEngine.isAvailable) {
    throw StateError('Native image engine is unavailable');
  }
  const engine = PicakeepImageEngine();
  final path = arguments[0];
  final backing = arguments[1];
  final metadata = await engine.probe(path);
  if (metadata.width <= 0 || metadata.height <= 0) {
    throw StateError('Pooled probe returned invalid metadata');
  }

  final rectangles = <NativeImageRect>[
    const NativeImageRect(0, 0, 256, 256),
    const NativeImageRect(256, 0, 256, 256),
  ];
  final initial = await Future.wait([
    for (final rect in rectangles)
      engine.decodeRegion(
        path,
        rect,
        backingPath: backing,
        memoryBudgetBytes: 64 << 20,
        diskBudgetBytes: 64 << 20,
      ),
  ]);
  final reference = Uint8List.fromList(initial.first.bytes);
  for (final result in initial) {
    if (result.width != 256 ||
        result.height != 256 ||
        result.bytes.length != 256 * 256 * 4) {
      throw StateError('Pooled decoder returned invalid pixel dimensions');
    }
    if (result.workerId <= 0) throw StateError('Missing worker identity');
  }
  for (final result in initial) {
    result.dispose();
  }

  final cancellation = NativeCancellationToken();
  try {
    final pendingCancelled = engine.decodeRegion(
      path,
      const NativeImageRect(0, 0, 64, 64),
      backingPath: backing,
      memoryBudgetBytes: 64 << 20,
      cancelToken: cancellation,
    );
    cancellation.cancel();
    final result = await pendingCancelled;
    result.dispose();
    throw StateError('A pre-cancelled pooled decode succeeded');
  } on ImageEngineException catch (error) {
    if (!error.isCancelled) rethrow;
  } finally {
    cancellation.dispose();
  }

  final reused = <NativePixelBuffer>[];
  for (var i = 0; i < 8; i++) {
    reused.add(
      await engine.decodeRegion(
        path,
        const NativeImageRect(0, 0, 256, 256),
        backingPath: backing,
        memoryBudgetBytes: 64 << 20,
        diskBudgetBytes: 64 << 20,
      ),
    );
  }
  final ids = reused.map((result) => result.workerId).toSet();
  if (ids.length > 2) throw StateError('Worker limit exceeded: $ids');
  if (reused.any((result) => result.workerStartupMicroseconds != 0)) {
    throw StateError('Warm job unexpectedly initialized a worker');
  }
  for (final result in reused) {
    if (result.bytes.length != reference.length ||
        !result.bytes.asMap().entries.every(
          (entry) => reference[entry.key] == entry.value,
        )) {
      throw StateError('Pooled warm output pixels changed');
    }
    result.dispose();
  }
  try {
    await engine.probe('$path.worker-invalid');
    throw StateError('Invalid source probe unexpectedly succeeded');
  } on ImageEngineException {
    // A request error must leave the worker reusable.
  }
  if ((await engine.probe(path)).width != metadata.width) {
    throw StateError('Worker did not recover from request failure');
  }
  final shutdown = PicakeepImageEngine.shutdownIdleWorkers();
  final duringShutdown = engine.probe(path);
  await shutdown;
  if ((await duringShutdown).width != metadata.width) {
    throw StateError('Idle shutdown racing a request lost that request');
  }
  final capacityResults = await Future.wait([
    for (var i = 0; i < 140; i++)
      engine
          .probe(path)
          .then(
            (_) => true,
            onError: (Object error) =>
                error is ImageEngineQueueExceeded &&
                    error.limit == 128 &&
                    error.isResourceLimited
                ? false
                : throw error,
          ),
  ]);
  if (capacityResults.every((value) => value)) {
    throw StateError('Bounded worker queue accepted all 140 concurrent calls');
  }
  if (PicakeepImageEngine.workerDiagnostics['workersAlive']! > 2 ||
      PicakeepImageEngine.workerDiagnostics['queuePeak']! > 128) {
    throw StateError('Worker execution or queue bound exceeded');
  }
  await PicakeepImageEngine.shutdownIdleWorkers();
  stdout.writeln(
    jsonEncode({
      'status': 'passed',
      'metadataDimensions': [metadata.width, metadata.height],
      'workerIdsReused': ids.toList()..sort(),
      'workerDiagnostics': PicakeepImageEngine.workerDiagnostics,
      'preCancelledRequestRejected': true,
      'requestFailureRecovered': true,
      'shutdownRaceRecovered': true,
      'queueBoundRejected': capacityResults.where((value) => !value).length,
    }),
  );
}

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:picakeep_image_engine/picakeep_image_engine.dart';

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) throw ArgumentError('fixture ownedBackingPath');
  const engine = PicakeepImageEngine();
  require(
    PicakeepImageEngine.preparedReadsAvailable,
    'Prepared symbol missing',
  );
  final source = arguments[0], backing = arguments[1];
  const rect = NativeImageRect(31, 73, 129, 137);
  await engine.prepareBacking(
    source,
    backingPath: backing,
    memoryBudgetBytes: 96 << 20,
    diskBudgetBytes: 32 << 20,
  );
  final raw = await engine.decodeRegion(
    source,
    rect,
    backingPath: backing,
    memoryBudgetBytes: 96 << 20,
    diskBudgetBytes: 32 << 20,
  );
  final reference = Uint8List.fromList(raw.bytes);
  raw.dispose();
  final read = await engine.decodeRegion(
    source,
    rect,
    backingPath: backing,
    memoryBudgetBytes: 96 << 20,
    diskBudgetBytes: 0,
    preparedOnly: true,
  );
  require(
    read.bytes.length == reference.length &&
        read.bytes.asMap().entries.every((e) => e.value == reference[e.key]),
    'Prepared pixels changed',
  );
  require(
    read.diskBytes == await File(backing).length(),
    'Existing occupancy lost',
  );
  read.dispose();
  Future<void> expectCode(int code, Future<NativePixelBuffer> call) async {
    try {
      (await call).dispose();
      throw StateError('Expected native code $code');
    } on ImageEngineException catch (error) {
      require(error.code == code, 'Expected $code, got ${error.code}');
    }
  }

  await expectCode(
    5,
    engine.decodeRegion(
      source,
      rect,
      backingPath: '$backing.missing',
      preparedOnly: true,
    ),
  );
  for (final budget in [0, 1, 1024]) {
    await expectCode(
      3,
      engine.decodeRegion(
        source,
        rect,
        backingPath: backing,
        preparedOnly: true,
        memoryBudgetBytes: budget,
      ),
    );
  }
  final token = NativeCancellationToken()..cancel();
  try {
    await expectCode(
      2,
      engine.decodeRegion(
        source,
        rect,
        backingPath: backing,
        preparedOnly: true,
        cancelToken: token,
      ),
    );
  } finally {
    token.dispose();
  }
  final diagnostics = PicakeepImageEngine.workerDiagnostics;
  require(diagnostics['jobsFailed'] == 5, 'Aggregate failure count changed');
  for (final code in [2, 3, 5]) {
    require(
      diagnostics['jobsFailedCode$code'] == (code == 3 ? 3 : 1),
      'Missing failure code $code',
    );
  }
  require(diagnostics['jobsFailedNonNative'] == 0, 'Unexpected worker failure');
  await PicakeepImageEngine.shutdownIdleWorkers();
  stdout.writeln(
    jsonEncode({
      'status': 'passed',
      'pixelsExact': true,
      'existingBackingBytes': await File(backing).length(),
      'failureCodesPreserved': [2, 3, 5],
      'diagnostics': diagnostics,
    }),
  );
}

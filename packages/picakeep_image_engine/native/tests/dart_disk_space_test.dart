import 'dart:convert';
import 'dart:io';
import 'package:picakeep_image_engine/picakeep_image_engine.dart';

Future<void> main(List<String> args) async {
  if (args.length == 3 && args.first == '--unavailable') {
    const engine = PicakeepImageEngine();
    final available = PicakeepImageEngine.isAvailable;
    final metadata = available ? await engine.probe(args[1]) : null;
    try {
      await engine.availableDiskSpace(File(args[1]).parent.path);
      throw StateError('Unavailable native query was accepted');
    } on ImageEngineException catch (error) {
      if (error.code != 4) rethrow;
      File(args[2]).writeAsStringSync(
        jsonEncode({
          'imageEngineAvailable': available,
          'existingProbeWidth': metadata?.width,
          'queryErrorCode': error.code,
          'queryError': error.message,
        }),
      );
    }
    await PicakeepImageEngine.shutdownIdleWorkers();
    print(
      'PASS: unavailable query fails explicitly; older image ABI still probes',
    );
    return;
  }
  if (args.length != 4) {
    throw ArgumentError('existingDirectory existingFile absentPath outputJson');
  }
  const engine = PicakeepImageEngine();
  final records = <String, Object?>{};
  for (var i = 0; i < 3; i++) {
    final result = await engine.availableDiskSpace(args[i]);
    if (result.availableBytes < 0 || result.volumeId.isEmpty) {
      throw StateError('Invalid OS disk result');
    }
    records['path$i'] = {
      'path': args[i],
      'availableBytes': result.availableBytes,
      'volumeId': result.volumeId,
    };
  }
  final parent = records['path0']! as Map<String, Object>;
  final absent = records['path2']! as Map<String, Object>;
  if (parent['volumeId'] != absent['volumeId']) {
    throw StateError('Nearest ancestor must report the same volume');
  }
  final invalid = <String>[];
  for (final path in ['', 'relative-output.rgba', '${args[0]}\u0000tail']) {
    try {
      await engine.availableDiskSpace(path);
      throw StateError('Invalid path was accepted');
    } on ImageEngineException catch (error) {
      if (error.code != 1) rethrow;
      invalid.add(error.message);
    }
  }
  records['invalidPathFailures'] = invalid;
  records['convenienceAvailableBytes'] = await engine.availableDiskBytes(
    args[0],
  );
  records['absentPathCreated'] =
      File(args[2]).existsSync() || Directory(args[2]).existsSync();
  if (records['absentPathCreated'] == true) {
    throw StateError('Read-only query created output');
  }
  File(
    args[3],
  ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(records));
  print(
    'PASS: existing directory/file, absent ancestor, invalid paths, no writes',
  );
}

import 'dart:convert';
import 'dart:io';

// Builds a test-only library from exact production files so private pool fault
// injection never becomes a public API or a product environment switch.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 3) {
    throw ArgumentError(
      'dart_worker_pool_lifecycle_test.dart fixture backing outputDirectory',
    );
  }
  final testDirectory = File.fromUri(Platform.script).parent;
  final packageDirectory = testDirectory.parent.parent;
  final output = Directory(arguments[2]).absolute;
  final sourceDirectory = Directory('${output.path}/src');
  await sourceDirectory.create(recursive: true);
  final production = File(
    '${packageDirectory.path}/lib/picakeep_image_engine.dart',
  );
  final cases = File(
    '${testDirectory.path}/dart_worker_pool_lifecycle_cases.txt',
  );
  final generated = File('${output.path}/picakeep_image_engine.dart');
  await generated.writeAsString(
    "import 'dart:convert';\n${await production.readAsString()}\n"
    '${await cases.readAsString()}',
  );
  for (final filename in ['bindings.dart', 'worker_pool.dart']) {
    await File(
      '${packageDirectory.path}/lib/src/$filename',
    ).copy('${sourceDirectory.path}/$filename');
  }
  final configuration = File('.dart_tool/package_config.json').absolute;
  if (!await configuration.exists()) {
    throw StateError('Run from the project with its existing package config');
  }
  // Resolve package roots before copying config to a different drive.
  final config = jsonDecode(await configuration.readAsString());
  for (final package in config['packages'] as List) {
    package['rootUri'] = configuration.uri
        .resolve(package['rootUri'] as String)
        .toString();
  }
  final generatedConfig = File('${output.path}/.dart_tool/package_config.json');
  await generatedConfig.parent.create(recursive: true);
  await generatedConfig.writeAsString(jsonEncode(config));
  final analysis = await Process.run(Platform.resolvedExecutable, [
    'analyze',
    generated.path,
  ]);
  stderr.write(analysis.stdout);
  stderr.write(analysis.stderr);
  if (analysis.exitCode != 0) exit(analysis.exitCode);
  final result = await Process.run(
    Platform.resolvedExecutable,
    [
      '--packages=${generatedConfig.path}',
      generated.path,
      ...arguments.take(2),
    ],
    environment: {
      'PICAKEEP_LIFECYCLE_MODE_FILE': '${output.path}/worker-mode.txt',
    },
  );
  await File(
    '${output.path}/lifecycle-result.json',
  ).writeAsString(result.stdout);
  stdout.write(result.stdout);
  stderr.write(result.stderr);
  exit(result.exitCode);
}

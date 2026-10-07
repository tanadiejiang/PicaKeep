import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/verification_server_paths.dart';

class _RejectOrdinaryPaths extends PathProviderPlatform {
  @override
  Future<String?> getApplicationCachePath() async =>
      throw StateError('Ordinary application cache must not be accessed');
  @override
  Future<String?> getApplicationSupportPath() async =>
      throw StateError('Ordinary application data must not be accessed');
}

void main() {
  final root = p.join(Directory.systemTemp.absolute.path, 'pk022-task');
  test('ordinary server startup does not opt into verification isolation', () {
    expect(resolveVerificationServerPaths(['--server', '--config=x.data']),
        isNull);
  });
  test('isolated server puts data, cache and default config in one task root',
      () {
    final result = resolveVerificationServerPaths(
        ['--server', '--verification-data-root=$root'])!;
    expect(result.dataRoot, root);
    expect(result.cacheRoot, p.join(root, 'cache'));
    expect(result.configPath, p.join(root, 'picakeep_server.data'));
  });
  test('isolated config stays inside the explicitly chosen task root', () {
    final config = p.join(root, 'configuration', 'test.data');
    final result = resolveVerificationServerPaths(
        ['--server', '--verification-data-root', root, '--config', config])!;
    expect(result.configPath, config);
    for (final outside in [
      p.join(p.dirname(root), 'ordinary.data'),
      p.join(root, '..', 'ordinary.data'),
      'relative.data'
    ]) {
      expect(
          () => resolveVerificationServerPaths([
                '--server',
                '--verification-data-root=$root',
                '--config=$outside'
              ]),
          throwsArgumentError);
    }
  });
  test(
      'verification isolation rejects GUI, relative, empty and filesystem roots',
      () {
    expect(
        () =>
            resolveVerificationServerPaths(['--verification-data-root=$root']),
        throwsArgumentError);
    for (final invalid in ['', '.', 'relative', p.rootPrefix(root)]) {
      expect(
          () => resolveVerificationServerPaths(
              ['--server', '--verification-data-root=$invalid']),
          throwsArgumentError);
    }
    expect(
        () => resolveVerificationServerPaths(
            ['--server', '--verification-data-root']),
        throwsArgumentError);
  });
  test('explicit isolated App initialization never queries ordinary paths',
      () async {
    final previous = PathProviderPlatform.instance;
    final base = Platform.isWindows
        ? Directory(r'E:\picakeep-image-pipeline-022-runtime')
        : Directory.systemTemp;
    await base.create(recursive: true);
    final workspace = await base.createTemp('isolated-init-');
    PathProviderPlatform.instance = _RejectOrdinaryPaths();
    try {
      final paths = resolveVerificationServerPaths(
          ['--server', '--verification-data-root=${workspace.path}'])!;
      await App.init(
          dataPathOverride: paths.dataRoot,
          cachePathOverride: paths.cacheRoot,
          migrateExistingData: false);
      expect(App.dataPath, workspace.absolute.path);
      expect(App.cachePath, p.join(workspace.absolute.path, 'cache'));
      expect(await Directory(App.cachePath).exists(), isTrue);
    } finally {
      PathProviderPlatform.instance = previous;
      await workspace.delete(recursive: true);
    }
  });
}

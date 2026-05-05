import 'dart:io';

import 'package:picakeep/server/server_app.dart';
import 'package:picakeep/server/server_config.dart';

Future<void> main(List<String> args) async {
  final configPath = _resolveConfigPath(args);
  final server = PicaKeepAdminServer(configPath: configPath);
  await server.serve();
}

String _resolveConfigPath(List<String> args) {
  for (final arg in args) {
    if (arg.startsWith('--config=')) {
      final value = arg.substring('--config='.length).trim();
      if (value.isNotEmpty) {
        return value;
      }
    }
  }
  return '${Directory.current.path}${Platform.pathSeparator}${PicaKeepServerConfig.defaultFileName}';
}
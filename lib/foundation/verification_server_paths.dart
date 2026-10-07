import 'package:path/path.dart' as p;

/// Explicit isolation for verification of the production Flutter server entry.
/// Ordinary --server/--config startup keeps its existing data migration rules.
class VerificationServerPaths {
  const VerificationServerPaths(this.dataRoot, this.cacheRoot, this.configPath);
  final String dataRoot;
  final String cacheRoot;
  final String configPath;
}

VerificationServerPaths? resolveVerificationServerPaths(List<String> args) {
  final value = _option(args, '--verification-data-root');
  if (value == null) return null;
  if (!args.contains('--server')) {
    throw ArgumentError('--verification-data-root requires --server');
  }
  if (value.trim().isEmpty || !p.isAbsolute(value)) {
    throw ArgumentError('Verification data root must be an absolute directory');
  }
  final root = p.normalize(value);
  if (p.dirname(root) == root) {
    throw ArgumentError('Verification data root cannot be a filesystem root');
  }
  final config = _option(args, '--config');
  final configPath = config == null
      ? p.join(root, 'picakeep_server.data')
      : p.normalize(config);
  if (!p.isAbsolute(configPath) || !p.isWithin(root, configPath)) {
    throw ArgumentError('Verification config must be inside its data root');
  }
  return VerificationServerPaths(root, p.join(root, 'cache'), configPath);
}

String? _option(List<String> args, String name) {
  for (var i = 0; i < args.length; i++) {
    if (args[i].startsWith('$name=')) {
      return args[i].substring(name.length + 1).trim();
    }
    if (args[i] == name) {
      if (i + 1 >= args.length || args[i + 1].startsWith('--')) {
        throw ArgumentError('$name requires a value');
      }
      return args[i + 1].trim();
    }
  }
  return null;
}

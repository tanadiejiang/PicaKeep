import 'archive_backend.dart';
import 'archive_errors.dart';
import 'backends/dart_zip_backend.dart';

class ArchiveRegistry {
  ArchiveRegistry._();
  static final ArchiveRegistry instance = ArchiveRegistry._();

  final List<ArchiveBackend> _backends = [];

  void register(ArchiveBackend backend) {
    _backends.add(backend);
  }

  List<ArchiveBackend> get all => List.unmodifiable(_backends);

  ArchiveBackend? backendFor(String archivePath) {
    for (final backend in _backends) {
      if (backend.supportsPath(archivePath)) {
        return backend;
      }
    }
    return null;
  }

  ArchiveBackend backendForOrThrow(String archivePath) {
    final backend = backendFor(archivePath);
    if (backend == null) {
      throw ArchiveFailure(
        code: ArchiveErrorCode.unsupportedFormat,
        debugMessage: 'No backend supports: $archivePath',
      );
    }
    return backend;
  }

  static void initDefaults() {
    instance.register(DartZipBackend());
  }
}

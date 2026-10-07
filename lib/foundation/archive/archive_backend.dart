import 'dart:typed_data';
import 'dart:io';

import 'archive_models.dart';

class ArchiveBackendCapabilities {
  const ArchiveBackendCapabilities({
    this.supportsZip = false,
    this.supportsZipCrypto = false,
    this.supportsAesZip = false,
    this.canListEntriesWithoutPassword = true,
    this.canReadEntryStreaming = false,
    this.requiresExternalBinary = false,
    this.hardEntrySizeLimitBytes,
  });

  final bool supportsZip;
  final bool supportsZipCrypto;
  final bool supportsAesZip;
  final bool canListEntriesWithoutPassword;
  final bool canReadEntryStreaming;
  final bool requiresExternalBinary;
  final int? hardEntrySizeLimitBytes;
}

abstract class StreamingArchiveBackend {
  Future<File> materializeEntry(
    String archivePath,
    String entryPath,
    File destination, {
    String? password,
    int maxBytes = 2 * 1024 * 1024 * 1024,
    bool Function()? isCancelled,
  });
}

abstract class ArchiveBackend {
  String get id;
  ArchiveBackendCapabilities get capabilities;

  bool supportsPath(String archivePath);

  Future<ArchiveProbeResult> probe(String archivePath);

  Future<ArchiveIndex> openIndex(String archivePath, {String? password});

  Future<Uint8List> readEntry(
    String archivePath,
    String entryPath, {
    String? password,
  });
}

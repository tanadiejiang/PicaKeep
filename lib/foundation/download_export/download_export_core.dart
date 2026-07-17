import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';

import '../archive/archive_errors.dart';
import '../archive/archive_models.dart';
import '../archive/archive_reading_service.dart';
import '../privileged_storage_access.dart';
import 'download_export_formatter.dart';
import 'download_export_models.dart';
import 'download_export_paths.dart';

typedef DownloadExportProgressCallback = void Function(
    DownloadExportProgress progress);

class DownloadExportSourceException implements Exception {
  const DownloadExportSourceException(this.message);

  final String message;

  @override
  String toString() => message;
}

class DownloadExportRequest {
  const DownloadExportRequest({
    required this.descriptor,
    required this.source,
  });

  final DownloadExportDescriptor descriptor;
  final DownloadExportContentSource source;
}

abstract class DownloadExportContentSource {
  const DownloadExportContentSource();

  Future<List<DownloadExportSourceFile>> listFiles(
    DownloadExportCancellationToken cancellation,
  );

  /// Resolves the number of actual image files/entries represented by this
  /// source. Content sources may override this when their cover semantics
  /// differ from an ordinary directory.
  Future<int?> resolvePageCount(
    DownloadExportCancellationToken cancellation,
  ) async {
    final files = await listFiles(cancellation);
    return _countImageFiles(files);
  }
}

abstract class DownloadExportSourceFile {
  String get relativePath;

  int? get sizeBytes;

  Future<int> copyTo(
    File target,
    DownloadExportCancellationToken cancellation,
    void Function(int bytes) onBytes,
  );
}

class DownloadExportDirectorySource extends DownloadExportContentSource {
  DownloadExportDirectorySource({
    required String rootPath,
    Map<int, List<String>> episodeFiles = const {},
    Iterable<String> episodeNames = const [],
  })  : rootPath = rootPath.trim(),
        episodeFiles = {
          for (final entry in episodeFiles.entries)
            entry.key: List<String>.unmodifiable(entry.value),
        },
        episodeNames = List<String>.unmodifiable(episodeNames.toList());

  static const maxPrivilegedFallbackBytes = 32 * 1024 * 1024;

  final String rootPath;
  final Map<int, List<String>> episodeFiles;
  final List<String> episodeNames;

  @override
  Future<List<DownloadExportSourceFile>> listFiles(
    DownloadExportCancellationToken cancellation,
  ) async {
    cancellation.throwIfCancelled();
    if (rootPath.isEmpty ||
        !await PrivilegedStorageAccess.directoryExists(rootPath)) {
      throw const DownloadExportSourceException('本地目录不存在或无法访问');
    }

    final files = episodeFiles.isNotEmpty
        ? await _listIndexedFiles(cancellation)
        : await _listRecursiveFiles(rootPath, cancellation);
    if (files.isEmpty) {
      throw const DownloadExportSourceException('目录中没有可导出的文件');
    }
    return files;
  }

  @override
  Future<int?> resolvePageCount(
    DownloadExportCancellationToken cancellation,
  ) async {
    final files = await listFiles(cancellation);
    return _countImageFiles(files, excludeStandaloneCover: true);
  }

  Future<List<DownloadExportSourceFile>> _listIndexedFiles(
    DownloadExportCancellationToken cancellation,
  ) async {
    final result = <DownloadExportSourceFile>[];
    final usedPaths = <String>{};
    final episodeKeys = episodeFiles.keys.toList()..sort();
    for (final episodeKey in episodeKeys) {
      cancellation.throwIfCancelled();
      final chapterName = episodeNames.length > 1 &&
              episodeKey >= 0 &&
              episodeKey < episodeNames.length
          ? DownloadExportPathTools.sanitizeSegment(episodeNames[episodeKey])
          : '';
      final sourcePaths = episodeFiles[episodeKey] ?? const <String>[];
      final sortedPaths = sourcePaths.toList()
        ..sort((a, b) => DownloadExportPathTools.naturalCompare(a, b));
      for (final sourcePath in sortedPaths) {
        cancellation.throwIfCancelled();
        if (sourcePath.trim().isEmpty || sourcePath.startsWith('archive:')) {
          continue;
        }
        var relativePath = _relativePath(rootPath, sourcePath);
        if (relativePath.isEmpty) {
          relativePath = _basename(sourcePath);
        }
        if (chapterName.isNotEmpty && !relativePath.contains('/')) {
          relativePath = '$chapterName/$relativePath';
        }
        result.add(_uniqueLocalFile(
          sourcePath,
          relativePath,
          usedPaths,
        ));
      }
    }
    return result;
  }

  Future<List<DownloadExportSourceFile>> _listRecursiveFiles(
    String path,
    DownloadExportCancellationToken cancellation,
  ) async {
    final result = <DownloadExportSourceFile>[];
    final usedPaths = <String>{};
    Future<void> visit(String directoryPath) async {
      cancellation.throwIfCancelled();
      final entries = await PrivilegedStorageAccess.listDirectoryEntries(
        directoryPath,
      );
      entries.sort(
          (a, b) => DownloadExportPathTools.naturalCompare(a.name, b.name));
      for (final entry in entries) {
        cancellation.throwIfCancelled();
        if (entry.name == '.' || entry.name == '..') continue;
        if (entry.isDirectory) {
          await visit(entry.path);
        } else {
          final relativePath = _relativePath(rootPath, entry.path);
          result.add(_uniqueLocalFile(
            entry.path,
            relativePath.isEmpty ? entry.name : relativePath,
            usedPaths,
          ));
        }
      }
    }

    await visit(path);
    result.sort((a, b) => DownloadExportPathTools.naturalCompare(
          a.relativePath,
          b.relativePath,
        ));
    return result;
  }

  DownloadExportSourceFile _uniqueLocalFile(
    String sourcePath,
    String relativePath,
    Set<String> usedPaths,
  ) {
    return _LocalDownloadExportFile(
      sourcePath: sourcePath,
      relativePath: DownloadExportPathTools.uniqueRelativePath(
        relativePath,
        usedPaths,
      ),
    );
  }

  static String _relativePath(String root, String child) {
    final normalizedRoot = _trimTrailingSeparators(root).replaceAll('\\', '/');
    final normalizedChild = child.replaceAll('\\', '/');
    final rootLower = normalizedRoot.toLowerCase();
    final childLower = normalizedChild.toLowerCase();
    final prefix = '$rootLower/';
    if (childLower.startsWith(prefix)) {
      return DownloadExportPathTools.sanitizeRelativePath(
        normalizedChild.substring(normalizedRoot.length + 1),
      );
    }
    return DownloadExportPathTools.sanitizeSegment(_basename(child));
  }

  static String _trimTrailingSeparators(String value) {
    var result = value;
    while (
        result.length > 1 && (result.endsWith('/') || result.endsWith('\\'))) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }

  static String _basename(String value) {
    final normalized = value.replaceAll('\\', '/');
    final index = normalized.lastIndexOf('/');
    return index < 0 ? normalized : normalized.substring(index + 1);
  }
}

class DownloadExportArchiveSource extends DownloadExportContentSource {
  DownloadExportArchiveSource({
    required String archivePath,
    Map<int, List<String>> episodeFiles = const {},
    Iterable<String> episodeNames = const [],
  })  : archivePath = archivePath.trim(),
        episodeFiles = {
          for (final entry in episodeFiles.entries)
            entry.key: List<String>.unmodifiable(entry.value),
        },
        episodeNames = List<String>.unmodifiable(episodeNames.toList());

  static const maxEntryBytes = 64 * 1024 * 1024;

  final String archivePath;
  final Map<int, List<String>> episodeFiles;
  final List<String> episodeNames;

  @override
  Future<List<DownloadExportSourceFile>> listFiles(
    DownloadExportCancellationToken cancellation,
  ) async {
    cancellation.throwIfCancelled();
    if (archivePath.isEmpty ||
        !await PrivilegedStorageAccess.fileExists(archivePath)) {
      throw const DownloadExportSourceException(
        'Root/Shizuku 压缩包无法直接访问，当前特权协议不支持安全分块导出',
      );
    }

    final index = await ArchiveReadingService.instance.getIndex(archivePath);
    final entries = <_ArchiveSelection>[];
    if (episodeFiles.isNotEmpty) {
      final keys = episodeFiles.keys.toList()..sort();
      for (final key in keys) {
        final paths = episodeFiles[key] ?? const <String>[];
        for (final uri in paths) {
          final parsed = parseArchiveUri(uri);
          if (parsed == null || !isValidArchiveEntryPath(parsed.entryPath)) {
            throw const DownloadExportSourceException('压缩包条目路径无效');
          }
          entries.add(_ArchiveSelection(
            chapterIndex: key,
            entryPath: parsed.entryPath,
          ));
        }
      }
    } else {
      for (final entry in index.imageEntries) {
        entries.add(_ArchiveSelection(
          chapterIndex: 0,
          entryPath: entry.path,
        ));
      }
    }

    final indexByPath = <String, ArchiveEntry>{
      for (final entry in index.imageEntries) entry.path: entry,
    };
    final result = <DownloadExportSourceFile>[];
    final usedPaths = <String>{};
    entries.sort((a, b) =>
        DownloadExportPathTools.naturalCompare(a.entryPath, b.entryPath));
    for (final selection in entries) {
      cancellation.throwIfCancelled();
      final archiveEntry = indexByPath[selection.entryPath];
      if (archiveEntry == null) continue;
      if (archiveEntry.size > maxEntryBytes) {
        throw DownloadExportSourceException(
          '压缩包条目过大，当前 archive backend 无法安全流式读取：${archiveEntry.name}',
        );
      }
      var outputPath = DownloadExportPathTools.sanitizeRelativePath(
        selection.entryPath,
      );
      if (episodeNames.length > 1 &&
          selection.chapterIndex >= 0 &&
          selection.chapterIndex < episodeNames.length) {
        outputPath =
            '${DownloadExportPathTools.sanitizeSegment(episodeNames[selection.chapterIndex])}/$outputPath';
      }
      outputPath = DownloadExportPathTools.uniqueRelativePath(
        outputPath,
        usedPaths,
      );
      result.add(_ArchiveDownloadExportFile(
        archivePath: archivePath,
        entryPath: selection.entryPath,
        relativePath: outputPath,
        entrySize: archiveEntry.size,
      ));
    }
    if (result.isEmpty) {
      throw const DownloadExportSourceException('压缩包中没有可导出的图片');
    }
    return result;
  }

  @override
  Future<int?> resolvePageCount(
    DownloadExportCancellationToken cancellation,
  ) async {
    final files = await listFiles(cancellation);
    // A cover entry is a page when it is part of the selected archive image
    // entries. Archive metadata, rather than its filename, defines exclusion.
    return _countImageFiles(files);
  }
}

class DownloadExportUnsupportedSource extends DownloadExportContentSource {
  const DownloadExportUnsupportedSource(this.reason);

  final String reason;

  @override
  Future<List<DownloadExportSourceFile>> listFiles(
    DownloadExportCancellationToken cancellation,
  ) async {
    cancellation.throwIfCancelled();
    throw DownloadExportSourceException(reason);
  }
}

class DownloadExportService {
  const DownloadExportService();

  /// Builds the exact manifest text shared by text delivery, clipboard
  /// copying and the manifest embedded in a content ZIP.
  Future<String> buildManifestText({
    required List<DownloadExportRequest> requests,
    required DownloadExportFieldConfiguration fields,
    DownloadExportCancellationToken? cancellation,
    DownloadExportProgressCallback? onProgress,
    bool omitEmptyOptionalFields = false,
  }) async {
    if (requests.isEmpty || fields.isEmpty) return '';
    final token = cancellation ?? DownloadExportCancellationToken();
    final records = <DownloadExportManifestRecord>[];
    for (var index = 0; index < requests.length; index++) {
      token.throwIfCancelled();
      final request = requests[index];
      var descriptor = request.descriptor;
      if (descriptor.pageCount == null) {
        try {
          final count = await request.source.resolvePageCount(token);
          descriptor = descriptor.copyWith(pageCount: count);
        } on DownloadExportCancelledException {
          rethrow;
        } catch (_) {
          // Metadata inspection is best effort; the manifest remains useful
          // and the formatter emits the explicit unknown page-count value.
        }
      }
      records.add(DownloadExportManifestRecord(descriptor: descriptor));
      _report(
        onProgress,
        DownloadExportProgress(
          current: index + 1,
          total: requests.length,
          currentTitle: descriptor.title,
          phase: '生成清单',
          writtenBytes: 0,
        ),
      );
    }
    return DownloadExportFormatter.format(
      records,
      fields,
      omitEmptyOptionalFields: omitEmptyOptionalFields,
    );
  }

  Future<DownloadExportResult> exportAndDeliver({
    required List<DownloadExportRequest> requests,
    required DownloadExportFieldConfiguration fields,
    required bool includeContent,
    required DownloadExportArtifactSink sink,
    DownloadExportCancellationToken? cancellation,
    DownloadExportProgressCallback? onProgress,
    String? suggestedName,
    Directory? tempRoot,
  }) async {
    final token = cancellation ?? DownloadExportCancellationToken();
    if (requests.isEmpty) {
      return const DownloadExportResult(
        status: DownloadExportResultStatus.failure,
        processed: 0,
        total: 0,
      );
    }
    if (fields.isEmpty) {
      return DownloadExportResult(
        status: DownloadExportResultStatus.failure,
        processed: 0,
        total: requests.length,
        failures: const [
          DownloadExportFailure(title: '漫画清单', reason: '至少选择一项'),
        ],
      );
    }

    Directory? workspace;
    File? artifactFile;
    try {
      final root = tempRoot ?? Directory.systemTemp;
      workspace = await Directory(
        '${root.path}${Platform.pathSeparator}picakeep_export_${DateTime.now().microsecondsSinceEpoch}',
      ).create(recursive: true);
      final extension = includeContent ? '.zip' : '.txt';
      artifactFile = File(
        '${workspace.path}${Platform.pathSeparator}export$extension',
      );
      if (includeContent) {
        return await _exportZip(
          workspace: workspace,
          artifactFile: artifactFile,
          requests: requests,
          sink: sink,
          token: token,
          onProgress: onProgress,
          suggestedName: suggestedName,
        );
      }
      return await _exportManifest(
        workspace: workspace,
        artifactFile: artifactFile,
        requests: requests,
        fields: fields,
        sink: sink,
        token: token,
        onProgress: onProgress,
        suggestedName: suggestedName,
      );
    } on DownloadExportCancelledException {
      return DownloadExportResult(
        status: DownloadExportResultStatus.cancelled,
        processed: 0,
        total: requests.length,
        artifactName: suggestedName,
      );
    } catch (error) {
      return DownloadExportResult(
        status: DownloadExportResultStatus.failure,
        processed: 0,
        total: requests.length,
        failures: [
          DownloadExportFailure(
            title: '导出任务',
            reason: _errorMessage(error),
          ),
        ],
      );
    } finally {
      if (artifactFile != null) {
        try {
          if (await artifactFile.exists()) await artifactFile.delete();
        } catch (_) {}
      }
      if (workspace != null) {
        try {
          if (await workspace.exists()) await workspace.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  Future<DownloadExportResult> _exportManifest({
    required Directory workspace,
    required File artifactFile,
    required List<DownloadExportRequest> requests,
    required DownloadExportFieldConfiguration fields,
    required DownloadExportArtifactSink sink,
    required DownloadExportCancellationToken token,
    required DownloadExportProgressCallback? onProgress,
    required String? suggestedName,
  }) async {
    _report(
      onProgress,
      DownloadExportProgress(
        current: 0,
        total: requests.length,
        currentTitle: requests.first.descriptor.title,
        phase: '生成清单',
        writtenBytes: 0,
      ),
    );
    token.throwIfCancelled();
    final content = await buildManifestText(
      requests: requests,
      fields: fields,
      cancellation: token,
      onProgress: onProgress,
    );
    await artifactFile.writeAsString(content, encoding: utf8, flush: true);
    token.throwIfCancelled();
    final delivered = await _deliver(
      artifactFile,
      suggestedName ?? 'PicaKeep-漫画清单-${_timestamp()}.txt',
      'text/plain; charset=utf-8',
      sink,
    );
    if (delivered.status == DownloadExportDeliveryStatus.cancelled) {
      return DownloadExportResult(
        status: DownloadExportResultStatus.cancelled,
        processed: requests.length,
        total: requests.length,
        artifactName: suggestedName,
      );
    }
    return DownloadExportResult(
      status: DownloadExportResultStatus.success,
      processed: requests.length,
      total: requests.length,
      delivered: true,
      artifactName: suggestedName,
    );
  }

  Future<DownloadExportResult> _exportZip({
    required Directory workspace,
    required File artifactFile,
    required List<DownloadExportRequest> requests,
    required DownloadExportArtifactSink sink,
    required DownloadExportCancellationToken token,
    required DownloadExportProgressCallback? onProgress,
    required String? suggestedName,
  }) async {
    final records = <DownloadExportManifestRecord>[];
    final failures = <DownloadExportFailure>[];
    final usedRoots = <String>{};
    final usedZipPaths = <String>{};
    final encoder = ZipFileEncoder();
    var encoderOpen = false;
    var processed = 0;
    var writtenBytes = 0;

    try {
      encoder.create(artifactFile.path);
      encoderOpen = true;
      for (final request in requests) {
        token.throwIfCancelled();
        var descriptor = request.descriptor;
        final title = descriptor.title.isEmpty ? '未命名' : descriptor.title;
        final rootName = DownloadExportPathTools.uniqueName(title, usedRoots);
        _report(
          onProgress,
          DownloadExportProgress(
            current: processed,
            total: requests.length,
            currentTitle: title,
            phase: '读取漫画',
            writtenBytes: writtenBytes,
          ),
        );
        try {
          final sourceFiles = await request.source.listFiles(token);
          if (descriptor.pageCount == null) {
            descriptor = descriptor.copyWith(
              pageCount: _countImageFiles(
                sourceFiles,
                excludeStandaloneCover:
                    request.source is DownloadExportDirectorySource,
              ),
            );
          }
          var sourceFileIndex = 0;
          for (final sourceFile in sourceFiles) {
            token.throwIfCancelled();
            final relativePath = DownloadExportPathTools.uniqueRelativePath(
              '$rootName/${sourceFile.relativePath}',
              usedZipPaths,
            );
            final tempFile = File(
              '${workspace.path}${Platform.pathSeparator}part_$sourceFileIndex',
            );
            sourceFileIndex++;
            try {
              final copiedBytes = await sourceFile.copyTo(
                tempFile,
                token,
                (bytes) {
                  writtenBytes += bytes;
                  _report(
                    onProgress,
                    DownloadExportProgress(
                      current: processed,
                      total: requests.length,
                      currentTitle: title,
                      phase: '写入 ZIP',
                      writtenBytes: writtenBytes,
                    ),
                  );
                },
              );
              token.throwIfCancelled();
              await encoder.addFile(tempFile, relativePath);
              if (copiedBytes == 0 && sourceFile.sizeBytes == null) {
                writtenBytes += 0;
              }
            } finally {
              try {
                if (await tempFile.exists()) await tempFile.delete();
              } catch (_) {}
            }
          }
          records.add(DownloadExportManifestRecord(
            descriptor: descriptor,
          ));
        } catch (error) {
          final reason = _errorMessage(error);
          failures.add(DownloadExportFailure(title: title, reason: reason));
          records.add(DownloadExportManifestRecord(
            descriptor: descriptor,
            status: DownloadExportItemStatus.failed,
            failureReason: reason,
          ));
        }
        processed++;
      }

      token.throwIfCancelled();
      if (records.every(
          (record) => record.status != DownloadExportItemStatus.success)) {
        return DownloadExportResult(
          status: DownloadExportResultStatus.failure,
          processed: processed,
          total: requests.length,
          failures: List.unmodifiable(failures),
          artifactName: suggestedName,
        );
      }

      final manifestFile = File(
        '${workspace.path}${Platform.pathSeparator}漫画清单.txt',
      );
      await manifestFile.writeAsString(
        DownloadExportFormatter.format(
          records,
          DownloadExportFieldConfiguration.compact(),
          omitEmptyOptionalFields: true,
        ),
        encoding: utf8,
        flush: true,
      );
      await encoder.addFile(manifestFile, '漫画清单.txt');
      await encoder.close();
      encoderOpen = false;

      final delivered = await _deliver(
        artifactFile,
        suggestedName ??
            (requests.length == 1
                ? '${DownloadExportPathTools.sanitizeSegment(requests.first.descriptor.title)}.zip'
                : 'comics.zip'),
        'application/zip',
        sink,
      );
      if (delivered.status == DownloadExportDeliveryStatus.cancelled) {
        return DownloadExportResult(
          status: DownloadExportResultStatus.cancelled,
          processed: processed,
          total: requests.length,
          failures: List.unmodifiable(failures),
          artifactName: suggestedName,
        );
      }
      return DownloadExportResult(
        status: failures.isEmpty
            ? DownloadExportResultStatus.success
            : DownloadExportResultStatus.partialFailure,
        processed: processed,
        total: requests.length,
        delivered: true,
        failures: List.unmodifiable(failures),
        artifactName: suggestedName,
      );
    } on DownloadExportCancelledException {
      return DownloadExportResult(
        status: DownloadExportResultStatus.cancelled,
        processed: processed,
        total: requests.length,
        failures: List.unmodifiable(failures),
        artifactName: suggestedName,
      );
    } finally {
      if (encoderOpen) {
        try {
          await encoder.close();
        } catch (_) {}
      }
    }
  }

  Future<DownloadExportDeliveryOutcome> _deliver(
    File file,
    String suggestedName,
    String mimeType,
    DownloadExportArtifactSink sink,
  ) {
    return sink.deliver(DownloadExportArtifact(
      path: file.path,
      suggestedName: suggestedName,
      mimeType: mimeType,
    ));
  }

  void _report(
    DownloadExportProgressCallback? callback,
    DownloadExportProgress progress,
  ) {
    try {
      callback?.call(progress);
    } catch (_) {}
  }

  String _timestamp() {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}';
  }

  String _errorMessage(Object error) {
    if (error is DownloadExportSourceException) return error.message;
    if (error is ArchiveFailure) return error.userMessage();
    if (error is FileSystemException) return '文件读取失败：${error.message}';
    if (error is DownloadExportCancelledException) return '用户取消导出';
    final text = error.toString().trim();
    return text.isEmpty ? '未知导出错误' : text;
  }
}

int? _countImageFiles(
  Iterable<DownloadExportSourceFile> files, {
  bool excludeStandaloneCover = false,
}) {
  final seen = <String>{};
  for (final file in files) {
    final path = file.relativePath.replaceAll('\\', '/').trim();
    final lower = path.toLowerCase();
    final isImage = lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.gif');
    if (!isImage) continue;
    if (excludeStandaloneCover) {
      final name = lower.split('/').last;
      if (const {
        'cover.jpg',
        'cover.jpeg',
        'cover.png',
        'cover.webp',
        'cover.gif',
        'folder.jpg',
        'folder.png',
        'thumb.jpg',
        'thumb.png',
        'thumbnail.jpg',
        'thumbnail.png',
      }.contains(name)) {
        continue;
      }
    }
    seen.add(lower);
  }
  return seen.isEmpty ? null : seen.length;
}

class _LocalDownloadExportFile implements DownloadExportSourceFile {
  _LocalDownloadExportFile({
    required this.sourcePath,
    required this.relativePath,
  });

  final String sourcePath;
  @override
  final String relativePath;

  @override
  int? get sizeBytes {
    try {
      final file = File(sourcePath);
      if (file.existsSync()) return file.lengthSync();
    } catch (_) {}
    return null;
  }

  @override
  Future<int> copyTo(
    File target,
    DownloadExportCancellationToken cancellation,
    void Function(int bytes) onBytes,
  ) async {
    await target.parent.create(recursive: true);
    try {
      var total = 0;
      final sink = target.openWrite();
      try {
        await for (final chunk in File(sourcePath).openRead()) {
          cancellation.throwIfCancelled();
          sink.add(chunk);
          total += chunk.length;
          onBytes(chunk.length);
        }
      } finally {
        await sink.close();
      }
      return total;
    } catch (_) {
      try {
        if (await target.exists()) await target.delete();
      } catch (_) {}
      final bytes = await PrivilegedStorageAccess.readFileBytes(sourcePath);
      if (bytes == null) rethrow;
      if (bytes.length >
          DownloadExportDirectorySource.maxPrivilegedFallbackBytes) {
        throw const DownloadExportSourceException(
          'Root/Shizuku 文件超过安全回退大小，当前特权协议不支持分块导出',
        );
      }
      cancellation.throwIfCancelled();
      await target.writeAsBytes(bytes, flush: true);
      onBytes(bytes.length);
      return bytes.length;
    }
  }
}

class _ArchiveSelection {
  const _ArchiveSelection({
    required this.chapterIndex,
    required this.entryPath,
  });

  final int chapterIndex;
  final String entryPath;
}

class _ArchiveDownloadExportFile implements DownloadExportSourceFile {
  _ArchiveDownloadExportFile({
    required this.archivePath,
    required this.entryPath,
    required this.relativePath,
    required this.entrySize,
  });

  final String archivePath;
  final String entryPath;
  @override
  final String relativePath;
  final int entrySize;

  @override
  int? get sizeBytes => entrySize;

  @override
  Future<int> copyTo(
    File target,
    DownloadExportCancellationToken cancellation,
    void Function(int bytes) onBytes,
  ) async {
    cancellation.throwIfCancelled();
    final bytes = await ArchiveReadingService.instance.readEntryBytes(
      archivePath,
      entryPath,
    );
    if (bytes.length > DownloadExportArchiveSource.maxEntryBytes) {
      throw const DownloadExportSourceException('压缩包条目超过安全读取大小');
    }
    cancellation.throwIfCancelled();
    await target.parent.create(recursive: true);
    await target.writeAsBytes(bytes, flush: true);
    onBytes(bytes.length);
    return bytes.length;
  }
}

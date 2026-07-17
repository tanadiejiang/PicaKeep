import 'dart:collection';

enum DownloadExportSourceKind {
  picacg,
  jm,
  ehentai,
  nhentai,
  hitomi,
  htmanga,
  localScan,
  localArchive,
  remote,
  remoteRoot,
  other,
}

enum DownloadExportField {
  title,
  author,
  id,
  link,
  source,
  rawTags,
  translatedTags,
  chapters,
  pageCount,
  size,
  downloadTime,
  sourceTime,
  localPath,
  coverPath,
}

extension DownloadExportFieldDetails on DownloadExportField {
  String get label {
    switch (this) {
      case DownloadExportField.title:
        return '标题';
      case DownloadExportField.author:
        return '作者/画师';
      case DownloadExportField.id:
        return 'ID';
      case DownloadExportField.link:
        return '链接';
      case DownloadExportField.source:
        return '来源';
      case DownloadExportField.rawTags:
        return '原始标签';
      case DownloadExportField.translatedTags:
        return '翻译后标签';
      case DownloadExportField.chapters:
        return '章节';
      case DownloadExportField.pageCount:
        return '页数';
      case DownloadExportField.size:
        return '大小';
      case DownloadExportField.downloadTime:
        return '下载时间';
      case DownloadExportField.sourceTime:
        return '源站时间';
      case DownloadExportField.localPath:
        return '本地路径';
      case DownloadExportField.coverPath:
        return '封面路径';
    }
  }

  bool get isSensitive {
    return this == DownloadExportField.localPath ||
        this == DownloadExportField.coverPath;
  }
}

class DownloadExportFieldConfiguration {
  factory DownloadExportFieldConfiguration(
    Iterable<DownloadExportField> fields,
  ) {
    final unique = <DownloadExportField>[];
    final seen = <DownloadExportField>{};
    for (final field in fields) {
      if (seen.add(field)) {
        unique.add(field);
      }
    }
    return DownloadExportFieldConfiguration._(unique);
  }

  DownloadExportFieldConfiguration._(Iterable<DownloadExportField> fields)
      : fields = UnmodifiableListView<DownloadExportField>(fields.toList());

  factory DownloadExportFieldConfiguration.defaults() {
    return DownloadExportFieldConfiguration(const [
      DownloadExportField.title,
      DownloadExportField.author,
      DownloadExportField.id,
    ]);
  }

  factory DownloadExportFieldConfiguration.compact() {
    return DownloadExportFieldConfiguration(const [
      DownloadExportField.title,
      DownloadExportField.author,
      DownloadExportField.id,
      DownloadExportField.link,
      DownloadExportField.source,
      DownloadExportField.rawTags,
      DownloadExportField.translatedTags,
      DownloadExportField.chapters,
      DownloadExportField.pageCount,
      DownloadExportField.size,
    ]);
  }

  factory DownloadExportFieldConfiguration.all() {
    return DownloadExportFieldConfiguration(DownloadExportField.values);
  }

  final List<DownloadExportField> fields;

  bool contains(DownloadExportField field) => fields.contains(field);

  bool get isEmpty => fields.isEmpty;

  DownloadExportFieldConfiguration copyWith(
      Iterable<DownloadExportField> nextFields) {
    return DownloadExportFieldConfiguration(nextFields);
  }
}

class DownloadExportDescriptor {
  factory DownloadExportDescriptor({
    required String title,
    Iterable<String> author = const [],
    String id = '',
    String link = '',
    String source = '',
    Iterable<String> rawTags = const [],
    Iterable<String> translatedTags = const [],
    Iterable<String> chapters = const [],
    int? pageCount,
    int? sizeBytes,
    DateTime? downloadTime,
    String sourceTime = '',
    String localPath = '',
    String coverPath = '',
    DownloadExportSourceKind sourceKind = DownloadExportSourceKind.other,
  }) {
    return DownloadExportDescriptor._(
      title: title.trim(),
      author: _cleanList(author),
      id: id.trim(),
      link: link.trim(),
      source: source.trim(),
      rawTags: _cleanList(rawTags),
      translatedTags: _cleanList(translatedTags),
      chapters: _cleanList(chapters),
      pageCount: pageCount != null && pageCount > 0 ? pageCount : null,
      sizeBytes: sizeBytes != null && sizeBytes >= 0 ? sizeBytes : null,
      downloadTime: downloadTime,
      sourceTime: sourceTime.trim(),
      localPath: localPath.trim(),
      coverPath: coverPath.trim(),
      sourceKind: sourceKind,
    );
  }

  DownloadExportDescriptor._({
    required this.title,
    required Iterable<String> author,
    required this.id,
    required this.link,
    required this.source,
    required Iterable<String> rawTags,
    required Iterable<String> translatedTags,
    required Iterable<String> chapters,
    required this.pageCount,
    required this.sizeBytes,
    required this.downloadTime,
    required this.sourceTime,
    required this.localPath,
    required this.coverPath,
    required this.sourceKind,
  })  : author = UnmodifiableListView<String>(author.toList()),
        rawTags = UnmodifiableListView<String>(rawTags.toList()),
        translatedTags = UnmodifiableListView<String>(translatedTags.toList()),
        chapters = UnmodifiableListView<String>(chapters.toList());

  final String title;
  final List<String> author;
  final String id;
  final String link;
  final String source;
  final List<String> rawTags;
  final List<String> translatedTags;
  final List<String> chapters;
  final int? pageCount;
  final int? sizeBytes;
  final DateTime? downloadTime;
  final String sourceTime;
  final String localPath;
  final String coverPath;
  final DownloadExportSourceKind sourceKind;

  /// Returns an immutable descriptor with a normalized page-count override.
  ///
  /// A null override deliberately means "unknown". This is used after a
  /// source has asynchronously inspected its real image entries/files.
  DownloadExportDescriptor copyWith({int? pageCount}) {
    return DownloadExportDescriptor(
      title: title,
      author: author,
      id: id,
      link: link,
      source: source,
      rawTags: rawTags,
      translatedTags: translatedTags,
      chapters: chapters,
      pageCount: pageCount,
      sizeBytes: sizeBytes,
      downloadTime: downloadTime,
      sourceTime: sourceTime,
      localPath: localPath,
      coverPath: coverPath,
      sourceKind: sourceKind,
    );
  }
}

enum DownloadExportItemStatus { success, failed, skipped }

class DownloadExportManifestRecord {
  const DownloadExportManifestRecord({
    required this.descriptor,
    this.status = DownloadExportItemStatus.success,
    this.failureReason = '',
  });

  final DownloadExportDescriptor descriptor;
  final DownloadExportItemStatus status;
  final String failureReason;
}

class DownloadExportFailure {
  const DownloadExportFailure({
    required this.title,
    required this.reason,
  });

  final String title;
  final String reason;
}

enum DownloadExportResultStatus {
  success,
  cancelled,
  partialFailure,
  failure,
}

class DownloadExportProgress {
  const DownloadExportProgress({
    required this.current,
    required this.total,
    required this.currentTitle,
    required this.phase,
    required this.writtenBytes,
    this.totalBytes,
  });

  final int current;
  final int total;
  final String currentTitle;
  final String phase;
  final int writtenBytes;
  final int? totalBytes;

  double? get fraction {
    if (totalBytes != null && totalBytes! > 0) {
      return (writtenBytes / totalBytes!).clamp(0, 1).toDouble();
    }
    if (total <= 0) return null;
    return (current / total).clamp(0, 1).toDouble();
  }
}

class DownloadExportCancellationToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;

  void throwIfCancelled() {
    if (_cancelled) {
      throw const DownloadExportCancelledException();
    }
  }
}

class DownloadExportCancelledException implements Exception {
  const DownloadExportCancelledException();
}

class DownloadExportArtifact {
  const DownloadExportArtifact({
    required this.path,
    required this.suggestedName,
    required this.mimeType,
  });

  final String path;
  final String suggestedName;
  final String mimeType;
}

enum DownloadExportDeliveryStatus { delivered, cancelled }

class DownloadExportDeliveryOutcome {
  const DownloadExportDeliveryOutcome(this.status);

  const DownloadExportDeliveryOutcome.delivered()
      : status = DownloadExportDeliveryStatus.delivered;

  const DownloadExportDeliveryOutcome.cancelled()
      : status = DownloadExportDeliveryStatus.cancelled;

  final DownloadExportDeliveryStatus status;
}

abstract class DownloadExportArtifactSink {
  Future<DownloadExportDeliveryOutcome> deliver(
    DownloadExportArtifact artifact,
  );
}

class DownloadExportResult {
  const DownloadExportResult({
    required this.status,
    required this.processed,
    required this.total,
    this.delivered = false,
    this.failures = const [],
    this.artifactName,
  });

  final DownloadExportResultStatus status;
  final int processed;
  final int total;
  final bool delivered;
  final List<DownloadExportFailure> failures;
  final String? artifactName;
}

List<String> _cleanList(Iterable<String> values) {
  final result = <String>[];
  final seen = <String>{};
  for (final value in values) {
    final normalized = value.trim();
    if (normalized.isNotEmpty && seen.add(normalized)) {
      result.add(normalized);
    }
  }
  return result;
}

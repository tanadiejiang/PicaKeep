import 'download_export_models.dart';

class DownloadExportFormatter {
  const DownloadExportFormatter._();

  static String format(Iterable<DownloadExportManifestRecord> records,
      DownloadExportFieldConfiguration configuration,
      {bool omitEmptyOptionalFields = false}) {
    final buffer = StringBuffer();
    for (final record in records) {
      final title =
          record.descriptor.title.isEmpty ? '无标题' : record.descriptor.title;
      buffer.write('=== $title ===\n');
      for (final field in configuration.fields) {
        _writeField(
          buffer,
          field,
          record.descriptor,
          omitEmptyOptionalFields: omitEmptyOptionalFields,
        );
      }
      if (record.status != DownloadExportItemStatus.success) {
        final label = switch (record.status) {
          DownloadExportItemStatus.failed => '失败',
          DownloadExportItemStatus.skipped => '已跳过',
          DownloadExportItemStatus.success => '成功',
        };
        buffer.write('导出状态: $label\n');
        if (record.failureReason.trim().isNotEmpty) {
          buffer.write('失败原因: ${record.failureReason.trim()}\n');
        }
      }
      buffer.write('\n');
    }
    return buffer.toString();
  }

  static void _writeField(StringBuffer buffer, DownloadExportField field,
      DownloadExportDescriptor descriptor,
      {required bool omitEmptyOptionalFields}) {
    final values = _valuesFor(field, descriptor);
    if (omitEmptyOptionalFields &&
        field != DownloadExportField.pageCount &&
        !_requiredFields.contains(field) &&
        values.isEmpty) {
      return;
    }
    if (values.length <= 1) {
      buffer.write('${field.label}: ${values.isEmpty ? '无' : values.first}\n');
      return;
    }
    buffer.write('${field.label}:\n');
    for (final value in values) {
      buffer.write('  - $value\n');
    }
  }

  static List<String> _valuesFor(
    DownloadExportField field,
    DownloadExportDescriptor descriptor,
  ) {
    switch (field) {
      case DownloadExportField.title:
        return _single(descriptor.title);
      case DownloadExportField.author:
        return _many(descriptor.author);
      case DownloadExportField.id:
        return _single(descriptor.id);
      case DownloadExportField.link:
        return _single(descriptor.link);
      case DownloadExportField.source:
        return _single(descriptor.source);
      case DownloadExportField.rawTags:
        return _many(descriptor.rawTags);
      case DownloadExportField.translatedTags:
        return _many(descriptor.translatedTags);
      case DownloadExportField.chapters:
        return _many(descriptor.chapters);
      case DownloadExportField.pageCount:
        return [descriptor.pageCount?.toString() ?? '无/不确定'];
      case DownloadExportField.size:
        return _single(_formatSize(descriptor.sizeBytes));
      case DownloadExportField.downloadTime:
        return _single(descriptor.downloadTime?.toIso8601String());
      case DownloadExportField.sourceTime:
        return _single(descriptor.sourceTime);
      case DownloadExportField.localPath:
        return _single(descriptor.localPath);
      case DownloadExportField.coverPath:
        return _single(descriptor.coverPath);
    }
  }

  static List<String> _single(String? value) {
    final normalized = value?.trim() ?? '';
    return normalized.isEmpty ? const [] : [normalized];
  }

  static List<String> _many(Iterable<String> values) {
    return values
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
  }

  static String _formatSize(int? bytes) {
    if (bytes == null || bytes < 0) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  static const _requiredFields = {
    DownloadExportField.title,
    DownloadExportField.author,
    DownloadExportField.id,
  };
}

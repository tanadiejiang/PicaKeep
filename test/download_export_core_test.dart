import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:picakeep/foundation/archive/archive_registry.dart';
import 'package:picakeep/foundation/download_export/download_export_core.dart';
import 'package:picakeep/foundation/download_export/download_export_formatter.dart';
import 'package:picakeep/foundation/download_export/download_export_models.dart';
import 'package:picakeep/foundation/download_export/download_export_paths.dart';
import 'package:picakeep/foundation/download_export/download_export_sources.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DownloadExportFieldConfiguration', () {
    test('defaults and compact fields stay separate', () {
      expect(
        DownloadExportFieldConfiguration.defaults().fields,
        const [
          DownloadExportField.title,
          DownloadExportField.author,
          DownloadExportField.id,
        ],
      );
      expect(
        DownloadExportFieldConfiguration.compact().fields,
        containsAllInOrder(const [
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
        ]),
      );
      expect(
        DownloadExportFieldConfiguration.compact().fields,
        isNot(contains(DownloadExportField.localPath)),
      );
    });

    test('descriptor copies collection values', () {
      final authors = <String>['artist'];
      final descriptor = DownloadExportDescriptor(
        title: 'Comic',
        author: authors,
      );
      authors.add('changed');
      expect(descriptor.author, ['artist']);
      expect(() => descriptor.author.add('blocked'), throwsUnsupportedError);
    });
  });

  test('formatter keeps source fields and multi-values in stable order', () {
    final descriptor = DownloadExportDescriptor(
      title: '示例',
      author: const ['画师'],
      id: '42',
      link: 'https://example.test/comic/42',
      source: '测试来源',
      rawTags: const ['artist:画师', 'language:中文'],
      translatedTags: const ['画师', '中文'],
      chapters: const ['第 1 章', '第 2 章'],
      pageCount: 12,
      sizeBytes: 1024 * 1024,
    );
    final text = DownloadExportFormatter.format(
      [DownloadExportManifestRecord(descriptor: descriptor)],
      DownloadExportFieldConfiguration.compact(),
    );
    expect(text, contains('=== 示例 ==='));
    expect(text, contains('作者/画师: 画师'));
    expect(text, contains('原始标签:\n  - artist:画师\n  - language:中文'));
    expect(text, contains('翻译后标签:\n  - 画师\n  - 中文'));
    expect(text, contains('页数: 12'));
    expect(text, contains('大小: 1.0 MB'));
  });

  test('page count accepts only positive values and keeps unknown explicit',
      () {
    for (final value in <int?>[0, -1, null]) {
      final descriptor = DownloadExportDescriptor(
        title: '未知页数',
        pageCount: value,
      );
      final text = DownloadExportFormatter.format(
        [DownloadExportManifestRecord(descriptor: descriptor)],
        DownloadExportFieldConfiguration.compact(),
        omitEmptyOptionalFields: true,
      );
      expect(descriptor.pageCount, isNull);
      expect(text, contains('页数: 无/不确定'));
    }

    final selectedWithoutPages = DownloadExportFormatter.format(
      [
        DownloadExportManifestRecord(
          descriptor: DownloadExportDescriptor(title: '不选页数'),
        ),
      ],
      DownloadExportFieldConfiguration.defaults(),
    );
    expect(selectedWithoutPages, isNot(contains('页数:')));
  });

  test('manifest builder counts directory images and excludes sidecar cover',
      () async {
    final temp =
        await Directory.systemTemp.createTemp('download_export_pages_');
    try {
      await File(_join(temp.path, 'cover.jpg')).writeAsBytes([0]);
      await File(_join(temp.path, 'page-1.jpg')).writeAsBytes([1]);
      await File(_join(temp.path, 'page-2.PNG')).writeAsBytes([2]);
      await File(_join(temp.path, 'metadata.json')).writeAsString('{}');
      final text = await const DownloadExportService().buildManifestText(
        requests: [
          DownloadExportRequest(
            descriptor: DownloadExportDescriptor(title: '目录漫画'),
            source: DownloadExportDirectorySource(rootPath: temp.path),
          ),
        ],
        fields: DownloadExportFieldConfiguration.compact(),
      );
      expect(text, contains('页数: 2'));
      expect(text, isNot(contains('页数: 3')));
    } finally {
      await temp.delete(recursive: true);
    }
  });

  test('descriptor factory keeps source-specific author and link semantics',
      () {
    final eh = DownloadedGallery(
      galleryTitle: 'EH title',
      uploader: 'uploader-must-not-be-author',
      link: 'https://e-hentai.org/g/123/abc/',
      tagList: const ['artist:alice', 'tag:general'],
    );
    final ehDescriptor = DownloadExportDescriptorFactory.fromItem(
      eh,
      translateTag: (tag) => 'translated:$tag',
    );
    expect(ehDescriptor.id, '123-abc');
    expect(ehDescriptor.author, ['alice']);
    expect(ehDescriptor.author, isNot(contains('uploader-must-not-be-author')));
    expect(ehDescriptor.link, eh.link);
    expect(ehDescriptor.translatedTags,
        ['translated:artist:alice', 'translated:tag:general']);

    final nh = NhentaiDownloadedComic(
      comicID: '456',
      title: 'NH title',
      categorizedTags: const {
        'Artists': ['artist-a'],
        'Tags': ['ordinary-tag'],
      },
      tagList: const ['ordinary-tag'],
    );
    final nhDescriptor = DownloadExportDescriptorFactory.fromItem(nh);
    expect(nhDescriptor.author, ['artist-a']);
    expect(nhDescriptor.author, isNot(contains('ordinary-tag')));
    expect(nhDescriptor.link, 'https://nhentai.net/g/456/');
  });

  test('path tools sanitize, natural sort and de-duplicate', () {
    expect(DownloadExportPathTools.sanitizeSegment('CON'), '_CON');
    expect(
      DownloadExportPathTools.sanitizeRelativePath(r'../第:1章\10?.jpg'),
      '_/第_1章/10_.jpg',
    );
    expect(
      ['page10.jpg', 'page2.jpg', 'page1.jpg'].toList()
        ..sort(DownloadExportPathTools.naturalCompare),
      ['page1.jpg', 'page2.jpg', 'page10.jpg'],
    );
    final used = <String>{};
    expect(DownloadExportPathTools.uniqueName('Comic', used), 'Comic');
    expect(DownloadExportPathTools.uniqueName('Comic', used), 'Comic (2)');
    final paths = <String>{};
    expect(
      DownloadExportPathTools.uniqueRelativePath('chapter/page.jpg', paths),
      'chapter/page.jpg',
    );
    expect(
      DownloadExportPathTools.uniqueRelativePath('chapter/page.jpg', paths),
      'chapter/page (2).jpg',
    );
  });

  test('directory source creates an outer ZIP and cleans temporary files',
      () async {
    final temp = await Directory.systemTemp.createTemp('download_export_test_');
    try {
      final sourceDir = Directory(_join(temp.path, 'comic'));
      await sourceDir.create();
      await File(_join(sourceDir.path, 'page10.jpg')).writeAsBytes([10]);
      await File(_join(sourceDir.path, 'page2.jpg')).writeAsBytes([2]);
      final sink = _CapturingSink();
      final result = await const DownloadExportService().exportAndDeliver(
        requests: [
          DownloadExportRequest(
            descriptor: DownloadExportDescriptor(title: 'Comic'),
            source: DownloadExportDirectorySource(rootPath: ''),
          ),
        ],
        fields: DownloadExportFieldConfiguration.compact(),
        includeContent: true,
        sink: sink,
      );
      expect(result.status, DownloadExportResultStatus.failure);

      final successful = await const DownloadExportService().exportAndDeliver(
        requests: [
          DownloadExportRequest(
            descriptor: DownloadExportDescriptor(title: 'Comic'),
            source: DownloadExportDirectorySource(rootPath: sourceDir.path),
          ),
        ],
        fields: DownloadExportFieldConfiguration.compact(),
        includeContent: true,
        sink: sink,
      );
      expect(successful.status, DownloadExportResultStatus.success);
      expect(
        sink.names,
        containsAll(<String>[
          'Comic/page2.jpg',
          'Comic/page10.jpg',
          '漫画清单.txt',
        ]),
      );
      expect(sink.manifest, contains('标题: Comic'));
      expect(sink.manifest, contains('页数: 2'));
      expect(sink.lastArtifactPath, isNotNull);
      expect(File(sink.lastArtifactPath!).existsSync(), isFalse);
    } finally {
      await temp.delete(recursive: true);
    }
  });

  test('partial failure preserves successful content and manifest reason',
      () async {
    final temp =
        await Directory.systemTemp.createTemp('download_export_partial_');
    try {
      final sourceDir = Directory(_join(temp.path, 'ok'));
      await sourceDir.create();
      await File(_join(sourceDir.path, 'page.jpg')).writeAsBytes([1, 2, 3]);
      final sink = _CapturingSink();
      final result = await const DownloadExportService().exportAndDeliver(
        requests: [
          DownloadExportRequest(
            descriptor: DownloadExportDescriptor(title: '成功项'),
            source: DownloadExportDirectorySource(rootPath: sourceDir.path),
          ),
          DownloadExportRequest(
            descriptor: DownloadExportDescriptor(title: '失败项'),
            source: DownloadExportDirectorySource(
              rootPath: _join(temp.path, 'missing'),
            ),
          ),
        ],
        fields: DownloadExportFieldConfiguration.compact(),
        includeContent: true,
        sink: sink,
      );
      expect(result.status, DownloadExportResultStatus.partialFailure);
      expect(result.failures.single.title, '失败项');
      expect(sink.names, contains('成功项/page.jpg'));
      expect(sink.manifest, contains('导出状态: 失败'));
      expect(sink.manifest, contains('目录不存在或无法访问'));
    } finally {
      await temp.delete(recursive: true);
    }
  });

  test('cancelled export never delivers an artifact', () async {
    final token = DownloadExportCancellationToken()..cancel();
    final sink = _CapturingSink();
    final result = await const DownloadExportService().exportAndDeliver(
      requests: [
        DownloadExportRequest(
          descriptor: DownloadExportDescriptor(title: 'Comic'),
          source: const DownloadExportUnsupportedSource('should not run'),
        ),
      ],
      fields: DownloadExportFieldConfiguration.compact(),
      includeContent: true,
      cancellation: token,
      sink: sink,
    );
    expect(result.status, DownloadExportResultStatus.cancelled);
    expect(sink.lastArtifactPath, isNull);
  });

  test('manifest-only export does not enumerate content source', () async {
    final sink = _CapturingSink();
    final result = await const DownloadExportService().exportAndDeliver(
      requests: [
        DownloadExportRequest(
          descriptor: DownloadExportDescriptor(title: 'Comic'),
          source: const DownloadExportUnsupportedSource('content must not run'),
        ),
      ],
      fields: DownloadExportFieldConfiguration.defaults(),
      includeContent: false,
      sink: sink,
    );
    expect(result.status, DownloadExportResultStatus.success);
    expect(sink.manifest, contains('标题: Comic'));
  });

  test('archive source unwraps inner ZIP entries', () async {
    final temp =
        await Directory.systemTemp.createTemp('download_export_archive_');
    try {
      final input = File(_join(temp.path, 'comic.cbz'));
      final page = File(_join(temp.path, 'page.jpg'));
      await page.writeAsBytes([4, 5, 6]);
      final encoder = ZipFileEncoder()..create(input.path);
      await encoder.addFile(page, 'chapter/page.jpg');
      await encoder.close();
      ArchiveRegistry.initDefaults();

      final sink = _CapturingSink();
      final result = await const DownloadExportService().exportAndDeliver(
        requests: [
          DownloadExportRequest(
            descriptor: DownloadExportDescriptor(title: 'Archive Comic'),
            source: DownloadExportArchiveSource(archivePath: input.path),
          ),
        ],
        fields: DownloadExportFieldConfiguration.compact(),
        includeContent: true,
        sink: sink,
      );
      expect(result.status, DownloadExportResultStatus.success);
      expect(sink.names, contains('Archive Comic/chapter/page.jpg'));
      expect(sink.manifest, contains('页数: 1'));
      expect(sink.names, isNot(contains('Archive Comic/comic.cbz')));
    } finally {
      await temp.delete(recursive: true);
    }
  });
}

String _join(String base, String child) =>
    base + Platform.pathSeparator + child;

class _CapturingSink implements DownloadExportArtifactSink {
  String? lastArtifactPath;
  List<String> names = const [];
  String manifest = '';

  @override
  Future<DownloadExportDeliveryOutcome> deliver(
    DownloadExportArtifact artifact,
  ) async {
    lastArtifactPath = artifact.path;
    final bytes = await File(artifact.path).readAsBytes();
    if (artifact.mimeType == 'application/zip') {
      final archive = ZipDecoder().decodeBytes(Uint8List.fromList(bytes));
      names = archive.files.map((file) => file.name).toList(growable: false);
      final manifestFile =
          archive.files.where((file) => file.name == '漫画清单.txt').single;
      manifest = utf8.decode(manifestFile.readBytes()!);
    } else {
      manifest = utf8.decode(bytes);
    }
    return const DownloadExportDeliveryOutcome.delivered();
  }
}

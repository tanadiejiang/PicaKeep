import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/pages/local_comic_detail_page.dart';

LocalDetailInfoGroup _group(
  String name,
  LocalDetailInfoRole role, {
  String value = 'value',
  List<LocalDetailInfoValue>? values,
  bool isTagGroup = false,
  String rawNamespace = '',
}) {
  return LocalDetailInfoGroup(
    name: name,
    role: role,
    isTagGroup: isTagGroup,
    rawNamespace: rawNamespace,
    values: values ?? [LocalDetailInfoValue(displayText: value)],
  );
}

void main() {
  group('local detail information roles and rows', () {
    test('classifies original namespaces without depending on display labels',
        () {
      expect(
        localDetailInfoRoleForNamespace('Artists'),
        LocalDetailInfoRole.creator,
      );
      expect(
        localDetailInfoRoleForNamespace('language'),
        LocalDetailInfoRole.language,
      );
      expect(
        localDetailInfoRoleForNamespace('Pages'),
        LocalDetailInfoRole.pageCount,
      );
      expect(
        localDetailInfoRoleForNamespace('Uploaded'),
        LocalDetailInfoRole.sourceTime,
      );
      expect(
        localDetailInfoRoleForNamespace('untranslated-category'),
        LocalDetailInfoRole.normal,
      );
    });

    test('orders ID, creators and download time before ordinary groups', () {
      final groups = [
        _group('标签', LocalDetailInfoRole.normal),
        _group('时间', LocalDetailInfoRole.sourceTime),
        _group('作者', LocalDetailInfoRole.creator),
        _group('页数', LocalDetailInfoRole.pageCount),
        _group('ID', LocalDetailInfoRole.id),
        _group(localDetailDownloadTimeLabel, LocalDetailInfoRole.downloadTime),
        _group('上传者', LocalDetailInfoRole.uploader),
        _group('语言', LocalDetailInfoRole.language),
      ];

      final ordered = orderLocalDetailInfoGroups(groups);
      expect(
        ordered.map((group) => group.role),
        [
          LocalDetailInfoRole.id,
          LocalDetailInfoRole.creator,
          LocalDetailInfoRole.downloadTime,
          LocalDetailInfoRole.normal,
          LocalDetailInfoRole.uploader,
          LocalDetailInfoRole.pageCount,
          LocalDetailInfoRole.language,
          LocalDetailInfoRole.sourceTime,
        ],
      );
      expect(
        ordered[2].name,
        localDetailDownloadTimeLabel,
      );
    });

    test('places page count, language and source time in one logical row', () {
      final rows = buildLocalDetailInfoRows([
        _group('标签', LocalDetailInfoRole.normal),
        _group('时间', LocalDetailInfoRole.sourceTime),
        _group('页数', LocalDetailInfoRole.pageCount),
        _group('语言', LocalDetailInfoRole.language),
        _group('ID', LocalDetailInfoRole.id),
      ]);

      expect(rows.map((row) => row.map((group) => group.role).toList()), [
        [LocalDetailInfoRole.id],
        [LocalDetailInfoRole.normal],
        [
          LocalDetailInfoRole.pageCount,
          LocalDetailInfoRole.language,
          LocalDetailInfoRole.sourceTime,
        ],
      ]);
    });

    test('skips groups without a display value and keeps raw tag search data',
        () {
      const rawTagValue = LocalDetailInfoValue(
        displayText: '狐女',
        rawTagSearchValue: 'female:fox girl',
        rawNamespace: 'female',
      );
      final rows = buildLocalDetailInfoRows([
        _group('ID', LocalDetailInfoRole.id),
        _group(
          '画师',
          LocalDetailInfoRole.creator,
          values: [rawTagValue],
          isTagGroup: true,
          rawNamespace: 'artist',
        ),
        _group(
          '语言',
          LocalDetailInfoRole.language,
          values: const [],
        ),
      ]);

      expect(rows, hasLength(2));
      final retained = rows[1].single.values.single;
      expect(retained.displayText, '狐女');
      expect(retained.rawTagSearchValue, 'female:fox girl');
      expect(retained.rawNamespace, 'female');
    });
  });

  group('local detail page count', () {
    test('counts readable body files across episodes once and excludes cover',
        () {
      expect(
        countLocalComicPageFiles({
          0: const [
            r'C:\comic\cover.jpg',
            r'C:\comic\1.jpg',
            r'C:\comic\2.jpg',
          ],
          1: const [
            r'C:\comic\2.jpg',
            r'C:\comic\3.jpg',
            ' ',
          ],
        }),
        3,
      );
    });

    test('uses local files before EH fallback and omits unknown Pica/JM', () {
      expect(
        resolveLocalDetailPageCount(
          source: DownloadType.ehentai,
          episodeFiles: const {
            0: ['1.jpg', '2.jpg'],
          },
          ehFallbackPageCount: 40,
        ),
        2,
      );
      expect(
        resolveLocalDetailPageCount(
          source: DownloadType.ehentai,
          episodeFiles: const {},
          ehFallbackPageCount: 40,
        ),
        40,
      );
      expect(
        resolveLocalDetailPageCount(
          source: DownloadType.picacg,
          episodeFiles: const {},
        ),
        isNull,
      );
      expect(
        resolveLocalDetailPageCount(
          source: DownloadType.jm,
          episodeFiles: const {},
        ),
        isNull,
      );
    });

    test('uses a valid NH Pages value only when the local file index is empty',
        () {
      expect(
        resolveLocalDetailPageCount(
          source: DownloadType.nhentai,
          episodeFiles: const {},
          nhSourcePageValues: const ['zero', '0', '24'],
        ),
        24,
      );
      expect(
        resolveLocalDetailPageCount(
          source: DownloadType.nhentai,
          episodeFiles: const {
            0: ['1.jpg'],
          },
          nhSourcePageValues: const ['24'],
        ),
        1,
      );
    });
  });

  group('local detail source time', () {
    test('keeps human-readable values and omits blank values', () {
      expect(formatLocalDetailSourceTime(' 7 个月前 '), '7 个月前');
      expect(formatLocalDetailSourceTime(''), isNull);
      expect(formatLocalDetailSourceTime(null), isNull);
    });

    test('formats parseable dates in local detail style', () {
      expect(
        formatLocalDetailSourceTime('2026-07-13T13:46:00'),
        '2026-07-13 13:46',
      );

      final utc = DateTime.utc(2026, 7, 13, 13, 46);
      expect(
        formatLocalDetailSourceTime(utc.toIso8601String()),
        formatLocalDetailDateTime(utc.toLocal()),
      );
    });
  });

  testWidgets(
      'direct EH detail keeps summary information usable on a narrow large-text viewport',
      (tester) async {
    final gallery = DownloadedGallery(
      galleryTitle: 'EH gallery',
      uploader: 'uploader',
      link: 'https://e-hentai.org/g/220980/abc123def/',
      tagList: const [
        'artist:artist',
        'language:english',
      ],
      sourceTime: '7 months ago',
      pageCount: 12,
    );

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(360, 800),
          textScaler: TextScaler.linear(1.8),
        ),
        child: MaterialApp(
          home: LocalComicDetailPage(comic: gallery),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('12'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}

import 'dart:convert';

const originalDownloadDirSettingIndex = 90;
const localComicPathsSettingIndex = 91;
const localAlbumImageSortSettingIndex = 92;
const localLibraryListSortSettingIndex = 93;
const localLibraryAlbumOnlySettingIndex = 94;
const localDetailRecommendationSettingIndex = 95;
const localLibraryShowAllDatabaseRecordsSettingIndex = 96;
const downloadedLibraryViewSettingIndex = 103;
const localLibraryViewSettingIndex = 104;
const androidRootModeSettingIndex = 101;
const androidShizukuModeSettingIndex = 102;

const localAlbumImageSortNameAsc = '0';
const localAlbumImageSortNameDesc = '1';
const localAlbumImageSortTimeAsc = '2';
const localAlbumImageSortTimeDesc = '3';

String normalizeLocalAlbumImageSort(String? value) {
  switch (value) {
    case localAlbumImageSortNameDesc:
    case localAlbumImageSortTimeAsc:
    case localAlbumImageSortTimeDesc:
      return value!;
    default:
      return localAlbumImageSortNameAsc;
  }
}

String normalizeLocalLibraryListSort(String? value) {
  switch (value) {
    case 'time_asc':
    case 'name_asc':
    case 'name_desc':
    case 'size_asc':
    case 'size_desc':
      return value!;
    default:
      return 'time_desc';
  }
}

String normalizeLocalDetailRecommendationMode(String? value) {
  switch (value) {
    case '0':
    case '1':
    case '2':
    case '3':
    case '4':
    case '5':
      return value!;
    default:
      return '0';
  }
}

String normalizeLocalLibraryShowAllDatabaseRecords(String? value) {
  return value == '1' ? '1' : '0';
}

String normalizeDownloadedLibraryView(String? value) {
  switch (value) {
    case 'aggregate':
    case 'remote':
      return value!;
    default:
      return 'local';
  }
}

String normalizeLocalLibraryView(String? value) {
  switch (value) {
    case 'aggregate':
    case 'remote':
      return value!;
    default:
      return 'local';
  }
}

String normalizeAndroidRootMode(String? value) {
  return value == '1' ? '1' : '0';
}

String normalizeAndroidShizukuMode(String? value) {
  return value == '1' ? '1' : '0';
}

List<String> decodeLocalComicPathList(String? raw) {
  if (raw == null || raw.trim().isEmpty) {
    return const [];
  }

  try {
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      final seen = <String>{};
      return decoded
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty && seen.add(e))
          .toList();
    }
  } catch (_) {}

  final seen = <String>{};
  return raw
      .split(';;')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty && seen.add(e))
      .toList();
}

String encodeLocalComicPathList(Iterable<String> paths) {
  final seen = <String>{};
  final normalized = paths
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty && seen.add(e))
      .toList();
  return jsonEncode(normalized);
}

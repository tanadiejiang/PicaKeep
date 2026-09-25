import 'dart:convert';

const originalDownloadDirSettingIndex = 90;

/// 原应用下载目录的**使用方式**。
///
/// - `'0'`（默认）：**直接使用** —— 原地读取该目录，不复制任何文件。
///   省空间，也不改动原应用的数据；代价是读取要依赖 Shizuku/Root 权限
///   （原应用目录在它自己的私有存储里）。
/// - `'1'`：**复制到本应用** —— 把内容复制进本应用下载目录后再使用。
///   之后不再依赖原目录与权限，但同一份漫画会占双倍空间。
///
/// 默认取"直接使用"，是因为它已经是既有行为（`PrivilegedStorageAccess`
/// 原地读，见 local_library_static.dart），且用户的漫画库可能很大
/// （实测某设备原应用下载目录 507 MB）。
const originalDirUsageModeSettingIndex = 151;

/// [originalDirUsageModeSettingIndex] 的取值。
const String originalDirUsageModeDirect = '0';
const String originalDirUsageModeCopy = '1';
const localComicPathsSettingIndex = 91;
const localAlbumImageSortSettingIndex = 92;
const localLibraryListSortSettingIndex = 93;
const localLibraryAlbumOnlySettingIndex = 94;
const localDetailRecommendationSettingIndex = 95;
const localLibraryShowAllDatabaseRecordsSettingIndex = 96;
const downloadedLibraryViewSettingIndex = 103;
const localLibraryViewSettingIndex = 104;
const deleteBehaviorSettingIndex = 105;
const externalToolOrderSettingIndex = 106;
const externalToolVisibilitySettingIndex = 107;
const archiveDefaultPasswordsSettingIndex = 108;
const archiveAutoUnlockEnabledSettingIndex = 109;
const archiveReadingCacheLimitMbSettingIndex = 110;
const archiveUseChapterNumberSettingIndex = 111;
const favoritesLibraryViewSettingIndex = 112;
const imageFavoritesLibraryViewSettingIndex = 113;
const localLibraryCollectionShellSettingIndex = 118;
const androidRootModeSettingIndex = 101;
const androidShizukuModeSettingIndex = 102;

/// Max concurrent remote image downloads while reading (reader full-size
/// pages / preload). Bounds the HttpClient connection pool so a reader that
/// fans out dozens of precache requests cannot saturate it — the surplus would
/// otherwise queue inside `getUrl` and fail with a 5s "couldn't get a
/// connection" timeout, poison the singleton pool, and break every remote tab.
const remoteReaderImageConcurrencySettingIndex = 114;

/// Max concurrent remote cover/thumbnail downloads while browsing (favorites,
/// image favorites, downloaded, albums grids). Separate from the reader limit
/// because grids and the reader are never on screen together.
const remoteBrowseImageConcurrencySettingIndex = 115;

int _clampConcurrency(String? raw, int fallback) {
  final value = int.tryParse(raw?.trim() ?? '') ?? fallback;
  if (value < 1) {
    return 1;
  }
  if (value > 12) {
    return 12;
  }
  return value;
}

int normalizeRemoteReaderImageConcurrency(String? value) =>
    _clampConcurrency(value, 6);

int normalizeRemoteBrowseImageConcurrency(String? value) =>
    _clampConcurrency(value, 8);

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
  return value == '0' ? '0' : '1';
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

String normalizeTwoWayLibraryView(String? value) {
  return value == 'remote' ? 'remote' : 'local';
}

String normalizeAndroidRootMode(String? value) {
  return value == '1' ? '1' : '0';
}

String normalizeAndroidShizukuMode(String? value) {
  return value == '1' ? '1' : '0';
}

String normalizeDeleteBehavior(String? value) {
  return value == 'permanent' ? 'permanent' : 'trash';
}

String normalizeExternalToolOrderSetting(String? value) {
  if (value == null || value.trim().isEmpty) {
    return '["service_info","local_files","albums","app_capabilities"]';
  }
  return value;
}

String normalizeExternalToolVisibilitySetting(String? value) {
  if (value == null || value.trim().isEmpty) {
    return '["service_info","local_files","albums","app_capabilities"]';
  }
  return value;
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

String normalizeLocalCollectionShellPathKey(String path) {
  final normalized = path.trim().replaceAll('\\', '/');
  if (normalized.isEmpty) {
    return '';
  }
  return normalized.replaceFirst(RegExp(r'/+$'), '');
}

Map<String, bool> decodeLocalCollectionShellPathMap(String? raw) {
  if (raw == null || raw.trim().isEmpty) {
    return const <String, bool>{};
  }
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      final result = <String, bool>{};
      for (final entry in decoded.entries) {
        final key = normalizeLocalCollectionShellPathKey(entry.key.toString());
        if (key.isEmpty) {
          continue;
        }
        final value = entry.value;
        if (value == true || value?.toString() == '1') {
          result[key] = true;
        }
      }
      return result;
    }
    if (decoded is List) {
      final result = <String, bool>{};
      for (final entry in decoded) {
        final key = normalizeLocalCollectionShellPathKey(entry.toString());
        if (key.isNotEmpty) {
          result[key] = true;
        }
      }
      return result;
    }
  } catch (_) {}
  return const <String, bool>{};
}

String encodeLocalCollectionShellPathMap(Map<String, bool> values) {
  final normalized = <String, bool>{};
  for (final entry in values.entries) {
    final key = normalizeLocalCollectionShellPathKey(entry.key);
    if (key.isNotEmpty && entry.value == true) {
      normalized[key] = true;
    }
  }
  return jsonEncode(normalized);
}

bool isLocalCollectionShellPathEnabled(String path, String? raw) {
  final key = normalizeLocalCollectionShellPathKey(path);
  if (key.isEmpty) {
    return false;
  }
  return decodeLocalCollectionShellPathMap(raw)[key] == true;
}

String setLocalCollectionShellPathEnabled(
  String? raw,
  String path,
  bool enabled,
) {
  final key = normalizeLocalCollectionShellPathKey(path);
  final values = Map<String, bool>.from(
    decodeLocalCollectionShellPathMap(raw),
  );
  if (key.isEmpty) {
    return encodeLocalCollectionShellPathMap(values);
  }
  if (enabled) {
    values[key] = true;
  } else {
    values.remove(key);
  }
  return encodeLocalCollectionShellPathMap(values);
}


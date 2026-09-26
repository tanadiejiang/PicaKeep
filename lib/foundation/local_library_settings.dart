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

/// 「资源库显示设置」面板里**该出现哪些区块**（33 号，36 号改语义）。
///
/// ## 为什么抽成纯函数
///
/// 与 `shouldShowIllustViewSwitcher`（`local_library_illust_view.dart`）同一个理由：
/// "哪一项在什么条件下出现"是**用户可见的行为契约**，也是日后最容易被
/// "顺手放宽一点"的地方。放在这里可以被单测直接钉住，不必去渲染整页图集页
/// （`local_library_page.dart` 的档位判据依赖 `_remoteAvailable`，而它要靠
/// 客户端模式 + 远程服务在线才会为真，widget 测试里根本造不出来）。
class LocalLibraryViewScopeMenu {
  const LocalLibraryViewScopeMenu({
    required this.tiersApplicable,
    required this.tiersEnabled,
    required this.showDisplaySettings,
  });

  /// 本页是否存在"档位"这个概念：**不在本地根 / 远程根子页面上**。
  ///
  /// 子页面（点进某个图集目录、或某个远程根内部）里"切档位"没有意义 ——
  /// 那一页本身就是某个根的内部，所以整个档位折叠区都不出现。
  ///
  /// 这就是 24 号以来那条判据的"前半截"（页面里原叫 `_showSourceSelector`）。
  final bool tiersApplicable;

  /// 档位是否可以**真正切换**：远程服务当前可用。
  ///
  /// ## 为假时是"置灰"而不是"隐藏"（36 号改的就是这一点）
  ///
  /// 33 号曾把远程不可用时的档位整块隐藏（沿用 24 号的 `_showSourceSelector`）。
  /// 真机反馈证明这个选择是错的：用户在远程不可用的状态下**根本找不到档位**，
  /// 于是问"本地-聚合-远程 的档位切换按钮呢"。
  ///
  /// 现在的口径：**位置固定可见（挂在「资源库显示设置」面板里），
  /// 需要远程的那两档置灰并写明原因**。用户找得到、也知道为什么现在切不了；
  /// 换成"藏起来"就等于这个功能不存在。
  ///
  /// ⚠️ 但**不要**把这条放宽成"三档一律可选"：那会让用户切到一个必然空白的
  /// 档位，还以为是自己点错了。
  final bool tiersEnabled;

  /// 是否列出「资源库显示设置」这个入口本身（32 号加的页内设置入口）。
  final bool showDisplaySettings;

  /// 某一档现在能不能选。[needsRemote] 为真的档位（聚合 / 远程）需要远程可用。
  bool tierAvailable({required bool needsRemote}) =>
      !needsRemote || tiersEnabled;

  /// 面板整体为空时不该挂那颗按钮（理论上不会发生：两条判据不会同时为假）。
  bool get isEmpty => !tiersApplicable && !showDisplaySettings;
}

/// 按 [LocalLibraryViewScopeMenu] 的契约算出各区块的可见性。
///
/// [remoteAvailable] = 远程服务当前可用（`_remoteAvailable`）；
/// [isLocalRootPage] / [isRemoteRootPage] = 本页是本地根 / 远程根**子页面**；
/// [pageAlbumOnly] = 构造本页时传的 `widget.albumOnly`；
/// [albumOnly] = 生效的"仅显示图集"（`widget.albumOnly || settings[94] != '0'`）。
LocalLibraryViewScopeMenu localLibraryViewScopeMenu({
  required bool remoteAvailable,
  required bool isLocalRootPage,
  required bool isRemoteRootPage,
  required bool pageAlbumOnly,
  required bool albumOnly,
}) {
  return LocalLibraryViewScopeMenu(
    // 档位有没有意义：只看"是不是子页面"，**与远程是否可用无关**（见字段注释）。
    tiersApplicable: !isLocalRootPage && !isRemoteRootPage,
    // 能不能切：只有远程可用时才允许切到"聚合 / 远程"。
    tiersEnabled: remoteAvailable,
    // 与 32 号那个 `if (!widget.albumOnly || _isAlbumOnly)` 逐字一致。
    showDisplaySettings: !pageAlbumOnly || albumOnly,
  );
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


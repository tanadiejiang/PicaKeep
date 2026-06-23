import 'dart:io';

import 'package:path_provider/path_provider.dart';

const managedDataSourceModeCurrentOnly = '0';
const managedDataSourceModeCurrentAndOriginal = '1';
const managedDataSourceModeOriginalOnly = '2';
const managedDataSourceModeSettingIndex = 75;

String _managedDataSourceMode = managedDataSourceModeCurrentOnly;
String? _managedDataRootOverride;

String normalizeManagedDataSourceMode([String? value]) {
  switch (value) {
    case managedDataSourceModeCurrentAndOriginal:
    case managedDataSourceModeOriginalOnly:
      return value!;
    default:
      return managedDataSourceModeCurrentOnly;
  }
}

void setManagedDataSourceMode(String value) {
  _managedDataSourceMode = normalizeManagedDataSourceMode(value);
}

String get managedDataSourceMode => _managedDataSourceMode;

void setManagedDataRootOverride(String? value) {
  final path = value?.trim();
  _managedDataRootOverride = path != null && path.isNotEmpty ? path : null;
}

Future<String> getCurrentManagedDataRoot() async {
  final override = _managedDataRootOverride?.trim();
  if (override != null && override.isNotEmpty) {
    return Directory(override).absolute.path;
  }
  return (await getApplicationSupportDirectory()).path;
}

Future<String?> getOriginalManagedDataRoot() async {
  if (Platform.isWindows) {
    final appData = Platform.environment['APPDATA']?.trim();
    if (appData != null && appData.isNotEmpty) {
      return '$appData${Platform.pathSeparator}com.github.pacalini${Platform.pathSeparator}pica_comic';
    }
  }

  final home = Platform.environment['HOME']?.trim();
  if (home == null || home.isEmpty) {
    return null;
  }

  if (Platform.isLinux) {
    return '$home/.local/share/com.github.pacalini/pica_comic';
  }
  if (Platform.isMacOS) {
    return '$home/Library/Application Support/com.github.pacalini/pica_comic';
  }
  return null;
}

Future<List<String>> getManagedDataRoots([String? mode]) async {
  final normalized =
      normalizeManagedDataSourceMode(mode ?? _managedDataSourceMode);
  final current = await getCurrentManagedDataRoot();
  final original = await getOriginalManagedDataRoot();

  switch (normalized) {
    case managedDataSourceModeCurrentAndOriginal:
      final roots = <String>[current];
      if (original != null && original.isNotEmpty && original != current) {
        roots.add(original);
      }
      return roots;
    case managedDataSourceModeOriginalOnly:
      if (original != null && original.isNotEmpty) {
        return [original];
      }
      return [current];
    default:
      return [current];
  }
}

String managedDataFilePath(String root, String fileName) {
  return '$root${Platform.pathSeparator}$fileName';
}

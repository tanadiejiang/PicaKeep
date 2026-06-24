import 'dart:io';

import '../foundation/local_data_source.dart';
import '../foundation/local_favorites.dart';
import '../foundation/history.dart';
import 'server_config.dart';

String resolveManagedDataRoot(PicaKeepServerConfig config) {
  final configuredRoot = config.managedDataRoot.trim();
  if (configuredRoot.isNotEmpty) {
    return Directory(configuredRoot).absolute.path;
  }

  final downloadRoot = config.currentDownloadRoot.trim();
  if (downloadRoot.isNotEmpty) {
    final downloadDirectory = Directory(downloadRoot).absolute;
    if (_looksLikeDownloadDbRoot(downloadDirectory)) {
      final parent = downloadDirectory.parent.path;
      if (parent.isNotEmpty) {
        return parent;
      }
    }
  }

  for (final rawRoot in config.allLibraryRoots) {
    final candidate = rawRoot.trim();
    if (candidate.isEmpty) {
      continue;
    }
    final directory = Directory(candidate).absolute;
    if (_looksLikeDownloadDbRoot(directory)) {
      final parent = directory.parent.path;
      if (parent.isNotEmpty) {
        return parent;
      }
    }
    final nestedDownload = Directory(
      '${directory.path}${Platform.pathSeparator}download',
    );
    if (_looksLikeDownloadDbRoot(nestedDownload)) {
      return directory.path;
    }
  }

  return '';
}

Future<void> applyManagedDataRootForServerConfig(
  PicaKeepServerConfig config,
) async {
  setManagedDataRootOverride(resolveManagedDataRoot(config));
}

Future<void> reloadManagedDataStoresForServerConfig(
  PicaKeepServerConfig config,
) async {
  await applyManagedDataRootForServerConfig(config);
  await Future.wait([
    LocalFavoritesManager().init(),
    HistoryManager().init(),
  ]);
}

bool _looksLikeDownloadDbRoot(Directory directory) {
  return File(
    '${directory.path}${Platform.pathSeparator}download.db',
  ).existsSync();
}

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';
import 'pixiv_library.dart';

Future<List<PixivFolder>> readPixivFolders(List<String> roots) async {
  // Folder registry is a tiny read-only metadata query. Keep it on the caller
  // isolate; only the potentially large download table is moved to a worker.
  return [for (final root in roots) ...PixivLibrary(root).folders()];
}

/// Only consumes the existing manager-owned DB snapshot, never a live DB.
/// The worker owns and closes its SQLite connection; only plain rows cross back.
Future<List<Map<String, Object?>>> readDownloadSnapshot(String path) async {
  String? windowsLibrary;
  if (Platform.isWindows) {
    final bundled = File('${Directory.current.path}/windows/sqlite3.dll');
    if (await bundled.exists()) windowsLibrary = bundled.absolute.path;
  }
  return Isolate.run(() {
    if (windowsLibrary != null) {
      open.overrideFor(
          OperatingSystem.windows, () => DynamicLibrary.open(windowsLibrary!));
    }
    final db = sqlite3.open(path, mode: OpenMode.readOnly);
    try {
      return db
          .select(
              'select rowid as __rowid__, * from download order by time desc')
          .map((row) => Map<String, Object?>.from(row))
          .toList();
    } finally {
      db.dispose();
    }
  });
}

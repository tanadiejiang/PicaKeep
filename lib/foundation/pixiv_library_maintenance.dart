part of 'pixiv_library.dart';

/// Maintenance touches only terminal journals and free pages in the root DB.
class PixivMaintenanceResult {
  const PixivMaintenanceResult({
    this.compacted = 0,
    this.pruned = 0,
    this.vacuumed = false,
    this.bytesBefore = 0,
    this.bytesAfter = 0,
    this.deferredReason,
    this.error,
  });
  final int compacted, pruned, bytesBefore, bytesAfter;
  final bool vacuumed;
  final String? deferredReason, error;
}

const _pixivHistoryLimit = 100;
const _pixivVacuumMinFreeBytes = 64 * 1024;
const _pixivVacuumMaxBytes = 16 * 1024 * 1024;
final _pixivLastVacuumAttempt = <String, DateTime>{};

extension PixivLibraryMaintenance on PixivLibrary {
  /// Best effort: a maintenance problem never invalidates a completed action.
  Future<PixivMaintenanceResult> maintain() => exclusive(
        () async => _maintainWhenIdle(),
        // The check below defers migration roots instead of throwing.
        allowRootMigration: true,
        maintainAfter: false,
      );

  PixivMaintenanceResult _maintainWhenIdle() {
    Database? db;
    var inTransaction = false;
    var compacted = 0, pruned = 0, before = 0, after = 0;
    var vacuumed = false;
    PixivMaintenanceResult result({String? reason, String? error}) =>
        PixivMaintenanceResult(
          compacted: compacted,
          pruned: pruned,
          vacuumed: vacuumed,
          bytesBefore: before,
          bytesAfter: after,
          deferredReason: reason,
          error: error,
        );
    try {
      if (PixivLibrary.rootWriteBlocked?.call(root) == true) {
        return result(reason: 'root-migration');
      }
      if (hasActiveWrites ||
          PixivLibrary._activeBatches.any((key) => key.startsWith('$root::'))) {
        return result(reason: 'active-writer');
      }
      if (!registered) return result(reason: 'unregistered');
      if (folders().any(
          (folder) => PixivLibrary.hasPendingDownloads?.call(folder) == true)) {
        return result(reason: 'download-queue');
      }
      db = sqlite3.open(dbPath);
      db.execute('PRAGMA busy_timeout=0');
      before = File(dbPath).lengthSync();
      after = before;
      db.execute('BEGIN IMMEDIATE');
      inTransaction = true;
      final rows = db.select(
          'SELECT rowid AS sequence,id,kind,payload,stage,error FROM pixiv_operations');
      // Conservatively retain every recovery dependency until the whole root
      // is idle. This includes a completed child whose parent has not recorded
      // success yet, as well as the remove -> restore completion window.
      if (rows.any(
          (row) => row['stage'] != 'complete' && row['stage'] != 'trashed')) {
        return result(reason: 'pending-operation');
      }
      final byId = {for (final row in rows) row['id'] as String: row};
      final receipts = <({Row row, Map<String, Object?> data})>[];
      for (final row in rows.where((row) => row['stage'] == 'complete')) {
        if (row['error'] != null) return result(reason: 'operation-error');
        final data = jsonDecode(row['payload'] as String);
        if (data is! Map<String, dynamic>) {
          return result(reason: 'invalid-payload');
        }
        final receipt = _completedReceipt(row, data, byId);
        if (receipt == null) return result(reason: 'unrecognized-completion');
        receipts.add((row: row, data: receipt));
      }
      receipts.sort((a, b) {
        final time = ((b.data['completedAtMs'] as int?) ?? 0)
            .compareTo((a.data['completedAtMs'] as int?) ?? 0);
        return time != 0
            ? time
            : (b.row['sequence'] as int).compareTo(a.row['sequence'] as int);
      });
      for (var i = 0; i < receipts.length; i++) {
        final receipt = receipts[i];
        if (i >= _pixivHistoryLimit) {
          db.execute(
              'DELETE FROM pixiv_operations WHERE id=?', [receipt.row['id']]);
          pruned++;
        } else {
          final encoded = jsonEncode(receipt.data);
          if (encoded != receipt.row['payload']) {
            db.execute('UPDATE pixiv_operations SET payload=? WHERE id=?',
                [encoded, receipt.row['id']]);
            compacted++;
          }
        }
      }
      db.execute('COMMIT');
      inTransaction = false;

      final pageSize =
          db.select('PRAGMA page_size').single.values.single as int;
      final pages = db.select('PRAGMA page_count').single.values.single as int;
      final free =
          db.select('PRAGMA freelist_count').single.values.single as int;
      final now = DateTime.now();
      final last = _pixivLastVacuumAttempt[root];
      // Physical shrinking is optional, bounded work. Logical compaction still
      // runs for large databases; SQLite may reuse their free pages later.
      if (pages * pageSize <= _pixivVacuumMaxBytes &&
          free * pageSize >= _pixivVacuumMinFreeBytes &&
          free * 4 >= pages &&
          (last == null || now.difference(last) >= const Duration(hours: 1))) {
        _pixivLastVacuumAttempt[root] = now;
        if (db
            .select('PRAGMA quick_check')
            .any((row) => row.values.single != 'ok')) {
          throw StateError('数据库完整性检查未通过，停止空间整理');
        }
        // SQLite itself manages the atomic rewrite. No unlink/rebuild fallback.
        db.execute('VACUUM');
        vacuumed = true;
      }
      after = File(dbPath).lengthSync();
      return result();
    } catch (error, stack) {
      // Transactional errors roll back below; a failed VACUUM leaves already
      // committed receipts valid and can be retried in a later idle period.
      if (inTransaction) {
        compacted = 0;
        pruned = 0;
      }
      developer.log('Pixiv database maintenance deferred',
          name: 'PixivLibrary', error: error, stackTrace: stack);
      return result(reason: 'maintenance-error', error: error.toString());
    } finally {
      if (inTransaction) {
        try {
          db?.execute('ROLLBACK');
        } catch (_) {
          // Closing the connection also rolls back an uncommitted transaction.
        }
      }
      try {
        db?.dispose();
      } catch (error, stack) {
        developer.log('Could not close Pixiv maintenance connection',
            name: 'PixivLibrary', error: error, stackTrace: stack);
      }
    }
  }
}

Map<String, Object?>? _completedReceipt(
    Row row, Map<String, dynamic> data, Map<String, Row> byId) {
  if (!const [
    'transfer',
    'batch',
    'create',
    'rename',
    'keep',
    'remove',
    'restore'
  ].contains(row['kind'])) {
    return null;
  }
  if (data.containsKey('summaryVersion')) {
    return _validReceipt(row['kind'] as String, data) ? data : null;
  }
  if (data['completedAtMs'] != null && data['completedAtMs'] is! int) {
    return null;
  }
  final receipt = <String, Object?>{
    'summaryVersion': 1,
    if (data['completedAtMs'] != null) 'completedAtMs': data['completedAtMs'],
    // Legacy rows have no completion timestamp. Do not invent one.
    'compactedAtMs': DateTime.now().millisecondsSinceEpoch,
  };
  switch (row['kind']) {
    case 'transfer':
      if (data['row'] is! Map ||
          (data['row'] as Map)['id'] is! String ||
          data['sourceFolder'] is! String ||
          data['targetFolder'] is! String ||
          data['move'] is! bool ||
          (data['sourceRoot'] != null && data['sourceRoot'] is! String)) {
        return null;
      }
      receipt.addAll({
        'workId': (data['row'] as Map)['id'],
        'sourceFolder': data['sourceFolder'],
        'sourceRoot': data['sourceRoot'],
        'targetFolder': data['targetFolder'],
        'move': data['move'],
      });
    case 'batch':
      if (data['items'] is! List ||
          data['target'] is! String ||
          data['move'] is! bool) {
        return null;
      }
      final items = data['items'] as List;
      var success = 0, skipped = 0;
      for (final item in items) {
        if (item is! Map || item['operation'] is! String) return null;
        final child = byId[item['operation']];
        if (item['status'] == 'success') {
          if (child == null ||
              child['kind'] != 'transfer' ||
              child['stage'] != 'complete' ||
              child['error'] != null) {
            return null;
          }
          success++;
        } else if (item['status'] == 'skipped') {
          if (child != null &&
              (child['stage'] != 'complete' || child['error'] != null)) {
            return null;
          }
          skipped++;
        } else {
          return null;
        }
      }
      receipt.addAll({
        'targetFolder': data['target'],
        'move': data['move'],
        'total': items.length,
        'succeeded': success,
        'skipped': skipped,
      });
    default:
      if (data['folderId'] is! String) return null;
      receipt['folderId'] = data['folderId'];
      if (data['name'] is String) receipt['name'] = data['name'];
  }
  return receipt;
}

bool _validReceipt(String kind, Map<String, dynamic> data) {
  if (data['summaryVersion'] != 1 ||
      data['compactedAtMs'] is! int ||
      (data['completedAtMs'] != null && data['completedAtMs'] is! int)) {
    return false;
  }
  final allowed = {'summaryVersion', 'compactedAtMs', 'completedAtMs'};
  switch (kind) {
    case 'transfer':
      allowed.addAll(
          {'workId', 'sourceFolder', 'sourceRoot', 'targetFolder', 'move'});
      if (data['workId'] is! String ||
          data['sourceFolder'] is! String ||
          data['targetFolder'] is! String ||
          data['move'] is! bool ||
          (data['sourceRoot'] != null && data['sourceRoot'] is! String)) {
        return false;
      }
    case 'batch':
      allowed.addAll({'targetFolder', 'move', 'total', 'succeeded', 'skipped'});
      if (data['targetFolder'] is! String ||
          data['move'] is! bool ||
          data['total'] is! int ||
          data['succeeded'] is! int ||
          data['skipped'] is! int) {
        return false;
      }
      if (data['succeeded'] < 0 ||
          data['skipped'] < 0 ||
          data['total'] != data['succeeded'] + data['skipped']) {
        return false;
      }
    default:
      allowed.addAll({'folderId', 'name'});
      if (data['folderId'] is! String ||
          (data['name'] != null && data['name'] is! String)) {
        return false;
      }
  }
  return data.keys.every(allowed.contains);
}

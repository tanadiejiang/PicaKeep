import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'app.dart';

const localTrashStateTrashed = 'trash';
const localTrashStatePending = 'pending';
const localTrashStatePurged = 'purged';

String _joinLocalTrashPath(String parent, String child) {
  return '$parent${Platform.pathSeparator}$child';
}

String _normalizeTrashPathKey(String path) {
  final normalized = path.trim().replaceAll('\\', '/');
  if (normalized.isEmpty) {
    return '';
  }
  return normalized.replaceFirst(RegExp(r'/+$'), '').toLowerCase();
}

String _dbRecordKey(String dbPath, String id) {
  return '${_normalizeTrashPathKey(dbPath)}\u0000${id.trim()}';
}

String _dbDirectoryKey(String dbPath, String directory) {
  return '${_normalizeTrashPathKey(dbPath)}\u0000${_normalizeTrashPathKey(directory)}';
}

class LocalTrashRecordData {
  const LocalTrashRecordData({
    required this.id,
    required this.state,
    required this.itemKind,
    required this.itemId,
    required this.title,
    required this.subtitle,
    required this.cover,
    required this.sourceLabel,
    required this.originalPath,
    required this.trashedPath,
    required this.deletedAtMillis,
    required this.sizeBytes,
    required this.snapshotJson,
    this.rootId = '',
    this.remotePath = '',
    this.detailUrl = '',
    this.sourceDbPath = '',
    this.sourceDbId = '',
    this.sourceDirectory = '',
    this.sourceDbRowId = 0,
    this.sourceDbTimeMillis = 0,
    this.sourceDbRecordRemoved = false,
  });

  final String id;
  final String state;
  final String itemKind;
  final String itemId;
  final String title;
  final String subtitle;
  final String cover;
  final String sourceLabel;
  final String originalPath;
  final String trashedPath;
  final int deletedAtMillis;
  final int sizeBytes;
  final String snapshotJson;
  final String rootId;
  final String remotePath;
  final String detailUrl;
  final String sourceDbPath;
  final String sourceDbId;
  final String sourceDirectory;
  final int sourceDbRowId;
  final int sourceDbTimeMillis;
  final bool sourceDbRecordRemoved;

  factory LocalTrashRecordData.fromRow(Row row) {
    return LocalTrashRecordData(
      id: row['id'] as String? ?? '',
      state: row['state'] as String? ?? localTrashStateTrashed,
      itemKind: row['item_kind'] as String? ?? '',
      itemId: row['item_id'] as String? ?? '',
      title: row['title'] as String? ?? '',
      subtitle: row['subtitle'] as String? ?? '',
      cover: row['cover'] as String? ?? '',
      sourceLabel: row['source_label'] as String? ?? '',
      originalPath: row['original_path'] as String? ?? '',
      trashedPath: row['trashed_path'] as String? ?? '',
      deletedAtMillis: (row['deleted_at'] as int?) ?? 0,
      sizeBytes: (row['size_bytes'] as int?) ?? 0,
      snapshotJson: row['snapshot_json'] as String? ?? '{}',
      rootId: row['root_id'] as String? ?? '',
      remotePath: row['remote_path'] as String? ?? '',
      detailUrl: row['detail_url'] as String? ?? '',
      sourceDbPath: row['source_db_path'] as String? ?? '',
      sourceDbId: row['source_db_id'] as String? ?? '',
      sourceDirectory: row['source_directory'] as String? ?? '',
      sourceDbRowId: (row['source_db_rowid'] as int?) ?? 0,
      sourceDbTimeMillis: (row['source_db_time'] as int?) ?? 0,
      sourceDbRecordRemoved:
          ((row['source_db_record_removed'] as int?) ?? 0) != 0,
    );
  }
}

class LocalTrashHiddenIndex {
  const LocalTrashHiddenIndex({
    required this.itemIds,
    required this.originalPaths,
    required this.sourceDbIds,
    required this.sourceDbDirectories,
  });

  final Set<String> itemIds;
  final Set<String> originalPaths;
  final Set<String> sourceDbIds;
  final Set<String> sourceDbDirectories;

  bool matchesPath(String path) {
    final key = _normalizeTrashPathKey(path);
    return key.isNotEmpty && originalPaths.contains(key);
  }

  bool matchesManagedDownload({
    required String itemId,
    required String sourceDbPath,
    required String sourceDbId,
    required String sourceDirectory,
    required String originalPath,
  }) {
    final normalizedItemId = itemId.trim();
    if (normalizedItemId.isNotEmpty && itemIds.contains(normalizedItemId)) {
      return true;
    }
    final normalizedDbPath = sourceDbPath.trim();
    final normalizedDbId = sourceDbId.trim();
    if (normalizedDbPath.isNotEmpty &&
        normalizedDbId.isNotEmpty &&
        sourceDbIds.contains(_dbRecordKey(normalizedDbPath, normalizedDbId))) {
      return true;
    }
    final normalizedDirectory = sourceDirectory.trim();
    if (normalizedDbPath.isNotEmpty &&
        normalizedDirectory.isNotEmpty &&
        sourceDbDirectories.contains(
          _dbDirectoryKey(normalizedDbPath, normalizedDirectory),
        )) {
      return true;
    }
    return matchesPath(originalPath);
  }
}

class LocalTrashStore {
  LocalTrashStore._();

  static final LocalTrashStore instance = LocalTrashStore._();

  Database? _db;
  String? _dbPath;

  String get databasePath =>
      _joinLocalTrashPath(App.dataPath, 'local_trash.db');

  Database get _database {
    final nextPath = databasePath;
    if (_db != null && _dbPath == nextPath) {
      return _db!;
    }
    _db?.dispose();
    final file = File(nextPath);
    file.parent.createSync(recursive: true);
    _db = sqlite3.open(nextPath);
    _dbPath = nextPath;
    _createTables(_db!);
    _migrateTables(_db!);
    return _db!;
  }

  void dispose() {
    _db?.dispose();
    _db = null;
    _dbPath = null;
  }

  Future<void> upsert(LocalTrashRecordData record) async {
    _database.execute('''
      insert or replace into local_trash (
        id,
        state,
        item_kind,
        item_id,
        title,
        subtitle,
        cover,
        source_label,
        original_path,
        trashed_path,
        deleted_at,
        size_bytes,
        snapshot_json,
        root_id,
        remote_path,
        detail_url,
        source_db_path,
        source_db_id,
        source_directory,
        source_db_rowid,
        source_db_time,
        source_db_record_removed
      ) values (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    ''', [
      record.id,
      record.state,
      record.itemKind,
      record.itemId,
      record.title,
      record.subtitle,
      record.cover,
      record.sourceLabel,
      record.originalPath,
      record.trashedPath,
      record.deletedAtMillis,
      record.sizeBytes,
      record.snapshotJson,
      record.rootId,
      record.remotePath,
      record.detailUrl,
      record.sourceDbPath,
      record.sourceDbId,
      record.sourceDirectory,
      record.sourceDbRowId,
      record.sourceDbTimeMillis,
      record.sourceDbRecordRemoved ? 1 : 0,
    ]);
  }

  Future<List<LocalTrashRecordData>> listTrashed() async {
    final rows = _database.select(
      '''
      select * from local_trash
      where state = ?
      order by deleted_at desc
      ''',
      [localTrashStateTrashed],
    );
    return rows.map(LocalTrashRecordData.fromRow).toList(growable: false);
  }

  Future<LocalTrashRecordData?> find(String id) async {
    final rows = _database.select(
      'select * from local_trash where id = ? limit 1',
      [id],
    );
    if (rows.isEmpty) {
      return null;
    }
    return LocalTrashRecordData.fromRow(rows.first);
  }

  Future<void> delete(String id) async {
    _database.execute('delete from local_trash where id = ?', [id]);
  }

  Future<void> markPurged(String id) async {
    _database.execute(
      'update local_trash set state = ? where id = ?',
      [localTrashStatePurged, id],
    );
  }

  Future<LocalTrashHiddenIndex> hiddenIndex() =>
      Future.value(hiddenIndexSync());

  LocalTrashHiddenIndex hiddenIndexSync() {
    final rows = _database.select(
      '''
      select item_id, original_path, source_db_path, source_db_id, source_directory
      from local_trash
      where state in (?, ?)
      ''',
      [localTrashStateTrashed, localTrashStatePurged],
    );
    final itemIds = <String>{};
    final originalPaths = <String>{};
    final sourceDbIds = <String>{};
    final sourceDbDirectories = <String>{};
    for (final row in rows) {
      final itemId = (row['item_id'] as String? ?? '').trim();
      if (itemId.isNotEmpty) {
        itemIds.add(itemId);
      }
      final originalPath = _normalizeTrashPathKey(
        row['original_path'] as String? ?? '',
      );
      if (originalPath.isNotEmpty) {
        originalPaths.add(originalPath);
      }
      final sourceDbPath = row['source_db_path'] as String? ?? '';
      final sourceDbId = row['source_db_id'] as String? ?? '';
      if (sourceDbPath.trim().isNotEmpty && sourceDbId.trim().isNotEmpty) {
        sourceDbIds.add(_dbRecordKey(sourceDbPath, sourceDbId));
      }
      final sourceDirectory = row['source_directory'] as String? ?? '';
      if (sourceDbPath.trim().isNotEmpty && sourceDirectory.trim().isNotEmpty) {
        sourceDbDirectories.add(_dbDirectoryKey(sourceDbPath, sourceDirectory));
      }
    }
    return LocalTrashHiddenIndex(
      itemIds: itemIds,
      originalPaths: originalPaths,
      sourceDbIds: sourceDbIds,
      sourceDbDirectories: sourceDbDirectories,
    );
  }

  void _createTables(Database db) {
    db.execute('''
      create table if not exists local_trash (
        id text primary key,
        state text not null default 'trash',
        item_kind text,
        item_id text,
        title text,
        subtitle text,
        cover text,
        source_label text,
        original_path text,
        trashed_path text,
        deleted_at integer,
        size_bytes integer,
        snapshot_json text,
        root_id text,
        remote_path text,
        detail_url text,
        source_db_path text,
        source_db_id text,
        source_directory text,
        source_db_rowid integer not null default 0,
        source_db_time integer,
        source_db_record_removed integer not null default 0
      )
    ''');
    db.execute(
      'create index if not exists idx_local_trash_state on local_trash(state)',
    );
    db.execute('''
      create index if not exists idx_local_trash_source_db
      on local_trash(source_db_path, source_db_id)
    ''');
    db.execute('''
      create index if not exists idx_local_trash_source_directory
      on local_trash(source_db_path, source_directory)
    ''');
  }

  void _migrateTables(Database db) {
    final columns = db
        .select('pragma table_info(local_trash)')
        .map((row) => (row['name'] as String? ?? '').trim())
        .where((name) => name.isNotEmpty)
        .toSet();
    if (!columns.contains('source_db_rowid')) {
      db.execute('''
        alter table local_trash
        add column source_db_rowid integer not null default 0
      ''');
    }
  }
}

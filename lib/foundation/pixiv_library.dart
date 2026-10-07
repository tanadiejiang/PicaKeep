/// Physical Pixiv folders and restartable file operations. This module never
/// opens a network connection or deletes an existing database to repair it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';
import 'image_pipeline/image_background_notifications.dart';

part 'pixiv_library_maintenance.dart';

const pixivTransferPolicyIndex = 161;
const pixivFolderDeletePolicyIndex = 162;
String normalizePixivTransferPolicy(String? value) =>
    const ['copy', 'move'].contains(value) ? value! : 'ask';
String normalizePixivFolderDeletePolicy(String? value) =>
    const ['delete', 'keep'].contains(value) ? value! : 'ask';

class PixivFolder {
  const PixivFolder(
      {required this.root,
      required this.libraryId,
      required this.id,
      required this.name,
      required this.relativePath,
      this.isDefault = false,
      this.count = 0});
  final String root, libraryId, id, name, relativePath;
  final bool isDefault;
  final int count;
  bool get isRoot => id == 'root';
  String get path => isRoot ? root : p.join(root, relativePath);
  String get sourceId => 'pixiv_folder::$libraryId::$id';
  Map<String, String> toJson() =>
      {'root': root, 'libraryId': libraryId, 'folderId': id};
}

class PixivRecord {
  PixivRecord(this.folder, this.row);
  final PixivFolder folder;
  final Map<String, Object?> row;
  String get id => row['id'].toString();
  String get name => row['title']?.toString() ?? id;
  String get fileName => row['directory'].toString();
  String get path {
    if (p.isAbsolute(fileName)) {
      if (!p.equals(p.dirname(fileName), folder.path)) {
        throw StateError('作品路径不属于所在下载文件夹');
      }
      return fileName;
    }
    if (p.basename(fileName) != fileName ||
        fileName == '.' ||
        fileName == '..' ||
        fileName.isEmpty ||
        fileName.contains('\x00')) {
      throw StateError('作品路径不是直接子项');
    }
    return p.join(folder.path, fileName);
  }

  String get locationId => '${folder.libraryId}::${folder.id}::$id';
}

class PixivOperationResult {
  const PixivOperationResult(this.id, {this.skipped = false});
  final String id;
  final bool skipped;
}

/// Root download.db owns folder metadata and operation journals; each folder's
/// download table owns only its own works. All paths in the registry are relative.
class PixivLibrary {
  PixivLibrary(String root, {this.afterStage})
      : root = p.normalize(p.absolute(root));
  final String root;

  /// Fault-injection/telemetry boundary, invoked only after a journal commit.
  final void Function(String operationId, String stage)? afterStage;
  static final Map<String, Future<void>> _locks = {};
  static final Set<String> _leases = {};
  static final Set<String> _activeBatches = {};
  static bool Function(PixivFolder folder)? hasPendingDownloads;
  static void Function(String from, String to)? onFolderRenamed;
  static bool Function(String root)? rootWriteBlocked;

  bool get hasActiveWrites => _leases.any((key) => key.startsWith('$root::'));

  void _checkRootWritable() {
    if (rootWriteBlocked?.call(root) == true) {
      throw StateError('下载根迁移未完成，请先继续迁移再写入此位置');
    }
  }

  static const _uuid = Uuid();
  static const _schema = '''CREATE TABLE IF NOT EXISTS download (
    id TEXT PRIMARY KEY, title TEXT, subtitle TEXT, time INT,
    directory TEXT, size REAL, json TEXT)''';

  String get dbPath => p.join(root, 'download.db');
  bool get registered =>
      File(dbPath).existsSync() && _hasTable(dbPath, 'pixiv_folders');

  static void validateSegment(String name) {
    if (name.isEmpty ||
        name != name.trim() ||
        name == '.' ||
        name == '..' ||
        name.startsWith('.') ||
        name.endsWith('.') ||
        name.contains(RegExp(r'[<>:"/\\|?*\x00-\x1f]')) ||
        utf8.encode(name).length > 240 ||
        RegExp(r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$',
                caseSensitive: false)
            .hasMatch(name) ||
        const [
          'download.db',
          'download.db-wal',
          'download.db-shm',
          'download_queue.json'
        ].contains(name.toLowerCase())) {
      throw ArgumentError('名称不能为空或包含路径分隔符、保留名，长度不能超过240字节');
    }
  }

  static Database openDownloads(String path) {
    // SQLite reports read-only/locked/corrupt errors. Never unlink a user's DB.
    final db = sqlite3.open(p.join(path, 'download.db'));
    try {
      db.execute('PRAGMA busy_timeout=5000');
      db.execute(_schema);
      return db;
    } catch (_) {
      db.dispose();
      rethrow;
    }
  }

  static bool _hasTable(String file, String table) {
    final db = sqlite3.open(file, mode: OpenMode.readOnly);
    try {
      return db.select('SELECT 1 FROM sqlite_master WHERE type=? AND name=?',
          ['table', table]).isNotEmpty;
    } finally {
      db.dispose();
    }
  }

  Future<T> exclusive<T>(Future<T> Function() action,
      {bool allowRootMigration = false, bool maintainAfter = true}) async {
    final previous = _locks[root] ?? Future<void>.value();
    final done = Completer<void>();
    _locks[root] = done.future;
    await previous;
    try {
      if (!allowRootMigration) _checkRootWritable();
      return await action();
    } finally {
      // Never change database bytes under a root migration's snapshot.
      if (!allowRootMigration && maintainAfter) _maintainWhenIdle();
      done.complete();
      if (identical(_locks[root], done.future)) _locks.remove(root);
    }
  }

  Future<void> initialize() => exclusive(() async {
        await Directory(root).create(recursive: true);
        final db = openDownloads(root);
        try {
          db.execute(
              'CREATE TABLE IF NOT EXISTS pixiv_library (id TEXT PRIMARY KEY)');
          db.execute(
              'CREATE TABLE IF NOT EXISTS pixiv_folders (id TEXT PRIMARY KEY, name TEXT NOT NULL, path TEXT NOT NULL, position INT NOT NULL, is_default INT NOT NULL DEFAULT 0, state TEXT NOT NULL DEFAULT \'active\')');
          db.execute(
              'CREATE TABLE IF NOT EXISTS pixiv_operations (id TEXT PRIMARY KEY, kind TEXT NOT NULL, payload TEXT NOT NULL, stage TEXT NOT NULL, error TEXT)');
          db.execute(
              "CREATE UNIQUE INDEX IF NOT EXISTS pixiv_active_folder_path ON pixiv_folders(path) WHERE state='active'");
          if (db.select('SELECT id FROM pixiv_library').isEmpty) {
            db.execute('INSERT INTO pixiv_library VALUES (?)', [_uuid.v4()]);
          }
          db.execute(
              "INSERT OR IGNORE INTO pixiv_folders(id,name,path,position,is_default) VALUES ('root','主目录','.',0,1)");
        } finally {
          db.dispose();
        }
      });

  List<PixivFolder> folders(
      {bool counts = false, bool includeInactive = false}) {
    if (!registered) {
      return [
        PixivFolder(
            root: root,
            libraryId: '',
            id: 'root',
            name: '主目录',
            relativePath: '.',
            isDefault: true)
      ];
    }
    final db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
    try {
      final library =
          db.select('SELECT id FROM pixiv_library').single['id'] as String;
      return db
          .select(
              'SELECT * FROM pixiv_folders ${includeInactive ? '' : "WHERE state='active'"} ORDER BY position,id')
          .map((row) {
        final path = row['path'] as String;
        if (row['id'] != 'root') validateSegment(path);
        var count = 0;
        final file =
            p.join(path == '.' ? root : p.join(root, path), 'download.db');
        if (counts && File(file).existsSync()) {
          final sub = sqlite3.open(file, mode: OpenMode.readOnly);
          try {
            count = (sub
                .select(
                    "SELECT count(*) AS n FROM download WHERE id LIKE 'pixiv%'")
                .single['n'] as int);
          } finally {
            sub.dispose();
          }
        }
        return PixivFolder(
            root: root,
            libraryId: library,
            id: row['id'] as String,
            name: row['name'] as String,
            relativePath: path,
            isDefault: row['is_default'] == 1,
            count: count);
      }).toList();
    } finally {
      db.dispose();
    }
  }

  PixivFolder folder(String id, {String? libraryId}) {
    final match = folders().where((f) => f.id == id).firstOrNull;
    if (match == null || (libraryId != null && match.libraryId != libraryId)) {
      throw StateError('下载文件夹已失效，请重新选择');
    }
    if (!match.isRoot) {
      final file = p.join(match.path, 'download.db');
      if (!File(file).existsSync() ||
          !_hasTable(file, 'pixiv_folder_identity')) {
        throw StateError('下载文件夹的数据库或身份信息缺失');
      }
      final db = sqlite3.open(file, mode: OpenMode.readOnly);
      try {
        final identity = db.select('SELECT * FROM pixiv_folder_identity');
        if (identity.length != 1 ||
            identity.single['folder_id'] != match.id ||
            identity.single['library_id'] != match.libraryId) {
          throw StateError('下载文件夹身份与登记不一致，已停止写入');
        }
      } finally {
        db.dispose();
      }
    }
    return match;
  }

  PixivFolder get defaultFolder =>
      folders().firstWhere((f) => f.isDefault, orElse: () => folder('root'));

  Future<PixivFolder> createFolder(String name) => exclusive(() async {
        validateSegment(name);
        if (!registered) throw StateError('请先初始化下载文件夹');
        final path = p.join(root, name);
        if (FileSystemEntity.typeSync(path, followLinks: false) !=
            FileSystemEntityType.notFound) {
          throw StateError('同名文件或文件夹已存在');
        }
        final id = _uuid.v4();
        final library = folder('root').libraryId;
        final op = _uuid.v4();
        final payload = <String, Object?>{
          'folderId': id,
          'name': name,
          'libraryId': library
        };
        _journal(op, 'create', payload, 'prepared');
        await Directory(path).create();
        final sub = openDownloads(path);
        try {
          sub.execute(
              'CREATE TABLE pixiv_folder_identity(library_id TEXT, folder_id TEXT)');
          sub.execute(
              'INSERT INTO pixiv_folder_identity VALUES (?,?)', [library, id]);
        } finally {
          sub.dispose();
        }
        final db = openDownloads(root);
        try {
          db.execute(
              'INSERT INTO pixiv_folders(id,name,path,position) VALUES(?,?,?,?)',
              [id, name, name, folders().length]);
        } finally {
          db.dispose();
        }
        _journal(op, 'create', payload, 'complete');
        return folder(id);
      });

  Future<void> setDefault(String id) => exclusive(() async {
        folder(id);
        final db = openDownloads(root);
        try {
          db.execute('BEGIN IMMEDIATE');
          db.execute('UPDATE pixiv_folders SET is_default=(id=?)', [id]);
          db.execute('COMMIT');
        } finally {
          db.dispose();
        }
      });
  Future<void> reorder(List<String> ids) => exclusive(() async {
        final current = folders().map((f) => f.id).toSet();
        if (ids.toSet().length != ids.length ||
            current.length != ids.length ||
            !current.containsAll(ids)) {
          throw StateError('文件夹列表已变化，请刷新后重试');
        }
        final db = openDownloads(root);
        try {
          db.execute('BEGIN IMMEDIATE');
          for (var i = 0; i < ids.length; i++) {
            db.execute(
                'UPDATE pixiv_folders SET position=? WHERE id=?', [i, ids[i]]);
          }
          db.execute('COMMIT');
        } finally {
          db.dispose();
        }
      });

  String acquireLease(String folderId) {
    _checkRootWritable();
    folder(folderId);
    final key = '$root::$folderId';
    if (!_leases.add(key)) throw StateError('此文件夹正在写入，请稍后重试');
    return key;
  }

  static void releaseLease(String lease) => _leases.remove(lease);
  void _checkAvailable(String id) {
    if (pending().isNotEmpty) {
      throw StateError('请先继续处理未完成的文件操作，再重命名或删除文件夹');
    }
    if (_leases.contains('$root::$id')) throw StateError('此文件夹正在写入，请稍后重试');
    final f = folders().where((f) => f.id == id).firstOrNull;
    if (f != null && hasPendingDownloads?.call(f) == true) {
      throw StateError('有未完成下载任务引用此文件夹，请先完成或取消任务');
    }
  }

  Future<void> rename(String id, String name) => exclusive(() async {
        if (id == 'root') throw StateError('主目录请通过下载根设置修改');
        _checkAvailable(id);
        validateSegment(name);
        final old = folder(id);
        if (old.name == name) return;
        final target = p.join(root, name);
        if (FileSystemEntity.typeSync(target, followLinks: false) !=
            FileSystemEntityType.notFound) {
          throw StateError('目标名称已存在');
        }
        final op = _uuid.v4();
        final data = <String, Object?>{
          'folderId': id,
          'from': old.path,
          'to': target,
          'name': name
        };
        _journal(op, 'rename', data, 'prepared');
        await Directory(old.path).rename(target);
        _finishRename(op, data);
      });
  void _finishRename(String op, Map<String, dynamic> data) {
    final db = openDownloads(root);
    try {
      db.execute('UPDATE pixiv_folders SET name=?,path=? WHERE id=?',
          [data['name'], data['name'], data['folderId']]);
    } finally {
      db.dispose();
    }
    onFolderRenamed?.call(data['from'] as String, data['to'] as String);
    _journal(op, 'rename', data, 'complete');
  }

  List<PixivRecord> records(PixivFolder f) {
    final file = p.join(f.path, 'download.db');
    if (!File(file).existsSync()) return [];
    final db = sqlite3.open(file, mode: OpenMode.readOnly);
    try {
      return db
          .select("SELECT * FROM download WHERE id LIKE 'pixiv%'")
          .map((r) => PixivRecord(f, Map<String, Object?>.from(r)))
          .toList();
    } finally {
      db.dispose();
    }
  }

  PixivRecord? find(String folderId, String workId) =>
      records(folder(folderId)).where((r) => r.id == workId).firstOrNull;
  List<PixivRecord> copiesOf(String workId) =>
      [for (final f in folders()) ...records(f).where((r) => r.id == workId)];

  void _journal(
      String id, String kind, Map<String, Object?> payload, String stage,
      {String? error}) {
    final db = openDownloads(root);
    try {
      db.execute(
          'INSERT INTO pixiv_operations VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload,stage=excluded.stage,error=excluded.error',
          [
            id,
            kind,
            jsonEncode({
              ...payload,
              if (stage == 'complete')
                'completedAtMs': DateTime.now().millisecondsSinceEpoch,
            }),
            stage,
            error
          ]);
    } finally {
      db.dispose();
    }
    afterStage?.call(id, stage);
  }

  List<Map<String, Object?>> pending() {
    if (!registered) return [];
    final db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
    try {
      return db
          .select(
              "SELECT * FROM pixiv_operations WHERE stage NOT IN ('complete','trashed') ORDER BY rowid")
          .map((r) => Map<String, Object?>.from(r))
          .toList();
    } finally {
      db.dispose();
    }
  }

  Future<PixivOperationResult> transfer(PixivRecord source, String targetId,
          {required bool move,
          bool mergeForFolderRemoval = false,
          String? operationId}) =>
      exclusive(() async {
        final target = folder(targetId);
        if (_leases.contains('${source.folder.root}::${source.folder.id}') ||
            _leases.contains('$root::$targetId')) {
          throw StateError('文件夹正在写入，请稍后重试');
        }
        if (p.equals(source.folder.path, target.path)) {
          return const PixivOperationResult('', skipped: true);
        }
        final snapshot = await snapshotOf(source.path);
        final existing = find(targetId, source.id);
        if (existing != null) {
          if (!await matchesSnapshot(existing.path, snapshot)) {
            throw StateError('目标文件夹已有同一作品，但内容不同或不完整');
          }
          if (!mergeForFolderRemoval) {
            return const PixivOperationResult('', skipped: true);
          }
        }
        var name = p.basename(source.path);
        if (existing != null) {
          name = existing.fileName;
        } else if (FileSystemEntity.typeSync(p.join(target.path, name),
                followLinks: false) !=
            FileSystemEntityType.notFound) {
          name =
              '${p.basenameWithoutExtension(name)}_${_uuid.v4().substring(0, 8)}${p.extension(name)}';
        }
        if (p.basename(name) != name || name == '.' || name == '..') {
          throw StateError('不安全的作品名称');
        }
        final op = operationId ?? _uuid.v4();
        final payload = <String, Object?>{
          'sourceFolder': source.folder.id,
          'sourceRoot': source.folder.root,
          'sourcePath': source.path,
          'targetFolder': targetId,
          'name': name,
          'move': move,
          'row': source.row,
          'snapshot': snapshot,
          'merged': existing != null
        };
        _journal(op, 'transfer', payload,
            existing == null ? 'prepared' : 'committed');
        await _continueTransfer(
            op, payload, existing == null ? 'prepared' : 'committed');
        return PixivOperationResult(op);
      });

  Future<void> _continueTransfer(
      String op, Map<String, dynamic> data, String stage) async {
    try {
      final target = folder(data['targetFolder'] as String);
      final source = data['sourcePath'] as String;
      final destination = p.join(target.path, data['name'] as String);
      final snapshot = Map<String, dynamic>.from(data['snapshot'] as Map);
      final row = Map<String, Object?>.from(data['row'] as Map);
      final staging = p.join(target.path, '.pixiv_pending_$op');
      if (stage == 'prepared') {
        // Prepared implies the formal name was absent when the operation began.
        // Reuse a published, checksum-equal file after a crash, never overwrite.
        if (FileSystemEntity.typeSync(destination, followLinks: false) ==
            FileSystemEntityType.notFound) {
          await copySnapshot(source, staging, snapshot);
          if (!await matchesSnapshot(staging, snapshot)) {
            throw StateError('复制校验失败');
          }
          await _renameEntity(staging, destination);
        }
        if (!await matchesSnapshot(destination, snapshot)) {
          throw StateError('目标内容发生变化，已停止');
        }
        _journal(op, 'transfer', data, 'published');
        stage = 'published';
      }
      if (stage == 'published') {
        if (!await matchesSnapshot(destination, snapshot)) {
          throw StateError('目标文件不可用');
        }
        final db = openDownloads(target.path);
        try {
          db.execute('BEGIN IMMEDIATE');
          final found = db
              .select('SELECT directory FROM download WHERE id=?', [row['id']]);
          if (found.isNotEmpty && found.single['directory'] != data['name']) {
            throw StateError('目标记录发生变化');
          }
          if (found.isEmpty) {
            db.execute(
                'INSERT INTO download(id,title,subtitle,time,directory,size,json) VALUES(?,?,?,?,?,?,?)',
                [
                  row['id'],
                  row['title'],
                  row['subtitle'],
                  row['time'],
                  data['name'],
                  row['size'],
                  row['json']
                ]);
          }
          db.execute('COMMIT');
        } finally {
          db.dispose();
        }
        _journal(op, 'transfer', data, 'committed');
        stage = 'committed';
      }
      if (data['move'] == true &&
          (stage == 'committed' || stage == 'cleaning')) {
        if (!await matchesSnapshot(destination, snapshot)) {
          throw StateError('目标完整性校验失败，保留源');
        }
        if (stage == 'committed') {
          if (!await matchesSnapshot(source, snapshot)) {
            throw StateError('源内容已变化，停止清理');
          }
          _journal(op, 'transfer', data, 'cleaning');
        }
        await removeSnapshot(source, snapshot);
        final sourceDb = openDownloads(p.dirname(source));
        try {
          sourceDb.execute(
              'DELETE FROM download WHERE id=? AND directory IN (?,?)',
              [row['id'], row['directory'], source]);
        } finally {
          sourceDb.dispose();
        }
      }
      _journal(op, 'transfer', data, 'complete');
      ImageBackgroundNotifications.committed(destination);
    } catch (e) {
      // Preserve the last committed stage, not a generic failure stage.
      final db = openDownloads(root);
      try {
        db.execute('UPDATE pixiv_operations SET error=? WHERE id=?',
            [e.toString(), op]);
      } finally {
        db.dispose();
      }
      rethrow;
    }
  }

  Future<void> resume(String operationId) async {
    final operation =
        pending().where((r) => r['id'] == operationId).firstOrNull;
    if (operation?['kind'] == 'keep') {
      await _continueKeep(
          operationId,
          Map<String, dynamic>.from(
              jsonDecode(operation!['payload'] as String) as Map));
      return;
    }
    if (operation?['kind'] == 'batch') {
      await runBatch(operationId);
      return;
    }
    await exclusive(() async {
      final row = pending().where((r) => r['id'] == operationId).firstOrNull;
      if (row == null) return;
      final data = Map<String, dynamic>.from(
          jsonDecode(row['payload'] as String) as Map);
      if (row['kind'] == 'transfer') {
        await _continueTransfer(operationId, data, row['stage'] as String);
        return;
      }
      if (row['kind'] == 'rename') {
        final from = data['from'] as String, to = data['to'] as String;
        if (Directory(from).existsSync() && !Directory(to).existsSync()) {
          await Directory(from).rename(to);
        }
        if (Directory(from).existsSync() || !Directory(to).existsSync()) {
          throw StateError('目录位置有冲突，请保留资料后处理');
        }
        _finishRename(operationId, data);
        return;
      }
      if (row['kind'] == 'remove') {
        await _continueRemove(operationId, data, row['stage'] as String);
        return;
      }
      if (row['kind'] == 'create') {
        await _continueCreate(operationId, data);
        return;
      }
      if (row['kind'] == 'restore') {
        await _continueRestore(operationId, data);
        return;
      }
      throw StateError('无法识别的操作，已保留数据');
    });
  }

  String createBatch(List<PixivRecord> records, String targetId,
      {required bool move}) {
    _checkRootWritable();
    folder(targetId);
    final id = _uuid.v4();
    _journal(
        id,
        'batch',
        {
          'target': targetId,
          'move': move,
          'items': [
            for (final record in records)
              {
                'folder': record.folder.toJson(),
                'row': record.row,
                'operation': _uuid.v4(),
                'status': 'pending',
                'error': null
              }
          ]
        },
        'pending');
    return id;
  }

  Future<void> runBatch(String id,
      {void Function(int, int, int, int, List<String>)? onProgress,
      bool Function()? shouldStop}) async {
    final key = '$root::$id';
    if (!_activeBatches.add(key)) throw StateError('此批次正在处理');
    try {
      await _runBatch(id, onProgress: onProgress, shouldStop: shouldStop);
    } finally {
      _activeBatches.remove(key);
      await maintain();
    }
  }

  Future<void> _runBatch(String id,
      {void Function(int, int, int, int, List<String>)? onProgress,
      bool Function()? shouldStop}) async {
    _checkRootWritable();
    final db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
    late Map<String, dynamic> data;
    try {
      final row = db.select(
          'SELECT kind,stage,payload FROM pixiv_operations WHERE id=?',
          [id]).firstOrNull;
      // A completed/pruned batch is an idempotent no-op, including after restart.
      if (row == null || row['stage'] == 'complete') return;
      if (row['kind'] != 'batch') throw StateError('此记录不是批次操作');
      data = Map<String, dynamic>.from(
          jsonDecode(row['payload'] as String) as Map);
    } finally {
      db.dispose();
    }
    final items = (data['items'] as List).cast<Map>();
    for (var i = 0; i < items.length; i++) {
      if (shouldStop?.call() == true) break;
      final item = items[i];
      if (item['status'] == 'success' || item['status'] == 'skipped') continue;
      try {
        final op = item['operation'] as String;
        final read = sqlite3.open(dbPath, mode: OpenMode.readOnly);
        late List<Row> previous;
        try {
          previous = read
              .select('SELECT stage FROM pixiv_operations WHERE id=?', [op]);
        } finally {
          read.dispose();
        }
        if (previous.isNotEmpty) {
          if (previous.single['stage'] != 'complete') await resume(op);
          item['status'] = 'success';
        } else {
          final from = Map<String, String>.from(item['folder'] as Map);
          final sourceLibrary = PixivLibrary(from['root']!);
          final sourceFolder = sourceLibrary.registered
              ? sourceLibrary.folder(from['folderId']!,
                  libraryId: from['libraryId'])
              : PixivFolder(
                  root: from['root']!,
                  libraryId: from['libraryId']!,
                  id: 'root',
                  name: '旧下载目录',
                  relativePath: '.');
          final result = await transfer(
              PixivRecord(
                  sourceFolder, Map<String, Object?>.from(item['row'] as Map)),
              data['target'] as String,
              move: data['move'] == true,
              operationId: op);
          item['status'] = result.skipped ? 'skipped' : 'success';
        }
        item['error'] = null;
      } catch (e) {
        item['status'] = 'failed';
        item['error'] = e.toString();
      }
      final succeeded = items.where((e) => e['status'] == 'success').length;
      final skipped = items.where((e) => e['status'] == 'skipped').length;
      final failures = items
          .where((e) => e['status'] == 'failed')
          .map((e) => '${(e['row'] as Map)['title']}：${e['error']}')
          .toList();
      _journal(id, 'batch', data,
          succeeded + skipped == items.length ? 'complete' : 'pending');
      onProgress?.call(i + 1, items.length, succeeded, skipped, failures);
    }
    if (items
        .every((e) => e['status'] == 'success' || e['status'] == 'skipped')) {
      _journal(id, 'batch', data, 'complete');
    }
  }

  Future<void> removeFolder(String id,
      {required bool keepWorks, required bool useTrash}) async {
    if (id == 'root') throw StateError('不能删除Pixiv主目录');
    _checkAvailable(id);
    final f = folder(id);
    if (keepWorks) {
      final existing = pending()
          .where((row) =>
              row['kind'] == 'keep' &&
              (jsonDecode(row['payload'] as String) as Map)['folderId'] == id)
          .firstOrNull;
      final op = existing?['id'] as String? ?? _uuid.v4();
      final payload = existing == null
          ? <String, dynamic>{
              'folderId': id,
              'path': f.path,
              'backup': p.join(root, '.pixiv_metadata', op)
            }
          : Map<String, dynamic>.from(
              jsonDecode(existing['payload'] as String) as Map);
      if (existing == null) _journal(op, 'keep', payload, 'returning');
      await _continueKeep(op, payload);
      return;
    }
    await exclusive(() async {
      final op = _uuid.v4();
      final payload = <String, Object?>{
        'folderId': id,
        'path': f.path,
        'name': f.name,
        'trash': useTrash,
        'quarantine': p.join(root, '.pixiv_folder_trash', op)
      };
      _journal(op, 'remove', payload, 'prepared');
      await _continueRemove(op, payload, 'prepared');
    });
  }

  Future<void> _continueKeep(String op, Map<String, dynamic> data) async {
    final id = data['folderId'] as String;
    final f = folders().firstWhere((f) => f.id == id);
    if (Directory(f.path).existsSync()) {
      for (final record in records(f)) {
        await transfer(record, 'root', move: true, mergeForFolderRemoval: true);
      }
    }
    await exclusive(() async {
      final path = data['path'] as String;
      if (Directory(path).existsSync()) {
        final remaining = Directory(path)
            .listSync(followLinks: false)
            .where((e) => !['download.db', 'download.db-wal', 'download.db-shm']
                .contains(p.basename(e.path)))
            .toList();
        if (remaining.isNotEmpty) throw StateError('作品已迁回，但目录仍有未登记文件；已保留目录');
        final backup = data['backup'] as String;
        await Directory(backup).create(recursive: true);
        _journal(op, 'keep', data, 'metadata');
        for (final e in Directory(path).listSync(followLinks: false)) {
          final dest = p.join(backup, p.basename(e.path));
          if (File(dest).existsSync()) throw StateError('元数据备份冲突，保留目录');
          await File(e.path).rename(dest);
        }
        await Directory(path).delete();
      }
      _deactivate(id, 'removed');
      _journal(op, 'keep', data, 'complete');
    });
  }

  Future<void> _continueCreate(String op, Map<String, dynamic> data) async {
    final name = data['name'] as String, id = data['folderId'] as String;
    validateSegment(name);
    final path = p.join(root, name);
    if (!Directory(path).existsSync()) await Directory(path).create();
    final existing = Directory(path).listSync();
    if (existing.any((e) => p.basename(e.path) != 'download.db')) {
      throw StateError('新建目录中已有未知资料，不能接管');
    }
    final sub = openDownloads(path);
    try {
      sub.execute(
          'CREATE TABLE IF NOT EXISTS pixiv_folder_identity(library_id TEXT,folder_id TEXT)');
      final identity = sub.select('SELECT * FROM pixiv_folder_identity');
      if (identity.isNotEmpty &&
          (identity.single['folder_id'] != id ||
              identity.single['library_id'] != data['libraryId'])) {
        throw StateError('目录身份冲突');
      }
      if (identity.isEmpty) {
        sub.execute('INSERT INTO pixiv_folder_identity VALUES(?,?)',
            [data['libraryId'], id]);
      }
    } finally {
      sub.dispose();
    }
    final db = openDownloads(root);
    try {
      db.execute(
          'INSERT OR IGNORE INTO pixiv_folders(id,name,path,position) VALUES(?,?,?,?)',
          [id, name, name, folders().length]);
    } finally {
      db.dispose();
    }
    _journal(op, 'create', data, 'complete');
  }

  void _deactivate(String id, String state) {
    final db = openDownloads(root);
    try {
      db.execute('BEGIN IMMEDIATE');
      final wasDefault = db.select(
              'SELECT is_default FROM pixiv_folders WHERE id=?',
              [id]).firstOrNull?['is_default'] ==
          1;
      db.execute('UPDATE pixiv_folders SET state=?,is_default=0 WHERE id=?',
          [state, id]);
      if (wasDefault) {
        db.execute("UPDATE pixiv_folders SET is_default=1 WHERE id='root'");
      }
      db.execute('COMMIT');
    } finally {
      db.dispose();
    }
  }

  Future<void> _continueRemove(
      String op, Map<String, dynamic> data, String stage) async {
    final from = data['path'] as String, to = data['quarantine'] as String;
    if (stage == 'prepared') {
      await Directory(p.dirname(to)).create(recursive: true);
      if (Directory(from).existsSync() && !Directory(to).existsSync()) {
        await Directory(from).rename(to);
      }
      if (Directory(from).existsSync() || !Directory(to).existsSync()) {
        throw StateError('文件夹删除位置冲突');
      }
      _journal(op, 'remove', data, 'quarantined');
    }
    _deactivate(data['folderId'] as String,
        data['trash'] == true ? 'trashed' : 'removed');
    if (data['trash'] != true) {
      // Only this operation's verified quarantine directory is removed recursively.
      if (!p.isWithin(p.join(root, '.pixiv_folder_trash'), to) ||
          p.basename(to) != op) {
        throw StateError('不安全的删除位置');
      }
      if (Directory(to).existsSync()) {
        await Directory(to).delete(recursive: true);
      }
    }
    _journal(
        op, 'remove', data, data['trash'] == true ? 'trashed' : 'complete');
  }

  List<Map<String, Object?>> trashedFolders() {
    if (!registered) return [];
    final db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
    try {
      return db
          .select(
              "SELECT * FROM pixiv_operations WHERE kind='remove' AND stage='trashed'")
          .map((r) => Map<String, Object?>.from(r))
          .toList();
    } finally {
      db.dispose();
    }
  }

  Future<void> restoreFolder(String op) => exclusive(() async {
        final row = trashedFolders().firstWhere((r) => r['id'] == op);
        final data = Map<String, dynamic>.from(
            jsonDecode(row['payload'] as String) as Map);
        final to = p.join(root, data['name'] as String);
        if (FileSystemEntity.typeSync(to, followLinks: false) !=
            FileSystemEntityType.notFound) {
          throw StateError('同名目录已存在，无法覆盖还原');
        }
        data['trashOperation'] = op;
        final restoreOp = _uuid.v4();
        _journal(restoreOp, 'restore', data, 'prepared');
        await _continueRestore(restoreOp, data);
      });
  Future<void> _continueRestore(String op, Map<String, dynamic> data) async {
    final to = p.join(root, data['name'] as String),
        from = data['quarantine'] as String;
    if (Directory(from).existsSync() && !Directory(to).existsSync()) {
      await Directory(from).rename(to);
    }
    if (Directory(from).existsSync() || !Directory(to).existsSync()) {
      throw StateError('还原位置冲突');
    }
    final sub =
        sqlite3.open(p.join(to, 'download.db'), mode: OpenMode.readOnly);
    try {
      if (sub
              .select('SELECT folder_id FROM pixiv_folder_identity')
              .single['folder_id'] !=
          data['folderId']) {
        throw StateError('还原目录身份不匹配');
      }
    } finally {
      sub.dispose();
    }
    final db = openDownloads(root);
    try {
      db.execute(
          "UPDATE pixiv_folders SET state='active',is_default=0 WHERE id=?",
          [data['folderId']]);
    } finally {
      db.dispose();
    }
    _journal(data['trashOperation'] as String, 'remove', data, 'complete');
    _journal(op, 'restore', data, 'complete');
  }

  void relocateJournalPaths(String from, String to) {
    if (!registered) return;
    dynamic rewrite(dynamic value) {
      if (value is String &&
          (p.equals(value, from) || p.isWithin(from, value))) {
        return p.join(to, p.relative(value, from: from));
      }
      if (value is List) return value.map(rewrite).toList();
      if (value is Map) return value.map((k, v) => MapEntry(k, rewrite(v)));
      return value;
    }

    final db = openDownloads(root);
    try {
      db.execute('BEGIN IMMEDIATE');
      for (final row in db.select('SELECT id,payload FROM pixiv_operations')) {
        db.execute('UPDATE pixiv_operations SET payload=? WHERE id=?', [
          jsonEncode(rewrite(jsonDecode(row['payload'] as String))),
          row['id']
        ]);
      }
      db.execute('COMMIT');
    } finally {
      db.dispose();
    }
  }

  static Future<Map<String, Object?>> snapshotOf(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.link ||
        type == FileSystemEntityType.notFound) {
      throw StateError('源文件不存在或为链接');
    }
    final files = <String, Object?>{};
    final directories = <String>[];
    Future<void> add(String name, File f) async {
      final stat = await f.stat();
      files[name] = {
        'size': stat.size,
        'sha256': (await sha256.bind(f.openRead()).first).toString()
      };
    }

    if (type == FileSystemEntityType.file) {
      await add('', File(path));
    } else {
      await for (final e
          in Directory(path).list(recursive: true, followLinks: false)) {
        if (e is Link) throw StateError('作品内包含链接，不能安全复制');
        if (e is File) await add(p.relative(e.path, from: path), e);
        if (e is Directory) directories.add(p.relative(e.path, from: path));
      }
    }
    if (files.isEmpty) throw StateError('作品内容为空');
    return {
      'directory': type == FileSystemEntityType.directory,
      'files': files,
      'directories': directories..sort(),
    };
  }

  static Future<bool> matchesSnapshot(
      String path, Map<String, dynamic> expected) async {
    try {
      final actual = await snapshotOf(path);
      if (actual['directory'] != expected['directory']) return false;
      if (expected['directories'] is List &&
          jsonEncode(actual['directories']) !=
              jsonEncode(expected['directories'])) {
        return false;
      }
      final a = actual['files'] as Map, b = expected['files'] as Map;
      return a.length == b.length &&
          a.keys.every((k) => jsonEncode(a[k]) == jsonEncode(b[k]));
    } catch (_) {
      return false;
    }
  }

  static Future<void> copySnapshot(
      String from, String to, Map<String, dynamic> snapshot) async {
    if (!await matchesSnapshot(from, snapshot)) throw StateError('源内容变化，停止复制');
    for (final name
        in (snapshot['directories'] as List? ?? const []).cast<String>()) {
      await Directory(_snapshotPath(to, name)).create(recursive: true);
    }
    final files = snapshot['files'] as Map;
    for (final name in files.keys.cast<String>()) {
      final source = File(_snapshotPath(from, name));
      final target = File(_snapshotPath(to, name));
      await target.parent.create(recursive: true);
      await source.copy(target.path);
    }
  }

  static Future<void> _renameEntity(String from, String to) async {
    if (await FileSystemEntity.type(from, followLinks: false) ==
        FileSystemEntityType.directory) {
      await Directory(from).rename(to);
    } else {
      await File(from).rename(to);
    }
  }

  static Future<void> removeSnapshot(
      String path, Map<String, dynamic> snapshot) async {
    final files = snapshot['files'] as Map;
    // A resumed cleanup may legitimately have missing old files. New files or
    // directories, however, must stop cleanup before any more source is removed.
    if (snapshot['directory'] == true && await Directory(path).exists()) {
      final expectedDirs =
          (snapshot['directories'] as List?)?.cast<String>().toSet();
      await for (final entity
          in Directory(path).list(recursive: true, followLinks: false)) {
        final name = p.relative(entity.path, from: path);
        if (entity is Link ||
            (entity is File && !files.containsKey(name)) ||
            (entity is Directory &&
                expectedDirs != null &&
                !expectedDirs.contains(name))) {
          throw StateError('源目录新增内容，停止清理并保留资料');
        }
      }
    }
    for (final name in files.keys.cast<String>()) {
      final f = File(_snapshotPath(path, name));
      if (!await f.exists()) continue; // resumed cleanup
      final expected = files[name] as Map;
      if (await f.length() != expected['size'] ||
          (await sha256.bind(f.openRead()).first).toString() !=
              expected['sha256']) {
        throw StateError('源文件变化，已停止删除');
      }
      await f.delete();
    }
    if (snapshot['directory'] == true && await Directory(path).exists()) {
      final dirs = await Directory(path)
          .list(recursive: true, followLinks: false)
          .where((e) => e is Directory)
          .toList();
      dirs.sort((a, b) => b.path.length.compareTo(a.path.length));
      for (final d in dirs) {
        if (await Directory(d.path).list().isEmpty) await d.delete();
      }
      await Directory(path)
          .delete(); // fails safely if any unrecorded file remains
    }
  }

  static String _snapshotPath(String root, String relative) {
    if (relative.isEmpty) return root;
    final path = p.normalize(p.join(root, relative));
    if (p.isAbsolute(relative) || !p.isWithin(root, path)) {
      throw StateError('文件快照包含越界路径，停止操作');
    }
    return path;
  }
}

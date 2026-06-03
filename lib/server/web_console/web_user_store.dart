import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../foundation/app.dart';
import '../server_config.dart';

class WebConsoleUser {
  const WebConsoleUser({
    required this.id,
    required this.username,
    required this.passwordHash,
    required this.salt,
    required this.role,
    required this.createdAt,
  });

  final int id;
  final String username;
  final String passwordHash;
  final String salt;
  final String role;
  final DateTime createdAt;

  bool get isAdmin => role == WebConsoleUserStore.adminRole;

  Map<String, dynamic> toJson() => {
        'id': id,
        'username': username,
        'role': role,
        'createdAt': createdAt.toIso8601String(),
      };

  static WebConsoleUser fromRow(Row row) {
    return WebConsoleUser(
      id: row['id'] as int,
      username: row['username']?.toString() ?? '',
      passwordHash: row['password_hash']?.toString() ?? '',
      salt: row['salt']?.toString() ?? '',
      role: row['role']?.toString() ?? WebConsoleUserStore.userRole,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (row['created_at'] as int?) ?? 0,
      ),
    );
  }
}

class WebConsoleHistoryEntry {
  const WebConsoleHistoryEntry({
    required this.userId,
    required this.target,
    required this.title,
    required this.cover,
    required this.ep,
    required this.page,
    required this.maxPage,
    required this.readEpisode,
    required this.updatedAt,
  });

  final int userId;
  final String target;
  final String title;
  final String cover;
  final int ep;
  final int page;
  final int? maxPage;
  final Set<int> readEpisode;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() => {
        'target': target,
        'title': title,
        'cover': cover,
        'coverUrl': cover,
        'ep': ep,
        'page': page,
        'maxPage': maxPage,
        'max_page': maxPage,
        'readEpisode': readEpisode.toList()..sort(),
        'updatedAt': updatedAt.toIso8601String(),
        'time': updatedAt.millisecondsSinceEpoch,
      };

  static WebConsoleHistoryEntry fromRow(Row row) {
    return WebConsoleHistoryEntry(
      userId: row['user_id'] as int,
      target: row['target']?.toString() ?? '',
      title: row['title']?.toString() ?? '',
      cover: row['cover']?.toString() ?? '',
      ep: (row['ep'] as int?) ?? 0,
      page: (row['page'] as int?) ?? 0,
      maxPage: row['max_page'] as int?,
      readEpisode: _decodeReadEpisode(row['read_episode']?.toString() ?? ''),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        (row['updated_at'] as int?) ?? 0,
      ),
    );
  }
}

class WebConsoleUserStore {
  WebConsoleUserStore({String? databasePath})
      : _databasePath = databasePath ??
            '${App.dataPath}${Platform.pathSeparator}web_console.db';

  static const adminRole = 'admin';
  static const userRole = 'user';

  final String _databasePath;
  Database? _db;

  Future<void> init(PicaKeepServerConfig config) async {
    final file = File(_databasePath);
    await file.parent.create(recursive: true);
    final db = sqlite3.open(_databasePath);
    _configureDatabase(db);
    _db = db;
    await ensureAdmin(config.consolePassword);
  }

  void dispose() {
    _db?.dispose();
    _db = null;
  }

  Future<WebConsoleUser> ensureAdmin(String password) async {
    final existing = findUserByUsername('admin');
    if (existing != null) {
      final nextPasswordHash = hashPassword(existing.salt, password);
      if (!_constantTimeEquals(nextPasswordHash, existing.passwordHash)) {
        return resetPassword(
          userId: existing.id,
          password: password,
          allowEmptyPassword: true,
        );
      }
      if (existing.role != adminRole) {
        _database.execute(
          'update web_users set role = ? where id = ?',
          [adminRole, existing.id],
        );
        return findUserById(existing.id)!;
      }
      return existing;
    }
    return createUser(
      username: 'admin',
      password: password,
      role: adminRole,
      allowEmptyPassword: true,
    );
  }

  WebConsoleUser createUser({
    required String username,
    required String password,
    String role = userRole,
    bool allowEmptyPassword = false,
  }) {
    final normalizedUsername = _normalizeUsername(username);
    if (normalizedUsername.isEmpty) {
      throw const WebConsoleStoreException('invalid username');
    }
    final normalizedRole = role == adminRole ? adminRole : userRole;
    if (!allowEmptyPassword && password.isEmpty) {
      throw const WebConsoleStoreException('empty password is not allowed');
    }
    if (findUserByUsername(normalizedUsername) != null) {
      throw const WebConsoleStoreException('user already exists');
    }
    final salt = _makeSalt();
    final hash = hashPassword(salt, password);
    _database.execute(
      '''
      insert into web_users (username, password_hash, salt, role, created_at)
      values (?, ?, ?, ?, ?)
      ''',
      [
        normalizedUsername,
        hash,
        salt,
        normalizedRole,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
    return findUserByUsername(normalizedUsername)!;
  }

  List<WebConsoleUser> listUsers() {
    final rows = _database.select(
      'select * from web_users order by role asc, username collate nocase asc',
    );
    return rows.map(WebConsoleUser.fromRow).toList(growable: false);
  }

  WebConsoleUser? findUserById(int id) {
    final rows = _database.select(
      'select * from web_users where id = ? limit 1',
      [id],
    );
    if (rows.isEmpty) {
      return null;
    }
    return WebConsoleUser.fromRow(rows.first);
  }

  WebConsoleUser? findUserByUsername(String username) {
    final normalizedUsername = _normalizeUsername(username);
    if (normalizedUsername.isEmpty) {
      return null;
    }
    final rows = _database.select(
      'select * from web_users where lower(username) = lower(?) limit 1',
      [normalizedUsername],
    );
    if (rows.isEmpty) {
      return null;
    }
    return WebConsoleUser.fromRow(rows.first);
  }

  WebConsoleUser? verifyLogin(String username, String password) {
    final user = findUserByUsername(username);
    if (user == null) {
      return null;
    }
    final candidate = hashPassword(user.salt, password);
    if (!_constantTimeEquals(candidate, user.passwordHash)) {
      return null;
    }
    return user;
  }

  WebConsoleUser resetPassword({
    required int userId,
    required String password,
    bool allowEmptyPassword = false,
  }) {
    if (!allowEmptyPassword && password.isEmpty) {
      throw const WebConsoleStoreException('empty password is not allowed');
    }
    final user = findUserById(userId);
    if (user == null) {
      throw const WebConsoleStoreException('user not found');
    }
    final salt = _makeSalt();
    final hash = hashPassword(salt, password);
    _database.execute(
      'update web_users set password_hash = ?, salt = ? where id = ?',
      [hash, salt, userId],
    );
    return findUserById(userId)!;
  }

  void deleteUser(int userId) {
    final user = findUserById(userId);
    if (user == null) {
      throw const WebConsoleStoreException('user not found');
    }
    if (user.isAdmin) {
      final adminCount = _database.select(
        'select count(*) as count from web_users where role = ?',
        [adminRole],
      ).first['count'] as int;
      if (adminCount <= 1) {
        throw const WebConsoleStoreException('cannot delete last admin');
      }
    }
    _database.execute('delete from web_users where id = ?', [userId]);
  }

  List<WebConsoleHistoryEntry> listHistory(int userId, {int limit = 50}) {
    final normalizedLimit = limit.clamp(1, 500).toInt();
    final rows = _database.select(
      '''
      select * from web_history
      where user_id = ?
      order by updated_at desc
      limit ?
      ''',
      [userId, normalizedLimit],
    );
    return rows.map(WebConsoleHistoryEntry.fromRow).toList(growable: false);
  }

  WebConsoleHistoryEntry upsertHistory({
    required int userId,
    required String target,
    required String title,
    required String cover,
    required int ep,
    required int page,
    required int? maxPage,
    required Set<int> readEpisode,
  }) {
    final normalizedTarget = target.trim();
    if (normalizedTarget.isEmpty) {
      throw const WebConsoleStoreException('invalid target');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    _database.execute(
      '''
      insert into web_history
        (user_id, target, title, cover, ep, page, max_page, read_episode, updated_at)
      values (?, ?, ?, ?, ?, ?, ?, ?, ?)
      on conflict(user_id, target) do update set
        title = excluded.title,
        cover = excluded.cover,
        ep = excluded.ep,
        page = excluded.page,
        max_page = excluded.max_page,
        read_episode = excluded.read_episode,
        updated_at = excluded.updated_at
      ''',
      [
        userId,
        normalizedTarget,
        title.trim(),
        cover.trim(),
        ep < 0 ? 0 : ep,
        page < 0 ? 0 : page,
        maxPage,
        _encodeReadEpisode(readEpisode),
        now,
      ],
    );
    return findHistory(userId: userId, target: normalizedTarget)!;
  }

  WebConsoleHistoryEntry? findHistory({
    required int userId,
    required String target,
  }) {
    final rows = _database.select(
      '''
      select * from web_history
      where user_id = ? and target = ?
      limit 1
      ''',
      [userId, target.trim()],
    );
    if (rows.isEmpty) {
      return null;
    }
    return WebConsoleHistoryEntry.fromRow(rows.first);
  }

  void deleteHistory({required int userId, String? target}) {
    final normalizedTarget = target?.trim() ?? '';
    if (normalizedTarget.isEmpty) {
      _database.execute('delete from web_history where user_id = ?', [userId]);
      return;
    }
    _database.execute(
      'delete from web_history where user_id = ? and target = ?',
      [userId, normalizedTarget],
    );
  }

  Database get _database {
    final db = _db;
    if (db == null) {
      throw StateError('web console user store is not initialized');
    }
    return db;
  }

  void _configureDatabase(Database db) {
    db.execute('pragma foreign_keys = on;');
    db.execute('''
      create table if not exists web_users (
        id integer primary key autoincrement,
        username text not null unique collate nocase,
        password_hash text not null,
        salt text not null,
        role text not null,
        created_at integer not null
      );
    ''');
    db.execute('''
      create table if not exists web_history (
        user_id integer not null,
        target text not null,
        title text not null default '',
        cover text not null default '',
        ep integer not null default 0,
        page integer not null default 0,
        max_page integer,
        read_episode text not null default '',
        updated_at integer not null,
        primary key (user_id, target),
        foreign key (user_id) references web_users(id) on delete cascade
      );
    ''');
    db.execute('''
      create index if not exists idx_web_history_user_updated
      on web_history(user_id, updated_at desc);
    ''');
  }

  static String hashPassword(String salt, String password) {
    return sha256.convert(utf8.encode('$salt$password')).toString();
  }

  static String _normalizeUsername(String username) => username.trim();

  static String _makeSalt() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return base64Url.encode(bytes);
  }

  static bool _constantTimeEquals(String a, String b) {
    final aBytes = utf8.encode(a);
    final bBytes = utf8.encode(b);
    var diff = aBytes.length ^ bBytes.length;
    final maxLength =
        aBytes.length > bBytes.length ? aBytes.length : bBytes.length;
    for (var i = 0; i < maxLength; i++) {
      final av = i < aBytes.length ? aBytes[i] : 0;
      final bv = i < bBytes.length ? bBytes[i] : 0;
      diff |= av ^ bv;
    }
    return diff == 0;
  }
}

class WebConsoleStoreException implements Exception {
  const WebConsoleStoreException(this.message);

  final String message;

  @override
  String toString() => message;
}

String _encodeReadEpisode(Set<int> readEpisode) {
  final values = readEpisode.where((value) => value >= 0).toList()..sort();
  return values.join(',');
}

Set<int> _decodeReadEpisode(String value) {
  return value
      .split(',')
      .map((entry) => int.tryParse(entry.trim()))
      .whereType<int>()
      .toSet();
}

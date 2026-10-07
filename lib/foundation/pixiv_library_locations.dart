import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'app.dart';
import 'local_trash_store.dart';
import 'pixiv_library.dart';
import 'windows_rename_retry.dart';

File get _locations =>
    File(p.join(App.dataPath, 'pixiv_library_locations.json'));
Map<String, dynamic> _read() {
  _configureWriteBarrier();
  if (!_locations.existsSync()) {
    return {'roots': <String>[], 'redirects': <String, String>{}};
  }
  return Map<String, dynamic>.from(
      jsonDecode(_locations.readAsStringSync()) as Map);
}

void _save(Map<String, dynamic> data) {
  _locations.parent.createSync(recursive: true);
  final temp = File('${_locations.path}.part');
  temp.writeAsStringSync(jsonEncode(data), flush: true);
  temp.renameSync(_locations.path);
}

String resolvePixivLibraryRoot(String path) {
  var resolved = p.normalize(p.absolute(path));
  final redirects = _read()['redirects'] as Map;
  if (!redirects.containsKey(resolved)) return path;
  final seen = <String>{};
  while (redirects.containsKey(resolved) && seen.add(resolved)) {
    resolved = redirects[resolved] as String;
  }
  return resolved;
}

void rememberPixivLibrary(String path) {
  PixivLibrary.onFolderRenamed = LocalTrashStore.instance.relocatePaths;
  final data = _read();
  final roots = List<String>.from(data['roots'] as List);
  final resolved = resolvePixivLibraryRoot(path);
  final incoming = PixivLibrary(resolved);
  if (incoming.registered) {
    final id = incoming.folder('root').libraryId;
    for (final previous in roots.map(resolvePixivLibraryRoot)) {
      if (p.equals(previous, resolved)) continue;
      final existing = PixivLibrary(previous);
      if (existing.registered && existing.folder('root').libraryId == id) {
        throw StateError('两个不同目录具有同一下载库身份，请使用应用迁移功能，不能直接接管整库副本');
      }
    }
  }
  if (!roots.any((r) => p.equals(r, resolved))) roots.add(resolved);
  data['roots'] = roots;
  _save(data);
}

List<String> pixivLibraryRoots(String current) => {
      current,
      ...List<String>.from(_read()['roots'] as List)
          .map(resolvePixivLibraryRoot),
    }.toList();

File get _rootJournal => File(p.join(App.dataPath, 'pixiv_root_move.json'));

void _configureWriteBarrier() {
  PixivLibrary.rootWriteBlocked = (path) {
    if (!_rootJournal.existsSync()) return false;
    try {
      final data = jsonDecode(_rootJournal.readAsStringSync()) as Map;
      return p.equals(path, data['from'] as String) ||
          p.equals(path, data['to'] as String) ||
          p.isWithin(data['from'] as String, path) ||
          p.isWithin(data['to'] as String, path);
    } catch (_) {
      return true; // An unreadable operation journal is not permission to write.
    }
  };
}

void _saveRootJournal(File file, Map<String, dynamic> data) {
  file.parent.createSync(recursive: true);
  final temporary = File('${file.path}.part');
  temporary.writeAsStringSync(jsonEncode(data), flush: true);
  temporary.renameSync(file.path);
}

void _validateRootMove(String from, String to) {
  if (!p.isAbsolute(from) ||
      !p.isAbsolute(to) ||
      p.equals(from, to) ||
      p.equals(from, App.dataPath) ||
      p.isWithin(from, App.dataPath) ||
      p.equals(to, App.dataPath) ||
      p.isWithin(to, App.dataPath) ||
      p.isWithin(from, to) ||
      p.isWithin(to, from)) {
    throw StateError('下载根迁移路径不安全或互相包含');
  }
  for (final path in [from, to]) {
    if (FileSystemEntity.typeSync(path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw StateError('不能以链接作为迁移根');
    }
  }
}

Future<void> relocatePixivLibrary(String from, String to,
    {void Function(String stage)? afterStage}) async {
  _configureWriteBarrier();
  from = p.normalize(p.absolute(resolvePixivLibraryRoot(from)));
  to = p.normalize(p.absolute(to));
  if (p.equals(from, to)) return;
  _validateRootMove(from, to);
  final library = PixivLibrary(from);
  await library.exclusive(() async {
    if (_rootJournal.existsSync()) throw StateError('有未完成的根迁移，请使用继续迁移');
    if (library.pending().isNotEmpty ||
        library.hasActiveWrites ||
        library
            .folders()
            .any((f) => PixivLibrary.hasPendingDownloads?.call(f) == true)) {
      throw StateError('请先处理未完成下载或文件操作，再迁移下载根');
    }
    if (Directory(to).existsSync() && Directory(to).listSync().isNotEmpty) {
      throw StateError('目标目录已有内容，请选择空目录；不会覆盖或合并现有库');
    }
    final data = <String, dynamic>{
      'from': from,
      'to': to,
      'libraryId': library.folder('root').libraryId,
      'temporary': '$to.pixiv_pending_${const Uuid().v4()}',
      'stage': 'preparing',
    };
    // Block application writers before computing the source snapshot.
    _saveRootJournal(_rootJournal, data);
    afterStage?.call('preparing');
    await _finishRelocation(_rootJournal, data, afterStage: afterStage);
  }, allowRootMigration: true);
}

bool get hasPendingPixivRootMove => _rootJournal.existsSync();
Future<void> resumePixivRootMove(
    {void Function(String stage)? afterStage}) async {
  _configureWriteBarrier();
  if (!_rootJournal.existsSync()) return;
  final data = Map<String, dynamic>.from(
      jsonDecode(_rootJournal.readAsStringSync()) as Map);
  await PixivLibrary(data['from'] as String).exclusive(() async {
    if (!_rootJournal.existsSync()) return;
    final current = Map<String, dynamic>.from(
        jsonDecode(_rootJournal.readAsStringSync()) as Map);
    await _finishRelocation(_rootJournal, current, afterStage: afterStage);
  }, allowRootMigration: true);
}

Future<void> _finishRelocation(File journal, Map<String, dynamic> data,
    {void Function(String stage)? afterStage}) async {
  final from = data['from'] as String,
      to = data['to'] as String,
      temp = data['temporary'] as String;
  _validateRootMove(from, to);
  if (!p.equals(p.dirname(temp), p.dirname(to)) ||
      !p.basename(temp).startsWith('${p.basename(to)}.pixiv_pending_') ||
      !const [
        'preparing',
        'copy',
        'published',
        'cleaning',
        'cleaned',
        'rebased'
      ].contains(data['stage'])) {
    throw StateError('迁移日志路径或阶段无效，已保留两边资料');
  }
  void stage(String value) {
    data['stage'] = value;
    _saveRootJournal(journal, data);
    afterStage?.call(value);
  }

  if (data['stage'] == 'preparing') {
    data['snapshot'] = await PixivLibrary.snapshotOf(from);
    stage('copy');
  }
  final snapshot = Map<String, dynamic>.from(data['snapshot'] as Map);
  if (data['stage'] == 'copy') {
    if (!await PixivLibrary.matchesSnapshot(to, snapshot)) {
      if (Directory(to).existsSync() && Directory(to).listSync().isNotEmpty) {
        throw StateError('迁移目标内容冲突');
      }
      await PixivLibrary.copySnapshot(from, temp, snapshot);
      if (!await PixivLibrary.matchesSnapshot(temp, snapshot)) {
        throw StateError('下载根副本校验失败');
      }
      if (Directory(to).existsSync()) await Directory(to).delete();
      await retryWindowsRename(() => Directory(temp).rename(to));
    }
    stage('published');
  }
  if (data['stage'] == 'published') {
    if (!await PixivLibrary.matchesSnapshot(from, snapshot) ||
        !await PixivLibrary.matchesSnapshot(to, snapshot)) {
      throw StateError('根内容发生变化，保留两边资料');
    }
    final locations = _read();
    final redirects = Map<String, dynamic>.from(locations['redirects'] as Map);
    redirects.remove(to);
    redirects[from] = to;
    locations['redirects'] = redirects;
    locations['roots'] = {
      ...List<String>.from(locations['roots'] as List)
          .where((r) => !p.equals(r, from)),
      to,
    }.toList();
    _save(locations);
    LocalTrashStore.instance.relocatePaths(from, to);
    stage('cleaning');
  }
  if (data['stage'] == 'cleaning') {
    // Required on every resume, including when source cleanup was interrupted.
    if (!await PixivLibrary.matchesSnapshot(to, snapshot)) {
      throw StateError('迁移目标已变化或缺失，停止清理并保留源资料');
    }
    await PixivLibrary.removeSnapshot(from, snapshot);
    stage('cleaned');
  }
  if (data['stage'] == 'cleaned') {
    final target = PixivLibrary(to);
    if (!target.registered ||
        (data['libraryId'] != null &&
            target.folder('root').libraryId != data['libraryId'])) {
      throw StateError('目标下载库身份失效，保留迁移日志');
    }
    // Rewriting journal paths changes DB bytes. Source cleanup must never run
    // again after this point, even if the process stops before journal removal.
    target.relocateJournalPaths(from, to);
    stage('rebased');
  }
  if (data['stage'] == 'rebased') journal.deleteSync();
}

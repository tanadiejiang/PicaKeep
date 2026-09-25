import 'dart:io';

import 'package:path/path.dart' as p;

/// 下载目录迁移里使用的数据库文件名。
const String kDownloadDatabaseFileName = 'download.db';

/// 复制过程中的暂存后缀。
///
/// **这是防数据丢失的关键**：复制一个目录时先写到 `<名字><后缀>`，整份复制完了
/// 才改成正式名字。于是目标目录里只要出现正式名字，就一定是一份**完整副本**，
/// 后面"目标已存在 → 跳过并清理源"才是安全的。
///
/// 少了这层保护，一次中断留下的半成品目录会在下次迁移时被当成"已经搬好了"，
/// 进而把唯一的完整副本（旧目录里那份）删掉 —— 那就是真的丢数据。
const String kDownloadMigrationPartialSuffix = '.__picakeep_partial__';

/// 迁移当前所处的阶段。
enum DownloadMigrationPhase {
  /// 默认模式的第一阶段：把内容复制到新目录，**旧目录一个条目都不删**。
  copying,

  /// 默认模式的第二阶段：复制已全部成功，回头清理旧目录。
  cleaningUp,

  /// 存储紧张模式：搬一本删一本，峰值占用最小。
  moving,
}

/// 迁移过程中的进度快照。
class DownloadMigrationProgress {
  const DownloadMigrationProgress({
    required this.completed,
    required this.total,
    required this.currentEntry,
    this.phase = DownloadMigrationPhase.moving,
  });

  /// 当前阶段内已处理的条目数（含跳过与失败的）。
  final int completed;

  /// 当前阶段内待处理的条目总数。
  final int total;

  /// 正在处理的条目名，用于进度文案。
  final String currentEntry;

  final DownloadMigrationPhase phase;

  /// 0..1 的整体完成比例。
  ///
  /// 默认模式把 90% 的进度给"复制"、10% 给"清理"，这样进度条**单调递增**，
  /// 不会在阶段切换时从 100% 掉回 0%。
  double get fraction {
    if (total <= 0) {
      return 1;
    }
    final local = (completed / total).clamp(0.0, 1.0);
    return switch (phase) {
      DownloadMigrationPhase.copying => local * 0.9,
      DownloadMigrationPhase.cleaningUp => 0.9 + local * 0.1,
      DownloadMigrationPhase.moving => local,
    };
  }
}

/// 一次迁移的结果。
class DownloadMigrationResult {
  const DownloadMigrationResult({
    required this.movedEntries,
    required this.skippedEntries,
    required this.failures,
    required this.stopped,
  });

  /// 本次真正搬过去的条目数。
  final int movedEntries;

  /// 目标目录里已存在、因而跳过的条目数（续传时大量出现）。
  final int skippedEntries;

  /// 失败条目的描述，形如 `目录名: 原因`。
  final List<String> failures;

  /// 是否因 [migrateDownloadEntries] 的 `shouldStop` 返回 true 而提前结束。
  final bool stopped;

  bool get hasFailures => failures.isNotEmpty;
}

/// 把 [from] 里的 `download.db` **复制**到 [to]，源文件保留。
///
/// 这是迁移的第一步，也是"先切路径、再搬数据"能成立的前提：
/// 新目录拿到一份完整的记录后立刻可用，之后即使搬漫画失败或被中断，
/// 也只是一部分漫画还没到位，**记录不会丢**。
/// 源库刻意不删，直到用户确认整批数据都在新目录里。
Future<bool> seedDownloadDatabase({
  required String from,
  required String to,
}) async {
  final sourcePath = _normalize(from);
  final targetPath = _normalize(to);
  if (sourcePath.isEmpty || targetPath.isEmpty || sourcePath == targetPath) {
    return false;
  }
  final sourceDb = File(p.join(sourcePath, kDownloadDatabaseFileName));
  if (!await sourceDb.exists()) {
    return false;
  }
  final target = Directory(targetPath);
  if (!await target.exists()) {
    await target.create(recursive: true);
  }
  await sourceDb.copy(p.join(targetPath, kDownloadDatabaseFileName));
  return true;
}

/// 把 [from] 中**除 `download.db` 以外**的条目搬到 [to]。
///
/// 两种模式，由 [deleteSourceAsWeGo] 决定：
///
/// - **false（默认，稳妥）**：先把全部条目**复制**到新目录，旧目录一个都不删；
///   只有全部复制成功，才回头清理旧目录。代价是峰值占用约为两倍。
/// - **true（存储紧张）**：搬一本删一本（同文件系统内直接 rename），
///   峰值占用只比原来多一本；代价是源目录在过程中逐步消失。
///
/// 两种模式都可随时重入，这是"继续迁移"的基础：目标已存在同名条目的直接跳过。
/// [onProgress] 每条目回调一次；[shouldStop] 返回 true 时在条目边界停下，
/// 已完成的成果全部保留。
Future<DownloadMigrationResult> migrateDownloadEntries({
  required String from,
  required String to,
  bool deleteSourceAsWeGo = false,
  void Function(DownloadMigrationProgress progress)? onProgress,
  bool Function()? shouldStop,
}) async {
  final sourcePath = _normalize(from);
  final targetPath = _normalize(to);
  if (sourcePath.isEmpty || targetPath.isEmpty) {
    throw const DownloadMigrationException('源目录或目标目录为空');
  }
  if (sourcePath == targetPath) {
    return const DownloadMigrationResult(
      movedEntries: 0,
      skippedEntries: 0,
      failures: <String>[],
      stopped: false,
    );
  }
  if (_isInside(sourcePath, targetPath) || _isInside(targetPath, sourcePath)) {
    throw const DownloadMigrationException('目标目录不能位于源目录内部（或相反）');
  }

  final source = Directory(sourcePath);
  if (!await source.exists()) {
    return const DownloadMigrationResult(
      movedEntries: 0,
      skippedEntries: 0,
      failures: <String>[],
      stopped: false,
    );
  }
  final target = Directory(targetPath);
  if (!await target.exists()) {
    await target.create(recursive: true);
  }
  // 上次中断可能留下不完整的暂存条目，先清掉，免得后续判断被它干扰。
  await _cleanupPartialArtifacts(targetPath);

  final List<FileSystemEntity> entries;
  try {
    entries = (await source.list(followLinks: false).toList())
        .where((e) => p.basename(e.path) != kDownloadDatabaseFileName)
        .toList();
  } catch (e) {
    throw DownloadMigrationException('无法读取源目录：${_describe(e)}');
  }

  if (deleteSourceAsWeGo) {
    return _moveEntryByEntry(
      entries: entries,
      targetPath: targetPath,
      onProgress: onProgress,
      shouldStop: shouldStop,
    );
  }
  return _copyThenCleanUp(
    entries: entries,
    targetPath: targetPath,
    onProgress: onProgress,
    shouldStop: shouldStop,
  );
}

/// 存储紧张模式：搬一本删一本。
Future<DownloadMigrationResult> _moveEntryByEntry({
  required List<FileSystemEntity> entries,
  required String targetPath,
  void Function(DownloadMigrationProgress progress)? onProgress,
  bool Function()? shouldStop,
}) async {
  var moved = 0;
  var skipped = 0;
  final failures = <String>[];
  var stopped = false;

  for (var i = 0; i < entries.length; i++) {
    if (shouldStop?.call() ?? false) {
      stopped = true;
      break;
    }
    final entry = entries[i];
    final name = p.basename(entry.path);
    final destinationPath = p.join(targetPath, name);
    if (await _exists(destinationPath)) {
      // 续传时的主要路径：上次已经搬过去了。源里这份多余的副本也顺手清掉。
      skipped++;
      try {
        await entry.delete(recursive: true);
      } catch (_) {}
    } else {
      try {
        await _moveEntity(entry, destinationPath);
        moved++;
      } catch (e) {
        // 单个条目失败不终止整批：把失败记下来继续搬其余的，
        // 用户之后可以再点一次"继续迁移"重试这些条目。
        failures.add('$name: ${_describe(e)}');
      }
    }
    onProgress?.call(
      DownloadMigrationProgress(
        completed: i + 1,
        total: entries.length,
        currentEntry: name,
        phase: DownloadMigrationPhase.moving,
      ),
    );
  }

  return DownloadMigrationResult(
    movedEntries: moved,
    skippedEntries: skipped,
    failures: failures,
    stopped: stopped,
  );
}

/// 默认模式：先全部复制（不删源），全部成功后才清理旧目录。
///
/// **只要复制阶段有任何失败或没做完，就一个源条目都不删** ——
/// 这是这个模式存在的意义：最坏情况只是"新目录多了一份副本"，
/// 而不是"旧的那份没了、新的那份还不全"。
Future<DownloadMigrationResult> _copyThenCleanUp({
  required List<FileSystemEntity> entries,
  required String targetPath,
  void Function(DownloadMigrationProgress progress)? onProgress,
  bool Function()? shouldStop,
}) async {
  var copied = 0;
  var skipped = 0;
  final failures = <String>[];
  var stopped = false;
  // 已经在新目录里就位的条目，复制阶段全部成功后回头清理这些源。
  final readyToClean = <FileSystemEntity>[];

  for (var i = 0; i < entries.length; i++) {
    if (shouldStop?.call() ?? false) {
      stopped = true;
      break;
    }
    final entry = entries[i];
    final name = p.basename(entry.path);
    final destinationPath = p.join(targetPath, name);
    if (await _exists(destinationPath)) {
      skipped++;
      readyToClean.add(entry);
    } else {
      try {
        await _copyEntity(entry, destinationPath);
        copied++;
        readyToClean.add(entry);
      } catch (e) {
        failures.add('$name: ${_describe(e)}');
      }
    }
    onProgress?.call(
      DownloadMigrationProgress(
        completed: i + 1,
        total: entries.length,
        currentEntry: name,
        phase: DownloadMigrationPhase.copying,
      ),
    );
  }

  if (stopped || failures.isNotEmpty) {
    // 没复制完或有失败：保留全部源文件，等用户重试。
    return DownloadMigrationResult(
      movedEntries: copied,
      skippedEntries: skipped,
      failures: failures,
      stopped: stopped,
    );
  }

  for (var i = 0; i < readyToClean.length; i++) {
    if (shouldStop?.call() ?? false) {
      stopped = true;
      break;
    }
    final entry = readyToClean[i];
    final name = p.basename(entry.path);
    try {
      // 只删到这一层为止：内容已经在新目录里了。
      await entry.delete(recursive: true);
    } catch (e) {
      // 删不掉只是留下冗余副本，数据仍然安全。
      failures.add('$name: ${_describe(e)}');
    }
    onProgress?.call(
      DownloadMigrationProgress(
        completed: i + 1,
        total: readyToClean.length,
        currentEntry: name,
        phase: DownloadMigrationPhase.cleaningUp,
      ),
    );
  }

  return DownloadMigrationResult(
    movedEntries: copied,
    skippedEntries: skipped,
    failures: failures,
    stopped: stopped,
  );
}

/// 把 [from] 下的全部顶层条目**复制**到 [to]，**源一个都不删**。
///
/// ## 与 [migrateDownloadEntries] 的区别（很重要）
///
/// 那个是"搬"：复制成功后**会清理源**。这个只复制。用在「原应用下载目录」
/// 选了"复制到本应用"的场景 —— 用户想摆脱对原目录与权限的依赖，
/// 但**原应用的数据必须原封不动**，所以这里绝不删除任何源文件。
///
/// 与迁移一样按条目粒度处理并回调进度，重复执行是安全的：
/// 目标已存在同名条目就跳过，不会重复复制，也不会覆盖。
///
/// `download.db` **会**被一起复制：只看漫画文件的话，本应用并不认识这些
/// 目录（记录在库里），复制过来也读不出来。
Future<DownloadMigrationResult> copyDirectoryContents({
  required String from,
  required String to,
  void Function(DownloadMigrationProgress progress)? onProgress,
  bool Function()? shouldStop,
}) async {
  final sourcePath = _normalize(from);
  final targetPath = _normalize(to);
  if (sourcePath.isEmpty || targetPath.isEmpty) {
    throw const DownloadMigrationException('源目录或目标目录为空');
  }
  if (sourcePath == targetPath) {
    return const DownloadMigrationResult(
      movedEntries: 0,
      skippedEntries: 0,
      failures: <String>[],
      stopped: false,
    );
  }
  if (_isInside(sourcePath, targetPath) || _isInside(targetPath, sourcePath)) {
    throw const DownloadMigrationException('目标目录不能位于源目录内部（或相反）');
  }

  final source = Directory(sourcePath);
  if (!await source.exists()) {
    return const DownloadMigrationResult(
      movedEntries: 0,
      skippedEntries: 0,
      failures: <String>[],
      stopped: false,
    );
  }
  final target = Directory(targetPath);
  if (!await target.exists()) {
    await target.create(recursive: true);
  }
  await _cleanupPartialArtifacts(targetPath);

  final List<FileSystemEntity> entries;
  try {
    entries = await source.list(followLinks: false).toList();
  } catch (e) {
    throw DownloadMigrationException('无法读取源目录：${_describe(e)}');
  }

  var copied = 0;
  var skipped = 0;
  final failures = <String>[];
  var stopped = false;

  for (var i = 0; i < entries.length; i++) {
    if (shouldStop?.call() ?? false) {
      stopped = true;
      break;
    }
    final entry = entries[i];
    final name = p.basename(entry.path);
    final destinationPath = p.join(targetPath, name);
    if (await _exists(destinationPath)) {
      // 已经复制过就跳过：重复执行不会重复占用空间，也不会覆盖用户改过的内容。
      skipped++;
    } else {
      try {
        await _copyEntity(entry, destinationPath);
        copied++;
      } catch (e) {
        failures.add('$name: ${_describe(e)}');
      }
    }
    onProgress?.call(
      DownloadMigrationProgress(
        completed: i + 1,
        total: entries.length,
        currentEntry: name,
        phase: DownloadMigrationPhase.copying,
      ),
    );
  }

  return DownloadMigrationResult(
    movedEntries: copied,
    skippedEntries: skipped,
    failures: failures,
    stopped: stopped,
  );
}

/// 下载目录迁移失败（参数非法等，条目级失败走 [DownloadMigrationResult.failures]）。
class DownloadMigrationException implements Exception {
  const DownloadMigrationException(this.message,
      {this.rollbackFailures = const <String>[]});

  final String message;

  /// 保留字段：当前实现不做回滚（失败条目留在原处更利于续传），
  /// 恒为空列表，仅为兼容既有调用方的展示逻辑。
  final List<String> rollbackFailures;

  @override
  String toString() => message;
}

/// [from] 中是否还有待迁移的漫画条目（忽略 `download.db`）。
///
/// "还有没有活要干"的唯一判据，比持久化"已迁移清单"更可靠：
/// 文件系统的实际状态就是唯一真相，应用被杀掉重启后依然成立。
Future<bool> hasPendingDownloadEntries(String from) async {
  final sourcePath = _normalize(from);
  if (sourcePath.isEmpty) {
    return false;
  }
  final source = Directory(sourcePath);
  try {
    if (!await source.exists()) {
      return false;
    }
    await for (final entity in source.list(followLinks: false)) {
      if (p.basename(entity.path) == kDownloadDatabaseFileName) {
        continue;
      }
      return true;
    }
    return false;
  } catch (_) {
    return false;
  }
}

/// [from] 下是否有任何可迁移的内容（含 `download.db`）。
///
/// 刻意把 db 也算作内容：只要旧目录里还留着库，就说明这里曾是下载目录，
/// 换目录时值得提示一次。
Future<bool> hasMigratableDownloadContent(String from) async {
  final sourcePath = _normalize(from);
  if (sourcePath.isEmpty) {
    return false;
  }
  final source = Directory(sourcePath);
  try {
    if (!await source.exists()) {
      return false;
    }
    return !await source.list(followLinks: false).isEmpty;
  } catch (_) {
    // 读不到就当作"没有"，避免用无法确认的信息去打扰用户。
    return false;
  }
}

Future<void> _moveEntity(
    FileSystemEntity entity, String destinationPath) async {
  try {
    await entity.rename(destinationPath);
    return;
  } on FileSystemException {
    // 跨文件系统无法 rename（EXDEV），回退到复制 + 删源。
  }
  await _copyEntity(entity, destinationPath);
  await entity.delete(recursive: true);
}

/// 只复制，不碰源文件。
///
/// 先复制到暂存名、完整后再改成正式名，保证目标里的正式名条目永远是完整副本。
Future<void> _copyEntity(
  FileSystemEntity entity,
  String destinationPath,
) async {
  final stagingPath = '$destinationPath$kDownloadMigrationPartialSuffix';
  final leftover = await _entityAt(stagingPath);
  if (leftover != null) {
    await leftover.delete(recursive: true);
  }
  await _copyEntityRaw(entity, stagingPath);
  await _renameTo(stagingPath, destinationPath);
}

Future<void> _copyEntityRaw(
  FileSystemEntity entity,
  String destinationPath,
) async {
  if (entity is Directory) {
    await _copyDirectory(entity, Directory(destinationPath));
  } else if (entity is File) {
    await entity.copy(destinationPath);
  } else {
    // 未知类型（软链接、socket 等）不做静默跳过：跳过等于悄悄丢数据。
    throw FileSystemException('不支持的条目类型，无法迁移', entity.path);
  }
}

Future<void> _renameTo(String fromPath, String toPath) async {
  final type = await FileSystemEntity.type(fromPath, followLinks: false);
  if (type == FileSystemEntityType.directory) {
    await Directory(fromPath).rename(toPath);
  } else {
    await File(fromPath).rename(toPath);
  }
}

/// 清掉上次中断留下的暂存条目：它们不是完整副本，重来一遍即可。
Future<void> _cleanupPartialArtifacts(String targetPath) async {
  final target = Directory(targetPath);
  if (!await target.exists()) {
    return;
  }
  try {
    await for (final entity in target.list(followLinks: false)) {
      if (!p.basename(entity.path).endsWith(kDownloadMigrationPartialSuffix)) {
        continue;
      }
      try {
        await entity.delete(recursive: true);
      } catch (_) {
        // 删不掉就留着，不影响正确性（下次复制同名条目时还会再试一次）。
      }
    }
  } catch (_) {}
}

Future<void> _copyDirectory(Directory source, Directory target) async {
  await target.create(recursive: true);
  await for (final entity in source.list(followLinks: false)) {
    final name = p.basename(entity.path);
    final destinationPath = p.join(target.path, name);
    if (entity is Directory) {
      await _copyDirectory(entity, Directory(destinationPath));
    } else if (entity is File) {
      await entity.copy(destinationPath);
    } else {
      throw FileSystemException('不支持的条目类型，无法迁移', entity.path);
    }
  }
}

Future<bool> _exists(String path) async {
  final type = await FileSystemEntity.type(path, followLinks: false);
  return type != FileSystemEntityType.notFound;
}

Future<FileSystemEntity?> _entityAt(String path) async {
  final type = await FileSystemEntity.type(path, followLinks: false);
  return switch (type) {
    FileSystemEntityType.directory => Directory(path),
    FileSystemEntityType.file => File(path),
    FileSystemEntityType.link => Link(path),
    _ => null,
  };
}

/// 去掉尾部斜杠（根目录除外），便于比较与拼接。
String _normalize(String path) {
  var normalized = path.trim().replaceAll('\\', '/');
  while (normalized.length > 1 && normalized.endsWith('/')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return normalized;
}

/// [child] 是否位于 [parent] 内部（不含自身）。
bool _isInside(String child, String parent) {
  if (parent == '/') {
    return child != '/';
  }
  return child.startsWith('$parent/');
}

String _describe(Object error) {
  if (error is FileSystemException) {
    final message = error.message.trim();
    final path = error.path?.trim() ?? '';
    if (path.isEmpty) {
      return message;
    }
    return '$message ($path)';
  }
  return error.toString();
}

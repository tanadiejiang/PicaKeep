part of 'trash.dart';

extension TrashManagerIo on TrashManager {
  String _generateRecordId() =>
      'trash_${DateTime.now().microsecondsSinceEpoch}_${_items.length}';

  Future<void> _moveDirectory(Directory source, Directory target) async {
    target.parent.createSync(recursive: true);
    try {
      await source.rename(target.path);
      return;
    } catch (_) {}
    await _copyDirectory(source, target);
    if (source.existsSync()) {
      await source.delete(recursive: true);
    }
  }

  Future<void> _copyDirectory(Directory source, Directory destination) async {
    destination.createSync(recursive: true);
    await for (final entity in source.list(recursive: false)) {
      if (entity is Directory) {
        await _copyDirectory(
          entity,
          Directory(_joinTrashPath(
              destination.path, _basenameTrashPath(entity.path))),
        );
      } else if (entity is File) {
        await entity.copy(
            _joinTrashPath(destination.path, _basenameTrashPath(entity.path)));
      }
    }
  }

  _LocalPathState _localPathState(Directory dir) {
    try {
      return dir.existsSync()
          ? _LocalPathState.exists
          : _LocalPathState.missing;
    } on FileSystemException catch (e) {
      if (_isPermissionDenied(e)) {
        return _LocalPathState.permissionDenied;
      }
      return _LocalPathState.missing;
    }
  }

  Future<_LocalPathState> _resolveLocalPathState(Directory dir) async {
    final localState = _localPathState(dir);
    final shouldCheckPrivileged = App.isAndroid &&
        (localState == _LocalPathState.permissionDenied ||
            _shouldForcePrivilegedIo(dir.path));
    if (!shouldCheckPrivileged) {
      return localState;
    }
    final mode = await _resolvePrivilegedWriteModeForOperation();
    if (mode == null) {
      return _LocalPathState.permissionDenied;
    }
    final exists = await _privilegedPathExists(dir.path, mode: mode);
    return exists ? _LocalPathState.exists : _LocalPathState.missing;
  }

  bool _isPermissionDenied(FileSystemException e) {
    final message = e.message.toLowerCase();
    final osMessage = e.osError?.message.toLowerCase() ?? '';
    return e.osError?.errorCode == 13 ||
        message.contains('permission denied') ||
        osMessage.contains('permission denied');
  }
}

part of 'download_page.dart';

extension DownloadPageLogicActions on DownloadPageLogic {
  bool get isDeleteOperationRunning => _isDeletingItems;

  int get deleteProgressCurrent => _deleteProgressCurrent;

  int get deleteProgressTotal => _deleteProgressTotal;

  String get deleteProgressActionLabel {
    if (_deleteProgressActionLabel.isNotEmpty) {
      return _deleteProgressActionLabel;
    }
    return TrashManager.instance.useTrashByDefault ? '正在放进回收站' : '正在删除';
  }

  String get deleteProgressHint => '请不要退出，强制退出可能导致操作异常';

  bool canDeleteItem(DownloadedItem item) {
    if (item is RemoteLibraryRootItem) {
      return false;
    }
    if (item is RemoteLibraryComicItem) {
      return true;
    }
    if (item is LocalLibraryComicItem) {
      return (item.fileSystemPath?.trim().isNotEmpty ?? false);
    }
    return item.canDelete && !_usesManagedDownloadSources;
  }

  String _deleteErrorText(String error) {
    return deleteFailureMessage(error).tl;
  }

  String _deleteErrorTextFromException(Object error) {
    final message = error.toString();
    if (message.contains(deleteFailurePermissionDenied) ||
        message.toLowerCase().contains('permission denied')) {
      return _deleteErrorText(deleteFailurePermissionDenied);
    }
    return message;
  }

  Future<String?> deleteItems(Iterable<DownloadedItem> items) async {
    if (_isDeletingItems) {
      return null;
    }
    final targets = items.where(canDeleteItem).toList(growable: false);
    if (targets.isEmpty) {
      return null;
    }
    _isDeletingItems = true;
    _deleteProgressCurrent = 0;
    _deleteProgressTotal = targets.length;
    _deleteProgressActionLabel =
        TrashManager.instance.useTrashByDefault ? '正在放进回收站' : '正在删除';
    App.beginNavigationLock();
    App.temporaryDisablePopGesture = true;
    update();
    String? errorText;
    try {
      for (int i = 0; i < targets.length; i++) {
        _deleteProgressCurrent = i + 1;
        update();
        final item = targets[i];
        final result = await TrashManager.instance.deleteItem(item);
        if (!result.ok) {
          errorText = _deleteErrorText(result.error ?? 'delete_failed');
          break;
        }
      }
    } catch (e) {
      errorText = _deleteErrorTextFromException(e);
    } finally {
      try {
        await reload();
      } catch (e) {
        print('[PicaKeep] DownloadPage reload after delete failed: $e');
      }
      _isDeletingItems = false;
      _deleteProgressCurrent = 0;
      _deleteProgressTotal = 0;
      _deleteProgressActionLabel = '';
      App.temporaryDisablePopGesture = false;
      App.endNavigationLock();
      update();
    }
    return errorText;
  }

  Future<int> rescanDisk() async {
    if (_view == _DownloadedLibraryView.remote) {
      await reload();
      return 0;
    }
    if (!_usesManagedDownloadSources) {
      final localLibraryManager = LocalLibraryManager();
      if (await localLibraryManager
          .shouldBypassDirectDownloadManagerForCurrentDownloads()) {
        final count = await localLibraryManager
            .refreshCurrentDownloadsWithShizukuFallback();
        await reload();
        return count;
      }
      await DownloadManager().init();
      final count = DownloadManager().scanDirectoryForComics();
      await reload();
      return count;
    }
    final localLibraryManager = LocalLibraryManager();
    final count = await (() async {
      if (await localLibraryManager
          .shouldUsePrivilegedManagedDownloadHandling()) {
        await localLibraryManager.refresh();
        return (await localLibraryManager.getManagedDownloads()).length;
      }
      return localLibraryManager.rescan();
    })();
    await reload();
    return count;
  }

  void resetSelected(int length) {
    selected = List.generate(length, (index) => false);
    selectedNum = 0;
  }
}

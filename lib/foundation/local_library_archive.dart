part of 'local_library.dart';

extension LocalLibraryArchive on LocalLibraryManager {
  String _collectionShellEpisodeTitle(String formalTitle, String chapterTitle) {
    final normalizedFormal = formalTitle.trim();
    final normalizedChapter = chapterTitle.trim();
    if (normalizedFormal.isEmpty) {
      return normalizedChapter;
    }
    if (normalizedChapter.isEmpty || normalizedChapter == normalizedFormal) {
      return normalizedFormal;
    }
    final numeric = int.tryParse(normalizedChapter);
    if (numeric != null) {
      return '$normalizedFormal 第$numeric话';
    }
    return normalizedChapter;
  }

  String _stripCollectionShellParentPrefix(String shellTitle, String title) {
    final normalizedShell = shellTitle.trim();
    final normalizedTitle = title.trim();
    if (normalizedShell.isEmpty ||
        !normalizedTitle.startsWith(normalizedShell)) {
      return title;
    }
    final rest = normalizedTitle.substring(normalizedShell.length).trimLeft();
    final cleaned =
        rest.replaceFirst(RegExp(r'^[\s/_\\\-—:：]+'), '').trimLeft();
    return cleaned.isEmpty ? title : cleaned;
  }

  Future<String?> _pickCollectionShellCoverPath(
    String shellPath,
    List<_LocalDirectoryEntry> formalEntries,
    List<String> orderedImages,
  ) async {
    final shellCover = await _resolveNamedCoverPath(shellPath);
    if (shellCover != null) {
      return shellCover;
    }
    for (final formalEntry in formalEntries) {
      final formalCover = await _resolveNamedCoverPath(formalEntry.path);
      if (formalCover != null) {
        return formalCover;
      }
    }
    if (orderedImages.isNotEmpty) {
      return orderedImages.first;
    }
    return null;
  }

  Future<void> refreshArchiveCoverFor(LocalLibraryComicItem item) async {
    if (!item.isArchiveItem) return;
    final archivePath = item.fileSystemPath ?? '';
    if (archivePath.isEmpty) return;
    try {
      final index = await ArchiveReadingService.instance
          .getIndex(archivePath, forceRefresh: true);
      final coverEntry = pickArchiveCoverEntry(index);
      if (coverEntry != null) {
        final newCoverPath = await ArchiveReadingService.instance
            .extractCoverToCache(archivePath, coverEntry);
        if (newCoverPath != null && newCoverPath.isNotEmpty) {
          item._localCoverPath = newCoverPath;
        }
      }
    } catch (_) {}
  }

  Future<void> _autoUnlockEncryptedArchives() async {
    final store = ArchivePasswordStore.instance;
    if (!store.autoUnlockEnabled) return;
    final passwords = store.defaultPasswords;
    if (passwords.isEmpty) return;

    final encryptedItems = _items
        .where((item) =>
            item.isArchiveItem &&
            item.archiveEncrypted &&
            !item.archivePasswordMatched &&
            !store.isBlacklisted(item.fileSystemPath ?? ''))
        .toList();
    if (encryptedItems.isEmpty) return;

    final semaphore = _Semaphore(2);
    final futures = encryptedItems.map((item) async {
      await semaphore.acquire();
      try {
        final archivePath = item.fileSystemPath ?? '';
        if (archivePath.isEmpty) return;
        for (final password in passwords) {
          final ok = await ArchiveReadingService.instance
              .tryUnlock(archivePath, password);
          if (ok) {
            item.markArchiveUnlocked(password);
            await refreshArchiveCoverFor(item);
            break;
          }
        }
      } catch (_) {
      } finally {
        semaphore.release();
      }
    });
    await Future.wait(futures);
  }
}

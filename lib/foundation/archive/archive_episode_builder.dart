import 'archive_models.dart';

class ArchiveEpisodesBuildResult {
  const ArchiveEpisodesBuildResult({
    required this.episodeFiles,
    required this.realNames,
  });

  final Map<int, List<String>> episodeFiles;
  final List<String> realNames;
}

ArchiveEpisodesBuildResult buildArchiveEpisodes(ArchiveIndex index) {
  final imageEntries = index.imageEntries;
  if (imageEntries.isEmpty) {
    return const ArchiveEpisodesBuildResult(
      episodeFiles: <int, List<String>>{},
      realNames: <String>[],
    );
  }

  final prefix = _longestCommonDirectoryPrefix(
    imageEntries.map((entry) => entry.path).toList(growable: false),
  );

  final groups = <String, List<String>>{};
  for (final entry in imageEntries) {
    final stripped =
        prefix.isEmpty ? entry.path : entry.path.substring(prefix.length);
    final slashIndex = stripped.indexOf('/');
    final parent = slashIndex > 0 ? stripped.substring(0, slashIndex) : '';
    groups.putIfAbsent(parent, () => <String>[]).add(
          buildArchiveUri(index.archivePath, entry.path).toString(),
        );
  }

  if (groups.length == 1) {
    final uris = groups.values.first;
    uris.sort(_archiveUriNaturalCompare);
    return ArchiveEpisodesBuildResult(
      episodeFiles: <int, List<String>>{0: uris},
      realNames: <String>[groups.keys.first],
    );
  }

  final result = <int, List<String>>{};
  final realNames = <String>[];
  final rootUris = groups[''] ?? <String>[];
  if (rootUris.isNotEmpty) {
    rootUris.sort(_archiveUriNaturalCompare);
    result[0] = rootUris;
    realNames.add('');
  }

  final subdirs = groups.keys.where((key) => key.isNotEmpty).toList()
    ..sort(_naturalCompare);
  for (var i = 0; i < subdirs.length; i++) {
    final uris = groups[subdirs[i]]!;
    uris.sort(_archiveUriNaturalCompare);
    result[i + 1] = uris;
    realNames.add(subdirs[i]);
  }

  return ArchiveEpisodesBuildResult(
    episodeFiles: result,
    realNames: realNames,
  );
}

String? pickArchiveCoverEntry(ArchiveIndex index) {
  if (index.imageEntries.isEmpty) {
    return null;
  }
  const coverNames = <String>[
    'cover.jpg',
    'cover.jpeg',
    'cover.png',
    'cover.webp',
  ];
  for (final candidate in coverNames) {
    for (final entry in index.imageEntries) {
      final basename = entry.path.split('/').last.toLowerCase();
      if (basename == candidate) {
        return entry.path;
      }
    }
  }

  final episodes = buildArchiveEpisodes(index).episodeFiles;
  if (episodes.isEmpty) {
    return null;
  }
  final keys = episodes.keys.toList()..sort();
  for (final key in keys) {
    final entries = episodes[key];
    if (entries == null || entries.isEmpty) {
      continue;
    }
    final parsed = parseArchiveUri(entries.first);
    if (parsed != null) {
      return parsed.entryPath;
    }
  }
  return null;
}

String _longestCommonDirectoryPrefix(List<String> paths) {
  if (paths.isEmpty) {
    return '';
  }
  final parts = paths.first.split('/');
  final prefixParts = <String>[];
  for (var depth = 0; depth < parts.length - 1; depth++) {
    final candidate = parts[depth];
    if (paths.every((path) {
      final split = path.split('/');
      return split.length > depth && split[depth] == candidate;
    })) {
      prefixParts.add(candidate);
      continue;
    }
    break;
  }
  return prefixParts.isEmpty ? '' : '${prefixParts.join('/')}/';
}

int _archiveUriNaturalCompare(String left, String right) {
  final parsedLeft = parseArchiveUri(left);
  final parsedRight = parseArchiveUri(right);
  if (parsedLeft == null || parsedRight == null) {
    return left.compareTo(right);
  }
  return _naturalCompare(parsedLeft.entryPath, parsedRight.entryPath);
}

int _naturalCompare(String left, String right) {
  final a = _splitNatural(left.toLowerCase());
  final b = _splitNatural(right.toLowerCase());
  final length = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < length; i++) {
    final leftToken = a[i];
    final rightToken = b[i];
    final leftNumber = int.tryParse(leftToken);
    final rightNumber = int.tryParse(rightToken);
    if (leftNumber != null && rightNumber != null) {
      final diff = leftNumber.compareTo(rightNumber);
      if (diff != 0) {
        return diff;
      }
      continue;
    }
    final diff = leftToken.compareTo(rightToken);
    if (diff != 0) {
      return diff;
    }
  }
  return a.length.compareTo(b.length);
}

List<String> _splitNatural(String value) {
  return RegExp(r'\d+|\D+')
      .allMatches(value)
      .map((match) => match.group(0)!)
      .toList(growable: false);
}

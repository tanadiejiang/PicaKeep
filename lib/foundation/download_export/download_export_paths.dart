class DownloadExportPathTools {
  const DownloadExportPathTools._();

  static String sanitizeSegment(String value, {String fallback = '未命名'}) {
    var normalized = value.trim();
    normalized =
        normalized.replaceAll(RegExp(r'[<>:"/\\|?*\u0000-\u001F]'), '_');
    normalized = normalized.replaceAll(RegExp(r'[\u007F]'), '_');
    normalized = normalized.replaceFirst(RegExp(r'^\.+$'), '_');
    normalized = normalized.replaceFirst(RegExp(r'[ .]+$'), '_');
    if (normalized.isEmpty) {
      normalized = fallback;
    }
    if (RegExp(
      r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$',
      caseSensitive: false,
    ).hasMatch(normalized)) {
      normalized = '_$normalized';
    }
    return normalized;
  }

  static String sanitizeRelativePath(String value) {
    final segments = value
        .replaceAll('\\', '/')
        .split('/')
        .where((segment) => segment.trim().isNotEmpty)
        .map((segment) => sanitizeSegment(segment))
        .toList(growable: false);
    return segments.join('/');
  }

  static String uniqueName(String value, Set<String> used) {
    final base = sanitizeSegment(value);
    var candidate = base;
    var suffix = 2;
    while (_containsIgnoreCase(used, candidate)) {
      candidate = '$base ($suffix)';
      suffix++;
    }
    used.add(candidate);
    return candidate;
  }

  static String uniqueRelativePath(String value, Set<String> used) {
    final normalized = sanitizeRelativePath(value);
    final parts = normalized.split('/');
    final file = parts.removeLast();
    final directory = parts.isEmpty ? '' : '${parts.join('/')}/';
    final stem = _fileStem(file);
    final extension = _fileExtension(file);
    var candidate = normalized;
    var suffix = 2;
    while (_containsIgnoreCase(used, candidate)) {
      candidate = '$directory$stem ($suffix)$extension';
      suffix++;
    }
    used.add(candidate);
    return candidate;
  }

  static int naturalCompare(String left, String right) {
    final a = _naturalParts(left.toLowerCase());
    final b = _naturalParts(right.toLowerCase());
    final length = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < length; i++) {
      final leftPart = a[i];
      final rightPart = b[i];
      final leftNumber = int.tryParse(leftPart);
      final rightNumber = int.tryParse(rightPart);
      if (leftNumber != null && rightNumber != null) {
        final numberCompare = leftNumber.compareTo(rightNumber);
        if (numberCompare != 0) return numberCompare;
        continue;
      }
      final textCompare = leftPart.compareTo(rightPart);
      if (textCompare != 0) return textCompare;
    }
    return a.length.compareTo(b.length);
  }

  static List<String> sortedNaturally(Iterable<String> values) {
    return values.toList()..sort(naturalCompare);
  }

  static bool _containsIgnoreCase(Set<String> values, String candidate) {
    final lower = candidate.toLowerCase();
    return values.any((value) => value.toLowerCase() == lower);
  }

  static String _fileStem(String value) {
    final dot = value.lastIndexOf('.');
    return dot <= 0 ? value : value.substring(0, dot);
  }

  static String _fileExtension(String value) {
    final dot = value.lastIndexOf('.');
    return dot <= 0 ? '' : value.substring(dot);
  }

  static List<String> _naturalParts(String value) {
    return RegExp(r'\d+|\D+')
        .allMatches(value)
        .map((match) => match.group(0)!)
        .toList(growable: false);
  }
}

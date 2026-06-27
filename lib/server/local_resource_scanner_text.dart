part of 'local_resource_scanner.dart';

extension LocalResourceScannerText on LocalResourceScanner {
  String _safeCacheName(String value) {
    final sanitized = value.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    return sanitized.isEmpty ? 'default' : sanitized;
  }

  String _sanitizePathSegment(String value) {
    final sanitized = value.trim().replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    return sanitized.isEmpty ? '' : sanitized;
  }

  String _firstNonEmptyValue(Iterable<String?> values) {
    for (final value in values) {
      final normalized = value?.trim() ?? '';
      if (normalized.isNotEmpty) {
        return normalized;
      }
    }
    return '';
  }

  String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    final parts =
        normalized.split('/').where((entry) => entry.isNotEmpty).toList();
    return parts.isEmpty ? normalized : parts.last;
  }

  String _basenameWithoutExtension(String name) {
    final dotIndex = name.lastIndexOf('.');
    if (dotIndex > 0) {
      return name.substring(0, dotIndex);
    }
    return name;
  }

  String _buildItemId(String rootId, String path) {
    final raw = utf8.encode('$rootId::$path');
    return base64Url.encode(raw).replaceAll('=', '');
  }

  String _directoryTitle(String directoryPath) {
    final normalized = directoryPath.replaceAll('\\', '/');
    final parts = normalized.split('/').where((e) => e.isNotEmpty).toList();
    return parts.isEmpty ? directoryPath : parts.last;
  }

  String _normalizePath(String path) {
    return path.replaceAll('\\', '/').toLowerCase();
  }

  int _naturalCompare(String a, String b) {
    final aTokens = _naturalTokens(a);
    final bTokens = _naturalTokens(b);
    final length =
        aTokens.length < bTokens.length ? aTokens.length : bTokens.length;
    for (var i = 0; i < length; i++) {
      final left = aTokens[i];
      final right = bTokens[i];
      if (left is int && right is int) {
        final compare = left.compareTo(right);
        if (compare != 0) {
          return compare;
        }
        continue;
      }
      final compare = left.toString().compareTo(right.toString());
      if (compare != 0) {
        return compare;
      }
    }
    return aTokens.length.compareTo(bTokens.length);
  }

  List<Object> _naturalTokens(String value) {
    final matches = RegExp(r'(\d+|\D+)').allMatches(value);
    return matches.map((match) {
      final part = match.group(0)!;
      final number = int.tryParse(part);
      return number ?? part;
    }).toList(growable: false);
  }
}

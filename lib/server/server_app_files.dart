part of 'server_app.dart';

extension ServerAppFiles on PicaKeepAdminServer {
  String? _archivePathForItem(ServerResourceItemSummary item) {
    final explicit = item.archivePath?.trim() ?? '';
    if (explicit.isNotEmpty) {
      return explicit;
    }
    if (isArchivePath(item.path)) {
      return item.path;
    }
    final normalizedId = item.id.trim();
    if (normalizedId.isEmpty) {
      return null;
    }
    try {
      var padded = normalizedId;
      while (padded.length % 4 != 0) {
        padded += '=';
      }
      final decoded = utf8.decode(base64Url.decode(padded));
      final marker = '${item.rootId}::';
      if (decoded.startsWith(marker)) {
        final path = decoded.substring(marker.length).trim();
        return path.isEmpty ? null : path;
      }
      final separator = decoded.indexOf('::');
      if (separator >= 0 && separator + 2 < decoded.length) {
        final path = decoded.substring(separator + 2).trim();
        return path.isEmpty ? null : path;
      }
    } catch (_) {}
    return null;
  }

  Future<Response> _archiveBytesResponse(
    Request request,
    String archiveUri,
  ) async {
    final parsed = parseArchiveUri(archiveUri);
    if (parsed == null) {
      return _jsonResponse({'error': 'archive entry not found'},
          statusCode: 404);
    }
    try {
      final bytes =
          await ArchiveReadingService.instance.readEntryBytesByUri(archiveUri);
      return Response.ok(
        bytes,
        headers: {
          HttpHeaders.contentTypeHeader: _contentTypeForPath(parsed.entryPath),
          HttpHeaders.contentLengthHeader: bytes.length.toString(),
          HttpHeaders.cacheControlHeader: 'public, max-age=300',
        },
      );
    } on ArchiveFailure catch (failure) {
      if (failure.code == ArchiveErrorCode.passwordRequired ||
          failure.code == ArchiveErrorCode.wrongPassword ||
          failure.code == ArchiveErrorCode.encryptedArchive) {
        return _jsonResponse({'error': 'archive locked'}, statusCode: 403);
      }
      return _jsonResponse({'error': 'archive entry not found'},
          statusCode: 404);
    }
  }

  Future<Response> _fileResponse(Request request, String filePath) async {
    final directFile = File(filePath);

    if (await directFile.exists()) {
      try {
        final length = await directFile.length();
        final headers = <String, String>{
          HttpHeaders.contentTypeHeader: _contentTypeForPath(filePath),
          HttpHeaders.acceptRangesHeader: 'bytes',
          HttpHeaders.cacheControlHeader: 'public, max-age=300',
        };

        final range = request.headers[HttpHeaders.rangeHeader];
        if (range != null) {
          final match = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(range);
          if (match != null) {
            var start = int.tryParse(match.group(1) ?? '') ?? 0;
            var end = int.tryParse(match.group(2) ?? '') ?? (length - 1);
            if (start < 0 || start >= length || end < start) {
              return Response(
                416,
                headers: {
                  HttpHeaders.contentRangeHeader: 'bytes */$length',
                  HttpHeaders.acceptRangesHeader: 'bytes',
                },
              );
            }
            if (end >= length) {
              end = length - 1;
            }
            final chunkLength = end - start + 1;
            return Response(
              206,
              body: directFile.openRead(start, end + 1),
              headers: {
                ...headers,
                HttpHeaders.contentLengthHeader: chunkLength.toString(),
                HttpHeaders.contentRangeHeader: 'bytes $start-$end/$length',
              },
            );
          }
        }

        return Response.ok(
          directFile.openRead(),
          headers: {
            ...headers,
            HttpHeaders.contentLengthHeader: length.toString(),
          },
        );
      } catch (_) {
        // dart:io access failed — try privileged fallback below.
      }
    }

    final bytes = await PrivilegedStorageAccess.readFileBytes(filePath);
    if (bytes == null || bytes.isEmpty) {
      return _jsonResponse({'error': 'file not found'}, statusCode: 404);
    }

    return Response.ok(
      bytes,
      headers: {
        HttpHeaders.contentTypeHeader: _contentTypeForPath(filePath),
        HttpHeaders.contentLengthHeader: bytes.length.toString(),
        HttpHeaders.cacheControlHeader: 'public, max-age=300',
      },
    );
  }

  String _contentTypeForPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) {
      return ContentType('image', 'png').toString();
    }
    if (lower.endsWith('.webp')) {
      return 'image/webp';
    }
    if (lower.endsWith('.gif')) {
      return 'image/gif';
    }
    if (lower.endsWith('.bmp')) {
      return 'image/bmp';
    }
    return ContentType('image', 'jpeg').toString();
  }
}

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:charset/charset.dart';
import 'package:pointycastle/export.dart' as pc;

import '../archive_backend.dart';
import '../archive_errors.dart';
import '../archive_models.dart';

class DartZipBackend implements ArchiveBackend {
  @override
  String get id => 'dart_zip';

  @override
  ArchiveBackendCapabilities get capabilities =>
      const ArchiveBackendCapabilities(
        supportsZip: true,
        supportsZipCrypto: true,
        supportsAesZip: true,
        canListEntriesWithoutPassword: true,
        canReadEntryStreaming: false,
      );

  @override
  bool supportsPath(String archivePath) {
    final lower = archivePath.toLowerCase();
    return lower.endsWith('.zip') || lower.endsWith('.cbz');
  }

  @override
  Future<ArchiveProbeResult> probe(String archivePath) async {
    final format = archiveFormatForPath(archivePath);
    if (format == ArchiveFormat.unknown) {
      throw ArchiveFailure(
        code: ArchiveErrorCode.unsupportedFormat,
        debugMessage: 'Not a zip/cbz: $archivePath',
      );
    }
    try {
      final entries = await _parseCentralDirectory(archivePath);
      var encrypted = false;
      var imageCount = 0;
      for (final entry in entries) {
        if (entry.isEncrypted) encrypted = true;
        if (_isImagePath(entry.path)) imageCount++;
      }
      return ArchiveProbeResult(
        format: format,
        isEncrypted: encrypted,
        entryCount: entries.length,
        imageEntryCount: imageCount,
      );
    } on ArchiveFailure {
      rethrow;
    } catch (_) {
      return _probeFallback(archivePath, format);
    }
  }

  @override
  Future<ArchiveIndex> openIndex(String archivePath, {String? password}) async {
    final format = archiveFormatForPath(archivePath);
    if (format == ArchiveFormat.unknown) {
      throw ArchiveFailure(
        code: ArchiveErrorCode.unsupportedFormat,
        debugMessage: 'Not a zip/cbz: $archivePath',
      );
    }
    try {
      final stat = await File(archivePath).stat();
      final entries = await _parseCentralDirectory(archivePath);
      final filtered = <ArchiveEntry>[];
      for (final entry in entries) {
        if (!isValidArchiveEntryPath(entry.path)) continue;
        if (isHiddenArchiveEntry(entry.path)) continue;
        filtered.add(entry);
      }
      return ArchiveIndex(
        archivePath: archivePath,
        format: format,
        isEncrypted: filtered.any((e) => e.isEncrypted),
        entries: filtered,
        fileSize: stat.size,
        mtimeMillis: stat.modified.millisecondsSinceEpoch,
      );
    } on ArchiveFailure {
      rethrow;
    } catch (_) {
      return _openIndexFallback(archivePath, format);
    }
  }

  @override
  Future<Uint8List> readEntry(
    String archivePath,
    String entryPath, {
    String? password,
  }) async {
    if (!isValidArchiveEntryPath(entryPath)) {
      throw ArchiveFailure(
        code: ArchiveErrorCode.entryNotFound,
        debugMessage: 'Invalid entry path: $entryPath',
      );
    }
    final normalizedTarget = entryPath.replaceAll('\\', '/');
    late final List<_CdEntry> cdEntries;
    late final List<_CdEntry> fileEntries;
    late final _CdEntry match;
    late final int matchIndex;
    try {
      cdEntries = await _parseCentralDirectoryWithOffsets(archivePath);
      fileEntries = cdEntries.where((e) => !e.isDirectory).toList();
      matchIndex = fileEntries.indexWhere((e) => e.path == normalizedTarget);
      if (matchIndex < 0) {
        throw ArchiveFailure(
          code: ArchiveErrorCode.entryNotFound,
          debugMessage: 'Entry not found: $entryPath in $archivePath',
        );
      }
      match = fileEntries[matchIndex];
    } on ArchiveFailure {
      rethrow;
    } catch (e) {
      throw ArchiveFailure(
        code: ArchiveErrorCode.corruptedArchive,
        debugMessage: 'Failed to parse central directory for $archivePath: $e',
        cause: e,
      );
    }

    try {
      if (match.isEncrypted) {
        if (password == null || password.isEmpty) {
          throw ArchiveFailure(
            code: ArchiveErrorCode.passwordRequired,
            debugMessage: 'Password required for $entryPath',
          );
        }
        if (match.isAesEncrypted) {
          return await _readAesEntry(archivePath, match, password);
        }
        return await _readZipCryptoEntry(archivePath, match, password);
      }
      return await _readEntryFallback(archivePath, normalizedTarget);
    } on ArchiveFailure {
      rethrow;
    } catch (e) {
      throw ArchiveFailure(
        code: ArchiveErrorCode.corruptedArchive,
        debugMessage: 'Failed to read $entryPath in $archivePath: $e',
        cause: e,
      );
    }
  }

  Future<Uint8List> _readZipCryptoEntry(
    String archivePath,
    _CdEntry match,
    String password,
  ) async {
    final f = await File(archivePath).open();
    Uint8List encrypted;
    int flags;
    int lastModTime;
    int localCrc32;
    try {
      await f.setPosition(match.localHeaderOffset);
      final lhFixed = await f.read(30);
      if (lhFixed[0] != 0x50 ||
          lhFixed[1] != 0x4b ||
          lhFixed[2] != 0x03 ||
          lhFixed[3] != 0x04) {
        throw ArchiveFailure(
          code: ArchiveErrorCode.corruptedArchive,
          debugMessage:
              'Invalid local file header at ${match.localHeaderOffset}',
        );
      }
      flags = _u16(lhFixed, 6);
      lastModTime = _u16(lhFixed, 10);
      localCrc32 = _u32(lhFixed, 14);
      final fnLen = _u16(lhFixed, 26);
      final extraLen = _u16(lhFixed, 28);
      await f.setPosition(match.localHeaderOffset + 30 + fnLen + extraLen);
      encrypted = Uint8List.fromList(await f.read(match.compressedSize));
    } finally {
      await f.close();
    }

    if (encrypted.length < 12) {
      throw ArchiveFailure(
        code: ArchiveErrorCode.corruptedArchive,
        debugMessage: 'ZipCrypto payload too small for ${match.path}',
      );
    }

    final keys = _zipCryptoInitKeys(password);
    final header = Uint8List(12);
    for (var i = 0; i < 12; i++) {
      final c = encrypted[i] ^ _zipCryptoDecryptByte(keys);
      _zipCryptoUpdateKeys(keys, c);
      header[i] = c;
    }

    final checkByte =
        (flags & 0x08) != 0 ? (lastModTime >> 8) & 0xFF : (localCrc32 >> 24) & 0xFF;
    if (header[11] != checkByte) {
      throw ArchiveFailure(
        code: ArchiveErrorCode.wrongPassword,
        debugMessage: 'ZipCrypto password verification failed for ${match.path}',
      );
    }

    final body = Uint8List(encrypted.length - 12);
    for (var i = 0; i < body.length; i++) {
      final c = encrypted[12 + i] ^ _zipCryptoDecryptByte(keys);
      _zipCryptoUpdateKeys(keys, c);
      body[i] = c;
    }

    final method = match.compressionMethod;
    if (method == 0) {
      return body;
    } else if (method == 8) {
      return _inflateRaw(body);
    } else {
      throw ArchiveFailure(
        code: ArchiveErrorCode.unsupportedFormat,
        debugMessage:
            'Unsupported ZipCrypto inner method $method for ${match.path}',
      );
    }
  }

  static List<int> _zipCryptoInitKeys(String password) {
    final keys = <int>[305419896, 591751049, 878082192];
    for (final c in password.codeUnits) {
      _zipCryptoUpdateKeys(keys, c);
    }
    return keys;
  }

  static void _zipCryptoUpdateKeys(List<int> keys, int c) {
    keys[0] = _zipCryptoCrc32Update(keys[0], c);
    keys[1] = (keys[1] + (keys[0] & 0xFF)) & 0xFFFFFFFF;
    keys[1] = (keys[1] * 134775813 + 1) & 0xFFFFFFFF;
    keys[2] = _zipCryptoCrc32Update(keys[2], (keys[1] >> 24) & 0xFF);
  }

  static int _zipCryptoDecryptByte(List<int> keys) {
    final temp = (keys[2] & 0xFFFF) | 2;
    return ((temp * (temp ^ 1)) >> 8) & 0xFF;
  }

  static int _zipCryptoCrc32Update(int crc, int b) {
    var c = crc ^ b;
    for (var i = 0; i < 8; i++) {
      c = ((c >> 1) & 0x7FFFFFFF) ^ (((c & 1) != 0) ? 0xEDB88320 : 0);
    }
    return c;
  }

  Future<Uint8List> _readAesEntry(
    String archivePath,
    _CdEntry match,
    String password,
  ) async {
    final f = await File(archivePath).open();
    Uint8List rawEncrypted;
    try {
      await f.setPosition(match.localHeaderOffset);
      final lhFixed = await f.read(30);
      if (lhFixed[0] != 0x50 ||
          lhFixed[1] != 0x4b ||
          lhFixed[2] != 0x03 ||
          lhFixed[3] != 0x04) {
        throw ArchiveFailure(
          code: ArchiveErrorCode.corruptedArchive,
          debugMessage:
              'Invalid local file header at ${match.localHeaderOffset}',
        );
      }
      final fnLen = _u16(lhFixed, 26);
      final extraLen = _u16(lhFixed, 28);
      await f.setPosition(match.localHeaderOffset + 30 + fnLen + extraLen);
      rawEncrypted = Uint8List.fromList(await f.read(match.compressedSize));
    } finally {
      await f.close();
    }

    final saltLen = match.aesStrength == 1
        ? 8
        : match.aesStrength == 2
            ? 12
            : 16;
    final keySize = match.aesStrength == 1
        ? 16
        : match.aesStrength == 2
            ? 24
            : 32;
    if (rawEncrypted.length < saltLen + 2 + 10) {
      throw ArchiveFailure(
        code: ArchiveErrorCode.corruptedArchive,
        debugMessage: 'AES payload too small for ${match.path}',
      );
    }
    final salt = Uint8List.sublistView(rawEncrypted, 0, saltLen);
    final pwdVerify =
        Uint8List.sublistView(rawEncrypted, saltLen, saltLen + 2);
    final dataEnd = rawEncrypted.length - 10;
    final cipherData = Uint8List.fromList(
      Uint8List.sublistView(rawEncrypted, saltLen + 2, dataEnd),
    );
    final fileMac = Uint8List.sublistView(rawEncrypted, dataEnd);

    final derivedKey = _pbkdf2HmacSha1(
      Uint8List.fromList(password.codeUnits),
      salt,
      1000,
      keySize * 2 + 2,
    );
    final encKey = Uint8List.fromList(
      Uint8List.sublistView(derivedKey, 0, keySize),
    );
    final macKey = Uint8List.fromList(
      Uint8List.sublistView(derivedKey, keySize, keySize * 2),
    );
    final pwdCheck =
        Uint8List.sublistView(derivedKey, keySize * 2, keySize * 2 + 2);

    if (!_bytesEqual(pwdCheck, pwdVerify)) {
      throw ArchiveFailure(
        code: ArchiveErrorCode.wrongPassword,
        debugMessage: 'Password verification failed for ${match.path}',
      );
    }

    final hmac = pc.HMac(pc.SHA1Digest(), 64)
      ..init(pc.KeyParameter(macKey))
      ..update(cipherData, 0, cipherData.length);
    final computedMac = Uint8List(hmac.macSize);
    hmac.doFinal(computedMac, 0);
    if (!_bytesEqual(
      Uint8List.sublistView(computedMac, 0, 10),
      Uint8List.fromList(fileMac),
    )) {
      throw ArchiveFailure(
        code: ArchiveErrorCode.wrongPassword,
        debugMessage: 'AES HMAC mismatch for ${match.path}',
      );
    }

    _aesCtrXorZip(cipherData, encKey);

    final method = match.compressionMethod;
    if (method == 0) {
      return cipherData;
    } else if (method == 8) {
      return _inflateRaw(cipherData);
    } else {
      throw ArchiveFailure(
        code: ArchiveErrorCode.unsupportedFormat,
        debugMessage: 'Unsupported AES inner method $method for ${match.path}',
      );
    }
  }

  static Uint8List _pbkdf2HmacSha1(
    Uint8List password,
    Uint8List salt,
    int iterations,
    int keyLength,
  ) {
    final derivator = pc.PBKDF2KeyDerivator(pc.HMac(pc.SHA1Digest(), 64))
      ..init(pc.Pbkdf2Parameters(salt, iterations, keyLength));
    return derivator.process(password);
  }

  static void _aesCtrXorZip(Uint8List data, Uint8List key) {
    final cipher = pc.AESEngine()..init(true, pc.KeyParameter(key));
    final iv = Uint8List(16);
    final block = Uint8List(16);
    var nonce = 1;
    for (var offset = 0; offset < data.length; offset += 16) {
      iv[0] = nonce & 0xFF;
      iv[1] = (nonce >> 8) & 0xFF;
      iv[2] = (nonce >> 16) & 0xFF;
      iv[3] = (nonce >> 24) & 0xFF;
      for (var i = 4; i < 16; i++) {
        iv[i] = 0;
      }
      cipher.processBlock(iv, 0, block, 0);
      final end = offset + 16 <= data.length ? offset + 16 : data.length;
      for (var i = offset; i < end; i++) {
        data[i] ^= block[i - offset];
      }
      nonce++;
    }
  }

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var v = 0;
    for (var i = 0; i < a.length; i++) {
      v |= a[i] ^ b[i];
    }
    return v == 0;
  }

  static Uint8List _inflateRaw(Uint8List src) {
    final filter = RawZLibFilter.inflateFilter(windowBits: -15);
    filter.process(src, 0, src.length);
    final chunks = <int>[];
    while (true) {
      final chunk = filter.processed(flush: false);
      if (chunk == null) break;
      chunks.addAll(chunk);
    }
    final last = filter.processed(flush: true, end: true);
    if (last != null) chunks.addAll(last);
    return Uint8List.fromList(chunks);
  }

  Future<Uint8List> _readEntryFallback(
    String archivePath,
    String entryPath,
  ) async {
    final cdEntries = await _parseCentralDirectoryWithOffsets(archivePath);
    final normalizedTarget = entryPath.replaceAll('\\', '/');
    final match =
        cdEntries.where((e) => e.path == normalizedTarget).firstOrNull;
    if (match == null) {
      throw ArchiveFailure(
        code: ArchiveErrorCode.entryNotFound,
        debugMessage: 'Entry not found (fallback): $entryPath in $archivePath',
      );
    }
    if (match.isEncrypted) {
      throw ArchiveFailure(
        code: ArchiveErrorCode.wrongPassword,
        debugMessage:
            'Encrypted entry cannot be read by raw fallback: $entryPath',
      );
    }

    final f = await File(archivePath).open();
    try {
      await f.setPosition(match.localHeaderOffset);
      final lhFixed = await f.read(30);
      if (lhFixed[0] != 0x50 ||
          lhFixed[1] != 0x4b ||
          lhFixed[2] != 0x03 ||
          lhFixed[3] != 0x04) {
        throw ArchiveFailure(
          code: ArchiveErrorCode.corruptedArchive,
          debugMessage:
              'Invalid local file header at ${match.localHeaderOffset}',
        );
      }
      final method = _u16(lhFixed, 8);
      final fnLen = _u16(lhFixed, 26);
      final extraLen = _u16(lhFixed, 28);
      await f.setPosition(match.localHeaderOffset + 30 + fnLen + extraLen);
      final compressedData = await f.read(match.compressedSize);

      if (method == 0) {
        return Uint8List.fromList(compressedData);
      } else if (method == 8) {
        final src = Uint8List.fromList(compressedData);
        final filter = RawZLibFilter.inflateFilter(windowBits: -15);
        filter.process(src, 0, src.length);
        final chunks = <int>[];
        while (true) {
          final chunk = filter.processed(flush: false);
          if (chunk == null) break;
          chunks.addAll(chunk);
        }
        final last = filter.processed(flush: true, end: true);
        if (last != null) chunks.addAll(last);
        return Uint8List.fromList(chunks);
      } else {
        throw ArchiveFailure(
          code: ArchiveErrorCode.unsupportedFormat,
          debugMessage: 'Unsupported compression method $method for $entryPath',
        );
      }
    } finally {
      await f.close();
    }
  }

  Future<List<_CdEntry>> _parseCentralDirectoryWithOffsets(
      String archivePath) async {
    final file = await File(archivePath).open();
    try {
      final fileSize = await file.length();
      final searchSize = (65536 + 22).clamp(0, fileSize);
      final searchOffset = fileSize - searchSize;
      await file.setPosition(searchOffset);
      final searchBuf = await file.read(searchSize);

      int eocdOffset = -1;
      for (int i = searchBuf.length - 22; i >= 0; i--) {
        if (searchBuf[i] == 0x50 &&
            searchBuf[i + 1] == 0x4b &&
            searchBuf[i + 2] == 0x05 &&
            searchBuf[i + 3] == 0x06) {
          eocdOffset = searchOffset + i;
          break;
        }
      }
      if (eocdOffset < 0) throw const FormatException('EOCD not found');

      await file.setPosition(eocdOffset);
      final eocd = await file.read(22);
      var cdSize = _u32(eocd, 12);
      var cdOffset = _u32(eocd, 16);

      if (eocdOffset >= 20) {
        await file.setPosition(eocdOffset - 20);
        final locator = await file.read(20);
        if (locator[0] == 0x50 &&
            locator[1] == 0x4b &&
            locator[2] == 0x06 &&
            locator[3] == 0x07) {
          final zip64EocdOffset = _u64(locator, 8);
          await file.setPosition(zip64EocdOffset);
          final zip64Eocd = await file.read(56);
          if (zip64Eocd[0] == 0x50 &&
              zip64Eocd[1] == 0x4b &&
              zip64Eocd[2] == 0x06 &&
              zip64Eocd[3] == 0x06) {
            cdSize = _u64(zip64Eocd, 40);
            cdOffset = _u64(zip64Eocd, 48);
          }
        }
      }

      await file.setPosition(cdOffset);
      final cd = await file.read(cdSize);

      final entries = <_CdEntry>[];
      int pos = 0;
      while (pos + 46 <= cd.length) {
        if (cd[pos] != 0x50 ||
            cd[pos + 1] != 0x4b ||
            cd[pos + 2] != 0x01 ||
            cd[pos + 3] != 0x02) {
          break;
        }

        final flags = _u16(cd, pos + 8);
        final isEncrypted = (flags & 0x1) != 0;
        var isAesEncrypted = false;
        var aesStrength = 0;
        var compressionMethod = _u16(cd, pos + 10);
        var compressedSize = _u32(cd, pos + 20);
        var uncompressedSize = _u32(cd, pos + 24);
        final fnLen = _u16(cd, pos + 28);
        final extraLen = _u16(cd, pos + 30);
        final commentLen = _u16(cd, pos + 32);
        final extAttrs = _u32(cd, pos + 38);
        var localOffset = _u32(cd, pos + 42);

        if (pos + 46 + fnLen > cd.length) break;
        final fnBytes = cd.sublist(pos + 46, pos + 46 + fnLen);
        final name = _decodeZipEntryPath(fnBytes, flags: flags);

        int ep = pos + 46 + fnLen;
        final epEnd = ep + extraLen;
        while (ep + 4 <= epEnd && ep + 4 <= cd.length) {
          final headerId = _u16(cd, ep);
          final dataSize = _u16(cd, ep + 2);
          final dataStart = ep + 4;
          final dataEnd = dataStart + dataSize;
          if (dataEnd > epEnd || dataEnd > cd.length) break;
          if (headerId == 0x0001) {
            int dp = dataStart;
            if (uncompressedSize == 0xFFFFFFFF && dp + 8 <= dataEnd) {
              uncompressedSize = _u64(cd, dp);
              dp += 8;
            }
            if (compressedSize == 0xFFFFFFFF && dp + 8 <= dataEnd) {
              compressedSize = _u64(cd, dp);
              dp += 8;
            }
            if (localOffset == 0xFFFFFFFF && dp + 8 <= dataEnd) {
              localOffset = _u64(cd, dp);
            }
          } else if (headerId == 0x9901 && dataSize >= 7) {
            final dp = dataStart;
            aesStrength = cd[dp + 4];
            compressionMethod = _u16(cd, dp + 5);
            isAesEncrypted = true;
          }
          ep += 4 + dataSize;
        }

        final isDir =
            name.endsWith('/') || (_u32(cd, pos + 38) >> 16 & 0x4000) != 0;
        entries.add(_CdEntry(
          path: name,
          localHeaderOffset: localOffset,
          compressedSize: compressedSize,
          uncompressedSize: uncompressedSize,
          isEncrypted: isEncrypted || isAesEncrypted,
          isDirectory: isDir,
          externalAttributes: extAttrs,
          isAesEncrypted: isAesEncrypted,
          compressionMethod: compressionMethod,
          aesStrength: aesStrength,
        ));
        pos += 46 + fnLen + extraLen + commentLen;
      }
      return entries;
    } finally {
      await file.close();
    }
  }

  Future<ArchiveProbeResult> _probeFallback(
    String archivePath,
    ArchiveFormat format,
  ) async {
    try {
      final entries = await _parseCentralDirectory(archivePath);
      var encrypted = false;
      var imageCount = 0;
      for (final e in entries) {
        if (e.isEncrypted) encrypted = true;
        if (_isImagePath(e.path)) imageCount++;
      }
      return ArchiveProbeResult(
        format: format,
        isEncrypted: encrypted,
        entryCount: entries.length,
        imageEntryCount: imageCount,
      );
    } catch (e) {
      throw ArchiveFailure(
        code: ArchiveErrorCode.corruptedArchive,
        debugMessage: 'probe fallback failed for $archivePath: $e',
        cause: e,
      );
    }
  }

  Future<ArchiveIndex> _openIndexFallback(
    String archivePath,
    ArchiveFormat format,
  ) async {
    try {
      final stat = await File(archivePath).stat();
      final entries = await _parseCentralDirectory(archivePath);
      final filtered = <ArchiveEntry>[];
      for (final e in entries) {
        if (!isValidArchiveEntryPath(e.path)) continue;
        if (isHiddenArchiveEntry(e.path)) continue;
        filtered.add(e);
      }
      return ArchiveIndex(
        archivePath: archivePath,
        format: format,
        isEncrypted: filtered.any((e) => e.isEncrypted),
        entries: filtered,
        fileSize: stat.size,
        mtimeMillis: stat.modified.millisecondsSinceEpoch,
      );
    } catch (e) {
      throw ArchiveFailure(
        code: ArchiveErrorCode.corruptedArchive,
        debugMessage: 'openIndex fallback failed for $archivePath: $e',
        cause: e,
      );
    }
  }

  Future<List<ArchiveEntry>> _parseCentralDirectory(String archivePath) async {
    final entries = await _parseCentralDirectoryWithOffsets(archivePath);
    return [
      for (final entry in entries)
        ArchiveEntry(
          path: entry.path,
          size: entry.uncompressedSize,
          isEncrypted: entry.isEncrypted,
          isDirectory: entry.isDirectory,
        ),
    ];
  }

  static int _u16(List<int> buf, int offset) =>
      buf[offset] | (buf[offset + 1] << 8);

  static int _u32(List<int> buf, int offset) =>
      buf[offset] |
      (buf[offset + 1] << 8) |
      (buf[offset + 2] << 16) |
      (buf[offset + 3] << 24);

  static int _u64(List<int> buf, int offset) {
    final lo = _u32(buf, offset);
    final hi = _u32(buf, offset + 4);
    return lo + hi * 0x100000000;
  }

  static String _decodeZipEntryPath(List<int> bytes, {required int flags}) {
    final name = _decodeString(bytes, useUtf8: (flags & 0x800) != 0)
        .replaceAll('\\', '/');
    return name;
  }

  static String _decodeString(List<int> bytes, {required bool useUtf8}) {
    final buf = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    if (useUtf8) {
      return utf8.decode(buf, allowMalformed: true);
    }
    if (_isAsciiOnly(buf)) {
      return latin1.decode(buf);
    }

    final candidates = <String>[];

    try {
      candidates.add(utf8.decode(buf));
    } catch (_) {}

    try {
      candidates.add(shiftJis.decode(buf));
    } catch (_) {}

    try {
      candidates.add(gbk.decode(buf));
    } catch (_) {}

    if (candidates.isEmpty) {
      return latin1.decode(buf);
    }

    candidates.sort((a, b) => _scoreDecodedFilename(b).compareTo(
          _scoreDecodedFilename(a),
        ));
    return candidates.first;
  }

  static bool _isAsciiOnly(List<int> bytes) {
    for (final byte in bytes) {
      if (byte > 0x7F) {
        return false;
      }
    }
    return true;
  }

  static int _scoreDecodedFilename(String value) {
    if (value.isEmpty) {
      return -1 << 20;
    }

    var score = 0;
    for (final rune in value.runes) {
      if (rune == 0xFFFD) {
        score -= 100;
        continue;
      }
      if (rune < 0x20 && rune != 0x09) {
        score -= 80;
        continue;
      }
      if (rune <= 0x7F) {
        score += 1;
        continue;
      }
      if (_isCjkRune(rune)) {
        score += 12;
        continue;
      }
      if (_isKanaRune(rune)) {
        score += 10;
        continue;
      }
      if (_isHangulRune(rune)) {
        score += 8;
        continue;
      }
      score += 2;
    }

    if (_filenameLooksMojibake(value)) {
      score -= 120;
    }
    return score;
  }

  static bool _isCjkRune(int rune) {
    return (rune >= 0x4E00 && rune <= 0x9FFF) ||
        (rune >= 0x3400 && rune <= 0x4DBF) ||
        (rune >= 0xF900 && rune <= 0xFAFF);
  }

  static bool _isKanaRune(int rune) {
    return (rune >= 0x3040 && rune <= 0x309F) ||
        (rune >= 0x30A0 && rune <= 0x30FF) ||
        (rune >= 0x31F0 && rune <= 0x31FF);
  }

  static bool _isHangulRune(int rune) {
    return (rune >= 0xAC00 && rune <= 0xD7AF) ||
        (rune >= 0x1100 && rune <= 0x11FF) ||
        (rune >= 0x3130 && rune <= 0x318F);
  }

  static bool _filenameLooksMojibake(String value) {
    return value.contains('Ã') ||
        value.contains('Â') ||
        value.contains('Ð') ||
        value.contains('Ñ') ||
        value.contains('鈥') ||
        value.contains('縺') ||
        value.contains('繧') ||
        value.contains('ｿ') ||
        value.contains('�');
  }

  bool _isImagePath(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.webp');
  }
}

class _CdEntry {
  const _CdEntry({
    required this.path,
    required this.localHeaderOffset,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.isEncrypted,
    required this.isDirectory,
    required this.externalAttributes,
    this.isAesEncrypted = false,
    this.compressionMethod = 0,
    this.aesStrength = 0,
  });

  final String path;
  final int localHeaderOffset;
  final int compressedSize;
  final int uncompressedSize;
  final bool isEncrypted;
  final bool isDirectory;
  final int externalAttributes;
  final bool isAesEncrypted;
  final int compressionMethod;
  final int aesStrength;
}

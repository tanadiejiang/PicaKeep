import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'reader_page_source.dart';

Future<({String extension, String mime})> originalImageType(File file) async {
  final input = await file.open();
  try {
    final bytes = await input.read(32);
    return readerPageTypeFromHeader(Uint8List.fromList(bytes));
  } finally {
    await input.close();
  }
}

Future<String> originalImageDigest(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

/// Atomic, bounded file copy. Existing files are never overwritten; the name
/// includes the source identity and content digest, so same-basename pages
/// from different works cannot silently reuse one another's persistent image.
Future<File> persistOriginalImage(
  File original, {
  required Directory directory,
  required ReaderPageIdentity identity,
  int maxBytes = 2 * 1024 * 1024 * 1024,
}) async {
  final size = await original.length();
  if (size <= 0 || size > maxBytes) {
    throw StateError('Original file exceeds persistence budget');
  }
  final type = await originalImageType(original);
  final digest = await originalImageDigest(original);
  final identityHash =
      sha256.convert(utf8.encode(identity.stableKey)).toString();
  await directory.create(recursive: true);
  final target =
      File('${directory.path}/$identityHash-$digest${type.extension}');
  if (await target.exists()) {
    if (await target.length() == size &&
        await originalImageDigest(target) == digest) {
      return target;
    }
    throw StateError(
        'Existing persistent original failed integrity verification');
  }
  final temporary =
      File('${target.path}.${DateTime.now().microsecondsSinceEpoch}.part');
  final output = await temporary.open(mode: FileMode.write);
  var count = 0;
  try {
    await for (final chunk in original.openRead()) {
      count += chunk.length;
      if (count > maxBytes) {
        throw StateError('Original file exceeds persistence budget');
      }
      await output.writeFrom(chunk);
    }
    await output.flush();
    await output.close();
    if (count != size || await originalImageDigest(temporary) != digest) {
      throw StateError('Original file changed while being copied');
    }
    // Identical concurrent persistence may complete first. Verify and reuse
    // that file rather than replacing it with an unverified copy.
    if (await target.exists()) {
      if (await originalImageDigest(target) != digest) {
        throw StateError('Persistent identity collision');
      }
      await temporary.delete();
      return target;
    }
    return await temporary.rename(target.path);
  } catch (_) {
    await output.close();
    if (await temporary.exists()) await temporary.delete();
    rethrow;
  }
}

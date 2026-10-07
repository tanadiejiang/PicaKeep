import 'dart:io';
import 'package:flutter/services.dart';

/// Android copies original bytes to a unique MediaStore item, verifies only
/// that new URI, and publishes it after SHA-256 matches. No Bitmap re-encode.
Future<Map<String, Object?>> saveAndroidOriginalToGallery(File file) async {
  if (!Platform.isAndroid) {
    throw UnsupportedError('Original MediaStore export requires Android');
  }
  final result = await const MethodChannel('lingxue.picakeep/storage_access')
      .invokeMapMethod<String, Object?>('saveOriginalToGallery', {
    'localFile': file.path,
  });
  final sourceSha = result?['sourceSha256'];
  final savedSha = result?['savedSha256'];
  final sourceBytes = result?['sourceBytes'];
  final savedBytes = result?['savedBytes'];
  if (result == null ||
      result['bytesEqual'] != true ||
      sourceSha is! String ||
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(sourceSha) ||
      sourceSha != savedSha ||
      sourceBytes is! int ||
      sourceBytes <= 0 ||
      sourceBytes != savedBytes ||
      result['uri'] is! String) {
    throw StateError('Android gallery export returned no verified original');
  }
  return result;
}

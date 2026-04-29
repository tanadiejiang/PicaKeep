// ignore_for_file: depend_on_referenced_packages

import 'dart:io';
import 'dart:math';

String bytesLengthToReadableSize(int length, {bool useBase2 = false}) {
  const suffixes = ["B", "KB", "MB", "GB", "TB", "PB"];
  const suffixesBase2 = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"];

  if (length == 0) return "0 B";

  var i = (log(length) / (useBase2 ? log(1024) : log(1000))).floor();
  var result = length / pow(useBase2 ? 1024 : 1000, i);
  var suffix = useBase2 ? suffixesBase2[i] : suffixes[i];

  return "${result.toStringAsFixed(2)} $suffix";
}

Future<void> openUrl(String url) async {
  // Placeholder - implement with url_launcher if needed
}

Future<bool> isOnline() async {
  try {
    final result = await InternetAddress.lookup('example.com');
    return result.isNotEmpty && result[0].rawAddress.isNotEmpty;
  } on SocketException catch (_) {
    return false;
  }
}

Future<void> safeCreateDirectory(Directory dir) async {
  if (!dir.existsSync()) {
    await dir.create(recursive: true);
  }
}

Future<void> eraseCache() async {}

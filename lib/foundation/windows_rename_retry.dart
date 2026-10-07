import 'dart:io';

/// Retry the same rename while Windows briefly denies deletion sharing.
///
/// A rename remains the publication boundary: this never copies, deletes a
/// destination, or reports a denied rename as successful. Persistent denial
/// and all errors other than Windows access/sharing/lock violations propagate.
Future<T> retryWindowsRename<T>(Future<T> Function() rename) async {
  const delays = [25, 75, 200, 500];
  for (var attempt = 0;; attempt++) {
    try {
      return await rename();
    } on FileSystemException catch (error) {
      if (!Platform.isWindows ||
          !const [5, 32, 33].contains(error.osError?.errorCode) ||
          attempt >= delays.length) {
        rethrow;
      }
      await Future<void>.delayed(Duration(milliseconds: delays[attempt]));
    }
  }
}

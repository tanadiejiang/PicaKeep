/// Pure-Dart event boundary; data modules never import a Flutter decoder.
class ImageBackgroundNotifications {
  ImageBackgroundNotifications._();
  static void Function(String finalPath)? onCommitted;
  static void committed(String finalPath) {
    if (finalPath.isEmpty) return;
    try { onCommitted?.call(finalPath); }
    catch (_) { /* Derived work is outside the resource transaction. */ }
  }
}

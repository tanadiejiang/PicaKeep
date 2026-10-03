import 'package:flutter/widgets.dart';

/// Keeps the same visible artwork at the same screen Y after idle size updates.
/// Uses actual rendered bounds, never a fixed-height approximation of masonry.
class IllustScrollAnchor {
  final controller = ScrollController();
  final _keys = <String, GlobalKey>{};
  GlobalKey keyFor(String id) => _keys.putIfAbsent(id, GlobalKey.new);

  ({String id, double y, double offset})? capture(
      Iterable<String> ids, double viewportTop, double viewportBottom) {
    if (!controller.hasClients || controller.offset <= 0) return null;
    for (final id in ids) {
      final render = _keys[id]?.currentContext?.findRenderObject();
      if (render is! RenderBox || !render.attached || !render.hasSize) continue;
      final y = render.localToGlobal(Offset.zero).dy;
      if (y + render.size.height > viewportTop && y < viewportBottom) {
        return (id: id, y: y, offset: controller.offset);
      }
    }
    return null;
  }

  void restore(({String id, double y, double offset})? anchor,
      {required bool Function() isCurrent}) {
    if (anchor == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!isCurrent() ||
          !controller.hasClients ||
          (controller.offset - anchor.offset).abs() > 0.5) {
        return;
      }
      final render = _keys[anchor.id]?.currentContext?.findRenderObject();
      if (render is! RenderBox || !render.attached || !render.hasSize) return;
      final delta = render.localToGlobal(Offset.zero).dy - anchor.y;
      if (delta.abs() < 0.5) return;
      final position = controller.position;
      controller.jumpTo((controller.offset + delta)
          .clamp(position.minScrollExtent, position.maxScrollExtent));
    });
  }

  void dispose() {
    controller.dispose();
    _keys.clear();
  }
}

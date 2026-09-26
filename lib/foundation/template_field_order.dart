/// 「勾选字段 + 拖拽排序」共用的**顺序调整**纯函数。
///
/// ## 为什么抽出来
///
/// 27 号（Pixiv 下载目录名模板）与 32 号（插画卡片底部信息）是**同一个交互形态**：
/// 一串候选字段，用户勾选若干项并拖动排序，顺序即渲染顺序。两者唯一的差别是
/// "字段有哪些"与"存到哪个 settings 下标"，排序算法必须**逐字相同** ——
/// 否则同一手势在两处表现不一致，而 `ReorderableListView.onReorder` 的索引语义
/// 又是最容易写错一位的地方（见 [reorderTemplateFieldOrder] 的说明）。
///
/// 所以算法留在这里一份，两处都调它。
library;

/// 把 [order] 的第 [oldIndex] 项移动到 [newIndex]，返回新列表。
///
/// 语义与 `ReorderableListView.onReorder` 一致：它给的 `newIndex` 是
/// "**移除该项之前**的目标位置"，所以**向下拖时必须减一**，否则每次都会差一位。
/// 这是该控件最常见的坑，抽成纯函数才有测试守得住 —— 编辑器里的 `onReorder`
/// 必须走这里，不要自己写 `removeAt` / `insert`。
///
/// 越界索引按"不动"处理（返回原顺序的副本）：拖动取消、或列表在拖动过程中被
/// 重建时索引可能瞬时越界，抛异常会让整个设置页崩掉。
List<String> reorderTemplateFieldOrder(
  List<String> order,
  int oldIndex,
  int newIndex,
) {
  if (oldIndex < 0 || oldIndex >= order.length) {
    return <String>[...order];
  }
  var target = newIndex;
  if (target > oldIndex) {
    target -= 1;
  }
  if (target < 0) {
    target = 0;
  }
  if (target > order.length - 1) {
    target = order.length - 1;
  }
  final next = <String>[...order];
  final moved = next.removeAt(oldIndex);
  next.insert(target, moved);
  return next;
}

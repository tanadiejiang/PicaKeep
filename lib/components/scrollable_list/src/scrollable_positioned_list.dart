import 'package:flutter/widgets.dart';
import 'item_positions_listener.dart';

class ScrollablePositionedList extends StatelessWidget {
  final int? itemCount;
  final Widget Function(BuildContext, int) itemBuilder;
  final ItemScrollController? itemScrollController;
  final ItemPositionsListener? itemPositionsListener;
  final ScrollController? scrollController;
  final int? initialScrollIndex;
  final bool? addSemanticIndexes;
  final ScrollBehavior? scrollBehavior;
  final ScrollPhysics? physics;

  const ScrollablePositionedList.builder({
    super.key,
    this.itemCount,
    required this.itemBuilder,
    this.itemScrollController,
    this.itemPositionsListener,
    this.scrollController,
    this.initialScrollIndex,
    this.addSemanticIndexes,
    this.scrollBehavior,
    this.physics,
  });

  @override
  Widget build(BuildContext context) => const SizedBox();
}

class ItemScrollController {
  void jumpTo({required int index}) {}

  void scrollTo({
    required int index,
    required Duration duration,
    Curve curve = Curves.easeInOut,
  }) {}
}

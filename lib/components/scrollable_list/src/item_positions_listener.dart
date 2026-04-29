import 'package:flutter/foundation.dart';

class ItemPosition {
  final int index;
  final double itemLeadingEdge;
  final double itemTrailingEdge;

  ItemPosition({required this.index, this.itemLeadingEdge = 0.0, this.itemTrailingEdge = 0.0});
}

class ItemPositionsListener {
  factory ItemPositionsListener.create() => ItemPositionsListener._();

  ItemPositionsListener._();

  final itemPositions = ValueNotifier<List<ItemPosition>>([ItemPosition(index: 0)]);
}

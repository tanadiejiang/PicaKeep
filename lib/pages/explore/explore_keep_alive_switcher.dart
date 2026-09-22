import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Keeps visited pages mounted, and gives viewport layout only to the selection.
///
/// Unlike IndexedStack or Offstage, switching or resizing the viewport does not
/// force all hidden pages through list/tag layout. A hidden page's own async
/// updates can still lay out its independently dirty render boundaries.
/// The incoming page uses paint-only transitions, without rebuilding child
/// widgets on every animation frame.
class ExploreKeepAliveSwitcher extends StatefulWidget {
  const ExploreKeepAliveSwitcher({
    super.key,
    required this.index,
    required this.children,
    this.animate = true,
    this.motionKey,
  }) : assert(index >= 0 && index < children.length);

  final int index;
  final List<Widget> children;
  final bool animate;

  /// Changes within one page (for example a ranking range) may also animate.
  final Object? motionKey;

  @override
  State<ExploreKeepAliveSwitcher> createState() =>
      _ExploreKeepAliveSwitcherState();
}

class _ExploreKeepAliveSwitcherState extends State<ExploreKeepAliveSwitcher>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    value: 1,
  );
  late final _curve = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );
  late final _opacity = Tween<double>(begin: 0.6, end: 1).animate(_curve);
  late Animation<Offset> _position = _offset(1);
  bool _disableAnimations = false;

  Animation<Offset> _offset(int direction) =>
      Tween<Offset>(begin: Offset(0.035 * direction, 0), end: Offset.zero)
          .animate(_curve);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _disableAnimations = MediaQuery.disableAnimationsOf(context);
    if (_disableAnimations) _controller.value = 1;
  }

  @override
  void didUpdateWidget(covariant ExploreKeepAliveSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.index != oldWidget.index ||
        widget.motionKey != oldWidget.motionKey) {
      _position = _offset(widget.index < oldWidget.index ? -1 : 1);
      if (widget.animate && !_disableAnimations) {
        _controller.forward(from: 0);
      } else {
        _controller.value = 1;
      }
    } else if (!widget.animate) {
      _controller.value = 1;
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipRect(
        child: FadeTransition(
          opacity: _opacity,
          child: SlideTransition(
            position: _position,
            child: _ActiveChildViewport(
              index: widget.index,
              children: [
                for (var i = 0; i < widget.children.length; i++)
                  KeyedSubtree(
                    key: widget.children[i].key ?? ValueKey(i),
                    child: TickerMode(
                      enabled: i == widget.index,
                      child: ExcludeFocus(
                        excluding: i != widget.index,
                        child: RepaintBoundary(child: widget.children[i]),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
}

class _ActiveChildViewport extends MultiChildRenderObjectWidget {
  const _ActiveChildViewport({required this.index, required super.children});

  final int index;

  @override
  MultiChildRenderObjectElement createElement() => _ActiveChildElement(this);

  @override
  _RenderActiveChildViewport createRenderObject(BuildContext context) =>
      _RenderActiveChildViewport(index);

  @override
  void updateRenderObject(
          BuildContext context, _RenderActiveChildViewport renderObject) =>
      renderObject.index = index;
}

class _ActiveChildElement extends MultiChildRenderObjectElement {
  _ActiveChildElement(_ActiveChildViewport super.widget);

  @override
  void debugVisitOnstageChildren(ElementVisitor visitor) {
    final selected = (widget as _ActiveChildViewport).index;
    var index = 0;
    visitChildren((child) {
      if (index++ == selected) visitor(child);
    });
  }
}

class _ActiveChildParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderActiveChildViewport extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _ActiveChildParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _ActiveChildParentData> {
  _RenderActiveChildViewport(this._index);

  int _index;
  set index(int value) {
    if (value == _index) return;
    _index = value;
    markNeedsLayout();
    markNeedsSemanticsUpdate();
  }

  RenderBox? get _activeChild {
    var child = firstChild;
    for (var i = 0; child != null && i < _index; i++) {
      child = childAfter(child);
    }
    return child;
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _ActiveChildParentData) {
      child.parentData = _ActiveChildParentData();
    }
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void performLayout() {
    assert(constraints.hasBoundedWidth && constraints.hasBoundedHeight,
        'ExploreKeepAliveSwitcher needs a bounded page viewport.');
    size = constraints.biggest;
    _activeChild?.layout(BoxConstraints.tight(size));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = _activeChild;
    if (child != null) context.paintChild(child, offset);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      _activeChild?.hitTest(result, position: position) ?? false;

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    final child = _activeChild;
    if (child != null) visitor(child);
  }
}

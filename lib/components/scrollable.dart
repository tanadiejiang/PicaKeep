import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:picakeep/foundation/app.dart';

const _fastAnimationDuration = Duration(milliseconds: 160);
const _desktopScrollbarDragDevices = <PointerDeviceKind>{
  PointerDeviceKind.touch,
  PointerDeviceKind.stylus,
  PointerDeviceKind.invertedStylus,
  PointerDeviceKind.trackpad,
  PointerDeviceKind.mouse,
  PointerDeviceKind.unknown,
};

class DesktopScrollbarDragBehavior extends StatelessWidget {
  const DesktopScrollbarDragBehavior({
    super.key,
    required this.child,
  });

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ScrollConfiguration(
      behavior: const MaterialScrollBehavior().copyWith(
        scrollbars: false,
        dragDevices: _desktopScrollbarDragDevices,
      ),
      child: child,
    );
  }
}

class SmoothCustomScrollView extends StatelessWidget {
  const SmoothCustomScrollView({
    super.key,
    required this.slivers,
    this.controller,
    this.cacheExtent,
    this.enableDesktopWheelSmoothing = true,
  });

  final ScrollController? controller;
  final List<Widget> slivers;
  final double? cacheExtent;
  final bool enableDesktopWheelSmoothing;

  @override
  Widget build(BuildContext context) {
    return SmoothScrollProvider(
      controller: controller,
      enableDesktopWheelSmoothing: enableDesktopWheelSmoothing,
      builder: (context, controller, physics) {
        return CustomScrollView(
          controller: controller,
          physics: physics,
          cacheExtent: cacheExtent,
          slivers: slivers,
        );
      },
    );
  }
}

class SmoothScrollProvider extends StatefulWidget {
  const SmoothScrollProvider({
    super.key,
    this.controller,
    this.enableDesktopWheelSmoothing = true,
    required this.builder,
  });

  final ScrollController? controller;
  final bool enableDesktopWheelSmoothing;
  final Widget Function(BuildContext, ScrollController, ScrollPhysics) builder;

  static bool get isMouseScroll => _SmoothScrollProviderState._isMouseScroll;

  @override
  State<SmoothScrollProvider> createState() => _SmoothScrollProviderState();
}

class _SmoothScrollProviderState extends State<SmoothScrollProvider> {
  late final ScrollController _controller;
  late final bool _ownsController;

  double? _futurePosition;

  static bool _isMouseScroll = App.isDesktop;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? ScrollController();
  }

  @override
  void dispose() {
    if (_ownsController) {
      _controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (App.isMacOS || !App.isDesktop || !widget.enableDesktopWheelSmoothing) {
      return widget.builder(
        context,
        _controller,
        const ClampingScrollPhysics(),
      );
    }

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) {
        _futurePosition = null;
        if (_isMouseScroll) {
          setState(() {
            _isMouseScroll = false;
          });
        }
      },
      onPointerSignal: (pointerSignal) {
        if (pointerSignal is! PointerScrollEvent) {
          return;
        }
        if (pointerSignal.kind == PointerDeviceKind.mouse && !_isMouseScroll) {
          setState(() {
            _isMouseScroll = true;
          });
        }
        if (!_isMouseScroll || !_controller.hasClients) {
          return;
        }

        final position = _controller.position;
        final currentLocation = position.pixels;
        _futurePosition ??= currentLocation;
        final factor = (_futurePosition! - currentLocation).abs() / 1600 + 1;
        _futurePosition =
            (_futurePosition! + pointerSignal.scrollDelta.dy * factor).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
        _controller.animateTo(
          _futurePosition!,
          duration: _fastAnimationDuration,
          curve: Curves.linear,
        );
      },
      child: widget.builder(
        context,
        _controller,
        _isMouseScroll
            ? const NeverScrollableScrollPhysics()
            : const ClampingScrollPhysics(),
      ),
    );
  }
}

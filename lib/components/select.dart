// ignore_for_file: depend_on_referenced_packages

import 'package:flutter/material.dart';

import '../foundation/widget_utils.dart';

const _fastAnimationDuration = Duration(milliseconds: 120);

class AnimatedContainer extends StatefulWidget {
  final bool open;
  final double width;
  final double height;
  final Widget child;
  final Duration duration;

  const AnimatedContainer(
      {super.key,
      required this.open,
      required this.width,
      required this.height,
      required this.child,
      this.duration = _fastAnimationDuration});

  @override
  State<AnimatedContainer> createState() => _AnimatedContainerState();
}

class _AnimatedContainerState extends State<AnimatedContainer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
    );

    _animation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );

    if (widget.open) {
      _controller.value = 1;
    }
  }

  @override
  void didUpdateWidget(AnimatedContainer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.open) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return ClipRect(
          child: Align(
            alignment: Alignment.centerLeft,
            heightFactor: widget.open ? 1 : 0,
            widthFactor: widget.open ? 1 : 0,
            child: SizedBox(
              width: widget.width,
              height: widget.height,
              child: widget.child,
            ),
          ),
        );
      },
    );
  }
}

class Select extends StatefulWidget {
  final String initialValue;
  final List<String> values;
  final List<String> titles;
  final double width;
  final bool enabled;
  final Widget? tailing;
  final Widget Function(String value)? leadingBuilder;
  final bool centerTextWhenPlain;
  final ValueChanged<String>? onChanged;

  const Select({
    super.key,
    this.width = 100,
    required this.initialValue,
    required this.values,
    required this.titles,
    this.enabled = true,
    this.tailing,
    this.leadingBuilder,
    this.centerTextWhenPlain = false,
    this.onChanged,
  });

  @override
  State<Select> createState() => _SelectState();
}

class _SelectState extends State<Select> {
  late String _currentValue;

  @override
  void initState() {
    super.initState();
    _currentValue = widget.initialValue;
  }

  @override
  void didUpdateWidget(Select oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_currentValue != widget.initialValue) {
      _currentValue = widget.initialValue;
    }
  }

  @override
  Widget build(BuildContext context) {
    int index = widget.values.indexOf(_currentValue);
    String title = index >= 0 && index < widget.titles.length
        ? widget.titles[index]
        : _currentValue;
    final currentLeading = widget.leadingBuilder?.call(_currentValue);
    final shouldCenterText =
        currentLeading == null &&
        widget.tailing == null &&
        widget.centerTextWhenPlain;

    return PopupMenuButton<String>(
      enabled: widget.enabled,
      initialValue: _currentValue,
      onSelected: (value) {
        setState(() {
          _currentValue = value;
        });
        widget.onChanged?.call(value);
      },
      offset: Offset(widget.width, -25),
      itemBuilder: (context) {
        return List.generate(widget.values.length, (index) {
          return PopupMenuItem<String>(
            value: widget.values[index],
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.leadingBuilder != null) ...[
                  widget.leadingBuilder!(widget.values[index]),
                  const SizedBox(width: 12),
                ],
                Flexible(child: Text(widget.titles[index])),
              ],
            ),
          );
        });
      },
      child: Container(
        width: widget.width,
        height: 40,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: context.colorScheme.outline),
        ),
        child: Row(
          children: [
            if (currentLeading != null) ...[
              currentLeading,
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: shouldCenterText ? TextAlign.center : TextAlign.start,
              ),
            ),
            if (widget.tailing != null) ...[
              const SizedBox(width: 10),
              widget.tailing!,
            ],
          ],
        ),
      ),
    );
  }
}

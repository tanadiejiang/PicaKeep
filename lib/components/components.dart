library components;

import 'dart:collection';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../foundation/app.dart';
import '../foundation/def.dart';
import '../foundation/ui_mode.dart';
import '../base.dart';

part 'consts.dart';
part 'message.dart';
part 'navigation_bar.dart';

Widget AnimatedContainerWidget({
  Key? key,
  Duration duration = const Duration(milliseconds: 200),
  VoidCallback? onEnd,
  double? height,
  double? width,
  Widget? child,
}) {
  return SizedBox(key: key, height: height, width: width, child: child);
}

class Button extends StatelessWidget {
  final VoidCallback? onPressed;
  final Widget? icon;
  final double? size;
  final Color? color;

  const Button({super.key, this.onPressed, this.icon, this.size, this.color});

  Button.icon({
    super.key,
    this.onPressed,
    this.icon,
    this.size,
    this.color,
  });

  @override
  Widget build(BuildContext context) => IconButton(
        onPressed: onPressed,
        icon: icon ?? const SizedBox(),
        iconSize: size,
        color: color,
      );
}

class Select extends StatefulWidget {
  final List<String> items;
  final List<String> values;
  final ValueChanged<String>? onChanged;
  final ValueChanged<int>? onChange;
  final dynamic initialValue;
  final int initialIndex;
  final String Function(String)? enumToString;
  final ValueChanged<String>? onSelected;

  const Select({
    super.key,
    this.items = const [],
    this.values = const [],
    this.onChanged,
    this.onChange,
    this.initialValue,
    this.initialIndex = 0,
    this.enumToString,
    this.onSelected,
  });

  @override
  State<Select> createState() => _SelectState();
}

class _SelectState extends State<Select> {
  @override
  Widget build(BuildContext context) => const SizedBox();
}

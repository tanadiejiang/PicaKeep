import 'package:flutter/material.dart';

class SmoothCustomScrollView extends StatelessWidget {
  const SmoothCustomScrollView({super.key, required this.slivers, this.controller});
  final ScrollController? controller;
  final List<Widget> slivers;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(controller: controller, slivers: slivers);
  }
}

import 'package:flutter/material.dart';

/// 播放一次的「打勾」动效：图标从左向右扫出。
///
/// 对齐原项目 `PicaComic/lib/components/select.dart` 的 `AnimatedCheckIcon` +
/// `AnimatedCheckWidget` 形态 —— 收藏夹单选后出现的那颗勾。
///
/// 实现上只用 `AnimatedBuilder` 监听进度，不引入额外状态：
/// 原项目用 `animation.addListener(() => setState(() {}))` 也能达到同样效果，
/// 但那样每帧都会整棵子树重建；`AnimatedBuilder` 只重建 builder 内的部分。
class AnimatedCheckIcon extends StatefulWidget {
  const AnimatedCheckIcon({super.key, this.size});

  final double? size;

  @override
  State<AnimatedCheckIcon> createState() => _AnimatedCheckIconState();
}

class _AnimatedCheckIconState extends State<AnimatedCheckIcon>
    with SingleTickerProviderStateMixin {
  static const _duration = Duration(milliseconds: 120);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _duration,
  )..forward();

  late final Animation<double> _animation =
      Tween<double>(begin: 0, end: 1).animate(_controller);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final iconSize = widget.size ?? IconTheme.of(context).size ?? 25;
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) => SizedBox(
        width: iconSize,
        height: iconSize,
        child: Align(
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: _animation.value,
            child: ClipRRect(
              child: Icon(
                Icons.check,
                size: iconSize,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

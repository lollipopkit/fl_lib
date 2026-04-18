import 'package:flutter/material.dart';

class FadeIn extends StatefulWidget {
  final Widget child;
  final Duration duration;

  const FadeIn({
    super.key,
    required this.child,
    this.duration = Durations.medium2,
  });

  @override
  State<FadeIn> createState() => _MyFadeInState();
}

class _MyFadeInState extends State<FadeIn> with SingleTickerProviderStateMixin {
  static final Animatable<double> _opacityTween = Tween<double>(
    begin: 0,
    end: 1,
  );

  late final _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );
  late final _animation = _controller.drive(_opacityTween);

  @override
  void initState() {
    super.initState();
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _animation,
      child: widget.child,
    );
  }
}

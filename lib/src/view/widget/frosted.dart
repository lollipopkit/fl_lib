import 'dart:ui' show ImageFilter;

import 'package:material_ui/material_ui.dart';

/// A surface of [shape] that blurs what is drawn behind it, for controls
/// floating over content: the content stays legible through them.
///
/// Ink of buttons inside reaches the surface: it is a transparent [Material].
class Frosted extends StatelessWidget {
  const Frosted({
    super.key,
    required this.child,
    this.shape = const StadiumBorder(),
    this.color,
    this.sigma = 20,
  });

  final Widget child;
  final ShapeBorder shape;

  /// Laid over the blur; the theme's high surface, translucent, by default.
  final Color? color;
  final double sigma;

  @override
  Widget build(BuildContext context) {
    final tint =
        color ??
        Theme.of(context).colorScheme.surfaceContainerHigh.withValues(alpha: .6);
    return ClipPath(
      clipper: ShapeBorderClipper(
        shape: shape,
        textDirection: Directionality.maybeOf(context),
      ),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: Material(
          type: MaterialType.transparency,
          shape: shape,
          child: Ink(
            decoration: ShapeDecoration(color: tint, shape: shape),
            child: child,
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

/// A customizable card widget with rounded corners and no elevation.
///
/// This widget wraps a [Card] with consistent styling including
/// clipping and customizable border radius and color.
class CardX extends StatelessWidget {
  /// The widget to display inside the card.
  final Widget child;

  /// The background color of the card.
  /// If null, uses the default card color from the theme.
  final Color? color;

  /// The border radius of the card.
  /// If null, uses [borderRadius] (13px circular radius).
  final BorderRadius? radius;

  /// The clip behavior of the card.
  /// Defaults to [Clip.hardEdge] for better performance on low-end devices.
  final Clip clipBehavior;

  /// Creates a [CardX] widget.
  ///
  /// The [child] parameter is required.
  const CardX({
    super.key,
    required this.child,
    this.color,
    this.radius,
    this.clipBehavior = Clip.hardEdge,
  });

  /// Default border radius with 13px circular corners.
  static const borderRadius = BorderRadius.all(Radius.circular(13));

  @override
  String toString({DiagnosticLevel minLevel = DiagnosticLevel.info}) {
    return switch (minLevel) {
      DiagnosticLevel.debug => 'CardX(child: $child, color: $color, radius: $radius)',
      _ => 'CardX(${child.runtimeType})',
    };
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      key: key,
      clipBehavior: clipBehavior,
      color: color,
      shape: RoundedRectangleBorder(
        borderRadius: radius ?? borderRadius,
      ),
      elevation: 0,
      child: child,
    );
  }
}

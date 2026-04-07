import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';

/// A circular progress indicator with customizable size and padding.
///
/// This widget provides a consistent way to display loading indicators
/// with predefined sizes (small, medium, large) or custom dimensions.
final class SizedLoading extends StatelessWidget {
  /// The total size of the widget including padding.
  final double size;

  /// The padding around the circular progress indicator.
  final double padding;

  /// The color animation for the progress indicator.
  final Animation<Color>? valueColor;

  /// Loading widget builder.
  final Widget Function(BuildContext context, Animation<Color>? valueColor) builder;

  /// Creates a [SizedLoading] widget.
  ///
  /// - [size] is the total size of the widget including padding
  /// - [padding] defaults to 7.0
  /// - [valueColor] if null, uses the primary color with AlwaysStoppedAnimation
  /// - [builder] is a function that builds the loading widget, defaults to [linearBuilder].
  const SizedLoading(this.size, {this.padding = 7, this.valueColor, this.builder = linearBuilder, super.key});

  static Widget linearBuilder(BuildContext context, Animation<Color>? valueColor) {
    return LinearProgressIndicator(
      valueColor: valueColor ?? AlwaysStoppedAnimation(Theme.of(context).colorScheme.primary),
    );
  }

  static Widget circularBuilder(BuildContext context, Animation<Color>? valueColor) {
    return CircularProgressIndicator(
      valueColor: valueColor ?? AlwaysStoppedAnimation(Theme.of(context).colorScheme.primary),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size - 2 * padding,
      height: size - 2 * padding,
      child: Center(child: builder(context, valueColor)).paddingAll(padding),
    ).paddingAll(3);
  }

  /// Small sized loading indicator (25x25).
  static const small = SizedLoading(25);

  /// Medium sized loading indicator (45x45).
  static const medium = SizedLoading(45);

  /// Large sized loading indicator (65x65).
  static const large = SizedLoading(65);
}

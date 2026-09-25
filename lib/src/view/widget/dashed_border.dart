import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';

/// A dashed outline around [child], with rounded corners.
///
/// For a place that holds nothing yet — the row at the end of a list that
/// adds to it. A solid outline reads as one more item; a dashed one as room
/// for one. Flutter's own `Border` draws only solid lines.
class DashedBorder extends StatelessWidget {
  const DashedBorder({
    super.key,
    required this.child,
    this.color,
    this.radius = 13,
    this.strokeWidth = 1,
    this.dash = 4,
    this.gap = 3,
  });

  final Widget child;

  /// Defaults to the theme's `outlineVariant`.
  final Color? color;
  final double radius;
  final double strokeWidth;

  /// Length of one dash, and of the space after it, along the outline.
  final double dash;
  final double gap;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DashedRRectPainter(
        color: color ?? Theme.of(context).colorScheme.outlineVariant,
        radius: radius,
        strokeWidth: strokeWidth,
        dash: dash,
        gap: gap,
      ),
      child: child,
    );
  }
}

class _DashedRRectPainter extends CustomPainter {
  const _DashedRRectPainter({
    required this.color,
    required this.radius,
    required this.strokeWidth,
    required this.dash,
    required this.gap,
  });

  final Color color;
  final double radius;
  final double strokeWidth;
  final double dash;
  final double gap;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || dash <= 0) return;
    // Inset by half the stroke, so the line sits inside the box as a
    // `Border` would, not half outside it.
    final inset = strokeWidth / 2;
    final rect = (Offset.zero & size).deflate(inset);
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)));
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    for (final PathMetric metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        canvas.drawPath(metric.extractPath(d, d + dash), paint);
        d += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedRRectPainter old) =>
      old.color != color ||
      old.radius != radius ||
      old.strokeWidth != strokeWidth ||
      old.dash != dash ||
      old.gap != gap;
}

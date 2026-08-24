import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Dims everything but one rectangle, and says what is in it.
///
/// For the parts of an interface that announce nothing: a long press that
/// opens a menu, a drag that resizes a pane. A tooltip cannot introduce those
/// — it only appears once you are already on the thing — and a page of release
/// notes is read somewhere else, away from the control it describes.
///
/// One rectangle, not a tour. Something that has to be explained in five steps
/// is a design problem rather than a documentation one, and every step is
/// another thing between the user and the app they opened.
///
/// The caller measures. [rectInOverlay] turns a widget's `GlobalKey` context
/// into the rectangle this wants, in the same coordinates.
abstract final class SpotlightGuide {
  /// Puts the overlay up and completes when it comes down.
  ///
  /// [spot] is in the root overlay's coordinates. [caption] is handed the
  /// dismissal so it can carry a real button rather than one that looks
  /// tappable because the whole screen happens to be.
  ///
  /// A caller writing a "seen it" flag should write it on the returned future
  /// and nowhere else: there is no overlay to dismiss when the context has
  /// none, and the flag would otherwise be set for a guide that never showed.
  ///
  /// [margin] is room around [spot], so the highlight is not flush against
  /// what it points at. It is also what puts the corners off screen when the
  /// target reaches an edge, where a rounded rectangle would otherwise read as
  /// a floating card rather than a hole.
  static Future<void> show(
    BuildContext context, {
    required Rect spot,
    required Widget Function(BuildContext context, VoidCallback dismiss)
    caption,
    double radius = 18,
    EdgeInsets margin = const EdgeInsets.all(6),
    Color? scrim,
  }) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return Future.value();

    final done = Completer<void>();
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => _Spotlight(
        spot: margin.inflateRect(spot),
        radius: radius,
        caption: caption,
        scrim: scrim ?? Colors.black.withValues(alpha: 0.72),
        onGone: () {
          if (done.isCompleted) return;
          entry.remove();
          done.complete();
        },
      ),
    );
    overlay.insert(entry);
    return done.future;
  }
}

class _Spotlight extends StatefulWidget {
  const _Spotlight({
    required this.spot,
    required this.radius,
    required this.caption,
    required this.scrim,
    required this.onGone,
  });

  final Rect spot;
  final double radius;
  final Widget Function(BuildContext context, VoidCallback dismiss) caption;
  final Color scrim;
  final VoidCallback onGone;

  @override
  State<_Spotlight> createState() => _SpotlightState();
}

class _SpotlightState extends State<_Spotlight>
    with SingleTickerProviderStateMixin {
  late final _ctrl = AnimationController(
    vsync: this,
    duration: Durations.medium2,
  )..forward();

  bool _leaving = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _dismiss() async {
    // A second tap while it is fading out would take the entry away twice.
    if (_leaving) return;
    _leaving = true;
    await _ctrl.reverse();
    widget.onGone();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // Opaque: the point of the scrim is that nothing under it can be reached
      // while it is up, including the control being pointed at.
      behavior: HitTestBehavior.opaque,
      onTap: _dismiss,
      child: FadeTransition(
        opacity: CurvedAnimation(parent: _ctrl, curve: Curves.easeOut),
        child: LayoutBuilder(
          builder: (_, cons) => Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _HolePainter(
                    spot: widget.spot,
                    radius: widget.radius,
                    scrim: widget.scrim,
                    edge: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
              _positionCaption(cons.biggest),
            ],
          ),
        ),
      ),
    );
  }

  /// The caption goes in whichever margin around the spot has the most room.
  ///
  /// Four sides rather than "above unless it is near the top": a rail is a tall
  /// column against one edge and a bottom bar is a wide strip against another,
  /// and the free space is on a different axis in each.
  Widget _positionCaption(Size size) {
    final spot = widget.spot;
    final above = spot.top;
    final below = size.height - spot.bottom;
    final before = spot.left;
    final after = size.width - spot.right;

    final child = Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Builder(builder: (ctx) => widget.caption(ctx, _dismiss)),
      ),
    );

    if (math.max(above, below) >= math.max(before, after)) {
      final onTop = above >= below;
      return Positioned(
        left: 0,
        right: 0,
        top: onTop ? 0 : spot.bottom,
        height: onTop ? above : below,
        child: child,
      );
    }
    final onLeft = before >= after;
    return Positioned(
      top: 0,
      bottom: 0,
      left: onLeft ? 0 : spot.right,
      width: onLeft ? before : after,
      child: child,
    );
  }
}

class _HolePainter extends CustomPainter {
  const _HolePainter({
    required this.spot,
    required this.radius,
    required this.scrim,
    required this.edge,
  });

  final Rect spot;
  final double radius;
  final Color scrim;
  final Color edge;

  @override
  void paint(Canvas canvas, Size size) {
    final hole = RRect.fromRectAndRadius(spot, Radius.circular(radius));
    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(Offset.zero & size),
        Path()..addRRect(hole),
      ),
      Paint()..color = scrim,
    );
    canvas.drawRRect(
      hole,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = edge,
    );
  }

  @override
  bool shouldRepaint(_HolePainter old) =>
      old.spot != spot ||
      old.radius != radius ||
      old.scrim != scrim ||
      old.edge != edge;
}

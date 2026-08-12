import 'package:flutter/material.dart';

/// A copy of a widget moving from one rectangle to another across an overlay.
///
/// [Hero] is the framework's answer to the same question, and only answers it
/// for route transitions: a hero flight is started by a navigator push. A list
/// that changes shape in place pushes nothing, so the widget that appears to
/// move has to be moved by hand — which is all this is. The caller says where
/// something was and where it now is; this puts a copy in the air between the
/// two and takes it away again.
///
/// The caller measures, because only the caller knows which two widgets are
/// the same thing. See [rectInOverlay] for the measuring.
class OverlayFlight {
  OverlayFlight._(this._entry, this._controller, this._onEnd);

  final OverlayEntry _entry;
  final AnimationController _controller;
  final VoidCallback? _onEnd;
  bool _done = false;

  /// Puts a copy in [overlay] and moves it from [from] to [to].
  ///
  /// Rectangles are in [overlay]'s coordinates. Children are laid out at the
  /// tweened rectangle rather than scaled into it, so a card that lands as a
  /// narrower row reflows on the way instead of arriving distorted — the same
  /// choice [Hero] makes.
  ///
  /// [child] is what it becomes. [departing] is what it was: when the two ends
  /// look different, giving both cross-fades between them along the way, so
  /// the change of form happens during the move rather than as a jump at one
  /// end of it. Leave it null when the two look the same.
  ///
  /// [onEnd] runs when the copy leaves the screen, whether it arrived or was
  /// cancelled, so it is where a caller unhides the real widget.
  static OverlayFlight launch({
    required OverlayState overlay,
    required TickerProvider vsync,
    required Rect from,
    required Rect to,
    required Widget child,
    Widget? departing,
    Duration duration = Durations.medium3,
    Curve curve = Curves.fastOutSlowIn,
    VoidCallback? onEnd,
  }) {
    final controller = AnimationController(vsync: vsync, duration: duration);
    final animation = CurvedAnimation(parent: controller, curve: curve);
    // The old form goes first and the new arrives after, overlapping in the
    // middle. Fading them in step would show both at half strength through
    // the whole flight, which reads as a smear rather than a change.
    final departingOpacity = CurvedAnimation(
      parent: controller,
      curve: const Interval(0, 0.4, curve: Curves.easeOut),
    );
    final arrivingOpacity = CurvedAnimation(
      parent: controller,
      curve: const Interval(0.25, 1, curve: Curves.easeIn),
    );

    final entry = OverlayEntry(
      builder: (_) => AnimatedBuilder(
        animation: animation,
        builder: (_, _) => Positioned.fromRect(
          rect: Rect.lerp(from, to, animation.value)!,
          // Scenery. A tap during the flight belongs to whatever the copy
          // happens to be passing over.
          child: IgnorePointer(
            child: Material(
              type: MaterialType.transparency,
              // Both ends are laid out at a rectangle that is neither's
              // natural size for most of the trip, so whatever spills has to
              // be cut rather than painted over the rest of the screen.
              child: ClipRect(
                child: Stack(
                  fit: StackFit.expand,
                  children: _forms(
                    departing: departing,
                    arriving: child,
                    goneBy: departingOpacity.value,
                    arrivedBy: arrivingOpacity.value,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final flight = OverlayFlight._(entry, controller, onEnd);
    overlay.insert(entry);
    // Arrival only. A stopped ticker never resolves this future — `_cancel`
    // reports to the `orCancel` completer alone — so [cancel] finishes by
    // hand rather than waiting for something that will not come.
    controller.forward().whenComplete(flight._finish);
    return flight;
  }

  /// The forms that are contributing to this frame, and only those.
  ///
  /// A fully transparent child is skipped when painting but still laid out,
  /// and the rectangle changes every frame — so keeping the form that has
  /// already gone would lay out a card's worth of charts for the whole trip
  /// to draw nothing. Dropping it costs one rebuild at the moment it goes.
  ///
  /// The two intervals overlap, so there is never a frame with neither.
  static List<Widget> _forms({
    required Widget? departing,
    required Widget arriving,
    required double goneBy,
    required double arrivedBy,
  }) {
    if (departing == null) return [arriving];
    return [
      if (goneBy < 1) Opacity(opacity: 1 - goneBy, child: departing),
      if (arrivedBy > 0) Opacity(opacity: arrivedBy, child: arriving),
    ];
  }

  /// Whether the copy is still on screen.
  bool get isFlying => !_done;

  /// Takes the copy off screen now.
  ///
  /// The `onEnd` given to [launch] still runs: a caller that hid the real
  /// widget for the duration has to be told to stop, and cutting a flight
  /// short is not a reason to leave a hole where the widget should be.
  void cancel() {
    // A finished flight is a common thing to be handed: a caller that cancels
    // whatever might be in the air rarely knows whether anything is.
    if (_done) return;
    _controller.stop();
    _finish();
  }

  void _finish() {
    if (_done) return;
    _done = true;
    _entry.remove();
    _controller.dispose();
    _onEnd?.call();
  }
}

/// [context]'s box in [overlay]'s coordinates, or null when it has none —
/// unmounted, or built but not laid out.
///
/// A widget kept in the layout but not painted (`Visibility` with
/// `maintainSize`) measures fine, which is how a flight can know where it is
/// going before the thing it is going to is shown.
Rect? rectInOverlay(BuildContext? context, OverlayState overlay) {
  final box = context?.findRenderObject();
  if (box is! RenderBox || !box.hasSize) return null;
  final overlayBox = overlay.context.findRenderObject();
  if (overlayBox is! RenderBox || !overlayBox.hasSize) return null;
  return box.localToGlobal(Offset.zero, ancestor: overlayBox) & box.size;
}

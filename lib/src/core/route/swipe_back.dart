import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

/// Android's predictive back — the page shrinks and follows the finger, the
/// one below shows through — on a platform with no such system gesture: a
/// swipe from the left edge drives it.
///
/// The swipe is turned into the events Android sends on
/// [SystemChannels.backGesture], so the gesture, the route and the
/// transition are [PredictiveBackPageTransitionsBuilder]'s own, not a copy of
/// them. For iOS and macOS, in place of Cupertino's transition; Android has
/// the real one.
class SwipeBackPageTransitionsBuilder extends PageTransitionsBuilder {
  const SwipeBackPageTransitionsBuilder({this.fallbackColor});

  /// See [PredictiveBackPageTransitionsBuilder.fallbackColor].
  final Color? fallbackColor;

  /// How far in from the left edge a swipe may start, beyond the safe area.
  static const double edgeWidth = 20;

  /// A swipe let go past this part of the width goes back; short of it, the
  /// page returns.
  static const double commitFraction = 0.35;

  /// A fling faster than this (logical pixels a second) decides by its
  /// direction, however far it went.
  static const double flingVelocity = 700;

  PredictiveBackPageTransitionsBuilder get _inner =>
      PredictiveBackPageTransitionsBuilder(fallbackColor: fallbackColor);

  @override
  Duration get transitionDuration => _inner.transitionDuration;

  @override
  DelegatedTransitionBuilder? get delegatedTransition => _inner.delegatedTransition;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // As the route's own detector decides: a back that would not go through
    // (a pop scope, an animation still running) is no gesture at all.
    return EdgeSwipeBack(
      enabled: () => route.isCurrent && route.popGestureEnabled,
      child: _inner.buildTransitions(route, context, animation, secondaryAnimation, child),
    );
  }
}

/// The left edge of [child], where a horizontal drag is a back gesture: sent
/// as Android's, which a route's transition follows, or, with [onEnd], told
/// to the caller to follow — for a page no route below it pops, such as the
/// root of a pane that closes on back.
class EdgeSwipeBack extends StatefulWidget {
  const EdgeSwipeBack({super.key, required this.enabled, this.onProgress, this.onEnd, required this.child});

  /// Whether a swipe starting now is a back.
  final bool Function() enabled;

  /// How far the swipe has gone, 0 to 1, with [onEnd].
  final ValueChanged<double>? onProgress;

  /// The swipe let go: [commit] when it goes back. Set, it is told here in
  /// place of Android's events.
  final void Function({required bool commit})? onEnd;
  final Widget child;

  @override
  State<EdgeSwipeBack> createState() => _EdgeSwipeState();
}

class _EdgeSwipeState extends State<EdgeSwipeBack> {
  late final _drag = HorizontalDragGestureRecognizer(debugOwner: this)
    ..onStart = _onStart
    ..onUpdate = _onUpdate
    ..onEnd = _onEnd
    ..onCancel = _onCancel;

  /// A back gesture this drag started.
  var _active = false;

  @override
  void dispose() {
    if (_active) {
      if (widget.onEnd case final onEnd?) {
        onEnd(commit: false);
      } else {
        _send('cancelBackGesture');
      }
    }
    _drag.dispose();
    super.dispose();
  }

  /// One of the calls Android makes on [SystemChannels.backGesture].
  static void _send(String method, [Map<String, Object?>? args]) {
    final data = SystemChannels.backGesture.codec.encodeMethodCall(MethodCall(method, args));
    ServicesBinding.instance.channelBuffers.push(SystemChannels.backGesture.name, data, (_) {});
  }

  /// [global] where the finger is; [x] how far it is into the page (the
  /// strip this listens on starts at its left edge).
  Map<String, Object?> _event(Offset global, double x) => {
    'touchOffset': [global.dx, global.dy],
    'progress': _progress(x),
    'swipeEdge': SwipeEdge.left.index,
  };

  double _progress(double x) => (x / context.size!.width).clamp(0.0, 1.0);

  void _onStart(DragStartDetails d) {
    if (!widget.enabled()) return;
    _active = true;
    if (widget.onEnd == null) {
      _send('startBackGesture', _event(d.globalPosition, d.localPosition.dx));
    } else {
      widget.onProgress?.call(_progress(d.localPosition.dx));
    }
  }

  void _onUpdate(DragUpdateDetails d) {
    if (!_active) return;
    if (widget.onEnd == null) {
      _send('updateBackGestureProgress', _event(d.globalPosition, d.localPosition.dx));
    } else {
      widget.onProgress?.call(_progress(d.localPosition.dx));
    }
  }

  void _onEnd(DragEndDetails d) {
    if (!_active) return;
    _active = false;
    final v = d.velocity.pixelsPerSecond.dx;
    final progress = _progress(d.localPosition.dx);
    final commit = v.abs() >= SwipeBackPageTransitionsBuilder.flingVelocity
        ? v > 0
        : progress >= SwipeBackPageTransitionsBuilder.commitFraction;
    if (widget.onEnd case final onEnd?) return onEnd(commit: commit);
    _send(commit ? 'commitBackGesture' : 'cancelBackGesture');
  }

  void _onCancel() {
    if (!_active) return;
    _active = false;
    if (widget.onEnd case final onEnd?) return onEnd(commit: false);
    _send('cancelBackGesture');
  }

  @override
  Widget build(BuildContext context) {
    final dragAreaWidth = SwipeBackPageTransitionsBuilder.edgeWidth + MediaQuery.paddingOf(context).left;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        widget.child,
        PositionedDirectional(
          start: 0,
          width: dragAreaWidth,
          top: 0,
          bottom: 0,
          child: Listener(
            onPointerDown: (e) {
              if (widget.enabled()) _drag.addPointer(e);
            },
            behavior: HitTestBehavior.translucent,
          ),
        ),
      ],
    );
  }
}

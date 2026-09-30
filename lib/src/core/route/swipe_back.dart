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
    return _EdgeSwipe(
      route: route,
      child: _inner.buildTransitions(route, context, animation, secondaryAnimation, child),
    );
  }
}

/// The left edge of a page, where a horizontal drag is a back gesture.
class _EdgeSwipe extends StatefulWidget {
  const _EdgeSwipe({required this.route, required this.child});

  final PageRoute<dynamic> route;
  final Widget child;

  @override
  State<_EdgeSwipe> createState() => _EdgeSwipeState();
}

class _EdgeSwipeState extends State<_EdgeSwipe> {
  late final _drag = HorizontalDragGestureRecognizer(debugOwner: this)
    ..onStart = _onStart
    ..onUpdate = _onUpdate
    ..onEnd = _onEnd
    ..onCancel = _onCancel;

  /// A back gesture this drag started.
  var _active = false;

  @override
  void dispose() {
    if (_active) _send('cancelBackGesture');
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
    final route = widget.route;
    // As the route's own detector decides: a back that would not go through
    // (a pop scope, an animation still running) is no gesture at all.
    if (!route.isCurrent || !route.popGestureEnabled) return;
    _active = true;
    _send('startBackGesture', _event(d.globalPosition, d.localPosition.dx));
  }

  void _onUpdate(DragUpdateDetails d) {
    if (_active) _send('updateBackGestureProgress', _event(d.globalPosition, d.localPosition.dx));
  }

  void _onEnd(DragEndDetails d) {
    if (!_active) return;
    _active = false;
    final v = d.velocity.pixelsPerSecond.dx;
    final progress = _progress(d.localPosition.dx);
    final commit = v.abs() >= SwipeBackPageTransitionsBuilder.flingVelocity
        ? v > 0
        : progress >= SwipeBackPageTransitionsBuilder.commitFraction;
    _send(commit ? 'commitBackGesture' : 'cancelBackGesture');
  }

  void _onCancel() {
    if (!_active) return;
    _active = false;
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
              if (widget.route.isCurrent && widget.route.popGestureEnabled) _drag.addPointer(e);
            },
            behavior: HitTestBehavior.translucent,
          ),
        ),
      ],
    );
  }
}

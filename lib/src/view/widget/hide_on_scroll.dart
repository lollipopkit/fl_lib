import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Slides [child] out of the way while the page is being scrolled forward, and
/// brings it back the moment it is scrolled the other way.
///
/// For something that floats over a page it does not belong to — a toolbar
/// above the content rather than beside it. Reading is scrolling forward, so
/// that is when the thing in the way should get out of it; reaching for the
/// toolbar starts with scrolling back, so that is when it should return.
///
/// It also arrives rather than simply being there: the first frames are spent
/// off the edge it sits on, and it comes up from there once the page it floats
/// over has settled. Same motion as the scroll, so a bar has one way of being
/// on screen and one way of being off it whatever put it in either state.
///
/// Not [AutoHide], which hides on a timer and shows on any scroll at all. That
/// suits a control that is in the way only while something is happening; this
/// suits one that is in the way whenever you are reading past it.
class HideOnScroll extends StatefulWidget {
  const HideOnScroll({
    super.key,
    required this.controller,
    required this.child,
    this.duration = Durations.short4,
    this.curve = Curves.easeOutCubic,
    this.enterDuration = Durations.medium2,
    this.enterCurve = Curves.easeOutBack,
    this.enterDelay = Durations.medium1,
  });

  final ScrollController controller;
  final Widget child;

  final Duration duration;
  final Curve curve;

  /// How long the arrival takes.
  ///
  /// Longer than [duration], which answers a finger and has to keep up with
  /// one. Arriving answers nothing, so it can afford to be seen.
  final Duration enterDuration;

  /// The arrival's motion.
  ///
  /// Allowed to overshoot — that is what makes the bar land with some spring
  /// rather than slide to a stop. Only the slide uses it, never the fade: an
  /// opacity past 1 is an assertion, not a brighter bar.
  final Curve enterCurve;

  /// How long the bar waits before arriving.
  ///
  /// Not zero, because the commonest thing to float over is a page that is
  /// itself still transitioning in, and a bar that lands while the page under
  /// it is still moving is not seen at all.
  final Duration enterDelay;

  @override
  State<HideOnScroll> createState() => _HideOnScrollState();
}

class _HideOnScrollState extends State<HideOnScroll> {
  bool _visible = true;

  /// Whether the bar has arrived. False for the first frames, which is what
  /// gives it somewhere to arrive from.
  bool _entered = false;

  /// Whether the change being animated is the arrival rather than a scroll.
  /// Decides which of the two motions above is used.
  bool _entering = false;

  Timer? _enterTimer;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onScroll);
    _enterTimer = Timer(widget.enterDelay, () {
      if (!mounted) return;
      setState(() {
        _entered = true;
        _entering = true;
      });
    });
  }

  @override
  void didUpdateWidget(HideOnScroll old) {
    super.didUpdateWidget(old);
    if (old.controller == widget.controller) return;
    old.controller.removeListener(_onScroll);
    widget.controller.addListener(_onScroll);
  }

  @override
  void dispose() {
    _enterTimer?.cancel();
    widget.controller.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() {
    if (!mounted || !widget.controller.hasClients) return;
    final position = widget.controller.position;

    // The direction the user dragged, not the direction the offset moved: a
    // list settling after a fling, or being scrolled by anything other than a
    // finger, is not someone asking for this.
    final next = switch (position.userScrollDirection) {
      ScrollDirection.reverse => false,
      ScrollDirection.forward => true,
      // Nothing new was asked for.
      ScrollDirection.idle => _visible,
    };

    // Always there at the top, whatever the last drag was. A page that opens
    // scrolled to its start opens with this on screen.
    final visible = next || position.pixels <= position.minScrollExtent;
    if (visible == _visible) return;
    // A scroll during the arrival takes it over: the finger is the newer
    // instruction, and its motion is the one that has to keep up.
    setState(() {
      _visible = visible;
      _entering = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    // A scroll away from the top before the arrival is due means the bar was
    // wanted out of the way before it ever came in. So it stays out, rather
    // than arriving on top of a page already being read.
    final shown = _entered && _visible;
    final duration = _entering ? widget.enterDuration : widget.duration;

    return AnimatedSlide(
      // Its own height, so it ends up entirely past whichever edge it sits on.
      offset: shown ? Offset.zero : const Offset(0, 1),
      duration: duration,
      curve: _entering ? widget.enterCurve : widget.curve,
      child: AnimatedOpacity(
        opacity: shown ? 1 : 0,
        duration: duration,
        // Never [enterCurve] — see it.
        curve: widget.curve,
        // Out of the way means out of the way: a hidden toolbar sliding past
        // the bottom of the window must not eat taps on its way there.
        child: IgnorePointer(ignoring: !shown, child: widget.child),
      ),
    );
  }
}

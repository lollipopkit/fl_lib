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
  });

  final ScrollController controller;
  final Widget child;

  final Duration duration;
  final Curve curve;

  @override
  State<HideOnScroll> createState() => _HideOnScrollState();
}

class _HideOnScrollState extends State<HideOnScroll> {
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onScroll);
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
    setState(() => _visible = visible);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSlide(
      // Its own height, so it ends up entirely past whichever edge it sits on.
      offset: _visible ? Offset.zero : const Offset(0, 1),
      duration: widget.duration,
      curve: widget.curve,
      child: AnimatedOpacity(
        opacity: _visible ? 1 : 0,
        duration: widget.duration,
        curve: widget.curve,
        // Out of the way means out of the way: a hidden toolbar sliding past
        // the bottom of the window must not eat taps on its way there.
        child: IgnorePointer(ignoring: !_visible, child: widget.child),
      ),
    );
  }
}

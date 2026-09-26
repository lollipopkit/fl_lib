import 'package:flutter/material.dart';

/// Rows that unfold under the header that opened them, and fold away again.
///
/// For the disclosure a form is made of: a row saying what a thing is, and its
/// own rows under it while it is open. Laid out as siblings, a plain
/// `if (open) ...[rows]` puts them on screen between one frame and the next —
/// everything below jumps down, and nothing says how it got there.
///
/// Not [ExpandableTile], which draws the header as well and is a card per row.
/// Not [AnimatedColumn], which animates children arriving and leaving a
/// filtered collection: what is here does not leave, it is folded away, and
/// the same rows come back when it is opened again — so there is nothing for a
/// key to track, and no list to keep in step.
///
/// The children are dropped once fully closed — not merely hidden, or an
/// `Offstage` would still build them, watching providers and starting requests
/// for rows nobody can see. They are kept for the length of the fold, so what
/// shrinks away is the rows themselves rather than an empty gap closing where
/// they were. A `SizeTransition` driven by a controller rather than an
/// `AnimatedSize` for that reason: `AnimatedSize` cannot keep what it was
/// given, so it has nothing left to paint on the way out.
///
/// State inside a child does not survive a fold. A control that holds
/// something across one — a drafted change, a typed filter — belongs to the
/// page, which keeps it while the row that draws it comes and goes.
class Reveal extends StatefulWidget {
  const Reveal({
    super.key,
    required this.open,
    required this.children,
    this.duration = Durations.short3,
    this.curve = Curves.easeOutCubic,
    this.reverseCurve = Curves.easeInCubic,
  });

  /// Whether the rows are showing. A change to this unfolds or folds them.
  final bool open;

  /// The rows, in order.
  ///
  /// Each brings its own spacing. Nothing is added between them: what these
  /// are is a list of the caller's own rows, which already sit apart the way
  /// every other row on the pane does.
  final List<Widget> children;

  /// The length of a fold, subject to the platform's reduced-motion setting.
  final Duration duration;

  /// Opening, which presents something, and closing, which acknowledges it —
  /// as the app's other movements are drawn.
  final Curve curve;
  final Curve reverseCurve;

  @override
  State<Reveal> createState() => _RevealState();
}

class _RevealState extends State<Reveal> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: widget.open ? 1 : 0,
  )..addStatusListener((_) {
      // The one thing a status change decides is [_closed], and that is read
      // during build.
      if (mounted) setState(() {});
    });

  late final CurvedAnimation _curve = CurvedAnimation(
    parent: _ctrl,
    curve: widget.curve,
    reverseCurve: widget.reverseCurve,
  );

  /// Closed *and* no longer animating — the rows are not on screen at all.
  ///
  /// Not the same as `!open`: the fold is still running for a while after the
  /// header says it is closed, and dropping the rows then would leave the gap
  /// closing with nothing in it.
  bool get _closed => !widget.open && _ctrl.isDismissed;

  /// Zero under the platform's reduced-motion setting, as the library's other
  /// movements are: the rows are there or not, with nothing travelling.
  void _syncDuration() {
    _ctrl.duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : widget.duration;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncDuration();
  }

  @override
  void didUpdateWidget(Reveal old) {
    super.didUpdateWidget(old);
    if (widget.duration != old.duration) _syncDuration();
    if (widget.open == old.open) return;
    if (widget.open) {
      _ctrl.forward();
    } else {
      _ctrl.reverse();
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_closed) return const SizedBox.shrink();
    return SizeTransition(
      sizeFactor: _curve,
      // Anchored to the top, so the rows unroll downwards from under the
      // header instead of growing out of their own middle.
      alignment: Alignment.topCenter,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: widget.children,
      ),
    );
  }
}

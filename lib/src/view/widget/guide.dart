import 'dart:async';
import 'dart:math' as math;

import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';

/// One thing a walkthrough has to say.
final class GuideStep {
  const GuideStep({this.title, required this.body, this.spot});

  /// Omitted for a guide that is one sentence: a heading over a single line
  /// says it twice.
  final String? title;

  final String body;

  /// The rectangle left lit, in the coordinates of the [GuideView] drawing it.
  ///
  /// Null dims everything the view covers, which is what a caller does when
  /// the thing being pointed at is *outside* that area — see [GuideView] for
  /// why that is a real case rather than a fallback.
  final Rect? spot;
}

/// A walkthrough's scrim and card, over whatever this is mounted in.
///
/// A widget and not an overlay of its own, because where the scrim stops is
/// the caller's decision. The terminal's key walkthrough covers the terminal
/// and no further — the keys it is describing are the `Scaffold`'s bottom bar,
/// outside that body, and so stay lit without a hole being cut for them. A
/// caller that does want it over the whole window mounts it with
/// [GuideOverlay.show] and gets a hole instead.
///
/// The card sits beside the lit rectangle when there is one, in whichever
/// margin around it has the most room, and at the bottom when there is not.
class GuideView extends StatelessWidget {
  const GuideView({
    super.key,
    required this.steps,
    required this.step,
    required this.onStep,
    required this.onDone,
    this.scrim,
    this.spotRadius = 18,
    this.spotMargin = const EdgeInsets.all(6),
  });

  final List<GuideStep> steps;

  /// Which step is showing, indexing [steps].
  final int step;

  final ValueChanged<int> onStep;

  /// Finished or dismissed — both mean the same thing to the caller, which is
  /// that this does not come back.
  final VoidCallback onDone;

  final Color? scrim;

  final double spotRadius;

  /// Room around [GuideStep.spot], so the highlight is not flush against what
  /// it points at. It is also what puts the corners off screen when the target
  /// reaches an edge, where a rounded rectangle would otherwise read as a
  /// floating card rather than a hole.
  final EdgeInsets spotMargin;

  @override
  Widget build(BuildContext context) {
    final current = steps[step];
    final last = step == steps.length - 1;
    final spot = current.spot.nullOr(spotMargin.inflateRect);
    final colour = scrim ?? Colors.black.withValues(alpha: 0.62);
    final next = last ? onDone : () => onStep(step + 1);

    final card = _GuideCard(
      step: step,
      count: steps.length,
      title: current.title,
      body: current.body,
      onNext: next,
      onSkip: onDone,
      last: last,
    );

    return LayoutBuilder(
      builder: (_, cons) => Stack(
        children: [
          // Tapping the scrim moves on rather than dismissing. Dismissing is
          // the ✕, which says so.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: next,
              child: spot == null
                  ? ColoredBox(color: colour)
                  : CustomPaint(
                      painter: _HolePainter(
                        spot: spot,
                        radius: spotRadius,
                        scrim: colour,
                        edge: Theme.of(context).colorScheme.primary,
                      ),
                    ),
            ),
          ),
          _place(card, spot, cons.biggest),
        ],
      ),
    );
  }

  /// Four sides rather than "above unless it is near the top": a rail is a
  /// tall column against one edge and a bottom bar is a wide strip against
  /// another, and the free space is on a different axis in each.
  Widget _place(Widget card, Rect? spot, Size size) {
    if (spot == null) {
      return Positioned(left: 13, right: 13, bottom: 13, child: card);
    }

    final child = Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: card,
        ),
      ),
    );

    final above = spot.top;
    final below = size.height - spot.bottom;
    final before = spot.left;
    final after = size.width - spot.right;

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

/// [GuideView] over the whole window, driving its own step.
///
/// For a guide whose target is somewhere the caller does not own — a tab
/// strip, a title bar. The caller measures with [rectInOverlay] and hands the
/// rectangle over; everything above every route is dimmed but that.
abstract final class GuideOverlay {
  /// Puts the guide up and completes when it comes down.
  ///
  /// A caller writing a "seen it" flag should write it on the returned future
  /// and nowhere else: there is no overlay to show in when the context has
  /// none, and the flag would otherwise be set for a guide nobody saw.
  static Future<void> show(
    BuildContext context,
    List<GuideStep> steps, {
    Color? scrim,
    double spotRadius = 18,
    EdgeInsets spotMargin = const EdgeInsets.all(6),
  }) {
    if (steps.isEmpty) return Future.value();
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return Future.value();

    final done = Completer<void>();
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _GuideHost(
        steps: steps,
        scrim: scrim,
        spotRadius: spotRadius,
        spotMargin: spotMargin,
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

class _GuideHost extends StatefulWidget {
  const _GuideHost({
    required this.steps,
    required this.scrim,
    required this.spotRadius,
    required this.spotMargin,
    required this.onGone,
  });

  final List<GuideStep> steps;
  final Color? scrim;
  final double spotRadius;
  final EdgeInsets spotMargin;
  final VoidCallback onGone;

  @override
  State<_GuideHost> createState() => _GuideHostState();
}

class _GuideHostState extends State<_GuideHost>
    with SingleTickerProviderStateMixin {
  late final _ctrl = AnimationController(
    vsync: this,
    duration: Durations.medium2,
  )..forward();

  int _step = 0;
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
    return FadeTransition(
      opacity: CurvedAnimation(parent: _ctrl, curve: Curves.easeOut),
      child: GuideView(
        steps: widget.steps,
        step: _step,
        onStep: (step) => setState(() => _step = step),
        onDone: _dismiss,
        scrim: widget.scrim,
        spotRadius: widget.spotRadius,
        spotMargin: widget.spotMargin,
      ),
    );
  }
}

final class _GuideCard extends StatelessWidget {
  const _GuideCard({
    required this.step,
    required this.count,
    required this.title,
    required this.body,
    required this.onNext,
    required this.onSkip,
    required this.last,
  });

  final int step;
  final int count;
  final String? title;
  final String body;
  final VoidCallback onNext;
  final VoidCallback onSkip;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = this.title;
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(17),
      elevation: 8,
      shadowColor: Colors.black.withValues(alpha: 0.4),
      child: Padding(
        padding: EdgeInsets.fromLTRB(17, title == null ? 3 : 13, 9, 9),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: title == null
                      ? const SizedBox.shrink()
                      : Text(
                          title,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
                // No label on it: every word here would need translating to
                // say what a ✕ already says.
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  color: scheme.onSurfaceVariant,
                  tooltip: libL10n.close,
                  onPressed: onSkip,
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8, top: 3, bottom: 13),
              child: Text(
                body,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.35,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            Row(
              children: [
                // Nothing to count through when there is one step, and a lone
                // dot beside a Done button says only that the row exists.
                if (count > 1)
                  for (var i = 0; i < count; i++)
                    _Dot(filled: i == step, done: i < step),
                const Spacer(),
                TextButton(
                  onPressed: onNext,
                  child: Text(last ? libL10n.done : libL10n.next),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// How far along, as far as it is worth saying. The step behind stays marked
/// so the row reads as progress rather than as a position.
final class _Dot extends StatelessWidget {
  const _Dot({required this.filled, required this.done});

  final bool filled;
  final bool done;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: Durations.short3,
      curve: Curves.easeOut,
      margin: const EdgeInsets.only(right: 5),
      width: filled ? 17 : 6,
      height: 6,
      decoration: BoxDecoration(
        color: filled || done
            ? scheme.primary
            : scheme.onSurfaceVariant.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(3),
      ),
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

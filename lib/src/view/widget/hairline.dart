import 'package:flutter/material.dart';

/// The colour and weight of every hairline the app draws on a surface: the seam
/// between two panes, the rules that bracket a panel's header and its composer,
/// the outline of an input box.
///
/// One value for all of them, because they meet each other at corners and any
/// difference between two lines that touch reads as one of the two halves being
/// a window of its own.
abstract final class Hairline {
  /// Material's default divider is drawn for a light background and reads as a
  /// bright seam on a dark one, so it is not used.
  static const thickness = 1.0;

  /// Translucent: a hairline separates two parts of one surface, and at full
  /// strength it reads as a border around each of them.
  static Color color(BuildContext context) =>
      Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.35);

  /// Solid, for the moment a draggable one is grabbed — see [PaneDivider].
  static Color activeColor(BuildContext context) =>
      Theme.of(context).colorScheme.primary;
}

/// The [Hairline] between two columns, and the handle for moving it.
///
/// Reports the drag in deltas rather than an absolute width, because only the
/// caller knows what the line is between and how far it may travel.
class PaneDivider extends StatefulWidget {
  const PaneDivider({super.key, required this.onDrag, this.onDragEnd});

  /// The line stays a hairline; the grab area does not, because a 1px target is
  /// not something a pointer can find.
  /// What `multi_split_view` wants either side of its own line to add up to
  /// [hitWidth]: it takes `thickness + 2 * buffer`. Stated once, here, rather
  /// than as arithmetic at a call site that cannot explain it.
  static const handleBuffer = (hitWidth - Hairline.thickness) / 2;

  static const hitWidth = 13.0;

  /// Pointer movement since the last call, in logical pixels.
  final ValueChanged<double> onDrag;

  /// The drag is over. Where a width is persisted, this is the moment for it —
  /// writing during the drag would be a write per frame.
  final VoidCallback? onDragEnd;

  @override
  State<PaneDivider> createState() => _PaneDividerState();
}

class _PaneDividerState extends State<PaneDivider> {
  bool _active = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _active = true),
      onExit: (_) => setState(() => _active = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (details) => widget.onDrag(details.delta.dx),
        onHorizontalDragEnd: (_) => widget.onDragEnd?.call(),
        child: SizedBox(
          width: PaneDivider.hitWidth,
          child: Center(
            child: Container(
              width: Hairline.thickness,
              color: _active
                  ? Hairline.activeColor(context)
                  : Hairline.color(context),
            ),
          ),
        ),
      ),
    );
  }
}

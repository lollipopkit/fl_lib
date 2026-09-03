import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';

/// The grip that folds the list column away and brings it back.
///
/// Both directions are one control in one place. A separate "hide" button in
/// the list and "show" button somewhere else would be two things to find, and
/// the second of them has to live on a surface that knows nothing about the
/// list — so it moves with the seam instead: on the divider while there is a
/// column, at the very edge once there is not.
///
/// The chevron is drawn at rest rather than on hover. A folded column is
/// reached by touch as well, where there is no hover to reveal anything, and a
/// control that only exists under a mouse leaves a tablet with no way back.
///
/// It drags as well as taps, because it sits on the divider and covers the
/// part of it a pointer aims for: a grip that swallowed the drag would take
/// resizing away at exactly the place people reach for it. Both gestures on
/// one target, the way the divider itself carries hover and drag.
class PaneCollapseHandle extends StatefulWidget {
  const PaneCollapseHandle({
    super.key,
    required this.collapsed,
    required this.onTap,
    this.onDrag,
    this.onDragEnd,
    this.tooltip,
  });

  /// Which way the chevron points, and what a tap does.
  final bool collapsed;

  final VoidCallback onTap;

  /// Pointer movement since the last call, in logical pixels.
  ///
  /// Null makes this a button and nothing else — for a layout whose column is
  /// not resizable, where a drag would have nothing to move.
  final ValueChanged<double>? onDrag;

  /// The drag is over. Where a width is persisted, this is the moment for it.
  final VoidCallback? onDragEnd;

  final String? tooltip;

  /// Wide enough for the chevron to sit inside it — the first version was the
  /// divider's 13pt hit width with a 15pt icon in it, which overflowed by a
  /// point either side and read as an arrow that was not centred.
  static const width = 18.0;

  static const height = 44.0;

  static const _iconSize = 15.0;

  @override
  State<PaneCollapseHandle> createState() => _PaneCollapseHandleState();
}

class _PaneCollapseHandleState extends State<PaneCollapseHandle> {
  bool _hovered = false;
  bool _pressed = false;

  bool get _active => _hovered || _pressed;

  void _setHovered(bool value) {
    if (_hovered == value) return;
    setState(() => _hovered = value);
  }

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final draggable = widget.onDrag != null;

    // Bigger under a finger, and scaled rather than sized: the grip is placed
    // by its left edge, so growing its width would move it sideways instead of
    // swelling in place — and a control that shifts while being held reads as
    // having been dragged.
    Widget handle = AnimatedScale(
      scale: _pressed ? 1.2 : 1,
      duration: Durations.short3,
      curve: Curves.easeOut,
      child: AnimatedContainer(
        duration: Durations.short3,
        curve: Curves.easeOut,
        width: PaneCollapseHandle.width,
        height: PaneCollapseHandle.height,
        // The icon is centred by the container rather than by a `Center`
        // inside it, so nothing between the two can offset it.
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: _active
              ? scheme.secondaryContainer
              : scheme.surfaceContainerHighest.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(PaneCollapseHandle.width / 2),
          border: Border.all(
            color: Hairline.color(context),
            width: Hairline.thickness,
          ),
        ),
        child: Icon(
          widget.collapsed ? Icons.chevron_right : Icons.chevron_left,
          size: PaneCollapseHandle._iconSize,
          color: _active
              ? scheme.onSecondaryContainer
              : scheme.onSurfaceVariant,
        ),
      ),
    );

    if (widget.tooltip case final tooltip?) {
      handle = Tooltip(message: tooltip, child: handle);
    }

    return MouseRegion(
      // What the pointer can do here, and dragging is the one that would
      // otherwise be a surprise: a click cursor over a part of the divider
      // says the resize stops at this square.
      cursor: draggable
          ? SystemMouseCursors.resizeColumn
          : SystemMouseCursors.click,
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      // Lit from the moment of contact rather than once a drag is recognised —
      // a touchscreen has no hover to have said anything beforehand. See
      // [PaneDivider], which lights up the same way for the same reason.
      child: Listener(
        onPointerDown: (_) => _setPressed(true),
        onPointerUp: (_) => _setPressed(false),
        onPointerCancel: (_) => _setPressed(false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          onHorizontalDragUpdate: widget.onDrag == null
              ? null
              : (details) => widget.onDrag!(details.delta.dx),
          onHorizontalDragEnd: widget.onDrag == null
              ? null
              : (_) => widget.onDragEnd?.call(),
          child: handle,
        ),
      ),
    );
  }
}

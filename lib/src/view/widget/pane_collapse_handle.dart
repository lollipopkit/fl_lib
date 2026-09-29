import 'package:fl_lib/fl_lib.dart';
import 'package:material_ui/material_ui.dart';

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
/// It resizes as well as folds, because of where it sits. Forty-four points
/// tall and centred on the seam, it covers exactly the stretch of the line a
/// pointer aims for — so while the two hit regions were kept separate, a drag
/// started in the middle of the divider did nothing at all. The answer is not
/// to move the grip, since the middle is where it belongs, but to let it hand
/// the drag on to the same callbacks the line uses.
///
/// Both gestures on one detector, and the arena decides between them: a
/// pointer that travels past the touch slop is a resize, one that does not is
/// a tap. Dragging it away from the edge while folded unfolds the column, for
/// the same reason and by the same path as dragging the line does.
///
/// The cursor stays [SystemMouseCursors.click]. What this control is *for* is
/// the fold; resizing from it is a rescue for an aim that landed here, and the
/// line above and below already offers the resize cursor.
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

  /// Pointer movement since the last call, in logical pixels — the same
  /// contract as [PaneDivider.onDrag], and meant to be given the same handler.
  ///
  /// Null leaves this a plain button, which is what it is anywhere the seam it
  /// sits on cannot be moved.
  final ValueChanged<double>? onDrag;

  /// The drag is over. See [PaneDivider.onDragEnd] — a width is persisted
  /// here, not on every frame of the drag.
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
    final localizations = MaterialLocalizations.of(context);
    final semanticsLabel =
        widget.tooltip ??
        (widget.collapsed
            ? localizations.collapsedIconTapHint
            : localizations.expandedIconTapHint);

    // Bigger under a finger, and scaled rather than sized: the grip is placed
    // by its left edge, so growing its width would move it sideways instead of
    // swelling in place — and a control that shifts while being held reads as
    // having been dragged.
    Widget handle = AnimatedScale(
      scale: _pressed ? 1.2 : 1,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : Durations.short3,
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
      cursor: SystemMouseCursors.click,
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      // Lit from the moment of contact rather than once a drag is recognised —
      // a touchscreen has no hover to have said anything beforehand. See
      // [PaneDivider], which lights up the same way for the same reason.
      child: Listener(
        onPointerDown: (_) => _setPressed(true),
        onPointerUp: (_) => _setPressed(false),
        onPointerCancel: (_) => _setPressed(false),
        child: Semantics(
          label: semanticsLabel,
          button: true,
          onTap: widget.onTap,
          excludeSemantics: true,
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
      ),
    );
  }
}

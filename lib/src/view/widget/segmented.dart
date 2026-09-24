import 'dart:ui' show PointerDeviceKind, lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// One position in a [SegmentedTabs].
final class SegmentedTab<T> {
  const SegmentedTab({required this.value, required this.label, this.icon});

  final T value;
  final String label;
  final IconData? icon;
}

/// A selector for which of several things a page is showing.
///
/// Material's own `SegmentedButton` outlines every segment and leaves the
/// unselected ones on whatever is behind them, which reads as a row of buttons
/// rather than as one control with a position in it. This draws a track
/// instead: no outline, and the track sits one surface step above the page, so
/// the unselected segments are legible as *places* and the filled one as where
/// you are.
///
/// The filled marker slides between them rather than fading in and out. A fade
/// says two segments changed; a slide says the one marker moved, which is what
/// actually happened.
///
/// [trackColor] defaults to `surfaceContainer`, which is the step above the
/// `surface` a Scaffold paints. Pass a colour only where the thing behind it
/// is not that.
final class SegmentedTabs<T> extends StatefulWidget {
  const SegmentedTabs({
    super.key,
    required this.segments,
    required this.selected,
    required this.onSelected,
    this.expand = false,
    this.collapse = false,
    this.trackColor,
  }) : assert(
         !(expand && collapse),
         'A control that is given the width has nothing to close to.',
       );

  final List<SegmentedTab<T>> segments;
  final T selected;
  final ValueChanged<T> onSelected;

  /// True gives every segment an equal share of the width, for a row that has
  /// the width to itself. False sizes each to its label, for one sharing a
  /// line with something else.
  final bool expand;

  /// True rests the control as its selected segment alone, and opens it to
  /// all of them under a pointer, or at a touch.
  ///
  /// For a control that shares a bar with other things and is changed once in
  /// a while: what it is set to is worth a place in the bar all the time, and
  /// what else it could be set to is worth one while somebody is choosing.
  ///
  /// Closed, it is drawn exactly as a control with one segment would be — the
  /// same track, the same filled marker — so it reads as the same control at
  /// rest rather than as a button that turns into one. See [_SegmentWindow]
  /// for how, and for why nothing inside it moves.
  ///
  /// A pointer opens it by being over it and closes it by leaving. A finger
  /// has no way of being over something, so a touch on the closed control
  /// opens it, and choosing a segment or touching anywhere else closes it.
  final bool collapse;

  final Color? trackColor;

  static const radius = BorderRadius.all(Radius.circular(30));
  static const duration = Duration(milliseconds: 200);
  static const curve = Curves.easeOutCubic;

  @override
  State<SegmentedTabs<T>> createState() => _SegmentedTabsState<T>();
}

class _SegmentedTabsState<T> extends State<SegmentedTabs<T>>
    with SingleTickerProviderStateMixin {
  final _trackKey = GlobalKey();
  final _segmentKeys = <T, GlobalKey>{};

  /// How far a [SegmentedTabs.collapse] control is open: 0 is the selected
  /// segment alone, 1 all of them.
  late final _openness = AnimationController(
    vsync: this,
    duration: SegmentedTabs.duration,
    value: widget.collapse ? 0 : 1,
  );
  late final _opening = CurvedAnimation(
    parent: _openness,
    curve: SegmentedTabs.curve,
    reverseCurve: SegmentedTabs.curve.flipped,
  );

  /// A pointer is over the control.
  bool _hovered = false;

  /// A touch opened it, and nothing has closed it since.
  bool _held = false;

  void _setOpen({bool? hovered, bool? held}) {
    _hovered = hovered ?? _hovered;
    _held = held ?? _held;
    if (!widget.collapse || _hovered || _held) {
      _openness.forward();
    } else {
      _openness.reverse();
    }
  }

  @override
  void didUpdateWidget(SegmentedTabs<T> old) {
    super.didUpdateWidget(old);
    if (old.collapse != widget.collapse) _setOpen();
  }

  @override
  void dispose() {
    _opening.dispose();
    _openness.dispose();
    super.dispose();
  }

  /// Where the marker is, in the track's own coordinates. Null until the first
  /// layout has happened — there is no way to know a segment's box before it
  /// has one, and segments are sized by their labels.
  Rect? _marker;

  void _measure() {
    if (!mounted) return;

    // A selection that names no segment leaves nothing to mark. Returning
    // early instead would keep the last rect, and the marker would go on
    // insisting on a segment the caller has moved off. Told apart from "the
    // segment is there but has not been laid out yet", which is every first
    // frame and must wait rather than clear.
    if (!widget.segments.any((segment) => segment.value == widget.selected)) {
      if (_marker != null) setState(() => _marker = null);
      return;
    }

    final track = _trackKey.currentContext?.findRenderObject();
    final segment = _segmentKeys[widget.selected]?.currentContext
        ?.findRenderObject();
    if (track is! RenderBox || segment is! RenderBox) return;
    if (!track.hasSize || !segment.hasSize) return;

    final rect =
        segment.localToGlobal(Offset.zero, ancestor: track) & segment.size;
    if (rect == _marker) return;
    setState(() => _marker = rect);
  }

  @override
  Widget build(BuildContext context) {
    assert(
      widget.segments.map((segment) => segment.value).toSet().length ==
          widget.segments.length,
      'SegmentedTabs segments must have distinct values: the value keys the '
      'GlobalKey the marker is measured from, so two segments sharing one put '
      'the same key in the tree twice.',
    );
    final scheme = Theme.of(context).colorScheme;

    // Measured after every build, which covers a new selection, a changed set
    // of segments and a label whose text grew. LayoutBuilder adds the case
    // none of those cover: the track itself being given a different width.
    return LayoutBuilder(
      builder: (_, _) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
        return Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: widget.trackColor ?? scheme.surfaceContainer,
            borderRadius: SegmentedTabs.radius,
          ),
          child: _collapsing(
            Stack(
              key: _trackKey,
              children: [
                if (_marker case final rect?)
                  // An implicit animation does not animate the values it is
                  // first built with, so the marker appears where it belongs and
                  // only slides once a later build moves it.
                  AnimatedPositioned(
                    key: const ValueKey('segmented-marker'),
                    duration: SegmentedTabs.duration,
                    curve: SegmentedTabs.curve,
                    left: rect.left,
                    top: rect.top,
                    width: rect.width,
                    height: rect.height,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: scheme.primaryContainer,
                        borderRadius: SegmentedTabs.radius,
                      ),
                    ),
                  ),
                Row(
                  mainAxisSize: widget.expand
                      ? MainAxisSize.max
                      : MainAxisSize.min,
                  children: [
                    for (var index = 0; index < widget.segments.length; index++)
                      ...[
                        if (index != 0) const SizedBox(width: 3),
                        if (widget.expand)
                          Expanded(
                            child: _buildSegment(scheme, widget.segments[index]),
                          )
                        else
                          _buildSegment(scheme, widget.segments[index]),
                      ],
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// [track] behind a window that rests on the selected segment, when the
  /// control is one that closes — see [SegmentedTabs.collapse].
  Widget _collapsing(Widget track) {
    if (!widget.collapse) return track;
    return TapRegion(
      onTapOutside: (_) => _setOpen(held: false),
      child: MouseRegion(
        onEnter: (_) => _setOpen(hovered: true),
        onExit: (_) => _setOpen(hovered: false),
        child: GestureDetector(
          // The selected segment takes no taps of its own — there is nothing
          // to select — so one on the closed control arrives here. Only a
          // touch: a pointer has opened it already by being over it, and a
          // click that also held it open would leave it open once the pointer
          // had gone.
          onTapUp: (details) {
            if (details.kind == PointerDeviceKind.mouse) return;
            _setOpen(held: !_held);
          },
          child: AnimatedBuilder(
            animation: _opening,
            builder: (_, child) => _SegmentWindow(
              openness: _opening.value,
              selected: _marker,
              // Nothing selected is nothing to rest on, and it stays open. A
              // segment that is selected and not measured yet is the first
              // frame — see [_SegmentWindow.waiting].
              waiting:
                  _marker == null &&
                  widget.segments.any((s) => s.value == widget.selected),
              child: child,
            ),
            child: track,
          ),
        ),
      ),
    );
  }

  void _select(T value) {
    // A touch that chose is done choosing. A pointer is still over it.
    if (widget.collapse) _setOpen(held: false);
    widget.onSelected(value);
  }

  Widget _buildSegment(ColorScheme scheme, SegmentedTab<T> segment) {
    final isSelected = segment.value == widget.selected;
    final foreground = isSelected
        ? scheme.onPrimaryContainer
        : scheme.onSurfaceVariant;

    return Semantics(
      button: true,
      selected: isSelected,
      child: Material(
        // Transparent: the marker behind is what fills a selected segment, so
        // that it can be one box that moves rather than one per segment.
        color: Colors.transparent,
        borderRadius: SegmentedTabs.radius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: _segmentKeys.putIfAbsent(segment.value, GlobalKey.new),
          onTap: isSelected ? null : () => _select(segment.value),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 5),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (segment.icon case final icon?) ...[
                  Icon(icon, size: 15, color: foreground),
                  const SizedBox(width: 5),
                ],
                Flexible(
                  child: AnimatedDefaultTextStyle(
                    duration: SegmentedTabs.duration,
                    curve: SegmentedTabs.curve,
                    style: Theme.of(context).textTheme.bodyMedium!.copyWith(
                      fontSize: 12,
                      color: foreground,
                      fontWeight: isSelected
                          ? FontWeight.w500
                          : FontWeight.normal,
                    ),
                    child: Text(
                      segment.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A window onto a row of segments, resting on the one that is selected.
///
/// What closes a [SegmentedTabs.collapse] control. The row behind it is laid
/// out in full and never changes: this is as wide as the selected segment when
/// closed and as wide as the row when open, and slides the row under itself so
/// that segment is always inside. So nothing in the row moves against
/// anything else in it — the marker, which is placed from a measurement a
/// frame old, stays under its label the whole way, where segments closing up
/// one by one would have had it trailing the label by a frame's travel.
///
/// [selected] is that same measurement, in the row's own coordinates, which
/// is why it can be a frame old here too: opening and closing do not move it.
/// Reading the segment's box during this layout instead would be a frame
/// fresher, and is a grandchild's size — which a render object may not ask
/// for.
class _SegmentWindow extends SingleChildRenderObjectWidget {
  const _SegmentWindow({
    required this.openness,
    required this.selected,
    required this.waiting,
    required super.child,
  });

  final double openness;

  /// Where the selected segment is in the row, or null for a window that has
  /// nothing to rest on and so stays open.
  final Rect? selected;

  /// The segment is there and has not been measured, which is the frame the
  /// control is first built on. Nothing is drawn for it: the choice is between
  /// the whole row for one frame and then the closed control, and the control
  /// arriving a frame late — which is when its marker arrives anyway.
  final bool waiting;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderSegmentWindow(
    openness: openness,
    selected: selected,
    waiting: waiting,
  );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSegmentWindow renderObject,
  ) {
    renderObject
      ..openness = openness
      ..selected = selected
      ..waiting = waiting;
  }
}

class _RenderSegmentWindow extends RenderShiftedBox {
  _RenderSegmentWindow({
    required double openness,
    required Rect? selected,
    required bool waiting,
  }) : _openness = openness,
       _selected = selected,
       _waiting = waiting,
       super(null);

  double _openness;
  set openness(double v) {
    if (_openness == v) return;
    _openness = v;
    markNeedsLayout();
  }

  Rect? _selected;
  set selected(Rect? v) {
    if (_selected == v) return;
    _selected = v;
    markNeedsLayout();
  }

  bool _waiting;
  set waiting(bool v) {
    if (_waiting == v) return;
    _waiting = v;
    markNeedsPaint();
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(constraints, parentUsesSize: true);
    final full = child.size;
    final at = _selected;

    final left = at == null ? 0.0 : lerpDouble(at.left, 0, _openness)!;
    final width = at == null
        ? full.width
        : lerpDouble(at.width, full.width, _openness)!;
    size = constraints.constrain(Size(width, full.height));
    (child.parentData! as BoxParentData).offset = Offset(-left, 0);
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) =>
      !_waiting && super.hitTest(result, position: position);

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null || _waiting) {
      layer = null;
      return;
    }
    if (_openness >= 1) {
      layer = null;
      super.paint(context, offset);
      return;
    }
    layer = context.pushClipRect(
      needsCompositing,
      offset,
      Offset.zero & size,
      super.paint,
      oldLayer: layer as ClipRectLayer?,
    );
  }
}

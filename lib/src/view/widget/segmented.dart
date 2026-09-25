import 'dart:math' as math;
import 'dart:ui' show PointerDeviceKind, lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// One position in a [SegmentedTabs].
final class SegmentedTab<T> {
  const SegmentedTab({
    required this.value,
    required this.label,
    this.icon,
    this.sub,
  });

  final T value;
  final String label;
  final IconData? icon;

  /// A second level, for a position that is itself a choice between a few
  /// things — a console that is a terminal or a screen. Shown inside the
  /// track, to the right of this segment's label and under the same marker,
  /// while this segment is the selected one; not at all otherwise. A
  /// [SegmentedTab.sub] of one of its own segments is ignored.
  final SegmentedSub<Object?>? sub;
}

/// The second level of a [SegmentedTab]: its positions and which is chosen.
final class SegmentedSub<S> {
  const SegmentedSub({
    required this.segments,
    required this.selected,
    required this.onSelected,
  });

  final List<SegmentedTab<S>> segments;
  final S selected;
  final ValueChanged<S> onSelected;

  /// [onSelected], reached through a [SegmentedSub] of any type argument: a
  /// `SegmentedSub<Mode>` held as `SegmentedSub<Object?>` may not have its
  /// callback read as one taking `Object?`.
  void _select(Object? value) => onSelected(value as S);
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

  /// The second level's segments, by their parent's value and their own.
  final _subKeys = <(T, Object?), GlobalKey>{};

  /// Labels hidden, icons only: the row does not fit with them. Only for a
  /// row that sizes to its labels (neither [SegmentedTabs.expand] nor
  /// [SegmentedTabs.collapse]), and only segments with an icon lose theirs.
  bool _compact = false;

  /// The width the row needed with its labels, when it went [_compact]: it
  /// shows them again once it has that much, and not before — so it does not
  /// flip between the two on every layout.
  double? _fullWidth;

  void _onMeasured(double needed, double room) {
    final bool next;
    if (!_compact) {
      if (needed <= room || !widget.segments.any((s) => s.icon != null)) return;
      _fullWidth = needed;
      next = true;
    } else {
      final full = _fullWidth;
      if (full != null && full > room) return;
      next = false;
    }
    // Reported from layout, where state may not change.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _compact != next) setState(() => _compact = next);
    });
  }

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
    // Other labels need another width: measured again, with them shown.
    if (_compact && !_sameLabels(old.segments, widget.segments)) {
      _compact = false;
      _fullWidth = null;
    }
  }

  static bool _sameLabels(
    List<SegmentedTab<Object?>> a,
    List<SegmentedTab<Object?>> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].label != b[i].label ||
          a[i].value != b[i].value ||
          a[i].sub?.segments.length != b[i].sub?.segments.length) {
        return false;
      }
    }
    return true;
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

  /// Where the second level's marker is, like [_marker]. Null when the
  /// selected segment has no second level, or it has not been laid out.
  Rect? _subMarker;

  /// The selected segment, when it has a second level.
  SegmentedTab<T>? get _selectedWithSub {
    for (final segment in widget.segments) {
      if (segment.value == widget.selected) {
        return segment.sub == null ? null : segment;
      }
    }
    return null;
  }

  void _measure() {
    if (!mounted) return;
    _measureSub();

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
    // A key can still name a box a rebuild has just taken out of the tree
    // (a segment that changed shape): sized, but nothing to measure against.
    if (!track.attached || !segment.attached) return;
    if (!track.hasSize || !segment.hasSize) return;

    final rect =
        segment.localToGlobal(Offset.zero, ancestor: track) & segment.size;
    if (rect == _marker) return;
    setState(() => _marker = rect);
  }

  void _measureSub() {
    final parent = _selectedWithSub;
    final sub = parent?.sub;
    Rect? rect;
    if (parent != null && sub != null) {
      final track = _trackKey.currentContext?.findRenderObject();
      final box = _subKeys[(parent.value, sub.selected)]?.currentContext
          ?.findRenderObject();
      if (track is RenderBox &&
          box is RenderBox &&
          track.attached &&
          box.attached &&
          track.hasSize &&
          box.hasSize) {
        rect = box.localToGlobal(Offset.zero, ancestor: track) & box.size;
      } else {
        // Not laid out yet: the next frame measures it.
        return;
      }
    }
    if (rect == _subMarker) return;
    setState(() => _subMarker = rect);
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
                if ((_subMarker, _selectedWithSub) case (
                  final rect?,
                  final parent?,
                ))
                  // Keyed by its parent: moving to another parent's second
                  // level is a new marker, not this one sliding over.
                  AnimatedPositioned(
                    key: ValueKey(('segmented-sub-marker', parent.value)),
                    duration: SegmentedTabs.duration,
                    curve: SegmentedTabs.curve,
                    left: rect.left,
                    top: rect.top,
                    width: rect.width,
                    height: rect.height,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: scheme.onPrimaryContainer.withValues(
                          alpha: 0.12,
                        ),
                        borderRadius: SegmentedTabs.radius,
                      ),
                    ),
                  ),
                if (widget.expand || widget.collapse)
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
                            // Laid out in full behind its window, never
                            // narrower: see [_SegmentWindow].
                            _buildSegment(scheme, widget.segments[index]),
                        ],
                    ],
                  )
                else
                  _ShrinkRow(
                    gap: 3,
                    textDirection: Directionality.of(context),
                    onMeasured: _onMeasured,
                    // Short of room with labels that can go: they go next
                    // frame, so this one is not squeezed in the meantime.
                    deferShrink:
                        !_compact && widget.segments.any((s) => s.icon != null),
                    children: [
                      for (final segment in widget.segments)
                        _buildSegment(scheme, segment),
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

  /// [segment], and its second level to the right of it when it has one and
  /// is selected — one box, which is what the marker is measured from.
  Widget _buildSegment(ColorScheme scheme, SegmentedTab<T> segment) {
    final sub = segment.sub;
    if (sub == null || segment.value != widget.selected) {
      return _buildOwnSegment(scheme, segment);
    }
    return Row(
      key: _segmentKeys.putIfAbsent(segment.value, GlobalKey.new),
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(child: _buildOwnSegment(scheme, segment, keyed: false)),
        for (final item in sub.segments)
          Flexible(child: _buildSubSegment(scheme, segment.value, sub, item)),
        const SizedBox(width: 3),
      ],
    );
  }

  Widget _buildSubSegment(
    ColorScheme scheme,
    T parent,
    SegmentedSub<Object?> sub,
    SegmentedTab<Object?> item,
  ) {
    final isSelected = item.value == sub.selected;
    return _segmentInk(
      scheme,
      key: _subKeys.putIfAbsent((parent, item.value), GlobalKey.new),
      label: item.label,
      icon: item.icon,
      foreground: scheme.onPrimaryContainer,
      bold: isSelected,
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
      onTap: isSelected ? null : () => sub._select(item.value),
    );
  }

  Widget _buildOwnSegment(
    ColorScheme scheme,
    SegmentedTab<T> segment, {
    bool keyed = true,
  }) {
    final isSelected = segment.value == widget.selected;
    return _segmentInk(
      scheme,
      key: keyed
          ? _segmentKeys.putIfAbsent(segment.value, GlobalKey.new)
          : null,
      label: segment.label,
      icon: segment.icon,
      foreground: isSelected
          ? scheme.onPrimaryContainer
          : scheme.onSurfaceVariant,
      bold: isSelected,
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 5),
      onTap: isSelected ? null : () => _select(segment.value),
    );
  }

  /// One tappable segment of either level. [key] is what a marker measures.
  Widget _segmentInk(
    ColorScheme scheme, {
    required Key? key,
    required String label,
    required IconData? icon,
    required Color foreground,
    required bool bold,
    required EdgeInsets padding,
    required VoidCallback? onTap,
  }) {
    final font = Theme.of(context).textTheme.bodyMedium;
    final iconOnly = _compact && icon != null && !widget.expand && !widget.collapse;
    if (iconOnly) {
      return Tooltip(
        message: label,
        child: Semantics(
          button: true,
          selected: bold,
          label: label,
          child: Material(
            color: Colors.transparent,
            borderRadius: SegmentedTabs.radius,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: key,
              onTap: onTap,
              child: Padding(
                padding: padding,
                child: Icon(icon, size: 15, color: foreground),
              ),
            ),
          ),
        ),
      );
    }
    return Semantics(
      button: true,
      selected: bold,
      child: Material(
        // Transparent: the marker behind is what fills a selected segment, so
        // that it can be one box that moves rather than one per segment.
        color: Colors.transparent,
        borderRadius: SegmentedTabs.radius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: key,
          onTap: onTap,
          child: Padding(
            padding: padding,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 15, color: foreground),
                  const SizedBox(width: 5),
                ],
                Flexible(
                  child: AnimatedDefaultTextStyle(
                    duration: SegmentedTabs.duration,
                    curve: SegmentedTabs.curve,
                    // Only the family comes from the theme: a label is 12pt,
                    // and the rest of `bodyMedium` is not — its line height
                    // (1.43) and tracking (0.25) are a 14pt body's.
                    style: TextStyle(
                      fontFamily: font?.fontFamily,
                      fontFamilyFallback: font?.fontFamilyFallback,
                      fontSize: 12,
                      color: foreground,
                      fontWeight: bold ? FontWeight.w500 : FontWeight.normal,
                    ),
                    child: Text(
                      label,
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

/// A row of segments, each as wide as it asks to be while they all fit.
///
/// Given less room than that, every one gives up the same share of its own
/// width, so a wide segment — one showing its second level — stays wide next
/// to narrow ones. `Flexible` would split the room evenly by count instead,
/// and cut that segment's labels to nothing long before the row was full.
class _ShrinkRow extends MultiChildRenderObjectWidget {
  const _ShrinkRow({
    required this.gap,
    required this.textDirection,
    required this.onMeasured,
    required this.deferShrink,
    required super.children,
  });

  /// Lays the children out at their own width and clips them, rather than
  /// narrowing them, when they do not fit — for the one frame before the
  /// row changes to icons only.
  final bool deferShrink;

  final double gap;
  final TextDirection textDirection;

  /// After each layout: the width the children asked for, and what there was.
  final void Function(double needed, double room) onMeasured;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderShrinkRow(
    gap: gap,
    textDirection: textDirection,
    onMeasured: onMeasured,
    deferShrink: deferShrink,
  );

  @override
  void updateRenderObject(BuildContext context, _RenderShrinkRow renderObject) {
    renderObject
      ..gap = gap
      ..textDirection = textDirection
      ..onMeasured = onMeasured
      ..deferShrink = deferShrink;
  }
}

class _ShrinkRowParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderShrinkRow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _ShrinkRowParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _ShrinkRowParentData> {
  _RenderShrinkRow({
    required double gap,
    required TextDirection textDirection,
    required this.onMeasured,
    required bool deferShrink,
  }) : _gap = gap,
       _textDirection = textDirection,
       _deferShrink = deferShrink;

  void Function(double needed, double room) onMeasured;

  bool _deferShrink;
  set deferShrink(bool value) {
    if (value == _deferShrink) return;
    _deferShrink = value;
    markNeedsLayout();
  }

  /// Laid out wider than it is: painted clipped.
  bool _overflows = false;

  double _gap;
  set gap(double value) {
    if (value == _gap) return;
    _gap = value;
    markNeedsLayout();
  }

  TextDirection _textDirection;
  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _ShrinkRowParentData) {
      child.parentData = _ShrinkRowParentData();
    }
  }

  double get _gaps => childCount < 2 ? 0 : _gap * (childCount - 1);

  @override
  double computeMinIntrinsicWidth(double height) => _gaps;

  @override
  double computeMaxIntrinsicWidth(double height) {
    var sum = _gaps;
    for (final child in getChildrenAsList()) {
      sum += child.getMaxIntrinsicWidth(height);
    }
    return sum;
  }

  @override
  double computeMinIntrinsicHeight(double width) => getChildrenAsList().fold(
    0,
    (h, c) => math.max(h, c.getMinIntrinsicHeight(double.infinity)),
  );

  @override
  double computeMaxIntrinsicHeight(double width) => getChildrenAsList().fold(
    0,
    (h, c) => math.max(h, c.getMaxIntrinsicHeight(double.infinity)),
  );

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      _layout(constraints, dry: true);

  @override
  void performLayout() => size = _layout(constraints, dry: false);

  Size _layout(BoxConstraints constraints, {required bool dry}) {
    final children = getChildrenAsList();
    final natural = [
      for (final c in children) c.getMaxIntrinsicWidth(double.infinity),
    ];
    final sum = natural.fold<double>(0, (a, b) => a + b);
    final room = constraints.maxWidth - _gaps;
    if (!dry) onMeasured(sum + _gaps, constraints.maxWidth);
    final fits = sum <= room || sum == 0;
    final scale = fits || _deferShrink ? 1.0 : math.max(0.0, room / sum);
    if (!dry) _overflows = !fits && _deferShrink;
    final sizes = <Size>[];
    for (var i = 0; i < children.length; i++) {
      final inner = BoxConstraints(
        maxWidth: natural[i] * scale,
        maxHeight: constraints.maxHeight,
      );
      sizes.add(
        dry
            ? children[i].getDryLayout(inner)
            : (children[i]..layout(inner, parentUsesSize: true)).size,
      );
    }
    final height = sizes.fold<double>(0, (h, s) => math.max(h, s.height));
    final width =
        sizes.fold<double>(0, (w, s) => w + s.width) + _gaps;
    final size = constraints.constrain(Size(width, height));
    if (dry) return size;
    final rtl = _textDirection == TextDirection.rtl;
    var x = rtl ? size.width : 0.0;
    for (var i = 0; i < children.length; i++) {
      final s = sizes[i];
      final dy = (height - s.height) / 2;
      final pd = children[i].parentData! as _ShrinkRowParentData;
      if (rtl) {
        x -= s.width;
        pd.offset = Offset(x, dy);
        x -= _gap;
      } else {
        pd.offset = Offset(x, dy);
        x += s.width + _gap;
      }
    }
    return size;
  }

  final _clip = LayerHandle<ClipRectLayer>();

  @override
  void paint(PaintingContext context, Offset offset) {
    if (!_overflows) {
      _clip.layer = null;
      defaultPaint(context, offset);
      return;
    }
    _clip.layer = context.pushClipRect(
      needsCompositing,
      offset,
      Offset.zero & size,
      defaultPaint,
      oldLayer: _clip.layer,
    );
  }

  @override
  void dispose() {
    _clip.layer = null;
    super.dispose();
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

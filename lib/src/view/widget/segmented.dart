import 'package:flutter/material.dart';

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
    this.trackColor,
  });

  final List<SegmentedTab<T>> segments;
  final T selected;
  final ValueChanged<T> onSelected;

  /// True gives every segment an equal share of the width, for a row that has
  /// the width to itself. False sizes each to its label, for one sharing a
  /// line with something else.
  final bool expand;

  final Color? trackColor;

  static const radius = BorderRadius.all(Radius.circular(30));
  static const duration = Duration(milliseconds: 200);
  static const curve = Curves.easeOutCubic;

  @override
  State<SegmentedTabs<T>> createState() => _SegmentedTabsState<T>();
}

class _SegmentedTabsState<T> extends State<SegmentedTabs<T>> {
  final _trackKey = GlobalKey();
  final _segmentKeys = <T, GlobalKey>{};

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
          child: Stack(
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
        );
      },
    );
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
          onTap: isSelected ? null : () => widget.onSelected(segment.value),
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
                    style: TextStyle(
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

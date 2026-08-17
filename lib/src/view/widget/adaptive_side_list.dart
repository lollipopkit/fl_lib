import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';

/// A list in its own column beside what it opens, when there is room, and
/// folded into that surface when there is not.
///
/// The sibling of [AdaptivePanes], for the case it cannot serve. There, the
/// detail is a route: pushed over the list on one screen, given a column on
/// two, and built fresh either way. Here the surface beside the list is not a
/// route but a place that holds things — terminals, file browsers, anything
/// with a connection behind it — and tearing it down because a window crossed
/// a width would take those connections with it.
///
/// So it is the list that moves. [builder] is called in both layouts and its
/// subtree keeps its place in the tree, which is what keeps its state. What
/// [builder] does with the list when there is no column for it is its own
/// business — a tab strip usually makes it the first tab.
class AdaptiveSideList extends StatefulWidget {
  const AdaptiveSideList({
    super.key,
    required this.sideBuilder,
    required this.builder,
    this.enabled = true,
    this.minWidthForSide = 800,
    this.sideWidth = 220,
    this.minSideWidth = 160,
    this.maxSideWidth = 520,
    this.onSideWidthChanged,
  });

  /// The list. Built only while it has a column of its own.
  final WidgetBuilder sideBuilder;

  /// The surface the list opens things on.
  ///
  /// Told whether the list is beside it, because it is the one that has to
  /// find somewhere else for the list when it is not.
  final Widget Function(BuildContext context, bool split) builder;

  /// Off keeps the single-column layout at any width.
  ///
  /// Where "there is nothing open yet" belongs: a column reserved beside an
  /// empty surface is width spent on nothing.
  final bool enabled;

  /// Below this the list cannot earn a column of its own. Set for the
  /// narrowest device that should still get two: an 11" iPad in portrait is
  /// 834pt.
  final double minWidthForSide;

  /// Starting width of the list. The user can drag from there.
  ///
  /// As narrow as dragging used to allow. The list is an index — what is being
  /// read is in the other column — and the width it opened with was taken from
  /// what the surface beside it then had to make do with.
  final double sideWidth;

  /// How narrow and how wide dragging may make the list.
  ///
  /// [minSideWidth] is what a row of this list still reads at: an entry is an
  /// icon, a name that ellipsizes, and sometimes a trailing control.
  final double minSideWidth;
  final double maxSideWidth;

  /// Called once the drag ends, not while it runs: persisting the width would
  /// otherwise be a write per frame.
  final ValueChanged<double>? onSideWidthChanged;

  @override
  State<AdaptiveSideList> createState() => _AdaptiveSideListState();
}

class _AdaptiveSideListState extends State<AdaptiveSideList> {
  late double _width = widget.sideWidth;

  @override
  void didUpdateWidget(AdaptiveSideList old) {
    super.didUpdateWidget(old);
    // Where several of these share one stored width, the page that is on
    // screen is not the only one holding a state: the others are kept alive
    // behind it, built once with the width of the day and never told it
    // changed. One setting then behaves as one per page, and whichever was
    // dragged last silently overwrites what the rest had persisted.
    //
    // Only when the caller's value actually changes, so a drag in progress is
    // not undone by the next rebuild carrying the old stored number.
    if (old.sideWidth != widget.sideWidth) _width = widget.sideWidth;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final split =
            widget.enabled && constraints.maxWidth >= widget.minWidthForSide;
        // The list may not take so much that the surface beside it is unusable,
        // however wide the user dragged it in a larger window.
        final maxWidth = (constraints.maxWidth / 2).clamp(
          widget.minSideWidth,
          widget.maxSideWidth,
        );

        return Row(
          children: [
            if (split) ...[
              SizedBox(
                width: _width.clamp(widget.minSideWidth, maxWidth),
                child: Builder(builder: widget.sideBuilder),
              ),
              PaneDivider(
                onDrag: (dx) => setState(() {
                  _width = (_width + dx).clamp(widget.minSideWidth, maxWidth);
                }),
                onDragEnd: () => widget.onSideWidthChanged?.call(_width),
              ),
            ],
            // Keyed, and the only child that is always here. The column
            // appearing beside it must read as this subtree staying put with a
            // sibling inserted before it, not as a new list whose first entry
            // happens to look familiar — the difference is whether everything
            // it holds is disposed and rebuilt.
            Expanded(
              key: const ValueKey('adaptive_side_list.main'),
              child: Builder(builder: (ctx) => widget.builder(ctx, split)),
            ),
          ],
        );
      },
    );
  }
}

import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';

/// A list in its own column beside what it opens, and one column where there
/// is no room for two.
///
/// This was two widgets. What differed between them was which half a narrow
/// window keeps, and that follows from one thing — whether what sits beside
/// the list can be torn down and built again:
///
/// - [AdaptivePanes.detail] holds a **route** in the pane. It is built fresh
///   wherever it goes, so a narrow window can keep the list and let the caller
///   push the detail over it. The server list and the snippets are this.
/// - [AdaptivePanes.surface] holds a **place**: a terminal, a file browser,
///   anything with a connection behind it. Tearing that down because a window
///   crossed a width would take the connection with it, so the surface stays
///   put and it is the list that moves. What [surfaceBuilder] does with the
///   list when there is no column for it is its own business — a tab strip
///   usually makes it the first tab.
///
/// The two are otherwise the same layout and share all of it: one width, one
/// divider, one fold, one grip.
///
/// Deliberately two columns and not N. The app's outermost column is its
/// navigation rail, which already exists and has nothing to do with this
/// widget; a general N-pane engine would be built for a case nobody has. It
/// used to be laid out by one — `multi_split_view` — and the seam that engine
/// draws is not the seam this one does: it advances the layout by the line's
/// thickness alone and widens the grab area by *overlapping* the areas either
/// side, which is a second geometry to get right for every measurement taken
/// against it.
class AdaptivePanes extends StatefulWidget {
  /// A list beside a pane holding a route.
  ///
  /// [detailBuilder] is null until something is opened, which gives the list
  /// the whole width — what an app looks like before the user has opened
  /// anything.
  const AdaptivePanes.detail({
    super.key,
    required this.listBuilder,
    required this.detailBuilder,
    this.detailId,
    this.onCloseDetail,
    this.minWidthForSplit = kSplitWidth,
    this.listWidth = 220,
    this.minListWidth = 160,
    this.maxListWidth = 520,
    this.onListWidthChanged,
    this.collapsed = false,
    this.onCollapsedChanged,
    this.collapseTooltip,
    this.expandTooltip,
  }) : surfaceBuilder = null,
       enabled = true;

  /// A list beside a surface that holds live things.
  ///
  /// [enabled] off keeps the single-column layout at any width — where "there
  /// is nothing open yet" belongs, since a column reserved beside an empty
  /// surface is width spent on nothing. It is what [detailBuilder] being null
  /// says in the other constructor.
  const AdaptivePanes.surface({
    super.key,
    required this.listBuilder,
    required this.surfaceBuilder,
    this.enabled = true,
    this.minWidthForSplit = kSplitWidth,
    this.listWidth = 220,
    this.minListWidth = 160,
    this.maxListWidth = 520,
    this.onListWidthChanged,
    this.collapsed = false,
    this.onCollapsedChanged,
    this.collapseTooltip,
    this.expandTooltip,
  }) : detailBuilder = null,
       detailId = null,
       onCloseDetail = null;

  /// The list. Always on screen in [AdaptivePanes.detail]; only while it has a
  /// column of its own in [AdaptivePanes.surface].
  ///
  /// Told whether it is sharing the width, because a list that is a browsing
  /// grid at full width should be a narrow index when it is a column beside
  /// something else — and only this widget knows which it is.
  final Widget Function(BuildContext context, bool split) listBuilder;

  /// The pane's root page, or null when nothing is selected.
  final WidgetBuilder? detailBuilder;

  /// Identity of what the detail shows. Changing it swaps the pane's root.
  final Object? detailId;

  /// Asks the caller to select nothing, which makes [detailBuilder] null and
  /// hands the width back to the list.
  ///
  /// The caller owns the selection, so it is the only thing that can clear it;
  /// this widget just carries the request down to whatever is rendered in the
  /// pane, via [PaneScope.closeDetailOf]. Leave null and no way out is
  /// offered — appropriate where something must always be open.
  final VoidCallback? onCloseDetail;

  /// The surface the list opens things on, told whether the list is beside it.
  final Widget Function(BuildContext context, bool split)? surfaceBuilder;

  /// Whether a column is worth reserving at all — see [AdaptivePanes.surface].
  final bool enabled;

  /// Below this the second column cannot be earned.
  ///
  /// Defaults to [kSplitWidth], which is also what everything else deciding
  /// between a phone's layout and a window's should read — see it.
  final double minWidthForSplit;

  /// The width at which this app stops being one column.
  ///
  /// Set for the narrowest device that should still get two: an 11" iPad in
  /// portrait is 834pt.
  ///
  /// Public, and the one place it is written down. A layout answering this
  /// question with its own number — or with a `ResponsiveBreakpoints` class,
  /// whose MOBILE ends at 600 — put the app in two minds between the two
  /// figures: a navigation rail down the side of a page too narrow to give any
  /// tab a second column, a settings menu beside content on a window where no
  /// other page had a menu.
  static const kSplitWidth = 800.0;

  /// Starting width of the list. The user can drag from there.
  ///
  /// As narrow as dragging used to allow. The list is an index — what is being
  /// read is in the other column — and the width it opened with was taken from
  /// what the detail beside it then had to make do with.
  final double listWidth;

  /// How narrow and how wide dragging may make the list.
  ///
  /// [minListWidth] is measured rather than chosen: it is the narrowest the
  /// server list's cards lay out at without overflowing, which
  /// `test/pane_width_test.dart` holds to.
  final double minListWidth;
  final double maxListWidth;

  /// Called once the drag ends, not while it runs: persisting the width would
  /// otherwise be a write per frame.
  final ValueChanged<double>? onListWidthChanged;

  /// Folded away entirely, giving the other column the whole width.
  ///
  /// Distinct from [enabled], which is the layout's own answer about whether a
  /// column is worth reserving. This one is the user's, it is remembered, and
  /// it survives the window being wide enough for two columns — which is the
  /// point: someone reading a terminal on a laptop wants the width, and wants
  /// it again the next time they open the tab.
  final bool collapsed;

  /// Asked to fold or unfold. Null offers no grip and no way to fold.
  final ValueChanged<bool>? onCollapsedChanged;

  final String? collapseTooltip;
  final String? expandTooltip;

  /// Whether the pane holds a route rather than a surface that stays put.
  bool get _isDetail => surfaceBuilder == null;

  /// Whether there is a second column to have at all, before any question of
  /// width or folding.
  bool get _hasContent => _isDetail ? detailBuilder != null : enabled;

  @override
  State<AdaptivePanes> createState() => _AdaptivePanesState();
}

class _AdaptivePanesState extends State<AdaptivePanes>
    with SingleTickerProviderStateMixin {
  /// One navigator, one key, and exactly one widget holding it at a time.
  ///
  /// A `GlobalKey` cannot be in two live places, so nothing here may ever
  /// build the pane twice — which is why the fold animates a width inside one
  /// unchanging tree rather than swapping between two arrangements of it.
  ///
  /// Only [AdaptivePanes.detail] has one. A surface is not a route and has no
  /// navigator of its own.
  final _navigatorKey = GlobalKey<NavigatorState>();

  late double _width = widget.listWidth;

  /// The widest the column may currently be, from the last layout. Kept so a
  /// drag can clamp without waiting for a build to tell it the number.
  late double _maxWidth = widget.maxListWidth;

  /// How open the column is, 1 to 0.
  late final _fold = AnimationController(
    vsync: this,
    duration: Durations.medium2,
    value: widget.collapsed ? 0 : 1,
  );

  late final _openness = CurvedAnimation(
    parent: _fold,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  /// Pointer movement accumulated while the column is folded.
  ///
  /// A fold is not a width, so there is nothing to add a delta to until the
  /// pull is long enough to mean "open" — and a stray pixel from a tap that
  /// wobbled must not count as that.
  double _pullFromFolded = 0;

  /// How far the grip has to be dragged away from the edge to unfold.
  static const _kPullToUnfold = 24.0;

  /// How far below the narrowest width a drag has to reach to fold instead.
  ///
  /// Dragging a column to nothing is how a folded column is asked for by
  /// people who never look for a button, and stopping dead at the minimum is
  /// what makes it feel like the layout is refusing rather than resisting.
  static const _kPushToFold = 48.0;

  @override
  void didUpdateWidget(AdaptivePanes old) {
    super.didUpdateWidget(old);
    // Where several of these share one stored width, the page that is on
    // screen is not the only one holding a state: the others are kept alive
    // behind it, built once with the width of the day and never told it
    // changed. One setting then behaves as one per page, and whichever was
    // dragged last silently overwrites what the rest had persisted.
    //
    // Only when the caller's value actually changes, so a drag in progress is
    // not undone by the next rebuild carrying the old stored number.
    if (old.listWidth != widget.listWidth) _width = widget.listWidth;
    if (old.collapsed == widget.collapsed) return;
    _pullFromFolded = 0;
    widget.collapsed ? _fold.reverse() : _fold.forward();
  }

  @override
  void dispose() {
    _openness.dispose();
    _fold.dispose();
    super.dispose();
  }

  /// The seam being dragged, by its line or by the grip on it: resizes the
  /// column, and folds it at either end of the travel.
  void _onSeamDrag(double dx) {
    final onCollapsed = widget.onCollapsedChanged;

    if (widget.collapsed) {
      if (onCollapsed == null) return;
      _pullFromFolded += dx;
      if (_pullFromFolded < _kPullToUnfold) return;
      _pullFromFolded = 0;
      onCollapsed(false);
      return;
    }

    final next = _width + dx;
    // Folded, not clamped: the width itself is left where it was, so
    // unfolding returns the column to the size it was dragged away from
    // rather than to the minimum it passed through on the way out.
    if (onCollapsed != null && next < widget.minListWidth - _kPushToFold) {
      onCollapsed(true);
      return;
    }
    setState(() => _width = next.clamp(widget.minListWidth, _maxWidth));
  }

  void _onSeamDragEnd() {
    if (widget.collapsed) return;
    widget.onListWidthChanged?.call(_width);
  }

  /// What goes in the second column.
  Widget _buildContent(BuildContext context, bool split) {
    final surface = widget.surfaceBuilder;
    if (surface != null) return surface(context, split);

    // Read on every build rather than captured once: the pane outlives any
    // particular selection, and a rebuild while it is being closed would
    // otherwise dereference a detail that is gone.
    final detail = widget.detailBuilder;
    if (detail == null) return const SizedBox.shrink();
    return NestedNavigator(
      navigatorKey: _navigatorKey,
      rootBuilder: detail,
      rootId: widget.detailId,
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Two different questions, and conflating them deadlocks: "will
        // opening something land it beside the list" is about the width, while
        // "is there something to show" is about the selection. Reporting the
        // second as the first means a list that only selects once a pane is on
        // screen can never put anything on it.
        final wideEnough = constraints.maxWidth >= widget.minWidthForSplit;
        final roomForTwo = wideEnough && widget._hasContent;

        // The list may not take so much that what is beside it is unusable,
        // however wide the user dragged it in a larger window.
        _maxWidth = (constraints.maxWidth / 2).clamp(
          widget.minListWidth,
          widget.maxListWidth,
        );
        final width = _width.clamp(widget.minListWidth, _maxWidth);
        final onCollapsed = widget.onCollapsedChanged;

        final body = AnimatedBuilder(
          animation: _openness,
          builder: (context, _) {
            final open = roomForTwo ? _openness.value : 0.0;
            // The column shrinks and the seam rides in with it. Both scale by
            // the same factor, so the row's total width reaches zero smoothly
            // — dropping a full-width divider on the last frame instead would
            // hand what is beside it 13 more points in one step.
            final columnWidth = width * open;
            final seamWidth = PaneDivider.hitWidth * open;
            // Two columns or one, and folding is not what decides it. A folded
            // column is one the user put away; a window too narrow for two is
            // one that was never on offer, and only the second is something
            // the other half has to find room for the list itself.
            //
            // Told `split: false` on a fold, a surface puts the list back as a
            // tab — the list, on screen, one tap from where it was just hidden
            // from — and rebuilds its whole layout to do it, which is the
            // flicker. A detail pane fares worse: its `Expanded` stops being
            // built at all and the pane leaves the tree, so folding the list
            // away emptied the window instead of giving the pane the width.
            //
            // So the fold moves a width, from `width` to zero, inside a row
            // whose shape does not change.
            final split = roomForTwo;

            // Which half a narrow window keeps, and the only place the two
            // constructors lay out differently. Each keeps whichever half it
            // is the one that cannot simply be rebuilt elsewhere.
            final keepsList = widget._isDetail;

            final row = Row(
              // Stretched, or every column is as tall as what is in it: the
              // default centres them and hands each a loose height, under
              // which a page's own scroll view takes the height of its
              // contents — so a list longer than the window ended partway
              // down it and was cut off there rather than scrolling. The
              // split view this replaced stretched its areas for free.
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (keepsList || split)
                  SizedBox(
                    // Full width when it is the only column: the list is the
                    // page then, and `Expanded` here instead would be a
                    // different widget in the same slot — the subtree would be
                    // rebuilt every time a window crossed the breakpoint.
                    width: split ? columnWidth : constraints.maxWidth,
                    child: ClipRect(
                      // Laid out at its resting width and cut to what is
                      // showing. Given the animated width directly, every row
                      // inside would re-wrap on the way out — a list reflowing
                      // as it closes, and 60 relayouts of it to watch.
                      child: OverflowBox(
                        alignment: Alignment.centerLeft,
                        minWidth: split ? width : constraints.maxWidth,
                        maxWidth: split ? width : constraints.maxWidth,
                        child: Builder(
                          builder: (ctx) => widget.listBuilder(ctx, split),
                        ),
                      ),
                    ),
                  ),
                if (split)
                  // Only the real divider drags, and only when the column is
                  // at rest. Mid-fold it is a plain line instead: the same
                  // line in the same place, narrowing and fading with
                  // everything else, with no grab area to offer for the tenth
                  // of a second it is on screen. The two are identical at
                  // `open == 1`, which is the only moment either has to match
                  // the other.
                  if (open == 1)
                    PaneDivider(onDrag: _onSeamDrag, onDragEnd: _onSeamDragEnd)
                  else
                    SizedBox(
                      width: seamWidth,
                      child: Center(
                        child: ColoredBox(
                          // Held solid for the first half of the fold and gone
                          // by the end of it. Faded across the whole of it, a
                          // line that is merely *moving* would spend most of
                          // that time looking half-erased.
                          color: Hairline.color(context).withValues(
                            alpha:
                                Hairline.color(context).a *
                                (open * 2).clamp(0.0, 1.0),
                          ),
                          child: const SizedBox(
                            width: Hairline.thickness,
                            height: double.infinity,
                          ),
                        ),
                      ),
                    ),
                if (!keepsList || split)
                  // Keyed so that the column appearing beside it reads as this
                  // subtree staying put with a sibling inserted before it, not
                  // as something new that happens to look familiar — the
                  // difference is whether everything it holds is disposed and
                  // rebuilt. Which is the whole reason a surface is laid out
                  // this way; a detail is a route and is rebuilt regardless.
                  Expanded(
                    key: const ValueKey('adaptive_panes.content'),
                    child: Builder(
                      builder: (ctx) => _buildContent(ctx, split),
                    ),
                  ),
              ],
            );

            // No grip where a second column was never on offer: at this width
            // the list and the surface share one, and folding away something
            // that is not a column means nothing.
            if (!roomForTwo || onCollapsed == null) return row;

            return Stack(
              children: [
                row,
                // Rides the fold, so it arrives at the edge exactly as the
                // column finishes leaving. Placed from the animated width
                // rather than animated itself — its own curve would run beside
                // this one, and trail the divider while that is dragged.
                Positioned(
                  // Centred on the seam while there is one, and against the
                  // edge once there is not, which is all the clamp does: the
                  // line is gone by the time it bites.
                  left:
                      (columnWidth +
                              seamWidth / 2 -
                              PaneCollapseHandle.width / 2)
                          .clamp(0.0, double.infinity),
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: PaneCollapseHandle(
                      collapsed: widget.collapsed,
                      tooltip: widget.collapsed
                          ? widget.expandTooltip
                          : widget.collapseTooltip,
                      onTap: () => onCollapsed(!widget.collapsed),
                      onDrag: _onSeamDrag,
                      onDragEnd: _onSeamDragEnd,
                    ),
                  ),
                ),
              ],
            );
          },
        );

        // Only a pane has one. A surface reaches nothing through a navigator
        // key, and `split` for it is the argument its own builder is given.
        if (!widget._isDetail) return body;

        return PaneScope(
          // Above both children on purpose: the list has to be able to reach
          // the detail pane's navigator, and that lookup only travels upwards.
          navigatorKey: _navigatorKey,
          split: wideEnough,
          closeDetail: widget.onCloseDetail,
          child: body,
        );
      },
    );
  }
}

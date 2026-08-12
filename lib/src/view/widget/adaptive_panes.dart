import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';
import 'package:multi_split_view/multi_split_view.dart';

/// A list beside what it opens, when there is room, and the list alone when
/// there is not.
///
/// Both layouts run the same code. The difference is only where the detail
/// ends up: in the pane next to the list, or pushed over it. Callers express
/// that with [NavTarget.pane] and never test the width themselves — see
/// [PaneScope].
///
/// Deliberately two panes and not N. The app's outermost column is its
/// navigation rail, which already exists and has nothing to do with this
/// widget; a general N-pane engine would be built for a case nobody has.
class AdaptivePanes extends StatefulWidget {
  const AdaptivePanes({
    super.key,
    required this.primaryBuilder,
    required this.detailBuilder,
    this.detailId,
    this.onCloseDetail,
    this.enabled = true,
    this.minWidthForDetail = 800,
    this.primaryWidth = 320,
    this.minPrimaryWidth = 220,
    this.maxPrimaryWidth = 520,
    this.onPrimaryWidthChanged,
  });

  /// The list. Always on screen.
  ///
  /// Told whether it is sharing the width, because a list that is a browsing
  /// grid at full width should be a narrow index when it is a column beside
  /// something else — and only this widget knows which it is.
  final Widget Function(BuildContext context, bool split) primaryBuilder;

  /// The pane's root page, or null when nothing is selected.
  ///
  /// Null collapses to [primary] at full width, which is what an app looks
  /// like before the user has opened anything.
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

  /// Off forces the single-pane layout at any width, for the setting that
  /// lets someone say they simply do not want this.
  final bool enabled;

  /// Below this the detail cannot earn a column. Set for the narrowest device
  /// that should still get two: an 11" iPad in portrait is 834pt.
  final double minWidthForDetail;

  /// Starting width of the list. The user can drag from there.
  final double primaryWidth;

  /// How narrow and how wide dragging may make the list.
  final double minPrimaryWidth;
  final double maxPrimaryWidth;

  /// Called once the drag ends, not while it runs: persisting the width would
  /// otherwise be a write per frame.
  final ValueChanged<double>? onPrimaryWidthChanged;

  @override
  State<AdaptivePanes> createState() => _AdaptivePanesState();
}

class _AdaptivePanesState extends State<AdaptivePanes> {
  /// One navigator, one key, and exactly one widget holding it at a time.
  ///
  /// The collapse used to cross-fade, which meant the outgoing and incoming
  /// subtrees were both mounted for the length of the animation — and both
  /// carried this key. A `GlobalKey` cannot be in two live places, so the
  /// framework threw as soon as anything made the pane rebuild during that
  /// window. Swapping without an animation is the price of the pane being a
  /// real navigator rather than a rendered widget.
  final _navigatorKey = GlobalKey<NavigatorState>();

  /// Held in state so a drag survives the rebuilds that selecting a different
  /// item causes. Passing `initialAreas` on every build would snap the divider
  /// back to where it started every time the user picked something.
  late final _splitCtrl = MultiSplitViewController(
    areas: [
      Area(
        size: widget.primaryWidth,
        min: widget.minPrimaryWidth,
        max: widget.maxPrimaryWidth,
        builder: (context, _) => widget.primaryBuilder(context, true),
      ),
      Area(
        flex: 1,
        builder: (context, _) {
          // Read on every build rather than captured once: the areas outlive
          // any particular selection, and a rebuild of the pane while it is
          // being closed would otherwise dereference a detail that is gone.
          final detail = widget.detailBuilder;
          if (detail == null) return const SizedBox.shrink();
          return NestedNavigator(
            navigatorKey: _navigatorKey,
            rootBuilder: detail,
            rootId: widget.detailId,
          );
        },
      ),
    ],
  );

  @override
  void dispose() {
    _splitCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final detail = widget.detailBuilder;
        // Two different questions, and conflating them deadlocks: "will
        // opening something land it beside the list" is about the width, while
        // "is there something to show" is about the selection. Reporting the
        // second as the first means a list that only selects once a pane is on
        // screen can never put anything on it.
        final canSplit =
            widget.enabled &&
            constraints.maxWidth >= widget.minWidthForDetail;
        final showDetail = canSplit && detail != null;

        return PaneScope(
          // Above both children on purpose: the list has to be able to reach
          // the detail pane's navigator, and that lookup only travels upwards.
          navigatorKey: _navigatorKey,
          split: canSplit,
          closeDetail: widget.onCloseDetail,
          child: showDetail
              ? MultiSplitViewTheme(
                  // A hairline in the surface's own outline colour. The
                  // default divider is drawn for a light background and reads
                  // as a bright seam on a dark one.
                  data: MultiSplitViewThemeData(
                    dividerThickness: 1,
                    // The line stays thin; the grab area does not, because a
                    // 1px target is not something a pointer can find.
                    dividerHandleBuffer: 6,
                    dividerPainter: DividerPainters.background(
                      // Translucent: the seam separates two halves of one
                      // surface, and at full strength it reads as a border
                      // around each of them. The highlight stays solid, so
                      // that grabbing it is unmistakable.
                      color: Theme.of(
                        context,
                      ).colorScheme.outlineVariant.withValues(alpha: 0.35),
                      highlightedColor: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  child: MultiSplitView(
                    axis: Axis.horizontal,
                    controller: _splitCtrl,
                    onDividerDragEnd: (_) {
                      final size = _splitCtrl.areas.firstOrNull?.size;
                      if (size != null) {
                        widget.onPrimaryWidthChanged?.call(size);
                      }
                    },
                  ),
                )
              : Builder(
                  builder: (ctx) => widget.primaryBuilder(ctx, false),
                ),
        );
      },
    );
  }
}

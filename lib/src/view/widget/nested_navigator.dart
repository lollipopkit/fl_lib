import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';

/// A region of the screen that keeps its own navigation stack.
///
/// Used for a detail pane, and for a tab whose surroundings should stay put
/// while you move around inside it: a page pushed here covers the region, not
/// the window, so the navigation bar or rail that got you here is still there.
///
/// A navigator rather than a slot to drop a widget into, because the pages
/// shown here are the same pages the app pushes full-screen elsewhere: they
/// call `context.pop()`, return values, push further pages of their own. Give
/// them a real stack and none of that has to know where it is displayed.
///
/// The root is [rootBuilder]. When [rootId] changes the stack resets to a
/// fresh root — selecting a different server must not leave the previous one's
/// edit page sitting on top.
class NestedNavigator extends StatefulWidget {
  const NestedNavigator({
    super.key,
    this.navigatorKey,
    required this.rootBuilder,
    this.rootId,
    this.observers = const [],
  });

  /// Shared with an enclosing [PaneScope] when there is one, which is how a
  /// widget beside a pane reaches the navigator inside it.
  ///
  /// Null when the region has no such neighbour — a tab, say — and one is then
  /// created in the state. Not in the constructor: a widget is rebuilt many
  /// times, and a fresh key each time would tear down and recreate everything
  /// under it, once per frame of whatever animation is running.
  final GlobalKey<NavigatorState>? navigatorKey;

  final WidgetBuilder rootBuilder;

  /// Identity of what the root shows. A change replaces the root and clears
  /// anything above it.
  final Object? rootId;

  final List<NavigatorObserver> observers;

  @override
  State<NestedNavigator> createState() => _NestedNavigatorState();
}

class _NestedNavigatorState extends State<NestedNavigator> {
  late final _navigatorKey =
      widget.navigatorKey ?? GlobalKey<NavigatorState>();

  /// What the current root page is keyed by.
  ///
  /// Its own object rather than [NestedNavigator.rootId], because the same id
  /// can be selected again after another one and the two roots would then
  /// share a key — which the navigator reads as the page never having
  /// changed.
  Object _pageKey = Object();

  /// Whether the change now being animated is a way *back*.
  ///
  /// Going to no selection at all is: the pane is being closed, not opened on
  /// something else. Read once by the delegate below, per change.
  bool _backwards = false;

  @override
  void didUpdateWidget(NestedNavigator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.rootId == oldWidget.rootId) return;
    setState(() {
      _pageKey = Object();
      _backwards = widget.rootId == null && oldWidget.rootId != null;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Back belongs to whichever navigator has somewhere to go. Inside this
    // region that is this stack; at its root there is nothing to pop, and
    // swallowing the gesture there would strand the user on a screen the
    // button appears to be for.
    return NavigatorPopHandler(
      // The route may have a PopScope of its own. `pop` removes it regardless
      // of that scope's disposition, which can empty this navigator's only
      // route and leave the region blank. `maybePop` lets the route reject the
      // gesture and deliver its callback instead.
      onPopWithResult: (_) => _navigatorKey.currentState?.maybePop(),
      child: Navigator(
        key: _navigatorKey,
        observers: widget.observers,
        transitionDelegate: _backwards
            ? const _BackwardsTransitionDelegate()
            : const DefaultTransitionDelegate<void>(),
        // Declared rather than pushed. Told to replace the root with
        // `pushAndRemoveUntil`, the navigator has no way to know whether that
        // was a way in or a way out, and animated every one of them as a way
        // in: closing a pane looked like the empty pane being opened over the
        // page being left. A page list is a description, and the delegate
        // below is where the direction is said.
        //
        // It also retires a workaround. Rebuilding a `Navigator` used to
        // rebuild the page of *every* route in its stack, so the route on its
        // way out ran `rootBuilder` again and rendered whatever was selected
        // *now* — the incoming page, twice, for the length of the transition.
        // A `Page`'s child is a value: the outgoing route keeps the one it was
        // given.
        pages: [
          MaterialPage<void>(
            key: ValueKey(_pageKey),
            name: '${widget.rootId}',
            child: Builder(builder: widget.rootBuilder),
          ),
        ],
        // Pages are replaced here, never popped one at a time — a root going
        // away takes the whole stack with it. Nothing to do, and required.
        onDidRemovePage: (_) {},
      ),
    );
  }
}

/// Runs a page replacement as a way back rather than a way in.
///
/// The arriving page is added underneath with no transition of its own, and
/// the departing one pops over it — which is what a back *is*, and so gets the
/// platform's own back animation rather than an imitation of it.
///
/// Anything pushed on top of the departing page goes without a transition: it
/// is above the page that is animating out, so a second animation there would
/// be two pages leaving in different directions.
class _BackwardsTransitionDelegate extends TransitionDelegate<void> {
  const _BackwardsTransitionDelegate();

  @override
  Iterable<RouteTransitionRecord> resolve({
    required List<RouteTransitionRecord> newPageRouteHistory,
    required Map<RouteTransitionRecord?, RouteTransitionRecord>
    locationToExitingPageRoute,
    required Map<RouteTransitionRecord?, List<RouteTransitionRecord>>
    pageRouteToPagelessRoutes,
  }) {
    final results = <RouteTransitionRecord>[];

    // The new root first, so it ends up *below* what is leaving. This is the
    // whole of the difference from the default, which puts the exiting route
    // at the bottom and pushes the new one over it.
    for (final entering in newPageRouteHistory) {
      if (entering.isWaitingForEnteringDecision) entering.markForAdd();
      results.add(entering);
    }

    for (final exiting in locationToExitingPageRoute.values) {
      if (exiting.isWaitingForExitingDecision) {
        for (final pageless in pageRouteToPagelessRoutes[exiting] ?? const []) {
          if (pageless.isWaitingForExitingDecision) {
            pageless.markForComplete(pageless.route.currentResult);
          }
        }
        exiting.markForPop(exiting.route.currentResult);
      }
      results.add(exiting);
    }

    return results;
  }
}

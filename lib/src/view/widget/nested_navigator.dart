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

  /// Which root route [rootBuilder] currently describes.
  ///
  /// Rebuilding a `Navigator` rebuilds the page of *every* route in its stack:
  /// the framework calls `changedExternalState` on all of them, which drops
  /// each route's cached page. So the route on its way out ran [rootBuilder]
  /// again and rendered whatever was selected *now* — putting the newly picked
  /// page on screen twice, once immediately underneath and once more as the
  /// incoming route animated in over it. Two of everything for the length of
  /// the transition, and two of any work the page does when it is created.
  Object? _current;

  @override
  void didUpdateWidget(NestedNavigator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.rootId == oldWidget.rootId) return;
    // Replaces rather than pushes: what was on the stack belonged to the
    // previous root, and a back gesture into another server's edit page would
    // be a surprise at best.
    _navigatorKey.currentState?.pushAndRemoveUntil(
      _rootRoute(),
      (route) => false,
    );
  }

  /// The platform's own page transition, via [MaterialPageRoute].
  ///
  /// A hand-rolled fade read better for a lateral move — one item of a list to
  /// another is neither further in nor back out — but it was also a second
  /// implementation of something the framework already does, and the
  /// framework's is the one that has been through every case.
  Route<void> _rootRoute() {
    // Identity of this route, held so the builder below can tell whether it is
    // still the one the caller is describing. The id cannot answer that: the
    // same one can be selected again after another, and both routes would then
    // claim to be current.
    final token = _current = Object();
    Widget? shown;
    return MaterialPageRoute<void>(
      settings: RouteSettings(name: '${widget.rootId}'),
      builder: (context) {
        // Superseded, so this route is on its way out. It keeps what it last
        // showed until it is removed — the same widget instance, which leaves
        // the outgoing page's subtree untouched rather than rebuilding it into
        // the incoming page's content.
        if (!identical(_current, token)) {
          return shown ?? const SizedBox.shrink();
        }
        return shown = widget.rootBuilder(context);
      },
    );
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
        onGenerateRoute: (_) => _rootRoute(),
      ),
    );
  }
}

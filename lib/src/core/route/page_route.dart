import 'package:material_ui/material_ui.dart';

/// A back gesture belongs to the page on screen, and only to it.
///
/// Flutter hands a predictive back gesture — Android's, and the edge swipe
/// [SwipeBackPageTransitionsBuilder] turns into one — to every route that is
/// current in *its own* navigator, and each one it was given pops. A page in a
/// nested navigator stays current there when something is pushed over the
/// whole window, when a dialog opens over it, and when its tab or pane is not
/// the one in use. One swipe then took the page on screen and every such page
/// with it: a settings level, a tab's page, another pane's page.
///
/// This makes the gesture go where back goes: see [isRouteOnScreen].
mixin OnScreenPopGestureRoute<T> on PageRoute<T> {
  @override
  bool get popGestureEnabled => super.popGestureEnabled && isRouteOnScreen(this);
}

/// Whether back reaches [route]: it is current in its navigator, the route
/// holding that navigator is current in its own, and so on up to the root, and
/// no [BackScope] on the way turns it off.
///
/// The route chain says whether anything covers it — a page, a dialog, a sheet.
/// A [BackScope] says what the chain cannot: which of several navigators that
/// are all uncovered is the one in use — the tab shown, the pane focused.
bool isRouteOnScreen(ModalRoute<dynamic> route) {
  if (!route.isCurrent) return false;
  var navigator = route.navigator;
  while (navigator != null) {
    final context = navigator.context;
    if (!BackScope.enabledAt(context)) return false;
    // The route this navigator is inside; null for the root. A dependency on
    // that route's `isCurrent` only, which is what is asked.
    if (ModalRoute.isCurrentOf(context) == false) return false;
    navigator = context.findAncestorStateOfType<NavigatorState>();
  }
  return true;
}

/// Whether back inside [child] goes to the navigators there: the pages'
/// gestures ([OnScreenPopGestureRoute]) and a [NestedNavigator]'s pop.
///
/// For a region that is uncovered but not the one in use — a tab kept alive
/// while another is shown, a pane that is not focused, a view hidden behind
/// another. Off anywhere above turns it off below.
class BackScope extends StatelessWidget {
  const BackScope({super.key, required this.enabled, required this.child});

  final bool enabled;
  final Widget child;

  /// Whether back reaches [context]'s region. Creates no dependency: see [of].
  static bool enabledAt(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_BackScopeData>()?.enabled ?? true;

  /// [enabledAt], depending on it.
  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_BackScopeData>()?.enabled ?? true;

  @override
  Widget build(BuildContext context) =>
      _BackScopeData(enabled: enabled && of(context), child: child);
}

class _BackScopeData extends InheritedWidget {
  const _BackScopeData({required this.enabled, required super.child});

  final bool enabled;

  @override
  bool updateShouldNotify(_BackScopeData oldWidget) => enabled != oldWidget.enabled;
}

/// [MaterialPageRoute], with the back gesture only for the page on screen —
/// see [OnScreenPopGestureRoute]. What `AppRoute.go` pushes.
class AppPageRoute<T> extends MaterialPageRoute<T> with OnScreenPopGestureRoute<T> {
  AppPageRoute({
    required super.builder,
    super.settings,
    super.requestFocus,
    super.maintainState,
    super.fullscreenDialog,
    super.allowSnapshotting,
    super.barrierDismissible,
    super.traversalEdgeBehavior,
    super.directionalTraversalEdgeBehavior,
  });
}

/// [MaterialPage], with the back gesture only for the page on screen — see
/// [OnScreenPopGestureRoute]. For a navigator's declared pages.
class AppPage<T> extends MaterialPage<T> {
  const AppPage({
    required super.child,
    super.maintainState,
    super.fullscreenDialog,
    super.allowSnapshotting,
    super.key,
    super.canPop,
    super.onPopInvoked,
    super.name,
    super.arguments,
    super.restorationId,
  });

  @override
  Route<T> createRoute(BuildContext context) =>
      _PageBasedAppRoute<T>(page: this, allowSnapshotting: allowSnapshotting);
}

/// Flutter's own page-based route for a [MaterialPage], which is private.
class _PageBasedAppRoute<T> extends PageRoute<T>
    with MaterialRouteTransitionMixin<T>, OnScreenPopGestureRoute<T> {
  _PageBasedAppRoute({required AppPage<T> page, super.allowSnapshotting}) : super(settings: page) {
    assert(opaque);
  }

  AppPage<T> get _page => settings as AppPage<T>;

  @override
  Widget buildContent(BuildContext context) => _page.child;

  @override
  bool get maintainState => _page.maintainState;

  @override
  bool get fullscreenDialog => _page.fullscreenDialog;

  @override
  String get debugLabel => '${super.debugLabel}(${_page.name})';
}

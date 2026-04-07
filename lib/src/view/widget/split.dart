import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';
import 'package:multi_split_view/multi_split_view.dart';
import 'dart:async';

// Helper class to store a widget and its completer for results
class _RouteEntry<T> {
  final Widget widget;
  final Completer<T?> completer;

  _RouteEntry(this.widget, this.completer);
}

/// {@template split_view_controller}
/// The controller of [SplitView]
/// It manages the navigation stack of the right pane.
/// {@endtemplate}
class SplitViewController {
  /// Notifier for the currently visible widget on the right pane
  late final VNode<List<_RouteEntry<dynamic>>> routes;

  /// Initializes the controller with the initial right widget.
  SplitViewController({Widget initialRight = UIs.placeholder}) {
    routes = [_RouteEntry<dynamic>(initialRight, Completer<dynamic>())].vn;
  }

  /// Track the last operation direction for animation purposes
  bool _isPushing = true;

  /// Tracks whether an animation is currently in progress
  bool _isAnimating = false;

  /// AnimationController reference - will be set by SplitView widget
  AnimationController? _animationController;

  /// Sets the animation controller reference
  @protected
  void _setAnimationController(AnimationController controller) {
    _animationController = controller;
  }

  /// Pushes a new [page] onto the right view stack.
  /// Returns a Future that completes with a result when the pushed page is popped.
  Future<T?> push<T extends Object?>(Widget page) async {
    // Don't allow operations during animation
    if (_isAnimating) return null;

    _isPushing = true;
    _isAnimating = true;

    final completer = Completer<T?>();
    final newEntry = _RouteEntry<T>(page, completer);

    // Update the stack in single operation to reduce rebuilds
    final newRoutes = List<_RouteEntry<dynamic>>.from(routes.value)..add(newEntry);
    routes.value = newRoutes;

    // Wait for animation to complete
    if (_animationController != null) {
      await _runAnimation();
    }

    _isAnimating = false;
    return completer.future;
  }

  /// Removes the top page from the right view stack, revealing the previous page.
  /// Does nothing if only the initial page is present.
  /// The [result] is passed to the Future returned by the corresponding `push` call.
  /// Returns a Future that completes when the animation finishes.
  Future<void> pop<T extends Object?>([T? result]) async {
    if (!canPop || _isAnimating) return;

    _isPushing = false;
    _isAnimating = true;

    // Update the stack in single operation to reduce rebuilds
    final currentEntries = List<_RouteEntry<dynamic>>.from(routes.value);
    final poppedEntry = currentEntries.removeLast();
    routes.value = currentEntries;

    // Wait for animation to complete
    if (_animationController != null) {
      await _runAnimation();
    }

    _isAnimating = false;
    poppedEntry.completer.complete(result);
    return;
  }

  /// Replaces the top page of the right view stack with a new page.
  /// The Future of the replaced page is completed with `null`.
  /// Returns a Future for the new page that completes with a result when it's popped.
  Future<T?> replace<T extends Object?>(Widget page) async {
    // Don't allow operations during animation
    if (_isAnimating) return null;

    // Need at least one route to replace
    if (routes.value.isEmpty) return null;

    // Compare the new page with the current top page by the key
    final lastEntry = routes.value.last;
    final lastWidget = lastEntry.widget;
    if (lastWidget.runtimeType == page.runtimeType && lastWidget.key == page.key) {
      return Future.value(null as T?);
    }

    _isPushing = true;
    _isAnimating = true;

    final newPageCompleter = Completer<T?>();
    final newEntry = _RouteEntry<T>(page, newPageCompleter);

    // Update the stack in single operation to reduce rebuilds
    final currentEntries = List<_RouteEntry<dynamic>>.from(routes.value);
    final oldEntry = currentEntries.removeLast();
    currentEntries.add(newEntry);
    routes.value = currentEntries;

    // Wait for animation to complete
    if (_animationController != null) {
      await _runAnimation();
    }

    _isAnimating = false;
    oldEntry.completer.complete(null);
    return newPageCompleter.future;
  }

  /// Runs the animation sequence
  ///
  /// Extracted to a separate method to avoid duplication
  Future<void> _runAnimation() async {
    _animationController!.reset();
    return _animationController!.forward().orCancel.catchError(
          (_) => Future<void>.value(),
          test: (error) => error is TickerCanceled,
        );
  }

  /// Returns true if the right view stack can be popped (i.e., contains more than one page).
  bool get canPop => routes.value.length > 1;
         
  /// Disposes the controller and its resources.
  void dispose() {
    // Complete any pending completers to avoid leaks if controller is disposed early.
    for (var entry in routes.value) {
      if (!entry.completer.isCompleted) {
        entry.completer.complete(null);
      }
    }
    routes.dispose();
  }
}

/// {@template split_view_scope}
/// InheritedWidget to provide SplitViewController down the tree
/// {@endtemplate}
class _SplitViewScope extends InheritedWidget {
  /// {@macro split_view_controller}
  final SplitViewController controller;

  /// {@macro split_view_scope}
  const _SplitViewScope({
    required this.controller,
    required super.child,
  });

  /// Finds the nearest [SplitViewController] ancestor in the widget tree.
  static SplitViewController? of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<_SplitViewScope>()?.controller;
  }

  @override
  bool updateShouldNotify(_SplitViewScope oldWidget) {
    return controller != oldWidget.controller;
  }
}

final class SplitViewNavigatorArgs {
  /// Whether to use the Flutter Navigator for navigation as **fallback**.
  final bool fallbackFlutterNavigator;

  /// Constructor for [SplitViewNavigatorArgs].
  const SplitViewNavigatorArgs({
    this.fallbackFlutterNavigator = true,
  });
}

/// Provides navigation control for the right pane of a `SplitView`.
/// Similar to `Navigator`, but operates specifically on the `SplitView`'s right pane.
class SplitViewNavigator {
  /// Finds the nearest `SplitViewController` ancestor and returns it.
  /// Throws an error if no `SplitViewController` is found.
  static SplitViewController? of(BuildContext context) {
    final controller = _SplitViewScope.of(context);
    assert(controller != null, 'SplitViewNavigator.of() called with a context that does not contain a SplitView.');
    return controller;
  }

  /// Pushes a new [page] onto the right pane's navigation stack.
  /// Returns a Future that completes with a result when the pushed page is popped.
  static Future<T?> push<T extends Object?>(
    BuildContext context,
    Widget page,
  ) async {
    final ctrl = of(context);
    if (ctrl == null) {
      throw Exception('No SplitViewController found in context for push.');
    }
    return ctrl.push<T>(page);
  }

  /// Navigates to the specified route with no arguments in the split view.
  /// Returns a Future that completes with a result when the page is popped.
  static Future<Ret?> pushRoute<Ret>(
    BuildContext context,
    AppRouteNoArg<Ret> route, {
    Key? key,
  }) async {
    final ctrl = of(context);
    if (ctrl == null) {
      throw Exception('No SplitViewController found in context for pushRoute.');
    }
    return ctrl.push<Ret>(route.page(key: key));
  }

  /// Navigates to the specified route with optional arguments in the split view.
  /// Returns a Future that completes with a result when the page is popped.
  static Future<Ret?> pushRouteWithOptionalArg<Ret, Arg extends Object>(
    BuildContext context,
    AppRoute<Ret, Arg> route, {
    Key? key,
    Arg? args,
  }) async {
    final ctrl = of(context);
    if (ctrl == null) {
      throw Exception('No SplitViewController found in context for pushRouteWithOptionalArg.');
    }
    return ctrl.push<Ret>(route.page(key: key, args: args));
  }

  /// Navigates to the specified route with required arguments in the split view.
  /// Returns a Future that completes with a result when the page is popped.
  static Future<Ret?> pushRouteWithArg<Ret, Arg extends Object>(
    BuildContext context,
    AppRouteArg<Ret, Arg> route,
    Arg args, {
    Key? key,
  }) async {
    final ctrl = of(context);
    if (ctrl == null) {
      throw Exception('No SplitViewController found in context for pushRouteWithArg.');
    }
    return ctrl.push<Ret>(route.page(key: key, args: args));
  }

  /// Pops the top page from the right pane's navigation stack.
  /// The [result] is passed to the Future returned by the corresponding `push` call.
  /// Returns a Future that completes when the animation finishes.
  static Future<void> pop<T extends Object?>(BuildContext context, [T? result]) {
    final ctrl = of(context);
    if (ctrl == null) {
      throw Exception('No SplitViewController found in context for pop.');
    }
    return ctrl.pop<T>(result);
  }

  /// Replaces the top page of the right pane's navigation stack with a new page.
  /// The Future of the replaced page is completed with `null`.
  /// Returns a Future for the new page that completes with a result when it's popped.
  static Future<T?> replace<T extends Object?>(BuildContext context, Widget page) {
    final ctrl = of(context);
    if (ctrl == null) {
      throw Exception('No SplitViewController found in context for replace.');
    }
    return ctrl.replace<T>(page);
  }

  /// Checks if the right pane's navigation stack can be popped.
  static bool? canPop(BuildContext context) {
    return of(context)?.canPop;
  }
}

/// {@template split_view}
/// A split view that allows for a split-screen layout with a left and right pane.
/// {@endtemplate}
class SplitView extends StatefulWidget {
  /// The controller for managing the split view's navigation.
  final SplitViewController? controller;

  /// A widget that provides a split view layout with a left and right pane.
  final AreaWidgetBuilder leftBuilder;

  /// The initial widget displayed on the right side of the split view.
  final Widget initialRight;

  /// The weight of the left pane in the split view.
  final double leftWeight;

  /// The weight of the right pane in the split view.
  final double rightWeight;

  /// The animation curve for the transition between pages.
  final Curve curve;

  /// The duration of the transition animation.
  final Duration duration;

  /// {@macro split_view}
  const SplitView({
    super.key,
    this.controller,
    required this.leftBuilder,
    required this.initialRight,
    this.leftWeight = 0.3,
    this.rightWeight = 0.7,
    this.curve = Curves.fastEaseInToSlowEaseOut,
    this.duration = Durations.medium3,
  });

  @override
  State<SplitView> createState() => _SplitViewState();
}

class _SplitViewState extends State<SplitView> with SingleTickerProviderStateMixin {
  late final controller = widget.controller ?? SplitViewController(initialRight: widget.initialRight);
  late final AnimationController _animationController;
  late final Animation<double> _animation;
  Widget? _previousWidget;
  Widget? _currentWidget;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: widget.duration,
    );

    // Share animation controller with the SplitViewController
    controller._setAnimationController(_animationController);

    _animation = CurvedAnimation(
      parent: _animationController,
      curve: widget.curve,
    );

    // Initialize with initial right widget
    _currentWidget = controller.routes.value.lastOrNull?.widget ?? widget.initialRight;

    // Listen for route changes
    controller.routes.addListener(_handleRouteChange);
  }

  void _handleRouteChange() {
    setState(() {
      _previousWidget = _currentWidget;
      _currentWidget = controller.routes.value.lastOrNull?.widget ?? widget.initialRight;
    });
  }

  @override
  void dispose() {
    controller.routes.removeListener(_handleRouteChange);
    if (widget.controller == null) {
      controller.dispose();
    }
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final multiSplitView = MultiSplitView(
      axis: Axis.horizontal,
      initialAreas: [
        _leftArea,
        _rightArea,
      ],
    );

    final theme = MultiSplitViewTheme(
      data: MultiSplitViewThemeData(
        dividerPainter: DividerPainters.grooved1(
          color: UIs.bgColor.resolve(context),
          highlightedColor: Theme.of(context).colorScheme.primary,
        ),
      ),
      child: multiSplitView,
    );

    return _SplitViewScope(
      controller: controller,
      child: theme,
    );
  }

  Area get _leftArea {
    return Area(
      flex: widget.leftWeight,
      builder: widget.leftBuilder,
    );
  }

  Area get _rightArea {
    return Area(
      flex: widget.rightWeight,
      builder: (context, area) => AnimatedBuilder(
        animation: _animation,
        builder: (context, _) {
          final currentDisplayWidget = _currentWidget ?? widget.initialRight;
          final previousDisplayWidget = _previousWidget;

          return Stack(
            children: [
              if (previousDisplayWidget != null && controller._isPushing == false && _animationController.isAnimating)
                SlideTransition(
                  position: Tween<Offset>(
                    begin: Offset.zero,
                    end: const Offset(1.0, 0.0),
                  ).animate(_animation),
                  child: FadeTransition(
                    opacity: Tween<double>(begin: 1.0, end: 0.0).animate(_animation),
                    child: KeyedSubtree(
                      key: ValueKey(previousDisplayWidget),
                      child: previousDisplayWidget,
                    ),
                  ),
                ),
              SlideTransition(
                position: Tween<Offset>(
                  begin: _animationController.isAnimating && controller._isPushing
                      ? const Offset(1.0, 0.0)
                      : _animationController.isAnimating && !controller._isPushing
                          ? const Offset(-1.0, 0.0)
                          : Offset.zero,
                  end: Offset.zero,
                ).animate(_animation),
                child: FadeTransition(
                  opacity: Tween<double>(begin: _animationController.isAnimating ? 0.0 : 1.0, end: 1.0).animate(_animation),
                  child: KeyedSubtree(
                    key: ValueKey(currentDisplayWidget),
                    child: currentDisplayWidget,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

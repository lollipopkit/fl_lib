import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';

part 'observer.dart';

/// Define it as a named record, makes it easier for refactor.
typedef Middleware<T extends AppRouteIface> = ({BuildContext context, T route});

/// Which navigator a route is pushed onto.
///
/// Exists because a pane layout has more than one navigator, and "push this
/// page" stops being an unambiguous instruction once it does.
enum NavTarget {
  /// The navigator that owns the calling context.
  ///
  /// Inside a pane that is the pane's own navigator. This is the default, and
  /// it is why an unchanged call site does the right thing in both layouts:
  /// pushed over the whole screen when there is only one, and within the pane
  /// when there are several.
  nearest,

  /// The root navigator, even when called from inside a pane.
  ///
  /// For pages that have to own the window rather than share it — a terminal,
  /// a full-screen viewer.
  root,

  /// The enclosing pane's navigator.
  ///
  /// For a widget beside the pane rather than inside it: a list that opens
  /// what it selects in the detail area next to it, instead of on top of
  /// itself. Falls back to [nearest] when there is no pane, which is exactly
  /// the single-page behaviour — with nothing beside it, "open in the detail
  /// area" and "open here" are the same instruction.
  pane,
}

/// {@template app_route_iface}
/// An app route.
/// {@endtemplate}
///
/// Sealed rather than open: the three shapes below differ only in what
/// arguments they take, and each one builds its page differently enough that a
/// shared `toWidget` on the base could only have thrown. It used to.
sealed class AppRouteIface {
  /// The path of the route.
  final String path;

  /// {@macro app_route_iface}
  const AppRouteIface({required this.path});

  /// Returns true if the current route is the same as this route.
  bool get alreadyIn => AppRouteObserver.currentRoute?.name == path;

  /// Returns the [RouteSettings] of the this route.
  RouteSettings get routeSettings => RouteSettings(name: path);
}

/// A route with non-null arguments.
final class AppRoute<Ret, Arg extends Object> extends AppRouteIface {
  final Widget Function({Key? key, Arg? args}) page;

  /// If [middlewares] returns false, the navigation will be canceled.
  final List<bool Function(Middleware<AppRoute<Ret, Arg>>)>? middlewares;

  /// {@macro app_route_iface}
  const AppRoute({required this.page, required super.path, this.middlewares});

  /// {@macro app_route_go}
  Future<Ret?> go(
    BuildContext context, {
    Key? key,
    Arg? args,
    PageRoute<Ret>? route,
    NavTarget target = NavTarget.nearest,
  }) {
    if (_rejected(middlewares, context, this)) return Future.value(null);
    return _push<Ret>(
      context,
      settings: routeSettings,
      build: (ctx) => _framed(ctx, page(key: key, args: args)),
      target: target,
      route: route,
    );
  }

  /// {@template app_route_to_widget}
  /// This route as a widget, for hosting it somewhere other than a route
  /// stack. Prefer [go] — see [PaneScope] for why a pane is a navigator and
  /// not a slot to drop a widget into.
  ///
  /// Framed on the same terms as a pushed page, so hosting one somewhere
  /// nested does not draw a second window caption.
  /// {@endtemplate}
  Widget toWidget({Key? key, Arg? args}) {
    return Builder(builder: (ctx) => _framed(ctx, page(key: key, args: args)));
  }
}

/// A route with required arguments.
final class AppRouteArg<Ret, Arg extends Object> extends AppRouteIface {
  final Widget Function({Key? key, required Arg args}) page;

  /// If [middlewares] returns false, the navigation will be canceled.
  final List<bool Function(Middleware<AppRouteArg<Ret, Arg>>)>? middlewares;

  /// {@macro app_route_iface}
  const AppRouteArg({
    required this.page,
    required super.path,
    this.middlewares,
  });

  /// {@macro app_route_go}
  Future<Ret?> go(
    BuildContext context,
    Arg args, {
    Key? key,
    PageRoute<Ret>? route,
    NavTarget target = NavTarget.nearest,
  }) {
    if (_rejected(middlewares, context, this)) return Future.value(null);
    return _push<Ret>(
      context,
      settings: routeSettings,
      build: (ctx) => _framed(ctx, page(key: key, args: args)),
      target: target,
      route: route,
    );
  }

  /// {@macro app_route_to_widget}
  Widget toWidget({Key? key, required Arg args}) {
    return Builder(builder: (ctx) => _framed(ctx, page(key: key, args: args)));
  }
}

/// A route without arguments.
final class AppRouteNoArg<Ret> extends AppRouteIface {
  final Widget Function({Key? key}) page;

  /// If [middlewares] returns false, the navigation will be canceled.
  final List<bool Function(Middleware<AppRouteNoArg<Ret>>)>? middlewares;

  /// {@macro app_route_iface}
  const AppRouteNoArg({
    required this.page,
    required super.path,
    this.middlewares,
  });

  /// {@macro app_route_go}
  Future<Ret?> go(
    BuildContext context, {
    Key? key,
    PageRoute<Ret>? route,
    NavTarget target = NavTarget.nearest,
  }) {
    if (_rejected(middlewares, context, this)) return Future.value(null);
    return _push<Ret>(
      context,
      settings: routeSettings,
      build: (ctx) => _framed(ctx, page(key: key)),
      target: target,
      route: route,
    );
  }

  /// {@macro app_route_to_widget}
  Widget toWidget({Key? key}) {
    return Builder(builder: (ctx) => _framed(ctx, page(key: key)));
  }
}

/// Whether [middlewares] vetoed the navigation.
bool _rejected<T extends AppRouteIface>(
  List<bool Function(Middleware<T>)>? middlewares,
  BuildContext context,
  T route,
) {
  return middlewares?.any((e) => !e((context: context, route: route))) == true;
}

/// The push the three route shapes share.
///
/// Takes a builder rather than a finished widget because the window-frame
/// decision needs the route's own context, which does not exist until the
/// route is being built.
Future<Ret?> _push<Ret>(
  BuildContext context, {
  required RouteSettings settings,
  required WidgetBuilder build,
  required NavTarget target,
  PageRoute<Ret>? route,
}) {
  final navigator = _navigatorFor(context, target);
  return navigator.push<Ret>(
    route ?? MaterialPageRoute<Ret>(builder: build, settings: settings),
  );
}

NavigatorState _navigatorFor(BuildContext context, NavTarget target) {
  return switch (target) {
    NavTarget.nearest => Navigator.of(context),
    NavTarget.root => Navigator.of(context, rootNavigator: true),
    // Deliberately falls back rather than asserting: a caller asking for the
    // detail pane on a phone wants the page opened, not an error.
    NavTarget.pane => PaneScope.navigatorOf(context) ?? Navigator.of(context),
  };
}

/// The desktop window frame, for pages that fill the window.
///
/// A page pushed onto a nested navigator does not: it covers a pane, or a tab
/// inside a shell that already has a frame of its own. Framing it again draws
/// a second caption bar below the first, which is height nothing asked for and
/// a title bar in the middle of the window.
Widget _framed(BuildContext context, Widget child) {
  final nearest = Navigator.maybeOf(context);
  final root = Navigator.maybeOf(context, rootNavigator: true);
  if (nearest != null && nearest != root) return child;
  return VirtualWindowFrame(child: child);
}

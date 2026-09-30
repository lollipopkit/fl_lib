import 'package:fl_lib/fl_lib.dart';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fl_lib/src/theme/package.dart';
import 'package:fl_lib/src/theme/style.dart';
import 'package:fl_lib/src/theme/host.dart';

/// The image or gradient the app stands on.
///
/// Drawn once behind the whole app — the pages over it are
/// [Colors.transparent] on purpose — and again inside a page while that page
/// is arriving or leaving, which is what [AppPageTransitions] is for.
class AppBackground extends StatelessWidget {
  const AppBackground({super.key, required this.child, this.visible = true});

  final Widget child;

  /// Whether the background is to be drawn here.
  ///
  /// Always for the one behind the app. Inside a page, only while the page is
  /// moving: at rest the page is transparent and the one behind the app is
  /// already what is being looked at.
  ///
  /// A page's copy is the window's background, not one fitted to the page: laid
  /// out at the window's size and placed where the window's is, cut to the
  /// page. A page in a pane covers part of the window, and a background fitted
  /// to that part is another picture — cropped elsewhere, its tiles starting
  /// elsewhere — which would jump into view as the page starts to move.
  final bool visible;

  @override
  Widget build(BuildContext context) {
    final preview = ThemePackages.preview.value;
    final style =
        preview?.backgroundStyle ?? ThemeHost.settings.appBackgroundStyle.fetch();
    final path = preview != null
        ? preview.backgroundPath ?? ''
        : ThemeHost.settings.appBackgroundPath.fetch();
    if (style == BackgroundStyle.none ||
        (style == BackgroundStyle.image && path.isEmpty)) {
      return child;
    }
    // The one behind the app has no other above it.
    final root = context.dependOnInheritedWidgetOfExactType<_BackgroundRoot>();
    final layer = _layer(context, style, path);
    // A `Stack` either way, and the background switched through an `Opacity`
    // rather than taken out of it: the child is a whole page, and a page
    // rebuilt from a different parent loses what it was holding — a scroll
    // position, a field being typed in — every time a transition starts.
    final stack = Stack(
      fit: StackFit.passthrough,
      children: [
        Positioned.fill(
          child: Opacity(
            opacity: visible ? 1 : 0,
            child: root == null
                ? layer
                : _WindowAligned(
                    root: root,
                    navigator: Navigator.maybeOf(context),
                    child: layer,
                  ),
          ),
        ),
        child,
      ],
    );
    if (root != null) return stack;
    return _BackgroundRoot(
      root: context,
      window: MediaQuery.sizeOf(context),
      child: stack,
    );
  }

  Widget _layer(BuildContext context, BackgroundStyle style, String path) {
    if (ThemePackages.preview.value case final preview?) {
      return BackgroundLayer.of(preview) ?? const SizedBox.shrink();
    }
    final settings = ThemeHost.settings;
    return BackgroundLayer(
      style: style,
      path: path,
      opacity: settings.appBackgroundOpacity.fetch(),
      blur: settings.appBackgroundBlur.fetch(),
      tile: settings.appBackgroundTile.fetch(),
    );
  }
}

/// The background behind the app, for the copies inside pages to line up with.
class _BackgroundRoot extends InheritedWidget {
  const _BackgroundRoot({
    required this.root,
    required this.window,
    required super.child,
  });

  /// The [AppBackground] behind the app; its box is the window's.
  final BuildContext root;
  final Size window;

  @override
  bool updateShouldNotify(_BackgroundRoot old) =>
      root != old.root || window != old.window;
}

/// A page's copy of the background, laid out at the window's size and painted
/// where the window's is, cut to the page.
///
/// Where the window's is: offset by where the page is at rest, which is where
/// its navigator is — a route's page fills its navigator, and the navigator is
/// not moved by its own routes' transitions. So at rest the copy is the same
/// pixels as the background behind the app, and moves with the page from
/// there.
class _WindowAligned extends SingleChildRenderObjectWidget {
  const _WindowAligned({
    required this.root,
    required this.navigator,
    required super.child,
  });

  final _BackgroundRoot root;
  final NavigatorState? navigator;

  @override
  _RenderWindowAligned createRenderObject(BuildContext context) =>
      _RenderWindowAligned(root.window, root.root, navigator);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderWindowAligned renderObject,
  ) {
    renderObject
      ..window = root.window
      ..root = root.root
      ..navigator = navigator;
  }
}

class _RenderWindowAligned extends RenderProxyBox {
  _RenderWindowAligned(this._window, this._root, this._navigator);

  Size _window;
  set window(Size value) {
    if (value == _window) return;
    _window = value;
    markNeedsLayout();
  }

  BuildContext _root;
  set root(BuildContext value) {
    if (value == _root) return;
    _root = value;
    markNeedsPaint();
  }

  NavigatorState? _navigator;
  set navigator(NavigatorState? value) {
    if (value == _navigator) return;
    _navigator = value;
    markNeedsPaint();
  }

  final _clip = LayerHandle<ClipRectLayer>();

  /// Where the page's box is at rest, from the window's top left.
  Offset get _origin {
    final root = _root.mounted ? _root.findRenderObject() : null;
    final navigator = (_navigator?.mounted ?? false)
        ? _navigator!.context.findRenderObject()
        : null;
    if (root is! RenderBox || navigator is! RenderBox) return Offset.zero;
    if (!root.attached || !navigator.attached) return Offset.zero;
    return MatrixUtils.transformPoint(
      navigator.getTransformTo(root),
      Offset.zero,
    );
  }

  @override
  void performLayout() {
    child?.layout(BoxConstraints.tight(_window));
    size = constraints.biggest;
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) => false;

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final origin = _origin;
    transform.translateByDouble(-origin.dx, -origin.dy, 0, 1);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    final origin = _origin;
    _clip.layer = context.pushClipRect(
      needsCompositing,
      offset,
      Offset.zero & size,
      (context, offset) => context.paintChild(child, offset - origin),
      oldLayer: _clip.layer,
    );
  }

  @override
  void dispose() {
    _clip.layer = null;
    super.dispose();
  }
}

/// One background as the app draws it: the gradient from the ambient scheme,
/// or the image faint over the surface, once and cover-fitted or repeated
/// every [tile] logical pixels. What [AppBackground] draws behind the app, and
/// what the theme store draws behind a preview.
class BackgroundLayer extends StatelessWidget {
  const BackgroundLayer({
    super.key,
    required this.style,
    required this.path,
    required this.opacity,
    required this.blur,
    this.tile = 0,
  });

  final BackgroundStyle style;
  final String path;
  final double opacity;
  final double blur;
  final double tile;

  /// [package]'s background, or null for a package without one.
  static BackgroundLayer? of(ThemePackage package) {
    final path = package.backgroundPath ?? '';
    if (package.backgroundStyle == BackgroundStyle.none ||
        (package.backgroundStyle == BackgroundStyle.image && path.isEmpty)) {
      return null;
    }
    return BackgroundLayer(
      style: package.backgroundStyle,
      path: path,
      opacity: package.opacity,
      blur: package.blur,
      tile: package.backgroundTile,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (style == BackgroundStyle.gradient) {
      return DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color.lerp(scheme.surface, scheme.primary, 0.22)!,
              scheme.surface,
              Color.lerp(scheme.surface, scheme.primary, 0.12)!,
            ],
          ),
        ),
      );
    }
    final blur = this.blur.clamp(0.0, 30.0);
    final Widget image;
    if (tile > 0) {
      // A pattern: decoded at one repeat's width in physical pixels and drawn
      // at that size from the top left, so it keeps its size on any window
      // rather than growing with it the way a `cover`-fitted picture does.
      final ratio = MediaQuery.devicePixelRatioOf(context);
      image = Image(
        image: ResizeImage(
          FileImage(File(path), scale: ratio),
          width: (tile * ratio).round(),
          allowUpscaling: true,
        ),
        fit: BoxFit.none,
        alignment: Alignment.topLeft,
        repeat: ImageRepeat.repeat,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      );
    } else {
      image = Image.file(
        File(path),
        fit: BoxFit.cover,
        cacheWidth: 4096,
        cacheHeight: 4096,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      );
    }
    // The image is faint and the colour under it is not: what makes a page
    // opaque enough to stand over the one below is this box, not the image.
    return ColoredBox(
      color: scheme.surface,
      child: Opacity(
        opacity: opacity.clamp(0.0, 0.6),
        child: blur == 0
            ? image
            : ImageFiltered(
                imageFilter: ui.ImageFilter.blur(
                  sigmaX: blur,
                  sigmaY: blur,
                  tileMode: ui.TileMode.clamp,
                ),
                child: image,
              ),
      ),
    );
  }
}

/// Every platform's own page transition, with the page given the app's
/// background for as long as it is moving.
///
/// A page here is transparent, so two of them over each other during a
/// transition are two sets of rows drawn on the same pixels — the arriving
/// page's over the leaving page's, for the length of the animation. Handing
/// each page the background makes it the complete surface it looks like at
/// rest, and the arriving page covers the one below as it comes in.
///
/// A page at rest gives it back: the background is drawn once behind the whole
/// app, and drawing it again in every page's own box would cost a layer per
/// route to show the same thing.
///
/// And either kind fades in place of moving when the app moves less — see
/// [_MotionAware].
abstract final class AppPageTransitions {
  /// For a theme whose pages are opaque: the platform's own transitions.
  static final plain = _wrap((builder) => _MotionAware(builder));

  /// For a theme whose pages are transparent.
  static final backgrounded = _wrap(
    (builder) => _Backgrounded(_MotionAware(builder)),
  );

  /// [current] ([plain] or [backgrounded]) with a slide across on every
  /// platform, for a pane whose pages are one subject after another.
  static PageTransitionsTheme paneSlide(PageTransitionsTheme current) =>
      identical(current, backgrounded)
      ? _paneSlideBackgrounded
      : _paneSlidePlain;

  static final _paneSlidePlain = _every(const _MotionAware(_PaneSlide()));
  static final _paneSlideBackgrounded = _every(
    const _Backgrounded(_MotionAware(_PaneSlide())),
  );

  /// Flutter's defaults, with Android's predictive back, driven by an edge
  /// swipe, where those are Cupertino's (iOS, macOS): a page moves and is left
  /// the same way on every platform a finger or pointer can drag it.
  static final _platform = {
    ...const PageTransitionsTheme().builders,
    TargetPlatform.iOS: const SwipeBackPageTransitionsBuilder(),
    TargetPlatform.macOS: const SwipeBackPageTransitionsBuilder(),
  };

  static PageTransitionsTheme _wrap(
    PageTransitionsBuilder Function(PageTransitionsBuilder) wrap,
  ) => PageTransitionsTheme(
    builders: {
      for (final MapEntry(key: platform, value: builder) in _platform.entries)
        platform: wrap(builder),
    },
  );

  static PageTransitionsTheme _every(PageTransitionsBuilder builder) =>
      PageTransitionsTheme(
        builders: {for (final platform in TargetPlatform.values) platform: builder},
      );
}

/// The arriving page slides in from the end edge, and the one below moves a
/// third of the way out towards the start.
final class _PaneSlide extends PageTransitionsBuilder {
  const _PaneSlide();

  static final _incoming = Tween<Offset>(
    begin: const Offset(1, 0),
    end: Offset.zero,
  ).chain(CurveTween(curve: Curves.fastEaseInToSlowEaseOut));
  static final _outgoing = Tween<Offset>(
    begin: Offset.zero,
    end: const Offset(-1 / 3, 0),
  ).chain(CurveTween(curve: Curves.fastEaseInToSlowEaseOut));

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final direction = Directionality.of(context);
    return SlideTransition(
      position: secondaryAnimation.drive(_outgoing),
      textDirection: direction,
      child: SlideTransition(
        position: animation.drive(_incoming),
        textDirection: direction,
        child: child,
      ),
    );
  }
}

/// The platform's transition, or a fade in its place when the app moves less.
///
/// The platform's builder is still the one that builds the page, only held
/// still: it is also what carries the back gesture, and a swipe back is how a
/// page is left on iOS whether or not it slides. Its gesture drives the route's
/// own animation, which is what the fade reads, so the page fades under the
/// finger instead of following it.
final class _MotionAware extends PageTransitionsBuilder {
  const _MotionAware(this._inner);

  final PageTransitionsBuilder _inner;

  @override
  Duration get transitionDuration => _inner.transitionDuration;

  @override
  Duration get reverseTransitionDuration => _inner.reverseTransitionDuration;

  @override
  DelegatedTransitionBuilder? get delegatedTransition =>
      _inner.delegatedTransition == null ? null : _delegated;

  /// The page below moving aside for the one arriving, which it does not when
  /// the app moves less. A tear-off, so every read of [delegatedTransition]
  /// is the same value — the navigator compares two routes' by equality.
  Widget? _delegated(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    bool allowSnapshotting,
    Widget? child,
  ) {
    if (context.reduceMotion) return child;
    return _inner.delegatedTransition!(
      context,
      animation,
      secondaryAnimation,
      allowSnapshotting,
      child,
    );
  }

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (!context.reduceMotion) {
      return _inner.buildTransitions(
        route,
        context,
        animation,
        secondaryAnimation,
        child,
      );
    }
    return FadeTransition(
      opacity: animation,
      child: _inner.buildTransitions(
        route,
        context,
        kAlwaysCompleteAnimation,
        kAlwaysDismissedAnimation,
        child,
      ),
    );
  }
}

/// Delegates to the platform's own transition, with the page wrapped.
final class _Backgrounded extends PageTransitionsBuilder {
  const _Backgrounded(this._inner);

  final PageTransitionsBuilder _inner;

  @override
  Duration get transitionDuration => _inner.transitionDuration;

  @override
  Duration get reverseTransitionDuration => _inner.reverseTransitionDuration;

  @override
  DelegatedTransitionBuilder? get delegatedTransition =>
      _inner.delegatedTransition;

  /// One per route, so the page's copy of the background moves with it when
  /// the platform's transition swaps the widgets around it — Android's
  /// predictive back does as a gesture starts and ends — instead of being
  /// built again, image and all.
  static final _keys = Expando<GlobalKey>();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return _inner.buildTransitions(
      route,
      context,
      animation,
      secondaryAnimation,
      AnimatedBuilder(
        key: _keys[route] ??= GlobalKey(),
        // This route's own animation, not the one above it: a page is given
        // the background while *it* is moving. A page under an arriving one
        // gives it back, and is meant to be seen there — it is what the
        // arriving page has not covered yet.
        animation: animation,
        // Passed through, not built here: this is rebuilt every frame of the
        // transition and the page under it is not.
        child: child,
        builder: (context, child) => AppBackground(
          // Anything but at rest, rather than below 1: a back gesture that
          // commits restarts the pop from fully shown
          // ([TransitionRoute.handleCommitBackGesture]), and for that frame
          // the value is 1 on a page that is leaving. A controller dragged by
          // hand is not completed short of 1 either.
          visible: !animation.isCompleted,
          child: child!,
        ),
      ),
    );
  }
}

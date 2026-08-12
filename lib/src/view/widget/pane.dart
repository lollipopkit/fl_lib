import 'package:flutter/widgets.dart';

/// Marks a subtree as living inside one pane of a multi-pane layout.
///
/// A pane owns a [Navigator] of its own, so that pages hosted in it keep
/// working exactly as they do when pushed full-screen: `context.pop()`, return
/// values, `PopScope` and transitions all still refer to something real. The
/// alternative — rendering a page into a pane as a bare widget — forces every
/// page that can push another to learn whether it is on a route stack, which
/// puts the layout decision into every leaf of the tree.
///
/// This scope is what lets the rest of the framework ask the two questions
/// that decision creates:
///
/// - *Am I inside a pane?* Things that assume they own the window — the
///   desktop caption bar, for one — must not be drawn in the middle of one.
/// - *Which navigator is the pane's?* A widget in a sibling pane (a list
///   beside a detail area) needs to push into the detail pane rather than over
///   itself.
///
/// Wraps the **whole** multi-pane layout, not the content pane alone. A widget
/// in the list pane has to be able to reach the detail pane's navigator, and
/// inherited widgets are only visible to descendants — a scope placed inside
/// the content pane would be invisible to everything beside it, which is
/// precisely the direction the interesting question travels.
///
/// Absent outside a pane layout, and every API here degrades to the
/// single-page answer when it is, so a caller never has to branch on layout.
class PaneScope extends InheritedWidget {
  const PaneScope({
    super.key,
    required this.navigatorKey,
    required this.split,
    this.closeDetail,
    required super.child,
  });

  /// The content pane's navigator — the one a sibling pane pushes into.
  ///
  /// A key rather than a [NavigatorState] because the scope is built above the
  /// navigator it describes: the state does not exist yet when this widget is
  /// constructed, and callers only ever need it later, on an event.
  final GlobalKey<NavigatorState> navigatorKey;

  /// Whether the detail is currently beside the list rather than pushed over
  /// it. The scope exists in both layouts, so its presence answers "could
  /// there be a pane here", not "is there one right now" — and a list deciding
  /// between selecting and pushing needs the second question.
  final bool split;

  /// Empties the pane, collapsing the layout back to the list at full width.
  ///
  /// Supplied by the host rather than done here, because what "nothing is
  /// open" means is the host's selection state — this widget only renders
  /// whatever that state produces. Null when the host has no way to express
  /// an empty pane, in which case no way out is offered.
  final VoidCallback? closeDetail;

  /// The enclosing pane layout, or null outside one.
  ///
  /// Registers a dependency, so a widget that changes appearance based on
  /// being in a pane layout rebuilds when that changes.
  static PaneScope? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<PaneScope>();
  }

  /// Whether a detail pane is on screen right now.
  ///
  /// False outside a pane layout and false inside one that is currently
  /// collapsed, which is what makes `isSplit ? select : push` the whole of a
  /// caller's layout awareness.
  static bool isSplit(BuildContext context) {
    return maybeOf(context)?.split ?? false;
  }

  /// Whether [context] is inside the content pane, as opposed to beside it or
  /// outside the layout entirely.
  ///
  /// Derived from the navigator rather than from a second marker widget: being
  /// in the pane *is* having the pane's navigator as the nearest one, so there
  /// is no second fact that could disagree with the first.
  ///
  /// Reads without registering a dependency — this answers a question about
  /// where a widget is being built, which is settled by the time it is asked.
  static bool isInPane(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<PaneScope>();
    if (scope == null) return false;
    final navigator = scope.navigatorKey.currentState;
    return navigator != null && Navigator.maybeOf(context) == navigator;
  }

  /// The content pane's navigator, or null outside a pane layout or before
  /// that navigator has been built.
  static NavigatorState? navigatorOf(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<PaneScope>();
    return scope?.navigatorKey.currentState;
  }

  /// The way out of the pane's root page, or null when there is none.
  ///
  /// Null outside a pane layout, in the list beside one, and — importantly —
  /// above a stack that can still pop, where back already means something and
  /// closing the pane would skip past the pages in between. So an app bar can
  /// take this as "no ordinary back button applies, use mine".
  ///
  /// Registers a dependency: collapsing to one column takes the pane away, and
  /// with it the button.
  static VoidCallback? closeDetailOf(BuildContext context) {
    final scope = maybeOf(context);
    if (scope == null || !scope.split) return null;
    final close = scope.closeDetail;
    if (close == null) return null;
    final navigator = scope.navigatorKey.currentState;
    if (navigator == null || Navigator.maybeOf(context) != navigator) {
      return null;
    }
    return navigator.canPop() ? null : close;
  }

  @override
  bool updateShouldNotify(PaneScope oldWidget) {
    return navigatorKey != oldWidget.navigatorKey ||
        split != oldWidget.split ||
        closeDetail != oldWidget.closeDetail;
  }
}

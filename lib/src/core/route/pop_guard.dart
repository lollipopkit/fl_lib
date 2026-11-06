import 'package:flutter/widgets.dart';

import '../../view/widget/pane.dart';

/// A page that asks before it is left, however it is left.
///
/// Back and the back gesture reach it through [PopScope], and closing a detail
/// pane through [PaneScope.closeDetailOf]. Code that removes pages itself —
/// switching what a pane shows, closing a pane, `popUntil` — asks with
/// [PopGuard.confirmLeave] or [PopGuardNavigator.popUntilGuarded] first.
class PopGuard extends StatefulWidget {
  const PopGuard({
    super.key,
    required this.enabled,
    required this.confirm,
    required this.child,
  });

  /// Whether there is anything to lose, such as unsaved edits.
  final bool enabled;

  /// Whether the page may go. Asked only while [enabled].
  final Future<bool> Function() confirm;

  final Widget child;

  static final _guards = <_PopGuardState>{};
  static var _created = 0;

  /// Asks every guarded page of [within] that is about to go, the newest
  /// first, and answers whether all of them agreed. Nothing is removed here;
  /// the first refusal stops the asking.
  ///
  /// A route of [within] goes unless [stays] holds for it, so [stays] has to
  /// hold for every route that remains — as `settings is Page` or `isFirst`
  /// do. A page in a navigator nested under [within] is always asked: whether
  /// the route holding that navigator stays is not known here, and asking too
  /// often loses nothing.
  static Future<bool> confirmLeave(
    NavigatorState within, {
    RoutePredicate? stays,
  }) async {
    final asking = [
      for (final guard in _guards)
        if (guard._leaves(within, stays)) guard,
    ]..sort((a, b) => b._order.compareTo(a._order));
    for (final guard in asking) {
      if (!guard.mounted || !guard.widget.enabled) continue;
      if (!await guard.widget.confirm()) return false;
    }
    return true;
  }

  @override
  State<PopGuard> createState() => _PopGuardState();
}

class _PopGuardState extends State<PopGuard> {
  /// When this page was built, which is the order it was pushed in.
  final _order = PopGuard._created++;
  ModalRoute<Object?>? _route;

  @override
  void initState() {
    super.initState();
    PopGuard._guards.add(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  @override
  void dispose() {
    PopGuard._guards.remove(this);
    super.dispose();
  }

  bool _leaves(NavigatorState within, RoutePredicate? stays) {
    final route = _route;
    if (!mounted || !widget.enabled) return false;
    if (route == null || !route.isActive) return false;
    final own = route.navigator;
    if (own == within) return !(stays?.call(route) ?? false);
    var nav = own?.context.findAncestorStateOfType<NavigatorState>();
    while (nav != null) {
      if (nav == within) return true;
      nav = nav.context.findAncestorStateOfType<NavigatorState>();
    }
    return false;
  }

  Future<void> _onPop(bool didPop, Object? result) async {
    if (didPop) return;
    if (!await widget.confirm() || !mounted) return;
    final nav = Navigator.of(context);
    if (nav.canPop()) {
      nav.pop(result);
      return;
    }
    // The root of a detail pane: leaving it is closing the pane. Already
    // asked, so not through [PaneScope.closeDetailOf].
    context.getInheritedWidgetOfExactType<PaneScope>()?.closeDetail?.call();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !widget.enabled,
      onPopInvokedWithResult: _onPop,
      child: widget.child,
    );
  }
}

extension PopGuardNavigator on NavigatorState {
  /// [popUntil], once every guarded page it removes agreed. [stays] holds for
  /// every route that remains: see [PopGuard.confirmLeave].
  Future<bool> popUntilGuarded(RoutePredicate stays) async {
    if (!await PopGuard.confirmLeave(this, stays: stays)) return false;
    if (!mounted) return false;
    popUntil(stays);
    return true;
  }
}

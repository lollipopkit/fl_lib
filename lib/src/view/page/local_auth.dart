import 'dart:async';

import 'package:fl_lib/fl_lib.dart';
import 'package:fl_lib/src/res/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:icons_plus/icons_plus.dart';

final class LocalAuthPageArgs {
  final bool autoReqAuth;
  final void Function()? onAuthSuccess;

  /// Called instead of [onAuthSuccess] when this device cannot authenticate at
  /// all — no sensor, nothing enrolled, no plugin for the platform.
  ///
  /// The page lets itself out in that case, so a caller that supplies nothing
  /// still gets an app it can use. Supply one to stop asking: the usual way a
  /// device ends up here is a backup restored from one that *could*
  /// authenticate, and rediscovering that every launch helps nobody.
  final void Function()? onUnavailable;

  const LocalAuthPageArgs({
    this.autoReqAuth = true,
    this.onAuthSuccess,
    this.onUnavailable,
  });
}

/// Holds the app until the device says who is holding it.
///
/// Deliberately hard to leave: [PopScope] refuses the back gesture and quits
/// the app instead, so the lock cannot be dismissed into the UI behind it. That
/// makes the *unavailable* case load-bearing — a device that can never satisfy
/// the check would otherwise be held here for ever, with quitting as the only
/// way out. See [LocalAuthPageArgs.onUnavailable].
final class LocalAuthPage extends StatefulWidget {
  final LocalAuthPageArgs? args;

  const LocalAuthPage({super.key, this.args});

  static const route = AppRoute<bool, LocalAuthPageArgs>(
    page: LocalAuthPage.new,
    path: '/local_auth',
  );

  @override
  State<LocalAuthPage> createState() => _LocalAuthPageState();
}

final class _LocalAuthPageState extends State<LocalAuthPage> with AfterLayoutMixin {
  /// Why the last attempt did not let the user in, or null before the first.
  ///
  /// Shown because the alternative was a screen that does nothing when tapped.
  /// A cancelled prompt, a wrong finger and a locked-out sensor all landed in
  /// the same silent branch, and from the outside the button simply looked
  /// broken.
  AuthResult? _lastFailure;

  /// One prompt at a time. [LocalAuth.goWithResult] has no re-entry guard of
  /// its own — [LocalAuth.go] does — and this page can start one from the
  /// first layout and from every tap.
  bool _authing = false;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) SystemNavigator.pop();
      },
      child: Scaffold(
        body: InkWell(
          onTap: _reqAuth,
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                const Icon(IonIcons.finger_print, size: 77),
                UIs.height13,
                Text(l10n.tapToAuth),
                if (_failureText case final text?) ...[
                  UIs.height13,
                  Text(text, style: UIs.textGrey),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// One word for every way this can go wrong short of being impossible.
  ///
  /// Not spelled out per result: `lockedOut` is the only one worth its own
  /// sentence — it is the one where trying again does not help — and there is
  /// no string here that says so without inventing a meaning for one that says
  /// something else. Better a true "failed" than a confident "timed out".
  String? get _failureText => switch (_lastFailure) {
    null || AuthResult.success || AuthResult.notAvail => null,
    AuthResult.fail || AuthResult.cancel || AuthResult.lockedOut => l10n.fail,
  };

  void _reqAuth() async {
    if (_authing) return;
    _authing = true;
    final AuthResult result;
    try {
      result = await LocalAuth.goWithResult();
    } finally {
      _authing = false;
    }
    if (!mounted) return;

    switch (result) {
      case AuthResult.success:
        context.pop();
        widget.args?.onAuthSuccess?.call();
      case AuthResult.notAvail:
        // Nothing on this device can answer the question, so holding the app
        // here protects no one and locks out the one person it is for.
        context.pop();
        widget.args?.onUnavailable?.call();
      case AuthResult.fail:
      case AuthResult.cancel:
      case AuthResult.lockedOut:
        setState(() => _lastFailure = result);
    }
  }

  @override
  FutureOr<void> afterFirstLayout(BuildContext context) async {
    if (widget.args?.autoReqAuth != false) {
      _reqAuth();
    }
  }
}

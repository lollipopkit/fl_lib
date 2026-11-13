import 'dart:async';

import 'package:fl_lib/fl_lib.dart';
import 'package:fl_lib/src/res/l10n.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

final class LocalAuthPageArgs {
  final bool autoReqAuth;
  final void Function()? onAuthSuccess;

  const LocalAuthPageArgs({this.autoReqAuth = true, this.onAuthSuccess});
}

/// Holds the app until the device says who is holding it.
///
/// Deliberately hard to leave: [PopScope] refuses the back gesture and quits
/// the app instead, so the lock cannot be dismissed into the UI behind it.
/// Only [AuthResult.success] opens it — a device that cannot authenticate any
/// more (passcode removed, nothing enrolled) stays locked, since letting it
/// through would let anyone holding it through.
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
                const Icon(Icons.fingerprint, size: 77),
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

  String? get _failureText => switch (_lastFailure) {
    null || AuthResult.success => null,
    AuthResult.notAvail => l10n.notAvailable,
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

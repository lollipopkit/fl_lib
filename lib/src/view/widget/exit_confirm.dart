import 'package:fl_lib/fl_lib.dart';
import 'package:fl_lib/src/res/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

final class ExitConfirm extends StatefulWidget {
  final Widget child;
  final void Function(BuildContext context) onPop;

  const ExitConfirm({
    super.key,
    required this.child,
    required this.onPop,
  });

  @override
  State<ExitConfirm> createState() => _ExitConfirmState();

  static void exitApp() {
    SystemNavigator.pop();
  }

  static void pop(BuildContext context) => context.pop();
}

final class _ExitConfirmState extends State<ExitConfirm> {
  var _lastExitTS = 0;
  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - _lastExitTS < 2000) {
          widget.onPop(context);
        } else {
          _lastExitTS = now;
          Toast.show(l10n.exitConfirmTip, tag: 'exit_confirm');
        }
      },
      child: widget.child,
    );
  }
}

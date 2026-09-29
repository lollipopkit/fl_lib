import 'dart:async';

import 'package:material_ui/material_ui.dart';

/// Mixin to run a callback once after the first layout frame.
///
/// Useful when you need layout-dependent data (e.g., sizes, positions) or
/// showing dialogs/snackbars immediately after the widget renders.
mixin AfterLayoutMixin<T extends StatefulWidget> on State<T> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.endOfFrame.then(
      (_) {
        if (mounted) afterFirstLayout(context);
      },
    );
  }

  /// Called once after the first layout frame.
  FutureOr<void> afterFirstLayout(BuildContext context);
}

import 'package:fl_lib/src/view/widget/toast/toast.dart';
import 'package:flutter/material.dart';

/// Kept only so that apps still on `showSnackBar` keep compiling. Every method
/// forwards to [Toast], which needs no [BuildContext].
///
// TODO: remove once every app depending on fl_lib has migrated to Toast.
extension SnackBarX on BuildContext {
  @Deprecated('Use Toast.show instead')
  void showSnackBar(String text) => Toast.show(text);

  @Deprecated('Use Toast.show(content: widget) instead')
  void showSnackBarWidget(Widget widget) => Toast.show('', content: widget);

  @Deprecated('Use Toast.show(action: ToastAction(...)) instead')
  void showSnackBarWithAction({
    required String content,
    required String action,
    required GestureTapCallback onTap,
  }) {
    Toast.show(
      content,
      action: ToastAction(label: action, onTap: onTap),
    );
  }

  @Deprecated('Use Toast.show(content: widget, action: ToastAction(...)) instead')
  void showSnackBarWidgetWithAction({
    required Widget content,
    required String action,
    required GestureTapCallback onTap,
  }) {
    Toast.show(
      '',
      content: content,
      action: ToastAction(label: action, onTap: onTap),
    );
  }
}

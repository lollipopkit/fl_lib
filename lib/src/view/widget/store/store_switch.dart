import 'dart:async';

import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';

/// {@template StoreSwitch}
/// A switch widget that integrates with a [StorePropDefault].
///
/// It allows for asynchronous validation and callback execution before changing the switch state.
///
/// If the validation fails, the switch will not change its state.
///
/// The switch will show a loading indicator while the change is being processed.
/// {@endtemplate}
class StoreSwitch extends StatefulWidget {
  /// The property that this switch controls.
  final StorePropDefault<bool> prop;

  /// Exec before make change, after validator.
  final FutureOr<void> Function(bool)? callback;

  /// If return false, the switch will not change.
  final FutureOr<bool> Function(bool)? validator;

  /// {@macro StoreSwitch}
  const StoreSwitch({super.key, required this.prop, this.callback, this.validator});

  @override
  State<StoreSwitch> createState() => _StoreSwitchState();
}

class _StoreSwitchState extends State<StoreSwitch> {
  bool isBusy = false;

  @override
  Widget build(BuildContext context) {
    return ValBuilder(
      listenable: widget.prop.listenable(),
      builder: (value) {
        if (isBusy) return SizedLoading.medium.paddingOnly(right: 17);
        return SwitchX(value: value, onChanged: _handleChange);
      },
    );
  }

  Future<void> _handleChange(bool newValue) async {
    if (isBusy) return;
    setStateSafe(() {
      isBusy = true;
    });

    final valid = await widget.validator?.call(newValue) ?? true;
    if (!valid) {
      setStateSafe(() {
        isBusy = false;
      });
      return;
    }

    try {
      await widget.callback?.call(newValue);
      await widget.prop.set(newValue);
    } finally {
      setStateSafe(() {
        isBusy = false;
      });
    }
  }
}

extension StoreBoolWidget on StorePropDefault<bool> {
  /// Creates a [StoreSwitch] widget for this property.
  ///
  /// This is a convenience method to quickly create a switch widget bound to this property.
  StoreSwitch switchWidget({
    FutureOr<void> Function(bool)? callback,
    FutureOr<bool> Function(bool)? validator,
  }) {
    return StoreSwitch(prop: this, callback: callback, validator: validator);
  }
}

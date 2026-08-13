import 'package:fl_lib/src/res/ui.dart';
import 'package:flutter/material.dart';

class PopupMenu<T> extends StatelessWidget {
  final List<PopupMenuEntry<T>> items;
  final void Function(T) onSelected;
  final Widget child;
  final EdgeInsetsGeometry padding;
  final T? initialValue;
  final String? tooltip;
  final BorderRadius? borderRadius;

  /// Off refuses the tap and greys the child, the way every other disabled
  /// control does. `PopupMenuButton` has always had this; not carrying it
  /// through meant a caller with a reason to refuse had to reach past this
  /// widget for the one underneath.
  final bool enabled;

  const PopupMenu({
    super.key,
    required this.items,
    required this.onSelected,
    this.child = UIs.popMenuChild,
    this.padding = const EdgeInsets.all(7),
    this.initialValue,
    this.tooltip,
    this.borderRadius,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<T>(
      itemBuilder: (_) => items,
      onSelected: onSelected,
      initialValue: initialValue,
      padding: padding,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      tooltip: tooltip,
      borderRadius: borderRadius,
      enabled: enabled,
      child: child,
    );
  }
}

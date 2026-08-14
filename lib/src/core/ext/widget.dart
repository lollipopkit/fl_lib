import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';

extension WidgetX on Widget {
  Widget get cardx => CardX(child: this);

  Widget paddingAll(double value) => Padding(padding: EdgeInsets.all(value), child: this);

  Widget paddingSymmetric({double horizontal = 0, double vertical = 0}) => Padding(
        padding: EdgeInsets.symmetric(
          horizontal: horizontal,
          vertical: vertical,
        ),
        child: this,
      );

  Widget paddingOnly({
    double left = 0,
    double top = 0,
    double right = 0,
    double bottom = 0,
  }) =>
      Padding(
        padding: EdgeInsets.only(
          left: left,
          top: top,
          right: right,
          bottom: bottom,
        ),
        child: this,
      );

  Widget expanded({int flex = 1}) => Expanded(flex: flex, child: this);

  Widget center() => Center(child: this);

  Widget align(AlignmentGeometry alignment) => Align(alignment: alignment, child: this);

  Widget sized({double? width, double? height}) => SizedBox(width: width, height: height, child: this);

  Widget tap({
    VoidCallback? onTap,
    bool disable = false,
    VoidCallback? onLongTap,
    VoidCallback? onDoubleTap,
    bool clip = true,
    void Function(Offset at)? onSecondaryTap,
  }) {
    if (disable) return this;

    final child = InkWell(
      onTap: onTap == null ? null : () => Fns.throttle(onTap),
      onLongPress: onLongTap,
      onDoubleTap: onDoubleTap,
      child: this,
    ).onSecondary(onSecondaryTap ?? asSecondary(onLongTap));
    if (!clip) return child;

    return ClipRRect(
      clipBehavior: Clip.hardEdge,
      borderRadius: BorderRadius.circular(17),
      child: Material(
        color: Colors.transparent,
        child: child,
      ),
    );
  }

  /// Wrap this widget in a [SliverToBoxAdapter].
  SliverToBoxAdapter sliver({Key? key}) {
    return SliverToBoxAdapter(
      key: key,
      child: this,
    );
  }
}

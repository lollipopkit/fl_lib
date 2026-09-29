import 'package:fl_lib/fl_lib.dart';
import 'package:material_ui/material_ui.dart';
import 'package:responsive_framework/responsive_framework.dart';

/// Utils for responsive framework.
abstract final class ResponsivePoints {
  const ResponsivePoints._();

  /// Responsive breakpoints builder.
  /// - 0–600: MOBILE
  /// - 600–1199: TABLET
  /// - 1199–3840: DESKTOP
  static Widget builder(BuildContext context, Widget? child) => ResponsiveBreakpoints.builder(
    child: child ?? UIs.placeholder,
    breakpoints: const [
      Breakpoint(start: 0, end: 600, name: MOBILE),
      Breakpoint(start: 600, end: 1199, name: TABLET),
      Breakpoint(start: 1199, end: 3840, name: DESKTOP),
    ],
  );
}

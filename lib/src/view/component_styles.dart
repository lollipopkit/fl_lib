import 'package:material_ui/material_ui.dart';

/// Styles for the widgets of this library that no Material theme covers: the
/// search field embedded in a bar, [SegmentedTabs], the side bar's rows, and
/// toasts.
///
/// Set by the app's theme as a [ThemeExtension]; every field is optional, and a
/// null keeps the widget's own look. Read with [ComponentStyles.of].
@immutable
class ComponentStyles extends ThemeExtension<ComponentStyles> {
  const ComponentStyles({
    this.search = const SearchFieldStyle(),
    this.segmented = const SegmentedStyle(),
    this.sidebar = const SidebarStyle(),
    this.toast = const ToastStyle(),
  });

  final SearchFieldStyle search;
  final SegmentedStyle segmented;
  final SidebarStyle sidebar;
  final ToastStyle toast;

  static const none = ComponentStyles();

  static ComponentStyles of(BuildContext context) =>
      Theme.of(context).extension<ComponentStyles>() ?? none;

  @override
  ComponentStyles copyWith({
    SearchFieldStyle? search,
    SegmentedStyle? segmented,
    SidebarStyle? sidebar,
    ToastStyle? toast,
  }) => ComponentStyles(
    search: search ?? this.search,
    segmented: segmented ?? this.segmented,
    sidebar: sidebar ?? this.sidebar,
    toast: toast ?? this.toast,
  );

  /// Discrete: a theme change swaps the styles at the midpoint. These are
  /// colours and radii of widgets that animate their own state, and a blend of
  /// two themes' search fields is not a look either theme has.
  @override
  ComponentStyles lerp(ComponentStyles? other, double t) =>
      other == null || t < 0.5 ? this : other;
}

/// A search field that sits in a bar or a pill of its own, rather than a form's
/// input.
@immutable
class SearchFieldStyle {
  const SearchFieldStyle({
    this.backgroundColor,
    this.radius,
    this.borderColor,
    this.borderWidth,
    this.iconColor,
    this.textColor,
    this.hintColor,
    this.height,
    this.padding,
  });

  final Color? backgroundColor;
  final double? radius;
  final Color? borderColor;
  final double? borderWidth;
  final Color? iconColor;
  final Color? textColor;
  final Color? hintColor;
  final double? height;
  final EdgeInsets? padding;

  /// The outline of the pill a search field draws itself in: [fallback] where
  /// the style says nothing about it.
  ShapeBorder shape(ShapeBorder fallback) {
    if (radius == null && borderColor == null && borderWidth == null) {
      return fallback;
    }
    final side = borderColor == null && borderWidth == null
        ? BorderSide.none
        : themeBorderSide(
            borderColor ?? const Color(0x33888888),
            borderWidth ?? 1,
          );
    return radius == null
        ? StadiumBorder(side: side)
        : RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius!),
            side: side,
          );
  }
}

/// [SegmentedTabs] and other segmented switches drawn by the app.
@immutable
class SegmentedStyle {
  const SegmentedStyle({
    this.trackColor,
    this.selectedColor,
    this.textColor,
    this.selectedTextColor,
    this.radius,
    this.borderColor,
    this.borderWidth,
  });

  final Color? trackColor;
  final Color? selectedColor;
  final Color? textColor;
  final Color? selectedTextColor;
  final double? radius;
  final Color? borderColor;
  final double? borderWidth;
}

/// The rows of a side bar or a menu down the side of a page.
@immutable
class SidebarStyle {
  const SidebarStyle({
    this.backgroundColor,
    this.selectedColor,
    this.textColor,
    this.selectedTextColor,
    this.iconColor,
    this.selectedIconColor,
    this.radius,
    this.padding,
  });

  final Color? backgroundColor;
  final Color? selectedColor;
  final Color? textColor;
  final Color? selectedTextColor;
  final Color? iconColor;
  final Color? selectedIconColor;
  final double? radius;
  final EdgeInsets? padding;
}

/// A toast's card.
@immutable
class ToastStyle {
  const ToastStyle({
    this.backgroundColor,
    this.textColor,
    this.radius,
    this.borderColor,
    this.borderWidth,
    this.elevation,
  });

  final Color? backgroundColor;
  final Color? textColor;
  final double? radius;
  final Color? borderColor;
  final double? borderWidth;
  final double? elevation;
}

/// A border line from a theme's color and width, where a width of 0 means no
/// line at all.
///
/// Not the same as `BorderSide(width: 0)`: Flutter draws a solid side of width
/// 0 as a hairline, one physical pixel wide, so a theme that says "no border"
/// got a thin one around every tile it rounded.
BorderSide themeBorderSide(Color color, double width) =>
    width <= 0 ? BorderSide.none : BorderSide(color: color, width: width);

/// The decoration of a text field that is part of something else — a search
/// pill, a bar, a composer — rather than a form's input.
///
/// Every border is set, and `filled` is false. Setting only `border` is not
/// enough: an [InputDecorationTheme] that defines `enabledBorder` and
/// `focusedBorder` wins over it, and a theme's form fields then draw a box
/// inside the pill the field already sits in.
///
/// [isCollapsed] is [InputDecoration.collapsed]: no padding unless
/// [contentPadding] says otherwise, rather than the theme's.
InputDecoration bareInputDecoration({
  String? hintText,
  TextStyle? hintStyle,
  EdgeInsetsGeometry? contentPadding,
  bool isDense = false,
  bool isCollapsed = false,
  Widget? prefixIcon,
  BoxConstraints? prefixIconConstraints,
}) => InputDecoration(
  hintText: hintText,
  hintStyle: hintStyle,
  contentPadding: contentPadding ?? (isCollapsed ? EdgeInsets.zero : null),
  isDense: isDense,
  isCollapsed: isCollapsed,
  prefixIcon: prefixIcon,
  prefixIconConstraints: prefixIconConstraints,
  filled: false,
  border: InputBorder.none,
  enabledBorder: InputBorder.none,
  focusedBorder: InputBorder.none,
  errorBorder: InputBorder.none,
  focusedErrorBorder: InputBorder.none,
  disabledBorder: InputBorder.none,
);

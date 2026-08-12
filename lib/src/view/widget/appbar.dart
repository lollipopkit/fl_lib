import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

class CustomAppBar extends StatelessWidget implements PreferredSizeWidget {
  /// System status bar height
  static final sysStatusBarHeight = isDesktop ? kWindowCaptionHeight : 0.0;

  const CustomAppBar({
    super.key,
    this.title,
    this.actions,
    this.centerTitle = true,
    this.leading,
    this.backgroundColor,
    this.bottom,
    this.scrolledUnderElevation = 0,
    this.surfaceTintColor = Colors.transparent,
  });

  final Widget? title;
  final List<Widget>? actions;
  final bool? centerTitle;
  final Widget? leading;
  final Color? backgroundColor;
  final PreferredSizeWidget? bottom;
  final double scrolledUnderElevation;
  final Color surfaceTintColor;

  @override
  Widget build(BuildContext context) {
    // At the root of a detail pane there is nothing on the stack to pop, so
    // `AppBar` draws no back button — yet there is still somewhere to go back
    // to: closing the pane hands the width back to the list. Resolved here so
    // that a page never has to know which of the two it is being shown in.
    final closeDetail = leading == null
        ? PaneScope.closeDetailOf(context)
        : null;
    final bar = AppBar(
      key: key,
      title: title,
      actions: actions,
      centerTitle: centerTitle,
      leading: closeDetail == null
          ? leading
          : BackButton(onPressed: closeDetail),
      backgroundColor: backgroundColor,
      toolbarHeight: appBarHeight,
      bottom: bottom,
      scrolledUnderElevation: scrolledUnderElevation,
      surfaceTintColor: surfaceTintColor,
    );
    return bar;
  }

  @override
  Size get preferredSize {
    return calcPreferredSize(bottomWidgetH: bottom?.preferredSize.height);
  }

  static const double appBarHeight = kToolbarHeight - 10;

  static Size calcPreferredSize({double? bottomWidgetH}) {
    bottomWidgetH ??= 0;
    return Size.fromHeight(appBarHeight + bottomWidgetH);
  }
}

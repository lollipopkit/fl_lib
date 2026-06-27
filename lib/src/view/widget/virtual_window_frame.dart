import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart' as wm;

abstract final class WindowFrameConfig {
  static final _showCaption = ValueNotifier(true);

  static bool get showCaption => _showCaption.value && isDesktop;

  static ValueListenable<bool> get listenable => _showCaption;

  static void setShowCaption(bool value) {
    _showCaption.value = value;
  }
}

class VirtualWindowFrame extends StatefulWidget {
  final Widget child;

  /// Title of the window.
  final String? title;

  const VirtualWindowFrame({super.key, required this.child, this.title});

  @override
  State<VirtualWindowFrame> createState() => _VirtualWindowFrameState();
}

class _VirtualWindowFrameState extends State<VirtualWindowFrame> {
  @override
  void initState() {
    super.initState();
    WindowFrameConfig.listenable.addListener(_onCaptionChanged);
  }

  @override
  void dispose() {
    WindowFrameConfig.listenable.removeListener(_onCaptionChanged);
    super.dispose();
  }

  void _onCaptionChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final content = switch (CustomAppBar.sysStatusBarHeight) {
      0.0 => widget.child,
      _ when WindowFrameConfig.showCaption => Column(
          children: [
            _WindowCaption(title: widget.title),
            Expanded(child: widget.child),
          ],
        ),
      _ => widget.child,
    };
    return wm.VirtualWindowFrame(child: content);
  }
}

class _WindowCaption extends StatelessWidget {
  final String? title;

  const _WindowCaption({this.title});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.scaffoldBackgroundColor,
      height: CustomAppBar.sysStatusBarHeight,
      width: double.infinity,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (title != null)
            Material(
              color: Colors.transparent,
              child: Text(
                title!,
                style: TextStyle(
                  color: theme.colorScheme.onSurface,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          if (isLinux || isWindows)
            wm.WindowCaption(
              backgroundColor: Colors.transparent,
              brightness: theme.brightness,
            )
        ],
      ),
    );
  }
}

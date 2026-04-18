import 'dart:async';
import 'package:flutter/material.dart';

final class AutoHide extends StatefulWidget {
  final Widget child;
  final ScrollController scrollController;
  final AxisDirection direction;
  final double offset;
  final AutoHideController? hideController;

  const AutoHide({
    super.key,
    required this.child,
    required this.scrollController,
    required this.direction,
    this.hideController,
    this.offset = 55,
  })  : assert(offset >= 0, 'Offset must be greater than or equal to 0'),
        assert(key is! GlobalKey, 'GlobalKey is not recommended, use hideController instead');

  @override
  State<AutoHide> createState() => AutoHideState();
}

final class AutoHideState extends State<AutoHide> {
  bool _isScrolling = false;
  Timer? _timer;
  Timer? _scrollDebouncer;
  late final _controller = widget.hideController ?? AutoHideController();

  @override
  void initState() {
    super.initState();
    widget.scrollController.addListener(_scrollListener);
    _setupTimer();
  }

  @override
  void dispose() {
    widget.scrollController.removeListener(_scrollListener);
    if (widget.hideController == null) {
      _controller.dispose();
    }
    _timer?.cancel();
    _scrollDebouncer?.cancel();
    _timer = _scrollDebouncer = null;
    super.dispose();
  }

  void _setupTimer() {
    // Cancel any existing timer
    _timer?.cancel();
    // If auto-hide is disabled, don't set up a new timer
    if (!_controller.autoHideEnabled) return;

    // Create a new timer that will fire after 3 seconds
    _timer = Timer(const Duration(seconds: 3), () {
      // Don't hide if widget is unmounted or user is currently scrolling
      if (!mounted || _isScrolling) return;
      // Don't hide if already hidden
      if (!_controller.visible) return;

      // Check if scrolling is possible
      final canScroll = widget.scrollController.hasClients && widget.scrollController.position.maxScrollExtent > 0;
      if (!canScroll) return;

      // Hide the widget
      _controller.hide();
    });
  }

  void _scrollListener() {
    if (!mounted || !_controller.autoHideEnabled) return;

    _isScrolling = true;
    _scrollDebouncer?.cancel();
    _scrollDebouncer = Timer(const Duration(milliseconds: 100), () {
      _isScrolling = false;
      if (!_controller.visible) {
        _controller.show();
        _setupTimer();
      }
    });

    if (!_controller.visible) {
      _controller.show();
      _setupTimer();
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final hiddenOffset = _getHiddenOffset(constraints);
        return AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            return AnimatedSlide(
              offset: _controller.visible ? Offset.zero : hiddenOffset,
              duration: Durations.medium1,
              curve: Curves.easeInOutCubic,
              child: child,
            );
          },
          child: widget.child,
        );
      },
    );
  }

  Offset _getHiddenOffset(BoxConstraints constraints) {
    final offsetPx = widget.offset;
    final denom = switch (widget.direction) {
      AxisDirection.down || AxisDirection.up =>
        constraints.maxHeight.isFinite && constraints.maxHeight > 0 ? constraints.maxHeight : widget.offset,
      AxisDirection.left || AxisDirection.right =>
        constraints.maxWidth.isFinite && constraints.maxWidth > 0 ? constraints.maxWidth : widget.offset,
    };
    final fraction = offsetPx / (denom == 0 ? 1 : denom);
    return switch (widget.direction) {
      AxisDirection.down => Offset(0, fraction),
      AxisDirection.up => Offset(0, -fraction),
      AxisDirection.left => Offset(-fraction, 0),
      AxisDirection.right => Offset(fraction, 0),
    };
  }
}

class AutoHideController extends ChangeNotifier {
  bool _visible = true;
  bool get visible => _visible;

  void show() {
    if (_visible) return;
    _visible = true;
    notifyListeners();
  }

  void hide() {
    if (!_visible) return;
    _visible = false;
    notifyListeners();
  }

  bool autoHideEnabled = true;
}

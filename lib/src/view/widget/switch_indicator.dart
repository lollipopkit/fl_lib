import 'dart:async';
import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';
import 'package:icons_plus/icons_plus.dart';

enum SwitchDirection { previous, next }

/// A widget that detects scroll gestures and shows a visual indicator for page switching
///
/// This widget wraps a scrollable child and provides visual feedback when the user
/// reaches the scroll boundaries, indicating they can switch to the previous or next page.
class SwitchIndicator extends StatefulWidget {
  final Widget child;
  final FutureOr<void> Function(SwitchDirection) onSwitchPage;

  const SwitchIndicator({
    super.key,
    required this.child,
    required this.onSwitchPage,
  });

  @override
  State<SwitchIndicator> createState() => _SwitchState();
}

class _SwitchState extends State<SwitchIndicator> with TickerProviderStateMixin {
  /// Icon size for the switch indicator
  static const _kIconSize = 23.0;

  /// Padding around the switch indicator
  static const _kPadding = 11.0;

  /// Threshold for triggering overscroll-based page switches
  static const _kOverscrollThreshold = 0.2;

  late final AnimationController _showIndicatorCtrl;
  late final Animation<double> _showIndicatorAnim;

  SwitchDirection? _scrollDirection;
  Timer? _doSwitchTimer;

  @override
  void initState() {
    super.initState();
    _showIndicatorCtrl = AnimationController(
      vsync: this,
      duration: Durations.medium3,
    );
    _showIndicatorAnim = CurvedAnimation(
      parent: _showIndicatorCtrl,
      curve: Curves.fastEaseInToSlowEaseOut,
    );
  }

  @override
  void dispose() {
    _showIndicatorCtrl.dispose();
    _doSwitchTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: _handleNotification,
      child: AnimatedBuilder(
        animation: _showIndicatorAnim,
        child: widget.child,
        builder: (_, child) {
          return Stack(
            alignment: AlignmentDirectional.center,
            children: [
              child ?? UIs.placeholder,
              ScaleTransition(
                scale: _showIndicatorAnim,
                child: _buildIndicator(context),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildIndicator(BuildContext context) {
    final icon = _scrollDirection == null
        ? null
        : Icon(
            _scrollDirection == SwitchDirection.previous ? MingCute.up_line : MingCute.down_line,
            size: _kIconSize,
          );

    if (icon == null) return UIs.placeholder;

    return ClipOval(
      child: ColoredBox(
        color: Theme.of(context).colorScheme.primary,
        child: Padding(padding: const EdgeInsets.all(_kPadding), child: icon),
      ),
    );
  }

  /// Handles all scroll-related notifications
  ///
  /// Routes different types of scroll notifications to their respective handlers
  bool _handleNotification(ScrollNotification noti) {
    return switch (noti) {
      final ScrollUpdateNotification update => _handleUpdateNoti(update),
      final ScrollEndNotification end => _handleEndNoti(end),
      final OverscrollNotification over => _handleOverScrollNoti(over),
      _ => false,
    };
  }

  bool _handleUpdateNoti(ScrollUpdateNotification noti) {
    if (noti.dragDetails == null) {
      _resetState();
      return false;
    }

    final metrics = noti.metrics;
    final scrollDirection = _getScrollDirection(
      atTop: metrics.extentAfter == 0.0,
      atBottom: metrics.extentBefore == 0.0,
    );

    if (!_updateScrollDirection(scrollDirection)) {
      return false;
    }

    if (scrollDirection != null) {
      _doSwitchPage();
    } else {
      _showIndicatorCtrl.reverse();
    }

    return false;
  }

  bool _handleEndNoti(ScrollEndNotification noti) {
    _resetState();
    return false;
  }

  bool _handleOverScrollNoti(OverscrollNotification noti) {
    if (_scrollDirection != null || noti.dragDetails == null) {
      return false;
    }

    final scrollDirection = _getScrollDirection(
      atTop: noti.overscroll < -_kOverscrollThreshold,
      atBottom: noti.overscroll > _kOverscrollThreshold,
    );

    _scrollDirection = scrollDirection;

    if (scrollDirection != null) {
      _doSwitchPage();
    } else {
      _showIndicatorCtrl.reverse();
    }

    return false;
  }

  /// Determines the scroll direction based on scroll position
  ///
  /// Returns [SwitchDirection.previous] when at bottom,
  /// [SwitchDirection.next] when at top, or null when in between
  SwitchDirection? _getScrollDirection({
    required bool atTop,
    required bool atBottom,
  }) {
    if (atBottom) return SwitchDirection.previous;
    if (atTop) return SwitchDirection.next;
    return null;
  }

  /// Updates the current scroll direction
  ///
  /// Returns true if the direction was successfully updated,
  /// false if the update was rejected due to conflicting directions
  bool _updateScrollDirection(SwitchDirection? newDirection) {
    if (_scrollDirection != null && newDirection != _scrollDirection) {
      _scrollDirection = null;
      return false;
    }
    if (_scrollDirection == null) {
      _scrollDirection = newDirection;
      return true;
    }
    return false;
  }

  void _resetState() {
    _showIndicatorCtrl.reverse();
    _scrollDirection = null;
    _doSwitchTimer?.cancel();
    _doSwitchTimer = null;
  }

  /// Initiates the page switching process with animation
  ///
  /// Shows the direction indicator and triggers the switch callback after a delay
  Future<void> _doSwitchPage() async {
    await _showIndicatorCtrl.forward();
    if (_scrollDirection == null) return;

    _doSwitchTimer?.cancel();
    _doSwitchTimer = Timer(Durations.medium3, () async {
      final direction = _scrollDirection;
      if (direction == null) return;

      await widget.onSwitchPage(direction);
      await _showIndicatorCtrl.reverse();
      _scrollDirection = null;
    });
  }
}

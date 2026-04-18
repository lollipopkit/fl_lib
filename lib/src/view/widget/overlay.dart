import 'dart:ui';

import 'package:fl_lib/src/core/ext/obj.dart';
import 'package:fl_lib/src/view/widget/val_builder.dart';
import 'package:flutter/material.dart';

class OverlayWidget extends StatefulWidget {
  final Widget child;
  final Widget popup;
  final bool blurBg;

  const OverlayWidget({
    super.key,
    required this.child,
    required this.popup,
    this.blurBg = true,
  });

  static _OverlayWidgetState? maybeOf(BuildContext context) {
    return context.findAncestorStateOfType<_OverlayWidgetState>();
  }

  @override
  State<OverlayWidget> createState() => _OverlayWidgetState();
}

class _OverlayWidgetState extends State<OverlayWidget> with SingleTickerProviderStateMixin {
  OverlayEntry? _overlayEntry;
  bool _isRemovingOverlay = false;
  late final AnimationController _animeCtrl;
  late final CurvedAnimation _overlayCurve;
  late final Animation<double> _blurAnime;
  late final Animation<double> _fadeAnime;

  final _isShowingOverlay = false.vn;

  @override
  void initState() {
    super.initState();
    _animeCtrl = AnimationController(
      vsync: this,
      duration: Durations.medium1,
    );
    _overlayCurve = CurvedAnimation(
      parent: _animeCtrl,
      curve: Curves.easeInOutCubic,
    );
    _blurAnime = Tween<double>(begin: 0, end: 5).animate(_overlayCurve);
    _fadeAnime = Tween<double>(begin: 0, end: 1).animate(_overlayCurve);
  }

  @override
  void dispose() {
    _overlayEntry?.remove();
    _overlayEntry = null;
    _isShowingOverlay.value = false;
    _animeCtrl.dispose();
    super.dispose();
  }

  void _showOverlay(BuildContext context) async {
    if (_overlayEntry != null) {
      return;
    }
    final overlayState = Overlay.of(context);

    _overlayEntry = _createOverlayEntry(context);
    overlayState.insert(_overlayEntry!);
    _isShowingOverlay.value = true;

    await _animeCtrl.forward(from: 0);
  }

  void _removeOverlaySafe() async {
    if (_overlayEntry == null || _isRemovingOverlay) {
      return;
    }
    _isRemovingOverlay = true;
    try {
      if (mounted) {
        await _animeCtrl.reverse();
      }
      _overlayEntry?.remove();
    } finally {
      _overlayEntry = null;
      _isShowingOverlay.value = false;
      _isRemovingOverlay = false;
    }
  }

  OverlayEntry _createOverlayEntry(BuildContext context) {
    return OverlayEntry(
      builder: (context) => GestureDetector(
        onTap: _removeOverlaySafe,
        behavior: HitTestBehavior.opaque,
        child: SizedBox.expand(child: _buildOverlayWidget()),
      ),
    );
  }

  Widget _buildOverlayWidget() {
    final popup = Container(
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 11),
      child: FadeTransition(
        opacity: _fadeAnime,
        child: Center(child: RepaintBoundary(child: widget.popup)),
      ),
    );
    if (!widget.blurBg) {
      return popup;
    }
    return AnimatedBuilder(
      animation: _blurAnime,
      child: popup,
      builder: (_, child) {
        return BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: _blurAnime.value,
            sigmaY: _blurAnime.value,
          ),
          child: child,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValBuilder(
      listenable: _isShowingOverlay,
      builder: (isShowing) {
        return PopScope(
          canPop: !isShowing,
          onPopInvokedWithResult: (didPop, _) {
            if (_overlayEntry == null) return;
            _removeOverlaySafe();
          },
          child: InkWell(
            borderRadius: BorderRadius.circular(7),
            onLongPress: () => _showOverlay(context),
            child: widget.child,
          ),
        );
      },
    );
  }
}

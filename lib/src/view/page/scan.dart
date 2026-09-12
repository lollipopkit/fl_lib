import 'dart:async';

import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';
import 'package:qr_code_dart_scan/qr_code_dart_scan.dart';

final class BarcodeScannerPageArgs {
  final List<BarcodeFormat>? formats;

  const BarcodeScannerPageArgs({this.formats});
}

/// Reads a code with the back camera.
///
/// **The defaults of the underlying view cannot scan a dense code.** Its
/// `resolutionPreset` is `medium`, which is 640x480 on both platforms, and a
/// QR a caller is allowed to generate can be version 40 — 177 modules across.
/// A code held far enough away for the lens to focus covers well under a
/// third of the frame, which at 640 wide leaves under one pixel per module,
/// and a decoder needs two. Raising the resolution is what makes the rest of
/// this page worth having; everything else here exists because the user still
/// has to get the code sharp and large:
///
/// - **Tap to focus.** Continuous autofocus hunts on a flat screen showing a
///   field of black and white squares, and every hunt is a run of frames a
///   blur check throws away. A tap locks it on the code instead.
/// - **Pinch to zoom.** The lens on a phone cannot focus closer than about ten
///   centimetres, and filling the frame from further back is the only other
///   way to get pixels onto a module. On a sensor larger than the stream this
///   crops rather than upscales, so those pixels are real.
class BarcodeScannerPage extends StatefulWidget {
  final BarcodeScannerPageArgs? args;

  const BarcodeScannerPage({
    super.key,
    this.args,
  });

  static const route = AppRoute<ScanResult, BarcodeScannerPageArgs>(
    page: BarcodeScannerPage.new,
    path: '/barcode_scan',
  );

  @override
  State<BarcodeScannerPage> createState() => _BarcodeScannerWithOverlayState();
}

/// How long the ring stays after a tap.
const _focusRingLinger = Durations.extralong4;
const _focusRingSize = 72.0;

class _BarcodeScannerWithOverlayState extends State<BarcodeScannerPage> {
  /// Held here so the overlay can reach the camera.
  ///
  /// Not disposed here: the view disposes whichever controller it is given,
  /// on every lifecycle stop as well as at the end, and documents it as
  /// reusable afterwards.
  final _controller = QRCodeDartScanController();

  var _torch = false;

  /// What the camera answered when asked, which is only known once it is up.
  /// Both 1 until then, so a pinch before the first frame does nothing.
  var _minZoom = 1.0;
  var _maxZoom = 1.0;
  var _zoom = 1.0;
  var _zoomAtPinchStart = 1.0;
  var _zoomRead = false;

  /// Where the last tap asked the camera to focus, in the body's coordinates.
  Offset? _focusAt;
  Timer? _focusTimer;

  @override
  void initState() {
    super.initState();
    _controller.state.addListener(_onCameraState);
  }

  @override
  void dispose() {
    _controller.state.removeListener(_onCameraState);
    _focusTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: CustomAppBar(
        actions: [
          IconButton(
            onPressed: () => unawaited(_toggleTorch()),
            icon: Icon(
              _torch ? Icons.flashlight_on_rounded : Icons.flashlight_off_rounded,
            ),
          ),
        ],
      ),
      // The size a tap is measured against. `MediaQuery` would be the whole
      // window, which is taller than the body by the app bar, and every tap
      // would ask the camera to focus above where the finger was.
      body: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          return GestureDetector(
            // The preview is a texture with no recognisers of its own, so a
            // tap reaches here either way; `opaque` also covers the black
            // before the first frame.
            behavior: HitTestBehavior.opaque,
            onTapUp: (details) => unawaited(_focusOn(details.localPosition, size)),
            onScaleStart: (_) => _zoomAtPinchStart = _zoom,
            onScaleUpdate: _onScaleUpdate,
            child: QRCodeDartScanView(
              controller: _controller,
              typeScan: TypeScan.live,
              formats:
                  widget.args?.formats ?? QRCodeDartScanDecoder.acceptedFormats,
              // 1080p. The one change that decides whether a dense code can be
              // read at all — see this class's own note.
              resolutionPreset: QRCodeDartScanResolutionPreset.veryHigh,
              // Halves the pixels the decoder walks, which it needs at this
              // resolution, and costs nothing visible: a full-screen portrait
              // preview already crops the frame's long axis to about this.
              croppingStrategy: CroppingStrategy.cropCenterSquare(),
              onCapture: context.pop,
              child: _overlay(context),
            ),
          );
        },
      ),
    );
  }

  Widget _overlay(BuildContext context) {
    final focus = _focusAt;
    final scheme = Theme.of(context).colorScheme;
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (focus != null)
            Positioned(
              left: focus.dx - _focusRingSize / 2,
              top: focus.dy - _focusRingSize / 2,
              width: _focusRingSize,
              height: _focusRingSize,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: scheme.primary, width: 2),
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          // Shown only while it is doing something, because it is the one
          // thing on screen that says the pinch was received.
          if (_zoom > _minZoom + 0.05)
            Positioned(
              left: 0,
              right: 0,
              bottom: 32,
              child: Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    child: Text(
                      '${_zoom.toStringAsFixed(1)}x',
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Reads the zoom range once the camera is up, and again after a restart.
  ///
  /// The notifier also fires for every frame's decode state, so this has to be
  /// cheap to call and idempotent — `getMinZoomLevel` is a platform round trip.
  void _onCameraState() {
    if (!_controller.state.value.initialized) {
      _zoomRead = false;
      return;
    }
    if (_zoomRead) return;
    _zoomRead = true;
    unawaited(_readZoomRange());
  }

  Future<void> _readZoomRange() async {
    final camera = _controller.cameraController;
    if (camera == null || !camera.value.isInitialized) return;
    try {
      final min = await camera.getMinZoomLevel();
      final max = await camera.getMaxZoomLevel();
      if (!mounted) return;
      setState(() {
        _minZoom = min;
        _maxZoom = max;
        _zoom = _zoom.clamp(min, max);
      });
    } catch (e) {
      // A camera that will not say is one that will not zoom either, and the
      // page works without it.
      Loggers.app.warning('Read camera zoom range', e);
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    // One finger is a pan, and `onScaleUpdate` reports those too with a scale
    // of exactly 1 — which would still fire a platform call per move event.
    if (details.pointerCount < 2) return;
    final next = (_zoomAtPinchStart * details.scale).clamp(_minZoom, _maxZoom);
    if ((next - _zoom).abs() < 0.01) return;
    setState(() => _zoom = next);
    unawaited(_applyZoom(next));
  }

  Future<void> _applyZoom(double zoom) async {
    final camera = _controller.cameraController;
    if (camera == null || !camera.value.isInitialized) return;
    try {
      await camera.setZoomLevel(zoom);
    } catch (_) {}
  }

  /// Locks focus where the finger was.
  ///
  /// Locked rather than a nudge to the continuous mode: the thing being
  /// scanned does not move, and the hunting is the problem.
  Future<void> _focusOn(Offset local, Size size) async {
    if (size.isEmpty) return;
    setState(() => _focusAt = local);
    _focusTimer?.cancel();
    _focusTimer = Timer(_focusRingLinger, () {
      if (mounted) setState(() => _focusAt = null);
    });
    await _controller.setFocusPoint(
      Offset(
        (local.dx / size.width).clamp(0.0, 1.0),
        (local.dy / size.height).clamp(0.0, 1.0),
      ),
    );
  }

  Future<void> _toggleTorch() async {
    final next = !_torch;
    setState(() => _torch = next);
    await _controller.setFlash(next);
  }
}

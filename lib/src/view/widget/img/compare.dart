import 'dart:async';
import 'dart:ui' as ui;

import 'package:fl_lib/fl_lib.dart';
import 'package:material_ui/material_ui.dart';

/// A widget for comparing two images.
///
/// It displays two images(stacked) side by side, and a draggable handle in the middle.
/// The handle can be dragged horizontally to compare the two images.
/// The left side is the original image, and the right side is the modified image.
final class ImgCompare extends StatefulWidget {
  /// The original image.
  final ImageProvider origin;

  /// The modified image.
  final ImageProvider modified;

  /// The thickness of the draggable handle.
  final double thickness;

  /// The indicator widget to show the drag position.
  ///
  /// If null, only the drag line is displayed.
  final Widget? indicator;

  /// The size of the indicator widget.
  ///
  /// Only works when [indicator] is not null.
  final double indicatorSize;

  final BoxFit fit;

  const ImgCompare({
    super.key,
    required this.origin,
    required this.modified,
    this.thickness = 2,
    this.indicator,
    this.indicatorSize = 30,
    this.fit = BoxFit.contain,
  });

  @override
  State<ImgCompare> createState() => _ImgCompareState();
}

final class _ImgCompareState extends State<ImgCompare> {
  late double _horizonPx;
  late Size _windowSize;

  /// The image ratio (height / width).
  ///
  /// Used for constraining the drag handle's height.
  double? _imgRatio;

  static const _kDragMinWidth = 30.0;

  // Store BoxConstraints for calculations
  late BoxConstraints _constraints;

  // Add this field to store the InteractiveViewer's transformation matrix
  Matrix4 _transformationMatrix = Matrix4.identity();
  final _controller = TransformationController();

  @override
  void initState() {
    super.initState();
    _loadImageRatio();
    _controller.addListener(() {
      // Update the transformation matrix when the controller changes
      setState(() {
        _transformationMatrix = _controller.value;
      });
    });
  }

  void _loadImageRatio() async {
    final ImageStream stream = widget.origin.resolve(ImageConfiguration.empty);
    final Completer<ui.Image> completer = Completer();

    void listener(ImageInfo info, bool _) {
      completer.complete(info.image);
      stream.removeListener(ImageStreamListener(listener));
    }

    stream.addListener(ImageStreamListener(listener));
    final ui.Image img = await completer.future;

    await Future.delayed(const Duration(milliseconds: 100));
    // It affects all the widgets in the descendant tree.
    // So, it's safe to call setState here.
    setState(() {
      _imgRatio = img.height / img.width;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _windowSize = context.windowSize;
    _horizonPx = _windowSize.width / 2;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (_, cons) {
      _constraints = cons;
      return _build;
    });
  }

  Widget get _build {
    return Stack(
      children: [
        InteractiveViewer(
          transformationController: _controller,
          child: Stack(
            children: [
              // Display the modified image as the background
              Image(
                image: widget.origin,
                fit: widget.fit,
                width: double.infinity,
                height: double.infinity,
              ),
              // Clip the original image based on the drag position
              ClipRect(
                clipper: _ImageClipper(_horizonPx),
                child: Image(
                  image: widget.modified,
                  fit: widget.fit,
                  width: double.infinity,
                  height: double.infinity,
                ),
              ),
              // Display the drag handle
              if (_imgRatio != null) _buildDragHandle(_windowSize.width * _imgRatio!),
            ],
          ),
        ),
        // Display the indicator
        // Put it outside the InteractiveViewer to avoid being scaled
        _buildDragIndicator,
      ],
    );
  }

  Widget _buildDragHandle(double height) {
    return Positioned(
      left: _horizonPx - widget.thickness / 2 - _kDragMinWidth / 2,
      top: 0,
      bottom: 0,
      child: FadeIn(
        duration: Durations.long3,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragUpdate: (v) => _onDragUpdate(v, true),
          child: Container(
            width: _kDragMinWidth, // Increased width for better touch area
            alignment: Alignment.center,
            child: SizedBox(
              width: widget.thickness,
              // Constraint the height of the drag handle, or it may overflow the image size
              height: height,
              child: _buildDragLine(height),
            ),
          ),
        ),
      ),
    );
  }

  Widget get _buildDragIndicator {
    final indicator = widget.indicator;
    if (indicator == null) return const SizedBox();
    final position = _calcIndicatorPosition();
    return Positioned(
      left: position.dx,
      top: position.dy,
      child: FadeIn(
        duration: Durations.long3,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragUpdate: (v) => _onDragUpdate(v, false),
          child: SizedBox(
            width: widget.indicatorSize,
            height: widget.indicatorSize,
            child: indicator,
          ),
        ),
      ),
    );
  }

  Offset _calcIndicatorPosition() {
    // Calculate the position based on the transformation matrix
    final indicatorSize = widget.indicatorSize;
    final scale = _transformationMatrix.getMaxScaleOnAxis();
    final originalPosition = Offset(
      _horizonPx - indicatorSize / 2 / scale - widget.thickness * scale / 2.2, // divide by scale to adjust the position
      (_constraints.maxHeight - indicatorSize / scale) / 2, // same as above
    );
    final transformedPosition = MatrixUtils.transformPoint(_transformationMatrix, originalPosition);
    return transformedPosition;
  }

  void _onDragUpdate(DragUpdateDetails details, bool isDragLine) {
    final consRatio = _constraints.maxHeight / _constraints.maxWidth;
    final imgRatio = _imgRatio;
    if (imgRatio == null) return;
    final delta = details.primaryDelta;
    if (delta == null) return;
    final isNarrowImg = consRatio < imgRatio;
    setState(() {
      if (isDragLine) {
        _horizonPx += delta;
      } else {
        _horizonPx += delta / _transformationMatrix.getMaxScaleOnAxis(); // divide by scale to adjust the drag speed
      }
      if (isNarrowImg) {
        final imgWidth = _constraints.maxHeight / imgRatio;
        final imgLeft = (_windowSize.width - imgWidth) / 2;
        _horizonPx = _horizonPx.clamp(imgLeft, imgLeft + imgWidth);
      } else {
        _horizonPx = _horizonPx.clamp(0.0, _windowSize.width);
      }
    });
  }

  Widget _buildDragLine(double height) {
    return CustomPaint(
      painter: _LinePainter(width: widget.thickness),
      size: ui.Size(widget.thickness, height),
    );
  }
}

/// A widget for comparing two images with a slide animation.
///
/// It's not draggable, but can slide the original image to compare with the modified image.
///
/// If you want to compare two images side by side, use [ImgCompare].
final class ImgSlideAnimCompare extends StatefulWidget {
  /// The original image.
  final ImageProvider origin;

  /// The modified image.
  final ImageProvider modified;
  final BoxFit fit;

  const ImgSlideAnimCompare({
    super.key,
    required this.origin,
    required this.modified,
    this.fit = BoxFit.contain,
  });

  @override
  State<ImgSlideAnimCompare> createState() => _ImgSlideAnimCompareState();
}

final class _ImgSlideAnimCompareState extends State<ImgSlideAnimCompare> with SingleTickerProviderStateMixin {
  late Size _windowSize;

  late final _originImgSlideLeftAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  );
  late final _curvedAnim = CurvedAnimation(
    parent: _originImgSlideLeftAnim,
    curve: Curves.fastEaseInToSlowEaseOut,
  );

  @override
  void initState() {
    super.initState();
    _originImgSlideLeftAnim.forward();
  }

  @override
  void dispose() {
    _originImgSlideLeftAnim.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _windowSize = context.windowSize;
    // The wipe travels across the image; under reduced motion it has already
    // happened.
    if (MediaQuery.disableAnimationsOf(context)) _originImgSlideLeftAnim.value = 1;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (_, cons) {
      return _build(cons);
    });
  }

  Widget _build(BoxConstraints cons) {
    return InteractiveViewer(
      child: SizedBox(
        width: cons.maxWidth,
        child: Stack(
          children: [
            // Display the modified image as the background
            Image(
              image: widget.modified,
              fit: widget.fit,
              width: double.infinity,
              height: double.infinity,
            ),
            // Clip the original image based on the drag position
            AnimatedBuilder(
              animation: _curvedAnim,
              builder: (_, _) {
                return ClipRect(
                  clipper: _ImageClipper(_windowSize.width * (1 - _curvedAnim.value)),
                  child: Image(
                    image: widget.origin,
                    fit: widget.fit,
                    width: double.infinity,
                    height: double.infinity,
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// The custom painter for the drag line
final class _LinePainter extends CustomPainter {
  final double width;

  _LinePainter({required this.width});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = width
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    canvas.drawLine(const Offset(0, 0), Offset(0, size.height), paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// Clips the image based on the drag position
class _ImageClipper extends CustomClipper<Rect> {
  final double clipX;
  _ImageClipper(this.clipX);

  @override
  Rect getClip(Size size) {
    return Rect.fromLTWH(0, 0, clipX, size.height);
  }

  @override
  bool shouldReclip(_ImageClipper oldClipper) => clipX != oldClipper.clipX;
}

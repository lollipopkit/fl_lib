import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Parts of the window the system's own window controls cover, in logical
/// pixels from the window's top left.
///
/// iPadOS 26 draws a windowed app's close, minimise and tile buttons over its
/// content, and the platform reports none of it as `MediaQuery.padding`. The
/// host fills this in; empty means nothing is covered, which is every other
/// platform and an iPad app in full screen.
abstract final class WindowControls {
  static final zones = ValueNotifier<List<Rect>>(const []);
}

/// Adds to its subtree's `MediaQuery.padding` whatever part of
/// [WindowControls.zones] it is laid out under.
///
/// For a widget that already keeps out of the padding — an `AppBar`, or a
/// `SafeArea` — at the top of the window: a bar under the controls moves its
/// content along [axis] past them, and one beside or below them is left as it
/// was. The padding is only ever grown, so a status bar or a notch that
/// already asks for more still wins.
///
/// Decided from where the widget is laid out, not where it is painted: a page
/// sliding in is still the page it lands as, and measuring it mid-flight
/// would move its back button the moment the transition ends.
class WindowControlsInset extends StatefulWidget {
  const WindowControlsInset({
    super.key,
    this.axis = Axis.horizontal,
    this.safeArea = false,
    required this.child,
  });

  /// [Axis.horizontal] moves content sideways past the controls, as a bar
  /// along the top does; [Axis.vertical] moves it down, as a column along the
  /// side does.
  final Axis axis;

  /// Wraps [child] in a `SafeArea` that keeps its top and sides, for a bar
  /// that does not keep out of the padding on its own. Inside a page that
  /// already took the padding, that is only ever the controls.
  final bool safeArea;

  final Widget child;

  @override
  State<WindowControlsInset> createState() => _WindowControlsInsetState();
}

class _WindowControlsInsetState extends State<WindowControlsInset> {
  /// Where this widget was last laid out, in the window.
  Rect? _bounds;

  @override
  void initState() {
    super.initState();
    WindowControls.zones.addListener(_rebuild);
  }

  @override
  void dispose() {
    WindowControls.zones.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() => setState(() {});

  /// Called from paint, so the rebuild waits for the frame to finish. Settles
  /// in one more frame: the padding it leads to does not move this widget.
  void _onBounds(Rect bounds) {
    if (bounds == _bounds) return;
    _bounds = bounds;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  /// What [padding] has to grow to for the content to clear every zone.
  ///
  /// Sideways, only a zone beside where the content starts counts: a bar
  /// whose padding already puts it below the controls, under a status bar,
  /// has nothing to step around.
  EdgeInsets _clear(EdgeInsets padding) {
    final bounds = _bounds;
    final zones = WindowControls.zones.value;
    if (bounds == null || zones.isEmpty) return padding;
    var out = padding;
    for (final zone in zones) {
      switch (widget.axis) {
        case Axis.vertical:
          if (!zone.overlaps(bounds)) continue;
          out = out.copyWith(top: _max(out.top, zone.bottom - bounds.top));
        case Axis.horizontal:
          final content = Rect.fromLTRB(
            bounds.left,
            bounds.top + padding.top,
            bounds.right,
            bounds.bottom,
          );
          if (!zone.overlaps(content)) continue;
          out = zone.center.dx < bounds.center.dx
              ? out.copyWith(left: _max(out.left, zone.right - bounds.left))
              : out.copyWith(right: _max(out.right, bounds.right - zone.left));
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return MediaQuery(
      data: mq.copyWith(padding: _clear(mq.padding)),
      child: _BoundsProbe(
        onBounds: _onBounds,
        child: widget.safeArea
            ? SafeArea(bottom: false, child: widget.child)
            : widget.child,
      ),
    );
  }
}

double _max(double a, double b) => a > b ? a : b;

class _BoundsProbe extends SingleChildRenderObjectWidget {
  const _BoundsProbe({required this.onBounds, super.child});

  final ValueChanged<Rect> onBounds;

  @override
  _RenderBoundsProbe createRenderObject(BuildContext context) =>
      _RenderBoundsProbe(onBounds);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderBoundsProbe renderObject,
  ) => renderObject.onBounds = onBounds;
}

class _RenderBoundsProbe extends RenderProxyBox {
  _RenderBoundsProbe(this.onBounds);

  ValueChanged<Rect> onBounds;

  // Zones appearing do not move anything, so nothing else would repaint this
  // and report where it is.
  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    WindowControls.zones.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    WindowControls.zones.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    // Only when something could be covered: everywhere else this is a walk up
    // the tree on every repaint of every bar, for nothing.
    if (WindowControls.zones.value.isEmpty) return;
    onBounds(_layoutOrigin() & size);
  }

  /// The sum of the offsets each ancestor laid its child out at. Transforms
  /// and scroll positions are not offsets and are left out on purpose: they
  /// are how a page moves on its way somewhere, and what matters is where it
  /// stops.
  Offset _layoutOrigin() {
    var origin = Offset.zero;
    RenderObject? node = this;
    while (node != null) {
      final data = node.parentData;
      if (data is BoxParentData) origin += data.offset;
      node = node.parent;
    }
    return origin;
  }
}

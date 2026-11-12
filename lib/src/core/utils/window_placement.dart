import 'dart:math' as math;
import 'dart:ui';

/// Height of the strip at the top of a window that holds its title bar or
/// drag area.
const kWindowTitleStripHeight = 32.0;

/// How much of [kWindowTitleStripHeight] must be on a display for the window
/// to be dragged from there.
const kWindowMinVisibleTitleHeight = 16.0;

/// How much of the title strip's width must be on a display, or the whole
/// width of a narrower window.
const kWindowMinVisibleTitleWidth = 120.0;

/// A display's usable area (without taskbar, dock or menu bar).
final class WindowDisplay {
  const WindowDisplay(this.area, {this.scale = 1});

  /// In the display's own logical pixels, the space a window on it reports
  /// its position in.
  final Rect area;

  /// Window logical pixels per display logical pixel at startup: on Windows
  /// the display's scale factor over the window's, elsewhere 1.
  final double scale;
}

/// The size and position to open a window with.
final class WindowPlacement {
  const WindowPlacement({this.size, this.position});

  final Size? size;

  /// Null leaves the window where the system puts it, centered.
  final Offset? position;

  @override
  bool operator ==(Object other) =>
      other is WindowPlacement && other.size == size && other.position == position;

  @override
  int get hashCode => Object.hash(size, position);

  @override
  String toString() => 'WindowPlacement(size: $size, position: $position)';
}

/// Decides where a window saved at [position] with [size] opens on the
/// [displays] now connected.
///
/// The saved position is kept when the window's title strip is on a display,
/// else the window is centered on [primary] (the first display when null),
/// or left to the system without a [size]. The size never exceeds the display
/// the window opens on. Without displays the saved values are returned as
/// they are.
WindowPlacement placeWindow({
  required Size? size,
  required Offset? position,
  required List<WindowDisplay> displays,
  WindowDisplay? primary,
}) {
  if (displays.isEmpty) return WindowPlacement(size: size, position: position);

  if (position != null) {
    const minimal = Size(kWindowMinVisibleTitleWidth, kWindowTitleStripHeight);
    final host = _hostDisplay(position, size ?? minimal, displays);
    if (host != null) {
      return WindowPlacement(
        // Moved there, the window is rescaled to the display's own pixels.
        size: size == null ? null : _clamp(size, host.area.size),
        position: position * host.scale,
      );
    }
  }

  if (size == null) return const WindowPlacement();
  final target = primary ?? displays.first;
  // As above: once on the display the size is in its pixels, the position
  // still in the window's.
  final fitted = _clamp(size, target.area.size);
  final centered = target.area.topLeft +
      Offset(
        (target.area.width - fitted.width) / 2,
        (target.area.height - fitted.height) / 2,
      );
  return WindowPlacement(size: fitted, position: centered * target.scale);
}

/// The display the title strip can be dragged from, with the window no larger
/// than that display.
WindowDisplay? _hostDisplay(Offset position, Size size, List<WindowDisplay> displays) {
  WindowDisplay? best;
  var bestArea = 0.0;
  for (final display in displays) {
    final fitted = _clamp(size, display.area.size);
    final stripHeight = math.min(kWindowTitleStripHeight, fitted.height);
    final strip = Rect.fromLTWH(position.dx, position.dy, fitted.width, stripHeight);
    if (!strip.overlaps(display.area)) continue;
    final visible = strip.intersect(display.area);
    if (visible.height < math.min(kWindowMinVisibleTitleHeight, stripHeight) ||
        visible.width < math.min(kWindowMinVisibleTitleWidth, fitted.width)) {
      continue;
    }
    final area = visible.width * visible.height;
    if (area > bestArea) {
      best = display;
      bestArea = area;
    }
  }
  return best;
}

Size _clamp(Size size, Size limit) =>
    Size(math.min(size.width, limit.width), math.min(size.height, limit.height));

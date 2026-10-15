import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

/// A modal bottom sheet with three heights, moved between by dragging its
/// grip: closed, its own, and the whole window.
///
/// Its own is the height of its content, up to [ResizableSheet.restFactor] of
/// the window — of what the keyboard leaves of it, which the sheet sits on.
/// The content sets no cap of its own, nor room for the keyboard: a cap would
/// stop it following the sheet up, and the room would be made twice.
///
/// [showGrip] false is for a [builder] that draws its own surface — a sheet
/// with a transparent background — and places a [SheetGrip] on it.
Future<T?> showResizableSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool showGrip = true,
  bool useRootNavigator = true,
  bool useSafeArea = true,
  Color? backgroundColor,
  BoxConstraints? constraints,
  AnimationStyle? sheetAnimationStyle,
}) {
  return showModalBottomSheet<T>(
    context: context,
    useRootNavigator: useRootNavigator,
    useSafeArea: useSafeArea,
    // What lets it grow past 9/16 at all; [ResizableSheet] decides the height.
    isScrollControlled: true,
    // [SheetGrip] instead: Material's handle only closes the sheet.
    showDragHandle: false,
    backgroundColor: backgroundColor,
    constraints: constraints,
    sheetAnimationStyle: sheetAnimationStyle,
    builder: (ctx) => ResizableSheet(showGrip: showGrip, child: builder(ctx)),
  );
}

/// The body of a [showResizableSheet]: the grip and the height it sets.
class ResizableSheet extends StatefulWidget {
  const ResizableSheet({super.key, required this.child, this.showGrip = true});

  final Widget child;
  final bool showGrip;

  /// The most of the window a sheet takes before it is asked for more.
  static const restFactor = 0.6;

  @override
  State<ResizableSheet> createState() => _ResizableSheetState();
}

class _ResizableSheetState extends State<ResizableSheet> {
  /// Null while it is at its own height, which its content decides.
  double? _height;

  /// Its own height, as laid out before the first drag.
  double? _restHeight;

  /// What there is above the keyboard: the window, while it is down.
  double _maxHeight = double.infinity;

  /// The keyboard, which the sheet sits on rather than its content making
  /// room for it: inside, it came out of the 60% and left the content little.
  double _inset = 0;
  bool _dragging = false;

  static const _flingVelocity = 700.0;

  /// Its own height, measured while it still has it.
  double? _rest() {
    if (_restHeight case final rest?) return rest;
    if (_height != null) return null;
    final size = context.size;
    if (size == null) return null;
    return _restHeight = size.height - _inset;
  }

  void _dragStart() {
    final rest = _rest();
    if (rest == null) return;
    setState(() {
      _height ??= rest;
      _dragging = true;
    });
  }

  void _dragUpdate(double dy) {
    final height = _height;
    if (height == null) return;
    setState(() => _height = (height - dy).clamp(0.0, _maxHeight));
  }

  void _dragEnd(double velocity) {
    final height = _height;
    final rest = _restHeight;
    if (height == null || rest == null) return;
    final full = _maxHeight;
    // A fling goes one step its way; a slow release to the nearest.
    final double target;
    if (velocity < -_flingVelocity) {
      target = height < rest ? rest : full;
    } else if (velocity > _flingVelocity) {
      target = height > rest ? rest : 0;
    } else if (height < rest / 2) {
      target = 0;
    } else if (height < (rest + full) / 2) {
      target = rest;
    } else {
      target = full;
    }
    if (target == 0) {
      // Left where it is: growing back while the route slid it away read as
      // the sheet bouncing before it closed. Back to its own height only if it
      // stays.
      setState(() => _dragging = false);
      Navigator.maybePop(context).then((closed) {
        if (!closed && mounted) setState(() => _height = rest);
      });
      return;
    }
    setState(() {
      _dragging = false;
      _height = target;
    });
  }

  /// Keyboard and screen reader steps: its own height and the window.
  void _step(bool up) {
    final rest = _rest();
    if (rest == null) return;
    setState(() => _height = up ? _maxHeight : rest);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _inset = MediaQuery.viewInsetsOf(context).bottom;
        final window = constraints.hasBoundedHeight
            ? constraints.maxHeight
            : MediaQuery.sizeOf(context).height;
        _maxHeight = (window - _inset).clamp(0.0, window);
        final content = _SheetScope(
          state: this,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.showGrip) const SheetGrip(),
              Flexible(child: widget.child),
            ],
          ),
        );
        // One widget at every height. Swapping a box for another at the first
        // drag rebuilt the grip under the finger, and the drag ended there.
        // The keyboard outside the animation, which would trail it.
        final height = _height;
        return Padding(
          padding: EdgeInsets.only(bottom: _inset),
          child: AnimatedContainer(
            duration: _dragging
                ? Duration.zero
                : const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            height: height?.clamp(0.0, _maxHeight),
            constraints: height == null
                ? BoxConstraints(
                    maxHeight: _maxHeight * ResizableSheet.restFactor,
                  )
                : null,
            child: content,
          ),
        );
      },
    );
  }
}

class _SheetScope extends InheritedWidget {
  const _SheetScope({required this.state, required super.child});

  final _ResizableSheetState state;

  @override
  bool updateShouldNotify(_SheetScope oldWidget) => state != oldWidget.state;
}

/// The handle a [ResizableSheet] is resized by.
///
/// Drawn by the sheet itself unless it was opened with `showGrip: false`, in
/// which case its content places one. Outside a [ResizableSheet] — the same
/// content shown in a dialog — it is nothing.
class SheetGrip extends StatelessWidget {
  const SheetGrip({super.key});

  /// Material's own measurements for the line.
  static const _size = Size(32, 4);

  /// Room above and below the line, which is also what can be dragged.
  static const _padding = 12.0;

  @override
  Widget build(BuildContext context) {
    final state = context
        .dependOnInheritedWidgetOfExactType<_SheetScope>()
        ?.state;
    if (state == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final line = Container(
      margin: const EdgeInsets.symmetric(vertical: _padding),
      width: _size.width,
      height: _size.height,
      decoration: BoxDecoration(
        color:
            Theme.of(context).bottomSheetTheme.dragHandleColor ??
            scheme.onSurfaceVariant.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(_size.height / 2),
      ),
    );
    final l10n = MaterialLocalizations.of(context);
    return Semantics(
      label: l10n.modalBarrierDismissLabel,
      onTap: () => Navigator.maybePop(context),
      onIncrease: () => state._step(true),
      onDecrease: () => state._step(false),
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeUpDown,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // From where the finger went down, so the edge stays under it.
          dragStartBehavior: DragStartBehavior.down,
          onVerticalDragStart: (_) => state._dragStart(),
          onVerticalDragUpdate: (d) => state._dragUpdate(d.delta.dy),
          onVerticalDragCancel: () => state._dragEnd(0),
          onVerticalDragEnd: (d) =>
              state._dragEnd(d.velocity.pixelsPerSecond.dy),
          child: SizedBox(
            width: double.infinity,
            child: Center(child: line),
          ),
        ),
      ),
    );
  }
}

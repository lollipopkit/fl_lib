import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

/// A modal bottom sheet whose height the user sets by dragging its grip: up to
/// the whole window, back down, or down past where it opened to close it.
///
/// [heightFactor] is the share of the window it opens at. Null opens it at the
/// height of its content, up to [contentMaxFactor] of the window — Material's
/// 9/16 for a sheet that is not scroll-controlled, unless said otherwise. The
/// content sets no cap of its own: one would stop it following the sheet up.
///
/// [showGrip] false is for a [builder] that draws its own surface — a sheet
/// with a transparent background — and places a [SheetGrip] on it.
Future<T?> showResizableSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  double? heightFactor,
  double contentMaxFactor = ResizableSheet.defaultContentMaxFactor,
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
    builder: (ctx) => ResizableSheet(
      heightFactor: heightFactor,
      contentMaxFactor: contentMaxFactor,
      showGrip: showGrip,
      child: builder(ctx),
    ),
  );
}

/// The body of a [showResizableSheet]: the grip and the height it sets.
class ResizableSheet extends StatefulWidget {
  const ResizableSheet({
    super.key,
    required this.child,
    this.heightFactor,
    this.contentMaxFactor = defaultContentMaxFactor,
    this.showGrip = true,
  });

  final Widget child;
  final double? heightFactor;
  final double contentMaxFactor;
  final bool showGrip;

  /// Material's cap for a sheet that is not scroll-controlled.
  static const defaultContentMaxFactor = 9 / 16;

  @override
  State<ResizableSheet> createState() => _ResizableSheetState();
}

class _ResizableSheetState extends State<ResizableSheet> {
  /// Null until the first drag: before it the sheet keeps its opening height.
  double? _height;

  /// The height it opened at, which a drag below closes it from.
  double? _restHeight;

  double _maxHeight = double.infinity;
  bool _dragging = false;

  static const _flingVelocity = 700.0;

  void _dragStart() {
    final height = context.size?.height;
    if (height == null) return;
    _restHeight ??= height;
    setState(() {
      _height ??= height;
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
    final double? target;
    if (height <= rest &&
        (velocity > _flingVelocity || height < rest / 2)) {
      // Material's own drag to close still works on the rest of the sheet;
      // this is the same gesture started on the grip.
      Navigator.maybePop(context);
      target = rest;
    } else if (velocity > _flingVelocity || height < rest) {
      target = rest;
    } else if (velocity < -_flingVelocity) {
      target = _maxHeight;
    } else {
      target = null;
    }
    setState(() {
      _dragging = false;
      if (target != null) _height = target;
    });
  }

  /// Keyboard and screen reader steps, between where it opened and the window.
  void _step(bool up) {
    final rest = _restHeight ?? context.size?.height;
    if (rest == null) return;
    _restHeight ??= rest;
    setState(() => _height = up ? _maxHeight : rest);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _maxHeight = constraints.hasBoundedHeight
            ? constraints.maxHeight
            : MediaQuery.sizeOf(context).height;
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
        final height = _height;
        if (height != null) {
          return AnimatedContainer(
            duration: _dragging
                ? Duration.zero
                : const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            height: height.clamp(0.0, _maxHeight),
            child: content,
          );
        }
        if (widget.heightFactor case final factor?) {
          return SizedBox(height: _maxHeight * factor, child: content);
        }
        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: _maxHeight * widget.contentMaxFactor,
          ),
          child: content,
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

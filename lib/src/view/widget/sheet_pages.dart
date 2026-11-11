import 'dart:async';

import 'package:fl_lib/src/core/ext/ctx/motion.dart';
import 'package:fl_lib/src/view/widget/resizable_sheet.dart';
import 'package:flutter/rendering.dart' show BoxHitTestResult, RenderProxyBox;
import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

/// The pages of one sheet `showSheet` raised: one modal route, and what is
/// raised while it is in front goes on as its next page rather than as a
/// second sheet stacked on it.
///
/// A pop of the route — `Navigator.pop`, `popSheet`, `context.pop`, back, the
/// barrier — pops the top page while there is more than one; a drag down on
/// the grip closes the whole sheet, when every page may be closed.
///
/// An answer waits for frames: a page's comes once it has left the tree, the
/// sheet's once it is off the screen. A paused or backgrounded app delivers
/// it on resume.
final class SheetStack extends ChangeNotifier {
  SheetStack._(WidgetBuilder first, bool dismissible, double restLimit) {
    _pages.add(SheetPage._(first, dismissible, restLimit, null));
  }

  final _pages = <SheetPage>[];
  late final SheetRoute _route;

  /// Set while the whole sheet is closing, when a pop is the route's own.
  bool _closing = false;

  ModalRoute<Object?> get route => _route;
  int get depth => _pages.length;
  SheetPage get top => _pages.last;

  /// Whether the barrier, a drag and back may take the top page away.
  bool get dismissible => top.dismissible;

  /// Whether the grip may close the whole sheet: no page under the top one
  /// holds either.
  bool get allDismissible => _pages.every((p) => p.dismissible);

  /// Pages taken away whose answers are not delivered yet: what is under
  /// them takes no taps until they are.
  int _answering = 0;
  bool get answering => _answering > 0;

  /// Over the navigator from the sheet's pop until its answer is delivered:
  /// the exit animation leaves the page beneath tappable, and a second tap on
  /// what raised the sheet raised a second one before the first was acted on.
  OverlayEntry? _absorber;

  /// Raises [builder] in a new sheet on [navigator]; its future is the first
  /// page's answer.
  static (SheetStack, Future<Object?>) raise(
    BuildContext context, {
    required WidgetBuilder builder,
    required bool dismissible,
    required double restLimit,
  }) {
    final navigator = Navigator.of(context, rootNavigator: true);
    final l10n = MaterialLocalizations.of(context);
    final stack = SheetStack._(builder, dismissible, restLimit);
    stack._route = SheetRoute._(
      stack,
      capturedThemes: InheritedTheme.capture(
        from: context,
        to: navigator.context,
      ),
      barrierLabel: l10n.scrimLabel,
      barrierOnTapHint: l10n.scrimOnTapHint(l10n.bottomSheetLabel),
      modalBarrierColor: Theme.of(context).bottomSheetTheme.modalBarrierColor,
    );
    return (stack, navigator.push<Object?>(stack._route));
  }

  /// The first page: what takes the route with it when removed.
  SheetPage get first => _pages.first;

  /// Puts [builder] on as the next page; its future completes when that page
  /// is taken away.
  (SheetPage, Future<Object?>) push(
    WidgetBuilder builder, {
    required bool dismissible,
    required double restLimit,
  }) {
    final page = SheetPage._(
      builder,
      dismissible,
      restLimit,
      Completer<Object?>(),
    );
    _pages.add(page);
    _changed();
    return (page, page._done!.future);
  }

  /// Pops the top page with [result]; false when it is the only one.
  bool popPage([Object? result]) {
    if (_pages.length < 2) return false;
    _take(result);
    _changed();
    return true;
  }

  /// Takes [page] away with every page over it, innermost first; the first
  /// page takes the sheet. What raised a page closes that page, not whatever
  /// was raised over it meanwhile.
  void remove(SheetPage page) {
    final i = _pages.indexOf(page);
    if (i < 0) return;
    if (i == 0) {
      close();
      return;
    }
    while (_pages.length > i) {
      _take(null);
    }
    _changed();
  }

  void _take(Object? result) {
    final page = _pages.removeLast();
    _answering++;
    // Answered once it has left the tree, not before: what a caller does with
    // the answer — disposing a field's controller — must not be under a page
    // still built.
    SchedulerBinding.instance
      ..addPostFrameCallback((_) {
        page._done!.complete(result);
        // After the caller's continuation, which the completion schedules.
        scheduleMicrotask(() {
          _answering--;
          if (!_disposed) notifyListeners();
        });
      })
      ..scheduleFrame();
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  bool _absorbing = false;

  void _absorb() {
    if (_absorber != null) return;
    final overlay = _route.navigator?.overlay;
    if (overlay == null) return;
    _absorbing = true;
    overlay.insert(
      _absorber = OverlayEntry(
        builder: (_) => _Absorb(
          absorbing: () => _absorbing,
          child: const SizedBox.expand(),
        ),
      ),
    );
  }

  /// Once the sheet's answer is delivered. Taps go through at once; the
  /// entry itself goes with the next frame.
  void released() {
    _absorbing = false;
    _absorber?.remove();
    _absorber?.dispose();
    _absorber = null;
  }

  /// Closes the whole sheet, every page answering null.
  void close() {
    if (!_route.isActive) return;
    _closing = true;
    if (_route.isCurrent) {
      _route.navigator?.pop();
    } else {
      _route.navigator?.removeRoute(_route);
    }
  }

  /// Answers the pages still open above the first with null, innermost
  /// first: the route is gone.
  ///
  /// Their futures, in that order: awaited one by one, whoever was waiting
  /// for a page hears before whoever waits for the next.
  List<Future<Object?>> ended() => [
    for (; _pages.length > 1;)
      (_pages.removeLast()._done!..complete(null)).future,
  ];

  void _changed() {
    notifyListeners();
    // The route reads the top page for its barrier and drag.
    if (_route.isActive) _route.changedExternalState();
  }
}

/// One page of a [SheetStack].
final class SheetPage {
  SheetPage._(this.builder, this.dismissible, this.restLimit, this._done);

  final WidgetBuilder builder;
  final bool dismissible;
  final double restLimit;

  /// Null for the first page, whose answer is the route's.
  final Completer<Object?>? _done;

  /// Built once: a rebuild of the stack is no reason to build every page.
  late final Widget _widget = Builder(builder: builder);
}

/// The modal route of a [SheetStack].
///
/// A `ModalBottomSheetRoute` whose barrier, drag and pop read the top page.
final class SheetRoute extends ModalBottomSheetRoute<Object?> {
  SheetRoute._(
    this.stack, {
    super.capturedThemes,
    super.barrierLabel,
    super.barrierOnTapHint,
    super.modalBarrierColor,
  }) : super(
         builder: (_) => _SheetPagesHost(stack),
         isScrollControlled: true,
         useSafeArea: true,
         showDragHandle: false,
       );

  final SheetStack stack;

  /// Material's own drag closes the route at once; with pages under the top
  /// one, only the grip's does, which closes them all.
  @override
  bool get enableDrag => stack.depth == 1 && stack.dismissible;

  // The barrier is Material's: its tap is a `maybePop`, which the host's
  // `PopScope` holds for a page that holds and [didPop] turns into one page.

  @override
  bool get isDismissible => stack.dismissible;

  @override
  bool get barrierDismissible => stack.dismissible;

  @override
  bool didPop(Object? result) {
    if (!stack._closing && stack.popPage(result)) return false;
    stack._absorb();
    return super.didPop(result);
  }
}

class _SheetPagesHost extends StatelessWidget {
  const _SheetPagesHost(this.stack);

  final SheetStack stack;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: stack,
      builder: (context, _) {
        final dismissible = stack.dismissible;
        final top = stack.top;
        return PopScope(
          // Back pops a page through [SheetRoute.didPop]; a page that holds
          // holds against it.
          canPop: dismissible,
          child: ResizableSheet(
            // The grip closes every page: not over one that holds.
            dismissible: stack.allDismissible,
            restLimit: top.restLimit,
            contentKey: top,
            onDismiss: stack.close,
            gripLeading: stack.depth > 1 && dismissible
                ? IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const BackButtonIcon(),
                    tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                    onPressed: () => stack.popPage(),
                  )
                : null,
            child: AnimatedSize(
              duration: context.motion(const Duration(milliseconds: 220)),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: _Absorb(
                absorbing: () => stack.answering,
                child: Stack(
                  children: [
                    for (final (i, page) in stack._pages.indexed)
                      _Page(
                        key: ObjectKey(page),
                        active: page == top,
                        enters: i > 0,
                        child: page._widget,
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A page, kept mounted and out of sight while one is over it, so what was
/// typed and scrolled is still there on the way back.
class _Page extends StatefulWidget {
  const _Page({
    super.key,
    required this.active,
    required this.enters,
    required this.child,
  });

  final bool active;

  /// Whether it comes in over a page, rather than with the sheet.
  final bool enters;
  final Widget child;

  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    value: widget.enters ? 0 : 1,
  );
  late final _curved = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );

  /// Which side it comes in from: after its page, or back from the one that
  /// was over it.
  var _back = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller.duration = context.motion(const Duration(milliseconds: 220));
    if (_controller.value == 0 && !_controller.isAnimating) {
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(_Page oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      _back = true;
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _curved.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curved = _curved;
    // A fade only when the device asks for less movement.
    final from = context.reduceMotion
        ? Offset.zero
        : Offset(_back ? -0.06 : 0.06, 0);
    return Offstage(
      offstage: !widget.active,
      child: TickerMode(
        enabled: widget.active,
        child: ExcludeFocus(
          excluding: !widget.active,
          child: SizedBox(
            width: double.infinity,
            child: FadeTransition(
              opacity: curved,
              child: SlideTransition(
                position: Tween(begin: from, end: Offset.zero).animate(curved),
                textDirection: Directionality.maybeOf(context),
                child: widget.child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Takes the taps over its box while [absorbing] says so, read when the tap
/// comes rather than when it was built: an answer delivered between two
/// frames lets the next tap through, not the one after the next frame.
class _Absorb extends SingleChildRenderObjectWidget {
  const _Absorb({required this.absorbing, super.child});

  final bool Function() absorbing;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderAbsorb(absorbing);

  @override
  void updateRenderObject(BuildContext context, _RenderAbsorb renderObject) {
    renderObject.absorbing = absorbing;
  }
}

class _RenderAbsorb extends RenderProxyBox {
  _RenderAbsorb(this.absorbing);

  bool Function() absorbing;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!absorbing()) return super.hitTest(result, position: position);
    return size.contains(position);
  }
}

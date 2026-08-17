part of 'toast.dart';

/// How many toasts show an edge from behind the front one while piled.
const _kMaxPeek = 2;

/// How much of each of those shows.
const _kPeek = 7.0;

/// Between two toasts once the pile is opened.
const _kPileGap = 8.0;

/// How much smaller each toast behind the front one is drawn.
const _kPileScaleStep = 0.035;

/// Displacement overshoots and settles instead of easing to a stop.
///
/// Only displacement: a size factor past 1 is blank space below the content,
/// and an opacity past 1 asserts. Those two keep an ordinary ease.
const _kSpring = Curves.easeOutBack;

/// Where the toasts are drawn.
///
/// Wrap it around the app in `MaterialApp.builder`, so that the stack sits
/// above every route and dialog and still finds a [Theme], a [Directionality]
/// and a [MediaQuery]:
///
/// ```dart
/// MaterialApp(
///   builder: (ctx, child) => ToastHost(child: child),
/// )
/// ```
class ToastHost extends StatefulWidget {
  /// The app.
  final Widget child;

  const ToastHost({super.key, required this.child});

  @override
  State<ToastHost> createState() => _ToastHostState();
}

class _ToastHostState extends State<ToastHost> {
  @override
  void initState() {
    super.initState();
    _ToastCtrl.hosts++;
  }

  @override
  void dispose() {
    _ToastCtrl.hosts--;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      // The host only wraps the app; it must not change how the app is
      // measured, so the incoming constraints go through untouched.
      fit: StackFit.passthrough,
      children: [
        // The pile changing size marks this stack for paint, and without a
        // boundary here that walks the whole app looking for layers to reuse.
        RepaintBoundary(child: widget.child),
        const _ToastLayer(),
      ],
    );
  }
}

class _ToastLayer extends StatefulWidget {
  const _ToastLayer();

  @override
  State<_ToastLayer> createState() => _ToastLayerState();
}

class _ToastLayerState extends State<_ToastLayer> with SingleTickerProviderStateMixin {
  late final AnimationController _openCtrl;
  late final CurvedAnimation _openCurve;

  /// Whether the user has opened the pile. Only meaningful with more than one
  /// toast; with one there is nothing to open and the two layouts coincide.
  var _opened = false;

  @override
  void initState() {
    super.initState();
    _openCtrl = AnimationController(vsync: this, duration: Durations.medium4);
    _openCurve = CurvedAnimation(
      parent: _openCtrl,
      curve: _kSpring,
      reverseCurve: _kSpring.flipped,
    );
  }

  @override
  void dispose() {
    _openCurve.dispose();
    _openCtrl.dispose();
    super.dispose();
  }

  void _togglePile() {
    setState(() => _opened = !_opened);
    if (_opened) {
      _openCtrl.forward();
    } else {
      _openCtrl.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValBuilder(listenable: _ToastCtrl.entries, builder: _build);
  }

  Widget _build(List<_ToastEntry> entries) {
    if (entries.isEmpty) {
      _resetWhenEmptied();
      return UIs.placeholder;
    }

    final align = ToastConfig.align;
    final margin = ToastConfig.margin;
    final dir = Directionality.of(context);
    final ltr = dir == TextDirection.ltr;
    final mediaQuery = MediaQuery.of(context);
    final safe = mediaQuery.padding;

    // Nothing rather than a negative box: the margins and the safe area are
    // fixed, so a window narrow enough — a phone in a split view, a desktop
    // window mid-drag — takes what is left below zero, and `SizedBox` asserts
    // on that before anything gets a chance to look wrong.
    final available = mediaQuery.size.width - margin.horizontal - safe.horizontal;
    if (available <= 0) return UIs.placeholder;
    final width = math.min(ToastConfig.maxWidth, available);

    // On Windows and Linux the virtual window frame draws the minimize and
    // close buttons across the top; a toast in that band would sit on them.
    final caption = WindowFrameConfig.showCaption ? CustomAppBar.sysStatusBarHeight : 0.0;
    final top = align.isTop ? safe.top + caption + margin.top : null;
    final bottom = align.isTop ? null : safe.bottom + margin.bottom;

    // No `AnimatedBuilder` around the pile: opening it used to rebuild every
    // toast's whole subtree on every frame of the 400ms. The animation is handed
    // down instead, and the two places that read it — this layout, and the
    // scale each toast is drawn at — listen to it on their own.
    final pile = RepaintBoundary(
      child: SizedBox(width: width, child: _buildPile(entries, width, align)),
    );

    // Pinned to neither side edge: stretched across instead, and centred
    // within that. `Align` shrink-wraps the height, which is unbounded here
    // because only one of top and bottom is given.
    if (align.isCenter) {
      return Positioned(
        top: top,
        bottom: bottom,
        left: 0,
        right: 0,
        child: Align(alignment: Alignment.topCenter, child: pile),
      );
    }

    return Positioned.directional(
      textDirection: dir,
      top: top,
      bottom: bottom,
      start: align.isEnd ? null : (ltr ? safe.left + margin.left : safe.right + margin.right),
      end: align.isEnd ? (ltr ? safe.right + margin.right : safe.left + margin.left) : null,
      child: pile,
    );
  }

  Widget _buildPile(List<_ToastEntry> entries, double width, ToastAlign align) {
    final piled = entries.length > 1;

    // Counted over the toasts still holding a place. One on its way out is
    // still in the list, and still on screen giving up its height, but the ones
    // behind it are already moving up into where it was.
    var depth = 0;

    return _ToastPile(
      open: _openCurve,
      fromTop: align.isTop,
      children: [
        for (var i = 0; i < entries.length; i++)
          _ToastItem(
            key: ValueKey(entries[i].id),
            entry: entries[i],
            width: width,
            depth: entries[i].dismissing.value ? depth : depth++,
            open: _openCurve,
            piled: piled,
            // A body is reachable when there is nothing else the tap could
            // mean: one toast on screen, or a pile the user has already opened.
            bodyAllowed: !piled || _opened,
            // Reading a pile is why it was opened; nothing in it should expire
            // in the middle of that.
            paused: piled && _opened,
            onPileToggle: piled ? _togglePile : null,
          ),
      ],
    );
  }

  /// Back to a pile, ready for the next batch.
  ///
  /// Deferred a frame: this runs from a build, and the controller has listeners
  /// that would be told to rebuild during it.
  void _resetWhenEmptied() {
    if (!_opened) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _ToastCtrl.entries.value.isNotEmpty) return;
      setState(() => _opened = false);
      _openCtrl.value = 0;
    });
  }
}

/// Lays the toasts out as a pile that opens into a list.
///
/// A custom layout rather than a [Stack] that gives way to a [Column]: the two
/// arrangements have to be interpolated frame by frame, and where the third
/// toast of the opened list goes is the sum of the heights of the two before
/// it — which nothing but the layout knows.
class _ToastPile extends MultiChildRenderObjectWidget {
  /// 0 piled, 1 opened. Overshoots both while the spring settles.
  ///
  /// The animation rather than its value: the render object subscribes and
  /// relayouts itself, so a frame of the opening costs no widget rebuild.
  final Animation<double> open;

  /// Whether the stack hangs from the top edge, in which case the front toast
  /// is the topmost one.
  final bool fromTop;

  const _ToastPile({
    required super.children,
    required this.open,
    required this.fromTop,
  });

  @override
  _RenderToastPile createRenderObject(BuildContext context) {
    return _RenderToastPile(open: open, fromTop: fromTop);
  }

  @override
  void updateRenderObject(BuildContext context, _RenderToastPile renderObject) {
    renderObject
      ..open = open
      ..fromTop = fromTop;
  }
}

/// Tells the pile how deep a toast sits, as a continuous value.
///
/// Continuous because the depths change while the pile is on screen: a toast
/// leaving stops holding its place at once, and the ones behind it have to move
/// up to where it was rather than snapping a place forward. [_ToastItem]
/// animates the integer the layer gives it and reports the value in between.
class _PileSlot extends ParentDataWidget<_PileParentData> {
  final double depth;

  const _PileSlot({required this.depth, required super.child});

  @override
  void applyParentData(RenderObject renderObject) {
    final parentData = renderObject.parentData! as _PileParentData;
    if (parentData.depth == depth) return;
    parentData.depth = depth;
    renderObject.parent?.markNeedsLayout();
  }

  @override
  Type get debugTypicalAncestorWidgetClass => _ToastPile;
}

class _PileParentData extends ContainerBoxParentData<RenderBox> {
  double depth = 0;
}

class _RenderToastPile extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _PileParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _PileParentData> {
  _RenderToastPile({required Animation<double> open, required bool fromTop})
      : _open = open,
        _fromTop = fromTop;

  Animation<double> _open;
  set open(Animation<double> value) {
    if (_open == value) return;
    if (attached) _open.removeListener(markNeedsLayout);
    _open = value;
    if (attached) _open.addListener(markNeedsLayout);
    markNeedsLayout();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _open.addListener(markNeedsLayout);
  }

  @override
  void detach() {
    _open.removeListener(markNeedsLayout);
    super.detach();
  }

  bool _fromTop;
  set fromTop(bool value) {
    if (_fromTop == value) return;
    _fromTop = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderObject child) {
    if (child.parentData is! _PileParentData) child.parentData = _PileParentData();
  }

  @override
  void performLayout() {
    final width = constraints.maxWidth;
    if (childCount == 0) {
      size = Size(width, 0);
      return;
    }

    final childConstraints = BoxConstraints.tightFor(width: width);
    final heights = <double>[];
    final depths = <double>[];
    var child = firstChild;
    while (child != null) {
      child.layout(childConstraints, parentUsesSize: true);
      heights.add(child.size.height);
      depths.add((child.parentData! as _PileParentData).depth);
      child = childAfter(child);
    }

    // Opened: after everything in front of it, one gap per toast still holding a
    // place. Piled: behind the one in front, only an edge showing, and past the
    // peek limit tucked right behind the last edge that does.
    //
    // Both read the depth rather than the index, so a toast on its way out
    // stops taking up a place before it stops taking up height — the heights it
    // contributes to the sum below is already shrinking towards nothing.
    final open = _open.value;
    final offsets = <double>[];
    var height = 0.0;
    var stacked = 0.0;
    for (var i = 0; i < heights.length; i++) {
      final opened = stacked + depths[i] * _kPileGap;
      final piled = math.min(depths[i], _kMaxPeek) * _kPeek;
      final offset = _lerp(piled, opened, open);
      offsets.add(offset);
      stacked += heights[i];
      height = math.max(height, offset + heights[i]);
    }
    size = Size(width, math.max(0, height));

    var i = 0;
    child = firstChild;
    while (child != null) {
      final parentData = child.parentData! as _PileParentData;
      // Measured from the edge the stack hangs from, whichever that is.
      parentData.offset = Offset(0, _fromTop ? offsets[i] : height - offsets[i] - heights[i]);
      i++;
      child = childAfter(child);
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    // Back to front: the newest toast is the first child and has to be drawn
    // last to sit above the rest of the pile.
    var child = lastChild;
    while (child != null) {
      final parentData = child.parentData! as _PileParentData;
      context.paintChild(child, offset + parentData.offset);
      child = childBefore(child);
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    // Front to back, the order they are drawn in reversed.
    var child = firstChild;
    while (child != null) {
      final target = child;
      final parentData = target.parentData! as _PileParentData;
      final hit = result.addWithPaintOffset(
        offset: parentData.offset,
        position: position,
        hitTest: (result, position) => target.hitTest(result, position: position),
      );
      if (hit) return true;
      child = childAfter(target);
    }
    return false;
  }
}

double _lerp(double a, double b, double t) => a + (b - a) * t;

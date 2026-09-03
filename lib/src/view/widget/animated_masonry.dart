import 'dart:math' as math;

import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

/// The masonry [MasonryList] draws, with cards that move instead of jumping.
///
/// Three things happen to a grid of cards and all three used to happen between
/// one frame and the next: a card is added, a card is taken away, and a card
/// ends up somewhere else — because the list was reordered, because a filter
/// changed, or because one card changed height and everything below it in that
/// column reflowed. The last is the commonest and the least explicable: a card
/// that grows when its server connects moves cards it has nothing to do with,
/// in a column it is not even in.
///
/// So: a card that arrives grows into its space and fades in, a card that
/// leaves shrinks out of it, and a card whose place changes is carried there.
/// Growing and shrinking rather than only fading is what lets the *rest* of the
/// grid flow smoothly around the change instead of closing the gap in one step.
///
/// **Every child needs a [Key]**, since that is what says which card is which
/// across a rebuild. Without one this is [MasonryList] with extra steps.
///
/// Not lazy, unlike [MasonryList.builder] — it has to hold every child to know
/// what left. In exchange a card is free to be its own `Consumer`: with a
/// builder, watching per card registers on whatever *called* the builder, so
/// one card's rebuild is the whole grid's anyway.
final class AnimatedMasonry extends StatefulWidget {
  const AnimatedMasonry({
    super.key,
    required this.children,
    this.columnWidth = UIs.columnWidth,
    this.maxColumns = 10,
    this.padding = MasonryList.kPadding,
    this.spacing = MasonryList.kSpacing,
    this.controller,
    this.moveDuration = Durations.medium2,
    this.changeDuration = Durations.medium2,
  });

  /// One per card. Each must carry a [Key] — see the class doc.
  final List<Widget> children;

  /// {@macro masonry_column_width}
  final double columnWidth;

  /// {@macro masonry_max_columns}
  final int maxColumns;

  final EdgeInsets padding;

  /// {@macro masonry_spacing}
  final double spacing;

  final ScrollController? controller;

  /// Roughly how long a card takes to reach a new place.
  ///
  /// Roughly, because the motion is an ease toward wherever the card is going
  /// *now* rather than a run from A to B — and where it is going changes under
  /// it constantly, since the commonest cause of a move is another card in the
  /// middle of its own height animation. A run would restart on every frame of
  /// that and so never get anywhere.
  final Duration moveDuration;

  /// How long a card takes to grow in or shrink out.
  final Duration changeDuration;

  @override
  State<AnimatedMasonry> createState() => _AnimatedMasonryState();
}

/// One card, for as long as it is on screen — which outlasts its removal from
/// [AnimatedMasonry.children] by however long it takes to shrink away.
final class _Entry {
  _Entry({required this.key, required this.child, required this.anim});

  final Key key;
  Widget child;
  final AnimationController anim;

  /// Owned here rather than made in a `build`. A [CurvedAnimation] keeps a
  /// listener on what it is driven by and has to be disposed; one per build
  /// is a leak the framework reports by name.
  late final CurvedAnimation curve = CurvedAnimation(
    parent: anim,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  /// Whether this card is on its way out and is only still here to be seen
  /// going.
  bool leaving = false;

  void dispose() {
    curve.dispose();
    anim.dispose();
  }
}

final class _AnimatedMasonryState extends State<AnimatedMasonry>
    with TickerProviderStateMixin {
  /// In the order they are laid out, which includes the ones on their way out
  /// at the place they were last.
  final _entries = <_Entry>[];

  @override
  void initState() {
    super.initState();
    // Already there, rather than every card growing in at once. The first
    // build is the grid arriving, and a card is only *new* against a grid that
    // was already on screen without it.
    _sync(animateEntry: false);
  }

  @override
  void didUpdateWidget(AnimatedMasonry old) {
    super.didUpdateWidget(old);
    _sync(animateEntry: true);
  }

  @override
  void dispose() {
    for (final entry in _entries) {
      entry.dispose();
    }
    _entries.clear();
    super.dispose();
  }

  /// Brings [_entries] in line with what was just built.
  void _sync({required bool animateEntry}) {
    final incoming = <Key, Widget>{};
    for (final child in widget.children) {
      final key = child.key;
      assert(key != null, 'AnimatedMasonry children must carry a Key');
      if (key != null) incoming[key] = child;
    }

    final byKey = {for (final entry in _entries) entry.key: entry};

    // Gone from the build, so on its way out — unless it already was, in which
    // case restarting would make it shrink from full size a second time.
    for (final entry in _entries) {
      if (incoming.containsKey(entry.key) || entry.leaving) continue;
      entry.leaving = true;
      entry.anim.reverse().whenComplete(() => _drop(entry));
    }

    // Back before it finished leaving. The card never went away, so it turns
    // around from wherever it had shrunk to rather than starting over.
    final ordered = <_Entry>[];
    for (final MapEntry(key: key, value: child) in incoming.entries) {
      final existing = byKey[key];
      if (existing == null) {
        final entry = _Entry(
          key: key,
          child: child,
          anim: AnimationController(
            vsync: this,
            duration: widget.changeDuration,
            value: animateEntry ? 0 : 1,
          ),
        );
        if (animateEntry) entry.anim.forward();
        ordered.add(entry);
        continue;
      }
      existing.child = child;
      if (existing.leaving) {
        existing.leaving = false;
        existing.anim.forward();
      }
      ordered.add(existing);
    }

    // The ones still shrinking, put back roughly where they were. Roughly is
    // enough: whatever the layout makes of it, the move is animated.
    for (var i = 0; i < _entries.length; i++) {
      final entry = _entries[i];
      if (!entry.leaving) continue;
      ordered.insert(math.min(i, ordered.length), entry);
    }

    _entries
      ..clear()
      ..addAll(ordered);
  }

  void _drop(_Entry entry) {
    // Already gone with the state, and disposed with it.
    if (!mounted) return;
    // It came back before the shrink finished, so this callback is stale and
    // the card is on screen for a reason again.
    if (!entry.leaving) return;
    _entries.remove(entry);
    setState(entry.dispose);
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      controller: widget.controller,
      padding: widget.padding,
      // Scrollable even when what is in it fits. Anything floating over this
      // — a bar at the top, a button at the bottom — can be dragged out from
      // under, and pull-to-refresh needs somewhere to pull from; a page of one
      // card had neither, and read as frozen rather than as short.
      physics: const AlwaysScrollableScrollPhysics(),
      child: _MasonryFlow(
        columnWidth: widget.columnWidth,
        maxColumns: widget.maxColumns,
        spacing: widget.spacing,
        moveDuration: widget.moveDuration,
        vsync: this,
        children: [
          for (final entry in _entries)
            _MasonryEntry(
              // Derived from the card's key rather than being it. The wrapper
              // needs one — it is what keeps a card's element, and so its
              // slide and its scroll position, with the card when the order
              // changes — but two widgets in one branch under the same key
              // make `find.byKey` ambiguous and read as a mistake.
              key: ValueKey(entry.key),
              anim: entry.curve,
              child: entry.child,
            ),
        ],
      ),
    );
  }
}

/// A card growing into its place or shrinking out of it.
final class _MasonryEntry extends StatelessWidget {
  const _MasonryEntry({
    super.key,
    required this.anim,
    required this.child,
  });

  final Animation<double> anim;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // The height as well as the opacity, and the height is the important one:
    // it is what makes the cards below flow into the space rather than close
    // it in a single frame. Aligned to the top so a card grows downward from
    // where the grid put it.
    return SizeTransition(
      alignment: Alignment.topCenter,
      sizeFactor: anim,
      child: FadeTransition(
        opacity: anim,
        // Just enough to read as arriving. A card is a big object; scaling one
        // up from nothing would be the only thing on screen while it happened.
        child: ScaleTransition(
          scale: Tween(begin: 0.94, end: 1.0).animate(anim),
          child: child,
        ),
      ),
    );
  }
}

/// Lays cards out in columns and carries each one to where it belongs.
final class _MasonryFlow extends MultiChildRenderObjectWidget {
  const _MasonryFlow({
    required super.children,
    required this.columnWidth,
    required this.maxColumns,
    required this.spacing,
    required this.moveDuration,
    required this.vsync,
  });

  final double columnWidth;
  final int maxColumns;
  final double spacing;
  final Duration moveDuration;
  final TickerProvider vsync;

  @override
  _RenderMasonryFlow createRenderObject(BuildContext context) {
    return _RenderMasonryFlow(
      columnWidth: columnWidth,
      maxColumns: maxColumns,
      spacing: spacing,
      moveDuration: moveDuration,
      vsync: vsync,
    );
  }

  @override
  void updateRenderObject(BuildContext context, _RenderMasonryFlow ro) {
    ro
      ..columnWidth = columnWidth
      ..maxColumns = maxColumns
      ..spacing = spacing
      ..moveDuration = moveDuration
      ..vsync = vsync;
  }
}

final class _MasonryParentData extends ContainerBoxParentData<RenderBox> {
  /// Where the last layout said this card belongs.
  Offset target = Offset.zero;

  /// Where it is being drawn, easing toward [target]. Null until it has been
  /// laid out once, which is how a card that has just appeared is told apart
  /// from one that moved — the first is drawn where it lands, no travel.
  Offset? current;
}

final class _RenderMasonryFlow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _MasonryParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _MasonryParentData> {
  _RenderMasonryFlow({
    required double columnWidth,
    required int maxColumns,
    required double spacing,
    required Duration moveDuration,
    required TickerProvider vsync,
  }) : _columnWidth = columnWidth,
       _maxColumns = maxColumns,
       _spacing = spacing,
       _moveDuration = moveDuration,
       _vsync = vsync;

  /// Within half a pixel of home is home. Without a floor the ease never
  /// arrives, and a ticker that never stops is a grid that repaints forever.
  static const _kEpsilon = 0.5;

  double _columnWidth;
  set columnWidth(double v) {
    if (_columnWidth == v) return;
    _columnWidth = v;
    markNeedsLayout();
  }

  int _maxColumns;
  set maxColumns(int v) {
    if (_maxColumns == v) return;
    _maxColumns = v;
    markNeedsLayout();
  }

  double _spacing;
  set spacing(double v) {
    if (_spacing == v) return;
    _spacing = v;
    markNeedsLayout();
  }

  Duration _moveDuration;
  set moveDuration(Duration v) => _moveDuration = v;

  TickerProvider _vsync;
  set vsync(TickerProvider v) {
    if (identical(_vsync, v)) return;
    _vsync = v;
    // The old provider is going away with the state that vended it, and a
    // ticker outliving one is a ticker nothing can stop.
    _ticker?.dispose();
    _ticker = null;
  }

  Ticker? _ticker;
  Duration _lastTick = Duration.zero;

  @override
  void setupParentData(RenderObject child) {
    if (child.parentData is! _MasonryParentData) {
      child.parentData = _MasonryParentData();
    }
  }

  @override
  void detach() {
    _ticker?.stop();
    super.detach();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _startTickingIfNeeded();
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _ticker = null;
    super.dispose();
  }

  int _columnsFor(double width) {
    if (width <= 0) return 1;
    return ((width + _spacing) / (_columnWidth + _spacing)).floor().clamp(
      1,
      _maxColumns,
    );
  }

  /// The column with the least in it, and the leftmost of those — so a row of
  /// equal cards fills left to right, which is the order they were given in.
  int _shortest(List<double> heights) {
    var best = 0;
    for (var i = 1; i < heights.length; i++) {
      if (heights[i] < heights[best] - _kEpsilon) best = i;
    }
    return best;
  }

  @override
  double computeMinIntrinsicWidth(double height) => _columnWidth;

  @override
  double computeMaxIntrinsicWidth(double height) => _columnWidth * _maxColumns;

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final width = constraints.maxWidth;
    final columns = _columnsFor(width);
    final colWidth = (width - _spacing * (columns - 1)) / columns;
    final heights = List.filled(columns, 0.0);

    var child = firstChild;
    while (child != null) {
      final size = child.getDryLayout(
        BoxConstraints.tightFor(width: colWidth),
      );
      final col = _shortest(heights);
      heights[col] += _slotHeight(size.height);
      child = (child.parentData! as _MasonryParentData).nextSibling;
    }

    return Size(width, _contentHeight(heights));
  }

  /// What a card of [height] costs its column, gap included.
  ///
  /// A card shrunk to nothing costs nothing, not a gap. Otherwise the last of
  /// a removal — the moment the card is finally dropped — is a step of
  /// [_spacing] that the shrink was supposed to have absorbed, and a grid full
  /// of cards being filtered out closes in stairs.
  double _slotHeight(double height) => height <= 0 ? 0 : height + _spacing;

  double _contentHeight(List<double> heights) {
    final tallest = heights.reduce(math.max);
    // Every column carries a trailing gap from the card above; the last one
    // has nothing under it to be a gap from.
    return math.max(0, tallest - _spacing);
  }

  @override
  void performLayout() {
    final width = constraints.maxWidth;
    final columns = _columnsFor(width);
    final colWidth = (width - _spacing * (columns - 1)) / columns;
    final heights = List.filled(columns, 0.0);

    // How far down anything is actually *drawn* right now, which is not the
    // same as how far down the cards are going. A card on its way up out of a
    // grid that has just got shorter is below the bottom of where the grid is
    // headed for as long as the trip takes.
    //
    // The box has to cover it. Not for painting — a viewport clips that — but
    // because every box between the finger and the card refuses a position
    // outside itself, starting with this one and then the scrollable's own
    // content box. A card can otherwise be under the finger, plainly on
    // screen, and not tappable.
    var drawnBottom = 0.0;

    var child = firstChild;
    while (child != null) {
      final pd = child.parentData! as _MasonryParentData;
      child.layout(
        BoxConstraints.tightFor(width: colWidth),
        parentUsesSize: true,
      );

      final col = _shortest(heights);
      pd.target = Offset(col * (colWidth + _spacing), heights[col]);
      // Never travelled, so it has nowhere to travel from: a card that has
      // just been added is drawn where it lands and grows there.
      pd.current ??= pd.target;
      pd.offset = pd.current!;
      // A card shrunk to nothing draws nothing, wherever it is sitting.
      if (child.size.height > 0) {
        drawnBottom = math.max(drawnBottom, pd.offset.dy + child.size.height);
      }

      heights[col] += _slotHeight(child.size.height);
      child = pd.nextSibling;
    }

    size = constraints.constrain(
      Size(width, math.max(_contentHeight(heights), drawnBottom)),
    );
    _startTickingIfNeeded();
  }

  bool get _settled {
    var child = firstChild;
    while (child != null) {
      final pd = child.parentData! as _MasonryParentData;
      if ((pd.target - pd.current!).distance > _kEpsilon) return false;
      child = pd.nextSibling;
    }
    return true;
  }

  /// Starts the ease, if anything is out of place.
  ///
  /// Called from layout, so the first tick is the *next* frame — a card is one
  /// frame late leaving its old place. That is the shape of the thing: where a
  /// card belongs is not known until it has been laid out, and by then this
  /// frame is spoken for.
  void _startTickingIfNeeded() {
    if (!attached || _settled) return;
    final ticker = _ticker ??= _vsync.createTicker(_tick);
    if (ticker.isActive) return;
    _lastTick = Duration.zero;
    ticker.start();
  }

  /// Eases every card toward where it belongs, framerate-independently.
  ///
  /// An exponential ease rather than a tween with a start and an end, because
  /// the target moves: the commonest reason a card is out of place is that a
  /// card above it is animating its own height, so the destination changes on
  /// every frame. A tween would restart on each of them and crawl. This just
  /// closes a fixed fraction of whatever gap is left, which is the same motion
  /// whether the target is still or sliding.
  void _tick(Duration elapsed) {
    final dtMicros = (elapsed - _lastTick).inMicroseconds;
    _lastTick = elapsed;
    // The first tick has no previous one to measure from.
    if (dtMicros <= 0) return;

    // Three time constants is ~95% of the way, which is what reads as "it took
    // [moveDuration]".
    final tau = _moveDuration.inMicroseconds / 3;
    final factor = tau <= 0 ? 1.0 : 1 - math.exp(-dtMicros / tau);

    var moving = false;
    var child = firstChild;
    while (child != null) {
      final pd = child.parentData! as _MasonryParentData;
      final current = pd.current!;
      final delta = pd.target - current;
      if (delta.distance <= _kEpsilon) {
        pd.current = pd.target;
      } else {
        pd.current = current + delta * factor;
        moving = true;
      }
      pd.offset = pd.current!;
      child = pd.nextSibling;
    }

    if (!moving) _ticker?.stop();
    // Layout, not paint. Where the cards are drawn is part of how tall this
    // is — see [performLayout] — so a frame that moves them is a frame that
    // resizes it, and a grid that shrank while a card was still on its way up
    // has to give that height back as the card arrives.
    markNeedsLayout();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    defaultPaint(context, offset);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    // [pd.offset] is kept equal to where the card is drawn, so the default —
    // which is what taps go through — follows it without knowing about any of
    // this.
    return defaultHitTestChildren(result, position: position);
  }
}

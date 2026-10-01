import 'dart:math' as math;

import 'package:fl_lib/fl_lib.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

/// How tall each card of an [AnimatedMasonry] was the last time it was laid
/// out in its column, kept by whoever owns the grid.
///
/// An expanded card takes no column space, so its column is told it still
/// costs what it did before — and "before" was the first layout the card was
/// expanded in. That is right for a grid that was on screen when the card
/// started growing. A grid mounted with a card already expanded has no such
/// layout: what it measured was the card at its expanded height, so every card
/// after it in that column was placed that much too low for the whole way
/// back, and travelled home only once the card had landed. A list in one
/// column is that case every time.
///
/// Held outside the grid because the grid is what goes away. Without one the
/// first expanded layout is used, as before.
final class MasonryMemory {
  final _heights = <Key, double>{};

  /// For a caller whose cards have changed shape entirely, so that what was
  /// learned about the old one is not used for the new.
  void clear() => _heights.clear();
}

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
    this.header,
    this.footer,
    this.expandedKey,
    this.expansion = 0,
    this.expandedInset = EdgeInsets.zero,
    this.memory,
    this.scrollable = true,
  });

  /// What this grid learned about its cards that has to outlive it.
  ///
  /// Needed by a caller that takes the grid off screen while a card is
  /// expanded and mounts it again for the way back — see [MasonryMemory].
  final MasonryMemory? memory;

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

  /// Above the grid, inside the same scrollable.
  ///
  /// A row of controls over a grid is usually a bar, which is pinned; this is
  /// for the ones that belong *to* the grid and should leave with it.
  final Widget? header;

  /// Under the grid, inside the same scrollable.
  final Widget? footer;

  /// {@template masonry_expansion}
  /// The card that is growing out of the grid into the page, and how far along
  /// it is: 0 leaves it in its column, 1 gives it the full width.
  ///
  /// Only the width is this; where the card goes is the ordinary layout, since
  /// a caller that expands one card takes the others out of [children] and the
  /// grid carries what is left to the top by itself. That is also what fades
  /// the others out — they are leaving, which is a thing this already draws.
  /// {@endtemplate}
  final Key? expandedKey;

  /// {@macro masonry_expansion}
  final double expansion;

  /// What the expanded card leaves clear of the grid's box once it has grown.
  ///
  /// For a caller that puts something beside the page the card becomes — a
  /// column sliding in over the grid's left edge — so the card lands where the
  /// page will be rather than under it. Applied in step with [expansion].
  final EdgeInsets expandedInset;

  /// Whether this brings its own scrolling.
  ///
  /// Off for a grid that is one section of a longer page — several of these
  /// under one scroll view, with a heading above each. Then [padding] is the
  /// section's own inset and the page supplies the rest, and [controller] and
  /// [header] belong to whatever is doing the scrolling instead.
  final bool scrollable;

  @override
  State<AnimatedMasonry> createState() => _AnimatedMasonryState();
}

final class _AnimatedMasonryState extends State<AnimatedMasonry>
    with TickerProviderStateMixin {
  /// The cards on screen, which includes the ones on their way out at the
  /// place they were last — see [AnimatedChildren], which is the same
  /// bookkeeping [AnimatedColumn] does.
  late final _children = AnimatedChildren(
    vsync: this,
    duration: widget.changeDuration,
    onChanged: () {
      if (mounted) setState(() {});
    },
  );

  @override
  void initState() {
    super.initState();
    // Already there, rather than every card growing in at once. The first
    // build is the grid arriving, and a card is only *new* against a grid that
    // was already on screen without it.
    _children.sync(widget.children, animateEntry: false);
  }

  @override
  void didUpdateWidget(AnimatedMasonry old) {
    super.didUpdateWidget(old);
    _children.sync(widget.children, animateEntry: true);
  }

  @override
  void dispose() {
    _children.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entries = _children.entries;
    final grid = _MasonryFlow(
      columnWidth: widget.columnWidth,
      maxColumns: widget.maxColumns,
      spacing: widget.spacing,
      // Zero lands every card in its place on the next frame.
      moveDuration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : widget.moveDuration,
      vsync: this,
      expandedAt: widget.expandedKey == null
          ? -1
          : entries.indexWhere((e) => e.key == widget.expandedKey),
      expansion: widget.expansion,
      expandedInset: widget.expandedInset,
      memory: widget.memory,
      keys: [for (final entry in entries) entry.key],
      children: [
        for (final entry in entries)
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
    );

    final body = widget.header == null && widget.footer == null
        ? grid
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [?widget.header, grid, ?widget.footer],
          );

    if (!widget.scrollable) {
      return Padding(padding: widget.padding, child: body);
    }

    return SingleChildScrollView(
      controller: widget.controller,
      padding: widget.padding,
      // Scrollable even when what is in it fits. Anything floating over this
      // — a bar at the top, a button at the bottom — can be dragged out from
      // under, and pull-to-refresh needs somewhere to pull from; a page of one
      // card had neither, and read as frozen rather than as short.
      physics: const AlwaysScrollableScrollPhysics(),
      child: body,
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
    // Under reduced motion only the fade is kept: the space opens and closes
    // at once, and nothing grows.
    if (MediaQuery.disableAnimationsOf(context)) {
      return FadeTransition(opacity: anim, child: child);
    }
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
          // The width of the slot it was given, not of whatever is in it:
          // [SizeTransition] is an `Align`, which loosens what it passes down,
          // so a card would otherwise shrink-wrap — and a card that grows out
          // of the grid would stop at the width of its old column.
          child: SizedBox(width: double.infinity, child: child),
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
    required this.expandedAt,
    required this.expansion,
    required this.expandedInset,
    required this.memory,
    required this.keys,
  });

  final double columnWidth;
  final int maxColumns;
  final double spacing;
  final Duration moveDuration;
  final TickerProvider vsync;
  final int expandedAt;
  final double expansion;
  final EdgeInsets expandedInset;
  final MasonryMemory? memory;

  /// Each child's own key, in order: what [memory] knows a card by.
  final List<Key> keys;

  @override
  _RenderMasonryFlow createRenderObject(BuildContext context) {
    return _RenderMasonryFlow(
      columnWidth: columnWidth,
      maxColumns: maxColumns,
      spacing: spacing,
      moveDuration: moveDuration,
      vsync: vsync,
      expandedAt: expandedAt,
      expansion: expansion,
      expandedInset: expandedInset,
      memory: memory,
      keys: keys,
    );
  }

  @override
  void updateRenderObject(BuildContext context, _RenderMasonryFlow ro) {
    ro
      ..columnWidth = columnWidth
      ..maxColumns = maxColumns
      ..spacing = spacing
      ..moveDuration = moveDuration
      ..vsync = vsync
      ..expandedAt = expandedAt
      ..expansion = expansion
      ..expandedInset = expandedInset
      ..memory = memory
      ..keys = keys;
  }
}

final class _MasonryParentData extends ContainerBoxParentData<RenderBox> {
  /// Where the last layout said this card belongs.
  Offset target = Offset.zero;

  /// Where it is being drawn, easing toward [target]. Null until it has been
  /// laid out once, which is how a card that has just appeared is told apart
  /// from one that moved — the first is drawn where it lands, no travel.
  Offset? current;

  /// Where the card was when it started growing out of the grid.
  ///
  /// Taken once and held, because the slot it would otherwise be measured
  /// from moves under it: the cards making way shrink to nothing partway
  /// through, and the column the growing one belongs to collapses to the
  /// first. Measured fresh every layout, the card slid smoothly most of the
  /// way and then jumped the rest.
  Offset? expandFrom;

  /// How tall it was then, which is what its column goes on being told it
  /// costs.
  ///
  /// A card growing out of the grid is as wide as every column and belongs to
  /// none of them, so its own column would otherwise close up — and every
  /// card after it would shuffle forward, and back again when it returned,
  /// for a movement that is not about them.
  double? expandHeight;
}

final class _RenderMasonryFlow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _MasonryParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _MasonryParentData> {
  _RenderMasonryFlow({
    required this._columnWidth,
    required this._maxColumns,
    required this._spacing,
    required this._moveDuration,
    required this._vsync,
    required this._expandedAt,
    required this._expansion,
    required this._expandedInset,
    required this.memory,
    required this.keys,
  });

  /// Read and written during layout, so neither needs a layout of its own: a
  /// change of cards is a change of children, which is one already.
  MasonryMemory? memory;
  List<Key> keys;

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

  int _expandedAt;
  set expandedAt(int v) {
    if (_expandedAt == v) return;
    _expandedAt = v;
    markNeedsLayout();
  }

  double _expansion;
  set expansion(double v) {
    if (_expansion == v) return;
    _expansion = v;
    markNeedsLayout();
  }

  EdgeInsets _expandedInset;
  set expandedInset(EdgeInsets v) {
    if (_expandedInset == v) return;
    _expandedInset = v;
    markNeedsLayout();
  }

  /// Whether the card at [at] is the one growing out of the grid.
  ///
  /// Only once it has started: at rest the expanded card is an ordinary card
  /// in an ordinary column, which is what makes the first frame of the growth
  /// continuous with the grid it leaves.
  bool _isExpanded(int at) => at == _expandedAt && _expansion > 0;

  /// What the card at [at] cost its column the last time it was in one.
  double? _remembered(int at) =>
      at < keys.length ? memory?._heights[keys[at]] : null;

  void _remember(int at, double height) {
    if (at < keys.length) memory?._heights[keys[at]] = height;
  }

  /// How wide the card at [at] is laid out, which is a column's width for
  /// every card but the one growing out of the grid.
  double _widthOf(int at, double colWidth, double full) {
    if (at != _expandedAt || _expansion <= 0) return colWidth;
    final to = math.max(colWidth, full - _expandedInset.horizontal);
    return colWidth + (to - colWidth) * _expansion;
  }

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
    var at = 0;
    var expandedHeight = 0.0;
    while (child != null) {
      final size = child.getDryLayout(
        BoxConstraints.tightFor(width: _widthOf(at, colWidth, width)),
      );
      if (_isExpanded(at)) {
        expandedHeight = size.height;
      } else {
        final col = _shortest(heights);
        heights[col] += _slotHeight(size.height);
      }
      child = (child.parentData! as _MasonryParentData).nextSibling;
      at++;
    }

    return Size(width, math.max(_contentHeight(heights), expandedHeight));
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
    var at = 0;
    while (child != null) {
      final pd = child.parentData! as _MasonryParentData;
      child.layout(
        BoxConstraints.tightFor(width: _widthOf(at, colWidth, width)),
        parentUsesSize: true,
      );

      final col = _shortest(heights);
      final slot = Offset(col * (colWidth + _spacing), heights[col]);
      if (!_isExpanded(at)) {
        pd.expandFrom = null;
        pd.expandHeight = null;
      }
      if (_isExpanded(at)) {
        // Between its column and the top of the grid, on [expansion] itself
        // rather than on the ease every other card travels by. The two are
        // different curves, and a card whose width was on one and whose
        // position was on the other arrived at the top well after it had
        // taken the width — which reads as two movements, and puts everything
        // else driven by [expansion] visibly ahead of the card.
        //
        // It takes no column space either: it is as wide as all of them.
        pd.expandFrom ??= pd.current ?? slot;
        // What it cost its column the last time it was in one, where that is
        // known — see [MasonryMemory]. This layout's own height is the card
        // already expanded whenever the grid was mounted that way.
        pd.expandHeight ??= _remembered(at) ?? child.size.height;
        pd.target = Offset.lerp(
          pd.expandFrom!,
          _expandedInset.topLeft,
          _expansion,
        )!;
        pd.current = pd.target;
        // Its column is told it is still the size it was, so the cards after
        // it stay where they are.
        heights[col] += _slotHeight(pd.expandHeight!);
      } else {
        pd.target = slot;
        heights[col] += _slotHeight(child.size.height);
        _remember(at, child.size.height);
      }
      // Never travelled, so it has nowhere to travel from: a card that has
      // just been added is drawn where it lands and grows there.
      pd.current ??= pd.target;
      pd.offset = pd.current!;
      // A card shrunk to nothing draws nothing, wherever it is sitting.
      if (child.size.height > 0) {
        drawnBottom = math.max(drawnBottom, pd.offset.dy + child.size.height);
      }

      child = pd.nextSibling;
      at++;
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

  /// The children in the order they are painted: the one growing out of the
  /// grid last, so that it is over the ones making way for it rather than
  /// under whichever of them happens to come after it in the list.
  List<RenderBox> get _painted {
    final all = <RenderBox>[];
    RenderBox? expanded;
    var child = firstChild;
    var at = 0;
    while (child != null) {
      if (_isExpanded(at)) {
        expanded = child;
      } else {
        all.add(child);
      }
      child = (child.parentData! as _MasonryParentData).nextSibling;
      at++;
    }
    if (expanded != null) all.add(expanded);
    return all;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_expandedAt < 0 || _expansion <= 0) {
      defaultPaint(context, offset);
      return;
    }
    for (final child in _painted) {
      final pd = child.parentData! as _MasonryParentData;
      context.paintChild(child, pd.offset + offset);
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    // [pd.offset] is kept equal to where the card is drawn, so the default —
    // which is what taps go through — follows it without knowing about any of
    // this.
    if (_expandedAt < 0 || _expansion <= 0) {
      return defaultHitTestChildren(result, position: position);
    }
    // Topmost first, which is the reverse of the paint order.
    for (final child in _painted.reversed) {
      final pd = child.parentData! as _MasonryParentData;
      final hit = result.addWithPaintOffset(
        offset: pd.offset,
        position: position,
        hitTest: (result, transformed) =>
            child.hitTest(result, position: transformed),
      );
      if (hit) return true;
    }
    return false;
  }
}

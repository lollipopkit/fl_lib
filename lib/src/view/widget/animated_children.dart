import 'dart:math' as math;

import 'package:flutter/material.dart';

/// One child of an animated collection, for as long as it is on screen —
/// which outlasts its removal from the list by however long it takes to
/// shrink away.
final class AnimatedChild {
  AnimatedChild({
    required this.key,
    required this.child,
    required this.anim,
    required Curve curve,
    required Curve reverseCurve,
  }) : curve = CurvedAnimation(
         parent: anim,
         curve: curve,
         reverseCurve: reverseCurve,
       );

  final Key key;
  Widget child;
  final AnimationController anim;

  /// Owned here rather than made in a `build`. A [CurvedAnimation] keeps a
  /// listener on what it is driven by and has to be disposed; one per build
  /// is a leak the framework reports by name.
  final CurvedAnimation curve;

  /// Whether this child is on its way out and is only still here to be seen
  /// going.
  bool leaving = false;

  void dispose() {
    curve.dispose();
    anim.dispose();
  }
}

/// What every animated collection of keyed children has to keep track of.
///
/// Three things happen to such a collection and all three would otherwise
/// happen between one frame and the next: a child is added, a child is taken
/// away, and a child ends up somewhere else. This holds the middle one — a
/// child that has left the build is kept, at roughly the place it was, until
/// its own animation has run out — which is what the other two are drawn
/// against.
///
/// **Every child needs a [Key]**, since that is what says which is which
/// across a rebuild.
final class AnimatedChildren {
  AnimatedChildren({
    required this.vsync,
    required this.duration,
    required this.onChanged,
    this.curve = Curves.easeOutCubic,
    this.reverseCurve = Curves.easeInCubic,
  });

  final TickerProvider vsync;
  final Duration duration;

  /// Called when a child that had left finally goes, which is the one change
  /// to this list that no build asked for.
  final VoidCallback onChanged;

  final Curve curve;
  final Curve reverseCurve;

  final _entries = <AnimatedChild>[];

  /// In the order they are laid out, which includes the ones on their way out
  /// at the place they were last.
  List<AnimatedChild> get entries => _entries;

  /// Brings [entries] in line with what was just built.
  ///
  /// [animateEntry] is false for the first build: that one is the collection
  /// arriving, and a child is only *new* against one that was already on
  /// screen without it.
  void sync(List<Widget> children, {required bool animateEntry}) {
    final incoming = <Key, Widget>{};
    for (final child in children) {
      final key = child.key;
      assert(key != null, 'An animated child must carry a Key');
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

    // Back before it finished leaving. The child never went away, so it turns
    // around from wherever it had shrunk to rather than starting over.
    final ordered = <AnimatedChild>[];
    for (final MapEntry(key: key, value: child) in incoming.entries) {
      final existing = byKey[key];
      if (existing == null) {
        final entry = AnimatedChild(
          key: key,
          child: child,
          anim: AnimationController(
            vsync: vsync,
            duration: duration,
            value: animateEntry ? 0 : 1,
          ),
          curve: curve,
          reverseCurve: reverseCurve,
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
    // enough: whatever the layout makes of it, the change is animated.
    for (var i = 0; i < _entries.length; i++) {
      final entry = _entries[i];
      if (!entry.leaving) continue;
      ordered.insert(math.min(i, ordered.length), entry);
    }

    _entries
      ..clear()
      ..addAll(ordered);
  }

  void _drop(AnimatedChild entry) {
    // It came back before the shrink finished, so this callback is stale and
    // the child is on screen for a reason again.
    if (!entry.leaving) return;
    if (!_entries.remove(entry)) return;
    entry.dispose();
    onChanged();
  }

  void dispose() {
    for (final entry in _entries) {
      entry.dispose();
    }
    _entries.clear();
  }
}

/// A column whose children arrive, leave and reflow rather than jump.
///
/// For a list that is rebuilt from a filter — search results, above all —
/// where what changed between two builds is the one thing a reader cannot see
/// happen. A child that arrives grows into its space and fades in, and one
/// that leaves shrinks out of it, so the rest of the column flows around the
/// change instead of closing the gap in a single frame.
///
/// **Every child needs a [Key]** — see [AnimatedChildren].
///
/// Not lazy: it has to hold every child to know what left. For a long list
/// that is a reason to use something else; for a filtered one it is what makes
/// the filter legible.
final class AnimatedColumn extends StatefulWidget {
  const AnimatedColumn({
    super.key,
    required this.children,
    this.duration = Durations.medium2,
    this.separator,
    this.crossAxisAlignment = CrossAxisAlignment.stretch,
  });

  /// One per row. Each must carry a [Key] — see the class doc.
  final List<Widget> children;

  final Duration duration;

  /// Drawn above every child but the first.
  ///
  /// Part of the child above it rather than a row of its own, so a child that
  /// leaves takes its own line with it — a separator that outlived its row
  /// would be a rule shrinking on its own.
  final Widget? separator;

  final CrossAxisAlignment crossAxisAlignment;

  @override
  State<AnimatedColumn> createState() => _AnimatedColumnState();
}

final class _AnimatedColumnState extends State<AnimatedColumn>
    with TickerProviderStateMixin {
  late final _children = AnimatedChildren(
    vsync: this,
    duration: widget.duration,
    onChanged: () {
      if (mounted) setState(() {});
    },
  );

  @override
  void initState() {
    super.initState();
    _children.sync(widget.children, animateEntry: false);
  }

  @override
  void didUpdateWidget(AnimatedColumn old) {
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: widget.crossAxisAlignment,
      children: [
        for (final (at, entry) in _children.entries.indexed)
          _AnimatedColumnEntry(
            // Derived from the child's key rather than being it: the wrapper
            // needs one, and two widgets in one branch under the same key make
            // `find.byKey` ambiguous and read as a mistake.
            key: ValueKey(entry.key),
            anim: entry.curve,
            // Read from where the child is *now*, which includes the ones on
            // their way out — so the line above a row is there for as long as
            // there is a row above it, and no longer.
            separator: at == 0 ? null : widget.separator,
            child: entry.child,
          ),
      ],
    );
  }
}

final class _AnimatedColumnEntry extends StatelessWidget {
  const _AnimatedColumnEntry({
    super.key,
    required this.anim,
    required this.separator,
    required this.child,
  });

  final Animation<double> anim;
  final Widget? separator;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final faded = FadeTransition(
      opacity: anim,
      child: separator == null
          ? child
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [separator!, child],
            ),
    );
    // Under reduced motion only the fade is kept: the space opens and closes
    // at once, and nothing grows.
    if (MediaQuery.disableAnimationsOf(context)) return faded;
    // The height as well as the opacity, and the height is the important one:
    // it is what makes the rows below flow into the space rather than close it
    // in a single frame. Anchored at the top so a row grows downward from
    // where the column put it.
    return SizeTransition(
      alignment: Alignment.topCenter,
      sizeFactor: anim,
      child: faded,
    );
  }
}

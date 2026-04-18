import 'dart:math' as math;

import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Signature for building each item in [AdaptiveReorderableList].
typedef AdaptiveReorderableItemBuilder<T> =
    Widget Function(
      BuildContext context,
      T item,
      int index,
      Animation<double> animation,
    );

/// Signature fired when the list has finished reordering items.
typedef AdaptiveReorderCompletion<T> = void Function(List<T> items);

/// A responsive multi-column reorderable list with animated insertions & removals.
///
/// The widget determines how many columns to display based on the available width.
/// Items can be long-pressed to drag into a new position and will animate when
/// inserted or removed from the provided [items] collection.
///
/// ## Example
/// ```dart
/// class ReorderableTags extends StatefulWidget {
///   const ReorderableTags({super.key});
///
///   @override
///   State<ReorderableTags> createState() => _ReorderableTagsState();
/// }
///
/// class _ReorderableTagsState extends State<ReorderableTags> {
///   var _tags = <String>['Design', 'Review', 'QA'];
///
///   @override
///   Widget build(BuildContext context) {
///     return AdaptiveReorderableList.builder<String>(
///       items: _tags,
///       itemKey: (tag) => tag,
///       itemBuilder: (context, tag, index, animation) {
///         return SizeTransition(
///           sizeFactor: animation,
///           child: Card(
///             child: ListTile(
///               leading: const Icon(Icons.drag_handle),
///               title: Text(tag),
///             ),
///           ),
///         );
///       },
///       onReorderComplete: (updated) {
///         setState(() => _tags = updated);
///       },
///     );
///   }
/// }
/// ```
class AdaptiveReorderableList<T> extends StatefulWidget {
  /// Creates a builder-based adaptive reorderable list.
  const AdaptiveReorderableList.builder({
    super.key,
    required this.items,
    required this.itemBuilder,
    required this.itemKey,
    this.useMasonry = true,
    this.onReorder,
    this.onReorderComplete,
    this.padding = EdgeInsets.zero,
    this.columnWidth = UIs.columnWidth,
    this.crossAxisSpacing = 16,
    this.mainAxisSpacing = 16,
    this.maxColumns = 6,
    this.animationDuration = const Duration(milliseconds: 220),
    this.dropAnimationDuration = const Duration(milliseconds: 220),
    this.insertCurve = Curves.easeOutCubic,
    this.removeCurve = Curves.easeInCubic,
    this.scrollController,
    this.physics,
    this.primary,
    this.clipBehavior = Clip.hardEdge,
    this.keyboardDismissBehavior = ScrollViewKeyboardDismissBehavior.manual,
    this.restorationId,
    this.reverse = false,
    this.rowMajor = false,
    this.draggingChildOpacity = 0.2,
  }) : assert(
         draggingChildOpacity >= 0 && draggingChildOpacity <= 1,
         'draggingChildOpacity must be between 0.0 and 1.0 inclusive.',
       ),
       separatorBuilder = null,
       separated = false;

  /// Creates a separated adaptive reorderable list where a separator widget is
  /// automatically inserted between children.
  const AdaptiveReorderableList.separated({
    super.key,
    required this.items,
    required this.itemBuilder,
    required this.itemKey,
    required this.separatorBuilder,
    this.useMasonry = true,
    this.onReorder,
    this.onReorderComplete,
    this.padding = EdgeInsets.zero,
    this.columnWidth = UIs.columnWidth,
    this.crossAxisSpacing = 16,
    this.mainAxisSpacing = 16,
    this.maxColumns = 6,
    this.animationDuration = const Duration(milliseconds: 220),
    this.dropAnimationDuration = const Duration(milliseconds: 220),
    this.insertCurve = Curves.easeOutCubic,
    this.removeCurve = Curves.easeInCubic,
    this.scrollController,
    this.physics,
    this.primary,
    this.clipBehavior = Clip.hardEdge,
    this.keyboardDismissBehavior = ScrollViewKeyboardDismissBehavior.manual,
    this.restorationId,
    this.reverse = false,
    this.rowMajor = false,
    this.draggingChildOpacity = 0.2,
  }) : assert(
         draggingChildOpacity >= 0 && draggingChildOpacity <= 1,
         'draggingChildOpacity must be between 0.0 and 1.0 inclusive.',
       ),
       separated = true;

  /// Data backing each item that will be rendered.
  final List<T> items;

  /// Builds the widget at the given [index].
  final AdaptiveReorderableItemBuilder<T> itemBuilder;

  /// Optional separator factory when using [AdaptiveReorderableList.separated].
  final IndexedWidgetBuilder? separatorBuilder;

  /// Extracts a stable key for the provided [item].
  final Object Function(T item) itemKey;

  /// Called when an item is dropped into a new position.
  ///
  /// The callback receives indices relative to the currently visible (non-removed)
  /// items so it can update the backing list accordingly.
  final ReorderCallback? onReorder;

  /// Called after a reorder completes with the latest ordered items.
  ///
  /// The callback receives a snapshot of [items] in their new order after drag
  /// operations have been applied.
  final AdaptiveReorderCompletion<T>? onReorderComplete;

  /// Whether to use a grid layout (waterfall/row-major) instead of Wrap.
  /// If [rowMajor] is false, uses a waterfall Masonry grid (minimal vertical gaps),
  /// which places items by shortest column and may not preserve row reading order.
  /// If [rowMajor] is true, uses an aligned row-major grid that preserves builder order
  /// left-to-right, top-to-bottom while allowing varying heights.
  final bool useMasonry;

  /// Padding applied to the entire list.
  final EdgeInsetsGeometry padding;

  /// Target width for each column before spacing.
  final double columnWidth;

  /// Space between columns in the grid layout.
  final double crossAxisSpacing;

  /// Space between rows in the grid layout.
  final double mainAxisSpacing;

  /// Upper bound on automatically calculated columns.
  final int maxColumns;

  /// Duration for insert/remove animations.
  final Duration animationDuration;

  /// Duration for the drag-settle overlay animation when an item is dropped.
  final Duration dropAnimationDuration;

  /// Curve applied when animating newly inserted items.
  final Curve insertCurve;

  /// Curve applied when animating removed items.
  final Curve removeCurve;

  /// Optional scroll controller.
  final ScrollController? scrollController;

  /// Scroll physics for the list view.
  final ScrollPhysics? physics;

  /// Whether this is the primary scroll view.
  final bool? primary;

  /// Clip behavior for the underlying scrollable.
  final Clip clipBehavior;

  /// Keyboard dismiss behavior for the scrollable.
  final ScrollViewKeyboardDismissBehavior keyboardDismissBehavior;

  /// Restoration id for state restoration.
  final String? restorationId;

  /// Whether the list scrolls in reverse.
  final bool reverse;

  final bool separated;

  /// Selects row-major aligned grid when [useMasonry] is true.
  /// - false (default): Masonry (waterfall) layout
  /// - true: Aligned row-major layout
  final bool rowMajor;

  /// Opacity applied to both the in-list placeholder and the drag feedback while
  /// an item is being dragged.
  ///
  /// Use 1.0 to keep the visuals fully opaque, or any value between 0 and 1 to
  /// fade them out during drag.
  final double draggingChildOpacity;

  @override
  State<AdaptiveReorderableList<T>> createState() =>
      _AdaptiveReorderableListState<T>();
}

class _AdaptiveReorderableListState<T> extends State<AdaptiveReorderableList<T>>
    with TickerProviderStateMixin {
  final List<_AdaptiveEntry<T>> _entries = [];
  final Map<Object, _AdaptiveEntry<T>> _entryByKey = {};
  final Map<Object, _ShiftAnimation> _shiftAnimations = {};
  final ValueNotifier<Object?> _hoveringKey = ValueNotifier<Object?>(null);
  _ActiveDrag? _activeDrag;

  static final Object _trailingDropMarker = Object();

  @override
  void initState() {
    super.initState();
    for (var i = 0; i < widget.items.length; i++) {
      _insertEntry(i, widget.items[i], animateIn: false);
    }
  }

  @override
  void didUpdateWidget(covariant AdaptiveReorderableList<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.items, oldWidget.items)) {
      _syncEntries();
    } else {
      // Still resync on potential list mutations without identity change.
      _syncEntries();
    }
  }

  void _syncEntries() {
    final desired = widget.items;

    final seenKeys = <Object>{};
    for (final entry in _entries) {
      entry.markedForRemoval = true;
    }

    var insertIndex = 0;
    for (final item in desired) {
      final key = widget.itemKey(item);
      assert(
        !seenKeys.contains(key),
        'AdaptiveReorderableList received duplicate keys: $key',
      );
      seenKeys.add(key);
      final existing = _entryByKey[key];
      if (existing != null) {
        existing.item = item;
        existing.markedForRemoval = false;
        existing.removed = false;
        final status = existing.controller.status;
        if (status == AnimationStatus.dismissed ||
            status == AnimationStatus.reverse) {
          existing.controller.forward();
        }
        if (_entries[insertIndex] != existing) {
          _entries.remove(existing);
          _entries.insert(insertIndex, existing);
        }
      } else {
        _insertEntry(insertIndex, item, animateIn: true);
      }
      insertIndex++;
    }

    for (final entry in _entries.toList()) {
      if (entry.markedForRemoval && !entry.removed) {
        entry.removed = true;
        entry.controller.reverse();
      }
    }
  }

  void _insertEntry(int index, T item, {required bool animateIn}) {
    final entry = _createEntry(item, animateIn: animateIn);
    assert(
      !_entryByKey.containsKey(entry.key),
      'AdaptiveReorderableList requires items to produce unique keys. Duplicate: ${entry.key}',
    );
    entry.markedForRemoval = false;
    entry.removed = false;
    _entries.insert(index, entry);
    _entryByKey[entry.key] = entry;
    if (animateIn) {
      entry.controller.forward();
    }
  }

  _AdaptiveEntry<T> _createEntry(T item, {required bool animateIn}) {
    final key = widget.itemKey(item);
    final controller = AnimationController(
      vsync: this,
      duration: widget.animationDuration,
    );
    if (!animateIn) {
      controller.value = 1;
    }

    final animation = CurvedAnimation(
      parent: controller,
      curve: widget.insertCurve,
      reverseCurve: widget.removeCurve,
    );

    late final _AdaptiveEntry<T> entry;
    entry = _AdaptiveEntry<T>(
      key: key,
      item: item,
      controller: controller,
      animation: animation,
      onRemoveCompleted: () {
        if (!mounted) return;
        setState(() {
          _entries.remove(entry);
          _entryByKey.remove(entry.key);
        });
        entry.dispose();
      },
    );

    controller.addStatusListener((status) {
      if (status == AnimationStatus.dismissed && entry.removed) {
        entry.onRemoveCompleted();
      }
    });

    return entry;
  }

  @override
  void dispose() {
    for (final entry in _entries) {
      entry.dispose();
    }
    for (final shift in _shiftAnimations.values) {
      shift.dispose();
    }
    _shiftAnimations.clear();
    _hoveringKey.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final resolvedPadding = widget.padding.resolve(
          Directionality.of(context),
        );
        final maxWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.of(context).size.width;
        final availableWidth = math.max(
          0.0,
          maxWidth - resolvedPadding.horizontal,
        );
        // Allow embedding inside unconstrained parents (e.g. Column) without throwing.
        final shouldShrinkWrap = !constraints.hasBoundedHeight;
        final bool? primary =
            widget.primary ?? (shouldShrinkWrap ? false : null);
        final columnCount = _calculateColumnCount(availableWidth);
        final tileWidth = _computeTileWidth(availableWidth, columnCount);

        final visibleEntries = _entries.toList(growable: false);
        final visibleCount = _visibleItemCount;

        final sliver = _WaterfallSliver(
          columnCount: columnCount,
          tileExtent: tileWidth,
          mainAxisSpacing: widget.mainAxisSpacing,
          crossAxisSpacing: widget.crossAxisSpacing,
          delegate: SliverChildBuilderDelegate((context, index) {
            if (index == visibleEntries.length) {
              return _buildTrailingDropZone(tileWidth);
            }
            final entry = visibleEntries[index];
            return _buildTile(
              entry: entry,
              width: tileWidth,
              visibleIndex: _visibleIndexFor(entry),
              visibleCount: visibleCount,
            );
          }, childCount: visibleEntries.length + 1),
        );

        final padding = resolvedPadding;
        final slivers = <Widget>[
          if (padding != EdgeInsets.zero)
            SliverPadding(padding: padding, sliver: sliver)
          else
            sliver,
        ];

        return CustomScrollView(
          controller: widget.scrollController,
          physics: widget.physics,
          primary: primary,
          shrinkWrap: shouldShrinkWrap,
          reverse: widget.reverse,
          keyboardDismissBehavior: widget.keyboardDismissBehavior,
          restorationId: widget.restorationId,
          clipBehavior: widget.clipBehavior,
          slivers: slivers,
        );
      },
    );
  }

  Widget _buildTile({
    required _AdaptiveEntry<T> entry,
    required double width,
    required int visibleIndex,
    required int visibleCount,
  }) {
    final child = RepaintBoundary(
      child: _buildAnimatedChild(entry, visibleIndex, visibleCount),
    );

    return KeyedSubtree(
      key: entry.tileKey,
      child: DragTarget<Object>(
        onWillAcceptWithDetails: (details) {
          final data = details.data;
          if (data == entry.key) {
            return false;
          }
          _setHovering(entry.key);
          return true;
        },
        onLeave: (_) => _clearHovering(entry.key),
        onAcceptWithDetails: (details) {
          _clearHovering(entry.key);
          _handleDrop(details.data, entry.key);
        },
        builder: (context, candidateData, rejectedData) {
          return ListenableBuilder(
            listenable: Listenable.merge([_hoveringKey, entry.dropAnimating]),
            child: child,
            builder: (context, stableChild) {
              final stable = stableChild;
              final isHovering =
                  candidateData.isNotEmpty || _hoveringKey.value == entry.key;
              final scale = isHovering ? 1.02 : 1.0;
              final draggingPlaceholder = widget.draggingChildOpacity < 1
                  ? Opacity(
                      opacity: widget.draggingChildOpacity,
                      child: stable,
                    )
                  : stable;
              final visibleChild = entry.dropAnimating.value
                  ? IgnorePointer(
                      child: Opacity(opacity: 0, child: stable),
                    )
                  : stable;

              final displayChild = IgnorePointer(
                ignoring: entry.removed,
                child: visibleChild,
              );

              return AnimatedScale(
                duration: const Duration(milliseconds: 120),
                scale: scale,
                child: SizedBox(
                  width: width,
                  child: LongPressDraggable<Object>(
                    data: entry.key,
                    dragAnchorStrategy: childDragAnchorStrategy,
                    feedback: _buildDragFeedback(
                      entry,
                      width,
                      visibleIndex,
                      visibleCount,
                    ),
                    childWhenDragging: draggingPlaceholder,
                    onDragStarted: () => _onDragStarted(entry),
                    onDragEnd: (details) {
                      if (!details.wasAccepted) {
                        _cancelActiveDrag();
                        entry.dropAnimating.value = false;
                      }
                    },
                    child: displayChild,
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildTrailingDropZone(double width) {
    return DragTarget<Object>(
      onWillAcceptWithDetails: (details) {
        _setHovering(_trailingDropMarker);
        return true;
      },
      onLeave: (_) => _clearHovering(_trailingDropMarker),
      onAcceptWithDetails: (details) {
        _clearHovering(_trailingDropMarker);
        _handleDrop(details.data, null);
      },
      builder: (context, candidateData, rejectedData) {
        return ValueListenableBuilder<Object?>(
          valueListenable: _hoveringKey,
          builder: (context, hoveringKey, _) {
            final isHovering =
                candidateData.isNotEmpty || hoveringKey == _trailingDropMarker;
            final colorScheme = Theme.of(context).colorScheme;
            final baseOnSurface = colorScheme.onSurface;
            final targetAlpha = ((baseOnSurface.a * 255.0) * 0.3)
                .round()
                .clamp(0, 255)
                .toInt();
            final fadedOnSurface = baseOnSurface.withAlpha(targetAlpha);

            return SizedBox(
              width: width,
              height: math.max(24, widget.mainAxisSpacing * 1.2),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isHovering
                        ? colorScheme.primary
                        : Colors.transparent,
                    width: 1.5,
                  ),
                ),
                child: Center(
                  child: Icon(
                    Icons.add,
                    size: 16,
                    color: isHovering ? colorScheme.primary : fadedOnSurface,
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildAnimatedChild(
    _AdaptiveEntry<T> entry,
    int visibleIndex,
    int visibleCount,
  ) {
    Widget child = _buildChildContent(
      entry,
      visibleIndex,
      visibleCount,
      animation: entry.animation,
    );

    final shift = _shiftAnimations[entry.key];
    if (shift != null) {
      child = AnimatedBuilder(
        animation: shift.animation,
        builder: (context, animatedChild) {
          final offset = shift.animation.value;
          if (offset == Offset.zero) {
            return animatedChild!;
          }
          return Transform.translate(offset: offset, child: animatedChild);
        },
        child: child,
      );
    }

    return _AnimatedEntry(
      key: ValueKey(entry.key),
      animation: entry.animation,
      child: child,
    );
  }

  Widget _buildChildContent(
    _AdaptiveEntry<T> entry,
    int visibleIndex,
    int visibleCount, {
    required Animation<double> animation,
  }) {
    final baseChild = widget.itemBuilder(
      context,
      entry.item,
      visibleIndex,
      animation,
    );

    if (!widget.separated || visibleIndex >= visibleCount - 1) {
      return baseChild;
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [baseChild, widget.separatorBuilder!(context, visibleIndex)],
    );
  }

  void _onDragStarted(_AdaptiveEntry<T> entry) {
    _activeDrag = _ActiveDrag(key: entry.key, startRect: _rectForEntry(entry));
  }

  void _cancelActiveDrag() {
    _activeDrag = null;
  }

  Map<Object, Rect> _captureEntryRects() {
    final rects = <Object, Rect>{};
    for (final entry in _entries) {
      final rect = _rectForEntry(entry);
      if (rect != null) {
        rects[entry.key] = rect;
      }
    }
    return rects;
  }

  Rect? _rectForEntry(_AdaptiveEntry<T> entry) {
    final context = entry.tileKey.currentContext;
    if (context == null) {
      return null;
    }
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.hasSize) {
      return null;
    }
    final origin = renderBox.localToGlobal(Offset.zero);
    return origin & renderBox.size;
  }

  Widget _buildDragFeedback(
    _AdaptiveEntry<T> entry,
    double width,
    int visibleIndex,
    int visibleCount,
  ) {
    final content = _buildChildContent(
      entry,
      visibleIndex,
      visibleCount,
      animation: const AlwaysStoppedAnimation<double>(1),
    );

    final feedback = widget.draggingChildOpacity < 1
        ? Opacity(opacity: widget.draggingChildOpacity, child: content)
        : content;

    return Material(
      color: Colors.transparent,
      elevation: 6,
      child: ConstrainedBox(
        constraints: BoxConstraints.tightFor(width: width),
        child: RepaintBoundary(child: feedback),
      ),
    );
  }

  void _handleDrop(Object data, Object? targetKey) {
    final dragged = _entryByKey[data];
    if (dragged == null) {
      return;
    }
    if (targetKey != null && targetKey == dragged.key) {
      return;
    }

    final previousRects = _captureEntryRects();

    final oldIndex = _entries.indexOf(dragged);
    if (oldIndex == -1) {
      return;
    }

    final oldVisibleIndex = _visibleIndexFor(dragged);
    final activeDrag = _activeDrag;
    _activeDrag = null;

    final matchingDrag = activeDrag != null && activeDrag.key == dragged.key
        ? activeDrag
        : null;

    setState(() {
      _hoveringKey.value = null;

      final entry = _entries.removeAt(oldIndex);

      final int insertIndex;
      if (targetKey == null) {
        insertIndex = _entries.length;
      } else {
        final targetIndex = _entries.indexWhere(
          (element) => element.key == targetKey,
        );

        if (targetIndex == -1) {
          insertIndex = _entries.length;
        } else if (targetIndex >= oldIndex) {
          insertIndex = math.min(targetIndex + 1, _entries.length);
        } else {
          insertIndex = targetIndex;
        }
      }

      final clampedIndex = insertIndex.clamp(0, _entries.length).toInt();
      entry.dropAnimating.value =
          matchingDrag != null && clampedIndex != oldIndex;
      _entries.insert(clampedIndex, entry);
    });

    _scheduleShiftAnimations(previousRects, dragged.key);

    final newVisibleIndex = _visibleIndexFor(dragged);
    final filtered = _entries
        .where((e) => !e.removed)
        .map((e) => e.item)
        .toList(growable: false);
    widget.onReorder?.call(oldVisibleIndex, newVisibleIndex);
    widget.onReorderComplete?.call(filtered);

    if (matchingDrag == null || oldVisibleIndex == newVisibleIndex) {
      if (dragged.dropAnimating.value) {
        _completeDropWithoutOverlay(dragged);
      }
      return;
    }

    _startDropAnimation(dragged, matchingDrag);
  }

  void _scheduleShiftAnimations(
    Map<Object, Rect> previousRects,
    Object draggedKey,
  ) {
    if (previousRects.isEmpty) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }

      final currentRects = <Object, Rect>{};
      for (final entry in _entries) {
        final rect = _rectForEntry(entry);
        if (rect != null) {
          currentRects[entry.key] = rect;
        }
      }

      final newShifts = <Object, _ShiftAnimation>{};

      for (final entry in _entries) {
        final key = entry.key;
        if (key == draggedKey) {
          continue;
        }
        final oldRect = previousRects[key];
        final newRect = currentRects[key];
        if (oldRect == null || newRect == null) {
          continue;
        }

        final delta = Offset(
          oldRect.left - newRect.left,
          oldRect.top - newRect.top,
        );
        if (delta.distanceSquared < 0.25) {
          continue;
        }

        final controller = AnimationController(
          vsync: this,
          duration: widget.dropAnimationDuration,
        );
        final animation = controller.drive(
          Tween<Offset>(
            begin: delta,
            end: Offset.zero,
          ).chain(CurveTween(curve: widget.insertCurve)),
        );
        final shift = _ShiftAnimation(
          controller: controller,
          animation: animation,
        );

        late final AnimationStatusListener listener;
        listener = (status) {
          if (status == AnimationStatus.completed ||
              status == AnimationStatus.dismissed) {
            controller.removeStatusListener(listener);
            if (!mounted) {
              shift.dispose();
              _shiftAnimations.remove(key);
              return;
            }
            setState(() {
              final removed = _shiftAnimations.remove(key);
              removed?.dispose();
            });
          }
        };
        controller.addStatusListener(listener);

        newShifts[key] = shift;
      }

      if (newShifts.isEmpty) {
        return;
      }

      setState(() {
        for (final entry in newShifts.entries) {
          final previous = _shiftAnimations.remove(entry.key);
          previous?.dispose();
          _shiftAnimations[entry.key] = entry.value;
        }
      });

      for (final shift in newShifts.values) {
        shift.controller.forward();
      }
    });
  }

  void _startDropAnimation(_AdaptiveEntry<T> entry, _ActiveDrag dragInfo) {
    final Rect? startRect = dragInfo.startRect ?? _rectForEntry(entry);
    if (startRect == null) {
      if (entry.dropAnimating.value && mounted) {
        _completeDropWithoutOverlay(entry);
      }
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final Rect? endRect = _rectForEntry(entry);
      if (endRect == null) {
        if (entry.dropAnimating.value) {
          _completeDropWithoutOverlay(entry);
        }
        return;
      }

      final overlayState = Overlay.maybeOf(context);
      if (overlayState == null) {
        if (entry.dropAnimating.value) {
          _completeDropWithoutOverlay(entry);
        }
        return;
      }

      final capturedChild = InheritedTheme.captureAll(
        context,
        Material(
          type: MaterialType.transparency,
          child: SizedBox(
            width: endRect.width,
            height: endRect.height,
            child: RepaintBoundary(
              child: _buildChildContent(
                entry,
                _visibleIndexFor(entry),
                _visibleItemCount,
                animation: const AlwaysStoppedAnimation<double>(1),
              ),
            ),
          ),
        ),
      );

      final controller = AnimationController(
        vsync: this,
        duration: widget.dropAnimationDuration,
      );
      final curved = CurvedAnimation(
        parent: controller,
        curve: widget.insertCurve,
      );

      late OverlayEntry overlayEntry;
      overlayEntry = OverlayEntry(
        builder: (overlayContext) {
          final t = curved.value;
          final rect = Rect.lerp(startRect, endRect, t) ?? endRect;
          return Positioned(
            left: rect.left,
            top: rect.top,
            width: rect.width,
            height: rect.height,
            child: IgnorePointer(child: capturedChild),
          );
        },
      );

      void handleComplete() {
        overlayEntry.remove();
        controller.dispose();
        if (mounted) {
          _completeDropWithoutOverlay(entry);
        }
      }

      curved.addListener(() {
        overlayEntry.markNeedsBuild();
      });
      curved.addStatusListener((status) {
        if (status == AnimationStatus.completed ||
            status == AnimationStatus.dismissed) {
          handleComplete();
        }
      });

      overlayState.insert(overlayEntry);
      controller.forward();
    });
  }

  void _completeDropWithoutOverlay(_AdaptiveEntry<T> entry) {
    entry.dropAnimating.value = false;
    entry.controller
      ..stop()
      ..forward(from: 0);
  }

  void _setHovering(Object key) {
    if (_hoveringKey.value == key) {
      return;
    }
    _hoveringKey.value = key;
  }

  void _clearHovering(Object key) {
    if (_hoveringKey.value != key) {
      return;
    }
    _hoveringKey.value = null;
  }

  int get _visibleItemCount => _entries.where((e) => !e.removed).length;

  int _visibleIndexFor(_AdaptiveEntry<T> entry) {
    var index = 0;
    for (final candidate in _entries) {
      if (candidate == entry) {
        return index;
      }
      if (!candidate.removed) {
        index++;
      }
    }
    return index;
  }

  int _calculateColumnCount(double availableWidth) {
    if (availableWidth <= 0) {
      return 1;
    }
    final desiredWidth = widget.columnWidth + widget.crossAxisSpacing;
    final computed = ((availableWidth + widget.crossAxisSpacing) / desiredWidth)
        .floor();
    return computed.clamp(1, widget.maxColumns);
  }

  double _computeTileWidth(double availableWidth, int columnCount) {
    if (columnCount <= 1 || availableWidth <= 0) {
      return availableWidth;
    }
    final totalSpacing = widget.crossAxisSpacing * (columnCount - 1);
    final width = (availableWidth - totalSpacing) / columnCount;
    return width.isFinite && width > 0 ? width : widget.columnWidth;
  }
}

class _AdaptiveEntry<T> {
  _AdaptiveEntry({
    required this.key,
    required this.item,
    required this.controller,
    required this.animation,
    required this.onRemoveCompleted,
  });

  final Object key;
  T item;
  final AnimationController controller;
  final Animation<double> animation;
  final VoidCallback onRemoveCompleted;
  final ValueNotifier<bool> dropAnimating = ValueNotifier(false);

  bool removed = false;
  bool markedForRemoval = false;
  final GlobalKey tileKey = GlobalKey(debugLabel: 'adaptive_reorderable_tile');

  void dispose() {
    controller.dispose();
    dropAnimating.dispose();
  }
}

class _ShiftAnimation {
  _ShiftAnimation({required this.controller, required this.animation});

  final AnimationController controller;
  final Animation<Offset> animation;

  void dispose() {
    controller.dispose();
  }
}

class _AnimatedEntry extends StatelessWidget {
  static final Animatable<double> _scaleTween = Tween<double>(
    begin: 0.92,
    end: 1,
  );

  const _AnimatedEntry({
    super.key,
    required this.animation,
    required this.child,
  });

  final Animation<double> animation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: animation,
      child: ScaleTransition(scale: animation.drive(_scaleTween), child: child),
    );
  }
}

class _ActiveDrag {
  const _ActiveDrag({required this.key, this.startRect});

  final Object key;
  final Rect? startRect;
}

class _WaterfallSliver extends SliverMultiBoxAdaptorWidget {
  const _WaterfallSliver({
    required this.columnCount,
    required this.tileExtent,
    required this.mainAxisSpacing,
    required this.crossAxisSpacing,
    required super.delegate,
  }) : assert(columnCount > 0),
       assert(tileExtent >= 0);

  final int columnCount;
  final double tileExtent;
  final double mainAxisSpacing;
  final double crossAxisSpacing;

  @override
  RenderSliverWaterfall createRenderObject(BuildContext context) {
    final SliverMultiBoxAdaptorElement element =
        context as SliverMultiBoxAdaptorElement;
    return RenderSliverWaterfall(
      childManager: element,
      columnCount: columnCount,
      tileExtent: tileExtent,
      mainAxisSpacing: mainAxisSpacing,
      crossAxisSpacing: crossAxisSpacing,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderSliverWaterfall renderObject,
  ) {
    renderObject
      ..columnCount = columnCount
      ..tileExtent = tileExtent
      ..mainAxisSpacing = mainAxisSpacing
      ..crossAxisSpacing = crossAxisSpacing;
  }
}

class _WaterfallParentData extends SliverMultiBoxAdaptorParentData {
  double crossAxisOffset = 0;
}

class _WaterfallCacheEntry {
  const _WaterfallCacheEntry({
    required this.column,
    required this.mainAxisOffset,
    required this.mainAxisExtent,
  });

  final int column;
  final double mainAxisOffset;
  final double mainAxisExtent;

  double get trailingOffset => mainAxisOffset + mainAxisExtent;
}

class _ChildMetrics {
  const _ChildMetrics({required this.mainAxisStart, required this.mainAxisEnd});

  final double mainAxisStart;
  final double mainAxisEnd;
}

class RenderSliverWaterfall extends RenderSliverMultiBoxAdaptor {
  RenderSliverWaterfall({
    required super.childManager,
    required int columnCount,
    required double tileExtent,
    required double mainAxisSpacing,
    required double crossAxisSpacing,
  }) : _columnCount = columnCount,
       _tileExtent = tileExtent,
       _mainAxisSpacing = mainAxisSpacing,
       _crossAxisSpacing = crossAxisSpacing;

  int get columnCount => _columnCount;
  int _columnCount;
  set columnCount(int value) {
    assert(value > 0);
    if (value == _columnCount) return;
    _columnCount = value;
    markNeedsLayout();
  }

  double get tileExtent => _tileExtent;
  double _tileExtent;
  set tileExtent(double value) {
    if (value == _tileExtent) return;
    _tileExtent = value;
    markNeedsLayout();
  }

  double get mainAxisSpacing => _mainAxisSpacing;
  double _mainAxisSpacing;
  set mainAxisSpacing(double value) {
    if (value == _mainAxisSpacing) return;
    _mainAxisSpacing = value;
    markNeedsLayout();
  }

  double get crossAxisSpacing => _crossAxisSpacing;
  double _crossAxisSpacing;
  set crossAxisSpacing(double value) {
    if (value == _crossAxisSpacing) return;
    _crossAxisSpacing = value;
    markNeedsLayout();
  }

  final List<_WaterfallCacheEntry?> _cache = <_WaterfallCacheEntry?>[];

  static const double _epsilon = 1e-3;

  @override
  void setupParentData(RenderObject child) {
    if (child.parentData is! _WaterfallParentData) {
      child.parentData = _WaterfallParentData();
    }
  }

  @override
  double childCrossAxisPosition(RenderBox child) {
    final _WaterfallParentData parentData =
        child.parentData! as _WaterfallParentData;
    return parentData.crossAxisOffset;
  }

  @override
  void performLayout() {
    final SliverConstraints constraints = this.constraints;
    childManager.didStartLayout();
    childManager.setDidUnderflow(false);

    final int childCount = childManager.childCount;
    if (childCount == 0) {
      _cache.clear();
      geometry = SliverGeometry.zero;
      childManager.didFinishLayout();
      return;
    }

    if (_cache.length > childCount) {
      _cache.removeRange(childCount, _cache.length);
    } else if (_cache.length < childCount) {
      _cache.addAll(
        List<_WaterfallCacheEntry?>.filled(childCount - _cache.length, null),
      );
    }

    final double scrollOffset =
        constraints.scrollOffset + constraints.cacheOrigin;
    final double remainingExtent = constraints.remainingCacheExtent;
    final double targetEnd = scrollOffset + remainingExtent;

    final List<double> columnOffsets = List<double>.filled(
      _columnCount,
      0.0,
      growable: false,
    );

    final int firstIndex = _resolveFirstIndex(scrollOffset, columnOffsets);

    final int leadingGarbage = firstChild != null
        ? calculateLeadingGarbage(firstIndex: firstIndex)
        : 0;
    collectGarbage(leadingGarbage, 0);

    RenderBox? child = firstChild;
    if (child == null) {
      if (!addInitialChild(index: firstIndex, layoutOffset: 0.0)) {
        geometry = const SliverGeometry(scrollExtent: 0, maxPaintExtent: 0);
        childManager.didFinishLayout();
        return;
      }
      child = firstChild;
    }

    // Ensure we have children leading up to the first index when scrolling back.
    while (true) {
      final SliverMultiBoxAdaptorParentData parentData =
          child!.parentData! as SliverMultiBoxAdaptorParentData;
      if (parentData.index! <= firstIndex) {
        break;
      }
      final RenderBox? previous = insertAndLayoutLeadingChild(
        _createChildConstraints(constraints),
      );
      if (previous == null) {
        break;
      }
      child = previous;
    }

    // Update column offsets for all items before firstIndex based on cache.
    _accumulateOffsetsForPrefix(firstIndex, columnOffsets);

    RenderBox? trailingChild = child;
    while (trailingChild != null && indexOf(trailingChild) < firstIndex) {
      trailingChild = childAfter(trailingChild);
    }
    if (trailingChild == null) {
      if (!addInitialChild(index: firstIndex, layoutOffset: 0.0)) {
        geometry = const SliverGeometry(scrollExtent: 0, maxPaintExtent: 0);
        childManager.didFinishLayout();
        return;
      }
      trailingChild = firstChild;
    }

    int trailingIndex = trailingChild != null
        ? indexOf(trailingChild)
        : firstIndex;
    double leadingScrollOffset = double.infinity;
    double trailingScrollOffset = double.negativeInfinity;
    bool reachedEnd = false;

    while (trailingChild != null) {
      final int currentIndex = indexOf(trailingChild);
      final _ChildMetrics metrics = _layoutChild(
        trailingChild,
        currentIndex,
        columnOffsets,
        constraints,
      );
      leadingScrollOffset = math.min(
        leadingScrollOffset,
        metrics.mainAxisStart,
      );
      trailingScrollOffset = math.max(
        trailingScrollOffset,
        metrics.mainAxisEnd,
      );
      trailingIndex = currentIndex;

      if (trailingScrollOffset >= targetEnd) {
        break;
      }

      final int nextIndex = currentIndex + 1;
      if (nextIndex >= childCount) {
        reachedEnd = true;
        break;
      }

      RenderBox? nextChild = childAfter(trailingChild);
      if (nextChild == null || indexOf(nextChild) != nextIndex) {
        nextChild = insertAndLayoutChild(
          _createChildConstraints(constraints),
          after: trailingChild,
        );
        if (nextChild == null) {
          reachedEnd = true;
          break;
        }
        final SliverMultiBoxAdaptorParentData nextParentData =
            nextChild.parentData! as SliverMultiBoxAdaptorParentData;
        assert(nextParentData.index == nextIndex);
      }
      trailingChild = nextChild;
    }

    final int lastIndex = trailingChild != null
        ? indexOf(trailingChild)
        : trailingIndex;
    final int trailingGarbage = lastChild != null
        ? calculateTrailingGarbage(lastIndex: lastIndex)
        : 0;
    if (trailingGarbage > 0) {
      collectGarbage(0, trailingGarbage);
    }

    final double leadingOffset = leadingScrollOffset.isFinite
        ? leadingScrollOffset
        : 0.0;
    final double trailingOffset = trailingScrollOffset.isFinite
        ? trailingScrollOffset
        : leadingOffset;

    final double estimatedMaxScrollExtent = reachedEnd
        ? trailingOffset
        : childManager.estimateMaxScrollOffset(
            constraints,
            firstIndex: firstIndex,
            lastIndex: lastIndex,
            leadingScrollOffset: leadingOffset,
            trailingScrollOffset: trailingOffset,
          );

    final double paintExtent = calculatePaintOffset(
      constraints,
      from: leadingOffset,
      to: trailingOffset,
    );
    final double cacheExtent = calculateCacheOffset(
      constraints,
      from: leadingOffset,
      to: trailingOffset,
    );

    final double scrollExtent = math.max(
      estimatedMaxScrollExtent,
      trailingOffset,
    );

    geometry = SliverGeometry(
      scrollExtent: scrollExtent,
      paintExtent: paintExtent,
      maxPaintExtent: math.max(scrollExtent, trailingOffset),
      cacheExtent: cacheExtent,
      hasVisualOverflow:
          scrollExtent > paintExtent ||
          constraints.scrollOffset > 0.0 ||
          constraints.overlap != 0.0,
    );

    if (reachedEnd) {
      childManager.setDidUnderflow(true);
    }

    childManager.didFinishLayout();
  }

  int _resolveFirstIndex(double scrollOffset, List<double> columnOffsets) {
    final int childCount = _cache.length;
    int index = 0;
    for (; index < childCount; index++) {
      final _WaterfallCacheEntry? entry = _cache[index];
      if (entry == null) {
        break;
      }
      if (entry.trailingOffset >= scrollOffset) {
        break;
      }
      columnOffsets[entry.column] = math.max(
        columnOffsets[entry.column],
        entry.trailingOffset + _mainAxisSpacing,
      );
    }
    if (childCount == 0) {
      return 0;
    }
    return index.clamp(0, childCount - 1);
  }

  void _accumulateOffsetsForPrefix(int limit, List<double> columnOffsets) {
    final int capped = limit.clamp(0, _cache.length);
    for (int i = 0; i < capped; i++) {
      final _WaterfallCacheEntry? entry = _cache[i];
      if (entry == null) {
        return;
      }
      columnOffsets[entry.column] = math.max(
        columnOffsets[entry.column],
        entry.trailingOffset + _mainAxisSpacing,
      );
    }
  }

  _ChildMetrics _layoutChild(
    RenderBox child,
    int index,
    List<double> columnOffsets,
    SliverConstraints constraints,
  ) {
    final _WaterfallParentData parentData =
        child.parentData! as _WaterfallParentData;

    final _WaterfallCacheEntry? cached = index < _cache.length
        ? _cache[index]
        : null;

    int column = 0;
    double mainAxisOffset = 0;

    if (cached != null) {
      column = cached.column.clamp(0, _columnCount - 1);
      mainAxisOffset = columnOffsets[column];
      if ((mainAxisOffset - cached.mainAxisOffset).abs() <= _epsilon) {
        mainAxisOffset = cached.mainAxisOffset;
      } else {
        mainAxisOffset = columnOffsets[column];
      }
    } else {
      column = _shortestColumn(columnOffsets);
      mainAxisOffset = columnOffsets[column];
    }

    final BoxConstraints childConstraints = _createChildConstraints(
      constraints,
    );
    child.layout(childConstraints, parentUsesSize: true);

    final double extent = _childExtent(child);
    final double crossAxisOffset = _computeCrossAxisOffset(column, constraints);

    parentData
      ..layoutOffset = mainAxisOffset
      ..crossAxisOffset = crossAxisOffset;

    final _WaterfallCacheEntry newEntry = _WaterfallCacheEntry(
      column: column,
      mainAxisOffset: mainAxisOffset,
      mainAxisExtent: extent,
    );

    final _WaterfallCacheEntry? oldEntry = index < _cache.length
        ? _cache[index]
        : null;
    if (!_sameEntry(oldEntry, newEntry)) {
      _invalidateCacheAfter(index);
    }
    if (index < _cache.length) {
      _cache[index] = newEntry;
    }

    columnOffsets[column] = mainAxisOffset + extent + _mainAxisSpacing;

    return _ChildMetrics(
      mainAxisStart: mainAxisOffset,
      mainAxisEnd: mainAxisOffset + extent,
    );
  }

  bool _sameEntry(_WaterfallCacheEntry? a, _WaterfallCacheEntry b) {
    if (a == null) {
      return false;
    }
    return a.column == b.column &&
        (a.mainAxisOffset - b.mainAxisOffset).abs() <= _epsilon &&
        (a.mainAxisExtent - b.mainAxisExtent).abs() <= _epsilon;
  }

  void _invalidateCacheAfter(int index) {
    for (int i = index + 1; i < _cache.length; i++) {
      if (_cache[i] == null) {
        break;
      }
      _cache[i] = null;
    }
  }

  int _shortestColumn(List<double> columnOffsets) {
    var shortest = columnOffsets[0];
    var result = 0;
    for (var i = 1; i < columnOffsets.length; i++) {
      final value = columnOffsets[i];
      if (value < shortest) {
        shortest = value;
        result = i;
      }
    }
    return result;
  }

  BoxConstraints _createChildConstraints(SliverConstraints constraints) {
    switch (constraints.axis) {
      case Axis.vertical:
        return BoxConstraints(minWidth: tileExtent, maxWidth: tileExtent);
      case Axis.horizontal:
        return BoxConstraints(minHeight: tileExtent, maxHeight: tileExtent);
    }
  }

  double _childExtent(RenderBox child) {
    switch (constraints.axis) {
      case Axis.vertical:
        return child.size.height;
      case Axis.horizontal:
        return child.size.width;
    }
  }

  double _computeCrossAxisOffset(int column, SliverConstraints constraints) {
    final double delta = tileExtent + crossAxisSpacing;
    final bool reverse = axisDirectionIsReversed(
      constraints.crossAxisDirection,
    );
    if (reverse) {
      return constraints.crossAxisExtent - tileExtent - column * delta;
    }
    return column * delta;
  }
}

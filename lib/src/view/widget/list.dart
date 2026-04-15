import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';

/// A widget that displays multiple lists in columns, adapting layout for mobile and desktop.
final class MultiList extends StatefulWidget {
  /// List of columns, each containing a list of widgets.
  final List<List<Widget>> children;

  /// Padding around the entire list.
  final EdgeInsetsGeometry outerPadding;

  /// Padding between columns.
  final double betweenPadding;

  /// Number used to divide available width for column sizing.
  final double widthDivider;
  final double scrollbarGutter;

  const MultiList({
    super.key,
    required this.children,
    this.outerPadding = kOuterPadding,
    this.widthDivider = 2.2,
    this.betweenPadding = 10,
    this.scrollbarGutter = 12,
  });

  /// Default outer padding.
  static const kOuterPadding = EdgeInsets.symmetric(horizontal: 17, vertical: 13);

  @override
  State<MultiList> createState() => _MultiListState();
}

/// State for MultiList, handles layout adaptation and scrolling.
final class _MultiListState extends State<MultiList> {
  var _isMobile = false;

  /// Controller for horizontal scrolling on desktop.
  final _horizonScroll = ScrollController();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _isMobile = context.isMobile;
  }

  @override
  void dispose() {
    _horizonScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isMobile) {
      return ListView(
        padding: widget.outerPadding,
        children: widget.children.expand((list) => list).toList(),
      );
    }

    return _buildDesktop(context);
  }

  Widget _buildDesktop(BuildContext context) {
    return LayoutBuilder(builder: (_, cons) {
      final len = widget.children.length;
      final totalBetweenPadding = widget.betweenPadding * (len - 1);
      final columnWidth = (cons.maxWidth - widget.outerPadding.horizontal - totalBetweenPadding) / widget.widthDivider;

      return Scrollbar(
        controller: _horizonScroll,
        child: ListView.separated(
          padding: widget.outerPadding,
          controller: _horizonScroll,
          scrollDirection: Axis.horizontal,
          itemCount: len,
          separatorBuilder: (_, _) => SizedBox(width: widget.betweenPadding),
          itemBuilder: (_, i) {
            final col = widget.children[i];

            return SizedBox(
              width: columnWidth,
              child: ListView.builder(
                padding: EdgeInsets.only(right: widget.scrollbarGutter),
                itemCount: col.length,
                itemBuilder: (_, index) => col[index],
              ),
            );
          },
        ),
      );
    });
  }
}

//// Based on [MultiList], but automatically calculates the number of columns based on the available width.
final class AutoMultiList extends StatefulWidget {
  /// List of widgets to distribute.
  final List<Widget> children;

  /// Desired width for each column.
  final double columnWidth;

  /// Padding around the entire list.
  final EdgeInsetsGeometry outerPadding;

  /// Padding between columns.
  final double betweenPadding;

  const AutoMultiList({
    super.key,
    required this.children,
    this.outerPadding = MultiList.kOuterPadding,
    this.columnWidth = UIs.columnWidth,
    this.betweenPadding = 10,
  });

  @override
  State<AutoMultiList> createState() => _AutoMultiListState();
}

/// State for AutoMultiList, handles dynamic column calculation and distribution.
class _AutoMultiListState extends State<AutoMultiList> {
  /// The distributed children into columns.
  List<List<Widget>> _distributedChildren = [];

  /// Actual number of columns calculated.
  int _actualColumnCount = 0;

  /// Current total width available.
  double _totalWidth = 0.0;

  /// Last total width used for distribution.
  double _lastTotalWidth = 1.0;

  /// Hash code of the last children list to detect changes
  int _lastChildrenHashCode = 0;

  @override
  void didUpdateWidget(covariant AutoMultiList oldWidget) {
    super.didUpdateWidget(oldWidget);
    final needsUpdate = oldWidget.children.length != widget.children.length ||
        oldWidget.columnWidth != widget.columnWidth ||
        oldWidget.outerPadding != widget.outerPadding;
    if (needsUpdate) {
      _updateDistribution(forceUpdate: true);
    }
  }

  void _updateDistribution({bool forceUpdate = false}) {
    final currentWidth = _totalWidth;
    final availableWidth = currentWidth - widget.outerPadding.horizontal;
    final newColumnCount = availableWidth / widget.columnWidth;
    final clampedColumnCount = newColumnCount.floor().clamp(1, 10);

    final currentChildrenHashCode = _computeChildrenHashCode(widget.children);
    final widthChanged = (_lastTotalWidth - currentWidth).abs() > 1.0;
    final needsUpdate = forceUpdate ||
        widthChanged ||
        _lastChildrenHashCode != currentChildrenHashCode ||
        _actualColumnCount != clampedColumnCount;

    if (!needsUpdate) {
      return;
    }

    _actualColumnCount = clampedColumnCount;
    _distributedChildren = _distributeChildrenToColumns(widget.children, _actualColumnCount);
    _lastTotalWidth = currentWidth;
    _lastChildrenHashCode = currentChildrenHashCode;
  }

  int _computeChildrenHashCode(List<Widget> children) {
    return Object.hashAll(children);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (_, cons) {
      _totalWidth = cons.maxWidth;
      _updateDistribution();

      return MultiList(
        betweenPadding: widget.betweenPadding,
        outerPadding: widget.outerPadding,
        widthDivider: _actualColumnCount.toDouble(),
        children: _distributedChildren,
      );
    });
  }
}

extension on _AutoMultiListState {
  List<List<Widget>> _distributeChildrenToColumns(List<Widget> children, int columnCount) {
    if (children.isEmpty || columnCount <= 1) {
      return [List<Widget>.from(children)];
    }

    final columns = List.generate(columnCount, (_) => <Widget>[]);
    final itemCount = children.length;
    final baseItemsPerColumn = itemCount ~/ columnCount;
    final extraItems = itemCount % columnCount;
    int currentIndex = 0;
    for (int col = 0; col < columnCount; col++) {
      final itemsInThisColumn = baseItemsPerColumn + (col < extraItems ? 1 : 0);
      for (int i = 0; i < itemsInThisColumn; i++) {
        if (currentIndex < itemCount) {
          columns[col].add(children[currentIndex++]);
        }
      }
    }
    return columns;
  }
}

import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

// `MultiList` was here: a list per group, side by side above 600pt and
// stacked below it. Two things were wrong with the wide half. Each column
// scrolled on its own inside a row that scrolled horizontally, so a page of
// cards had no one position to be at — the same fault [MasonryList] was
// written to fix, and its doc used to point here for grouped content. And it
// split at 600 while the layouts around it split at 800, so between the two a
// page reached for a second column at a width that had already been judged too
// narrow for one.
//
// The groups it took are titles in a single list now. Nothing was reading its
// columns as columns; they were sections, and a section is a heading.
//
// `kOuterPadding` went with it, having always been [UIs.roundRectCardPadding]
// spelled a second time.

/// Cards flowing down as many columns as the width allows, each landing in
/// whichever column is currently shortest.
///
/// Replaces a round-robin split into one [ListView] per column. That put every
/// other card in the next column regardless of how tall any of them were, so
/// one long card left its neighbour half empty; worse, each column scrolled on
/// its own, and a page of cards had no single position to be at.
///
/// The columns here are only how many fit. Where the grouping means something,
/// the sections belong in one list under their own headings — see the note
/// above, where a widget that made each of them a column used to be.
final class MasonryList extends StatelessWidget {
  MasonryList({
    super.key,
    required List<Widget> children,
    this.columnWidth = UIs.columnWidth,
    this.maxColumns = 10,
    this.padding = kPadding,
    this.spacing = kSpacing,
    this.controller,
  }) : itemCount = children.length,
       itemBuilder = ((_, i) => children[i]);

  /// The lazy form, for a list long enough that building the ones off screen
  /// costs something — a card per server, each watching its own state.
  const MasonryList.builder({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.columnWidth = UIs.columnWidth,
    this.maxColumns = 10,
    this.padding = kPadding,
    this.spacing = kSpacing,
    this.controller,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  /// {@template masonry_column_width}
  /// How wide a column wants to be. The real width is whatever is left after
  /// dividing the space between however many of these fit.
  /// {@endtemplate}
  final double columnWidth;

  /// {@template masonry_max_columns}
  /// A ceiling on the columns, for content that stops being readable when it
  /// is spread across a whole desktop window.
  /// {@endtemplate}
  final int maxColumns;

  final EdgeInsets padding;

  /// {@template masonry_spacing}
  /// Between columns and between cards, the same on both axes: the grid should
  /// read as one field of cards rather than as rows or as columns.
  /// {@endtemplate}
  final double spacing;

  final ScrollController? controller;

  /// Enough to keep cards off the window edge and each other, and no more.
  ///
  /// Read with [kSpacing]: the cards here are [CardX], and a `Card` brings a
  /// 4pt margin of its own. So what shows above the first card is this plus
  /// that, and what shows between two of them is [kSpacing] plus two of them —
  /// which is how a nominal 8 and 8 drew as 12 and 16, and why the vertical
  /// rhythm of every tab that uses this read as loose.
  static const kPadding = EdgeInsets.symmetric(horizontal: 8, vertical: 4);

  /// Between one card and the next, before their own margins are added.
  ///
  /// Shared with `PageColumns`, which does the same column arithmetic for the
  /// pages that switch between the two layouts and used to spell this out a
  /// second time.
  static const kSpacing = 4.0;

  /// How many columns [width] holds. Public so a caller that has to size
  /// itself around the same answer gets the same one.
  int columnsFor(double width) {
    final available = width - padding.horizontal;
    if (available <= 0) return 1;
    return ((available + spacing) / (columnWidth + spacing)).floor().clamp(
      1,
      maxColumns,
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (_, cons) => MasonryGridView.count(
        controller: controller,
        padding: padding,
        crossAxisCount: columnsFor(cons.maxWidth),
        mainAxisSpacing: spacing,
        crossAxisSpacing: spacing,
        itemCount: itemCount,
        itemBuilder: itemBuilder,
      ),
    );
  }
}

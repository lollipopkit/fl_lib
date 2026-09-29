import 'package:fl_lib/fl_lib.dart';
import 'package:material_ui/material_ui.dart';

/// The card/form grid used by the pages that lay their content out in columns.
///
/// Left to itself on a wide desktop window a grid of these produced five or six
/// narrow columns, and reading one page meant crossing the whole screen. Edit
/// pages suffered most: a single form became five columns of unrelated fields.
/// Hence both a wider column and a ceiling on how many of them there can be.
///
/// Children are placed in the order they are given — the first in the first
/// column, the second in the second, and so on across and down. Not packed by
/// height like the home grid: these pages are forms, and a form whose first
/// field lands at the top of the *second* column because that column happened
/// to be shorter is a form nobody can read in the order it was written.
class PageColumns extends StatelessWidget {
  const PageColumns({
    super.key,
    required this.children,
    this.controller,
    this.bottomInset = 0,
    this.padding = defaultPadding,
    this.spacing = defaultSpacing,
  });

  final List<Widget> children;

  /// The grid's scroll position, for a page with something floating over it
  /// that has to know when the content moves.
  final ScrollController? controller;

  /// Room below the last card, for whatever is floating there. Without it the
  /// bottom of the page can only be read by scrolling past its own end.
  final double bottomInset;

  /// Around the grid.
  ///
  /// Given rather than fixed because what a child *is* decides how much of
  /// this it already carries: a `CardX` brings a margin of its own, so a page
  /// of them wants less here than a page of bare rows to reach the same gap on
  /// screen.
  final EdgeInsets padding;

  /// Between one column and the next, and between two children of one.
  final double spacing;

  static const columnWidth = UIs.pageColumnWidth;

  static const _maxColumns = 3;

  // Both taken from the grid rather than restated. `_spacing` was written out
  // as its own 8 and would have gone on saying 8 after the grid stopped, which
  // is the disagreement the comment below is there to prevent.
  static const defaultSpacing = MasonryList.kSpacing;
  static const defaultPadding = MasonryList.kPadding;

  /// Wide enough for [_maxColumns] and no more. Derived from the grid's own
  /// arithmetic rather than written out, so it follows if either input
  /// changes — a cap without the width just leaves emptier columns.
  static final maxWidth = widthFor(_maxColumns);

  /// How wide a grid of [columns] columns is, at its own metrics.
  ///
  /// What a caller capping the page it puts this on needs: a cap a few points
  /// under this leaves [columnsFor] measuring room for one fewer, and the form
  /// is laid out in a single column the width of two.
  static double widthFor(
    int columns, {
    EdgeInsets padding = defaultPadding,
    double spacing = defaultSpacing,
  }) =>
      columns * columnWidth + (columns - 1) * spacing + padding.horizontal;

  /// How many columns [width] holds. The same arithmetic [MasonryList] uses,
  /// so a page that switches between the two does not change width.
  static int columnsFor(
    double width, {
    EdgeInsets padding = defaultPadding,
    double spacing = defaultSpacing,
  }) {
    final available = width - padding.horizontal;
    if (available <= 0) return 1;
    return ((available + spacing) / (columnWidth + spacing)).floor().clamp(
      1,
      _maxColumns,
    );
  }

  @override
  Widget build(BuildContext context) {
    // `SizedBox.expand` rather than letting the scroll view size itself: a
    // `SingleChildScrollView` under the loose constraints a `Center` passes
    // down takes the height of its content, so a page with less than a
    // screenful of cards ended up centred vertically, floating with empty
    // space above it. Told to fill, it starts at the top and scrolls only
    // when there is more than fits.
    //
    // Requires a bounded height, which every caller has — this is a page
    // body, and the grid it replaced needed one too.
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: widthFor(_maxColumns, padding: padding, spacing: spacing),
        ),
        child: SizedBox.expand(
          child: LayoutBuilder(
            builder: (_, cons) {
              final columns = columnsFor(
                cons.maxWidth,
                padding: padding,
                spacing: spacing,
              );
              return SingleChildScrollView(
                controller: controller,
                padding: padding.copyWith(
                  bottom: padding.bottom + bottomInset,
                ),
                child: columns == 1
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        spacing: spacing,
                        children: children,
                      )
                    : Row(
                        // Columns are as tall as what is in them, and a short
                        // one beside a long one should stop rather than
                        // stretch.
                        crossAxisAlignment: CrossAxisAlignment.start,
                        spacing: spacing,
                        children: [
                          for (var col = 0; col < columns; col++)
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                spacing: spacing,
                                children: [
                                  for (
                                    var i = col;
                                    i < children.length;
                                    i += columns
                                  )
                                    children[i],
                                ],
                              ),
                            ),
                        ],
                      ),
              );
            },
          ),
        ),
      ),
    );
  }
}

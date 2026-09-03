import 'package:flutter/material.dart';

/// A sheet that is a short list of things to pick from.
///
/// Distinct from the sheets that are a *panel* — a conversation history, an
/// editor — which take most of the window and bring their own chrome. This one
/// is as tall as its rows, so every point of padding in it is a point of the
/// sheet, and the two should not be sized alike.
///
/// One place for how such a sheet is raised, because there is more than one:
/// the home page's "more", the session switcher on the terminal and file tabs.
/// They looked alike until one of them was adjusted.
Future<T?> showRowsSheet<T>(
  BuildContext context, {
  required List<Widget> Function(BuildContext context) rows,
}) {
  return showModalBottomSheet<T>(
    context: context,
    // Above whatever navigator raised it. A tab's own navigator would clip the
    // sheet to the tab, and these are raised from tabs.
    useRootNavigator: true,
    // Not Material's: it puts the handle in a strip `kMinInteractiveDimension`
    // tall — 48 points to draw a 4-point line, which on a sheet of three rows
    // is a fifth of the sheet. [RowsSheet] draws its own, and dragging the
    // sheet away works the same either way; the handle only says that it can
    // be.
    showDragHandle: false,
    builder: (ctx) => RowsSheet(children: rows(ctx)),
  );
}

/// One of a set of choices, in a [showRowsSheet].
///
/// The tick is what says which one is on. `ListTile.selected` alone only
/// recolours the text and the icon, which on a list where every row is the
/// same shape reads as "this one is a different colour" rather than as an
/// answer — and not at all to anyone who cannot tell the two colours apart.
class SheetChoiceTile extends StatelessWidget {
  const SheetChoiceTile({
    super.key,
    required this.title,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  final String title;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return ListTile(
      selected: selected,
      leading: icon == null ? null : Icon(icon),
      title: Text(title),
      trailing: selected ? Icon(Icons.check, color: scheme.primary) : null,
      onTap: onTap,
    );
  }
}

/// The body of a [showRowsSheet], and what makes one row-sized.
class RowsSheet extends StatelessWidget {
  const RowsSheet({super.key, required this.children});

  final List<Widget> children;

  /// The grip, at Material's own measurements — only the room around it is
  /// this file's own.
  static const _handleSize = Size(32, 4);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return SafeArea(
      // The sheet's own top is against the barrier, not against a status bar.
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            margin: const EdgeInsets.symmetric(vertical: 10),
            width: _handleSize.width,
            height: _handleSize.height,
            decoration: BoxDecoration(
              color: scheme.onSurfaceVariant.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(_handleSize.height / 2),
            ),
          ),
          Flexible(
            // Compact rather than dense: `dense` shrinks the text as well, and
            // these rows are read, not scanned. What is being taken out is the
            // room around a row, which is what there is too much of when the
            // whole sheet is four of them.
            child: ListTileTheme.merge(
              visualDensity: VisualDensity.compact,
              minVerticalPadding: 4,
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 8),
                children: children,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

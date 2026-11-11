import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:fl_lib/src/view/widget/resizable_sheet.dart';

/// Text editors retain their own caret-navigation shortcuts.
class _RowTraversalActivator extends SingleActivator {
  const _RowTraversalActivator(super.trigger);

  @override
  bool accepts(KeyEvent event, HardwareKeyboard state) {
    final editor = FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<EditableText>();
    return editor == null && super.accepts(event, state);
  }
}

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
  // Resizable like every other sheet: a list of a hundred network interfaces
  // is still "a list of things to pick from", and wants the window.
  return showResizableSheet<T>(
    context,
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
    this.leading,
    this.subtitle,
    this.action,
    this.onFocusChange,
    this.autofocus = false,
  });

  final String title;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  /// In place of [icon], for a row whose mark is not an icon — a server's.
  final Widget? leading;

  /// A second line under [title], for a row the title alone does not tell
  /// apart — which servers a workspace holds, which key runs a command.
  final String? subtitle;

  /// A button of the row's own, before the tick: closing or deleting the
  /// thing the row picks, without picking it.
  final Widget? action;

  final ValueChanged<bool>? onFocusChange;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Focus(
      canRequestFocus: false,
      onFocusChange: onFocusChange,
      child: ListTile(
        autofocus: autofocus,
        selected: selected,
        leading: leading ?? (icon == null ? null : Icon(icon)),
        title: Text(title),
        subtitle: subtitle == null
            ? null
            : Text(
                subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
        trailing: action == null
            ? (selected ? Icon(Icons.check, color: scheme.primary) : null)
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (selected) Icon(Icons.check, color: scheme.primary),
                  action!,
                ],
              ),
        onTap: onTap,
      ),
    );
  }
}

/// The body of a [showRowsSheet], and what makes one row-sized.
class RowsSheet extends StatelessWidget {
  const RowsSheet({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        _RowTraversalActivator(LogicalKeyboardKey.arrowDown): NextFocusIntent(),
        _RowTraversalActivator(LogicalKeyboardKey.arrowUp):
            PreviousFocusIntent(),
      },
      child: FocusTraversalGroup(
        policy: WidgetOrderTraversalPolicy(),
        child: FocusScope(
          autofocus: true,
          child: SafeArea(
            // The sheet's own top is against the barrier, not against a status bar.
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  // Compact rather than dense: `dense` shrinks the text as well, and
                  // these rows are read, not scanned. What is being taken out is the
                  // room around a row, which is what there is too much of when the
                  // whole sheet is four of them.
                  child: ListTileTheme.merge(
                    visualDensity: VisualDensity.compact,
                    minVerticalPadding: 4,
                    // Build all rows so focus traversal can reach offscreen choices.
                    // The traversal policy scrolls the newly focused row into view.
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: children,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A title, content and actions, as the body of a [showResizableSheet] —
/// what `showSheet` raises.
///
/// The title and the actions are `PickSheet`'s, so a sheet that asks and one
/// that picks look like one thing.
class PromptSheet extends StatelessWidget {
  const PromptSheet({
    super.key,
    this.title,
    this.child,
    this.actions,
    this.titlePadding = defaultTitlePadding,
    this.contentPadding = defaultContentPadding,
    this.actionsPadding = defaultActionsPadding,
  });

  final Widget? title;
  final Widget? child;
  final List<Widget>? actions;
  final EdgeInsetsGeometry titlePadding;
  final EdgeInsetsGeometry contentPadding;
  final EdgeInsetsGeometry actionsPadding;

  static const defaultTitlePadding = EdgeInsets.fromLTRB(17, 0, 17, 3);
  static const defaultContentPadding = EdgeInsets.fromLTRB(17, 7, 17, 13);
  static const defaultActionsPadding = EdgeInsets.fromLTRB(13, 3, 13, 7);

  /// Its [ResizableSheet.restLimit]. What it holds is read whole and often
  /// does not scroll: at 60%, a form of a few fields under a keyboard
  /// overflowed.
  static const restLimit = 0.9;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final actions = this.actions;
    return SafeArea(
      // The sheet's own top is against the barrier, not against a status bar.
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title case final title?)
            Padding(
              padding: titlePadding,
              // At the start whatever it is given: a title narrower than the
              // sheet, or one under an inherited alignment, read as centred.
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: Semantics(
                  header: true,
                  namesRoute: true,
                  child: DefaultTextStyle.merge(
                    style: theme.textTheme.titleMedium,
                    textAlign: TextAlign.start,
                    child: title,
                  ),
                ),
              ),
            ),
          if (child case final child?)
            Flexible(
              child: Padding(
                padding: contentPadding,
                // Loose, at the start: what has a size of its own — a spinner,
                // a code capped at a width — keeps it, as in a dialog, rather
                // than being pulled to the sheet's width. As tall as it is.
                child: Align(
                  alignment: AlignmentDirectional.topStart,
                  heightFactor: 1,
                  // An [AlertDialog]'s, so a plain text reads as it did there.
                  child: DefaultTextStyle.merge(
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    child: child,
                  ),
                ),
              ),
            ),
          if (actions != null && actions.isNotEmpty)
            Padding(
              padding: actionsPadding,
              child: OverflowBar(
                alignment: MainAxisAlignment.end,
                overflowAlignment: OverflowBarAlignment.end,
                spacing: 8,
                children: actions,
              ),
            ),
        ],
      ),
    );
  }
}

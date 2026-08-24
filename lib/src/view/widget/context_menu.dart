import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';

/// One entry in a context menu.
///
/// A description rather than a widget, because the same menu has to be drawn
/// two ways: a centred dialog for a finger and a popup at the pointer for a
/// mouse. A `List<Widget>` can only be the first.
///
/// It also moves closing the menu off the action. Every entry used to begin
/// with `context.popDialog()` — the boilerplate that, forgotten or written as
/// `context.pop()`, closes the page instead (see the rule in the project's
/// CLAUDE.md). Here the menu closes itself and then runs [onTap].
@immutable
class ContextMenuAction {
  const ContextMenuAction({
    required this.text,
    required this.onTap,
    this.icon,
    this.destructive = false,
  });

  final String text;

  /// Run after the menu has closed, so an action that opens a dialog of its
  /// own is not opening it underneath this one.
  final VoidCallback onTap;

  final IconData? icon;

  /// Drawn in the warning colour. For the entries that take something away.
  final bool destructive;
}

/// Opens a menu for something, at [at] or — for a long press, which has a
/// finger over the spot — in the middle.
///
/// The shape [showContextMenu] takes, so a widget offering "the other thing"
/// can hand its caller the position without knowing what the menu will be.
typedef ContextMenuOpener = void Function(Offset? at);

/// Shows [actions], where the pointer is or in the middle of the screen.
///
/// [at] is a global position — what `WidgetSecondaryX.onSecondary` hands over.
/// Null means it was a long press, and a menu that opens under the finger that
/// summoned it is a menu partly covered by that finger.
Future<void> showContextMenu(
  BuildContext context,
  List<ContextMenuAction> actions, {
  String? title,
  Offset? at,
}) async {
  if (actions.isEmpty) return;

  final ContextMenuAction? chosen;
  if (at == null) {
    chosen = await context.showRoundDialog<ContextMenuAction>(
      title: title,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final action in actions)
            Btn.tile(
              icon: Icon(action.icon),
              text: action.text,
              textStyle: action.destructive
                  ? UIs.textRed
                  : const TextStyle(fontSize: 16, fontWeight: FontWeight.w400),
              // Popped as a value rather than run here: the dialog has to be
              // gone before an action that opens another one runs.
              onTap: () => context.popDialog(action),
            ),
        ],
      ),
    );
  } else {
    chosen = await _showAt(context, actions, at);
  }

  chosen?.onTap();
}

Future<ContextMenuAction?> _showAt(
  BuildContext context,
  List<ContextMenuAction> actions,
  Offset at,
) {
  final overlay = Overlay.of(context).context.findRenderObject();
  if (overlay is! RenderBox) return Future.value();

  return showMenu<ContextMenuAction>(
    context: context,
    // A zero-size rect at the pointer: the menu opens from there and Flutter
    // reflows it when it would run off an edge, which is what makes a
    // right-click near the bottom of a short window still usable.
    position: RelativeRect.fromRect(
      at & Size.zero,
      Offset.zero & overlay.size,
    ),
    items: [
      for (final action in actions)
        PopupMenuItem<ContextMenuAction>(
          value: action,
          child: Row(
            spacing: 11,
            children: [
              if (action.icon case final icon?)
                Icon(
                  icon,
                  size: 18,
                  color: action.destructive ? UIs.textRed.color : null,
                ),
              Text(
                action.text,
                style: action.destructive ? UIs.textRed : null,
              ),
            ],
          ),
        ),
    ],
  );
}

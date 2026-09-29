import 'dart:math' as math;

import 'package:fl_lib/fl_lib.dart';
import 'package:material_ui/material_ui.dart';

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
    this.note,
    this.destructive = false,
  });

  final String text;

  /// What the entry is of, when that is worth saying and is not the entry.
  ///
  /// An address to copy, a session to open. Drawn small and grey at the other
  /// end of the row, so a menu can be read down its left edge and the detail
  /// is there for the one entry being considered.
  final String? note;

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

/// Every measurement the menu at a pointer is drawn from.
///
/// Named rather than written into the widgets because a menu is read as one
/// object: the rows, the head above them and the corner around all of them
/// line up only while they are laid out from the same numbers.
abstract final class ContextMenuUi {
  /// Stated rather than taken from the widest entry.
  ///
  /// A menu as wide as its contents is a different width for every row of a
  /// list it is opened from, and its width is the one thing about it that
  /// nobody is looking at and everybody would notice moving. What does not fit
  /// elides — see [ContextMenuRow], where the entry wins and its note gives.
  static const width = 260.0;

  /// Around the rows, inside the menu's own corner.
  static const pad = 5.0;

  /// A row, and what a row has to be for a finger.
  ///
  /// The smaller is the design's. The larger is the platform minimum, and this
  /// menu is opened by a long press as often as by a right-click.
  static const rowHeight = 34.0;
  static const touchRowHeight = 44.0;

  static const rowPad = 11.0;
  static const rowRadius = 9.0;

  /// Between a row's mark and its words.
  static const gap = 11.0;
  static const iconSize = 18.0;

  /// The most an entry's note may take at the other end of its row.
  ///
  /// A cap rather than a share, because the row is a different width in each
  /// of the three places this menu is drawn and the entry is what has to
  /// survive all three.
  static const noteWidth = 110.0;

  /// What the menu keeps clear of the window's own edges, on top of whatever
  /// the window says is already spent — a notch, a home indicator.
  static const edge = 8.0;

  /// How long it takes to arrive, and to go.
  static const duration = Durations.short3;
}

/// One entry, drawn.
///
/// Public because a menu is not only a popup: the same set of actions is a
/// sheet on a phone and a dialog where there is nowhere to hang a popup, and
/// an entry that looked like a different thing in each of them would be three
/// menus rather than one.
///
/// Wants a bounded width — see [ContextMenuUi.width].
class ContextMenuRow extends StatelessWidget {
  const ContextMenuRow({super.key, required this.action, required this.onTap});

  final ContextMenuAction action;

  /// Answering the menu, not running [ContextMenuAction.onTap].
  ///
  /// The menu has to be gone before an action that opens a dialog of its own
  /// runs, so what a row does is say which one was chosen.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = action.destructive ? UIs.textRed.color : null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(ContextMenuUi.rowRadius),
      child: ConstrainedBox(
        // A minimum rather than a height: a row is text, and the text is as
        // big as the reader has asked for it to be.
        constraints: BoxConstraints(
          minHeight: isMobile
              ? ContextMenuUi.touchRowHeight
              : ContextMenuUi.rowHeight,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: ContextMenuUi.rowPad,
            vertical: 5,
          ),
          child: Row(
            children: [
              if (action.icon case final icon?) ...[
                Icon(icon, size: ContextMenuUi.iconSize, color: color ?? Colors.grey),
                const SizedBox(width: ContextMenuUi.gap),
              ],
              Expanded(
                child: Text(
                  action.text,
                  style: TextStyle(fontSize: 13, height: 1.2, color: color),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (action.note case final note?) ...[
                const SizedBox(width: 9),
                // Capped rather than flexible: the entry is what has to
                // survive a narrow menu, and this is the half that gives.
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: ContextMenuUi.noteWidth,
                  ),
                  child: Text(
                    note,
                    style: UIs.text11Grey,
                    textAlign: TextAlign.end,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Shows [actions], in whichever of the three places there is room for them.
///
/// One menu, and that is the point of this being one function: the same
/// entries in the same order, drawn from the same [ContextMenuRow], wherever
/// they end up. Three surfaces that each rolled their own rows were three
/// menus that happened to list the same things.
///
/// - [at] is a global position — what `WidgetSecondaryX.onSecondary` hands
///   over. The menu hangs off it. This is the one that wins when given.
/// - [sheet] is for the window with nowhere to hang one: a single column under
///   a finger, where the middle of the screen is where the thing being acted
///   on is and the top half is out of a thumb's reach.
/// - Neither is a dialog in the middle, which is what a long press with
///   nothing to measure falls back to. [title] names it.
///
/// [header] says what the menu is about, inside it, for a caller whose own
/// shape is too small to have said so. Not an entry: nothing happens when it
/// is pressed, and the keyboard steps past it. The dialog has [title] instead
/// and ignores it.
Future<void> showContextMenu(
  BuildContext context,
  List<ContextMenuAction> actions, {
  String? title,
  Widget? header,
  Offset? at,
  bool sheet = false,
}) async {
  if (actions.isEmpty) return;

  // Branches rather than a switch expression over [at]: every arm of one is
  // written after the first arm's `await`, so the analyzer reads the later
  // ones as using a context across an async gap.
  final ContextMenuAction? chosen;
  if (at != null) {
    chosen = await _showAt(context, actions, at, header);
  } else if (sheet) {
    chosen = await _showSheet(context, actions, header);
  } else {
    chosen = await _showDialog(context, actions, title);
  }

  chosen?.onTap();
}

/// The menu as a sheet, for a phone.
///
/// The rows carry the menu's own inset on top of the sheet's, so an entry
/// starts where a `ListTile` in any other sheet in the app starts.
Future<ContextMenuAction?> _showSheet(
  BuildContext context,
  List<ContextMenuAction> actions,
  Widget? header,
) {
  return showRowsSheet<ContextMenuAction>(
    context,
    rows: (ctx) => [
      // A sheet is at the bottom of the window rather than beside what it is
      // about, so this is worth more here than in the popup — which is why a
      // caller is expected to give one.
      ?switch (header) {
        final header? => Padding(
          padding: const EdgeInsets.symmetric(horizontal: ContextMenuUi.pad),
          child: header,
        ),
        null => null,
      },
      for (final action in actions)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: ContextMenuUi.pad),
          child: ContextMenuRow(
            action: action,
            // Answered rather than run here: the sheet has to be gone before
            // an action that opens a dialog of its own runs, or the dialog
            // opens underneath it.
            onTap: () => Navigator.of(ctx).pop(action),
          ),
        ),
    ],
  );
}

/// The menu in the middle, for a long press with nothing to hang it off.
Future<ContextMenuAction?> _showDialog(
  BuildContext context,
  List<ContextMenuAction> actions,
  String? title,
) {
  return context.showRoundDialog<ContextMenuAction>(
    title: title,
    // Scrolls, because how many entries there are is the caller's to decide
    // and a dialog's height is the window's: a menu of everything that can
    // be done to a server is a column taller than a laptop screen, and a
    // `Column` past its box is an overflow rather than a scroll.
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final action in actions)
            ContextMenuRow(
              action: action,
              // Popped as a value rather than run here, and through
              // `popDialog` — the root navigator, which is where a dialog is.
              // `context.pop()` here closes the page under it.
              onTap: () => context.popDialog(action),
            ),
        ],
      ),
    ),
  );
}

Future<ContextMenuAction?> _showAt(
  BuildContext context,
  List<ContextMenuAction> actions,
  Offset at,
  Widget? header,
) {
  // The root navigator, and that is what makes [at] mean anything: it is in
  // the window's coordinates, and the root is the only navigator whose overlay
  // is the window. Pushed onto a pane's, the menu would be placed inside the
  // pane and clipped to it — and a menu is a thing over the whole app, which
  // is the same reason dialogs go here.
  return Navigator.of(context, rootNavigator: true).push(
    _ContextMenuRoute(
      actions: actions,
      header: header,
      at: at,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      // Not nothing: a menu that is simply there between two frames reads as
      // the page having changed rather than as something having opened.
      duration: MediaQuery.disableAnimationsOf(context)
          ? Durations.short2
          : ContextMenuUi.duration,
    ),
  );
}

/// The menu at a pointer, drawn here rather than by `showMenu`.
///
/// Material's own is a different object from the one this app is made of: its
/// own corner, its own 48pt rows with their own inset, its own width stepped
/// in multiples of 56 — so the one surface that opens beside a card was the
/// one surface that did not look like the card. What is kept from it is the
/// behaviour, which is a route: a barrier that dismisses, `Escape`, arrow keys
/// through the entries, and a result answered to whoever opened it.
class _ContextMenuRoute extends PopupRoute<ContextMenuAction> {
  _ContextMenuRoute({
    required this.actions,
    required this.header,
    required this.at,
    required this.barrierLabel,
    required this.duration,
  });

  final List<ContextMenuAction> actions;
  final Widget? header;

  /// Where the menu hangs from, in the window's coordinates.
  final Offset at;

  final Duration duration;

  @override
  final String barrierLabel;

  /// Nothing behind it is dimmed. A menu is about one row of what is under it,
  /// and the rest of the page is still what the row has to be read against —
  /// see the highlight the caller leaves on the row itself.
  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  Duration get transitionDuration => duration;

  @override
  Duration get reverseTransitionDuration => Durations.short2;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final scheme = Theme.of(context).colorScheme;
    // A theme's popup menu style is this menu's too: both are "a menu".
    final menuTheme = PopupMenuTheme.of(context);
    final menuShape = menuTheme.shape;
    return CustomSingleChildLayout(
      delegate: _ContextMenuLayout(at: at, padding: MediaQuery.paddingOf(context)),
      child: Material(
        color: menuTheme.color ?? scheme.surfaceContainerHigh,
        // The tint is off: the colour above is the one the design names, and
        // Material would mix elevation's own into it. What elevation is for
        // here is the shadow that lifts the menu off the row it is about.
        surfaceTintColor: Colors.transparent,
        elevation: menuTheme.elevation ?? 3,
        shape: menuShape ??
            const RoundedRectangleBorder(borderRadius: CardX.borderRadius),
        clipBehavior: Clip.antiAlias,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(ContextMenuUi.pad),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ?header,
              for (final action in actions)
                ContextMenuRow(
                  action: action,
                  // This context is inside the menu's own route, so this is
                  // the menu closing and not the page under it.
                  onTap: () => Navigator.of(context).pop(action),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // `drive` rather than a `CurvedAnimation`, which owns resources and would
    // be built and dropped on every frame of the transition.
    return FadeTransition(
      opacity: animation.drive(CurveTween(curve: Curves.easeOutCubic)),
      child: ScaleTransition(
        // Barely a movement: enough that the menu reads as having come out of
        // the corner it is anchored at, and not so much that it travels.
        scale: animation.drive(
          Tween(begin: 0.96, end: 1.0).chain(
            CurveTween(curve: Curves.easeOutCubic),
          ),
        ),
        alignment: Alignment.topLeft,
        child: child,
      ),
    );
  }
}

/// Where the menu lands: at the pointer, pushed back inside the window.
///
/// Pushed rather than flipped. The anchor is the bottom left of whatever was
/// pressed, so a menu that flipped to sit above it would cover that row — and
/// near the bottom of a window, where the flip is what would happen, the row
/// being acted on is exactly the one worth keeping visible.
class _ContextMenuLayout extends SingleChildLayoutDelegate {
  const _ContextMenuLayout({required this.at, required this.padding});

  final Offset at;

  /// What the window itself has already spent: a notch, a home indicator.
  final EdgeInsets padding;

  EdgeInsets get _clear => padding + const EdgeInsets.all(ContextMenuUi.edge);

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final free = constraints.deflate(_clear);
    return BoxConstraints(
      maxWidth: math.min(ContextMenuUi.width, free.maxWidth),
      maxHeight: free.maxHeight,
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final clear = _clear;
    final left = clear.left;
    final top = clear.top;
    // `max` against the near edge, for the window too small to hold the menu
    // at all: without it the far edge is the smaller of the two and `clamp`
    // throws rather than laying anything out.
    final right = math.max(left, size.width - clear.right - childSize.width);
    final bottom = math.max(top, size.height - clear.bottom - childSize.height);
    return Offset(at.dx.clamp(left, right), at.dy.clamp(top, bottom));
  }

  @override
  bool shouldRelayout(_ContextMenuLayout old) =>
      old.at != at || old.padding != padding;
}

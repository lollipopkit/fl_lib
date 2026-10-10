import 'package:fl_lib/fl_lib.dart';
import 'package:material_ui/material_ui.dart';

/// One button of a [SwitcherBar].
sealed class BarAction {
  const factory BarAction({
    Key? key,
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    Color? color,
    bool destructive,
    bool loading,
    int? badge,
  }) = _TapAction;

  /// A button that opens a menu under itself — a choice with several values,
  /// such as a zoom level, that would be several buttons otherwise.
  const factory BarAction.menu({
    Key? key,
    required IconData icon,
    required String label,
    required List<ContextMenuAction> Function() menu,
    Color? color,
  }) = _MenuAction;

  /// A button drawn from state the bar is not rebuilt for: [build] is asked
  /// again whenever [listenable] fires, and when the overflow menu opens.
  /// Null shows nothing. Nests, for state that is itself behind a listenable.
  const factory BarAction.listen({
    Key? key,
    required Listenable listenable,
    required BarAction? Function(BuildContext context) build,
  }) = _ListenAction;

  Key? get key;

  /// The button on its own, for a bar that is not a [SwitcherBar] — the
  /// title bar of a pane beside a list, say — so a page lists its actions
  /// once for every layout.
  Widget button();

  /// Its row in the bar's overflow menu, which [anchor] is the button of;
  /// null for none.
  ContextMenuAction? _item(BuildContext anchor);
}

final class _TapAction implements BarAction {
  const _TapAction({
    this.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
    this.destructive = false,
    this.loading = false,
    this.badge,
  });

  @override
  final Key? key;
  final IconData icon;

  /// Its tooltip in the bar, its text in the menu.
  final String label;

  /// Null draws the button dimmed and refuses the tap.
  final VoidCallback? onTap;

  /// A toggle that is on.
  final Color? color;

  /// Destroys something: drawn in the error colour, and so is its row.
  final bool destructive;

  /// A spinner in place of the icon, and no tap: for a refresh that is
  /// running, which is said where it was asked for rather than by a line
  /// somewhere else on the page.
  final bool loading;

  /// A count on the icon's corner.
  final int? badge;

  bool get _enabled => !loading && onTap != null;

  static const _spinner = SizedBox.square(
    dimension: 18,
    child: Padding(
      padding: EdgeInsets.all(1.5),
      child: CircularProgressIndicator(strokeWidth: 2),
    ),
  );

  @override
  Widget button() {
    if (loading) {
      // The slot a button takes, so the bar does not shift.
      return Tooltip(
        key: key,
        message: label,
        child: const Padding(padding: EdgeInsets.all(7), child: _spinner),
      );
    }
    return Builder(
      key: key,
      builder: (context) => Btn.icon(
        text: label,
        icon: _glyph(context, icon, badge, color, destructive, _enabled),
        onTap: onTap,
      ),
    );
  }

  @override
  ContextMenuAction _item(BuildContext anchor) => ContextMenuAction(
    text: label,
    icon: icon,
    enabled: _enabled,
    destructive: destructive,
    onTap: onTap ?? () {},
  );
}

final class _MenuAction implements BarAction {
  const _MenuAction({
    this.key,
    required this.icon,
    required this.label,
    required this.menu,
    this.color,
  });

  @override
  final Key? key;
  final IconData icon;
  final String label;
  final List<ContextMenuAction> Function() menu;
  final Color? color;

  void _open(BuildContext anchor) => showContextMenu(
    anchor,
    menu(),
    at: contextMenuAnchorBelow(anchor),
  );

  @override
  Widget button() => Builder(
    key: key,
    builder: (context) => Btn.icon(
      text: label,
      icon: _glyph(context, icon, null, color, false, true),
      onTap: () => _open(context),
    ),
  );

  /// Its own menu opens from where the overflow menu was.
  @override
  ContextMenuAction _item(BuildContext anchor) =>
      ContextMenuAction(text: label, icon: icon, onTap: () => _open(anchor));
}

final class _ListenAction implements BarAction {
  const _ListenAction({
    this.key,
    required this.listenable,
    required this.build,
  });

  @override
  final Key? key;
  final Listenable listenable;
  final BarAction? Function(BuildContext context) build;

  @override
  Widget button() => ListenableBuilder(
    key: key,
    listenable: listenable,
    builder: (context, _) => build(context)?.button() ?? UIs.placeholder,
  );

  @override
  ContextMenuAction? _item(BuildContext anchor) =>
      build(anchor)?._item(anchor);
}

Widget _glyph(
  BuildContext context,
  IconData icon,
  int? badge,
  Color? color,
  bool destructive,
  bool enabled,
) {
  final scheme = Theme.of(context).colorScheme;
  final glyph = Icon(
    icon,
    size: 18,
    // `Btn.icon` has no disabled look of its own: a null `onTap` only stops
    // the ink.
    color: !enabled
        ? scheme.onSurface.withValues(alpha: 0.38)
        : destructive
        ? scheme.error
        : color,
  );
  return badge == null ? glyph : Badge.count(count: badge, child: glyph);
}

/// The line at the top of a tab in a single column: what is on screen and the
/// way to the rest of the set on the left, what can be done to it on the
/// right.
///
/// Every tab's narrow bar is this, so they are one line down the app: the same
/// height, the same switcher, the same 18pt buttons, the same gap at the end.
/// A window wide enough for two panes gives each tab a layout of its own and
/// does not use this.
///
/// The buttons get what the switcher leaves past [switcherMinWidth], as many
/// as fit; the rest are rows of a menu behind a last button, after [menu]. So
/// a narrow phone shows what the bar is about and still reaches every action,
/// rather than a name squeezed past its chevron into an overflow.
///
/// Keeps clear of the window's own controls and of the insets it is laid out
/// under, so a page pushed outside a tab's `SafeArea` needs nothing more.
final class SwitcherBar extends StatelessWidget implements PreferredSizeWidget {
  const SwitcherBar({
    super.key,
    this.leading,
    required this.switcher,
    this.actions = const [],
    this.menu,
    this.menuLabel,
    this.menuKey,
    this.search,
    this.searchHint,
    this.switcherMinWidth = 104,
  });

  /// Before the switcher: the way out of a detail, or of a selection.
  final Widget? leading;

  /// Usually a [SessionSwitcherLabel].
  final Widget switcher;

  final List<BarAction> actions;

  /// Rows that always live behind the last button, before any action that did
  /// not fit.
  final List<ContextMenuAction> Function()? menu;

  /// The overflow button's tooltip; [LibLocalizations.more] by default.
  final String? menuLabel;

  /// On the overflow button, for something that points at it.
  final Key? menuKey;

  /// Replaces the whole line with a search field while it is searching — see
  /// [InlineSearchBar].
  final InlineSearchController? search;
  final String? searchHint;

  /// Enough for a [SessionSwitcherLabel]'s counter, chevron and a few letters
  /// of its name.
  final double switcherMinWidth;

  /// Tall enough for a 32pt icon button with room around it, and no taller.
  /// Every point here is a row of terminal output.
  static const height = 40.0;

  /// A `Btn.icon` of an 18pt icon: the icon and 7 of padding each side.
  static const slot = 18.0 + 7 * 2;

  /// The way back out of a detail, in the place a [leading] goes.
  ///
  /// Inset to where the switcher's own glyph sits when there is nothing open,
  /// so the first thing in the bar is in the same place either way.
  static Widget back({required VoidCallback onTap, String? tooltip}) => Padding(
    padding: const EdgeInsets.only(left: 7),
    child: Btn.icon(
      text: tooltip ?? libL10n.close,
      icon: const Icon(Icons.arrow_back_ios_new, size: 17),
      onTap: onTap,
    ),
  );

  @override
  Size get preferredSize => const Size.fromHeight(height);

  @override
  Widget build(BuildContext context) {
    Widget line = Row(
      children: [
        ?leading,
        Expanded(child: LayoutBuilder(builder: _buildFolding)),
        const SizedBox(width: 7),
      ],
    );
    final search = this.search;
    if (search != null) {
      line = InlineSearchBar(controller: search, hint: searchHint, child: line);
    }
    return WindowControlsInset(
      safeArea: true,
      child: SizedBox(height: height, child: line),
    );
  }

  Widget _buildFolding(BuildContext context, BoxConstraints constraints) {
    final menu = this.menu;
    final room = constraints.maxWidth - switcherMinWidth;
    final fits = room.isFinite ? (room / slot).floor() : actions.length;
    // The menu button takes one of the slots whenever there is a menu.
    final hasMenu = menu != null || fits < actions.length;
    final roomForActions = hasMenu ? fits - 1 : fits;
    final shown = actions.take(roomForActions.clamp(0, actions.length));
    final folded = actions.skip(shown.length).toList();
    return Row(
      children: [
        Expanded(child: switcher),
        for (final a in shown) a.button(),
        if (hasMenu)
          Builder(
            key: menuKey,
            builder: (anchor) => ContextMenuButton(
              tooltip: menuLabel ?? libL10n.more,
              actions: () => [
                ...?menu?.call(),
                for (final a in folded) ?a._item(anchor),
              ],
              child: const Padding(
                padding: EdgeInsets.all(7),
                child: Icon(Icons.more_vert, size: 18),
              ),
            ),
          ),
      ],
    );
  }
}

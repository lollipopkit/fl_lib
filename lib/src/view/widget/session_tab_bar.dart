import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';
import 'package:icons_plus/icons_plus.dart';

/// What a session's row says under its name, or null for a one-line row.
typedef SessionDetailOf = String? Function(int index);

/// The line above a [SessionTabsView], naming the session on screen.
///
/// Not a strip of tabs, which is what this was. A phone gave each tab a fixed
/// 60–90pt — about six characters once the close button and the insets had
/// taken their share — so `prod-db-01` and `prod-db-02` drew identically, and
/// a third session already overflowed a row that spent 43% of its width on a
/// leading button, three dividers and the actions. It looked like an overview
/// and carried almost nothing.
///
/// So this says how many there are, which one is on screen, and its whole
/// name. Everything else moves into a sheet, where a row is wide enough to
/// also say *where* the session is, and where closing one is that row's own
/// button rather than a 24pt target wedged against the tab beside it.
///
/// Takes a snapshot — the names and the selected index — rather than the
/// controller. The page above it already listens for changes, and two widgets
/// watching one piece of state is how they end up disagreeing about it. The
/// sheet is closed before anything acts on what was picked, for the same
/// reason: closing a session renumbers the rest of the list it drew.
final class SessionTabBar extends StatelessWidget implements PreferredSizeWidget {
  const SessionTabBar({
    super.key,
    required this.names,
    required this.index,
    required this.onTap,
    required this.onClose,
    required this.sessionActions,
    required this.leadingActions,
    this.leadingIcon = MingCute.add_circle_fill,
    this.detailOf,
  });

  /// Tab labels, the leading tab's included at index 0.
  final List<String> names;

  final int index;
  final void Function(int index) onTap;

  /// By position, not by label: the bar renders a snapshot, and a position is
  /// what it actually drew. Which session that is stays the page's business.
  final void Function(int index) onClose;

  /// Shown while a session is open.
  final List<Widget> sessionActions;

  /// Shown while the leading tab is open.
  final List<Widget> leadingActions;

  /// What the leading tab shows instead of a label.
  final IconData leadingIcon;

  /// Where a session is, for its row in the sheet — an address, a path. The
  /// name says which one it is and this says which thing it is on, which is
  /// the pair a strip of six-character tabs could never carry.
  final SessionDetailOf? detailOf;

  /// Tall enough for a 32pt icon button with room around it, and no taller.
  /// Every point here is a row of terminal output.
  ///
  /// Public because this is usually wrapped in something that rebuilds it, and
  /// the `Scaffold` measures the wrapper — which is built before this is and so
  /// cannot ask it. A wrapper left on its own default gave the old strip 56pt
  /// for its 48, and would give this one 56 for its 40.
  static const height = 40.0;

  @override
  Size get preferredSize => Size.fromHeight(_bare ? 0 : height);

  bool get _onLeading => index == 0;

  /// Whether anything is open. With nothing open there is nowhere to switch
  /// to, so the name is a label rather than a way into the sheet.
  bool get _anyTabs => names.length > 1;

  List<Widget> get _actions => _onLeading ? leadingActions : sessionActions;

  /// A line with nothing to switch between and no buttons on it is a row of
  /// height above a page for no reason.
  bool get _bare => !_anyTabs && _actions.isEmpty;

  @override
  Widget build(BuildContext context) {
    if (_bare) return const SizedBox.shrink();

    return SizedBox(
      height: height,
      child: Row(
        children: [
          Expanded(child: _buildSwitcher(context)),
          for (final action in _actions) ...[action, const SizedBox(width: 7)],
        ],
      ),
    );
  }

  /// The name, what it is one of, and the way to the rest.
  Widget _buildSwitcher(BuildContext context) {
    return SessionSwitcherLabel(
      name: index >= 0 && index < names.length ? names[index] : '',
      // Sessions, so the leading tab is not one of them: "2/4" counts
      // terminals, not pages.
      total: names.length - 1,
      position: _onLeading ? null : index,
      icon: leadingIcon,
      onTap: _anyTabs ? () => _showSheet(context) : null,
    );
  }

  Future<void> _showSheet(BuildContext context) async {
    final picked = await showModalBottomSheet<({int index, bool close})>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      builder: (_) => _SessionSheet(
        names: names,
        index: index,
        leadingIcon: leadingIcon,
        detailOf: detailOf,
      ),
    );
    if (picked == null) return;
    // Acted on once the sheet is gone. It drew a snapshot of the names, and
    // closing a session renumbers everything after it — which is also why the
    // page, not the sheet, is what asks whether to close.
    if (picked.close) return onClose(picked.index);
    if (picked.index != index) onTap(picked.index);
  }
}

/// Which one of how many, its name, and the way to the rest.
///
/// The switcher half of [SessionTabBar], on its own because the Agent tab has
/// the same shape of problem — one conversation on screen and the others a tap
/// away — but its own list to open, with renaming and clearing on it, rather
/// than this file's sheet. Sharing the label is what keeps the three tabs one
/// weight; sharing the sheet would have meant growing it a menu for one caller.
final class SessionSwitcherLabel extends StatelessWidget {
  const SessionSwitcherLabel({
    super.key,
    required this.name,
    this.position,
    this.total = 0,
    this.icon,
    this.onTap,
  });

  final String name;

  /// Which one this is, counting from 1. Null shows [icon] instead — for a
  /// page that is not one of the set, such as the picker at its head.
  final int? position;

  final int total;

  final IconData? icon;

  /// Null makes this a label rather than a way anywhere: no chevron, no ink.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final position_ = position;
    final icon_ = icon;

    final label = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (position_ == null) ...[
          if (icon_ != null)
            Icon(icon_, size: _iconSize, color: scheme.onSurfaceVariant),
        ]
        // One of anything is not a set, and "1/1" is a fact nobody needed.
        else if (total > 1)
          _SessionCounter(position: position_, total: total),
        const SizedBox(width: 7),
        Flexible(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            softWrap: false,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
          ),
        ),
        if (onTap != null)
          Icon(Icons.expand_more, size: 18, color: scheme.onSurfaceVariant),
      ],
    );

    const padding = EdgeInsets.fromLTRB(9, 5, 5, 5);
    final onTap_ = onTap;
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Padding(
        padding: const EdgeInsets.only(left: 5),
        child: onTap_ == null
            ? Padding(padding: padding, child: label)
            : _SessionTabInk(
                onTap: onTap_,
                child: Padding(padding: padding, child: label),
              ),
      ),
    );
  }
}

/// Which session this is, of how many.
///
/// Tabular figures so that going from 9 to 10 does not nudge the name beside
/// it, and the total in a lighter weight so the pair reads as one fact rather
/// than as two numbers.
final class _SessionCounter extends StatelessWidget {
  const _SessionCounter({required this.position, required this.total});

  final int position;
  final int total;

  static const _figures = TextStyle(
    fontSize: 12,
    height: 1,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$position',
              style: _figures.copyWith(
                color: scheme.onSecondaryContainer,
                fontWeight: FontWeight.w700,
              ),
            ),
            TextSpan(
              text: '/$total',
              style: _figures.copyWith(
                color: scheme.onSecondaryContainer.withValues(alpha: 0.55),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Every session at once, which is what the line above cannot be.
///
/// Numbered down the leading edge in the same figures the counter uses, so the
/// sheet reads as that counter opened out rather than as a menu of its own.
final class _SessionSheet extends StatelessWidget {
  const _SessionSheet({
    required this.names,
    required this.index,
    required this.leadingIcon,
    required this.detailOf,
  });

  final List<String> names;
  final int index;
  final IconData leadingIcon;
  final SessionDetailOf? detailOf;

  @override
  Widget build(BuildContext context) {
    void pick(int at, {bool close = false}) =>
        Navigator.of(context).pop((index: at, close: close));

    return SafeArea(
      top: false,
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: 8),
        children: [
          for (var i = 1; i < names.length; i++)
            _SessionRow(
              position: i,
              name: names[i],
              detail: detailOf?.call(i),
              selected: i == index,
              onTap: () => pick(i),
              onClose: () => pick(i, close: true),
            ),
          const Divider(height: 17, indent: 17, endIndent: 17),
          // Last, because it is what to do when none of the above is what you
          // wanted — and because a list of open sessions should open on the
          // sessions.
          ListTile(
            leading: SizedBox(
              width: _numberWidth,
              child: Center(child: Icon(leadingIcon, size: _iconSize)),
            ),
            title: Text(names.first),
            onTap: () => pick(0),
          ),
        ],
      ),
    );
  }
}

final class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.position,
    required this.name,
    required this.detail,
    required this.selected,
    required this.onTap,
    required this.onClose,
  });

  final int position;
  final String name;
  final String? detail;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final detail_ = detail;
    return ListTile(
      selected: selected,
      leading: SizedBox(
        width: _numberWidth,
        child: Text(
          '$position',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            fontFeatures: const [FontFeature.tabularFigures()],
            fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
            color: selected ? scheme.primary : scheme.onSurfaceVariant,
          ),
        ),
      ),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: detail_ == null
          ? null
          : Text(
              detail_,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: UIs.textGrey,
            ),
      trailing: IconButton(
        icon: const Icon(MingCute.close_line, size: _iconSize),
        color: scheme.onSurfaceVariant,
        tooltip: libL10n.close,
        onPressed: onClose,
      ),
      onTap: onTap,
    );
  }
}

/// One size for every icon on the line and in the sheet, so the leading tab's
/// own icon and a row's close button do not read as two different weights.
const _iconSize = 17.0;

/// The numbered column down the sheet's leading edge. Wide enough for three
/// figures, which is more sessions than anyone will open.
const _numberWidth = 26.0;

class _SessionTabInk extends StatelessWidget {
  const _SessionTabInk({required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  static final _radius = BorderRadius.circular(11);

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: _radius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(borderRadius: _radius, onTap: onTap, child: child),
    );
  }
}

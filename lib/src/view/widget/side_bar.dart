import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';
import 'package:icons_plus/icons_plus.dart';

/// The rail beside a [SessionTabsView]: what is running, above what can be
/// started.
///
/// Two kinds of row that read alike and mean opposite things. A name under
/// [SessionSideBar] is a session with scrollback behind it and possibly a
/// command still going; the same name further down is a machine nobody has
/// connected to yet. Tapping one goes there, tapping the other starts
/// something. A section heading alone does not carry that distinction at the
/// speed people scan a rail, so the running ones are marked on the leading
/// edge — see [SideBarTile.live].
///
/// Takes a snapshot rather than the controller, like [SessionTabBar], for the
/// same reason: two widgets watching one piece of state is how they end up
/// disagreeing about it.
final class SessionSideBar extends StatelessWidget {
  const SessionSideBar({
    super.key,
    required this.names,
    required this.index,
    required this.onTap,
    required this.onClose,
    required this.targets,
    this.actions = const [],
    this.runningLabel,
  });

  /// Tab labels, the leading page's included at index 0 and ignored here —
  /// this rail *is* that page.
  final List<String> names;

  final int index;
  final void Function(int index) onTap;

  /// By position, not by label: the rail renders a snapshot, and a position is
  /// what it actually drew.
  final void Function(int index) onClose;

  /// What can be opened. Composed by the caller, so it can group its own
  /// entries — see [SideBarSection] and [SideBarTile].
  final List<Widget> targets;

  /// A row of buttons above everything, for what acts on the rail as a whole:
  /// sorting it, searching it, adding to it.
  final List<Widget> actions;

  /// Heading over the running sessions. Defaults to [LibLocalizations.running].
  final String? runningLabel;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 12),
      children: [
        if (actions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                for (final action in actions) ...[
                  action,
                  const SizedBox(width: 4),
                ],
              ],
            ),
          ),
        if (names.length > 1) ...[
          SideBarSection(runningLabel ?? libL10n.running),
          for (var i = 1; i < names.length; i++)
            SideBarTile(
              title: names[i],
              selected: index == i,
              live: true,
              onTap: () => onTap(i),
              trailing: _CloseButton(onTap: () => onClose(i)),
            ),
        ],
        ...targets,
      ],
    );
  }
}

/// A heading over one group of rail entries.
///
/// The rule after the label runs to the edge because the group does: it says
/// where one ends, which is the only thing a heading in a rail this narrow has
/// to say.
final class SideBarSection extends StatelessWidget {
  const SideBarSection(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 14, 6),
      child: Row(
        children: [
          // Allowed to give way. Its callers pass a single word — "RUNNING",
          // "BROWSING" — but a heading in a rail this narrow that is sized to
          // its own text takes the rule's width and then runs past the column;
          // a longer label in another language does it in a rail that was fine
          // in English.
          Flexible(
            child: Text(
              label.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Divider(
              height: Hairline.thickness,
              thickness: Hairline.thickness,
              color: Hairline.color(context),
            ),
          ),
        ],
      ),
    );
  }
}

/// One entry in a side rail.
///
/// A name and nothing else. There was an address under each one; at two lines
/// a row the rail stopped being something you could take in at a glance, and
/// what it said is on the page beside it anyway.
final class SideBarTile extends StatelessWidget {
  const SideBarTile({
    super.key,
    required this.title,
    this.selected = false,
    this.live = false,
    this.icon,
    this.leading,
    this.trailing,
    this.onTap,
    this.onLongPress,
  });

  final String title;

  /// Drawn before the title, at the size of the row's text.
  ///
  /// For a rail whose entries are kinds of thing rather than instances of one:
  /// a list of servers reads faster without the same icon down the side of it,
  /// while a list of subjects is quicker to find your place in with them.
  final IconData? icon;

  /// Drawn where [icon] would be, for a mark that is not one of Material's.
  ///
  /// Sized and coloured by the caller, since whatever goes here is the
  /// caller's own — this only reserves the column and the gap after it, so a
  /// rail mixing the two keeps one edge for its names to start from. [icon]
  /// wins if both are given.
  final Widget? leading;

  /// Whether this is the entry being shown.
  final bool selected;

  /// Whether there is a session behind this entry.
  ///
  /// Drawn as a short bar on the leading edge, the shape of a terminal cursor,
  /// which is what marks a live line everywhere else in this app's subject.
  /// The bar takes the accent colour on [selected] and a neutral one
  /// otherwise, so "which of these is running" and "which one am I looking at"
  /// are one glance rather than two.
  final bool live;

  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // Right-click reaches whatever the long press does — see
    // `WidgetSecondaryX`, which is where the reasoning lives.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: _kTileRadius,
          onTap: onTap,
          onLongPress: onLongPress,
          child: AnimatedContainer(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : Durations.short3,
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              borderRadius: _kTileRadius,
              color: selected
                  // Soft, because this marks where you are and not what you
                  // just picked out of a list.
                  ? scheme.secondaryContainer.withValues(alpha: 0.55)
                  : null,
            ),
            padding: const EdgeInsets.fromLTRB(6, 8, 6, 8),
            child: Row(
              children: [
                // Kept whether or not there is a bar in it, so a name means the
                // same distance from the edge in every row and the eye has one
                // column to run down.
                SizedBox(
                  width: 11,
                  child: live
                      ? Center(
                          child: Container(
                            width: 3,
                            height: 16,
                            decoration: BoxDecoration(
                              color: selected
                                  ? scheme.primary
                                  : scheme.outlineVariant,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        )
                      : null,
                ),
                if (icon != null) ...[
                  Icon(
                    icon,
                    size: 17,
                    color: selected ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 9),
                ] else if (leading != null) ...[
                  SizedBox(width: 17, height: 17, child: leading),
                  const SizedBox(width: 9),
                ],
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.2,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
                if (trailing != null)
                  // A Material control sizes itself to a 48pt tap target
                  // whatever its own constraints say, and that is taller than
                  // this row's text — so a row carrying one came out 58pt
                  // against 35pt, and a name grew by two thirds the moment a
                  // session opened behind it and gave it a close button. The
                  // row owns its height, so the override belongs here rather
                  // than in each caller's trailing widget.
                  Theme(
                    data: Theme.of(context).copyWith(
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: trailing!,
                  ),
              ],
            ),
          ),
        ),
      ),
    ).onSecondary(asSecondary(onLongPress));
  }
}

final _kTileRadius = BorderRadius.circular(9);

class _CloseButton extends StatelessWidget {
  const _CloseButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(MingCute.close_circle_fill, size: 15),
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 26, height: 26),
      visualDensity: VisualDensity.compact,
      onPressed: onTap,
    );
  }
}

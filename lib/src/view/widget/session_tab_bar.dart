import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';
import 'package:icons_plus/icons_plus.dart';
import 'package:responsive_framework/responsive_framework.dart';

/// The strip of tabs above a [SessionTabsView], with the leading tab at its
/// head.
///
/// Takes a snapshot — the names and the selected index — rather than the
/// controller. The page above it already listens for changes, and two widgets
/// watching one piece of state is how they end up disagreeing about it.
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

  @override
  Size get preferredSize => Size.fromHeight(_bare ? 0 : 48);

  bool get _onLeading => index == 0;

  /// Whether anything is open. With nothing open there is nowhere to switch
  /// to, so the leading tab would only select the page already on screen.
  bool get _anyTabs => names.length > 1;

  List<Widget> get _actions => _onLeading ? leadingActions : sessionActions;

  /// A strip with no tabs to switch between and no buttons on it is a row of
  /// height above a page for no reason.
  bool get _bare => !_anyTabs && _actions.isEmpty;

  @override
  Widget build(BuildContext context) {
    if (_bare) return const SizedBox.shrink();

    final actions = _actions;
    return Row(
      children: [
        if (_anyTabs) ...[
          _LeadingTabButton(
            selected: _onLeading,
            leadingIcon: leadingIcon,
            onTap: () => onTap(0),
          ),
          const _SessionTabDivider(),
        ],
        Expanded(
          child: ClipRect(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
              itemCount: names.length - 1,
              separatorBuilder: (_, _) => const _SessionTabDivider(),
              itemBuilder: (context, i) {
                // The list skips the add button, so its own index is one
                // behind the tab index everything else uses.
                final tabIndex = i + 1;
                return _SessionTabItem(
                  name: names[tabIndex],
                  selected: index == tabIndex,
                  onTap: () => onTap(tabIndex),
                  onClose: () => onClose(tabIndex),
                );
              },
            ),
          ),
        ),
        if (actions.isNotEmpty) ...[
          const _SessionTabDivider(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final action in actions) ...[action, const SizedBox(width: 7)],
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _SessionTabDivider extends StatelessWidget {
  const _SessionTabDivider();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 17),
      child: Container(
        color: Theme.of(context).dividerColor.withAlpha(61),
        width: 3,
      ),
    );
  }
}

class _LeadingTabButton extends StatelessWidget {
  const _LeadingTabButton({
    required this.selected,
    required this.onTap,
    required this.leadingIcon,
  });

  final bool selected;
  final VoidCallback onTap;
  final IconData leadingIcon;

  @override
  Widget build(BuildContext context) {
    return _SessionTabInk(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Icon(
          leadingIcon,
          size: _iconSize,
          color: selected ? null : Colors.grey,
        ),
      ),
    );
  }
}

class _SessionTabItem extends StatelessWidget {
  const _SessionTabItem({
    required this.name,
    required this.selected,
    required this.onTap,
    required this.onClose,
  });

  final String name;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final isMobile = ResponsiveBreakpoints.of(context).isMobile;
    final text = Text(
      name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      softWrap: false,
      textAlign: TextAlign.center,
      style: TextStyle(color: selected ? null : Colors.grey),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 7),
      child: _SessionTabInk(
        onTap: onTap,
        child: AnimatedContainer(
          // The close button only appears on the current tab, so the tab has
          // to make room for it as it becomes current.
          width: switch ((selected, isMobile)) {
            (true, true) => 90,
            (true, false) => 130,
            (false, true) => 60,
            (false, false) => 90,
          },
          duration: Durations.medium3,
          curve: Curves.fastEaseInToSlowEaseOut,
          // The button and the name are centred together, as one group. The
          // button is not pinned to an edge, so a short name does not sit an
          // empty gap away from the button that closes it.
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: _labelInset),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (selected) ...[
                  IconButton(
                    icon: const Icon(MingCute.close_circle_fill, size: _iconSize),
                    color: Colors.grey,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: _closeWidth,
                      height: _closeWidth,
                    ),
                    visualDensity: VisualDensity.compact,
                    onPressed: onClose,
                  ),
                  const SizedBox(width: 2),
                ],
                // Flexible, not Expanded: a name shorter than the tab takes
                // only the width it needs, which is what leaves the group
                // centred. A longer one still gives way and is cut.
                Flexible(child: text),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The close button's tap target on the current tab.
const _closeWidth = 24.0;

/// One size for every icon in the bar, so the close button on a tab and the
/// leading tab's own icon do not read as two different weights of the same row.
const _iconSize = 17.0;

/// Breathing room between a tab's contents and its edge.
const _labelInset = 4.0;

class _SessionTabInk extends StatelessWidget {
  const _SessionTabInk({required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  static final _radius = BorderRadius.circular(13);

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

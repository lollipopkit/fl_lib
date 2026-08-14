import 'package:fl_lib/src/res/ui.dart';
import 'package:fl_lib/src/view/widget/card.dart';
import 'package:flutter/material.dart';

/// One thing in a full-width list: what it is, what it says about itself, and
/// that opening it goes somewhere.
///
/// The counterpart to [SideBarTile], which is the same entry once the list has
/// been squeezed into a column beside something else. A rail has room for a
/// name and nothing more; at full width the line underneath is what makes a
/// list of names worth scrolling, and the chevron is what promises that
/// tapping opens rather than selects.
class CardTile extends StatelessWidget {
  const CardTile({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.trailing = const Icon(Icons.chevron_right),
    this.onTap,
    this.onLongPress,
  });

  final String title;

  /// A line about it — an address, a path, the first of a script. Absent
  /// leaves the row one line tall rather than leaving a gap.
  final String? subtitle;

  /// What kind of thing this is. Absent indents the title to the edge, for a
  /// list whose entries are all the same kind and so say nothing by having an
  /// icon.
  final IconData? icon;

  /// Defaults to the chevron. Pass null for a row that opens nothing, or a
  /// widget of your own for one that also acts.
  final Widget? trailing;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return CardX(
      child: ListTile(
        leading: icon == null ? null : Icon(icon),
        title: Text(
          title,
          style: UIs.text18,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: subtitle == null
            ? null
            : Text(
                subtitle!,
                style: UIs.text12Grey,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
        trailing: trailing,
        onTap: onTap,
        onLongPress: onLongPress,
      ),
    );
  }
}

import 'package:fl_lib/src/res/ui.dart';
import 'package:fl_lib/src/view/widget/card.dart';
import 'package:flutter/material.dart';

/// A header tile that reveals a group of tiles *below* it.
///
/// The counterpart to [ExpandTile], which is an `ExpansionTile` and therefore
/// draws its children inside itself. That shape fights a form whose every row
/// is its own card: wrapping the tile in a [CardX] puts the children inside
/// the header's card, and not wrapping it leaves the header the one row on the
/// page with no card at all. Here the header is one card and each child is a
/// card beside it, so opening a group adds rows rather than growing a box.
///
/// What ties the rows to the header is then [expandedColor] alone, which is
/// why it defaults to a colour the surrounding cards do not use — and why it
/// applies only while the group is open. Closed, the header is one more row of
/// a list and has nothing to be tied to.
class ExpandableTile extends StatefulWidget {
  const ExpandableTile({
    super.key,
    required this.title,
    required this.children,
    this.leading,
    this.summary,
    this.initiallyExpanded = false,
    this.maintainState = false,
    this.expandedColor,
    this.padding = const EdgeInsets.all(13),
    this.onExpansionChanged,
  });

  /// What the group is.
  final Widget title;

  /// What the group currently amounts to, at the end of the header's line.
  ///
  /// Shown only while the group is closed. Open, the rows below say it in
  /// full, and a summary repeating them is a second answer to a question
  /// already on screen.
  final Widget? summary;

  final Widget? leading;

  /// Revealed below the header, as siblings of it.
  final List<Widget> children;

  final bool initiallyExpanded;

  /// Whether [children] are built while the group is closed.
  ///
  /// False, as `ExpansionTile`'s is, and for the same reason: a group is
  /// closed most of the time, and building what is inside it costs whatever
  /// its rows cost to build — a provider watched, a store read, a request
  /// made. A form of six of these built all six on the way to showing none.
  ///
  /// Nothing that belongs to the page is lost by it. A field's text lives in
  /// the controller the page holds, not in the widget, so a group folded
  /// mid-edit comes back with what was typed in it.
  final bool maintainState;

  /// The header's background **while it is open**, closed being the card
  /// colour like every other row.
  ///
  /// Defaults to [ColorScheme.surfaceContainerHigh]: once the group is open
  /// the header is the only thing saying which of the rows below belong to it,
  /// and a header that looks like its own children says nothing.
  final Color? expandedColor;

  /// Inside the header. Not applied to [children], which bring their own.
  final EdgeInsetsGeometry padding;

  final ValueChanged<bool>? onExpansionChanged;

  @override
  State<ExpandableTile> createState() => _ExpandableTileState();
}

class _ExpandableTileState extends State<ExpandableTile>
    with SingleTickerProviderStateMixin {
  static const _duration = Duration(milliseconds: 200);

  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: _duration,
    value: widget.initiallyExpanded ? 1 : 0,
  )..addStatusListener((_) {
    // The one thing a status change decides is [_closed], and that is read
    // during build.
    if (mounted) setState(() {});
  });

  late final CurvedAnimation _curve = CurvedAnimation(
    parent: _ctrl,
    curve: Curves.easeInOut,
  );

  late final Animation<double> _turns = _curve.drive(
    Tween(begin: 0.0, end: 0.5),
  );

  late bool _expanded = widget.initiallyExpanded;

  /// Closed *and* no longer animating — the rows are not on screen at all.
  ///
  /// The whole header follows this rather than [_expanded], so the colour and
  /// the summary change at the two moments the rows appear and disappear:
  /// opening lifts the colour at once, and closing keeps it until the last row
  /// is gone. Driven by [_expanded] instead, the header would go back to
  /// looking like an ordinary row with rows still visible under it.
  ///
  /// It is also what drops the children, or — under [maintainState] — merely
  /// takes them out of the tree's reach: off screen they are kept away from
  /// focus traversal and the ticker, or a tab lands in a text field nobody can
  /// see. This is what `ExpansionTile` does and the reason it does it.
  bool get _closed => !_expanded && _ctrl.isDismissed;

  @override
  void dispose() {
    _curve.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  void _toggle() {
    setState(() {
      _expanded = !_expanded;
      if (_expanded) {
        _ctrl.forward();
      } else {
        _ctrl.reverse();
      }
    });
    widget.onExpansionChanged?.call(_expanded);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(context),
        // Not built at all while closed, unless asked to be. `Offstage` alone
        // would still build them — it only declines to paint what it is given.
        if (!_closed || widget.maintainState)
          Offstage(
            offstage: _closed,
            child: TickerMode(
              enabled: !_closed,
              child: SizeTransition(
                sizeFactor: _curve,
                // Anchored to the top, so the rows unroll downwards from
                // under the header instead of growing out of their own
                // middle.
                alignment: Alignment.topCenter,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: widget.children,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildHeader(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final summary = widget.summary;
    return CardX(
      // Null is the card colour the theme gives every other row, which is what
      // a closed header is.
      color: _closed
          ? null
          : widget.expandedColor ?? scheme.surfaceContainerHigh,
      child: InkWell(
        onTap: _toggle,
        child: Padding(
          padding: widget.padding,
          child: Row(
            children: [
              if (widget.leading != null) ...[
                IconTheme.merge(
                  data: IconThemeData(size: 19, color: scheme.onSurfaceVariant),
                  child: widget.leading!,
                ),
                const SizedBox(width: 13),
              ],
              DefaultTextStyle.merge(
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
                child: widget.title,
              ),
              const SizedBox(width: 13),
              // Takes the rest of the line so that the summaries of a stack of
              // these line up in a column of their own, and ellipsises from
              // the right when there is not enough of it.
              Expanded(
                child: !_closed || summary == null
                    ? const SizedBox.shrink()
                    : DefaultTextStyle.merge(
                        style: UIs.text12Grey,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end,
                        child: summary,
                      ),
              ),
              const SizedBox(width: 13),
              RotationTransition(
                turns: _turns,
                child: Icon(
                  Icons.expand_more,
                  size: 17,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

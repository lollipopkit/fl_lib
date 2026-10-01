import 'package:material_ui/material_ui.dart';

/// A [Switch] at the size this app's rows are built for.
///
/// Material's M3 switch draws a 52x32 track inside a 52x40 box, which is
/// taller than the two lines of text it is normally the trailing widget of —
/// so a row carrying one is sized by its switch rather than by what it says,
/// and a form of them is a column of gaps.
///
/// There is no theme for this. `SwitchThemeData` carries colours, the splash
/// and the tap-target size; the track and thumb come from a private
/// `_SwitchConfigM3` that nothing outside the framework can reach. Scaling the
/// whole control is what is left, so that is what this does.
///
/// [height] is the box, not the track: the track is the inner 0.8 of it, so
/// the default 25 draws the 20 the design asks for. Uniform — the width
/// follows, because [FittedBox] is given a height and an unbounded width and
/// answers with the child's own ratio, rather than two constants that would
/// distort the day Material's metrics move.
///
/// Across, the box is the track: M3 lays the switch out 60 wide around its 52
/// of track, and those 4 either side left a trailing switch short of the edge
/// every other row's content ends at. The height keeps its margin, which is
/// what [height] is measured by.
class SwitchX extends StatelessWidget {
  const SwitchX({
    super.key,
    required this.value,
    required this.onChanged,
    this.height = 25,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;

  /// The height of the laid-out box. The drawn track is ~0.8 of it.
  final double height;

  // M3's switch, shrink-wrapped: a 52 track in a 60x40 box.
  static const _m3Track = 52.0;
  static const _m3Width = 60.0;
  static const _m3Box = 40.0;

  @override
  Widget build(BuildContext context) {
    final Widget toggle = Switch(
      value: value,
      onChanged: onChanged,
      // The 8 of padding `padded` adds is a tap target, and a scaled one
      // is not a tap target — the row is what has to be tappable. Taking
      // it off first also means [height] is the switch and nothing else.
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    return SizedBox(
      height: height,
      child: FittedBox(
        fit: BoxFit.contain,
        child: Theme.of(context).useMaterial3
            ? SizedBox(
                width: _m3Track,
                height: _m3Box,
                child: OverflowBox(maxWidth: _m3Width, child: toggle),
              )
            : toggle,
      ),
    );
  }
}

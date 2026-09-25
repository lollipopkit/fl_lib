import 'package:flutter/material.dart';

/// The mark that a feature is still in beta.
///
/// **Beta is not localized**, and every locale that had to say it before said
/// it in Latin letters inside a parenthesis — `Linux (Beta)`, `BMC (Beta)`,
/// `端口映射 (Beta)`. Localizing the word would put a feature's stability behind
/// a translation nobody can check, and the translators this ships with left
/// the word alone when it was part of a title. So the string here is a
/// constant, and only the callers that want it say otherwise.
///
/// The mark is drawn rather than appended to a title. A suffix is part of the
/// name it is attached to: it ellipsises with it, it is what the settings
/// search matches on, and a title in a language that puts the qualifier first
/// cannot carry it. Beside the title it survives a clipped name and can be
/// read as what it is — a statement about the thing next to it.
final class BetaTag extends StatelessWidget {
  const BetaTag({super.key, this.text = 'Beta', this.tip, this.height = title});

  /// What the mark reads. `Beta` unless a caller has a reason.
  final String text;

  /// A sentence for a long press or a hover, when the caller has one.
  ///
  /// Null — the common case — draws the mark with no tooltip at all rather
  /// than with a generic one. What a tooltip would have to say is that the
  /// feature may not work, and that is worth saying once where the feature is
  /// turned on, not on every mark drawn in the app.
  final String? tip;

  /// How tall the pill is. Its type and its padding are read off this, so a
  /// mark is one thing scaled rather than three numbers kept in step.
  ///
  /// Beside a 13–15pt line, which is what [title] is for: the pill is then as
  /// tall as the name it stands next to and the row around them does not grow.
  final double height;

  /// How tall the mark is beside a title.
  static const title = 15.0;

  /// How tall it is beside [IntroPage]'s 41pt heading.
  static const heading = 23.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Tertiary, not primary or secondary: those two are the accent a page
    // already spends on what is selected and on filled containers, and a mark
    // drawn in either reads as part of the thing it marks. This one is not a
    // louder version of the title — it is a warning standing beside it.
    final pill = SizedBox(
      height: height,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          shape: const StadiumBorder(),
          color: scheme.tertiaryContainer,
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: height / 3),
          // `widthFactor` rather than a bare `Center`: a `SizedBox` with a
          // height and no width hands down an unbounded one, which a `Center`
          // would fill — taking the whole line and pushing what it marks out
          // of the row.
          child: Center(
            widthFactor: 1,
            child: Text(
              text,
              style: TextStyle(
                fontSize: height * 0.6,
                height: 1,
                fontWeight: FontWeight.w600,
                letterSpacing: height * 0.02,
                color: scheme.onTertiaryContainer,
              ),
            ),
          ),
        ),
      ),
    );
    if (tip case final tip?) {
      return Tooltip(message: tip, child: pill);
    }
    return pill;
  }
}

import 'package:fl_lib/src/core/ext/ctx/dialog.dart';
import 'package:fl_lib/src/res/l10n.dart';
import 'package:fl_lib/src/res/ui.dart';
import 'package:fl_lib/src/view/widget/btn/btn.dart';
import 'package:fl_lib/src/view/widget/markdown.dart';
import 'package:flutter/material.dart';

final class TipText extends StatelessWidget {
  final String text;
  final String tip;

  /// Whether [tip] is markdown.
  ///
  /// It was declared, defaulted and accepted for a long time without ever
  /// being read — `build` always rendered a plain `Text`, so passing true did
  /// nothing at all and nothing said so. Honoured now, which also makes a
  /// link in a tip work: [SimpleMarkdown] launches what it is tapped on.
  final bool isMarkdown;
  final TextStyle? textStyle;

  const TipText(
    this.text,
    this.tip, {
    super.key,
    this.isMarkdown = false,
    this.textStyle,
  });

  @override
  Widget build(BuildContext context) {
    final textWidget = Text(
      text,
      style: textStyle,
    );

    return LayoutBuilder(
      builder: (context, cons) {
        final width = cons.maxWidth;
        // Unbounded when this is a row's non-flexible child — a tile's title
        // beside a trailing widget, say. There is no width to fill or to hold
        // the text back to, so the row is just as wide as what is in it;
        // taking `width` on faith made `SizedBox` and `ConstrainedBox` both
        // infinite and the layout threw.
        final bounded = width.isFinite;
        final row = Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            if (bounded)
              ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: width - 13 - 23),
                  child: textWidget)
            else
              textWidget,
            UIs.width13,
            InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () {
                context.showRoundDialog(
                  title: l10n.note,
                  child: isMarkdown
                      ? SingleChildScrollView(child: SimpleMarkdown(data: tip))
                      : Text(tip),
                  actions: Btnx.oks,
                );
              },
              child: const Icon(
                Icons.help_outline,
                size: 17,
                color: Colors.grey,
              ),
            ),
          ],
        );
        return bounded ? SizedBox(width: width, child: row) : row;
      },
    );
  }
}

final class CenterGreyTitle extends StatelessWidget {
  final String text;

  const CenterGreyTitle(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 23, bottom: 17),
      child: Center(
        child: Text(text, style: UIs.textGrey),
      ),
    );
  }
}

class TwoLineText extends StatelessWidget {
  const TwoLineText({super.key, required this.up, required this.down});
  final String up;
  final String down;

  @override
  Widget build(BuildContext context) {
    return Column(
      // The two lines are a name and what it belongs to, and they are never
      // the same width. Centred, neither edge lines up with the other or with
      // anything else on the bar; on the left they share one edge, which is
      // also the edge the bar's own title sits on.
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          up,
          style: UIs.text15,
          overflow: TextOverflow.ellipsis,
        ),
        Text(
          down,
          style: UIs.text11,
          overflow: TextOverflow.ellipsis,
        )
      ],
    );
  }
}

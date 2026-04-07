import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

final class SimpleMarkdown extends StatelessWidget {
  final String data;
  final MarkdownStyleSheet? styleSheet;
  final void Function()? onOpenFail;
  final bool selectable;

  const SimpleMarkdown({
    super.key,
    required this.data,
    this.styleSheet,
    this.onOpenFail,
    this.selectable = false,
  });

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).colorScheme.primary;
    return MarkdownBody(
      data: data,
      onTapLink: (text, href, title) async {
        if (href != null && href.isNotEmpty) {
          final suc = await href.launchUrl();
          if (suc) return;
        }
        onOpenFail?.call();
      },
      selectable: selectable,
      extensionSet: MarkdownUtils.extensionSet,
      styleSheet:
          styleSheet?.copyWith(a: TextStyle(color: primaryColor)) ?? MarkdownStyleSheet(a: TextStyle(color: primaryColor)),
    );
  }
}

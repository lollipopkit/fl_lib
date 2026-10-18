import 'package:fl_lib/fl_lib.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

final class SimpleMarkdown extends StatelessWidget {
  final String data;
  final MarkdownStyleSheet? styleSheet;
  final void Function()? onOpenFail;
  final bool selectable;

  /// False for untrusted text: an image is shown as its alt text, since
  /// loading `http(s)` images tells their host who opened the document.
  final bool loadImages;

  const SimpleMarkdown({
    super.key,
    required this.data,
    this.styleSheet,
    this.onOpenFail,
    this.selectable = false,
    this.loadImages = true,
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
      imageBuilder: loadImages ? null : _imagePlaceholder,
      extensionSet: MarkdownUtils.extensionSet,
      styleSheet:
          styleSheet?.copyWith(a: TextStyle(color: primaryColor)) ?? MarkdownStyleSheet(a: TextStyle(color: primaryColor)),
    );
  }

  static Widget _imagePlaceholder(Uri uri, String? title, String? alt) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.image_outlined, size: 17),
        UIs.width7,
        Flexible(child: Text(alt?.isNotEmpty == true ? alt! : uri.toString())),
      ],
    );
  }
}

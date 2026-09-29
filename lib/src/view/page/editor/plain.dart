import 'package:material_ui/material_ui.dart';
import 'package:fl_lib/fl_lib.dart';

final class PlainEditPageArgs {
  final String initialText;
  final String? title;

  const PlainEditPageArgs({
    this.initialText = '',
    this.title,
  });
}

class PlainEditPage extends StatefulWidget {
  final PlainEditPageArgs? args;

  const PlainEditPage({super.key, this.args});

  static const route = AppRoute<String, PlainEditPageArgs>(
    page: PlainEditPage.new,
    path: '/plain_edit',
  );

  @override
  State<PlainEditPage> createState() => _FullscreenEditWidgetState();
}

class _FullscreenEditWidgetState extends State<PlainEditPage> {
  late final _controller =
      TextEditingController(text: widget.args?.initialText ?? '');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final sure = await context.showRoundDialog(
          title: libL10n.attention,
          actions: Btnx.oks,
        );
        if (sure != true) return;
        contextSafe?.pop();
      },
      child: Scaffold(
        appBar: CustomAppBar(
          title: Text(widget.args?.title ?? libL10n.edit),
          actions: [
            IconButton(
              icon: const Icon(Icons.save),
              onPressed: () {
                context.pop(_controller.text);
              },
            ),
          ],
        ),
        body: TextField(
          controller: _controller,
          maxLines: null,
          expands: true,
          textAlignVertical: TextAlignVertical.top,
          decoration: const InputDecoration(
            hintText: '~',
            contentPadding: EdgeInsets.all(7),
            border: InputBorder.none,
          ),
        ),
      ),
    );
  }
}

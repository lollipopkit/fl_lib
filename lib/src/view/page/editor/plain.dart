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
  late final _initial = widget.args?.initialText ?? '';
  late final _controller = TextEditingController(text: _initial);
  var _dirty = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onChanged() {
    final dirty = _controller.text != _initial;
    if (dirty != _dirty) setState(() => _dirty = dirty);
  }

  Future<bool> _confirm() async {
    final sure = await context.showRoundDialog<bool>(
      title: libL10n.attention,
      child: Text(libL10n.askContinue(libL10n.exit)),
      actions: Btnx.cancelOk,
    );
    return sure == true;
  }

  @override
  Widget build(BuildContext context) {
    return PopGuard(
      enabled: _dirty,
      confirm: _confirm,
      child: Scaffold(
        appBar: CustomAppBar(
          title: Text(widget.args?.title ?? libL10n.edit),
          actions: [
            IconButton(
              icon: const Icon(Icons.save),
              tooltip: libL10n.save,
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

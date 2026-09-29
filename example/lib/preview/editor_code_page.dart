import 'package:fl_lib/fl_lib.dart';
import 'package:material_ui/material_ui.dart';

class PreviewEditorCodePage extends StatelessWidget {
  const PreviewEditorCodePage({super.key});

  static const _sampleCode = '''
import 'dart:math';

Future<int> generateNumber() async {
  await Future<void>.delayed(const Duration(milliseconds: 200));
  return Random().nextInt(100);
}

void main() async {
  final number = await generateNumber();
  print('Generated: \$number');
}
''';

  @override
  Widget build(BuildContext context) {
    return EditorPage(
      args: EditorPageArgs(
        title: 'sample.dart',
        lang: ProgLang.dart,
        text: _sampleCode,
        softWrap: true,
        toolbarController: AdaptiveSelectionToolbarController(),
        onSave: (ret) {
          final message = switch (ret.typ) {
            EditorPageRetType.path => 'Saved file: ${ret.val}',
            EditorPageRetType.text => 'Buffer saved (${ret.val.length} chars)',
          };
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(message)));
        },
      ),
    );
  }
}

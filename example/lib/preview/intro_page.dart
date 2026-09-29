import 'package:fl_lib/fl_lib.dart';
import 'package:material_ui/material_ui.dart';

class PreviewIntroPage extends StatelessWidget {
  const PreviewIntroPage({super.key});

  @override
  Widget build(BuildContext context) {
    return IntroPage(args: IntroPageArgs(pages: [const Center(child: Text('Intro Page'))], onDone: (_) {}));
  }
}

import 'package:fl_lib/fl_lib.dart';
import 'package:material_ui/material_ui.dart';

class PreviewFilePage extends StatelessWidget {
  const PreviewFilePage({super.key});

  @override
  Widget build(BuildContext context) {
    return const FileCardView(path: 'README.md');
  }
}

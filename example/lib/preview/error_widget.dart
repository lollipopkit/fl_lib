import 'package:material_ui/material_ui.dart';
import 'package:fl_lib/fl_lib.dart';

class PreviewErrorWidget extends StatelessWidget {
  const PreviewErrorWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: CustomAppBar(title: const Text('Error Widget Preview')),
      body: Center(child: ErrorWidget('Error 示例')),
    );
  }
}

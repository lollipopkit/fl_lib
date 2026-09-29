import 'package:fl_lib/fl_lib.dart';
import 'package:material_ui/material_ui.dart';

class PreviewLoadingWidget extends StatefulWidget {
  const PreviewLoadingWidget({super.key});

  @override
  State<PreviewLoadingWidget> createState() => _State();
}

class _State extends State<PreviewLoadingWidget> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: CustomAppBar(title: const Text('Loading Widget Preview')),
      body: Center(
        child: ListView(
          children: [
            UIs.centerLoading,
            const SizedBox(height: 20),
            UIs.smallLinearLoading,
            SizedLoading.large,
            SizedLoading.medium,
            SizedLoading.small,
            AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                return SizedLoading(
                  150,
                  padding: 10,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    Color.lerp(Colors.blue, Colors.red, _controller.value) ?? Colors.blue,
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

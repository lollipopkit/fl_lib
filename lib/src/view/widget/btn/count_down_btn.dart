import 'dart:async';

import 'package:fl_lib/src/res/l10n.dart';
import 'package:material_ui/material_ui.dart';

final class CountDownBtn extends StatefulWidget {
  final int seconds;
  final String? text;
  final Color? afterColor;
  final VoidCallback onTap;

  const CountDownBtn({
    super.key,
    required this.onTap,
    this.seconds = 3,
    this.text,
    this.afterColor,
  });

  @override
  State<CountDownBtn> createState() => _CountDownBtnState();
}

final class _CountDownBtnState extends State<CountDownBtn> {
  late int _seconds = widget.seconds;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _startCountDown();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  bool get isCounting => _seconds > 0;

  void _startCountDown() {
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!isCounting) {
        _timer?.cancel();
      }
      setState(() {
        _seconds--;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: () {
        if (isCounting) return;
        widget.onTap();
      },
      child: Text(
        isCounting ? '$_seconds s' : widget.text ?? l10n.ok,
        style: TextStyle(
          color: _seconds > 0 ? Colors.grey : widget.afterColor,
        ),
      ),
    );
  }
}

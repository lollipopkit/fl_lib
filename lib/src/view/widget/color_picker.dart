import 'package:fl_lib/fl_lib.dart';
import 'package:material_ui/material_ui.dart';

enum _ColorPropType {
  r,
  g,
  b,
}

class ColorPicker extends StatefulWidget {
  final Color color;
  final ValueChanged<Color> onColorChanged;

  const ColorPicker({
    super.key,
    required this.color,
    required this.onColorChanged,
  });

  @override
  State<ColorPicker> createState() => _ColorPickerState();
}

class _ColorPickerState extends State<ColorPicker> {
  late var _r = widget.color.red255;
  late var _g = widget.color.green255;
  late var _b = widget.color.blue255;

  late final _rVN = widget.color.red255.vn;
  late final _gVN = widget.color.green255.vn;
  late final _bVN = widget.color.blue255.vn;

  final ctrl = TextEditingController();

  Color get _color => Color.fromARGB(255, _r, _g, _b);

  @override
  void initState() {
    super.initState();
    ctrl.text = widget.color.toHexRGB;
  }

  @override
  void didUpdateWidget(covariant ColorPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.color != widget.color) {
      _r = widget.color.red255;
      _g = widget.color.green255;
      _b = widget.color.blue255;
      _rVN.value = _r;
      _gVN.value = _g;
      _bVN.value = _b;
      ctrl.text = widget.color.toHexRGB;
    }
  }

  @override
  void dispose() {
    ctrl.dispose();
    _rVN.dispose();
    _gVN.dispose();
    _bVN.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    void onTextChanged(String v) {
      final c = v.fromColorHexRGB;
      if (c == null) return;
      widget.onColorChanged(c);
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedBuilder(
          animation: Listenable.merge([_rVN, _gVN, _bVN]),
          builder: (context, _) {
            final color = Color.fromARGB(255, _rVN.value, _gVN.value, _bVN.value);
            return Container(
              height: 37,
              width: 77,
              decoration: BoxDecoration(
                color: color,
                border: Border.all(color: Colors.grey),
                borderRadius: BorderRadius.circular(8),
              ),
            );
          },
        ),
        UIs.height13,
        Input(
          onSubmitted: onTextChanged,
          onChanged: onTextChanged,
          controller: ctrl,
          hint: '#8b2252',
          icon: Icons.colorize,
          suggestion: false,
        ),
        _buildProgress(_ColorPropType.r, 'R', _rVN),
        _buildProgress(_ColorPropType.g, 'G', _gVN),
        _buildProgress(_ColorPropType.b, 'B', _bVN),
      ],
    );
  }

  Widget _buildProgress(_ColorPropType type, String title, ValueNotifier<int> vn) {
    return Row(
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
        Expanded(
          child: ValBuilder(
            listenable: vn,
            builder: (val) {
              return Slider(
                value: val.toDouble(),
                onChanged: (v) {
                  final intValue = v.toInt();
                  switch (type) {
                    case _ColorPropType.r:
                      _r = intValue;
                      break;
                    case _ColorPropType.g:
                      _g = intValue;
                      break;
                    case _ColorPropType.b:
                      _b = intValue;
                      break;
                  }
                  vn.value = intValue;
                },
                onChangeEnd: (value) {
                  final c = _color;
                  ctrl.text = c.toHexRGB;
                  widget.onColorChanged(_color);
                },
                min: 0,
                max: 255,
                divisions: 255,
                label: val.toString(),
              );
            },
          ),
        ),
      ],
    );
  }
}

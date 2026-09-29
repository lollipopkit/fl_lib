import 'package:material_ui/material_ui.dart';

final class AvgSize extends StatelessWidget {
  final List<Widget> children;
  final double? totalSize;
  final double padding;
  final MainAxisAlignment mainAxisAlignment;
  final Axis axis;

  const AvgSize({
    super.key,
    required this.children,
    this.totalSize,
    this.padding = 0,
    this.mainAxisAlignment = MainAxisAlignment.spaceAround,
    this.axis = Axis.horizontal,
  });

  @override
  Widget build(BuildContext context) {
    final totalSize = this.totalSize;
    if (totalSize != null) {
      assert(
        totalSize > padding && totalSize > 0,
        'Width must be greater than padding',
      );
      return _buildItems((totalSize - padding) / children.length);
    }

    assert(padding >= 0, 'Padding must be non-negative');
    return LayoutBuilder(builder: (_, cons) {
      final size = (cons.maxWidth - padding) / children.length;
      return _buildItems(size);
    });
  }

  Widget _buildItems(double size) {
    final builder = switch (axis) {
      Axis.horizontal => Row.new,
      Axis.vertical => Column.new,
    };
    final childrenBuilder = switch (axis) {
      Axis.horizontal => (Widget child) => SizedBox(width: size, child: child),
      Axis.vertical => (Widget child) => SizedBox(height: size, child: child),
    };
    return builder(
      mainAxisAlignment: mainAxisAlignment,
      children: children.map(childrenBuilder).toList(),
    );
  }
}

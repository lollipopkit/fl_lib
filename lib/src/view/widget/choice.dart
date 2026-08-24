import 'package:choice/choice.dart';
import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';

final class ChoiceWidget<T> extends StatelessWidget {
  const ChoiceWidget({
    super.key,
    this.clearable = false,
    this.multi = false,
    this.display,
    this.avatar,
    required this.items,
    required this.selected,
    required this.onChanged,
  });

  final bool multi;
  final bool clearable;
  final String? Function(T)? display;

  /// Drawn inside each chip, before its label.
  ///
  /// For a list whose entries are instances of something with a mark of its
  /// own — servers, say. Null for the whole list, or for one item, leaves the
  /// chip as it was.
  final Widget? Function(T)? avatar;

  final List<T> items;
  final List<T> selected;
  final void Function(List<T>) onChanged;

  @override
  Widget build(BuildContext context) {
    return Choice<T>(
      onChanged: onChanged,
      multiple: multi,
      clearable: clearable,
      value: selected,
      builder: (state, _) => Wrap(
        children: List<Widget>.generate(
          items.length,
          (index) {
            final item = items.elementAtOrNull(index);
            if (item == null) return UIs.placeholder;
            return ChoiceChipX<T>(
              key: ValueKey(item),
              label: display?.call(item) ?? item.toString(),
              avatar: avatar?.call(item),
              state: state,
              value: item,
            );
          },
        ),
      ),
    );
  }
}

class ChoiceChipX<T> extends StatelessWidget {
  const ChoiceChipX({
    super.key,
    required this.label,
    required this.state,
    required this.value,
    this.avatar,
    this.onSelected,
    this.outPadding,
    this.padding = const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
    this.labelPadding = const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
    this.showCheckmark = true,
    this.color,
  });

  final String label;

  /// Drawn before the label. Sized by the caller; `ChoiceChip` gives it the
  /// height of the label's line either way.
  final Widget? avatar;

  final ChoiceController<T> state;
  final T value;
  final void Function(T, bool)? onSelected;
  final EdgeInsetsGeometry? outPadding;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry labelPadding;
  final bool showCheckmark;
  final WidgetStateProperty<Color>? color;

  @override
  Widget build(BuildContext context) {
    final outPadding = this.outPadding ??
        EdgeInsets.only(
          left: 5,
          right: 5,
          top: isDesktop ? 7 : 0,
        );
    return Padding(
      padding: outPadding,
      child: ChoiceChip(
        label: Text(label),
        avatar: avatar,
        side: BorderSide.none,
        showCheckmark: showCheckmark,
        padding: padding,
        labelPadding: labelPadding,
        color: color, // ?? ChoiceChipColor(context),
        selected: state.selected(value),
        elevation: 0,
        pressElevation: 0,
        onSelected: (val) {
          state.onSelected(value)(val);
          onSelected?.call(value, val);
        },
      ),
    );
  }
}

final class ChoiceChipColor extends WidgetStateProperty<Color> {
  final BuildContext context;

  ChoiceChipColor(this.context);

  @override
  Color resolve(Set<WidgetState> states) {
    final isDark = context.isDark;
    final isSelected = states.contains(WidgetState.selected);
    // if (isSelected) {
    //   return const Color.fromARGB(8, 22, 22, 22);
    // }
    // return const Color.fromARGB(16, 10, 10, 10);
    return switch ((isSelected, isDark)) {
      (true, false) => const Color.fromARGB(8, 22, 22, 22),
      (true, true) => const Color.fromARGB(8, 255, 255, 255),
      (false, false) => const Color.fromARGB(16, 10, 10, 10),
      (false, true) => const Color.fromARGB(16, 255, 255, 255),
    };
  }
}

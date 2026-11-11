import 'package:fl_lib/fl_lib.dart';
import 'package:fl_lib/src/res/l10n.dart';
import 'package:material_ui/material_ui.dart';

/// What `showPickSheet` raises: the items as rows with a tick, in a
/// [showResizableSheet].
///
/// Pops `true` with [onChanged] having said the choice.
class PickSheet<T> extends StatefulWidget {
  const PickSheet({
    super.key,
    required this.items,
    required this.initial,
    required this.onChanged,
    required this.multi,
    required this.clearable,
    required this.actions,
    required this.showLoading,
    required this.ascend,
    this.title,
    this.display,
    this.avatar,
  });

  final String? title;
  final List<T> items;
  final List<T> initial;
  final ValueChanged<List<T>> onChanged;
  final String Function(T)? display;
  final Widget? Function(T)? avatar;
  final bool multi;
  final bool clearable;

  /// Under the rows: the caller's, and the OK that ends a multiple choice.
  final List<Widget> actions;
  final ValueNotifier<bool> showLoading;

  /// Null until sorted; then which way.
  final ValueNotifier<bool?> ascend;

  @override
  State<PickSheet<T>> createState() => _PickSheetState<T>();
}

class _PickSheetState<T> extends State<PickSheet<T>> {
  late final _items = widget.items.toList();
  late final _selected = widget.initial.toList();

  String _label(T item) => widget.display?.call(item) ?? item.toString();

  void _sort() {
    final asc = !(widget.ascend.value ?? false);
    setState(() {
      _items.sort((a, b) {
        final c = _label(a).compareTo(_label(b));
        return asc ? c : -c;
      });
    });
    widget.ascend.value = asc;
  }

  void _tap(T item) {
    final on = _selected.contains(item);
    if (!widget.multi) {
      final next = on && widget.clearable ? <T>[] : [item];
      widget.onChanged(next);
      context.popSheet(true);
      return;
    }
    // Choice's rule: without [clearable] the last one stays.
    if (on && _selected.length == 1 && !widget.clearable) return;
    setState(() => on ? _selected.remove(item) : _selected.add(item));
    widget.onChanged(_selected.toList());
  }

  @override
  Widget build(BuildContext context) {
    final header = Row(
      children: [
        Expanded(child: Text(widget.title ?? l10n.select)),
        widget.ascend.listenVal(
          (asc) => IconButton(
            icon: Icon(switch (asc) {
              true => Icons.arrow_upward,
              false => Icons.arrow_downward,
              null => Icons.sort,
            }),
            tooltip: l10n.sort,
            onPressed: _sort,
          ),
        ),
      ],
    );

    final rows = widget.showLoading.listenVal((loading) {
      if (loading) return const Center(child: SizedLoading.medium);
      return RowsSheet(
        children: [
          for (final item in _items)
            SheetChoiceTile(
              key: ValueKey(item),
              title: _label(item),
              leading: widget.avatar?.call(item),
              selected: _selected.contains(item),
              onTap: () => _tap(item),
            ),
        ],
      );
    });

    return PromptSheet(
      title: header,
      // The sort button brings its own room.
      titlePadding: const EdgeInsets.fromLTRB(17, 0, 7, 3),
      contentPadding: EdgeInsets.zero,
      actions: widget.actions,
      child: rows,
    );
  }
}

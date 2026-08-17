import 'dart:convert';
import 'package:fl_lib/fl_lib.dart';
import 'package:fl_lib/src/res/l10n.dart';
import 'package:flutter/material.dart';

final class JsonListEditorArgs {
  final List<dynamic> data;
  final Widget Function(dynamic item)? entryBuilder;

  const JsonListEditorArgs({required this.data, this.entryBuilder});
}

final class JsonListEditor extends StatefulWidget {
  final JsonListEditorArgs args;

  const JsonListEditor({super.key, required this.args});

  static const route = AppRouteArg<List<dynamic>, JsonListEditorArgs>(page: JsonListEditor.new, path: '/json_list_editor');

  @override
  State<JsonListEditor> createState() => _JsonListEditorState();
}

class _JsonListEditorState extends State<JsonListEditor> {
  late final _args = widget.args;
  late final List<dynamic> _list = _loadList();
  final _listKey = GlobalKey<AnimatedListState>();
  late Size _size;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _size = MediaQuery.sizeOf(context);
  }

  @override
  Widget build(BuildContext context) {
    final animatedList = AnimatedList(
      key: _listKey,
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
      initialItemCount: _list.length,
      itemBuilder: (context, idx, animation) {
        final item = _list[idx];
        return FadeTransition(opacity: animation, child: _buildItem(item, idx, animation));
      },
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.edit),
        actions: [
          IconButton(onPressed: _onTapAdd, icon: const Icon(Icons.add)),
          IconButton(onPressed: () => context.pop(_saveList()), icon: const Icon(Icons.save)),
        ],
      ),
      body: animatedList,
    );
  }

  Widget _buildItem(dynamic item, int idx, Animation<double> animation) {
    return switch (_args.entryBuilder) {
      null => _buildDefaultItem(item, idx, animation),
      final func => func(item),
    };
  }

  Widget _buildDefaultItem(dynamic item, int index, Animation<double> animation) {
    final title = SizedBox(width: _size.width * 0.5, child: Text('${index + 1}. ${_getItemType(item)}'));

    final subtitle = SizedBox(
      width: _size.width * 0.5,
      child: Text(_getItemPreview(item), style: UIs.textGrey, maxLines: 2, overflow: TextOverflow.ellipsis),
    );

    final tile = ListTile(
      title: title,
      subtitle: subtitle,
      contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 23),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Btn.icon(text: l10n.edit, icon: const Icon(Icons.edit), onTap: () => _onTapEdit(item, index)),
          Btn.icon(text: l10n.delete, icon: const Icon(Icons.delete), onTap: () => _onTapDelete(index)),
        ],
      ),
    ).cardx;

    return SizeTransition(
      sizeFactor: CurvedAnimation(parent: animation, curve: Curves.easeInOutCubic),
      alignment: const AlignmentDirectional(0.0, 0.0),
      child: tile,
    );
  }

  String _getItemType(dynamic item) {
    if (item == null) return 'null';
    if (item is Map) return 'Object';
    if (item is List) return 'List';
    if (item is String) return 'String';
    if (item is num) return 'Number';
    if (item is bool) return 'Boolean';
    return 'Unknown';
  }

  String _getItemPreview(dynamic item) {
    try {
      final jsonStr = json.encode(item);
      return jsonStr;
    } catch (e) {
      return item.toString();
    }
  }

  void _onTapDelete(int idx) {
    final item = _list.removeAt(idx);
    _listKey.currentState?.removeItem(idx, (context, animation) => _buildItem(item, idx, animation));
  }

  void _onTapEdit(dynamic item, int idx) async {
    final ctrl = TextEditingController(text: json.encode(item));

    void onSave() {
      final jsonStr = ctrl.text;
      if (jsonStr.isEmpty) {
        context.popDialog();
        context.showRoundDialog(title: l10n.fail, child: Text(l10n.empty));

        return;
      }

      try {
        final parsed = Fns.parseWithPriority(jsonStr);
        _list[idx] = parsed;
        contextSafe?.popDialog(true);
      } catch (e) {
        contextSafe?.popDialog();
        contextSafe?.showRoundDialog(title: l10n.fail, child: Text('Invalid input: $e'));
      }
    }

    final result = await context.showRoundDialog<bool>(
      title: l10n.edit,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [Input(controller: ctrl, hint: 'Value (JSON, bool, number, or string)', maxLines: 10, minLines: 3)],
      ),
      actions: [
        TextButton(onPressed: context.pop, child: Text(l10n.cancel)),
        TextButton(onPressed: onSave, child: Text(l10n.ok)),
      ],
    );
    if (result == true) {
      await Future.delayed(Durations.short3);
      _listKey.currentState?.removeItem(idx, (context, animation) => _buildItem(item, idx, animation));
      _listKey.currentState?.insertItem(idx, duration: Durations.medium1);
    }
  }

  void _onTapAdd() async {
    final ctrl = TextEditingController();

    void onSave() {
      final jsonStr = ctrl.text;
      if (jsonStr.isEmpty) {
        context.popDialog();
        context.showRoundDialog(title: l10n.fail, child: Text(l10n.empty));

        return;
      }

      try {
        final parsed = Fns.parseWithPriority(jsonStr);
        _list.add(parsed);
        contextSafe?.popDialog(true);
      } catch (e) {
        context.popDialog();
        context.showRoundDialog(title: l10n.fail, child: Text('Invalid input: $e'));
      }
    }

    final result = await context.showRoundDialog(
      title: l10n.add,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [Input(controller: ctrl, hint: 'Value (JSON, bool, number, or string)', maxLines: 8, minLines: 3)],
      ),
      actions: [
        TextButton(onPressed: context.pop, child: Text(l10n.cancel)),
        TextButton(onPressed: onSave, child: Text(l10n.ok)),
      ],
    );

    if (result == true) {
      await Future.delayed(Durations.short3);
      _listKey.currentState?.insertItem(_list.length - 1, duration: Durations.medium1);
    }
  }

  List<dynamic> _loadList() {
    return List<dynamic>.from(_args.data);
  }

  List<dynamic> _saveList() {
    return List<dynamic>.from(_list);
  }
}

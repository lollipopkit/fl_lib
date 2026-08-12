import 'package:fl_lib/fl_lib.dart';
import 'package:fl_lib/src/res/l10n.dart';
import 'package:flutter/material.dart';

final class KvEditorArgs {
  final Map<String, String> data;
  final Widget Function(String k, String v)? entryBuilder;

  /// If not null, the actual stored key will be [prefix] + key. But it will
  /// display as 'key'. Keys that don't start with [prefix] will be ignored.
  /// eg.:
  /// - prefix: 'a_', data: {'a_key': 'av', 'bkey': 'bv'}, only 'key' will be
  /// displayed. When saved, it will be saved as 'a_key'.
  final String? prefix;

  const KvEditorArgs({required this.data, this.entryBuilder, this.prefix});
}

final class KvEditor extends StatefulWidget {
  final KvEditorArgs args;

  const KvEditor({super.key, required this.args});

  static const route = AppRouteArg<Map<String, String>, KvEditorArgs>(page: KvEditor.new, path: '/kv_editor');

  @override
  State<KvEditor> createState() => _KvEditorState();
}

class _KvEditorState extends State<KvEditor> {
  late final _args = widget.args;
  late final Map<String, String> _map = _loadMap();
  final _listKey = GlobalKey<AnimatedListState>();
  late Size _media;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _media = MediaQuery.sizeOf(context);
  }

  @override
  Widget build(BuildContext context) {
    final animatedList = AnimatedList(
      key: _listKey,
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
      initialItemCount: _map.length,
      itemBuilder: (context, idx, animation) {
        final k = _map.keys.elementAt(idx);
        final v = _map[k];
        if (v == null) return UIs.placeholder;
        return FadeTransition(opacity: animation, child: _buildItem(k, v, idx, animation));
      },
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.edit),
        actions: [
          IconButton(onPressed: _onTapAdd, icon: const Icon(Icons.add)),
          IconButton(onPressed: () => context.pop(_saveMap()), icon: const Icon(Icons.save)),
        ],
      ),
      body: animatedList,
    );
  }

  Widget _buildItem(String k, String v, int idx, Animation<double> animation) {
    return switch (_args.entryBuilder) {
      null => _buildDefaultItem(k, v, idx, animation),
      final func => func(k, v),
    };
  }

  Widget _buildDefaultItem(String k, String v, int index, Animation<double> animation) {
    final title = SizedBox(width: _media.width * 0.5, child: Text(k));

    final subtitle = SizedBox(
      width: _media.width * 0.5,
      child: Text(v, style: UIs.textGrey),
    );

    final tile = ListTile(
      title: title,
      subtitle: subtitle,
      contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 23),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Btn.icon(text: l10n.edit, icon: const Icon(Icons.edit), onTap: () => _onTapEdit(k, index)),
          Btn.icon(text: l10n.delete, icon: const Icon(Icons.delete), onTap: () => _onTapDelete(k, index)),
        ],
      ),
    ).cardx;

    return SizeTransition(
      sizeFactor: CurvedAnimation(parent: animation, curve: Curves.easeInOutCubic),
      axisAlignment: 0.0,
      child: tile,
    );
  }

  void _onTapDelete(String k, int idx) {
    final v = _map.remove(k);
    _listKey.currentState?.removeItem(idx, (context, animation) => _buildItem(k, v ?? '', idx, animation));
  }

  void _onTapEdit(String k, int idx) async {
    final oldV = _map[k] ?? '';
    final ctrlK = TextEditingController(text: k);
    final ctrlV = TextEditingController(text: oldV);

    void onSave() async {
      final newK = ctrlK.text;
      final newV = ctrlV.text;
      if (newK.isEmpty || newV.isEmpty) {
        context.popDialog();
        await context.showRoundDialog(title: l10n.fail, child: Text(l10n.empty));
      }
      _map.remove(k);
      _map[newK] = newV;
      contextSafe?.popDialog(true);
    }

    final result = await context.showRoundDialog<bool>(
      title: l10n.edit,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Input(controller: ctrlK, hint: l10n.key),
          UIs.height7,
          Input(controller: ctrlV, hint: l10n.value, maxLines: 5, minLines: 1),
        ],
      ),
      actions: [
        TextButton(onPressed: context.pop, child: Text(l10n.cancel)),
        TextButton(onPressed: onSave, child: Text(l10n.ok)),
      ],
    );
    if (result == true) {
      await Future.delayed(Durations.short3);
      _listKey.currentState?.removeItem(idx, (context, animation) => _buildItem(k, oldV, idx, animation));
      final newIdx = _map.keys.toList().indexOf(ctrlK.text);
      _listKey.currentState?.insertItem(newIdx, duration: Durations.medium1);
    }
  }

  void _onTapAdd() async {
    final ctrlK = TextEditingController();
    final ctrlV = TextEditingController();

    void onSave() {
      final k = ctrlK.text;
      final v = ctrlV.text;
      if (k.isEmpty || v.isEmpty) {
        context.popDialog();
        context.showRoundDialog(title: l10n.fail, child: Text(l10n.empty));
        return;
      }
      _map[k] = v;
      context.popDialog(true);
    }

    final result = await context.showRoundDialog(
      title: l10n.add,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Input(controller: ctrlK, hint: l10n.key),
          UIs.height7,
          Input(controller: ctrlV, hint: l10n.value),
        ],
      ),
      actions: [
        TextButton(onPressed: context.pop, child: Text(l10n.cancel)),
        TextButton(onPressed: onSave, child: Text(l10n.ok)),
      ],
    );

    if (result == true) {
      await Future.delayed(Durations.short3);
      _listKey.currentState?.insertItem(_map.length - 1, duration: Durations.medium1);
    }
  }

  Map<String, String> _loadMap() {
    final prefix = _args.prefix;
    if (prefix == null) return Map<String, String>.from(_args.data);
    final map = <String, String>{};
    for (final entry in _args.data.entries) {
      if (entry.key.startsWith(prefix)) {
        map[entry.key.substring(prefix.length)] = entry.value;
      }
    }
    return map;
  }

  Map<String, String> _saveMap() {
    final prefix = _args.prefix;
    if (prefix == null) return _map;
    return _map.map((k, v) => MapEntry('$prefix$k', v));
  }
}

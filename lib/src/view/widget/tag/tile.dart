import 'package:fl_lib/fl_lib.dart';
import 'package:fl_lib/src/res/l10n.dart';
import 'package:flutter/material.dart';
import 'package:icons_plus/icons_plus.dart';

final class TagTile extends StatelessWidget {
  final Set<String> allTags;
  final ValueNotifier<Set<String>> tags;

  const TagTile({super.key, required this.tags, required this.allTags});

  @override
  Widget build(BuildContext context) {
    return tags.listenVal((vals) {
      return ListTile(
        leading: const Icon(MingCute.hashtag_line),
        title: Text(l10n.tag),
        subtitle: vals.isEmpty
            ? null
            : Text(vals.join(', '), style: UIs.textGrey),
        trailing: const Icon(Icons.keyboard_arrow_right),
        onTap: () async {
          final allTags_ = {...allTags, ...vals}.toList();
          final res = await context.showPickDialog(
            items: allTags_,
            initial: vals.toList(),
            clearable: true,
            actions: [
              TextButton(
                onPressed: () {
                  context.pop();
                  tags.value = {};
                },
                child: Text(l10n.clear),
              ),
              TextButton(
                onPressed: () async {
                  context.pop();
                  final dialogKey = GlobalKey<_AddTagDialogState>();

                  await context.showRoundDialog(
                    title: l10n.add,
                    child: _AddTagDialog(
                      key: dialogKey,
                      onSaved: (value) => tags.value = {...tags.value, value},
                    ),
                    actions: [
                      Btn.ok(onTap: () => dialogKey.currentState?.save()),
                    ],
                  );
                },
                child: Text(l10n.add),
              ),
            ],
          );

          if (res == null) return;
          tags.value = res.toSet();
        },
      );
    });
  }
}

final class _AddTagDialog extends StatefulWidget {
  final ValueChanged<String> onSaved;

  const _AddTagDialog({super.key, required this.onSaved});

  @override
  State<_AddTagDialog> createState() => _AddTagDialogState();
}

final class _AddTagDialogState extends State<_AddTagDialog> {
  final _ctrl = TextEditingController();

  void save() {
    final value = _ctrl.text.trim();
    if (value.isEmpty) return;
    widget.onSaved(value);
    context.pop();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Input(
      controller: _ctrl,
      type: TextInputType.text,
      label: l10n.tag,
      icon: MingCute.hashtag_line,
      hint: l10n.name,
      suggestion: true,
      autoCorrect: true,
      autoFocus: true,
      onSubmitted: (_) => save(),
    );
  }
}

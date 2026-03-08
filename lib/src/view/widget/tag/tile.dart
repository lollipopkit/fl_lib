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
        subtitle: vals.isEmpty ? null : Text(vals.join(', '), style: UIs.textGrey),
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
                  final ctrl = TextEditingController();
                  void onSave() {
                    final s = ctrl.text.trim();
                    if (s.isEmpty) return;
                    tags.value = {...tags.value, s};
                    context.pop();
                  }

                  context.showRoundDialog(
                    title: l10n.add,
                    child: Input(
                      controller: ctrl,
                      type: TextInputType.text,
                      label: l10n.tag,
                      icon: MingCute.hashtag_line,
                      hint: l10n.name,
                      suggestion: true,
                      autoCorrect: true,
                      autoFocus: true,
                      onSubmitted: (_) => onSave(),
                    ),
                    actions: [Btn.ok(onTap: onSave)],
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

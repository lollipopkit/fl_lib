import 'package:choice/choice.dart';
import 'package:fl_lib/fl_lib.dart';
import 'package:fl_lib/src/res/l10n.dart';
import 'package:flutter/material.dart';
import 'package:icons_plus/icons_plus.dart';

/// A wrapped switcher for multiple tags.
///
/// {@template tag-swicther-empty}
/// [kDefaultTag] (empty string) indicates all tags.
/// {@endtemplate}
class TagSwitcher extends StatelessWidget implements PreferredSizeWidget {
  final ValueNotifier<Set<String>> tags;
  final void Function(String) onTagChanged;

  /// {@macro tag-swicther-empty}
  final String initTag;

  /// If true, the tags will be wrapped in a [SingleChildScrollView].
  /// Or in a [Wrap].
  final bool singleLine;

  /// If true, the tags will be reversed.
  ///
  /// Only works when [singleLine] is true.
  final bool reversed;

  /// Whether the row takes the width of the tags in it rather than all it is
  /// given. Only works when [singleLine] is true.
  ///
  /// For a switcher that floats over a page instead of spanning a bar: it has
  /// to say how wide it is, and once whatever holds it runs out of room it
  /// scrolls rather than overflowing. Off by default, which is a row that
  /// fills its bar.
  final bool shrinkWrap;

  final EdgeInsetsGeometry padding;

  const TagSwitcher({
    super.key,
    required this.tags,
    required this.onTagChanged,
    this.initTag = kDefaultTag,
    this.singleLine = false,
    this.reversed = false,
    this.shrinkWrap = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 13),
  });

  static const kTagBtnHeight = 45.0;
  static const kDefaultTag = '';

  @override
  Widget build(BuildContext context) {
    return tags.listenVal(
      (vals) {
        if (vals.isEmpty) return UIs.placeholder;
        final items = <String>[kDefaultTag, ...vals];
        return Choice<String>(
          multiple: false,
          clearable: false,
          value: [initTag],
          builder: (state, _) {
            return singleLine
                ? _buildListView(items, state)
                : _buildWrap(items, state);
          },
        );
      },
    );
  }

  Widget _buildItem(String item, ChoiceController<String> state) {
    return ChoiceChipX<String>(
      // Half the gap on each side rather than the whole of it after every
      // chip. That put the extra 5 points on the last one, so the row sat 5
      // points off centre inside anything that measured it — which the tag
      // pill on the server page does, being as wide as what is in it.
      outPadding: const EdgeInsets.symmetric(horizontal: 2.5),
      padding: const EdgeInsets.symmetric(horizontal: 3),
      showCheckmark: false,
      label: item.isEmpty ? libL10n.all : '#$item',
      state: state,
      value: item,
      onSelected: (val, _) => onTagChanged(val),
    );
  }

  Widget _buildWrap(List<String> items, ChoiceController<String> state) {
    final children = List<Widget>.generate(
      items.length,
      (index) {
        final item = items[index];
        return _buildItem(item, state);
      },
    );
    return Padding(padding: padding, child: Wrap(children: children));
  }

  Widget _buildListView(List<String> items, ChoiceController<String> state) {
    return ListView.builder(
      scrollDirection: Axis.horizontal,
      shrinkWrap: shrinkWrap,
      itemCount: items.length,
      reverse: reversed,
      padding: padding,
      itemBuilder: (context, index) {
        final item = items[index];
        return _buildItem(item, state);
      },
    );
  }

  @override
  Size get preferredSize => const Size.fromHeight(kTagBtnHeight);
}

final class TagTile extends StatelessWidget {
  final Set<String> allTags;
  final ValueNotifier<Set<String>> tags;

  const TagTile({super.key, required this.tags, required this.allTags});

  @override
  Widget build(BuildContext context) {
    return tags.listenVal(
      (vals) {
        return ListTile(
          leading: const Icon(MingCute.hashtag_line),
          title: Text(l10n.tag),
          subtitle:
              vals.isEmpty ? null : Text(vals.join(', '), style: UIs.textGrey),
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
                    context.popDialog();
                    tags.value = {};
                  },
                  child: Text(l10n.clear),
                ),
                TextButton(
                  onPressed: () async {
                    context.popDialog();
                    final ctrl = TextEditingController();
                    void onSave() {
                      final s = ctrl.text.trim();
                      if (s.isEmpty) return;
                      tags.value = tags.value..add(s);
                      context.popDialog();
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
      },
    );
  }
}

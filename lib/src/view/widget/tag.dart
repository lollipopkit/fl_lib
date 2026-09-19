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

  /// Opens the editor, for a caller that has more to say than this widget
  /// knows — how many things carry each tag, and how to rename one across all
  /// of them. Defaults to [showTagEditor] with neither.
  ///
  /// A callback rather than the editor's dozen labels forwarded through here:
  /// every one of them names what carries a tag, which is exactly what this
  /// widget is not allowed to know.
  final Future<void> Function(BuildContext context)? onEdit;

  const TagTile({
    super.key,
    required this.tags,
    required this.allTags,
    this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return tags.listenVal((vals) {
      return InkWell(
        onTap: () => onEdit?.call(context) ?? _edit(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
          child: Row(
            children: [
              Icon(MingCute.hashtag_line, color: scheme.onSurfaceVariant),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.tag,
                      style: UIs.text12Grey.copyWith(height: 1.35),
                    ),
                    const SizedBox(height: 2),
                    // The tags themselves, not a comma-joined line of them:
                    // what a tag is worth here is being one of a set, and a
                    // subtitle reading "hk, prod" says the value of this row
                    // is a string. The last chip is the way in, so a row with
                    // nothing on it still shows what it is for.
                    Wrap(
                      spacing: 5,
                      runSpacing: 5,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        for (final tag in vals)
                          TagChip(
                            text: tag,
                            color: scheme.secondaryContainer,
                            textColor: scheme.onSecondaryContainer,
                          ),
                        TagChip(
                          text: '+ ${l10n.add}',
                          border: scheme.outlineVariant,
                          textColor: UIs.text12Grey.color,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 13),
              Icon(
                Icons.chevron_right,
                size: 17,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      );
    });
  }

  Future<void> _edit(BuildContext context) {
    return showTagEditor(context, tags: tags, allTags: allTags);
  }
}

/// One tag, or the row's own way in.
///
/// Filled when it stands for a tag that is set and outlined when it is the
/// `+ Add` at the end, so the set reads as a set and the way to change it is
/// not one more member of it.
final class TagChip extends StatelessWidget {
  const TagChip({
    super.key,
    required this.text,
    this.color,
    this.border,
    this.textColor,
  });

  final String text;
  final Color? color;
  final Color? border;
  final Color? textColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 9),
      decoration: BoxDecoration(
        color: color,
        border: border == null ? null : Border.all(color: border!),
        borderRadius: BorderRadius.circular(30),
      ),
      // Not `Container.alignment`, which wraps the child in a bare `Align` —
      // and an `Align` with no factor fills the width it is offered, so every
      // chip took the whole row and the set came out as a column.
      child: Center(
        widthFactor: 1,
        child: Text(
          text,
          style: TextStyle(fontSize: 12, height: 1, color: textColor),
        ),
      ),
    );
  }
}

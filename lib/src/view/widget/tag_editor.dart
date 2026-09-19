import 'package:fl_lib/fl_lib.dart';
import 'package:fl_lib/src/res/l10n.dart';
import 'package:flutter/material.dart';
import 'package:icons_plus/icons_plus.dart';

/// What a row says beside a tag's name — how many things carry it, whether
/// this one does, whether it is why the row survived the filter.
typedef TagNoteBuilder =
    String Function(String tag, bool selected, bool matching);

/// The tag editor, as a dialog on a wide window and a bottom sheet on a narrow
/// one.
///
/// Wide it is a dialog because the page behind it is still the subject; narrow
/// it comes up from the bottom and takes the width, which is the only shape
/// that leaves room for a list plus a field a thumb can reach.
Future<void> showTagEditor(
  BuildContext context, {
  required ValueNotifier<Set<String>> tags,
  required Set<String> allTags,
  String? title,
  String? hint,
  String? listTitle,
  String? matchingTitle,
  String Function(int count)? countLabel,
  String Function(String needle)? createLabel,
  TagNoteBuilder? noteOf,
  void Function(String from, String to)? onRename,
  String? note,
  String? footer,
}) {
  final editor = TagEditor(
    tags: tags,
    allTags: allTags,
    title: title,
    hint: hint,
    listTitle: listTitle,
    matchingTitle: matchingTitle,
    countLabel: countLabel,
    createLabel: createLabel,
    noteOf: noteOf,
    onRename: onRename,
    note: note,
    footer: footer,
  );

  // The window, not the surface: a pane hands its child a narrow box on a wide
  // screen, and a dialog centred in the window is still right there.
  final narrow = MediaQuery.sizeOf(context).width < 500;
  if (narrow) {
    return showModalBottomSheet<void>(
      context: context,
      // Above whatever navigator raised it — this is reached from inside a
      // tab, whose own navigator would clip the sheet to the tab.
      useRootNavigator: true,
      isScrollControlled: true,
      showDragHandle: false,
      backgroundColor: Colors.transparent,
      builder: (_) => editor,
    );
  }
  return showDialog<void>(
    context: context,
    useRootNavigator: true,
    builder: (_) => Padding(
      padding: const EdgeInsets.all(34),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: editor,
        ),
      ),
    ),
  );
}

/// Every tag there is, with the ones on this thing ticked.
///
/// The field at the top is a filter and the way to make a new tag at once:
/// what is typed narrows the list, and the button beside it creates that tag
/// and puts it on this thing in one step. Picking from a list of what already
/// exists is the point — typing a tag blind is how a set of them becomes
/// `prod`, `production` and `Prod`.
///
/// Nothing here is about servers, or about anything else in particular: every
/// line that would have to name what carries a tag is a parameter, so the
/// caller says "3 servers" and this says the rest.
class TagEditor extends StatefulWidget {
  const TagEditor({
    super.key,
    required this.tags,
    required this.allTags,
    this.title,
    this.hint,
    this.listTitle,
    this.matchingTitle,
    this.countLabel,
    this.createLabel,
    this.noteOf,
    this.onRename,
    this.note,
    this.footer,
  });

  /// This thing's tags, edited in place — tapping a row adds or removes one.
  final ValueNotifier<Set<String>> tags;

  /// Every tag that exists anywhere, this thing's included.
  final Set<String> allTags;

  final String? title;
  final String? hint;

  /// Over the list. [matchingTitle] replaces it while the field has something
  /// in it, because the list is then a different list.
  final String? listTitle;
  final String? matchingTitle;

  /// The count in the header, given how many tags this thing carries.
  final String Function(int count)? countLabel;

  /// The button beside the field, given what is typed.
  final String Function(String needle)? createLabel;

  final TagNoteBuilder? noteOf;

  /// Renames a tag everywhere it is used. Null draws no pencil, which is the
  /// right answer when the caller cannot rename it everywhere: a rename that
  /// reached only this thing would be a delete and an add wearing one name.
  final void Function(String from, String to)? onRename;

  /// Under the list, in the caller's own voice.
  final String? note;

  /// Beside `Done`.
  final String? footer;

  @override
  State<TagEditor> createState() => _TagEditorState();
}

class _TagEditorState extends State<TagEditor> {
  final _ctrl = TextEditingController();

  /// Every tag as this panel currently knows them.
  ///
  /// A copy, because a rename has to show here at once and what it renamed is
  /// the caller's set — which the caller may not write until it is saved. The
  /// copy is this panel's lifetime only; [TagEditor.onRename] is what makes it
  /// true anywhere else.
  late final Set<String> _all = {...widget.allTags};

  String get _needle => _ctrl.text.trim();

  @override
  void initState() {
    super.initState();
    // The field drives the list and the button both, so every keystroke is a
    // rebuild of the whole panel rather than of the field.
    _ctrl.addListener(_onTyped);
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onTyped);
    _ctrl.dispose();
    super.dispose();
  }

  void _onTyped() => setState(() {});

  void _toggle(String tag) {
    final next = {...widget.tags.value};
    if (!next.remove(tag)) next.add(tag);
    widget.tags.value = next;
  }

  void _create() {
    final needle = _needle;
    if (needle.isEmpty) return;
    widget.tags.value = {...widget.tags.value, needle};
    _ctrl.clear();
  }

  Future<void> _rename(String tag) async {
    final ctrl = TextEditingController(text: tag);
    void onSave() {
      final next = ctrl.text.trim();
      context.popDialog();
      if (next.isEmpty || next == tag) return;
      widget.onRename?.call(tag, next);
      setState(() {
        _all.remove(tag);
        _all.add(next);
      });
      // Only reachable once a selected row grows a pencil, which the design
      // does not draw — but a rename that left this thing on the old name
      // would be a delete and an add, so it is handled where it is decided
      // rather than left to whoever draws the row next.
      final selected = widget.tags.value;
      if (selected.contains(tag)) {
        widget.tags.value = {...selected}
          ..remove(tag)
          ..add(next);
      }
    }

    await context.showRoundDialog(
      title: l10n.rename,
      child: Input(
        controller: ctrl,
        type: TextInputType.text,
        label: l10n.tag,
        icon: MingCute.hashtag_line,
        autoFocus: true,
        onSubmitted: (_) => onSave(),
      ),
      actions: [Btn.ok(onTap: onSave)],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(13),
      clipBehavior: Clip.hardEdge,
      child: SafeArea(
        top: false,
        child: widget.tags.listenVal((selected) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildHeader(scheme, selected),
              const Divider(height: 1),
              Flexible(child: _buildBody(scheme, selected)),
              const Divider(height: 1),
              _buildFooter(scheme),
            ],
          );
        }),
      ),
    );
  }

  Widget _buildHeader(ColorScheme scheme, Set<String> selected) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 13),
      child: Row(
        children: [
          Icon(MingCute.hashtag_line, color: scheme.onSurfaceVariant),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              widget.title ?? l10n.tag,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
            ),
          ),
          if (widget.countLabel != null) ...[
            Text(widget.countLabel!(selected.length), style: UIs.text12Grey),
            const SizedBox(width: 9),
          ],
          InkWell(
            onTap: context.popDialog,
            child: Icon(Icons.close, size: 19, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(ColorScheme scheme, Set<String> selected) {
    final needle = _needle.toLowerCase();
    final all = {..._all, ...selected};
    // What is on this thing stays on screen whatever is typed: the rows are
    // also how a tag comes back off, and a filter that hid them would make
    // typing a way to lose the tick you came here to clear.
    final rows = [
      ...all.where(selected.contains),
      ...all.where(
        (e) =>
            !selected.contains(e) &&
            (needle.isEmpty || e.toLowerCase().contains(needle)),
      ),
    ];

    final listTitle = needle.isEmpty
        ? widget.listTitle
        : (widget.matchingTitle ?? widget.listTitle);

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildField(scheme),
          if (listTitle != null) ...[
            const SizedBox(height: 12),
            Text(
              listTitle.toUpperCase(),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.9,
                color: UIs.textGrey.color,
              ),
            ),
          ],
          const SizedBox(height: 9),
          for (final tag in rows) ...[
            _buildRow(scheme, tag, selected.contains(tag), needle.isNotEmpty),
            const SizedBox(height: 9),
          ],
          if (widget.note != null)
            Text(widget.note!, style: UIs.text11Grey.copyWith(height: 1.5)),
        ],
      ),
    );
  }

  Widget _buildField(ColorScheme scheme) {
    final needle = _needle;
    final active = needle.isNotEmpty;
    final label = widget.createLabel?.call(needle) ?? '${l10n.add} #$needle';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(
          color: active ? scheme.primary : scheme.outlineVariant,
        ),
      ),
      child: Row(
        children: [
          const Text('#', style: UIs.text13Grey),
          const SizedBox(width: 9),
          Expanded(
            child: TextField(
              controller: _ctrl,
              style: const TextStyle(fontSize: 14),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _create(),
              decoration: InputDecoration.collapsed(
                hintText: widget.hint ?? l10n.name,
                hintStyle: UIs.text13Grey,
              ),
            ),
          ),
          const SizedBox(width: 9),
          Material(
            color: active ? scheme.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(30),
            clipBehavior: Clip.hardEdge,
            child: InkWell(
              onTap: active ? _create : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                child: Text(
                  active ? label : l10n.add,
                  style: TextStyle(
                    fontSize: 12,
                    color: active ? scheme.onPrimary : UIs.textGrey.color,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRow(
    ColorScheme scheme,
    String tag,
    bool selected,
    bool typing,
  ) {
    final note = widget.noteOf?.call(tag, selected, typing);
    return Material(
      color: selected ? scheme.surfaceContainerLowest : Colors.transparent,
      borderRadius: BorderRadius.circular(13),
      clipBehavior: Clip.hardEdge,
      child: InkWell(
        onTap: () => _toggle(tag),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
          child: Row(
            children: [
              TagChip(
                text: '#$tag',
                color: selected
                    ? scheme.secondaryContainer
                    : scheme.surfaceContainerHighest,
                textColor: selected
                    ? scheme.onSecondaryContainer
                    : (typing ? null : UIs.textGrey.color),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Text(
                  note ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: UIs.text12Grey,
                ),
              ),
              if (selected)
                const Icon(Icons.check, size: 17)
              else if (widget.onRename != null)
                InkWell(
                  onTap: () => _rename(tag),
                  child: Icon(
                    Icons.edit,
                    size: 17,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFooter(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 9),
      child: Row(
        children: [
          Expanded(
            child: Text(
              widget.footer ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: UIs.text12Grey,
            ),
          ),
          const SizedBox(width: 13),
          Material(
            color: scheme.primary,
            borderRadius: BorderRadius.circular(30),
            clipBehavior: Clip.hardEdge,
            child: InkWell(
              onTap: context.popDialog,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 17,
                  vertical: 7,
                ),
                child: Text(
                  l10n.done,
                  style: TextStyle(fontSize: 12, color: scheme.onPrimary),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

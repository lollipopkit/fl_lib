import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';

/// The field a bar becomes while searching, in place of what it held.
///
/// Searching narrows the list already on screen rather than opening a page of
/// results over it. What is being searched is right there, so the list is the
/// result — it narrows as the query is typed, and its rows stay the rows, with
/// everything they can do still on them. A results page answers with a
/// read-only copy and has to be dismissed before anything can be done about
/// what it found.
///
/// Sized by the caller, because the bars this replaces are not all one height.
class InlineSearchField extends StatelessWidget {
  const InlineSearchField({
    super.key,
    required this.controller,
    required this.onChanged,
    required this.onClose,
    this.hint,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  /// Leave the search. The caller is what clears the query — the field only
  /// says the button was pressed.
  final VoidCallback onClose;

  final String? hint;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const SizedBox(width: 13),
        Expanded(
          child: TextField(
            controller: controller,
            autofocus: true,
            textInputAction: TextInputAction.search,
            onChanged: onChanged,
            // Leaves the field but not the search: what was typed is still
            // narrowing the list, and dismissing the keyboard to look at it is
            // the reason to submit.
            onSubmitted: (_) => FocusScope.of(context).unfocus(),
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              hintText: hint ?? libL10n.search,
            ),
          ),
        ),
        Btn.icon(
          text: libL10n.close,
          icon: const Icon(Icons.close, size: 18),
          onTap: onClose,
        ),
        const SizedBox(width: 7),
      ],
    );
  }
}

/// The query behind an [InlineSearchBar], and whether the bar is a field.
///
/// One object because the two are one state: a page holding them apart kept a
/// notifier, a text controller, a pair of start/stop methods and a `dispose`
/// for each — five pieces of the same thing, written out once per page that
/// can be searched.
///
/// `null` and `''` are different: no field at all, and a field with nothing in
/// it yet. Only the first shows what the bar held before.
class InlineSearchController extends ValueNotifier<String?> {
  InlineSearchController() : super(null);

  final text = TextEditingController();

  /// Whether the bar is a field.
  bool get active => value != null;

  /// What to match against, trimmed and folded. Empty while the field is
  /// empty, so a caller can treat "searching for nothing" as "not searching".
  String get needle => value?.trim().toLowerCase() ?? '';

  void start() {
    text.clear();
    value = '';
  }

  void end() {
    text.clear();
    value = null;
  }

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }
}

/// A bar that is [child] until a search starts, and a field while one is on.
///
/// Crossed rather than cut, because the bar is where the eye already is: what
/// replaces it should read as the same strip changing rather than as one
/// control being swapped for another.
class InlineSearchBar extends StatelessWidget {
  const InlineSearchBar({
    super.key,
    required this.controller,
    required this.child,
    this.hint,
  });

  final InlineSearchController controller;

  /// What the bar holds when nothing is being searched.
  final Widget child;

  final String? hint;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => AnimatedSwitcher(
        duration: Durations.short4,
        child: controller.active
            ? InlineSearchField(
                key: const ValueKey('inline-search-field'),
                controller: controller.text,
                onChanged: (value) => controller.value = value,
                onClose: controller.end,
                hint: hint,
              )
            : KeyedSubtree(
                key: const ValueKey('inline-search-rest'),
                child: child,
              ),
      ),
    );
  }
}

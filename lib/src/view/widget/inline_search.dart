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

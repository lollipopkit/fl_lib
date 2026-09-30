import 'package:fl_lib/fl_lib.dart';
import 'package:material_ui/material_ui.dart';

class Input extends StatefulWidget {
  final TextEditingController? controller;

  /// Default is `1`.
  final int maxLines;
  final int? minLines;
  final String? hint;
  final String? label;
  final void Function(String)? onSubmitted;
  final void Function(String)? onChanged;

  /// {@template concurrent_obscure_suffix}
  /// Can't use both [obscureText] and [suffix] at the same time.
  /// {@endtemplate}
  final bool obscureText;

  /// {@macro concurrent_obscure_suffix}
  final Widget? suffix;

  /// The leading icon of the input.
  final IconData? icon;
  final TextInputType? type;
  final TextInputAction? action;
  final FocusNode? node;

  /// Default is `false`.
  final bool autoCorrect;

  /// By default, it uses the value of [PrefProps.imeSuggestions] or `true`.
  final bool? suggestion;

  /// Works on [TextField.decoration]
  final String? errorText;

  /// Default is `false`.
  final bool autoFocus;
  final void Function(bool)? onViewPwdTap;

  /// If true, the input will not be wrapped in a [Card] and [Padding].
  ///
  /// Default is `false`.
  final bool noWrap;
  final InputCounterWidgetBuilder? counterBuilder;
  final void Function()? onTap;
  final void Function(PointerDownEvent)? onTapOutside;

  /// If null, it uses the [AdaptiveTextSelectionToolbar.editableText].
  final EditableTextContextMenuBuilder? contextMenuBuilder;
  final int? maxLength;
  final bool? enabled;

  const Input({
    super.key,
    this.controller,
    this.maxLines = 1,
    this.minLines,
    this.hint,
    this.label,
    this.onSubmitted,
    this.onChanged,
    this.obscureText = false,
    this.icon,
    this.type,
    this.action,
    this.node,
    this.autoCorrect = false,
    this.suggestion,
    this.errorText,
    this.autoFocus = false,
    this.onViewPwdTap,
    this.noWrap = false,
    this.suffix,
    this.counterBuilder,
    this.onTap,
    this.onTapOutside,
    this.contextMenuBuilder,
    this.maxLength,
    this.enabled,
  }) : assert(
         !(obscureText && suffix != null),
         'suffix != null && obscureText',
       );

  @override
  State<StatefulWidget> createState() => _InputState();
}

class _InputState extends State<Input> {
  late final _obscureText = widget.obscureText.vn;

  @override
  Widget build(BuildContext context) {
    final icon = widget.icon;
    // Laid out here rather than handed to `InputDecoration.icon`, which puts a
    // hard-coded 16 between the icon and the field and takes no say in it. A
    // `ListTile` leaves `horizontalTitleGap` — 13 — so the two stacked in one
    // form had their icons on one line and their text on another.
    final child = icon == null
        ? _buildField()
        : Row(
            children: [
              Icon(icon, color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(width: 13),
              Expanded(child: _buildField()),
            ],
          );

    if (widget.noWrap) return child;

    return CardX(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 3),
        child: child,
      ),
    );
  }

  Widget _buildField() {
    return _obscureText.listenVal((obscureText) {
      return TextField(
        controller: widget.controller,
        maxLines: widget.maxLines,
        minLines: widget.minLines,
        // A suffix taller than the text makes the field taller, and a field
        // puts its text at the top: one line sat above the middle of the
        // button beside it. More lines start at the top, as text does.
        textAlignVertical: widget.maxLines == 1 ? TextAlignVertical.center : null,
        obscureText: obscureText,
        // What is typed here is a value of a form row, the same thing a tile's
        // title is, and Material's 16 made every field outweigh the tiles
        // stacked against it.
        style: const TextStyle(fontSize: 14),
        decoration: InputDecoration(
          hintText: widget.hint,
          // An empty label still takes the room it would float into, and
          // leaves the text below the middle of the field under nothing.
          labelText: widget.label?.isEmpty ?? true ? null : widget.label,
          errorText: widget.errorText,
          // No frame of its own, in any state, whatever the theme says. The
          // row this sits in — its own card, or the tile or card a `noWrap`
          // field is placed in — is the frame; a theme's field border drew a
          // second one inside it. Every state is named: a null one is filled
          // in from `InputDecorationTheme`, which is where that border comes
          // from. The fill goes for the same reason. A theme's field style is
          // for a bare `TextField`.
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          errorBorder: InputBorder.none,
          focusedErrorBorder: InputBorder.none,
          disabledBorder: InputBorder.none,
          filled: false,
          suffixIcon: _buildSuffix(obscureText),
          // Material sizes a field to be picked out of a page of prose. These
          // are rows of a form, each already inside a card of its own and
          // stacked against tiles that are 44 high, and at the default the
          // label and the value sat in the middle of a box half again as tall
          // as either of its neighbours.
          isDense: true,
          // Not the theme's either: that padding is room inside a border this
          // field no longer draws.
          contentPadding: const EdgeInsets.symmetric(vertical: 7),
          // Sitting in the field, the label is the value's size, because that
          // is the slot it is standing in for. Risen, it is a caption over the
          // value — set outright rather than left to the 0.75 the float
          // applies, which off 13 would land at 9.75.
          labelStyle: const TextStyle(fontSize: 14),
          floatingLabelStyle: const TextStyle(fontSize: 12),
        ),
        keyboardType: widget.type,
        textInputAction: widget.action,
        focusNode: widget.node,
        autocorrect: widget.autoCorrect,
        enableSuggestions:
            widget.suggestion ?? PrefProps.imeSuggestions.get() ?? true,
        autofocus: widget.autoFocus,
        onSubmitted: widget.onSubmitted,
        onChanged: widget.onChanged,
        buildCounter: widget.counterBuilder,
        onTap: widget.onTap,
        onTapOutside: widget.onTapOutside,
        maxLength: widget.maxLength,
        enabled: widget.enabled,
        contextMenuBuilder: widget.contextMenuBuilder ?? _ctxMenuBuilder,
      );
    });
  }

  Widget? _buildSuffix(bool obscureText) {
    if (widget.suffix != null) return widget.suffix!;
    if (!widget.obscureText) return null;

    return IconButton(
      // An `IconButton` is 48 square at its smallest, which is taller than the
      // field it sits in — so a password field was the one row on the page
      // whose height came from its button rather than its content. Compact is
      // 40, still a target worth aiming at.
      visualDensity: VisualDensity.compact,
      icon: Icon(obscureText ? Icons.visibility : Icons.visibility_off),
      onPressed: () {
        _obscureText.value = !obscureText;
        widget.onViewPwdTap?.call(obscureText);
      },
    );
  }

  Widget _ctxMenuBuilder(BuildContext context, EditableTextState state) =>
      AdaptiveTextSelectionToolbar.editableText(editableTextState: state);
}

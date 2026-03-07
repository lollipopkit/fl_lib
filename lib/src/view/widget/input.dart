import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';

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

  bool get _enableSuggestions {
    final suggestion = widget.suggestion;
    if (suggestion != null) return suggestion;
    if (!PrefStore.shared.isInitialized) return true;
    return PrefProps.imeSuggestions.get() ?? true;
  }

  @override
  Widget build(BuildContext context) {
    final icon = widget.icon.nullOr((i) => Icon(i).paddingOnly(left: 5));
    final child = _buildField(icon);

    if (widget.noWrap) return child;

    return CardX(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 5),
        child: child,
      ),
    );
  }

  Widget _buildField(Widget? icon) {
    return _obscureText.listenVal((obscureText) {
      return TextField(
        controller: widget.controller,
        maxLines: widget.maxLines,
        minLines: widget.minLines,
        obscureText: obscureText,
        decoration: InputDecoration(
          hintText: widget.hint,
          labelText: widget.label,
          errorText: widget.errorText,
          border: InputBorder.none,
          icon: icon,
          suffixIcon: _buildSuffix(obscureText),
        ),
        keyboardType: widget.type,
        textInputAction: widget.action,
        focusNode: widget.node,
        autocorrect: widget.autoCorrect,
        enableSuggestions: _enableSuggestions,
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

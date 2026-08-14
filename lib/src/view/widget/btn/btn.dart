import 'package:fl_lib/fl_lib.dart';
import 'package:fl_lib/src/res/l10n.dart';
import 'package:flutter/material.dart';
import 'package:icons_plus/icons_plus.dart';

/// {@template btntype}
/// The type of the button.
/// - [BtnType.text] => [TextButton]
/// - [BtnType.icon] => [Icon] wrapped by [InkWell]
/// - [BtnType.column] => [Column] wrapped by [InkWell]
/// - [BtnType.row] => [Row] wrapped by [InkWell]
/// {@endtemplate}
///
/// {@template btntype_is_column_or_row}
/// If [type] is [BtnType.column], [BtnType.row],
/// {@endtemplate}
/// some properties will be ignored.
enum BtnType {
  /// Row( Icon, Text ) or Row( Text, Icon ) based on LTR or RTL
  row,

  /// Text only
  text,

  /// Icon only
  icon,

  /// Column( Icon, Text )
  column,

  /// [ElevatedButton]
  elevated,
  ;
}

/// Just a placeholder for the default onTap.
///
/// {@template btn_default_on_tap}
/// By default, it will exec `context.pop()`.
/// {@endtemplate}
///
/// Put if here, or the template macro will work incorrectly.
Null _defaultOnTap() => null;

const _kGap = 7.0;

const _kPadding = EdgeInsets.all(7);

/// A placeholder icon that can't be displayed.
const _kPlaceholderIcon = Icon(MingCute.question_line);

const _kBorderRadius = BorderRadius.all(Radius.circular(30));

final class Btn extends StatelessWidget {
  /// The callback when the button is tapped.
  ///
  /// If it's set to `null` explicitly, the button will be disabled.
  ///
  /// {@macro btn_default_on_tap}
  final void Function()? onTap;

  /// The callback when the button is long tapped.
  final void Function()? onLongTap;

  /// {@template btn_text_icon}
  /// At lease one of [text] and [icon] must be not null.
  /// {@endtemplate}
  ///
  /// The text of the button.
  /// If [Btn.type] is [BtnType.icon], it will be passed to the tooltip.
  final String text;

  /// {@macro btn_text_icon}
  /// The icon of the button.
  final Icon? icon;

  /// The gap between the [icon] and the [text].
  ///
  /// It will be ignored if the [icon] or [text] is null.
  final double? gap;

  /// Style of the [text]
  final TextStyle? textStyle;

  /// {@macro btntype}
  final BtnType type;

  /// The padding of the button.
  ///
  /// {@macro btntype_is_column_or_row}
  /// or [BtnType.icon], default is [_kPadding], or `null`.
  final EdgeInsetsGeometry? padding;

  /// The alignment of the [Column] or [Row].
  ///
  /// {@macro btntype_is_column_or_row}
  /// default is [MainAxisAlignment.spaceBetween], or `null`.
  final MainAxisAlignment? mainAxisAlignment;

  /// The [MainAxisSize] of the [Column] or [Row].
  ///
  /// {@macro btntype_is_column_or_row}
  /// default is [MainAxisSize.max], or `null`.
  final MainAxisSize? mainAxisSize;

  /// Border radius of the button.
  ///
  /// Not effect on [BtnType.text].
  final BorderRadius? borderRadius;

  /// If you want to pop a value and [onTap] is null, you can pass it to the [popVal].
  /// If [onTap] is not null, [popVal] will be ignored.
  ///
  /// By default:
  /// - [Btn.ok] pops `true`
  /// - Everything else, [Btn.cancel] included, pops `null`
  final Object? popVal;

  /// TextButton
  const Btn.text({
    super.key,
    required this.text,
    this.onTap = _defaultOnTap,
    this.textStyle,
    this.padding,
    this.onLongTap,
  })  : type = BtnType.text,
        gap = null,
        mainAxisAlignment = null,
        mainAxisSize = null,
        borderRadius = null,
        popVal = null,
        icon = null;

  /// IconButton
  const Btn.icon({
    super.key,
    required this.icon,
    this.text = '',
    this.onTap = _defaultOnTap,
    this.padding = _kPadding,
    this.onLongTap,
  })  : type = BtnType.icon,
        gap = null,
        mainAxisAlignment = null,
        mainAxisSize = null,
        borderRadius = null,
        popVal = null,
        textStyle = null;

  /// Column( Icon, Text )
  const Btn.column({
    super.key,
    required this.text,
    required this.icon,
    this.onTap = _defaultOnTap,
    this.gap,
    this.textStyle,
    this.padding = _kPadding,
    this.mainAxisAlignment,
    this.mainAxisSize,
    this.borderRadius = _kBorderRadius,
    this.onLongTap,
  })  : type = BtnType.column,
        popVal = null;

  /// Row( Icon, Text ) or Row( Text, Icon ) based on LTR or RTL
  const Btn.row({
    super.key,
    required this.text,
    required this.icon,
    this.onTap = _defaultOnTap,
    this.gap,
    this.textStyle,
    this.padding = _kPadding,
    this.mainAxisAlignment,
    this.mainAxisSize,
    this.borderRadius = _kBorderRadius,
    this.onLongTap,
  })  : type = BtnType.row,
        popVal = null;

  /// Row( Icon, Text ) or Row( Text, Icon ) based on LTR or RTL
  const Btn.tile({
    super.key,
    required this.text,
    required this.icon,
    this.onTap = _defaultOnTap,
    this.gap = 20,
    this.textStyle = const TextStyle(fontSize: 16, fontWeight: FontWeight.w400),
    this.padding = const EdgeInsets.symmetric(vertical: 13, horizontal: 20),
    this.mainAxisAlignment,
    this.mainAxisSize,
    this.borderRadius = const BorderRadius.all(Radius.circular(13)),
    this.onLongTap,
  })  : type = BtnType.row,
        popVal = null;

  const Btn.elevated({
    super.key,
    required this.text,
    this.icon,
    this.onTap = _defaultOnTap,
    this.gap = 20,
    this.textStyle,
    this.padding = const EdgeInsets.symmetric(vertical: 13, horizontal: 20),
    this.mainAxisAlignment,
    this.mainAxisSize,
    this.borderRadius = const BorderRadius.all(Radius.circular(13)),
    this.onLongTap,
  })  : type = BtnType.elevated,
        popVal = null;

  /// {@template btn_ok_pop}
  /// It will pop `true` if [onTap] is null.
  /// {@endtemplate}
  Btn.ok({
    super.key,
    this.onTap = _defaultOnTap,
    bool red = false,
    this.onLongTap,
  })  : text = l10n.ok,
        icon = null,
        type = BtnType.text,
        gap = null,
        padding = null,
        mainAxisAlignment = null,
        mainAxisSize = null,
        borderRadius = null,
        popVal = true,
        textStyle = red ? UIs.textRed : null;

  /// {@template btn_cancel_pop}
  /// It pops nothing — a null result — if [onTap] is null.
  ///
  /// Not `false`, which it used to pop: a `showRoundDialog<T>` is a
  /// `Route<T>`, and popping a bool through one typed for anything else threw
  /// on the way out, leaving the dialog on screen with a cancel button that
  /// did nothing. Null is the one result every `T` accepts, and a caller
  /// asking whether something was confirmed reads `== true` either way.
  /// {@endtemplate}
  Btn.cancel({
    super.key,
    this.onTap = _defaultOnTap,
    this.onLongTap,
  })  : text = l10n.cancel,
        icon = null,
        type = BtnType.text,
        gap = null,
        padding = null,
        mainAxisAlignment = null,
        mainAxisSize = null,
        borderRadius = null,
        popVal = null,
        textStyle = null;

  /// Right-click reaches [onLongTap], for the same reason every other tile
  /// does — see `WidgetSecondaryX`. Wrapped once here rather than in each of
  /// the six shapes below, which all carry the same callback.
  @override
  Widget build(BuildContext context) => switch (type) {
        BtnType.text => _text(context),
        BtnType.icon => _icon(context),
        BtnType.column => _column(context),
        BtnType.row => _row(context),
        BtnType.elevated => _elevated(context),
      }
          .onSecondary(asSecondary(onLongTap));

  VoidCallback? _resolveOnTap(BuildContext c) {
    if (onTap == _defaultOnTap) {
      if (popVal != null) return () => c.pop(popVal);
      return c.pop;
    }
    return onTap;
  }

  Widget _text(BuildContext context) {
    if (icon != null) {
      dprint(
        '[icon] should be null if [type] == [BtnType.text].'
        ' The icon will be ignored.',
      );
    }
    return TextButton(
      onPressed: _resolveOnTap(context),
      onLongPress: onLongTap,
      style: padding != null
          ? ButtonStyle(padding: WidgetStateProperty.all(padding))
          : null,
      child: Text(text, style: textStyle),
    );
  }

  Widget _icon(BuildContext context) {
    if (icon == null) {
      dprint('[icon] can\'t be null if [type] == [BtnType.icon].');
    }

    Widget child = Tooltip(
      message: text,
      child: icon ?? _kPlaceholderIcon,
    );
    if (padding != null) child = Padding(padding: padding!, child: child);
    return InkWell(
      borderRadius: borderRadius ?? _kBorderRadius,
      onTap: _resolveOnTap(context),
      onLongPress: onLongTap,
      child: child,
    );
  }

  Widget _column(BuildContext context) {
    if (icon == null) {
      dprint('[icon] can\'t be null if [type] == [BtnType.column].');
    }

    Widget child = Column(
      children: [
        icon ?? _kPlaceholderIcon,
        SizedBox(height: gap ?? _kGap),
        Text(text, style: textStyle),
      ],
    );
    if (padding != null) {
      child = Padding(padding: padding!, child: child);
    }
    return InkWell(
      borderRadius: borderRadius ?? _kBorderRadius,
      onTap: _resolveOnTap(context),
      onLongPress: onLongTap,
      child: child,
    );
  }

  Widget _row(BuildContext context) {
    if (icon == null) {
      dprint('[icon] can\'t be null if [type] == [BtnType.tile].');
    }

    final isRTL = Directionality.of(context) == TextDirection.rtl;
    final icon_ = icon ?? _kPlaceholderIcon;
    final gap_ = SizedBox(width: gap ?? _kGap);
    final text_ = Text(text, style: textStyle);
    final children = isRTL ? [text_, gap_, icon_] : [icon_, gap_, text_];

    Widget child = Row(
      mainAxisAlignment: mainAxisAlignment ?? MainAxisAlignment.start,
      mainAxisSize: mainAxisSize ?? MainAxisSize.max,
      children: children,
    );
    if (padding != null) {
      child = Padding(padding: padding!, child: child);
    }
    return InkWell(
      borderRadius: borderRadius ?? _kBorderRadius,
      onTap: _resolveOnTap(context),
      onLongPress: onLongTap,
      child: child,
    );
  }

  Widget _elevated(BuildContext context) {
    final isRTL = Directionality.of(context) == TextDirection.rtl;
    final btnStyle = ButtonStyle(
      padding: WidgetStateProperty.all(padding),
      shape: WidgetStateProperty.all(
        RoundedRectangleBorder(borderRadius: borderRadius ?? _kBorderRadius),
      ),
    );
    final text_ = Text(text, style: textStyle);

    if (icon != null) {
      final gap_ = SizedBox(width: gap ?? _kGap);
      final children = isRTL ? [text_, gap_, icon!] : [icon!, gap_, text_];

      final child = ElevatedButton(
        onPressed: _resolveOnTap(context),
        onLongPress: onLongTap,
        style: btnStyle,
        child: Row(
          mainAxisAlignment: mainAxisAlignment ?? MainAxisAlignment.start,
          mainAxisSize: mainAxisSize ?? MainAxisSize.max,
          children: children,
        ),
      );
      return child;
    }

    return ElevatedButton(
      onPressed: _resolveOnTap(context),
      onLongPress: onLongTap,
      style: btnStyle,
      child: text_,
    );
  }
}

/// Make a convention here to return null if you cancel,
/// click on the outside of the dialogue box,
/// and return true if you click on the confirmation.
///
/// Keeps naming `Btnx` for better input experience.
extension Btnx on Btn {
  List<Widget> get toList => [this];

  /// A [Btn.ok] which pops `true`
  ///
  /// {@template btnx_ok_non_final}
  /// Use a getter instead of a `final` var to avoid [l10n] unfollowing.
  /// {@endtemplate}
  static Btn get ok => Btn.ok();

  /// A [Btn.ok] which pops `true` and is red.
  ///
  /// {@macro btnx_ok_non_final}
  static Btn get okRed => Btn.ok(red: true);

  /// A list `[Btnx.ok]`
  ///
  /// {@macro btnx_ok_non_final}
  static List<Widget> get oks => ok.toList;

  /// A list `[Btnx.okRed]`
  ///
  /// {@macro btnx_ok_non_final}
  static List<Widget> get okReds => okRed.toList;

  /// A list `[Btn.cancel(), Btnx.ok]`
  ///
  /// {@macro btnx_ok_non_final}
  static List<Widget> get cancelOk => [Btn.cancel(), ok];

  /// A list `[Btn.cancel(), Btnx.okRed]`
  ///
  /// {@macro btnx_ok_non_final}
  static List<Widget> get cancelRedOk => [Btn.cancel(), Btnx.okRed];
}

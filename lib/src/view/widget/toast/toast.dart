import 'dart:async';
import 'dart:math' as math;

import 'package:fl_lib/src/core/logger.dart';
import 'package:fl_lib/src/core/utils/platform/base.dart';
import 'package:fl_lib/src/res/ui.dart';
import 'package:fl_lib/src/view/widget/appbar.dart';
import 'package:fl_lib/src/view/widget/val_builder.dart';
import 'package:fl_lib/src/view/widget/virtual_window_frame.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

part 'host.dart';
part 'item.dart';

/// A transient message shown in a corner of the window.
///
/// Replaces `SnackBar`. Three differences are the reason it exists:
/// - It takes no [BuildContext]. A message reporting the result of an async
///   operation used to depend on the page that started it still being mounted.
/// - It is not carried by a [ScaffoldMessenger], which stops being an
///   unambiguous target once the layout has more than one pane.
/// - It keeps the whole text. Collapsed it is one line; opened on tap it shows
///   the [ToastData.body] and the untruncated title, and a long press copies
///   both — an exception string is no longer cut off at the screen edge.
///
/// Requires a [ToastHost] in the tree, normally in `MaterialApp.builder`.
abstract final class Toast {
  /// Shows a toast.
  ///
  /// - [title] is the single line shown while collapsed.
  /// - [body] is revealed on tap. Put the detail of a failure here.
  /// - [icon] is drawn before the title; [leading] replaces it with an
  ///   arbitrary widget when an [IconData] is not enough.
  /// - [color] tints the icon and the surface. Defaults to what [level] says.
  /// - [content] replaces the whole title/body layout. Expanding is then
  ///   meaningless and is disabled; dragging and long-pressing still work.
  /// - [duration] of `Duration.zero` keeps the toast until it is dismissed.
  ///   Defaults to [ToastConfig.duration].
  /// - [action] adds a trailing button.
  /// - [onTap] takes over the tap. Expanding then moves to the chevron.
  /// - [copyText] is what a long press copies. Defaults to title and body.
  /// - [tag] makes a toast replace the one before it instead of stacking, for
  ///   a message that can repeat quickly.
  static void show(
    String title, {
    String? body,
    IconData? icon,
    Widget? leading,
    Color? color,
    Widget? content,
    Duration? duration,
    ToastAction? action,
    VoidCallback? onTap,
    String? copyText,
    String? tag,
    bool expanded = false,
    ToastLevel level = ToastLevel.none,
  }) {
    _ToastCtrl.add(ToastData(
      title: title,
      body: body,
      icon: icon,
      leading: leading,
      color: color,
      content: content,
      duration: duration ?? ToastConfig.duration,
      action: action,
      onTap: onTap,
      copyText: copyText,
      tag: tag,
      expanded: expanded,
      level: level,
    ));
  }

  /// {@template toast_level_shortcut}
  /// Same as [show], with the icon and the color of the level.
  /// {@endtemplate}
  static void success(
    String title, {
    String? body,
    IconData? icon,
    Widget? leading,
    Color? color,
    Duration? duration,
    ToastAction? action,
    VoidCallback? onTap,
    String? copyText,
    String? tag,
    bool expanded = false,
  }) =>
      show(
        title,
        body: body,
        icon: icon,
        leading: leading,
        color: color,
        duration: duration,
        action: action,
        onTap: onTap,
        copyText: copyText,
        tag: tag,
        expanded: expanded,
        level: ToastLevel.success,
      );

  /// {@macro toast_level_shortcut}
  static void error(
    String title, {
    String? body,
    IconData? icon,
    Widget? leading,
    Color? color,
    Duration? duration,
    ToastAction? action,
    VoidCallback? onTap,
    String? copyText,
    String? tag,
    bool expanded = false,
  }) =>
      show(
        title,
        body: body,
        icon: icon,
        leading: leading,
        color: color,
        duration: duration,
        action: action,
        onTap: onTap,
        copyText: copyText,
        tag: tag,
        expanded: expanded,
        level: ToastLevel.error,
      );

  /// {@macro toast_level_shortcut}
  static void warn(
    String title, {
    String? body,
    IconData? icon,
    Widget? leading,
    Color? color,
    Duration? duration,
    ToastAction? action,
    VoidCallback? onTap,
    String? copyText,
    String? tag,
    bool expanded = false,
  }) =>
      show(
        title,
        body: body,
        icon: icon,
        leading: leading,
        color: color,
        duration: duration,
        action: action,
        onTap: onTap,
        copyText: copyText,
        tag: tag,
        expanded: expanded,
        level: ToastLevel.warn,
      );

  /// {@macro toast_level_shortcut}
  static void info(
    String title, {
    String? body,
    IconData? icon,
    Widget? leading,
    Color? color,
    Duration? duration,
    ToastAction? action,
    VoidCallback? onTap,
    String? copyText,
    String? tag,
    bool expanded = false,
  }) =>
      show(
        title,
        body: body,
        icon: icon,
        leading: leading,
        color: color,
        duration: duration,
        action: action,
        onTap: onTap,
        copyText: copyText,
        tag: tag,
        expanded: expanded,
        level: ToastLevel.info,
      );

  /// Dismisses every toast on screen.
  static void dismissAll() => _ToastCtrl.dismissAll();
}

/// What a toast means, when the call site does not spell out an icon and a
/// color. [ToastLevel.none] is a plain message with neither.
enum ToastLevel { none, success, error, warn, info }

/// Where the toasts stack.
///
/// `start` and `end` follow the text direction: [topEnd] is the top right in a
/// left-to-right locale and the top left in a right-to-left one.
enum ToastAlign {
  topStart,
  topCenter,
  topEnd,
  bottomStart,
  bottomCenter,
  bottomEnd;

  /// Whether the stack hangs from the top edge, newest first.
  bool get isTop => switch (this) {
        topStart || topCenter || topEnd => true,
        bottomStart || bottomCenter || bottomEnd => false,
      };

  /// Pinned to the end edge.
  bool get isEnd => this == topEnd || this == bottomEnd;

  /// Pinned to the start edge.
  bool get isStart => this == topStart || this == bottomStart;

  /// Pinned to neither side edge, centred between them.
  bool get isCenter => this == topCenter || this == bottomCenter;
}

/// App-wide defaults, so that they can be changed without touching call sites.
abstract final class ToastConfig {
  /// How long a toast stays before dismissing itself.
  static Duration duration = const Duration(seconds: 3);

  /// How many toasts may be on screen at once. The oldest goes when a new one
  /// arrives over the limit.
  static int maxVisible = 5;

  /// Width of a toast, unless the window is too narrow for it.
  static double maxWidth = 380;

  /// Distance from the window edges. The side insets are unused when [align]
  /// is centred horizontally, other than to bound [maxWidth].
  static EdgeInsets margin = const EdgeInsets.all(12);

  /// Where the toasts stack. Also decides which way one is dragged away, which
  /// is always towards the nearest edge.
  static ToastAlign align = ToastAlign.topEnd;
}

/// Trailing button of a toast.
@immutable
final class ToastAction {
  /// Text of the button.
  final String label;

  /// Called when the button is pressed.
  final VoidCallback onTap;

  /// Whether pressing the button also dismisses the toast.
  final bool dismissOnTap;

  const ToastAction({
    required this.label,
    required this.onTap,
    this.dismissOnTap = true,
  });
}

/// Everything a single toast displays. See [Toast.show] for what each field
/// means.
@immutable
final class ToastData {
  final String title;
  final String? body;
  final IconData? icon;
  final Widget? leading;
  final Color? color;
  final Widget? content;
  final Duration duration;
  final ToastAction? action;
  final VoidCallback? onTap;
  final String? copyText;
  final String? tag;
  final bool expanded;
  final ToastLevel level;

  const ToastData({
    required this.title,
    this.body,
    this.icon,
    this.leading,
    this.color,
    this.content,
    this.duration = const Duration(seconds: 3),
    this.action,
    this.onTap,
    this.copyText,
    this.tag,
    this.expanded = false,
    this.level = ToastLevel.none,
  });

  /// What a long press puts on the clipboard.
  String get textToCopy {
    if (copyText != null) return copyText!;
    final body_ = body;
    return body_ == null ? title : '$title\n\n$body_';
  }

  /// The icon to draw, [icon] if given and the one of [level] otherwise.
  IconData? get iconData =>
      icon ??
      switch (level) {
        ToastLevel.none => null,
        ToastLevel.success => Icons.check_circle_outline,
        ToastLevel.error => Icons.error_outline,
        ToastLevel.warn => Icons.warning_amber_rounded,
        ToastLevel.info => Icons.info_outline,
      };

  /// [color] if given, and the one of [level] otherwise.
  ///
  /// Resolved against the theme rather than stored, so that a toast raised from
  /// a place with no context still follows the current brightness.
  Color accentColor(BuildContext context) {
    final color_ = color;
    if (color_ != null) return color_;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    return switch (level) {
      ToastLevel.none => scheme.onSurfaceVariant,
      ToastLevel.success => isDark ? const Color(0xFF6ADF8E) : const Color(0xFF2E7D32),
      ToastLevel.error => scheme.error,
      ToastLevel.warn => isDark ? const Color(0xFFFFB74D) : const Color(0xFFE65100),
      ToastLevel.info => scheme.primary,
    };
  }

  @override
  String toString() => 'ToastData($title)';
}

/// One toast in the stack.
///
/// Mutable where [ToastData] is not: whether it is on its way out, and whether
/// a widget has ever picked it up, are both state the stack needs to know.
final class _ToastEntry {
  _ToastEntry(this.id, this.data);

  final int id;
  final ToastData data;

  /// Set when the toast should leave. The item widget listens, plays its exit
  /// animation, and only then removes the entry — which is why dismissing is a
  /// request rather than a list removal.
  final dismissing = ValueNotifier(false);

  /// Whether a [_ToastItem] has taken this entry. An entry that no widget ever
  /// picked up cannot animate itself out, so it is dropped outright instead.
  var mounted = false;
}

abstract final class _ToastCtrl {
  static final entries = ValueNotifier<List<_ToastEntry>>(const []);

  static var _lastId = 0;

  /// How many [ToastHost]s are in the tree.
  ///
  /// Zero in an app is a wiring mistake, but only a logged one: a widget test
  /// that pumps one page and nothing else is the same situation and is not.
  /// The toast is queued either way, and shows if a host does turn up.
  static var hosts = 0;

  static void add(ToastData data) {
    if (hosts == 0) {
      Loggers.app.warning('No ToastHost in the tree, `${data.title}` will not show');
    }

    final list = [...entries.value];
    final tag = data.tag;
    if (tag != null) {
      for (final entry in list) {
        if (entry.data.tag == tag) _dismiss(entry, list);
      }
    }

    final entry = _ToastEntry(++_lastId, data);
    if (ToastConfig.align.isTop) {
      list.insert(0, entry);
    } else {
      list.add(entry);
    }

    // Only the ones not already leaving count against the limit, else a burst
    // of toasts would evict the arrivals that replaced them.
    final alive = list.where((e) => !e.dismissing.value).toList();
    final excess = alive.length - ToastConfig.maxVisible;
    if (excess > 0) {
      // Oldest first. The list is newest-first when the stack grows downward
      // from the top, and oldest-first when it grows upward from the bottom.
      final oldestFirst = ToastConfig.align.isTop ? alive.reversed.toList() : alive;
      for (var i = 0; i < excess; i++) {
        _dismiss(oldestFirst[i], list);
      }
    }

    entries.value = list;
  }

  /// Asks [entry] to leave. Mutates [list] when the entry can be dropped right
  /// away; the caller is responsible for publishing [list].
  static void _dismiss(_ToastEntry entry, List<_ToastEntry> list) {
    if (entry.mounted) {
      entry.dismissing.value = true;
    } else {
      list.remove(entry);
    }
  }

  static void dismiss(_ToastEntry entry) {
    if (entry.dismissing.value) return;
    if (entry.mounted) {
      entry.dismissing.value = true;
      // Republished so that the stack recounts its depths: one on its way out
      // stops holding a place, and everything behind it starts moving up while
      // it is still there giving up its height.
      entries.value = [...entries.value];
      return;
    }
    remove(entry);
  }

  static void dismissAll() {
    final list = [...entries.value];
    for (final entry in [...list]) {
      _dismiss(entry, list);
    }
    entries.value = list;
  }

  /// Takes the entry out of the stack. Idempotent: an item that was dragged
  /// away and one whose exit animation ended both end up here.
  static void remove(_ToastEntry entry) {
    if (!entries.value.contains(entry)) return;
    entries.value = [...entries.value]..remove(entry);
    entry.dismissing.dispose();
  }
}

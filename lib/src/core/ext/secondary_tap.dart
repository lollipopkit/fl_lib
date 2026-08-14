import 'package:flutter/widgets.dart';

/// Right-click, for the same thing a long press does.
///
/// A long press is how a touch screen asks for "the other thing"; a pointer
/// asks by right-clicking. Neither `ListTile` nor `InkWell` takes a
/// secondary-tap callback, so this wraps rather than configures.
///
/// Not gated on the platform. `onSecondaryTapUp` only fires where there *is* a
/// secondary button — never on a phone, and on an iPad with a trackpad or an
/// Android with a mouse, which are exactly the cases worth serving. A
/// `Pfs.type` check would withhold it from them.
extension WidgetSecondaryX on Widget {
  /// [onTap] is given where the pointer was, for a menu that opens there.
  ///
  /// Null leaves the widget untouched rather than wrapping it in a detector
  /// that answers nothing.
  Widget onSecondary(void Function(Offset at)? onTap) {
    if (onTap == null) return this;
    return GestureDetector(
      // On release, not on press: Windows opens a context menu when the button
      // comes up, and releasing is also what lets someone change their mind by
      // dragging off the item first.
      onSecondaryTapUp: (details) => onTap(details.globalPosition),
      // Translucent, not opaque: this claims the secondary button and leaves
      // everything else — taps, long presses, scroll drags — to the child.
      behavior: HitTestBehavior.translucent,
      child: this,
    );
  }
}

/// A long-press callback as a secondary-tap one, ignoring the position.
///
/// For the actions that are not menus — flipping a card, opening an edit page
/// — where right-click means the same thing and has nowhere to put a position.
void Function(Offset)? asSecondary(VoidCallback? onLongPress) =>
    onLongPress == null ? null : (_) => onLongPress();

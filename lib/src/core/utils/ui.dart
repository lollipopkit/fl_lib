import 'dart:async';
import 'dart:io';

import 'package:fl_lib/fl_lib.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'window_placement.dart';

abstract final class FontUtils {
  /// Loads a font from a local file path.
  ///
  /// Derives the font name from the file name. Does nothing if the file or its
  /// name is unavailable.
  static Future<void> loadFrom(String localPath) async {
    final name = localPath.getFileName();
    if (name == null) return;
    final file = File(localPath);
    if (!await file.exists()) return;
    final fontLoader = FontLoader(name);
    fontLoader.addFont(file.readAsBytes().byteData);
    await fontLoader.load();
  }
}

abstract final class SystemUIs {
  /// Enables edge-to-edge mode with a transparent navigation bar on Android.
  static void setTransparentNavigationBar(BuildContext context) {
    if (isAndroid) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setSystemUIOverlayStyle(
        const SystemUiOverlayStyle(
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarContrastEnforced: false,
        ),
      );
    }
  }

  /// Shows or hides the system status bar.
  ///
  /// - [hide] if true, hides the status bar using immersive sticky mode.
  /// If false, shows the status bar using edge-to-edge mode.
  static void switchStatusBar({required bool hide}) {
    if (hide) {
      SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.immersiveSticky,
        overlays: [],
      );
    } else {
      SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.edgeToEdge,
        overlays: [SystemUiOverlay.top, SystemUiOverlay.bottom],
      );
    }
  }

  /// Initializes desktop window configuration.
  ///
  /// Only works on desktop platforms. On mobile platforms, this method does nothing.
  ///
  /// - [hideTitleBar] whether to hide the window title bar
  /// - [size] initial window size, if not provided uses default
  /// - [position] initial window position, if not provided or on no connected
  ///   display centers the window
  /// - [listener] optional window event listener
  static Future<void> initDesktopWindow({
    required bool hideTitleBar,
    Size? size,
    Offset? position,
    WindowStateListener? listener,
  }) async {
    if (!isDesktop) return;

    final window = WindowManager.instance.getCurrent();
    if (window == null) {
      Loggers.app.warning('initDesktopWindow: no current window');
      return;
    }

    final placement = _placeWindow(size, position);
    size = placement.size;
    position = placement.position;

    if (hideTitleBar) {
      window.titleBarStyle = TitleBarStyle.hidden;
      if (isMacOS) window.isWindowControlButtonsVisible = true;
    }
    if (window.isFullScreen) window.isFullScreen = false;
    if (window.isMaximized) window.unmaximize();
    if (window.isMinimized) window.restore();
    // Left alone on macOS, where the system title bar draws the window's
    // background: a transparent color turns into `NSColor.clear`, and on
    // macOS 27 a visible title bar with that background is fully see-through
    // (alpha 0 in a rendered frame, against 1 with the default). The default,
    // `windowBackgroundColor`, follows the system appearance, as the title text
    // drawn on it does. With the title bar hidden the Flutter view covers that
    // area, so nothing else shows it.
    if (!isMacOS) {
      window.backgroundColor = Colors.transparent.toNative();
    }
    window.isVisibleInTaskbar = true;
    window.minimumSize = const Size(300, 300).toNative();
    if (size != null && position != null) {
      window.bounds = (position & size).toNative();
    } else {
      if (size != null) {
        window.setSize(size.toNative(), false);
      }
      if (position != null) {
        window.position = position.toNative();
      } else {
        window.center();
      }
    }
    window.show();
    window.focus();
    listener?.attach(window);
  }

  /// Keeps a saved window on a connected display (a display unplugged since,
  /// a position saved while minimized). Saved values stand when the displays
  /// cannot be read.
  static WindowPlacement _placeWindow(Size? size, Offset? position) {
    if (size == null && position == null) return const WindowPlacement();
    try {
      WindowDisplay toDisplay(Display d) {
        final workArea = d.workArea.toRect();
        return WindowDisplay(
          workArea.isEmpty ? d.position.toOffset() & d.size.toSize() : workArea,
        );
      }

      final rawDisplays = DisplayManager.instance.getAll();
      final primaryDisplay = DisplayManager.instance.getPrimary();
      try {
        final displays = rawDisplays.map(toDisplay).toList();
        final primary = primaryDisplay != null
            ? toDisplay(primaryDisplay)
            : null;
        return placeWindow(
          size: size,
          position: position,
          displays: displays,
          primary: primary,
        );
      } finally {
        for (final d in rawDisplays) {
          d.dispose();
        }
        primaryDisplay?.dispose();
      }
    } catch (e, s) {
      Loggers.app.warning('Reading displays', e, s);
      return WindowPlacement(size: size, position: position);
    }
  }

  /// Updates the title bar style at runtime without restarting the app.
  ///
  /// Only works on desktop platforms.
  static Future<void> updateTitleBarStyle({required bool hideTitleBar}) async {
    if (!isDesktop) return;
    final window = WindowManager.instance.getCurrent();
    if (window != null) {
      window.titleBarStyle = hideTitleBar
          ? TitleBarStyle.hidden
          : TitleBarStyle.normal;
      if (isMacOS && hideTitleBar) {
        window.isWindowControlButtonsVisible = true;
      }
    }
    WindowFrameConfig.setShowCaption(hideTitleBar);
  }
}

void withTextFieldController(
  Future<void> Function(TextEditingController) callback,
) async {
  final controller = TextEditingController();
  try {
    await callback(controller);
    // Wait a moment to ensure any UI updates are processed
    await Future.delayed(const Duration(seconds: 3));
  } finally {
    controller.dispose();
  }
}

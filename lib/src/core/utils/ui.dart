import 'dart:async';
import 'dart:io';

import 'package:fl_lib/fl_lib.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

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
  /// - [position] initial window position, if not provided centers the window
  /// - [listener] optional window event listener
  static Future<void> initDesktopWindow({
    required bool hideTitleBar,
    Size? size,
    Offset? position,
    WindowListener? listener,
  }) async {
    if (!isDesktop) return;

    await windowManager.ensureInitialized();

    final windowOptions = WindowOptions(
      center: position == null,
      // Left alone on macOS, where the system title bar draws the window's
      // background: `window_manager` turns a transparent color into
      // `NSColor.clear`, and on macOS 27 a visible title bar with that
      // background is fully see-through (alpha 0 in a rendered frame, against
      // 1 with the default). The default, `windowBackgroundColor`, follows the
      // system appearance, as the title text drawn on it does. With the title
      // bar hidden the Flutter view covers that area, so nothing else shows it.
      backgroundColor: isMacOS ? null : Colors.transparent,
      skipTaskbar: false,
      titleBarStyle: hideTitleBar ? TitleBarStyle.hidden : null,
      minimumSize: const Size(300, 300),
      size: size,
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      if (position != null) {
        await windowManager.setPosition(position);
      }
      await windowManager.show();
      await windowManager.focus();
      if (listener != null) {
        windowManager.addListener(listener);
      }
    });
  }

  /// Updates the title bar style at runtime without restarting the app.
  ///
  /// Only works on desktop platforms.
  static Future<void> updateTitleBarStyle({required bool hideTitleBar}) async {
    if (!isDesktop) return;
    await windowManager.setTitleBarStyle(
      hideTitleBar ? TitleBarStyle.hidden : TitleBarStyle.normal,
    );
    WindowFrameConfig.setShowCaption(hideTitleBar);
  }
}

void withTextFieldController(Future<void> Function(TextEditingController) callback) async {
  final controller = TextEditingController();
  try {
    await callback(controller);
    // Wait a moment to ensure any UI updates are processed
    await Future.delayed(const Duration(seconds: 3));
  } finally {
    controller.dispose();
  }
}

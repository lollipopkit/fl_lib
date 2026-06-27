import 'dart:async';
import 'dart:io';

import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

/// Utility class for font-related operations.
abstract final class FontUtils {
  /// Loads a font from a local file path.
  ///
  /// - [localPath] is the path to the font file.
  ///
  /// The font name will be derived from the file name.
  /// If the file doesn't exist or the name can't be extracted, the operation is silently skipped.
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

/// Utility class for system UI related operations.
abstract final class SystemUIs {
  /// Sets transparent navigation bar on Android devices.
  ///
  /// Only takes effect on Android platform. On other platforms, this method does nothing.
  /// Uses edge-to-edge system UI mode with transparent navigation bar.
  static void setTransparentNavigationBar(BuildContext context) {
    if (isAndroid) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setSystemUIOverlayStyle(
        const SystemUiOverlayStyle(systemNavigationBarColor: Colors.transparent, systemNavigationBarContrastEnforced: true),
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
      backgroundColor: Colors.transparent,
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

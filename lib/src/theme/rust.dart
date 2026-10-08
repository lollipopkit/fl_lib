import 'dart:typed_data';

import 'package:fl_lib/src/rust/api/theme.dart';
import 'package:fl_lib/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;

/// fl_lib's Rust (`rust/`, `fl_theme`): what a theme package or a theme
/// repository says is read and checked there, the same code the Server Box
/// agent runs, so a package one accepts the other accepts too. This side keeps
/// the IO and the drawing.
///
/// Loaded once: [ensureInitialized] before the first theme is read (an app
/// awaits [ThemePackages.prepareSelectedTheme] at launch, which does it). The
/// synchronous reads ([ThemePackages.installed]) answer nothing until then.
abstract final class ThemeRust {
  static Future<void>? _init;

  /// Loads the library; [library] is for tests, which load the one cargo built.
  static Future<void> ensureInitialized({ExternalLibrary? library}) =>
      _init ??= RustLib.init(externalLibrary: library);

  static bool get ready => RustLib.instance.initialized;

  /// Checks a `.fsbt`.
  static Future<PreparedTheme> preparePackage(List<int> bytes) async {
    await ensureInitialized();
    return _checked(() => prepareThemePackage(bytes: bytes));
  }

  /// Checks a theme given as its files.
  static Future<PreparedTheme> prepareFiles(Map<String, Uint8List> files) async {
    await ensureInitialized();
    return _checked(
      () => prepareThemeFiles(
        files: [
          for (final MapEntry(key: path, value: bytes) in files.entries)
            ThemeFile(path: path, bytes: bytes),
        ],
      ),
    );
  }

  /// A refusal in the installer's own words, as this side has always thrown it.
  static Future<T> _checked<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on ThemeFailure catch (e) {
      throw FormatException(e.message);
    }
  }
}

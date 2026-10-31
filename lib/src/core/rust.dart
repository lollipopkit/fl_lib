import 'package:fl_lib/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;

/// fl_lib's Rust (`rust/ffi`): the theme packages (`fl_theme`) and LK Cloud
/// (`fl_lkc`) share one library, loaded once.
abstract final class FlRust {
  static Future<void>? _init;

  /// Loads the library; [library] is for tests, which load the one cargo built.
  static Future<void> ensureInitialized({ExternalLibrary? library}) =>
      _init ??= RustLib.init(externalLibrary: library);

  static bool get ready => RustLib.instance.initialized;
}

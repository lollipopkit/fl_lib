import 'package:fl_lib/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;

/// fl_lib's Rust (`rust/ffi`): the theme packages (`fl_theme`) and LK Cloud
/// (`fl_lkc`) share one library, loaded once.
abstract final class FlRust {
  static Future<void>? _init;

  /// Loads the library; [library] is for tests, which load the one cargo built.
  /// Clears the cached future on failure so later callers can retry.
  static Future<void> ensureInitialized({ExternalLibrary? library}) {
    final future = _init ??= RustLib.init(externalLibrary: library).catchError((Object e, StackTrace s) {
      _init = null;
      Error.throwWithStackTrace(e, s);
    });
    return future;
  }

  static bool get ready => RustLib.instance.initialized;
}

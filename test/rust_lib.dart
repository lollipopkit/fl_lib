import 'dart:io';

import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;

/// fl_lib's Rust as cargo built it: `cargo build -p fl_lib_ffi` in `rust/`.
Future<void> loadFlRustForTest() {
  final library = [
    if (Platform.isMacOS) 'rust/target/debug/libfl_lib_ffi.dylib',
    if (Platform.isLinux) 'rust/target/debug/libfl_lib_ffi.so',
    if (Platform.isWindows) 'rust/target/debug/fl_lib_ffi.dll',
  ].firstWhere(
    (path) => File(path).existsSync(),
    orElse: () => throw StateError(
      'fl_lib_ffi not built: run `cargo build -p fl_lib_ffi` in rust/',
    ),
  );
  return FlRust.ensureInitialized(library: ExternalLibrary.open(library));
}

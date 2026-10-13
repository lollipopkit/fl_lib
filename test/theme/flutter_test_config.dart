import 'dart:async';
import 'dart:io';

import 'package:fl_lib/src/theme/rust.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;

import 'helper.dart';

/// Runs before every test file under `test/theme/`: the theme code reads its
/// host from where an app sets it at launch, so this is the tests' launch.
///
/// Themes are read in Rust (`rust/`): the library cargo built is loaded here,
/// so `cargo build -p fl_lib_ffi` (in `rust/`) comes first.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  initTestThemeHost();
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
  await ThemeRust.ensureInitialized(library: ExternalLibrary.open(library));
  await testMain();
}

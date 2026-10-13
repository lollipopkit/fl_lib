import 'dart:io';

import 'package:flutter_rust_bridge_hooks/flutter_rust_bridge_hooks.dart';

import 'rust_build_environment.dart';

/// Builds `rust/ffi` (theme packages and the theme store, `fl_theme`) and
/// hands the library to the Dart/Flutter SDK as a code asset: no pod, Swift
/// package or Gradle plugin, and an app on fl_lib needs nothing else.
void main(List<String> args) async {
  await build(args, (input, output) async {
    await FlutterRustBridgeNativeAssetsBuilder(
      cratePath: 'rust/ffi',
      extraCargoEnvironmentVariables: reproducibleCargoEnvironment(
        environment: Platform.environment,
        packageRoot: Directory.fromUri(input.packageRoot).path,
        isWindows: Platform.isWindows,
      ),
    ).run(input: input, output: output);
  });
}

import 'dart:io';

import 'package:fl_lib/src/core/utils/platform/base.dart';

/// Archs that Flutter can runs on.
enum CpuArch {
  amd64,
  arm64,
  arm,
  ;

  static const amd64Codes = ['x86_64', 'amd64'];
  static const arm64Codes = [
    'arm64',
    'aarch64',
    'armv8',
    'armv8a',
    'arm64-v8a',
    'arm64e'
  ];
  static const armCodes = [
    'arm',
    'armv7',
    'armv7a',
    'armv7l',
    'armv6',
    'armv6l',
    'armeabi',
    'armeabi-v7a',
    'armv5',
    'armv5te'
  ];

  static CpuArch? _current;

  /// The architecture of the machine this runs on.
  ///
  /// The machine, not the process: on macOS the two differ, and every caller
  /// wants the machine — this is what picks the download an update offers, and
  /// a Mac that can run the native build should be offered it.
  ///
  /// Answered once. Everything below spawns a process, and the update check
  /// asks for this once per release in the list; the answer cannot change while
  /// this one is running.
  static CpuArch get current => _current ??= _resolve();

  static CpuArch _resolve() {
    switch (Pfs.type) {
      case Pfs.windows:
        final cpu = Platform.environment['PROCESSOR_ARCHITECTURE'];
        return switch (cpu) {
          'AMD64' => CpuArch.amd64,
          'ARM64' => CpuArch.arm64,
          _ => throw UnsupportedError('Unsupported CPU architecture: $cpu'),
        };
      case Pfs.ios:
        return CpuArch.arm64;
      case Pfs.macos:
        // `uname -m` answers for the process: an x86_64 build on Apple Silicon
        // runs under Rosetta and reads back `x86_64`, as does anything it
        // spawns. Taken at face value that machine is offered the Intel
        // download for good, which is how an install stays translated across
        // every update it ever takes.
        if (_isRosetta) return CpuArch.arm64;
        return _fromUname();
      case Pfs.linux || Pfs.android || Pfs.fuchsia:
        return _fromUname();
      case Pfs.web || Pfs.unknown:
        throw UnsupportedError('Unsupported platform: ${Pfs.type}');
    }
  }

  static CpuArch _fromUname() {
    final cpu = Process.runSync('uname', ['-m']);
    if (cpu.exitCode != 0) {
      throw Exception('Failed to run uname -m: ${cpu.stderr}');
    }
    final output = cpu.stdout.toString().trim();
    if (amd64Codes.contains(output)) return CpuArch.amd64;
    if (arm64Codes.contains(output)) return CpuArch.arm64;
    if (armCodes.contains(output)) return CpuArch.arm;
    throw UnsupportedError('Unsupported CPU architecture: $output');
  }

  /// Whether this process is an x86_64 binary translated onto Apple Silicon.
  ///
  /// `sysctl.proc_translated` is Apple's own answer to this and the only one
  /// that is not a guess: it is 1 under Rosetta, 0 for a native process, and
  /// absent on an Intel Mac — where `sysctl` exits non-zero, which reads as
  /// false the same way.
  static bool get _isRosetta {
    try {
      final result = Process.runSync('sysctl', ['-n', 'sysctl.proc_translated']);
      if (result.exitCode != 0) return false;
      return result.stdout.toString().trim() == '1';
    } catch (_) {
      return false;
    }
  }
}

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:fl_lib/src/core/utils/platform/arch.dart';
import 'package:fl_lib/src/core/utils/platform/base.dart';

class AppUpdate {
  const AppUpdate({
    required this.changelog,
    required this.build,
    required this.url,
  });

  final AppUpdatePlatformSpecific<String> changelog;
  final AppUpdateBuild build;
  final AppUpdateArchSpec<AppUpdatePlatformSpecific<String>> url;

  static Future<AppUpdate> fromUrl(String url) async {
    final resp = await Dio().get(url);
    return AppUpdate.fromJson(resp.data);
  }

  factory AppUpdate.fromJson(Map<String, dynamic> json) => AppUpdate(
        changelog: AppUpdatePlatformSpecific.fromJson(json["changelog"]),
        build: AppUpdateBuild.fromJson(json["build"]),
        url: AppUpdateArchSpec.fromJson(json["urls"]),
      );

  Map<String, dynamic> toJson() => {
        "changelog": changelog.toJson(),
        "build": build.toJson(),
        "urls": url.toJson(),
      };
}

class AppUpdateBuild {
  AppUpdateBuild({
    required this.min,
    required this.last,
  });

  final AppUpdatePlatformSpecific<int> min;
  final AppUpdatePlatformSpecific<int> last;

  factory AppUpdateBuild.fromRawJson(String str) =>
      AppUpdateBuild.fromJson(json.decode(str));

  String toRawJson() => json.encode(toJson());

  factory AppUpdateBuild.fromJson(Map<String, dynamic> json) => AppUpdateBuild(
        min: AppUpdatePlatformSpecific.fromJson(json["min"]),
        last: AppUpdatePlatformSpecific.fromJson(json["last"]),
      );

  Map<String, dynamic> toJson() => {
        "min": min.toJson(),
        "last": last.toJson(),
      };
}

class AppUpdateArchSpec<T> {
  final T? x64;
  final T? arm;
  final T? arm64;
  final T? rv64;

  AppUpdateArchSpec({
    required this.x64,
    required this.arm,
    required this.arm64,
    required this.rv64,
  });

  factory AppUpdateArchSpec.fromRawJson(String str) =>
      AppUpdateArchSpec.fromJson(json.decode(str));

  factory AppUpdateArchSpec.fromJson(Map<String, dynamic> json) =>
      AppUpdateArchSpec(
        x64: json["x64"],
        arm: json["arm"],
        arm64: json["arm64"],
        rv64: json["rv64"],
      );

  Map<String, dynamic> toJson() => {
        "x64": x64,
        "arm": arm,
        "arm64": arm64,
        "rv64": rv64,
      };

  T? get current {
    final arch = CpuArch.current;
    return switch (arch) {
      CpuArch.arm => arm,
      CpuArch.arm64 => arm64,
      CpuArch.x64 => x64,
    };
  }
}

class AppUpdatePlatformSpecific<T> {
  AppUpdatePlatformSpecific({
    required this.mac,
    required this.ios,
    required this.android,
    required this.windows,
    required this.linux,
    required this.web,
  });

  final T? mac;
  final T? ios;
  final T? android;
  final T? windows;
  final T? linux;
  final T? web;

  factory AppUpdatePlatformSpecific.fromRawJson(String str) =>
      AppUpdatePlatformSpecific.fromJson(json.decode(str));

  String toRawJson() => json.encode(toJson());

  factory AppUpdatePlatformSpecific.fromJson(Map<String, dynamic> json) =>
      AppUpdatePlatformSpecific(
        mac: json["mac"],
        ios: json["ios"],
        android: json["android"],
        windows: json["windows"],
        linux: json["linux"],
        web: json["web"],
      );

  Map<String, dynamic> toJson() => {
        "mac": mac,
        "ios": ios,
        "android": android,
        "windows": windows,
        "linux": linux,
        "web": web,
      };

  T? get current {
    return switch (Pfs.type) {
      Pfs.macos => mac,
      Pfs.ios => ios,
      Pfs.android => android,
      Pfs.windows => windows,
      Pfs.linux => linux,
      Pfs.web => web,
      _ => null,
    };
  }
}

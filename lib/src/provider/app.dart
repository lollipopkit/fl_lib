import 'package:material_ui/material_ui.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'app.g.dart';
part 'app.freezed.dart';

@freezed
abstract class AppState with _$AppState {
  const factory AppState({
    @Default(Color(0xff8b2252)) Color primaryColor,
    @Default(Locale('en')) Locale locale,
  }) = _AppState;
}

@Riverpod(keepAlive: true)
class AppStates extends _$AppStates {
  static BuildContext? ctx;

  @override
  AppState build() {
    return const AppState();
  }
}
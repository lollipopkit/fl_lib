// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(AppStates)
final appStatesProvider = AppStatesProvider._();

final class AppStatesProvider extends $NotifierProvider<AppStates, AppState> {
  AppStatesProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'appStatesProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$appStatesHash();

  @$internal
  @override
  AppStates create() => AppStates();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(AppState value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<AppState>(value),
    );
  }
}

String _$appStatesHash() => r'ef96f10f6fff0f3dd6d3128ebf070ad79cbc8bc9';

abstract class _$AppStates extends $Notifier<AppState> {
  AppState build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<AppState, AppState>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<AppState, AppState>,
              AppState,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

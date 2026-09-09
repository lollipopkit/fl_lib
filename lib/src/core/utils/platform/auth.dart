import 'package:fl_lib/src/res/l10n.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

abstract final class LocalAuth {
  static final _auth = LocalAuthentication();

  static bool _isAuthing = false;

  /// {@template local_auth_for_test}
  /// Stands in for the platform, so the pages built on this can be tested.
  ///
  /// `local_auth` is a plugin, and a plugin call's future does not complete
  /// inside the fake-async zone a `testWidgets` body runs in — it neither
  /// resolves nor throws. A widget waiting on [isAvail] therefore renders its
  /// loading state for ever, and the test reads as "the control is missing"
  /// rather than "the platform never answered". Nothing in a shipped build
  /// assigns these.
  ///
  /// Both, not one: [goWithResult] consults [isAvail] before the prompt, so
  /// overriding only the first still leaves the prompt itself unreachable.
  /// {@endtemplate}
  @visibleForTesting
  static Future<bool> Function()? isAvailForTest;

  /// {@macro local_auth_for_test}
  @visibleForTesting
  static Future<AuthResult> Function({bool onlyBio})? goWithResultForTest;

  /// Whether this device can answer an authentication prompt at all.
  ///
  /// False for a desktop with no sensor, for a phone with nothing enrolled,
  /// and for any platform the plugin does not implement. A caller that holds
  /// the UI until this passes has to handle it, or it holds the UI for ever.
  static Future<bool> get isAvail async {
    final forTest = isAvailForTest;
    if (forTest != null) return forTest();
    try {
      return await _auth.canCheckBiometrics || await _auth.isDeviceSupported();
    } catch (e) {
      return false;
    }
  }

  static Future<void> go({
    VoidCallback? onUnavailable,
    int maxRetries = 3,
  }) async {
    if (_isAuthing) return;
    _isAuthing = true;

    try {
      var retries = 0;
      while (retries < maxRetries) {
        final val = await goWithResult();
        switch (val) {
          case AuthResult.success:
            return;
          case AuthResult.notAvail:
            onUnavailable?.call();
            return;
          case AuthResult.lockedOut:
            return;
          case AuthResult.fail:
          case AuthResult.cancel:
            retries++;
            if (retries >= maxRetries) return;
            break;
        }
      }
    } finally {
      _isAuthing = false;
    }
  }

  static Future<AuthResult> goWithResult({bool onlyBio = false}) async {
    final forTest = goWithResultForTest;
    if (forTest != null) return forTest(onlyBio: onlyBio);
    if (!await isAvail) return AuthResult.notAvail;
    try {
      final result = await _auth.authenticate(
        localizedReason: '🔐 ${l10n.authRequired}',
        biometricOnly: onlyBio,
        sensitiveTransaction: false,
        persistAcrossBackgrounding: true,
      );
      if (result) {
        return AuthResult.success;
      }
      return AuthResult.fail;
    } on LocalAuthException catch (e) {
      switch (e.code) {
        case LocalAuthExceptionCode.noBiometricsEnrolled:
          return AuthResult.notAvail;
        case LocalAuthExceptionCode.temporaryLockout:
        case LocalAuthExceptionCode.biometricLockout:
          return AuthResult.lockedOut;
        default:
          return AuthResult.cancel;
      }
    } on PlatformException {
      return AuthResult.cancel;
    }
  }
}

enum AuthResult {
  success,
  fail,
  cancel,
  notAvail,
  lockedOut,
}

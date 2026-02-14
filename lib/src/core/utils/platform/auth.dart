import 'package:fl_lib/src/res/l10n.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

abstract final class LocalAuth {
  static final _auth = LocalAuthentication();

  static bool _isAuthing = false;

  static Future<bool> get isAvail async {
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

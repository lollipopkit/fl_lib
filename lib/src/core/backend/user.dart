part of 'api.dart';

/// If current user is anonymous, it will be called to prompt user to confirm.
/// Return true to confirm following actions.
typedef AnonUserConfirmFn = Future<bool> Function();

/// User APIs
abstract final class UserApi {
  /// API token. Stored in shared preferences.
  static const tokenProp = PrefProp<String>('lpkt_api_token');

  /// Whether the user is logged in. By checking the token.
  static bool get loggedIn => tokenProp.get() != null;

  /// Current user.
  static final user = nvn<User>();

  /// Get auth headers.
  static Map<String, String>? get authHeaders {
    final t = tokenProp.get();
    if (t == null || t.isEmpty) return null;
    return {'Authorization': t};
  }

  /// Logout, clear token and user.
  static Future<void> logout(AnonUserConfirmFn anonConfirm) async {
    if (user.value?.isAnon == true) {
      if (!await anonConfirm()) return;
    }
    await tokenProp.remove();
    user.value = null;
  }

  /// Login with OAuth.
  ///
  /// Before using this method, you should set [DeepLinks.appId] at first.
  static Future<void> login() async {
    if (DeepLinks.appId == null) {
      throw StateError('[DeepLinks.appId] is not set');
    }
    await launchUrlString(
      '${ApiUrls.oauth}?app_id=${DeepLinks.appId}',
      mode: LaunchMode.externalApplication,
    );
  }

  /// Edit current user.
  ///
  /// [name] and [avatar] are optional.
  static Future<void> edit({String? name, String? avatar}) async {
    final body = <String, dynamic>{};
    if (name != null) body['name'] = name;
    if (avatar != null) {
      if (avatar.isEmpty) {
        body['avatar'] = null;
      } else {
        body['avatar'] = avatar;
      }
    }
    await myDio.post(
      ApiUrls.user,
      data: body,
      options: Options(
        headers: authHeaders,
        responseType: ResponseType.json,
      ),
    );
    await refresh();
  }

  /// Refresh current user.
  ///
  /// It will update [UserApi.user] value.
  static Future<void> refresh() async {
    final resp = await myDio.get(
      ApiUrls.user,
      options: Options(
        headers: authHeaders,
        responseType: ResponseType.json,
      ),
    );
    final data = _getRespData<Map<dynamic, dynamic>>(resp.data);
    if (data == null) throw 'Invalid resp: ${resp.data}';
    user.value = User.fromJson(data.cast());
    dprint(user.value);
  }

  /// Delete current user.
  ///
  /// If current user is anonymous, it will be called to prompt user to confirm.
  static Future<void> delete(AnonUserConfirmFn onAnonUser) async {
    if (user.value?.isAnon == true) {
      if (!await onAnonUser()) return;
    }
    await myDio.delete(
      ApiUrls.user,
      options: Options(headers: authHeaders),
    );
    await logout(() async => true);
  }

  static Future<void> init() async {
    if (loggedIn) await refresh();
  }
}
